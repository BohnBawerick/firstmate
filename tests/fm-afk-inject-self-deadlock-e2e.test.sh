#!/usr/bin/env bash
# Prove that a Claude native background daemon cannot target its own busy Herdr pane.
# Prove that the non-visible Herdr daemon terminal delivers to an idle Claude pane.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HERDR_LAB_HELPER="${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}"

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

fail() {
  printf 'not ok - %s\n' "$1" >&2
  if [ -n "${DAEMON_LOG:-}" ] && [ -f "$DAEMON_LOG" ]; then
    tail -n 30 "$DAEMON_LOG" >&2
  fi
  if [ -n "${STATE_DIR:-}" ] && [ -f "$STATE_DIR/daemon-child.err" ]; then
    cat "$STATE_DIR/daemon-child.err" >&2
  fi
  exit 1
}

pass() { printf 'ok - %s\n' "$1"; }

wait_for_file() {
  local file=$1 attempts=${2:-80} attempt=0
  while [ "$attempt" -lt "$attempts" ]; do
    [ -e "$file" ] && return 0
    sleep 0.25
    attempt=$((attempt + 1))
  done
  return 1
}

wait_for_log() {
  local pattern=$1 log=$2 attempts=${3:-80} attempt=0
  while [ "$attempt" -lt "$attempts" ]; do
    grep -F "$pattern" "$log" >/dev/null 2>&1 && return 0
    sleep 0.25
    attempt=$((attempt + 1))
  done
  return 1
}

HERDR_LAB_SESSION=$($HERDR_LAB_HELPER name fm-afk-inject-self-deadlock)
export FM_ESCALATE_BATCH_SECS=0
export FM_HOUSEKEEPING_TICK=1
export FM_POLL=1
export FM_SIGNAL_GRACE=1
export FM_HEARTBEAT=999999
export FM_CHECK_INTERVAL=999999
export FM_STALE_ESCALATE_SECS=999999
export FM_INJECT_CONFIRM_SLEEP=0.2
export FM_INJECT_CONFIRM_RETRIES=2
trap 'set +e
if [ "${AWAY_STARTED:-0}" = 1 ]; then
  FM_HOME="$HOME_DIR" HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_SUPERVISOR_TARGET="${TARGET:-}" FM_SUPERVISOR_BACKEND=herdr \
    "$ROOT/bin/fm-afk-launch.sh" stop >/dev/null 2>&1 || true
fi
if [ "${FIXTURE_RUNNING:-0}" = 1 ]; then
  "$HERDR_LAB_HELPER" run "$HERDR_LAB_SESSION" pane send-keys "$PANE_ID" ctrl+c >/dev/null 2>&1 || true
fi
"$HERDR_LAB_HELPER" teardown "$HERDR_LAB_SESSION" >/dev/null 2>&1 || true
rm -rf "${HOME_DIR:-}"' EXIT

$HERDR_LAB_HELPER provision "$HERDR_LAB_SESSION" >/dev/null \
  || fail "could not provision the named Herdr lab"

HOME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-self-deadlock-home.XXXXXX")
STATE_DIR="$HOME_DIR/state"
mkdir -p "$STATE_DIR"

WORKSPACE_JSON=$($HERDR_LAB_HELPER run "$HERDR_LAB_SESSION" \
  workspace create --cwd /tmp --label fm-afk-self-deadlock --no-focus) \
  || fail "could not create the isolated supervisor workspace"
