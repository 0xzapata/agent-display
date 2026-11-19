#!/bin/bash
# Self-check for agent-display. Run: ./test.sh   (creates and removes displays named ad-test-*)
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
osascript -e 'tell application "TextEdit" to quit saving no' 2>/dev/null
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
 '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"display_list","arguments":{}}}'; sleep 3; } | $B mcp )
echo "$mcp" | grep -q '"serverInfo"' && ok "mcp initialize" || bad "mcp init"
[ "$(echo "$mcp" | grep -o '"name":"display_[a-z_]*"' | sort -u | wc -l | tr -d ' ')" = 6 ] && ok "mcp lists 6 tools" || bad "mcp tools"
echo "$mcp" | grep '"id":4' | grep -q '"type":"image"' && ok "mcp screenshot returns image" || bad "mcp shot"
echo "$mcp" | grep '"id":5' | grep -q 'ad-test-mcp' && ok "mcp display listed" || bad "mcp list"
sleep 1; ! has ad-test-mcp && ok "mcp disconnect removes display" || bad "mcp cleanup"

rm -rf "$out" "$HOME"/.cache/agent-display/ad_test_mcp-*.png
echo "$pass passed, $failn failed"; [ $failn -eq 0 ]
