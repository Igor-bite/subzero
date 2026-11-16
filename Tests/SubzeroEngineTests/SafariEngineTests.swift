import Darwin
import Foundation
import Synchronization
import Testing
import SubzeroCore
import SubzeroEngine
import SubzeroSystem

// Safari sites through a fake extension link: what the engine orders and when.

private struct Probe: NetworkProbing {
    let result: NetworkSnapshot
    func snapshot(includeIPv6: Bool, includeDNS: Bool) async -> NetworkSnapshot { result }
}

private struct NoProcesses: ProcessControlling {
    func snapshot(includeInterpreterArguments: Bool) -> [ProcessRecord] { [] }
    func send(_ signal: Int32, to pids: Set<Int32>) -> Int { 0 }
}

private final class FakeSafari: SafariLinking {
    private let state = Mutex<(commands: [SafariCommand], report: SafariReport?)>(([], nil))

    func publish(_ command: SafariCommand) throws {
        state.withLock { $0.commands.append(command) }
    }

    func latestReport() -> SafariReport? {
        state.withLock { $0.report }
    }

    func setReport(_ report: SafariReport?) {
        state.withLock { $0.report = report }
    }

    var last: SafariCommand? { state.withLock { $0.commands.last } }
    var count: Int { state.withLock { $0.commands.count } }

    func site(_ id: String) -> SafariCommand.Site? {
        last?.sites.first { $0.id == id }
    }
}

private func snapshot(_ ip: String, country: String) -> NetworkSnapshot {
    let address = IPAddress(ip)!
    return NetworkSnapshot(ipv4: .agreed(address, votes: 3), ipv6: .none, countries: [address: country])
}

@MainActor
private func makeEngine(_ snap: NetworkSnapshot, safari: FakeSafari, grace: TimeInterval = 300) -> GuardEngine {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("subzero-safari-test-\(UUID()).json")
    let engine = GuardEngine(
        store: ConfigStore(url: url), defaults: nil,
        probe: Probe(result: snap), processes: NoProcesses(), safari: safari, observesSystem: false
    )
    var config = GuardConfig()
    config.allowedCountries = ["NL"]
    config.checkIPv6 = false
    config.dnsCheck = .off
    config.grace = grace
    config.safariSites = ["claude"]
    engine.config = config
    engine.describeBlock = { _ in "чужой IP" }
    return engine
}

private func report(claudeOpen: Int, claudeFrozen: Int, at: Date = Date()) -> SafariReport {
    SafariReport(at: at.timeIntervalSince1970, extensionVersion: "1.0", blocksNetwork: true, sites: [
        .init(id: "claude", open: claudeOpen, frozen: claudeFrozen, access: true),
        .init(id: "chatgpt", open: 0, frozen: 0, access: true),
    ])
}

@MainActor
@Test func startHoldsProtectedSitesUntilFirstVerdict() {
    let safari = FakeSafari()
    let engine = makeEngine(snapshot("185.10.10.10", country: "NL"), safari: safari)

    engine.start()

    // No verdict yet: network cut, tabs untouched.
    #expect(safari.last?.active == true)
    #expect(safari.site("claude")?.mode == .hold)
    #expect(safari.site("chatgpt")?.mode == .run)
    #expect(safari.site("chatgpt")?.protected == false)
    engine.shutdown()
}

@MainActor
@Test func blockedIPFreezesSiteAndAllowedReleases() async {
    let safari = FakeSafari()
    let engine = makeEngine(snapshot("95.165.10.20", country: "RU"), safari: safari)
    var events: [GuardEvent] = []
    engine.onEvent = { events.append($0) }

    engine.start()
    safari.setReport(report(claudeOpen: 0, claudeFrozen: 2))
    await engine.checkNow()

    #expect(safari.site("claude")?.mode == .freeze)
    #expect(safari.site("claude")?.why == .network)
    #expect(safari.last?.detail == "чужой IP")
    #expect(engine.controlledSites.first?.state == .frozen)
    #expect(engine.frozenSiteNames == ["Claude в Safari"])
    #expect(engine.frozenAppCount == 1)
    #expect(events.contains { if case .blocked(_, ["Claude в Safari"]) = $0 { true } else { false } })

    engine.allowCountry("RU")
    #expect(safari.site("claude")?.mode == .run)
    #expect(events.last == .resumed(ip: IPAddress("95.165.10.20"), country: "RU"))
    engine.shutdown()
}