WORKSPACE_ID=$(printf '%s' "$WORKSPACE_JSON" | jq -r '.result.workspace.workspace_id // empty')
PANE_ID=$(printf '%s' "$WORKSPACE_JSON" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$WORKSPACE_ID" ] || fail "workspace create returned no workspace id"
[ -n "$PANE_ID" ] || fail "workspace create returned no pane id"
TARGET="$HERDR_LAB_SESSION:$PANE_ID"

FLEET_JSON=$($HERDR_LAB_HELPER run "$HERDR_LAB_SESSION" \
  tab create --workspace "$WORKSPACE_ID" --cwd /tmp --label fm-fleet-worker --no-focus) \
  || fail "could not create the busy fleet worker pane"
FLEET_PANE_ID=$(printf '%s' "$FLEET_JSON" | jq -r '.result.root_pane.pane_id // empty')
[ -n "$FLEET_PANE_ID" ] || fail "fleet worker tab returned no pane id"
$HERDR_LAB_HELPER run "$HERDR_LAB_SESSION" pane report-agent "$FLEET_PANE_ID" \
  --source fm-afk-repro --agent fm-afk-fleet-worker --state working >/dev/null \
  || fail "could not mark the fleet worker busy"

# shellcheck disable=SC2016
FIXTURE_SCRIPT='set -u
mode=$1
root=$2
helper=$3
session=$4
pane=$5
home=$6
state=$7
log=$8
report() {
  "$helper" run "$session" pane report-agent "$pane" \
    --source fm-afk-repro --agent fm-afk-primary --state "$1" >/dev/null 2>&1 || true
}
daemon_pid=
if [ "$mode" = native ]; then
  report working
  (
    HERDR_SESSION="$session" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
      FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=1 FM_POLL=1 \
      FM_SIGNAL_GRACE=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 \
      FM_STALE_ESCALATE_SECS=999999 FM_INJECT_CONFIRM_SLEEP=0.2 \
      FM_INJECT_CONFIRM_RETRIES=2 "$root/bin/fm-afk-start.sh" \
      >"$state/daemon-child.out" 2>"$state/daemon-child.err"
  ) &
  daemon_pid=$!
else
  report idle
fi
old_stty=$(stty -g 2>/dev/null || true)
[ -z "$old_stty" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
cleanup() {
  trap - EXIT INT TERM
  if [ -n "$daemon_pid" ]; then
    kill "$daemon_pid" 2>/dev/null || true
    wait "$daemon_pid" 2>/dev/null || true
  fi
  report idle
  [ -z "$old_stty" ] || stty "$old_stty" 2>/dev/null || true
}
trap cleanup EXIT
trap cleanup INT TERM
buf=
mark=$(printf "\\u2063")
redraw() { printf "\\r\\033[K❯ %s" "$buf"; }
submit() {
  local line=$buf kind=user
  [ "${line#"$mark"}" != "$line" ] && kind=injection
  printf "%s\\t%s\\n" "$line" "$kind" >> "$log"
  buf=
  printf "\\r\\033[K\\n"
  redraw
  if [ "$mode" = idle ]; then
    report working
    sleep 0.6
    report idle
  fi
}
redraw
while IFS= read -r -n 1 ch; do
  if [ -z "$ch" ]; then
    submit
    continue
  fi
  case "$ch" in
    $'\\r'|$'\\n') submit ;;
    $'\\177'|$'\\b') buf=${buf%?}; redraw ;;
    *) buf=${buf}${ch}; redraw ;;
  esac
done'

start_fixture() {
  local mode=$1 command
  command=$(printf 'bash -c %q -- %q %q %q %q %q %q %q %q' \
    "$FIXTURE_SCRIPT" "$mode" "$ROOT" "$HERDR_LAB_HELPER" \
    "$HERDR_LAB_SESSION" "$PANE_ID" "$HOME_DIR" "$STATE_DIR" \
    "$STATE_DIR/submitted.log")
  $HERDR_LAB_HELPER run "$HERDR_LAB_SESSION" pane run "$PANE_ID" "$command" \
    >/dev/null || fail "could not start the $mode primary-pane fixture"
  FIXTURE_RUNNING=1
  sleep 1
}

stop_fixture() {
  [ "${FIXTURE_RUNNING:-0}" = 1 ] || return 0
  $HERDR_LAB_HELPER run "$HERDR_LAB_SESSION" pane send-keys "$PANE_ID" ctrl+c \
    >/dev/null 2>&1 || true
  sleep 0.75
  FIXTURE_RUNNING=0
}

