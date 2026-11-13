import AppKit
import FreezerCore
import SwiftUI

// MARK: - Status palette

extension GuardEngine.Phase {
    var colors: [Color] {
        switch self {
        case .checking: [Color(red: 0.30, green: 0.47, blue: 0.95), Color(red: 0.42, green: 0.36, blue: 0.90)]
        case .protected: [Color(red: 0.16, green: 0.72, blue: 0.45), Color(red: 0.10, green: 0.62, blue: 0.62)]
        case .blocked: [Color(red: 0.93, green: 0.27, blue: 0.30), Color(red: 0.86, green: 0.22, blue: 0.52)]
        case .paused: [Color(red: 0.98, green: 0.62, blue: 0.18), Color(red: 0.95, green: 0.45, blue: 0.20)]
        }
    }

    var tint: Color { colors[0] }

    var symbol: String {
        switch self {
        case .checking: "shield.lefthalf.filled"
        case .protected: "checkmark.shield.fill"
        case .blocked: "xmark.shield.fill"
        case .paused: "pause.circle.fill"
        }
    }

    var nsColor: NSColor? {
        switch self {
        case .checking: nil
        case .protected: .systemGreen
        case .blocked: .systemRed
        case .paused: .systemOrange
        }
    }
}

enum Palette {
    static let frozen = Color(red: 0.20, green: 0.62, blue: 0.95)
    static let running = Color(red: 0.16, green: 0.72, blue: 0.45)
    static let warning = Color.orange
    static let danger = Color(red: 0.93, green: 0.27, blue: 0.30)
    static let manual = Color.purple
}

// MARK: - Building blocks

/// Rounded, softly filled container.
struct Card<Content: View>: View {
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(tint.map { AnyShapeStyle($0.opacity(0.12)) } ?? AnyShapeStyle(.quaternary.opacity(0.55)))
            }
            .overlay {
                if let tint {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(tint.opacity(0.35), lineWidth: 1)
                }
            }
    }
}

struct SectionTitle: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }
}

struct StatusDot: View {
    let color: Color

    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.5), radius: 2)
    }
}

/// Small colored capsule label.
struct Badge: View {
    let text: String
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .bold)) }
            Text(text).font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.15), in: Capsule())
    }
}

/// Round tinted icon button.
struct IconButton: View {
    let symbol: String
    let color: Color
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(hovering ? .white : color)
                .frame(width: 24, height: 24)
                .background(Circle().fill(hovering ? AnyShapeStyle(color.gradient) : AnyShapeStyle(color.opacity(0.15))))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Filled capsule button that keeps its color even when the panel is not key.
struct PillButtonStyle: ButtonStyle {
    var color: Color
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(filled ? AnyShapeStyle(.white) : AnyShapeStyle(color))
            .background(Capsule().fill(filled ? AnyShapeStyle(color.gradient) : AnyShapeStyle(color.opacity(0.15))))
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

/// System Settings style colored square with a white symbol.
struct IconTile: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.gradient))
    }
}

struct AppIcon: View {
    let kind: AppRuleKind
    var size: CGFloat = 24

    var body: some View {
        Group {
            if let icon = AppCatalog.icon(for: kind) {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: kind.needsArguments ? "terminal.fill" : "app.dashed")
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(Color.gray.gradient))
            }
        }
        .frame(width: size, height: size)
    }
}

struct AppStateBadge: View {
    let app: ControlledApp

    var body: some View {
        HStack(spacing: 4) {
            switch app.state {
            case .running: Badge(text: "работает", color: Palette.running, symbol: "circle.fill")
            case .frozen: Badge(text: "заморожено", color: Palette.frozen, symbol: "snowflake")
            case .notRunning: Badge(text: "не запущено", color: .secondary)
            }
            if app.isManuallyFrozen {
                Badge(text: "вручную", color: Palette.manual, symbol: "hand.raised.fill")
            }
            if app.isOverridden {
                Badge(text: "отпущено", color: Palette.warning, symbol: "exclamationmark.triangle.fill")
                    .help("Разморожено вручную и работает при чужом IP до конца блокировки")
            }
        }
    }
}

/// Freeze / unfreeze / SIGKILL controls with an inline kill confirmation.
struct AppControls: View {
    let app: ControlledApp
    let engine: GuardEngine
    @State private var confirmingKill = false

    var body: some View {
        HStack(spacing: 6) {
            if confirmingKill {
                Text("Убить?").font(.caption).foregroundStyle(.secondary)
                Button("Да") {
                    engine.forceKill(app)
                    confirmingKill = false
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.danger)
                .controlSize(.small)
                Button("Нет") { confirmingKill = false }
                    .controlSize(.small)
            } else {
                switch app.state {
                case .frozen:
                    IconButton(symbol: "play.fill", color: Palette.running, help: "Разморозить") { engine.unfreeze(app) }
                case .running:
                    IconButton(symbol: "snowflake", color: Palette.frozen, help: "Заморозить вручную") { engine.freeze(app) }
                case .notRunning:
                    if app.isManuallyFrozen {
                        IconButton(symbol: "minus", color: .secondary, help: "Снять ручную заморозку") { engine.unfreeze(app) }
                    }
                }
                if app.state != .notRunning {
                    IconButton(symbol: "xmark", color: Palette.danger, help: "Закрыть принудительно (SIGKILL)") {
                        confirmingKill = true
                    }
                }
            }
        }
    }
}

extension GuardEngine {
    /// Country of the current external IP, if known.
    var currentCountry: String? {
        guard let snapshot, let ip = snapshot.primaryIP else { return nil }
        return snapshot.countries[ip]
    }

    /// Text next to the menu bar icon, per the user's choice.
    var menuBarText: String? {
        switch config.menuBarText {
        case .icon:
            return nil
        case .country:
            return currentCountry.map { "\(CountryInfo.flag($0)) \($0)" }
        case .ip:
            return snapshot?.primaryIP?.description
        }
    }

    /// One line for the Dock menu and accessibility.
    var statusSummary: String {
        let place = currentCountry.map { " · \(CountryInfo.flag($0)) \(CountryInfo.name($0))" } ?? ""
        switch phase {
        case .checking: return "Проверяю IP…"
        case .protected: return "Защищено\(place)"
        case .blocked: return (frozenRuleIDs.isEmpty ? "IP не разрешён" : "Заморожено") + place
        case .paused(let until):
            return until == .distantFuture
                ? "Пауза без срока"
                : "Пауза до \(until.formatted(date: .omitted, time: .shortened))"
        }
    }
}

extension CountryInfo {
    static func label(_ code: String) -> String {
        "\(flag(code)) \(name(code))"
    }
}
