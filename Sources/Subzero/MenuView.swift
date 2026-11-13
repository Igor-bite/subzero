import AppKit
import SubzeroCore
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
        .background(LinearGradient(colors: [Arcade.night, Color(red: 0.06, green: 0.08, blue: 0.15)], startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .dark)
        .tint(Arcade.ice)
    }

    private func openSettings() {
        openWindow(id: SettingsView.windowID)
        NSApp.activate()
    }
}

// MARK: - Header: the arena

private struct HeaderCard: View {
    let engine: GuardEngine

    var body: some View {
        let phase = engine.phase
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 8) {
                HealthBar(label: ipLabel, value: ipHealth(phase), color: phase.tint)
                RoundTimer(text: timerText(phase), urgent: engine.killDeadline != nil || engine.killsImmediately)
                HealthBar(label: dnsLabel, value: dnsHealth.value, color: dnsHealth.color, mirrored: true)
            }
            HStack(alignment: .bottom, spacing: 6) {
                TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                    let pose = throwing(at: timeline.date) ? .cast : pose(phase)
                    SpriteView(sprite: Frost.sprite(pose), scale: 3, bob: pose == .stance, dim: isPaused(phase))
                }
                VStack(alignment: .leading, spacing: 2) {
                    PixelText(text: banner(phase), scale: 4, colors: bannerColors(phase))
                    Text(subtitle(phase))
                        .font(Arcade.font(10, weight: .bold))
                        .foregroundStyle(Arcade.frost.opacity(0.9))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .shadow(color: .black, radius: 0, x: 1, y: 1)
                        .padding(.leading, 4)
                    Spacer(minLength: 0)
                }
                .padding(.top, 14)
                Spacer(minLength: 0)
                refreshButton
                    .padding(.bottom, 26)
                    .opacity(hitActive ? 0 : 1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 9)
        .overlay {
            if let hit = engine.lastHit, engine.now.timeIntervalSince(hit.at) < IceBall.total + 1 {
                // Hand of the cast pose: sprite pixel (22, 16) at scale 3, below the HUD row.
                ArenaThrow(hit: hit, hand: CGPoint(x: 10 + 22 * 3, y: 9 + 34 + 4 + 18 * 3))
            }
        }
        .background(ArenaBackdrop(tint: phase.tint).clipShape(Chamfer(cut: 9)))
        .overlay {
            Chamfer(cut: 9).strokeBorder(Arcade.night, lineWidth: 3)
            Chamfer(cut: 9).inset(by: 1).strokeBorder(Arcade.gold.opacity(0.85), lineWidth: 1.5)
        }
        .animation(.easeInOut(duration: 0.25), value: phase)
    }

    private var refreshButton: some View {
        Button {
            engine.requestCheck()
        } label: {
            Group {
                if engine.isChecking {
                    ProgressView().controlSize(.mini).tint(Arcade.frost)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .black))
                }
            }
            .foregroundStyle(Arcade.frost)
            .frame(width: 26, height: 26)
            .background(BevelPlate(color: Arcade.ice, cut: 4))
        }
        .buttonStyle(.plain)
        .help("Проверить сейчас")
        .disabled(engine.isChecking)
    }

    // MARK: Fighter

    private func pose(_ phase: GuardEngine.Phase) -> Frost.Pose {
        switch phase {
        case .blocked: .cast
        case .paused: .rest
        case .checking, .protected: .stance
        }
    }

    /// An ice ball or its impact is on screen (the target sits where the refresh button is).
    private var hitActive: Bool {
        guard let hit = engine.lastHit else { return false }
        return engine.now.timeIntervalSince(hit.at) < IceBall.total
    }

    /// The golem holds the throwing pose while the ball is in the air and a moment after.
    private func throwing(at date: Date) -> Bool {
        guard let hit = engine.lastHit else { return false }
        let t = date.timeIntervalSince(hit.at)
        return t >= -0.05 && t < IceBall.flight + 0.35
    }

    private func isPaused(_ phase: GuardEngine.Phase) -> Bool {
        if case .paused = phase { return true }
        return false
    }

    private func banner(_ phase: GuardEngine.Phase) -> String {
        switch phase {
        case .checking: "SCAN"
        case .protected: engine.enabledRules.isEmpty ? "READY" : "FIGHT!"
        case .blocked:
            engine.killsImmediately ? "K.O." : (engine.frozenRuleIDs.isEmpty ? "BLOCK" : "FROZEN!")
        case .paused: "PAUSE"
        }
    }

    private func bannerColors(_ phase: GuardEngine.Phase) -> [Color] {
        switch phase {
        case .checking: [Arcade.frost, Arcade.ice, Arcade.iceDeep]
        case .protected: [Color(red: 1, green: 0.97, blue: 0.75), Arcade.gold, Arcade.ember]
        case .blocked:
            engine.killsImmediately || engine.frozenRuleIDs.isEmpty
                ? [Color(red: 1, green: 0.85, blue: 0.6), Arcade.ember, Arcade.blood]
                : [Arcade.frost, Arcade.ice, Arcade.iceDeep]
        case .paused: [Color(red: 1, green: 0.95, blue: 0.8), Arcade.caution, Arcade.ember]
        }
    }

    // MARK: HUD

    private var ipLabel: String {
        engine.currentCountry.map { "IP \($0)" } ?? "IP"
    }

    private func ipHealth(_ phase: GuardEngine.Phase) -> Double {
        switch phase {
        case .protected: return 1
        case .checking: return 0.6
        case .paused: return 0.5
        case .blocked:
            guard let deadline = engine.killDeadline else { return engine.killsImmediately ? 0 : 0.08 }
            return max(0.02, deadline.timeIntervalSince(engine.now) / max(1, engine.config.grace))
        }
    }

    private var dnsLabel: String {
        guard engine.config.policySettings.needsDNS else { return "DNS OFF" }
        guard let snap = engine.snapshot, let resolver = snap.dnsResolver, let code = snap.countries[resolver] else { return "DNS" }
        return "DNS \(code)"
    }

    private var dnsHealth: (value: Double, color: Color) {
        guard engine.config.policySettings.needsDNS else { return (0, Arcade.steel) }
        guard engine.snapshot?.dnsResolver != nil else { return (0.3, Arcade.steelLight) }
        switch engine.dnsFinding?.action {
        case nil, .off: return (1, Arcade.life)
        case .warn: return (0.5, Arcade.caution)
        case .block: return (0.12, Arcade.blood)
        case .kill: return (0, Arcade.blood)
        }
    }

    private func timerText(_ phase: GuardEngine.Phase) -> String {
        if engine.killsImmediately { return "KO" }
        if case .paused(let until) = phase {
            guard until != .distantFuture else { return "--" }
            return "\(Int(ceil(until.timeIntervalSince(engine.now) / 60)))M"
        }
        if let deadline = engine.killDeadline {
            let left = max(0, Int(deadline.timeIntervalSince(engine.now)))
            return left < 1000 ? "\(left)" : "\(left / 60)M"
        }
        return "99"
    }

    private func subtitle(_ phase: GuardEngine.Phase) -> String {
        switch phase {
        case .checking:
            return "Сверяю адрес с сервисами"
        case .paused(let until):
            return until == .distantFuture
                ? "Без срока — программы не защищены"
                : "До \(until.formatted(date: .omitted, time: .shortened)) — без защиты"
        case .protected, .blocked:
            var parts: [String] = []
            if case .blocked(let reason) = phase {
                if case .dnsLeak = reason {
                    parts.append(engine.killsImmediately ? "Утечка DNS — программы закрыты" : "Утечка DNS")
                } else {
                    parts.append(engine.frozenRuleIDs.isEmpty ? "IP не разрешён" : "Программы заморожены")
                }
            } else {
                parts.append(engine.enabledRules.isEmpty ? "IP в порядке" : "Защищено")
            }
            if let code = engine.currentCountry {
                parts.append(CountryInfo.label(code))
            }
            return parts.joined(separator: " · ")
        }
    }
}

