#!/usr/bin/env bash
# tests/fm-session-lock-ownership.test.sh - who holds the helm, and what a
# session that does not hold it is allowed to do.
#
# Covers the three halves of the session-lock split (docs/watcher-continuity.md
# "Session-lock ownership"):
#   1. bin/fm-session-lock-lib.sh's fleet-mutation gate, exercised through the
#      real mutating entry points rather than through the predicate alone.
#   2. bin/fm-lock.sh's ownership wording, and a background continuation of the
#      lock-holding conversation inheriting the helm.
#   3. bin/fm-turnend-guard.sh telling a correct decline apart from a failure,
#      and standing down after one report.
#
# Every competing session here is a REAL live process the shared harness
# predicate accepts, because the defect was two live processes disagreeing about
# which of them held the home. Every fixture tree is detached from this suite
# (reparented to init) before it runs, so the ancestry walk terminates inside the
# fixture and can never climb into the session running these tests - the same
# technique tests/fm-session-lock-ancestry.test.sh uses.
# shellcheck disable=SC2016 # single quotes are deliberate: $$ and $@ expand inside the fixture child
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-session-lock-ownership)
fm_git_identity fmtest fmtest@example.invalid

FAKEBIN=$(fm_fakebin "$TMP_ROOT/fakebin")
ln -s /bin/bash "$FAKEBIN/claude"
FAKE_CLAUDE="$FAKEBIN/claude"

cleanup_holders() {
  local pid
  while IFS= read -r pid; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done < "$TMP_ROOT/holders" 2>/dev/null
  fm_test_cleanup
}
: > "$TMP_ROOT/holders"
trap cleanup_holders EXIT INT TERM

