import Foundation

// Safari tabs cannot be frozen with signals: every tab lives in shared WebKit
// processes. The Subzero Safari extension (`Safari/` in the repository) does it
// instead, following orders that Subzero writes to a file:
//
//   Subzero  --SafariCommand-->  state.json   --native messaging-->  extension
//   Subzero  <--SafariReport---  report.json  <--native messaging--  extension
//
// Both formats mirror `Safari/Extension/logic.js`; keep them in sync.

/// A website protected in Safari.
public struct SafariSite: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// Domains of the site; subdomains are covered too.
    public let domains: [String]

    public init(id: String, name: String, domains: [String]) {
        self.id = id
        self.name = name
        self.domains = domains
    }

    /// Sites the extension knows. The extension manifest asks Safari for access to
    /// exactly these domains, so adding a site means updating `Safari/Extension` too.
    public static let catalog: [SafariSite] = [
        SafariSite(id: "claude", name: "Claude", domains: ["claude.ai"]),
        SafariSite(id: "chatgpt", name: "ChatGPT", domains: ["chatgpt.com", "chat.openai.com"]),
    ]

    public static func site(id: String) -> SafariSite? {
        catalog.first { $0.id == id }
    }

    /// `host` is one of the domains or a subdomain of one.
    public func matches(host: String) -> Bool {
        let host = host.lowercased()
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// What the extension does with a site.
public enum SafariMode: String, Codable, Sendable {
    /// Tabs work normally.
    case run
    /// Network to the site is cut, open tabs stay as they are. Used while the IP is
    /// being re-checked (network change, wake, start), so a short check does not
    /// reload every tab.
    case hold
    /// Network is cut and tabs are unloaded to a "frozen" page; they come back by
    /// themselves when the site runs again.
    case freeze
}

/// Why a site is held or frozen.
public enum SafariWhy: String, Codable, Sendable {
    /// The IP is not allowed (or not confirmed yet).
    case network
    /// Frozen by hand.
    case manual
}

/// Orders from Subzero to the extension, written to `state.json`.
public struct SafariCommand: Codable, Equatable, Sendable {
    public static let formatVersion = 1

    public var version: Int
    /// `false` once Subzero quits normally: the extension releases every tab.
    public var active: Bool
    /// Seconds since 1970, refreshed as a heartbeat. The extension treats a stale
    /// command as "Subzero is gone" and freezes protected sites (fail-closed).
    public var updatedAt: Double
    /// Why the current block happened, shown on frozen tabs.
    public var detail: String?
    public var sites: [Site]

    public struct Site: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var domains: [String]
        /// Covered by protection (frozen when the IP is wrong).
        public var protected: Bool
        public var mode: SafariMode
        public var why: SafariWhy?
        /// Seconds since 1970 of the last "close all tabs" order; 0 = never.
        public var closeAt: Double

        public init(id: String, name: String, domains: [String], protected: Bool, mode: SafariMode, why: SafariWhy?, closeAt: Double) {
            self.id = id
            self.name = name
            self.domains = domains
            self.protected = protected
            self.mode = mode
            self.why = why
            self.closeAt = closeAt
        }
    }

    public init(version: Int = SafariCommand.formatVersion, active: Bool, updatedAt: Double, detail: String? = nil, sites: [Site]) {
        self.version = version
        self.active = active
        self.updatedAt = updatedAt
        self.detail = detail
        self.sites = sites
    }

    /// Same orders, whatever the heartbeat time.
    public func sameOrders(as other: SafariCommand) -> Bool {
        var a = self, b = other
        a.updatedAt = 0
        b.updatedAt = 0
        return a == b
    }
}

/// What the extension sees in Safari, written to `report.json`.
public struct SafariReport: Codable, Equatable, Sendable {
    /// Seconds since 1970 when the extension wrote it.
    public var at: Double
    public var extensionVersion: String?
    /// Network blocking (`declarativeNetRequest`) works. Without it `hold` falls back to `freeze`.
    public var blocksNetwork: Bool
    public var sites: [Site]

    public struct Site: Codable, Equatable, Sendable {
        public var id: String
        /// Tabs showing the live site.
        public var open: Int
        /// Tabs unloaded to the frozen page.
        public var frozen: Int
        /// Safari lets the extension see the site. Without access tabs cannot be frozen.
        public var access: Bool

        public init(id: String, open: Int, frozen: Int, access: Bool) {
            self.id = id
            self.open = open
            self.frozen = frozen
            self.access = access
        }
    }

    public init(at: Double, extensionVersion: String? = nil, blocksNetwork: Bool, sites: [Site]) {
        self.at = at
        self.extensionVersion = extensionVersion
        self.blocksNetwork = blocksNetwork
        self.sites = sites
    }

    public func site(_ id: String) -> Site? {
        sites.first { $0.id == id }
    }
}

extension SafariReport {
    // Written by JavaScript: tolerate missing fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = try c.decode(Double.self, forKey: .at)
        extensionVersion = try? c.decodeIfPresent(String.self, forKey: .extensionVersion)
        blocksNetwork = (try? c.decodeIfPresent(Bool.self, forKey: .blocksNetwork)) ?? false
        sites = (try? c.decodeIfPresent([Site].self, forKey: .sites)) ?? []
    }
}

extension SafariReport.Site {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        open = (try? c.decodeIfPresent(Int.self, forKey: .open)) ?? 0
        frozen = (try? c.decodeIfPresent(Int.self, forKey: .frozen)) ?? 0
        access = (try? c.decodeIfPresent(Bool.self, forKey: .access)) ?? false
    }
}
