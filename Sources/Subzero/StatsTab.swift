import Charts
import SubzeroCore
import SubzeroEngine
import SwiftUI

enum StatsPeriod: String, CaseIterable, Identifiable {
    case day, week, month

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: "24 часа"
        case .week: "7 дней"
        case .month: "30 дней"
        }
    }

    var bucketUnit: Calendar.Component { self == .day ? .hour : .day }

    /// From the start of the first hour/day to the end of the current one.
    func interval(now: Date, calendar: Calendar = .current) -> DateInterval {
        switch self {
        case .day:
            let hour = calendar.dateInterval(of: .hour, for: now) ?? DateInterval(start: now, duration: 3600)
            return DateInterval(start: hour.end.addingTimeInterval(-24 * 3600), end: hour.end)
        case .week, .month:
            let days = self == .week ? 7 : 30
            let today = calendar.dateInterval(of: .day, for: now) ?? DateInterval(start: now, duration: 86_400)
            let start = calendar.date(byAdding: .day, value: -(days - 1), to: today.start) ?? today.start
            return DateInterval(start: start, end: today.end)
        }
    }
}

/// How a duration axis is labeled: minutes for short totals, hours otherwise.
private struct DurationScale {
    let divisor: Double
    let unit: String

    init(max seconds: TimeInterval) {
        if seconds <= 2 * 3600 {
            divisor = 60
            unit = "мин"
        } else {
            divisor = 3600
            unit = "ч"
        }
    }
}

/// Numbers and charts over the journal for the chosen period.
struct StatsTab: View {
    let engine: GuardEngine
    @State private var period: StatsPeriod
    /// Pinned "now" for snapshots; live views follow the clock.
    var fixedNow: Date?

    init(engine: GuardEngine, fixedNow: Date? = nil, period: StatsPeriod = .week) {
        self.engine = engine
        self.fixedNow = fixedNow
        _period = State(initialValue: period)
    }

