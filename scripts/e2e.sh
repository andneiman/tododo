#!/bin/bash
# End-to-end sync test: two real app processes ("phone" A and "mac" B) against a local server.
# Usage: scripts/e2e.sh path/to/Tods.app/Contents/MacOS/Tods
set -u
BIN="$1"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
PORT=8787
URL="http://127.0.0.1:$PORT"
export TODODO_LOCAL_FILE="$TMP/server-state.json"
FAILS=0

server_start() { (cd "$ROOT/backend" && PORT=$PORT node test/local-server.mjs > "$TMP/server.log" 2>&1 &) ; for i in $(seq 1 50); do curl -s -o /dev/null "$URL/" && return; sleep 0.1; done; echo "server did not start"; cat "$TMP/server.log"; exit 1; }
server_stop() { pkill -f "test/local-server.mjs" 2>/dev/null; sleep 0.3; }
run() { local dev="$1"; shift; TODODO_DIR="$TMP/$dev" TODODO_URL="$URL" TODODO_TOKEN="test-app" TODODO_SCRIPT="$*" "$BIN" -e2e 2>/dev/null | grep '^E2E|' | sed 's/^E2E|//'; }
state() { grep -v '^pending|' ; }
check() { if eval "$2"; then echo "  ok    $1"; else echo "  FAIL  $1"; FAILS=$((FAILS+1)); fi; }
same() { local a b; a="$(run A "sync;sync;dump" | state)"; b="$(run B "sync;sync;dump" | state)"; a="$(run A "sync;dump" | state)"; if [ "$a" = "$b" ]; then echo "  ok    $1: both devices identical"; else echo "  FAIL  $1: devices differ"; diff <(echo "$a") <(echo "$b"); FAILS=$((FAILS+1)); fi; }
mcp() { curl -s -X POST "$URL/api/mcp/test-mcp" -H 'content-type: application/json' -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":$2}}"; }

server_start
echo "1. Phone creates, Mac sees"
run A "add:Молоко;add:# Сделать;addmyday:Позвонить;list:Работа;add:Отчёт;move:Отчёт>Работа;step:Отчёт>Собрать цифры;sync" > /dev/null
OUT="$(run B "sync;dump")"
check "task arrives" 'echo "$OUT" | grep -q "^task|Молоко|Tasks||"'
check "section arrives" 'echo "$OUT" | grep -q "^task|Сделать|Tasks|section"'
check "my day flag arrives" 'echo "$OUT" | grep -q "^task|Позвонить|Tasks|myday"'
check "list, moved task and step arrive" 'echo "$OUT" | grep -q "^task|Отчёт|Работа||Собрать цифры"'
check "nothing pending on Mac" 'echo "$OUT" | grep -q "^pending|0"'

echo "2. Both edit the same task before syncing (different fields)"
run A "rename:Молоко>Овсяное молоко" > /dev/null
run B "star:Молоко;done:Молоко;step:Молоко>Проверить срок;sync" > /dev/null
OUT="$(run A "sync;dump")"
check "phone keeps its rename and gets star, done and step" 'echo "$OUT" | grep -q "^task|Овсяное молоко|Tasks|done,important|Проверить срок"'
same "after field merge"

echo "3. Offline (airplane): edits are kept, then sent when the network is back"
server_stop
OUT="$(run A "add:В самолёте 1;add:В самолёте 2;done:Позвонить;sync;dump")"
check "three changes wait while offline" 'echo "$OUT" | grep -q "^pending|3"'
OUT="$(run A "dump")"
check "pending changes survive an app restart" 'echo "$OUT" | grep -q "^pending|3" && echo "$OUT" | grep -q "^task|В самолёте 2"'
run B "add:С мака офлайн;sync" > /dev/null
server_start
OUT="$(run A "sync;dump")"
check "everything sent after reconnect" 'echo "$OUT" | grep -q "^pending|0"'
OUT="$(run B "sync;dump")"
check "Mac receives airplane edits" 'echo "$OUT" | grep -q "^task|В самолёте 1" && echo "$OUT" | grep -q "^task|Позвонить|Tasks|done,myday"'
same "after offline period"

echo "4. One device deletes, the other edits the same task later"
run A "delete:В самолёте 1" > /dev/null
run B "wait:30;rename:В самолёте 1>Переименована позже;sync" > /dev/null
OUT="$(run A "sync;sync;dump")"
check "the later edit wins, task is not lost" 'echo "$OUT" | grep -q "^task|Переименована позже"'
same "after delete vs edit"

echo "5. Delete on one device reaches the other"
run B "delete:В самолёте 2;sync" > /dev/null
OUT="$(run A "sync;dump")"
check "task removed on phone" '! echo "$OUT" | grep -q "В самолёте 2"'

echo "6. Change made through Claude (MCP) reaches devices"
mcp add_tasks '{"tasks":[{"title":"Из Claude","my_day":true,"steps":["шаг 1"]}]}' > /dev/null
OUT="$(run A "sync;dump")"
check "task from Claude arrives" 'echo "$OUT" | grep -q "^task|Из Claude|Tasks|myday|шаг 1"'
run A "done:Из Claude;sync" > /dev/null
check "Claude sees it completed" 'mcp list_tasks "{\"view\":\"my_day\",\"include_completed\":true}" | grep -q "Из Claude.*completed.*true"'

echo "7. Deleted task restored through Claude comes back"
run A "delete:Овсяное молоко;sync" > /dev/null
ID="$(mcp recover '{"action":"list_deleted"}' | grep -o 'id\\":\\"[^\\]*\\",\\"kind\\":\\"task\\",\\"title\\":\\"Овсяное молоко' | head -1 | sed 's/id\\":\\"//; s/\\".*//')"
mcp recover "{\"action\":\"undelete\",\"ids\":[\"$ID\"]}" > /dev/null
OUT="$(run A "sync;dump")"
check "restored task with its step is back" 'echo "$OUT" | grep -q "^task|Овсяное молоко|Tasks|done,important|Проверить срок"'
same "after restore"

echo "8. Server loses all data: devices put it back"
BEFORE="$(run A "dump" | state)"
server_stop; rm -f "$TODODO_LOCAL_FILE"; server_start
run A "sync;sync" > /dev/null
OUT="$(run B "sync;sync;dump" | state)"
check "server refilled from a device, nothing lost" '[ "$BEFORE" = "$OUT" ]'
same "after server reset"

echo "9. Local file damaged: the app falls back to its daily copy and catches up"
check "daily local copy exists" 'ls "$TMP/A/Backups"/state-*.json > /dev/null 2>&1'
echo "garbage" > "$TMP/A/state.json"
OUT="$(run A "sync;sync;dump" | state)"
EXPECT="$(run B "sync;dump" | state)"
check "phone recovers everything" '[ "$OUT" = "$EXPECT" ]'

echo "10. Rapid alternation: edit on phone, immediately continue on Mac"
for i in 1 2 3 4 5; do run A "add:Чередование $i;sync" > /dev/null; run B "sync;done:Чередование $i;sync" > /dev/null; done
OUT="$(run A "sync;dump")"
check "all five created on phone are done after Mac" '[ "$(echo "$OUT" | grep -c "^task|Чередование .|Tasks|done")" = "5" ]'
same "after alternation"

server_stop
echo
echo "Final state:"; run B "dump"
if [ "$FAILS" = "0" ]; then echo "E2E: ALL PASSED"; else echo "E2E: $FAILS FAILED"; echo "--- server log"; tail -20 "$TMP/server.log"; exit 1; fi
