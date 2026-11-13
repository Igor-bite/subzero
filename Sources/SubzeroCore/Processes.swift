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

public enum ProcessScanner {
    /// All processes owned by `uid` (default: the current user).
    public static func snapshot(uid: uid_t = getuid(), includeInterpreterArguments: Bool) -> [ProcessRecord] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: uid)]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
        size = buffer.count * stride
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return [] }
        let count = min(buffer.count, size / stride)

        var records: [ProcessRecord] = []
        records.reserveCapacity(count)
        for i in 0..<count {
            var kp = buffer[i]
            let pid = kp.kp_proc.p_pid
            let ppid = kp.kp_eproc.e_ppid
            let name = withUnsafeBytes(of: &kp.kp_proc.p_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            let path = executablePath(pid)
            var args: [String] = []
            if includeInterpreterArguments {
                let exeName = path.map { ($0 as NSString).lastPathComponent } ?? name
                if ProcessMatcher.isInterpreter(exeName) || ProcessMatcher.isInterpreter(name) {
                    args = arguments(pid) ?? []
                }
            }
            let stopped = Int32(kp.kp_proc.p_stat) == SSTOP
            records.append(ProcessRecord(pid: pid, ppid: ppid, name: name, path: path, arguments: args, isStopped: stopped))
        }
        return records
    }

    public static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let utf8 = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: utf8, as: UTF8.self)
    }

    public static func arguments(_ pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// Layout of KERN_PROCARGS2: Int32 argc, exec path, NUL padding, argv[0..argc), env…
    public static func parseProcArgs(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count >= 4 else { return nil }
        let argc = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argc > 0 else { return [] }

        var i = 4
        while i < bytes.count && bytes[i] != 0 { i += 1 }   // exec path
        while i < bytes.count && bytes[i] == 0 { i += 1 }   // padding

        var args: [String] = []
        while args.count < Int(argc) && i < bytes.count {
            let start = i
            while i < bytes.count && bytes[i] != 0 { i += 1 }
            args.append(String(decoding: bytes[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }
}

public enum ProcessSignaler {
    /// Sends `signal` to each pid. Never touches pid ≤ 1 or this process.
    @discardableResult
    public static func send(_ signal: Int32, to pids: some Sequence<Int32>) -> Int {
        let me = getpid()
        var delivered = 0
        for pid in pids where pid > 1 && pid != me {
            if kill(pid, signal) == 0 { delivered += 1 }
        }
        return delivered
    }
}
