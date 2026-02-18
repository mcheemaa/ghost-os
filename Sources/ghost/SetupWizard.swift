// SetupWizard.swift — Interactive setup for Ghost OS
//
// Walks the user through:
//   1. Accessibility permission
//   2. Screen Recording permission (optional)
//   3. MCP configuration for Claude Code / Claude Desktop
//   4. Verification test
//
// Usage: ghost setup

import Foundation
import GhostOS
import AXorcist

@MainActor
struct SetupWizard {

    func run() async {
        printBanner()

        // Step 1: Accessibility
        let hasAccess = checkAccessibility()

        // Step 2: Screen Recording (optional)
        let hasScreenRecording = checkScreenRecording()

        // Step 3: MCP configuration
        configureMCP()

        // Step 4: Verification
        let verified = verify()

        // Summary
        printSummary(accessibility: hasAccess, screenRecording: hasScreenRecording, verified: verified)
    }

    // MARK: - Step 1: Accessibility Permission

    private func checkAccessibility() -> Bool {
        printStep(1, "Accessibility Permission")
        print("  Ghost OS reads the accessibility tree to see what's on screen.")
        print("  This requires the Accessibility permission for your terminal app.")
        print("")

        // Quick check first
        if AXPermissionHelpers.hasAccessibilityPermissions() {
            // Double-check with a real AX read
            let sm = StateManager()
            sm.refresh()
            let state = sm.getState()
            if !state.apps.isEmpty {
                printStatus("GRANTED", ok: true)
                print("  \(state.apps.count) apps visible.")
                print("")
                return true
            }
        }

        // Not granted. Trigger the system prompt.
        print("  Not granted yet. Opening the permission dialog...")
        print("")
        _ = AXPermissionHelpers.askForAccessibilityIfNeeded()

        // Open System Settings to the right pane
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

        if let terminal = terminalAppName() {
            print("  Add \"\(terminal)\" to the Accessibility list in System Settings.")
        } else {
            print("  Add your terminal app to the Accessibility list in System Settings.")
        }
        print("  You may need to toggle it off and on if it was already in the list.")
        print("")

        // Retry loop
        for attempt in 1...3 {
            print("  Press Enter after granting permission (attempt \(attempt)/3)...")
            _ = readLine()

            if AXPermissionHelpers.hasAccessibilityPermissions() {
                let sm = StateManager()
                sm.refresh()
                let state = sm.getState()
                if !state.apps.isEmpty {
                    printStatus("GRANTED", ok: true)
                    print("  \(state.apps.count) apps visible.")
                    print("")
                    return true
                }
            }

            if attempt < 3 {
                print("  Still not granted. Make sure you added the right app.")
            }
        }

        printStatus("NOT GRANTED", ok: false)
        print("  Ghost OS needs Accessibility permission to function.")
        print("  Go to: System Settings > Privacy & Security > Accessibility")
        print("  Then run `ghost setup` again.")
        print("")
        return false
    }

    // MARK: - Step 2: Screen Recording Permission

    private func checkScreenRecording() -> Bool {
        printStep(2, "Screen Recording Permission (optional)")
        print("  Ghost OS can capture screenshots for visual debugging.")
        print("  This is optional. Skip it if you don't need screenshots.")
        print("")

        if ScreenCapture.hasPermission() {
            printStatus("GRANTED", ok: true)
            print("")
            return true
        }

        print("  Not granted. This is optional, but useful for debugging.")
        print("  Want to set it up now? (y/N) ", terminator: "")
        fflush(stdout)

        guard let answer = readLine()?.lowercased(), answer == "y" || answer == "yes" else {
            printStatus("SKIPPED", ok: true)
            print("")
            return false
        }

        ScreenCapture.requestPermission()
        openSystemSettings("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")

        if let terminal = terminalAppName() {
            print("  Add \"\(terminal)\" to the Screen Recording list in System Settings.")
        } else {
            print("  Add your terminal app to the Screen Recording list.")
        }
        print("")
        print("  Press Enter after granting permission...")
        _ = readLine()

        if ScreenCapture.hasPermission() {
            printStatus("GRANTED", ok: true)
            print("")
            return true
        }

        printStatus("NOT GRANTED", ok: false)
        print("  You can set this up later by running `ghost setup` again.")
        print("")
        return false
    }

