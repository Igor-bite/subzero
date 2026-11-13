import AppKit
import Foundation
import FreezerCore
import Observation

/// A row in the "programs" list: a protected rule or an app frozen by hand.
struct ControlledApp: Identifiable, Equatable {
    enum State: Equatable {
        case notRunning
        case running
        case frozen
    }

    let id: UUID
    let name: String
    let kind: AppRuleKind
    /// Covered by an enabled protection rule.
    let isProtected: Bool
    let state: State
    /// Frozen by the user, independent of the IP.
    let isManuallyFrozen: Bool
    /// Protected, but the user let it run during the current block.
    let isOverridden: Bool
}

/// An app the user froze by hand. Persisted, so it stays frozen across restarts.
struct ManualFreeze: Codable, Equatable {
    var id: UUID
    var name: String
    var kind: AppRuleKind
}

/// Orchestrates checks and enforcement. All state lives on the main actor.
///
/// Enforcement is declarative: every tick computes the set of processes that
/// should be stopped (auto-protected while blocked, plus manual freezes) and
/// sends SIGSTOP/SIGCONT only for the difference.
@MainActor
@Observable
final class GuardEngine {
    enum Phase: Equatable {
        case checking
        case protected
        case blocked(BlockReason)
        case paused(until: Date)
    }

    // MARK: Published state

    var config: GuardConfig {
        didSet {
            guard config != oldValue else { return }
            persist()
            configChanged(from: oldValue)
        }
    }

    private(set) var snapshot: NetworkSnapshot?
    private(set) var verdict: Verdict?
    private(set) var lastCheck: Date?
    private(set) var isChecking = false
    private(set) var pausedUntil: Date?
    private(set) var killDeadline: Date?
    /// Protected rules whose processes are frozen because of the IP.
    private(set) var frozenRuleIDs: Set<UUID> = []
    private(set) var manualFreezes: [ManualFreeze] = []
    /// Protected rules the user unfroze during the current block.
    private(set) var overrides: Set<UUID> = []
    private(set) var appStates: [UUID: ControlledApp.State] = [:]
    private(set) var lastError: String?
    /// Updated every tick so countdowns refresh.
    private(set) var now = Date()

    // MARK: Private state

    private let store: ConfigStore
    private let defaults: UserDefaults?
    private static let manualKey = "manualFreezes"
    private let probe = IPProbe()
    private let notifier = Notifier()
    private var enforcer = Enforcer()
    private var frozenPIDs: Set<Int32> = []
    private var lastScan = Date.distantPast
    private var networkChangePending = true   // fail closed until the first check
    private var sleeping = false
    private var announcedBlock = false
    private var notifiedDNSResolver: IPAddress?
    private var activeChecks = 0
    private var started = false

    private var loopTask: Task<Void, Never>?
    private var ticker: Timer?
    private var networkMonitor: NetworkChangeMonitor?
    private var observers: [NSObjectProtocol] = []

