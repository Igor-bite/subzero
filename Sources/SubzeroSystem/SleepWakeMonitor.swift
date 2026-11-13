import AppKit
import Foundation

/// Reports system sleep and wake (`NSWorkspace` notifications), delivered on the main actor.
@MainActor
public final class SleepWakeMonitor {
    public enum Event: Sendable {
        case willSleep
        case didWake
    }

    private let onEvent: @MainActor (Event) -> Void
    private var observers: [NSObjectProtocol] = []

    public init(onEvent: @escaping @MainActor (Event) -> Void) {
        self.onEvent = onEvent
    }

    public func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, Event)] = [
            (NSWorkspace.willSleepNotification, .willSleep),
            (NSWorkspace.didWakeNotification, .didWake),
        ]
        for (name, event) in pairs {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onEvent(event) }
            })
        }
    }

    public func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }
}
