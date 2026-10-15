#!/usr/bin/env bash
# tests/fm-backend-herdr-eventwait-smoke.test.sh - REAL-herdr smoke test for the
# native pane.agent_status_changed push escalation (fm_backend_herdr_wait_transition,
# bin/backends/herdr.sh, and its raw-socket reader bin/backends/herdr-eventwait.py).
# It drives a real idle->blocked transition in an ISOLATED, never-default herdr
# lab session and asserts the subscriber returns that transition sub-second and
# that the watcher's handle_push_transition lands a stale record in a scratch
# state/.wake-queue. Skips cleanly when herdr, jq, or python3 is missing.
#
# Safety (2026-07-02 incident, tests/herdr-test-safety.sh): cleanup uses ONLY
# herdr_safe_stop_and_delete on a private fm-lab-* session, never a bare/ambient
# `herdr server stop`. Every lifecycle op goes through bin/fm-herdr-lab.sh, which
# refuses the default session and verifies the fleet-state tripwire.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by the event subscriber)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity (tests/herdr-test-safety.sh).
herdr_forget_inherited_pane

SESSION="fm-lab-eventwait-smoke-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
cleanup_all() {
  [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare the isolated Herdr lab session"

# The dispatcher is a separately linted production boundary. Its dynamic
# adapter source edges stop at each independently linted canonical adapter.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

HERDR_VERSION=$(herdr --version 2>/dev/null | head -1)

# --- real capability gate ----------------------------------------------------

if ! fm_backend_herdr_events_capable "$SESSION"; then
  echo "skip: this herdr build is below the events.subscribe capability (protocol < 16 or events surface absent)"
  cleanup_all
  trap - EXIT
  exit 0
fi
pass "real herdr ($HERDR_VERSION): events.subscribe capability gate passes (protocol >= 16, events surface present in api schema)"

# --- container + a real task pane in the isolated session --------------------

CONTAINER_RAW=$(fm_backend_herdr_container_ensure /tmp) || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-evwait1" /tmp "$SEEDED_TAB_ID") || fail "create_task failed"
read -r _TAB_ID PANE_ID <<EOF
$IDS
EOF
[ -n "$PANE_ID" ] || fail "create_task did not return a pane id"
TARGET="$SESSION:$PANE_ID"

# scratch firstmate state so window_to_task and the wake queue resolve
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-evwait.XXXXXX")
STATE="$SCRATCH/state"; mkdir -p "$STATE"
cat > "$STATE/evwait1.meta" <<EOF
window=$TARGET
backend=herdr
kind=ship
herdr_session=$SESSION
herdr_workspace_id=${CONTAINER#*:}
herdr_tab_id=$_TAB_ID
herdr_pane_id=$PANE_ID
EOF

cp "$STATE/evwait1.meta" "$STATE/a.meta"
mkdir -p "$SCRATCH/data" "$SCRATCH/config"
watch_once() {
  FM_HOME="$SCRATCH" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$SCRATCH/data" \
    FM_CONFIG_OVERRIDE="$SCRATCH/config" FM_BACKEND_HERDR_EVENTS_FORCE=0 \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_HOME_SUMMARY_INTERVAL=999999 timeout 12 "$ROOT/bin/fm-watch.sh" > "$SCRATCH/watch.out" 2>&1
}
watch_once || fail "the reused-address watcher did not report the stale task: $(cat "$SCRATCH/watch.out")"
grep -F 'agent missing' "$SCRATCH/watch.out" >/dev/null || fail "the stale endpoint was not classified missing"
grep -F 'task a)' "$SCRATCH/watch.out" >/dev/null || fail "the missing endpoint report did not identify task a"
MISSING_REASON=$(sed -n '/^stale:/p' "$SCRATCH/watch.out")
FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-wake-drain.sh" > "$SCRATCH/drain.out" 2> "$SCRATCH/drain.err" \
  || fail "could not drain the stale task wake"
sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*$/\1/p' "$SCRATCH/drain.err")
generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$SCRATCH/drain.err")
FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$sequence" --recovery-generation "$generation" >/dev/null \
  || fail "could not acknowledge the stale task wake"
watch_once || [ "$?" -eq 124 ] || fail "the rearmed watcher failed: $(cat "$SCRATCH/watch.out")"
key=$(printf '%s' "$TARGET" | tr ':/.' '___')
[ -s "$STATE/.hash-$key" ] || fail "the live task behind the stale address was not supervised"
pass "real herdr: polling reports a stale record without dropping the task that owns its reused address"

SOCK=$(fm_backend_herdr_socket_path "$SESSION")
[ -n "$SOCK" ] || fail "could not resolve the isolated session's socket path"

# --- register the pane's agent idle, then drive idle->blocked ----------------
# report-agent is herdr's documented primitive for a non-built-in process to
# report its own agent state (docs/herdr-backend.md); routed through the lab
# helper's guarded `run` so it carries the trailing --session.
fm_herdr_lab_cli "$SESSION" pane report-agent "$PANE_ID" --source fm-evwait-test --agent claude --state idle >/dev/null 2>&1 \
  || fail "could not register the pane's agent as idle"

OUT="$SCRATCH/out"; RCF="$SCRATCH/rc"
: > "$OUT"; : > "$RCF"
# Bounded subscriber wait in the background; it must sit past the idle reconcile
# and return only when the pane transitions to blocked.
( fm_backend_herdr_wait_transition "$SESSION" 8 "$STATE" "$TARGET" > "$OUT"; echo $? > "$RCF" ) &
WPID=$!
sleep 0.5   # let it connect, subscribe, and reconcile the idle baseline

START=$(python3 -c 'import time; print(time.time())')
fm_herdr_lab_cli "$SESSION" pane report-agent "$PANE_ID" --source fm-evwait-test --agent claude --state blocked >/dev/null 2>&1 \
  || fail "could not drive the pane's agent to blocked"
wait "$WPID"
END=$(python3 -c 'import time; print(time.time())')

RC=$(cat "$RCF" 2>/dev/null || echo "")
REC=$(cat "$OUT" 2>/dev/null || echo "")
ELAPSED=$(python3 -c "print(f'{($END)-($START):.3f}')" 2>/dev/null || echo "?")

[ "$RC" = 0 ] || fail "wait_transition should return 0 on a real idle->blocked transition, got rc='$RC' rec='$REC'"
REC_PANE=$(fm_transition_pane_id "$REC")
REC_TO=$(fm_transition_to_status "$REC")
[ "$REC_PANE" = "$PANE_ID" ] || fail "the returned record's pane_id ('$REC_PANE') must match the driven pane ('$PANE_ID')"
[ "$REC_TO" = "blocked" ] || fail "the returned record's to_status must be 'blocked', got '$REC_TO'"
# Sub-second: comfortably under the ~240s stale-pane wedge timer this replaces.
UNDER_ONE=$(python3 -c "print('yes' if (($END)-($START)) < 1.0 else 'no')" 2>/dev/null || echo "no")
[ "$UNDER_ONE" = yes ] || echo "note: idle->blocked wake took ${ELAPSED}s (>1s; still far under the 240s wedge timer, not fatal)" >&2
pass "real herdr ($HERDR_VERSION): a driven idle->blocked transition returns the blocked record in ${ELAPSED}s (pane $PANE_ID)"

# --- the watcher's fast-path lands a stale record in the scratch wake queue ---
# Load the narrow production owner only after pointing it at scratch state, then
# override wake so the handler enqueues without exiting the test.
export FM_STATE_OVERRIDE="$STATE"
export FM_ROOT_OVERRIDE="$ROOT"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-push-transition-lib.sh"
wake() { PUSH_REASON=$1; }
printf 'paused: waiting on an external dependency\n' > "$STATE/a.status"
printf 'blocked: need a captain answer\n' > "$STATE/evwait1.status"
: > "$STATE/.wake-queue"
handle_push_transition herdr "$SESSION" "$REC"
[ -e "$STATE/.wake-queue" ] || fail "handle_push_transition did not create the wake queue"
grep -q 'stale' "$STATE/.wake-queue" || fail "the wake queue must carry a stale record: $(cat "$STATE/.wake-queue")"
[ "$(awk -F '\t' '{print $4}' "$STATE/.wake-queue")" = evwait1 ] \
  || fail "the stale record discarded its resolved task identity"
grep -q 'herdr: agent blocked' "$STATE/.wake-queue" || fail "the stale payload must name the herdr-blocked cause"
[ -s "$(status_heartbeat_seen_marker_path "$STATE" evwait1)" ] \
  || fail "the live task's push status was not marked surfaced"
[ ! -e "$(status_heartbeat_seen_marker_path "$STATE" a)" ] \
  || fail "the push transition was attributed to the stale record"
pass "real herdr: push supervision uses the live owner despite an earlier paused record at the same address"

[ "$(window_to_task "$TARGET" "$STATE")" = evwait1 ] || fail "notification lookup selected the stale record"
# shellcheck source=bin/fm-supervise-daemon.sh
. "$ROOT/bin/fm-supervise-daemon.sh"
LOG="$SCRATCH/daemon.log"
FM_ESCALATE_BATCH_SECS=999 handle_wake "$PUSH_REASON" "$STATE"
grep -F 'need a captain answer' "$STATE/.subsuper-escalations" >/dev/null \
  || fail "the stale paused task absorbed the live task's notification"
[ -s "$STATE/.subsuper-seen-status-evwait1" ] || fail "delivery did not retain the live task's status identity"
FM_ESCALATE_BATCH_SECS=999 handle_wake "$MISSING_REASON" "$STATE"
[ -e "$STATE/.subsuper-paused-a" ] || fail "the missing endpoint notification was attributed to the current pane owner"
pass "real herdr: notification delivery preserves live and missing task identities at a reused address"

printf 'working: continuing the task\n' > "$STATE/evwait1.status"
INITIAL_STALE=$(( $(date +%s) - 100 ))
printf '%s\n' "$INITIAL_STALE" > "$STATE/.subsuper-stale-evwait1"
printf '%s\n' "$INITIAL_STALE" > "$STATE/.stale-since-$key"
printf 'watcher-hash\n' > "$STATE/.stale-$key"
for _ in 1 2; do
  FM_ESCALATE_BATCH_SECS=999999 FM_HEARTBEAT_SCAN_SECS=999999 FM_STALE_ESCALATE_SECS=240 \
    FM_PAUSE_RESURFACE_SECS=3600 housekeeping "$STATE"
  [ "$(cat "$STATE/.subsuper-stale-evwait1" 2>/dev/null)" = "$INITIAL_STALE" ] \
    || fail "a stale task's pause reset the live task's wedge timer during housekeeping"
  [ "$(cat "$STATE/.stale-since-$key" 2>/dev/null)" = "$INITIAL_STALE" ] \
    || fail "a stale task's pause removed the live task's watcher timer"
  [ ! -e "$STATE/.subsuper-paused-evwait1" ] || fail "the live task inherited the stale task's pause"
done
sync_pause_markers_from_signal "$STATE" "$STATE/a.status"
[ "$(cat "$STATE/.subsuper-stale-evwait1" 2>/dev/null)" = "$INITIAL_STALE" ] \
  || fail "signal reconciliation discarded the live task's timer"
printf '%s\n' "$(( $(date +%s) - 500 ))" > "$STATE/.subsuper-stale-evwait1"
: > "$STATE/.subsuper-escalations"
FM_ESCALATE_BATCH_SECS=999999 FM_HEARTBEAT_SCAN_SECS=999999 FM_STALE_ESCALATE_SECS=240 \
  FM_PAUSE_RESURFACE_SECS=3600 housekeeping "$STATE"
grep -F 'possible wedge' "$STATE/.subsuper-escalations" >/dev/null \
  || fail "the live task's preserved timer did not mature into an escalation"
[ ! -e "$STATE/.subsuper-stale-evwait1" ] || fail "the delivered live-task wedge retained its timer"
[ -e "$STATE/.subsuper-paused-a" ] || fail "housekeeping lost the stale task's own pause"
pass "real herdr: housekeeping and signal reconciliation preserve each task's timers at a reused address"

cleanup_all
trap - EXIT
