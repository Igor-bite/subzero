import SubzeroCore
import SubzeroEngine

// User-facing text for engine values. The engine itself has no strings.

extension BlockReason {
    var text: String {
        switch self {
        case .offline:
            return "Сервисы IP не отвечают: нет интернета или запросы блокируются."
        case .servicesDisagree(let ips):
            return "Сервисы видят разные IP (\(ips.map(\.description).joined(separator: ", "))) — похоже на утечку."
        case .notEnoughAnswers(let got, let need):
            return "IP подтвердили \(got) из \(need) нужных сервисов."
        case .countryUnknown(let ip):
            return "Не удалось определить страну для \(ip)."
        case .notAllowed(let ip, let country):
            return "IP \(ip)\(country.map { " (\(CountryInfo.flag($0)) \(CountryInfo.name($0)))" } ?? "") не разрешён."
        case .ipv6Leak(let ip, let country):
            return "Утечка IPv6: \(ip)\(country.map { " (\(CountryInfo.flag($0)) \($0))" } ?? "") идёт мимо VPN."
        case .ipv6Disagree:
            return "Сервисы IPv6 видят разные адреса — похоже на утечку."
        case .dnsLeak(let resolver, let country):
            return "Утечка DNS: запросы идут через резолвер \(resolver) в \(CountryInfo.flag(country)) \(CountryInfo.name(country))."
        }
    }
}

extension GuardEvent {
    /// Title and body of the system notification for this event.
    var notification: (title: String, body: String) {
        switch self {
        case .blocked(let reason, let apps):
            return ("Программы заморожены: \(apps.joined(separator: ", "))", reason.text)
        case .resumed(let ip, let country):
            guard let ip else { return ("Программы снова работают", "IP в порядке") }
            let place = country.map { " \(CountryInfo.flag($0)) \($0)" } ?? ""
            return ("Программы снова работают", "IP \(ip)\(place)")
        case .killed(let apps, let cause):
            let why = cause == .dnsLeak ? "Утечка DNS" : "Разрешённый IP не вернулся"
            return ("K.O. — программы закрыты", "\(why): \(apps.joined(separator: ", "))")
        case .pauseEnded:
            return ("Пауза закончилась", "Проверяю IP и снова защищаю программы.")
        case .dnsWarning(let leak):
            return (
                "Возможна утечка DNS",
                "DNS-запросы идут через резолвер в \(CountryInfo.flag(leak.country)) \(CountryInfo.name(leak.country)), а не через страну VPN."
            )
        }
    }
}
