<p align="center">
  <h1 align="center">Ghost OS</h1>
  <p align="center">Make Claude Code control your computer.</p>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-black.svg" alt="macOS 14+">
  <img src="https://img.shields.io/badge/swift-6.2-orange.svg" alt="Swift 6.2">
  <img src="https://img.shields.io/badge/MCP-compatible-green.svg" alt="MCP Compatible">
</p>

---

Your AI coding agent can write code, run tests, search files. But it can't see your screen. It can't click a button in Chrome, send an email, fill out a form, or read what's in Slack.

Ghost OS fixes that. Install it, and Claude Code can see and operate every app on your Mac.

```
You:     "Send an email to sarah@company.com about the Q4 report"
Claude:  [opens Gmail, clicks Compose, types recipient, subject, body, sends]
         Done. Email sent from your Gmail account.
```

No screenshots. No vision models burning tokens on pixel-guessing. Ghost OS reads the macOS accessibility tree directly. Every button, text field, link, and label is structured data. The same information screen readers use, delivered as JSON to your AI agent.

## Install

```bash
brew install mcheemaa/ghost-os/ghost-os
ghost setup
```

<details>
<summary>Build from source</summary>

```bash
git clone https://github.com/mcheemaa/ghost-os.git
cd ghost-os
swift build
.build/debug/ghost setup
```

