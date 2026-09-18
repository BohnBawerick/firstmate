#!/usr/bin/env bash
# Behavior tests for the explicit per-task delivery contract (AGENTS.md section 7)
# across bin/fm-spawn.sh, bin/fm-promote.sh, and bin/fm-project-mode.sh.
#
# A ship task's delivery mode and yolo posture are firstmate's decision at intake,
# so the tools refuse to guess: the spawn and a scout promotion require both flags,
# validate them against a closed set, and the spawn additionally refuses to launch
# when the brief it is about to hand the worker records a different mode. Scout
# spawns carry no delivery posture at all. The registry keeps only the captain's
# standing posture, for the mechanical consumers and for one advisory notice.
#
# The delivery-check cases stop before any endpoint exists: those checks run ahead
# of backend creation, and a fake `tmux` that exits non-zero backstops the cases
# that are meant to get past them, so no window or worktree is ever created. The
# metadata and standing-posture cases are the opposite on purpose: make_spawning_home
# builds a real git worktree and a fake `tmux` that exits 0 and answers the
# pane-path query, so run_spawning carries a ship spawn all the way to its durable
# record. Those cases really do create things, including /tmp/fm-<id> outside
# TMP_ROOT, so they own the teardown in delivery_cleanup below.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
BRIEF="$ROOT/bin/fm-brief.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-delivery)

# A spawn that gets all the way to metadata also creates /tmp/fm-<id>, which is
# outside TMP_ROOT and therefore outside fm_test_tmproot's cleanup. Track and
# remove each one so this suite leaks nothing on a shared host.
#
# The tracking goes through a `$$`-keyed file, not an array, for the reason
# tests/lib.sh gives under "self-cleaning temp root": every spawn here is invoked
# as `out=$(run_spawning ...)`, which forks a subshell, so an array append made
# inside it dies with that subshell and never reaches this shell. `$$` stays the
# invoking shell's PID across that boundary, so the file does reach cleanup.
#
# This trap replaces the shared EXIT trap tests/lib.sh arms at source time, so it
# ends by calling fm_test_cleanup itself: TMP_ROOT and lib.sh's own registry still
# go, and they go on the failing path too, because fail() exits.
SPAWNED_TASK_REGISTRY=$(mktemp "${TMPDIR:-/tmp}/.fm-task-delivery-tmps.$$.XXXXXX")
track_spawned_task_tmp() {  # <dir>
  printf '%s\n' "$1" >> "$SPAWNED_TASK_REGISTRY" 2>/dev/null || true
}
delivery_cleanup() {
  local d
  if [ -f "$SPAWNED_TASK_REGISTRY" ]; then
    while IFS= read -r d; do
      [ -z "$d" ] || rm -rf "$d"
    done < "$SPAWNED_TASK_REGISTRY"
    rm -f "$SPAWNED_TASK_REGISTRY"
  fi
  fm_test_cleanup
}
trap delivery_cleanup EXIT
trap 'delivery_cleanup; exit 130' INT
trap 'delivery_cleanup; exit 143' TERM

# A home with one registered project, one project directory, and a fake tmux that
# refuses, so a spawn that clears the delivery checks still creates nothing.
# Echoes "<home>|<project-dir>|<fakebin>".
make_home() {  # <name> [<registry-line>...]
  local name=$1 home projects fakebin
  shift
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/proj" "$fakebin"
  git -C "$projects/proj" init -q || fail "could not initialize project fixture"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$home/data/projects.md"
  fi
  printf '%s\n' "$home|$projects/proj|$fakebin"
}

write_brief() {  # <home> <id> [<recorded-mode>] [<recorded-quality>]
  local home=$1 id=$2 mode=${3:-} quality=${4:-}
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Task\n## Captain'\''s intent\nExercise the delivery contract.\n\n## Firstmate spec\nVerify the selected delivery behavior.\n\n# Definition of done\n'
    [ -z "$mode" ] || printf 'Delivery contract: mode=%s\n' "$mode"
    [ -z "$quality" ] || printf 'Quality contract: quality=%s\n' "$quality"
  } > "$home/data/$id/brief.md"
}

