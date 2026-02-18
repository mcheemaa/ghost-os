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

    /// Get the content tree for an app — rooted at AXWebArea (web apps) or focused window (native).
    /// This skips menus and chrome, giving SmartResolver access to the actual page content
    /// with a deep enough depth budget to reach interactive elements.
    public func getContentTree(appName: String? = nil, depth: Int = 15) -> ElementNode? {
        let targetApp = appName ?? currentState.frontmostApp?.name
        guard let app = targetApp else { return nil }
        guard let appInfo = currentState.apps.first(where: {
            $0.name.localizedCaseInsensitiveContains(app)
        }) else { return nil }

        guard let contentRoot = findContentRoot(pid: appInfo.pid) else { return nil }
        var visited = Set<UInt>()
        return ElementNode.from(contentRoot, depth: depth, maxChildren: 200, visited: &visited)
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

    // MARK: - Deep Content Reading

    /// Roles to skip when searching for content — menus are noise for content reading
    private static let skipRoles: Set<String> = [
        "AXMenuBar", "AXMenu", "AXMenuItem", "AXMenuBarItem",
    ]

    /// Roles that carry readable text content
    private static let textRoles: Set<String> = [
        "AXStaticText", "AXHeading", "AXLink", "AXTextField", "AXTextArea",
        "AXButton", "AXCell", "AXImage", "AXRow", "AXCheckBox", "AXRadioButton",
        "AXComboBox", "AXPopUpButton", "AXTable", "AXList", "AXGroup",
    ]

    /// Find the content root for an app — skips menus, finds web area or focused window.
    /// This is the key insight: search from the CONTENT root, not the app root.
    private func findContentRoot(pid: pid_t) -> Element? {
        let axApp = AXUIElementCreateApplication(pid)
        let appElement = Element(axApp)

        // Strategy 1: Find AXWebArea (web apps like Gmail, Slack web, etc.)
        if let webArea = findElementByRole(appElement, role: "AXWebArea", maxDepth: 8) {
            return webArea
        }

        // Strategy 2: Find the focused window's content
        if let focusedWindow = appElement.focusedWindow() {
            return focusedWindow
        }

        // Strategy 3: Find the main window
        if let windows = appElement.windows(), let mainWindow = windows.first {
            return mainWindow
        }

        // Fallback: use the app element itself
        return appElement
    }

    /// Walk the AX tree to find an element with a specific role
    private func findElementByRole(_ element: Element, role: String, maxDepth: Int) -> Element? {
        if maxDepth <= 0 { return nil }
        if element.role() == role { return element }

        guard let children = element.children() else { return nil }
        for child in children.prefix(50) {
            // Skip menus when searching for content
            let childRole = child.role() ?? ""
            if Self.skipRoles.contains(childRole) { continue }

            if let found = findElementByRole(child, role: role, maxDepth: maxDepth - 1) {
                return found
            }
        }
        return nil
    }

    /// Roles that are layout-only containers — they don't carry semantic meaning
    /// and shouldn't consume depth budget when empty. These are CSS scaffolding
    /// that leaked into the accessibility tree (wrapper divs, layout containers, etc.).
    private static let layoutRoles: Set<String> = [
        "AXGroup", "AXGenericElement", "AXLayoutArea", "AXLayoutItem",
        "AXScrollArea", "AXSplitGroup", "AXSection", "AXDiv",
    ]

    /// Read content from an app — extracts all readable text in document order.
    /// Returns structured content items that an agent can understand.
    ///
    /// Uses **semantic depth** instead of DOM depth: empty layout containers (AXGroup
    /// wrappers from CSS divs) don't consume depth budget. Only nodes with actual
    /// content (text, buttons, headings, interactive elements) cost a depth point.
    /// This lets us reach deeply nested content (Amazon products at 30+ DOM levels,
    /// Slack messages, Gmail threads) with a modest depth budget of 25.
    public func readContent(appName: String? = nil, maxItems: Int = 500, maxDepth: Int = 20) -> [ContentItem] {
        let targetApp = appName ?? currentState.frontmostApp?.name
        guard let app = targetApp else { return [] }
        guard let appInfo = currentState.apps.first(where: {
            $0.name.localizedCaseInsensitiveContains(app)
        }) else { return [] }

        guard let contentRoot = findContentRoot(pid: appInfo.pid) else { return [] }

        var context = ContentExtractionContext(
            maxItems: maxItems,
            semanticDepthBudget: 25,
            deadline: Date().addingTimeInterval(5.0) // safety time budget
        )
        extractContent(contentRoot, semanticDepth: 0, context: &context)
        return context.items
    }

    /// Mutable context passed through content extraction to track limits.
    private struct ContentExtractionContext {
        var items: [ContentItem] = []
        var visited: Set<UInt> = []
        let maxItems: Int
        let semanticDepthBudget: Int
        let deadline: Date

        var shouldStop: Bool {
            items.count >= maxItems || Date() > deadline
        }
    }

    /// Check if an element is a semantically empty layout container.
    /// These are CSS wrapper divs that leaked into the AX tree — no title, no desc,
    /// no value, not interactive. They should be "tunneled through" without costing
    /// depth budget.
    private func isEmptyLayoutContainer(role: String, title: String?, desc: String?, value: String?) -> Bool {
        guard Self.layoutRoles.contains(role) else { return false }
        let titleEmpty = title == nil || title!.isEmpty
        let descEmpty = desc == nil || desc!.isEmpty
        let valueEmpty = value == nil || value!.isEmpty
        return titleEmpty && descEmpty && valueEmpty
    }

    /// Recursively extract readable content from an element tree.
    /// Uses semantic depth: empty layout containers (AXGroup, etc.) are tunneled
    /// through at zero cost. Only nodes with actual content consume depth budget.
    /// Also limited by maxItems and a time budget as safety nets.
    private func extractContent(
        _ element: Element,
        semanticDepth: Int,
        context: inout ContentExtractionContext
    ) {
        if context.shouldStop { return }
        if semanticDepth > context.semanticDepthBudget { return }

        // Cycle detection
        let hash = CFHash(element.underlyingElement)
        guard !context.visited.contains(hash) else { return }
        context.visited.insert(hash)

        let role = element.role() ?? "Unknown"

        // Skip menus entirely
        if Self.skipRoles.contains(role) { return }

        // Extract text from this element
        let title = element.title()
        let desc = element.descriptionText()

        // Read AXValue directly via raw API — AXorcist's generic value() returns nil
        // for Chrome's AXStaticText due to Attribute<Any> type mismatch, but the raw
        // AXUIElementCopyAttributeValue correctly returns the text as CFString.
        var value: String? = nil
        var rawVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(element.underlyingElement, kAXValueAttribute as CFString, &rawVal) == .success,
           let cfVal = rawVal {
            if let str = cfVal as? String, !str.isEmpty {
                value = str
            } else {
                // Fallback: try String(describing:) for non-string value types
                let s = String(describing: cfVal).trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty && s != "nil" {
                    value = s
                }
            }
        }

        // If still no value, try parameterized text attributes
        // (some elements store text only in visibleCharacterRange + stringForRange)
        let titleEmpty = title == nil || title!.isEmpty
        let descEmpty = desc == nil || desc!.isEmpty
        let valueEmpty = value == nil || value!.isEmpty
        if titleEmpty && descEmpty && valueEmpty {
            if let range = element.visibleCharacterRange(), range.length > 0 {
                value = element.string(forRange: range)
            } else if let numChars = element.numberOfCharacters(), numChars > 0 {
                let fullRange = CFRange(location: 0, length: Int(numChars))
                value = element.string(forRange: fullRange)
            }
        }

        // Determine if this node is a semantically empty container (tunnel through it)
        let isTunnel = isEmptyLayoutContainer(role: role, title: title, desc: desc, value: value)

        let text = title ?? desc
        let hasContent = (text != nil && !text!.isEmpty) || (value != nil && !value!.isEmpty)

        if hasContent && Self.textRoles.contains(role) {
            let displayText: String
            if let text = text, let value = value, !value.isEmpty && value != text {
                displayText = "\(text): \(value)"
            } else {
                displayText = text ?? value ?? ""
            }

            // Skip shallow AXGroup with long text (aggregated children text)
            if role == "AXGroup" && displayText.count > 150 && semanticDepth < 10 {
                // Still recurse into children below
            } else {
            let contentType: String
            switch role {
            case "AXHeading": contentType = "heading"
            case "AXLink": contentType = "link"
            case "AXButton", "AXPopUpButton": contentType = "button"
            case "AXTextField", "AXTextArea", "AXComboBox": contentType = "input"
            case "AXImage": contentType = "image"
            case "AXCell": contentType = "cell"
            case "AXRow": contentType = "row"
            case "AXCheckBox", "AXRadioButton": contentType = "control"
            case "AXTable", "AXList": contentType = "list"
            case "AXGroup": contentType = "group"
            default: contentType = "text"
            }

            // Truncate very long text
            let truncated = displayText.count > 500
                ? String(displayText.prefix(500)) + "..."
                : displayText

            // Deduplicate: skip if the previous item has the exact same text
            let isDuplicate = context.items.last.map { $0.text == truncated } ?? false
            if !isDuplicate && !truncated.isEmpty {
                context.items.append(ContentItem(
                    type: contentType,
                    text: truncated,
                    role: role,
                    depth: semanticDepth
                ))
            }
            } // end else (not long AXGroup)
        }

        // Recurse into children
        // Semantic depth: empty layout containers cost 0, everything else costs 1
        let childDepth = isTunnel ? semanticDepth : semanticDepth + 1
        guard let children = element.children() else { return }
        for child in children.prefix(100) {
            if context.shouldStop { return }
            extractContent(child, semanticDepth: childDepth, context: &context)
        }
    }

    // MARK: - Context (Situational Awareness)

    /// Get rich context about the current app — everything an AI agent needs to know.
    /// Works across all app types: web (Chrome, Firefox), Electron (Slack, VS Code),
    /// native (Finder, System Settings), and terminal apps.
    public func getContext(appName: String? = nil) -> ContextInfo? {
        let targetApp = appName ?? currentState.frontmostApp?.name
        guard let app = targetApp else { return nil }
        guard let appInfo = currentState.apps.first(where: {
            $0.name.localizedCaseInsensitiveContains(app)
        }) else { return nil }

        let axApp = AXUIElementCreateApplication(appInfo.pid)
        let appElement = Element(axApp)

        // 1. Window title
        let windowTitle: String?
        if let focusedWindow = appElement.focusedWindow() {
            windowTitle = focusedWindow.title()
        } else if let windows = appElement.windows(), let first = windows.first {
            windowTitle = first.title()
        } else {
            windowTitle = appInfo.windows.first?.title
        }

        // 2. URL — check AXWebArea first (Chrome, Firefox, Safari), then AXDocument (native apps)
        var url: String? = nil
        var pageTitle: String? = nil
        if let webArea = findElementByRole(appElement, role: "AXWebArea", maxDepth: 8) {
            if let webUrl = webArea.url() {
                url = webUrl.absoluteString
            }
            // Web area title is often the page title
            let webTitle = webArea.title()
            if let t = webTitle, !t.isEmpty {
                pageTitle = t
            }
        }
        // Fallback: AXDocument attribute on the app or focused window
        if url == nil {
            if let docUrl = readDocumentAttribute(appElement) {
                url = docUrl
            } else if let focusedWindow = appElement.focusedWindow() {
                if let docUrl = readDocumentAttribute(focusedWindow) {
                    url = docUrl
                }
            }
        }

        // 3. Focused element info
        var focusInfo: FocusInfo? = nil
        if let focused = appElement.focusedUIElement() {
            let role = focused.role() ?? "Unknown"
            let label = focused.title() ?? focused.descriptionText()
            var val: String? = nil
            var focusedRawVal: CFTypeRef?
            if AXUIElementCopyAttributeValue(focused.underlyingElement, kAXValueAttribute as CFString, &focusedRawVal) == .success,
               let cfVal = focusedRawVal {
                if let str = cfVal as? String, !str.isEmpty {
                    val = str
                } else {
                    let s = String(describing: cfVal).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !s.isEmpty && s != "nil" { val = s }
                }
            }
            let editable = focused.isEditable() ?? false
            focusInfo = FocusInfo(role: role, label: label, value: val, isEditable: editable)
        }

        // 4. Interactive elements — buttons, links, text fields near the user's focus
        var interactiveDescs: [String] = []
        let contentRoot = findContentRoot(pid: appInfo.pid)
        if let root = contentRoot {
            var visited = Set<UInt>()
            collectInteractiveElements(root, descriptions: &interactiveDescs, visited: &visited, maxDepth: 10, depth: 0)
        }

        // 5. Window titles as "tabs" — each window title listed
        let windowTabs = appInfo.windows.compactMap { win -> String? in
            guard let title = win.title, !title.isEmpty else { return nil }
            if win.isMinimized { return nil }
            return title
        }

        return ContextInfo(
            app: appInfo.name,
            bundleId: appInfo.bundleId,
            window: windowTitle,
            url: url,
            pageTitle: pageTitle,
            focused: focusInfo,
            interactiveElements: interactiveDescs,
            windowTabs: windowTabs
        )
    }

    /// Read AXDocument attribute from an element (returns file path or URL string)
    private func readDocumentAttribute(_ element: Element) -> String? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            element.underlyingElement,
            "AXDocument" as CFString,
            &value
        )
        guard error == .success, let cfValue = value else { return nil }
        if let str = cfValue as? String, !str.isEmpty {
            return str
        }
        return nil
    }

    /// Collect short descriptions of interactive elements (buttons, links, text fields)
    private func collectInteractiveElements(
        _ element: Element,
        descriptions: inout [String],
        visited: inout Set<UInt>,
        maxDepth: Int,
        depth: Int
    ) {
        if depth > maxDepth || descriptions.count >= 30 { return }

        let hash = CFHash(element.underlyingElement)
        guard !visited.contains(hash) else { return }
        visited.insert(hash)

        let role = element.role() ?? ""

        // Skip menus
        if Self.skipRoles.contains(role) { return }

        // Check if interactive
        let interactiveRoles: Set<String> = [
            "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXComboBox",
            "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXMenuItem",
            "AXSlider", "AXIncrementor", "AXTab"
        ]

        if interactiveRoles.contains(role) {
            let label = element.title() ?? element.descriptionText() ?? ""
            if !label.isEmpty {
                let shortRole = role.replacingOccurrences(of: "AX", with: "").lowercased()
                descriptions.append("\(shortRole): \(label)")
            }
        }

        // Recurse
        guard let children = element.children() else { return }
        for child in children.prefix(50) {
            collectInteractiveElements(child, descriptions: &descriptions, visited: &visited, maxDepth: maxDepth, depth: depth + 1)
        }
    }

    /// Deep find — searches from the content root (skipping menus) with fresh depth budget.
    /// This finds elements that the regular findElements misses because they're too deep.
    public func findElementsDeep(
        query: String,
        role: String? = nil,
        appName: String? = nil,
        maxDepth: Int = 15
    ) -> [ElementNode] {
        let targetApp = appName ?? currentState.frontmostApp?.name
        guard let app = targetApp else { return [] }
        guard let appInfo = currentState.apps.first(where: {
            $0.name.localizedCaseInsensitiveContains(app)
        }) else { return [] }

        guard let contentRoot = findContentRoot(pid: appInfo.pid) else { return [] }

        var visited = Set<UInt>()
        let root = ElementNode.from(contentRoot, depth: maxDepth, maxChildren: 100, visited: &visited)
            ?? ElementNode(
                id: "empty", role: "Unknown", label: nil, value: nil,
                roleDescription: nil, position: nil, size: nil,
                isInteractive: false, isEnabled: false, isFocused: false,
                actions: nil, children: nil
            )
        return searchTree(root, query: query, role: role)
    }

    // MARK: - App Resolution

    /// Resolve an app by name — extracted from the repeated pattern used everywhere.
    public func resolveApp(_ appName: String? = nil) -> AppInfo? {
        let targetApp = appName ?? currentState.frontmostApp?.name
        guard let app = targetApp else { return nil }
        return currentState.apps.first(where: {
            $0.name.localizedCaseInsensitiveContains(app)
        })
    }

    // MARK: - Live Element Search (for AX-native actions)

    /// Find a live Element by fuzzy matching — searches content tree first, falls back to full tree.
    /// Returns the AXUIElement handle for AX-native actions (performAction, setValue, etc.).
    ///
    /// Uses semantic depth: empty layout containers (AXGroup wrappers from CSS divs) are
    /// tunneled through at zero cost, so buttons at DOM level 30+ are reachable.
    public func findLiveElement(query: String, role: String? = nil, appName: String? = nil) -> Element? {
        guard let appInfo = resolveApp(appName) else { return nil }

        // Normalize role: "button" → "AXButton"
        let normalizedRole: String?
        if let role = role {
            normalizedRole = role.hasPrefix("AX") ? role : "AX" + role.prefix(1).uppercased() + role.dropFirst()
        } else {
            normalizedRole = nil
        }

        let queryLower = query.lowercased().trimmingCharacters(in: .whitespaces)
        let deadline = Date().addingTimeInterval(2.0) // 2-second time budget

        // Strategy 1: Search content root first (in-page elements like buttons, text fields)
        if let contentRoot = findContentRoot(pid: appInfo.pid) {
            var ctx = LiveSearchContext(visited: [], deadline: deadline)
            searchLiveTree(
                contentRoot, queryLower: queryLower, role: normalizedRole,
                semanticDepth: 0, domDepth: 0, context: &ctx
            )
            if let found = ctx.bestMatch?.element {
                return found
            }
        }

        // Strategy 2: Fall back to full app tree (menus, toolbar, etc.)
        let axApp = AXUIElementCreateApplication(appInfo.pid)
        let appElement = Element(axApp)
        var ctx = LiveSearchContext(visited: [], deadline: deadline)
        searchLiveTree(
            appElement, queryLower: queryLower, role: normalizedRole,
            semanticDepth: 0, domDepth: 0, context: &ctx
        )
        return ctx.bestMatch?.element
    }

    /// Mutable context for live tree search.
    private struct LiveSearchContext {
        var visited: Set<UInt>
        let deadline: Date
        var bestMatch: (element: Element, score: Int)? = nil
        /// Semantic depth budget — only meaningful nodes cost a point.
        let semanticBudget: Int = 25
        /// Hard DOM depth cap — prevents pathological nesting from hanging.
        let domCap: Int = 50

        var shouldStop: Bool { Date() > deadline }
    }

    /// Walk a live Element tree with fuzzy matching and semantic depth.
    /// Empty layout containers (AXGroup, AXSection, etc. with no title/desc) are
    /// tunneled through at zero semantic cost, letting us reach buttons at DOM level 30+.
    /// Returns the best match above threshold via context.bestMatch.
    private func searchLiveTree(
        _ element: Element,
        queryLower: String,
        role: String?,
        semanticDepth: Int,
        domDepth: Int,
        context: inout LiveSearchContext
    ) {
        if context.shouldStop { return }
        if semanticDepth > context.semanticBudget { return }
        if domDepth > context.domCap { return }

        // Cycle detection
        let hash = CFHash(element.underlyingElement)
        guard !context.visited.contains(hash) else { return }
        context.visited.insert(hash)

        let elementRole = element.role() ?? ""

        // Skip menus
        if Self.skipRoles.contains(elementRole) { return }

        // Read title and desc once — used for both scoring AND tunnel detection
        let title = element.title() ?? ""
        let desc = element.descriptionText() ?? ""

        // Determine if this is an empty layout container (tunnel through at zero semantic cost)
        let isTunnel = Self.layoutRoles.contains(elementRole)
            && title.isEmpty && desc.isEmpty

        // Check role filter
        let roleMatches: Bool
        if let role = role {
            roleMatches = elementRole.caseInsensitiveCompare(role) == .orderedSame
        } else {
            roleMatches = true
        }

        // Score this element (reuse title/desc already read above)
        if roleMatches || role == nil {
            let titleLower = title.lowercased()
            let descLower = desc.lowercased()

            // Also check AXValue directly for Chrome AXStaticText (same fix as extractContent)
            var valueLower = ""
            if titleLower.isEmpty && descLower.isEmpty {
                var rawVal: CFTypeRef?
                if AXUIElementCopyAttributeValue(element.underlyingElement, kAXValueAttribute as CFString, &rawVal) == .success,
                   let str = rawVal as? String, !str.isEmpty {
                    valueLower = str.lowercased()
                }
            }

            var score = 0
            // Exact match
            if !titleLower.isEmpty && titleLower == queryLower {
                score = 100
            } else if !descLower.isEmpty && descLower == queryLower {
                score = 100
            } else if !valueLower.isEmpty && valueLower == queryLower {
                score = 100
            }
            // Trimmed match
            else if !titleLower.isEmpty && titleLower.trimmingCharacters(in: .whitespaces) == queryLower {
                score = 95
            }
            // Starts with
            else if !titleLower.isEmpty && titleLower.hasPrefix(queryLower) {
                score = 80
            } else if !descLower.isEmpty && descLower.hasPrefix(queryLower) {
                score = 80
            } else if !valueLower.isEmpty && valueLower.hasPrefix(queryLower) {
                score = 80
            }
            // Contains
            else if !titleLower.isEmpty && titleLower.contains(queryLower) {
                score = 60
            } else if !descLower.isEmpty && descLower.contains(queryLower) {
                score = 60
            } else if !valueLower.isEmpty && valueLower.contains(queryLower) {
                score = 60
            }

            // Role match bonus
            if score > 0 && role != nil && roleMatches {
                score += 20
            }

            // Interactivity bonus
            if score > 0 {
                let interactiveRoles: Set<String> = [
                    "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXComboBox",
                    "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXMenuItem",
                ]
                if interactiveRoles.contains(elementRole) {
                    score += 15
                }
            }

            if score >= 50 {
                if context.bestMatch == nil || score > context.bestMatch!.score {
                    context.bestMatch = (element, score)
                }
            }
        }

        // Recurse into children
        // Semantic depth: empty layout containers cost 0, everything else costs 1
        let childSemanticDepth = isTunnel ? semanticDepth : semanticDepth + 1
        guard let children = element.children() else { return }
        for child in children.prefix(100) {
            if context.shouldStop { return }
            searchLiveTree(
                child, queryLower: queryLower, role: role,
                semanticDepth: childSemanticDepth, domDepth: domDepth + 1,
                context: &context
            )
        }
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
