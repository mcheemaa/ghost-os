// ActionExecutor.swift — AX-native first action execution with synthetic fallback
//
// Strategy: Every action tries the AX-native path first (performAction, setValue),
// falls back to synthetic input (InputDriver), and returns post-action context.

import AppKit
import ApplicationServices
import AXorcist
import Foundation

/// ActionExecutor provides high-level action methods that combine element
/// finding (via StateManager) with action execution (via AXorcist).
/// Uses AX-native methods first, synthetic input as fallback.
@MainActor
public final class ActionExecutor {
    private let stateManager: StateManager

    public init(stateManager: StateManager) {
        self.stateManager = stateManager
    }

    // MARK: - Smart Click (AX-native first)

    /// Smart click — find the best matching element and act on it.
    /// Strategy: AX-native performAction(.press) first, synthetic click fallback.
    public func smartClick(query: String, role: String? = nil, appName: String? = nil) -> ActionResult {
        stateManager.refresh()

        // 1. Find the live element
        guard let element = stateManager.findLiveElement(query: query, role: role, appName: appName) else {
            return ActionResult(
                success: false,
                description: "No element matching '\(query)'\(appName.map { " in \($0)" } ?? "")",
                method: "none",
                context: stateManager.getContext(appName: appName)
            )
        }

        let label = element.title() ?? element.descriptionText() ?? query

        // 2. Try AX-native press (no focus needed, works on background apps)
        // Capture pre-action state to detect if AX press actually did something
        let preContext = stateManager.getContext(appName: appName)
        do {
            try element.performAction(.press)
            // Brief pause for the app to react
            usleep(300_000) // 300ms
            stateManager.refresh()
            let postContext = stateManager.getContext(appName: appName)

            // Check if something actually changed (focused element, window title, URL)
            let changed = contextDidChange(pre: preContext, post: postContext)
            if changed {
                return ActionResult(
                    success: true,
                    description: "Pressed '\(label)' via AX-native",
                    method: "ax-native",
                    context: postContext
                )
            }
            // AX press "succeeded" but nothing changed — fall through to synthetic
            // This happens with Chrome web content buttons that silently accept AX press
        } catch {
            // AX-native threw — fall through to synthetic
        }

        // 3. Fallback: auto-focus + synthetic click at element center
        if let appName = appName {
            autoFocus(appName: appName)
        }

        if let pos = element.position(), let size = element.size() {
            let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
            do {
                try InputDriver.click(at: center)
                usleep(150_000)
                stateManager.refresh()
                let ctx = stateManager.getContext(appName: appName)
                return ActionResult(
                    success: true,
                    description: "Clicked '\(label)' at (\(Int(center.x)),\(Int(center.y))) — synthetic fallback",
                    method: "synthetic",
                    context: ctx
                )
            } catch {
                return ActionResult(
                    success: false,
                    description: "Click failed for '\(label)': \(error)",
                    method: "synthetic",
                    context: stateManager.getContext(appName: appName)
                )
            }
        }

        // 4. Element found but no position — can't click
        return ActionResult(
            success: false,
            description: "Found '\(label)' but it has no screen position",
            method: "none",
            context: stateManager.getContext(appName: appName)
        )
    }

    // MARK: - Smart Type (AX-native first)

    /// Smart type — optionally find a target field, set its value using AX-native or typeText fallback.
    /// Strategy: setValue (instant, background) → typeText (char-by-char) → InputDriver (legacy)
    public func smartType(
        text: String,
        target: String? = nil,
        role: String? = nil,
        appName: String? = nil
    ) -> ActionResult {
        stateManager.refresh()

        // If a target field is specified, find it first
        if let target = target {
            let fieldRole = role ?? "AXTextField"
            guard let element = stateManager.findLiveElement(query: target, role: fieldRole, appName: appName) else {
                // Also try without role filter — some fields have unusual roles (AXTextArea, AXComboBox)
                if let element = stateManager.findLiveElement(query: target, role: nil, appName: appName) {
                    return typeIntoElement(element, text: text, label: target, appName: appName)
                }
                return ActionResult(
                    success: false,
                    description: "No field matching '\(target)'\(appName.map { " in \($0)" } ?? "")",
                    method: "none",
                    context: stateManager.getContext(appName: appName)
                )
            }
            return typeIntoElement(element, text: text, label: target, appName: appName)
        }

        // No target — type at current focus
        do {
            try Element.typeText(text, delay: 0.01)
            usleep(100_000)
            stateManager.refresh()
            return ActionResult(
                success: true,
                description: "Typed \(text.count) characters at current focus",
                method: "typeText",
                context: stateManager.getContext(appName: appName)
            )
        } catch {
            return ActionResult(
                success: false,
                description: "Type failed: \(error)",
                method: "typeText",
                context: stateManager.getContext(appName: appName)
            )
        }
    }

