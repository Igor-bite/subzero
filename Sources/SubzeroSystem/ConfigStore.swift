import Foundation
import SubzeroCore

/// Reads and writes `GuardConfig` as JSON on disk.
public struct ConfigStore: Sendable {
    public let url: URL

    public init(url: URL = ConfigStore.defaultURL) {
        self.url = url
    }

    public static var standard: ConfigStore { ConfigStore() }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Subzero", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    public func load() -> GuardConfig {
        guard let data = try? Data(contentsOf: url) else { return GuardConfig() }
        return (try? JSONDecoder().decode(GuardConfig.self, from: data)) ?? GuardConfig()
    }

    public func save(_ config: GuardConfig) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}
