#!/usr/bin/env bash
# Real Herdr dot displays: replay, exact ownership, focus and delivery-before-close.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
command -v herdr >/dev/null || { printf 'SKIP: herdr is unavailable\n'; exit 0; }
TMP=$(mktemp -d)
export HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name dot-mcp-bridge)
export HERDR_LAB_SESSION ORIGINAL_PATH=$PATH
WATCH_PID='' HELD_LOCK=''
cleanup() {
  local rc=$?
  if [ -n "$WATCH_PID" ]; then kill -TERM "$WATCH_PID" 2>/dev/null || true; wait "$WATCH_PID" 2>/dev/null || true; fi
  if [ -n "$HELD_LOCK" ]; then fm_lock_release "$HELD_LOCK" || rc=1; fi
  env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  fm_test_cleanup
  rm -rf "$TMP"
  exit "$rc"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
mkdir -p "$TMP/fakebin" "$TMP/home/state" "$TMP/home/data"
# Every backend call, even status/version checks, passes the lab guard.
cat > "$TMP/fakebin/herdr" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
args=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --session ]; then
    [ "$2" = "$HERDR_LAB_SESSION" ] || exit 90
    shift 2
  else
    args+=("$1"); shift
  fi
done
if [ "${args[0]:-}" = pane ] && [ "${args[1]:-}" = run ] && [[ "${args[3]:-}" == exec\ env*fm-dot-view.py* ]]; then
  args[3]=${args[3]#exec }
fi
exec env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
WRAPPER
chmod +x "$TMP/fakebin/herdr"
export PATH="$TMP/fakebin:$PATH" FM_HOME="$TMP/home" FM_ROOT_OVERRIDE="$TMP/home"
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE
unset HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_ENV
export HERDR_SESSION=$HERDR_LAB_SESSION
lab() { env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
export DB="$TMP/mailbox/db.sqlite3"
printf 'Idle until routed work; reply through the mailbox.\n' > "$TMP/charter.md"
bash "$ROOT/bin/fm-dot-secondmate.sh" register dot-test "$DB" "$TMP/mate" work http://127.0.0.1:1/health http://127.0.0.1:1/readyz 'Cloud tests' "$TMP/charter.md" > /dev/null
bash "$ROOT/bin/fm-send.sh" dot-test 'Read-only proof' > /dev/null
# A separate focused tab must survive every display operation.
other=$(lab workspace create --cwd "$TMP" --label unrelated --focus)
other_ws=$(jq -r '.result.workspace.workspace_id' <<< "$other")
other_tab=$(jq -r '.result.tab.tab_id' <<< "$other")
python3 - "$ROOT" <<'PY'
import importlib.util, json, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('mailbox', Path(sys.argv[1]) / 'bin/fm-dot-mailbox.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
b = m.Mailbox(os.environ['DB'])
msg = b.get_messages(queue='work')['messages'][0]
note = {'schema':'fm.activity-note.v1','event_id':'created','kind':'task-created',
        'observed_at':'2026-01-01T00:00:00Z','summary':'read-only proof admitted','task_id':'native-thread','turn_id':'native-turn'}
b.reply_message(msg['id'], 'activity-note: ' + json.dumps(note), msg['correlation_id'])
PY
sync_view() { bash "$ROOT/bin/fm-dot-view.sh" sync dot-test "$HERDR_LAB_SESSION"; }
sync_view
BINDING="$FM_HOME/state/dot-views/dot-test.json"
first=$(<"$BINDING")
ws=$(jq -r '.workspace' <<< "$first")
child=$(jq -r '.displays | keys[] | select(.!="console")' <<< "$first")
pane=$(jq -r --arg c "$child" '.displays[$c].pane' <<< "$first")
console=$(jq -r '.displays.console.pane' <<< "$first")
[ "$(jq '.displays | length' <<< "$first")" = 2 ] || fail 'expected mate console and one cloud display'
for _ in {1..100}; do
  rendered=$(lab pane read "$pane")
  if [[ "$rendered" == *native-thread* && "$rendered" == *read-only* ]]; then break; fi
  sleep .1
done
[[ "$rendered" == *native-thread* && "$rendered" == *read-only* ]] || fail 'cloud renderer did not replay durable activity'
python3 - "$ROOT" <<'PY'
import importlib.util, json, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('mailbox', Path(sys.argv[1]) / 'bin/fm-dot-mailbox.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
b = m.Mailbox(os.environ['DB']); msg = b.get_messages(queue='work')['messages'][0]
for n in range(101):
    note = {'schema':'fm.activity-note.v1','event_id':f'past-{n}','kind':'done',
            'observed_at':'2026-01-01T00:00:00Z','summary':'retained result','task_id':f'past-task-{n}','turn_id':'turn'}
    b.reply_message(msg['id'], 'activity-note: ' + json.dumps(note), msg['correlation_id'])
with b.transaction():
    b.conn.execute("UPDATE mate_replies SET published=1 WHERE json_extract(activity,'$.event_id') LIKE 'past-%'")
PY
sync_view
[ "$(<"$BINDING")" = "$first" ] || fail 'restart reconciliation duplicated displays'
python3 - "$ROOT" <<'PY'
import importlib.util, json, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('mailbox', Path(sys.argv[1]) / 'bin/fm-dot-mailbox.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
b = m.Mailbox(os.environ['DB']); msg = b.get_messages(queue='work')['messages'][0]
for event, turn, stamp in [('next-turn','native-turn-2','2026-01-01T00:01:00Z'),
                            ('old-progress','native-turn','2026-01-01T00:00:30Z')]:
    note = {'schema':'fm.activity-note.v1','event_id':event,'kind':'milestone',
            'observed_at':stamp,'summary':'read-only proof progressing','task_id':'native-thread','turn_id':turn}
    b.reply_message(msg['id'], 'activity-note: ' + json.dumps(note), msg['correlation_id'])
PY
sync_view
[ "$(<"$BINDING")" = "$first" ] || fail 'turn change replaced or duplicated the native task display'
for _ in {1..100}; do
  rendered=$(lab pane read "$pane")
  if [[ "$rendered" == *'Turn: native-turn-2'* ]]; then break; fi
  sleep .1
done
[[ "$rendered" == *'Turn: native-turn-2'* ]] || fail 'task display did not follow the latest turn'
. "$ROOT/bin/fm-backend.sh"
. "$ROOT/bin/backends/herdr.sh"
. "$ROOT/bin/fm-wake-lib.sh"
reader_pid() {
  local target=$1 expected_child=$2 expected info
  expected=$(jq -n --arg reader "$ROOT/bin/fm-dot-view.py" --arg db "$DB" --arg child "$expected_child" \
    '[$reader,"--db",$db,"dot-test"] + (if $child == "console" then [] else ["--child",$child] end)')
  info=$(lab pane process-info --pane "$target")
  jq -er --arg pane "$target" --argjson expected "$expected" '
    select(.result.process_info.pane_id==$pane)
    | .result.process_info.foreground_processes | select(length==1) | .[0]
    | select(.argv[1:]==$expected and .pid>1) | .pid' <<< "$info"
}
stop_reader() {
  local target=$1 expected_child=$2 pid
  pid=$(reader_pid "$target" "$expected_child") || fail 'reader identity unavailable'
  [ "$(reader_pid "$target" "$expected_child")" = "$pid" ] || fail 'reader process identity changed'
  kill -TERM "$pid"
  for _ in {1..40}; do
    if fm_backend_herdr_pane_idle_shell_pid "$HERDR_LAB_SESSION" "$target" >/dev/null; then return; fi
    sleep .1
  done
  fail 'owned pane did not return to its idle shell'
}
stop_reader "$pane" "$child"
stop_reader "$console" console
sync_view
[ "$(<"$BINDING")" = "$first" ] || fail 'reader recovery changed display bindings'
for _ in {1..50}; do
  if reader_pid "$pane" "$child" >/dev/null && reader_pid "$console" console >/dev/null; then break; fi
  sleep .1
done
reader_pid "$pane" "$child" >/dev/null || fail 'missing child reader was not restored'
reader_pid "$console" console >/dev/null || fail 'missing console reader was not restored'
stop_reader "$console" console
lab pane run "$console" 'sleep 60' >/dev/null
for _ in {1..50}; do
  unrelated_pid=$(lab pane process-info --pane "$console" | jq -r '.result.process_info.foreground_processes[]? | select(.name=="sleep") | .pid')
  [ -n "$unrelated_pid" ] && break
  sleep .1
done
[ -n "$unrelated_pid" ] || fail 'unrelated process fixture did not start'
if sync_view >/dev/null 2>&1; then fail 'unrelated process was accepted as a reader'; fi
kill -0 "$unrelated_pid" || fail 'reader recovery touched an unrelated process'
lab pane get "$console" >/dev/null || fail 'reader recovery removed the unrelated process pane'
[ "$(lab pane process-info --pane "$console" | jq -r '.result.process_info.foreground_processes[]? | select(.name=="sleep") | .pid')" = "$unrelated_pid" ] || fail 'unrelated process identity changed'
kill -TERM "$unrelated_pid"
for _ in {1..40}; do
  if fm_backend_herdr_pane_idle_shell_pid "$HERDR_LAB_SESSION" "$console" >/dev/null; then break; fi
  sleep .1
done
sync_view
# Typing in a read-only display must never reach a shell.
lab pane send-text "$console" "touch $TMP/should-not-exist" >/dev/null
lab pane send-keys "$console" Enter >/dev/null
sleep 1
[ ! -e "$TMP/should-not-exist" ] || fail 'display executed terminal input'
HELD_LOCK=$(fm_backend_herdr_presentation_session_lock_path "$HERDR_LAB_SESSION")
fm_lock_try_acquire "$HELD_LOCK" || fail 'could not hold the lab presentation lock'
if sync_view >/dev/null 2>&1; then fail 'sync ignored presentation lock contention'; fi
python3 - "$ROOT" <<'PY'
import importlib.util, json, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('mailbox', Path(sys.argv[1]) / 'bin/fm-dot-mailbox.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
b = m.Mailbox(os.environ['DB']); msg = b.get_messages(queue='work')['messages'][0]
note = {'schema':'fm.activity-note.v1','event_id':'watch-created','kind':'task-created',
        'observed_at':m.now_iso(),'summary':'watch contention proof','task_id':'watch-task','turn_id':'turn'}
b.reply_message(msg['id'], 'activity-note: ' + json.dumps(note), msg['correlation_id'])
PY
bash "$ROOT/bin/fm-dot-view.sh" watch dot-test "$HERDR_LAB_SESSION" > "$TMP/watch.log" 2>&1 &
WATCH_PID=$!
sleep 1
kill -0 "$WATCH_PID" 2>/dev/null || fail 'watch exited during presentation lock contention'
fm_lock_release "$HELD_LOCK"
HELD_LOCK=''
for _ in {1..80}; do
  [ "$(jq '.displays | length' "$BINDING")" = 3 ] && break
  sleep .2
done
[ "$(jq '.displays | length' "$BINDING")" = 3 ] || fail 'watch did not reconcile after contention cleared'
kill -0 "$WATCH_PID" || fail 'watch stopped after contention cleared'
kill -TERM "$WATCH_PID"
wait "$WATCH_PID"
WATCH_PID=''
python3 - "$ROOT" <<'PY'
import importlib.util, json, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('mailbox', Path(sys.argv[1]) / 'bin/fm-dot-mailbox.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
b = m.Mailbox(os.environ['DB']); msg = b.get_messages(queue='work')['messages'][0]
note = {'schema':'fm.activity-note.v1','event_id':'result','kind':'done','observed_at':'2026-01-01T00:02:00Z',
        'summary':'read-only proof finished','task_id':'native-thread','turn_id':'native-turn-2'}
b.reply_message(msg['id'], 'activity-note: ' + json.dumps(note), msg['correlation_id'])
note.update(event_id='watch-result', task_id='watch-task', turn_id='turn', observed_at=m.now_iso())
b.reply_message(msg['id'], 'activity-note: ' + json.dumps(note), msg['correlation_id'])
PY
sync_view
lab pane get "$pane" >/dev/null || fail 'closed a terminal tab before parent delivery'
python3 - "$ROOT" <<'PY'
import importlib.util, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('mailbox', Path(sys.argv[1]) / 'bin/fm-dot-mailbox.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
m.Mailbox(os.environ['DB']).publish_mate_replies()
PY
sync_view
[ "$(jq '.displays | length' "$BINDING")" = 1 ] || fail 'delivered terminal display was not retired'
lab pane get "$console" >/dev/null || fail 'closed the mate console'
focus=$(lab workspace get "$other_ws")
jq -e --arg tab "$other_tab" '.result.workspace.focused==true and .result.workspace.active_tab_id==$tab' <<< "$focus" >/dev/null || fail 'display reconciliation changed unrelated focus'
[ "$(lab tab list --workspace "$ws" | jq '.result.tabs | length')" = 1 ] || fail 'unexpected leftover display tabs'
# No unknown/renamed binding may grant cleanup or replace a display.
console_tab=$(jq -r '.displays.console.tab' "$BINDING")
lab tab rename "$console_tab" renamed-display >/dev/null
if sync_view >/dev/null 2>&1; then fail 'renamed display was adopted'; fi
lab pane get "$console" >/dev/null || fail 'renamed display was removed'
pass 'real Herdr: read-only replay, idempotent restart, exact ownership, focus, and delivered-result cleanup'
