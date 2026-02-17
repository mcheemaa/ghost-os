// StateManager.swift — Maintains continuous screen awareness

import AppKit
import ApplicationServices
import AXorcist
import CoreGraphics
import Foundation

/// StateManager is the core of Ghost OS's "Eyes" — it maintains a continuously
/// updated semantic model of what's on screen by combining:
/// 1. NSWorkspace for app enumeration
/// 2. CGWindowList for reliable window enumeration (works for all apps)
/// 3. AXorcist for element tree traversal (accessibility tree reading)
@MainActor
public final class StateManager {
    // MARK: - State

    private var currentState: ScreenState
    private var previousState: ScreenState?
    private(set) var lastDiff: StateDiff?
    private var stateVersion: UInt64 = 0

    // Apps to ignore (system services, background daemons)
    private let ignoredBundleIds: Set<String> = [
        "com.apple.loginwindow",
        "com.apple.dock",
        "com.apple.WindowManager",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.Spotlight",
    ]

    // MARK: - Init

    public init() {
        self.currentState = ScreenState(
            timestamp: Date(),
            frontmostApp: nil,
            focusedElement: nil,
            apps: []
        )
    }

    // MARK: - Public API

    /// Get the current screen state
    public func getState() -> ScreenState {
        currentState
    }

    /// Get the most recent state diff (what changed since last refresh)
    public func getDiff() -> StateDiff? {
        lastDiff
    }

    /// Get state for a specific app only
    public func getState(forApp appName: String) -> AppInfo? {
        currentState.apps.first { $0.name.localizedCaseInsensitiveContains(appName) }
    }

    /// Find elements matching a query across an app's element tree
    public func findElements(
        query: String,
        role: String? = nil,
        appName: String? = nil
    ) -> [ElementNode] {
        let targetApp = appName ?? currentState.frontmostApp?.name
        guard let app = targetApp else { return [] }
        guard let appInfo = currentState.apps.first(where: {
            $0.name.localizedCaseInsensitiveContains(app)
        }) else { return [] }

        // Walk the app's element tree using AXorcist's comprehensive children()
        let axApp = AXUIElementCreateApplication(appInfo.pid)
        let appElement = Element(axApp)
        let root = ElementNode.from(appElement, depth: 8, maxChildren: 200)
        return searchTree(root, query: query, role: role)
    }

    /// Dump the raw element tree for an app (for `ghost tree`)
    public func getTree(appName: String? = nil, depth: Int = 5) -> ElementNode? {
        let targetApp = appName ?? currentState.frontmostApp?.name
        guard let app = targetApp else { return nil }
        guard let appInfo = currentState.apps.first(where: {
            $0.name.localizedCaseInsensitiveContains(app)
        }) else { return nil }

        let axApp = AXUIElementCreateApplication(appInfo.pid)
        let appElement = Element(axApp)
        return ElementNode.from(appElement, depth: depth, maxChildren: 200)
    }

    /// Refresh the full state (called on startup and on major events)
    public func refresh() {
        let workspace = NSWorkspace.shared
        let runningApps = workspace.runningApplications
        let frontApp = workspace.frontmostApplication

        // Get ALL on-screen windows via CGWindowList — this is reliable
        // for all apps regardless of focus state
        let cgWindows = getCGWindows()

        var apps: [AppInfo] = []

        for app in runningApps {
            guard app.activationPolicy == .regular else { continue }
            guard let bundleId = app.bundleIdentifier,
                  !ignoredBundleIds.contains(bundleId) else { continue }

            let name = app.localizedName ?? app.bundleIdentifier ?? "Unknown"
            let pid = app.processIdentifier
            let isActive = pid == frontApp?.processIdentifier

            // Get windows from CGWindowList (reliable for all apps)
            // then enrich with AX data where available
            let windows = buildWindows(pid: pid, cgWindows: cgWindows)

            apps.append(AppInfo(
                name: name,
                bundleId: bundleId,
                pid: pid,
                isActive: isActive,
                windows: windows
            ))
        }

        // Read focused element from the frontmost app
        var focusedNode: ElementNode? = nil
        if let front = frontApp {
            let axApp = AXUIElementCreateApplication(front.processIdentifier)
            let appElement = Element(axApp)
            if let focused = appElement.focusedUIElement() {
                focusedNode = ElementNode.from(focused, depth: 1, maxChildren: 10)
            }
        }

        let frontAppInfo = apps.first { $0.isActive }

        let newState = ScreenState(
            timestamp: Date(),
            frontmostApp: frontAppInfo,
            focusedElement: focusedNode,
            apps: apps
        )
        self.lastDiff = computeDiff(from: currentState, to: newState)
        self.previousState = currentState
        self.currentState = newState
        self.stateVersion += 1
    }

