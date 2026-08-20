#!/usr/bin/env bash
# Behavioral coverage for Memory Slice 3: the Dreamer scout brief, the idle
# dream trigger / evaluation helper, and the independent grader rubric.
#
# Every assertion here runs the real helper scripts on disk and inspects their
# real outputs, files, and exit codes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-dreamer)
BRIEF="$ROOT/bin/fm-brief.sh"
WATCH="$ROOT/bin/fm-dreamer-watch.sh"
GRADE="$ROOT/bin/fm-dreamer-grade.sh"
VERIFY="$ROOT/bin/fm-memory-verify.sh"
DROP="$ROOT/bin/fm-memory-drop.sh"
PUBLISH="$ROOT/bin/fm-memory-publish.sh"
COMPILE="$ROOT/bin/fm-memory-compile.sh"

# new_home <name> [budget]: a clean test home with budget and standard dirs.
new_home() {
  local budget=${2:-7500} home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/data" "$home/state" "$home/data/memory/drop"
  printf '%s\n' "$budget" > "$home/config/startup-memory-budget"
  printf '%s\n' "$home"
}

# write_note <notes_dir> <slug> <title> <triggers> <updated> <source> [body]
write_note() {
  local notes_dir=$1 slug=$2 title=$3 triggers=$4 updated=$5 source=$6 body=${7:-""}
  mkdir -p "$notes_dir"
  {
    printf -- '---\n'
    printf 'title: %s\n' "$title"
    printf 'triggers: %s\n' "$triggers"
    printf 'updated: %s\n' "$updated"
    printf 'source: %s\n' "$source"
    printf -- '---\n\n'
    printf '# %s\n\n' "$title"
    if [ -n "$body" ]; then
      printf '%s\n' "$body"
    else
      printf 'Body of note %s citing %s.\n' "$slug" "$source"
    fi
  } > "$notes_dir/$slug.md"
}

# --- 1. Dreamer brief scaffolding -------------------------------------------

test_dreamer_brief_scaffolds_contract() {
  local home out brief content
  home=$(new_home dream-brief-basic)
  out=$(FM_HOME="$home" "$BRIEF" fm-dream-1 firstmate --dreamer)
  assert_contains "$out" 'dreamer' 'scaffold did not identify a dreamer brief'

  brief="$home/data/fm-dream-1/brief.md"
  assert_present "$brief" 'dreamer brief was not written'
  content=$(cat "$brief")

  # The dreamer contract rules must all be present.
  assert_contains "$content" 'DREAMER' 'brief did not name the dreamer role'
  assert_contains "$content" 'NEVER take the session lock' \
    'dreamer brief does not forbid taking the session lock'
  assert_contains "$content" 'NEVER edit published memory in place' \
    'dreamer brief does not forbid editing published memory in place'
  assert_contains "$content" 'NEVER address the captain' \
    'dreamer brief does not forbid addressing the captain'
  assert_contains "$content" 'bin/fm-memory-verify.sh' \
    'dreamer brief does not require mechanical verification'
  assert_contains "$content" 'data/memory/gen/' \
    'dreamer brief does not direct writing an immutable generation'
  assert_contains "$content" 'data/memory/drop/' \
    'dreamer brief does not name the drop tray as an input'
  assert_contains "$content" 'state/.dream.lock' \
    'dreamer brief does not mention the single-flight dream lock'
  # The deliverable is a generation + receipt, never a PR.
  assert_contains "$content" 'never open a PR' \
    'dreamer brief does not forbid opening a PR'

  pass 'dreamer brief scaffolds the full offline-consolidation contract'
}

test_dreamer_brief_refuses_ship_mode() {
  local home out
  home=$(new_home dream-brief-mode)
  if out=$(FM_HOME="$home" "$BRIEF" fm-dream-2 firstmate --dreamer --mode no-mistakes 2>&1); then
    fail "dreamer brief accepted a ship --mode: $out"
  fi
  assert_contains "$out" '--mode applies only to ship briefs' \
    'dreamer brief did not explain the mode refusal'
  assert_absent "$home/data/fm-dream-2" 'a refused brief left data behind'

  pass 'dreamer brief refuses the ship-only --mode flag'
}

