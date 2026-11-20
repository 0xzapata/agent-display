#!/usr/bin/env node
// agent-display for Linux: the same commands as the macOS binary, built on screen-relay
// (https://github.com/vercel-labs/screen-relay), which owns the Xvfb display and the stream.
// Each display is one screen-relay session with the same name, so `screen-relay click --name NAME`
// and friends work on it too. Every X display has its own pointer and keyboard.
//
//   agent-display up NAME [--size WxH]            start a display (returns at once; `down` removes it)
//   agent-display run NAME [--size WxH] -- CMD     display lives exactly as long as CMD
//   agent-display down NAME
//   agent-display list
//   agent-display shot NAME [PATH|-]               PNG; `-` writes the bytes to stdout
//   agent-display record NAME PATH|- [--seconds N]
//   agent-display open NAME APP [ARGS...]          start APP on the display
//   agent-display click|move|scroll NAME X Y, drag NAME X1 Y1 X2 Y2, type NAME TEXT, key NAME COMBO...
//                                                  input; X Y are pixels from the top left
//   agent-display serve NAME [--show-link]         tailnet-only HTTPS viewer through Tailscale Serve
//   agent-display unserve NAME
//
// ponytail: no --host and no MCP server here; the macOS binary reaches this script over ssh.
// Add them when an agent that runs on Linux must drive a display on a third machine.
import { spawn, spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, join } from 'node:path';

const VERSION = '0.3.0';
const HOME = homedir();
const CACHE = join(HOME, '.cache/agent-display');
const SR_STATE = join(process.env.XDG_STATE_HOME || join(HOME, '.local/state'), 'screen-relay');

const emit = (o) => process.stdout.write(JSON.stringify(o) + '\n');
const fail = (msg, code = 1) => { process.stderr.write(`agent-display: ${msg}\n`); process.exit(code); };

function findTool(name) {
  const dirs = [...(process.env.PATH || '').split(':'), dirname(process.execPath), join(HOME, '.npm-global/bin'), join(HOME, '.local/bin')];
  for (const d of dirs) if (d && existsSync(join(d, name))) return join(d, name);
  return null;
}
const SR = findTool('screen-relay');

// Run screen-relay with --json. Returns the parsed object, or null when it exits non-zero and `soft`.
function sr(args, { soft = false, env, input } = {}) {
  if (!SR) fail('screen-relay not found; run `npm install -g screen-relay && screen-relay install --yes --desktop none`');
  // --json goes right after the subcommand: after a `--` it would be part of the app's command.
  const r = spawnSync(SR, [args[0], '--json', ...args.slice(1)], { encoding: 'utf8', env: env || process.env, input });
  let j = null;
  for (const text of [r.stdout, r.stderr]) {  // results go to stdout, errors to stderr
    try { j = JSON.parse(text.trim().split('\n').pop()); break; } catch {}
  }
  if (r.status !== 0) {
    if (soft) return null;
    fail(j?.message || r.stderr.trim() || `screen-relay ${args[0]} failed`);
  }
  return j;
}

const session = (name) => { const s = sr(['status', '--name', name], { soft: true })?.session; return s?.running ? s : null; };
const needSession = (name) => session(name) || fail('no display with that name');

function checkName(name) {
  if (!/^[a-z0-9][a-z0-9-]{0,30}$/.test(name || '')) fail('NAME must be lowercase letters, digits and dashes, max 31 characters', 2);
  return name;
}

function tailscale(args) {
  const ts = findTool('tailscale');
  if (!ts) return { status: 127, stdout: '', stderr: 'tailscale not found' };
  let r = spawnSync(ts, args, { encoding: 'utf8' });
  // Without `tailscale set --operator=$USER`, serve changes need root.
  if (r.status !== 0 && /denied|operator|sudo/i.test(r.stdout + r.stderr)) r = spawnSync('sudo', ['-n', ts, ...args], { encoding: 'utf8' });
  return r;
}

function tailnetName() {
  const r = tailscale(['status', '--json']);
  try { return JSON.parse(r.stdout).Self.DNSName.replace(/\.$/, '') || null; } catch { return null; }
}

