# Contributing to Ghost OS

Thanks for your interest in Ghost OS. Here's how to get involved.

## Development Setup

```bash
git clone https://github.com/mcheemaa/ghost-os.git
cd ghost-os
swift build
```

Requirements:
- macOS 14+
- Swift 6.2+ (install via [Swiftly](https://swiftlang.github.io/swiftly/))
- Xcode Command Line Tools
- Accessibility permission for your terminal app

Run the binary:
```bash
.build/debug/ghost permissions    # verify accessibility
.build/debug/ghost state --summary  # test it works
```

## How to Contribute

### Reporting Issues

Open a GitHub issue. Include:
- What you tried to do
- What happened instead
- Your macOS version and terminal app
- The output of `ghost version` and `ghost permissions`

### Submitting Pull Requests

1. Fork the repo
2. Create a branch from `main` (`git checkout -b my-feature`)
3. Make your changes
4. Run `swift build` and make sure it compiles without errors
5. Test your changes manually (see Testing below)
6. Open a PR against `main`

Keep PRs focused. One feature or fix per PR. Write a clear description of what changed and why.

### What We're Looking For

- Bug fixes
- New recipes (add to `recipes/` directory)
- Improvements to element matching and content extraction
- Better error messages and failure handling
- Documentation improvements
- Platform support (Windows UI Automation, Linux AT-SPI)

## Code Conventions

### Architecture

Ghost OS has two targets:

- **GhostOS** (library at `Sources/GhostOS/`) - The core: state management, actions, recipes, MCP server, IPC
- **ghost** (CLI at `Sources/ghost/`) - The command-line interface, calls into GhostOS library

All heavy logic belongs in the library. The CLI is thin.

### Rules

- **No app-specific hacks.** Everything must be generic. If Gmail needs special handling, find a generic solution that works for all web apps. We do not add `if app == "Gmail"` anywhere.
- **Check AXorcist first.** Before building new accessibility functionality, check if [AXorcist](https://github.com/steipete/AXorcist) already has it. We use their API, not our own reimplementation.
- **AX-native first.** Actions should try accessibility API methods (`performAction(.press)`, `setValue`) before falling back to synthetic input (mouse/keyboard events).
- **Every action returns context.** Actions return `ActionResult` with a description of what happened and post-action `ContextInfo`. The agent should never need a separate call to check the result.
- **Swift 6 concurrency.** We use `@MainActor` isolation and strict concurrency checking. No `nonisolated(unsafe)` shortcuts.

### Style

- No unnecessary abstractions. Three similar lines are better than a premature helper function.
- No docstrings on obvious code. Comments only where the logic isn't self-evident.
- Match the existing code style. Look at nearby code before writing new code.

## Testing

There are no automated tests yet (the project is 3 days old). Testing is manual:

```bash
# Build
swift build

# Core functionality
.build/debug/ghost context --app Chrome      # reads Chrome state
.build/debug/ghost state --summary           # lists all apps
.build/debug/ghost read --app Chrome --limit 20  # reads page content
.build/debug/ghost find "Compose" --deep --app Chrome  # finds elements

# Actions (these interact with real apps)
.build/debug/ghost click "Compose" --app Chrome  # clicks a button
.build/debug/ghost type "Hello" --into "To" --app Chrome  # types into a field
.build/debug/ghost press return  # presses Enter
.build/debug/ghost hotkey cmd,l  # key combination

# MCP (start server, Ctrl+C to stop)
.build/debug/ghost mcp

# Recipes
.build/debug/ghost recipes
.build/debug/ghost recipe show gmail-send
```

When testing actions, be aware that they interact with real apps on your screen. `ghost click "Send"` will actually send whatever is in your compose window.

## Project Structure

```
Sources/
  GhostOS/
    State/
      ScreenState.swift        Data models (ScreenState, AppInfo, ActionResult, ContextInfo)
      StateManager.swift       Reads AX tree, builds state, content extraction
      ElementNode.swift        Serializable UI element with cycle detection
      ScreenCapture.swift      Window screenshots via ScreenCaptureKit
    Actions/
      ActionExecutor.swift     Click, type, press, hotkey, scroll, wait
      SmartResolver.swift      Fuzzy element matching (Levenshtein distance)
    Recipes/
      RecipeTypes.swift        Recipe, RecipeStep, Recording data models
      RecipeStore.swift        Filesystem storage (~/.ghost-os/recipes/)
      RecordingManager.swift   Records actions as they happen
      RecipeEngine.swift       Executes recipes with param substitution
    Protocol/
      RPCMessage.swift         JSON-RPC request/response types
      RPCHandler.swift         Routes 33 RPC methods
    MCP/
      MCPServer.swift          MCP server (27 tools, stdio, NDJSON + Content-Length)
    Observer/
      SystemObserver.swift     AX notification subscriptions
    Daemon/
      GhostDaemon.swift        Lifecycle, PID file, signal handling
      IPCServer.swift          Unix socket server
  ghost/
    main.swift                 CLI commands
    SetupWizard.swift          Interactive setup flow
```

## Questions?

Open a GitHub issue. We're happy to help.
