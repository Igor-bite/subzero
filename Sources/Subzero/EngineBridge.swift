import AppKit
import Observation
import SubzeroEngine

/// Connects the UI-free engine to macOS: system notifications and the Dock badge.
@MainActor
final class EngineBridge {
    private let engine: GuardEngine
    private let notifier = Notifier()

    init(engine: GuardEngine) {
        self.engine = engine
    }

    func start() {
        engine.onEvent = { [weak self] event in self?.handle(event) }

        observe({ [engine] in engine.config.notifications }) { [notifier] enabled in
            notifier.enabled = enabled
            notifier.requestAuthorizationIfNeeded()
        }
        // Dock badge: how many apps stand frozen right now.
        observe({ [engine] in engine.frozenAppCount }) { count in
            let badge = count > 0 ? "\(count)" : nil
            if NSApp.dockTile.badgeLabel != badge { NSApp.dockTile.badgeLabel = badge }
        }
    }

    private func handle(_ event: GuardEvent) {
        let text = event.notification
        notifier.post(title: text.title, body: text.body)
    }

    /// Calls `apply` with the current value now and again after every change.
    private func observe<Value: Equatable & Sendable>(
        _ value: @escaping @MainActor () -> Value,
        previous: Value? = nil,
        apply: @escaping @MainActor (Value) -> Void
    ) {
        let current = value()
        if current != previous { apply(current) }
        withObservationTracking { _ = value() } onChange: { [weak self] in
            Task { @MainActor in self?.observe(value, previous: current, apply: apply) }
        }
    }
}
