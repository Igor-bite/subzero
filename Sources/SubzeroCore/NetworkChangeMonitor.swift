import Foundation
import Network

/// Reports when the set of network interfaces, gateways or reachability changes
/// (VPN up/down, Wi-Fi switch, cable plugged). The first path update is not reported.
public final class NetworkChangeMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "subzero.network-monitor")
    // Touched only on `queue`.
    private var lastSignature: String?
    private let onChange: @Sendable (_ description: String) -> Void

    public init(onChange: @escaping @Sendable (_ description: String) -> Void) {
        self.onChange = onChange
    }

    public func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let signature = Self.signature(of: path)
            defer { self.lastSignature = signature }
            if let last = self.lastSignature, last != signature {
                self.onChange(signature)
            }
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.cancel()
    }

    static func signature(of path: NWPath) -> String {
        let interfaces = path.availableInterfaces
            .map { "\($0.name):\($0.type)" }
            .sorted()
            .joined(separator: ",")
        let gateways = path.gateways.map { "\($0)" }.sorted().joined(separator: ",")
        return "\(path.status)|\(interfaces)|gw=\(gateways)|v4=\(path.supportsIPv4)|v6=\(path.supportsIPv6)|dns=\(path.supportsDNS)"
    }
}
