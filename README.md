# Ghost OS

Give your AI agent eyes and hands on macOS.

Ghost OS reads the macOS accessibility tree and gives your AI agent structured data about every button, text field, link, and label on screen. No screenshots. No OCR. No pixel-guessing. It can also click, type, scroll, and press keys in any app.

It works with Claude Code, Claude Desktop, or any MCP-compatible AI agent.

## Quick Start

```bash
# Build from source (macOS 14+, Swift 6.2+)
git clone https://github.com/mcheemaa/ghost-os.git
cd ghost-os
swift build

# Set up permissions and MCP config
.build/debug/ghost setup
```

That's it. Start a new Claude Code session and ask it to interact with any app on your screen.

## What It Actually Does

```bash
$ ghost context --app Chrome
App: Google Chrome
Window: Inbox (38,207) - cheemawrites@gmail.com - Gmail
URL: https://mail.google.com/mail/u/0/#inbox
Focused: AXGroup
Windows/Tabs: 2
  1. Inbox (38,207) - cheemawrites@gmail.com - Gmail
  2. Cloudflare Dashboard
```

```bash
$ ghost state --summary
Screen State (20 apps, 127 windows)
  Active: iTerm2
  Focused: AXTextArea "shell" in iTerm2
  Background: Slack (7w), Messages (12w), GitHub Desktop (6w), ...
```

```bash
$ ghost click "Compose" --app Chrome
Clicked 'Compose' at (98,342) via synthetic (AX-native .press silently failed)
  Method: synthetic (AX-native verify-and-retry)

App: Google Chrome
URL: https://mail.google.com/mail/u/0/#inbox?compose=new
Focused: AXComboBox "To"
```

Every action returns what happened and where you ended up. The agent doesn't need a separate call to check the result.

## Why This Exists

Every major AI company is racing to let agents use computers. They all do it the same way: take a screenshot, send it to a frontier vision model, get back "click at pixel (412, 307)", repeat. That's using the most powerful AI ever created to figure out where a button is on screen.

The accessibility tree already has that information. Every app on macOS exposes its UI structure through the accessibility API. The same data that screen readers use to help blind users navigate a computer. Structured, instant, free.

Ghost OS makes that data available to AI agents. Instead of processing a 500KB screenshot through a vision model to find a "Compose" button, the agent gets `AXButton "Compose" at (98, 342)` in 50ms.

## Installation

### From Source

```bash
git clone https://github.com/mcheemaa/ghost-os.git
cd ghost-os
swift build
```