fill_brief_subsections() {  # <file> <intent> <spec>
  local file=$1 intent=$2 spec=$3 content
  content=$(cat "$file")
  content=${content//'{TASK}'/$intent}
  content=${content//'{FIRSTMATE_SPEC}'/$spec}
  printf '%s\n' "$content" > "$file"
}

run_spawn() {  # <home> <fakebin> <spawn-args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

# A ship spawn must stop when its delivery contract was never decided or cannot be
# a task mode, and must leave no task metadata behind when it does.
test_ship_spawn_requires_a_valid_delivery_contract() {
  local rec home proj fakebin label flags expect out status n=0
  rec=$(make_home required)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  while IFS='|' read -r label flags expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    write_brief "$home" "delivery-required-$n" no-mistakes
    # shellcheck disable=SC2086  # flags is an intentional word-split arg list
    out=$(run_spawn "$home" "$fakebin" "delivery-required-$n" "$proj" claude $flags)
    status=$?
    [ "$status" -ne 0 ] || fail "$label: expected a non-zero exit"
    assert_contains "$out" "$expect" "$label: refusal did not explain the contract"
    assert_absent "$home/state/delivery-required-$n.meta" "$label: refused spawn wrote task metadata"
  done <<'ROWS'
missing both flags||ship spawns require --mode
missing --yolo|--mode no-mistakes|ship spawns require --yolo
missing --mode|--yolo off|ship spawns require --mode
unknown mode|--mode nope --yolo off|must be one of no-mistakes, direct-PR, local-only
unknown yolo|--mode no-mistakes --yolo maybe|--yolo must be on or off
conditional policy as a task mode|--mode no-mistakes-prod-only --yolo off|classify this task's surface
ROWS
  pass "fm-spawn: a ship spawn requires a valid explicit mode and yolo before anything is created"
}

# A scout has no merge to govern and a secondmate's posture is fixed, so the flags
# are refused rather than accepted and quietly ignored.
test_scout_and_secondmate_refuse_delivery_flags() {
  local rec home proj fakebin out status
  rec=$(make_home refused)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scout-a1

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --mode direct-PR)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --mode should exit non-zero"
  assert_contains "$out" "--mode applies only to ship spawns" "scout spawn did not refuse --mode"

  out=$(run_spawn "$home" "$fakebin" delivery-scout-a1 "$proj" claude --scout --yolo on)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --yolo should exit non-zero"
  assert_contains "$out" "--yolo applies only to ship spawns" "scout spawn did not refuse --yolo"

  out=$(run_spawn "$home" "$fakebin" delivery-sm-a2 "$home" --secondmate --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn carrying delivery flags should exit non-zero"
  assert_contains "$out" "applies only to ship spawns" "secondmate spawn did not refuse the delivery flags"
  pass "fm-spawn: scout and secondmate spawns refuse ship delivery flags"
}

# The brief is what the worker actually follows, so a spawn whose explicit mode
# disagrees with the brief's recorded contract must refuse instead of launching a
# worker whose instructions contradict the recorded task delivery.
test_spawn_refuses_a_brief_mode_mismatch() {
  local rec home proj fakebin out status
  rec=$(make_home agreement)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-mismatch-b1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" delivery-mismatch-b1 "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a brief/spawn mode mismatch should exit non-zero"
  assert_contains "$out" "delivery mismatch for delivery-mismatch-b1" "mismatch refusal did not name the task"
  assert_contains "$out" "the brief says mode=no-mistakes but this spawn passed --mode direct-PR" \
    "mismatch refusal did not show both sides of the disagreement"
  assert_absent "$home/state/delivery-mismatch-b1.meta" "mismatched spawn wrote task metadata"

  # The agreeing case clears the check and only fails later, at the refusing tmux.
  write_brief "$home" delivery-agree-b2 direct-PR
  out=$(run_spawn "$home" "$fakebin" delivery-agree-b2 "$proj" claude --mode direct-PR --yolo off)
  assert_not_contains "$out" "delivery mismatch" "an agreeing mode was reported as a mismatch"

  # A brief scaffolded before the contract line existed warns once and continues.
  write_brief "$home" delivery-legacy-b3
  out=$(run_spawn "$home" "$fakebin" delivery-legacy-b3 "$proj" claude --mode local-only --yolo off)
  assert_contains "$out" "records no delivery contract line" "a legacy brief did not warn about its missing contract"
  assert_not_contains "$out" "delivery mismatch" "a legacy brief was treated as a mismatch"
  pass "fm-spawn: the brief's recorded mode and the spawn's explicit mode must agree"
}

# The registry is the captain's standing posture, so dropping below its rigor is
# allowed but never silent, while matching or exceeding it stays quiet. An
# unregistered project resolves to the same no-mistakes standing default
# (AGENTS.md section 7), so a downgrade there is announced too. A conditional
# policy is excluded because both of its legs are legitimate classifications.
test_spawn_notices_a_rigor_downgrade_against_the_registry() {
  local rec home proj fakebin out label mode registry expect registered n=0
  while IFS='|' read -r label registry mode expect registered; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    rec=$(make_home "deviation-$n" "$registry")
    IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
    write_brief "$home" "delivery-dev-$n" "$mode"
    out=$(run_spawn "$home" "$fakebin" "delivery-dev-$n" "$proj" claude --mode "$mode" --yolo off)
    case "$expect" in
      notice)
        assert_contains "$out" "less rigor than the captain's standing posture" \
          "$label: no deviation notice for a rigor downgrade"
        assert_contains "$out" "the standing posture for proj is $registered" \
          "$label: notice did not name the standing posture it compared against" ;;
      quiet)
        assert_not_contains "$out" "less rigor than the captain's standing posture" \
          "$label: printed a deviation notice that is not a downgrade" ;;
    esac
  done <<'ROWS'
no-mistakes project shipped direct-PR|- proj [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
no-mistakes project shipped local-only|- proj [no-mistakes] - fixture (added 2026-01-01)|local-only|notice|no-mistakes
no-mistakes project shipped no-mistakes|- proj [no-mistakes] - fixture (added 2026-01-01)|no-mistakes|quiet|no-mistakes
local-only project shipped no-mistakes|- proj [local-only] - fixture (added 2026-01-01)|no-mistakes|quiet|local-only
conditional policy shipped direct-PR|- proj [no-mistakes-prod-only] - fixture (added 2026-01-01)|direct-PR|quiet|no-mistakes-prod-only
unregistered project resolves to the no-mistakes standing default|- other [no-mistakes] - fixture (added 2026-01-01)|direct-PR|notice|no-mistakes
ROWS
  pass "fm-spawn: a rigor downgrade against the registered posture is announced, never blocked"
}

# A scout's deliverable is a report, so it records no delivery posture at all;
# teardown already treats an absent mode as the most protective one.
test_scout_records_no_delivery_posture() {
  local rec home proj fakebin out
  rec=$(make_home scout-meta "- proj [direct-PR] - fixture (added 2026-01-01)")
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" delivery-scoutmeta-c1
  out=$(run_spawn "$home" "$fakebin" delivery-scoutmeta-c1 "$proj" claude --scout)
  assert_not_contains "$out" "less rigor" "a scout spawn consulted the registered delivery posture"
  assert_not_contains "$out" "delivery mismatch" "a scout spawn checked a delivery contract it does not carry"
  pass "fm-spawn: a scout spawn resolves no delivery posture from the registry"
}

# Promotion is where a scout's ship contract is finally decided, so it requires the
# same explicit values and writes them into the task's durable record.
test_promote_requires_and_records_the_delivery_contract() {
  local home meta out status blocked_data instructions_path
  home="$TMP_ROOT/promote/home"
  mkdir -p "$home/state"
  meta="$home/state/promote-d1.meta"
  write_brief "$home" promote-d1

  write_scout_meta() {
    printf 'window=fm-promote-d1\nkind=scout\nworktree=/tmp/wt\n' > "$meta"
  }

  write_scout_meta
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without --mode should exit non-zero"
  assert_contains "$out" "promotion requires --mode" "promote refusal did not name the missing mode"
  assert_grep 'kind=scout' "$meta" "refused promotion still changed the task record"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without --yolo should exit non-zero"
  assert_contains "$out" "promotion requires --yolo" "promote refusal did not name the missing merge posture"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode no-mistakes-prod-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion on a conditional policy should exit non-zero"
  assert_contains "$out" "classify this task's surface" "promote did not refuse the conditional policy as a task mode"

  blocked_data="$home/data-blocked"
  printf 'not a directory\n' > "$blocked_data"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$blocked_data" \
    "$PROMOTE" promote-d1 --mode direct-PR --yolo on 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without writable instruction storage should exit non-zero"
  assert_grep 'kind=scout' "$meta" "failed instruction publication still promoted the task"
  assert_no_grep '^mode=' "$meta" "failed instruction publication recorded a delivery mode"
  assert_no_grep '^yolo=' "$meta" "failed instruction publication recorded a merge posture"

  instructions_path="$home/data/promote-d1/ship-instructions.md"
  mkdir -p "$instructions_path"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" promote-d1 --mode direct-PR --yolo on 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion over an instruction directory should exit non-zero"
  assert_contains "$out" "ship instructions path is a directory" \
    "promotion did not explain the invalid instruction destination"
  assert_grep 'kind=scout' "$meta" "invalid instruction destination still promoted the task"
  assert_no_grep '^mode=' "$meta" "invalid instruction destination recorded a delivery mode"
  assert_no_grep '^yolo=' "$meta" "invalid instruction destination recorded a merge posture"
  rmdir "$instructions_path"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR --yolo on 2>&1)
  status=$?
  expect_code 0 "$status" "a promotion carrying both flags should succeed"
  assert_grep 'kind=ship' "$meta" "promotion did not restore ship teardown protection"
  assert_grep 'mode=direct-PR' "$meta" "promotion did not record the decided delivery mode"
  assert_grep 'yolo=on' "$meta" "promotion did not record the decided merge posture"
  assert_contains "$out" "ship instructions for mode=direct-PR" "promotion hint did not carry the decided mode"
  [ "$(grep -c '^mode=' "$meta")" = 1 ] || fail "promotion left more than one mode= line in the task record"
  pass "fm-promote: promotion requires the delivery contract and records it exactly once"
}

# A promoted task carries no quality posture at all, so the registry's standing
# posture is announced rather than silently lost. Advisory only: the promotion still
# happens, and a record with no project= to look up promotes quietly.
test_promote_notices_the_standing_quality_posture() {
  local home meta out status
  home="$TMP_ROOT/promote-quality/home"
  mkdir -p "$home/state" "$home/data"

  run_promote() {  # <id>
    write_brief "$home" "$1"
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      "$PROMOTE" "$1" --mode direct-PR --yolo on 2>&1
  }

  # 1. A hardened project: the notice fires and the promotion still lands.
  printf '%s\n' '- proj [no-mistakes +hardened] - fixture (added 2026-01-01)' > "$home/data/projects.md"
  meta="$home/state/promote-q1.meta"
  printf 'window=fm-promote-q1\nkind=scout\nworktree=/tmp/wt\nproject=%s/projects/proj\n' "$home" > "$meta"
  out=$(run_promote promote-q1)
  status=$?
  expect_code 0 "$status" "the quality notice must not block a promotion"$'\n'"$out"
  assert_contains "$out" "the standing posture for proj is hardened" \
    "no notice when a hardened project's scout was promoted"
  assert_grep 'kind=ship' "$meta" "the announced promotion did not restore ship teardown protection"
  assert_grep 'mode=direct-PR' "$meta" "the announced promotion did not record the decided delivery mode"
  assert_grep 'yolo=on' "$meta" "the announced promotion did not record the decided approval posture"
  assert_no_grep 'quality=' "$meta" "a promoted task recorded a quality posture it cannot anchor"
  assert_no_grep 'base_sha=' "$meta" "a promoted task recorded a base commit it cannot capture"

  # 2. The same promotion against a project with no +hardened token stays quiet.
  printf '%s\n' '- proj [no-mistakes] - fixture (added 2026-01-01)' > "$home/data/projects.md"
  meta="$home/state/promote-q2.meta"
  printf 'window=fm-promote-q2\nkind=scout\nworktree=/tmp/wt\nproject=%s/projects/proj\n' "$home" > "$meta"
  out=$(run_promote promote-q2)
  status=$?
  expect_code 0 "$status" "a standard project's promotion should succeed"$'\n'"$out"
  assert_not_contains "$out" "standing posture" \
    "a project with no registered quality posture printed a notice"

  # 3. A record with no project= line has nothing to look up and promotes silently.
  printf '%s\n' '- proj [no-mistakes +hardened] - fixture (added 2026-01-01)' > "$home/data/projects.md"
  meta="$home/state/promote-q3.meta"
  printf 'window=fm-promote-q3\nkind=scout\nworktree=/tmp/wt\n' > "$meta"
  out=$(run_promote promote-q3)
  status=$?
  expect_code 0 "$status" "a promotion with no project= should still succeed"$'\n'"$out"
  assert_not_contains "$out" "standing posture" \
    "a record with no project= resolved a standing posture from somewhere"
  assert_grep 'kind=ship' "$meta" "a promotion with no project= did not rewrite the record"
  pass "fm-promote: a hardened standing posture is announced on promotion, never blocked"
}

# A symlink at state/<id>.meta is the containment hazard the shared publisher
# refuses: promotion must not rewrite the symlink target in place.
test_promote_refuses_a_symlinked_task_record() {
  local home meta target original out status leftover
  home="$TMP_ROOT/promote-symlink/home"
  mkdir -p "$home/state"
  meta="$home/state/promote-sym.meta"
  target="$TMP_ROOT/promote-symlink/foreign-task-record"
  original="$TMP_ROOT/promote-symlink/foreign-task-record.expected"
  printf '%s\n' 'window=fm-promote-sym' 'kind=scout' 'worktree=/tmp/wt' > "$target"
  cp "$target" "$original"
  ln -s "$target" "$meta"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$PROMOTE" promote-sym --mode direct-PR --yolo on 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion through a symlink record should refuse"
  assert_contains "$out" "task record" "promotion did not identify the unpublished task record"
  [ -L "$meta" ] || fail "promotion replaced or removed the symlink record"
  cmp -s "$target" "$original" \
    || fail "promotion rewrote the symlink target in place"
  assert_absent "$home/data/promote-sym/ship-instructions.md" \
    "refused promotion published ship instructions"
  leftover=$(find "$home/state" -maxdepth 1 -name '.*.meta.promote.*' -print 2>/dev/null || true)
  [ -z "$leftover" ] || fail "promotion left a staging file after a refused publish: $leftover"
  pass "fm-promote: a symlinked task record is refused and its target is left untouched"
}

# The delivery contract only protects a worker that actually receives it. A promoted
# scout used to get a free-form hint instead of the mode-specific Definition of done,
# so it never saw the ask-user escalation rule or the --yes ban that every briefed
# no-mistakes worker gets. This drives the real promotion path, then runs the delivery command it
# prints against a capturing fm-send.sh, and asserts on the message the worker would
# actually receive - for every supported mode.
test_promotion_delivers_the_real_definition_of_done() {
  local home meta out sendroot payload mode id brief_dod delivered_dod
  home="$TMP_ROOT/promote-dod/home"
  sendroot="$TMP_ROOT/promote-dod/sendroot"
  mkdir -p "$home/state" "$sendroot/bin"
  cat > "$sendroot/bin/fm-send.sh" <<'STUB'
#!/usr/bin/env bash
# Capture the message a promoted worker would receive, instead of steering one.
printf '%s' "$2" > "$FM_TEST_CAPTURE"
STUB
  chmod +x "$sendroot/bin/fm-send.sh"

  for mode in no-mistakes direct-PR local-only; do
    id="promote-dod-$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
    meta="$home/state/$id.meta"
    printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$meta"
    FM_HOME="$home" "$BRIEF" "$id" fixture-project --scout >/dev/null 2>&1 \
      || fail "$mode: scout brief generation should succeed"
    fill_brief_subsections "$home/data/$id/brief.md" \
      "Ship the delivery-contract change." "Preserve the selected delivery mode."
    out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" --mode "$mode" --yolo off 2>&1) \
      || fail "$mode: promotion should succeed"

    payload="$TMP_ROOT/promote-dod/payload-$id"
    # Run the delivery command promotion printed, so the assertions below are made
    # against the message the worker receives rather than the script's own text.
    ( cd "$sendroot" \
      && FM_TEST_CAPTURE="$payload" \
         eval "$(printf '%s\n' "$out" | sed -n 's/^next: //p' | grep 'fm-send\.sh')" ) \
      || fail "$mode: promotion's delivery command did not run"
    assert_present "$payload" "$mode: promotion delivered no message to the worker"

    grep -qx "Delivery contract: mode=$mode" "$payload" \
      || fail "$mode: promoted worker did not receive the machine-readable delivery contract"
    assert_grep "# Definition of done" "$payload" \
      "$mode: promoted worker did not receive a Definition of done"
    assert_grep "pwd -P" "$payload" \
      "$mode: promoted worker was not told to verify its physical worktree"
    assert_grep "git rev-parse --show-toplevel" "$payload" \
      "$mode: promoted worker was not told to verify its repository root"
    assert_grep "If either does not resolve to the worktree you were launched in, stop and escalate to firstmate" "$payload" \
      "$mode: promoted worker was not told to stop for any wrong worktree"
    assert_grep "git checkout -b fm/$id" "$payload" \
      "$mode: promoted worker was not told to leave the scratch base for its ship branch"
    assert_grep "## Captain's intent" "$payload" \
      "$mode: promoted worker did not receive the Captain's intent subsection"
    assert_grep "## Firstmate spec" "$payload" \
      "$mode: promoted worker did not receive the Firstmate spec subsection"

    # Compare the public outputs of both real generation paths. The promoted
    # payload ends at its Definition of done, as does an ordinary generated
    # brief, so identical suffixes prove both workers receive the same contract.
    FM_HOME="$home/ordinary" "$BRIEF" "$id" fixture-project --mode "$mode" >/dev/null 2>&1 \
      || fail "$mode: ordinary ship brief generation should succeed"
    brief_dod="$TMP_ROOT/promote-dod/brief-dod-$id"
    delivered_dod="$TMP_ROOT/promote-dod/delivered-dod-$id"
    awk '/^# Definition of done$/ { emit=1 } emit' "$home/ordinary/data/$id/brief.md" > "$brief_dod"
    awk '/^# Definition of done$/ { emit=1 } emit' "$payload" > "$delivered_dod"
    cmp -s "$brief_dod" "$delivered_dod" \
      || fail "$mode: promotion and ordinary brief generation delivered different Definitions of done"
  done

  payload="$TMP_ROOT/promote-dod/payload-promote-dod-no-mistakes"
  assert_grep "ask-user findings are never yours to answer: escalate to firstmate" "$payload" \
    "promoted no-mistakes worker did not receive the ask-user escalation rule"
  assert_grep "write only the ask-user findings, verbatim and unparaphrased (id, severity, file, line, description, authority)" "$payload" \
    "promoted no-mistakes worker did not receive the ask-user-only snapshot contract"
  assert_grep 'needs-decision [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file='"$home/data/promote-dod-no-mistakes/nm-<run>-findings.txt" "$payload" \
    "promoted no-mistakes worker did not receive the structured escalation event"
  assert_grep "NEVER pass \`--yes\` (or \`-y\`)" "$payload" \
    "promoted no-mistakes worker did not receive the --yes prohibition"
  assert_grep "It is banned fleet-wide" "$payload" \
    "promoted no-mistakes worker did not receive the fleet-wide ban wording"

  payload="$TMP_ROOT/promote-dod/payload-promote-dod-direct-pr"
  assert_grep "supersede the scout delivery rules and report-based Definition of done" "$payload" \
    "promoted worker retained the scout delivery contract"
  assert_grep "status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; and every safety rule" "$payload" \
    "promoted worker lost the scout protocols and safety rules that still apply"

  # The faster paths keep their own contracts rather than inheriting the pipeline's.
  assert_grep "Do NOT run the no-mistakes pipeline." "$payload" \
    "promoted direct-PR worker lost its no-pipeline contract"
  assert_grep "Do NOT push, do NOT open a PR, do NOT merge" "$TMP_ROOT/promote-dod/payload-promote-dod-local-only" \
    "promoted local-only worker lost its no-remote contract"
  assert_no_grep "no-mistakes axi respond" "$TMP_ROOT/promote-dod/payload-promote-dod-direct-pr" \
    "promoted direct-PR worker received the pipeline gate contract"
  pass "fm-promote: a promoted worker receives the same mode-specific delivery contract a briefed one does"
}

# The registry parser survives for the mechanical consumers only. It accepts the
# conditional policy, maps it to its most rigorous leg for them, and exposes the
# raw annotation for the one caller that must tell a policy from a flat mode.
test_project_mode_maps_the_conditional_policy() {
  local home out err
  home="$TMP_ROOT/project-mode/home"
  mkdir -p "$home/data"
  cat > "$home/data/projects.md" <<'EOF'
- prodproj [no-mistakes-prod-only] - fixture (added 2026-01-01)
- yoloproj [no-mistakes-prod-only +yolo] - fixture (added 2026-01-01)
- flatproj [direct-PR] - fixture (added 2026-01-01)
- typoproj [no-mistakez] - fixture (added 2026-01-01)
EOF
  out=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "conditional policy did not map to its most rigorous leg (got '$out')"
  err=$(FM_HOME="$home" "$PROJECT_MODE" prodproj 2>&1 >/dev/null)
  [ -z "$err" ] || fail "a registered conditional policy still warned as unknown: $err"

  out=$(FM_HOME="$home" "$PROJECT_MODE" yoloproj 2>/dev/null)
  [ "$out" = "no-mistakes on" ] || fail "conditional policy dropped its +yolo posture (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw prodproj 2>/dev/null)
  [ "$out" = "no-mistakes-prod-only off" ] || fail "--raw did not expose the registered annotation (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw flatproj 2>/dev/null)
  [ "$out" = "direct-PR off" ] || fail "--raw altered a flat registered mode (got '$out')"

  out=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "a typo'd mode no longer falls back to the most rigorous default"
  err=$(FM_HOME="$home" "$PROJECT_MODE" typoproj 2>&1 >/dev/null)
  assert_contains "$err" "unknown mode" "a typo'd registry mode stopped warning"
  pass "fm-project-mode: the conditional policy is accepted, mapped for mechanical callers, and readable raw"
}

# The registry's quality posture is the fourth thing a captain can put on a
# project line, and --quality is the only way to read it. Every row here is
# exercised through the real script against a real registry file.
test_project_mode_reads_the_registered_quality_posture() {
  local home out label line expect n=0
  home="$TMP_ROOT/project-quality/home"
  mkdir -p "$home/data"
  while IFS='|' read -r label line expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    printf '%s\n' "$line" > "$home/data/projects.md"
    out=$(FM_HOME="$home" "$PROJECT_MODE" --quality qproj 2>/dev/null)
    [ "$out" = "$expect" ] || fail "$label: --quality printed '$out', expected '$expect'"
  done <<'ROWS'
no annotation at all|- qproj - fixture (added 2026-01-01)|standard
mode only|- qproj [direct-PR] - fixture (added 2026-01-01)|standard
mode and yolo only|- qproj [local-only +yolo] - fixture (added 2026-01-01)|standard
hardened after the mode|- qproj [no-mistakes +hardened] - fixture (added 2026-01-01)|hardened
hardened after mode and yolo|- qproj [direct-PR +yolo +hardened] - fixture (added 2026-01-01)|hardened
hardened between mode and yolo|- qproj [direct-PR +hardened +yolo] - fixture (added 2026-01-01)|hardened
hardened before the mode|- qproj [+hardened local-only +yolo] - fixture (added 2026-01-01)|hardened
hardened on a conditional policy is refused and drops to standard|- qproj [no-mistakes-prod-only +hardened] - fixture (added 2026-01-01)|standard
an unrecognized flag is ignored, not refused|- qproj [direct-PR +from-the-future] - fixture (added 2026-01-01)|standard
ROWS
  # An absent project and an absent registry both resolve to the safe posture
  # rather than inheriting the previous row's answer.
  out=$(FM_HOME="$home" "$PROJECT_MODE" --quality never-registered 2>/dev/null)
  [ "$out" = standard ] || fail "an unregistered project resolved quality '$out', expected standard"
  out=$(FM_HOME="$TMP_ROOT/project-quality/no-such-home" "$PROJECT_MODE" --quality qproj 2>/dev/null)
  [ "$out" = standard ] || fail "an absent registry resolved quality '$out', expected standard"
  pass "fm-project-mode: --quality reads +hardened from any bracket position and defaults to standard"
}

# The registry is the only way to turn the quality gate on, so this reader is where
# the registration rule is backed mechanically
# (.agents/skills/project-management/SKILL.md "Delivery posture"). +hardened rides a
# flat mode; alongside the conditional policy it is refused, because a policy that
# decides per task cannot carry one statable quality posture. The refusal follows the
# unknown-mode precedent: warn on stderr, resolve to the safe value, leave the
# two-word stdout its three callers parse alone, and exit 0.
test_project_mode_refuses_hardened_on_the_conditional_policy() {
  local home out err status label line quality words n=0
  home="$TMP_ROOT/project-hardened-policy/home"
  mkdir -p "$home/data"
  while IFS='|' read -r label line quality words; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    printf '%s\n' "$line" > "$home/data/projects.md"
    out=$(FM_HOME="$home" "$PROJECT_MODE" --quality qproj 2>/dev/null)
    status=$?
    expect_code 0 "$status" "$label: --quality exited non-zero"
    [ "$out" = "$quality" ] || fail "$label: --quality printed '$out', expected '$quality'"
    out=$(FM_HOME="$home" "$PROJECT_MODE" qproj 2>/dev/null)
    [ "$out" = "$words" ] || fail "$label: the two-word stdout printed '$out', expected '$words'"
    err=$(FM_HOME="$home" "$PROJECT_MODE" --quality qproj 2>&1 >/dev/null)
    case "$label" in
      refused*)
        assert_contains "$err" "+hardened is refused" "$label: the refused combination printed no warning"
        assert_contains "$err" "flat delivery mode" "$label: the warning did not say how to fix the registry line" ;;
      *)
        assert_not_contains "$err" "+hardened is refused" "$label: a legitimate registry line was warned about" ;;
    esac
  done <<'ROWS'
