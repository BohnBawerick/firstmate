#!/usr/bin/env bash
# Behavior tests for bin/fm-quality.sh - the quality-gate loop controller.
#
# Every case drives the real script over a real throwaway git worktree, a real
# .quality-gate.yaml, and a phase command that prints a real D2 receipt the real
# validator has to accept. Nothing here greps the script's source.
#
# The cases are built in falsifiable pairs wherever a single assertion could be
# satisfied by a constant:
#
#   pass vs read-only          the same measurement, the same threshold met, and
#                              two different outcomes and exit codes - so a
#                              read-only score can never be read as a gate that
#                              ran and approved
#   measured vs could-not      the same contract with a runnable and an
#                              unrunnable command; a constant `pass` fails the
#                              second, a constant `blocked` fails the first
#   stuck vs exhausted         identical finding ids across rounds vs shrinking
#                              ones, so the no-progress rule has to actually
#                              compare ids rather than count rounds
#   bound hit vs bound spare    the same slow command under a tight and a roomy
#                              wall-clock bound
#   flag present vs absent     a harness whose --help advertises structured
#                              output and one whose does not
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

QUALITY="$ROOT/bin/fm-quality.sh"
TMP_ROOT=$(fm_test_tmproot fm-quality)
fm_git_identity fmtest fmtest@example.invalid

# --- fixture ----------------------------------------------------------------

# A case dir with state/, data/, a real git worktree on a branch, a fakebin, and
# a ctl/ dir of test-owned scripts that live OUTSIDE the worktree so a reverted
# round can never take them with it.
new_case() {  # <name> -> echoes case dir
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state" "$d/data" "$d/ctl" "$d/fakebin"
  git -C "$d" init -q --bare .unused.git 2>/dev/null || true
  mkdir -p "$d/wt"
  git -C "$d/wt" init -q
  git -C "$d/wt" commit -q --allow-empty -m init
  git -C "$d/wt" checkout -q -b fm/task

  cat > "$d/ctl/phase.sh" <<'SH'
#!/usr/bin/env sh
n=$(cat "$FMQ_CTL/round" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$FMQ_CTL/round"
exec python3 "$FMQ_CTL/receipt.py" "$n"
SH

  # Builds one D2 phase receipt. The outcome and the finding ids are driven by
  # the environment so a case can shape a run without a second fixture.
  cat > "$d/ctl/receipt.py" <<'PY'
import json
import os
import sys

round_no = int(sys.argv[1])
outcome = os.environ.get("FMQ_OUTCOME", "exhausted")
pass_at = os.environ.get("FMQ_PASS_AT_ROUND", "")
if pass_at and round_no >= int(pass_at):
    outcome = "pass"

mode = os.environ.get("FMQ_IDS_MODE", "none")
if mode == "static":
    ids = ["m1", "m2", "m3"]
elif mode == "shrinking":
    ids = [f"m{i}" for i in range(1, max(1, 8 - round_no))]
else:
    ids = []

phase = os.environ.get("FMQ_FORCE_PHASE") or os.environ["FM_QUALITY_PHASE"]
classification = "over-threshold" if phase == "clean" else "killable"
receipt = {
    "schema_version": 1,
    "phase": phase,
    "outcome": outcome,
    "base_sha": os.environ.get("FMQ_FORCE_BASE") or os.environ["FM_QUALITY_BASE_SHA"],
    "head_sha": os.environ.get("FMQ_FORCE_HEAD") or os.environ["FM_QUALITY_HEAD_SHA"],
    "duration_ms": 7,
    "engine": {"name": "fixture-engine", "version": "1.2.3"},
    "threshold": json.loads(os.environ["FMQ_FORCE_THRESHOLD"])
    if os.environ.get("FMQ_FORCE_THRESHOLD")
    else ({"crap_max": 15} if phase == "clean" else {"kill_rate_min": 0.8}),
    "metrics": {"observed": float(len(ids))},
    "findings": [
        {"id": i, "file": "src/a.ts", "line": 3, "classification": classification}
        for i in ids
    ],
}
json.dump(receipt, sys.stdout)
sys.stdout.write("\n")
PY

  # Exit codes are consumed one per call from ctl/test-exits; the last line
  # repeats, so a case names only as many outcomes as it cares about.
  cat > "$d/ctl/test.sh" <<'SH'
#!/usr/bin/env sh
n=$(cat "$FMQ_CTL/test-calls" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$FMQ_CTL/test-calls"
code=$(sed -n "${n}p" "$FMQ_CTL/test-exits" 2>/dev/null)
[ -n "$code" ] || code=$(tail -1 "$FMQ_CTL/test-exits" 2>/dev/null)
[ -n "$code" ] || code=0
exit "$code"
SH
  printf '0\n' > "$d/ctl/test-exits"

  # A stub claude: answers --version and --help like the real one, consumes the
  # prompt on stdin, optionally edits the worktree, and prints one structured
  # answer. FMQ_CLAUDE_NO_SCHEMA drops the structured-output flag from --help.
  cat > "$d/fakebin/claude" <<'SH'
#!/usr/bin/env bash
set -u
for arg in "$@"; do
  case "$arg" in
    --version) printf '9.9.9 (Claude Code fixture)\n'; exit 0 ;;
    --help)
      printf '  -p, --print   Print response and exit\n'
      [ "${FMQ_CLAUDE_NO_SCHEMA:-0}" = 1 ] || printf '  --json-schema <schema>   JSON Schema for structured output\n'
      exit 0 ;;
  esac
done
cat > /dev/null
[ -z "${FMQ_TURN_DIRTY:-}" ] || printf 'half finished\n' > "$FMQ_TURN_DIRTY"
if [ -n "${FMQ_CLAUDE_TURN_FAILS:-}" ]; then
  printf 'Invalid API key · Please run /login\n' >&2
  exit "$FMQ_CLAUDE_TURN_FAILS"
fi
[ -z "${FMQ_TURN_EDIT:-}" ] || printf 'round\n' >> "$FMQ_TURN_EDIT"
[ -z "${FMQ_TURN_EXCLUDE:-}" ] || printf '    - "%s"\n' "$FMQ_TURN_EXCLUDE" >> .quality-gate.yaml
[ -z "${FMQ_TURN_THRESHOLD:-}" ] || python3 - "$FMQ_TURN_THRESHOLD" <<'EDIT'
import re
import sys

with open(".quality-gate.yaml", encoding="utf-8") as handle:
    text = handle.read()
with open(".quality-gate.yaml", "w", encoding="utf-8") as handle:
    handle.write(re.sub(r"crap_max: .*", "crap_max: " + sys.argv[1], text))
EDIT
printf '{"action":"%s"}\n' "${FMQ_TURN_ACTION:-tested}"
exit 0
SH
  # A phase command that honours the exclude list the loop hands it. The
  # finding survives until "src/a.ts" is excluded, and then the phase passes.
  cat > "$d/ctl/exclude-phase.sh" <<'SH'
#!/usr/bin/env sh
exec python3 "$FMQ_CTL/exclude-receipt.py"
SH

  cat > "$d/ctl/exclude-receipt.py" <<'PY'
import json
import os
import sys

excluded = "src/a.ts" in os.environ.get("FM_QUALITY_EXCLUDE", "").split()
engine_excludes = [e for e in os.environ.get("FMQ_ENGINE_EXCLUDES", "").split() if e]
findings = [] if excluded else [
    {"id": "m1", "file": "src/a.ts", "line": 3, "classification": "over-threshold"}
]
receipt = {
    "schema_version": 1,
    "phase": os.environ["FM_QUALITY_PHASE"],
    "outcome": "pass" if excluded else "exhausted",
    "base_sha": os.environ["FM_QUALITY_BASE_SHA"],
    "head_sha": os.environ["FM_QUALITY_HEAD_SHA"],
    "duration_ms": 7,
    "engine": {"name": "fixture-engine", "version": "1.2.3"},
    "threshold": {"crap_max": 15},
    "metrics": {"observed": float(len(findings))},
    "findings": findings,
}
if engine_excludes:
    receipt["exclusions"] = engine_excludes
json.dump(receipt, sys.stdout)
sys.stdout.write("\n")
PY

  # A phase command that judges against the threshold the loop hands it, so a
  # widened bar turns the same measurement into a pass.
  cat > "$d/ctl/threshold-phase.sh" <<'SH'
#!/usr/bin/env sh
exec python3 "$FMQ_CTL/threshold-receipt.py"
SH

  cat > "$d/ctl/threshold-receipt.py" <<'PY'
import json
import os
import sys

observed = 20.0
bar = 0.0
for line in os.environ.get("FM_QUALITY_THRESHOLD", "").splitlines():
    if line.startswith("crap_max="):
        bar = float(line.split("=", 1)[1])
met = observed <= bar
findings = [] if met else [
    {"id": "m1", "file": "src/a.ts", "line": 3, "classification": "over-threshold"}
]
receipt = {
    "schema_version": 1,
    "phase": os.environ["FM_QUALITY_PHASE"],
    "outcome": "pass" if met else "exhausted",
    "base_sha": os.environ["FM_QUALITY_BASE_SHA"],
    "head_sha": os.environ["FM_QUALITY_HEAD_SHA"],
    "duration_ms": 7,
    "engine": {"name": "fixture-engine", "version": "1.2.3"},
    "threshold": {"crap_max": bar},
    "metrics": {"observed": observed},
    "findings": findings,
}
json.dump(receipt, sys.stdout)
sys.stdout.write("\n")
PY

  chmod +x "$d/ctl/phase.sh" "$d/ctl/test.sh" "$d/ctl/exclude-phase.sh" \
    "$d/ctl/threshold-phase.sh" "$d/fakebin/claude"
  printf '%s\n' "$d"
}

