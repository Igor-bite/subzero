import Foundation

/// Asks several independent services for the external IP and resolves its country.
public actor IPProbe {
    public static let ipv4Services: [URL] = [
        "https://api.ipify.org",
        "https://ipv4.icanhazip.com",
        "https://v4.ident.me",
        "https://checkip.amazonaws.com",
    ].map { URL(string: $0)! }

    public static let ipv6Services: [URL] = [
        "https://api6.ipify.org",
        "https://ipv6.icanhazip.com",
        "https://v6.ident.me",
    ].map { URL(string: $0)! }

    private var countryCache: [IPAddress: String] = [:]

    public init() {}

    /// Hostname whose A record is the address of the recursive resolver that asked for it.
    public static let dnsWhoamiHost = "whoami.akamai.net"

    public func snapshot(includeIPv6: Bool, includeDNS: Bool) async -> NetworkSnapshot {
        // A fresh session per round: no connection reuse across network changes.
        let session = Self.makeSession()
        defer { session.invalidateAndCancel() }

        async let v4 = Self.fetchAll(Self.ipv4Services, wantV4: true, session: session)
        async let v6: [IPAddress] = includeIPv6
            ? Self.fetchAll(Self.ipv6Services, wantV4: false, session: session)
            : []
        async let dns: IPAddress? = includeDNS
            ? Self.resolveIPv4(Self.dnsWhoamiHost, timeout: 5)
            : nil
        let (answers4, answers6, resolver) = await (v4, v6, dns)

        let c4 = Consensus(answers: answers4)
        let c6 = Consensus(answers: answers6)

        var countries: [IPAddress: String] = [:]
        for ip in [c4.agreedIP, c6.agreedIP, resolver].compactMap({ $0 }) where countries[ip] == nil {
            if let code = await country(for: ip, session: session) {
                countries[ip] = code
            }
        }
        return NetworkSnapshot(ipv4: c4, ipv6: c6, countries: countries, dnsResolver: resolver)
    }

    // MARK: - DNS

    /// Resolves through the system resolver (the same path apps use), with a hard timeout:
    /// getaddrinfo cannot be cancelled, so a stuck lookup is abandoned, not awaited.
    static func resolveIPv4(_ host: String, timeout: TimeInterval) async -> IPAddress? {
        await withCheckedContinuation { (continuation: CheckedContinuation<IPAddress?, Never>) in
            let once = OnceFlag()
            DispatchQueue.global(qos: .utility).async {
                let result = blockingResolveIPv4(host)
                if once.claim() { continuation.resume(returning: result) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if once.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    static func blockingResolveIPv4(_ host: String) -> IPAddress? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        guard let sockaddr = first.pointee.ai_addr, first.pointee.ai_family == AF_INET else { return nil }
        return sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
            var addr = sin.pointee.sin_addr
            return IPAddress(bytes: withUnsafeBytes(of: &addr) { Array($0) })
        }
    }

    private func country(for ip: IPAddress, session: URLSession) async -> String? {
        if let cached = countryCache[ip] { return cached }
        guard let code = await Self.lookupCountry(ip, session: session) else { return nil }
        if countryCache.count > 256 { countryCache.removeAll() }
        countryCache[ip] = code
        return code
    }

    // MARK: - Networking

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": "Subzero/1.0", "Accept": "text/plain, application/json"]
        return URLSession(configuration: config)
    }

    static func fetchText(_ url: URL, session: URLSession) async -> String? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    static func fetchAll(_ urls: [URL], wantV4: Bool, session: URLSession) async -> [IPAddress] {
        await withTaskGroup(of: IPAddress?.self) { group in
            for url in urls {
                group.addTask {
                    guard let text = await fetchText(url, session: session),
                          let ip = IPAddress(text), ip.isV4 == wantV4 else { return nil }
                    return ip
                }
            }
            var result: [IPAddress] = []
            for await ip in group {
                if let ip { result.append(ip) }
            }
            return result
        }
    }

    static func lookupCountry(_ ip: IPAddress, session: URLSession) async -> String? {
        let host = ip.description
        if let text = await fetchText(URL(string: "https://ipinfo.io/\(host)/country")!, session: session),
           let code = normalizeCountry(text) {
            return code
        }
        if let text = await fetchText(URL(string: "https://api.country.is/\(host)")!, session: session),
           let data = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = json["country"] as? String,
           let code = normalizeCountry(raw) {
            return code
        }
        if let text = await fetchText(URL(string: "https://ipapi.co/\(host)/country/")!, session: session),
           let code = normalizeCountry(text) {
            return code
        }
        return nil
    }

    static func normalizeCountry(_ text: String) -> String? {
        let code = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return code
    }
}

/// Lets exactly one of several racing callbacks win.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
