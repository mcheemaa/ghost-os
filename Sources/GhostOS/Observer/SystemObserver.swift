// SystemObserver.swift — Subscribes to AX notifications for continuous awareness

import ApplicationServices
import AXorcist
import Foundation

/// SystemObserver uses AXorcist's AXObserverCenter to subscribe to system-wide
/// accessibility notifications. When events occur (app switch, focus change,
/// window move, etc.), it calls StateManager to update the screen state.
@MainActor
public final class SystemObserver {
    private let stateManager: StateManager
    private var tokens: [SubscriptionToken] = []

    public init(stateManager: StateManager) {
        self.stateManager = stateManager
    }

    /// Start observing system-wide accessibility events
    public func startObserving() {
        let center = AXObserverCenter.shared

        // Global notifications (pid: nil = system-wide)
        let globalNotifications: [AXNotification] = [
            .focusedApplicationChanged,
            .focusedUIElementChanged,
        ]

        for notification in globalNotifications {
            let result = center.subscribe(
                pid: nil,
                element: nil,
                notification: notification,
                handler: { [weak self] pid, notification, rawElement, userInfo in
                    self?.handleNotification(
                        pid: pid,
                        notification: notification,
                        rawElement: rawElement
                    )
                }
            )
            if case let .success(token) = result {
                tokens.append(token)
            }
        }
    }

    /// Subscribe to notifications for a specific app's process
    public func observeApp(pid: pid_t) {
        let center = AXObserverCenter.shared

        let appNotifications: [AXNotification] = [
            .windowCreated,
            .windowResized,
            .windowMoved,
            .windowMinimized,
            .windowDeminiaturized,
            .titleChanged,
            .valueChanged,
        ]

        for notification in appNotifications {
            let result = center.subscribe(
                pid: pid,
                element: nil,
                notification: notification,
                handler: { [weak self] pid, notification, rawElement, userInfo in
                    self?.handleNotification(
                        pid: pid,
                        notification: notification,
                        rawElement: rawElement
                    )
                }
            )
            if case let .success(token) = result {
                tokens.append(token)
            }
        }
    }

    /// Stop all observations
    public func stopObserving() {
        let center = AXObserverCenter.shared
        for token in tokens {
            try? center.unsubscribe(token: token)
        }
        tokens.removeAll()
    }

    // MARK: - Private

    private func handleNotification(
        pid: pid_t,
        notification: AXNotification,
        rawElement: AXUIElement
    ) {
        switch notification {
        case .focusedApplicationChanged:
            stateManager.refreshFocus()

        case .focusedUIElementChanged:
            stateManager.refreshFocus()

        case .windowCreated, .windowResized, .windowMoved,
             .windowMinimized, .windowDeminiaturized:
            stateManager.refreshApp(pid: pid)

        case .titleChanged, .valueChanged:
            // Lightweight: just refresh focus info for now
            stateManager.refreshFocus()

        default:
            break
        }
    }
}
