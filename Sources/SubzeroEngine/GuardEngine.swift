import Darwin
import Foundation
import Observation
import SubzeroCore
import SubzeroSystem

/// Orchestrates checks and enforcement. All state lives on the main actor.
///
/// Enforcement is declarative: every tick computes the set of processes that
/// should be stopped (auto-protected while blocked, plus manual freezes) and
/// sends SIGSTOP/SIGCONT only for the difference.
///
/// The engine has no UI and no user-facing text. Hosts observe its state
/// (`@Observable`) and react to `onEvent` (notifications, sounds, logs).
///
/// ```swift
/// let engine = GuardEngine()
/// engine.onEvent = { event in print(event) }
/// engine.start()
/// // ...
/// engine.shutdown()   // releases everything Subzero stopped
/// ```
@MainActor
@Observable
public final class GuardEngine {
    public enum Phase: Equatable, Sendable {
        case checking
        case protected
        case blocked(BlockReason)
        case paused(until: Date)
    }

    // MARK: Published state

    /// Current settings. Every change is saved to the store and applied right away.
    public var config: GuardConfig {
        didSet {
            guard config != oldValue else { return }
            persist()
            configChanged(from: oldValue)
        }
    }

    public private(set) var snapshot: NetworkSnapshot?
    public private(set) var verdict: Verdict?
    public private(set) var lastCheck: Date?
    public private(set) var isChecking = false
    public private(set) var pausedUntil: Date?
    public private(set) var killDeadline: Date?
    /// Protected rules whose processes are frozen because of the IP.
    public private(set) var frozenRuleIDs: Set<UUID> = []
    public private(set) var manualFreezes: [ManualFreeze] = []
    /// Protected rules the user unfroze during the current block.
    public private(set) var overrides: Set<UUID> = []
    public private(set) var appStates: [UUID: ControlledApp.State] = [:]
    /// Processes caught per subject (the app and all its descendants), refreshed every scan.
    public private(set) var appProcesses: [UUID: [ProcessRecord]] = [:]
    /// Apps whose process list is expanded in a host's UI. Not persisted, never read by the engine.
    public var expandedApps: Set<UUID> = []
    /// Last persistence error, if any.
    public private(set) var lastError: String?
    /// Last freeze/kill/release.
    public private(set) var lastHit: EnforcementHit?
    /// Updated every tick so countdowns refresh.
    public private(set) var now = Date()

    /// Called on the main actor for every `GuardEvent`.
    @ObservationIgnored
    public var onEvent: (@MainActor (GuardEvent) -> Void)?

    // MARK: Private state

    @ObservationIgnored private let store: ConfigStore
    @ObservationIgnored private let defaults: UserDefaults?
    private static let manualKey = "manualFreezes"
    @ObservationIgnored private let probe: any NetworkProbing
    @ObservationIgnored private let processes: any ProcessControlling
    @ObservationIgnored private let observesSystem: Bool
    @ObservationIgnored private var enforcer = Enforcer()
    @ObservationIgnored private var frozenPIDs: Set<Int32> = []
    @ObservationIgnored private var lastScan = Date.distantPast
    private var networkChangePending = true   // fail closed until the first check
    private var sleeping = false
    @ObservationIgnored private var announcedBlock = false
    @ObservationIgnored private var notifiedDNSResolver: IPAddress?
    @ObservationIgnored private var activeChecks = 0
    @ObservationIgnored private var started = false

    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var networkMonitor: NetworkChangeMonitor?
    @ObservationIgnored private var sleepMonitor: SleepWakeMonitor?

    /// - Parameters:
    ///   - store: where the config is loaded from and saved to.
    ///   - defaults: where manual freezes are kept across restarts; `nil` keeps them in memory only.
    ///   - probe: source of network observations.
    ///   - processes: process listing and signals.
    ///   - observesSystem: react to network changes and sleep/wake. Turn off in tests.
    public init(
        store: ConfigStore = .standard,
        defaults: UserDefaults? = .standard,
        probe: any NetworkProbing = IPProbe(),
        processes: any ProcessControlling = SystemProcessController(),
        observesSystem: Bool = true
    ) {
        self.store = store
        self.defaults = defaults
        self.probe = probe
        self.processes = processes
        self.observesSystem = observesSystem
        self.config = store.load()
        if let data = defaults?.data(forKey: Self.manualKey), let saved = try? JSONDecoder().decode([ManualFreeze].self, from: data) {
            manualFreezes = saved
        }
    }

