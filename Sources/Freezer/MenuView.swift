import AppKit
import FreezerCore
import SwiftUI

struct MenuView: View {
    let engine: GuardEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 10) {
            HeaderCard(engine: engine)
            if case .blocked(let reason) = engine.phase {
                BlockedCard(engine: engine, reason: reason)
            }
            if case .paused(let until) = engine.phase {
                PausedCard(engine: engine, until: until)
            }
            SetupHints(engine: engine, openSettings: openSettings)
            NetworkCard(engine: engine)
            AppsCard(engine: engine)
            FooterBar(engine: engine, openSettings: openSettings)
        }
        .padding(12)
        .frame(width: 350)
    }

    private func openSettings() {
        openWindow(id: SettingsView.windowID)
        NSApp.activate()
    }
}

// MARK: - Header

private struct HeaderCard: View {
    let engine: GuardEngine

    var body: some View {
        let phase = engine.phase
        HStack(spacing: 12) {
            Image(systemName: phase.symbol)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.white.opacity(0.22)))
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(title(phase))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                Text(subtitle(phase))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                engine.requestCheck()
            } label: {
                Group {
                    if engine.isChecking {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .bold))
                    }
                }
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(.white.opacity(0.2)))
            }
            .buttonStyle(.plain)
            .help("Проверить сейчас")
            .disabled(engine.isChecking)
        }
        .padding(12)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(LinearGradient(colors: phase.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: phase.tint.opacity(0.35), radius: 6, y: 2)
        }
        .animation(.easeInOut(duration: 0.25), value: phase)
    }

    private func title(_ phase: GuardEngine.Phase) -> String {
        switch phase {
        case .checking: "Проверяю IP…"
        case .protected: engine.enabledRules.isEmpty ? "IP в порядке" : "Защищено"
        case .blocked: engine.frozenRuleIDs.isEmpty ? "IP не разрешён" : "Заморожено"
        case .paused: "Пауза"
        }
    }

    private func subtitle(_ phase: GuardEngine.Phase) -> String {
        switch phase {
        case .checking:
            return "Сверяю адрес с сервисами"
        case .paused(let until):
            return until == .distantFuture
                ? "Без срока — программы не защищены"
                : "До \(until.formatted(date: .omitted, time: .shortened)) — программы не защищены"
        case .protected, .blocked:
            var parts: [String] = []
            if let snap = engine.snapshot, let ip = snap.primaryIP, let code = snap.countries[ip] {
                parts.append(CountryInfo.label(code))
            }
            if let last = engine.lastCheck {
                parts.append(last.formatted(date: .omitted, time: .standard))
            }
            return parts.isEmpty ? "Ещё не проверял" : parts.joined(separator: " · ")
        }
    }
}

// MARK: - Blocked / paused

private struct BlockedCard: View {
    let engine: GuardEngine
    let reason: BlockReason

    var body: some View {
        Card(tint: Palette.danger) {
            Label {
                Text(reason.text).font(.callout).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(Palette.danger)
            }

            if !engine.frozenAppNames.isEmpty {
                Label(engine.frozenAppNames.joined(separator: ", "), systemImage: "snowflake")
                    .font(.callout)
                    .foregroundStyle(Palette.frozen)
                    .lineLimit(2)
            }

            if let deadline = engine.killDeadline, !engine.frozenRuleIDs.isEmpty {
                let left = max(0, deadline.timeIntervalSince(engine.now))
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: "timer")
                        Text("Закрою через \(Int(left) / 60):\(String(format: "%02d", Int(left) % 60))")
                            .monospacedDigit()
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Palette.danger)
                    ProgressView(value: left, total: max(1, engine.config.grace))
                        .tint(Palette.danger)
                }
            }

            if let allowable = reason.allowable {
                HStack {
                    if let code = allowable.country {
                        Button {
                            engine.allowCountry(code)
                        } label: {
                            Text("Разрешить \(CountryInfo.flag(code)) \(code)").lineLimit(1)
                        }
                        .buttonStyle(PillButtonStyle(color: Palette.running))
                        .fixedSize()
                        .help("Добавить \(CountryInfo.name(code)) в разрешённые страны")
                    }
                    Button { engine.allowIP(allowable.ip) } label: {
                        Text("Только этот IP").lineLimit(1)
                    }
                    .buttonStyle(PillButtonStyle(color: Palette.running, filled: false))
                    .fixedSize()
                    .help("Добавить \(allowable.ip.description) в разрешённые адреса")
                }
            }
        }
    }
}