    var body: some View {
        if let fixedNow {
            content(now: fixedNow)
        } else {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                content(now: context.date)
            }
        }
    }

    private func content(now: Date) -> some View {
        let interval = period.interval(now: now)
        let stats = JournalStats(entries: engine.journal.entries, interval: interval, now: now, bucketUnit: period.bucketUnit)
        return Form {
            Section {
                Picker("Период", selection: $period) {
                    ForEach(StatsPeriod.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                KPIRow(stats: stats)
            }

            if stats.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label("Пока нет данных", systemImage: "chart.bar.xaxis")
                    } description: {
                        Text("Статистика копится, пока Subzero работает. Загляните позже.")
                    }
                }
            } else {
                Section {
                    StatusTimeline(stats: stats, period: period)
                } header: {
                    header("Хронология", "timeline.selection", Arcade.iceDeep)
                } footer: {
                    note("Сон Mac и время, когда Subzero не работал, остаются пустыми.")
                }

                Section {
                    StatusBuckets(stats: stats, period: period)
                } header: {
                    header(period == .day ? "Состояние по часам" : "Состояние по дням", "chart.bar.fill", .indigo)
                }

                if !stats.reasons.isEmpty {
                    Section {
                        ReasonsChart(stats: stats)
                    } header: {
                        header("Причины блокировок", "xmark.shield.fill", Palette.danger)
                    } footer: {
                        note("Длина полосы — сколько длились блокировки, число — сколько раз начинались.")
                    }
                }

                if !stats.countries.isEmpty {
                    Section {
                        CountriesChart(stats: stats, allowed: Set(engine.config.allowedCountries))
                    } header: {
                        header("Страны внешнего IP", "globe.europe.africa.fill", .blue)
                    } footer: {
                        note("Смен IP за период: \(stats.ipChanges). Предупреждений об утечке DNS: \(stats.dnsWarnings).")
                    }
                }

                if !stats.targets.isEmpty {
                    Section {
                        TargetsChart(stats: stats)
                    } header: {
                        header("Программы и сайты", "snowflake", Palette.frozen)
                    } footer: {
                        note("Сколько каждая программа простояла замороженной, сколько раз замерзала и сколько раз её закрыли (K.O.).")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func header(_ title: String, _ symbol: String, _ color: Color) -> some View {
        Label { Text(title) } icon: { IconTile(symbol: symbol, color: color) }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }
}

// MARK: - Headline numbers

private struct KPIRow: View {
    let stats: JournalStats

    var body: some View {
        HStack(spacing: 8) {
            tile(
                "Под защитой",
                stats.protectedShare.map { Self.percent($0) } ?? "—",
                stats.watched > 0 ? "из \(Durations.short(stats.watched)) работы" : "нет данных",
                symbol: "checkmark.shield.fill", color: Arcade.life
            )
            tile(
                "Блокировок", "\(stats.blocks)",
                "всего \(Durations.short(stats.seconds[.blocked] ?? 0))",
                symbol: "xmark.shield.fill", color: Arcade.blood
            )
            tile(
                "Дольше всего", stats.blocks > 0 ? Durations.short(stats.longestBlock) : "—",
                "одна блокировка",
                symbol: "timer", color: Arcade.caution
            )
            tile(
                "K.O.", "\(stats.kills)",
                "закрыто программ",
                symbol: "xmark.octagon.fill", color: Palette.danger
            )
        }
        .padding(.vertical, 2)
    }

    static func percent(_ share: Double) -> String {
        let value = share * 100
        // 99.96% is not 100%.
        if value >= 99.95, value < 100 { return "99,9%" }
        return value.formatted(.number.precision(.fractionLength(value < 10 || value >= 99 ? 1 : 0)).locale(Locale(identifier: "ru_RU"))) + "%"
    }

    private func tile(_ title: String, _ value: String, _ sub: String, symbol: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 9, weight: .black)).foregroundStyle(color)
                Text(title.uppercased()).font(Arcade.font(9, weight: .black)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(Arcade.font(20, weight: .black))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Chamfer(cut: 5).fill(.white.opacity(0.04)))
        .overlay(Chamfer(cut: 5).strokeBorder(color.opacity(0.35), lineWidth: 1))
    }
}

// MARK: - Status charts

private extension View {
    /// Fixed legend colors for statuses.
    func statusColors() -> some View {
        chartForegroundStyleScale(
            domain: JournalStatus.charted.map(\.title),
            range: JournalStatus.charted.map(\.color)
        )
    }
}

/// One horizontal strip per period: what protection was doing, when.
private struct StatusTimeline: View {
    let stats: JournalStats
    let period: StatsPeriod
    @State private var hovered: Date?

    private var spans: [StatusSpan] { stats.spans.filter { $0.status != .asleep } }

    private var hoveredSpan: StatusSpan? {
        guard let hovered else { return nil }
        return spans.first { $0.start <= hovered && hovered < $0.end }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(Array(spans.enumerated()), id: \.offset) { _, span in
                    RectangleMark(
                        xStart: .value("Начало", span.start),
                        xEnd: .value("Конец", span.end),
                        y: .value("Ряд", "статус"),
                        height: .fixed(26)
                    )
                    .foregroundStyle(by: .value("Статус", span.status.title))
                }
                if let hovered {
                    RuleMark(x: .value("Курсор", hovered))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .statusColors()
            .chartXScale(domain: stats.interval.start...stats.interval.end)
            .chartYAxis(.hidden)
            .chartXAxis { timeAxis(period) }
            .chartLegend(position: .bottom, alignment: .leading)
            .chartXSelection(value: $hovered)
            .frame(height: 86)

            Group {
                if let span = hoveredSpan {
                    Text(Self.describe(span, period: period))
                } else {
                    Text("Наведите курсор на полосу, чтобы увидеть подробности.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
    }

    static func describe(_ span: StatusSpan, period: StatsPeriod) -> String {
        let style: Date.FormatStyle = period == .day
            ? .dateTime.hour().minute()
            : .dateTime.day().month(.abbreviated).hour().minute()
        let range = "\(span.start.formatted(style.locale(Locale(identifier: "ru_RU")))) – \(span.end.formatted(style.locale(Locale(identifier: "ru_RU"))))"
        var text = "\(range) · \(span.status.title) · \(Durations.short(span.duration))"
        if let block = span.block { text += " · \(block.text)" }
        return text
    }
}

/// Stacked bars per hour or day: time with each status.
private struct StatusBuckets: View {
    let stats: JournalStats
    let period: StatsPeriod
    @State private var hovered: Date?

    private var calendar: Calendar { .current }

    private var hoveredBucket: (start: Date, items: [JournalStats.Bucket])? {
        guard let hovered, let bucket = calendar.dateInterval(of: period.bucketUnit, for: hovered) else { return nil }
        let items = stats.buckets.filter { $0.start == bucket.start }
        return items.isEmpty ? nil : (bucket.start, items)
    }

    var body: some View {
        let unitSeconds: TimeInterval = period == .day ? 3600 : 86_400
        let scale = period == .day ? DurationScale(max: 0) : DurationScale(max: unitSeconds)
        VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(Array(stats.buckets.enumerated()), id: \.offset) { _, bucket in
                    BarMark(
                        x: .value("Время", bucket.start, unit: period.bucketUnit),
                        y: .value("Длительность", bucket.seconds / scale.divisor)
                    )
                    .foregroundStyle(by: .value("Статус", bucket.status.title))
                    .opacity(hovered == nil || hoveredBucket?.start == bucket.start ? 1 : 0.45)
                }
            }
            .statusColors()
            .chartXScale(domain: stats.interval.start...stats.interval.end)
            .chartXAxis { timeAxis(period) }
            .chartYScale(domain: 0...(unitSeconds / scale.divisor))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.white.opacity(0.12))
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text("\(Int(number)) \(scale.unit)") }
                    }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .chartXSelection(value: $hovered)
            .frame(height: 170)

            Group {
                if let bucket = hoveredBucket {
                    let style: Date.FormatStyle = period == .day ? .dateTime.hour().minute() : .dateTime.weekday(.abbreviated).day().month(.abbreviated)
                    let parts = bucket.items.map { "\($0.status.title) \(Durations.short($0.seconds))" }
                    Text("\(bucket.start.formatted(style.locale(Locale(identifier: "ru_RU")))): \(parts.joined(separator: " · "))")
                } else {
                    Text("Наведите курсор на столбец, чтобы увидеть разбивку.")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

@AxisContentBuilder
private func timeAxis(_ period: StatsPeriod) -> some AxisContent {
    switch period {
    case .day:
        AxisMarks(values: .stride(by: .hour, count: 3)) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.white.opacity(0.12))
            AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)))
        }
    case .week:
        AxisMarks(values: .stride(by: .day)) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.white.opacity(0.12))
            AxisValueLabel(format: .dateTime.weekday(.abbreviated).locale(Locale(identifier: "ru_RU")), centered: true)
        }
    case .month:
        AxisMarks(values: .stride(by: .day, count: 5)) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.white.opacity(0.12))
            AxisValueLabel(format: .dateTime.day().month(.abbreviated).locale(Locale(identifier: "ru_RU")))
        }
    }
}