function pickPort(name) {
  const used = new Set();
  const ss = spawnSync('ss', ['-tlnH'], { encoding: 'utf8' }).stdout || '';
  for (const m of ss.matchAll(/:(\d+)\s/g)) used.add(+m[1]);
  for (const m of (tailscale(['serve', 'status']).stdout || '').matchAll(/:(\d+)\b/g)) used.add(+m[1]);
  let h = 2166136261;
  for (const c of Buffer.from(name)) h = Math.imul(h ^ c, 16777619) >>> 0;
  for (let i = 0; i < 600; i++) { const p = 18400 + ((h + i) % 600); if (!used.has(p)) return p; }
  fail('no free port between 18400 and 18999');
}

function info(s) {
  const [w, h] = s.resolution.split('x').map(Number);
  return { name: s.name, displayID: s.display, bounds: { x: 0, y: 0, width: w, height: h }, scale: 1, port: s.port };
}

function up(name, size) {
  if (session(name)) fail(`a display named "${name}" already exists`);
  const port = pickPort(name), dns = tailnetName();
  const args = ['up', '-d', '--name', name, '--port', String(port), '--desktop', 'none'];
  // --public makes the engine demand a token, even from other users on this machine. It stays on
  // loopback; only `serve` (Tailscale Serve, tailnet only) exposes it.
  if (dns) args.push('--public', `https://${dns}:${port}`, '--bind', '127.0.0.1');
  sr(args, { env: { ...process.env, SCREEN_RELAY_RESOLUTION: size } });
  return needSession(name);
}

function unserve(name) {
  const marker = join(CACHE, `${name}.serve`);
  if (!existsSync(marker)) return false;
  tailscale(['serve', `--https=${readFileSync(marker, 'utf8').trim()}`, 'off']);
  rmSync(marker, { force: true });
  rmSync(join(CACHE, `${name}.link`), { force: true });
  return true;
}

function down(name) {
  unserve(name);
  sr(['down', '--name', name], { soft: true });
  // Drop the stopped session's state (logs, old token), so `list` stays fast and nothing piles up.
  if (!session(name)) rmSync(join(SR_STATE, name), { recursive: true, force: true });
}

// `-` as a path: write to a temp file, send the bytes to stdout, delete the file.
function withOutput(path, ext, write) {
  if (path !== '-') { write(path); return path; }
  const tmp = join(tmpdir(), `agent-display-${process.pid}.${ext}`);
  try { write(tmp); process.stdout.write(readFileSync(tmp)); } finally { rmSync(tmp, { force: true }); }
  return null;
}

function parseSize(argv) {
  let size = '1440x900';
  const i = argv.indexOf('--size');
  if (i >= 0) {
    size = argv[i + 1] || '';
    const m = /^(\d+)x(\d+)$/.exec(size);
    if (!m || +m[1] < 640 || +m[2] < 480 || +m[1] > 8192 || +m[2] > 8192 || +m[1] % 2 || +m[2] % 2)
      fail('--size must be WIDTHxHEIGHT, even numbers, 640x480 to 8192x8192', 2);
    argv.splice(i, 2);
  }
  if (argv.includes('--hidpi')) fail('--hidpi is not supported on Linux', 2);
  return size;
}

// ---------- main ----------

let argv = process.argv.slice(2);
if (argv[0] === '--expect-version') {  // the caller on another machine checks that both sides match
  if (argv[1] !== VERSION) fail(`this host has agent-display ${VERSION}, the caller has ${argv[1]}; run \`agent-display setup HOST\` on the caller`, 3);
  argv = argv.slice(2);
}
const cmd = argv.shift();
mkdirSync(CACHE, { recursive: true });

if (cmd === 'version') { emit({ version: VERSION, platform: 'linux', screenRelay: SR }); process.exit(0); }
if (cmd === 'list') {
  const names = existsSync(SR_STATE) ? readdirSync(SR_STATE) : [];
  emit(names.map(session).filter(Boolean).map(info));
  process.exit(0);
}

if (['ui', 'press', 'set'].includes(cmd))
  fail(`${cmd} works on macOS only. A Linux display has its own pointer and keyboard: use click, type and key`, 2);