# Writes .quality-gate.yaml and commits it, so the worktree starts clean.
write_contract() {  # <case-dir> <yaml-body>
  printf '%s\n' "$2" > "$1/wt/.quality-gate.yaml"
  git -C "$1/wt" add -A
  git -C "$1/wt" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -qm contract
}

write_meta() {  # <case-dir> <quality> [extra key=val ...]
  local d=$1 quality=$2 base
  shift 2
  base=$(git -C "$d/wt" rev-parse HEAD)
  fm_write_meta "$d/state/task.meta" \
    "window=fm:fm-task" "worktree=$d/wt" "kind=ship" "mode=no-mistakes" \
    "harness=claude" "quality=$quality" "base_sha=$base" "$@"
}

run_quality() {  # <case-dir> <args...>
  local d=$1
  shift
  PATH="$d/fakebin:$PATH" \
  FMQ_CTL="$d/ctl" \
  FM_STATE_OVERRIDE="$d/state" \
  FM_DATA_OVERRIDE="$d/data" \
    "$QUALITY" "$@"
}

# A case's phase-command receipt path.
receipt_of() {  # <case-dir> <phase>
  printf '%s/data/task/quality-%s-receipt.json\n' "$1" "$2"
}

assert_clean_worktree() {  # <case-dir> <why>
  local dirty
  dirty=$(git -C "$1/wt" status --porcelain 2>/dev/null)
  [ -z "$dirty" ] || fail "$2: the task copy was left dirty: $dirty"
}

set_receipt_sha() {  # <file> <field> <value>
  python3 - "$1" "$2" "$3" <<'PY'
import json
import sys

path, field, value = sys.argv[1:4]
with open(path, encoding="utf-8") as handle:
    doc = json.load(handle)
doc[field] = value
with open(path, "w", encoding="utf-8") as handle:
    json.dump(doc, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

# A 12-character sha that shares every character but its last with the one given,
# so it is a near miss rather than a prefix. A rule that compared a fixed number
# of leading characters would call this the same commit.
near_miss_sha() {  # <sha>
  local short=${1:0:12} last
  last=${short:11:1}
  case "$last" in
    a) last=b ;;
    *) last=a ;;
  esac
  printf '%s%s' "${short:0:11}" "$last"
}

receipt_exclusions() {  # <file> -> one glob per line
  python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1])).get("exclusions", [])))' "$1"
}

receipt_outcome() {  # <file>
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["outcome"])' "$1"
}

# The standard single-phase contract. $FMQ_CTL is expanded by the platform shell
# the command runs under, not by YAML.
# shellcheck disable=SC2016 # the phase command's child shell expands $FMQ_CTL, not this test shell
STD_CONTRACT='version: 1
verify: "true"
test: "sh $FMQ_CTL/test.sh"
clean:
  command: "sh $FMQ_CTL/phase.sh"   # scoped by FM_QUALITY_BASE_SHA
  threshold:
    crap_max: 15
bounds:
  max_iterations: 4
  no_progress_limit: 2
  budget_minutes: 5'

# Builds a PATH dir holding only the named tools, so a case can drive the script
# on a host that is missing one - GNU timeout, for instance.
build_toolbin() {  # <case-dir> <extra-tool...>
  local d=$1 tool real
  shift
  mkdir -p "$d/toolbin"
  for tool in python3 git sh bash sed awk grep cut tr sort head tail cat cp mv rm \
      mkdir mktemp chmod dirname basename date env ls "$@"; do
    real=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$real" "$d/toolbin/$tool"
  done
  [ -x "$d/toolbin/python3" ] && [ -x "$d/toolbin/git" ] \
    || fail "the toolbin fixture needs python3 and git"
}

# --- pass, and its read-only twin -------------------------------------------

test_pass() {
  local d out rc=0
  d=$(new_case pass)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  out=$(FMQ_OUTCOME=pass run_quality "$d" run task --phase clean) || rc=$?
  expect_code 0 "$rc" "a met threshold on a hardened task"
  assert_contains "$out" "outcome: pass" "a met threshold reports pass"
  [ "$(receipt_outcome "$(receipt_of "$d" clean)")" = pass ] \
    || fail "the receipt should record pass"
  "$ROOT/bin/fm-quality-receipt.sh" validate "$(receipt_of "$d" clean)" >/dev/null \
    || fail "the written receipt must satisfy the committed schema"
  assert_grep "working: quality clean passed" "$d/state/task.status" \
    "a hardened pass appends its outcome line"
  pass "a hardened task that meets its threshold reports pass and writes a receipt"
}

# The twin of the case above: identical contract, identical measurement,
# identical threshold met. Only the recorded posture differs, and the outcome
# and exit code must differ with it - otherwise a reported score is
# indistinguishable from a gate that ran and approved.
test_read_only_is_not_pass() {
  local d out rc=0
  d=$(new_case read-only)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" standard
  out=$(FMQ_OUTCOME=pass run_quality "$d" run task --phase clean) || rc=$?
  expect_code 6 "$rc" "a read-only run must not exit with the pass code"
  assert_contains "$out" "outcome: read-only" "a read-only run reports read-only"
  assert_not_contains "$out" "outcome: pass" "a read-only run never reports pass"
  case "$out" in
    "outcome: read-only"*) : ;;
    *) fail "the outcome token itself must be read-only: $out" ;;
  esac
  local file
  file=$(receipt_of "$d" clean)
  [ "$(receipt_outcome "$file")" = read-only ] \
    || fail "the receipt must record read-only, not the measured pass"
  "$ROOT/bin/fm-quality-receipt.sh" validate "$file" >/dev/null \
    || fail "a read-only receipt must satisfy the committed schema"
  assert_absent "$d/state/task.status" \
    "a read-only run appends no supervisor status line"
  pass "read-only reports the score with its own outcome and exit code, never pass"
}

# Read-only relaxes blocking, never honesty. The same unrunnable command that a
# hardened task refuses on must not become a score on a standard one.
test_read_only_cannot_measure_is_blocked() {
  local d out rc=0
  d=$(new_case read-only-blocked)
  write_contract "$d" "${STD_CONTRACT/sh \$FMQ_CTL\/phase.sh/fm-no-such-quality-engine}"
  write_meta "$d" standard
  out=$(run_quality "$d" run task --phase clean) || rc=$?
  expect_code 3 "$rc" "a read-only run that could not measure is blocked"
  assert_contains "$out" "outcome: blocked" "could-not-measure is blocked in read-only too"
  case "$out" in
    "outcome: blocked"*) : ;;
    *) fail "a failed measurement must not report a read-only score: $out" ;;
  esac
  assert_absent "$(receipt_of "$d" clean)" "no measurement means no receipt"
  pass "a read-only run that cannot measure reports blocked, not a score"
}

# --- could not measure is never a pass --------------------------------------

