# GHOST.md — How to Use Ghost OS

You are an AI agent with access to Ghost OS, a tool that lets you see and operate
any macOS application through the accessibility tree. This document teaches you
how to think about screen interaction.

## The Core Idea

You do not need screenshots to understand what's on screen. Ghost OS reads the
macOS accessibility tree — every button, text field, link, and label in every app
is available as structured data. Screenshots are a fallback for debugging, not
your primary sense.

Ghost OS gives you two things:
- **Eyes**: see what's on screen (state, context, content, elements)
- **Hands**: act on what you see (click, type, press, hotkey, scroll, focus)

Every action returns what happened AND where you landed afterward. You never need
a separate "verify" step — the result IS the verification.

## Before You Do Anything: Orient

Before touching anything, know where you are.

```bash
ghost context --app Chrome
```

This tells you:
- Which app, which window, which URL (for browsers)
- What element is focused (text field? button? page body?)
- What interactive elements are visible (buttons, links, fields)
- Whether the app needs focus for interaction

**If you skip this step, you will click the wrong thing.** The most common agent
mistake is acting without knowing the starting state.

### Context Awareness Checklist
- Which app is frontmost? (`ghost context`)
- Is the target app the one you think it is? (`ghost context --app Chrome`)
- Is the right page/tab/window active? (check URL and window title)
- Is a dialog or modal blocking? (check focused element)
- Is a compose window already open? (check for expected elements)

## The Interaction Pattern

Every multi-step workflow follows this pattern:

```
Orient → Focus → Act → Read Result → (repeat)
```

### 1. Orient
```bash
ghost context --app Chrome
```

### 2. Focus the target app
```bash
ghost focus Chrome && sleep 0.3
```
Always sleep 0.3s after focus — the app needs time to become active.

### 3. Act
```bash
ghost click "Compose" --app Chrome
ghost type "hello@example.com" --into "To" --app Chrome
ghost press return
ghost hotkey cmd,return
```

### 4. Read the result
Every smart action (click, type) returns post-action context automatically.
For navigation, use `ghost wait` instead of sleep:
```bash
ghost wait urlContains "inbox" --timeout 10 --app Chrome
```

### 5. Return focus
```bash
ghost focus iTerm2
```
Always return focus to the terminal when done. Otherwise you leave the user
stranded in another app.

## Command Chaining

**Chain everything in a single command.** If you issue focus, click, type as
separate commands, you risk focus switching between them, escape keys interrupting
Claude Code, or timing issues.

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

## Recipes: Use Them First

Before doing any multi-step task manually, check if a recipe exists:

```bash
ghost recipes
```

Recipes are tested, parameterized workflows that handle timing, waits, and
failure detection for you.

```bash
ghost run gmail-send \
  --param recipient=someone@example.com \
  --param "subject=Meeting tomorrow" \
  --param "body=Can we reschedule to 3pm?"
```

The recipe engine handles: focus management, element finding, AX-native vs
synthetic fallback, wait conditions, delay timing, failure screenshots. You
get a structured result with per-step details.

### When to use recipes vs manual commands
- **Recipe exists, params match**: always use the recipe
- **Recipe exists, needs adaptation**: run it, see where it fails, then do
  the remaining steps manually
- **No recipe exists**: do it manually, consider creating a recipe if you'll
  do it again

## Recordings: Raw Material, Not Recipes

You can record your manual interactions:

```bash
ghost record start my-workflow
# ... do things ...
ghost record stop
```

Ghost OS does not automatically convert recordings to recipes. **That is your
job.** Recordings are raw evidence — they include mistakes, retries, pauses.
Read a recording, understand what worked, then craft a clean recipe from it.

```bash
ghost recordings                    # list saved recordings
ghost recordings show my-workflow   # inspect the raw log
```

## Tool Reference

### Perception (read-only, no focus needed for web apps)
| Command | Purpose |
|---------|---------|
| `ghost context --app <name>` | Where am I? URL, focused element, available actions |
| `ghost state --summary` | Quick overview of all apps and windows |
| `ghost read --app <name>` | Read all text content (large output — use --limit) |
| `ghost find "text" --deep --app <name>` | Search for specific elements deep in the tree |
| `ghost find "text" --smart --app <name>` | Fuzzy search with confidence scores |
| `ghost tree --app <name> --depth 6` | Dump element tree structure |
| `ghost screenshot --app <name>` | Visual capture for debugging when AX is unclear |

