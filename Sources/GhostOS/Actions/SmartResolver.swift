// SmartResolver.swift — Intelligent element resolution with confidence scoring
//
// This is what makes "ghost click Compose" just work, even when the button
// says " Compose" or "Compose Mail" or has slight variations.

import Foundation

/// A resolved element match with confidence scoring
public struct ResolvedElement: Sendable {
    public let node: ElementNode
    public let score: Int           // 0-100+, higher = better match
    public let matchReason: String  // human-readable: "exact label match", "fuzzy (87%)", etc.
}

/// SmartResolver finds the best matching UI element for a natural language query.
/// This is what makes "ghost click Compose" just work.
@MainActor
public final class SmartResolver {

    /// Container roles that we deprioritize — users rarely mean to target these
    private static let containerRoles: Set<String> = [
        "AXGroup", "AXScrollArea", "AXSplitGroup", "AXTabGroup",
        "AXLayoutArea", "AXList", "AXOutline", "AXBrowser",
    ]

    /// Minimum score threshold — anything below this is noise
    private static let noiseThreshold = 30

    public init() {}

    // MARK: - Public API

    /// Resolve a natural language query to the best matching UI elements.
    ///
    /// - Parameters:
    ///   - query: What the user is looking for ("Compose", "Save", "search field", etc.)
    ///   - role: Optional role hint ("button", "textField", "AXButton", etc.)
    ///   - root: The element tree to search
    ///   - limit: Maximum number of results to return
    /// - Returns: Top matches sorted by score descending, filtered by noise threshold
    public func resolve(
        query: String,
        role: String? = nil,
        in root: ElementNode,
        limit: Int = 5
    ) -> [ResolvedElement] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespaces)
        guard !normalizedQuery.isEmpty else { return [] }

        let queryLower = normalizedQuery.lowercased()

        // Normalize role hint: "button" -> "AXButton"
        let normalizedRole: String?
        if let role = role {
            if role.hasPrefix("AX") {
                normalizedRole = role
            } else {
                normalizedRole = "AX" + role.prefix(1).uppercased() + role.dropFirst()
            }
        } else {
            normalizedRole = nil
        }

        // Collect all scored elements by walking the tree
        var results: [ResolvedElement] = []
        scoreTree(node: root, queryLower: queryLower, normalizedRole: normalizedRole, results: &results)

        // Sort by score descending, filter noise
        results.sort { $0.score > $1.score }
        let filtered = results.filter { $0.score >= Self.noiseThreshold }
        return Array(filtered.prefix(limit))
    }

    // MARK: - Tree Walking

    private func scoreTree(
        node: ElementNode,
        queryLower: String,
        normalizedRole: String?,
        results: inout [ResolvedElement]
    ) {
        let (score, reason) = scoreElement(node: node, queryLower: queryLower, normalizedRole: normalizedRole)
        if score > 0 {
            results.append(ResolvedElement(node: node, score: score, matchReason: reason))
        }

        if let children = node.children {
            for child in children {
                scoreTree(node: child, queryLower: queryLower, normalizedRole: normalizedRole, results: &results)
            }
        }
    }

    // MARK: - Scoring

    private func scoreElement(
        node: ElementNode,
        queryLower: String,
        normalizedRole: String?
    ) -> (score: Int, reason: String) {
        var score = 0
        var reason = ""

        // --- 1. ID matching ---
        let (idScore, idReason) = scoreID(node: node, queryLower: queryLower)
        if idScore > 0 {
            score = idScore
            reason = idReason
        }

        // --- 2. Label matching (most important signal) ---
        let (labelScore, labelReason) = scoreLabel(node: node, queryLower: queryLower)
        if labelScore > score {
            score = labelScore
            reason = labelReason
        }

        // --- 3. Value matching (secondary signal) ---
        let (valueScore, valueReason) = scoreValue(node: node, queryLower: queryLower)
        if valueScore > 0 {
            score += valueScore
            if reason.isEmpty {
                reason = valueReason
            } else {
                reason += " + \(valueReason)"
            }
        }

        // Only apply bonuses if we have some base match
        guard score > 0 else { return (0, "") }

        // --- 4. Role matching (bonus when caller specifies a role hint) ---
        if let normalizedRole = normalizedRole {
            if node.role.caseInsensitiveCompare(normalizedRole) == .orderedSame {
                score += 20
            } else if let roleDesc = node.roleDescription,
                      roleDesc.lowercased() == normalizedRole.lowercased()
                        || roleDesc.lowercased() == normalizedRole.dropFirst(2).lowercased() {
                score += 15
            }
        }

        // --- 5. Element quality bonuses ---
        if node.isInteractive {
            score += 15
        }
        if node.isEnabled {
            score += 10
        }
        if let size = node.size, size.width > 0 && size.height > 0 {
            score += 10
        }
        if node.label != nil && !(node.label?.isEmpty ?? true) {
            score += 5
        }
        if !Self.containerRoles.contains(node.role) {
            score += 5
        }

        return (score, reason)
    }

    // MARK: - ID Matching

    private func scoreID(node: ElementNode, queryLower: String) -> (score: Int, reason: String) {
        // Check if query looks like an element ID
        let looksLikeID = queryLower.contains(":") || queryLower.hasPrefix("_ns:")
            || queryLower.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ":" })

        guard looksLikeID else { return (0, "") }

        let nodeIdLower = node.id.lowercased()
        if nodeIdLower == queryLower {
            return (100, "exact ID match")
        }

        return (0, "")
    }

    // MARK: - Label Matching

    private func scoreLabel(node: ElementNode, queryLower: String) -> (score: Int, reason: String) {
        guard let label = node.label, !label.isEmpty else { return (0, "") }

        let labelLower = label.lowercased()
        let labelTrimmed = labelLower.trimmingCharacters(in: .whitespaces)

        // Exact match (case-insensitive)
        if labelLower == queryLower {
            return (100, "exact label match")
        }

        // Trimmed match
        if labelTrimmed == queryLower {
            return (95, "label match (trimmed)")
        }

        // Label starts with query
        if labelLower.hasPrefix(queryLower) {
            return (80, "label starts with query")
        }

        // Query starts with label (query is more specific)
        if queryLower.hasPrefix(labelLower) {
            return (75, "query starts with label")
        }

        // Label contains query as a complete word
        if containsWholeWord(labelLower, word: queryLower) {
            return (70, "whole word match in label")
        }

        // Label contains query as substring
        if labelLower.contains(queryLower) {
            return (60, "substring match in label")
        }

        // Any word in query matches any word in label
        let queryWords = queryLower.split(separator: " ").map(String.init)
        let labelWords = labelLower.split(separator: " ").map(String.init)
        if queryWords.count > 1 || labelWords.count > 1 {
            for qw in queryWords {
                for lw in labelWords {
                    if qw == lw {
                        return (50, "word match: '\(qw)'")
                    }
                }
            }
        }

        // Levenshtein similarity — only for reasonably short strings
        if queryLower.count < 100 && labelLower.count < 100 {
            let similarity = levenshteinSimilarity(queryLower, labelLower)
            if similarity > 0.8 {
                let pct = Int(similarity * 100)
                return (45, "fuzzy match (\(pct)%)")
            }
            if similarity > 0.6 {
                let pct = Int(similarity * 100)
                return (30, "fuzzy match (\(pct)%)")
            }
        }

        return (0, "")
    }

    // MARK: - Value Matching

    private func scoreValue(node: ElementNode, queryLower: String) -> (score: Int, reason: String) {
        guard let value = node.value, !value.isEmpty else { return (0, "") }

        let valueLower = value.lowercased()

        if valueLower == queryLower {
            return (30, "exact value match")
        }
        if valueLower.contains(queryLower) {
            return (20, "value contains query")
        }

        return (0, "")
    }

    // MARK: - String Utilities

    /// Check if `text` contains `word` as a whole word (bounded by non-alphanumeric chars or edges)
    private func containsWholeWord(_ text: String, word: String) -> Bool {
        guard let range = text.range(of: word) else { return false }

        let beforeOK: Bool
        if range.lowerBound == text.startIndex {
            beforeOK = true
        } else {
            let charBefore = text[text.index(before: range.lowerBound)]
            beforeOK = !charBefore.isLetter && !charBefore.isNumber
        }

        let afterOK: Bool
        if range.upperBound == text.endIndex {
            afterOK = true
        } else {
            let charAfter = text[range.upperBound]
            afterOK = !charAfter.isLetter && !charAfter.isNumber
        }

        return beforeOK && afterOK
    }

    /// Levenshtein distance between two strings
    private func levenshteinDistance(_ s1: String, _ s2: String) -> Int {
        let a = Array(s1)
        let b = Array(s2)
        let m = a.count
        let n = b.count

        if m == 0 { return n }
        if n == 0 { return m }

        // Use two-row optimization to save memory
        var prevRow = [Int](0...n)
        var currRow = [Int](repeating: 0, count: n + 1)

        for i in 1...m {
            currRow[0] = i
            for j in 1...n {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                currRow[j] = min(
                    prevRow[j] + 1,         // deletion
                    currRow[j - 1] + 1,     // insertion
                    prevRow[j - 1] + cost   // substitution
                )
            }
            let temp = prevRow
            prevRow = currRow
            currRow = temp
        }

        return prevRow[n]
    }

    /// Levenshtein similarity: 1.0 = identical, 0.0 = completely different
    private func levenshteinSimilarity(_ s1: String, _ s2: String) -> Double {
        let maxLen = max(s1.count, s2.count)
        guard maxLen > 0 else { return 1.0 }
        let dist = levenshteinDistance(s1, s2)
        return 1.0 - Double(dist) / Double(maxLen)
    }
}
