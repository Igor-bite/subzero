import Foundation

/// What is allowed: countries (ISO 3166-1 alpha-2) and explicit addresses/subnets.
public struct AllowRules: Sendable, Equatable {
    public var countries: Set<String>
    public var networks: [IPNetwork]

    public init(countries: [String], networks: [String]) {
        self.countries = Set(countries.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }.filter { $0.count == 2 })
        self.networks = networks.compactMap(IPNetwork.init)
    }

    public func allows(_ ip: IPAddress, country: String?) -> Bool {
        if networks.contains(where: { $0.contains(ip) }) { return true }
        if let country, countries.contains(country.uppercased()) { return true }
        return false
    }
}

/// How independent "what is my IP" services answered.
public enum Consensus: Equatable, Sendable {
    /// Nobody answered.
    case none
    /// Everyone who answered named the same address.
    case agreed(IPAddress, votes: Int)
    /// Services named different addresses: looks like a leak or split routing.
    case disagreement([IPAddress])

    public init(answers: [IPAddress]) {
        guard !answers.isEmpty else { self = .none; return }
        let unique = Set(answers).sorted()
        if unique.count > 1 {
            self = .disagreement(unique)
        } else {
            self = .agreed(unique[0], votes: answers.count)
        }
    }

    public var agreedIP: IPAddress? {
        if case .agreed(let ip, _) = self { return ip }
        return nil
    }
}

public struct NetworkSnapshot: Equatable, Sendable {
    public var ipv4: Consensus
    public var ipv6: Consensus
    /// Country codes resolved for the agreed addresses and the DNS resolver.
    public var countries: [IPAddress: String]
    /// Address the DNS resolver uses to reach the internet (as seen by
    /// `whoami.akamai.net`), or nil if not checked / not determined.
    public var dnsResolver: IPAddress?

    public init(ipv4: Consensus, ipv6: Consensus, countries: [IPAddress: String], dnsResolver: IPAddress? = nil) {
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.countries = countries
        self.dnsResolver = dnsResolver
    }

    /// Main external address: agreed IPv4, else agreed IPv6.
    public var primaryIP: IPAddress? { ipv4.agreedIP ?? ipv6.agreedIP }
}

public enum DNSCheckMode: String, Codable, Sendable, CaseIterable {
    case off
    /// Show and notify, keep apps running.
    case warn
    /// Treat as a block: freeze apps.
    case block
}

public struct DNSLeak: Equatable, Sendable {
    public var resolver: IPAddress
    public var country: String
}

public struct PolicySettings: Sendable, Equatable {
    public var minAgree: Int
    public var checkIPv6: Bool
    public var blockWhenOffline: Bool
    public var dnsCheck: DNSCheckMode

    public init(minAgree: Int, checkIPv6: Bool, blockWhenOffline: Bool, dnsCheck: DNSCheckMode = .off) {
        self.minAgree = minAgree
        self.checkIPv6 = checkIPv6
        self.blockWhenOffline = blockWhenOffline
        self.dnsCheck = dnsCheck
    }
}

/// DNS goes through a resolver in a country that is neither allowed nor the
/// country of the current exit IP: typically the ISP's DNS while traffic uses a VPN.
/// Unknown resolver or unknown country is not reported (cannot tell).
public func dnsLeak(in snapshot: NetworkSnapshot, rules: AllowRules) -> DNSLeak? {
    guard let resolver = snapshot.dnsResolver, let country = snapshot.countries[resolver] else { return nil }
    if rules.allows(resolver, country: country) { return nil }
    if let exit = snapshot.primaryIP, snapshot.countries[exit] == country { return nil }
    return DNSLeak(resolver: resolver, country: country)
}

public enum BlockReason: Equatable, Sendable {
    case offline
    case servicesDisagree([IPAddress])
    case notEnoughAnswers(got: Int, need: Int)
    case countryUnknown(IPAddress)
    case notAllowed(IPAddress, country: String?)
    case ipv6Leak(IPAddress, country: String?)
    case ipv6Disagree([IPAddress])
    case dnsLeak(IPAddress, country: String)
}

public enum Verdict: Equatable, Sendable {
    case allowed(IPAddress?)
    case blocked(BlockReason)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }
}

/// Pure decision: may protected apps run with this network state?
/// Fails closed: anything uncertain is a block.
public func evaluate(_ snapshot: NetworkSnapshot, rules: AllowRules, settings: PolicySettings) -> Verdict {
    func problem(with ip: IPAddress) -> BlockReason? {
        let country = snapshot.countries[ip]
        if rules.allows(ip, country: country) { return nil }
        guard let country else { return .countryUnknown(ip) }
        return .notAllowed(ip, country: country)
    }

    var primary: IPAddress?

    switch snapshot.ipv4 {
    case .disagreement(let ips):
        return .blocked(.servicesDisagree(ips))
    case .agreed(let ip, let votes):
        guard votes >= max(1, settings.minAgree) else {
            return .blocked(.notEnoughAnswers(got: votes, need: settings.minAgree))
        }
        if let reason = problem(with: ip) { return .blocked(reason) }
        primary = ip
    case .none:
        break
    }

    if settings.checkIPv6 {
        switch snapshot.ipv6 {
        case .none:
            break
        case .disagreement(let ips):
            return .blocked(.ipv6Disagree(ips))
        case .agreed(let ip, _):
            if problem(with: ip) != nil {
                if primary == nil {
                    // IPv6-only network: this is the main address, not a leak.
                    return .blocked(problem(with: ip)!)
                }
                return .blocked(.ipv6Leak(ip, country: snapshot.countries[ip]))
            }
            if primary == nil { primary = ip }
        }
    }

    if primary == nil {
        return settings.blockWhenOffline ? .blocked(.offline) : .allowed(nil)
    }
    if settings.dnsCheck == .block, let leak = dnsLeak(in: snapshot, rules: rules) {
        return .blocked(.dnsLeak(leak.resolver, country: leak.country))
    }
    return .allowed(primary)
}

public enum EnforcementAction: Equatable, Sendable {
    case none
    case freeze
    case resume
    case kill
}

/// Tracks how long protected apps have been blocked and when to escalate to a kill.
public struct Enforcer: Sendable {
    public private(set) var blockedSince: Date?
    private var killClock: Date?

    public init() {}

    public var isBlocking: Bool { blockedSince != nil }

    public func deadline(grace: TimeInterval?) -> Date? {
        guard let grace, let killClock else { return nil }
        return killClock.addingTimeInterval(grace)
    }

    /// - Parameter grace: seconds to wait before killing, or `nil` to never kill.
    public mutating func step(blocked: Bool, now: Date, grace: TimeInterval?) -> EnforcementAction {
        guard blocked else {
            guard blockedSince != nil else { return .none }
            blockedSince = nil
            killClock = nil
            return .resume
        }
        if blockedSince == nil {
            blockedSince = now
            killClock = now
            return .freeze
        }
        if let deadline = deadline(grace: grace), now >= deadline {
            killClock = now
            return .kill
        }
        return .freeze
    }
}