Requires macOS 14+, Swift 6.2+ ([install via Swiftly](https://swiftlang.github.io/swiftly/)), Xcode Command Line Tools.

</details>

`ghost setup` handles everything: grants permissions, detects Claude Code, configures MCP, runs a verification test. One command.

Start a new Claude Code session. That's it. Your agent can now see your screen.

## What Can It Do

**See any app.** Claude Code can read the content of Chrome, Slack, Messages, Finder, or any app running on your Mac. Web apps work from background. No need to bring them to the front.

```
You:     "What's on my screen right now?"
Claude:  Screen State (20 apps, 127 windows)
           Active: VS Code
           Background: Chrome (Gmail), Slack (3 unread), Messages, Finder...
```

**Operate any app.** Click buttons, type into fields, press keys, scroll, navigate. Ghost OS tries the fast path first (accessibility API actions) and falls back to synthetic input when needed. Every action tells the agent what happened.

```
You:     "Click Compose in Gmail"
Claude:  Clicked 'Compose' at (98,342) via synthetic
         Now focused: To field in Gmail compose window
```

**Learn and repeat.** The first time your agent does something, it figures it out step by step. Record that as a recipe. Next time, it runs in seconds. Recipes are parameterized, so "send an email" becomes a reusable template with recipient, subject, and body as inputs.

```
You:     "Send a test email to john@example.com"
Claude:  [runs gmail-send recipe: 7 steps, 9.4 seconds, done]
```

**Debug visually.** When the accessibility tree isn't enough, Ghost OS captures a screenshot and the agent can see what's actually on screen. CAPTCHAs, canvas apps, weird layouts. The screenshot is the escape hatch, not the primary interface.

## How It Works

Most computer-use agents today rely on screenshots and vision models to understand what's on screen. That works, but it's expensive and slow because the model has to extract information (button positions, labels, field values) that the operating system already knows.

Ghost OS takes a different approach. It reads the accessibility tree, the same structured data that screen readers use. Every button, text field, and label is available as JSON, instantly, without a model call.

| | Screenshot approach | Accessibility tree approach |
|---|---|---|
| **How it sees** | Screenshot through a vision model | Structured JSON from the OS (50ms) |
| **How it acts** | "Click at pixel (412, 307)" | `performAction(.press)` on the actual element |
| **Cost per action** | Vision model API call | Zero (local OS call) |
| **Speed** | Seconds per action | Milliseconds per action |
| **Data quality** | Inferred from pixels | Exact labels, roles, positions, values from the app |
| **Works offline** | Needs API access | Yes (perception is local) |

These approaches aren't mutually exclusive. Ghost OS uses the accessibility tree as the primary source and falls back to screenshots when needed (canvas apps, PDFs, visual debugging). The best tool for each situation.

## The Recipe System

Ghost OS gets faster the more you use it.

**First time:** Your agent navigates Gmail manually. Click Compose, type To, press Enter (to confirm autocomplete), Tab to Subject, type it, Tab to Body, type it, Cmd+Enter to send. 7 steps, figured out on the fly.

**Record it:** Those 7 steps become a recipe. Parameterized with `{{recipient}}`, `{{subject}}`, `{{body}}`.

**Next time:** `ghost run gmail-send` with parameters. Same 7 steps, but replayed instantly. No thinking, no planning, just execution.

**Share it:** Recipes are JSON files. Drop them in `~/.ghost-os/recipes/` and they're available to every agent on your machine. Share them with your team. Share them with the community.

This is the opposite of hand-written skills. The agent learns by doing, records what worked, and reuses it. Every interaction makes it faster.

## Setup

### Permissions

Ghost OS needs two macOS permissions. Grant these to whatever terminal app you use (iTerm2, Terminal, Warp, VS Code, etc.).

1. **Accessibility** (required) - System Settings > Privacy & Security > Accessibility
   Add your terminal app. Ghost OS uses this to read the UI of every app on your screen.

2. **Screen Recording** (optional) - System Settings > Privacy & Security > Screen Recording
   Add your terminal app. Only needed for `ghost screenshot`. Skip this if you don't need screenshots.

Grant these **before** running `ghost setup`. If you skip this step, macOS will show a permission dialog during setup that can interrupt the process.

### What `ghost setup` does

```bash
ghost setup
```

1. Checks that Accessibility permission is granted
2. Checks Screen Recording permission (optional)
3. Detects Claude Code and registers Ghost OS as an MCP server
4. Runs a verification test to confirm everything works

### Manual Claude Code setup

If `ghost setup` can't auto-configure Claude Code (or you prefer to do it yourself):

```bash
claude mcp add --transport stdio ghost-os -- ghost mcp
```

Then allow all Ghost OS tools without approval prompts. Add to your project's `.claude/settings.local.json`:

```json
{
  "permissions": {
    "allow": ["mcp__ghost-os__*"]
  }
}
```

Start a new Claude Code session after setup. Your agent can now see your screen.

## CLI

28 commands. All work directly, no daemon needed.

<details>
<summary>Full command reference</summary>

### See the screen

| Command | Description |
|---------|-------------|
| `ghost context --app Chrome` | Current state: URL, focused element, interactive elements |
| `ghost state --summary` | All running apps and windows |
| `ghost read --app Chrome` | Full text content from any app |
| `ghost find "Send" --deep --app Chrome` | Find elements deep in web content |
| `ghost tree --app Chrome --depth 8` | Raw accessibility element tree |
| `ghost describe --app Chrome` | Natural language screen description |
| `ghost diff` | What changed since last check |
| `ghost screenshot --app Chrome` | Capture window as PNG |

### Act on apps

| Command | Description |
|---------|-------------|
| `ghost click "Compose" --app Chrome` | Smart click with fuzzy matching |
| `ghost click --at 680,52` | Click at coordinates |
| `ghost click "file" --double --app Finder` | Double-click |
| `ghost click "file" --right --app Finder` | Right-click |
| `ghost type "Hello" --into "To" --app Chrome` | Type into a specific field |
| `ghost type "Hello world"` | Type at current focus |
| `ghost press return` | Press a single key |
| `ghost hotkey cmd,s` | Key combination |
| `ghost scroll down --amount 5` | Scroll |
| `ghost focus Chrome` | Bring app to foreground |
| `ghost wait urlContains "google.com" --timeout 10` | Wait for a condition |

### Recipes

| Command | Description |
|---------|-------------|
| `ghost recipes` | List available recipes |
| `ghost run gmail-send --param recipient=x --param subject=y --param body=z` | Execute a recipe |
| `ghost recipe show gmail-send` | View recipe details |
| `ghost recipe save recipe.json` | Install a recipe from JSON |
| `ghost recipe delete my-recipe` | Delete a recipe |
| `ghost record start my-workflow` | Start recording actions |
| `ghost record stop` | Stop and save recording |

### Utility

| Command | Description |
|---------|-------------|
| `ghost setup` | Interactive setup wizard |
| `ghost mcp` | Start MCP server (spawned by Claude Code) |
| `ghost permissions` | Check accessibility permissions |
| `ghost version` | Print version |

</details>

## Things to Know

Real issues from development. Not hypothetical.

- **Chrome tabs are invisible.** Chromium doesn't expose tabs in the accessibility tree. Navigate by URL: `cmd,l` then type the URL.
- **Web apps work from background, native apps need focus.** Chrome and Slack are readable without bringing them forward. Native macOS apps (Preview, GitHub Desktop) only show their menu bar until you focus them.
- **Gmail autocomplete needs Enter.** After typing a recipient, press Enter to confirm. Otherwise the address won't stick.
- **Always run `ghost setup` first.** Permission dialogs during an agent session will break the workflow.

## Platform Support

Ghost OS is macOS-only today. The accessibility tree approach works on every OS:
- **macOS:** Accessibility Framework (AXUIElement) - what Ghost OS uses now
- **Windows:** UI Automation (UIA)
- **Linux:** AT-SPI (Assistive Technology Service Provider Interface)

Cross-platform support is on the roadmap. The architecture is designed for it. The perception layer, action layer, and recipe system are all platform-independent. Only the OS-specific accessibility bindings need to change.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on:
- Setting up the development environment
- How to submit pull requests
- Code conventions and architecture overview
- Testing your changes

## Architecture

Built on [AXorcist](https://github.com/steipete/AXorcist) (MIT), a Swift accessibility library by Peter Steinberger.

```
ghost-os/
  Sources/
    GhostOS/                        Library (~6500 lines)
      State/                        ScreenState, StateManager, ElementNode, ScreenCapture
      Actions/                      ActionExecutor (AX-native first), SmartResolver (fuzzy matching)
      Recipes/                      RecipeEngine, RecipeStore, RecordingManager
      Protocol/                     RPCHandler (33 methods), RPCMessage
      MCP/                          MCPServer (27 tools, NDJSON + Content-Length)
      Observer/                     SystemObserver (AX notifications)
      Daemon/                       GhostDaemon, IPCServer (Unix socket)
    ghost/                          CLI (~1500 lines)
      main.swift                    28 commands
      SetupWizard.swift             Interactive setup
```

The MCP instruction document ([GHOST-MCP.md](GHOST-MCP.md)) is served to Claude Code on connection. It teaches the agent how to use Ghost OS: focus management, workflow patterns, recipe-first approach, platform-specific knowledge.

## License

MIT. See [LICENSE](LICENSE).
