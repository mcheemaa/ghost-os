// ActionExecutor.swift — Wraps AXorcist's InputDriver for action execution

import AppKit
import ApplicationServices
import AXorcist
import Foundation

/// ActionExecutor provides high-level action methods that combine element
/// finding (via StateManager) with action execution (via AXorcist's InputDriver).
@MainActor
public final class ActionExecutor {
    private let stateManager: StateManager

    public init(stateManager: StateManager) {
        self.stateManager = stateManager
    }

    // MARK: - Click

    /// Click an element by label (searches frontmost app)
    public func click(target: String, appName: String? = nil) throws -> String {
        let elements = stateManager.findElements(query: target, role: nil, appName: appName)
        guard let element = elements.first else {
            throw GhostError.elementNotFound("No element matching '\(target)'")
        }
        guard let pos = element.position else {
            throw GhostError.noPosition("Element '\(target)' has no screen position")
        }

        // Click at the center of the element
        let center = CGPoint(
            x: pos.x + (element.size?.width ?? 0) / 2,
            y: pos.y + (element.size?.height ?? 0) / 2
        )
        try InputDriver.click(at: center)
        return "Clicked '\(element.label ?? target)' at (\(Int(center.x)), \(Int(center.y)))"
    }

    /// Click at specific coordinates
    public func click(at point: CGPoint) throws -> String {
        try InputDriver.click(at: point)
        return "Clicked at (\(Int(point.x)), \(Int(point.y)))"
    }

    // MARK: - Type

    /// Type text at the current focus
    public func type(text: String) throws -> String {
        try InputDriver.type(text)
        return "Typed \(text.count) characters"
    }

    // MARK: - Press Key

    /// Press a special key (return, tab, escape, etc.)
    public func press(key: String) throws -> String {
        guard let specialKey = SpecialKey(rawValue: key.lowercased()) else {
            throw GhostError.invalidKey("Unknown key: '\(key)'. Valid: return, tab, escape, space, delete, up, down, left, right, etc.")
        }
        try InputDriver.tapKey(specialKey)
        return "Pressed \(key)"
    }

    // MARK: - Hotkey

    /// Perform a keyboard shortcut (e.g., ["cmd", "s"])
    public func hotkey(keys: [String]) throws -> String {
        try InputDriver.hotkey(keys: keys)
        return "Hotkey \(keys.joined(separator: "+"))"
    }

    // MARK: - Scroll

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

    // MARK: - Focus App

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
        // Give the app a moment to come to front
        stateManager.refreshFocus()
        return "Focused \(app.localizedName ?? appName)"
    }

    // MARK: - Direct AX Action

    /// Perform an accessibility action (like AXPress) on a found element
    public func performAction(
        action: String,
        target: String,
        appName: String? = nil
    ) throws -> String {
        // Find the target app
        let state = stateManager.getState()
        let targetAppName = appName ?? state.frontmostApp?.name
        guard let appInfo = state.apps.first(where: {
            $0.name.localizedCaseInsensitiveContains(targetAppName ?? "")
        }) else {
            throw GhostError.appNotFound("No app found")
        }

        // Use AXorcist to find and act on the element
        let axApp = AXUIElementCreateApplication(appInfo.pid)
        let appElement = Element(axApp)

        // Search for the element
        guard let found = findElementInTree(appElement, query: target, depth: 6) else {
            throw GhostError.elementNotFound("No element matching '\(target)'")
        }

        try found.performAction(action)
        return "Performed \(action) on '\(target)'"
    }

    // MARK: - Private

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
