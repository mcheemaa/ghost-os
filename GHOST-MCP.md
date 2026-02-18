# Ghost OS — MCP Agent Instructions

You have Ghost OS, a tool that lets you see and operate any macOS application
through the accessibility tree. No screenshots needed — every button, text field,
link, and label is available as structured data.

**You are not in a terminal.** You call Ghost OS tools through MCP. Each tool call
is independent. There is no bash, no command chaining, no `sleep`. Think in terms
of individual tool calls.

---

## Rule 1: Always Check Recipes First

Before doing ANY multi-step task manually, call `ghost_recipes`.

If a recipe exists for what you need, use it. Recipes handle focus management,
timing, element finding, wait conditions, and failure detection. They are tested,
reliable, and faster than manual steps. Focus auto-restores to your app when a
recipe finishes.

Example: to send an email via Gmail, call `ghost_run` with recipe `gmail-send`
and params `{recipient, subject, body}`. Do NOT manually focus Chrome, click
Compose, type fields, etc. — the recipe does all of that in one atomic operation.

**If no recipe exists**, do it manually using the patterns below.

---

## Rule 2: Orient Before Acting

Before interacting with any app, call `ghost_context` with the app name.

This tells you:
- Which app and window are active
- The current URL (for browsers)
- What element is focused (text field? button? page?)
- What interactive elements are visible

**If you skip this, you will click the wrong thing.** Always know the starting
state before acting.

### Context Awareness Checklist
- Is the target app running? (`ghost_state`)
- Is the right page/tab active? (`ghost_context` — check URL and title)
- Is a dialog or modal blocking? (check focused element in context)
- Is the right account logged in? (check window title for email/username)

---

## Rule 3: Understand Focus

This is the most important concept. Different tools have different focus needs:

### Tools that work from background (no focus needed)
All perception tools read the accessibility tree without disturbing the user:
- `ghost_context`, `ghost_state`, `ghost_read`, `ghost_find`
- `ghost_tree`, `ghost_describe`, `ghost_diff`
- `ghost_screenshot` (uses ScreenCaptureKit, works on background windows)

### Smart action tools (handle focus automatically)
These tools try AX-native methods first (works from background), and auto-focus
the target app only if they need synthetic fallback:
- **`ghost_click`** with `app` parameter — tries `performAction(.press)` first
  (no focus needed), falls back to synthetic click (auto-focuses)
- **`ghost_type`** with `app` and `into` parameters — tries `setValue` first
  (no focus needed for native apps), falls back to typing (auto-focuses)

### Synthetic input tools (need the target app focused)
These tools send keyboard/mouse events to the **frontmost app**:
- **`ghost_press`** — press a single key (return, tab, escape, etc.)
- **`ghost_hotkey`** — key combo (cmd+s, cmd+l, cmd+return, etc.)
- **`ghost_scroll`** — scroll in a direction

**When you include the `app` parameter**, these tools auto-focus the target app
before executing. Always include `app` for these tools.

Good: `ghost_press(key: "return", app: "Chrome")` — focuses Chrome, then presses Return
Bad: `ghost_press(key: "return")` — presses Return in whatever app happens to be frontmost

### ghost_focus (explicit focus change)
Call `ghost_focus` when you need to bring an app to the foreground — for example,
before a sequence of press/hotkey calls to the same app. Focus persists between
tool calls, so you only need to focus once at the start of a sequence.

---

## Workflow Patterns

### Pattern: Click a button in an app
Just call `ghost_click` with the `app` parameter. No focus needed — AX-native
click works from background for most elements.

```
ghost_click(target: "Compose", app: "Chrome")
```

If AX-native click fails (common in Chrome), Ghost OS automatically focuses
the app and uses synthetic click. This is transparent to you.

### Pattern: Type into a specific field
Use `ghost_type` with `into` and `app` parameters:

```
ghost_type(text: "hello@example.com", into: "To", app: "Chrome")
```

### Pattern: Navigate Chrome to a URL
This requires multiple steps because address bar interaction is keyboard-based:

1. `ghost_hotkey(keys: "cmd,l", app: "Chrome")` — select address bar
2. `ghost_type(text: "mail.google.com", app: "Chrome")` — type URL
   (the address bar is already focused from step 1)