/// Round timer between the health bars.
private struct RoundTimer: View {
    let text: String
    let urgent: Bool

    var body: some View {
        PixelText(text: text, scale: 3, colors: urgent ? [Color.white, Arcade.ember, Arcade.blood] : [Color.white, Arcade.gold, Arcade.ember])
            .frame(minWidth: 44, minHeight: 30)
            .background(Chamfer(cut: 4).fill(Arcade.night.opacity(0.85)))
            .overlay(Chamfer(cut: 4).strokeBorder(Arcade.gold.opacity(0.8), lineWidth: 1))
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
                    SegmentBar(value: left / max(1, engine.config.grace))
                }
            }

            if case .dnsLeak(_, let country) = reason,
               let rule = engine.config.dnsCountryRules.first(where: { $0.country == country }) {
                Label("Правило для \(CountryInfo.label(country)): \(rule.action.title.lowercased()). Изменить можно в настройках.", systemImage: "drop.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let allowable = reason.allowable {
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
                if engine.config.policySettings.needsDNS {
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
        let finding = engine.dnsFinding
        let leak = finding?.leak
        let leakColor = finding?.action.stops == true ? Palette.danger : Palette.warning
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
                if let finding {
                    Badge(text: finding.action == .kill ? "утечка · K.O." : "утечка", color: leakColor, symbol: "drop.fill")
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
