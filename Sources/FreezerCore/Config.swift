import Foundation

public struct AppRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: AppRuleKind
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, kind: AppRuleKind, enabled: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.enabled = enabled
    }
}

/// What to show next to the menu bar icon.
public enum MenuBarText: String, Codable, Sendable, CaseIterable {
    case icon
    case country
    case ip
}

public struct GuardConfig: Codable, Equatable, Sendable {
    /// ISO country codes where protected apps may run.
    public var allowedCountries: [String] = []
    /// Explicit addresses or CIDR blocks that are always fine.
    public var allowedNetworks: [String] = []
    /// What to protect.
    public var apps: [AppRule] = []

    /// Seconds between checks while everything is fine.
    public var checkInterval: TimeInterval = 30
    /// Kill protected apps if no allowed IP returns within `grace`.
    public var killAfterGrace: Bool = true
    public var grace: TimeInterval = 300
    /// How many IP services must name the same address.
    public var minAgree: Int = 2
    public var checkIPv6: Bool = true
    public var freezeOnNetworkChange: Bool = true
    public var blockWhenOffline: Bool = true
    public var dnsCheck: DNSCheckMode = .warn
    public var notifications: Bool = true
    public var menuBarText: MenuBarText = .country

    public init() {}

    public var allowRules: AllowRules {
        AllowRules(countries: allowedCountries, networks: allowedNetworks)
    }

    public var policySettings: PolicySettings {
        PolicySettings(minAgree: minAgree, checkIPv6: checkIPv6, blockWhenOffline: blockWhenOffline, dnsCheck: dnsCheck)
    }
}

extension GuardConfig {
    // Tolerates missing keys so older config files keep loading.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GuardConfig()
        allowedCountries = try c.decodeIfPresent([String].self, forKey: .allowedCountries) ?? d.allowedCountries
        allowedNetworks = try c.decodeIfPresent([String].self, forKey: .allowedNetworks) ?? d.allowedNetworks
        apps = try c.decodeIfPresent([AppRule].self, forKey: .apps) ?? d.apps
        checkInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .checkInterval) ?? d.checkInterval
        killAfterGrace = try c.decodeIfPresent(Bool.self, forKey: .killAfterGrace) ?? d.killAfterGrace
        grace = try c.decodeIfPresent(TimeInterval.self, forKey: .grace) ?? d.grace
        minAgree = try c.decodeIfPresent(Int.self, forKey: .minAgree) ?? d.minAgree
        checkIPv6 = try c.decodeIfPresent(Bool.self, forKey: .checkIPv6) ?? d.checkIPv6
        freezeOnNetworkChange = try c.decodeIfPresent(Bool.self, forKey: .freezeOnNetworkChange) ?? d.freezeOnNetworkChange
        blockWhenOffline = try c.decodeIfPresent(Bool.self, forKey: .blockWhenOffline) ?? d.blockWhenOffline
        dnsCheck = (try? c.decodeIfPresent(DNSCheckMode.self, forKey: .dnsCheck)) ?? d.dnsCheck
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? d.notifications
        menuBarText = (try? c.decodeIfPresent(MenuBarText.self, forKey: .menuBarText)) ?? d.menuBarText
    }
}

public struct ConfigStore: Sendable {
    public let url: URL
    /// Where an older build kept its config; copied over once if `url` does not exist yet.
    public let legacyURL: URL?

    public init(url: URL = ConfigStore.defaultURL, legacyURL: URL? = nil) {
        self.url = url
        self.legacyURL = legacyURL
    }

    /// The app's real store, migrating from the old "Karing" location.
    public static var standard: ConfigStore {
        ConfigStore(url: defaultURL, legacyURL: legacyDefaultURL)
    }

    private static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    public static var defaultURL: URL {
        supportDirectory.appendingPathComponent("Freezer", isDirectory: true).appendingPathComponent("config.json")
    }

    /// The app used to be called Karing.
    public static var legacyDefaultURL: URL {
        supportDirectory.appendingPathComponent("Karing", isDirectory: true).appendingPathComponent("config.json")
    }

    public func load() -> GuardConfig {
        migrateIfNeeded()
        guard let data = try? Data(contentsOf: url) else { return GuardConfig() }
        return (try? JSONDecoder().decode(GuardConfig.self, from: data)) ?? GuardConfig()
    }

    private func migrateIfNeeded() {
        let fm = FileManager.default
        guard let legacyURL, !fm.fileExists(atPath: url.path), fm.fileExists(atPath: legacyURL.path) else { return }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.copyItem(at: legacyURL, to: url)
    }

    public func save(_ config: GuardConfig) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
    }
}

public enum CountryInfo {
    public static func flag(_ code: String) -> String {
        let upper = code.uppercased()
        guard upper.count == 2, upper.allSatisfy({ $0.isASCII && $0.isLetter }) else { return "" }
        return String(String.UnicodeScalarView(upper.unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }))
    }

    public static func name(_ code: String, locale: Locale = Locale(identifier: "ru_RU")) -> String {
        locale.localizedString(forRegionCode: code.uppercased()) ?? code.uppercased()
    }

    /// All two-letter ISO regions, sorted by localized name.
    public static func allCodes(locale: Locale = Locale(identifier: "ru_RU")) -> [String] {
        Locale.Region.isoRegions
            .map(\.identifier)
            .filter { $0.count == 2 && $0.allSatisfy(\.isLetter) }
            .sorted { name($0, locale: locale).localizedCompare(name($1, locale: locale)) == .orderedAscending }
    }
}
