import Foundation
import Testing
import SubzeroCore
import SubzeroSystem

private func tempStore() -> JournalStore {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("subzero-journal-\(UUID())", isDirectory: true)
    return JournalStore(url: dir.appendingPathComponent("journal.jsonl"))
}

@Test func journalStoreAppendsAndLoadsInOrder() throws {
    let store = tempStore()
    let t = Date(timeIntervalSince1970: 1_700_000_000)
    let first = JournalEntry(at: t, event: .started)
    let second = JournalEntry(at: t.addingTimeInterval(5), event: .status(.blocked, block: JournalBlock(kind: .offline)))
    try store.append([first])
    try store.append([second])
    #expect(store.load() == [first, second])

    try store.replace(with: [second])
    #expect(store.load() == [second])
}

@Test func journalStoreSkipsBrokenLines() throws {
    let store = tempStore()
    let entry = JournalEntry(at: Date(timeIntervalSince1970: 1_700_000_000), event: .stopped(clean: true))
    try store.append([entry])
    let handle = try FileHandle(forWritingTo: store.url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data("{\"torn\":\n".utf8))
    try handle.close()
    #expect(store.load() == [entry])
}

@Test func journalStoreRemembersLastAlive() {
    let store = tempStore()
    #expect(store.lastAlive() == nil)
    try? FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let t = Date(timeIntervalSince1970: 1_700_000_123)
    store.markAlive(at: t)
    #expect(store.lastAlive() == t)
}
