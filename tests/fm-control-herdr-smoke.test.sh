#!/usr/bin/env bash
# tests/fm-control-herdr-smoke.test.sh - real-herdr smoke test for the agent
# lifecycle control plane (bin/fm-control.sh).
#
# tmux is the control plane's reference backend and is covered hermetically in
# tests/fm-control.test.sh. herdr is the OTHER backend whose recovery-grade
# agent-state classifier the control plane is allowed to trust, so its
# behavior is pinned here against the REAL binary rather than a stub: whether
# an agent is running, and therefore whether a lifecycle verb may act at all,
# comes from herdr's own agent registry.
#
# No real harness is launched. herdr's `pane report-agent` is the same registry
# the adapter reads, and a symlink named like a harness is the same process
# identity the adapter proves through `pane process-info`, so registering an
# agent over a real agent-named process, over a plain shell, and not at all
# exercises exactly the classification the control plane gates on - including
# the registration Herdr keeps after the agent process is gone (issue #4115).
#
# Always runs on a private, named, throwaway lab session, never the default
# one (tests/herdr-test-safety.sh; the 2026-07-02 incident). Skips cleanly
# when herdr or jq is missing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the herdr adapter)"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

# The agent-named process below is a symlink to fm_agent_standin's stand-in;
# decide it before any lab session exists so an impossible case skips cleanly.
STANDIN_DIR=$(fm_test_tmproot fm-control-herdr-standin) || {
  printf 'not ok - %s\n' "could not create the stand-in directory" >&2
  exit 1
}
STANDIN_BIN=$(fm_agent_standin "$STANDIN_DIR") || {
  echo "skip: no long-running stand-in binary survives a rename (multicall coreutils, no C compiler)"
  exit 0
}

SESSION="fm-lab-control-smoke-$$"
export HERDR_SESSION="$SESSION"
SCRATCH=
LAB_PREPARED=0
cleanup_all() {
  local status=$? cleanup_status=0
  trap - EXIT
  if [ -n "$SCRATCH" ]; then
    if [ -d "$SCRATCH/home/state/hsmoke.git-hooks" ]; then
      chmod u+w "$SCRATCH/home/state/hsmoke.git-hooks" || {
        echo "not ok - could not restore write permission on test git hooks" >&2
        cleanup_status=1
      }
    fi
    rm -rf "$SCRATCH" || {
      echo "not ok - could not remove Herdr smoke scratch tree: $SCRATCH" >&2
      cleanup_status=1
    }
  fi
  if [ "$LAB_PREPARED" = 1 ]; then
    herdr_safe_stop_and_delete "$SESSION" || {
      echo "not ok - could not tear down Herdr smoke lab session: $SESSION" >&2
      cleanup_status=1
    }
  fi
  fm_test_cleanup
  [ "$cleanup_status" = 0 ] || status=1
  exit "$status"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"
LAB_PREPARED=1

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-herdr.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd)
HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/hsmoke"
cat > "$HOME_DIR/data/hsmoke/brief.md" <<'EOF'
# Task
## Captain's intent
Exercise Herdr lifecycle control safely.

## Firstmate spec
Keep the isolated endpoint and worktree intact.
EOF

# A real git worktree so the control plane's checkpoint has a real local copy.
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b hsmoke "$WT"
PROJ_REAL=$(cd "$PROJ" && pwd -P)
WT_REAL=$(cd "$WT" && pwd -P)

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-hsmoke" "$WT" "$SEEDED_TAB_ID") \
  || fail "create_task failed"
read -r TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
[ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] || fail "create_task did not return tab/pane ids"

