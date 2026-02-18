# GHOST.md — How to Use Ghost OS

You are an AI agent with access to Ghost OS, a tool that lets you see and operate
any macOS application through the accessibility tree. This document teaches you
how to think about screen interaction.

You do not need screenshots to understand what's on screen. Ghost OS reads the
macOS accessibility tree — every button, text field, link, and label in every app
is available as structured data. Screenshots are a fallback for debugging, not
your primary sense.

---

## Step 0: Check for Recipes

**Your first call for any multi-step task must be `ghost recipes`.**

```bash
ghost recipes
```

If a recipe exists for what you need, use it. Recipes handle timing, element
finding, wait conditions, and failure detection. They are tested workflows.

```bash
ghost run gmail-send \
  --param recipient=someone@example.com \
  --param "subject=Meeting tomorrow" \
  --param "body=Can we reschedule to 3pm?"
```

Do NOT read recipe files from disk. Do NOT assume you know what recipes exist.
Call `ghost recipes` and read the output. This is the only reliable way to
discover available recipes — especially when Ghost OS is accessed through MCP,
where you have no filesystem access.

**If a recipe exists, use it. If not, proceed to Step 1.**

---

## Step 1: Orient

Before touching anything, know where you are.

```bash
ghost context --app Chrome
```

This tells you:
- Which app, which window, which URL (for browsers)
- What element is focused (text field? button? page body?)
- What interactive elements are visible (buttons, links, fields)

**If you skip this step, you will click the wrong thing.** The most common
agent mistake is acting without knowing the starting state.

### Context Awareness Checklist
- Which app is frontmost? (`ghost context`)
- Is the target app the one you think it is? (`ghost context --app Chrome`)
- Is the right page/tab/window active? (check URL and window title)
- Is the right account logged in? (check window title for email/username)
- Is a dialog or modal blocking? (check focused element)

---

## Step 2: Navigate to Where You Need to Be

Most tasks require a precondition: the right app on the right page with the
right account. Ghost OS has tools for seeing and acting, but navigation is
your job. Here are the patterns.

### Navigate Chrome to a URL
```bash
ghost focus Chrome && sleep 0.3 && \
  ghost hotkey cmd,l && sleep 0.3 && \
  ghost type "mail.google.com/mail/u/3/#inbox" --delay 0.03 && \
  sleep 0.2 && ghost press return && \
  ghost wait urlContains "mail.google.com" --timeout 15 --app Chrome && \
  ghost focus iTerm2
```
Key details:
- `cmd,l` selects the address bar (works on any page)
- `--delay 0.03` prevents Chrome's omnibox from mangling fast input
- `ghost wait` replaces fragile `sleep` — waits for the page to actually load
- Always return focus to iTerm2 at the end

### Switch Chrome accounts (Gmail, Google apps)
Gmail uses `/mail/u/N/` where N is the account index. You may need to try
a few values. Check the window title after navigation — it shows the email
address. Common pattern:
```bash
# Navigate directly to the right account
ghost focus Chrome && sleep 0.3 && \
  ghost hotkey cmd,l && sleep 0.3 && \
  ghost type "mail.google.com/mail/u/3/#inbox" --delay 0.03 && \
  sleep 0.2 && ghost press return && \
  ghost wait urlContains "mail.google.com/mail/u/3" --timeout 15 --app Chrome && \
  ghost context --app Chrome && ghost focus iTerm2
```
The context output will show the window title with the account email. If it's
the wrong account, try a different number.

### Chrome tabs
**Chrome tabs are invisible to the accessibility API.** This is a Chromium
design limitation, not a Ghost OS limitation. You cannot enumerate open tabs.

What you CAN do:
- `ghost context --app Chrome` shows the ACTIVE tab's URL and title
- `cmd,1` through `cmd,9` switches to tab by position
- `ctrl,tab` cycles to the next tab
- `cmd,l` then type a URL navigates the current tab directly
- The window title includes the active tab's title

**Do not waste time trying to find or list tabs.** Navigate directly to the
URL you need using `cmd,l`. This is always faster than trying to find an
existing tab.

