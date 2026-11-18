import Foundation

// History of what Subzero saw and did: network status changes, IP changes,
// freezes, releases and kills. Stored on disk by `JournalStore` (SubzeroSystem),
// recorded by `GuardEngine` (SubzeroEngine), summarized by `JournalStats`.

/// What network protection was doing.
public enum JournalStatus: String, Codable, Sendable, CaseIterable {
    /// Waiting for a fresh verdict: start, network change, wake.
    case checking
    /// Allowed IP, protected apps run.
    case protected
    /// Not allowed: protected apps are frozen.
    case blocked
    /// Protection paused by the user.
    case paused
    /// The Mac slept.
    case asleep
}

/// Block reason without the noise: what stats group by.
public enum BlockKind: String, Codable, Sendable, CaseIterable {
    case offline
    case servicesDisagree
    case notEnoughAnswers
    case countryUnknown
    case notAllowed
    case ipv6Leak
    case ipv6Disagree
    case dnsLeak
}

/// A block reason as kept in the journal: the kind plus the address and country involved.
public struct JournalBlock: Codable, Equatable, Hashable, Sendable {
    public var kind: BlockKind
    /// Address involved (exit IP, IPv6 leak, DNS resolver), or several joined by ", ".
    public var ip: String?
    public var country: String?

    public init(kind: BlockKind, ip: String? = nil, country: String? = nil) {
        self.kind = kind
        self.ip = ip
        self.country = country
    }

    public init(_ reason: BlockReason) {
        switch reason {
        case .offline:
            self.init(kind: .offline)
        case .servicesDisagree(let ips):
            self.init(kind: .servicesDisagree, ip: ips.map(\.description).joined(separator: ", "))
        case .notEnoughAnswers:
            self.init(kind: .notEnoughAnswers)
        case .countryUnknown(let ip):
            self.init(kind: .countryUnknown, ip: ip.description)
        case .notAllowed(let ip, let country):
            self.init(kind: .notAllowed, ip: ip.description, country: country)
        case .ipv6Leak(let ip, let country):
            self.init(kind: .ipv6Leak, ip: ip.description, country: country)
        case .ipv6Disagree(let ips):
            self.init(kind: .ipv6Disagree, ip: ips.map(\.description).joined(separator: ", "))
        case .dnsLeak(let ip, let country):
            self.init(kind: .dnsLeak, ip: ip.description, country: country)
        }
    }
}

/// Why apps or Safari tabs were killed, as kept in the journal.
public enum JournalKillCause: String, Codable, Sendable {
    /// DNS leak whose rule says "kill right away".
    case dnsLeak
    /// No allowed IP came back within the grace period.
    case graceExpired
    /// The user pressed ✕.
    case manual
}

public enum JournalEvent: Codable, Equatable, Sendable {
    /// Subzero started.
    case started
    /// Subzero stopped. `clean` is false when it crashed or was force-quit
    /// (written on the next start, at the last moment it was known alive).
    case stopped(clean: Bool)
    /// Protection status changed. `block` is set for `.blocked`, `until` for a timed `.paused`.
    case status(JournalStatus, block: JournalBlock? = nil, until: Date? = nil)
    /// The external IP changed (first IP of every run is recorded too).
    case ipChanged(ip: String, country: String?)
    /// DNS goes through a resolver in another country; apps keep running.
    case dnsWarning(resolver: String, country: String)
    /// Apps or Safari sites froze. `manual`: frozen by hand, not because of the IP.
    case frozen(targets: [String], manual: Bool)
    /// Apps or Safari sites run again. `manual`: released by hand.
    case thawed(targets: [String], manual: Bool)
    /// Apps or Safari tabs were killed.
    case killed(targets: [String], cause: JournalKillCause)
    /// Frozen apps or tabs went away without Subzero killing them (quit, Safari closed).
    case exited(targets: [String])

