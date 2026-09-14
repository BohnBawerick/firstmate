#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB="$ROOT/.test-phase-herdr/runtime"
EVIDENCE=/home/bohn/.no-mistakes/evidence/01M2FSAP36PE8TM5G7KKWCZCFM/herdr-recheck
mkdir -p "$LAB" "$LAB/bin" "$LAB/home/.gemini/antigravity-cli" "$LAB/home/.gemini/config" "$LAB/home/state" "$LAB/home/data/liveness" "$LAB/home/config" "$LAB/home/projects"
export HERDR_LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"
export HERDR_LAB_SESSION
HERDR_LAB_SESSION=$("$HERDR_LAB_HELPER" name nm-live-liveness)
export FM_HERDR_LAB_STATE_DIR="$LAB/lab-state"
export HERDR_ORIGINAL_PATH=$PATH HERDR_ORIGINAL_HOME=$HOME
cleanup() {
  local rc=$?
  trap - EXIT
  env PATH="$HERDR_ORIGINAL_PATH" HOME="$HERDR_ORIGINAL_HOME" "$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" || rc=1
  printf 'guarded cleanup exit=%s\n' "$rc"
  exit "$rc"
}
trap cleanup EXIT
"$HERDR_LAB_HELPER" provision "$HERDR_LAB_SESSION"
lab() { env PATH="$HERDR_ORIGINAL_PATH" HOME="$HERDR_ORIGINAL_HOME" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "$@"; }
lab status --json > "$EVIDENCE/herdr-live-status.json"
cp "$LAB/lab-state/$HERDR_LAB_SESSION.fleet-state.json" "$EVIDENCE/herdr-default-baseline.json"
for filename in jetski_state.pbtxt installation_id; do
  cp "$HERDR_ORIGINAL_HOME/.gemini/antigravity-cli/$filename" "$LAB/home/.gemini/antigravity-cli/$filename"
done
cp "$HERDR_ORIGINAL_HOME/.gemini/config/config.json" "$LAB/home/.gemini/config/config.json"
printf '{}\n' > "$LAB/home/.gemini/antigravity-cli/settings.json"
git init -q "$LAB/project"
git -C "$LAB/project" -c user.name=Test -c user.email=test@local commit -q --allow-empty -m init
git -C "$LAB/project" worktree add -q -b live "$LAB/wt"
cat > "$LAB/bin/herdr" <<'WRAP'
#!/usr/bin/env bash
set -eu
args=("$@")
n=${#args[@]}
if (( n >= 2 )) && [[ ${args[n-2]} == --session && ${args[n-1]} == "$HERDR_LAB_SESSION" ]]; then
  unset 'args[n-1]' 'args[n-2]'
fi
for arg in "${args[@]}"; do
  case "$arg" in --session|--session=*) exit 90;; esac
done
if [ -f "$FM_LIVE_LAB/unreadable" ]; then
  if [[ ${args[0]:-} == agent && ${args[1]:-} == get ]]; then
    printf '{"error":{"code":"agent_not_found"}}\n'
    exit 1
  fi
  if [[ ${args[0]:-} == pane && ${args[1]:-} == process-info ]]; then
    printf 'injected unavailable process evidence\n' >&2
    exit 1
  fi
