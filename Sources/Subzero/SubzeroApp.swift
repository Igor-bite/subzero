import AppKit
import SubzeroCore
import SwiftUI

@main
struct SubzeroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuView(engine: appDelegate.engine)
        } label: {
            MenuBarLabel(engine: appDelegate.engine)
        }
        .menuBarExtraStyle(.window)

        Window("Subzero — настройки", id: SettingsView.windowID) {
            SettingsView(engine: appDelegate.engine)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .commands { SubzeroCommands() }
    }
}

struct SubzeroCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Настройки…") {
                openWindow(id: SettingsView.windowID)
                NSApp.activate()
            }
            .keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(replacing: .newItem) {}
    }
}

/// Lets AppKit code (Dock clicks, Dock menu) open the SwiftUI settings window.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    var action: OpenWindowAction?

    private var settingsWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains(SettingsView.windowID) == true }
    }

    var isSettingsVisible: Bool { settingsWindow?.isVisible == true }

    func openSettings() {
        NSApp.activate()
        if let action {
            action(id: SettingsView.windowID)
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}

/// Whether Subzero shows up in the Dock (default: yes).
@MainActor
enum DockPolicy {
    static let key = "showInDock"

    static var enabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    static func apply(_ show: Bool) {
        NSApp.setActivationPolicy(show ? .regular : .accessory)
        if !show {
            // Switching to accessory hides our windows; bring settings back.
            DispatchQueue.main.async { WindowOpener.shared.openSettings() }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = GuardEngine()
    private var signalSources: [DispatchSourceSignal] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        // One instance only: a second one would fight over SIGSTOP/SIGCONT.
        if let id = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .filter { $0 != NSRunningApplication.current }
            if let other = others.first {
                other.activate()
                exit(0)
            }
        }
        if !DockPolicy.enabled {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        SnapshotRenderer.runIfRequested()
        #endif
        // On kill/logout signals, unfreeze apps before exiting.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.engine.shutdown()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
        engine.start()

        // Nothing configured yet: show settings right away.
        if engine.config.apps.isEmpty || engine.config.allowedCountries.isEmpty && engine.config.allowedNetworks.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                WindowOpener.shared.openSettings()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.shutdown()
    }

    /// Dock icon click with no window open: show settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // `flag` is true whenever the menu bar item exists (its windows count as visible),
        // so check the settings window itself.
        if !WindowOpener.shared.isSettingsVisible { WindowOpener.shared.openSettings() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Right-click menu on the Dock icon.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let status = NSMenuItem(title: engine.statusSummary, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if !engine.frozenAppNames.isEmpty {
            let frozen = NSMenuItem(title: "❄︎ \(engine.frozenAppNames.joined(separator: ", "))", action: nil, keyEquivalent: "")
            frozen.isEnabled = false
            menu.addItem(frozen)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Проверить IP сейчас") { [engine] in engine.requestCheck() })
        if case .paused = engine.phase {
            menu.addItem(ClosureMenuItem("Снять паузу") { [engine] in engine.endPause() })
        } else {
            menu.addItem(ClosureMenuItem("Пауза на 15 минут") { [engine] in engine.pause(for: 15 * 60) })
            menu.addItem(ClosureMenuItem("Пауза на 1 час") { [engine] in engine.pause(for: 60 * 60) })
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Настройки…") { WindowOpener.shared.openSettings() })
        return menu
    }
}

/// NSMenuItem that runs a closure.
@MainActor
final class ClosureMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(_ title: String, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func fire() { handler() }
}

struct MenuBarLabel: View {
    let engine: GuardEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let phase = engine.phase
        HStack(spacing: 4) {
            Image(nsImage: MenuBarArt.image(color: phase.nsColor))
            if let text = engine.menuBarText {
                Text(text).monospacedDigit()
            }
        }
        .accessibilityLabel("Subzero: \(engine.statusSummary)")
        .task { WindowOpener.shared.action = openWindow }
    }
}
