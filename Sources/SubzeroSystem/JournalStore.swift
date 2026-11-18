import Foundation
import SubzeroCore

/// Keeps the journal on disk as JSON Lines: one `JournalEntry` per line, appended as it happens.
/// A second small file remembers when Subzero was last known alive (to close the
/// history of a run that crashed).
public struct JournalStore: Sendable {
    public let url: URL

    public init(url: URL = JournalStore.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        ConfigStore.defaultURL.deletingLastPathComponent().appendingPathComponent("journal.jsonl")
    }

    private var aliveURL: URL {
        url.deletingPathExtension().appendingPathExtension("alive")
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// All entries in time order. Lines that do not parse (a torn write, a newer format) are skipped.
    public func load() -> [JournalEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let entries = data.split(separator: UInt8(ascii: "\n")).compactMap { line in
            try? decoder.decode(JournalEntry.self, from: Data(line))
        }
        return entries.sorted { $0.at < $1.at }
    }

    public func append(_ entries: [JournalEntry]) throws {
        guard !entries.isEmpty else { return }
        let data = try lines(entries)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let handle = try? FileHandle(forWritingTo: url) else {
            try data.write(to: url, options: .atomic)
            return
        }
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Rewrites the whole file (pruning, clearing).
    public func replace(with entries: [JournalEntry]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try lines(entries).write(to: url, options: .atomic)
    }

    public func markAlive(at date: Date) {
        try? String(date.timeIntervalSince1970).write(to: aliveURL, atomically: true, encoding: .utf8)
    }

    public func lastAlive() -> Date? {
        guard let text = try? String(contentsOf: aliveURL, encoding: .utf8), let seconds = Double(text) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private func lines(_ entries: [JournalEntry]) throws -> Data {
        let encoder = Self.encoder()
        var data = Data()
        for entry in entries {
            data.append(try encoder.encode(entry))
            data.append(UInt8(ascii: "\n"))
        }
        return data
    }
}