    // MARK: Lifecycle

    /// Starts checking and enforcing. Idempotent.
    public func start() {
        guard !started else { return }
        started = true

        if observesSystem {
            let monitor = NetworkChangeMonitor { [weak self] _ in
                Task { @MainActor in self?.networkChanged() }
            }
            monitor.start()
            networkMonitor = monitor

            let sleep = SleepWakeMonitor { [weak self] event in
                switch event {
                case .willSleep: self?.willSleep()
                case .didWake: self?.didWake()
                }
            }
            sleep.start()
            sleepMonitor = sleep
        }

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer

        tick()
        requestCheck()
    }

    /// Unfreezes everything we stopped (manual freezes come back on next start). Call on quit.
    public func shutdown() {
        guard started else { return }
        let targets = currentTargets().keys
        started = false
        loopTask?.cancel()
        ticker?.invalidate()
        networkMonitor?.stop()
        sleepMonitor?.stop()

        processes.send(SIGCONT, to: Set(targets).union(frozenPIDs))
        frozenPIDs.removeAll()
        frozenRuleIDs.removeAll()
    }

    // MARK: Derived state

    public var phase: Phase {
        if let until = pausedUntil, until > now { return .paused(until: until) }
        if networkChangePending || sleeping { return .checking }
        switch verdict {
        case .none: return .checking
        case .allowed: return .protected
        case .blocked(let reason): return .blocked(reason)
        }
    }

    public var enabledRules: [AppRule] { config.apps.filter(\.enabled) }

    public var frozenAppNames: [String] {
        config.apps.filter { frozenRuleIDs.contains($0.id) }.map(\.name)
    }

    /// How many apps stand frozen right now (any reason).
    public var frozenAppCount: Int {
        appStates.values.filter { $0 == .frozen }.count
    }

    /// DNS leak with the action the settings assign to it (default or per-country rule).
    public var dnsFinding: DNSFinding? {
        guard let snapshot else { return nil }
        return SubzeroCore.dnsFinding(in: snapshot, rules: config.allowRules, settings: config.policySettings)
    }

    /// DNS leak shown as a warning only (apps keep running).
    public var dnsWarning: DNSLeak? {
        guard let finding = dnsFinding, finding.action == .warn else { return nil }
        return finding.leak
    }

    /// The current block is a DNS leak whose rule says "kill right away".
    public var killsImmediately: Bool {
        guard case .blocked(.dnsLeak) = phase else { return false }
        return dnsFinding?.action == .kill
    }

    /// Country of the current external IP, if known.
    public var currentCountry: String? {
        guard let snapshot, let ip = snapshot.primaryIP else { return nil }
        return snapshot.countries[ip]
    }