    // MARK: - Step 3: MCP Configuration

    private func configureMCP() {
        printStep(3, "MCP Configuration")
        print("  Ghost OS connects to AI agents (Claude Code, Claude Desktop)")
        print("  through the Model Context Protocol (MCP).")
        print("")

        let binaryPath = resolveBinaryPath()
        let hasClaudeCode = detectClaudeCode()
        let hasClaudeDesktop = detectClaudeDesktop()

        if !hasClaudeCode && !hasClaudeDesktop {
            print("  No MCP clients detected.")
            print("")
            print("  To set up manually later:")
            print("")
            print("  Claude Code:")
            print("    claude mcp add --transport stdio ghost-os -- \(binaryPath) mcp")
            print("")
            print("  Claude Desktop (~/.config/claude/claude_desktop_config.json):")
            print("    {")
            print("      \"mcpServers\": {")
            print("        \"ghost-os\": {")
            print("          \"command\": \"\(binaryPath)\",")
            print("          \"args\": [\"mcp\"]")
            print("        }")
            print("      }")
            print("    }")
            print("")
            return
        }

        // Claude Code
        if hasClaudeCode {
            configureClaudeCode(binaryPath: binaryPath)
        }

        // Claude Desktop
        if hasClaudeDesktop {
            configureClaudeDesktop(binaryPath: binaryPath)
        }

        // Permission allow rule
        print("  ---")
        print("  Recommended: allow all Ghost OS tools without prompting.")
        print("  Add this to your Claude Code settings (.claude/settings.local.json):")
        print("")
        print("    \"permissions\": {")
        print("      \"allow\": [\"mcp__ghost-os__*\"]")
        print("    }")
        print("")
    }

    private func configureClaudeCode(binaryPath: String) {
        print("  Found: Claude Code")

        // Check if already configured
        if isGhostOSConfiguredInClaudeCode() {
            print("  Ghost OS is already configured as an MCP server.")
            print("")
            return
        }

        print("  Adding Ghost OS as MCP server...")
        let result = runProcess(
            "/usr/bin/env",
            args: ["claude", "mcp", "add", "--transport", "stdio", "ghost-os", "--", binaryPath, "mcp"],
            env: ["CLAUDECODE": ""]  // Unset to avoid nested session error
        )

        if result.exitCode == 0 {
            print("  Done.")
        } else {
            print("  Auto-configure failed. Add manually:")
            print("    claude mcp add --transport stdio ghost-os -- \(binaryPath) mcp")
        }
        print("")
    }

    private func configureClaudeDesktop(binaryPath: String) {
        print("  Found: Claude Desktop")

        let configPath = claudeDesktopConfigPath()
        var config: [String: Any] = [:]

        // Read existing config
        if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            config = parsed
        }

        // Check if already configured
        if let servers = config["mcpServers"] as? [String: Any], servers["ghost-os"] != nil {
            print("  Ghost OS is already configured in Claude Desktop.")
            print("")
            return
        }

        // Add ghost-os server
        var servers = (config["mcpServers"] as? [String: Any]) ?? [:]
        servers["ghost-os"] = [
            "command": binaryPath,
            "args": ["mcp"]
        ] as [String: Any]
        config["mcpServers"] = servers

