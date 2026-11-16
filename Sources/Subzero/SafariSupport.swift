import AppKit
import Observation
import SafariServices
import SubzeroCore
import SubzeroEngine
import SwiftUI

/// The Safari extension embedded in Subzero.app: whether Safari has it turned on,
/// and a shortcut to its page in Safari settings.
@MainActor
@Observable
final class SafariExtension {
    static let shared = SafariExtension()

    /// Bundle id of `Contents/PlugIns/SubzeroSafari.appex`; nil when run outside the .app.
    let identifier: String?
    /// `nil` until Safari answered.
    private(set) var isEnabled: Bool?
    @ObservationIgnored private var lastRefresh = Date.distantPast

    private init() {
        let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("SubzeroSafari.appex")
        identifier = url.flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// Asks Safari whether the extension is on. Throttled: the call is not free for Safari.
    func refresh() {
        guard let identifier, Date().timeIntervalSince(lastRefresh) > 5 else { return }
        lastRefresh = Date()
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: identifier) { state, _ in
            let enabled = state?.isEnabled
            Task { @MainActor in SafariExtension.shared.isEnabled = enabled }
        }
    }

    func openSafariSettings() {
        guard let identifier else { return }
        SFSafariApplication.showPreferencesForExtension(withIdentifier: identifier) { _ in
            Task { @MainActor in
                SafariExtension.shared.lastRefresh = .distantPast
                SafariExtension.shared.refresh()
            }
        }
    }

    /// What is wrong with the setup, if anything, for a hint line.
    func problem(_ engine: GuardEngine) -> String? {
        guard identifier != nil else {
            return "Расширение Safari есть только в собранном Subzero.app."
        }
        if isEnabled == false {
            return "Расширение Subzero выключено в Safari — вкладки не защищены."
        }
        switch engine.safariLink {
        case .silent:
            return "Расширение ещё не выходило на связь. Включите его: Safari → Настройки → Расширения → Subzero."
        case .connected(let report):
            let blind = engine.controlledSites.filter { $0.hasAccess == false }
            if !blind.isEmpty {
                let domains = blind.flatMap(\.domains).prefix(3).joined(separator: ", ")
                return "Safari не дал расширению доступ к \(domains). Разрешите эти сайты в настройках расширения."
            }
            if !report.blocksNetwork {
                return "Safari не дал заблокировать сеть: при проверке IP вкладки будут выгружаться."
            }
            return nil
        case .lost:
            return nil
        }
    }
}

// MARK: - Views

/// Letter tile for a site (no brand artwork).
struct SiteIcon: View {
    let id: String
    let name: String
    var size: CGFloat = 24

    private var color: Color {
        switch id {
        case "claude": Arcade.ember
        case "chatgpt": Arcade.life
        default: Arcade.ice
        }
    }

    /// Short distinct mark: both sites start with "C".
    private var monogram: String {
        switch id {
        case "claude": "Cl"
        case "chatgpt": "GPT"
        default: String(name.prefix(1))
        }
    }

    var body: some View {
        Text(monogram)
            .font(.system(size: size * (monogram.count > 2 ? 0.34 : 0.48), weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .padding(.horizontal, 2)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(color.gradient))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "safari.fill")
                    .font(.system(size: size * 0.38, weight: .bold))
                    .foregroundStyle(.white, Arcade.iceDeep)
                    .background(Circle().fill(Arcade.night).padding(-1))
                    .offset(x: size * 0.12, y: size * 0.12)
            }
    }
}

enum TabNoun {
    static func text(_ n: Int) -> String {
        let mod100 = n % 100, mod10 = n % 10
        let noun: String
        if (11...14).contains(mod100) {
            noun = "вкладок"
        } else {
            switch mod10 {
            case 1: noun = "вкладка"
            case 2...4: noun = "вкладки"
            default: noun = "вкладок"
            }
        }
        return "\(n) \(noun)"
    }
}

struct SiteStateBadge: View {
    let site: ControlledSite

    var body: some View {
        HStack(spacing: 4) {
            switch site.state {
            case .running:
                Badge(text: TabNoun.text(site.tabCount), color: Palette.running, symbol: "circle.fill")
            case .frozen:
                Badge(text: "заморожено · \(site.tabCount)", color: Palette.frozen, symbol: "snowflake")
            case .notRunning:
                Badge(text: "нет вкладок", color: .secondary)
            }
            if site.mode == .hold && site.openTabs > 0 {
                Badge(text: "сеть отрезана", color: Palette.warning, symbol: "wifi.slash")
                    .help("Пока IP перепроверяется, сайт не получает запросов. Вкладки остаются как есть.")
            }
            if site.isManuallyFrozen {
                Badge(text: "вручную", color: Palette.manual, symbol: "hand.raised.fill")
            }
            if site.isOverridden {
                Badge(text: "отпущено", color: Palette.warning, symbol: "exclamationmark.triangle.fill")
                    .help("Разморожено вручную и работает при чужом IP до конца блокировки")
            }
            if site.hasAccess == false {
                Badge(text: "нет доступа", color: Palette.danger, symbol: "lock.fill")
                    .help("Safari не дал расширению доступ к \(site.domains.joined(separator: ", ")): вкладки не видны и не замораживаются.")
            }
        }
    }
}

/// Freeze / unfreeze / close-tabs controls with an inline close confirmation.
struct SiteControls: View {
    let site: ControlledSite
    let engine: GuardEngine
    @State private var confirmingClose = false

    var body: some View {
        HStack(spacing: 6) {
            if confirmingClose {
                Text("Закрыть?").font(.caption).foregroundStyle(.secondary)
                Button("Да") {
                    engine.closeSite(site)
                    confirmingClose = false
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.danger)
                .controlSize(.small)
                Button("Нет") { confirmingClose = false }
                    .controlSize(.small)
            } else {
                if site.mode == .run {
                    IconButton(symbol: "snowflake", color: Palette.frozen, help: "Заморозить вкладки \(site.name) вручную") {
                        engine.freezeSite(site.id)
                    }
                } else {
                    IconButton(symbol: "play.fill", color: Palette.running, help: "Разморозить") { engine.unfreezeSite(site) }
                }
                if site.tabCount > 0 {
                    IconButton(symbol: "xmark", color: Palette.danger, help: "Закрыть все вкладки \(site.name)") {
                        confirmingClose = true
                    }
                }
            }
        }
    }
}

/// "на связи" / "нет связи" tag for the Safari extension.
struct SafariLinkBadge: View {
    let engine: GuardEngine

    var body: some View {
        switch engine.safariLink {
        case .connected:
            Badge(text: "на связи", color: Palette.running, symbol: "checkmark")
                .help("Расширение Safari отвечает")
        case .lost(let since):
            Badge(text: "нет связи", color: Palette.warning, symbol: "wifi.slash")
                .help("Последний ответ расширения: \(since.formatted(date: .omitted, time: .shortened)). Safari закрыт или расширение выключено.")
        case .silent:
            Badge(text: SafariExtension.shared.isEnabled == true ? "ждёт Safari" : "не подключено", color: .secondary)
        }
    }
}
