import Darwin
import Foundation

public struct ProcessRecord: Sendable, Equatable {
    public let pid: Int32
    public let ppid: Int32
    /// Short command name from the kernel (`p_comm`, up to 16 chars).
    public let name: String
    /// Full path of the executable, if readable.
    public let path: String?
    /// argv (including argv[0]); only filled for interpreters like node/python.
    public let arguments: [String]
    /// Stopped in the kernel (`SSTOP`), e.g. by our SIGSTOP.
    public let isStopped: Bool

    public init(pid: Int32, ppid: Int32, name: String, path: String?, arguments: [String] = [], isStopped: Bool = false) {
        self.pid = pid
        self.ppid = ppid
        self.name = name
        self.path = path
        self.arguments = arguments
        self.isStopped = isStopped
    }

    /// Human-readable name: executable basename (`p_comm` is cut at 16 chars),
    /// plus the script name for interpreters ("node claude").
    public var displayName: String {
        let exe = path.map { ($0 as NSString).lastPathComponent } ?? name
        guard arguments.count > 1, ProcessMatcher.isInterpreter(exe) || ProcessMatcher.isInterpreter(name),
              let script = arguments.dropFirst().first(where: { !$0.hasPrefix("-") })
        else { return exe }
        return "\(exe) \((script as NSString).lastPathComponent)"
    }

    public func with(isStopped: Bool) -> ProcessRecord {
        ProcessRecord(pid: pid, ppid: ppid, name: name, path: path, arguments: arguments, isStopped: isStopped)
    }
}

public enum ProcessTree {
    public struct Node: Sendable, Equatable {
        public let record: ProcessRecord
        public let depth: Int
    }

    /// Parent of `pid` skipping processes outside `kept` (e.g. root-owned `login`
    /// between iTermServer and the shell). Returns the direct parent when no kept
    /// ancestor is found before launchd, so the record still looks like a root.
    public static func nearestAncestor(of pid: Int32, in kept: Set<Int32>, parentOf: [Int32: Int32]) -> Int32 {
        guard let direct = parentOf[pid] else { return 0 }
        var current = direct
        var steps = 0
        while current > 1, !kept.contains(current), let next = parentOf[current], next != current, steps < 64 {
            current = next
            steps += 1
        }
        return kept.contains(current) ? current : direct
    }

    /// Depth-first order, parents before children, siblings by pid.
    /// Records whose parent is not in the set are roots.
    public static func flatten(_ records: [ProcessRecord]) -> [Node] {
        let pids = Set(records.map(\.pid))
        var children: [Int32: [ProcessRecord]] = [:]
        var roots: [ProcessRecord] = []
        for r in records {
            if r.ppid != r.pid, pids.contains(r.ppid) {
                children[r.ppid, default: []].append(r)
            } else {
                roots.append(r)
            }
        }

        var result: [Node] = []
        result.reserveCapacity(records.count)
        var visited = Set<Int32>()
        func visit(_ r: ProcessRecord, _ depth: Int) {
            guard visited.insert(r.pid).inserted else { return }
            result.append(Node(record: r, depth: depth))
            for child in (children[r.pid] ?? []).sorted(by: { $0.pid < $1.pid }) {
                visit(child, depth + 1)
            }
        }
        for r in roots.sorted(by: { $0.pid < $1.pid }) { visit(r, 0) }
        // Cycles (pid reuse) have no root: emit what is left as roots.
        for r in records.sorted(by: { $0.pid < $1.pid }) where !visited.contains(r.pid) { visit(r, 0) }
        return result
    }
}

public enum AppRuleKind: Codable, Hashable, Sendable {
    /// Everything whose executable lives inside this `.app` bundle.
    case bundle(path: String)
    /// Command-line tools. A pattern matches when it equals the executable name
    /// (case-sensitive), or — if it contains `/` or `@` — appears in the executable path.
    /// For interpreters (node, python, …) the script arguments are checked the same way.
    case patterns([String])
}

public enum ProcessMatcher {
    static let interpreterNames: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby", "perl"]

    public static func isInterpreter(_ name: String) -> Bool {
        interpreterNames.contains(name) || name.hasPrefix("python3.")
    }

    private static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    private static func pattern(_ p: String, matchesPath path: String) -> Bool {
        if basename(path) == p { return true }
        if p.contains("/") || p.contains("@") { return path.contains(p) }
        return false
    }

    public static func matches(_ kind: AppRuleKind, _ process: ProcessRecord) -> Bool {
        switch kind {
        case .bundle(let bundlePath):
            guard let exe = process.path else { return false }
            let prefix = bundlePath.hasSuffix("/") ? bundlePath : bundlePath + "/"
            return exe.hasPrefix(prefix)

        case .patterns(let patterns):
            let cleaned = patterns.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            for p in cleaned {
                if process.name == p { return true }
                if let exe = process.path, pattern(p, matchesPath: exe) { return true }
                let exeName = process.path.map(basename) ?? process.name
                if isInterpreter(exeName) || isInterpreter(process.name) {
                    for arg in process.arguments where !arg.hasPrefix("-") {
                        if pattern(p, matchesPath: arg) { return true }
                    }
                }
            }
            return false
        }
    }

    /// Returns every process to act on, mapped to the rule that caught it.
    /// Descendants of a matched process are included (a terminal tab started by Cursor,
    /// a helper spawned by a CLI agent). launchd, pid 0 and `excludingPIDs` are never returned.
    public static func targets(
        processes: [ProcessRecord],
        rules: [(id: UUID, kind: AppRuleKind)],
        excludingPIDs: Set<Int32>
    ) -> [Int32: UUID] {
        guard !rules.isEmpty else { return [:] }

        var children: [Int32: [Int32]] = [:]
        for p in processes where p.pid != p.ppid {
            children[p.ppid, default: []].append(p.pid)
        }

        var result: [Int32: UUID] = [:]
        var queue: [(Int32, UUID)] = []
        for p in processes {
            if let rule = rules.first(where: { matches($0.kind, p) }) {
                result[p.pid] = rule.id
                queue.append((p.pid, rule.id))
            }
        }

        var index = 0
        while index < queue.count {
            let (pid, ruleID) = queue[index]
            index += 1
            for child in children[pid] ?? [] where result[child] == nil {
                result[child] = ruleID
                queue.append((child, ruleID))
            }
        }

        return result.filter { pid, _ in pid > 1 && !excludingPIDs.contains(pid) }
    }
}

extension AppRuleKind {
    /// Matching needs process arguments (interpreters running a script), which costs an extra syscall per process.
    public var needsArguments: Bool {
        if case .patterns = self { return true }
        return false
    }
}