test_missing_toolchain_is_blocked_not_pass() {
  local d out rc=0
  d=$(new_case missing-toolchain)
  write_contract "$d" "${STD_CONTRACT/sh \$FMQ_CTL\/phase.sh/fm-no-such-quality-engine}"
  write_meta "$d" hardened
  out=$(run_quality "$d" run task --phase clean) || rc=$?
  expect_code 3 "$rc" "an unrunnable phase command is blocked"
  assert_contains "$out" "outcome: blocked" "an unrunnable command reports blocked"
  assert_not_contains "$out" "pass" "an unrunnable command never mentions pass"
  assert_absent "$(receipt_of "$d" clean)" "a blocked measurement writes no receipt"
  assert_grep "blocked: quality clean could not measure" "$d/state/task.status" \
    "a hardened blocked run escalates on the status file"
  pass "a missing toolchain reports blocked and never pass"
}

# The dangerous case the pilot found: an earlier pass must not survive a run
# that could not measure, or the receipt would keep vouching for code nobody
# measured.
test_stale_pass_receipt_is_cleared() {
  local d rc=0 file
  d=$(new_case stale-receipt)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  FMQ_OUTCOME=pass run_quality "$d" run task --phase clean >/dev/null || rc=$?
  expect_code 0 "$rc" "the first run passes"
  file=$(receipt_of "$d" clean)
  assert_present "$file" "the first run leaves a receipt"
  write_contract "$d" "${STD_CONTRACT/sh \$FMQ_CTL\/phase.sh/fm-no-such-quality-engine}"
  rc=0
  run_quality "$d" run task --phase clean >/dev/null || rc=$?
  expect_code 3 "$rc" "the second run cannot measure"
  assert_absent "$file" "a run that could not measure must not leave the old pass standing"
  pass "a run that cannot measure clears the previous receipt instead of inheriting it"
}

test_invalid_receipt_is_blocked() {
  local d out rc=0
  d=$(new_case invalid-receipt)
  write_contract "$d" "${STD_CONTRACT/sh \$FMQ_CTL\/phase.sh/echo not-json}"
  write_meta "$d" hardened
  out=$(run_quality "$d" run task --phase clean) || rc=$?
  expect_code 3 "$rc" "prose instead of a receipt is blocked"
  assert_contains "$out" "invalid receipt" "the refusal names the unreadable receipt"
  pass "a phase command that prints prose is blocked, not parsed"
}

# base_sha drift is the silent miss the schema revision was written for: a gate
# measuring the wrong anchor keeps reporting success.
test_base_drift_is_blocked() {
  local d out rc=0
  d=$(new_case base-drift)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  out=$(FMQ_OUTCOME=pass FMQ_FORCE_BASE=1111111111111111111111111111111111111111 \
    run_quality "$d" run task --phase clean) || rc=$?
  expect_code 3 "$rc" "a receipt measured against another base is blocked"
  assert_contains "$out" "not this task's base commit" "the refusal names the drift"
  pass "a receipt whose base commit drifted is blocked, not accepted as a pass"
}

# --- the ordinary suite decides whether a score means anything --------------

test_red_suite_is_blocked() {
  local d out rc=0
  d=$(new_case red-suite)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  printf '1\n' > "$d/ctl/test-exits"
  out=$(FMQ_OUTCOME=pass run_quality "$d" run task --phase clean) || rc=$?
  expect_code 3 "$rc" "a red suite blocks before the score is trusted"
  assert_contains "$out" "red before any quality work" "the refusal names the red suite"
  assert_absent "$(receipt_of "$d" clean)" "a red suite leaves no receipt"
  pass "a red ordinary suite is blocked even when the phase command would pass"
}

# The pilot's flattering failure: a wall-clock-sensitive test that fails under
# load and passes idle. Averaging across that noise is exactly what must not
# happen.
test_flaky_suite_is_blocked() {
  local d out rc=0
  d=$(new_case flaky-suite)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  printf '1\n0\n' > "$d/ctl/test-exits"
  out=$(FMQ_OUTCOME=pass run_quality "$d" run task --phase clean) || rc=$?
  expect_code 3 "$rc" "a flaky suite blocks rather than being averaged over"
  assert_contains "$out" "flaky" "the refusal names the flaky suite"
  pass "a suite that is red then green on identical code is blocked, not measured over"
}

# --- not-applicable is deliberately a different word from pass --------------

test_no_contract_is_not_applicable() {
  local d out rc=0
  d=$(new_case no-contract)
  write_meta "$d" hardened
  out=$(run_quality "$d" run task --phase clean) || rc=$?
  expect_code 4 "$rc" "a project with no contract is not-applicable"
  assert_contains "$out" "outcome: not-applicable" "no contract reports not-applicable"
  assert_not_contains "$out" "outcome: pass" "no contract is never a pass"
  pass "a project with no .quality-gate.yaml is not-applicable, not a pass"
}

test_unconfigured_phase_is_not_applicable() {
  local d out rc=0
  d=$(new_case no-phase)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  out=$(run_quality "$d" run task --phase harden) || rc=$?
  expect_code 4 "$rc" "an unconfigured phase is not-applicable"
  assert_contains "$out" "no harden phase" "the message names the missing phase"
  pass "a phase the contract does not configure is not-applicable"
}

test_measured_nothing_is_not_applicable() {
  local d out rc=0
  d=$(new_case measured-nothing)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  out=$(FMQ_OUTCOME=not-applicable run_quality "$d" run task --phase clean) || rc=$?
  expect_code 4 "$rc" "a docs-only diff is not-applicable"
  [ "$(receipt_outcome "$(receipt_of "$d" clean)")" = not-applicable ] \
    || fail "measured-nothing is recorded as not-applicable in the receipt"
  pass "a phase that found nothing to measure records not-applicable"
}

# --- bounds: exhausted and stuck are distinguished by the findings ----------

# Shrinking finding ids mean every round made progress, so only the round bound
# can end this phase.
test_rounds_exhausted() {
  local d out rc=0
  d=$(new_case exhausted)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  out=$(FMQ_IDS_MODE=shrinking run_quality "$d" run task --phase clean) || rc=$?
  expect_code 1 "$rc" "rounds running out below threshold exits 1"
  assert_contains "$out" "outcome: exhausted" "rounds running out reports exhausted"
  assert_not_contains "$out" "outcome: stuck" "progress every round is not stuck"
  [ "$(receipt_outcome "$(receipt_of "$d" clean)")" = exhausted ] \
    || fail "the receipt records the exhausted outcome"
  pass "a phase below threshold with progress every round reports exhausted"
}

# The twin: same contract, same round bound, same agent turn. Only the finding
# ids stop moving, and that alone must change the verdict - so the rule has to
# compare ids rather than count rounds.
test_no_progress_is_stuck() {
  local d out rc=0
  d=$(new_case stuck)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  out=$(FMQ_IDS_MODE=static run_quality "$d" run task --phase clean) || rc=$?
  expect_code 1 "$rc" "no progress below threshold exits 1"
  assert_contains "$out" "outcome: stuck" "identical findings across rounds is stuck"
  assert_not_contains "$out" "outcome: exhausted" "stuck is reported before the round bound"
  pass "rounds that leave the same findings untouched report stuck, not exhausted"
}

# --- the wall-clock bound is enforced, not assumed --------------------------

test_wall_clock_bound_cuts_a_slow_engine_short() {
  local d out rc=0 started ended
  d=$(new_case wall-clock)
  write_contract "$d" 'version: 1
verify: "true"
clean:
  command: "sleep 60"
bounds:
  budget_minutes: 0.03'
  write_meta "$d" hardened
  started=$(date +%s)
  out=$(run_quality "$d" run task --phase clean) || rc=$?
  ended=$(date +%s)
  expect_code 1 "$rc" "a measurement that outruns the bound exits 1"
  assert_contains "$out" "outcome: exhausted" "an overrunning measurement is exhausted"
  assert_not_contains "$out" "outcome: pass" "an overrunning measurement is never a pass"
  [ $((ended - started)) -lt 30 ] \
    || fail "the bound did not actually stop the command: took $((ended - started))s of a 60s sleep"
  pass "a measurement that outruns the wall-clock bound is cut short and reports exhausted"
}

# The twin: the same shape of slow command under a roomy bound must finish, so
# the case above cannot be satisfied by always reporting exhausted.
test_wall_clock_bound_leaves_a_fast_engine_alone() {
  local d rc=0
  d=$(new_case wall-clock-spare)
  # shellcheck disable=SC2016 # the phase command's child shell expands $FMQ_CTL, not this test shell
  write_contract "$d" 'version: 1
verify: "true"
clean:
  command: "sleep 1 && sh $FMQ_CTL/phase.sh"
bounds:
  budget_minutes: 5'
  write_meta "$d" hardened
  FMQ_OUTCOME=pass run_quality "$d" run task --phase clean >/dev/null || rc=$?
  expect_code 0 "$rc" "a measurement inside the bound still passes"
  pass "a measurement that fits inside the wall-clock bound is left alone"
}

