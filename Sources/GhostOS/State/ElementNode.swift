// ElementNode.swift — Simplified, serializable representation of a UI element

import AXorcist
import ApplicationServices
import Foundation

/// A lightweight, Codable representation of a UI element from the accessibility tree.
/// Unlike AXorcist's `Element` (which wraps a live AXUIElement handle), ElementNode is
/// a pure data snapshot suitable for JSON serialization, caching, and IPC transfer.
public struct ElementNode: Codable, Sendable {
    public let id: String
    public let role: String
    public let label: String?
    public let value: String?
    public let roleDescription: String?
    public let position: CGPointCodable?
    public let size: CGSizeCodable?
    public let isInteractive: Bool
    public let isEnabled: Bool
    public let isFocused: Bool
    public let actions: [String]?
    public let children: [ElementNode]?

    public init(
        id: String,
        role: String,
        label: String?,
        value: String?,
        roleDescription: String?,
        position: CGPointCodable?,
        size: CGSizeCodable?,
        isInteractive: Bool,
        isEnabled: Bool,
        isFocused: Bool,
        actions: [String]?,
        children: [ElementNode]?
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.value = value
        self.roleDescription = roleDescription
        self.position = position
        self.size = size
        self.isInteractive = isInteractive
        self.isEnabled = isEnabled
        self.isFocused = isFocused
        self.actions = actions
        self.children = children
    }
}

// MARK: - Codable wrappers for CoreGraphics types

public struct CGPointCodable: Codable, Sendable {
    public let x: Double
    public let y: Double

    public init(_ point: CGPoint) {
        self.x = Double(point.x)
        self.y = Double(point.y)
    }

    public var cgPoint: CGPoint {
        CGPoint(x: x, y: y)
    }
}

public struct CGSizeCodable: Codable, Sendable {
    public let width: Double
    public let height: Double

    public init(_ size: CGSize) {
        self.width = Double(size.width)
        self.height = Double(size.height)
    }

    public var cgSize: CGSize {
        CGSize(width: width, height: height)
    }
}

// MARK: - Build ElementNode from AXorcist Element

extension ElementNode {
    /// Interactive AX roles — elements users can click, type in, toggle, etc.
    private static let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXCheckBox",
        "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXSlider",
        "AXIncrementor", "AXMenuButton", "AXMenuItem", "AXTab",
        "AXDisclosureTriangle", "AXColorWell", "AXSwitch",
    ]

    /// Snapshot an AXorcist Element into an ElementNode tree.
    ///
    /// Uses AXorcist's `children()` which is comprehensive — it checks 14+
    /// alternative child attributes, collects AXWindows for app elements,
    /// and deduplicates automatically.
    ///
    /// - Parameters:
    ///   - element: The live AXUIElement wrapper
    ///   - depth: How deep to recurse into children (0 = this element only)
    ///   - maxChildren: Max children per node to prevent explosions
    ///   - visited: CFHash set for cycle detection (prevents infinite loops)
    @MainActor
    public static func from(
        _ element: Element,
        depth: Int = 3,
        maxChildren: Int = 50,
        visited: inout Set<UInt> // CFHash-based cycle detection
    ) -> ElementNode? {
        // Cycle detection: skip if we've seen this element before
        let hash = CFHash(element.underlyingElement)
        guard !visited.contains(hash) else { return nil }
        visited.insert(hash)

        let role = element.role() ?? "Unknown"
        let title = element.title()
        let desc = element.descriptionText()
        let label = title ?? desc
        let roleDesc = element.roleDescription()

        // Value — try to get a string representation
        var valueStr: String? = nil
        if let v = element.value() {
            let s = String(describing: v).trimmingCharacters(in: .whitespacesAndNewlines)
            // Filter unhelpful values
            if !s.isEmpty && s != "nil" && !(s == "0" && role != "AXSlider") {
                valueStr = s.count > 200 ? String(s.prefix(200)) + "..." : s
            }
        }

        // Position and size
        let pos = element.position()
        let size = element.size()

        // Interactive = has press action or is a known interactive role
        let supportedActions = element.supportedActions() ?? []
        let isInteractive = Self.interactiveRoles.contains(role)
            || supportedActions.contains("AXPress")

        let isEnabled = element.isEnabled() ?? true
        let isFocused = element.isFocused() ?? false

        // Stable-ish ID
        let id = element.identifier() ?? element.domIdentifier()
            ?? "\(role):\(label ?? "?")"

        // Children — use AXorcist's comprehensive children() method
        // which handles AXWindows, alternative attributes, and deduplication
        var childNodes: [ElementNode]? = nil
        if depth > 0 {
            if let kids = element.children() {
                let limitedKids = Array(kids.prefix(maxChildren))
                var nodes: [ElementNode] = []
                for child in limitedKids {
                    if let node = ElementNode.from(
                        child, depth: depth - 1,
                        maxChildren: maxChildren, visited: &visited
                    ) {
                        nodes.append(node)
                    }
                }
                if !nodes.isEmpty {
                    childNodes = nodes
                }
            }
        }

        return ElementNode(
            id: id,
            role: role,
            label: label,
            value: valueStr,
            roleDescription: roleDesc,
            position: pos != nil ? CGPointCodable(pos!) : nil,
            size: size != nil ? CGSizeCodable(size!) : nil,
            isInteractive: isInteractive,
            isEnabled: isEnabled,
            isFocused: isFocused,
            actions: supportedActions.isEmpty ? nil : supportedActions,
            children: childNodes
        )
    }

    /// Convenience overload that creates the visited set for you
    @MainActor
    public static func from(
        _ element: Element,
        depth: Int = 3,
        maxChildren: Int = 50
    ) -> ElementNode {
        var visited = Set<UInt>()
        return from(element, depth: depth, maxChildren: maxChildren, visited: &visited)
            ?? ElementNode(
                id: "error", role: "Unknown", label: nil, value: nil,
                roleDescription: nil, position: nil, size: nil,
                isInteractive: false, isEnabled: false, isFocused: false,
                actions: nil, children: nil
            )
    }

    /// Render as an indented text tree (for `ghost tree` command)
    public func renderTree(indent: Int = 0) -> String {
        var lines: [String] = []
        let pad = String(repeating: "  ", count: indent)

        // Build a concise description: role + label + value
        var parts: [String] = [role]
        if let label, !label.isEmpty { parts.append("\"\(label)\"") }
        if let value, !value.isEmpty { parts.append("= \(value)") }
        if isInteractive { parts.append("[interactive]") }

        lines.append("\(pad)\(parts.joined(separator: " "))")

        if let children {
            for child in children {
                lines.append(child.renderTree(indent: indent + 1))
            }
        }

        return lines.joined(separator: "\n")
    }
}

// MARK: - Element geometry helpers

extension Element {
    @MainActor
    func position() -> CGPoint? {
        var pointRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            underlyingElement, "AXPosition" as CFString, &pointRef)
        guard err == .success, let val = pointRef else { return nil }
        var point = CGPoint.zero
        if AXValueGetValue(val as! AXValue, .cgPoint, &point) {
            return point
        }
        return nil
    }

    @MainActor
    func size() -> CGSize? {
        var sizeRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            underlyingElement, "AXSize" as CFString, &sizeRef)
        guard err == .success, let val = sizeRef else { return nil }
        var size = CGSize.zero
        if AXValueGetValue(val as! AXValue, .cgSize, &size) {
            return size
        }
        return nil
    }
}