failed_run_cleanup_probe() {
  local probe_session probe_output probe_sessions
  probe_session=$("$HERDR_LAB_HELPER" name fm-afk-cleanup)
  probe_output=$(mktemp "${TMPDIR:-/tmp}/fm-afk-cleanup-probe.XXXXXX") \
    || fail "could not create the cleanup-probe output"
  if bash -c '
    set -u
    helper=$1
    session=$2
    trap '"'"'"$helper" teardown "$session"'"'"' EXIT
    "$helper" provision "$session" >/dev/null || exit 91
    workspace_json=$("$helper" run "$session" workspace create --cwd /tmp \
      --label fm-afk-cleanup-probe --no-focus) || exit 92
    workspace_id=$(printf "%s" "$workspace_json" | jq -r \
      ".result.workspace.workspace_id // empty")
    [ -n "$workspace_id" ] || exit 93
    printf "cleanup-probe-created=%s\\n" "$workspace_id" >&2
    [ "$workspace_id" = intentional-workspace-id ] || exit 94
  ' bash "$HERDR_LAB_HELPER" "$probe_session" >"$probe_output" 2>&1; then
    rm -f "$probe_output"
    fail "failed-run cleanup probe unexpectedly succeeded"
  fi
  grep -q 'cleanup-probe-created=' "$probe_output" \
    || { rm -f "$probe_output"; fail "cleanup probe did not fail after creating a workspace"; }
  probe_sessions=$("$HERDR_LAB_HELPER" run "$probe_session" session list --json) \
    || { rm -f "$probe_output"; fail "could not inspect the failed-run cleanup probe"; }
  rm -f "$probe_output"
  if printf "%s" "$probe_sessions" | jq -e --arg name "$probe_session" \
    '.sessions[]? | select(.name == $name)' >/dev/null 2>&1; then
    fail "failed-run cleanup probe left its named lab session behind"
  fi
  pass "failed-run cleanup removes the lab session and its created workspace"
}

stop_away() {
  [ "${AWAY_STARTED:-0}" = 1 ] || return 0
  FM_HOME="$HOME_DIR" HERDR_SESSION="$HERDR_LAB_SESSION" \
    FM_SUPERVISOR_TARGET="$TARGET" FM_SUPERVISOR_BACKEND=herdr \
    "$ROOT/bin/fm-afk-launch.sh" stop >/dev/null 2>&1 \
    || fail "away-mode cleanup failed"
  AWAY_STARTED=0
}

# Reproduce the old topology directly through the daemon entry point.
start_fixture native
wait_for_file "$STATE_DIR/.supervise-daemon.pid" \
  || fail "native daemon never started"
DAEMON_LOG="$STATE_DIR/.supervise-daemon.log"
wait_for_log "target=$TARGET; target_source=HERDR_ENV(HERDR_PANE_ID); backend=herdr; backend_source=HERDR_ENV" \
  "$DAEMON_LOG" || fail "native daemon did not auto-discover its own pane"
printf 'done: native topology reproduction\n' > "$STATE_DIR/repro.status"
wait_for_log "inject deferred: supervisor pane busy (agent mid-turn)" "$DAEMON_LOG" \
  || fail "native self-target did not hit the busy guard"
sleep 4
grep -F "inject deferred: supervisor pane busy (agent mid-turn)" "$DAEMON_LOG" >/dev/null \
  || fail "native self-target stopped reporting the busy deferral"
[ -s "$STATE_DIR/.subsuper-escalations" ] \
  || fail "native self-target lost the undelivered escalation buffer"
[ ! -s "$STATE_DIR/submitted.log" ] \
  || fail "native self-target submitted a digest despite its busy pane"
