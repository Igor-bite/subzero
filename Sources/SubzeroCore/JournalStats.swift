import Foundation

/// Numbers for one period of the journal: how much time went to each status,
/// how often and why protection blocked, where the IP was, what got frozen and killed.
public struct JournalStats: Equatable, Sendable {
    /// Time with one status inside one bucket (hour or day) of the period.
    public struct Bucket: Equatable, Sendable {
        public var start: Date
        public var status: JournalStatus
        public var seconds: TimeInterval
    }

    public struct Reason: Equatable, Sendable {
        public var kind: BlockKind
        /// Blocks that started with this reason.
        public var count: Int
        public var seconds: TimeInterval
    }

    public struct Country: Equatable, Sendable {
        /// ISO code, nil when the country could not be determined.
        public var code: String?
        public var seconds: TimeInterval
    }

    public struct Target: Equatable, Sendable {
        public var name: String
        public var frozenSeconds: TimeInterval
        public var freezes: Int
        public var kills: Int
    }

    public let interval: DateInterval
    /// Status spans cut to the period, in time order.
    public let spans: [StatusSpan]
    public let seconds: [JournalStatus: TimeInterval]
    /// Blocks that started inside the period (a change of reason inside a block does not count).
    public let blocks: Int
    /// Longest uninterrupted block, cut to the period.
    public let longestBlock: TimeInterval
    /// By total blocked time, longest first.
    public let reasons: [Reason]
    /// By time, longest first.
    public let countries: [Country]
    /// Apps and Safari sites by frozen time, longest first.
    public let targets: [Target]
    public let kills: Int
    public let ipChanges: Int
    public let dnsWarnings: Int
    /// Status time per bucket, in time order. Asleep time is left out.
    public let buckets: [Bucket]
    public let bucketUnit: Calendar.Component

    /// Time Subzero was awake and watching: protected, blocked or checking.
    public var watched: TimeInterval {
        (seconds[.protected] ?? 0) + (seconds[.blocked] ?? 0) + (seconds[.checking] ?? 0)
    }

    /// Share of watched time with an allowed IP; nil when nothing was watched.
    public var protectedShare: Double? {
        let total = watched
        guard total > 0 else { return nil }
        return (seconds[.protected] ?? 0) / total
    }

    public var isEmpty: Bool { spans.isEmpty && targets.isEmpty && kills == 0 && ipChanges == 0 }

    /// - Parameters:
    ///   - entries: the journal, sorted by time.
    ///   - interval: the period to sum up.
    ///   - now: where open spans end.
    ///   - bucketUnit: `.hour` or `.day`.
    public init(
        entries: [JournalEntry], interval: DateInterval, now: Date,
        bucketUnit: Calendar.Component = .day, calendar: Calendar = .current
    ) {
        self.interval = interval
        self.bucketUnit = bucketUnit

        // Status time.
        var spans: [StatusSpan] = []
        for span in JournalTimeline.statusSpans(entries, now: now) {
            guard let (from, to) = JournalTimeline.clip(start: span.start, end: span.end, to: interval) else { continue }
            spans.append(StatusSpan(status: span.status, block: span.block, start: from, end: to))
        }
        self.spans = spans
        seconds = spans.reduce(into: [:]) { $0[$1.status, default: 0] += $1.duration }

        // Blocks: consecutive blocked spans (reason changes) make one block.
        var blocks = 0
        var longest: TimeInterval = 0
        var current: TimeInterval = 0
        var previousEnd: Date?
        var reasons: [BlockKind: Reason] = [:]
        for span in spans {
            let continues = span.status == .blocked && previousEnd == span.start && current > 0
            if span.status == .blocked {
                let kind = span.block?.kind ?? .offline
                var reason = reasons[kind] ?? Reason(kind: kind, count: 0, seconds: 0)
                reason.seconds += span.duration
                if !continues {
                    blocks += 1
                    reason.count += 1
                    current = 0
                }
                reasons[kind] = reason
                current += span.duration
                longest = max(longest, current)
            } else {
                current = 0
            }
            previousEnd = span.end
        }
        self.blocks = blocks
        longestBlock = longest
        self.reasons = reasons.values.sorted { ($0.seconds, $0.count) > ($1.seconds, $1.count) }

        // Countries.
        var countries: [String?: TimeInterval] = [:]
        for span in JournalTimeline.countrySpans(entries, now: now) {
            guard let (from, to) = JournalTimeline.clip(start: span.start, end: span.end, to: interval) else { continue }
            countries[span.country, default: 0] += to.timeIntervalSince(from)
        }
        self.countries = countries.map { Country(code: $0.key, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }

        // Events inside the period.
        let inside = entries.filter { interval.contains($0.at) && $0.at < interval.end }
        var targets: [String: Target] = [:]
        func target(_ name: String) -> Target { targets[name] ?? Target(name: name, frozenSeconds: 0, freezes: 0, kills: 0) }
        var kills = 0, ipChanges = 0, dnsWarnings = 0
        var previousIP: String?
        for entry in entries where entry.at < interval.end {
            // An IP change counts when it differs from the IP before it (restarts log the same IP again).
            if case .ipChanged(let ip, _) = entry.event {
                if interval.contains(entry.at), let previousIP, previousIP != ip { ipChanges += 1 }
                previousIP = ip
            }
        }
        for entry in inside {
            switch entry.event {
            case .frozen(let names, _):
                for name in names { targets[name] = { var t = target(name); t.freezes += 1; return t }() }
            case .killed(let names, _):
                kills += names.count
                for name in names { targets[name] = { var t = target(name); t.kills += 1; return t }() }
            case .dnsWarning:
                dnsWarnings += 1
            default:
                break
            }
        }
        for span in JournalTimeline.frozenSpans(entries, now: now) {
            guard let (from, to) = JournalTimeline.clip(start: span.start, end: span.end, to: interval) else { continue }
            var t = target(span.target)
            t.frozenSeconds += to.timeIntervalSince(from)
            targets[span.target] = t
        }
        self.targets = targets.values.sorted { ($0.frozenSeconds, $0.kills, $0.freezes) > ($1.frozenSeconds, $1.kills, $1.freezes) }
        self.kills = kills
        self.ipChanges = ipChanges
        self.dnsWarnings = dnsWarnings

        // Buckets: split spans at hour/day boundaries.
        var buckets: [Date: [JournalStatus: TimeInterval]] = [:]
        for span in spans where span.status != .asleep {
            var from = span.start
            while from < span.end {
                guard let bucket = calendar.dateInterval(of: bucketUnit, for: from) else { break }
                let to = min(span.end, bucket.end)
                buckets[bucket.start, default: [:]][span.status, default: 0] += to.timeIntervalSince(from)
                from = to
            }
        }
        self.buckets = buckets.keys.sorted().flatMap { start in
            JournalStatus.allCases.compactMap { status in
                buckets[start]?[status].map { Bucket(start: start, status: status, seconds: $0) }
            }
        }
    }
}
