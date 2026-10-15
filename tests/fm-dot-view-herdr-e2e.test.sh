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
cleanup() {
  local rc=$?
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
        'observed_at':m.now_iso(),'summary':'read-only proof admitted','task_id':'native-thread','turn_id':'native-turn'}
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
sync_view
[ "$(<"$BINDING")" = "$first" ] || fail 'restart reconciliation duplicated displays'
# Typing in a read-only display must never reach a shell.
lab pane send-text "$console" "touch $TMP/should-not-exist" >/dev/null
lab pane send-keys "$console" Enter >/dev/null
sleep 1
[ ! -e "$TMP/should-not-exist" ] || fail 'display executed terminal input'
python3 - "$ROOT" <<'PY'
import importlib.util, json, os, sys
from pathlib import Path
spec = importlib.util.spec_from_file_location('mailbox', Path(sys.argv[1]) / 'bin/fm-dot-mailbox.py')
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
b = m.Mailbox(os.environ['DB']); msg = b.get_messages(queue='work')['messages'][0]
note = {'schema':'fm.activity-note.v1','event_id':'result','kind':'done','observed_at':m.now_iso(),
        'summary':'read-only proof finished','task_id':'native-thread','turn_id':'native-turn'}
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