    public var controlledApps: [ControlledApp] {
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

    /// Restarts the check loop with an immediate check.
    public func requestCheck() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    /// Runs one check now and applies its verdict. Does not touch the background loop.
    public func checkNow() async {
        await performCheck()
    }

    /// Stops enforcing for `duration` seconds, or until `endPause()` when `nil`.
    public func pause(for duration: TimeInterval?) {
        pausedUntil = duration.map { Date().addingTimeInterval($0) } ?? .distantFuture
        tick()
    }

    public func endPause() {
        pausedUntil = nil
        networkChangePending = true
        tick()
        requestCheck()
    }

    public func allowIP(_ ip: IPAddress) {
        let text = ip.description
        guard !config.allowedNetworks.contains(text) else { return }
        config.allowedNetworks.append(text)
    }

    public func allowCountry(_ code: String) {
        let upper = code.uppercased()
        guard !config.allowedCountries.contains(upper) else { return }
        config.allowedCountries.append(upper)
    }

    // MARK: User actions: manual control

    /// Freeze now and keep frozen until unfrozen by hand, whatever the IP.
    public func freezeManually(kind: AppRuleKind, name: String) {
        if let rule = enabledRules.first(where: { $0.kind == kind }) {
            overrides.remove(rule.id)
        }
        if !manualFreezes.contains(where: { $0.kind == kind }) {
            manualFreezes.append(ManualFreeze(id: UUID(), name: name, kind: kind))
            saveManualFreezes()
        }
        reconcile(force: true)
        lastHit = EnforcementHit(names: [name], kinds: [kind], at: Date(), kind: .freeze)
    }

    public func freeze(_ app: ControlledApp) {
        freezeManually(kind: app.kind, name: app.name)
    }

    /// Unfreeze now. A protected app unfrozen during a block runs until the block ends.
    public func unfreeze(_ app: ControlledApp) {
        manualFreezes.removeAll { $0.kind == app.kind }
        saveManualFreezes()
        if app.isProtected && shouldBlock {
            overrides.insert(app.id)
        }
        reconcile(force: true)
        if app.state == .frozen {
            lastHit = EnforcementHit(names: [app.name], kinds: [app.kind], at: Date(), kind: .thaw)
        }
    }

    /// SIGKILL every process of the app right now.
    public func forceKill(_ app: ControlledApp) {
        manualFreezes.removeAll { $0.kind == app.kind }
        saveManualFreezes()
        let records = processes.snapshot(includeInterpreterArguments: app.kind.needsArguments)
        let victims = ProcessMatcher.targets(processes: records, rules: [(app.id, app.kind)], excludingPIDs: [getpid()])
        processes.send(SIGKILL, to: Set(victims.keys))
        frozenPIDs.subtract(victims.keys)
        reconcile(force: true)
        lastHit = EnforcementHit(names: [app.name], kinds: [app.kind], at: Date(), kind: .shatter)
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

        let snap = await probe.snapshot(includeIPv6: config.checkIPv6, includeDNS: config.policySettings.needsDNS)
        guard !Task.isCancelled else { return }

        snapshot = snap
        lastCheck = Date()
        networkChangePending = false
        verdict = evaluate(snap, rules: config.allowRules, settings: config.policySettings)
        reportDNSWarningIfNeeded()
        tick()
    }

    private func reportDNSWarningIfNeeded() {
        guard let leak = dnsWarning else {
            notifiedDNSResolver = nil
            return
        }
        guard notifiedDNSResolver != leak.resolver else { return }
        notifiedDNSResolver = leak.resolver
        emit(.dnsWarning(leak))
    }

    private func emit(_ event: GuardEvent) {
        onEvent?(event)
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
        // Re-judge the last observation right away (e.g. "allow this country").
        if let snapshot {
            verdict = evaluate(snapshot, rules: config.allowRules, settings: config.policySettings)
        }
        let enabledIDs = Set(enabledRules.map(\.id))
        overrides.formIntersection(enabledIDs)
        guard started else { return }
        if old.checkIPv6 != config.checkIPv6 || old.checkInterval != config.checkInterval
            || old.minAgree != config.minAgree || old.policySettings.needsDNS != config.policySettings.needsDNS {
            requestCheck()
        }
        tick()
        reconcile(force: true)
    }

    private func persist() {
        do {
            try store.save(config)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
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
        scan().targets
    }

    private func scan() -> (targets: [Int32: UUID], processes: [ProcessRecord]) {
        let subjects = subjects
        guard !subjects.isEmpty else { return ([:], []) }
        let records = processes.snapshot(includeInterpreterArguments: subjects.contains { $0.kind.needsArguments })
        return (ProcessMatcher.targets(processes: records, rules: subjects, excludingPIDs: [getpid()]), records)
    }

    private func tick() {
        guard started else { return }
        now = Date()
        if let until = pausedUntil, until <= now {
            pausedUntil = nil
            networkChangePending = true
            emit(.pauseEnded)
            requestCheck()
        }

        let grace: TimeInterval? = killsImmediately ? 0 : (config.killAfterGrace ? config.grace : nil)
        let blocked = shouldBlock
        let action = enforcer.step(blocked: blocked, now: now, grace: grace)
        let deadline = blocked ? enforcer.deadline(grace: grace) : nil
        if killDeadline != deadline { killDeadline = deadline }
        if action == .resume, !overrides.isEmpty { overrides.removeAll() }

        reconcile(action: action, force: false)

        if action == .resume, announcedBlock {
            announcedBlock = false
            let ip: IPAddress? = if case .allowed(let ip) = verdict { ip } else { nil }
            emit(.resumed(ip: ip, country: ip.flatMap { snapshot?.countries[$0] }))
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

        let scanned = scan()
        var targets = scanned.targets
        let records = scanned.processes
        let autoIDs = Set(enabledRules.map(\.id)).subtracting(overrides)
        let manualIDs = manualSubjectIDs

        if action == .kill {
            // Kill what is frozen because of the IP; hand-frozen apps stay frozen.
            let victims = targets.filter { autoIDs.contains($0.value) && !manualIDs.contains($0.value) }
            if !victims.isEmpty {
                processes.send(SIGKILL, to: Set(victims.keys))
                frozenPIDs.subtract(victims.keys)
                targets = targets.filter { victims[$0.key] == nil }
                let ids = Set(victims.values)
                let killed = config.apps.filter { ids.contains($0.id) }
                lastHit = EnforcementHit(names: killed.map(\.name), kinds: killed.map(\.kind), at: Date(), kind: .shatter)
                emit(.killed(apps: killed.map(\.name), cause: killsImmediately ? .dnsLeak : .graceExpired))
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
            // stopped by a previous crash of the host.
            let autoPIDs = targets.filter { autoIDs.contains($0.value) }.keys
            toContinue.formUnion(Set(autoPIDs).subtracting(desired))
        }
        if !toStop.isEmpty { processes.send(SIGSTOP, to: toStop) }
        if !toContinue.isEmpty { processes.send(SIGCONT, to: toContinue) }
        frozenPIDs = desired

        // Kernel state comes from the scan, taken before the signals above:
        // patch in what we just sent, the next scan reports the real state.
        var processesByID: [UUID: [ProcessRecord]] = [:]
        for record in records {
            guard let id = targets[record.pid] else { continue }
            let stopped = toStop.contains(record.pid) ? true : toContinue.contains(record.pid) ? false : record.isStopped
            processesByID[id, default: []].append(record.with(isStopped: stopped))
        }
        if appProcesses != processesByID { appProcesses = processesByID }

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

        let autoFrozen = Set(targets.filter { desired.contains($0.key) && autoIDs.contains($0.value) && !manualIDs.contains($0.value) }.values)
        let newFrozenRules = blocked ? autoFrozen : []
        let justFrozen = newFrozenRules.subtracting(frozenRuleIDs)
        if !justFrozen.isEmpty {
            let hit = config.apps.filter { justFrozen.contains($0.id) }
            lastHit = EnforcementHit(names: hit.map(\.name), kinds: hit.map(\.kind), at: Date(), kind: .freeze)
        } else if !blocked, !frozenRuleIDs.isEmpty {
            // The block is over: apps frozen because of the IP are released.
            let released = config.apps.filter { frozenRuleIDs.contains($0.id) }
            lastHit = EnforcementHit(names: released.map(\.name), kinds: released.map(\.kind), at: Date(), kind: .thaw)
        }
        if frozenRuleIDs != newFrozenRules { frozenRuleIDs = newFrozenRules }
    }

    /// Report once per block episode, and only for real verdicts (not the
    /// sub-second freeze while re-checking after a network change).
    private func announceIfNeeded() {
        guard !announcedBlock, case .blocked(let reason) = phase, !frozenRuleIDs.isEmpty else { return }
        announcedBlock = true
        emit(.blocked(reason, apps: frozenAppNames))
    }

    #if DEBUG
    /// Puts the engine into a fixed state for UI snapshots. Never starts checks or signals.
    public func debugApply(
        snapshot: NetworkSnapshot?,
        verdict: Verdict?,
        appStates: [UUID: ControlledApp.State] = [:],
        frozenRuleIDs: Set<UUID> = [],
        manualFreezes: [ManualFreeze] = [],
        overrides: Set<UUID> = [],
        pausedUntil: Date? = nil,
        killDeadline: Date? = nil,
        lastHit: EnforcementHit? = nil,
        appProcesses: [UUID: [ProcessRecord]] = [:],
        expandedApps: Set<UUID> = []
    ) {
        self.lastHit = lastHit
        self.snapshot = snapshot
        self.verdict = verdict
        self.lastCheck = Date()
        self.networkChangePending = false
        self.appStates = appStates
        self.appProcesses = appProcesses
        self.expandedApps = expandedApps
        self.frozenRuleIDs = frozenRuleIDs
        self.manualFreezes = manualFreezes
        self.overrides = overrides
        self.pausedUntil = pausedUntil
        self.killDeadline = killDeadline
        self.now = Date()
    }
    #endif
}