{
  echo "window=$SESSION:$PANE_ID"
  echo "endpoint_task_id=hsmoke"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"
  echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/hsmoke.meta"

run_control() {
  env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.2 FM_CONTROL_EXIT_WAIT=2 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

fm_herdr_lab_cli "$SESSION" tab rename "$TAB_ID" fm-other >/dev/null \
  || fail "could not set up a reused endpoint for restart"
fm_herdr_lab_stop "$SESSION" >/dev/null || fail "could not stop the isolated session"
printf -v RESTART_MARKER_Q '%q' "$SCRATCH/restart-misdirected"
if OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SEND_RETRIES=1 FM_SEND_SLEEP=0.05 \
  "$ROOT/bin/fm-send.sh" hsmoke "/bin/echo misdirected > $RESTART_MARKER_Q" 2>&1); then
  fail "a stopped-session send accepted another task's restored pane"
fi
fm_herdr_lab_cli "$SESSION" status --json | jq -e '.server.running == true' >/dev/null \
  || fail "the typed send did not restore the isolated session before checking its binding"
sleep 0.3
[ ! -e "$SCRATCH/restart-misdirected" ] || fail "a stopped-session send typed and submitted into another task's restored pane"
fm_herdr_lab_cli "$SESSION" tab rename "$TAB_ID" fm-hsmoke >/dev/null \
  || fail "could not restore the expected task binding"
printf -v BOUND_MARKER_Q '%q' "$SCRATCH/bound-delivery"
env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SEND_RETRIES=1 FM_SEND_SLEEP=0.05 \
  "$ROOT/bin/fm-send.sh" hsmoke "/bin/echo delivered > $BOUND_MARKER_Q" >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
  [ ! -e "$SCRATCH/bound-delivery" ] || break
  sleep 0.1
done
[ "$(cat "$SCRATCH/bound-delivery" 2>/dev/null)" = delivered ] || fail "a correctly bound send did not reach the restored shell"
printf -v MID_MARKER_Q '%q' "$SCRATCH/mid-send-misdirected"
MID_COMMAND="/bin/echo ownership-mid-send > $MID_MARKER_Q"
(
  # shellcheck disable=SC2329
  fm_backend_herdr_cli() {
    fm_herdr_lab_cli "$@" || return
    case "${2:-} ${3:-}" in
      'pane send-text') fm_herdr_lab_cli "$SESSION" tab rename "$TAB_ID" fm-other >/dev/null ;;
    esac
  }
  verdict=$(fm_backend_herdr_send_text_submit "$SESSION:$PANE_ID" "$MID_COMMAND" 1 0.05 0 fm-hsmoke)
  [ "$verdict" = send-failed ] || fail "submission lost the task label between typing and Enter: $verdict"
) || fail "a task binding change during submission was accepted"
sleep 0.2
[ ! -e "$SCRATCH/mid-send-misdirected" ] || fail "Enter submitted into the task that reused the pane"
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" /bin/true fm-hsmoke \
  && fail "a staged line send accepted another task's binding"
[ -z "$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" fm-hsmoke)" ] \
  || fail "working-directory discovery read another task's pane"
fm_backend_herdr_composer_clear "$SESSION:$PANE_ID" "$MID_COMMAND" fm-hsmoke \
  && fail "composer clearing accepted another task's binding"
case "$(fm_herdr_lab_cli "$SESSION" pane read "$PANE_ID" --source visible)" in
  *ownership-mid-send*) ;;
  *) fail "composer clearing removed another task's draft" ;;