### Action (requires focus for most apps)
| Command | Purpose |
|---------|---------|
| `ghost focus <app>` | Bring app to foreground (always do this first) |
| `ghost click "label" --app <name>` | Smart click — finds element, tries AX-native, falls back to synthetic |
| `ghost click "label" --double` | Double-click (open files, select words) |
| `ghost click "label" --right` | Right-click (context menus) |
| `ghost click --at x,y` | Click exact coordinates (last resort) |
| `ghost type "text"` | Type at current focus |
| `ghost type "text" --into "field" --app <name>` | Find field by label, then type into it |
| `ghost press <key>` | Press a key (return, tab, escape, space, delete, arrow keys) |
| `ghost hotkey cmd,s` | Key combination (modifiers auto-cleared afterward) |
| `ghost scroll down` | Scroll (up, down, left, right) |

### Waiting (replaces sleep for navigation and state changes)
| Command | Purpose |
|---------|---------|
| `ghost wait urlContains "text" --app <name>` | Wait until URL contains text |
| `ghost wait titleContains "text" --app <name>` | Wait until window title contains text |
| `ghost wait elementExists "text" --app <name>` | Wait until element appears |
| `ghost wait elementGone "text" --app <name>` | Wait until element disappears |

### Recipes and Recording
| Command | Purpose |
|---------|---------|
| `ghost recipes` | List available recipes |
| `ghost run <recipe> --param key=value` | Execute a recipe with parameters |
| `ghost recipe show <name>` | View recipe details |
| `ghost record start <name>` | Start recording commands |
| `ghost record stop` | Stop recording and save |
| `ghost recordings` | List saved recordings |

## What Works and What Doesn't

### Web apps (Chrome, Slack, etc.)
- Fully readable from background — no focus needed to read content
- AX-native click (.press) silently fails — Ghost OS auto-detects and retries
  with synthetic click. You don't need to worry about this.
- `--into` field targeting works via AXDescription labels
- Tab navigation between fields works with `ghost press tab`

### Native macOS apps (Messages, Finder, System Settings)
- Need focus to read content (menus visible from background, content is not)
- AX-native actions work directly — Messages buttons respond to .press
- `setValue` works for text fields — instant, no character-by-character typing

### Things to watch for
- **Gmail To field**: press Return after typing to confirm the autocomplete,
  then wait 500ms before typing Subject
- **Chrome address bar**: use `ghost hotkey cmd,l` then type URL with
  `--delay 0.03` flag for reliability
- **Chrome tabs are invisible** to the AX API — use `ctrl,tab` to cycle,
  `ghost context` to check which tab is active
- **Sleep between focus and first action**: 0.3s minimum
- **Always return focus to iTerm2**: end every chain with `ghost focus iTerm2`

## Creating Recipes

A recipe is a JSON file with parameterized steps. Each step maps to a Ghost OS
command. Here's the structure:

```json
{
  "schema_version": 1,
  "name": "my-recipe",
  "description": "What this recipe does",
  "app": "Chrome",
  "params": {
    "input": {
      "type": "string",
      "description": "What to type",
      "required": true
    }
  },
  "steps": [
    {
      "id": 1,
      "action": "focus",
      "params": {"app": "Chrome"}
    },
    {
      "id": 2,
      "action": "click",
      "params": {"target": "Search", "app": "Chrome"},
      "wait_after": {"condition": "elementExists", "value": "Search field", "timeout": 5}
    },
    {
      "id": 3,
      "action": "type",
      "params": {"text": "{{input}}", "target": "Search", "app": "Chrome"},
      "delay_ms": 300
    }
  ]
}
```

Key rules:
- **`params` values are always strings** — even for hotkey arrays: `"keys": "cmd,return"`
- **`{{param}}` substitution** happens before execution
- **`wait_after`** validates the action succeeded (always stops on failure)
- **`delay_ms`** settles the UI before the NEXT step (not before the current one)
- **`on_failure`**: `"stop"` (default) halts with debug screenshot, `"skip"` continues
- **Actions map to smart variants**: `click` becomes `smartClick`, `type` becomes `smartType`

Install a recipe:
```bash
ghost recipe save /path/to/recipe.json
```

## Debugging

When something goes wrong:

1. **Check context first**: `ghost context --app Chrome` — is the app in the
   state you expect?
2. **Search for the element**: `ghost find "Button Text" --deep --app Chrome` —
   does it exist? What's its role?
3. **Take a screenshot**: `ghost screenshot --app Chrome` — visual confirmation
   of what's actually on screen
4. **Action failures include screenshots**: when click/type fails, the error
   includes a debug screenshot saved to /tmp/

The debugging loop: action fails → read error message → check context →
screenshot if unclear → adjust approach → retry.

## Key Principle

Ghost OS is your eyes and hands. You are the brain. Ghost OS does not make
decisions — it sees accurately, acts reliably, and reports what happened.
You decide what to do, when to retry, and when to try something different.
