import Foundation
import Observation
import SubzeroCore
import SubzeroSystem

/// In-memory journal backed by a `JournalStore`. `GuardEngine` records into it;
/// hosts read `entries` (observable) and build `JournalStats` from them.
@MainActor
@Observable
public final class Journal {
    /// Every kept entry, oldest first.
    public private(set) var entries: [JournalEntry] = []
    /// Last failure to write the journal, if any.
    public private(set) var lastError: String?

    /// Hard cap on kept entries, whatever the retention.
    public static let maxEntries = 50_000
    /// How often the "still alive" mark is refreshed.
    static let aliveInterval: TimeInterval = 60

    @ObservationIgnored private let store: JournalStore?
    @ObservationIgnored private var lastAlive = Date.distantPast
    @ObservationIgnored private var lastPrune = Date.distantPast

    /// - Parameter store: where entries are kept; `nil` keeps them in memory only.
    public init(store: JournalStore?) {
        self.store = store
        entries = store?.load() ?? []
    }

    /// Start of a run: closes the previous run if it did not stop cleanly, then records `.started`.
    func open(now: Date, keepDays: Int) {
        if let last = entries.last, last.event != .stopped(clean: true), last.event != .stopped(clean: false) {
            // Crashed or force-quit: the run ended when it was last seen alive.
            let alive = store?.lastAlive() ?? last.at
            let end = min(max(alive, last.at), now)
            record(.stopped(clean: false), at: end)
        }
        prune(now: now, keepDays: keepDays)
        record(.started, at: now)
        store?.markAlive(at: now)
        lastAlive = now
    }

    /// Clean end of a run.
    func close(now: Date) {
        record(.stopped(clean: true), at: now)
        store?.markAlive(at: now)
    }

    /// Called every engine tick: refreshes the alive mark, prunes once an hour.
    func heartbeat(now: Date, keepDays: Int) {
        if now.timeIntervalSince(lastAlive) >= Self.aliveInterval {
            store?.markAlive(at: now)
            lastAlive = now
        }
        if now.timeIntervalSince(lastPrune) >= 3600 {
            prune(now: now, keepDays: keepDays)
        }
    }

    func record(_ event: JournalEvent, at date: Date = Date()) {
        let entry = JournalEntry(at: date, event: event)
        entries.append(entry)
        do {
            try store?.append([entry])
            if lastError != nil { lastError = nil }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Drops entries older than `keepDays` days and beyond `maxEntries`.
    func prune(now: Date, keepDays: Int) {
        lastPrune = now
        let cutoff = now.addingTimeInterval(-Double(max(1, keepDays)) * 86_400)
        var kept = entries.drop { $0.at < cutoff }
        if kept.count > Self.maxEntries { kept = kept.suffix(Self.maxEntries) }
        guard kept.count != entries.count else { return }
        entries = Array(kept)
        save()
    }

    /// Forgets everything.
    public func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        do {
            try store?.replace(with: entries)
            if lastError != nil { lastError = nil }
        } catch {
            lastError = error.localizedDescription
        }
    }

    #if DEBUG
    /// Replaces the entries for UI snapshots. Never touches the store.
    public func debugReplace(_ entries: [JournalEntry]) {
        self.entries = entries
    }
    #endif
}
