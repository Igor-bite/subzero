import Foundation
import Testing
@testable import SubzeroCore

@Test func siteMatchesDomainsAndSubdomainsOnly() {
    let chatgpt = SafariSite.site(id: "chatgpt")!
    #expect(chatgpt.matches(host: "chatgpt.com"))
    #expect(chatgpt.matches(host: "ab.CHATGPT.com"))
    #expect(chatgpt.matches(host: "chat.openai.com"))
    #expect(!chatgpt.matches(host: "openai.com"))
    #expect(!chatgpt.matches(host: "notchatgpt.com"))
    #expect(!chatgpt.matches(host: "chatgpt.com.evil.net"))
}

@Test func configProtectsCatalogSitesByDefault() throws {
    #expect(GuardConfig().safariSites == ["claude", "chatgpt"])
    // Old config files without the key keep the default.
    let old = try JSONDecoder().decode(GuardConfig.self, from: Data(#"{"allowedCountries":["NL"]}"#.utf8))
    #expect(old.safariSites == ["claude", "chatgpt"])
    var config = GuardConfig()
    config.safariSites = ["claude"]
    let back = try JSONDecoder().decode(GuardConfig.self, from: JSONEncoder().encode(config))
    #expect(back.safariSites == ["claude"])
}

@Test func reportFromJavaScriptToleratesMissingFields() throws {
    let json = #"{"version":1,"at":1800000000.5,"sites":[{"id":"claude","open":2},{"id":"chatgpt","frozen":1,"access":true}]}"#
    let report = try JSONDecoder().decode(SafariReport.self, from: Data(json.utf8))
    #expect(report.at == 1_800_000_000.5)
    #expect(report.blocksNetwork == false)
    #expect(report.extensionVersion == nil)
    #expect(report.site("claude") == .init(id: "claude", open: 2, frozen: 0, access: false))
    #expect(report.site("chatgpt") == .init(id: "chatgpt", open: 0, frozen: 1, access: true))
}

@Test func commandUsesTheKeysTheExtensionReads() throws {
    let command = SafariCommand(active: true, updatedAt: 12, detail: "x", sites: [
        .init(id: "claude", name: "Claude", domains: ["claude.ai"], protected: true, mode: .hold, why: .network, closeAt: 0),
    ])
    let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: Any])
    #expect(Set(object.keys) == ["version", "active", "updatedAt", "detail", "sites"])
    let site = try #require((object["sites"] as? [[String: Any]])?.first)
    #expect(Set(site.keys) == ["id", "name", "domains", "protected", "mode", "why", "closeAt"])
    #expect(site["mode"] as? String == "hold")

    var later = command
    later.updatedAt = 99
    #expect(command.sameOrders(as: later))
    later.sites[0].mode = .freeze
    #expect(!command.sameOrders(as: later))
}

/// The extension keeps its own copy of the catalog (for the fail-closed case) and asks
/// Safari for access to these domains; all three must agree.
@Test func extensionKnowsEveryCatalogSite() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let logic = try String(contentsOf: root.appendingPathComponent("Safari/Extension/logic.js"), encoding: .utf8)
    let manifestData = try Data(contentsOf: root.appendingPathComponent("Safari/Extension/manifest.json"))
    let manifest = try #require(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
    let permissions = try #require(manifest["permissions"] as? [String])

    for site in SafariSite.catalog {
        #expect(logic.contains(#"id: "\#(site.id)""#), "logic.js misses site \(site.id)")
        for domain in site.domains {
            #expect(logic.contains(#""\#(domain)""#), "logic.js misses \(domain)")
            #expect(permissions.contains("*://\(domain)/*"), "manifest misses \(domain)")
            #expect(permissions.contains("*://*.\(domain)/*"), "manifest misses *.\(domain)")
        }
    }
}