pass "reproduced: daemon hosted in its target pane defers forever on Herdr busy state"
stop_away
stop_fixture
rm -f "$STATE_DIR"/*.status "$STATE_DIR"/.supervise-daemon.log \
  "$STATE_DIR"/.supervise-daemon.pid "$STATE_DIR"/.supervise-daemon.lock \
  "$STATE_DIR"/.subsuper-* "$STATE_DIR"/.watcher-down* \
  "$STATE_DIR"/.last-watcher-beat "$STATE_DIR"/.watch.lock \
  "$STATE_DIR"/daemon-child.* "$STATE_DIR"/submitted.log

# Verify the repaired native compatibility path refuses ambient targeting.
GUARD_OUTPUT=$(CLAUDECODE=1 FM_HOME="$HOME_DIR" HERDR_SESSION="$HERDR_LAB_SESSION" \
  FM_SUPERVISOR_BACKEND=herdr "$ROOT/bin/fm-afk-launch.sh" start-native 2>&1) \
  && fail "Claude + Herdr native launch accepted missing explicit target"
printf "%s" "$GUARD_OUTPUT" | grep -F \
  "requires explicit HERDR_SESSION and FM_SUPERVISOR_TARGET" >/dev/null \
  || fail "native compatibility path did not report its explicit-target requirement"
[ ! -e "$STATE_DIR/.afk-daemon-terminal" ] \
  || fail "native compatibility guard created a daemon terminal before refusing"
MISMATCH_OUTPUT=$(CLAUDECODE=1 FM_HOME="$HOME_DIR" HERDR_SESSION="$HERDR_LAB_SESSION" \
  FM_SUPERVISOR_TARGET="default:$PANE_ID" FM_SUPERVISOR_BACKEND=herdr \
  "$ROOT/bin/fm-afk-launch.sh" start-native 2>&1) \
  && fail "Claude + Herdr native launch accepted a target outside its session"
printf "%s" "$MISMATCH_OUTPUT" | grep -F \
  "is outside HERDR_SESSION" >/dev/null \
  || fail "native compatibility path did not reject a mismatched target session"
failed_run_cleanup_probe

# Exercise the repaired topology with a busy fleet worker and an idle Claude pane.
# CLAUDECODE makes the launcher take the same harness branch as a Claude primary.
CLAUDECODE=1 FM_HOME="$HOME_DIR" HERDR_SESSION="$HERDR_LAB_SESSION" \
  FM_SUPERVISOR_TARGET="$TARGET" FM_SUPERVISOR_BACKEND=herdr \
  FM_AFK_LAUNCH_LABEL="fm-afk-self-deadlock-fixed" \
  "$ROOT/bin/fm-afk-launch.sh" start-native >/dev/null \
  || fail "non-visible away-mode launch failed"
AWAY_STARTED=1
RECORD_BACKEND=$(cut -f1 "$STATE_DIR/.afk-daemon-terminal" 2>/dev/null || true)
[ "$RECORD_BACKEND" = herdr ] \
  || fail "Claude + Herdr native launch still recorded an in-pane daemon"
start_fixture idle
wait_for_file "$STATE_DIR/.supervise-daemon.pid" \
  || fail "non-visible daemon never started"
RECORD_TARGET=$(cut -f2 "$STATE_DIR/.afk-daemon-terminal" 2>/dev/null || true)
[ -n "$RECORD_TARGET" ] && [ "$RECORD_TARGET" != "$TARGET" ] \
  || fail "non-visible launch did not record a separate daemon pane"
wait_for_log "backend=herdr" "$STATE_DIR/.supervise-daemon.log" \
  || fail "non-visible daemon did not start"
# Keep the heartbeat backstop from winning the race with the status signal.
date +%s > "$STATE_DIR/.subsuper-last-scan"
printf 'done: fleet worker remains busy while primary is idle\n' > "$STATE_DIR/repro.status"
wait_for_log "Supervisor escalate" "$STATE_DIR/submitted.log" \
  || fail "digest was not delivered to the idle Claude pane"
grep -F $'\tinjection' "$STATE_DIR/submitted.log" >/dev/null \
  || fail "delivered digest was not classified as an injection"
$HERDR_LAB_HELPER run "$HERDR_LAB_SESSION" agent get "$FLEET_PANE_ID" \
  | jq -e '.result.agent.agent_status == "working"' >/dev/null \
  || fail "fleet worker was no longer busy during delivery"
pass "fixed: digest delivered to idle Claude pane while a Herdr fleet worker stayed busy"

stop_away
stop_fixture