    init(store: ConfigStore = .standard, defaults: UserDefaults? = .standard) {
        self.store = store
        self.defaults = defaults
        self.config = store.load()
        // Manual freezes from older bundle ids arrive via DefaultsMigration (AppDelegate.init).
        if let data = defaults?.data(forKey: Self.manualKey), let saved = try? JSONDecoder().decode([ManualFreeze].self, from: data) {
            manualFreezes = saved
        }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        notifier.enabled = config.notifications
        notifier.requestAuthorizationIfNeeded()

        let monitor = NetworkChangeMonitor { [weak self] _ in
            Task { @MainActor in self?.networkChanged() }
        }
        monitor.start()
        networkMonitor = monitor

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        })

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer

        tick()
        requestCheck()
    }

    /// Unfreezes everything we stopped (manual freezes come back on next launch). Called on quit.
    func shutdown() {
        guard started else { return }
        let targets = currentTargets().keys
        started = false
        loopTask?.cancel()
        ticker?.invalidate()
        networkMonitor?.stop()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()

        ProcessSignaler.send(SIGCONT, to: Set(targets).union(frozenPIDs))
        frozenPIDs.removeAll()
        frozenRuleIDs.removeAll()
    }

    // MARK: Derived state

    var phase: Phase {
        if let until = pausedUntil, until > now { return .paused(until: until) }
        if networkChangePending || sleeping { return .checking }
        switch verdict {
        case .none: return .checking
        case .allowed: return .protected
        case .blocked(let reason): return .blocked(reason)
        }
    }

    var enabledRules: [AppRule] { config.apps.filter(\.enabled) }

    var frozenAppNames: [String] {
        config.apps.filter { frozenRuleIDs.contains($0.id) }.map(\.name)
    }

    /// DNS leak shown as a warning (only when the DNS check is in "warn" mode).
    var dnsWarning: DNSLeak? {
        guard config.dnsCheck == .warn, let snapshot else { return nil }
        return dnsLeak(in: snapshot, rules: config.allowRules)
    }

    var controlledApps: [ControlledApp] {
        let rules = enabledRules
        let ruleKinds = Set(rules.map(\.kind))
        let manualKinds = Set(manualFreezes.map(\.kind))
        var result = rules.map { rule in
            ControlledApp(
                id: rule.id, name: rule.name, kind: rule.kind, isProtected: true,
                state: appStates[rule.id] ?? .notRunning,
                isManuallyFrozen: manualKinds.contains(rule.kind),
                isOverridden: overrides.contains(rule.id)
            )
        }
        for entry in manualFreezes where !ruleKinds.contains(entry.kind) {
            result.append(ControlledApp(
                id: entry.id, name: entry.name, kind: entry.kind, isProtected: false,
                state: appStates[entry.id] ?? .notRunning,
                isManuallyFrozen: true, isOverridden: false
            ))
        }
        return result
    }

    private var shouldBlock: Bool {
        if let until = pausedUntil, until > now { return false }
        if networkChangePending || sleeping { return true }
        guard let verdict else { return true }
        return !verdict.isAllowed
    }

    // MARK: User actions: protection

    func requestCheck() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func pause(for duration: TimeInterval?) {
        pausedUntil = duration.map { Date().addingTimeInterval($0) } ?? .distantFuture
        tick()
    }

    func endPause() {
        pausedUntil = nil
        networkChangePending = true
        tick()
        requestCheck()
    }

    func allowIP(_ ip: IPAddress) {
        let text = ip.description
        guard !config.allowedNetworks.contains(text) else { return }
        config.allowedNetworks.append(text)
    }

    func allowCountry(_ code: String) {
        let upper = code.uppercased()
        guard !config.allowedCountries.contains(upper) else { return }
        config.allowedCountries.append(upper)
    }

    // MARK: User actions: manual control

    /// Freeze now and keep frozen until unfrozen by hand, whatever the IP.
    func freezeManually(kind: AppRuleKind, name: String) {
        if let rule = enabledRules.first(where: { $0.kind == kind }) {
            overrides.remove(rule.id)
        }
        if !manualFreezes.contains(where: { $0.kind == kind }) {
            manualFreezes.append(ManualFreeze(id: UUID(), name: name, kind: kind))
            saveManualFreezes()
        }
        reconcile(force: true)
    }

    func freeze(_ app: ControlledApp) {
        freezeManually(kind: app.kind, name: app.name)
    }

    /// Unfreeze now. A protected app unfrozen during a block runs until the block ends.
    func unfreeze(_ app: ControlledApp) {
        manualFreezes.removeAll { $0.kind == app.kind }
        saveManualFreezes()
        if app.isProtected && shouldBlock {
            overrides.insert(app.id)
        }
        reconcile(force: true)
    }

    /// SIGKILL every process of the app right now.
    func forceKill(_ app: ControlledApp) {
        manualFreezes.removeAll { $0.kind == app.kind }
        saveManualFreezes()
        let processes = ProcessScanner.snapshot(includeInterpreterArguments: app.kind.needsArguments)
        let victims = ProcessMatcher.targets(processes: processes, rules: [(app.id, app.kind)], excludingPIDs: [getpid()])
        ProcessSignaler.send(SIGKILL, to: victims.keys)
        frozenPIDs.subtract(victims.keys)
        reconcile(force: true)
    }

    // MARK: Check loop

    private func runLoop() async {
        while !Task.isCancelled {
            await performCheck()
            if Task.isCancelled { return }
            let allowed = verdict?.isAllowed == true && !networkChangePending
            let interval = allowed ? max(5, config.checkInterval) : 5
            try? await Task.sleep(for: .seconds(interval))
        }
    }

    private func performCheck() async {
        activeChecks += 1
        isChecking = true
        defer {
            activeChecks -= 1
            isChecking = activeChecks > 0
        }

        let snap = await probe.snapshot(includeIPv6: config.checkIPv6, includeDNS: config.dnsCheck != .off)
        guard !Task.isCancelled else { return }

        snapshot = snap
        lastCheck = Date()
        networkChangePending = false
        verdict = evaluate(snap, rules: config.allowRules, settings: config.policySettings)
        notifyDNSWarningIfNeeded()
        tick()
    }

    private func notifyDNSWarningIfNeeded() {
        guard let leak = dnsWarning else {
            notifiedDNSResolver = nil
            return
        }
        guard notifiedDNSResolver != leak.resolver else { return }
        notifiedDNSResolver = leak.resolver
        notifier.post(
            title: "Возможна утечка DNS",
            body: "DNS-запросы идут через резолвер в \(CountryInfo.flag(leak.country)) \(CountryInfo.name(leak.country)), а не через страну VPN."
        )
    }

    // MARK: Events

    private func networkChanged() {
        guard started else { return }
        if config.freezeOnNetworkChange {
            networkChangePending = true
            tick()
        }
        requestCheck()
    }

    private func willSleep() {
        sleeping = true
        tick()
    }

    private func didWake() {
        sleeping = false
        networkChangePending = true
        tick()
        requestCheck()
    }

    private func configChanged(from old: GuardConfig) {
        notifier.enabled = config.notifications
        if old.notifications != config.notifications, config.notifications {
            notifier.requestAuthorizationIfNeeded()
        }
        // Re-judge the last observation right away (e.g. "allow this country").
        if let snapshot {
            verdict = evaluate(snapshot, rules: config.allowRules, settings: config.policySettings)
        }
        let enabledIDs = Set(enabledRules.map(\.id))
        overrides.formIntersection(enabledIDs)
        if old.checkIPv6 != config.checkIPv6 || old.checkInterval != config.checkInterval
            || old.minAgree != config.minAgree || old.dnsCheck != config.dnsCheck {
            requestCheck()
        }
        if started {
            tick()
            reconcile(force: true)
        }
    }

    private func persist() {
        do {
            try store.save(config)
            lastError = nil
        } catch {
            lastError = "Не удалось сохранить настройки: \(error.localizedDescription)"
        }
    }

    private func saveManualFreezes() {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(manualFreezes) {
            defaults.set(data, forKey: Self.manualKey)
        }
    }

    // MARK: Enforcement

    /// Everything we may act on: enabled rules plus manual freezes not covered by a rule.
    private var subjects: [(id: UUID, kind: AppRuleKind)] {
        let rules = enabledRules
        let ruleKinds = Set(rules.map(\.kind))
        return rules.map { ($0.id, $0.kind) }
            + manualFreezes.filter { !ruleKinds.contains($0.kind) }.map { ($0.id, $0.kind) }
    }

    /// Subject ids that are frozen by hand (the rule's id when a rule covers the same app).
    private var manualSubjectIDs: Set<UUID> {
        let ruleByKind = Dictionary(enabledRules.map { ($0.kind, $0.id) }, uniquingKeysWith: { first, _ in first })
        return Set(manualFreezes.map { ruleByKind[$0.kind] ?? $0.id })
    }

    private func currentTargets() -> [Int32: UUID] {
        let subjects = subjects
        guard !subjects.isEmpty else { return [:] }
        let processes = ProcessScanner.snapshot(includeInterpreterArguments: subjects.contains { $0.kind.needsArguments })
        return ProcessMatcher.targets(processes: processes, rules: subjects, excludingPIDs: [getpid()])
    }

    private func tick() {
        guard started else { return }
        now = Date()
        if let until = pausedUntil, until <= now {
            pausedUntil = nil
            networkChangePending = true
            notifier.post(title: "Пауза закончилась", body: "Проверяю IP и снова защищаю программы.")
            requestCheck()
        }

        let grace: TimeInterval? = config.killAfterGrace ? config.grace : nil
        let blocked = shouldBlock
        let action = enforcer.step(blocked: blocked, now: now, grace: grace)
        let deadline = blocked ? enforcer.deadline(grace: grace) : nil
        if killDeadline != deadline { killDeadline = deadline }
        if action == .resume, !overrides.isEmpty { overrides.removeAll() }

        reconcile(action: action, force: false)

        if action == .resume, announcedBlock {
            announcedBlock = false
            notifier.post(title: "Программы снова работают", body: statusLine())
        }
        announceIfNeeded()
    }

    private func reconcile(action: EnforcementAction = .none, force: Bool) {
        guard started else { return }
        let blocked = shouldBlock
        let busy = blocked || !manualFreezes.isEmpty || !frozenPIDs.isEmpty || action != .none
        // Scan every second while enforcing, every 2 s otherwise (for the status list).
        guard force || busy || Date().timeIntervalSince(lastScan) >= 1.9 else { return }
        lastScan = Date()

        var targets = currentTargets()
        let autoIDs = Set(enabledRules.map(\.id)).subtracting(overrides)
        let manualIDs = manualSubjectIDs

        if action == .kill {
            // Kill what is frozen because of the IP; hand-frozen apps stay frozen.
            let victims = targets.filter { autoIDs.contains($0.value) && !manualIDs.contains($0.value) }
            if !victims.isEmpty {
                ProcessSignaler.send(SIGKILL, to: victims.keys)
                frozenPIDs.subtract(victims.keys)
                targets = targets.filter { victims[$0.key] == nil }
                let ids = Set(victims.values)
                let names = config.apps.filter { ids.contains($0.id) }.map(\.name)
                notifier.post(title: "Закрыл программы", body: "Разрешённый IP не вернулся: \(names.joined(separator: ", "))")
            }
        }

        var desired = Set<Int32>()
        var pidsByID: [UUID: [Int32]] = [:]
        for (pid, id) in targets {
            pidsByID[id, default: []].append(pid)
            if manualIDs.contains(id) || (blocked && autoIDs.contains(id)) {
                desired.insert(pid)
            }
        }

        let toStop = desired.subtracting(frozenPIDs)
        var toContinue = frozenPIDs.subtracting(desired)
        if action == .resume {
            // Also release matches we did not track: recovers apps left
            // stopped by a previous crash of Freezer.
            let autoPIDs = targets.filter { autoIDs.contains($0.value) }.keys
            toContinue.formUnion(Set(autoPIDs).subtracting(desired))
        }
        if !toStop.isEmpty { ProcessSignaler.send(SIGSTOP, to: toStop) }
        if !toContinue.isEmpty { ProcessSignaler.send(SIGCONT, to: toContinue) }
        frozenPIDs = desired

        var states: [UUID: ControlledApp.State] = [:]
        for subject in subjects {
            let pids = pidsByID[subject.id] ?? []
            if pids.isEmpty {
                states[subject.id] = .notRunning
            } else {
                states[subject.id] = pids.allSatisfy(desired.contains) ? .frozen : .running
            }
        }
        if appStates != states { appStates = states }

        // Dock badge: how many apps stand frozen right now.
        let frozenCount = states.values.filter { $0 == .frozen }.count
        let badge = frozenCount > 0 ? "\(frozenCount)" : nil
        if NSApp.dockTile.badgeLabel != badge { NSApp.dockTile.badgeLabel = badge }

        let autoFrozen = Set(targets.filter { desired.contains($0.key) && autoIDs.contains($0.value) && !manualIDs.contains($0.value) }.values)
        let newFrozenRules = blocked ? autoFrozen : []
        if frozenRuleIDs != newFrozenRules { frozenRuleIDs = newFrozenRules }
    }

    /// Notify once per block episode, and only for real verdicts (not the
    /// sub-second freeze while re-checking after a network change).
    private func announceIfNeeded() {
        guard !announcedBlock, case .blocked(let reason) = phase, !frozenRuleIDs.isEmpty else { return }
        announcedBlock = true
        notifier.post(title: "Программы заморожены: \(frozenAppNames.joined(separator: ", "))", body: reason.text)
    }

    private func statusLine() -> String {
        guard let ip = verdict.flatMap({ if case .allowed(let ip) = $0 { ip } else { nil } }) else { return "IP в порядке" }
        let country = snapshot?.countries[ip].map { " \(CountryInfo.flag($0)) \($0)" } ?? ""
        return "IP \(ip)\(country)"
    }

    #if DEBUG
    /// Puts the engine into a fixed state for UI snapshots. Never starts checks or signals.
    func debugApply(
        snapshot: NetworkSnapshot?,
        verdict: Verdict?,
        appStates: [UUID: ControlledApp.State] = [:],
        frozenRuleIDs: Set<UUID> = [],
        manualFreezes: [ManualFreeze] = [],
        overrides: Set<UUID> = [],
        pausedUntil: Date? = nil,
        killDeadline: Date? = nil
    ) {
        self.snapshot = snapshot
        self.verdict = verdict
        self.lastCheck = Date()
        self.networkChangePending = false
        self.appStates = appStates
        self.frozenRuleIDs = frozenRuleIDs
        self.manualFreezes = manualFreezes
        self.overrides = overrides
        self.pausedUntil = pausedUntil
        self.killDeadline = killDeadline
        self.now = Date()
    }
    #endif
}