        // Write config
        do {
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            let dir = (configPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: configPath))
            print("  Updated \(configPath)")
        } catch {
            print("  Could not write config. Add manually to \(configPath):")
            print("    \"ghost-os\": {\"command\": \"\(binaryPath)\", \"args\": [\"mcp\"]}")
        }
        print("")
    }

    // MARK: - Step 4: Verification

    private func verify() -> Bool {
        printStep(4, "Verification")

        let sm = StateManager()
        sm.refresh()
        let state = sm.getState()

        if state.apps.isEmpty {
            print("  Could not read screen state. Check your permissions.")
            printStatus("FAILED", ok: false)
            print("")
            return false
        }

        print("  \(state.apps.count) apps visible.")

        // Try to get context of frontmost app
        if let front = state.frontmostApp {
            let ctx = sm.getContext(appName: front.name)
            if let ctx = ctx {
                print("  Frontmost: \(ctx.app) (\(ctx.url ?? "no URL"))")
            } else {
                print("  Frontmost: \(front.name)")
            }
        }

        printStatus("OK", ok: true)
        print("")
        return true
    }

    // MARK: - Summary

    private func printSummary(accessibility: Bool, screenRecording: Bool, verified: Bool) {
        print("  ========================================")

        if accessibility && verified {
            print("  Setup complete. Ghost OS is ready.")
            print("")
            print("  Next steps:")
            print("    1. Start a new Claude Code session (or restart Claude Desktop)")
            print("    2. Ask Claude to interact with any app on your screen")
            print("    3. Try: \"What apps are on my screen right now?\"")
        } else if !accessibility {
            print("  Setup incomplete. Accessibility permission is required.")
            print("  Run `ghost setup` again after granting permission.")
        } else {
            print("  Setup finished with warnings. Check the output above.")
        }

        print("")
    }

    // MARK: - Detection Helpers

    private func detectClaudeCode() -> Bool {
        let result = runProcess("/usr/bin/which", args: ["claude"])
        return result.exitCode == 0 && !result.stdout.isEmpty
    }

    private func detectClaudeDesktop() -> Bool {
        FileManager.default.fileExists(atPath: claudeDesktopConfigDir())
    }

    private func isGhostOSConfiguredInClaudeCode() -> Bool {
        let result = runProcess(
            "/usr/bin/env",
            args: ["claude", "mcp", "get", "ghost-os"],
            env: ["CLAUDECODE": ""]
        )
        return result.exitCode == 0
    }

    private func claudeDesktopConfigDir() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/Claude"
    }

    private func claudeDesktopConfigPath() -> String {
        "\(claudeDesktopConfigDir())/claude_desktop_config.json"
    }

    // MARK: - Utility Helpers

    private func resolveBinaryPath() -> String {
        let arg0 = CommandLine.arguments[0]
        if arg0.hasPrefix("/") {
            return arg0
        }
        // Relative path - resolve against cwd
        let cwd = FileManager.default.currentDirectoryPath
        return (cwd as NSString).appendingPathComponent(arg0)
    }

    private func terminalAppName() -> String? {
        // TERM_PROGRAM is set by most terminal emulators
        if let term = ProcessInfo.processInfo.environment["TERM_PROGRAM"] {
            return term
        }
        return nil
    }

    private func openSystemSettings(_ url: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url]
        try? process.run()
        process.waitUntilExit()
    }

    private struct ProcessResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    private func runProcess(_ executable: String, args: [String], env: [String: String]? = nil) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        if let env = env {
            var environment = ProcessInfo.processInfo.environment
            for (key, value) in env {
                if value.isEmpty {
                    environment.removeValue(forKey: key)
                } else {
                    environment[key] = value
                }
            }
            process.environment = environment
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return ProcessResult(stdout: "", stderr: error.localizedDescription, exitCode: -1)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return ProcessResult(
            stdout: String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            stderr: String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            exitCode: process.terminationStatus
        )
    }

    // MARK: - Formatting

    private func printBanner() {
        print("")
        print("  Ghost OS Setup")
        print("  ==============")
        print("")
    }

    private func printStep(_ number: Int, _ title: String) {
        print("  Step \(number)/4: \(title)")
        print("  " + String(repeating: "-", count: title.count + 10))
    }

    private func printStatus(_ status: String, ok: Bool) {
        let icon = ok ? "[ok]" : "[!!]"
        print("  \(icon) \(status)")
    }
}
