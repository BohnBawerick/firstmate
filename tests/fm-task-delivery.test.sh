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
# Every spawn case here stops before any endpoint exists: the delivery checks run
# ahead of backend creation, and a fake `tmux` that exits non-zero backstops the
# cases that are meant to get past them, so no window or worktree is ever created.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
PROMOTE="$ROOT/bin/fm-promote.sh"
PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-delivery)

# A spawn that gets all the way to metadata also creates /tmp/fm-<id>, which is
# outside TMP_ROOT and therefore outside fm_test_tmproot's cleanup. Track and
# remove each one so this suite leaks nothing on a shared host.
SPAWNED_TASK_TMPS=()
delivery_cleanup() {
  local d
  for d in "${SPAWNED_TASK_TMPS[@]:-}"; do
    [ -z "$d" ] || rm -rf "$d"
  done
}
trap delivery_cleanup EXIT

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
    printf 'You are a crewmate.\n\n# Definition of done\n'
    [ -z "$mode" ] || printf 'Delivery contract: mode=%s\n' "$mode"
    [ -z "$quality" ] || printf 'Quality contract: quality=%s\n' "$quality"
  } > "$home/data/$id/brief.md"
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
  local home meta out status
  home="$TMP_ROOT/promote/home"
  mkdir -p "$home/state"
  meta="$home/state/promote-d1.meta"

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
  assert_contains "$out" "promotion requires --yolo" "promote refusal did not name the missing approval posture"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode no-mistakes-prod-only --yolo off 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "promotion on a conditional policy should exit non-zero"
  assert_contains "$out" "classify this task's surface" "promote did not refuse the conditional policy as a task mode"

  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$PROMOTE" promote-d1 --mode direct-PR --yolo on 2>&1)
  status=$?
  expect_code 0 "$status" "a promotion carrying both flags should succeed"
  assert_grep 'kind=ship' "$meta" "promotion did not restore ship teardown protection"
  assert_grep 'mode=direct-PR' "$meta" "promotion did not record the decided delivery mode"
  assert_grep 'yolo=on' "$meta" "promotion did not record the decided approval posture"
  assert_contains "$out" "ship instructions for mode=direct-PR" "promotion hint did not carry the decided mode"
  [ "$(grep -c '^mode=' "$meta")" = 1 ] || fail "promotion left more than one mode= line in the task record"
  pass "fm-promote: promotion requires the delivery contract and records it exactly once"
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
hardened on a conditional policy|- qproj [no-mistakes-prod-only +hardened] - fixture (added 2026-01-01)|hardened
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
  SPAWNED_TASK_TMPS+=("/tmp/fm-$1")
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
  local rec home proj wt fakebin meta out status base keys
  rec=$(make_spawning_home quality-meta)
  IFS='|' read -r home proj wt fakebin <<EOF
$rec
EOF
  base=$(git -C "$wt" rev-parse HEAD)

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
    || fail "base_sha recorded '$(meta_value "$meta" base_sha)', expected the worktree's HEAD $base"
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

test_ship_spawn_requires_a_valid_delivery_contract
test_scout_and_secondmate_refuse_delivery_flags
test_spawn_refuses_a_brief_mode_mismatch
test_spawn_notices_a_rigor_downgrade_against_the_registry
test_scout_records_no_delivery_posture
test_promote_requires_and_records_the_delivery_contract
test_project_mode_maps_the_conditional_policy
test_project_mode_reads_the_registered_quality_posture
test_project_mode_two_word_contract_survives_the_quality_posture
test_scout_and_secondmate_refuse_the_quality_flag
test_spawn_refuses_a_brief_quality_mismatch
test_spawn_records_the_quality_posture_and_base_commit
echo "# all fm-task-delivery tests passed"