    /// Type text into a specific live element — tries setValue first, typeText fallback
    private func typeIntoElement(_ element: Element, text: String, label: String, appName: String?) -> ActionResult {
        // 1. Try AX-native setValue (instant, works from background on native apps)
        if element.isAttributeSettable(named: "AXValue") {
            let ok = element.setValue(text, forAttribute: "AXValue")
            if ok {
                usleep(150_000)
                // Verify: read the value back to check if it actually took
                let readBack = element.value().flatMap { v -> String? in
                    let s = String(describing: v).trimmingCharacters(in: .whitespacesAndNewlines)
                    return s.isEmpty || s == "nil" ? nil : s
                }
                if let readBack = readBack, readBack.contains(text.prefix(10)) {
                    stateManager.refresh()
                    let ctx = stateManager.getContext(appName: appName)
                    return ActionResult(
                        success: true,
                        description: "Set '\(label)' = '\(text.prefix(80))' via AX setValue",
                        method: "setValue",
                        context: ctx
                    )
                }
                // setValue returned true but value didn't stick (Chrome web fields)
                // Fall through to typeText
            }
        }

        // 2. Fallback: focus the element, then typeText char-by-char
        if let appName = appName {
            autoFocus(appName: appName)
        }

        // Focus the element via AX
        _ = element.setValue(true, forAttribute: "AXFocused")
        usleep(100_000) // 100ms for focus to take effect

        do {
            try element.typeText(text, delay: 0.01)
            usleep(100_000)
            stateManager.refresh()
            let ctx = stateManager.getContext(appName: appName)
            return ActionResult(
                success: true,
                description: "Typed \(text.count) chars into '\(label)' via typeText",
                method: "typeText",
                context: ctx
            )
        } catch {
            return ActionResult(
                success: false,
                description: "Type into '\(label)' failed: \(error)",
                method: "typeText",
                context: stateManager.getContext(appName: appName)
            )
        }
    }

    // MARK: - Press/Hotkey with Context

    /// Press a key and return post-action context
    public func pressWithContext(key: String, appName: String? = nil) -> ActionResult {
        guard let specialKey = SpecialKey(rawValue: key.lowercased()) else {
            return ActionResult(
                success: false,
                description: "Unknown key: '\(key)'. Valid: return, tab, escape, space, delete, up, down, left, right, etc.",
                method: "none",
                context: nil
            )
        }
        do {
            try InputDriver.tapKey(specialKey)
            usleep(150_000)
            stateManager.refresh()
            return ActionResult(
                success: true,
                description: "Pressed \(key)",
                method: "synthetic",
                context: stateManager.getContext(appName: appName)
            )
        } catch {
            return ActionResult(
                success: false,
                description: "Press failed: \(error)",
                method: "synthetic",
                context: stateManager.getContext(appName: appName)
            )
        }
    }

    /// Hotkey with post-action context
    public func hotkeyWithContext(keys: [String], appName: String? = nil) -> ActionResult {
        do {
            try InputDriver.hotkey(keys: keys)
            usleep(200_000)
            stateManager.refresh()
            return ActionResult(
                success: true,
                description: "Hotkey \(keys.joined(separator: "+"))",
                method: "synthetic",
                context: stateManager.getContext(appName: appName)
            )
        } catch {
            return ActionResult(
                success: false,
                description: "Hotkey failed: \(error)",
                method: "synthetic",
                context: stateManager.getContext(appName: appName)
            )
        }
    }

    // MARK: - Backward-compatible methods (still used by some paths)

    /// Click at specific coordinates (synthetic only, no AX-native equivalent)
    public func click(at point: CGPoint) throws -> String {
        try InputDriver.click(at: point)
        return "Clicked at (\(Int(point.x)), \(Int(point.y)))"
    }

    /// Click an element by label (legacy — uses synthetic click)
    public func click(target: String, appName: String? = nil) throws -> String {
        let elements = stateManager.findElements(query: target, role: nil, appName: appName)
        guard let element = elements.first else {
            throw GhostError.elementNotFound("No element matching '\(target)'")
        }
        guard let pos = element.position else {
            throw GhostError.noPosition("Element '\(target)' has no screen position")
        }
        let center = CGPoint(
            x: pos.x + (element.size?.width ?? 0) / 2,
            y: pos.y + (element.size?.height ?? 0) / 2
        )
        try InputDriver.click(at: center)
        return "Clicked '\(element.label ?? target)' at (\(Int(center.x)), \(Int(center.y)))"
    }

    /// Type text at the current focus (legacy)
    public func type(text: String, delay: TimeInterval = 0.01) throws -> String {
        try Element.typeText(text, delay: delay)
        return "Typed \(text.count) characters"
    }

    /// Press a special key (legacy)
    public func press(key: String) throws -> String {
        guard let specialKey = SpecialKey(rawValue: key.lowercased()) else {
            throw GhostError.invalidKey("Unknown key: '\(key)'. Valid: return, tab, escape, space, delete, up, down, left, right, etc.")
        }
        try InputDriver.tapKey(specialKey)
        return "Pressed \(key)"
    }

    /// Perform a keyboard shortcut (legacy)
    public func hotkey(keys: [String]) throws -> String {
        try InputDriver.hotkey(keys: keys)
        return "Hotkey \(keys.joined(separator: "+"))"
    }