if (['click', 'move', 'drag', 'scroll', 'type', 'key'].includes(cmd)) {
  const name = checkName(argv.shift()), s = needSession(name);
  const [w, h] = s.resolution.split('x').map(Number);
  const text = cmd === 'type' || cmd === 'key', pos = [], opt = {};
  let literal = false;  // after `--` every argument is data
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!literal && a === '--') literal = true;
    else if (literal || text) pos.push(a);
    else if (a === '--double') opt[a] = '1';
    else if (['--button', '--dx', '--dy'].includes(a) && i + 1 < argv.length) opt[a] = argv[++i];
    else pos.push(a);
  }
  const want = text ? 1 : cmd === 'drag' ? 4 : 2;
  if (pos.length < want || (pos.length !== want && cmd !== 'key'))
    fail('usage: click|move|scroll NAME X Y, drag NAME X1 Y1 X2 Y2, type NAME TEXT, key NAME COMBO...', 2);
  // screen-relay takes fractions of the screen; aim at the middle of the pixel.
  const pt = [];
  if (!text) for (let i = 0; i < want; i += 2) {
    const x = Number(pos[i]), y = Number(pos[i + 1]);
    if (pos[i] === '' || pos[i + 1] === '' || !(x >= 0 && y >= 0 && x < w && y < h)) fail(`X Y must be inside the display: 0,0 to ${w - 1},${h - 1}`, 2);
    pt.push({ x: (x + 0.5) / w, y: (y + 0.5) / h });
  }
  const send = (events) => sr(['input', '--name', name, '--stdin'], { input: JSON.stringify(events) });
  if (cmd === 'type') {
    if (!pos[0]) fail('TEXT must not be empty', 2);
    sr(['type', '--name', name, '--stdin'], { input: pos[0] });
    emit({ name, typed: pos[0].length });
  } else if (cmd === 'key') {
    // A combination goes to screen-relay as an argument, so it must not look like an option.
    for (const c of pos) if (!/^[A-Za-z0-9]/.test(c) && c.length > 1) fail(`unknown key combination "${c}"; use e.g. ctrl+l, shift+tab, enter, f5`, 2);
    sr(['key', '--name', name, ...pos]);
    emit({ name, keys: pos });
  } else {
    if (cmd === 'move') send([{ type: 'pointerMove', ...pt[0] }]);
    if (cmd === 'click') {
      const button = { left: 1, middle: 2, right: 3 }[opt['--button'] || 'left'];
      if (!button) fail('--button must be left, right or middle', 2);
      const one = [{ type: 'buttonDown', button, ...pt[0] }, { type: 'buttonUp', button, ...pt[0] }];
      send([{ type: 'pointerMove', ...pt[0] }, ...one, ...(opt['--double'] ? one : [])]);
    }
    if (cmd === 'drag') {
      const steps = Array.from({ length: 10 }, (_, i) => ({ type: 'pointerMove', buttons: 1,
        x: pt[0].x + (pt[1].x - pt[0].x) * (i + 1) / 10, y: pt[0].y + (pt[1].y - pt[0].y) * (i + 1) / 10 }));
      send([{ type: 'pointerMove', ...pt[0] }, { type: 'buttonDown', button: 1, ...pt[0] }, ...steps, { type: 'buttonUp', button: 1, ...pt[1] }]);
    }
    if (cmd === 'scroll') {
      const dx = Number(opt['--dx'] || 0), dy = Number(opt['--dy'] || 0);
      if (!Number.isInteger(dx) || !Number.isInteger(dy) || (!dx && !dy) || Math.abs(dx) > 100 || Math.abs(dy) > 100) fail('scroll needs --dx N or --dy N, -100 to 100 notches', 2);
      sr(['scroll', '--name', name, `--dx=${dx}`, `--dy=${dy}`, String(pt[0].x), String(pt[0].y)]);
    }
    emit({ name, action: cmd });
  }
  process.exit(0);
}

const dd = argv.indexOf('--');
const child = dd >= 0 ? argv.splice(dd).slice(1) : null;
const name = checkName(argv.shift());

