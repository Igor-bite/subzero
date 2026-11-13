import Foundation
import Testing
@testable import SubzeroCore

// MARK: - IP parsing and networks

@Test func parsesIPv4AndIPv6() throws {
    let v4 = try #require(IPAddress("  203.0.113.7\n"))
    #expect(v4.isV4)
    #expect(v4.description == "203.0.113.7")

    let v6 = try #require(IPAddress("2001:db8::1"))
    #expect(!v6.isV4)
    #expect(v6.description == "2001:db8::1")

    #expect(IPAddress("not an ip") == nil)
    #expect(IPAddress("1.2.3") == nil)
    #expect(IPAddress("") == nil)
}

@Test func networkContainment() throws {
    let net = try #require(IPNetwork("10.1.2.0/23"))
    #expect(net.contains(IPAddress("10.1.2.5")!))
    #expect(net.contains(IPAddress("10.1.3.255")!))
    #expect(!net.contains(IPAddress("10.1.4.0")!))
    #expect(!net.contains(IPAddress("2001:db8::1")!))

    let single = try #require(IPNetwork("8.8.8.8"))
    #expect(single.prefix == 32)
    #expect(single.contains(IPAddress("8.8.8.8")!))
    #expect(!single.contains(IPAddress("8.8.8.9")!))

    let v6net = try #require(IPNetwork("2001:db8::/32"))
    #expect(v6net.contains(IPAddress("2001:db8:ffff::1")!))
    #expect(!v6net.contains(IPAddress("2001:db9::1")!))

    #expect(IPNetwork("10.0.0.0/33") == nil)
    #expect(IPNetwork("10.0.0.0/-1") == nil)
    #expect(IPNetwork("garbage/8") == nil)
}

@Test func allowRulesMatchCountryOrNetwork() {
    let rules = AllowRules(countries: ["nl", " DE "], networks: ["198.51.100.0/24", "bad"])
    #expect(rules.countries == ["NL", "DE"])
    #expect(rules.networks.count == 1)
    #expect(rules.allows(IPAddress("1.1.1.1")!, country: "NL"))
    #expect(rules.allows(IPAddress("198.51.100.20")!, country: nil))
    #expect(!rules.allows(IPAddress("1.1.1.1")!, country: "RU"))
    #expect(!rules.allows(IPAddress("1.1.1.1")!, country: nil))
}

// MARK: - Consensus

@Test func consensusOutcomes() {
    let a = IPAddress("1.1.1.1")!
    let b = IPAddress("2.2.2.2")!
    #expect(Consensus(answers: []) == .none)
    #expect(Consensus(answers: [a, a, a]) == .agreed(a, votes: 3))
    #expect(Consensus(answers: [a, b, a]) == .disagreement([a, b]))
}

// MARK: - Policy

private let nl = IPAddress("185.10.10.10")!
private let ru = IPAddress("95.10.10.10")!
private let v6 = IPAddress("2a02:6b8::1")!
private let rulesNL = AllowRules(countries: ["NL"], networks: [])
private let settings = PolicySettings(minAgree: 2, checkIPv6: true, blockWhenOffline: true, dnsCheck: .off)

@Test func allowsAgreedIPInAllowedCountry() {
    let snap = NetworkSnapshot(ipv4: .agreed(nl, votes: 3), ipv6: .none, countries: [nl: "NL"])
    #expect(evaluate(snap, rules: rulesNL, settings: settings) == .allowed(nl))
}

@Test func blocksWrongCountry() {
    let snap = NetworkSnapshot(ipv4: .agreed(ru, votes: 3), ipv6: .none, countries: [ru: "RU"])
    #expect(evaluate(snap, rules: rulesNL, settings: settings) == .blocked(.notAllowed(ru, country: "RU")))
}

@Test func blocksUnknownCountry() {
    let snap = NetworkSnapshot(ipv4: .agreed(ru, votes: 3), ipv6: .none, countries: [:])
    #expect(evaluate(snap, rules: rulesNL, settings: settings) == .blocked(.countryUnknown(ru)))
}

@Test func explicitNetworkAllowsWithoutCountry() {
    let rules = AllowRules(countries: [], networks: ["95.10.10.0/24"])
    let snap = NetworkSnapshot(ipv4: .agreed(ru, votes: 2), ipv6: .none, countries: [:])
    #expect(evaluate(snap, rules: rules, settings: settings) == .allowed(ru))
}

@Test func blocksWhenTooFewServicesAgree() {
    let snap = NetworkSnapshot(ipv4: .agreed(nl, votes: 1), ipv6: .none, countries: [nl: "NL"])
    #expect(evaluate(snap, rules: rulesNL, settings: settings) == .blocked(.notEnoughAnswers(got: 1, need: 2)))
}

