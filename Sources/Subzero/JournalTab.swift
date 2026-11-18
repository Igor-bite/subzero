import AppKit
import SubzeroCore
import SubzeroEngine
import SwiftUI
import UniformTypeIdentifiers

/// History: statuses, IP changes, freezes and kills, newest first, grouped by day.
struct JournalTab: View {
    @Bindable var engine: GuardEngine
    @State private var filter: JournalFilter = .all
    @State private var search = ""
    @State private var confirmingClear = false

    /// Rows shown at most; older ones stay in the file and in the stats.
    private static let rowLimit = 1500
    private static let retentionDays = [7, 30, 90, 365]

    private struct Day: Identifiable {
        let id: Date
        var entries: [JournalEntry]
    }

    private var matching: [JournalEntry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        var result: [JournalEntry] = []
        for entry in engine.journal.entries.reversed() where filter.accepts(entry.event) {
            if !query.isEmpty {
                let text = entry.event.title + " " + (entry.event.detail ?? "")
                guard text.localizedCaseInsensitiveContains(query) else { continue }
            }
            result.append(entry)
            if result.count == Self.rowLimit { break }
        }
        return result
    }

    private func days(_ entries: [JournalEntry]) -> [Day] {
        let calendar = Calendar.current
        var days: [Day] = []
        for entry in entries {
            let day = calendar.startOfDay(for: entry.at)
            if days.last?.id == day {
                days[days.count - 1].entries.append(entry)
            } else {
                days.append(Day(id: day, entries: [entry]))
            }
        }
        return days
    }

    var body: some View {
        let entries = matching
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Показывать", selection: $filter) {
                    ForEach(JournalFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                TextField("Поиск", text: $search, prompt: Text("Поиск: программа, IP, страна"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 8)

            if entries.isEmpty {
                ContentUnavailableView {
                    Label(engine.journal.entries.isEmpty ? "Журнал пуст" : "Ничего не найдено", systemImage: "list.bullet.rectangle")
                } description: {
                    Text(engine.journal.entries.isEmpty
                         ? "Здесь появятся смены IP, блокировки, заморозки и K.O."
                         : "Попробуйте другой фильтр или запрос.")
                }
                .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(days(entries)) { day in
                        Section {
                            ForEach(day.entries) { JournalRow(entry: $0) }
                        } header: {
                            Text(Self.dayTitle(day.id))
                        }
                    }
                    if entries.count == Self.rowLimit {
                        Text("Показаны последние \(Self.rowLimit) записей. Полная история — в экспорте.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
            }

            Divider()
            HStack(spacing: 10) {
                Picker("Хранить", selection: $engine.config.journalDays) {
                    ForEach(Self.retentionDays, id: \.self) { Text(Self.daysText($0)).tag($0) }
                }
                .fixedSize()
                if let error = engine.journal.lastError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.warning)
                        .help("Журнал не записался: \(error)")
                }
                Spacer()
                Button { export() } label: { Label("Экспорт CSV…", systemImage: "square.and.arrow.up") }
                    .disabled(engine.journal.entries.isEmpty)
                Button(role: .destructive) { confirmingClear = true } label: { Label("Очистить…", systemImage: "trash") }
                    .disabled(engine.journal.entries.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .confirmationDialog("Очистить журнал?", isPresented: $confirmingClear) {
            Button("Очистить", role: .destructive) { engine.journal.clear() }
        } message: {
            Text("Удалятся вся история и статистика. Отменить нельзя.")
        }
    }

    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Сегодня" }
        if calendar.isDateInYesterday(day) { return "Вчера" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(Locale(identifier: "ru_RU")))
    }

    static func daysText(_ days: Int) -> String {
        switch days {
        case 7: "7 дней"
        case 30: "30 дней"
        case 90: "90 дней"
        case 365: "1 год"
        default: "\(days) дн."
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "subzero-journal.csv"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Self.csv(engine.journal.entries).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Semicolon-separated (opens as columns in Numbers and Excel with a Russian locale).
    static func csv(_ entries: [JournalEntry]) -> String {
        func cell(_ text: String) -> String { "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        let format = ISO8601DateFormatter()
        format.timeZone = .current
        var lines = ["время;событие;подробности"]
        for entry in entries {
            lines.append([format.string(from: entry.at), cell(entry.event.title), cell(entry.event.detail ?? "")].joined(separator: ";"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

private struct JournalRow: View {
    let entry: JournalEntry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(entry.at.formatted(date: .omitted, time: .standard))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Image(systemName: entry.event.symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(entry.event.color)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.event.title)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if let detail = entry.event.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
