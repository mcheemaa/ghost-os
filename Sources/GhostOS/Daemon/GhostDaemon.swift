// GhostDaemon.swift — Main daemon lifecycle

import AXorcist
import Foundation

/// GhostDaemon is the top-level coordinator that ties together
/// StateManager, SystemObserver, ActionExecutor, and IPCServer.
/// Manages PID file, signal handling, and graceful shutdown.
@MainActor
public final class GhostDaemon {
    private let stateManager: StateManager
    private let systemObserver: SystemObserver
    private let actionExecutor: ActionExecutor
    private let rpcHandler: RPCHandler
    private let ipcServer: IPCServer

    private var sigintSource: (any DispatchSourceSignal)?
    private var sigtermSource: (any DispatchSourceSignal)?

    public init() {
        self.stateManager = StateManager()
        self.systemObserver = SystemObserver(stateManager: stateManager)
        self.actionExecutor = ActionExecutor(stateManager: stateManager)
        self.rpcHandler = RPCHandler(stateManager: stateManager, actionExecutor: actionExecutor)
        self.ipcServer = IPCServer(handler: rpcHandler)
    }

    // MARK: - PID file management

    private static func pidFilePath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.ghost-os/ghost.pid"
    }

    /// Write current process PID to the PID file
    private func writePIDFile() throws {
        let pidPath = GhostDaemon.pidFilePath()
        let dir = (pidPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )
        let pid = ProcessInfo.processInfo.processIdentifier
        try "\(pid)".write(toFile: pidPath, atomically: true, encoding: .utf8)
    }

    /// Remove the PID file
    private func removePIDFile() {
        let pidPath = GhostDaemon.pidFilePath()
        try? FileManager.default.removeItem(atPath: pidPath)
    }

    /// Read the PID from an existing PID file, or nil if none exists
    private static func readPIDFile() -> pid_t? {
        let pidPath = pidFilePath()
        guard let contents = try? String(contentsOfFile: pidPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(contents) else {
            return nil
        }
        return pid
    }

    /// Check whether a process with the given PID is alive
    private static func isProcessRunning(_ pid: pid_t) -> Bool {
        // kill with signal 0 checks existence without sending a signal
        return kill(pid, 0) == 0
    }

    /// Check if another daemon instance is already running.
    /// Returns the PID if running, nil otherwise.
    /// Cleans up stale PID files from crashed instances.
    public static func existingDaemonPID() -> pid_t? {
        guard let pid = readPIDFile() else {
            return nil
        }

        if isProcessRunning(pid) {
            return pid
        }

        // Stale PID file from a crashed daemon — clean it up
        try? FileManager.default.removeItem(atPath: pidFilePath())
        return nil
    }

    // MARK: - Signal handling

    /// Install signal handlers for graceful shutdown
    private func installSignalHandlers() {
        // Ignore the default signal behavior so DispatchSource can handle them
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler { [weak self] in
            guard let self = self else { return }
            print("\n[ghost-daemon] Received SIGINT")
            MainActor.assumeIsolated {
                self.stop()
            }
            exit(0)
        }
        sigint.resume()
        sigintSource = sigint

        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigterm.setEventHandler { [weak self] in
            guard let self = self else { return }
            print("[ghost-daemon] Received SIGTERM")
            MainActor.assumeIsolated {
                self.stop()
            }
            exit(0)
        }
        sigterm.resume()
        sigtermSource = sigterm
    }

    // MARK: - Daemon lifecycle

    /// Start the daemon: check for existing instance, check permissions,
    /// build initial state, start observing, start IPC, write PID file.
    public func start() throws {
        print("[ghost-daemon] Starting Ghost OS daemon...")

        // 0. Check if another daemon is already running
        if let existingPID = GhostDaemon.existingDaemonPID() {
            print("[ghost-daemon] ERROR: Another daemon is already running (PID \(existingPID))")
            print("[ghost-daemon] Stop it first, or run: kill \(existingPID)")
            throw GhostError.ipcError("Daemon already running (PID \(existingPID))")
        }

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
        if let front = state.frontmostApp {
            systemObserver.observeApp(pid: front.pid)
        }
        print("[ghost-daemon] Observers active")

        // 4. Start IPC server
        print("[ghost-daemon] Starting IPC server...")
        try ipcServer.start()

        // 5. Write PID file
        try writePIDFile()

        // 6. Install signal handlers for graceful shutdown
        installSignalHandlers()

        print("[ghost-daemon] Ghost OS daemon is running.")
        print("[ghost-daemon] Socket: \(IPCServer.defaultSocketPath())")
        print("[ghost-daemon] PID: \(ProcessInfo.processInfo.processIdentifier)")
        print("[ghost-daemon] Press Ctrl+C to stop.")
    }

    /// Stop the daemon cleanly: stop observers, IPC, remove PID file
    public func stop() {
        print("[ghost-daemon] Shutting down...")
        systemObserver.stopObserving()
        ipcServer.stop()
        removePIDFile()
        print("[ghost-daemon] Goodbye.")
    }

    // MARK: - Status check

    /// Check if a daemon is running. First checks PID file, then tries a socket ping.
    public static func isDaemonRunning() -> Bool {
        // Fast path: check PID file
        if let pid = readPIDFile(), isProcessRunning(pid) {
            return true
        }

        // Slow path: try connecting to the socket
        let request = RPCRequest(method: "ping", id: 0)
        if let response = try? IPCServer.sendRequest(request) {
            return response.error == nil
        }

        return false
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

    /// Get the content tree (AXWebArea or focused window), skipping menus.
    /// Use this for SmartResolver — it searches where users actually interact.
    public func getContentTree(app: String? = nil, depth: Int = 15) -> ElementNode? {
        stateManager.refresh()
        return stateManager.getContentTree(appName: app, depth: depth)
    }

    /// Execute an action without going through IPC
    public func execute(action: String, params: RPCParams) -> RPCResponse {
        let request = RPCRequest(method: action, params: params, id: 0)
        return rpcHandler.dispatch(request)
    }

    /// Read content from an app (for `ghost read`)
    public func readContent(app: String? = nil, maxItems: Int = 500) -> [ContentItem] {
        stateManager.refresh()
        return stateManager.readContent(appName: app, maxItems: maxItems)
    }

    /// Get rich context about the current app (for `ghost context`)
    public func getContext(app: String? = nil) -> ContextInfo? {
        stateManager.refresh()
        return stateManager.getContext(appName: app)
    }

    /// Deep find elements (skips menus, searches deeper)
    public func findElementsDeep(query: String, role: String? = nil, app: String? = nil, maxDepth: Int = 15) -> [ElementNode] {
        stateManager.refresh()
        return stateManager.findElementsDeep(query: query, role: role, appName: app, maxDepth: maxDepth)
    }

    // MARK: - Smart Actions (AX-native first)

    /// Smart click — AX-native first, synthetic fallback, returns context
    public func smartClick(query: String, role: String? = nil, app: String? = nil) -> ActionResult {
        stateManager.refresh()
        return actionExecutor.smartClick(query: query, role: role, appName: app)
    }

    /// Smart double-click — find element and double-click
    public func smartDoubleClick(query: String, role: String? = nil, app: String? = nil) -> ActionResult {
        stateManager.refresh()
        return actionExecutor.smartDoubleClick(query: query, role: role, appName: app)
    }

    /// Smart right-click — find element and right-click (context menu)
    public func smartRightClick(query: String, role: String? = nil, app: String? = nil) -> ActionResult {
        stateManager.refresh()
        return actionExecutor.smartRightClick(query: query, role: role, appName: app)
    }

    /// Smart type — setValue first, typeText fallback, returns context
    public func smartType(text: String, target: String? = nil, role: String? = nil, app: String? = nil) -> ActionResult {
        stateManager.refresh()
        return actionExecutor.smartType(text: text, target: target, role: role, appName: app)
    }

    /// Press key with context
    public func pressWithContext(key: String, app: String? = nil) -> ActionResult {
        return actionExecutor.pressWithContext(key: key, appName: app)
    }

    /// Hotkey with context
    public func hotkeyWithContext(keys: [String], app: String? = nil) -> ActionResult {
        return actionExecutor.hotkeyWithContext(keys: keys, appName: app)
    }

    /// Wait for a condition to be met
    public func wait(condition: String, value: String?, timeout: Double = 10.0, interval: Double = 0.5, app: String? = nil, baseline: ContextInfo? = nil) -> ActionResult {
        return actionExecutor.wait(condition: condition, value: value, timeout: timeout, interval: interval, appName: app, baseline: baseline)
    }

    /// Capture a screenshot of a window (async — uses ScreenCaptureKit)
    public func screenshot(app: String, windowTitle: String? = nil, fullResolution: Bool = false) async -> ScreenshotResult? {
        stateManager.refresh()
        guard let appInfo = stateManager.getState().apps.first(where: {
            $0.name.localizedCaseInsensitiveContains(app)
        }) else { return nil }
        return await ScreenCapture.captureWindow(pid: appInfo.pid, windowTitle: windowTitle, fullResolution: fullResolution)
    }

    /// Check accessibility permissions
    public func checkPermissions() -> Bool {
        let status = getPermissionsStatus()
        return status.canUseAccessibility
    }
}