# The bound has to be enforceable before any measurement is trusted.
test_unenforceable_bound_is_blocked() {
  local d out rc=0 toolbin tool real
  d=$(new_case no-timeout)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  toolbin="$d/toolbin"
  mkdir -p "$toolbin"
  for tool in python3 git sh bash sed awk grep cut tr sort head tail cat cp mv rm \
      mkdir mktemp chmod dirname basename date env ls; do
    real=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$real" "$toolbin/$tool"
  done
  [ -x "$toolbin/python3" ] && [ -x "$toolbin/git" ] \
    || fail "the no-timeout fixture needs python3 and git"
  out=$(PATH="$toolbin" FMQ_CTL="$d/ctl" FM_STATE_OVERRIDE="$d/state" \
    FM_DATA_OVERRIDE="$d/data" "$QUALITY" run task --phase clean) || rc=$?
  expect_code 3 "$rc" "a host that cannot bound the measurement refuses"
  assert_contains "$out" "wall-clock bound cannot be enforced" \
    "the refusal names the unenforceable bound"
  pass "a host with no way to bound a measurement is blocked rather than run unbounded"
}

# --- defect-found leaves the loop -------------------------------------------

test_command_reported_defect() {
  local d out rc=0
  d=$(new_case defect-command)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  out=$(FMQ_OUTCOME=defect-found run_quality "$d" run task --phase clean) || rc=$?
  expect_code 5 "$rc" "a reported defect exits 5"
  assert_contains "$out" "outcome: defect-found" "a reported defect is defect-found"
  [ "$(receipt_outcome "$(receipt_of "$d" clean)")" = defect-found ] \
    || fail "the receipt records defect-found"
  pass "a phase command that reports a real defect leaves the loop as defect-found"
}

test_agent_reported_defect_leaves_the_loop() {
  local d out rc=0
  d=$(new_case defect-agent)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  out=$(FMQ_IDS_MODE=static FMQ_TURN_ACTION=defect-found \
    run_quality "$d" run task --phase clean) || rc=$?
  expect_code 5 "$rc" "an agent-reported defect exits 5"
  assert_contains "$out" "outcome: defect-found" "an agent-reported defect ends the phase"
  assert_not_contains "$out" "outcome: stuck" "a defect leaves before the no-progress rule fires"
  assert_grep "blocked: quality clean defect-found" "$d/state/task.status" \
    "a defect escalates on the status file"
  pass "a survivor reported as a real defect leaves the loop instead of being tested around"
}

# --- a round is committed or reverted, never half-applied -------------------

test_green_round_is_committed() {
  local d before after rc=0
  d=$(new_case round-commit)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  before=$(git -C "$d/wt" rev-parse HEAD)
  FMQ_IDS_MODE=shrinking FMQ_TURN_EDIT="$d/wt/new-test.txt" \
    run_quality "$d" run task --phase clean >/dev/null || rc=$?
  expect_code 1 "$rc" "the phase still runs out of rounds"
  after=$(git -C "$d/wt" rev-parse HEAD)
  [ "$before" != "$after" ] || fail "a green round should have been committed"
  assert_present "$d/wt/new-test.txt" "a green round keeps its edit"
  git -C "$d/wt" log --oneline | grep -q 'quality(clean): round 1' \
    || fail "the round commit should name its phase and round"
  pass "a round whose ordinary suite stays green is committed"
}

# The twin: identical round, identical edit, only the suite goes red.
test_red_round_is_reverted() {
  local d before after rc=0
  d=$(new_case round-revert)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  printf '0\n1\n' > "$d/ctl/test-exits"
  before=$(git -C "$d/wt" rev-parse HEAD)
  FMQ_IDS_MODE=shrinking FMQ_TURN_EDIT="$d/wt/broken.txt" \
    run_quality "$d" run task --phase clean >/dev/null || rc=$?
  expect_code 1 "$rc" "the phase still runs out of rounds"
  after=$(git -C "$d/wt" rev-parse HEAD)
  [ "$before" = "$after" ] || fail "a round that broke the suite should not be committed"
  assert_absent "$d/wt/broken.txt" "a reverted round takes its edit with it"
  pass "a round that breaks the ordinary suite is reverted, costing budget and nothing else"
}

test_dirty_worktree_refuses() {
  local d out rc=0
  d=$(new_case dirty)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  printf 'uncommitted\n' > "$d/wt/scratch.txt"
  out=$(FMQ_OUTCOME=pass run_quality "$d" run task --phase clean) || rc=$?
  expect_code 3 "$rc" "an uncommitted tree refuses before the loop commits anything"
  assert_contains "$out" "uncommitted changes" "the refusal names the uncommitted work"
  assert_present "$d/wt/scratch.txt" "the refusal must not touch the uncommitted work"
  pass "a hardened loop refuses on an uncommitted tree rather than risking that work"
}

# --- the structured-output guard --------------------------------------------

test_harness_without_a_recipe_refuses() {
  local d out rc=0
  d=$(new_case harness-unsupported)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  fm_write_meta "$d/state/task.meta" \
    "window=fm:fm-task" "worktree=$d/wt" "kind=ship" "mode=no-mistakes" \
    "harness=grok" "quality=hardened" "base_sha=$(git -C "$d/wt" rev-parse HEAD)"
  out=$(run_quality "$d" run task --phase clean) || rc=$?
  expect_code 3 "$rc" "a harness with no schema-validated answer refuses"
  assert_contains "$out" "harness grok" "the refusal names the harness"
  pass "a hardened loop refuses a harness with no schema-validated final answer"
}

# The guard reads the resolved binary's own --help rather than trusting a name,
# so a renamed or dropped flag refuses loudly instead of running blind. The pair
# proves the check reads the help: same harness name, two different verdicts.
test_structured_output_flag_is_read_from_the_harness() {
  local d out rc=0
  d=$(new_case harness-flag)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  out=$(FMQ_CLAUDE_NO_SCHEMA=1 run_quality "$d" run task --phase clean) || rc=$?
  expect_code 3 "$rc" "a harness that stopped advertising the flag refuses"
  assert_contains "$out" "no longer advertises --json-schema" \
    "the refusal names the missing flag"
  assert_contains "$out" "9.9.9" "the refusal names the harness version"
  rc=0
  out=$(FMQ_OUTCOME=pass run_quality "$d" run task --phase clean) || rc=$?
  expect_code 0 "$rc" "the same harness advertising the flag is not refused"
  pass "the structured-output guard reads the harness's own help, not a hardcoded name"
}

# --- status and receipt surfaces --------------------------------------------

test_status_reports_the_gate_verdict() {
  local d out
  d=$(new_case status-verdict)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  out=$(run_quality "$d" status task)
  assert_contains "$out" "quality: missing" "no receipt yet reports missing"
  FMQ_OUTCOME=pass run_quality "$d" run task --phase clean >/dev/null
  out=$(run_quality "$d" status task)
  assert_contains "$out" "quality: satisfied" "a passing receipt satisfies the gate"
  printf 'not a receipt\n' > "$(receipt_of "$d" clean)"
  out=$(run_quality "$d" status task)
  assert_contains "$out" "quality: unreadable" \
    "an unreadable receipt is its own answer, not the same as a missing one"
  pass "status distinguishes a missing receipt from an unreadable one from a satisfied gate"
}

test_status_on_a_standard_task_requires_nothing() {
  local d out
  d=$(new_case status-standard)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" standard
  out=$(run_quality "$d" status task)
  assert_contains "$out" "quality: not-required" "a standard task gates on no receipt"
  pass "a standard task's quality status requires no receipt"
}

test_receipt_prints_what_was_written() {
  local d out
  d=$(new_case receipt-cmd)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  out=$(run_quality "$d" receipt task)
  [ "$out" = "[]" ] || fail "no receipts should print an empty list, got: $out"
  FMQ_OUTCOME=pass run_quality "$d" run task --phase clean >/dev/null
  out=$(run_quality "$d" receipt task)
  assert_contains "$out" '"outcome": "pass"' "the receipt command prints the written receipt"
  pass "the receipt command prints exactly the receipts that exist"
}