@Test func blocksWhenServicesDisagree() {
    let snap = NetworkSnapshot(ipv4: .disagreement([nl, ru]), ipv6: .none, countries: [:])
    #expect(evaluate(snap, rules: rulesNL, settings: settings) == .blocked(.servicesDisagree([nl, ru])))
}

@Test func offlineHandling() {
    let snap = NetworkSnapshot(ipv4: .none, ipv6: .none, countries: [:])
    #expect(evaluate(snap, rules: rulesNL, settings: settings) == .blocked(.offline))

    var lenient = settings
    lenient.blockWhenOffline = false
    #expect(evaluate(snap, rules: rulesNL, settings: lenient) == .allowed(nil))
}

@Test func detectsIPv6Leak() {
    let snap = NetworkSnapshot(ipv4: .agreed(nl, votes: 3), ipv6: .agreed(v6, votes: 1), countries: [nl: "NL", v6: "RU"])
    #expect(evaluate(snap, rules: rulesNL, settings: settings) == .blocked(.ipv6Leak(v6, country: "RU")))

    var noV6 = settings
    noV6.checkIPv6 = false
    #expect(evaluate(snap, rules: rulesNL, settings: noV6) == .allowed(nl))
}

@Test func allowsIPv6InAllowedCountry() {
    let snap = NetworkSnapshot(ipv4: .agreed(nl, votes: 3), ipv6: .agreed(v6, votes: 2), countries: [nl: "NL", v6: "NL"])
    #expect(evaluate(snap, rules: rulesNL, settings: settings) == .allowed(nl))
}

@Test func ipv6OnlyNetworkIsJudgedByIPv6() {
    let snap = NetworkSnapshot(ipv4: .none, ipv6: .agreed(v6, votes: 1), countries: [v6: "NL"])
    #expect(evaluate(snap, rules: rulesNL, settings: settings) == .allowed(v6))
}

// MARK: - DNS leaks

private let resolverRU = IPAddress("77.88.8.8")!
private let resolverNL = IPAddress("185.10.10.53")!

@Test func dnsResolverInExitCountryIsFine() {
    let snap = NetworkSnapshot(ipv4: .agreed(nl, votes: 3), ipv6: .none, countries: [nl: "NL", resolverNL: "NL"], dnsResolver: resolverNL)
    #expect(dnsLeak(in: snap, rules: rulesNL) == nil)
}

@Test func dnsResolverInAnotherCountryIsALeak() {
    let snap = NetworkSnapshot(ipv4: .agreed(nl, votes: 3), ipv6: .none, countries: [nl: "NL", resolverRU: "RU"], dnsResolver: resolverRU)
    #expect(dnsLeak(in: snap, rules: rulesNL) == DNSLeak(resolver: resolverRU, country: "RU"))

    var warn = settings
    warn.dnsCheck = .warn
    #expect(evaluate(snap, rules: rulesNL, settings: warn) == .allowed(nl))

    var block = settings
    block.dnsCheck = .block
    #expect(evaluate(snap, rules: rulesNL, settings: block) == .blocked(.dnsLeak(resolverRU, country: "RU")))
}

@Test func dnsResolverInOtherAllowedCountryIsFine() {
    let rules = AllowRules(countries: ["NL", "DE"], networks: [])
    let resolverDE = IPAddress("9.9.9.9")!
    let snap = NetworkSnapshot(ipv4: .agreed(nl, votes: 3), ipv6: .none, countries: [nl: "NL", resolverDE: "DE"], dnsResolver: resolverDE)
    #expect(dnsLeak(in: snap, rules: rules) == nil)
}

@Test func unknownResolverCountryIsNotALeak() {
    let snap = NetworkSnapshot(ipv4: .agreed(nl, votes: 3), ipv6: .none, countries: [nl: "NL"], dnsResolver: resolverRU)
    #expect(dnsLeak(in: snap, rules: rulesNL) == nil)
    let none = NetworkSnapshot(ipv4: .agreed(nl, votes: 3), ipv6: .none, countries: [nl: "NL"], dnsResolver: nil)
    #expect(dnsLeak(in: none, rules: rulesNL) == nil)
}

@Test func dnsBlockModeDoesNotHideIPProblems() {
    let snap = NetworkSnapshot(ipv4: .agreed(ru, votes: 3), ipv6: .none, countries: [ru: "RU", resolverRU: "RU"], dnsResolver: resolverRU)
    var block = settings
    block.dnsCheck = .block
    #expect(evaluate(snap, rules: rulesNL, settings: block) == .blocked(.notAllowed(ru, country: "RU")))
}

