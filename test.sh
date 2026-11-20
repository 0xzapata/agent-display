#!/bin/bash
# Self-check for agent-display. Run: ./test.sh   (creates and removes displays named ad-test-*)
# Remote checks too: AD_TEST_HOST=my-vps ./test.sh
set -u
cd "$(dirname "$0")"
B=./agent-display; out=$(mktemp -d "$HOME/.cache/agent-display-test.XXXX"); pass=0; failn=0
ok()  { echo "PASS $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; failn=$((failn+1)); }
has() { $B list | grep -q "\"name\":\"$1\""; }

$B up ad-test-1 --size 1280x800 > "$out/up.json" & upid=$!
for i in $(seq 1 100); do [ -s "$out/up.json" ] && break; sleep 0.1; done  # wait up to 10 s for the JSON line
grep -q '"width":1280' "$out/up.json" && has ad-test-1 && ok "up creates 1280x800 display" || bad "up"
$B up ad-test-1 2>/dev/null; [ $? -eq 1 ] && ok "duplicate name rejected" || bad "duplicate"
$B shot ad-test-1 "$out/s.png" >/dev/null && [ "$(sips -g pixelWidth "$out/s.png" | awk '/pixelWidth/{print $2}')" = 1280 ] && ok "shot is 1280 px wide (1x)" || bad "shot"
$B record ad-test-1 "$out/r.mov" --seconds 2 >/dev/null && [ -s "$out/r.mov" ] && ok "record writes .mov" || bad "record"
$B open ad-test-1 TextEdit >/dev/null && ok "open moves TextEdit window" || bad "open"
pkill -x TextEdit; sleep 0.5
# Input: these checks move your pointer and type into a TextEdit window on the test display.
tf="$out/input.txt"; : > "$tf"; open -a TextEdit "$tf"; sleep 1.5; $B open ad-test-1 TextEdit >/dev/null; sleep 0.7
$B click ad-test-1 640 400 | grep -q '"pointer":{"x":640,"y":400}' && ok "click lands at 640,400 of the display" || bad "click"
$B type ad-test-1 "héllo 🙂" >/dev/null; $B key ad-test-1 enter >/dev/null; $B type ad-test-1 -- "--two" >/dev/null; $B key ad-test-1 cmd+s >/dev/null; sleep 1
[ "$(cat "$tf")" = "$(printf 'Héllo 🙂\n--two')" ] || [ "$(cat "$tf")" = "$(printf 'héllo 🙂\n--two')" ] && ok "type and key reach the app (text saved with cmd+s)" || bad "type/key: $(cat "$tf")"
$B drag ad-test-1 200 300 400 350 | grep -q '"pointer":{"x":400,"y":350}' && $B scroll ad-test-1 640 400 --dy 3 >/dev/null && ok "drag ends at its target, scroll runs" || bad "drag/scroll"
# Accessibility actions: these must not move the pointer. The check fails if you move the mouse in that second.
ptr() { osascript -l JavaScript -e 'ObjC.import("AppKit"); var p=$.NSEvent.mouseLocation; Math.round(p.x)+","+Math.round(p.y)'; }
uid() { $B ui ad-test-1 | python3 -I -c "import json,sys; print([e['id'] for e in json.load(sys.stdin)['elements'] if e['role']=='$1'][0])"; }
ta=$(uid AXTextArea); p0=$(ptr)
$B set ad-test-1 "$ta" -- "--set by ax é" | grep -q '"value":"--set by ax é"' && ok "set writes a field value" || bad "set"
[ -n "$ta" ] && [ "$(ptr)" = "$p0" ] && ok "set does not move the pointer" || bad "set moved the pointer"
$B key ad-test-1 cmd+s >/dev/null; sleep 1; $B press ad-test-1 "$(uid AXButton)" | grep -q '"action":"AXPress"'; sleep 1
[ "$(cat "$tf")" = "--set by ax é" ] && $B ui ad-test-1 | grep -q '"windows":\[\]' && ok "press closes the window, text was saved" || bad "press: $(cat "$tf")"
$B press ad-test-1 1:0 2>/dev/null; a=$?; $B press ad-test-1 'x;y' 2>/dev/null; b=$?; [ $a -eq 1 ] && [ $b -eq 2 ] && ok "stale ID and malformed ID rejected" || bad "ui validation $a $b"
$B click ad-test-1 5000 5 2>/dev/null; a=$?; $B key ad-test-1 cmd+nope 2>/dev/null; b=$?; [ $a -eq 2 ] && [ $b -eq 2 ] && ok "point outside the display and unknown key rejected" || bad "input validation"
pkill -x TextEdit
$B down ad-test-1 | grep -q '"removed":true' && ! has ad-test-1 && ok "down removes display" || bad "down"
wait $upid 2>/dev/null; [ ! -e "$HOME/.cache/agent-display/ad_test_1.pid" ] && ok "pid file cleaned" || bad "pid file"

$B run ad-test-2 -- bash -c '[ -n "$AGENT_DISPLAY_ID" ] && exit 7' 2>/dev/null; [ $? -eq 7 ] && ok "run passes env + exit code" || bad "run exit"
sleep 1; ! has ad-test-2 && ok "run removes display after cmd" || bad "run cleanup"
$B run ad-test-3 -- sleep 60 2>/dev/null & rpid=$!
for i in $(seq 1 100); do has ad-test-3 && break; sleep 0.1; done; has ad-test-3 || bad "run start"
kill -TERM $rpid; wait $rpid; sleep 1; ! has ad-test-3 && ok "SIGTERM to run removes display" || bad "run kill"
$B run ad-test-4 -- /nonexistent 2>/dev/null; [ $? -eq 127 ] && ok "missing cmd exits 127" || bad "run 127"
sleep 1; ! has ad-test-4 && ok "display removed after missing cmd" || bad "127 cleanup"

mcp=$( { printf '%s\n' \
 '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
 '{"jsonrpc":"2.0","method":"notifications/initialized"}' \
 '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
 '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"display_create","arguments":{"name":"ad-test-mcp"}}}' \
 '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"display_screenshot","arguments":{"name":"ad-test-mcp"}}}' \
 '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"display_list","arguments":{}}}' \
 '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"display_click","arguments":{"name":"ad-test-mcp","x":10,"y":20}}}' \
 '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"display_type","arguments":{"name":"ad-test-mcp"}}}'; sleep 3; } | $B mcp )
echo "$mcp" | grep -q '"serverInfo"' && ok "mcp initialize" || bad "mcp init"
[ "$(echo "$mcp" | grep -o '"name":"display_[a-z_]*"' | sort -u | wc -l | tr -d ' ')" = 17 ] && ok "mcp lists 17 tools" || bad "mcp tools"
echo "$mcp" | grep '"id":4' | grep -q '"type":"image"' && ok "mcp screenshot returns image" || bad "mcp shot"
echo "$mcp" | grep '"id":5' | grep -q 'ad-test-mcp' && ok "mcp display listed" || bad "mcp list"
echo "$mcp" | grep '"id":6' | grep -q 'pointer.*:10,.*:20' && ok "mcp click lands at 10,20" || bad "mcp click"
echo "$mcp" | grep '"id":7' | grep -q '"isError":true' && ok "mcp type without text is an error" || bad "mcp type validation"
echo "$mcp" | grep '"id":5' | grep -q '"isError":false' && ok "mcp isError is a JSON boolean" || bad "mcp isError"
sleep 1; ! has ad-test-mcp && ok "mcp disconnect removes display" || bad "mcp cleanup"


# --- serve: needs screen-relay and Tailscale on this Mac ---
if command -v tailscale >/dev/null && ls "$HOME"/.local/share/screen-relay/engine/*/relay-engine >/dev/null 2>&1; then
  $B up ad-test-s --size 1280x800 > "$out/s.json" & spid=$!
  for i in $(seq 1 100); do [ -s "$out/s.json" ] && break; sleep 0.1; done
  $B serve ad-test-s > "$out/serve.json"; url=$(sed -E 's/.*"url":"([^"]+)".*/\1/' "$out/serve.json" | tr -d '\\')
  lf="$HOME/.cache/agent-display/ad_test_s.link"
  ! grep -q token "$out/serve.json" && [ "$(stat -f %Lp "$lf")" = 600 ] && ok "serve keeps the token in a 600 file" || bad "serve token"
  [ "$(curl -s -m 20 -o /dev/null -w '%{http_code}' "$url/")" = 200 ] && ok "viewer page loads over the tailnet" || bad "serve viewer ($url)"
  [ "$(curl -s -m 20 -o /dev/null -w '%{http_code}' "$url/screenshot.png")" = 401 ] && ok "no token gets 401" || bad "serve 401"
  [ "$(curl -s -m 20 -o "$out/v.png" -w '%{http_code}' -H "Authorization: Bearer $(sed -E 's/.*#token=//' "$lf")" "$url/screenshot.png")" = 200 ] \
    && [ "$(sips -g pixelWidth "$out/v.png" | awk '/pixelWidth/{print $2}')" = 1280 ] && ok "token gets the 1280 px display" || bad "serve token shot"
  port=${url##*:}
  kill $spid; wait $spid 2>/dev/null; sleep 1
  ! tailscale serve status 2>/dev/null | grep -q ":$port " && [ ! -e "$lf" ] && ! lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1 \
    && [ ! -e "$HOME/.local/state/screen-relay/ad-ad-test-s" ] && ok "killing the display stops its viewer and removes its state" || bad "serve cleanup"
else
  echo "SKIP serve (screen-relay or tailscale not installed)"
fi

# --- --host: set AD_TEST_HOST to a host prepared with `agent-display setup HOST` ---
if [ -n "${AD_TEST_HOST:-}" ]; then
  H=$AD_TEST_HOST; R="--host $H"
  $B up ad-test-r --size 1280x800 $R | grep -q '"width":1280' && ok "remote up" || bad "remote up"
  $B list $R | grep -q '"name":"ad-test-r"' && ok "remote list" || bad "remote list"
  $B open ad-test-r xmessage hello $R | grep -q '"pid":[0-9]' && ok "remote open" || bad "remote open"
  $B shot ad-test-r "$out/r.png" $R >/dev/null && [ "$(sips -g pixelWidth "$out/r.png" | awk '/pixelWidth/{print $2}')" = 1280 ] && ok "remote shot lands here, 1280 px" || bad "remote shot"
  $B record ad-test-r "$out/r.mp4" --seconds 2 $R >/dev/null && [ -s "$out/r.mp4" ] && ok "remote record lands here" || bad "remote record"
  $B serve ad-test-r $R > "$out/rs.json"; rurl=$(sed -E 's/.*"url":"([^"]+)".*/\1/' "$out/rs.json" | tr -d '\\')
  rlf="$HOME/.cache/agent-display/${H//[^A-Za-z0-9]/_}_ad_test_r.link"
  ! grep -q token "$out/rs.json" && [ "$(curl -s -m 20 -o /dev/null -w '%{http_code}' "$rurl/screenshot.png")" = 401 ] \
    && [ "$(curl -s -m 20 -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(sed -E 's/.*#token=//' "$rlf")" "$rurl/screenshot.png")" = 200 ] \
    && ok "remote serve: 401 without token, 200 with" || bad "remote serve"
  # Input on the host: xdotool reads the pointer back, xev records what the X server received.
  if ssh -o BatchMode=yes "$H" 'command -v xdotool xev >/dev/null'; then
    $B move ad-test-r 100 50 $R >/dev/null; $B drag ad-test-r 200 300 400 350 $R >/dev/null
    $B run ad-test-ri --size 1280x800 $R -- bash -c 'A=~/.local/bin/agent-display; N=$AGENT_DISPLAY_NAME
      $A move $N 100 50 >/dev/null; xdotool getmouselocation
      xev -geometry 1280x800+0+0 > /tmp/ad-xev.$$ 2>&1 & X=$!; sleep 1.5
      $A click $N 640 400 >/dev/null; $A click $N 300 200 --button right >/dev/null; $A scroll $N 640 400 --dy 2 >/dev/null
      $A type $N -- "-Zé" >/dev/null; $A key $N ctrl+l enter >/dev/null; sleep 1; kill $X
      echo "b3=$(grep -A3 ButtonPress /tmp/ad-xev.$$ | grep -c "button 3")" "wheel=$(grep -A3 ButtonPress /tmp/ad-xev.$$ | grep -c "button [45]")"
      echo "at=$(grep -B2 "button 3" /tmp/ad-xev.$$ | grep -c "(300,200)")"
      echo "keys=$(grep -A6 "^KeyPress" /tmp/ad-xev.$$ | grep -o "keysym 0x[0-9a-f]*, [A-Za-z0-9_]*" | cut -d" " -f3 | tr "\n" " ")"; rm -f /tmp/ad-xev.$$' > "$out/ri.txt" 2>/dev/null
    grep -q 'x:100 y:50 ' "$out/ri.txt" && ok "remote move lands at 100,50" || bad "remote move"
    grep -q 'b3=1' "$out/ri.txt" && grep -q 'at=2' "$out/ri.txt" && grep -q 'wheel=2' "$out/ri.txt" && ok "remote right click at 300,200 and 2 wheel notches reach X" || bad "remote click/scroll: $(cat "$out/ri.txt")"
    grep -q 'keys=minus Z eacute Control_L l Return' "$out/ri.txt" && ok "remote type and key reach X" || bad "remote type/key: $(grep keys= "$out/ri.txt")"
    $B ui ad-test-r $R 2>&1 | grep -q 'macOS only' && ok "remote ui says macOS only" || bad "remote ui"
    $B click ad-test-r 5000 5 $R 2>/dev/null; [ $? -eq 2 ] && ok "remote point outside the display rejected" || bad "remote input validation"
  else
    echo "SKIP remote input (xdotool or xev missing on $H)"
  fi
  $B down ad-test-r $R | grep -q '"removed":true' && ! $B list $R | grep -q ad-test-r && [ ! -e "$rlf" ] && ok "remote down" || bad "remote down"
  $B run ad-test-r2 $R -- bash -c '[ -n "$DISPLAY" ] && exit 7' 2>/dev/null; [ $? -eq 7 ] && ok "remote run passes DISPLAY + exit code" || bad "remote run"
  ! $B list $R | grep -q ad-test-r2 && ok "remote run removes its display" || bad "remote run cleanup"
  $B run ad-test-r3 $R -- sleep 60 2>/dev/null & kpid=$!
  for i in $(seq 1 100); do $B list $R | grep -q ad-test-r3 && break; sleep 0.2; done
  kill -TERM $kpid; wait $kpid 2>/dev/null; sleep 3
  ! $B list $R | grep -q ad-test-r3 && ! pgrep -f 'ssh .*ad-test-r3' >/dev/null && ok "killing a remote run removes its display and ssh" || bad "remote run kill"
  $B list --host '-oProxyCommand=x' 2>/dev/null; [ $? -eq 2 ] && ok "option-like host rejected" || bad "host validation"
else
  echo "SKIP --host (set AD_TEST_HOST=<host>)"
fi

rm -rf "$out" "$HOME"/.cache/agent-display/ad_test_mcp-*.png
echo "$pass passed, $failn failed"; [ $failn -eq 0 ]
