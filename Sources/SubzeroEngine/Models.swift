import Foundation
import SubzeroCore

/// A row in the "programs" list: a protected rule or an app frozen by hand.
public struct ControlledApp: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case notRunning
        case running
        case frozen
    }

    public let id: UUID
    public let name: String
    public let kind: AppRuleKind
    /// Covered by an enabled protection rule.
    public let isProtected: Bool
    public let state: State
    /// Frozen by the user, independent of the IP.
    public let isManuallyFrozen: Bool
    /// Protected, but the user let it run during the current block.
    public let isOverridden: Bool

    public init(
        id: UUID, name: String, kind: AppRuleKind, isProtected: Bool, state: State,
        isManuallyFrozen: Bool, isOverridden: Bool
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isProtected = isProtected
        self.state = state
        self.isManuallyFrozen = isManuallyFrozen
        self.isOverridden = isOverridden
    }
}

/// The last thing enforcement did to apps: froze them, killed them, or released them.
public struct EnforcementHit: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case freeze, shatter, thaw }

    public let id: UUID
    public let names: [String]
    public let kinds: [AppRuleKind]
    public let at: Date
    public let kind: Kind

    public init(id: UUID = UUID(), names: [String], kinds: [AppRuleKind], at: Date, kind: Kind) {
        self.id = id
        self.names = names
        self.kinds = kinds
        self.at = at
        self.kind = kind
    }

    /// The apps were killed.
    public var shatter: Bool { kind == .shatter }
}

/// An app the user froze by hand. Persisted, so it stays frozen across restarts.
public struct ManualFreeze: Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: AppRuleKind

    public init(id: UUID = UUID(), name: String, kind: AppRuleKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

/// Why protected apps were killed.
public enum KillCause: Equatable, Sendable {
    /// A DNS leak whose rule says "kill right away".
    case dnsLeak
    /// No allowed IP came back within the grace period.
    case graceExpired
}

/// Things worth telling the user about. Delivered once per occurrence, on the main actor.
public enum GuardEvent: Equatable, Sendable {
    /// Protected apps were frozen because of the network; sent once per block episode.
    case blocked(BlockReason, apps: [String])
    /// The block is over and frozen apps run again.
    case resumed(ip: IPAddress?, country: String?)
    /// Protected apps were killed.
    case killed(apps: [String], cause: KillCause)
    /// A timed pause ran out; protection is back.
    case pauseEnded
    /// A DNS leak whose action is "warn" (apps keep running). Sent once per resolver.
    case dnsWarning(DNSLeak)
}