// MARK: - DNS rules by country

private let resolverDE = IPAddress("9.9.9.9")!
private let resolverUS = IPAddress("8.8.8.8")!

private func snapNL(resolver: IPAddress, country: String) -> NetworkSnapshot {
    NetworkSnapshot(ipv4: .agreed(nl, votes: 3), ipv6: .none, countries: [nl: "NL", resolver: country], dnsResolver: resolver)
}

@Test func countryRuleOverridesDefault() {
    var s = settings
    s.dnsCheck = .warn
    s.dnsCountries = ["RU": .kill]
    let ruLeak = snapNL(resolver: resolverRU, country: "RU")
    #expect(dnsFinding(in: ruLeak, rules: rulesNL, settings: s)?.action == .kill)
    #expect(evaluate(ruLeak, rules: rulesNL, settings: s) == .blocked(.dnsLeak(resolverRU, country: "RU")))

    // Other countries keep the default.
    let usLeak = snapNL(resolver: resolverUS, country: "US")
    #expect(dnsFinding(in: usLeak, rules: rulesNL, settings: s)?.action == .warn)
    #expect(evaluate(usLeak, rules: rulesNL, settings: s) == .allowed(nl))
}

@Test func countryRuleCanIgnoreACountry() {
    var s = settings
    s.dnsCheck = .block
    s.dnsCountries = ["US": .off]
    let usLeak = snapNL(resolver: resolverUS, country: "US")
    #expect(dnsFinding(in: usLeak, rules: rulesNL, settings: s) == nil)
    #expect(evaluate(usLeak, rules: rulesNL, settings: s) == .allowed(nl))
    #expect(dnsFinding(in: snapNL(resolver: resolverRU, country: "RU"), rules: rulesNL, settings: s)?.action == .block)
}

@Test func countryRuleAppliesEvenToAllowedCountry() {
    let rules = AllowRules(countries: ["NL", "DE"], networks: [])
    var s = settings
    let deResolver = snapNL(resolver: resolverDE, country: "DE")
    s.dnsCheck = .block
    #expect(dnsFinding(in: deResolver, rules: rules, settings: s) == nil)   // allowed: no default leak
    s.dnsCountries = ["DE": .warn]
    #expect(dnsFinding(in: deResolver, rules: rules, settings: s)?.action == .warn)
}

@Test func resolverInExitCountryNeverTriggersCountryRule() {
    var s = settings
    s.dnsCountries = ["NL": .kill]
    #expect(dnsFinding(in: snapNL(resolver: resolverNL, country: "NL"), rules: rulesNL, settings: s) == nil)
}

@Test func dnsLookupNeededOnlyWhenSomethingChecks() {
    var s = settings
    #expect(!s.needsDNS)
    s.dnsCountries = ["RU": .off]
    #expect(!s.needsDNS)
    s.dnsCountries = ["RU": .warn]
    #expect(s.needsDNS)
}