esac
(
  # shellcheck disable=SC2329
  fm_backend_herdr_cli() {
    case "${2:-} ${3:-}" in
      'agent get') printf '{"result":{"agent":{"agent_status":"working"}}}\n' ;;
      *) fm_herdr_lab_cli "$@" ;;
    esac
  }
  [ "$(fm_backend_herdr_wait_for_working "$SESSION" "$PANE_ID" 0 1 fm-hsmoke)" = unknown ] \
    || fail "submission was confirmed by another task's native state"
) || fail "confirmation discarded the expected task identity"
fm_herdr_lab_cli "$SESSION" tab rename "$TAB_ID" fm-hsmoke >/dev/null || fail "could not restore the task binding after submission"
fm_backend_send_key herdr "$SESSION:$PANE_ID" C-u fm-hsmoke || fail "could not clear the test draft"
fm_backend_send_key herdr "$SESSION:$PANE_ID" Enter fm-hsmoke || fail "could not reset the test shell"
(
  # shellcheck disable=SC2329
  fm_backend_herdr_cli() {
    case "${2:-} ${3:-}" in 'tab get') return 1 ;; esac
    fm_herdr_lab_cli "$@"
  }
  [ "$(fm_backend_agent_state herdr "$SESSION:$PANE_ID" fm-hsmoke)" = unreadable ] || fail "an unreadable binding was treated as recoverable or alive"
  fm_backend_target_exists herdr "$SESSION:$PANE_ID" fm-hsmoke && fail "existence accepted an unreadable task binding"
  fm_backend_send_key herdr "$SESSION:$PANE_ID" Enter fm-hsmoke && fail "a key reached an endpoint with unreadable binding"
  fm_backend_capture herdr "$SESSION:$PANE_ID" 10 fm-hsmoke && fail "capture accepted an unreadable binding"
  fm_backend_visible_capture herdr "$SESSION:$PANE_ID" fm-hsmoke && fail "visible capture accepted an unreadable binding"
  [ "$(fm_backend_composer_state herdr "$SESSION:$PANE_ID" fm-hsmoke)" = unknown ] || fail "an unreadable binding produced a composer verdict"
  [ "$(fm_backend_herdr_send_text_submit "$SESSION:$PANE_ID" text 1 0 0 fm-hsmoke)" = send-failed ] || fail "typed submission accepted an unreadable binding"
  fm_backend_kill herdr "$SESSION:$PANE_ID" "" fm-hsmoke && fail "close accepted an unreadable binding"
  fm_backend_herdr_kill_serialized "$SESSION" "$PANE_ID" fm-hsmoke && fail "a serialized close accepted an unreadable binding"
  exit 0
) || fail "an endpoint operation failed to preserve the binding invariant"
pass "real herdr: restart and unreadable bindings cannot authorize actions on another task"

if [ "${1:-}" = --ownership-regressions ]; then exit 0; fi

if OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" HERDR_PANE_ID="$PANE_ID" \
  "$ROOT/bin/fm-send.sh" "$SESSION:$PANE_ID" --key Escape 2>&1); then
  fail "an unlabelled raw send accepted the caller's own pane: $OUT"
fi
# shellcheck disable=SC2016
env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" HERDR_PANE_ID="$PANE_ID" \
  TARGET="$SESSION:$PANE_ID" ROOT="$ROOT" bash -c '
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_source herdr
    fm_backend_send_key herdr "$TARGET" Escape && exit 1
    fm_backend_capture herdr "$TARGET" 10 && exit 1
    fm_backend_visible_capture herdr "$TARGET" && exit 1
    fm_backend_target_exists herdr "$TARGET" && exit 1
    [ "$(fm_backend_composer_state herdr "$TARGET")" = unknown ] || exit 1
    [ "$(fm_backend_herdr_send_text_submit "$TARGET" text 1 0 0)" = send-failed ] || exit 1
    fm_backend_kill herdr "$TARGET" && exit 1
    exit 0
  ' || fail "an unlabelled endpoint action accepted the caller pane"
fm_herdr_lab_cli "$SESSION" tab rename "$TAB_ID" fm-foreign >/dev/null \
  || fail "could not model a reused pane binding"
if OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
  "$ROOT/bin/fm-send.sh" "$SESSION:$PANE_ID" --key Escape 2>&1); then
  fail "a raw recorded send accepted a foreign task binding: $OUT"
fi
if fm_backend_kill herdr "$SESSION:$PANE_ID" "" fm-hsmoke; then
  fail "endpoint close accepted another task's binding"
fi
fm_herdr_lab_cli "$SESSION" tab rename "$TAB_ID" fm-hsmoke >/dev/null \
  || fail "could not restore the worker binding"
env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" \
  "$ROOT/bin/fm-send.sh" "$SESSION:$PANE_ID" --key Enter >/dev/null \
  || fail "a correctly bound raw send was refused"
pass "real herdr: raw sends reject caller and foreign panes while allowing the recorded task"

# --- no registered agent: the endpoint exists but hosts no agent ------------

OUT=$(run_control hsmoke exit) || fail "exit against an agent-free herdr pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "an agent-free herdr pane should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit on a pane with no registered agent is idempotent success"