test_dry_run_changes_nothing() {
  local d out rc=0
  d=$(new_case dry-run)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  out=$(run_quality "$d" run task --phase clean --dry-run) || rc=$?
  expect_code 0 "$rc" "a dry run resolves cleanly"
  assert_contains "$out" "dry-run: phase clean" "a dry run names the resolved phase"
  assert_absent "$(receipt_of "$d" clean)" "a dry run writes no receipt"
  assert_absent "$d/ctl/round" "a dry run runs no phase command"
  pass "a dry run resolves the plan without measuring or writing anything"
}

# --- refusals on a malformed or unknown contract ----------------------------

test_unknown_contract_version_refuses() {
  local d rc=0
  d=$(new_case bad-version)
  write_contract "$d" 'version: 2
verify: "true"'
  write_meta "$d" hardened
  run_quality "$d" run task --phase clean >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an unknown contract version refuses loudly"
  pass "an unknown .quality-gate.yaml version is refused rather than half-read"
}

test_contract_without_verify_refuses() {
  local d rc=0
  d=$(new_case no-verify)
  write_contract "$d" 'version: 1
clean:
  command: "true"'
  write_meta "$d" hardened
  run_quality "$d" run task --phase clean >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "a contract with no verify command refuses"
  pass "a contract with no verify command is refused"
}

test_missing_base_anchor_is_blocked() {
  local d out rc=0
  d=$(new_case no-base)
  write_contract "$d" "$STD_CONTRACT"
  fm_write_meta "$d/state/task.meta" \
    "window=fm:fm-task" "worktree=$d/wt" "kind=ship" "mode=no-mistakes" \
    "harness=claude" "quality=hardened"
  out=$(run_quality "$d" run task --phase clean) || rc=$?
  expect_code 3 "$rc" "no base commit means no diff-scoped measurement"
  assert_contains "$out" "no base commit" "the refusal names the missing anchor"
  pass "a task with no recorded base commit is blocked rather than measured against HEAD"
}

test_usage_errors() {
  local rc=0
  "$QUALITY" run >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "run with no task id is a usage error"
  rc=0
  "$QUALITY" run nosuchtask >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "run with no phase is a usage error"
  rc=0
  "$QUALITY" -h >/dev/null 2>&1 || rc=$?
  expect_code 0 "$rc" "--help exits 0"
  pass "usage errors exit 2 and --help exits 0"
}

# A dry run is an inspection. It must not destroy the durable proof an earlier
# run left behind: on a hardened task bin/fm-crew-state.sh reads that file, and
# a missing receipt reopens a task that was finished.
test_dry_run_keeps_an_existing_receipt() {
  local d file rc=0 out
  d=$(new_case dry-run-keeps)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  FMQ_OUTCOME=pass run_quality "$d" run task --phase clean >/dev/null || rc=$?
  expect_code 0 "$rc" "the measuring run passes"
  file=$(receipt_of "$d" clean)
  assert_present "$file" "the measuring run leaves a receipt"
  rc=0
  out=$(run_quality "$d" run task --phase clean --dry-run) || rc=$?
  expect_code 0 "$rc" "a dry run resolves cleanly"
  assert_contains "$out" "no receipt was written" "a dry run says it wrote nothing"
  assert_present "$file" "a dry run must not delete the receipt it says it did not touch"
  [ "$(receipt_outcome "$file")" = pass ] \
    || fail "the earlier pass must survive a dry run untouched"
  pass "a dry run leaves an existing receipt exactly as it found it"
}

# The turn prompt asks the agent to answer `excluded` by editing the contract's
# exclude list. The loop commits that edit, so the next round has to read it
# back or one of the four documented answers is a no-op inside a run.
# shellcheck disable=SC2016 # the phase command's child shell expands $FMQ_CTL, not this test shell
EXCLUDE_CONTRACT='version: 1
verify: "true"
test: "sh $FMQ_CTL/test.sh"
bounds:
  max_iterations: 4
  no_progress_limit: 3
  budget_minutes: 5
clean:
  command: "sh $FMQ_CTL/exclude-phase.sh"
  threshold:
    crap_max: 15
  exclude:
    - "src/gen/**"'

test_a_round_can_exclude_a_finding() {
  local d out rc=0
  d=$(new_case exclude-honoured)
  write_contract "$d" "$EXCLUDE_CONTRACT"
  write_meta "$d" hardened
  out=$(FMQ_TURN_ACTION=excluded FMQ_TURN_EXCLUDE=src/a.ts \
    run_quality "$d" run task --phase clean) || rc=$?
  expect_code 0 "$rc" "a round that excludes the finding reaches pass"
  assert_contains "$out" "outcome: pass" "the next round measures against the new exclude list"
  [ "$(receipt_outcome "$(receipt_of "$d" clean)")" = pass ] \
    || fail "the receipt records the pass the exclusion produced"
  pass "a finding excluded by a round is gone from the next round's measurement"
}

# The twin: identical contract, identical rounds, identical agent turn - only
# the exclude edit is missing. The finding must survive, so the case above
# cannot be satisfied by a phase command that always passes.
test_without_the_exclude_edit_the_finding_survives() {
  local d out rc=0
  d=$(new_case exclude-absent)
  write_contract "$d" "$EXCLUDE_CONTRACT"
  write_meta "$d" hardened
  out=$(FMQ_TURN_ACTION=tested run_quality "$d" run task --phase clean) || rc=$?
  expect_code 1 "$rc" "a finding nobody excluded keeps the phase below threshold"
  assert_not_contains "$out" "outcome: pass" "an unexcluded finding is never a pass"
  pass "without the exclude edit the same finding survives every round"
}

# clean and harden judge findings by different vocabularies, so a receipt from
# the other phase is not evidence about this one.
test_receipt_from_another_phase_is_blocked() {
  local d out rc=0
  d=$(new_case wrong-phase)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  out=$(FMQ_FORCE_PHASE=harden FMQ_OUTCOME=pass \
    run_quality "$d" run task --phase clean) || rc=$?
  expect_code 3 "$rc" "a receipt for the other phase is blocked"
  assert_contains "$out" "outcome: blocked" "a mismatched phase reports blocked"
  assert_not_contains "$out" "outcome: pass" "a harden receipt never satisfies the clean gate"
  assert_absent "$(receipt_of "$d" clean)" "a mismatched receipt is not filed as this phase's proof"
  pass "a phase command that answers for the other phase is blocked, not accepted"
}

# An unchanged empty finding set is the clearest no-progress case there is.
test_repeated_empty_findings_is_stuck() {
  local d out rc=0
  d=$(new_case stuck-empty)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  out=$(FMQ_IDS_MODE=none FMQ_OUTCOME=exhausted \
    run_quality "$d" run task --phase clean) || rc=$?
  expect_code 1 "$rc" "rounds below threshold with no progress exit 1"
  assert_contains "$out" "outcome: stuck" "an unchanged empty finding set is no progress"
  assert_not_contains "$out" "outcome: exhausted" "stuck is reported before the round bound"
  pass "rounds that repeat an empty finding set report stuck, not exhausted"
}

# The suite re-run that tells red apart from flaky shares the one bound; it does
# not get a second full copy of it.
test_the_suite_recheck_stays_inside_the_bound() {
  local d out rc=0 started ended
  d=$(new_case suite-recheck-bound)
  # shellcheck disable=SC2016 # the phase command's child shell expands $FMQ_CTL, not this test shell
  write_contract "$d" 'version: 1
verify: "true"
test: "sleep 5; exit 1"
clean:
  command: "sh $FMQ_CTL/phase.sh"
bounds:
  budget_minutes: 0.1'
  write_meta "$d" hardened
  started=$(date +%s)
  out=$(run_quality "$d" run task --phase clean) || rc=$?
  ended=$(date +%s)
  expect_code 3 "$rc" "a red suite the bound cut short is blocked, not exhausted"
  assert_contains "$out" "outcome: blocked" "a red suite that outran the bound is still could-not-measure"
  assert_not_contains "$out" "outcome: pass" "a red suite is never a pass"
  [ $((ended - started)) -lt 9 ] \
    || fail "the suite check spent more than one bound: $((ended - started))s of a 6s bound"
  pass "checking a red suite twice stays inside the one wall-clock bound"
}