@Test func configCarriesCountryRulesIntoPolicy() throws {
    var cfg = GuardConfig()
    cfg.dnsCountryRules = [DNSCountryRule(country: "ru", action: .kill)]
    #expect(cfg.policySettings.dnsCountries == ["RU": .kill])
    let back = try JSONDecoder().decode(GuardConfig.self, from: JSONEncoder().encode(cfg))
    #expect(back.dnsCountryRules == cfg.dnsCountryRules)
    // Old files without the key still load.
    let old = try JSONDecoder().decode(GuardConfig.self, from: Data(#"{"dnsCheck":"block"}"#.utf8))
    #expect(old.dnsCheck == .block && old.dnsCountryRules.isEmpty)
}

@Test func ipFromBytes() {
    #expect(IPAddress(bytes: [8, 8, 4, 4])?.description == "8.8.4.4")
    #expect(IPAddress(bytes: [1, 2, 3]) == nil)
}

// MARK: - Enforcer

@Test func enforcerFreezesKillsAndResumes() {
    var e = Enforcer()
    let t0 = Date(timeIntervalSince1970: 1_000)

    #expect(e.step(blocked: false, now: t0, grace: 60) == .none)
    #expect(e.step(blocked: true, now: t0, grace: 60) == .freeze)
    #expect(e.deadline(grace: 60) == t0.addingTimeInterval(60))
    #expect(e.step(blocked: true, now: t0.addingTimeInterval(30), grace: 60) == .freeze)
    #expect(e.step(blocked: true, now: t0.addingTimeInterval(60), grace: 60) == .kill)
    // After a kill the clock restarts for anything launched again.
    #expect(e.step(blocked: true, now: t0.addingTimeInterval(61), grace: 60) == .freeze)
    #expect(e.step(blocked: true, now: t0.addingTimeInterval(120), grace: 60) == .kill)
    #expect(e.step(blocked: false, now: t0.addingTimeInterval(130), grace: 60) == .resume)
    #expect(e.step(blocked: false, now: t0.addingTimeInterval(131), grace: 60) == .none)
}

@Test func enforcerNeverKillsWithoutGrace() {
    var e = Enforcer()
    let t0 = Date(timeIntervalSince1970: 0)
    #expect(e.step(blocked: true, now: t0, grace: nil) == .freeze)
    #expect(e.step(blocked: true, now: t0.addingTimeInterval(100_000), grace: nil) == .freeze)
    #expect(e.deadline(grace: nil) == nil)
}

// MARK: - Process matching

private func proc(_ pid: Int32, _ ppid: Int32, _ path: String?, name: String? = nil, args: [String] = []) -> ProcessRecord {
    ProcessRecord(pid: pid, ppid: ppid, name: name ?? (path.map { ($0 as NSString).lastPathComponent } ?? "?"), path: path, arguments: args)
}

@Test func bundleRuleMatchesHelpersAndDescendants() {
    let ruleID = UUID()
    let processes = [
        proc(1, 0, "/sbin/launchd"),
        proc(100, 1, "/Applications/Cursor.app/Contents/MacOS/Cursor"),
        proc(101, 100, "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper.app/Contents/MacOS/Cursor Helper"),
        proc(102, 100, "/bin/zsh"),
        proc(103, 102, "/usr/bin/git"),
        proc(200, 1, "/Applications/CursorLike.app/Contents/MacOS/CursorLike"),
        proc(300, 1, "/Applications/Other.app/Contents/MacOS/Other"),
    ]
    let targets = ProcessMatcher.targets(
        processes: processes,
        rules: [(ruleID, .bundle(path: "/Applications/Cursor.app"))],
        excludingPIDs: []
    )
    #expect(Set(targets.keys) == [100, 101, 102, 103])
    #expect(targets.values.allSatisfy { $0 == ruleID })
}

@Test func patternRuleMatchesNameCaseSensitivelyAndInterpreterArgs() {
    let cli = UUID()
    let processes = [
        proc(10, 1, "/Users/u/.local/share/claude/versions/2.1.3", name: "2.1.3"),
        proc(11, 1, "/opt/homebrew/bin/node", args: ["/opt/homebrew/bin/claude", "--resume"]),
        proc(12, 1, "/Applications/Claude.app/Contents/MacOS/Claude"),
        proc(13, 1, "/usr/local/bin/claude"),
        proc(14, 1, "/opt/homebrew/bin/node", args: ["/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js"]),
    ]
    let targets = ProcessMatcher.targets(
        processes: processes,
        rules: [(cli, .patterns(["claude", "/.local/share/claude/versions/", "@anthropic-ai/claude-code"]))],
        excludingPIDs: []
    )
    #expect(Set(targets.keys) == [10, 11, 13, 14])
}

@Test func neverTargetsLaunchdOrExcludedPIDs() {
    let r = UUID()
    let processes = [
        proc(1, 0, "/Applications/X.app/Contents/MacOS/X"),
        proc(50, 1, "/Applications/X.app/Contents/MacOS/X"),
        proc(51, 50, "/Applications/Subzero.app/Contents/MacOS/Subzero"),
    ]
    let targets = ProcessMatcher.targets(
        processes: processes,
        rules: [(r, .bundle(path: "/Applications/X.app/"))],
        excludingPIDs: [51]
    )
    #expect(Set(targets.keys) == [50])
}

// MARK: - Config

@Test func configDecodesMissingKeysWithDefaults() throws {
    let json = #"{"allowedCountries":["NL"],"grace":120}"#
    let cfg = try JSONDecoder().decode(GuardConfig.self, from: Data(json.utf8))
    #expect(cfg.allowedCountries == ["NL"])
    #expect(cfg.grace == 120)
    #expect(cfg.minAgree == GuardConfig().minAgree)
    #expect(cfg.dnsCheck == .warn)
    #expect(cfg.apps.isEmpty)
}

@Test func configRoundTrips() throws {
    var cfg = GuardConfig()
    cfg.apps = [
        AppRule(name: "Cursor", kind: .bundle(path: "/Applications/Cursor.app")),
        AppRule(name: "Claude Code", kind: .patterns(["claude"]), enabled: false),
    ]
    cfg.allowedNetworks = ["10.0.0.0/8"]
    let data = try JSONEncoder().encode(cfg)
    let back = try JSONDecoder().decode(GuardConfig.self, from: data)
    #expect(back == cfg)
}