# --- the recovery-grade read, against the real binary ------------------------
#
# The classification that decides whether a task can be recovered at all is read
# out of what herdr actually answers, so a stub can only confirm the assumption
# already written into the stub. Its logic is pinned portably in
# tests/fm-backend-herdr.test.sh; this is the check that notices when the real
# client stops answering the way that logic expects, and it names the version so
# a release change is attributed rather than mysterious.
HERDR_VERSION=$(herdr --version 2>&1 | head -1)
HERDR_VERSION=${HERDR_VERSION#herdr }
version_fail() {  # <message>
  fail "$1 [herdr $HERDR_VERSION]"
}

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = dead ] \
  || version_fail "a real, present, agent-free pane reads '$STATE' rather than 'dead'; every relaunch would be refused"

# `status --json` is the second signal, and the only one that answers for a
# session whose operational calls cannot be reached at all. A release that drops
# or renames `.server.running` would silently make every gone endpoint
# unrecoverable again, so it is asserted by name on both a live and an absent
# session.
[ "$(fm_backend_herdr_server_running_state "$SESSION")" = running ] \
  || version_fail "this run's own live lab session does not report .server.running=true through status --json"
[ "$(fm_backend_herdr_server_running_state "fm-lab-never-started-$$")" = stopped ] \
  || version_fail "a session with no server does not report .server.running=false, so authoritative absence can no longer be told from an unreadable read"

# Issue #4091's exact stranding shape: an endpoint recorded in a session whose
# server is not running used to read `unreadable` and block recovery.
[ "$(fm_backend_agent_state herdr "fm-lab-never-started-$$:w1:p2")" = missing ] \
  || version_fail "an endpoint in a session with no running server is not classified as recoverable"

# And the safety direction: an uninterpretable read must never license recovery.
[ "$(fm_backend_agent_state herdr "no-separator-here")" = unreadable ] \
  || version_fail "a malformed endpoint target does not stay unreadable"
pass "real herdr $HERDR_VERSION: a gone session reads recoverable while a live pane and a malformed target do not"

FAKEBIN="$SCRATCH/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/codex" <<EOF
#!/usr/bin/env bash
: > "$SCRATCH/codex-launched"
EOF
chmod +x "$FAKEBIN/codex"
printf -v FAKEBIN_Q '%q' "$FAKEBIN"
printf -v PROJ_Q '%q' "$PROJ"
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "export PATH=$FAKEBIN_Q:\$PATH" \
  || fail "could not put the inert test harness on the pane PATH"
fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "cd -- $PROJ_Q" \
  || fail "could not move the agent-free pane out of its recorded worktree"
for _ in $(seq 1 20); do
  [ "$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)" != "$PROJ_REAL" ] || break
  sleep 0.1
done
[ "$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)" = "$PROJ_REAL" ] \
  || fail "the real Herdr pane did not drift out of its recorded worktree"

SHARED=$("$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" tab create --workspace "$WORKSPACE_ID" --cwd "$WT" --label captain-shell --no-focus) \
  || fail "could not create a shared-workspace fixture"
SHARED_PANE=$(printf '%s' "$SHARED" | jq -r '.result.root_pane.pane_id')
cp "$HOME_DIR/state/hsmoke.meta" "$SCRATCH/shared-before.meta"
if OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" hsmoke --relaunch --harness codex 2>&1); then
  fail "a surviving shared-tab endpoint was relaunched"
fi
case "$OUT" in
  *"one-task workspace isolation"*) ;;
  *) fail "shared-tab relaunch did not explain its refusal: $OUT" ;;
esac
cmp -s "$HOME_DIR/state/hsmoke.meta" "$SCRATCH/shared-before.meta" \
  || fail "shared-tab refusal changed task metadata"
[ ! -e "$SCRATCH/codex-launched" ] || fail "shared-tab refusal launched a harness"
"$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" pane close "$SHARED_PANE" >/dev/null \
  || fail "could not remove the shared-workspace fixture"
