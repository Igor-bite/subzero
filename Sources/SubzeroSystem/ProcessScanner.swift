import Darwin
import Foundation
import SubzeroCore

public enum ProcessScanner {
    /// All processes owned by `uid` (default: the current user).
    ///
    /// Processes of other users are left out, but the tree goes through them: a
    /// shell started via root-owned `/usr/bin/login` (iTerm, Terminal) gets the
    /// nearest own ancestor as its parent, so it stays under the terminal app.
    public static func snapshot(uid: uid_t = getuid(), includeInterpreterArguments: Bool) -> [ProcessRecord] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }

        let stride = MemoryLayout<kinfo_proc>.stride
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 64)
        size = buffer.count * stride
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return [] }
        let count = min(buffer.count, size / stride)

        var parentOf: [Int32: Int32] = [:]
        parentOf.reserveCapacity(count)
        var owned: [Int] = []
        for i in 0..<count {
            let kp = buffer[i]
            parentOf[kp.kp_proc.p_pid] = kp.kp_eproc.e_ppid
            if kp.kp_eproc.e_ucred.cr_uid == uid { owned.append(i) }
        }
        let ownedPIDs = Set(owned.map { buffer[$0].kp_proc.p_pid })

        var records: [ProcessRecord] = []
        records.reserveCapacity(owned.count)
        for i in owned {
            var kp = buffer[i]
            let pid = kp.kp_proc.p_pid
            let ppid = ProcessTree.nearestAncestor(of: pid, in: ownedPIDs, parentOf: parentOf)
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