@MainActor
@Test func shutdownReleasesEveryTab() {
    let safari = FakeSafari()
    let engine = makeEngine(snapshot("95.165.10.20", country: "RU"), safari: safari)

    engine.start()
    engine.freezeSite("chatgpt")
    engine.shutdown()

    #expect(safari.last?.active == false)
    #expect(safari.last?.sites.allSatisfy { $0.mode == .run } == true)
}

@MainActor
@Test func manualFreezeHoldsOnAllowedIPAndUnfreezeReleases() async {
    let safari = FakeSafari()
    let engine = makeEngine(snapshot("185.10.10.10", country: "NL"), safari: safari)

    engine.start()
    await engine.checkNow()
    #expect(safari.site("claude")?.mode == .run)

    engine.freezeSite("chatgpt")
    #expect(safari.site("chatgpt")?.mode == .freeze)
    #expect(safari.site("chatgpt")?.why == .manual)
    #expect(engine.controlledSites.map(\.id) == ["claude", "chatgpt"])

    let chatgpt = engine.controlledSites.first { $0.id == "chatgpt" }!
    engine.unfreezeSite(chatgpt)
    #expect(safari.site("chatgpt")?.mode == .run)
    #expect(!engine.controlledSites.contains { $0.id == "chatgpt" })
    engine.shutdown()
}

@MainActor
@Test func unfreezingProtectedSiteDuringBlockOverridesUntilResume() async {
    let safari = FakeSafari()
    let engine = makeEngine(snapshot("95.165.10.20", country: "RU"), safari: safari)

    engine.start()
    await engine.checkNow()
    let claude = engine.controlledSites.first { $0.id == "claude" }!
    engine.unfreezeSite(claude)

    #expect(safari.site("claude")?.mode == .run)
    #expect(engine.controlledSites.first?.isOverridden == true)

    engine.allowCountry("RU")
    #expect(engine.siteOverrides.isEmpty)
    engine.shutdown()
}

@MainActor
@Test func closeSiteStampsCloseOrder() async {
    let safari = FakeSafari()
    let engine = makeEngine(snapshot("185.10.10.10", country: "NL"), safari: safari)

    engine.start()
    await engine.checkNow()
    let before = Date().timeIntervalSince1970
    engine.closeSite(engine.controlledSites.first!)

    #expect((safari.site("claude")?.closeAt ?? 0) >= before)
    #expect(safari.site("chatgpt")?.closeAt == 0)
    engine.shutdown()
}

@MainActor
@Test func graceExpiryClosesFrozenSiteTabs() async throws {
    let safari = FakeSafari()
    let engine = makeEngine(snapshot("95.165.10.20", country: "RU"), safari: safari, grace: 0)
    var events: [GuardEvent] = []
    engine.onEvent = { events.append($0) }

    engine.start()
    safari.setReport(report(claudeOpen: 0, claudeFrozen: 1))
    await engine.checkNow()
    // The kill happens on the next tick after the grace deadline.
    try await Task.sleep(for: .milliseconds(1200))

    #expect((safari.site("claude")?.closeAt ?? 0) > 0)
    #expect(events.contains { if case .killed(["Claude в Safari"], .graceExpired) = $0 { true } else { false } })
    engine.shutdown()
}

@MainActor
@Test func staleReportMeansLinkLost() {
    let safari = FakeSafari()
    let engine = makeEngine(snapshot("185.10.10.10", country: "NL"), safari: safari)

    engine.start()
    #expect(engine.safariLink == .silent)
    #expect(engine.controlledSites.first?.hasAccess == nil)

    safari.setReport(report(claudeOpen: 2, claudeFrozen: 0, at: Date().addingTimeInterval(-60)))
    engine.freezeSite("claude")   // any sync reads the report
    if case .lost = engine.safariLink {} else { Issue.record("expected .lost, got \(engine.safariLink)") }
    // Tabs from a stale report are not trusted.
    #expect(engine.controlledSites.first?.tabCount == 0)
    engine.shutdown()
}

@MainActor
@Test func heartbeatRepublishesUnchangedOrders() async throws {
    let safari = FakeSafari()
    let engine = makeEngine(snapshot("185.10.10.10", country: "NL"), safari: safari)

    engine.start()
    await engine.checkNow()
    let first = safari.last!.updatedAt
    try await Task.sleep(for: .seconds(GuardEngine.safariHeartbeat + 1.2))

    #expect(safari.last!.updatedAt > first)
    #expect(safari.last!.sameOrders(as: safari.last!))
    engine.shutdown()
}