    /// Lightweight update: just refresh the frontmost app and focused element
    public func refreshFocus() {
        let workspace = NSWorkspace.shared
        guard let front = workspace.frontmostApplication else { return }

        // Update which app is active
        var updatedApps = currentState.apps.map { app -> AppInfo in
            AppInfo(
                name: app.name,
                bundleId: app.bundleId,
                pid: app.pid,
                isActive: app.pid == front.processIdentifier,
                windows: app.windows
            )
        }

        // If the frontmost app isn't in our list, add it
        let frontPid = front.processIdentifier
        if !updatedApps.contains(where: { $0.pid == frontPid }) {
            let name = front.localizedName ?? front.bundleIdentifier ?? "Unknown"
            let cgWindows = getCGWindows()
            let windows = buildWindows(pid: frontPid, cgWindows: cgWindows)
            updatedApps.append(AppInfo(
                name: name,
                bundleId: front.bundleIdentifier,
                pid: frontPid,
                isActive: true,
                windows: windows
            ))
        }

        // Read focused element
        let axApp = AXUIElementCreateApplication(frontPid)
        let appElement = Element(axApp)
        var focusedNode: ElementNode? = nil
        if let focused = appElement.focusedUIElement() {
            focusedNode = ElementNode.from(focused, depth: 1, maxChildren: 10)
        }

        let frontAppInfo = updatedApps.first { $0.isActive }

        let newState = ScreenState(
            timestamp: Date(),
            frontmostApp: frontAppInfo,
            focusedElement: focusedNode,
            apps: updatedApps
        )
        self.lastDiff = computeDiff(from: currentState, to: newState)
        self.previousState = currentState
        self.currentState = newState
        self.stateVersion += 1
    }

    /// Update windows for a specific app (after window create/move/resize)
    public func refreshApp(pid: pid_t) {
        guard let appIdx = currentState.apps.firstIndex(where: { $0.pid == pid }) else { return }

        let cgWindows = getCGWindows()
        let windows = buildWindows(pid: pid, cgWindows: cgWindows)
        let old = currentState.apps[appIdx]
        var updatedApps = currentState.apps
        updatedApps[appIdx] = AppInfo(
            name: old.name,
            bundleId: old.bundleId,
            pid: old.pid,
            isActive: old.isActive,
            windows: windows
        )

        let newState = ScreenState(
            timestamp: Date(),
            frontmostApp: updatedApps.first { $0.isActive },
            focusedElement: currentState.focusedElement,
            apps: updatedApps
        )
        self.lastDiff = computeDiff(from: currentState, to: newState)
        self.previousState = currentState
        self.currentState = newState
        self.stateVersion += 1
    }

    // MARK: - Window Enumeration via CGWindowList

    /// Raw window info from CGWindowList
    private struct CGWindowInfo {
        let pid: pid_t
        let title: String?
        let bounds: CGRect
        let layer: Int
        let isOnScreen: Bool
    }

    /// Get all windows via CoreGraphics — works for ALL apps, including other Spaces
    private func getCGWindows() -> [CGWindowInfo] {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return [] }

