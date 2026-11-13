import AppKit
import FreezerCore
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    static let windowID = "settings"
    @Bindable var engine: GuardEngine

    var body: some View {
        TabView {
            AppsTab(engine: engine)
                .tabItem { Label("Программы", systemImage: "square.stack.3d.up.fill") }
            AllowTab(engine: engine)
                .tabItem { Label("Разрешено", systemImage: "globe.europe.africa.fill") }
            BehaviorTab(engine: engine)
                .tabItem { Label("Поведение", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 600, height: 540)
    }
}

// MARK: - Apps

struct AppsTab: View {
    @Bindable var engine: GuardEngine
    @State private var showingCLISheet = false
    @State private var alert: String?

    private var presets: [AppRule] {
        let existing = Set(engine.config.apps.map(\.kind))
        return (AppCatalog.installedPresets() + AppCatalog.cliPresets).filter { !existing.contains($0.kind) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    if engine.config.apps.isEmpty {
                        Label("Пока ничего. Добавьте программы — при чужом IP они замёрзнут.", systemImage: "sparkles")
                            .foregroundStyle(.secondary)
                    }
                    ForEach($engine.config.apps) { $rule in
                        RuleRow(
                            rule: $rule,
                            app: engine.controlledApps.first { $0.id == rule.id },
                            engine: engine
                        ) {
                            engine.config.apps.removeAll { $0.id == rule.id }
                        }
                    }
                } header: {
                    Label { Text("Защищаемые программы") } icon: { IconTile(symbol: "shield.fill", color: .green) }
                } footer: {
                    Text("Замораживаются все процессы программы, включая помощники и всё, что она запустила. Браузер замерзает целиком, со всеми вкладками. Кнопки ❄︎ / ▶︎ / ✕ работают сразу, независимо от IP.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                let manualOnly = engine.controlledApps.filter { !$0.isProtected }
                if !manualOnly.isEmpty {
                    Section {
                        ForEach(manualOnly) { app in
                            HStack(spacing: 10) {
                                AppIcon(kind: app.kind)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(app.name)
                                    AppStateBadge(app: app)
                                }
                                Spacer()
                                AppControls(app: app, engine: engine)
                            }
                        }
                    } header: {
                        Label { Text("Заморожены вручную") } icon: { IconTile(symbol: "hand.raised.fill", color: .purple) }
                    }
                }

                if !presets.isEmpty {
                    Section {
                        ForEach(presets, id: \.kind) { preset in
                            HStack(spacing: 10) {
                                AppIcon(kind: preset.kind)
                                VStack(alignment: .leading) {
                                    Text(preset.name)
                                    Text(AppCatalog.subtitle(for: preset)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Button("Добавить") { add(preset) }
                                    .buttonStyle(.bordered)
                                    .tint(.green)
                            }
                        }
                    } header: {
                        Label { Text("Быстро добавить") } icon: { IconTile(symbol: "bolt.fill", color: .orange) }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Button { pickApps() } label: { Label("Добавить программу…", systemImage: "plus.app.fill") }
                    .buttonStyle(.borderedProminent)
                Button { showingCLISheet = true } label: { Label("Добавить CLI-команду…", systemImage: "terminal.fill") }
                    .buttonStyle(.bordered)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .sheet(isPresented: $showingCLISheet) {
            CLIRuleSheet { add($0) }
        }
        .alert("Нельзя добавить", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK") { alert = nil }
        } message: {
            Text(alert ?? "")
        }
    }

    private func add(_ rule: AppRule) {
        if let reason = AppCatalog.rejection(for: rule) {
            alert = reason
            return
        }
        guard !engine.config.apps.contains(where: { $0.kind == rule.kind }) else { return }
        engine.config.apps.append(AppRule(name: rule.name, kind: rule.kind))
    }

    private func pickApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Защищать"
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { add(AppCatalog.rule(forAppAt: url)) }
    }
}

private struct RuleRow: View {
    @Binding var rule: AppRule
    let app: ControlledApp?
    let engine: GuardEngine
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $rule.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.green)
                .help(rule.enabled ? "Защищается" : "Защита выключена")
            AppIcon(kind: rule.kind)
                .saturation(rule.enabled ? 1 : 0)
            VStack(alignment: .leading, spacing: 2) {
                Text(rule.name)
                if let app {
                    AppStateBadge(app: app)
                } else {
                    Text(AppCatalog.subtitle(for: rule)).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if let app {
                AppControls(app: app, engine: engine)
            }
            IconButton(symbol: "trash", color: .secondary, help: "Убрать из защиты", action: onDelete)
        }
        .opacity(rule.enabled ? 1 : 0.65)
        .help(AppCatalog.subtitle(for: rule))
    }
}

private struct CLIRuleSheet: View {
    let onAdd: (AppRule) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var patterns = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label { Text("CLI-команда").font(.headline) } icon: { IconTile(symbol: "terminal.fill", color: .gray) }
            TextField("Название", text: $name, prompt: Text("Например, Aider"))
            TextField("Шаблоны через запятую", text: $patterns, prompt: Text("aider, /site-packages/aider/"))
            Text("Шаблон срабатывает, если совпадает с именем исполняемого файла (с учётом регистра) или, если в нём есть «/» или «@», встречается в пути. Для node, python, bun и т. п. проверяются и аргументы — так находятся скрипты.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                Button("Добавить") {
                    let list = patterns.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    let title = name.trimmingCharacters(in: .whitespaces)
                    onAdd(AppRule(name: title.isEmpty ? (list.first ?? "CLI") : title, kind: .patterns(list)))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(patterns.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

// MARK: - Allow lists

struct AllowTab: View {
    @Bindable var engine: GuardEngine
    @State private var newNetwork = ""
    @State private var countryToAdd = ""

    private var currentCountry: String? {
        guard let snap = engine.snapshot, let ip = snap.primaryIP else { return nil }
        return snap.countries[ip]
    }

    private var networkIsValid: Bool { IPNetwork(newNetwork) != nil }

    /// Current external addresses (IPv4, and IPv6 if checked), as agreed by the services.
    private var currentAddresses: [IPAddress] {
        guard let snap = engine.snapshot else { return [] }
        var result = [snap.ipv4.agreedIP]
        if engine.config.checkIPv6 { result.append(snap.ipv6.agreedIP) }
        return result.compactMap { $0 }
    }

    private func isCovered(_ ip: IPAddress) -> Bool {
        engine.config.allowRules.networks.contains { $0.contains(ip) }
    }

    private func coversCurrent(_ entry: String) -> Bool {
        guard let net = IPNetwork(entry) else { return false }
        return currentAddresses.contains { net.contains($0) }
    }

    var body: some View {
        Form {
            Section {
                if engine.config.allowedCountries.isEmpty {
                    Label("Ни одной страны — любой IP считается чужим.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                ForEach(engine.config.allowedCountries, id: \.self) { code in
                    HStack(spacing: 10) {
                        Text(CountryInfo.flag(code)).font(.title2)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(CountryInfo.name(code))
                            Text(code).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        if code == currentCountry {
                            Badge(text: "вы здесь", color: .green, symbol: "location.fill")
                        }
                        Spacer()
                        IconButton(symbol: "minus", color: Palette.danger, help: "Убрать") {
                            engine.config.allowedCountries.removeAll { $0 == code }
                        }
                    }
                }
                Picker("Добавить страну", selection: $countryToAdd) {
                    Text("Выберите…").tag("")
                    ForEach(CountryInfo.allCodes().filter { !engine.config.allowedCountries.contains($0) }, id: \.self) { code in
                        Text(CountryInfo.label(code)).tag(code)
                    }
                }
                .onChange(of: countryToAdd) { _, code in
                    guard !code.isEmpty else { return }
                    engine.allowCountry(code)
                    countryToAdd = ""
                }
                if let code = currentCountry, !engine.config.allowedCountries.contains(code) {
                    Button {
                        engine.allowCountry(code)
                    } label: {
                        Label("Разрешить текущую: \(CountryInfo.label(code))", systemImage: "location.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
            } header: {
                Label { Text("Разрешённые страны") } icon: { IconTile(symbol: "globe.europe.africa.fill", color: .blue) }
            } footer: {
                Text("Программы работают, только если внешний IP из этих стран.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(engine.config.allowedNetworks, id: \.self) { net in
                    HStack {
                        Image(systemName: "number").foregroundStyle(.teal)
                        Text(net).font(.body.monospaced())
                        if coversCurrent(net) {
                            Badge(text: "вы здесь", color: .green, symbol: "location.fill")
                        }
                        Spacer()
                        IconButton(symbol: "minus", color: Palette.danger, help: "Убрать") {
                            engine.config.allowedNetworks.removeAll { $0 == net }
                        }
                    }
                }
                HStack {
                    TextField("IP или подсеть", text: $newNetwork, prompt: Text("185.10.10.10 или 10.0.0.0/8"))
                        .onSubmit(addNetwork)
                    if !newNetwork.isEmpty {
                        Image(systemName: networkIsValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(networkIsValid ? .green : .red)
                    }
                    Button("Добавить", action: addNetwork)
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)
                        .disabled(!networkIsValid)
                }
                if currentAddresses.isEmpty {
                    HStack {
                        Image(systemName: "location.slash").foregroundStyle(.secondary)
                        Text("Текущий IP ещё не определён").foregroundStyle(.secondary)
                        Spacer()
                        Button("Добавить текущий") {}
                            .disabled(true)
                    }
                }
                ForEach(currentAddresses.filter { !isCovered($0) }, id: \.self) { ip in
                    HStack(spacing: 8) {
                        Image(systemName: "location.fill").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Текущий \(ip.isV4 ? "IPv4" : "IPv6")").font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Text(ip.description).font(.body.monospaced()).textSelection(.enabled)
                                    .lineLimit(1).truncationMode(.middle)
                                if let code = engine.snapshot?.countries[ip] {
                                    Text(CountryInfo.label(code)).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        Spacer()
                        Button {
                            engine.allowIP(ip)
                        } label: {
                            Label("Добавить текущий", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    }
                }
            } header: {
                Label { Text("Разрешённые IP и подсети") } icon: { IconTile(symbol: "network", color: .teal) }
            } footer: {
                Text("Эти адреса разрешены всегда, независимо от страны — например, IP вашего VPN-сервера.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func addNetwork() {
        guard let net = IPNetwork(newNetwork) else { return }
        let text = net.description
        if !engine.config.allowedNetworks.contains(text) {
            engine.config.allowedNetworks.append(text)
        }
        newNetwork = ""
    }
}

// MARK: - Behavior

struct BehaviorTab: View {
    @Bindable var engine: GuardEngine
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @AppStorage(DockPolicy.key) private var showInDock = true

    private static let intervals: [TimeInterval] = [10, 15, 30, 60, 120]
    private static let graces: [TimeInterval] = [60, 120, 300, 600, 900, 1800, 3600]

    var body: some View {
        Form {
            Section {
                Picker(selection: $engine.config.checkInterval) {
                    ForEach(Self.intervals, id: \.self) { Text(duration($0)).tag($0) }
                } label: {
                    row("Проверять IP каждые", "clock.fill", .blue)
                }
                LabeledContent {
                    HStack(spacing: 6) {
                        Text("\(engine.config.minAgree) из \(IPProbe.ipv4Services.count)").monospacedDigit()
                        Stepper("", value: $engine.config.minAgree, in: 1...4).labelsHidden()
                    }
                } label: {
                    row("Сколько сервисов должны назвать один IP", "person.3.fill", .indigo)
                }
                Toggle(isOn: $engine.config.checkIPv6) {
                    row("Проверять утечку IPv6", "6.circle.fill", .purple)
                }
                Picker(selection: $engine.config.dnsCheck) {
                    Text("Выключена").tag(DNSCheckMode.off)
                    Text("Предупреждать").tag(DNSCheckMode.warn)
                    Text("Замораживать").tag(DNSCheckMode.block)
                } label: {
                    row("Утечка DNS", "drop.fill", .cyan)
                }
            } header: {
                Text("Проверка")
            } footer: {
                Text("Утечка DNS — когда трафик идёт через VPN, а DNS-запросы через резолвер в другой стране (обычно провайдера). Резолвер определяется через whoami.akamai.net.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $engine.config.freezeOnNetworkChange) {
                    row("Замораживать при смене сети", "wifi", .blue)
                }
                Toggle(isOn: $engine.config.blockWhenOffline) {
                    row("Замораживать, когда нет интернета", "wifi.slash", .gray)
                }
                Toggle(isOn: $engine.config.killAfterGrace) {
                    row("Закрывать, если разрешённый IP не вернулся", "xmark.octagon.fill", .red)
                }
                Picker(selection: $engine.config.grace) {
                    ForEach(Self.graces, id: \.self) { Text(duration($0)).tag($0) }
                } label: {
                    row("Ждать перед закрытием", "timer", .orange)
                }
                .disabled(!engine.config.killAfterGrace)
            } header: {
                Text("Заморозка")
            } footer: {
                Text("Замороженная программа стоит и ничего не отправляет, но сохраняет состояние. Закрытие принудительное (SIGKILL): мягкое закрытие потребовало бы разморозить программу при чужом IP.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Вид") {
                Picker(selection: $engine.config.menuBarText) {
                    Text("Только значок").tag(MenuBarText.icon)
                    Text("Флаг и страна").tag(MenuBarText.country)
                    Text("IP-адрес").tag(MenuBarText.ip)
                } label: {
                    row("Рядом со значком в строке меню", "menubar.rectangle", .indigo)
                }
                Toggle(isOn: $showInDock) {
                    row("Показывать в Dock", "dock.rectangle", .blue)
                }
                .onChange(of: showInDock) { _, on in DockPolicy.apply(on) }
            }

            Section("Прочее") {
                Toggle(isOn: $engine.config.notifications) {
                    row("Уведомления", "bell.badge.fill", .red)
                }
                Toggle(isOn: $launchAtLogin) {
                    row("Запускать при входе в систему", "power", .green)
                }
                .onChange(of: launchAtLogin) { _, on in setLaunchAtLogin(on) }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.red)
                }
                LabeledContent {
                    Button("Показать в Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.defaultURL])
                    }
                } label: {
                    row("Файл настроек", "doc.text.fill", .gray)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ title: String, _ symbol: String, _ color: Color) -> some View {
        Label { Text(title) } icon: { IconTile(symbol: symbol, color: color) }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds)) с" : "\(Int(seconds / 60)) мин"
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginError = nil
        } catch {
            loginError = "Не получилось: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