3. `ghost_press(key: "return", app: "Chrome")` — navigate
4. `ghost_wait(condition: "urlContains", value: "mail.google.com", timeout: 15, app: "Chrome")`

**Important Chrome address bar notes:**
- `cmd,l` reliably selects the address bar from any page
- Type the URL, then press Return to navigate
- Use `ghost_wait` to confirm the page loaded — never assume it's instant
- Chrome's New Tab page may steal focus from the address bar. Navigate from
  existing pages when possible.

### Pattern: Form filling (Gmail, web forms)
```
1. ghost_click(target: "Compose", app: "Chrome")
2. ghost_type(text: "recipient@email.com", into: "To", app: "Chrome")
3. ghost_press(key: "return", app: "Chrome")     ← confirms autocomplete
4. ghost_type(text: "Subject line", into: "Subject", app: "Chrome")
5. ghost_press(key: "tab", app: "Chrome")         ← move to body field
6. ghost_type(text: "Email body text", app: "Chrome")
7. ghost_hotkey(keys: "cmd,return", app: "Chrome") ← send
```

Key details:
- Gmail's To field has autocomplete — press Return after typing to confirm
- Use Tab to move between form fields
- `cmd,return` sends in Gmail

### Pattern: Wait for something to happen
Use `ghost_wait` instead of guessing when something is ready:

```
ghost_wait(condition: "urlContains", value: "inbox", timeout: 10, app: "Chrome")
ghost_wait(condition: "elementExists", value: "Compose", timeout: 10, app: "Chrome")
ghost_wait(condition: "elementGone", value: "Loading", timeout: 10, app: "Chrome")
```

Available conditions: `urlContains`, `titleContains`, `elementExists`,
`elementGone`, `urlChanged`, `titleChanged`.

### Pattern: Read page content
For a quick summary: `ghost_context(app: "Chrome")`
For full text content: `ghost_read(app: "Chrome", limit: 100)`
To find a specific element: `ghost_find(query: "Add to Cart", app: "Chrome", deep: true)`

**Be surgical with context.** `ghost_read` can return thousands of lines. Use
`ghost_context` for orientation and `ghost_find` for targeted queries.

### Pattern: When something goes wrong
1. `ghost_context(app: "Chrome")` — is the app in the state you expect?
2. `ghost_find(query: "error", app: "Chrome", deep: true)` — look for error messages
3. `ghost_screenshot(app: "Chrome")` — visual confirmation when AX is unclear

Action failures auto-include a debug screenshot saved to /tmp/.

---

## Chrome-Specific Knowledge

- **Tabs are invisible** to the accessibility API. You cannot list or enumerate tabs.
  Navigate directly to URLs with `cmd,l` instead of looking for tabs.
- **`ghost_context`** shows the active tab's URL and title — use this to check
  which page you're on.
- **Tab switching**: `cmd,1` through `cmd,9` for position, `ctrl,tab` for next tab.
- **AX-native click silently fails** on many Chrome elements — Ghost OS detects
  this and auto-falls back to synthetic click. This is transparent to you.
- **Web apps (Chrome, Slack)** are fully readable from background — no focus needed
  for perception tools.

## Native App Knowledge

- **Native macOS apps** (Messages, Finder, System Settings) need focus to read
  content beyond the menu bar. Call `ghost_focus` first, then `ghost_context`.
- **AX-native actions work directly** on native apps — Messages buttons respond
  to `.press`, text fields accept `setValue`. These are faster and work from background.
- **Messages and Finder** are exceptions — they're readable from background.

---

## Gmail-Specific Knowledge

- **Account selection**: Gmail URLs use `/mail/u/N/` where N is the account index
  (0, 1, 2, 3...). Navigate directly: `mail.google.com/mail/u/3/#inbox`
- **To field autocomplete**: After typing a recipient, press Return to confirm.
  The autocomplete dropdown must be dismissed before moving to the next field.
- **Send shortcut**: `cmd,return` sends the email in Gmail.
- **Window title** shows the account email — check it to verify you're in the
  right account.

---

## Recipes

### Using recipes
```
ghost_recipes()                                    — list available recipes
ghost_run(recipe: "name", params: {key: "value"})  — execute with parameters
ghost_recipe_show(name: "name")                     — view recipe details
```

### When to use recipes vs manual steps
- **Recipe exists, params match**: ALWAYS use the recipe
- **Recipe exists, needs adaptation**: run it, see where it fails, do remaining
  steps manually
