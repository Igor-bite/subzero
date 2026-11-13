#if DEBUG
import AppKit
import SubzeroCore
import SwiftUI

/// Debug-only: `Subzero --render-snapshots <dir>` renders the UI with fake data
/// into PNGs (light and dark) and exits. Never starts checks or sends signals.
@MainActor
enum SnapshotRenderer {
    static func runIfRequested() {
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--render-iconset"), flag + 1 < args.count {
            IconRenderer.writeIconset(to: URL(fileURLWithPath: args[flag + 1], isDirectory: true))
            exit(0)
        }
        guard let flag = args.firstIndex(of: "--render-snapshots"), flag + 1 < args.count else { return }
        let dir = URL(fileURLWithPath: args[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        render(to: dir)
        exit(0)
    }

    private static func makeEngine() -> (GuardEngine, cursor: UUID, chrome: UUID, claude: UUID) {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("subzero-snapshot-\(UUID()).json")
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
        // Throw frames are built right before capture: the animation is time-based.
        func throwEngine(age: TimeInterval) -> GuardEngine {
            let (engine, cursor, chrome, _) = makeEngine()
            engine.debugApply(
                snapshot: NetworkSnapshot(ipv4: .agreed(ru, votes: 4), ipv6: .none, countries: [ru: "RU"]),
                verdict: .blocked(.notAllowed(ru, country: "RU")),
                appStates: [cursor: .frozen, chrome: .frozen],
                frozenRuleIDs: [cursor, chrome],
                killDeadline: Date().addingTimeInterval(299),
                // Capture happens ~0.4 s after the view is installed.
                lastHit: ArenaHit(names: ["Cursor"], kinds: [.bundle(path: "/Applications/Cursor.app")], at: Date().addingTimeInterval(0.4 - age), shatter: false)
            )
            return engine
        }
        let timed: [(String, () -> GuardEngine)] = [
            ("menu-throw", { throwEngine(age: 0.3) }),
            ("menu-impact", { throwEngine(age: 0.95) }),
        ]
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

        do {
            let (engine, cursor, chrome, claude) = makeEngine()
            engine.config.dnsCountryRules = [DNSCountryRule(country: "RU", action: .kill)]
            engine.debugApply(
                snapshot: NetworkSnapshot(ipv4: .agreed(nl, votes: 4), ipv6: .none, countries: [nl: "NL", resolverRU: "RU"], dnsResolver: resolverRU),
                verdict: .blocked(.dnsLeak(resolverRU, country: "RU")),
                appStates: [cursor: .notRunning, chrome: .notRunning, claude: .notRunning],
                frozenRuleIDs: []
            )
            scenarios.append(("menu-dnskill", engine))
        }
        do {
            let (engine, cursor, chrome, claude) = makeEngine()
            engine.debugApply(snapshot: nil, verdict: nil, appStates: [cursor: .running, chrome: .running, claude: .notRunning])
            scenarios.append(("menu-checking", engine))
        }

        let appearances: [(String, NSAppearance)] = [
            ("light", NSAppearance(named: .aqua)!),
            ("dark", NSAppearance(named: .darkAqua)!),
        ]

        for (name, make) in timed {
            for (suffix, appearance) in appearances {
                save(MenuView(engine: make()), width: 350, height: nil, appearance: appearance,
                     to: dir.appendingPathComponent("\(name)-\(suffix).png"))
            }
        }

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
            engine.config.dnsCountryRules = [DNSCountryRule(country: "RU", action: .kill), DNSCountryRule(country: "US", action: .off)]
            save(BehaviorTab(engine: engine), width: 600, height: 900, appearance: appearance, to: dir.appendingPathComponent("settings-behavior-\(suffix).png"))
            save(SettingsView(engine: engine), width: 600, height: 620, appearance: appearance, to: dir.appendingPathComponent("settings-window-\(suffix).png"))
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

/// App icon: the golem standing in a frozen arena.
@MainActor
enum IconRenderer {
    static func writeIconset(to dir: URL) {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sizes: [(String, Int)] = [
            ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
            ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
            ("512x512", 512), ("512x512@2x", 1024),
        ]
        for (name, px) in sizes {
            try? render(pixels: px).write(to: dir.appendingPathComponent("icon_\(name).png"))
        }
        print("Iconset written to \(dir.path)")
    }

    static func render(pixels: Int) -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .none
        let s = CGFloat(pixels) / 1024
        let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 24 * s
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.set()
        NSColor.black.setFill()
        squircle.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        squircle.addClip()
        NSGradient(colors: [
            NSColor(red: 0.03, green: 0.04, blue: 0.10, alpha: 1),
            NSColor(red: 0.10, green: 0.22, blue: 0.48, alpha: 1),
            NSColor(red: 0.30, green: 0.62, blue: 0.92, alpha: 1),
        ])!.draw(in: body, angle: 90)
        // Floor.
        let floor = NSRect(x: body.minX, y: body.minY, width: body.width, height: 190 * s)
        NSColor(red: 0.10, green: 0.12, blue: 0.22, alpha: 1).setFill()
        floor.fill()
        NSColor(red: 0.62, green: 0.90, blue: 1.0, alpha: 1).setFill()
        NSRect(x: body.minX, y: floor.maxY - 12 * s, width: body.width, height: 12 * s).fill()
        // Snow.
        var seed: UInt32 = 3
        NSColor.white.withAlphaComponent(0.8).setFill()
        for _ in 0..<26 {
            seed = seed &* 1_103_515_245 &+ 12345
            let x = body.minX + CGFloat(seed % 1000) / 1000 * body.width
            seed = seed &* 1_103_515_245 &+ 12345
            let y = floor.maxY + CGFloat(seed % 1000) / 1000 * (body.maxY - floor.maxY)
            let d = (seed % 3 == 0 ? 20 : 12) * s
            NSRect(x: x.rounded(), y: y.rounded(), width: d, height: d).fill()
        }
        // Fighter.
        let sprite = Frost.sprite(.stance)
        let unit = (19 * s).rounded(.down) > 0 ? (19 * s) : 1
        let w = CGFloat(sprite.width) * unit, h = CGFloat(sprite.height) * unit
        let image = sprite.image(scale: 1)
        image.draw(in: NSRect(x: body.midX - w / 2 + 10 * s, y: floor.maxY - 70 * s, width: w, height: h),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}
#endif
