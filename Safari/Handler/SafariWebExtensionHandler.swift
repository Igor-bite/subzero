import Foundation
import SafariServices

// Native side of the Subzero Safari extension (SubzeroSafari.appex).
//
// The extension's background page calls `browser.runtime.sendNativeMessage` every
// second with `{ op: "sync", report?: "<json>" }`. The handler stores the report for
// Subzero and answers with Subzero's latest command: `{ state: "<json>" }`, or `{}`
// when there is none (the extension then fails closed).
//
// The appex runs in the App Sandbox. Its entitlements open exactly one folder,
// `~/Library/Application Support/Subzero/Safari/` (see SafariChannel.swift).
// Built by Scripts/package_app.sh with swiftc, not SwiftPM.

@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]
        let directory = Self.exchangeDirectory

        if let report = message?["report"] as? String, let data = report.data(using: .utf8), data.count < 64 * 1024 {
            Self.write(data, to: directory.appendingPathComponent("report.json"))
        }

        var reply: [String: Any] = [:]
        if let data = try? Data(contentsOf: directory.appendingPathComponent("state.json")),
           let text = String(data: data, encoding: .utf8) {
            reply["state"] = text
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: reply]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    /// The real home folder: inside the sandbox `NSHomeDirectory()` is the container.
    private static var exchangeDirectory: URL {
        let home: String
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            home = String(cString: dir)
        } else {
            home = NSHomeDirectory()
        }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Subzero/Safari", isDirectory: true)
    }

    /// Writes next to the target and renames: atomic, and stays inside the allowed folder.
    private static func write(_ data: Data, to url: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(getpid()).tmp")
        guard (try? data.write(to: temp)) != nil else { return }
        if rename(temp.path, url.path) != 0 {
            try? fm.removeItem(at: temp)
        }
    }
}
