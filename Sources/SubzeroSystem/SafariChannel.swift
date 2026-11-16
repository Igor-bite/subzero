import Darwin
import Foundation
import SubzeroCore

/// File exchange with the Safari extension.
///
/// Subzero writes `state.json` (`SafariCommand`), the extension's native handler
/// reads it and writes `report.json` (`SafariReport`). The handler runs in the App
/// Sandbox and may touch only this folder (see `Safari/SubzeroSafari.entitlements`),
/// so the path must stay `~/Library/Application Support/Subzero/Safari/`.
public struct SafariChannel: Sendable {
    public let directory: URL

    public init(directory: URL = SafariChannel.defaultDirectory) {
        self.directory = directory
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Subzero", isDirectory: true)
            .appendingPathComponent("Safari", isDirectory: true)
    }

    public var commandURL: URL { directory.appendingPathComponent("state.json") }
    public var reportURL: URL { directory.appendingPathComponent("report.json") }

    public func write(_ command: SafariCommand) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // Atomic: the extension never reads half a file.
        try encoder.encode(command).write(to: commandURL, options: .atomic)
    }

    public func readCommand() -> SafariCommand? {
        guard let data = try? Data(contentsOf: commandURL) else { return nil }
        return try? JSONDecoder().decode(SafariCommand.self, from: data)
    }

    public func readReport() -> SafariReport? {
        guard let data = try? Data(contentsOf: reportURL) else { return nil }
        return try? JSONDecoder().decode(SafariReport.self, from: data)
    }
}