### Open or switch to an app
```bash
ghost focus Chrome           # if already running
ghost focus Messages         # native apps too
ghost focus "System Settings"  # use full name for apps with spaces
```
If the app isn't running, you'll get an error. Use `ghost state --summary`
to see what's running.

---

## Step 3: Act

Every multi-step workflow follows: **Focus → Act → Read Result → Repeat**

### Focus the target app first
```bash
ghost focus Chrome && sleep 0.3
```
Always sleep 0.3s after focus — the app needs time to become active.

### Click, type, press
```bash
ghost click "Compose" --app Chrome
ghost type "hello@example.com" --into "To" --app Chrome
ghost press return
ghost hotkey cmd,return
```

Every smart action (click, type) returns post-action context automatically.
You never need a separate "verify" step — the result IS the verification.

### Wait instead of sleep
For navigation and state changes, use `ghost wait` instead of fixed sleeps:
```bash
ghost wait urlContains "inbox" --timeout 10 --app Chrome
ghost wait elementExists "Add to Cart" --timeout 10 --app Chrome
```

### Return focus when done
```bash
ghost focus iTerm2
```
Always return focus to the terminal. Otherwise you leave the user stranded
in another app.

### Chain everything in a single command
If you issue focus, click, type as separate commands, you risk focus switching
between them, escape keys interrupting Claude Code, or timing issues.

```bash
ghost focus Chrome && sleep 0.3 && \
  ghost click "Compose" --app Chrome && sleep 0.5 && \
  ghost type "recipient@email.com" --into "To" --app Chrome && sleep 0.3 && \
  ghost press return && sleep 0.5 && \
  ghost type "Subject line" --into "Subject" --app Chrome && sleep 0.3 && \
  ghost type "Body text" --into "Message Body" --app Chrome && sleep 0.3 && \
  ghost hotkey cmd,return && \
  ghost wait urlContains "#inbox" --timeout 10 --app Chrome && \
  ghost focus iTerm2
```

---

## Recipes

### Using recipes
```bash
ghost recipes                                    # list available recipes
ghost run <name> --param key=value               # run with parameters
ghost run <name> --params-json '{"key":"value"}'  # bulk params as JSON
ghost recipe show <name>                          # view recipe details
```

### When to use recipes vs manual commands
- **Recipe exists, params match**: always use the recipe
- **Recipe exists, needs adaptation**: run it, see where it fails, do the
  remaining steps manually
- **No recipe exists**: do it manually. Consider creating a recipe if you'll
  repeat the task.

### Creating recipes
A recipe is a JSON file with parameterized steps:

```json
{
  "schema_version": 1,
  "name": "my-recipe",
  "description": "What this recipe does",
  "app": "Chrome",
  "params": {
    "input": {"type": "string", "description": "What to type", "required": true}
  },
  "steps": [
    {"id": 1, "action": "focus", "params": {"app": "Chrome"}},
    {
      "id": 2, "action": "click",
      "params": {"target": "Search", "app": "Chrome"},
      "wait_after": {"condition": "elementExists", "value": "Search field", "timeout": 5}
    },
    {
      "id": 3, "action": "type",
      "params": {"text": "{{input}}", "target": "Search", "app": "Chrome"},
      "delay_ms": 300
    }
  ]
}
```

Key rules:
- **`params` values are always strings** — even hotkey arrays: `"keys": "cmd,return"`
- **`{{param}}` substitution** happens before execution
- **Every step that uses `wait_after` MUST include `"app"` in params** — otherwise
  the wait checks the frontmost app, which may have changed
- **`wait_after`** validates the action succeeded (always stops on failure)
- **`delay_ms`** settles the UI before the NEXT step (not the current one)
- **Actions map to smart variants**: `click` → `smartClick`, `type` → `smartType`

Install: `ghost recipe save /path/to/recipe.json`

---

## Recordings

You can record manual interactions for later analysis:

```bash
ghost record start my-workflow    # start recording
# ... do things ...
ghost record stop                 # stop and save to disk

ghost recordings                  # list saved recordings
ghost recordings show <name>      # inspect the raw log
```

