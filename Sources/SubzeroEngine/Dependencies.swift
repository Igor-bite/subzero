import Foundation
import SubzeroCore
import SubzeroSystem

/// Source of network observations. `IPProbe` is the real one; tests and hosts can plug in their own.
public protocol NetworkProbing: Sendable {
    func snapshot(includeIPv6: Bool, includeDNS: Bool) async -> NetworkSnapshot
}

extension IPProbe: NetworkProbing {}

/// Lists processes and sends them signals. `SystemProcessController` is the real one.
public protocol ProcessControlling: Sendable {
    func snapshot(includeInterpreterArguments: Bool) -> [ProcessRecord]
    /// Returns how many processes received the signal.
    @discardableResult
    func send(_ signal: Int32, to pids: Set<Int32>) -> Int
}

/// Real processes of the current user, via `ProcessScanner` and `ProcessSignaler`.
public struct SystemProcessController: ProcessControlling {
    public init() {}

    public func snapshot(includeInterpreterArguments: Bool) -> [ProcessRecord] {
        ProcessScanner.snapshot(includeInterpreterArguments: includeInterpreterArguments)
    }

    @discardableResult
    public func send(_ signal: Int32, to pids: Set<Int32>) -> Int {
        ProcessSignaler.send(signal, to: pids)
    }
}

/// Link to the Safari extension: publishes orders, returns what it last reported.
/// `SafariChannel` is the real one.
public protocol SafariLinking: Sendable {
    func publish(_ command: SafariCommand) throws
    func latestReport() -> SafariReport?
}

extension SafariChannel: SafariLinking {
    public func publish(_ command: SafariCommand) throws {
        try write(command)
    }

    public func latestReport() -> SafariReport? {
        readReport()
    }
}