wait_for_file() {  # <path>
  local i=0
  while [ "$i" -lt 600 ]; do
    [ -s "$1" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

# Waits until this suite is no longer anywhere in its own ancestry, then runs
# the command and publishes its combined output and exit code.
# Escaping the suite's tree is the point: without it the ancestry walk under test
# would climb out of the fixture into the real harness running these tests, and
# every ownership question would be answered by the developer's own session.
# The condition is "the suite is gone from my ancestry", not "my parent is pid 1":
# a host with a subreaper (a container init, a session leader) reparents an
# orphan to that reaper instead, so a wait keyed on pid 1 would only ever time
# out there.
cat > "$TMP_ROOT/detached.sh" <<'SH'
#!/usr/bin/env bash
set -u
suite=$1
out=$2
rc=$3
shift 3
i=0
while [ "$i" -lt 400 ]; do
  p=$$
  escaped=1
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    [ -n "$p" ] && [ "$p" -gt 1 ] || break
    if [ "$p" = "$suite" ]; then
      escaped=0
      break
    fi
  done
  [ "$escaped" -eq 1 ] && break
  sleep 0.05
  i=$((i + 1))
done
"$@" < /dev/null > "$out" 2>&1
printf '%s\n' "$?" > "$rc"
SH
chmod +x "$TMP_ROOT/detached.sh"
RUN_OUT_FILE="$TMP_ROOT/run.out"
RUN_RC_FILE="$TMP_ROOT/run.rc"

# Fixed paths, not per-call names: every call site captures the exit code with
# `rc=$(detached_run ...)`, which runs the function in a subshell, so a variable
# it set would never reach run_output. This suite is serial, so one slot is
# enough.
# Run <command...> in a tree detached from this suite, and print its exit code.
# Prefix the command with `env ...` to control the fixture's declared identity;
# a shell-function prefix would not survive into the detached process.
detached_run() {  # <command...>
  : > "$RUN_OUT_FILE"
  rm -f "$RUN_RC_FILE"
  bash -c '"$0" "$@" &' "$TMP_ROOT/detached.sh" "$$" "$RUN_OUT_FILE" "$RUN_RC_FILE" "$@"
  wait_for_file "$RUN_RC_FILE" || fail "a detached fixture command never finished"
  tr -d '[:space:]' < "$RUN_RC_FILE"
}

run_output() {
  cat "$RUN_OUT_FILE" 2>/dev/null || true
}

# A plain primary checkout carrying the real bin/.
make_home() {  # <dir>
  local dir=$1
  mkdir -p "$dir/state" "$dir/data" "$dir/config"
  git init -q "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  : > "$dir/AGENTS.md"
  cp -R "$ROOT/bin" "$dir/bin"
  # No real watcher may ever start from a fixture home.
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: arm fixture, no actionable reason\n'
SH
  chmod +x "$dir/bin/fm-watch-arm.sh"
  printf 'id=demo\nproject=demo\n' > "$dir/state/demo.meta"
}

# Start a live process the harness predicate accepts and record its pid as the
# home's lock owner, then echo that pid.
#
# Two details are load-bearing. The trailing `:` keeps the holder a "claude":
# bash execs a lone final command, which would replace that image with `sleep`
# and hide the holder from the very predicate under test. And the holder's own
# stdout goes to /dev/null, because a caller capturing this function's output
# would otherwise wait on the pipe the backgrounded holder inherited - for the
# holder's whole lifetime, not the function's.
start_lock_holder() {  # <dir>
  local dir=$1 pid
  rm -f "$dir/state/.lock"
  "$FAKE_CLAUDE" -c 'printf "%s\n" "$$" > "$1"; sleep 600; :' _ "$dir/state/.lock" \
    > /dev/null 2>&1 &
  pid=$!
  # Recorded in a file, not a shell array: this function is called from command
  # substitutions, whose subshell state never reaches the cleanup trap.
  printf '%s\n' "$pid" >> "$TMP_ROOT/holders"
  wait_for_file "$dir/state/.lock" || fail "the fixture lock holder never published its pid"
  printf '%s\n' "$pid"
}

# --- 1. the fleet-mutation gate ---------------------------------------------

test_every_mutating_entry_point_refuses_a_non_owning_session() {
  local dir rc out script
  dir="$TMP_ROOT/gate"
  make_home "$dir"
  start_lock_holder "$dir" >/dev/null

  # The set AGENTS.md section 3 forbids a read-only session. Each is called with
  # no arguments: the gate must come BEFORE argument validation, or a non-owner
  # is told only that its request was malformed.
  for script in fm-wake-drain.sh fm-send.sh fm-spawn.sh fm-teardown.sh \
    fm-promote.sh fm-merge-local.sh fm-pr-merge.sh fm-control.sh; do
    rc=$(detached_run env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID \
      FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
      "$FAKE_CLAUDE" -c '"$@"; exit $?' _ "$dir/bin/$script")
    out=$(run_output)
    [ "$rc" != 0 ] || fail "$script let a non-owning session proceed"
    assert_contains "$out" "does not hold the fleet lock" \
      "$script refused without naming why, so the session cannot act on it"
    assert_contains "$out" "Operate read-only" \
      "$script refused without saying what to do instead"
  done

  pass "every mutating fleet entry point refuses a session that does not hold the home"
}

test_the_lock_holder_itself_still_mutates() {
  local dir out
  dir="$TMP_ROOT/gate-owner"
  make_home "$dir"

  # The holder's own children ARE the session: a gate that also stops the owner
  # has closed the home rather than closed the split.
  detached_run env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" "$FAKE_CLAUDE" -c '
      printf "%s\n" "$$" > "$1/state/.lock"
      "$1/bin/fm-wake-drain.sh"
      exit $?
    ' _ "$dir" >/dev/null
  out=$(run_output)
  assert_not_contains "$out" "does not hold the fleet lock" \
    "the gate refused the session that actually holds the lock"

  pass "the lock-holding session passes the fleet-mutation gate untouched"
}

test_a_caller_outside_any_harness_session_is_not_a_competing_session() {
  local dir out
  dir="$TMP_ROOT/gate-nonharness"
  make_home "$dir"
  start_lock_holder "$dir" >/dev/null

  # A parent home reaching into a secondmate's endpoint over ssh, a detached
  # job, or CI has no harness of its own. Refusing there would break the remote
  # path without closing any two-agents-one-home split.
  detached_run env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" "$dir/bin/fm-wake-drain.sh" >/dev/null
  out=$(run_output)
  assert_not_contains "$out" "does not hold the fleet lock" \
    "a caller with no harness session of its own was treated as a competing session"

  pass "a caller outside any harness session is not treated as a competing session"
}

# --- 2. ownership wording, and the background continuation ------------------

test_lock_output_states_ownership_in_words() {
  local dir rc out
  dir="$TMP_ROOT/wording"
  make_home "$dir"
  start_lock_holder "$dir" >/dev/null

  rc=$(detached_run env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID \
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
    "$FAKE_CLAUDE" -c '"$@"; exit $?' _ "$dir/bin/fm-lock.sh")
  out=$(run_output)
  [ "$rc" != 0 ] || fail "a non-owning session was told it acquired the lock"
  assert_contains "$out" "NOT THIS SESSION" \
    "the refusal did not distinguish this session from the holder"
  assert_not_contains "$out" "lock acquired" "a refusal still read as an acquisition"

  detached_run env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" "$FAKE_CLAUDE" -c '"$@"; exit $?' _ "$dir/bin/fm-lock.sh" status >/dev/null
  out=$(run_output)
  assert_contains "$out" "held by ANOTHER live session" \
    "lock status did not say whose session holds the home"

  pass "the lock path names ownership in words, never as a bare pid"
}

test_a_background_continuation_of_the_same_conversation_inherits_the_helm() {
  local dir holder rc out
  dir="$TMP_ROOT/continuation"
  make_home "$dir"
  holder=$(start_lock_holder "$dir")

  # The holder takes the helm while publishing its conversation, exactly as a
  # Claude Code session does.
  CLAUDE_PID="$holder" CLAUDE_CODE_SESSION_ID=conv-alpha \
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" "$dir/bin/fm-lock.sh" >/dev/null \
    || fail "the holder could not record its own conversation on the lock"

  # A background continuation is a different process in a detached tree, under
  # its own harness, carrying the SAME conversation. It must inherit the helm.
  detached_run env -u CLAUDE_PID CLAUDE_CODE_SESSION_ID=conv-alpha FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" "$FAKE_CLAUDE" -c '"$@"; exit $?' _ "$dir/bin/fm-wake-drain.sh" >/dev/null
  out=$(run_output)
  assert_not_contains "$out" "does not hold the fleet lock" \
    "a background continuation of the lock-holding conversation was locked out of its own home"

  # A different conversation is a different session and stays out.
  rc=$(detached_run env -u CLAUDE_PID CLAUDE_CODE_SESSION_ID=conv-beta \
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
    "$FAKE_CLAUDE" -c '"$@"; exit $?' _ "$dir/bin/fm-wake-drain.sh")
  out=$(run_output)
  [ "$rc" != 0 ] || fail "an unrelated conversation inherited the helm"
  assert_contains "$out" "does not hold the fleet lock" \
    "an unrelated conversation was not refused"

  pass "a background continuation of the lock-holding conversation inherits the helm, and only it does"
}

# --- 3. the turn-end guard's decline ----------------------------------------

test_autoarm_declines_without_recording_a_failure() {
  local dir rc out
  dir="$TMP_ROOT/autoarm"
  make_home "$dir"
  start_lock_holder "$dir" >/dev/null

  rc=$(detached_run env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID \
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" \
    "$FAKE_CLAUDE" -c '"$@"; exit $?' _ "$dir/bin/fm-claude-stop-autoarm.sh")
  out=$(run_output)
  expect_code 0 "$rc" "the auto-arm did not stand down cleanly for a home it does not hold"
  [ -z "$out" ] || fail "a clean stand-down was not silent: $out"

  # The fact the guard's decline path exists for: a correct stand-down writes NO
  # failure record, so any escape that waits for one waits forever.
  [ -e "$dir/state/.claude-autoarm-epoch" ] \
    && fail "a stand-down wrote an event epoch it never earned"
  [ -e "$dir/state/.claude-autoarm-failure-notified" ] \
    && fail "a stand-down wrote a failure notice it never earned"

  pass "the auto-arm declines silently and records no failure for a home it does not hold"
}

guard_turn() {  # <dir>
  local dir=$1
  detached_run env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 "$FAKE_CLAUDE" -c '
      printf "%s\n" "{\"session_id\":\"other\",\"stop_hook_active\":false}" \
        | "$1" --claude
      exit $?
    ' _ "$dir/bin/fm-turnend-guard.sh"
}

test_turnend_guard_reports_the_decline_once_then_stops_blocking() {
  local dir rc out turn
  dir="$TMP_ROOT/turnend"
  make_home "$dir"
  start_lock_holder "$dir" >/dev/null

  rc=$(guard_turn "$dir")
  out=$(run_output)
  expect_code 2 "$rc" "the first turn did not report the decline"
  assert_contains "$out" "THIS SESSION CANNOT TURN IT ON" \
    "the decline did not say why this session cannot fix supervision"
  assert_contains "$out" "Reported once" \
    "the decline did not tell the session it will not be blocked again"

  # Every later turn stands down. The old failure-record escape was unreachable
  # from here, so the session was blocked on every turn forever.
  for turn in 2 3 4 5; do
    rc=$(guard_turn "$dir")
    out=$(run_output)
    expect_code 0 "$rc" "turn $turn blocked again after the decline was reported"
    [ -z "$out" ] || fail "turn $turn repeated the decline: $out"
  done

  # The decline must not spend the auto-arm block budget, which belongs to a
  # genuinely broken arm in a home this session actually holds.
  [ -e "$dir/state/.turnend-claude-blocks" ] \
    && fail "the decline consumed the auto-arm block budget"

  pass "the turn-end guard reports a not-this-session decline once, then stops blocking"
}

test_turnend_guard_reports_again_when_the_holder_changes() {
  local dir first second rc out
  dir="$TMP_ROOT/turnend-rehold"
  make_home "$dir"
  first=$(start_lock_holder "$dir")

  expect_code 2 "$(guard_turn "$dir")" "the first decline did not report"
  expect_code 0 "$(guard_turn "$dir")" "the decline did not stand down"

  kill "$first" 2>/dev/null || true
  second=$(start_lock_holder "$dir")
  [ "$second" != "$first" ] || fail "the fixture reused the retired holder pid"

  rc=$(guard_turn "$dir")
  out=$(run_output)
  expect_code 2 "$rc" "a new holder of the home was not reported"
  assert_contains "$out" "$second" "the report named the retired holder, not the current one"

  pass "the decline is reported again when a different session takes the home"
}

test_every_mutating_entry_point_refuses_a_non_owning_session
test_the_lock_holder_itself_still_mutates
test_a_caller_outside_any_harness_session_is_not_a_competing_session
test_lock_output_states_ownership_in_words
test_a_background_continuation_of_the_same_conversation_inherits_the_helm
test_autoarm_declines_without_recording_a_failure
test_turnend_guard_reports_the_decline_once_then_stops_blocking
test_turnend_guard_reports_again_when_the_holder_changes
