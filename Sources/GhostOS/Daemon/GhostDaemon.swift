// GhostDaemon.swift — Main daemon lifecycle

import AXorcist
import Foundation

/// GhostDaemon is the top-level coordinator that ties together
/// StateManager, SystemObserver, ActionExecutor, and IPCServer.
@MainActor
public final class GhostDaemon {
    private let stateManager: StateManager
    private let systemObserver: SystemObserver
    private let actionExecutor: ActionExecutor
    private let rpcHandler: RPCHandler
    private let ipcServer: IPCServer

    public init() {
        self.stateManager = StateManager()
        self.systemObserver = SystemObserver(stateManager: stateManager)
        self.actionExecutor = ActionExecutor(stateManager: stateManager)
        self.rpcHandler = RPCHandler(stateManager: stateManager, actionExecutor: actionExecutor)
        self.ipcServer = IPCServer(handler: rpcHandler)
    }

    /// Start the daemon: check permissions, build initial state, start observing, start IPC
    public func start() throws {
        print("[ghost-daemon] Starting Ghost OS daemon...")

        // 1. Check accessibility permissions
        print("[ghost-daemon] Checking accessibility permissions...")
        let status = getPermissionsStatus()
        guard status.canUseAccessibility else {
            print("[ghost-daemon] ERROR: Accessibility permissions not granted.")
            print("[ghost-daemon] Go to: System Settings > Privacy & Security > Accessibility")
            print("[ghost-daemon] Add your terminal app (Terminal, iTerm2, etc.) to the list.")
            throw GhostError.permissionDenied("Accessibility permissions required")
        }
        print("[ghost-daemon] Accessibility permissions OK")

        // 2. Build initial screen state
        print("[ghost-daemon] Building initial screen state...")
        stateManager.refresh()
        let state = stateManager.getState()
        print("[ghost-daemon] Found \(state.apps.count) apps")
        if let front = state.frontmostApp {
            print("[ghost-daemon] Frontmost: \(front.name) (\(front.windows.count) windows)")
        }

        // 3. Start observing AX notifications
        print("[ghost-daemon] Starting accessibility observers...")
        systemObserver.startObserving()
        // Also observe the frontmost app specifically
        if let front = state.frontmostApp {
            systemObserver.observeApp(pid: front.pid)
        }
        print("[ghost-daemon] Observers active")

        // 4. Start IPC server
        print("[ghost-daemon] Starting IPC server...")
        try ipcServer.start()

        print("[ghost-daemon] Ghost OS daemon is running.")
        print("[ghost-daemon] Socket: \(IPCServer.defaultSocketPath())")
        print("[ghost-daemon] Press Ctrl+C to stop.")
    }

    /// Stop the daemon cleanly
    public func stop() {
        print("[ghost-daemon] Shutting down...")
        systemObserver.stopObserving()
        ipcServer.stop()
        print("[ghost-daemon] Goodbye.")
    }

    // MARK: - Direct API (for CLI in-process mode)

    /// Get current state without going through IPC
    public func getState() -> ScreenState {
        stateManager.refresh()
        return stateManager.getState()
    }

    /// Find elements without going through IPC
    public func findElements(query: String, role: String? = nil, app: String? = nil) -> [ElementNode] {
        stateManager.refresh()
        return stateManager.findElements(query: query, role: role, appName: app)
    }

    /// Dump the element tree for an app (for `ghost tree`)
    public func getTree(app: String? = nil, depth: Int = 5) -> ElementNode? {
        stateManager.refresh()
        return stateManager.getTree(appName: app, depth: depth)
    }

    /// Execute an action without going through IPC
    public func execute(action: String, params: RPCParams) -> RPCResponse {
        let request = RPCRequest(method: action, params: params, id: 0)
        return rpcHandler.dispatch(request)
    }

    /// Check accessibility permissions
    public func checkPermissions() -> Bool {
        let status = getPermissionsStatus()
        return status.canUseAccessibility
    }
}