if (cmd === 'up') {
  if (child) fail('use `run` to tie a display to a command', 2);
  emit(info(up(name, parseSize(argv))));
} else if (cmd === 'run') {
  if (!child?.length) fail('usage: agent-display run NAME [--size WxH] -- CMD [ARGS...]', 2);
  const s = up(name, parseSize(argv)), i = info(s);
  const env = { ...process.env, DISPLAY: s.display, XAUTHORITY: s.xauthority, AGENT_DISPLAY_NAME: name,
                AGENT_DISPLAY_ID: s.display, AGENT_DISPLAY_BOUNDS: `0,0,${i.bounds.width},${i.bounds.height}` };
  process.stderr.write(`agent-display: "${name}" is display ${s.display} (${s.resolution}); running ${child[0]}\n`);
  const p = spawn(child[0], child.slice(1), { stdio: 'inherit', env });
  for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(sig, () => p.kill(sig));
  p.on('error', (e) => { down(name); fail(`cannot start ${child[0]}: ${e.message}`, 127); });
  p.on('exit', (code, sig) => { down(name); process.exit(sig ? 128 + (({ SIGINT: 2, SIGTERM: 15, SIGHUP: 1 })[sig] || 1) : code); });
} else if (cmd === 'down') {
  needSession(name);
  down(name);
  emit({ name, removed: !session(name) });
} else if (cmd === 'shot') {
  needSession(name);
  const path = argv[0] || join(CACHE, `${name}-${Math.floor(Date.now() / 1000)}.png`);
  const out = withOutput(path, 'png', (p) => sr(['screenshot', '--name', name, p]));
  if (out) emit({ name, path: out });
} else if (cmd === 'record') {
  const s = needSession(name), path = argv.shift();
  let seconds = 10;
  if (argv[0] === '--seconds') seconds = Number(argv[1]);
  if (!path || !Number.isInteger(seconds) || seconds < 1 || seconds > 600) fail('usage: agent-display record NAME PATH|- [--seconds N]  (1 to 600)', 2);
  const out = withOutput(path, 'mp4', (p) => {
    const r = spawnSync('ffmpeg', ['-loglevel', 'error', '-y', '-f', 'x11grab', '-video_size', s.resolution, '-framerate', '30',
      '-i', s.display, '-t', String(seconds), '-pix_fmt', 'yuv420p', p], { env: { ...process.env, XAUTHORITY: s.xauthority }, encoding: 'utf8' });
    if (r.status !== 0 || !existsSync(p)) fail(`ffmpeg recording failed: ${(r.stderr || r.error?.message || '').trim()}`);
  });
  if (out) emit({ name, path: out, seconds });
} else if (cmd === 'open') {
  needSession(name);
  if (!argv.length) fail('usage: agent-display open NAME APP [ARGS...]', 2);
  const r = sr(['run', '--name', name, '--', ...argv]);
  emit({ name, app: argv[0], pid: r?.app?.pid ?? null });
} else if (cmd === 'serve') {
  const s = sr(['status', '--name', name, '--show-token'], { soft: true })?.session;
  if (!s?.running) fail('no display with that name');
  if (!s.token) fail('this display was created without Tailscale; start Tailscale, then `down` and `up` the display');
  const r = tailscale(['serve', '--bg', `--https=${s.port}`, `http://127.0.0.1:${s.port}`]);
  if (r.status !== 0) fail(`tailscale serve failed: ${(r.stderr || r.stdout).trim()}`);
  const linkFile = join(CACHE, `${name}.link`), link = `${s.url}/#token=${s.token}`;
  writeFileSync(linkFile, link + '\n', { mode: 0o600 });
  chmodSync(linkFile, 0o600);
  writeFileSync(join(CACHE, `${name}.serve`), String(s.port));
  // The link carries the session token, so it is printed only on request.
  emit({ name, url: s.url, linkFile, ...(argv.includes('--show-link') ? { link } : {}) });
} else if (cmd === 'unserve') {
  emit({ name, unserved: unserve(name) });
} else {
  fail('usage: agent-display up|run|down|list|shot|record|open|click|move|drag|scroll|type|key|serve|unserve|version ...', 2);
}