private struct PausedCard: View {
    let engine: GuardEngine
    let until: Date

    var body: some View {
        Card(tint: Palette.warning) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning)
                Text("Защита выключена: программы работают при любом IP.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                engine.endPause()
            } label: {
                Label("Снять паузу", systemImage: "play.fill")
            }
            .buttonStyle(PillButtonStyle(color: Palette.warning))
        }
    }
}

private struct SetupHints: View {
    let engine: GuardEngine
    let openSettings: () -> Void

    var body: some View {
        if engine.config.allowedCountries.isEmpty && engine.config.allowedNetworks.isEmpty {
            Card(tint: .blue) {
                Label("Нет разрешённых стран — любой IP считается чужим.", systemImage: "globe")
                    .font(.callout)
                if let snap = engine.snapshot, let ip = snap.primaryIP, let code = snap.countries[ip] {
                    Button("Разрешить \(CountryInfo.label(code))") { engine.allowCountry(code) }
                        .buttonStyle(PillButtonStyle(color: .blue))
                }
            }
        }
        if engine.enabledRules.isEmpty && engine.manualFreezes.isEmpty {
            Card(tint: .blue) {
                HStack {
                    Label("Не выбраны программы для защиты.", systemImage: "app.dashed").font(.callout)
                    Spacer()
                    Button("Выбрать…", action: openSettings)
                        .buttonStyle(PillButtonStyle(color: .blue))
                }
            }
        }
        if let error = engine.lastError {
            Text(error).font(.caption).foregroundStyle(Palette.danger)
        }
    }
}

// MARK: - Network

private struct NetworkCard: View {
    let engine: GuardEngine

    var body: some View {
        if let snap = engine.snapshot {
            Card {
                SectionTitle(text: "Сеть")
                ipRow(label: "IPv4", consensus: snap.ipv4, snap: snap, total: IPProbe.ipv4Services.count)
                if engine.config.checkIPv6 {
                    ipRow(label: "IPv6", consensus: snap.ipv6, snap: snap, total: IPProbe.ipv6Services.count)
                }
                if engine.config.dnsCheck != .off {
                    dnsRow(snap)
                }
            }
        }
    }

    private func isAllowed(_ ip: IPAddress, _ snap: NetworkSnapshot) -> Bool {
        engine.config.allowRules.allows(ip, country: snap.countries[ip])
    }