fi
exec env -u XDG_CONFIG_HOME PATH="$HERDR_ORIGINAL_PATH" HOME="$HERDR_ORIGINAL_HOME" "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" "${args[@]}"
WRAP
chmod +x "$LAB/bin/herdr"
CREATE=$(lab workspace create --cwd "$LAB/wt" --label liveness --no-focus)
printf '%s\n' "$CREATE" > "$EVIDENCE/herdr-live-workspace.json"
PANE=$(jq -er '.result.root_pane.pane_id' <<< "$CREATE")
WS=$(jq -er '.result.workspace.workspace_id' <<< "$CREATE")
TAB=$(jq -er '.result.tab.tab_id // .result.root_pane.tab_id // .result.workspace.active_tab_id' <<< "$CREATE")
printf 'session=%s pane=%s workspace=%s tab=%s\n' "$HERDR_LAB_SESSION" "$PANE" "$WS" "$TAB"
cat > "$LAB/home/state/liveness.meta" <<EOF
kind=scout
harness=agy
backend=herdr
project=$LAB/project
worktree=$LAB/wt
endpoint_task_id=liveness
window=$HERDR_LAB_SESSION:$PANE
herdr_session=$HERDR_LAB_SESSION
herdr_workspace_id=$WS
herdr_tab_id=$TAB
herdr_pane_id=$PANE
EOF
cat > "$LAB/home/data/liveness/brief.md" <<EOF
# Task
## Captain's intent
Exercise a live shell tool and durable steering in this isolated test workspace.
## Firstmate spec
Run exactly this shell command first: echo \$\$ > '$LAB/tool.pid'; touch '$LAB/tool-started'; sleep 90; touch '$LAB/tool-finished'.
Then read every pending instruction in '$LAB/home/state/liveness.inbox', carry it out, and move each handled message to the handled subdirectory.
Work only beneath '$LAB'. Do not run any Firstmate command, contact anyone, or change other files.
EOF
# Set the pane's environment before the production launch so worker writes stay local.
ENVLINE=$(printf 'export HOME=%q XDG_CONFIG_HOME=%q; unset CLAUDECODE PI_CODING_AGENT HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH' "$LAB/home" "$LAB/home/.config")
lab pane run "$PANE" "$ENVLINE" >/dev/null
sleep 1
export FM_LIVE_LAB="$LAB" FM_HOME="$LAB/home" FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1
export PATH="$LAB/bin:$HERDR_ORIGINAL_PATH"
export FM_AGY_READY_POLLS=0 FM_AGY_POLL_INTERVAL=0.1
set +e
env HOME="$LAB/home" "$ROOT/bin/fm-spawn.sh" liveness --relaunch --harness agy --model gemini-3.8-flash-low > "$EVIDENCE/herdr-live-spawn.log" 2>&1
spawn_rc=$?
set -e
cat "$EVIDENCE/herdr-live-spawn.log"
printf 'spawn exit=%s\n' "$spawn_rc"
[ "$spawn_rc" -ne 0 ]
grep -q 'unreadable: agy startup unconfirmed:' "$LAB/home/state/liveness.status"
for ((i=0; i<180; i++)); do
  [ ! -f "$LAB/tool-started" ] || break
  sleep 1
done
lab pane read "$PANE" > "$EVIDENCE/herdr-live-startup-pane.json"
[ -f "$LAB/tool-started" ] || { echo 'FAIL: real agy never started its shell tool'; exit 1; }
lab pane process-info --pane "$PANE" > "$EVIDENCE/herdr-live-processes.json"
lab agent get "$PANE" > "$EVIDENCE/herdr-live-agent.json" || true
TOOL_PID=$(cat "$LAB/tool.pid")
kill -0 "$TOOL_PID"
echo 'PASS: startup unconfirmed while real agent and shell tool remain live'
touch "$LAB/unreadable"
. "$ROOT/bin/fm-backend.sh"
state=$(fm_backend_agent_state herdr "$HERDR_LAB_SESSION:$PANE")
printf 'fault-injected agent state=%s\n' "$state"
[ "$state" = unreadable ]
"$ROOT/bin/fm-send.sh" liveness "Write the sum of 12345 and 67890 to '$LAB/steer-result'." > "$EVIDENCE/herdr-live-send.log" 2>&1
cat "$EVIDENCE/herdr-live-send.log"
cp "$LAB/home/state/liveness.meta" "$EVIDENCE/herdr-live-preserved.meta"
set +e
"$ROOT/bin/fm-control.sh" liveness relaunch --note 'Probe refusal while process evidence is unavailable.' > "$EVIDENCE/herdr-live-recovery.log" 2>&1
recovery_rc=$?
set -e
cat "$EVIDENCE/herdr-live-recovery.log"
[ "$recovery_rc" -ne 0 ]
grep -q "endpoint reads 'unreadable'" "$EVIDENCE/herdr-live-recovery.log"
cmp "$LAB/home/state/liveness.meta" "$EVIDENCE/herdr-live-preserved.meta"
kill -0 "$TOOL_PID"
lab pane get "$PANE" > /dev/null
echo 'PASS: uncertain recovery refused without killing the tool or changing ownership'
for ((i=0; i<180; i++)); do
  [ ! -f "$LAB/steer-result" ] || break
  sleep 1
done
lab pane read "$PANE" > "$EVIDENCE/herdr-live-final-pane.json"
[ -f "$LAB/tool-finished" ]
[ "$(tr -cd '0-9' < "$LAB/steer-result")" = 80235 ]
cp "$LAB/steer-result" "$EVIDENCE/herdr-live-steer-result.txt"
cp "$LAB/home/state/liveness.status" "$EVIDENCE/herdr-live-task.status"
cp -r "$LAB/home/state/liveness.inbox" "$EVIDENCE/herdr-live-inbox"
echo 'PASS: live shell tool completed and worker acted on durable steering' 
rm "$LAB/unreadable"
