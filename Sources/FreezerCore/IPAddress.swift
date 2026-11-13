import Darwin
import Foundation

/// An IPv4 or IPv6 address stored as raw network-order bytes.
public struct IPAddress: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let bytes: [UInt8]

    public init?(_ string: String) {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 {
            bytes = withUnsafeBytes(of: &v4) { Array($0) }
            return
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 {
            bytes = withUnsafeBytes(of: &v6) { Array($0) }
            return
        }
        return nil
    }

    /// Raw network-order bytes: 4 for IPv4, 16 for IPv6.
    public init?(bytes: [UInt8]) {
        guard bytes.count == 4 || bytes.count == 16 else { return nil }
        self.bytes = bytes
    }

    public var isV4: Bool { bytes.count == 4 }

    public var description: String {
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let family = isV4 ? AF_INET : AF_INET6
        let ok = bytes.withUnsafeBytes { raw in
            inet_ntop(family, raw.baseAddress, &buffer, socklen_t(buffer.count)) != nil
        }
        guard ok else { return "?" }
        let utf8 = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: utf8, as: UTF8.self)
    }

    public static func < (lhs: IPAddress, rhs: IPAddress) -> Bool {
        if lhs.bytes.count != rhs.bytes.count { return lhs.bytes.count < rhs.bytes.count }
        return lhs.bytes.lexicographicallyPrecedes(rhs.bytes)
    }
}

/// A single address or a CIDR block, e.g. `203.0.113.7` or `10.0.0.0/8`.
public struct IPNetwork: Hashable, Sendable, CustomStringConvertible {
    public let base: IPAddress
    public let prefix: Int

    public init?(_ string: String) {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, let ip = IPAddress(String(first)) else { return nil }
        let maxBits = ip.bytes.count * 8
        if parts.count == 2 {
            guard let p = Int(parts[1]), (0...maxBits).contains(p) else { return nil }
            prefix = p
        } else {
            prefix = maxBits
        }
        base = ip
    }

    public func contains(_ ip: IPAddress) -> Bool {
        guard ip.bytes.count == base.bytes.count else { return false }
        var remaining = prefix
        for i in 0..<ip.bytes.count {
            if remaining <= 0 { return true }
            let bits = min(8, remaining)
            let mask: UInt8 = bits == 8 ? 0xFF : ~(UInt8(0xFF) >> UInt8(bits))
            if ip.bytes[i] & mask != base.bytes[i] & mask { return false }
            remaining -= bits
        }
        return true
    }

    public var description: String {
        prefix == base.bytes.count * 8 ? base.description : "\(base)/\(prefix)"
    }
}
