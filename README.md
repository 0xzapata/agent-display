# agent-display

Named virtual displays on macOS for AI agents. Give each agent its own screen, tie the screen to the
agent's lifetime, and capture only that screen. One Objective-C file, no dependencies.

```sh
agent-display run agent-1 -- claude          # display exists exactly as long as the command
agent-display open agent-1 "Google Chrome"   # move an app's window onto it
agent-display shot agent-1                   # PNG of that display only
agent-display mcp                            # same features as MCP tools

agent-display serve agent-1 --open           # watch and control it in a browser, from your tailnet only
agent-display setup my-vps                   # install on a Linux host over ssh, one time
agent-display run agent-2 --host my-vps -- ./agent.sh   # the same commands, on that host
```

## Install

Tested on macOS 15.5 (Apple silicon). Needs the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/0xzapata/agent-display && cd agent-display
clang -fobjc-arc -framework AppKit -framework CoreGraphics agent-display.m -o agent-display
./test.sh                                    # self-check: creates and removes ad-test-* displays
AD_TEST_HOST=my-vps ./test.sh                # also checks --host against a prepared host
ln -s "$PWD/agent-display" /usr/local/bin/   # optional; `setup` needs agent-display-linux.mjs next to the binary
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
| `serve NAME [--open] [--show-link]` | Start a browser viewer for the display, reachable only from your tailnet |
| `unserve NAME` | Stop the viewer. `down` does this too |
| `setup HOST` | Install agent-display and screen-relay on a Linux host over ssh. Run it again after an update |
| `mcp` | MCP server on stdio |

Add `--host HOST` to `up`, `run`, `down`, `list`, `shot`, `record`, `open`, `serve` or `unserve` to
run it on a host that you prepared with `setup`.

Every command prints one JSON line on success and exits non-zero on failure. `run` gives CMD the
environment variables `AGENT_DISPLAY_NAME`, `AGENT_DISPLAY_ID` and `AGENT_DISPLAY_BOUNDS` (`x,y,w,h`).

Defaults: 1440x900 points at 1x. A fixed size keeps screenshots repeatable, and 1x images have 4x
fewer pixels than HiDPI, which matters when a model reads them. New displays line up to the right of
the existing ones. Each name gets a stable serial number, so macOS remembers its arrangement.

## Remote view: `serve`

`serve` uses [screen-relay](https://github.com/vercel-labs/screen-relay) for the stream and the
input, and Tailscale Serve for access. agent-display adds the display and the wiring.

```sh
npm install -g screen-relay && screen-relay install --yes   # one time
agent-display up agent-1 &
agent-display serve agent-1 --open
```

- The viewer is at `https://<this-machine>.<tailnet>.ts.net:<port>`. Only devices on your tailnet
  can reach it. There is no pairing step: a device that is on your tailnet is already paired.
- screen-relay listens on loopback and demands a token. The full link, with the token, is written
  to a file that only you can read (`linkFile` in the output). `--open` opens it in your browser.
  `--show-link` prints it. Share the link only with people who may control that display.
- The port is derived from the display name, so the URL stays the same between runs.
- `down`, or killing `up`/`run`, stops the viewer and removes the Tailscale Serve route.

## Other machines: `--host`

```sh
agent-display setup my-vps                       # copies the Linux script, installs screen-relay
agent-display up agent-1 --host my-vps
agent-display open agent-1 chromium --host my-vps
agent-display shot agent-1 --host my-vps         # the PNG lands on this machine
agent-display serve agent-1 --open --host my-vps
agent-display down agent-1 --host my-vps
```

- The host needs Linux (Debian, Ubuntu, Fedora, Arch or Alpine), Node 22 or newer, `sudo` for the
  one-time package install, and ssh access. With Tailscale SSH you need no keys.
- On Linux each display is its own X server (Xvfb). **Each one has its own pointer and keyboard**,
  so agents never fight you or each other for input. Every display is a screen-relay session with
  the same name: `screen-relay click 0.5 0.5 --name agent-1` works on the host.
- `run --host` ties the remote display to the remote command. If the ssh connection drops, the
  host removes the display.
- `setup` and every remote call check that both sides have the same version.
- `--hidpi` is macOS only. `open` on Linux takes a command, not an app name.

## MCP

```sh
claude mcp add --scope user agent-display -- /path/to/agent-display mcp
```

Tools: `display_create`, `display_list`, `display_remove`, `display_screenshot` (returns the image),
`display_record`, `display_open_app`, `display_serve`, `display_unserve`. Each tool takes an optional
`host`. Displays created over MCP are removed when the client disconnects, on every host.

## Agent skill

[`skills/agent-display/SKILL.md`](skills/agent-display/SKILL.md) tells an agent when and how to use
the tool. Copy the folder to `~/.claude/skills/` (Claude Code) or your harness's skill folder.

## Limits

- macOS has one pointer and one keyboard focus. Clicks on an agent display still move your pointer.
  For browsers, drive them through Playwright or the Chrome DevTools Protocol instead.
- It uses the private `CGVirtualDisplay` classes in CoreGraphics, the same API that BetterDisplay
  and DeskPad use. Apple can change them in any macOS release.
- Nothing shows the display on a physical screen. Use `shot`, `record` or `serve` to see it.
- Without Tailscale SSH or an ssh agent, `--host` cannot log in. It never asks for a password.
- A viewer link gives full control of that display to anyone on your tailnet who has it.

## License

MIT
