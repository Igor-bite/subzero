import AppKit
import FreezerCore

enum AppCatalog {
    /// Apps commonly worth protecting; shown when installed.
    static let bundleNames = [
        "Claude", "ChatGPT", "Codex", "Cursor", "Windsurf", "Perplexity", "Comet",
        "Google Chrome", "Microsoft Edge", "Firefox", "Brave Browser", "Yandex", "Arc", "Opera", "Vivaldi",
        "Telegram", "Discord", "Slack", "Zoom", "Figma", "Notion", "Spotify",
        "TradingView", "Binance", "Upwork",
    ]

    static let cliPresets: [AppRule] = [
        AppRule(name: "Claude Code (CLI)", kind: .patterns(["claude", "/.local/share/claude/versions/", "@anthropic-ai/claude-code"])),
        AppRule(name: "Codex CLI", kind: .patterns(["codex", "@openai/codex"])),
        AppRule(name: "Gemini CLI", kind: .patterns(["gemini", "@google/gemini-cli"])),
    ]

    /// Names that must never be frozen: the desktop itself would hang.
    static let forbiddenNames: Set<String> = [
        "launchd", "WindowServer", "loginwindow", "Finder", "Dock", "SystemUIServer",
        "ControlCenter", "kernel_task", "Freezer",
    ]

    static var searchDirectories: [URL] {
        [URL(fileURLWithPath: "/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
    }

    static func installedPresets() -> [AppRule] {
        bundleNames.compactMap { name in
            for dir in searchDirectories {
                let url = dir.appendingPathComponent("\(name).app")
                if FileManager.default.fileExists(atPath: url.path) {
                    return rule(forAppAt: url)
                }
            }
            return nil
        }
    }

    static func rule(forAppAt url: URL) -> AppRule {
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        return AppRule(name: name, kind: .bundle(path: url.standardizedFileURL.path))
    }

    /// Why a rule must not be added, or nil if it is fine.
    static func rejection(for rule: AppRule) -> String? {
        switch rule.kind {
        case .bundle(let path):
            if path.hasPrefix("/System/") { return "Системные программы защищать нельзя." }
            if path.hasSuffix("/Safari.app") { return "Safari защитить нельзя: его вкладки живут в общих системных процессах." }
            if path == Bundle.main.bundlePath { return "Freezer не может замораживать сам себя." }
        case .patterns(let patterns):
            let cleaned = patterns.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if cleaned.isEmpty { return "Укажите хотя бы одно имя или часть пути." }
            if let bad = cleaned.first(where: { forbiddenNames.contains($0) || $0 == "/" || $0.count < 2 }) {
                return "«\(bad)» нельзя: это заморозит систему."
            }
        }
        return nil
    }

    static func icon(for kind: AppRuleKind) -> NSImage? {
        guard case .bundle(let path) = kind, FileManager.default.fileExists(atPath: path) else { return nil }
        return NSWorkspace.shared.icon(forFile: path)
    }

    struct Candidate {
        let name: String
        let kind: AppRuleKind
        let icon: NSImage?
    }

    /// Running regular apps that can be frozen by hand.
    @MainActor
    static func runningCandidates(excluding excluded: Set<AppRuleKind>) -> [Candidate] {
        var seen = Set<AppRuleKind>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0 != NSRunningApplication.current }
            .compactMap { app -> Candidate? in
                guard let url = app.bundleURL else { return nil }
                let kind = AppRuleKind.bundle(path: url.standardizedFileURL.path)
                guard !excluded.contains(kind), !seen.contains(kind) else { return nil }
                let name = app.localizedName ?? url.deletingPathExtension().lastPathComponent
                guard rejection(for: AppRule(name: name, kind: kind)) == nil else { return nil }
                seen.insert(kind)
                let icon = (app.icon?.copy() as? NSImage).map { image -> NSImage in
                    image.size = NSSize(width: 16, height: 16)
                    return image
                }
                return Candidate(name: name, kind: kind, icon: icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func subtitle(for rule: AppRule) -> String {
        switch rule.kind {
        case .bundle(let path): path
        case .patterns(let p): p.joined(separator: ", ")
        }
    }
}