- **No recipe exists**: do it manually. Consider creating a recipe if the task
  will be repeated.

### Creating recipes
Use `ghost_recipe_save` with a JSON string. Recipe format:
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
    {"id": 2, "action": "click", "params": {"target": "Search", "app": "Chrome"},
     "wait_after": {"condition": "elementExists", "value": "Search field", "timeout": 5}},
    {"id": 3, "action": "type", "params": {"text": "{{input}}", "app": "Chrome"},
     "delay_ms": 300}
  ]
}
```

Key rules:
- `params` values are always strings — even arrays: `"keys": "cmd,return"`
- `{{param}}` substitution happens before execution
- Every step with `wait_after` MUST include `"app"` in params
- Actions map to smart variants: `click` → smartClick, `type` → smartType

---

## Recordings

Record manual interactions for later analysis:
```
ghost_record_start(name: "my-workflow")  — start recording
... do things ...
ghost_record_stop()                       — stop and save
ghost_recordings()                        — list saved recordings
ghost_recording_show(name: "name")        — inspect the raw log
```

Recordings are raw evidence — they include mistakes and retries. Read a recording,
understand what worked, then craft a clean recipe from it.

---

## Common Mistakes

1. **Not checking recipes first.** Always call `ghost_recipes` before manually
   orchestrating a multi-step task. A tested recipe is always better.

2. **Skipping orientation.** Always call `ghost_context` before acting.
   You need to know the starting state.

3. **Forgetting `app` on press/hotkey/scroll.** These are synthetic input tools.
   Without `app`, the keypress goes to whatever app is frontmost — which might
   be Claude, not your target app. Always include `app`.

4. **Over-reading.** `ghost_read` returns everything on screen — often thousands
   of items. Use `ghost_context` for quick orientation and `ghost_find` for
   targeted queries. Only use `ghost_read` when you need comprehensive content.

5. **Trying to find Chrome tabs.** Tabs are invisible to the AX API. Don't waste
   time searching. Navigate directly to the URL you need with `cmd,l`.

6. **Not confirming Gmail autocomplete.** After typing in Gmail's To field,
   press Return to confirm the autocomplete suggestion. Without this, the
   recipient won't be set correctly.

7. **Assuming pages load instantly.** After navigating, use `ghost_wait` to
   confirm the page loaded before interacting with it.

8. **Reading recipe files from disk.** You have no filesystem access through MCP.
   Use `ghost_recipes` and `ghost_recipe_show` to discover and inspect recipes.

---

## Tool Quick Reference

| Tool | Purpose | Needs Focus? |
|------|---------|-------------|
| `ghost_context` | Where am I? URL, focused element, actions | No |
| `ghost_state` | All running apps and windows | No |
| `ghost_read` | Read all text content (use limit!) | No (web) |
| `ghost_find` | Search for elements by text | No (web) |
| `ghost_tree` | Raw element tree dump | No (web) |
| `ghost_describe` | Natural language screen description | No (web) |
| `ghost_screenshot` | Visual capture for debugging | No |
| `ghost_diff` | What changed since last check? | No |
| `ghost_click` | Click element by label or coords | Auto (with app) |
| `ghost_type` | Type text, optionally into a field | Auto (with app) |
| `ghost_press` | Press single key (return, tab, etc.) | Yes — use `app` |
| `ghost_hotkey` | Key combo (cmd+s, cmd+l, etc.) | Yes — use `app` |
| `ghost_scroll` | Scroll up/down | Yes — use `app` |
| `ghost_focus` | Bring app to foreground | N/A |
| `ghost_wait` | Wait for condition (replaces sleep) | No |
| `ghost_run` | Execute a recipe | Auto-restores |
| `ghost_recipes` | List available recipes | No |
| `ghost_recipe_show` | View recipe details | No |
| `ghost_recipe_save` | Install a new recipe | No |
| `ghost_recipe_delete` | Delete a recipe | No |
| `ghost_record_start` | Start recording commands | No |
| `ghost_record_stop` | Stop and save recording | No |
| `ghost_record_status` | Check recording status | No |
| `ghost_recordings` | List saved recordings | No |
| `ghost_recording_show` | View a recording | No |
| `ghost_refresh` | Force refresh screen state | No |
| `ghost_ping` | Health check | No |