Ghost OS does not automatically convert recordings to recipes. **That is your
job.** Recordings are raw evidence — they include mistakes, retries, pauses.
Read a recording, understand what worked, then craft a clean recipe from it.

---

## Tool Reference

### Perception (read-only, no focus needed for web apps)
| Command | Purpose |
|---------|---------|
| `ghost context --app <name>` | Where am I? URL, focused element, available actions |
| `ghost state --summary` | Quick overview of all apps and windows |
| `ghost read --app <name>` | Read all text content (large output — use --limit) |
| `ghost find "text" --deep --app <name>` | Search for elements deep in the tree |
| `ghost find "text" --smart --app <name>` | Fuzzy search with confidence scores |
| `ghost tree --app <name> --depth 6` | Dump element tree structure |
| `ghost screenshot --app <name>` | Visual capture for debugging when AX is unclear |

### Action (requires focus for most apps)
| Command | Purpose |
|---------|---------|
| `ghost focus <app>` | Bring app to foreground (always do this first) |
| `ghost click "label" --app <name>` | Smart click — AX-native first, synthetic fallback |
| `ghost click "label" --double` | Double-click (open files, select words) |
| `ghost click "label" --right` | Right-click (context menus) |
| `ghost click --at x,y` | Click exact coordinates (last resort) |
| `ghost type "text"` | Type at current focus |
| `ghost type "text" --into "field" --app <name>` | Find field by label, then type |
| `ghost press <key>` | Press a key (return, tab, escape, space, delete, arrows) |
| `ghost hotkey cmd,s` | Key combination (modifiers auto-cleared afterward) |
| `ghost scroll down` | Scroll (up, down, left, right) |

### Waiting (replaces sleep)
| Command | Purpose |
|---------|---------|
| `ghost wait urlContains "text" --app <name>` | Wait until URL contains text |
| `ghost wait titleContains "text" --app <name>` | Wait until title contains text |
| `ghost wait elementExists "text" --app <name>` | Wait until element appears |
| `ghost wait elementGone "text" --app <name>` | Wait until element disappears |

### Recipes and Recording
| Command | Purpose |
|---------|---------|
| `ghost recipes` | List available recipes |
| `ghost run <recipe> --param key=value` | Execute a recipe with parameters |
| `ghost recipe show <name>` | View recipe details |
| `ghost recipe save <file>` | Install a recipe from JSON file |
| `ghost record start <name>` | Start recording commands |
| `ghost record stop` | Stop recording and save |
| `ghost recordings` | List saved recordings |

---

## What Works and What Doesn't

### Web apps (Chrome, Slack, etc.)
- Fully readable from background — no focus needed to read content
- AX-native click silently fails on Chrome — Ghost OS auto-detects and uses
  synthetic click. This is transparent to you.
- `--into` field targeting works via AXDescription labels
- Tab navigation between fields works with `ghost press tab`

### Native macOS apps (Messages, Finder, System Settings)
- Need focus to read content (menus visible from background, content is not)
- AX-native actions work directly — Messages buttons respond to .press
- `setValue` works for text fields — instant, no character-by-character typing

### Known limitations
- **Chrome tabs are invisible** to the AX API. Navigate directly via URL.
- **Gmail To field** needs Return after typing to confirm the autocomplete
- **Chrome address bar** needs `--delay 0.03` for reliable typing
- **Sleep 0.3s** between focus and first action (app activation time)
- **Always return focus to iTerm2** at the end of any action chain

---

## Debugging

When something goes wrong:

1. `ghost context --app Chrome` — is the app in the state you expect?
2. `ghost find "text" --deep --app Chrome` — does the element exist?
3. `ghost screenshot --app Chrome` — visual confirmation when AX is unclear
4. Action failures auto-include debug screenshots saved to /tmp/

---

## Key Principle

Ghost OS is your eyes and hands. You are the brain. Ghost OS sees accurately,
acts reliably, and reports what happened. You decide what to do, when to retry,
and when to try something different.