hardened rides no-mistakes|- qproj [no-mistakes +hardened] - fixture (added 2026-01-01)|hardened|no-mistakes off
hardened rides direct-PR|- qproj [direct-PR +hardened] - fixture (added 2026-01-01)|hardened|direct-PR off
hardened rides local-only|- qproj [local-only +hardened] - fixture (added 2026-01-01)|hardened|local-only off
hardened rides a flat mode with yolo|- qproj [direct-PR +yolo +hardened] - fixture (added 2026-01-01)|hardened|direct-PR on
refused alongside the conditional policy|- qproj [no-mistakes-prod-only +hardened] - fixture (added 2026-01-01)|standard|no-mistakes off
refused alongside the conditional policy with yolo|- qproj [no-mistakes-prod-only +yolo +hardened] - fixture (added 2026-01-01)|standard|no-mistakes on
the conditional policy without hardened stays quiet|- qproj [no-mistakes-prod-only] - fixture (added 2026-01-01)|standard|no-mistakes off
ROWS
  # --raw still reports the registered annotation: only the quality posture drops.
  printf '%s\n' '- qproj [no-mistakes-prod-only +hardened] - fixture (added 2026-01-01)' > "$home/data/projects.md"
  out=$(FM_HOME="$home" "$PROJECT_MODE" --raw qproj 2>/dev/null)
  [ "$out" = "no-mistakes-prod-only off" ] \
    || fail "the refusal changed the raw annotation to '$out', expected 'no-mistakes-prod-only off'"
  pass "fm-project-mode: +hardened rides a flat mode and is refused on the conditional policy"
}

