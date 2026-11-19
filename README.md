# agent-display

Named virtual displays on macOS for AI agents. Give each agent its own screen, tie the screen to the
agent's lifetime, and capture only that screen. One Objective-C file, no dependencies.

```sh
agent-display run agent-1 -- claude          # display exists exactly as long as the command
agent-display open agent-1 "Google Chrome"   # move an app's window onto it
agent-display shot agent-1                   # PNG of that display only
agent-display mcp                            # same features as MCP tools
```

## Install

Tested on macOS 15.5 (Apple silicon). Needs the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/0xzapata/agent-display && cd agent-display
clang -fobjc-arc -framework AppKit -framework CoreGraphics agent-display.m -o agent-display
./test.sh                                    # self-check: creates and removes ad-test-* displays
sudo install agent-display /usr/local/bin/   # optional
```

Permissions, for the app that runs the commands (Terminal, your agent host):

- Screen Recording: `shot`, `record`.
- Accessibility: `open`.

## Commands

| Command | What it does |
|---|---|
| `up NAME [--size WxH] [--hidpi]` | Create a display and hold it until the process is killed |
| `run NAME [--size WxH] [--hidpi] -- CMD...` | Create a display, run CMD, remove the display when CMD exits. Exits with CMD's status |
| `down NAME` | Remove a display started with `up` |
| `list` | JSON list of all displays: name, ID, bounds, scale |
| `shot NAME [PATH]` | Screenshot one display |
| `record NAME PATH [--seconds N]` | Record one display to `.mov` (default 10 s, max 600) |
| `open NAME APP` | Launch APP and move its first window onto the display, full size |
| `mcp` | MCP server on stdio |

Every command prints one JSON line on success and exits non-zero on failure. `run` gives CMD the
environment variables `AGENT_DISPLAY_NAME`, `AGENT_DISPLAY_ID` and `AGENT_DISPLAY_BOUNDS` (`x,y,w,h`).

Defaults: 1440x900 points at 1x. A fixed size keeps screenshots repeatable, and 1x images have 4x
fewer pixels than HiDPI, which matters when a model reads them. New displays line up to the right of
the existing ones. Each name gets a stable serial number, so macOS remembers its arrangement.

## MCP

```sh
claude mcp add --scope user agent-display -- /path/to/agent-display mcp
```

Tools: `display_create`, `display_list`, `display_remove`, `display_screenshot` (returns the image),
`display_record`, `display_open_app`. Displays created over MCP are removed when the client disconnects.

## Agent skill

[`skills/agent-display/SKILL.md`](skills/agent-display/SKILL.md) tells an agent when and how to use
the tool. Copy the folder to `~/.claude/skills/` (Claude Code) or your harness's skill folder.

## Limits

- macOS has one pointer and one keyboard focus. Clicks on an agent display still move your pointer.
  For browsers, drive them through Playwright or the Chrome DevTools Protocol instead.
- It uses the private `CGVirtualDisplay` classes in CoreGraphics, the same API that BetterDisplay
  and DeskPad use. Apple can change them in any macOS release.
- Nothing shows the display on a physical screen. Use `shot` or `record` to see it.

## License

MIT
