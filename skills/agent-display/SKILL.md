---
name: agent-display
description: Give an agent its own macOS virtual display for computer-use, browser, simulator, or UI test work, so the user's screen stays free. Use when a task needs a separate screen, a screenshot or recording of only the agent's screen, or an app moved off the user's display. Also drives that display for computer use: click, type, key, scroll, drag. Uses the agent-display CLI or its MCP tools (display_create, display_screenshot, display_click, display_ui, display_press, ...).
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

## Computer use: look, then act

1. Look: `display_screenshot` / `agent-display shot NAME`.
2. Act with coordinates from that screenshot (pixels from its top left, at the default 1x):
   - `display_click {"name", "x", "y"}` / `agent-display click NAME X Y [--button right] [--double]`
   - `display_type {"name", "text"}` / `agent-display type NAME TEXT`. Click the field first.
   - `display_key {"name", "keys": ["cmd+l", "enter"]}` / `agent-display key NAME cmd+l enter`
   - `display_scroll` (positive `dy` scrolls down), `display_drag`, `display_move`.
3. Look again to confirm the result. Do not chain many actions without a screenshot.

- On a `--hidpi` display, divide screenshot pixels by 2.
- In the CLI, put `--` before text that starts with a dash.
- On macOS, try the accessibility commands first. They do not move the user's pointer:
  1. `display_ui {"name"}` / `agent-display ui NAME` lists controls with `id`, `role`, `label`, `value`, `actions`.
  2. `display_press {"name", "id"}` / `agent-display press NAME ID` presses one.
  3. `display_set {"name", "id", "text"}` / `agent-display set NAME ID TEXT` writes a field marked `settable`.
  4. Run `ui` again after each action. An ID is a position and goes stale. Check the role and label that `press` and `set` print.
  Fall back to `click` and `type` when `ui` does not list the control.
- On macOS each `click`/`type`/`key` action moves the user's pointer, and `type`/`key` go to the focused app. Tell the
  user before you start, keep the run short, and prefer a Linux `host` for long runs.
- Use these for apps without a better interface. For a web page, Playwright or the Chrome DevTools
  Protocol is faster and does not move the pointer.

## Let the user watch: serve

- `display_serve {"name": ...}` or `agent-display serve NAME` starts a browser viewer that only the
  user's own Tailscale devices can reach. Pass `"open": true` / `--open` to open it on this Mac.
- Give the user the `url` from the result. The full link with its access token is in `linkFile`.
  Never print the token or put it in a message, a log, or a commit.
- `display_unserve` stops the viewer. Removing the display stops it too.

## Run on another machine: host

- Every MCP tool takes an optional `host`, and every CLI command takes `--host HOST`. Use a host
  only when the user names it or the task says where the work runs. Do not pick hosts yourself.
- A host works after `agent-display setup HOST`. On "not installed on HOST" or a version mismatch,
  run that command once, then retry.
- A Linux host gives each display its own pointer and keyboard, so click-driven work there does
  not disturb the user. Prefer it for long computer-use tasks when the user has such a host.
- On a Linux host, `open` takes a command (`chromium`, `firefox`), and the display is 1x only.
- Screenshots and recordings from a host are saved on this machine.
- If ssh prints a Tailscale check link, show the link to the user and wait. Do not retry in a loop.

## Defaults and sizes

- Default size is 1440x900 points at 1x. Keep it: 1x screenshots have 4x fewer pixels than HiDPI,
  so they cost fewer image tokens, and a fixed size keeps screenshot tests repeatable.
- Use `--size WxH` (or MCP `size`) to match a target, for example `1280x800` or `390x844` portrait
  web views. Use `--hidpi` only when the task checks Retina rendering.
- `run` exports `AGENT_DISPLAY_NAME`, `AGENT_DISPLAY_ID` and `AGENT_DISPLAY_BOUNDS` (`x,y,w,h` in
  global points) to the command. Use the bounds to place windows or to click in the right area.

## Limits you must respect

- On macOS there is one mouse pointer and one keyboard focus for all displays. Clicking or typing on your
  display still moves the user's pointer and can take focus. For browsers, prefer Playwright or the
  Chrome DevTools Protocol, which do not move the pointer. Warn the user before long click-driven work.
- `open` and the input commands need Accessibility permission, and `shot`/`record` need Screen Recording permission, for the
  app that runs the agent (Terminal, T3 Code, ...). On a permission error, tell the user which
  setting to turn on: System Settings > Privacy & Security.
- Never remove a display you did not create. `display_list` / `agent-display list` show all displays,
  including the user's physical ones.
- The tool uses private CoreGraphics classes. If creation fails after a macOS update, report it; do not retry in a loop.
