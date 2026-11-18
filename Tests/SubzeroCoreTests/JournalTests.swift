import Foundation
import Testing
import SubzeroCore

private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

private func entry(_ minutes: Double, _ event: JournalEvent) -> JournalEntry {
    JournalEntry(at: at(minutes), event: event)
}

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private let ru = JournalBlock(kind: .notAllowed, ip: "95.165.10.20", country: "RU")

@Test func entryRoundTripsThroughJSON() throws {
    let entries = [
        entry(0, .started),
        entry(1, .status(.blocked, block: ru)),
        entry(2, .status(.paused, until: at(30))),
        entry(3, .frozen(targets: ["Cursor", "Claude в Safari"], manual: false)),
        entry(4, .killed(targets: ["Cursor"], cause: .graceExpired)),
        entry(5, .stopped(clean: true)),
    ]
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .secondsSince1970
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    for item in entries {
        let back = try decoder.decode(JournalEntry.self, from: encoder.encode(item))
        #expect(back == item)
    }
}

@Test func blockReasonKeepsAddressAndCountry() {
    let block = JournalBlock(.notAllowed(IPAddress("95.165.10.20")!, country: "RU"))
    #expect(block == ru)
    #expect(JournalBlock(.offline) == JournalBlock(kind: .offline))
}

@Test func statusSpansEndAtNextStatusStopAndNow() {
    let entries = [
        entry(0, .started),
        entry(0, .status(.checking)),
        entry(1, .status(.protected)),
        entry(10, .stopped(clean: true)),
        // Nothing is known while Subzero was not running.
        entry(20, .started),
        entry(20, .status(.blocked, block: ru)),
    ]
    let spans = JournalTimeline.statusSpans(entries, now: at(25))
    #expect(spans.map(\.status) == [.checking, .protected, .blocked])
    #expect(spans.map(\.duration) == [60, 540, 300])
    #expect(spans[2].block == ru)
}

@Test func statsSumTimeBlocksAndShare() {
    let entries = [
        entry(0, .started),
        entry(0, .status(.protected)),
        entry(30, .status(.blocked, block: ru)),
        // Reason changes inside the same block: still one block.
        entry(40, .status(.blocked, block: JournalBlock(kind: .offline))),
        entry(50, .status(.protected)),
        entry(80, .status(.asleep)),
        entry(100, .status(.checking)),
        entry(101, .status(.blocked, block: ru)),
        entry(106, .status(.protected)),
    ]
    let stats = JournalStats(entries: entries, interval: DateInterval(start: at(0), end: at(120)), now: at(120), calendar: utc)

    #expect(stats.seconds[.protected] ?? 0 == TimeInterval(74 * 60))
    #expect(stats.seconds[.blocked] ?? 0 == TimeInterval(25 * 60))
    #expect(stats.seconds[.asleep] ?? 0 == TimeInterval(20 * 60))
    #expect(stats.seconds[.checking] ?? 0 == TimeInterval(60))
    #expect(stats.blocks == 2)
    #expect(stats.longestBlock == 20 * 60)
    #expect(stats.reasons.map(\.kind) == [.notAllowed, .offline])
    #expect(stats.reasons.first { $0.kind == .notAllowed }?.count == 2)
    #expect(stats.reasons.first { $0.kind == .offline }?.count == 0)
    // Sleep is not watched time.
    #expect(abs(stats.protectedShare! - 74.0 / 100.0) < 1e-9)
}

@Test func statsCutSpansToThePeriod() {
    let entries = [
        entry(0, .started),
        entry(0, .status(.blocked, block: ru)),
        entry(60, .status(.protected)),
    ]
    let stats = JournalStats(entries: entries, interval: DateInterval(start: at(30), end: at(90)), now: at(120), calendar: utc)
    #expect(stats.seconds[.blocked] ?? 0 == TimeInterval(30 * 60))
    #expect(stats.seconds[.protected] ?? 0 == TimeInterval(30 * 60))
    #expect(stats.blocks == 1)
}

@Test func statsPerTargetFrozenTimeFreezesAndKills() {
    let entries = [
        entry(0, .started),
        entry(1, .frozen(targets: ["Cursor", "Claude в Safari"], manual: false)),
        entry(6, .thawed(targets: ["Claude в Safari"], manual: false)),
        entry(11, .killed(targets: ["Cursor"], cause: .graceExpired)),
        entry(21, .frozen(targets: ["Telegram"], manual: true)),
        entry(25, .stopped(clean: true)),
    ]
    let stats = JournalStats(entries: entries, interval: DateInterval(start: at(0), end: at(60)), now: at(60), calendar: utc)

    #expect(stats.targets.map(\.name) == ["Cursor", "Claude в Safari", "Telegram"])
    let cursor = stats.targets[0]
    #expect(cursor.frozenSeconds == 600)
    #expect(cursor.freezes == 1)
    #expect(cursor.kills == 1)
    // The run ended: Telegram's freeze ends with it.
    #expect(stats.targets[2].frozenSeconds == 240)
    #expect(stats.kills == 1)
}

@Test func statsCountCountriesAndRealIPChanges() {
    let entries = [
        entry(0, .started),
        entry(0, .ipChanged(ip: "185.10.10.10", country: "NL")),
        entry(10, .ipChanged(ip: "95.165.10.20", country: "RU")),
        entry(15, .stopped(clean: true)),
        // A restart logs the same IP again: not a change.
        entry(20, .started),
        entry(20, .ipChanged(ip: "95.165.10.20", country: "RU")),
        entry(30, .ipChanged(ip: "185.10.10.10", country: "nl")),
    ]
    let stats = JournalStats(entries: entries, interval: DateInterval(start: at(0), end: at(40)), now: at(40), calendar: utc)
    #expect(stats.countries.map(\.code) == ["NL", "RU"])
    #expect(stats.countries.map(\.seconds) == [20 * 60, 15 * 60])
    #expect(stats.ipChanges == 2)
}

@Test func bucketsSplitAtDayBoundariesAndSkipSleep() {
    let day = utc.startOfDay(for: t0)
    let late = day.addingTimeInterval(23 * 3600)
    let entries = [
        JournalEntry(at: late, event: .started),
        JournalEntry(at: late, event: .status(.protected)),
        JournalEntry(at: late.addingTimeInterval(2 * 3600), event: .status(.asleep)),
    ]
    let stats = JournalStats(
        entries: entries, interval: DateInterval(start: day, duration: 3 * 86_400),
        now: late.addingTimeInterval(5 * 3600), bucketUnit: .day, calendar: utc
    )
    #expect(stats.buckets.map(\.start) == [day, day.addingTimeInterval(86_400)])
    #expect(stats.buckets.map(\.status) == [.protected, .protected])
    #expect(stats.buckets.map(\.seconds) == [3600, 3600])
}

@Test func emptyJournalHasNoShare() {
    let stats = JournalStats(entries: [], interval: DateInterval(start: t0, duration: 3600), now: at(60))
    #expect(stats.isEmpty)
    #expect(stats.protectedShare == nil)
    #expect(stats.blocks == 0)
}
