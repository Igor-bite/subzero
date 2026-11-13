import AppKit
import SubzeroCore
import SwiftUI

// MARK: - Status palette

extension GuardEngine.Phase {
    var colors: [Color] {
        switch self {
        case .checking: [Arcade.ice, Arcade.iceDeep]
        case .protected: [Arcade.life, Color(red: 0.12, green: 0.55, blue: 0.40)]
        case .blocked: [Arcade.blood, Color(red: 0.55, green: 0.08, blue: 0.20)]
        case .paused: [Arcade.caution, Arcade.ember]
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
        case .protected: nil
        case .blocked: .systemRed
        case .paused: .systemOrange
        }
    }
}

enum Palette {
    static let frozen = Arcade.ice
    static let running = Arcade.life
    static let warning = Arcade.caution
    static let danger = Arcade.blood
    static let manual = Color(red: 0.72, green: 0.52, blue: 1.0)
}

// MARK: - Building blocks

/// HUD panel: dark steel plate with cut corners and a bevelled frame.
struct Card<Content: View>: View {
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        let frame = tint ?? Arcade.steel
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                ZStack {
                    Chamfer(cut: 7).fill(LinearGradient(colors: [Arcade.panelHigh, Arcade.panel], startPoint: .top, endPoint: .bottom))
                    if let tint {
                        Chamfer(cut: 7).fill(tint.opacity(0.12))
                    }
                    Chamfer(cut: 7).strokeBorder(Arcade.night, lineWidth: 3)
                    Chamfer(cut: 7).inset(by: 1).strokeBorder(frame.opacity(0.9), lineWidth: 1.5)
                    Chamfer(cut: 6).inset(by: 3).strokeBorder(.white.opacity(0.06), lineWidth: 1)
                }
            }
    }
}

struct SectionTitle: View {
    let text: String

    var body: some View {
        HStack(spacing: 5) {
            Rectangle().fill(Arcade.gold).frame(width: 4, height: 4)
            Text(text.uppercased())
                .font(Arcade.font(10, weight: .black))
                .foregroundStyle(Arcade.gold)
                .tracking(1.2)
        }
    }
}

/// Square "LED".
struct StatusDot: View {
    let color: Color

    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 7, height: 7)
            .overlay(Rectangle().strokeBorder(Arcade.night, lineWidth: 1))
            .shadow(color: color.opacity(0.7), radius: 3)
    }
}

/// Small square-cornered tag.
struct Badge: View {
    let text: String
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 7, weight: .black)) }
            Text(text.uppercased()).font(Arcade.font(8.5, weight: .black)).tracking(0.4)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(Chamfer(cut: 2.5).fill(color.opacity(0.16)))
        .overlay(Chamfer(cut: 2.5).strokeBorder(color.opacity(0.55), lineWidth: 1))
    }
}

/// Square bevelled icon button.
struct IconButton: View {
    let symbol: String
    let color: Color
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .black))
                .foregroundStyle(hovering ? Arcade.night : color)
                .frame(width: 24, height: 24)
                .background(BevelPlate(color: color, lit: hovering, cut: 4))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Bevelled plate behind buttons: light top edge, dark bottom edge.
struct BevelPlate: View {
    let color: Color
    var lit = false
    var filled = false
    var cut: CGFloat = 5
    var pressed = false

    var body: some View {
        ZStack {
            Chamfer(cut: cut).fill(Arcade.night)
            Chamfer(cut: cut).inset(by: 1)
                .fill(lit || filled
                      ? AnyShapeStyle(LinearGradient(colors: [color.mix(with: .white, by: 0.25), color, color.mix(with: .black, by: 0.35)], startPoint: .top, endPoint: .bottom))
                      : AnyShapeStyle(color.opacity(0.14)))
            Chamfer(cut: cut).inset(by: 1).strokeBorder(color.opacity(lit || filled ? 0 : 0.6), lineWidth: 1)
            if lit || filled {
                Rectangle().fill(.white.opacity(pressed ? 0 : 0.35)).frame(height: 1).padding(.horizontal, cut + 1)
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 2)
            }
        }
    }
}

/// Arcade button: chunky, uppercase, bevelled. Keeps its color when the panel is not key.
struct PillButtonStyle: ButtonStyle {
    var color: Color
    var filled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Arcade.font(11, weight: .black))
            .textCase(.uppercase)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(filled ? Arcade.night : color)
            .background(BevelPlate(color: color, filled: filled, pressed: configuration.isPressed))
            .offset(y: configuration.isPressed ? 1 : 0)
            .contentShape(Chamfer(cut: 5))
    }
}

/// Square tile with a white symbol, pixel-panel style.
struct IconTile: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(BevelPlate(color: color, filled: true, cut: 4))
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

// MARK: - Process tree

/// "14 процессов ›": count of caught processes, expands the list.
struct ProcessToggle: View {
    let processes: [ProcessRecord]
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        let stopped = processes.filter(\.isStopped).count
        Button(action: action) {
            HStack(spacing: 3) {
                Text(verbatim: "\(processes.count) \(Self.noun(processes.count))")
                if stopped > 0 && stopped < processes.count {
                    Text(verbatim: "· \(stopped)")
                    Image(systemName: "snowflake").foregroundStyle(Palette.frozen)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(expanded ? "Скрыть процессы" : "Показать процессы программы и её потомков")
    }

    static func noun(_ n: Int) -> String {
        let mod100 = n % 100, mod10 = n % 10
        if (11...14).contains(mod100) { return "процессов" }
        switch mod10 {
        case 1: return "процесс"
        case 2...4: return "процесса"
        default: return "процессов"
        }
    }
}

/// Process tree of one app: name, pid, real kernel state (stopped or running).
struct ProcessList: View {
    let processes: [ProcessRecord]
    private static let rowHeight: CGFloat = 17
    private static let visibleRows = 8

    var body: some View {
        let nodes = ProcessTree.flatten(processes)
        let list = VStack(alignment: .leading, spacing: 0) {
            ForEach(nodes, id: \.record.pid) { node in
                row(node)
            }
        }
        Group {
            if nodes.count > Self.visibleRows {
                ScrollView { list }
                    .frame(height: (CGFloat(Self.visibleRows) + 0.5) * Self.rowHeight)
            } else {
                list
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(Chamfer(cut: 4).fill(Arcade.night.opacity(0.45)))
    }

    private func row(_ node: ProcessTree.Node) -> some View {
        let record = node.record
        return HStack(spacing: 5) {
            Image(systemName: record.isStopped ? "snowflake" : "circle.fill")
                .font(.system(size: record.isStopped ? 9 : 5, weight: .bold))
                .foregroundStyle(record.isStopped ? Palette.frozen : Palette.running)
                .frame(width: 10)
            Text(record.displayName)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(verbatim: String(record.pid))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.leading, CGFloat(min(node.depth, 4)) * 10)
        .frame(height: Self.rowHeight)
        .help(record.path ?? record.name)
    }
}