test_dreamer_brief_accepts_herdr_lab() {
  local home out content
  home=$(new_home dream-brief-herdr)
  out=$(FM_HOME="$home" "$BRIEF" fm-dream-3 firstmate --dreamer --herdr-lab)
  content=$(cat "$home/data/fm-dream-3/brief.md")
  assert_contains "$content" 'Herdr isolation - HARD SAFETY CONTRACT' \
    'dreamer brief with --herdr-lab lacks the isolation contract'
  pass 'dreamer brief composes with --herdr-lab'
}

# --- 2. Idle dream evaluation (fm-dreamer-watch check) -----------------------

test_watch_not_due_on_empty_home() {
  local home out rc
  home=$(new_home watch-empty)
  out=$(FM_HOME="$home" "$WATCH" check 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "empty home was not clean not-due (exit $rc): $out"
  assert_contains "$out" 'DREAM_DUE: not-due' 'empty home did not report not-due'
  pass 'watch reports not-due when there is nothing to consolidate'
}

test_watch_due_on_unconsumed_drop() {
  local home out rc
  home=$(new_home watch-drop)
  printf -- '- candidate claim\n' > "$home/data/memory/drop/cand.md"
  out=$(FM_HOME="$home" "$WATCH" check 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "unconsumed drop did not make the dream due (exit $rc): $out"
  assert_contains "$out" 'DREAM_DUE: due' 'unconsumed drop did not report due'
  assert_contains "$out" 'data/memory/drop' 'due reason did not name the drop tray'
  pass 'watch reports due when the drop tray holds an unconsumed candidate'
}

test_watch_due_on_stale_head() {
  local home out rc
  home=$(new_home watch-stale-head)
  printf 'gen/0\n' > "$home/data/memory/HEAD"
  touch -d '30 hours ago' "$home/data/memory/HEAD"
  out=$(FM_HOME="$home" "$WATCH" check --head-age 12 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "stale HEAD did not make the dream due (exit $rc): $out"
  assert_contains "$out" 'older than 12 hours' 'stale HEAD reason did not name the age threshold'
  pass 'watch reports due when HEAD is older than the threshold'
}

test_watch_not_due_on_fresh_head() {
  local home out rc
  home=$(new_home watch-fresh-head)
  printf 'gen/0\n' > "$home/data/memory/HEAD"
  out=$(FM_HOME="$home" "$WATCH" check --head-age 12 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "fresh HEAD was treated as due (exit $rc): $out"
  assert_contains "$out" 'DREAM_DUE: not-due' 'fresh HEAD did not report not-due'
  pass 'watch reports not-due when HEAD is fresh'
}

test_watch_blocked_by_live_non_dreamer_worker() {
  local home out rc
  home=$(new_home watch-live-worker)
  printf -- '- candidate\n' > "$home/data/memory/drop/cand.md"
  # An unsupported backend cannot prove the worker is idle, so it must block.
  printf 'window=foo:0.1\nbackend=none\n' > "$home/state/fm-real-task.meta"
  out=$(FM_HOME="$home" "$WATCH" check 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "a live non-dreamer worker did not block the dream (exit $rc): $out"
  assert_contains "$out" 'live non-dreamer worker' \
    'blocked reason did not name the live worker'
  assert_contains "$out" 'fm-real-task' 'blocked reason did not name the blocking worker'
  pass 'watch blocks dreaming while a live non-dreamer worker exists'
}

test_watch_ignores_dreamer_prefixed_worker() {
  local home out rc
  home=$(new_home watch-dream-worker)
  printf -- '- candidate\n' > "$home/data/memory/drop/cand.md"
  printf 'window=foo:0.1\nbackend=none\n' > "$home/state/fm-dream-99.meta"
  out=$(FM_HOME="$home" "$WATCH" check 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "a dreamer-prefixed worker wrongly blocked the dream (exit $rc): $out"
  assert_contains "$out" 'DREAM_DUE: due' 'dreamer-prefixed worker prevented a due verdict'
  pass 'watch does not count a dreamer task as a blocking live worker'
}

test_watch_counts_a_remote_worker_as_live() {
  local home out rc notmux
  home=$(new_home watch-remote-worker)
  printf -- '- candidate\n' > "$home/data/memory/drop/cand.md"
  # A remote worker's local meta carries the placeholder window=remote:<id> and
  # records the real endpoint on another host. Probing the placeholder with the
  # local backend proves nothing about the worker.
  printf 'window=remote:fm-sm-1\nendpoint_task_id=fm-sm-1\nkind=secondmate\n' \
    > "$home/state/fm-sm-1.meta"
  printf 'remote_host=nas\nremote_backend=tmux\nremote_target=fm:1.0\n' \
    >> "$home/state/fm-sm-1.meta"
  # No local tmux server, so a local probe of the placeholder can only fail.
  notmux="$TMP_ROOT/watch-remote-worker-tmux"
  mkdir -p "$notmux"
  out=$(FM_HOME="$home" TMUX_TMPDIR="$notmux" "$WATCH" check 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "a live remote worker did not block the dream (exit $rc): $out"
  assert_contains "$out" 'fm-sm-1' 'blocked reason did not name the remote worker'
  pass 'watch counts a remote worker as live rather than probing it locally'
}

test_watch_accepts_a_symlinked_home() {
  local home link out rc
  home=$(new_home watch-symlink-home)
  printf -- '- candidate\n' > "$home/data/memory/drop/cand.md"
  link="$TMP_ROOT/watch-symlink-home-link"
  ln -s "$home" "$link"

  out=$(FM_HOME="$link" "$WATCH" check --home "$link" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "check refused a symlinked home (exit $rc): $out"
  assert_contains "$out" 'DREAM_DUE: due' 'check did not evaluate the symlinked home'

  # arm must register a spec its own check accepts, so it pins the resolved
  # physical home rather than the symlink it was handed.
  out=$(FM_HOME="$link" "$WATCH" arm --dry-run)
  assert_contains "$out" "--home $home" 'arm did not pin the resolved physical home'
  pass 'a symlinked home is resolved rather than refused'
}

test_watch_arm_refuses_a_missing_home() {
  local out rc
  out=$(FM_HOME="$TMP_ROOT/watch-no-such-home" "$WATCH" arm --dry-run 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "arm on a missing home did not exit 2 (exit $rc): $out"
  assert_contains "$out" 'not an existing directory' \
    'arm did not explain the refusal of a missing home'
  pass 'arm refuses to register a watch whose home does not exist'
}

test_watch_blocked_by_worker_with_unresolvable_endpoint() {
  local home out rc
  home=$(new_home watch-empty-target)
  printf -- '- candidate\n' > "$home/data/memory/drop/cand.md"
  # A supported backend with no recorded endpoint is a partially written meta.
  # That is not proof the worker is gone, so it must block the dream.
  printf 'backend=tmux\n' > "$home/state/fm-real-task.meta"
  out=$(FM_HOME="$home" "$WATCH" check 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "a worker with no resolvable endpoint did not block (exit $rc): $out"
  assert_contains "$out" 'fm-real-task' 'blocked reason did not name the unresolvable worker'
  pass 'watch treats a worker with no resolvable endpoint as live'
}

test_watch_home_flag_pins_the_evaluated_home() {
  local pinned ambient out rc
  pinned=$(new_home watch-home-pinned)
  ambient=$(new_home watch-home-ambient)
  printf -- '- candidate\n' > "$pinned/data/memory/drop/cand.md"
  # FM_HOME points at a home with nothing to consolidate; --home must win.
  out=$(FM_HOME="$ambient" "$WATCH" check --home "$pinned" 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "--home did not select the pinned home (exit $rc): $out"
  assert_contains "$out" 'DREAM_DUE: due' '--home did not evaluate the pinned home'

  out=$(FM_HOME="$pinned" "$WATCH" check --home "$ambient" 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "--home did not override an ambient due home (exit $rc): $out"
  pass 'check --home evaluates the pinned home, not the ambient FM_HOME'
}

test_watch_mark_due_home_flag_writes_into_the_pinned_home() {
  local pinned ambient
  pinned=$(new_home watch-mark-pinned)
  ambient=$(new_home watch-mark-ambient)
  FM_HOME="$ambient" "$WATCH" mark-due when-dream-due --home "$pinned" >/dev/null
  assert_present "$pinned/state/.dream-due" 'mark-due did not write into the pinned home'
  assert_absent "$ambient/state/.dream-due" 'mark-due wrote into the ambient home'
  pass 'mark-due --home writes the marker into the pinned home'
}

test_watch_mark_due_writes_durable_marker() {
  local home out marker
  home=$(new_home watch-marker)
  out=$(FM_HOME="$home" "$WATCH" mark-due when-dream-due)
  assert_contains "$out" 'dream due marker written' 'mark-due did not confirm the marker'
  marker=$(cat "$home/state/.dream-due")
  assert_contains "$marker" 'when-dream-due' 'marker did not record the source id'
  pass 'mark-due writes the durable dream-due marker'
}

test_watch_arm_dry_run_prints_argv() {
  local home out
  home=$(new_home watch-arm)
  out=$(FM_HOME="$home" "$WATCH" arm --dry-run)
  assert_contains "$out" 'would arm: bin/fm-procevent-when.sh arm dream-due' \
    'arm dry-run did not name the when watch'
  assert_contains "$out" 'fm-dreamer-watch.sh check --head-age 12' \
    'arm dry-run condition argv is missing or wrong'
  assert_contains "$out" 'fm-dreamer-watch.sh mark-due when-dream-due' \
    'arm dry-run action argv is missing or wrong'
  # The registered spec must be self-contained: both argv vectors pin the home
  # rather than depending on whatever environment the runner carries.
  assert_contains "$out" "check --head-age 12 --home $home" \
    'arm dry-run condition argv does not pin the resolved home'
  assert_contains "$out" "mark-due when-dream-due --home $home" \
    'arm dry-run action argv does not pin the resolved home'
  assert_absent "$home/state/.dream-due" 'arm dry-run must not write the marker'
  pass 'arm --dry-run prints the exact when registration argv without registering'
}

# --- 3. Grader rubric --------------------------------------------------------

# valid_gen0: a home whose published HEAD is a real, verifying generation so a
# later proposed generation can be graded against it.
build_passing_home() {
  local home=$1
  printf 'SOURCE\n' > "$home/data/source.md"
  printf '# Captain\n- Rule One: always test changes\n' > "$home/data/captain.md"
  local gen0="$home/data/memory/gen/0"
  mkdir -p "$gen0/notes"
  printf '# Core\n<!-- source: data/captain.md -->\n- Rule One: always test changes\n' > "$gen0/core.md"
  write_note "$gen0/notes" n1 'Standing Note' 'test' 2026-08-20 'data/source.md'
  printf 'gen/0\n' > "$home/data/memory/HEAD"
}

test_grade_approves_no_core_change() {
  local home out rc
  home=$(new_home grade-no-change)
  build_passing_home "$home"
  local gen1="$home/data/memory/gen/1"
  mkdir -p "$gen1/notes"
  printf '# Core\n<!-- source: data/captain.md -->\n- Rule One: always test changes\n' > "$gen1/core.md"
  write_note "$gen1/notes" n1 'Standing Note' 'test' 2026-08-20 'data/source.md'
  out=$(FM_HOME="$home" "$GRADE" grade gen/0 gen/1 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "grade rejected a safe no-op generation (exit $rc): $out"
  assert_contains "$out" 'GRADE APPROVED' 'grade did not approve a no-op generation'
  pass 'grade approves a proposed generation with no core change'
}

test_grade_rejects_failing_mechanical_verify() {
  local home out rc
  home=$(new_home grade-verify-fail)
  build_passing_home "$home"
  # A proposed generation that deletes every baseline note fails diff-bounds.
  local gen1="$home/data/memory/gen/1"
  mkdir -p "$gen1/notes"
  printf '# Core\n<!-- source: data/captain.md -->\n- Rule One: always test changes\n' > "$gen1/core.md"
  out=$(FM_HOME="$home" "$GRADE" grade gen/0 gen/1 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "grade did not reject a verifier-failing generation (exit $rc): $out"
  assert_contains "$out" 'FAIL grade' 'grade did not report the mechanical failure'
  pass 'grade rejects a proposed generation that fails the mechanical verifier'
}

test_grade_flags_tactical_scrap_as_warning() {
  local home out rc
  home=$(new_home grade-scrap)
  build_passing_home "$home"
  # New core passes verify (keeps the standing rule) but adds a dated recap
  # line, which the rubric surfaces as a possible tactical scrap.
  local gen1="$home/data/memory/gen/1"
  mkdir -p "$gen1/notes"
  {
    printf '# Core\n<!-- source: data/captain.md -->\n- Rule One: always test changes\n'
    printf -- '- on 2026-08-19 fm-abc-12 failed with a timeout\n'
  } > "$gen1/core.md"
  write_note "$gen1/notes" n1 'Standing Note' 'test' 2026-08-20 'data/source.md'
  out=$(FM_HOME="$home" "$GRADE" grade gen/0 gen/1 2>&1); rc=$?
  assert_contains "$out" 'possible tactical scrap' \
    'grade did not surface the dated recap as a tactical scrap'
  pass 'grade flags a dated incident recap as a possible tactical scrap'
}

test_grade_rejects_contradiction_of_standing_rule() {
  local home out rc
  home=$(new_home grade-contradiction)
  build_passing_home "$home"
  # New core preserves the standing rule (so verify passes) but also adds a
  # negation that reverses it, which the rubric rejects as a contradiction.
  local gen1="$home/data/memory/gen/1"
  mkdir -p "$gen1/notes"
  {
    printf '# Core\n<!-- source: data/captain.md -->\n- Rule One: always test changes\n'
    printf -- '- never test changes under any circumstance\n'
  } > "$gen1/core.md"
  write_note "$gen1/notes" n1 'Standing Note' 'test' 2026-08-20 'data/source.md'
  out=$(FM_HOME="$home" "$GRADE" grade gen/0 gen/1 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "grade did not reject a contradiction of a standing rule (exit $rc): $out"
  assert_contains "$out" 'contradicts a standing rule' \
    'grade did not report the standing-rule contradiction'
  pass 'grade rejects a new statement that contradicts a standing rule'
}

test_grade_approves_preserved_negative_standing_rule() {
  local home out rc core gen0 gen1
  home=$(new_home grade-preserved-rule)
  printf 'SOURCE\n' > "$home/data/source.md"
  core='# Core
<!-- source: data/captain.md -->
- Rule One: always test changes; never skip the suite'
  printf '# Captain\n- Rule One: always test changes; never skip the suite\n' > "$home/data/captain.md"
  gen0="$home/data/memory/gen/0"
  gen1="$home/data/memory/gen/1"
  mkdir -p "$gen0/notes" "$gen1/notes"
  # The mechanical verifier REQUIRES every standing rule to survive into the new
  # generation, so a preserved rule must never be read as contradicting itself.
  printf '%s\n' "$core" > "$gen0/core.md"
  printf '%s\n' "$core" > "$gen1/core.md"
  write_note "$gen0/notes" n1 'Standing Note' 'test' 2026-08-20 'data/source.md'
  write_note "$gen1/notes" n1 'Standing Note' 'test' 2026-08-20 'data/source.md'
  printf 'gen/0\n' > "$home/data/memory/HEAD"
  out=$(FM_HOME="$home" "$GRADE" grade gen/0 gen/1 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "grade rejected a verbatim-preserved standing rule (exit $rc): $out"
  assert_contains "$out" 'GRADE APPROVED' 'grade did not approve a preserved standing rule'
  pass 'grade does not read a preserved standing rule as contradicting itself'
}

test_grade_rejects_capitalised_contradiction() {
  local home out rc gen1
  home=$(new_home grade-contradiction-case)
  build_passing_home "$home"
  gen1="$home/data/memory/gen/1"
  mkdir -p "$gen1/notes"
  {
    printf '# Core\n<!-- source: data/captain.md -->\n- Rule One: always test changes\n'
    printf -- '- Never test changes under any circumstance\n'
  } > "$gen1/core.md"
  write_note "$gen1/notes" n1 'Standing Note' 'test' 2026-08-20 'data/source.md'
  out=$(FM_HOME="$home" "$GRADE" grade gen/0 gen/1 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "grade accepted a sentence-case contradiction (exit $rc): $out"
  assert_contains "$out" 'contradicts a standing rule' \
    'grade did not report the sentence-case contradiction'
  pass 'grade rejects a contradiction written in ordinary sentence case'
}

test_grade_inspects_changed_notes() {
  local home out gen1
  home=$(new_home grade-note-rubric)
  build_passing_home "$home"
  gen1="$home/data/memory/gen/1"
  mkdir -p "$gen1/notes"
  printf '# Core\n<!-- source: data/captain.md -->\n- Rule One: always test changes\n' > "$gen1/core.md"
  write_note "$gen1/notes" n1 'Standing Note' 'test' 2026-08-20 'data/source.md'
  # A claim smuggled into a note is published exactly like a core statement, so
  # the same rubric must reach it. The unchanged note above must stay silent.
  write_note "$gen1/notes" recap 'Recap' 'test' 2026-08-20 'data/source.md' \
    '- on 2026-08-19 fm-abc-12 failed with a timeout'
  out=$(FM_HOME="$home" "$GRADE" grade gen/0 gen/1 2>&1)
  assert_contains "$out" 'possible tactical scrap in changed note notes/recap.md' \
    'grade did not run the scrap rubric over a changed note'
  case "$out" in
    *'notes/n1.md'*) fail "grade flagged an unchanged note: $out" ;;
  esac
  pass 'grade runs the rubric over changed notes and skips unchanged ones'
}

test_grade_finishes_promptly_on_a_large_core() {
  local home out rc i gen0 gen1
  home=$(new_home grade-large-core)
  printf 'SOURCE\n' > "$home/data/source.md"
  {
    printf '# Captain\n'
    for i in $(seq 1 40); do
      printf -- '- Rule %s: always run the verification suite before merging change %s\n' "$i" "$i"
    done
  } > "$home/data/captain.md"
  gen0="$home/data/memory/gen/0"
  gen1="$home/data/memory/gen/1"
  mkdir -p "$gen0/notes" "$gen1/notes"
  {
    printf '# Core\n<!-- source: data/captain.md -->\n'
    for i in $(seq 1 40); do
      printf -- '- Rule %s: always run the verification suite before merging change %s\n' "$i" "$i"
    done
  } > "$gen0/core.md"
  cp "$gen0/core.md" "$gen1/core.md"
  write_note "$gen0/notes" n1 'Standing Note' 'test' 2026-08-20 'data/source.md'
  write_note "$gen1/notes" n1 'Standing Note' 'test' 2026-08-20 'data/source.md'
  printf 'gen/0\n' > "$home/data/memory/HEAD"
  # A realistically sized constitution must grade in seconds, not minutes: the
  # grader runs behind a bounded action timeout.
  out=$(FM_HOME="$home" timeout 30 "$GRADE" grade gen/0 gen/1 2>&1); rc=$?
  [ "$rc" -ne 124 ] || fail "grade did not finish within 30s on a 40-rule core: $out"
  [ "$rc" -eq 0 ] || fail "grade rejected an unchanged 40-rule core (exit $rc): $out"
  pass 'grade finishes promptly on a realistically sized core'
}

test_grade_approves_a_rule_echoing_the_citation_marker() {
  local home out rc gen1
  home=$(new_home grade-citation-marker)
  build_passing_home "$home"
  gen1="$home/data/memory/gen/1"
  mkdir -p "$gen1/notes"
  # The `<!-- source: ... -->` marker is mandatory in a non-empty core, and it
  # is not a standing rule. A new durable rule that happens to echo its words
  # must not be rejected as contradicting it.
  {
    printf '# Core\n<!-- source: data/captain.md -->\n- Rule One: always test changes\n'
    printf -- '- Never write a claim without a resolvable source in the data tree\n'
  } > "$gen1/core.md"
  write_note "$gen1/notes" n1 'Standing Note' 'test' 2026-08-20 'data/source.md'
  out=$(FM_HOME="$home" "$GRADE" grade gen/0 gen/1 2>&1); rc=$?
  [ "$rc" -eq 0 ] || fail "grade rejected a rule echoing the citation marker (exit $rc): $out"
  assert_contains "$out" 'GRADE APPROVED' 'grade did not approve a legitimate new rule'
  pass 'grade treats only bullet rules as standing rules'
}

test_grade_rejects_an_indented_contradiction() {
  local home out rc gen1
  home=$(new_home grade-indented-contradiction)
  build_passing_home "$home"
  gen1="$home/data/memory/gen/1"
  mkdir -p "$gen1/notes"
  # A nested bullet is an ordinary constitution form and the verifier reads it
  # as a standing rule, so indentation must not bypass the rubric.
  {
    printf '# Core\n<!-- source: data/captain.md -->\n- Rule One: always test changes\n'
    printf -- '  - never test changes under any circumstance\n'
  } > "$gen1/core.md"
  write_note "$gen1/notes" n1 'Standing Note' 'test' 2026-08-20 'data/source.md'
  out=$(FM_HOME="$home" "$GRADE" grade gen/0 gen/1 2>&1); rc=$?
  [ "$rc" -eq 1 ] || fail "an indented contradiction bypassed the rubric (exit $rc): $out"
  assert_contains "$out" 'contradicts a standing rule' \
    'grade did not report the indented contradiction'
  pass 'grade inspects indented bullets like top-level ones'
}

test_grade_surfaces_verifier_diagnostics() {
  local home out gen1
  home=$(new_home grade-verify-diagnostics)
  build_passing_home "$home"
  gen1="$home/data/memory/gen/1"
  mkdir -p "$gen1/notes"
  # Deleting every baseline note fails diff-bounds inside the verifier.
  printf '# Core\n<!-- source: data/captain.md -->\n- Rule One: always test changes\n' > "$gen1/core.md"
  out=$(FM_HOME="$home" "$GRADE" grade gen/0 gen/1 2>&1)
  assert_contains "$out" 'FAIL diff-bounds' \
    'grade swallowed the verifier diagnostic that explains the failure'
  pass 'grade surfaces which mechanical check failed and why'
}

test_grade_reports_a_bad_diff_ratio_as_a_usage_error() {
  local home out rc
  home=$(new_home grade-bad-ratio)
  build_passing_home "$home"
  out=$(FM_HOME="$home" "$GRADE" grade gen/0 gen/0 --max-diff-ratio 400 2>&1); rc=$?
  [ "$rc" -eq 2 ] || fail "a bad --max-diff-ratio did not exit 2 (exit $rc): $out"
  assert_contains "$out" 'max-diff-ratio' 'grade did not name the offending flag'
  assert_not_contains "$out" 'fails the mechanical verifier' \
    'a bad flag was reported as a memory-safety failure'
  pass 'grade reports a bad --max-diff-ratio as a usage error'
}

test_grade_scout_status_command_survives_a_space_in_the_home() {
  local home spaced out brief cmd
  home=$(new_home grade-scout-quoting)
  spaced="$home/a home with spaces"
  mkdir -p "$spaced/config" "$spaced/data" "$spaced/state"
  printf '7500\n' > "$spaced/config/startup-memory-budget"
  out=$(FM_HOME="$spaced" "$GRADE" scout grade-space firstmate gen/0 gen/1)
  brief="$spaced/data/grade-space/brief.md"
  assert_present "$brief" 'grader scout brief was not written'
  # The brief is a generated agent-facing contract: the status command it emits
  # must run as written. Execute it exactly as the agent would.
  # shellcheck disable=SC2016 # The backticks are literal sed pattern text: the brief wraps its status command in markdown backticks.
  cmd=$(sed -n 's/^[[:space:]]*`\(echo .*\)`$/\1/p' "$brief")
  [ -n "$cmd" ] || fail "no status-report command found in the scaffolded brief"
  cmd=${cmd//\{state\}/done}
  bash -c "$cmd" || fail "the scaffolded status command failed to run: $cmd"
  assert_present "$spaced/state/grade-space.status" \
    'the status command did not append into the home with a space'
  pass 'grade scout emits a status command that survives a space in the home path'
}

test_grade_scout_scaffolds_independent_grader_brief() {
  local home out brief content
  home=$(new_home grade-scout-brief)
  out=$(FM_HOME="$home" "$GRADE" scout grade-1 firstmate gen/0 gen/1)
  assert_contains "$out" 'grader scout' 'grade scout did not identify the deliverable'
  brief="$home/data/grade-1/brief.md"
  assert_present "$brief" 'grader scout brief was not written'
  content=$(cat "$brief")
  assert_contains "$content" 'INDEPENDENT GRADER' 'grader brief did not name the role'
  assert_contains "$content" 'gen/0' 'grader brief did not name the old generation'
  assert_contains "$content" 'gen/1' 'grader brief did not name the new generation'
  assert_contains "$content" 'APPROVE' 'grader brief lacks the APPROVE verdict'
  assert_contains "$content" 'REJECT' 'grader brief lacks the REJECT verdict'
  assert_contains "$content" 'never open a PR' 'grader brief does not forbid a PR'
  assert_contains "$content" 'Do NOT address the captain' \
    'grader brief does not forbid addressing the captain'
  pass 'grade scout scaffolds a fresh-context independent grader brief'
}

# --- 4. Full integration: dream -> verify -> grade -> publish ----------------

test_full_dream_loop_integration() {
  local home out
  home=$(new_home dream-loop)
  build_passing_home "$home"

  # Simulate a completed task depositing a drop, which the dreamer would read.
  mkdir -p "$home/data/fm-task-9"
  printf '# Report\nHealthlog needs xvfb for playwright.\n' > "$home/data/fm-task-9/report.md"
  # A finished task keeps its meta, with a recorded endpoint that is gone, so
  # the fleet reads as idle and the dream may run.
  printf 'project=healthlog\nreport=data/fm-task-9/report.md\nbackend=zellij\nwindow=fm-dreamer-test-gone:0\n' \
    > "$home/state/fm-task-9.meta"
  FM_HOME="$home" "$DROP" fm-task-9 --claim "Healthlog requires xvfb for playwright" >/dev/null

  # The watch sees the unconsumed drop and reports due.
  out=$(FM_HOME="$home" "$WATCH" check 2>&1)
  assert_contains "$out" 'DREAM_DUE: due' 'watch did not report due with a drop present'

  # A dreamer proposes generation 1 from the drop: a new abstraction with a
  # resolvable citation, preserving the standing rule AND the baseline note.
  local gen1="$home/data/memory/gen/1"
  mkdir -p "$gen1/notes"
  {
    printf '# Core\n<!-- source: data/captain.md -->\n- Rule One: always test changes\n'
  } > "$gen1/core.md"
  write_note "$gen1/notes" n1 'Standing Note' 'test' 2026-08-20 'data/source.md'
  write_note "$gen1/notes" healthlog 'Healthlog needs xvfb for playwright' 'healthlog' 2026-08-20 'data/fm-task-9/report.md' 'BODY-OF-HEALTHLOG-NOTE'

  # The mechanical verifier passes.
  out=$(FM_HOME="$home" "$VERIFY" 1)
  assert_contains "$out" 'VERIFICATION PASSED' 'verifier did not pass the proposed generation'

  # The grader approves (no core change, no contradictions).
  out=$(FM_HOME="$home" "$GRADE" grade gen/0 gen/1 2>&1)
  assert_contains "$out" 'GRADE APPROVED' 'grader did not approve the valid generation'

  # Firstmate publishes HEAD to the new generation.
  out=$(FM_HOME="$home" "$PUBLISH" 1)
  assert_contains "$out" 'published generation gen/1' 'publish did not update HEAD'
  [ "$(head -n 1 "$home/data/memory/HEAD")" = "gen/1" ] \
    || fail "HEAD does not point at gen/1 after publish"

  # The compiler now injects from the published generation.
  out=$(FM_HOME="$home" "$COMPILE" compile)
  assert_contains "$out" 'COMPILED WORKING MEMORY (data/memory/gen/1)' \
    'compiler did not compile from the published generation'
  assert_contains "$out" 'BODY-OF-HEALTHLOG-NOTE' \
    'compiler did not inject the promoted note from the published generation'

  pass 'dreamer loop composes: drop -> due -> verify -> grade -> publish -> compile'
}

# --- runner ------------------------------------------------------------------

test_dreamer_brief_scaffolds_contract
test_dreamer_brief_refuses_ship_mode
test_dreamer_brief_accepts_herdr_lab
test_watch_not_due_on_empty_home
test_watch_due_on_unconsumed_drop
test_watch_due_on_stale_head
test_watch_not_due_on_fresh_head
test_watch_blocked_by_live_non_dreamer_worker
test_watch_ignores_dreamer_prefixed_worker
test_watch_blocked_by_worker_with_unresolvable_endpoint
test_watch_counts_a_remote_worker_as_live
test_watch_accepts_a_symlinked_home
test_watch_arm_refuses_a_missing_home
test_watch_home_flag_pins_the_evaluated_home
test_watch_mark_due_home_flag_writes_into_the_pinned_home
test_watch_mark_due_writes_durable_marker
test_watch_arm_dry_run_prints_argv
test_grade_approves_no_core_change
test_grade_rejects_failing_mechanical_verify
test_grade_flags_tactical_scrap_as_warning
test_grade_rejects_contradiction_of_standing_rule
test_grade_approves_preserved_negative_standing_rule
test_grade_rejects_capitalised_contradiction
test_grade_inspects_changed_notes
test_grade_finishes_promptly_on_a_large_core
test_grade_approves_a_rule_echoing_the_citation_marker
test_grade_rejects_an_indented_contradiction
test_grade_surfaces_verifier_diagnostics
test_grade_reports_a_bad_diff_ratio_as_a_usage_error
test_grade_scout_status_command_survives_a_space_in_the_home
test_grade_scout_scaffolds_independent_grader_brief
test_full_dream_loop_integration
