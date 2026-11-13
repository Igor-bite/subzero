import Darwin
import Foundation
import Synchronization
import Testing
import SubzeroCore
import SubzeroEngine
import SubzeroSystem

// The engine runs against fakes: no network, no real signals.

private struct FakeProbe: NetworkProbing {
    let result: NetworkSnapshot

    func snapshot(includeIPv6: Bool, includeDNS: Bool) async -> NetworkSnapshot { result }
}

private final class FakeProcesses: ProcessControlling {
    private let state: Mutex<(records: [ProcessRecord], signals: [(Int32, Set<Int32>)])>

    init(_ records: [ProcessRecord]) {
        state = Mutex((records, []))
    }

    func snapshot(includeInterpreterArguments: Bool) -> [ProcessRecord] {
        state.withLock { $0.records }
    }

    @discardableResult
    func send(_ signal: Int32, to pids: Set<Int32>) -> Int {
        state.withLock { $0.signals.append((signal, pids)) }
        return pids.count
    }

    func pids(sent signal: Int32) -> Set<Int32> {
        state.withLock { $0.signals.filter { $0.0 == signal }.reduce(into: Set()) { $0.formUnion($1.1) } }
    }
}

private let cursorPath = "/Applications/Cursor.app"
private let cursorProcesses = [
    ProcessRecord(pid: 9001, ppid: 1, name: "Cursor", path: "\(cursorPath)/Contents/MacOS/Cursor"),
    ProcessRecord(pid: 9002, ppid: 9001, name: "zsh", path: "/bin/zsh"),
    ProcessRecord(pid: 9100, ppid: 1, name: "Safari", path: "/Applications/Safari.app/Contents/MacOS/Safari"),
]

private func snapshot(_ ip: String, country: String) -> NetworkSnapshot {
    let address = IPAddress(ip)!
    return NetworkSnapshot(ipv4: .agreed(address, votes: 3), ipv6: .none, countries: [address: country])
}

@MainActor
private func makeEngine(_ snap: NetworkSnapshot, processes: FakeProcesses) -> GuardEngine {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("subzero-test-\(UUID()).json")
    let engine = GuardEngine(
        store: ConfigStore(url: url), defaults: nil,
        probe: FakeProbe(result: snap), processes: processes, observesSystem: false
    )
    var config = GuardConfig()
    config.allowedCountries = ["NL"]
    config.apps = [AppRule(name: "Cursor", kind: .bundle(path: cursorPath))]
    config.checkIPv6 = false
    config.dnsCheck = .off
    engine.config = config
    return engine
}

@MainActor
@Test func blockedIPFreezesAppAndItsChildren() async {
    let processes = FakeProcesses(cursorProcesses)
    let engine = makeEngine(snapshot("95.165.10.20", country: "RU"), processes: processes)
    var events: [GuardEvent] = []
    engine.onEvent = { events.append($0) }

    engine.start()
    await engine.checkNow()

    #expect(engine.phase == .blocked(.notAllowed(IPAddress("95.165.10.20")!, country: "RU")))
    #expect(processes.pids(sent: SIGSTOP) == [9001, 9002])
    #expect(engine.frozenAppNames == ["Cursor"])
    #expect(engine.frozenAppCount == 1)
    #expect(events.contains { if case .blocked(_, ["Cursor"]) = $0 { true } else { false } })

    engine.shutdown()
    #expect(processes.pids(sent: SIGCONT).isSuperset(of: [9001, 9002]))
    #expect(!processes.pids(sent: SIGSTOP).contains(9100))
}

@MainActor
@Test func allowedIPLeavesAppsRunning() async {
    let processes = FakeProcesses(cursorProcesses)
    let engine = makeEngine(snapshot("185.10.10.10", country: "NL"), processes: processes)

    engine.start()
    await engine.checkNow()

    #expect(engine.phase == .protected)
    // Fail-closed: frozen on start until the first verdict, then released.
    #expect(processes.pids(sent: SIGCONT).isSuperset(of: [9001, 9002]))
    #expect(engine.controlledApps.first?.state == .running)
    #expect(engine.frozenAppCount == 0)
    engine.shutdown()
}

@MainActor
@Test func manualFreezeHoldsEvenOnAllowedIP() async {
    let processes = FakeProcesses(cursorProcesses)
    let engine = makeEngine(snapshot("185.10.10.10", country: "NL"), processes: processes)

    engine.start()
    await engine.checkNow()
    engine.freezeManually(kind: .bundle(path: "/Applications/Safari.app"), name: "Safari")

    #expect(processes.pids(sent: SIGSTOP).contains(9100))
    #expect(engine.controlledApps.first { $0.name == "Safari" }?.state == .frozen)
    #expect(engine.controlledApps.first { $0.name == "Cursor" }?.state == .running)
    #expect(engine.lastHit?.kind == .freeze)
    engine.shutdown()
}

@MainActor
@Test func allowingTheCountryResumesRightAway() async {
    let processes = FakeProcesses(cursorProcesses)
    let engine = makeEngine(snapshot("95.165.10.20", country: "RU"), processes: processes)
    var events: [GuardEvent] = []
    engine.onEvent = { events.append($0) }

    engine.start()
    await engine.checkNow()
    engine.allowCountry("ru")

    #expect(engine.phase == .protected)
    #expect(processes.pids(sent: SIGCONT).isSuperset(of: [9001, 9002]))
    #expect(events.last == .resumed(ip: IPAddress("95.165.10.20"), country: "RU"))
    engine.shutdown()
}
