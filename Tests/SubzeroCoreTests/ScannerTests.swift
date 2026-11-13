import Darwin
import Foundation
import Testing
@testable import SubzeroCore

@Test func scannerSeesCurrentProcessQuickly() {
    let clock = ContinuousClock()
    var records: [ProcessRecord] = []
    let elapsed = clock.measure {
        records = ProcessScanner.snapshot(includeInterpreterArguments: true)
    }
    let me = records.first { $0.pid == getpid() }
    #expect(me != nil)
    #expect(me?.path != nil)
    print("scan: \(records.count) processes in \(elapsed)")
    #expect(elapsed < .milliseconds(500))
}

/// Hits the network; runs only with FREEZER_LIVE=1.
@Test(.enabled(if: ProcessInfo.processInfo.environment["FREEZER_LIVE"] == "1"))
func liveSnapshotFindsDNSResolver() async {
    let snap = await IPProbe().snapshot(includeIPv6: true, includeDNS: true)
    #expect(snap.ipv4.agreedIP != nil)
    #expect(snap.dnsResolver != nil)
    if let r = snap.dnsResolver { #expect(snap.countries[r] != nil) }
    print("live: v4 votes=\(snap.ipv4), dns country=\(snap.dnsResolver.flatMap { snap.countries[$0] } ?? "?")")
}