"$ROOT/bin/fm-herdr-lab.sh" run "$SESSION" workspace rename "$WORKSPACE_ID" hsmoke-owned >/dev/null \
  || fail "could not name the isolated worker workspace"
pass "real herdr: surviving shared-tab relaunch refuses before launch or metadata publication"

OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" hsmoke --relaunch --harness codex) \
  || fail "a drifted, agent-free Herdr pane should be re-homed and relaunched: $OUT"
for _ in $(seq 1 20); do
  [ ! -e "$SCRATCH/codex-launched" ] || break
  sleep 0.1
done
[ -e "$SCRATCH/codex-launched" ] || fail "the replacement harness was not launched"
[ "$(fm_backend_herdr_current_path "$SESSION:$PANE_ID" 2>/dev/null || true)" = "$WT_REAL" ] \
  || fail "the relaunched Herdr shell did not end up in its recorded worktree"
[ "$(sed -n 's/^window=//p' "$HOME_DIR/state/hsmoke.meta" | tail -1)" = "$SESSION:$PANE_ID" ] \
  || fail "the Herdr relaunch replaced its endpoint instead of reusing it"
herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the Herdr relaunch removed the endpoint it was required to reuse"
awk -F= '$1 == "harness" {$0="harness=claude"} {print}' "$HOME_DIR/state/hsmoke.meta" \
  > "$HOME_DIR/state/hsmoke.meta.tmp"
mv "$HOME_DIR/state/hsmoke.meta.tmp" "$HOME_DIR/state/hsmoke.meta"
pass "real herdr: a drifted agent-free shell returns to its worktree and reuses the same endpoint"

if OUT=$(run_control hsmoke interrupt 2>&1); then
  fail "interrupt should refuse when herdr reports no agent on the pane: $OUT"
fi
case "$OUT" in
  *"nothing to interrupt"*) : ;;
  *) fail "the interrupt refusal should say there is no agent, got: $OUT" ;;
esac
pass "real herdr: interrupt refuses when herdr's own agent registry reports no agent"

# --- a registered agent WITH a live process: classification flips ------------
#
# A registration alone no longer proves an agent (issue #4115): the adapter
# verifies the pane's processes through the real `pane process-info` view. So
# the registered agent is backed by a real agent-named foreground process - a
# symlink named `claude` to the fm_agent_standin stand-in decided above, the same
# construction tests/fm-tmux-agent-liveness.test.sh uses (the symlink name is
# what the kernel records as argv[0]; tests/lib.sh owns why it is never a copy).
AGENT_BIN="$SCRATCH/agentbin"
mkdir -p "$AGENT_BIN"
ln -s "$STANDIN_BIN" "$AGENT_BIN/claude"
printf -v AGENT_Q '%q' "$AGENT_BIN/claude"

wait_process_state() {  # <expected> <tries>
  local expected=$1 tries=$2 i=0
  while [ "$i" -lt "$tries" ]; do
    [ "$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")" != "$expected" ] || return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

start_agent_process() {
  fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "$AGENT_Q 900" \
    || fail "could not start the agent-named foreground process in the task pane"
  wait_process_state agent 50 \
    || version_fail "a real agent-named foreground process reads '$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")' rather than 'agent' through pane process-info"
}

start_agent_process
herdr pane report-agent "$PANE_ID" --source fm-control-smoke --agent fm-control-smoke-agent \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not register a live agent on the task pane"

STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = alive ] || fail "herdr should classify a registered agent with a live process as alive, got '$STATE'"

OUT=$(run_control hsmoke interrupt) || fail "interrupt against a registered agent should succeed: $OUT"
case "$OUT" in
  *"interrupt-delivered hsmoke harness=claude backend=herdr verified=agent-alive cancel=unconfirmed"*) : ;;
  *) fail "interrupt should report the agent-alive proof on herdr, got: $OUT" ;;
esac
pass "real herdr: interrupt delivers the harness's key and proves the agent survived it"

herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the control plane must never remove the endpoint it was operating on"
[ -d "$WT" ] || fail "the control plane must never remove the task's local copy"
pass "real herdr: no control verb removed the endpoint or the task's local copy"

