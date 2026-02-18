// SetupWizard.swift — Interactive setup for Ghost OS
//
// Walks the user through:
//   1. Accessibility permission
//   2. Screen Recording permission (optional)
//   3. MCP configuration for Claude Code
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

        // Step 4: Default recipes
        installDefaultRecipes()

        // Step 5: Verification
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
        print("  Ghost OS connects to Claude Code through the Model Context Protocol (MCP).")
        print("")

        let binaryPath = resolveBinaryPath()
        let hasClaudeCode = detectClaudeCode()

        if !hasClaudeCode {
            let mcpCommand = "claude mcp add --transport stdio ghost-os -- \(binaryPath) mcp"
            print("  Claude Code not found.")
            print("")
            print("  Install Claude Code first, then run:")
            print("    \(mcpCommand)")
            print("")
            return
        }

        configureClaudeCode(binaryPath: binaryPath)
    }

    private func configureClaudeCode(binaryPath: String) {
        print("  Found: Claude Code")
        print("  Checking MCP configuration...")

        let mcpCommand = "claude mcp add --transport stdio ghost-os -- \(binaryPath) mcp"

        // Check if already configured
        if isGhostOSConfiguredInClaudeCode() {
            print("  Ghost OS is already configured as an MCP server.")
        } else {
            print("  Adding Ghost OS as MCP server...")
            let result = runProcess(
                "/usr/bin/env",
                args: ["claude", "mcp", "add", "--transport", "stdio", "ghost-os", "--", binaryPath, "mcp"],
                env: ["CLAUDECODE": ""],  // Unset to avoid nested session error
                timeout: 15
            )

            if result.exitCode == 0 {
                print("  Done.")
            } else if result.stderr == "timed out" {
                print("  Claude CLI did not respond (it may need login or first-run setup).")
                print("")
                print("  After setting up Claude Code, run this command:")
                print("    \(mcpCommand)")
            } else {
                print("  Auto-configure failed.")
                print("")
                print("  Run this command to add Ghost OS to Claude Code:")
                print("    \(mcpCommand)")
            }
        }

        // Configure permissions to allow Ghost OS tools without prompts
        print("")
        configurePermissions()
    }

    private func configurePermissions() {
        let settingsPath = FileManager.default.currentDirectoryPath + "/.claude/settings.local.json"
        let allowRule = "mcp__ghost-os__*"

        // Read existing settings
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = parsed
        }

        // Check if already configured
        if let permissions = settings["permissions"] as? [String: Any],
           let allow = permissions["allow"] as? [String],
           allow.contains(allowRule) {
            print("  Ghost OS tools already allowed (no approval prompts).")
            print("")
            return
        }

        // Add the allow rule
        var permissions = (settings["permissions"] as? [String: Any]) ?? [:]
        var allow = (permissions["allow"] as? [String]) ?? []
        allow.append(allowRule)
        permissions["allow"] = allow
        settings["permissions"] = permissions

        // Write settings
        do {
            let dir = (settingsPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: settingsPath))
            print("  Allowed Ghost OS tools without approval prompts.")
            print("  Updated: \(settingsPath)")
        } catch {
            print("  Could not update settings automatically.")
            print("  Add this to \(settingsPath):")
            print("")
            print("    \"permissions\": {")
            print("      \"allow\": [\"mcp__ghost-os__*\"]")
            print("    }")
        }
        print("")
    }


    // MARK: - Step 4: Default Recipes

    private func installDefaultRecipes() {
        printStep(4, "Default Recipes")

        let recipesDir = FileManager.default.homeDirectoryForCurrentUser.path + "/.ghost-os/recipes"

        // Create recipes directory
        try? FileManager.default.createDirectory(atPath: recipesDir, withIntermediateDirectories: true)

        let recipes: [(String, String)] = [
            ("gmail-send", gmailSendRecipe),
            ("arxiv-search", arxivSearchRecipe)
        ]

        var installed = 0
        for (name, json) in recipes {
            let path = recipesDir + "/" + name + ".json"
            if FileManager.default.fileExists(atPath: path) {
                print("  \(name) - already exists")
                installed += 1
                continue
            }
            do {
                try json.write(toFile: path, atomically: true, encoding: .utf8)
                print("  \(name) - installed")
                installed += 1
            } catch {
                print("  \(name) - failed to install")
            }
        }

        printStatus("\(installed) recipe(s) ready", ok: true)
        print("")
    }

    // Default recipe: gmail-send
    private let gmailSendRecipe = """
    {
      "schema_version": 1,
      "name": "gmail-send",
      "description": "Send an email via Gmail in Chrome",
      "app": "Chrome",
      "params": {
        "recipient": {"type": "string", "description": "Email address to send to", "required": true},
        "subject": {"type": "string", "description": "Email subject line", "required": true},
        "body": {"type": "string", "description": "Email body text", "required": true}
      },
      "steps": [
        {
          "id": 1, "action": "focus", "note": "Bring Gmail to front",
          "params": {"app": "Chrome"}
        },
        {
          "id": 2, "action": "click", "note": "Open compose window",
          "params": {"target": "Compose", "app": "Chrome"},
          "wait_after": {"condition": "elementExists", "value": "To recipients", "timeout": 5}
        },
        {
          "id": 3, "action": "type", "note": "Type recipient email",
          "params": {"text": "{{recipient}}", "target": "To", "app": "Chrome"},
          "delay_ms": 500
        },
        {
          "id": 4, "action": "press", "note": "Confirm autocomplete",
          "params": {"key": "return"},
          "delay_ms": 500
        },
        {
          "id": 5, "action": "type", "note": "Type subject line",
          "params": {"text": "{{subject}}", "target": "Subject", "app": "Chrome"},
          "delay_ms": 300
        },
        {
          "id": 6, "action": "type", "note": "Type email body",
          "params": {"text": "{{body}}", "target": "Message Body", "app": "Chrome"},
          "delay_ms": 300
        },
        {
          "id": 7, "action": "hotkey", "note": "Send email",
          "params": {"keys": "cmd,return", "app": "Chrome"},
          "wait_after": {"condition": "urlContains", "value": "#inbox", "timeout": 10}
        }
      ]
    }
    """

    // Default recipe: arxiv-search
    private let arxivSearchRecipe = """
    {
      "schema_version": 1,
      "name": "arxiv-search",
      "description": "Search arXiv for academic papers by topic",
      "app": "Chrome",
      "params": {
        "query": {"type": "string", "description": "Search terms (e.g. 'large language model agents')", "required": true}
      },
      "steps": [
        {
          "id": 1, "action": "focus", "note": "Bring Chrome to front",
          "params": {"app": "Chrome"}
        },
        {
          "id": 2, "action": "hotkey", "note": "Select address bar",
          "params": {"keys": "cmd,l", "app": "Chrome"},
          "delay_ms": 300
        },
        {
          "id": 3, "action": "type", "note": "Navigate to arXiv search",
          "params": {"text": "arxiv.org/search/", "app": "Chrome"},
          "delay_ms": 200
        },
        {
          "id": 4, "action": "press", "note": "Go to search page",
          "params": {"key": "return", "app": "Chrome"},
          "wait_after": {"condition": "urlContains", "value": "arxiv.org/search", "timeout": 10, "app": "Chrome"}
        },
        {
          "id": 5, "action": "type", "note": "Enter search query",
          "params": {"text": "{{query}}", "target": "Search term or terms", "app": "Chrome"},
          "delay_ms": 300
        },
        {
          "id": 6, "action": "click", "note": "Submit search",
          "params": {"target": "Search", "app": "Chrome"},
          "wait_after": {"condition": "urlContains", "value": "query=", "timeout": 10, "app": "Chrome"}
        }
      ]
    }
    """

    // MARK: - Step 5: Verification

    private func verify() -> Bool {
        printStep(5, "Verification")

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
            print("    1. Start a new Claude Code session")
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


    private func isGhostOSConfiguredInClaudeCode() -> Bool {
        let result = runProcess(
            "/usr/bin/env",
            args: ["claude", "mcp", "get", "ghost-os"],
            env: ["CLAUDECODE": ""]
        )
        return result.exitCode == 0
    }


    // MARK: - Utility Helpers

    private func resolveBinaryPath() -> String {
        let arg0 = CommandLine.arguments[0]
        // Already absolute
        if arg0.hasPrefix("/") {
            return arg0
        }
        // Contains path separator - resolve against cwd
        if arg0.contains("/") {
            let cwd = FileManager.default.currentDirectoryPath
            return (cwd as NSString).appendingPathComponent(arg0)
        }
        // Bare command name (e.g. "ghost") - resolve via PATH using `which`
        let result = runProcess("/usr/bin/which", args: [arg0])
        if result.exitCode == 0 && !result.stdout.isEmpty {
            return result.stdout
        }
        // Fallback to cwd
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

    private func runProcess(_ executable: String, args: [String], env: [String: String]? = nil, timeout: TimeInterval = 10) -> ProcessResult {
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
        } catch {
            return ProcessResult(stdout: "", stderr: error.localizedDescription, exitCode: -1)
        }

        // Wait with timeout to avoid hanging on interactive prompts
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }

        if process.isRunning {
            process.terminate()
            return ProcessResult(stdout: "", stderr: "timed out", exitCode: -1)
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
        print("  Step \(number)/5: \(title)")
        print("  " + String(repeating: "-", count: title.count + 10))
    }

    private func printStatus(_ status: String, ok: Bool) {
        let icon = ok ? "[ok]" : "[!!]"
        print("  \(icon) \(status)")
    }
}
