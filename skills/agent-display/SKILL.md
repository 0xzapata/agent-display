---
name: agent-display
description: Give an agent its own macOS virtual display for computer-use, browser, simulator, or UI test work, so the user's screen stays free. Use when a task needs a separate screen, a screenshot or recording of only the agent's screen, or an app moved off the user's display. Uses the agent-display CLI or its MCP tools (display_create, display_screenshot, ...).
---

# agent-display

`agent-display` makes named virtual displays on macOS. macOS treats each one as a real monitor.

## Pick the interface

- MCP tools (`display_*`) are present: use them. Displays you create are removed when your session ends.
- Otherwise use the CLI. Check with `command -v agent-display`. If it is absent, build it from
  https://github.com/0xzapata/agent-display (see its README), or tell the user it is not installed.

## Workflow

1. Create one display per task. Use a short unique name, for example `agent-<task>`.
   - MCP: `display_create {"name": "agent-login-test"}`.
   - CLI, tied to your command: `agent-display run agent-login-test -- <command>`. The display is
     removed when the command exits. Prefer this over `up` so a crash leaves nothing behind.
   - CLI, standing display: `agent-display up NAME &`, and later `agent-display down NAME`.
2. Move the app there: `display_open_app {"name": ..., "app": "Google Chrome"}` or
   `agent-display open NAME "Google Chrome"`. The window fills the display.
3. Look at it: `display_screenshot` (returns the image) or `agent-display shot NAME [path.png]`.
4. Record a flow when the user needs video proof: `agent-display record NAME out.mov --seconds 30`.
5. Remove the display when done: `display_remove` or `agent-display down NAME`. Displays from `run`
   and from MCP remove themselves.

All CLI commands print one JSON line on success and exit non-zero with a message on stderr on failure.

## Defaults and sizes

- Default size is 1440x900 points at 1x. Keep it: 1x screenshots have 4x fewer pixels than HiDPI,
  so they cost fewer image tokens, and a fixed size keeps screenshot tests repeatable.
- Use `--size WxH` (or MCP `size`) to match a target, for example `1280x800` or `390x844` portrait
  web views. Use `--hidpi` only when the task checks Retina rendering.
- `run` exports `AGENT_DISPLAY_NAME`, `AGENT_DISPLAY_ID` and `AGENT_DISPLAY_BOUNDS` (`x,y,w,h` in
  global points) to the command. Use the bounds to place windows or to click in the right area.

## Limits you must respect

- macOS has one mouse pointer and one keyboard focus for all displays. Clicking or typing on your
  display still moves the user's pointer and can take focus. For browsers, prefer Playwright or the
  Chrome DevTools Protocol, which do not move the pointer. Warn the user before long click-driven work.
- `open` needs Accessibility permission, and `shot`/`record` need Screen Recording permission, for the
  app that runs the agent (Terminal, T3 Code, ...). On a permission error, tell the user which
  setting to turn on: System Settings > Privacy & Security.
- Never remove a display you did not create. `display_list` / `agent-display list` show all displays,
  including the user's physical ones.
- The tool uses private CoreGraphics classes. If creation fails after a macOS update, report it; do not retry in a loop.
