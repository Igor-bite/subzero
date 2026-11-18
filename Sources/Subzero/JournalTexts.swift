import SubzeroCore
import SwiftUI

// User-facing text and colors for journal values.

enum Durations {
    /// "45 с", "12 мин", "3 ч 20 мин", "2 д 4 ч".
    static func short(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded())) с" }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) мин" }
        let hours = minutes / 60, restMinutes = minutes % 60
        if hours < 24 { return restMinutes == 0 ? "\(hours) ч" : "\(hours) ч \(restMinutes) мин" }
        let days = hours / 24, restHours = hours % 24
        return restHours == 0 ? "\(days) д" : "\(days) д \(restHours) ч"
    }
}

extension JournalStatus {
    var title: String {
        switch self {
        case .checking: "Проверка"
        case .protected: "Защищено"
        case .blocked: "Блокировка"
        case .paused: "Пауза"
        case .asleep: "Сон"
        }
    }

    var color: Color {
        switch self {
        case .checking: Arcade.ice
        case .protected: Arcade.life
        case .blocked: Arcade.blood
        case .paused: Arcade.caution
        case .asleep: Arcade.steelLight
        }
    }

    var symbol: String {
        switch self {
        case .checking: "shield.lefthalf.filled"
        case .protected: "checkmark.shield.fill"
        case .blocked: "xmark.shield.fill"
        case .paused: "pause.circle.fill"
        case .asleep: "moon.zzz.fill"
        }
    }

    /// Statuses drawn on charts, in legend order (sleep is left out).
    static let charted: [JournalStatus] = [.protected, .blocked, .checking, .paused]
}

extension BlockKind {
    /// Short name for charts.
    var title: String {
        switch self {
        case .offline: "Нет ответа"
        case .servicesDisagree: "Разные IP"
        case .notEnoughAnswers: "Мало ответов"
        case .countryUnknown: "Страна неизвестна"
        case .notAllowed: "Чужой IP"
        case .ipv6Leak: "Утечка IPv6"
        case .ipv6Disagree: "Разные IPv6"
        case .dnsLeak: "Утечка DNS"
        }
    }
}

extension JournalBlock {
    var text: String {
        let place = country.map { " (\(CountryInfo.flag($0)) \(CountryInfo.name($0)))" } ?? ""
        let address = ip ?? "?"
        switch kind {
        case .offline: return "Сервисы IP не отвечают: нет интернета или запросы блокируются."
        case .servicesDisagree: return "Сервисы видят разные IP (\(address)) — похоже на утечку."
        case .notEnoughAnswers: return "IP подтвердило слишком мало сервисов."
        case .countryUnknown: return "Не удалось определить страну для \(address)."
        case .notAllowed: return "IP \(address)\(place) не разрешён."
        case .ipv6Leak: return "Утечка IPv6: \(address)\(place) идёт мимо VPN."
        case .ipv6Disagree: return "Сервисы IPv6 видят разные адреса (\(address))."
        case .dnsLeak: return "Утечка DNS: резолвер \(address)\(place)."
        }
    }
}

extension JournalKillCause {
    var text: String {
        switch self {
        case .dnsLeak: "Утечка DNS с правилом «убивать сразу»"
        case .graceExpired: "Разрешённый IP не вернулся вовремя"
        case .manual: "Закрыто вручную"
        }
    }
}

enum JournalFilter: String, CaseIterable, Identifiable {
    case all, network, apps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "Всё"
        case .network: "Сеть"
        case .apps: "Программы"
        }
    }

    func accepts(_ event: JournalEvent) -> Bool {
        switch self {
        case .all: true
        case .network: !event.isAboutTargets
        case .apps: event.isAboutTargets
        }
    }
}

extension JournalEvent {
    var title: String {
        switch self {
        case .started: return "Subzero запущен"
        case .stopped(let clean): return clean ? "Subzero выключен" : "Subzero завершился аварийно"
        case .status(let status, _, _):
            switch status {
            case .checking: return "Проверка IP"
            case .protected: return "Защищено"
            case .blocked: return "Блокировка"
            case .paused: return "Пауза"
            case .asleep: return "Mac уснул"
            }
        case .ipChanged(let ip, _): return "Внешний IP: \(ip)"
        case .dnsWarning: return "Возможна утечка DNS"
        case .frozen(let targets, _): return "Заморожено: \(targets.joined(separator: ", "))"
        case .thawed(let targets, _): return "Разморожено: \(targets.joined(separator: ", "))"
        case .killed(let targets, _): return "K.O.: \(targets.joined(separator: ", "))"
        case .exited(let targets): return "Закрылось, пока было заморожено: \(targets.joined(separator: ", "))"
        }
    }

    var detail: String? {
        switch self {
        case .started: return nil
        case .stopped(let clean): return clean ? nil : "Время — когда Subzero последний раз был на связи."
        case .status(let status, let block, let until):
            switch status {
            case .checking: return "Программы стоят, пока не придёт вердикт (запуск, смена сети, пробуждение)."
            case .protected: return "IP разрешён, программы работают."
            case .blocked: return block?.text
            case .paused: return until.map { "До \($0.formatted(date: .omitted, time: .shortened))" } ?? "Без срока"
            case .asleep: return nil
            }
        case .ipChanged(_, let country):
            return country.map { CountryInfo.label($0) } ?? "Страна не определена"
        case .dnsWarning(let resolver, let country):
            return "Резолвер \(resolver) в \(CountryInfo.label(country)); программы работают."
        case .frozen(_, let manual): return manual ? "Вручную" : "Из-за IP"
        case .thawed(_, let manual): return manual ? "Вручную" : "IP снова в порядке"
        case .killed(_, let cause): return cause.text
        case .exited: return "Программа завершилась или вкладки закрыты в Safari."
        }
    }

    var symbol: String {
        switch self {
        case .started: "power"
        case .stopped(let clean): clean ? "power" : "exclamationmark.triangle.fill"
        case .status(let status, _, _): status.symbol
        case .ipChanged: "network"
        case .dnsWarning: "drop.fill"
        case .frozen: "snowflake"
        case .thawed: "play.fill"
        case .killed: "xmark.octagon.fill"
        case .exited: "xmark"
        }
    }

    var color: Color {
        switch self {
        case .started: .secondary
        case .stopped(let clean): clean ? .secondary : Palette.warning
        case .status(let status, _, _): status.color
        case .ipChanged: Color.teal
        case .dnsWarning: Palette.warning
        case .frozen(_, let manual): manual ? Palette.manual : Palette.frozen
        case .thawed: Palette.running
        case .killed: Palette.danger
        case .exited: .secondary
        }
    }
}