# The perl fallback is the only bounded runner on a host without GNU timeout. A
# suite killed by a signal has to read as red there too, or a crashed or
# OOM-killed suite is scored green and every number measured over it is trusted.
test_signal_killed_suite_is_red_without_gnu_timeout() {
  local d out rc=0
  if ! command -v perl >/dev/null 2>&1; then
    pass "skipped: this host has no perl to fall back to"
    return 0
  fi
  d=$(new_case perl-signal)
  # shellcheck disable=SC2016 # the phase command's child shell expands $$ and $FMQ_CTL, not this test shell
  write_contract "$d" 'version: 1
verify: "true"
test: "kill -SEGV $$"
clean:
  command: "sh $FMQ_CTL/phase.sh"
bounds:
  budget_minutes: 5'
  write_meta "$d" hardened
  build_toolbin "$d" perl sleep kill
  out=$(PATH="$d/toolbin:$d/fakebin" FMQ_CTL="$d/ctl" FM_STATE_OVERRIDE="$d/state" \
    FM_DATA_OVERRIDE="$d/data" FMQ_OUTCOME=pass "$QUALITY" run task --phase clean) || rc=$?
  expect_code 3 "$rc" "a suite killed by a signal blocks the measurement"
  assert_contains "$out" "outcome: blocked" "a crashed suite reports blocked"
  assert_not_contains "$out" "outcome: pass" "a crashed suite is never scored green"
  assert_absent "$d/ctl/round" "the phase command never runs over a crashed suite"
  pass "a signal-killed test suite reads as red on a host that only has perl"
}

# The twin: the same perl-only host with a green suite must measure normally, so
# the case above cannot be satisfied by refusing whenever GNU timeout is gone.
test_perl_host_still_measures_a_green_suite() {
  local d rc=0
  if ! command -v perl >/dev/null 2>&1; then
    pass "skipped: this host has no perl to fall back to"
    return 0
  fi
  d=$(new_case perl-green)
  # shellcheck disable=SC2016 # the phase command's child shell expands $FMQ_CTL, not this test shell
  write_contract "$d" 'version: 1
verify: "true"
test: "exit 0"
clean:
  command: "sh $FMQ_CTL/phase.sh"
bounds:
  budget_minutes: 5'
  write_meta "$d" hardened
  build_toolbin "$d" perl sleep kill
  PATH="$d/toolbin:$d/fakebin" FMQ_CTL="$d/ctl" FM_STATE_OVERRIDE="$d/state" \
    FM_DATA_OVERRIDE="$d/data" FMQ_OUTCOME=pass "$QUALITY" run task --phase clean >/dev/null || rc=$?
  expect_code 0 "$rc" "a green suite on a perl-only host still measures and passes"
  pass "a perl-only host measures a green suite normally"
}

# A dry run is an inspection, so it must file no supervision event either. A
# hardened task is dirty for most of its working life, and bin/fm-classify-lib.sh
# reads a `blocked:` status line as a decision-opening event about a real crew.
test_dry_run_files_no_supervision_event() {
  local d rc=0
  d=$(new_case dry-run-quiet)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  printf 'uncommitted\n' > "$d/wt/scratch.txt"
  run_quality "$d" run task --phase clean --dry-run >/dev/null 2>&1 || rc=$?
  assert_absent "$d/state/task.status" "a dry run must append no status line at all"
  rc=0
  run_quality "$d" run task --phase clean >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "the same state without --dry-run refuses"
  assert_grep "blocked: quality clean could not measure" "$d/state/task.status" \
    "the same state without --dry-run does file the blocked event"
  pass "a dry run reports without filing the supervision event a real run files"
}

# The loop re-reads the contract each round so an exclusion lands, and the agent
# turn runs with full write access to the worktree. The bar it is judged against
# is not one of the things it gets to move.
# shellcheck disable=SC2016 # the phase command's child shell expands $FMQ_CTL, not this test shell
THRESHOLD_CONTRACT='version: 1
verify: "true"
test: "sh $FMQ_CTL/test.sh"
bounds:
  max_iterations: 4
  no_progress_limit: 3
  budget_minutes: 5
clean:
  command: "sh $FMQ_CTL/threshold-phase.sh"
  threshold:
    crap_max: 15'

test_a_round_cannot_widen_its_own_threshold() {
  local d out rc=0
  d=$(new_case threshold-tamper)
  write_contract "$d" "$THRESHOLD_CONTRACT"
  write_meta "$d" hardened
  out=$(FMQ_TURN_THRESHOLD=9999 run_quality "$d" run task --phase clean) || rc=$?
  expect_code 3 "$rc" "a widened threshold is blocked, not honoured"
  assert_contains "$out" "outcome: blocked" "moving the bar mid-run is could-not-measure"
  assert_contains "$out" "threshold" "the refusal names what the round changed"
  assert_not_contains "$out" "outcome: pass" "the same measurement must not become a pass"
  assert_absent "$(receipt_of "$d" clean)" "a tampered run leaves no receipt vouching for the code"
  pass "a round that widens its own threshold is blocked instead of passing"
}

# The twin: same contract, same rounds, same agent turn, no threshold edit. The
# phase must run to its bound below the unchanged bar, so the case above cannot
# be satisfied by blocking every multi-round run.
test_an_untouched_threshold_runs_the_rounds_out() {
  local d out rc=0
  d=$(new_case threshold-intact)
  write_contract "$d" "$THRESHOLD_CONTRACT"
  write_meta "$d" hardened
  out=$(run_quality "$d" run task --phase clean) || rc=$?
  expect_code 1 "$rc" "an unchanged bar leaves the phase below threshold"
  assert_not_contains "$out" "outcome: blocked" "an unchanged contract is not a refusal"
  assert_not_contains "$out" "outcome: pass" "the measurement never met the unchanged bar"
  pass "a run that leaves the contract alone measures against its own bar to the end"
}

# budget_usd is the harness spend ceiling. A value the harness cannot read is
# not a ceiling, and swallowing it turns every agent turn into a silent no-op.
test_unreadable_budget_usd_refuses() {
  local d out rc=0
  d=$(new_case bad-budget-usd)
  # shellcheck disable=SC2016 # the phase command's child shell expands $FMQ_CTL, not this test shell
  write_contract "$d" 'version: 1
verify: "true"
clean:
  command: "sh $FMQ_CTL/phase.sh"
bounds:
  budget_usd: unlimited'
  write_meta "$d" hardened
  out=$(run_quality "$d" run task --phase clean 2>&1) || rc=$?
  expect_code 2 "$rc" "a spend ceiling that is not a number is a contract error"
  assert_contains "$out" "budget_usd" "the refusal names the bound it could not read"
  assert_absent "$d/ctl/round" "no measurement runs under an unreadable spend ceiling"
  pass "a budget_usd that is not a positive number is refused, not passed to the harness"
}

# The twin: the same contract with a readable ceiling must measure normally, so
# the case above cannot be satisfied by refusing whenever budget_usd is set.
test_a_readable_budget_usd_is_accepted() {
  local d rc=0
  d=$(new_case good-budget-usd)
  # shellcheck disable=SC2016 # the phase command's child shell expands $FMQ_CTL, not this test shell
  write_contract "$d" 'version: 1
verify: "true"
clean:
  command: "sh $FMQ_CTL/phase.sh"
bounds:
  budget_usd: 3'
  write_meta "$d" hardened
  FMQ_OUTCOME=pass run_quality "$d" run task --phase clean >/dev/null || rc=$?
  expect_code 0 "$rc" "a numeric spend ceiling is accepted"
  pass "a budget_usd the harness can read is accepted and the phase measures"
}

# A harness that never ran is not an agent that looked and changed nothing. The
# loop must name the broken harness rather than spend every round and then blame
# the code for leaving the findings untouched.
test_a_harness_that_cannot_run_is_blocked() {
  local d out rc=0
  d=$(new_case turn-harness-down)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  out=$(FMQ_IDS_MODE=static FMQ_CLAUDE_TURN_FAILS=1 \
    run_quality "$d" run task --phase clean) || rc=$?
  expect_code 3 "$rc" "a harness that exits non-zero with no answer is blocked"
  assert_contains "$out" "outcome: blocked" "a turn that never ran is could-not-measure"
  assert_contains "$out" "claude" "the refusal names the harness that failed"
  assert_not_contains "$out" "outcome: stuck" "a broken harness is not the code standing still"
  [ "$(receipt_outcome "$(receipt_of "$d" clean)")" = blocked ] \
    || fail "the receipt records blocked, not a verdict about the code"
  pass "a harness that cannot run reports blocked instead of blaming the code"
}