Requirements:
- macOS 14 (Sonnet) or later
- Swift 6.2+ (install via [Swiftly](https://swiftlang.github.io/swiftly/))
- Xcode Command Line Tools

### Setup

```bash
.build/debug/ghost setup
```

The setup wizard walks you through:
1. **Accessibility permission** - Ghost OS needs this to read the screen. System Settings will open automatically.
2. **Screen Recording permission** (optional) - Only needed for `ghost screenshot`. Useful for visual debugging.
3. **MCP configuration** - Auto-detects Claude Code and Claude Desktop, configures them to use Ghost OS.

## Using with Claude Code

If `ghost setup` detected Claude Code, it already configured the MCP server. Start a new session and Ghost OS tools are available.

### Manual setup

```bash
claude mcp add --transport stdio ghost-os -- /path/to/ghost mcp
```

Add the permission allow rule to avoid tool approval prompts. In your project's `.claude/settings.local.json`:

```json
{
  "permissions": {
    "allow": ["mcp__ghost-os__*"]
  }
}
```

### Test it

In Claude Code, try:
- "What apps are on my screen?"
- "What page is open in Chrome?"
- "Send an email to test@example.com with subject 'Hello' and body 'Testing Ghost OS'"

## Using with Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "ghost-os": {
      "command": "/path/to/ghost",
      "args": ["mcp"]
    }
  }
}
```

Replace `/path/to/ghost` with the actual path to the binary (e.g., `/Users/you/ghost-os/.build/debug/ghost`).

## CLI Reference

Ghost OS has 28 commands. Every command works in direct mode (no daemon needed).

### Perception (read the screen, no focus needed for web apps)

| Command | What it does |
|---------|-------------|
| `ghost context --app Chrome` | Where am I? URL, focused element, interactive elements |
| `ghost state --summary` | All running apps and windows |
| `ghost read --app Chrome` | Read all text content from an app |
| `ghost find "Send" --deep --app Chrome` | Find elements by text (deep search into web content) |
| `ghost tree --app Chrome` | Raw accessibility element tree |
| `ghost describe --app Chrome` | Natural language screen description |
| `ghost diff` | What changed since last check |
| `ghost screenshot --app Chrome` | Capture window as PNG (for visual debugging) |

### Actions (interact with apps)

| Command | What it does |
|---------|-------------|
| `ghost click "Compose" --app Chrome` | Smart click: fuzzy find + AX-native first + fallback |
| `ghost click --at 680,52` | Click at exact coordinates |
| `ghost click "file.txt" --double --app Finder` | Double-click (open files) |
| `ghost click "file.txt" --right --app Finder` | Right-click (context menu) |
| `ghost type "Hello" --into "To" --app Chrome` | Type into a specific field |
| `ghost press return` | Press a key |
| `ghost hotkey cmd,s` | Key combination |
| `ghost scroll down` | Scroll |
| `ghost focus Chrome` | Bring app to foreground |
| `ghost wait urlContains "google.com" --timeout 10` | Wait for a condition (replaces sleep) |

### Recipes (multi-step workflows)

| Command | What it does |
|---------|-------------|
| `ghost recipes` | List available recipes |
| `ghost run gmail-send --param recipient=test@example.com --param subject=Hello --param body=Hi` | Run a recipe |
| `ghost recipe show gmail-send` | View recipe details |
| `ghost recipe save recipe.json` | Install a recipe from file |
| `ghost record start my-flow` | Start recording commands |
| `ghost record stop` | Stop and save recording |

### Utility

| Command | What it does |
|---------|-------------|
| `ghost setup` | Interactive setup wizard |
| `ghost mcp` | Start MCP server (spawned by Claude Code/Desktop) |
| `ghost permissions` | Check accessibility permissions |
| `ghost version` | Show version |

## How It Works

Ghost OS is built on [AXorcist](https://github.com/steipete/AXorcist), a Swift accessibility library. It adds:

- **StateManager** - Reads the full screen state: every app, window, and element. Uses semantic depth to tunnel through empty CSS wrapper divs and reach content 30+ levels deep in web apps.
- **ActionExecutor** - Tries AX-native methods first (`performAction(.press)`, `setValue`), verifies they worked, falls back to synthetic input (mouse/keyboard events). Every action returns a result with post-action context.
- **SmartResolver** - Fuzzy element matching. `ghost click "Compose"` finds the best match by Levenshtein distance, scores content-tree matches higher than menu items.
- **RecipeEngine** - Multi-step workflow execution with parameter substitution, wait conditions, failure detection, and automatic focus restore.
- **MCPServer** - Model Context Protocol over stdin/stdout. Auto-detects NDJSON (Claude Desktop) vs Content-Length framing. 27 tools mapped to the full Ghost OS API.

## Permissions

### Accessibility (required)

Ghost OS reads the accessibility tree. macOS requires explicit permission for this.

Go to: **System Settings > Privacy & Security > Accessibility** and add your terminal app (iTerm2, Terminal, Warp, VS Code, etc.).

When running through MCP, the permission attaches to the MCP client. If you use Claude Code, add the terminal app that runs Claude Code. If you use Claude Desktop, add Claude Desktop itself.

### Screen Recording (optional)

Only needed for `ghost screenshot`. Useful for visual debugging when the accessibility tree doesn't tell the whole story.

Go to: **System Settings > Privacy & Security > Screen Recording** and add your terminal app.

## Things to Know

These are real issues we hit during development. Not hypothetical edge cases.

**Chrome tabs are invisible.** Chromium doesn't expose tabs through the accessibility API. You can't list tabs or find a specific tab. Navigate by URL instead: `ghost hotkey cmd,l` then `ghost type "google.com"` then `ghost press return`.

**Web apps work from background. Native apps need focus.** Chrome, Slack, and other Electron/web apps are fully readable without bringing them to the foreground. Native macOS apps (GitHub Desktop, Preview, Claude) only expose their menu bar from background. Call `ghost focus <app>` before reading native apps.

**AX-native actions work on native apps, not Chrome.** `performAction(.press)` works on Messages buttons but silently fails on Chrome web content. Ghost OS detects this through verify-and-retry: it checks whether the context changed after the action, and falls back to synthetic click if nothing happened.

**Gmail autocomplete needs Enter.** After typing an email address in Gmail's To field, press Enter to confirm the autocomplete suggestion before moving to the next field.

**Modifier keys are automatically cleared.** After every hotkey command, Ghost OS sends a CGEvent to clear stuck modifier keys. Without this, typing after `cmd,l` would produce Cmd+character shortcuts instead of plain text.

**Permission dialog breaks agent workflows.** If Accessibility permission isn't granted before the agent starts, macOS shows a dialog that steals focus and confuses the agent. Always run `ghost setup` first.

## Architecture

```
ghost-os/
  Sources/
    GhostOS/                    (library, ~6500 lines)
      State/                    ScreenState, StateManager, ElementNode, ScreenCapture
      Actions/                  ActionExecutor, SmartResolver
      Recipes/                  RecipeTypes, RecipeStore, RecordingManager, RecipeEngine
      Protocol/                 RPCMessage, RPCHandler (33 RPC methods)
      MCP/                      MCPServer (27 MCP tools)
      Observer/                 SystemObserver (AX notifications)
      Daemon/                   GhostDaemon, IPCServer
    ghost/                      (CLI, ~1400 lines)
      main.swift                28 commands
      SetupWizard.swift         Interactive setup
```

The MCP agent instruction document is at [GHOST-MCP.md](GHOST-MCP.md). It's served to the AI agent on MCP initialization and covers focus rules, workflow patterns, Chrome/Gmail knowledge, and recipe usage.

## License

MIT. See [LICENSE](LICENSE).

Built on [AXorcist](https://github.com/steipete/AXorcist) by Peter Steinberger (MIT).