# The load-bearing registry case. Three callers parse this script's two words
# (bin/fm-fleet-sync.sh, bin/fm-home-seed.sh, bin/fm-spawn.sh), so adding the
# quality posture must leave that stdout exactly as it was: still two words, the
# same two words, for every annotation form including the new one.
test_project_mode_two_word_contract_survives_the_quality_posture() {
  local home out label line expect n=0
  home="$TMP_ROOT/project-twoword/home"
  mkdir -p "$home/data"
  while IFS='|' read -r label line expect; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    printf '%s\n' "$line" > "$home/data/projects.md"
    out=$(FM_HOME="$home" "$PROJECT_MODE" qproj 2>/dev/null)
    [ "$out" = "$expect" ] || fail "$label: printed '$out', expected '$expect'"
    [ "$(printf '%s' "$out" | wc -w)" -eq 2 ] || fail "$label: stdout was not exactly two words ('$out')"
    out=$(FM_HOME="$home" "$PROJECT_MODE" --raw qproj 2>/dev/null)
    [ "$(printf '%s' "$out" | wc -w)" -eq 2 ] || fail "$label: --raw stdout was not exactly two words ('$out')"
  done <<'ROWS'
no annotation at all|- qproj - fixture (added 2026-01-01)|no-mistakes off
mode only|- qproj [direct-PR] - fixture (added 2026-01-01)|direct-PR off
mode and yolo|- qproj [local-only +yolo] - fixture (added 2026-01-01)|local-only on
yolo only|- qproj [+yolo] - fixture (added 2026-01-01)|no-mistakes on
conditional policy|- qproj [no-mistakes-prod-only] - fixture (added 2026-01-01)|no-mistakes off
conditional policy with yolo|- qproj [no-mistakes-prod-only +yolo] - fixture (added 2026-01-01)|no-mistakes on
unrecognized flag ignored|- qproj [direct-PR +from-the-future] - fixture (added 2026-01-01)|direct-PR off
hardened does not disturb the mode|- qproj [direct-PR +hardened] - fixture (added 2026-01-01)|direct-PR off
hardened does not disturb mode or yolo|- qproj [local-only +yolo +hardened] - fixture (added 2026-01-01)|local-only on
hardened first still resolves the mode behind it|- qproj [+hardened local-only +yolo] - fixture (added 2026-01-01)|local-only on
ROWS
  # A typo'd mode keeps warning and keeps falling back, rather than being
  # silently rescued by the new flag scan.
  printf '%s\n' "- qproj [no-mistakez +hardened] - fixture (added 2026-01-01)" > "$home/data/projects.md"
  out=$(FM_HOME="$home" "$PROJECT_MODE" qproj 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "a typo'd mode alongside +hardened resolved '$out'"
  out=$(FM_HOME="$home" "$PROJECT_MODE" qproj 2>&1 >/dev/null)
  assert_contains "$out" "unknown mode" "a typo'd mode alongside +hardened stopped warning"
  # The quality posture resolves on its own, so the mode fallback does not take the
  # +hardened down with it: a typo in the mode must not silently drop the gate.
  out=$(FM_HOME="$home" "$PROJECT_MODE" --quality qproj 2>/dev/null)
  [ "$out" = hardened ] \
    || fail "a typo'd mode dropped the registered quality posture to '$out', expected hardened"
  pass "fm-project-mode: the two-word stdout its three callers parse is unchanged by the quality posture"
}

# A scout has no quality loop to run and a charter is not a delivery contract, so
# --quality is refused there rather than accepted and quietly ignored. A ship
# spawn accepts it but validates the value, because a typo must never ship a
# hardened task down the standard path.
test_scout_and_secondmate_refuse_the_quality_flag() {
  local rec home proj fakebin out status
  rec=$(make_home quality-refused)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" quality-scout-g1

  out=$(run_spawn "$home" "$fakebin" quality-scout-g1 "$proj" claude --scout --quality hardened)
  status=$?
  [ "$status" -ne 0 ] || fail "a scout spawn carrying --quality should exit non-zero"
  assert_contains "$out" "--quality applies only to ship spawns" "scout spawn did not refuse --quality"

  out=$(run_spawn "$home" "$fakebin" quality-sm-g2 "$home" --secondmate --quality hardened)
  status=$?
  [ "$status" -ne 0 ] || fail "a secondmate spawn carrying --quality should exit non-zero"
  assert_contains "$out" "--quality applies only to ship spawns" "secondmate spawn did not refuse --quality"

  write_brief "$home" quality-bad-g3 no-mistakes
  out=$(run_spawn "$home" "$fakebin" quality-bad-g3 "$proj" claude --mode no-mistakes --yolo off --quality nope)
  status=$?
  [ "$status" -ne 0 ] || fail "an unknown --quality value should exit non-zero"
  assert_contains "$out" "--quality must be one of standard, hardened" "spawn did not refuse an unknown quality value"
  assert_absent "$home/state/quality-bad-g3.meta" "a refused quality value still wrote task metadata"

  out=$(run_spawn "$home" "$fakebin" quality-bad-g4 "$proj" claude --mode no-mistakes --yolo off --quality)
  status=$?
  [ "$status" -ne 0 ] || fail "an empty --quality value should exit non-zero"
  assert_contains "$out" "requires a value" "spawn did not refuse an empty quality value"
  pass "fm-spawn: --quality is closed-set validated on ship spawns and refused everywhere else"
}

# The brief is what the worker actually follows. A hardened spawn against a brief
# that never carried the quality-gate section, or a standard spawn against a brief
# that tells the worker to run the loop, is the same drift the delivery check
# already prevents - so it refuses in both directions, before anything is created.
test_spawn_refuses_a_brief_quality_mismatch() {
  local rec home proj fakebin out status
  rec=$(make_home quality-agreement)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  # Standard brief (no quality line at all), hardened spawn.
  write_brief "$home" quality-mismatch-h1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" quality-mismatch-h1 "$proj" claude --mode no-mistakes --yolo off --quality hardened)
  status=$?
  [ "$status" -ne 0 ] || fail "a hardened spawn against a standard brief should exit non-zero"
  assert_contains "$out" "quality mismatch for quality-mismatch-h1" "mismatch refusal did not name the task"
  assert_contains "$out" "the brief says quality=standard but this spawn passed --quality hardened" \
    "mismatch refusal did not show both sides of the disagreement"
  assert_absent "$home/state/quality-mismatch-h1.meta" "a mismatched spawn wrote task metadata"

  # Hardened brief, standard (defaulted) spawn.
  write_brief "$home" quality-mismatch-h2 no-mistakes hardened
  out=$(run_spawn "$home" "$fakebin" quality-mismatch-h2 "$proj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a defaulted-standard spawn against a hardened brief should exit non-zero"
  assert_contains "$out" "the brief says quality=hardened but this spawn passed --quality standard" \
    "mismatch refusal did not report the defaulted standard posture"
  assert_absent "$home/state/quality-mismatch-h2.meta" "a mismatched spawn wrote task metadata"

  # Both agreeing forms clear the check and only fail later, at the refusing tmux.
  write_brief "$home" quality-agree-h3 direct-PR hardened
  out=$(run_spawn "$home" "$fakebin" quality-agree-h3 "$proj" claude --mode direct-PR --yolo off --quality hardened)
  assert_not_contains "$out" "quality mismatch" "an agreeing hardened posture was reported as a mismatch"

  write_brief "$home" quality-agree-h4 direct-PR
  out=$(run_spawn "$home" "$fakebin" quality-agree-h4 "$proj" claude --mode direct-PR --yolo off)
  assert_not_contains "$out" "quality mismatch" "a brief with no quality line was not read as standard"
  assert_not_contains "$out" "records no delivery contract line" "a quality-silent brief was reported as a legacy delivery brief"
  pass "fm-spawn: the brief's recorded quality and the spawn's quality must agree in both directions"
}

# A fixture that gets a ship spawn all the way to its durable record: a real git
# worktree, a fake tmux that answers the pane-path query, and a stubbed treehouse.
# Echoes "<home>|<project>|<worktree>|<fakebin>".
make_spawning_home() {  # <name>
  local name=$1 dir home proj wt fakebin
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  proj="$dir/proj"
  wt="$dir/wt"
  fakebin=$(fm_fakebin "$dir/fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '%s\n' "$$" > "$home/state/.lock"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s\n' "$home|$proj|$wt|$fakebin"
}

run_spawning() {  # <home> <worktree> <fakebin> <spawn-args...>
  local home=$1 wt=$2 fakebin=$3
  shift 3
  track_spawned_task_tmp "/tmp/fm-$1"
  # `env -u` keeps the recorded key set hermetic against an ambient
  # FM_TRACE_CONTEXT, which would otherwise add a traceparent= line.
  env -u FM_TRACE_CONTEXT \
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

meta_value() {  # <meta-file> <key>
  sed -n "s/^$2=//p" "$1" | tail -n 1
}

# The quality posture and the base commit have to reach the task's durable record,
# because that record is what the quality loop reads back later. base_sha must be
# the commit the worktree actually starts from - the whole loop measures diffs
# against it - so this asserts it against a real `git rev-parse HEAD`, not a shape.
#
# The load-bearing half is the standard task: a spawn with no --quality must write
# the record it always wrote, with nothing removed, nothing changed, and only the
# two new additive lines present.
test_spawn_records_the_quality_posture_and_base_commit() {
  local rec home proj wt fakebin meta out status base prespawn keys
  rec=$(make_spawning_home quality-meta)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  # The base is the commit the spawn resets the worktree to, which is origin's
  # default tip, NOT the worktree's pre-spawn HEAD. Advance the worktree's own branch
  # first so the two are different objects: a capture taken before the reset would
  # anchor a pooled worktree on whatever the previous task left behind, and with the
  # fixture's two commits identical the assertion could not tell the cases apart.
  base=$(git -C "$proj.origin.git" rev-parse HEAD)
  git -C "$wt" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit --quiet --allow-empty -m 'worktree advanced past the base'
  prespawn=$(git -C "$wt" rev-parse HEAD)
  [ "$prespawn" != "$base" ] \
    || fail "the fixture stopped diverging: pre-spawn HEAD and the reset target are both $base, so the capture point is untested"

  # 1. No --quality at all: the pre-quality call site, unchanged.
  write_brief "$home" quality-meta-i1 no-mistakes
  out=$(run_spawning "$home" "$wt" "$fakebin" quality-meta-i1 "$proj" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a ship spawn with no --quality should succeed"$'\n'"$out"
  meta="$home/state/quality-meta-i1.meta"
  assert_present "$meta" "a successful ship spawn wrote no task record"
  [ "$(meta_value "$meta" quality)" = standard ] \
    || fail "a spawn with no --quality recorded quality='$(meta_value "$meta" quality)'"
  [ "$(meta_value "$meta" base_sha)" = "$base" ] \
    || fail "base_sha recorded '$(meta_value "$meta" base_sha)', expected the reset target $base"
  [ "$(meta_value "$meta" base_sha)" != "$prespawn" ] \
    || fail "base_sha recorded the worktree's pre-spawn HEAD $prespawn, so the anchor was captured before the reset"
  # Everything the record carried before the quality wiring is still exactly there.
  [ "$(meta_value "$meta" mode)" = no-mistakes ] || fail "the recorded delivery mode changed"
  [ "$(meta_value "$meta" yolo)" = off ] || fail "the recorded approval posture changed"
  [ "$(meta_value "$meta" kind)" = ship ] || fail "the recorded kind changed"
  [ "$(meta_value "$meta" worktree)" = "$wt" ] || fail "the recorded worktree changed"
  [ "$(meta_value "$meta" project)" = "$proj" ] || fail "the recorded project changed"
  [ "$(meta_value "$meta" harness)" = claude ] || fail "the recorded harness changed"
  # ...and the only keys added are the two additive ones.
  keys=$(cut -d= -f1 "$meta" | grep -vx -e quality -e base_sha | sort | tr '\n' ' ')
  [ "$keys" = "busy_gen effort endpoint_task_id harness kind mode model project spawn_gen tasktmp window worktree yolo " ] \
    || fail "the ship task record gained or lost a key beyond the additive quality= and base_sha=; this pin is deliberate, so change it only with the callers that read the record: '$keys'"
  # The success line three callers read is untouched too.
  assert_contains "$out" "spawned quality-meta-i1 harness=claude kind=ship mode=no-mistakes yolo=off window=" \
    "the spawn success line changed shape"

  # 2. A hardened task records the hardened posture and the same kind of anchor.
  write_brief "$home" quality-meta-i2 direct-PR hardened
  out=$(run_spawning "$home" "$wt" "$fakebin" quality-meta-i2 "$proj" --mode direct-PR --yolo on --quality hardened)
  status=$?
  expect_code 0 "$status" "a hardened ship spawn should succeed"$'\n'"$out"
  meta="$home/state/quality-meta-i2.meta"
  [ "$(meta_value "$meta" quality)" = hardened ] \
    || fail "a hardened spawn recorded quality='$(meta_value "$meta" quality)'"
  [ "$(meta_value "$meta" base_sha)" = "$base" ] \
    || fail "a hardened spawn recorded base_sha='$(meta_value "$meta" base_sha)', expected $base"
  [ "$(meta_value "$meta" mode)" = direct-PR ] || fail "the hardened task lost its delivery mode"
  [ "$(meta_value "$meta" yolo)" = on ] || fail "the hardened task lost its approval posture"
  [ "$(grep -c '^quality=' "$meta")" = 1 ] || fail "the record carries more than one quality= line"
  [ "$(grep -c '^base_sha=' "$meta")" = 1 ] || fail "the record carries more than one base_sha= line"

  # 3. A scout carries no quality posture and no base anchor at all, exactly as it
  #    carries no delivery posture: there is no loop to anchor.
  write_brief "$home" quality-meta-i3
  out=$(run_spawning "$home" "$wt" "$fakebin" quality-meta-i3 "$proj" --scout)
  status=$?
  expect_code 0 "$status" "a scout spawn should succeed"$'\n'"$out"
  meta="$home/state/quality-meta-i3.meta"
  assert_no_grep "quality=" "$meta" "a scout task recorded a quality posture"
  assert_no_grep "base_sha=" "$meta" "a scout task recorded a quality base commit"
  pass "fm-spawn: a ship task records quality= and base_sha= additively, and a scout records neither"
}

# The registry is the captain's standing quality posture too, so a hardened project
# shipped as a standard task is announced for the same reason a rigor downgrade is:
# allowed on a current captain instruction, never silent. It is advisory only, so the
# spawn still succeeds and still records the standard posture it was handed.
test_spawn_notices_a_quality_downgrade_against_the_registry() {
  local rec home proj wt fakebin out status meta
  rec=$(make_spawning_home quality-standing)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF

  # 1. A hardened project, spawned from a standard brief with no --quality.
  printf '%s\n' '- proj [no-mistakes +hardened] - fixture (added 2026-01-01)' > "$home/data/projects.md"
  write_brief "$home" quality-standing-i1 no-mistakes
  out=$(run_spawning "$home" "$wt" "$fakebin" quality-standing-i1 "$proj" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "the quality notice must not block the spawn"$'\n'"$out"
  assert_contains "$out" "ships quality=standard while the standing posture for proj is hardened" \
    "no notice when a hardened project shipped a standard task"
  meta="$home/state/quality-standing-i1.meta"
  assert_present "$meta" "the announced spawn wrote no task record"
  [ "$(meta_value "$meta" quality)" = standard ] \
    || fail "the notice changed the recorded posture to '$(meta_value "$meta" quality)'"

  # 2. The same spawn against a project carrying no +hardened token stays quiet.
  printf '%s\n' '- proj [no-mistakes] - fixture (added 2026-01-01)' > "$home/data/projects.md"
  write_brief "$home" quality-standing-i2 no-mistakes
  out=$(run_spawning "$home" "$wt" "$fakebin" quality-standing-i2 "$proj" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "a standard project spawn should succeed"$'\n'"$out"
  assert_not_contains "$out" "ships quality=" \
    "a project with no registered quality posture printed a quality notice"
  pass "fm-spawn: a standard task under a hardened standing posture is announced, never blocked"
}

# Spawn and promotion refuse leftover Task-subsection placeholders through the
# public brief/spawn/promote path. Filling both subsections lets the spawn
# delivery checks proceed (the fake tmux still fails later).
test_spawn_and_promote_require_filled_task_subsections() {
  local rec home proj fakebin out status id brief meta intent_body spec_body authorized
  rec=$(make_home subsections)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF

  id=delivery-unfilled-ship
  FM_HOME="$home" "$BRIEF" "$id" proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "unfilled ship brief should still scaffold"
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn of an unfilled ship brief should exit non-zero"
  assert_contains "$out" "still contains {TASK} or {FIRSTMATE_SPEC}" \
    "unfilled ship spawn did not name the leftover placeholders"
  assert_contains "$out" "## Captain's intent" \
    "unfilled ship spawn did not name the intent subsection to fill"
  assert_absent "$home/state/$id.meta" "unfilled ship spawn wrote task metadata"

  id=delivery-filled-ship
  FM_HOME="$home" "$BRIEF" "$id" proj --mode direct-PR >/dev/null 2>&1 \
    || fail "filled-ship brief should scaffold"
  fill_brief_subsections "$home/data/$id/brief.md" \
    "Fix replacement of \`{TASK}\` in Herdr briefs." \
    "Keep literal \`{FIRSTMATE_SPEC}\` examples intact."
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode direct-PR --yolo off)
  assert_not_contains "$out" "still contains {TASK} or {FIRSTMATE_SPEC}" \
    "a filled ship brief mentioning placeholder tokens was refused as unfilled"
  assert_not_contains "$out" "must contain nonempty" \
    "a filled ship brief mentioning placeholder tokens failed content validation"

  id=delivery-legacy-fenced-headings
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
You are a crewmate.

# Task
Preserve this legacy task containing a format example.

```markdown
## Captain's intent
Example intent
## Firstmate spec
Example specification
```

# Definition of done
Delivery contract: mode=direct-PR
EOF
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode direct-PR --yolo off)
  assert_not_contains "$out" "must contain nonempty" \
    "fenced example headings made a filled legacy Task fail validation"
  assert_not_contains "$out" "still contains {TASK} or {FIRSTMATE_SPEC}" \
    "fenced example headings made a filled legacy Task look unfilled"

  id=delivery-legacy-no-mistakes
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
Captain: Fix the legacy dispatch boundary.
Preserve this Firstmate-authored compatibility constraint.

# Definition of done
Delivery contract: mode=no-mistakes
Pass the entire Task as --intent.
EOF
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode no-mistakes --yolo off)
  assert_not_contains "$out" "has no provenance-marked captain words" \
    "legacy no-mistakes spawn rejected explicitly marked captain words"
  assert_present "$home/data/$id/launch-brief.md" \
    "marked legacy spawn did not render a current launch contract"
  assert_grep "supersedes every earlier brief instruction about constructing \`--intent\`" \
    "$home/data/$id/launch-brief.md" \
    "marked legacy spawn did not override its stale intent instruction"
  assert_grep "plus later accepted requirements" \
    "$home/data/$id/launch-brief.md" \
    "marked legacy launch contract excluded later captain clarifications"
  authorized=$(awk '$0 == "## Captain intent authorized for --intent" { emit=1; next } emit && /^$/ { exit } emit { print }' "$home/data/$id/launch-brief.md")
  assert_contains "$authorized" "Fix the legacy dispatch boundary." \
    "marked legacy launch contract omitted captain words"
  assert_grep "Preserve this Firstmate-authored compatibility constraint." "$home/data/$id/launch-brief.md" \
    "marked legacy launch contract lost accepted specification"

  id=delivery-migrated-stale-no-mistakes
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Fix the migrated dispatch boundary.

## Firstmate spec
Preserve the existing compatibility path.

# Definition of done
Delivery contract: mode=no-mistakes
Pass the entire Task and every Firstmate requirement as --intent.
EOF
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode no-mistakes --yolo off)
  assert_present "$home/data/$id/launch-brief.md" \
    "migrated subsection brief did not receive the current launch contract"
  authorized=$(awk '$0 == "## Captain intent authorized for --intent" { emit=1; next } emit && /^$/ { exit } emit { print }' "$home/data/$id/launch-brief.md")
  assert_contains "$authorized" "Fix the migrated dispatch boundary." \
    "migrated launch contract omitted Captain's intent"
  assert_grep "Preserve the existing compatibility path." "$home/data/$id/launch-brief.md" \
    "migrated launch contract omitted accepted Firstmate specification"
  assert_grep "supersedes every earlier brief instruction about constructing \`--intent\`" \
    "$home/data/$id/launch-brief.md" \
    "migrated launch contract did not supersede its stale mixed-Task DoD"
  assert_grep "plus later accepted requirements" \
    "$home/data/$id/launch-brief.md" \
    "migrated launch contract excluded later captain clarifications"
  assert_grep "The Definition of done's rule that \`--intent\` must be self-sufficient still governs" \
    "$home/data/$id/launch-brief.md" \
    "migrated launch contract's overlay dropped the self-sufficiency pointer"

  id=delivery-legacy-unmarked-no-mistakes
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
Fix the legacy dispatch boundary.
Preserve this Firstmate-authored compatibility constraint.

# Definition of done
Delivery contract: mode=no-mistakes

# Notes
## Captain's intent
Unrelated notes must not become task intent.
## Firstmate spec
Unrelated notes must not satisfy task validation.
EOF
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode no-mistakes --yolo off)
  status=$?
  assert_present "$home/data/$id/launch-brief.md" "legacy task requirements were not preserved"
  assert_grep "No separately attributed captain words" "$home/data/$id/launch-brief.md" \
    "unmarked legacy task invented captain provenance"
  assert_grep "Preserve this Firstmate-authored compatibility constraint." "$home/data/$id/launch-brief.md" \
    "legacy task omitted accepted requirements"

  id=delivery-unfilled-scout
  FM_HOME="$home" "$BRIEF" "$id" proj --scout >/dev/null 2>&1 \
    || fail "unfilled scout brief should still scaffold"
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn of an unfilled scout brief should exit non-zero"
  assert_contains "$out" "still contains {TASK} or {FIRSTMATE_SPEC}" \
    "unfilled scout spawn did not name the leftover placeholders"
  assert_absent "$home/state/$id.meta" "unfilled scout spawn wrote task metadata"

  id=delivery-empty-ship
  FM_HOME="$home" "$BRIEF" "$id" proj --mode direct-PR >/dev/null 2>&1 \
    || fail "empty-ship brief should scaffold"
  fill_brief_subsections "$home/data/$id/brief.md" "" ""
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode direct-PR --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn of empty Task subsections should exit non-zero"
  assert_contains "$out" "must contain nonempty ## Captain's intent and ## Firstmate spec" \
    "empty Task subsections were not rejected semantically"
  assert_absent "$home/state/$id.meta" "empty-subsection spawn wrote task metadata"

  id=promote-unfilled-e1
  meta="$home/state/$id.meta"
  mkdir -p "$home/state"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$meta"
  FM_HOME="$home" "$BRIEF" "$id" proj --scout >/dev/null 2>&1 \
    || fail "unfilled promote scout brief should scaffold"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" --mode direct-PR --yolo on 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion of an unfilled scout brief should exit non-zero"
  assert_contains "$out" "preserve the original ask in ## Captain's intent" \
    "unfilled promotion did not preserve the original captain ask boundary"
  assert_contains "$out" "promotion generates a separate ship-time spec" \
    "unfilled promotion did not distinguish scout and ship Firstmate specs"
  assert_grep 'kind=scout' "$meta" "unfilled promotion still changed the task record"

  id=promote-missing-brief
  meta="$home/state/$id.meta"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$meta"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" --mode direct-PR --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without a scout brief should exit non-zero"
  assert_contains "$out" "must contain nonempty" \
    "promotion without a scout brief did not reject missing task content"
  assert_absent "$home/data/$id/ship-instructions.md" \
    "promotion without a scout brief fabricated ship instructions"
  assert_grep 'kind=scout' "$meta" "missing-brief promotion changed the task record"

  id=promote-unmarked-legacy
  meta="$home/state/$id.meta"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$meta"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
Investigate the unmarked legacy failure.
Keep this Firstmate constraint out of captain intent.

# Notes
## Captain's intent
Unrelated notes are not the original ask.
## Firstmate spec
Unrelated notes are not the task specification.
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" --mode direct-PR --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion without provenance-marked captain intent should fail"
  assert_contains "$out" "has no provenance-marked Captain's intent" \
    "unmarked legacy promotion did not explain the missing intent provenance"
  assert_absent "$home/data/$id/ship-instructions.md" \
    "unmarked legacy promotion published empty captain intent"
  assert_grep 'kind=scout' "$meta" "unmarked legacy promotion changed the task record"

  id=promote-filled-e2
  meta="$home/state/$id.meta"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$meta"
  FM_HOME="$home" "$BRIEF" "$id" proj --scout >/dev/null 2>&1 \
    || fail "filled promote scout brief should scaffold"
  fill_brief_subsections "$home/data/$id/brief.md" \
    "Investigate why the identity check is failing." \
    "Ship the identity-check fix without adding a classifier."
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" --mode no-mistakes --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "promotion of a filled scout brief should succeed"
  assert_grep 'kind=ship' "$meta" "filled promotion did not restore ship teardown protection"
  brief="$home/data/$id/ship-instructions.md"
  assert_grep "Investigate why the identity check is failing." "$brief" \
    "promotion did not preserve the original Captain's intent"
  assert_no_grep "Ship the identity-check fix without adding a classifier." "$brief" \
    "promotion reused the scout-time Firstmate spec as ship instructions"
  spec_body=$(awk '$0 == "## Firstmate spec" { emit=1; next } emit && /^# / { exit } emit { print }' "$brief")
  assert_contains "$spec_body" "Verify isolation before anything else" \
    "promotion did not place its ship-time instructions in Firstmate spec"
  assert_no_grep "SCOUT task" "$brief" \
    "promotion copied the scout Setup/Rules contract into Firstmate spec"
  assert_no_grep "# Setup" "$brief" \
    "promotion copied a later brief section into a Task subsection"

  id=promote-nested-spec
  meta="$home/state/$id.meta"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$meta"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
# Task
## Captain's intent
Ship the parser without losing detailed requirements.

## Firstmate spec
Keep this opening requirement.

### Acceptance criteria
Keep this nested requirement too.

```markdown
# This example heading is fenced content.
```

Keep this closing requirement.

# Setup
This scout-only setup must not become the spec.
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" --mode direct-PR --yolo off 2>&1)
  status=$?
  expect_code 0 "$status" "promotion with nested and fenced spec content should succeed"
  brief="$home/data/$id/ship-instructions.md"
  assert_grep "Ship the parser without losing detailed requirements." "$brief" \
    "promotion discarded Captain's intent while replacing the scout spec"
  assert_no_grep "### Acceptance criteria" "$brief" \
    "promotion reused nested scout acceptance criteria as ship instructions"
  assert_no_grep "# This example heading is fenced content." "$brief" \
    "promotion reused a fenced scout-spec example as ship instructions"
  assert_no_grep "Keep this closing requirement." "$brief" \
    "promotion reused trailing scout spec as ship instructions"
  assert_no_grep "This scout-only setup must not become the spec." "$brief" \
    "promotion copied the following top-level section into Firstmate spec"

  id=promote-legacy-e3
  meta="$home/state/$id.meta"
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$meta"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<'EOF'
You are a crewmate.

# Task
[captain] Investigate the fold's session-floor refusal.
[captain] Preserve the existing successful session behavior.

Reproduce the refusal before changing code.
Ship the narrow session-floor fix with a regression test.

# Setup
This is a SCOUT task: the deliverable is a written report, not a PR.
EOF
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" --mode direct-PR --yolo on 2>&1)
  status=$?
  expect_code 0 "$status" "promotion of a pre-subsection scout brief should succeed"
  brief="$home/data/$id/ship-instructions.md"
  intent_body=$(awk '$0 == "## Captain'\''s intent" { emit=1; next } emit && /^## / { exit } emit { print }' "$brief")
  spec_body=$(awk '$0 == "## Firstmate spec" { emit=1; next } emit && /^# / { exit } emit { print }' "$brief")
  assert_contains "$intent_body" "Investigate the fold's session-floor refusal." \
    "legacy promotion discarded provenance-marked captain words"
  assert_contains "$intent_body" "Preserve the existing successful session behavior." \
    "legacy promotion truncated multiline provenance-marked captain words"
  assert_not_contains "$intent_body" "Reproduce the refusal" \
    "legacy promotion classified unmarked mixed Task text as captain intent"
  assert_not_contains "$spec_body" "Reproduce the refusal before changing code." \
    "legacy promotion reused the scout-time mixed Task as ship instructions"
  assert_not_contains "$spec_body" "Ship the narrow session-floor fix with a regression test." \
    "legacy promotion reused old build instructions as the ship spec"
  assert_contains "$spec_body" "Verify isolation before anything else" \
    "legacy promotion did not place promotion ship instructions in Firstmate spec"
  assert_not_contains "$spec_body" "This is a SCOUT task" \
    "legacy promotion copied the scout Setup section into Firstmate spec"
  pass "fm-spawn/fm-promote: leftover Task placeholders are refused until both subsections are filled"
}

# Exercise the serialized input a worker is told to pass to no-mistakes, not
# just the presence of words somewhere in its much larger launch brief.
# No live model or pipeline is needed: spawn publishes this exact input before
# the fixture backend refuses to create an endpoint.
test_authorized_intent_keeps_words_without_composed_address() {
  local rec home proj fakebin id words authorized out status marker n=0
  rec=$(make_home intent-emission)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  id='intent-plain'
  words=$(printf '%s\n' 'Keep the original request intact.' '' "Preserve its provenance, punctuation, and \`literal code\`.")
  FM_HOME="$home" "$BRIEF" "$id" proj --mode no-mistakes >/dev/null 2>&1 \
    || fail "intent brief should scaffold"
  fill_brief_subsections "$home/data/$id/brief.md" "$words" 'This build constraint must not become intent.'
  out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode no-mistakes --yolo off)
  assert_present "$home/data/$id/launch-brief.md" "plain intent was not serialized"
  authorized=$(awk '$0 == "## Captain intent authorized for --intent" { emit=1; next } emit && /^## Firstmate specification/ { exit } emit { print }' "$home/data/$id/launch-brief.md")
  [ "$authorized" = "$words" ] || fail "authorized --intent must contain exactly the request, without headings, address, or contract prose: $authorized"

  # The request itself may discuss an address spelling. It is data, not an
  # invitation to scrub the user's words or synthesize a different request.
  words=$(printf '%s\n' "Keep the literal example \`Captain, hello\` in the documentation." \
    "Stop composing Captain:, Captain's words:, Captain's ask:, and Captain's intent: into PR bodies.")
  write_brief "$home" intent-literal no-mistakes
  printf '# Task\n## Captain'"'"'s intent\n%s\n\n## Firstmate spec\nDo not paraphrase.\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n' "$words" > "$home/data/intent-literal/brief.md"
  out=$(run_spawn "$home" "$fakebin" intent-literal "$proj" claude --mode no-mistakes --yolo off)
  assert_not_contains "$out" "operator-address line" "labels mentioned mid-line were refused as address"
  authorized=$(awk '$0 == "## Captain intent authorized for --intent" { emit=1; next } emit && /^## Firstmate specification/ { exit } emit { print }' "$home/data/intent-literal/launch-brief.md")
  [ "$authorized" = "$words" ] || fail "literal words in the request were scrubbed"

  # A body line that opens with operator address is refused, never rewritten.
  for marker in 'Captain:' "Captain's words:" "Captain's ask:" "Captain's intent:" 'Captain,'; do
    n=$((n + 1))
    id="intent-addressed-$n"
    write_brief "$home" "$id" no-mistakes
    printf '# Task\n## Captain'"'"'s intent\nKeep the original request intact.\n  %s preserve its provenance.\n\n## Firstmate spec\nDo not paraphrase.\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n' \
      "$marker" > "$home/data/$id/brief.md"
    out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode no-mistakes --yolo off)
    status=$?
    [ "$status" -ne 0 ] || fail "$marker: addressed intent should be refused"
    assert_contains "$out" "operator-address line:   $marker preserve its provenance." \
      "$marker: refusal did not name the offending line"
    assert_contains "$out" "write the captain's actual words without a Captain label or address" \
      "$marker: refusal did not say what to write instead"
    assert_absent "$home/data/$id/launch-brief.md" "$marker: addressed intent was serialized"
    assert_absent "$home/state/$id.meta" "$marker: addressed intent spawn wrote task metadata"
    assert_grep "  $marker preserve its provenance." "$home/data/$id/brief.md" "$marker: refusal rewrote the brief"
  done

  id='intent-addressed-promote'
  printf 'window=fm-%s\nkind=scout\nworktree=/tmp/wt\n' "$id" > "$home/state/$id.meta"
  write_brief "$home" "$id"
  printf '# Task\n## Captain'"'"'s intent\nCaptain: investigate the refusal.\n\n## Firstmate spec\nReproduce it first.\n' > "$home/data/$id/brief.md"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" "$id" --mode no-mistakes --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion of addressed intent should be refused"
  assert_contains "$out" "operator-address line: Captain: investigate the refusal." \
    "promotion refusal did not name the offending line"
  assert_absent "$home/data/$id/ship-instructions.md" "promotion published addressed intent"
  assert_grep 'kind=scout' "$home/state/$id.meta" "refused promotion changed the task record"

  # New legacy briefs use neutral provenance. Previously stored labels remain
  # readable without encouraging their use in newly composed pipeline input.
  for marker in '[captain]' 'Captain:' "Captain's words:" "Captain's ask:" "Captain's intent:"; do
    n=$((n + 1))
    id="intent-marked-$n"
    write_brief "$home" "$id" no-mistakes
    printf '# Task\n%s %s\nDo not include this build constraint.\n%s %s\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n' \
      "$marker" 'Keep the original request intact.' "$marker" 'Preserve its provenance.' > "$home/data/$id/brief.md"
    out=$(run_spawn "$home" "$fakebin" "$id" "$proj" claude --mode no-mistakes --yolo off)
    assert_present "$home/data/$id/launch-brief.md" "$marker: provenance was not accepted"
    authorized=$(awk '$0 == "## Captain intent authorized for --intent" { emit=1; next } emit && /^## Firstmate specification/ { exit } emit { print }' "$home/data/$id/launch-brief.md")
    words=$(printf '%s\n' 'Keep the original request intact.' 'Preserve its provenance.')
    [ "$authorized" = "$words" ] || fail "$marker: legacy intent changed words or included provenance/build prose"
  done
  pass "fm-spawn/fm-promote: authorized intent preserves exact words and refuses operator-address lines"
}

test_spawn_refreshes_legacy_worker_roles() {
  local rec home proj fakebin kind id out brief project_kind first_line role_line supervisor_line
  rec=$(make_home worker-roles)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  # AGENTS.md and its import are instruction inputs, not implementation-source
  # assertions: launching a worker must never rewrite either project's files.
  cp "$ROOT/AGENTS.md" "$home/AGENTS.md"
  for project_kind in firstmate unrelated; do
    if [ "$project_kind" = firstmate ]; then
      cp "$ROOT/AGENTS.md" "$proj/AGENTS.md"
    else
      printf 'Use this project coding standard.\n' > "$proj/AGENTS.md"
    fi
    printf '@AGENTS.md\n' > "$proj/CLAUDE.md"
    cp "$proj/AGENTS.md" "$proj/agents-before"
    for kind in no-mistakes direct-PR local-only scout; do
      id="roles-$project_kind-$kind"
      write_brief "$home" "$id"
      if [ "$kind" = scout ]; then
        out=$(run_spawn "$home" "$fakebin" "$id" "$proj" codex --scout)
      else
        out=$(run_spawn "$home" "$fakebin" "$id" "$proj" codex --mode "$kind" --yolo off)
      fi
      assert_not_contains "$out" 'could not render' "worker role rendering failed"
      brief="$home/data/$id/launch-brief.md"
      assert_present "$brief" "$project_kind $kind did not refresh the legacy launch brief"
      first_line=$(sed -n '1p' "$brief")
      [ "$first_line" = '# Current worker role contract' ] ||
        fail "$project_kind $kind did not put worker identity first"
      assert_grep 'follow this brief instead of that supervisor contract' "$brief" "$project_kind $kind omitted worker authority"
      assert_grep "$home/state/$id.inbox" "$brief" "$project_kind $kind omitted its exact steering inbox"
      assert_grep 'When this task works on Firstmate itself' "$brief" "$project_kind $kind made the exception unconditional"
      assert_grep 'Project instructions still govern the work wherever they do not conflict with this worker identity' "$brief" "$project_kind $kind displaced project guidance"
      ! grep -q '^This section supersedes every earlier brief instruction about your role' "$brief" ||
        fail "$project_kind $kind revoked the brief's own role for a task that is not Firstmate"
      assert_no_grep '# Current worker role contract' "$home/data/$id/brief.md" "spawn rewrote the source brief"
      cmp -s "$proj/agents-before" "$proj/AGENTS.md" || fail "spawn changed project AGENTS.md"
      [ "$(cat "$proj/CLAUDE.md")" = '@AGENTS.md' ] || fail "spawn changed the project import"
    done
  done
  role_line=$(grep -n 'A ship or scout worker launched by Firstmate into a worktree of this repository' "$ROOT/AGENTS.md" | cut -d: -f1)
  supervisor_line=$(grep -n '^You are the first mate\.$' "$ROOT/AGENTS.md" | head -1 | cut -d: -f1)
  [ -n "$role_line" ] && [ "$role_line" -lt "$supervisor_line" ] ||
    fail "Firstmate AGENTS.md does not disambiguate a launched worker before assigning the supervisor identity"
  cmp -s "$ROOT/AGENTS.md" "$home/AGENTS.md" || fail "worker spawn changed the primary contract"
  pass "fm-spawn: every legacy worker receives scoped role instructions without changing project or primary instructions"
}

test_authorized_intent_keeps_words_without_composed_address
test_spawn_refreshes_legacy_worker_roles
test_ship_spawn_requires_a_valid_delivery_contract
test_scout_and_secondmate_refuse_delivery_flags
test_spawn_refuses_a_brief_mode_mismatch
test_spawn_notices_a_rigor_downgrade_against_the_registry
test_scout_records_no_delivery_posture
test_promote_requires_and_records_the_delivery_contract
test_promote_notices_the_standing_quality_posture
test_project_mode_maps_the_conditional_policy
test_project_mode_reads_the_registered_quality_posture
test_project_mode_refuses_hardened_on_the_conditional_policy
test_project_mode_two_word_contract_survives_the_quality_posture
test_scout_and_secondmate_refuse_the_quality_flag
test_spawn_refuses_a_brief_quality_mismatch
test_spawn_records_the_quality_posture_and_base_commit
test_spawn_notices_a_quality_downgrade_against_the_registry
test_promote_refuses_a_symlinked_task_record
test_promotion_delivers_the_real_definition_of_done
test_spawn_and_promote_require_filled_task_subsections
echo "# all fm-task-delivery tests passed"