# The twin: the same contract, the same unmoving findings, the same rounds - only
# the harness works and answers. That must still reach stuck, so the case above
# cannot be satisfied by blocking whenever the findings do not move.
test_a_working_harness_that_changes_nothing_is_stuck() {
  local d out rc=0
  d=$(new_case turn-no-change)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  out=$(FMQ_IDS_MODE=static FMQ_TURN_ACTION=no-change \
    run_quality "$d" run task --phase clean) || rc=$?
  expect_code 1 "$rc" "an agent that answered no-change leaves the phase stuck"
  assert_contains "$out" "outcome: stuck" "an agent that ran and changed nothing is stuck"
  assert_not_contains "$out" "outcome: blocked" "a working harness is not a broken one"
  pass "an agent that ran and answered no-change still reports stuck"
}

# The receipt is the durable proof, so it has to record the bar the run measured
# against. A pass earned by excluding the diff must not be byte-identical to a
# pass earned by writing tests.
test_the_receipt_records_what_was_excluded() {
  local d file rc=0
  d=$(new_case receipt-exclusions)
  write_contract "$d" "$EXCLUDE_CONTRACT"
  write_meta "$d" hardened
  FMQ_TURN_ACTION=excluded FMQ_TURN_EXCLUDE=src/a.ts \
    run_quality "$d" run task --phase clean >/dev/null || rc=$?
  expect_code 0 "$rc" "the excluding round reaches pass"
  file=$(receipt_of "$d" clean)
  [ "$(receipt_exclusions "$file")" = "src/gen/**
src/a.ts" ] \
    || fail "the receipt must record both the contract's exclusions and the one this run added: $(receipt_exclusions "$file")"
  "$ROOT/bin/fm-quality-receipt.sh" validate "$file" >/dev/null \
    || fail "a receipt carrying exclusions must still satisfy the committed schema"
  pass "the receipt records the exclude list the run was measured against"
}

# The twin: the same contract measured with no round adding anything must record
# only the contract's own entry, so the field cannot be a constant.
test_the_receipt_records_no_exclusion_that_was_not_made() {
  local d file rc=0
  d=$(new_case receipt-exclusions-untouched)
  write_contract "$d" "$EXCLUDE_CONTRACT"
  write_meta "$d" hardened
  FMQ_TURN_ACTION=tested run_quality "$d" run task --phase clean >/dev/null || rc=$?
  expect_code 1 "$rc" "a run nobody excluded anything in stays below threshold"
  file=$(receipt_of "$d" clean)
  [ "$(receipt_exclusions "$file")" = "src/gen/**" ] \
    || fail "the receipt must record only the contract's own exclusion: $(receipt_exclusions "$file")"
  pass "a run that excluded nothing records only the contract's own exclusions"
}

# Every exit that skips the ordinary suite's verdict still owes the task copy a
# revert. A half-finished edit no test ever saw would otherwise sit uncommitted,
# and the next hardened run refuses on a dirty tree until a human cleans it.
test_a_failed_turn_leaves_no_half_finished_work() {
  local d out rc=0
  d=$(new_case turn-failed-dirty)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  out=$(FMQ_IDS_MODE=static FMQ_TURN_DIRTY="$d/wt/half-done.txt" FMQ_CLAUDE_TURN_FAILS=1 \
    run_quality "$d" run task --phase clean) || rc=$?
  expect_code 3 "$rc" "a harness that could not run is blocked"
  assert_contains "$out" "outcome: blocked" "a turn that never finished is could-not-measure"
  assert_absent "$d/wt/half-done.txt" "the half-finished edit must not survive the round"
  assert_clean_worktree "$d" "a blocked turn"
  pass "a turn that ends the phase by failing reverts its half-finished work"
}

# The sibling exit: the prompt tells a defect report to change nothing, and the
# loop enforces that rather than trusting it.
test_a_defect_report_leaves_no_half_finished_work() {
  local d out rc=0
  d=$(new_case defect-dirty)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  out=$(FMQ_IDS_MODE=static FMQ_TURN_DIRTY="$d/wt/half-done.txt" FMQ_TURN_ACTION=defect-found \
    run_quality "$d" run task --phase clean) || rc=$?
  expect_code 5 "$rc" "an agent-reported defect exits 5"
  assert_contains "$out" "outcome: defect-found" "the defect still ends the phase"
  assert_absent "$d/wt/half-done.txt" "a defect report that also edited must not leave the edit"
  assert_clean_worktree "$d" "a defect-found turn"
  pass "a defect report reverts anything the turn changed on its way out"
}

# The twin for both: a round the ordinary suite approves must keep its work, so
# neither case above can be satisfied by reverting every round.
test_an_approved_round_keeps_its_work() {
  local d rc=0 kept
  d=$(new_case round-kept)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  FMQ_IDS_MODE=shrinking FMQ_TURN_DIRTY="$d/wt/kept.txt" \
    run_quality "$d" run task --phase clean >/dev/null || rc=$?
  expect_code 1 "$rc" "the rounds run out below threshold"
  assert_present "$d/wt/kept.txt" "a round the suite approved keeps its work"
  kept=$(git -C "$d/wt" log --oneline -- kept.txt | wc -l)
  [ "$kept" -gt 0 ] || fail "the approved round's work must be committed, not left loose"
  assert_clean_worktree "$d" "an approved round"
  pass "a round the ordinary suite approves keeps and commits its work"
}

# The contract pins the bar inside .quality-gate.yaml, but the phase command is
# a script in the same repo the agent can edit. A receipt judged against some
# other number is not evidence about this contract's bar.
test_a_receipt_judged_against_another_bar_is_blocked() {
  local d out rc=0
  d=$(new_case threshold-receipt-drift)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  out=$(FMQ_OUTCOME=pass FMQ_FORCE_THRESHOLD='{"crap_max": 9999}' \
    run_quality "$d" run task --phase clean) || rc=$?
  expect_code 3 "$rc" "a receipt judged against another bar is blocked"
  assert_contains "$out" "outcome: blocked" "the wrong bar is could-not-measure"
  assert_contains "$out" "crap_max=9999" "the refusal names the bar the receipt used"
  assert_not_contains "$out" "outcome: pass" "a self-declared bar never earns a pass"
  assert_absent "$(receipt_of "$d" clean)" "no receipt is filed for a bar nobody configured"
  pass "a receipt judged against a bar the contract never set is blocked"
}

# The twin: the same number written the other way is the same bar, so the check
# has to compare numerically rather than by text.
test_the_same_bar_written_differently_still_passes() {
  local d rc=0
  d=$(new_case threshold-same-number)
  write_contract "$d" "${STD_CONTRACT/crap_max: 15/crap_max: 15.0}"
  write_meta "$d" hardened
  FMQ_OUTCOME=pass run_quality "$d" run task --phase clean >/dev/null || rc=$?
  expect_code 0 "$rc" "15.0 and 15 are the same bar"
  pass "a threshold written 15.0 against a receipt's 15 is the same bar, not drift"
}

# The receipt has to record the whole surface the run skipped, so an engine that
# narrows the diff for itself is not silently dropped from the durable proof.
test_the_receipt_keeps_the_engines_own_exclusions() {
  local d file rc=0
  d=$(new_case receipt-engine-exclusions)
  write_contract "$d" "$EXCLUDE_CONTRACT"
  write_meta "$d" hardened
  FMQ_ENGINE_EXCLUDES='**/*.d.ts' FMQ_TURN_ACTION=excluded FMQ_TURN_EXCLUDE=src/a.ts \
    run_quality "$d" run task --phase clean >/dev/null || rc=$?
  expect_code 0 "$rc" "the excluding round reaches pass"
  file=$(receipt_of "$d" clean)
  [ "$(receipt_exclusions "$file")" = "src/gen/**
src/a.ts
**/*.d.ts" ] \
    || fail "the receipt must union the contract's list with the engine's: $(receipt_exclusions "$file")"
  "$ROOT/bin/fm-quality-receipt.sh" validate "$file" >/dev/null \
    || fail "the merged exclusions must still satisfy the committed schema"
  pass "the receipt unions the engine's own exclusions with the contract's"
}

# A passing receipt from an earlier head still counts - the pipeline commits
# after the pre-flight loop by design - but a caller must be able to see the
# drift from the verdict token alone.
test_status_marks_a_receipt_from_an_earlier_head() {
  local d out
  d=$(new_case status-stale-head)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  FMQ_OUTCOME=pass run_quality "$d" run task --phase clean >/dev/null \
    || fail "the measuring run should pass"
  out=$(run_quality "$d" status task)
  case "$out" in
    "quality: satisfied "*) : ;;
    *) fail "a receipt at the current head is plain satisfied: $out" ;;
  esac
  git -C "$d/wt" commit -q --allow-empty -m "a later fix round"
  out=$(run_quality "$d" status task)
  case "$out" in
    "quality: satisfied-stale "*) : ;;
    *) fail "a receipt from an earlier head needs its own token: $out" ;;
  esac
  assert_contains "$out" "$(git -C "$d/wt" rev-parse HEAD)" "the detail names the current commit"
  pass "status reports satisfied-stale once HEAD moves past the receipt"
}

# The schema lets a receipt abbreviate the head it measured, so a conforming
# engine that records `git rev-parse --short HEAD` must not read as drift. The
# comparison is over the shorter value's own length, not raw string equality.
test_an_abbreviated_head_is_the_same_commit() {
  local d out short
  d=$(new_case status-short-head)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  short=$(git -C "$d/wt" rev-parse --short=12 HEAD)
  FMQ_OUTCOME=pass FMQ_FORCE_HEAD="$short" \
    run_quality "$d" run task --phase clean >/dev/null \
    || fail "a receipt naming the head in short form should still pass"
  [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["head_sha"])' \
    "$(receipt_of "$d" clean)")" = "$short" ] \
    || fail "the fixture must file the abbreviated head it was told to"
  out=$(run_quality "$d" status task)
  case "$out" in
    "quality: satisfied "*) : ;;
    *) fail "an abbreviated head at the current HEAD is not drift: $out" ;;
  esac
  git -C "$d/wt" commit -q --allow-empty -m "a later fix round"
  out=$(run_quality "$d" status task)
  case "$out" in
    "quality: satisfied-stale "*) : ;;
    *) fail "the same abbreviated receipt must go stale once HEAD moves: $out" ;;
  esac
  pass "an abbreviated head_sha reads as the same commit until HEAD moves"
}

# The twin that pins the length discipline: a 12-character sha that shares all
# but its last character with HEAD is a different commit, not a prefix of it.
test_a_near_miss_short_head_is_drift() {
  local d out
  d=$(new_case status-near-miss-head)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  FMQ_OUTCOME=pass run_quality "$d" run task --phase clean >/dev/null \
    || fail "the measuring run should pass"
  set_receipt_sha "$(receipt_of "$d" clean)" head_sha \
    "$(near_miss_sha "$(git -C "$d/wt" rev-parse HEAD)")"
  out=$(run_quality "$d" status task)
  case "$out" in
    "quality: satisfied-stale "*) : ;;
    *) fail "a short sha that is not a prefix of HEAD is drift: $out" ;;
  esac
  pass "a near-miss short sha reads as drift, not as the same commit"
}

# The sibling comparison in the same verdict: an abbreviated base_sha names the
# same base commit too, and must not read as an unreadable receipt.
test_an_abbreviated_base_is_the_same_commit() {
  local d out
  d=$(new_case status-short-base)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  FMQ_OUTCOME=pass run_quality "$d" run task --phase clean >/dev/null \
    || fail "the measuring run should pass"
  set_receipt_sha "$(receipt_of "$d" clean)" base_sha \
    "$(git -C "$d/wt" rev-parse --short=12 HEAD)"
  out=$(run_quality "$d" status task)
  case "$out" in
    "quality: satisfied "*) : ;;
    *) fail "an abbreviated base commit is the same base commit: $out" ;;
  esac
  set_receipt_sha "$(receipt_of "$d" clean)" base_sha \
    "$(near_miss_sha "$(git -C "$d/wt" rev-parse HEAD)")"
  out=$(run_quality "$d" status task)
  case "$out" in
    "quality: unreadable "*) : ;;
    *) fail "a base commit that is not this task's is still unreadable: $out" ;;
  esac
  pass "an abbreviated base_sha names the same base commit, a near miss does not"
}

# The base commit is compared by the same rule as the head: a conforming engine
# may abbreviate it, and refusing that would hard-block the gate for the whole
# run rather than only mislabelling a status line.
test_an_abbreviated_base_in_the_measurement_is_accepted() {
  local d out rc=0
  d=$(new_case measure-short-base)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  out=$(FMQ_OUTCOME=pass FMQ_FORCE_BASE="$(git -C "$d/wt" rev-parse --short=12 HEAD)" \
    run_quality "$d" run task --phase clean) || rc=$?
  expect_code 0 "$rc" "an abbreviated base commit is this task's base commit"
  assert_contains "$out" "outcome: pass" "the run measures and passes"
  assert_not_contains "$out" "outcome: blocked" "an abbreviation is not drift"
  pass "a measurement naming the base commit in short form is accepted"
}

# The twin: a 12-character sha that shares all but its last character with the
# base is a different commit, and the run still refuses it as drift.
test_a_near_miss_base_in_the_measurement_is_drift() {
  local d out rc=0
  d=$(new_case measure-near-miss-base)
  write_contract "$d" "$STD_CONTRACT"
  write_meta "$d" hardened
  out=$(FMQ_OUTCOME=pass FMQ_FORCE_BASE="$(near_miss_sha "$(git -C "$d/wt" rev-parse HEAD)")" \
    run_quality "$d" run task --phase clean) || rc=$?
  expect_code 3 "$rc" "a base commit that is not this task's is blocked"
  assert_contains "$out" "outcome: blocked" "a near miss is could-not-measure"
  assert_contains "$out" "measured against" "the refusal names the base it was given"
  assert_not_contains "$out" "outcome: pass" "a different base never earns a pass"
  pass "a measurement naming a near-miss base commit is still refused as drift"
}

test_pass
test_read_only_is_not_pass
test_read_only_cannot_measure_is_blocked
test_missing_toolchain_is_blocked_not_pass
test_stale_pass_receipt_is_cleared
test_invalid_receipt_is_blocked
test_base_drift_is_blocked
test_red_suite_is_blocked
test_flaky_suite_is_blocked
test_no_contract_is_not_applicable
test_unconfigured_phase_is_not_applicable
test_measured_nothing_is_not_applicable
test_rounds_exhausted
test_no_progress_is_stuck
test_wall_clock_bound_cuts_a_slow_engine_short
test_wall_clock_bound_leaves_a_fast_engine_alone
test_unenforceable_bound_is_blocked
test_command_reported_defect
test_agent_reported_defect_leaves_the_loop
test_green_round_is_committed
test_red_round_is_reverted
test_dirty_worktree_refuses
test_harness_without_a_recipe_refuses
test_structured_output_flag_is_read_from_the_harness
test_status_reports_the_gate_verdict
test_status_on_a_standard_task_requires_nothing
test_receipt_prints_what_was_written
test_dry_run_changes_nothing
test_dry_run_keeps_an_existing_receipt
test_a_round_can_exclude_a_finding
test_without_the_exclude_edit_the_finding_survives
test_receipt_from_another_phase_is_blocked
test_repeated_empty_findings_is_stuck
test_the_suite_recheck_stays_inside_the_bound
test_signal_killed_suite_is_red_without_gnu_timeout
test_perl_host_still_measures_a_green_suite
test_dry_run_files_no_supervision_event
test_a_round_cannot_widen_its_own_threshold
test_an_untouched_threshold_runs_the_rounds_out
test_unreadable_budget_usd_refuses
test_a_readable_budget_usd_is_accepted
test_a_harness_that_cannot_run_is_blocked
test_a_working_harness_that_changes_nothing_is_stuck
test_the_receipt_records_what_was_excluded
test_the_receipt_records_no_exclusion_that_was_not_made
test_a_failed_turn_leaves_no_half_finished_work
test_a_defect_report_leaves_no_half_finished_work
test_an_approved_round_keeps_its_work
test_a_receipt_judged_against_another_bar_is_blocked
test_the_same_bar_written_differently_still_passes
test_the_receipt_keeps_the_engines_own_exclusions
test_status_marks_a_receipt_from_an_earlier_head
test_an_abbreviated_head_is_the_same_commit
test_a_near_miss_short_head_is_drift
test_an_abbreviated_base_is_the_same_commit
test_an_abbreviated_base_in_the_measurement_is_accepted
test_a_near_miss_base_in_the_measurement_is_drift
test_unknown_contract_version_refuses
test_contract_without_verify_refuses
test_missing_base_anchor_is_blocked
test_usage_errors

echo "all fm-quality tests passed"
