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

@Test func scannerReportsStoppedState() throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["30"]
    try child.run()
    defer { child.terminate() }
    let pid = child.processIdentifier

    func record() -> ProcessRecord? {
        ProcessScanner.snapshot(includeInterpreterArguments: false).first { $0.pid == pid }
    }
    #expect(record()?.isStopped == false)

    kill(pid, SIGSTOP)
    var stopped = false
    for _ in 0..<50 where !stopped {
        stopped = record()?.isStopped == true
        if !stopped { usleep(10_000) }
    }
    #expect(stopped)

    kill(pid, SIGCONT)
}

// MARK: - Process tree

private func rec(_ pid: Int32, _ ppid: Int32, _ path: String?, name: String = "?", args: [String] = []) -> ProcessRecord {
    ProcessRecord(pid: pid, ppid: ppid, name: name, path: path, arguments: args)
}

@Test func treeOrdersParentsBeforeChildrenWithDepth() {
    let records = [
        rec(103, 102, "/usr/bin/git"),
        rec(101, 100, "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper"),
        rec(100, 1, "/Applications/Cursor.app/Contents/MacOS/Cursor"),
        rec(102, 100, "/bin/zsh"),
        rec(500, 1, "/Applications/Cursor.app/Contents/MacOS/Orphan"),
    ]
    let tree = ProcessTree.flatten(records)
    #expect(tree.map(\.record.pid) == [100, 101, 102, 103, 500])
    #expect(tree.map(\.depth) == [0, 1, 1, 2, 0])
}

@Test func treeSurvivesParentCycles() {
    // pid reuse can make two records point at each other; must not loop or drop them.
    let tree = ProcessTree.flatten([rec(10, 11, "/a"), rec(11, 10, "/b")])
    #expect(Set(tree.map(\.record.pid)) == [10, 11])
}

@Test func displayNamePrefersPathAndScript() {
    #expect(rec(1, 0, "/Applications/Cursor.app/Contents/MacOS/Cursor", name: "Cursor").displayName == "Cursor")
    #expect(rec(1, 0, nil, name: "kernel_task").displayName == "kernel_task")
    #expect(rec(1, 0, "/opt/homebrew/bin/node", name: "node",
                args: ["node", "--no-warnings", "/Users/me/.local/bin/claude", "--resume"]).displayName == "node claude")
    #expect(rec(1, 0, "/usr/bin/python3", name: "python3", args: ["python3"]).displayName == "python3")
}