// MARK: - Breakdown charts

/// Horizontal bars of durations with a text label on each row.
private struct DurationBars: View {
    struct Row: Identifiable {
        let id: String
        let label: String
        let seconds: TimeInterval
        let note: String
        var group: String?
    }

    let rows: [Row]
    var color: Color = Arcade.ice
    /// Legend for `Row.group`: names and colors. Without it bars use `color`.
    var groups: [(String, Color)] = []

    var body: some View {
        let scale = DurationScale(max: rows.map(\.seconds).max() ?? 0)
        let longest = (rows.map(\.seconds).max() ?? 0) / scale.divisor
        Chart(rows) { row in
            BarMark(
                x: .value("Длительность", row.seconds / scale.divisor),
                y: .value("Что", row.label),
                height: .fixed(14)
            )
            .foregroundStyle(by: .value("Группа", row.group ?? ""))
            .cornerRadius(2)
            .annotation(position: .trailing, alignment: .leading, spacing: 6) {
                Text(row.note)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .chartForegroundStyleScale(
            domain: groups.isEmpty ? [""] : groups.map(\.0),
            range: groups.isEmpty ? [color] : groups.map(\.1)
        )
        .chartLegend(groups.isEmpty ? .hidden : .visible)
        .chartLegend(position: .bottom, alignment: .leading)
        // Room on the right for the labels.
        .chartXScale(domain: 0...max(longest * 1.45, 1))
        .chartXAxis {
            // Ticks only under the bars: the right side holds the labels.
            AxisMarks(values: Self.ticks(upTo: longest)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(.white.opacity(0.12))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text("\(number.formatted(.number.precision(.fractionLength(0...1)).locale(Locale(identifier: "ru_RU")))) \(scale.unit)")
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks { _ in AxisValueLabel().font(.callout) }
        }
        .frame(height: CGFloat(rows.count) * 28 + (groups.isEmpty ? 30 : 52))
    }
}

extension DurationBars {
    /// 0 and a few round steps up to `longest`.
    static func ticks(upTo longest: Double) -> [Double] {
        guard longest > 0 else { return [0] }
        let raw = longest / 3
        let magnitude = pow(10, floor(log10(raw)))
        let step = [1, 2, 2.5, 5, 10].map { $0 * magnitude }.first { $0 >= raw } ?? raw
        return stride(from: 0, through: longest * 1.05, by: step).map { $0 }
    }
}

private struct ReasonsChart: View {
    let stats: JournalStats

    var body: some View {
        DurationBars(
            rows: stats.reasons.map { reason in
                .init(id: reason.kind.rawValue, label: reason.kind.title, seconds: reason.seconds,
                      note: reason.count > 0 ? "\(reason.count)× · \(Durations.short(reason.seconds))" : Durations.short(reason.seconds))
            },
            color: Arcade.blood
        )
    }
}

private struct CountriesChart: View {
    let stats: JournalStats
    let allowed: Set<String>

    private static let groups: [(String, Color)] = [
        ("Разрешена", Arcade.life),
        ("Не разрешена", Arcade.blood),
        ("Не определена", Arcade.steelLight),
    ]

    var body: some View {
        DurationBars(
            rows: stats.countries.prefix(8).map { country in
                let label = country.code.map { CountryInfo.label($0) } ?? "Не определена"
                let group = country.code.map { allowed.contains($0) ? "Разрешена" : "Не разрешена" } ?? "Не определена"
                return .init(id: country.code ?? "?", label: label, seconds: country.seconds,
                             note: Durations.short(country.seconds), group: group)
            },
            groups: Self.groups.filter { group in
                stats.countries.prefix(8).contains { country in
                    (country.code.map { allowed.contains($0) ? "Разрешена" : "Не разрешена" } ?? "Не определена") == group.0
                }
            }
        )
    }
}

private struct TargetsChart: View {
    let stats: JournalStats

    var body: some View {
        DurationBars(
            rows: stats.targets.prefix(10).map { target in
                var note = "❄︎ \(target.freezes) · \(Durations.short(target.frozenSeconds))"
                if target.kills > 0 { note += " · K.O. \(target.kills)" }
                return .init(id: target.name, label: target.name, seconds: target.frozenSeconds, note: note)
            },
            color: Palette.frozen
        )
    }
}