    private func ipRow(label: String, consensus: Consensus, snap: NetworkSnapshot, total: Int) -> some View {
        HStack(spacing: 8) {
            switch consensus {
            case .none:
                StatusDot(color: .gray)
                rowLabel(label)
                Text("нет").foregroundStyle(.secondary)
                Spacer()
            case .agreed(let ip, let votes):
                StatusDot(color: isAllowed(ip, snap) ? Palette.running : Palette.danger)
                rowLabel(label)
                if let code = snap.countries[ip] {
                    Text(CountryInfo.label(code)).lineLimit(1)
                }
                Text(ip.description)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Text("\(votes)/\(total)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help("Столько сервисов назвали этот адрес")
            case .disagreement(let ips):
                StatusDot(color: Palette.danger)
                rowLabel(label)
                Text("разные: \(ips.map(\.description).joined(separator: ", "))")
                    .foregroundStyle(Palette.danger)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
        }
        .font(.callout)
    }

    private func dnsRow(_ snap: NetworkSnapshot) -> some View {
        let leak = dnsLeak(in: snap, rules: engine.config.allowRules)
        let leakColor = engine.config.dnsCheck == .block ? Palette.danger : Palette.warning
        return HStack(spacing: 8) {
            if let resolver = snap.dnsResolver {
                StatusDot(color: leak != nil ? leakColor : (snap.countries[resolver] == nil ? .gray : Palette.running))
                rowLabel("DNS")
                if let code = snap.countries[resolver] {
                    Text(CountryInfo.label(code)).lineLimit(1)
                }
                Text(resolver.description)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                if leak != nil {
                    Badge(text: "утечка", color: leakColor, symbol: "drop.fill")
                } else {
                    Badge(text: "ок", color: Palette.running)
                }
            } else {
                StatusDot(color: .gray)
                rowLabel("DNS")
                Text("резолвер не определён").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .font(.callout)
        .help("Через какой резолвер уходят DNS-запросы. Если он в другой стране, чем VPN, — сайты видят ваш DNS-провайдер.")
    }

    private func rowLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 34, alignment: .leading)
    }
}

// MARK: - Apps

private struct AppsCard: View {
    let engine: GuardEngine

    var body: some View {
        let apps = engine.controlledApps
        Card {
            HStack {
                SectionTitle(text: "Программы")
                Spacer()
                OtherAppsMenu(engine: engine, excluded: Set(apps.map(\.kind)))
            }
            if apps.isEmpty {
                Text("Пусто. Добавьте программы в настройках или заморозьте любую запущенную через «+».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if apps.count > 5 {
                ScrollView {
                    rows(apps)
                }
                .frame(maxHeight: 230)
            } else {
                rows(apps)
            }
        }
    }

    private func rows(_ apps: [ControlledApp]) -> some View {
        VStack(spacing: 8) {
            ForEach(apps) { app in
                HStack(spacing: 8) {
                    AppIcon(kind: app.kind, size: 26)
                        .saturation(app.state == .frozen ? 0.2 : 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.name).font(.callout.weight(.medium)).lineLimit(1)
                        AppStateBadge(app: app)
                    }
                    Spacer(minLength: 4)
                    AppControls(app: app, engine: engine)
                }
            }
        }
    }
}

/// "+" menu: freeze any running app by hand.
private struct OtherAppsMenu: View {
    let engine: GuardEngine
    let excluded: Set<AppRuleKind>

    var body: some View {
        Menu {
            let candidates = AppCatalog.runningCandidates(excluding: excluded)
            if candidates.isEmpty {
                Text("Нет других запущенных программ")
            }
            ForEach(candidates, id: \.kind) { candidate in
                Button {
                    engine.freezeManually(kind: candidate.kind, name: candidate.name)
                } label: {
                    if let icon = candidate.icon {
                        Image(nsImage: icon)
                    }
                    Text(candidate.name)
                }
            }
        } label: {
            Label("Заморозить", systemImage: "plus")
                .font(.caption.weight(.semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Заморозить любую запущенную программу вручную")
    }
}

// MARK: - Footer

private struct FooterBar: View {
    let engine: GuardEngine
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if case .paused = engine.phase {
                // Resume lives in the paused card.
                EmptyView()
            } else {
                Menu {
                    Button("На 15 минут") { engine.pause(for: 15 * 60) }
                    Button("На 1 час") { engine.pause(for: 60 * 60) }
                    Divider()
                    Button("Без срока") { engine.pause(for: nil) }
                } label: {
                    Label("Пауза", systemImage: "pause.fill")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .tint(Palette.warning)
            }
            Spacer()
            IconButton(symbol: "gearshape.fill", color: .gray, help: "Настройки", action: openSettings)
            IconButton(symbol: "power", color: Palette.danger, help: "Выйти (программы разморозятся)") {
                NSApp.terminate(nil)
            }
        }
        .padding(.horizontal, 2)
    }
}