    /// Targets (apps, "X в Safari") the event is about.
    public var targets: [String] {
        switch self {
        case .frozen(let targets, _), .thawed(let targets, _), .killed(let targets, _), .exited(let targets):
            return targets
        default:
            return []
        }
    }

    /// About apps and Safari tabs (as opposed to the network).
    public var isAboutTargets: Bool { !targets.isEmpty }
}

public struct JournalEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var at: Date
    public var event: JournalEvent

    public init(id: UUID = UUID(), at: Date, event: JournalEvent) {
        self.id = id
        self.at = at
        self.event = event
    }
}

// MARK: - Spans

/// A stretch of time with one protection status.
public struct StatusSpan: Equatable, Sendable {
    public var status: JournalStatus
    public var block: JournalBlock?
    public var start: Date
    public var end: Date

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// A stretch of time one app or Safari site stood frozen.
public struct FrozenSpan: Equatable, Sendable {
    public var target: String
    public var manual: Bool
    public var start: Date
    public var end: Date

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// A stretch of time with one external IP country.
public struct CountrySpan: Equatable, Sendable {
    public var country: String?
    public var start: Date
    public var end: Date

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// Turns the event list into spans. Entries must be sorted by time.
///
/// A span lasts until the next event of its kind, or until Subzero stopped or
/// started again (nothing is known while it was not running). The last span of a
/// run that has not stopped lasts until `now`.
public enum JournalTimeline {
    public static func statusSpans(_ entries: [JournalEntry], now: Date) -> [StatusSpan] {
        var spans: [StatusSpan] = []
        var open: StatusSpan?
        func close(at date: Date) {
            guard var span = open else { return }
            span.end = max(span.start, date)
            if span.duration > 0 { spans.append(span) }
            open = nil
        }
        for entry in entries {
            switch entry.event {
            case .status(let status, let block, _):
                close(at: entry.at)
                open = StatusSpan(status: status, block: block, start: entry.at, end: entry.at)
            case .started, .stopped:
                close(at: entry.at)
            default:
                break
            }
        }
        close(at: now)
        return spans
    }

    public static func frozenSpans(_ entries: [JournalEntry], now: Date) -> [FrozenSpan] {
        var spans: [FrozenSpan] = []
        var open: [String: FrozenSpan] = [:]
        func close(_ target: String, at date: Date) {
            guard var span = open.removeValue(forKey: target) else { return }
            span.end = max(span.start, date)
            if span.duration > 0 { spans.append(span) }
        }
        for entry in entries {
            switch entry.event {
            case .frozen(let targets, let manual):
                for target in targets where open[target] == nil {
                    open[target] = FrozenSpan(target: target, manual: manual, start: entry.at, end: entry.at)
                }
            case .thawed(let targets, _), .killed(let targets, _), .exited(let targets):
                for target in targets { close(target, at: entry.at) }
            case .started, .stopped:
                for target in Array(open.keys) { close(target, at: entry.at) }
            default:
                break
            }
        }
        for target in Array(open.keys) { close(target, at: now) }
        return spans.sorted { $0.start < $1.start }
    }

    public static func countrySpans(_ entries: [JournalEntry], now: Date) -> [CountrySpan] {
        var spans: [CountrySpan] = []
        var open: CountrySpan?
        func close(at date: Date) {
            guard var span = open else { return }
            span.end = max(span.start, date)
            if span.duration > 0 { spans.append(span) }
            open = nil
        }
        for entry in entries {
            switch entry.event {
            case .ipChanged(_, let country):
                close(at: entry.at)
                open = CountrySpan(country: country?.uppercased(), start: entry.at, end: entry.at)
            case .started, .stopped:
                close(at: entry.at)
            default:
                break
            }
        }
        close(at: now)
        return spans
    }

    /// The span cut to `interval`, or nil if they do not overlap.
    static func clip(start: Date, end: Date, to interval: DateInterval) -> (Date, Date)? {
        let from = max(start, interval.start), to = min(end, interval.end)
        return to > from ? (from, to) : nil
    }
}