        return windowList.compactMap { dict -> CGWindowInfo? in
            guard let pid = dict[kCGWindowOwnerPID] as? Int32 else { return nil }
            let title = dict[kCGWindowName] as? String
            let layer = dict[kCGWindowLayer] as? Int ?? 0
            let isOnScreen = dict[kCGWindowIsOnscreen] as? Bool ?? true

            // Skip menu bar, system overlays, and other non-standard layers
            guard layer == 0 else { return nil }

            var bounds = CGRect.zero
            if let boundsDict = dict[kCGWindowBounds] as? [String: CGFloat] {
                bounds = CGRect(
                    x: boundsDict["X"] ?? 0,
                    y: boundsDict["Y"] ?? 0,
                    width: boundsDict["Width"] ?? 0,
                    height: boundsDict["Height"] ?? 0
                )
            }

            // Skip zero-size windows (invisible system windows)
            guard bounds.width > 0 && bounds.height > 0 else { return nil }

            return CGWindowInfo(
                pid: pid,
                title: title,
                bounds: bounds,
                layer: layer,
                isOnScreen: isOnScreen
            )
        }
    }

    /// Build WindowInfo array by combining AX and CGWindowList data.
    /// Strategy: AX windows are primary (they represent real user windows).
    /// CGWindowList is fallback for apps where AX returns nothing.
    private func buildWindows(pid: pid_t, cgWindows: [CGWindowInfo]) -> [WindowInfo] {
        let axApp = AXUIElementCreateApplication(pid)
        let appElement = Element(axApp)
        let axWindows = appElement.windows() ?? []

        // AX windows are authoritative — they represent actual app windows
        if !axWindows.isEmpty {
            return axWindows.compactMap { win -> WindowInfo? in
                let title = win.title()
                let pos = win.position()
                let sz = win.size()
                let isMain = win.attribute(Attribute<Bool>.main) ?? false
                let isFocused = win.isFocused() ?? false
                let isMinimized = win.attribute(Attribute<Bool>.minimized) ?? false

                // Enrich with CG bounds if AX position/size is missing
                var position = pos.map { CGPointCodable($0) }
                var size = sz.map { CGSizeCodable($0) }
                if position == nil || size == nil {
                    let matchingCG = cgWindows.first {
                        $0.pid == pid && $0.title == title
                    }
                    if let cg = matchingCG {
                        position = position ?? CGPointCodable(cg.bounds.origin)
                        size = size ?? CGSizeCodable(cg.bounds.size)
                    }
                }

                return WindowInfo(
                    title: title,
                    position: position,
                    size: size,
                    isMain: isMain,
                    isFocused: isFocused,
                    isMinimized: isMinimized
                )
            }
        }

        // Fallback: use CGWindowList for apps where AX returns no windows
        // Filter to on-screen windows only to avoid invisible system windows
        let appCGWindows = cgWindows.filter { $0.pid == pid && $0.isOnScreen }
        return appCGWindows.map { cg in
            WindowInfo(
                title: cg.title,
                position: CGPointCodable(cg.bounds.origin),
                size: CGSizeCodable(cg.bounds.size),
                isMain: false,
                isFocused: false,
                isMinimized: false
            )
        }
    }

    // MARK: - State Diffing

    /// Compute the diff between two screen states
    private func computeDiff(from old: ScreenState, to new: ScreenState) -> StateDiff {
        var changes: [StateChange] = []

        let oldAppNames = Set(old.apps.map { $0.name })
        let newAppNames = Set(new.apps.map { $0.name })

        // App launched / quit
        for name in newAppNames.subtracting(oldAppNames) {
            changes.append(.appLaunched(name: name))
        }
        for name in oldAppNames.subtracting(newAppNames) {
            changes.append(.appQuit(name: name))
        }

        // Active app changed
        if let newFront = new.frontmostApp,
           old.frontmostApp?.name != newFront.name {
            changes.append(.appActivated(name: newFront.name))
        }

        // Window changes per app (only for apps present in both states)
        let oldAppsByName = Dictionary(old.apps.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        for newApp in new.apps {
            guard let oldApp = oldAppsByName[newApp.name] else { continue }

            let oldTitles = oldApp.windows.map { $0.title }
            let newTitles = newApp.windows.map { $0.title }

            // Use multisets for window comparison (apps can have multiple windows with same title)
            var oldTitleCounts: [String: Int] = [:]
            for t in oldTitles {
                let key = t ?? ""
                oldTitleCounts[key, default: 0] += 1
            }
            var newTitleCounts: [String: Int] = [:]
            for t in newTitles {
                let key = t ?? ""
                newTitleCounts[key, default: 0] += 1
            }

            // Windows opened (in new but not old)
            for (title, count) in newTitleCounts {
                let oldCount = oldTitleCounts[title] ?? 0
                for _ in 0..<max(0, count - oldCount) {
                    changes.append(.windowOpened(app: newApp.name, title: title.isEmpty ? nil : title))
                }
            }

            // Windows closed (in old but not new)
            for (title, count) in oldTitleCounts {
                let newCount = newTitleCounts[title] ?? 0
                for _ in 0..<max(0, count - newCount) {
                    changes.append(.windowClosed(app: newApp.name, title: title.isEmpty ? nil : title))
                }
            }

        }

        // Focus changed
        if let newFocused = new.focusedElement {
            let oldFocusId = old.focusedElement?.id
            if newFocused.id != oldFocusId {
                let appName = new.frontmostApp?.name ?? "unknown"
                let label = newFocused.label.flatMap({ $0.isEmpty ? nil : $0 })
                let desc = label != nil ? "\(newFocused.role) \"\(label!)\"" : newFocused.role
                changes.append(.focusChanged(app: appName, element: desc))
            }
        }

        return StateDiff(timestamp: Date(), changes: changes)
    }

    // MARK: - Element Search

    private func searchTree(_ node: ElementNode, query: String, role: String?) -> [ElementNode] {
        var results: [ElementNode] = []

        // Normalize role matching: accept both "button" and "AXButton"
        let matchesRole: Bool
        if let role = role {
            let normalizedRole =
                role.hasPrefix("AX")
                ? role : "AX" + role.prefix(1).uppercased() + role.dropFirst()
            matchesRole =
                node.role.caseInsensitiveCompare(normalizedRole) == .orderedSame
                || node.role.caseInsensitiveCompare(role) == .orderedSame
        } else {
            matchesRole = true
        }
        let matchesQuery =
            query.isEmpty
            || node.label?.localizedCaseInsensitiveContains(query) == true
            || node.value?.localizedCaseInsensitiveContains(query) == true
            || node.id.localizedCaseInsensitiveContains(query)

        if matchesRole && matchesQuery {
            results.append(node)
        }

        if let children = node.children {
            for child in children {
                results.append(contentsOf: searchTree(child, query: query, role: role))
            }
        }

        return results
    }
}