extension AppRuleKind {
    var needsArguments: Bool {
        if case .patterns = self { return true }
        return false
    }
}

// MARK: - Text

extension BlockReason {
    var text: String {
        switch self {
        case .offline:
            return "Сервисы IP не отвечают: нет интернета или запросы блокируются."
        case .servicesDisagree(let ips):
            return "Сервисы видят разные IP (\(ips.map(\.description).joined(separator: ", "))) — похоже на утечку."
        case .notEnoughAnswers(let got, let need):
            return "IP подтвердили \(got) из \(need) нужных сервисов."
        case .countryUnknown(let ip):
            return "Не удалось определить страну для \(ip)."
        case .notAllowed(let ip, let country):
            return "IP \(ip)\(country.map { " (\(CountryInfo.flag($0)) \(CountryInfo.name($0)))" } ?? "") не разрешён."
        case .ipv6Leak(let ip, let country):
            return "Утечка IPv6: \(ip)\(country.map { " (\(CountryInfo.flag($0)) \($0))" } ?? "") идёт мимо VPN."
        case .ipv6Disagree:
            return "Сервисы IPv6 видят разные адреса — похоже на утечку."
        case .dnsLeak(let resolver, let country):
            return "Утечка DNS: запросы идут через резолвер \(resolver) в \(CountryInfo.flag(country)) \(CountryInfo.name(country))."
        }
    }

    /// Address and country the user could allow to resolve this block.
    var allowable: (ip: IPAddress, country: String?)? {
        switch self {
        case .notAllowed(let ip, let country), .ipv6Leak(let ip, let country):
            return (ip, country)
        case .countryUnknown(let ip):
            return (ip, nil)
        case .dnsLeak(let ip, let country):
            return (ip, country)
        default:
            return nil
        }
    }
}