# --- a reused pane id: the record names a pane that is no longer its task's --
#
# Herdr hands pane ids out again after a restart, so a dead task's record can
# name the pane a newer live worker now runs in, or the supervising session's
# own pane. hsmoke's live agent stands in for that newer worker: hreuse is a
# dead record whose recorded pane id is hsmoke's. Its endpoint must read gone,
# and no control verb on hreuse may reach hsmoke's agent.
mkdir -p "$HOME_DIR/data/hreuse"
cp "$HOME_DIR/data/hsmoke/brief.md" "$HOME_DIR/data/hreuse/brief.md"
sed 's/^endpoint_task_id=hsmoke$/endpoint_task_id=hreuse/' "$HOME_DIR/state/hsmoke.meta" \
  > "$HOME_DIR/state/hreuse.meta"
STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID" fm-hreuse)
[ "$STATE" = missing ] \
  || fail "a pane in another task's tab should read as this task's endpoint gone, got '$STATE'"
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE_ID" fm-hsmoke)" = alive ] \
  || fail "the pane's own task must still read its live agent"
OUT=$(run_control hreuse interrupt 2>&1) && fail "interrupt must not act through another task's pane: $OUT"
case "$OUT" in
  *interrupt-delivered*) fail "interrupt delivered a key into another task's pane: $OUT" ;;
esac
OUT=$(run_control hreuse exit) || fail "exit on a record whose pane belongs to another task should report its endpoint gone: $OUT"
case "$OUT" in
  "endpoint-gone hreuse"*) : ;;
  *) fail "exit should report the reused pane as this task's endpoint gone, got: $OUT" ;;
esac
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE_ID" fm-hsmoke)" = alive ] \
  || fail "control verbs on the stale record reached the live worker that now owns the pane"
# A process running in that very pane (the supervising session, in the
# reported incident) must not read or drive it as the task.
as_pane_process() {  # <function and args...>
  HERDR_PANE_ID="$PANE_ID" HERDR_SESSION="$SESSION" bash -c \
    '. "$1/bin/fm-backend.sh"; fm_backend_source herdr || exit 9; shift; "$@"' _ "$ROOT" "$@"
}
SELF_STATE=$(as_pane_process fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$SELF_STATE" = missing ] \
  || fail "a recorded pane that is the caller's own pane should read as the task's endpoint gone, got '$SELF_STATE'"
if as_pane_process fm_backend_herdr_capture "$SESSION:$PANE_ID" 5 fm-hsmoke >/dev/null; then
  fail "a labelled read of the caller's own pane must refuse rather than read it as a task's screen"
fi
rm -f "$HOME_DIR/state/hreuse.meta"
pass "real herdr $HERDR_VERSION: a reused pane id reads as the stale task's endpoint gone and is never acted on for it"

# --- the stale registration (issue #4115): the agent process is gone, the ---
# --- record is not, and recovery must proceed anyway ------------------------
#
# Stopping the agent-named process leaves the pane a plain shell while Herdr
# keeps the registration, which is exactly the shape a Pi crew leaves behind
# when it exits under a nested shell. Before the fix this read `alive` forever:
# exit waited out its timeout and refused, and relaunch was refused for good.
AGENT_PID=$(herdr pane process-info --pane "$PANE_ID" --session "$SESSION" 2>/dev/null \
  | jq -r '.result.process_info.foreground_processes[0].pid // empty')
[ -n "$AGENT_PID" ] || fail "could not read the agent-named process pid from pane process-info"
kill "$AGENT_PID" 2>/dev/null || fail "could not stop the agent-named process"
wait_process_state shell 50 \
  || version_fail "after the agent process exited the pane reads '$(fm_backend_herdr_pane_process_state "$SESSION" "$PANE_ID")' rather than 'shell' through pane process-info. Raw process-info: $(herdr pane process-info --pane "$PANE_ID" --session "$SESSION" 2>&1 | tr -d '\n')"

fm_herdr_lab_cli "$SESSION" pane report-agent "$PANE_ID" --source fm-control-smoke \
  --agent fm-control-smoke-agent --state idle >/dev/null \
  || fail "could not seed the stale registration over the exited process"

# The divergence that makes this case non-vacuous: Herdr's own registry still
# reports the agent, and only the process-level view disagrees.
REGISTERED=$(herdr agent get "$PANE_ID" --session "$SESSION" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
[ -n "$REGISTERED" ] \
  || version_fail "Herdr released the registration when the agent process exited, so this run cannot prove the stale-registration path; the classifier still reads dead through agent_not_found"

PANE_STATE=$(fm_backend_herdr_pane_agent_state "$SESSION" "$PANE_ID")
[ "$PANE_STATE" = stale-agent ] \
  || version_fail "a registration over a shell-only pane reads '$PANE_STATE' rather than 'stale-agent'"
STATE=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
[ "$STATE" = dead ] \
  || version_fail "a registration over a shell-only pane recovers as '$STATE' rather than 'dead'; every relaunch would be refused"
pass "real herdr $HERDR_VERSION: a registration Herdr keeps after its agent exits reads stale-agent and recovers as dead"

OUT=$(run_control hsmoke exit) || fail "exit against a stale-registration pane should be idempotent success: $OUT"
case "$OUT" in
  "already-stopped hsmoke"*) : ;;
  *) fail "a stale-registration pane should report already-stopped, got: $OUT" ;;