    /// Scroll in a direction
    public func scroll(direction: String, amount: Double = 3.0, at point: CGPoint? = nil) throws -> String {
        let deltaY: Double
        switch direction.lowercased() {
        case "up": deltaY = amount * 10
        case "down": deltaY = -amount * 10
        default:
            throw GhostError.invalidArgument("Direction must be 'up' or 'down'")
        }
        try InputDriver.scroll(deltaY: deltaY, at: point)
        return "Scrolled \(direction)"
    }

    /// Bring an application to the foreground
    public func focus(appName: String) throws -> String {
        let workspace = NSWorkspace.shared
        let apps = workspace.runningApplications
        guard let app = apps.first(where: {
            $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
                || $0.bundleIdentifier?.localizedCaseInsensitiveContains(appName) == true
        }) else {
            throw GhostError.appNotFound("No running app matching '\(appName)'")
        }
        app.activate()
        stateManager.refreshFocus()
        return "Focused \(app.localizedName ?? appName)"
    }

    // MARK: - Legacy Smart Actions (deprecated — kept for transition)

    /// Smart click on ElementNode tree (deprecated — use smartClick(query:role:appName:))
    public func smartClickLegacy(
        query: String,
        role: String? = nil,
        in root: ElementNode
    ) -> (success: Bool, description: String) {
        let resolver = SmartResolver()
        let matches = resolver.resolve(query: query, role: role, in: root, limit: 5)

        guard let best = matches.first else {
            return (false, "No match for '\(query)'")
        }
        guard best.score >= 60 else {
            let label = best.node.label ?? best.node.id
            return (false, "No confident match for '\(query)'. Best: '\(label)' (score: \(best.score), \(best.matchReason))")
        }
        guard let pos = best.node.position else {
            let label = best.node.label ?? best.node.id
            return (false, "Found '\(label)' but it has no screen position")
        }

        let center = CGPoint(
            x: pos.x + (best.node.size?.width ?? 0) / 2,
            y: pos.y + (best.node.size?.height ?? 0) / 2
        )

        do {
            try InputDriver.click(at: center)
            let label = best.node.label ?? best.node.id
            return (true, "Clicked '\(label)' at (\(Int(center.x)), \(Int(center.y))) — \(best.matchReason)")
        } catch {
            return (false, "Click failed: \(error)")
        }
    }

    // MARK: - Private Helpers

    /// Check if context changed between pre and post action states.
    /// Used to detect when AX-native press "succeeded" but didn't actually do anything.
    private func contextDidChange(pre: ContextInfo?, post: ContextInfo?) -> Bool {
        guard let pre = pre, let post = post else { return post != nil }

        // Check focused element changed
        if pre.focused?.role != post.focused?.role { return true }
        if pre.focused?.label != post.focused?.label { return true }

        // Check window title changed (dialog opened, page navigated)
        if pre.window != post.window { return true }

        // Check URL changed
        if pre.url != post.url { return true }

        // Check interactive elements changed (new buttons appeared, dialog opened)
        if pre.interactiveElements.count != post.interactiveElements.count { return true }

        return false
    }

    /// Auto-focus an app with a brief delay for it to come to front
    private func autoFocus(appName: String) {
        let workspace = NSWorkspace.shared
        if let app = workspace.runningApplications.first(where: {
            $0.localizedName?.localizedCaseInsensitiveContains(appName) == true
                || $0.bundleIdentifier?.localizedCaseInsensitiveContains(appName) == true
        }) {
            app.activate()
            usleep(200_000) // 200ms for app to come to front
        }
    }

    private func findElementInTree(_ element: Element, query: String, depth: Int) -> Element? {
        if depth <= 0 { return nil }

        let title = element.title()
        let desc = element.descriptionText()
        if title?.localizedCaseInsensitiveContains(query) == true
            || desc?.localizedCaseInsensitiveContains(query) == true
        {
            return element
        }

        guard let children = element.children() else { return nil }
        for child in children {
            if let found = findElementInTree(child, query: query, depth: depth - 1) {
                return found
            }
        }
        return nil
    }
}

// MARK: - Error types

public enum GhostError: Error, CustomStringConvertible {
    case elementNotFound(String)
    case noPosition(String)
    case invalidKey(String)
    case invalidArgument(String)
    case appNotFound(String)
    case permissionDenied(String)
    case daemonNotRunning
    case ipcError(String)

    public var description: String {
        switch self {
        case let .elementNotFound(msg): return "Element not found: \(msg)"
        case let .noPosition(msg): return "No position: \(msg)"
        case let .invalidKey(msg): return "Invalid key: \(msg)"
        case let .invalidArgument(msg): return "Invalid argument: \(msg)"
        case let .appNotFound(msg): return "App not found: \(msg)"
        case let .permissionDenied(msg): return "Permission denied: \(msg)"
        case .daemonNotRunning: return "Ghost daemon is not running"
        case let .ipcError(msg): return "IPC error: \(msg)"
        }
    }
}
