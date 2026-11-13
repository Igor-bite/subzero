#if DEBUG
import AppKit
import FreezerCore
import SwiftUI

/// Debug-only: `Freezer --render-snapshots <dir>` renders the UI with fake data
/// into PNGs (light and dark) and exits. Never starts checks or sends signals.
@MainActor
enum SnapshotRenderer {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let flag = args.firstIndex(of: "--render-snapshots"), flag + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        render(to: dir)
        exit(0)
    }

    private static func makeEngine() -> (GuardEngine, cursor: UUID, chrome: UUID, claude: UUID) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("freezer-snapshot-\(UUID()).json")
        let engine = GuardEngine(store: ConfigStore(url: tmp), defaults: nil)
        var config = GuardConfig()
        config.allowedCountries = ["NL", "DE"]
        config.allowedNetworks = ["185.10.10.10", "10.0.0.0/8"]
        let cursor = AppRule(name: "Cursor", kind: .bundle(path: "/Applications/Cursor.app"))
        let chrome = AppRule(name: "Google Chrome", kind: .bundle(path: "/Applications/Google Chrome.app"))
        let claude = AppRule(name: "Claude Code (CLI)", kind: .patterns(["claude"]))
        config.apps = [cursor, chrome, claude, AppRule(name: "Discord", kind: .bundle(path: "/Applications/Discord.app"), enabled: false)]
        engine.config = config
        return (engine, cursor.id, chrome.id, claude.id)
    }

    private static func render(to dir: URL) {
        let nl = IPAddress("185.10.10.10")!
        let ru = IPAddress("95.165.10.20")!
        let resolverRU = IPAddress("77.88.8.8")!
        let telegram = ManualFreeze(id: UUID(), name: "Telegram", kind: .bundle(path: "/Applications/Telegram.app"))

        var scenarios: [(String, GuardEngine)] = []

        do {
            let (engine, cursor, chrome, claude) = makeEngine()
            engine.config.dnsCheck = .warn
            engine.debugApply(
                snapshot: NetworkSnapshot(ipv4: .agreed(nl, votes: 4), ipv6: .none, countries: [nl: "NL", resolverRU: "RU"], dnsResolver: resolverRU),
                verdict: .allowed(nl),
                appStates: [cursor: .running, chrome: .running, claude: .notRunning, telegram.id: .frozen],
                manualFreezes: [telegram]
            )
            scenarios.append(("menu-protected", engine))
        }
        do {
            let (engine, cursor, chrome, claude) = makeEngine()
            engine.debugApply(
                snapshot: NetworkSnapshot(ipv4: .agreed(ru, votes: 4), ipv6: .none, countries: [ru: "RU", resolverRU: "RU"], dnsResolver: resolverRU),
                verdict: .blocked(.notAllowed(ru, country: "RU")),
                appStates: [cursor: .frozen, chrome: .running, claude: .frozen],
                frozenRuleIDs: [cursor, claude],
                overrides: [chrome],
                killDeadline: Date().addingTimeInterval(187)
            )
            scenarios.append(("menu-blocked", engine))
        }
        do {
            let (engine, cursor, chrome, _) = makeEngine()
            engine.debugApply(
                snapshot: NetworkSnapshot(ipv4: .agreed(nl, votes: 4), ipv6: .none, countries: [nl: "NL"]),
                verdict: .allowed(nl),
                appStates: [cursor: .running, chrome: .running],
                pausedUntil: Date().addingTimeInterval(45 * 60)
            )
            scenarios.append(("menu-paused", engine))
        }

        let appearances: [(String, NSAppearance)] = [
            ("light", NSAppearance(named: .aqua)!),
            ("dark", NSAppearance(named: .darkAqua)!),
        ]

        for (name, engine) in scenarios {
            for (suffix, appearance) in appearances {
                save(MenuView(engine: engine), width: 350, height: nil, appearance: appearance,
                     to: dir.appendingPathComponent("\(name)-\(suffix).png"))
            }
        }

        // Current IP not yet in the allowed list, so "Добавить текущий" shows up.
        let fresh = IPAddress("89.20.30.40")!
        let (engine, cursor, chrome, claude) = makeEngine()
        engine.debugApply(
            snapshot: NetworkSnapshot(ipv4: .agreed(fresh, votes: 4), ipv6: .none, countries: [fresh: "NL"]),
            verdict: .allowed(fresh),
            appStates: [cursor: .frozen, chrome: .running, claude: .notRunning],
            manualFreezes: [ManualFreeze(id: UUID(), name: "Cursor", kind: .bundle(path: "/Applications/Cursor.app")), telegram]
        )
        for (suffix, appearance) in appearances {
            save(AppsTab(engine: engine), width: 600, height: 540, appearance: appearance, to: dir.appendingPathComponent("settings-apps-\(suffix).png"))
            save(AllowTab(engine: engine), width: 600, height: 540, appearance: appearance, to: dir.appendingPathComponent("settings-allow-\(suffix).png"))
            save(BehaviorTab(engine: engine), width: 600, height: 640, appearance: appearance, to: dir.appendingPathComponent("settings-behavior-\(suffix).png"))
        }
        print("Snapshots written to \(dir.path)")
    }

    private static func save(_ view: some View, width: CGFloat, height: CGFloat?, appearance: NSAppearance, to url: URL) {
        let root = view
            .frame(width: width)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.appearance = appearance
        let size = NSSize(width: width, height: height ?? host.fittingSize.height)

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
#endif