esac
pass "real herdr: exit on a pane with a stale registration is idempotent success"

rm -f "$SCRATCH/codex-launched"
OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" hsmoke --relaunch --harness codex) \
  || fail "a stale-registration Herdr pane should be relaunched: $OUT"
for _ in $(seq 1 20); do
  [ ! -e "$SCRATCH/codex-launched" ] || break
  sleep 0.1
done
[ -e "$SCRATCH/codex-launched" ] || fail "the replacement harness was not launched after the stale registration"
[ "$(sed -n 's/^window=//p' "$HOME_DIR/state/hsmoke.meta" | tail -1)" = "$SESSION:$PANE_ID" ] \
  || fail "the relaunch replaced its endpoint instead of reusing it"
herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 \
  || fail "the relaunch removed the endpoint it was required to reuse"
[ -d "$WT" ] || fail "the relaunch must never remove the task's local copy"
awk -F= '$1 == "harness" {$0="harness=claude"} {print}' "$HOME_DIR/state/hsmoke.meta" \
  > "$HOME_DIR/state/hsmoke.meta.tmp"
mv "$HOME_DIR/state/hsmoke.meta.tmp" "$HOME_DIR/state/hsmoke.meta"
pass "real herdr: a stale registration no longer blocks relaunch, and the endpoint and local copy survive"

# Last: the foreground process is the sleeping stand-in, so the pane never draws any
# recognized composer chrome. exit's composer-empty guard (bin/fm-control.sh)
# therefore refuses before ever typing the exit command, rather than typing it
# into a live agent that ignores it and reporting a stop that did not happen.
start_agent_process
herdr pane report-agent "$PANE_ID" --source fm-control-smoke --agent fm-control-smoke-agent \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || fail "could not re-register the live agent on the task pane"
if OUT=$(run_control hsmoke exit 2>&1); then
  fail "exit should fail closed when the agent's composer is not proven empty: $OUT"
fi
case "$OUT" in
  *"composer visibly holds pending text; refusing to type the /exit exit command"*|*"not proven empty; refusing to type the /exit exit command"*) : ;;
  *) fail "the exit failure should refuse to type the /exit command for an unproven or pending composer, got: $OUT" ;;
esac
[ "$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")" = alive ] \
  || fail "the exit refusal did not preserve the fake foreground agent"
SCREEN_AFTER=$(fm_backend_herdr_visible_capture "$SESSION:$PANE_ID") \
  || fail "could not read the pane after the exit refusal"
case "$SCREEN_AFTER" in
  *'/exit'*) fail "the refused /exit command appeared on the agent pane" ;;
esac
pass "real herdr: exit refuses an unproven or pending composer without typing an exit command"

fm_backend_herdr_kill "$SESSION:$PANE_ID" 2>/dev/null || true
