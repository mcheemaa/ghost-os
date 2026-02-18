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

        // 1. Find and resolve the target element
        let (target, failure) = resolveClickTarget(query: query, role: role, appName: appName)
        guard let target = target else { return failure! }

        // 2. Try AX-native press (no focus needed, works on background apps)
        let preContext = stateManager.getContext(appName: appName)
        do {
            try target.element.performAction(.press)
            usleep(300_000) // 300ms for app to react
            stateManager.refresh()
            let postContext = stateManager.getContext(appName: appName)

            if contextDidChange(pre: preContext, post: postContext) {
                return ActionResult(
                    success: true,
                    description: "Pressed '\(target.label)' via AX-native",
                    method: "ax-native",
                    context: postContext
                )
            }
            // AX press "succeeded" but nothing changed — fall through to synthetic
        } catch {
            // AX-native threw — fall through to synthetic
        }

        // 3. Fallback: auto-focus + synthetic click at element center
        if let appName = appName { autoFocus(appName: appName) }

        do {
            try InputDriver.click(at: target.center)
            usleep(150_000)
            stateManager.refresh()
            return ActionResult(
                success: true,
                description: "Clicked '\(target.label)' at (\(Int(target.center.x)),\(Int(target.center.y))) — synthetic fallback",
                method: "synthetic",
                context: stateManager.getContext(appName: appName)
            )
        } catch {
            return ActionResult(
                success: false,
                description: "Click failed for '\(target.label)': \(error)",
                method: "synthetic",
                context: stateManager.getContext(appName: appName)
            )
        }
    }

    // MARK: - Double-Click

    /// Smart double-click — find element and double-click it.
    /// Uses synthetic double-click (two rapid CGEvents). AX has no native double-click.
    public func smartDoubleClick(query: String, role: String? = nil, appName: String? = nil) -> ActionResult {
        stateManager.refresh()

        let (target, failure) = resolveClickTarget(query: query, role: role, appName: appName)
        guard let target = target else { return failure! }

        if let appName = appName { autoFocus(appName: appName) }

        let c = target.center
        let mouseDown1 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: c, mouseButton: .left)
        let mouseUp1 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: c, mouseButton: .left)
        let mouseDown2 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: c, mouseButton: .left)
        let mouseUp2 = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: c, mouseButton: .left)

        mouseDown1?.setIntegerValueField(.mouseEventClickState, value: 1)
        mouseUp1?.setIntegerValueField(.mouseEventClickState, value: 1)
        mouseDown2?.setIntegerValueField(.mouseEventClickState, value: 2)
        mouseUp2?.setIntegerValueField(.mouseEventClickState, value: 2)

        mouseDown1?.post(tap: .cghidEventTap)
        mouseUp1?.post(tap: .cghidEventTap)
        usleep(50_000) // 50ms between clicks
        mouseDown2?.post(tap: .cghidEventTap)
        mouseUp2?.post(tap: .cghidEventTap)

        usleep(200_000)
        stateManager.refresh()
        return ActionResult(
            success: true,
            description: "Double-clicked '\(target.label)' at (\(Int(c.x)),\(Int(c.y)))",
            method: "synthetic",
            context: stateManager.getContext(appName: appName)
        )
    }

    // MARK: - Right-Click

    /// Smart right-click — find element and right-click it (opens context menu).
    public func smartRightClick(query: String, role: String? = nil, appName: String? = nil) -> ActionResult {
        stateManager.refresh()

        let (target, failure) = resolveClickTarget(query: query, role: role, appName: appName)
        guard let target = target else { return failure! }

        if let appName = appName { autoFocus(appName: appName) }

        let c = target.center
        let mouseDown = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: c, mouseButton: .right)
        let mouseUp = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: c, mouseButton: .right)

        mouseDown?.post(tap: .cghidEventTap)
        usleep(50_000)
        mouseUp?.post(tap: .cghidEventTap)

        usleep(300_000) // Context menus take a moment
        stateManager.refresh()
        return ActionResult(
            success: true,
            description: "Right-clicked '\(target.label)' at (\(Int(c.x)),\(Int(c.y)))",
            method: "synthetic",
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
                let screenshot = captureDebugScreenshot(appName: appName)
                return ActionResult(
                    success: false,
                    description: "No field matching '\(target)'\(appName.map { " in \($0)" } ?? "")",
                    method: "none",
                    context: stateManager.getContext(appName: appName),
                    screenshot: screenshot
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
                // Verify: read AXValue back directly to check if it actually took
                var readBackRef: CFTypeRef?
                let readBack: String?
                if AXUIElementCopyAttributeValue(element.underlyingElement, kAXValueAttribute as CFString, &readBackRef) == .success,
                   let str = readBackRef as? String, !str.isEmpty {
                    readBack = str
                } else {
                    readBack = nil
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
            clearModifierFlags()
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

    // MARK: - Wait (Condition Polling)

    /// Wait until a condition is met, polling getContext and/or readContent.
    /// Returns ActionResult with the final context (whether success or timeout).
    ///
    /// Conditions:
    ///   - urlContains: ctx.url contains value
    ///   - titleContains: ctx.window contains value
    ///   - elementExists: findLiveElement or readContent finds value
    ///   - elementGone: readContent does NOT contain value
    ///   - urlChanged: ctx.url differs from initial
    ///   - titleChanged: ctx.window differs from initial
    /// - Parameter baseline: Optional pre-action context for "changed" conditions.
    ///   If provided, urlChanged/titleChanged compare against this baseline instead of
    ///   capturing state at wait-start. This prevents the race condition where navigation
    ///   completes before wait begins (baseline was captured before the action).
    public func wait(
        condition: String,
        value: String?,
        timeout: Double = 10.0,
        interval: Double = 0.5,
        appName: String? = nil,
        baseline: ContextInfo? = nil
    ) -> ActionResult {
        let deadline = Date().addingTimeInterval(timeout)
        let intervalUs = UInt32(interval * 1_000_000)

        // Use provided baseline for "changed" conditions, or capture now
        let baselineContext = baseline ?? {
            stateManager.refresh()
            return stateManager.getContext(appName: appName)
        }()
        let initialUrl = baselineContext?.url
        let initialTitle = baselineContext?.window

        while Date() < deadline {
            stateManager.refresh()
            let ctx = stateManager.getContext(appName: appName)

            let met: Bool
            switch condition {
            case "urlContains":
                met = value != nil && (ctx?.url?.localizedCaseInsensitiveContains(value!) == true)

            case "titleContains":
                met = value != nil && (ctx?.window?.localizedCaseInsensitiveContains(value!) == true)

            case "elementExists":
                if let v = value {
                    // Try live element search first (fast), fall back to content scan
                    if stateManager.findLiveElement(query: v, appName: appName) != nil {
                        met = true
                    } else {
                        let items = stateManager.readContent(appName: appName, maxItems: 200)
                        met = items.contains { $0.text.localizedCaseInsensitiveContains(v) }
                    }
                } else {
                    met = false
                }

            case "elementGone":
                if let v = value {
                    let items = stateManager.readContent(appName: appName, maxItems: 200)
                    met = !items.contains { $0.text.localizedCaseInsensitiveContains(v) }
                } else {
                    met = true
                }

            case "urlChanged":
                met = ctx?.url != nil && ctx?.url != initialUrl

            case "titleChanged":
                met = ctx?.window != nil && ctx?.window != initialTitle

            default:
                return ActionResult(
                    success: false,
                    description: "Unknown condition: '\(condition)'. Valid: urlContains, titleContains, elementExists, elementGone, urlChanged, titleChanged",
                    method: "wait",
                    context: ctx
                )
            }

            if met {
                return ActionResult(
                    success: true,
                    description: "Condition '\(condition)' met\(value.map { " (value: \($0))" } ?? "")",
                    method: "wait",
                    context: ctx
                )
            }

            usleep(intervalUs)
        }

        // Timeout
        stateManager.refresh()
        let finalCtx = stateManager.getContext(appName: appName)
        return ActionResult(
            success: false,
            description: "Timeout after \(timeout)s waiting for '\(condition)'\(value.map { " (value: \($0))" } ?? "")",
            method: "wait",
            context: finalCtx
        )
    }

    // MARK: - Coordinate-based & utility actions

    /// Click at specific coordinates (synthetic only, no AX-native equivalent)
    public func click(at point: CGPoint) throws -> String {
        try InputDriver.click(at: point)
        return "Clicked at (\(Int(point.x)), \(Int(point.y)))"
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

    // MARK: - Click Target Resolution (shared by all click variants)

    /// Resolved click target — element + label + center point.
    /// Shared by smartClick, smartDoubleClick, smartRightClick to avoid code duplication.
    private struct ClickTarget {
        let element: Element
        let label: String
        let center: CGPoint
    }

    /// Find an element, resolve its label (with raw AXValue fallback for Chrome),
    /// and compute its center point. Returns nil with appropriate ActionResult if not found.
    private func resolveClickTarget(
        query: String, role: String?, appName: String?
    ) -> (target: ClickTarget?, failureResult: ActionResult?) {
        guard let element = stateManager.findLiveElement(query: query, role: role, appName: appName) else {
            let screenshot = captureDebugScreenshot(appName: appName)
            return (nil, ActionResult(
                success: false,
                description: "No element matching '\(query)'\(appName.map { " in \($0)" } ?? "")",
                method: "none",
                context: stateManager.getContext(appName: appName),
                screenshot: screenshot
            ))
        }

        let label = resolveLabel(element, fallback: query)

        guard let pos = element.position(), let size = element.size(),
              size.width > 0 && size.height > 0 else {
            let screenshot = captureDebugScreenshot(appName: appName)
            return (nil, ActionResult(
                success: false,
                description: "Found '\(label)' but it has no screen position",
                method: "none",
                context: stateManager.getContext(appName: appName),
                screenshot: screenshot
            ))
        }

        let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
        return (ClickTarget(element: element, label: label, center: center), nil)
    }

    /// Resolve an element's display label: title → descriptionText → raw AXValue → fallback.
    /// Handles Chrome's AXStaticText where title/desc are empty but AXValue has the text.
    private func resolveLabel(_ element: Element, fallback: String) -> String {
        if let title = element.title(), !title.isEmpty { return title }
        if let desc = element.descriptionText(), !desc.isEmpty { return desc }
        // Raw AXValue fallback for Chrome elements
        var rawVal: CFTypeRef?
        if AXUIElementCopyAttributeValue(element.underlyingElement, kAXValueAttribute as CFString, &rawVal) == .success,
           let str = rawVal as? String, !str.isEmpty {
            return String(str.prefix(100))
        }
        return fallback
    }

    // MARK: - Debug Screenshot on Failure

    /// Capture a screenshot for debugging when an action fails.
    /// Returns nil if screenshot can't be captured (no app found, no permission, etc.).
    /// Uses RunLoop bridge to call async ScreenCaptureKit from sync context.
    private func captureDebugScreenshot(appName: String?) -> ScreenshotResult? {
        guard ScreenCapture.hasPermission() else { return nil }

        // Resolve PID from app name (or frontmost)
        let pid: pid_t
        if let name = appName {
            guard let app = stateManager.getState().apps.first(where: {
                $0.name.localizedCaseInsensitiveContains(name)
            }) else { return nil }
            pid = app.pid
        } else {
            guard let front = stateManager.getState().frontmostApp else { return nil }
            pid = front.pid
        }

        var result: ScreenshotResult?
        var done = false
        Task {
            result = await ScreenCapture.captureWindow(pid: pid)
            done = true
        }
        while !done {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return result
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

    /// Clear any stuck modifier keys (Cmd, Shift, Option, Ctrl) after a hotkey.
    ///
    /// AXorcist's performHotkey sets modifier flags on keyDown/keyUp events but never
    /// sends explicit modifier keyUp events. This can leave the system thinking Cmd (or
    /// other modifiers) is still held, causing subsequent keystrokes to be interpreted
    /// as Cmd+key shortcuts (e.g. typing 'a' becomes Cmd+A).
    ///
    /// Fix: post a flagsChanged CGEvent with empty flags to clear the modifier state.
    private func clearModifierFlags() {
        // Post flagsChanged with no modifiers to tell the system all modifiers are released
        if let flagsEvent = CGEvent(source: nil) {
            flagsEvent.type = .flagsChanged
            flagsEvent.flags = []
            flagsEvent.post(tap: .cghidEventTap)
        }
        usleep(10_000) // 10ms for the event to propagate
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
