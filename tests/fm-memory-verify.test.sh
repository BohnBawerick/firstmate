#!/usr/bin/env bash
# Behavioral coverage for Memory Slice 2: Drop Tray Capture Helper,
# Mechanical Safety Verifier, and Atomic Generation Publication Guard.
#
# Every assertion here runs real Firstmate helper scripts on disk and inspects
# real outputs, files, and exit codes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-memory-verify)
DROP="$ROOT/bin/fm-memory-drop.sh"
VERIFY="$ROOT/bin/fm-memory-verify.sh"
PUBLISH="$ROOT/bin/fm-memory-publish.sh"
COMPILE="$ROOT/bin/fm-memory-compile.sh"
SESSION_START="$ROOT/bin/fm-session-start.sh"

# new_home <name> [budget]: a clean test home with budget and standard directories
new_home() {
  local budget=${2:-7500} home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/data" "$home/state" "$home/data/memory" "$home/data/memory/drop"
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

# --- 1. Drop Tray Helper Tests ----------------------------------------------

test_drop_tray_capture_basic() {
  local home out drop_file
  home=$(new_home drop-basic)
  mkdir -p "$home/data/fm-task-1"
  printf '# Scout Report\nFindings from investigation.\n' > "$home/data/fm-task-1/report.md"
  printf 'project=healthlog\nreport=data/fm-task-1/report.md\n' > "$home/state/fm-task-1.meta"

  out=$(FM_HOME="$home" "$DROP" fm-task-1 \
    --claim "Healthlog requires xvfb for playwright tests" \
    --claim "Contention on port 9222 causes timeout")

  assert_contains "$out" 'drop: deposited candidate claims for fm-task-1' \
    'drop script did not report successful deposit'

  drop_file="$home/data/memory/drop/fm-task-1.md"
  assert_present "$drop_file" 'drop file was not created'

  local content
  content=$(cat "$drop_file")
  assert_contains "$content" 'task: fm-task-1' 'metadata missing task id'
  assert_contains "$content" 'project: healthlog' 'metadata missing auto-detected project'
  assert_contains "$content" 'report: data/fm-task-1/report.md' 'metadata missing auto-detected report'
  assert_contains "$content" 'Healthlog requires xvfb for playwright tests' 'missing candidate claim 1'
  assert_contains "$content" 'Contention on port 9222 causes timeout' 'missing candidate claim 2'

  pass 'drop tray captures task metadata and candidate claims'
}

test_drop_tray_idempotence_and_merge() {
  local home drop_file content
  home=$(new_home drop-idempotent)

  FM_HOME="$home" "$DROP" fm-task-merge --claim "Initial claim A" >/dev/null
  FM_HOME="$home" "$DROP" fm-task-merge --claim "New claim B" --claim "Initial claim A" >/dev/null

  drop_file="$home/data/memory/drop/fm-task-merge.md"
  assert_present "$drop_file" 'drop file missing after second run'
  content=$(cat "$drop_file")

  assert_contains "$content" 'Initial claim A' 'original claim was lost on rerun'
  assert_contains "$content" 'New claim B' 'new claim was not merged on rerun'

  local count_a
  count_a=$(grep -c 'Initial claim A' "$drop_file")
  [ "$count_a" -eq 1 ] || fail "duplicate claim was not deduplicated: count=$count_a"

  pass 'drop tray is idempotent and merges new claims without duplicates'
}

test_drop_tray_graceful_missing_records() {
  local home drop_file content
  home=$(new_home drop-missing-records)

  # No meta, no report, no explicit claims
  FM_HOME="$home" "$DROP" fm-orphan-task >/dev/null

  drop_file="$home/data/memory/drop/fm-orphan-task.md"
  assert_present "$drop_file" 'drop file not created for orphan task'
  content=$(cat "$drop_file")
  assert_contains "$content" 'task: fm-orphan-task' 'missing task id'
  assert_contains "$content" 'Task completed: fm-orphan-task' 'fallback claim missing'

  pass 'drop tray fails gracefully and records fallback claims when input records are missing'
}

test_drop_tray_safety_and_path_traversal() {
  local home
  home=$(new_home drop-safety)

  if FM_HOME="$home" "$DROP" "../../etc/passwd" 2>/dev/null; then
    fail 'drop script accepted path traversal task id'
  fi

  if FM_HOME="$home" "$DROP" "" 2>/dev/null; then
    fail 'drop script accepted empty task id'
  fi

  pass 'drop tray rejects path traversal and invalid task identifiers'
}

# --- 2. Budget Refusal Tests ------------------------------------------------

test_verify_refuses_oversized_generation() {
  local home gen_dir out
  home=$(new_home budget-refusal 100)
  gen_dir="$home/data/memory/gen/1"
  mkdir -p "$gen_dir/notes"

  # Core alone exceeds 100 tokens
  printf '# Core Constitution\n\n' > "$gen_dir/core.md"
  for i in $(seq 1 50); do
    printf 'This is a long standing rule sentence %s with lots of words exceeding the tiny budget cap.\n' "$i" >> "$gen_dir/core.md"
  done

  # Also write an existing file for citation
  printf 'EXISTING\n' > "$home/data/source.md"
  printf '<!-- source: data/source.md -->\n' >> "$gen_dir/core.md"

  if out=$(FM_HOME="$home" "$VERIFY" 1 2>&1); then
    fail "verify passed an oversized generation: $out"
  fi

  assert_contains "$out" 'FAIL budget' 'verify output did not report budget failure'
  assert_contains "$out" 'VERIFICATION FAILED' 'verification did not fail'

  pass 'verifier refuses a proposed generation whose bundle exceeds the startup budget'
}

# --- 3. Citation Check Tests ------------------------------------------------

test_verify_refuses_missing_or_unresolvable_citations() {
  local home gen_dir out
  home=$(new_home citation-refusal 7500)
  gen_dir="$home/data/memory/gen/1"
  mkdir -p "$gen_dir/notes"
  printf '# Core\n<!-- source: data/captain.md -->\nStanding preferences.\n' > "$gen_dir/core.md"
  printf '# Captain\n- Autonomy: standard\n' > "$home/data/captain.md"

  # Note 1: No citations at all
  cat <<'NOTE' > "$gen_dir/notes/uncited-note.md"
---
title: Uncited claim
triggers: uncited
updated: 2026-08-20
---

# Uncited claim

This claim has no citation.
NOTE

  if out=$(FM_HOME="$home" "$VERIFY" 1 2>&1); then
    fail "verify passed a note with no citations: $out"
  fi
  assert_contains "$out" 'FAIL citations' 'verifier did not fail on uncited note'

  # Note 2: Citing a non-existent file
  cat <<'NOTE' > "$gen_dir/notes/uncited-note.md"
---
title: Fake citation claim
triggers: fake
updated: 2026-08-20
source: data/nonexistent-report.md
---

# Fake citation claim

This cites data/nonexistent-report.md which does not exist.
NOTE

  if out=$(FM_HOME="$home" "$VERIFY" 1 2>&1); then
    fail "verify passed a note with a fake non-existent citation: $out"
  fi
  assert_contains "$out" 'FAIL citations' 'verifier did not fail on non-existent citation'
  assert_contains "$out" 'nonexistent-report.md' 'error did not name the missing cited file'

  pass 'verifier refuses proposed generations with missing or unresolvable citations'
}

# --- 4. Standing Constitution Safety Tests ----------------------------------

test_verify_refuses_silent_standing_rule_deletion() {
  local home gen_dir out
  home=$(new_home constitution-safety 7500)
  gen_dir="$home/data/memory/gen/1"
  mkdir -p "$gen_dir/notes"

  # Baseline captain.md with standing preferences
  cat <<'CAPTAIN' > "$home/data/captain.md"
# Captain preferences

## Autonomy & delivery
- Never merge a PR without explicit captain approval
- Always run no-mistakes validation before delivery
- Keep concurrency high and avoid serial stalls
CAPTAIN

  # Proposed core.md that silently dropped "Never merge a PR without explicit captain approval"
  cat <<'CORE' > "$gen_dir/core.md"
# Core Memory

<!-- source: data/captain.md -->

## Autonomy & delivery
- Always run no-mistakes validation before delivery
- Keep concurrency high and avoid serial stalls
CORE

  # Add a valid cited note
  printf 'VALID\n' > "$home/data/source.md"
  write_note "$gen_dir/notes" valid 'Valid Note' 'valid' 2026-08-20 'data/source.md'

  if out=$(FM_HOME="$home" "$VERIFY" 1 2>&1); then
    fail "verify passed a generation that silently deleted standing captain preference: $out"
  fi

  assert_contains "$out" 'FAIL constitution' 'verifier did not report constitution failure'
  assert_contains "$out" 'Never merge a PR without explicit captain approval' \
    'error did not name the deleted standing preference rule'

  pass 'verifier refuses proposed generations that silently drop standing captain preferences'
}

# --- 5. Diff Bounds Check Tests ---------------------------------------------

test_verify_refuses_excessive_deletion_diff_bounds() {
  local home gen0_dir gen1_dir out
  home=$(new_home diff-bounds 7500)
  printf 'SOURCE\n' > "$home/data/source.md"

  # Generation 0 (baseline) with 4 notes
  gen0_dir="$home/data/memory/gen/0"
  mkdir -p "$gen0_dir/notes"
  printf '# Core\n<!-- source: data/captain.md -->\n- Rule A\n' > "$gen0_dir/core.md"
  printf '# Captain\n- Rule A\n' > "$home/data/captain.md"
  write_note "$gen0_dir/notes" note1 'Note 1' 'one' 2026-08-01 'data/source.md'
  write_note "$gen0_dir/notes" note2 'Note 2' 'two' 2026-08-02 'data/source.md'
  write_note "$gen0_dir/notes" note3 'Note 3' 'three' 2026-08-03 'data/source.md'
  write_note "$gen0_dir/notes" note4 'Note 4' 'four' 2026-08-04 'data/source.md'

  # Publish Gen 0 to HEAD
  printf 'gen/0\n' > "$home/data/memory/HEAD"

  # Proposed Generation 1 deletes 3 out of 4 notes (75% deletion > 50% cap)
  gen1_dir="$home/data/memory/gen/1"
  mkdir -p "$gen1_dir/notes"
  printf '# Core\n<!-- source: data/captain.md -->\n- Rule A\n' > "$gen1_dir/core.md"
  write_note "$gen1_dir/notes" note1 'Note 1' 'one' 2026-08-01 'data/source.md'

  if out=$(FM_HOME="$home" "$VERIFY" 1 2>&1); then
    fail "verify passed a generation that deleted 75% of baseline notes: $out"
  fi

  assert_contains "$out" 'FAIL diff-bounds' 'verifier did not report diff-bounds failure'
  assert_contains "$out" '75%' 'error did not mention the deletion percentage'

  pass 'verifier refuses proposed generations that delete excessive proportions of memory'
}

# --- 6. Atomic Publication & Compiler / Session Start Compatibility ---------

test_atomic_publish_and_compiler_integration() {
  local home gen_dir out publish_out compile_out head_content
  home=$(new_home publish-flow 7500)
  printf 'SOURCE\n' > "$home/data/source.md"
  printf '# Captain\n- Rule One: always test\n' > "$home/data/captain.md"
  printf -- '- testproj [no-mistakes] - test project\n' > "$home/data/projects.md"

  gen_dir="$home/data/memory/gen/1"
  mkdir -p "$gen_dir/notes"
  printf '# Core\n<!-- source: data/captain.md -->\n- Rule One: always test\n' > "$gen_dir/core.md"
  write_note "$gen_dir/notes" testnote 'Test Note Claim' 'testproj' 2026-08-20 'data/source.md' 'BODY-OF-GEN1-NOTE'

  # 1. Run verify mode directly
  out=$(FM_HOME="$home" "$VERIFY" 1)
  assert_contains "$out" 'VERIFICATION PASSED' 'verify did not pass valid generation'
  assert_absent "$home/data/memory/HEAD" 'verify mode wrote HEAD unexpectedly'

  # 2. Run publish mode
  publish_out=$(FM_HOME="$home" "$PUBLISH" 1)
  assert_contains "$publish_out" 'memory: published generation gen/1 to data/memory/HEAD' \
    'publish output did not confirm publication'

  assert_present "$home/data/memory/HEAD" 'HEAD pointer file was not created'
  head_content=$(head -n 1 "$home/data/memory/HEAD")
  [ "$head_content" = "gen/1" ] || fail "HEAD contains unexpected value: $head_content"

  # 3. Test compiler reads from HEAD
  compile_out=$(FM_HOME="$home" "$COMPILE" compile)
  assert_contains "$compile_out" 'COMPILED WORKING MEMORY (data/memory/gen/1)' \
    'compiler did not compile from gen/1 generation'
  assert_contains "$compile_out" 'BODY-OF-GEN1-NOTE' \
    'compiler did not inject hot note from gen/1'
  assert_contains "$compile_out" 'Test Note Claim' \
    'compiler did not include catalog entry from gen/1'

  # 4. Test session-start compiles from HEAD
  local session_out
  session_out=$(FM_HOME="$home" "$SESSION_START" 2>&1 || true)
  assert_contains "$session_out" 'COMPILED WORKING MEMORY (data/memory/gen/1)' \
    'session start did not compile memory from gen/1 generation'
  assert_contains "$session_out" 'BODY-OF-GEN1-NOTE' \
    'session start did not inject note from gen/1 generation'

  pass 'atomic publish updates HEAD pointer and compiler/session-start inject from the published generation'
}

test_publish_dry_run_leaves_head_unchanged() {
  local home gen_dir out
  home=$(new_home publish-dry-run 7500)
  printf 'SOURCE\n' > "$home/data/source.md"
  printf '# Captain\n- Rule Alpha\n' > "$home/data/captain.md"

  gen_dir="$home/data/memory/gen/1"
  mkdir -p "$gen_dir/notes"
  printf '# Core\n<!-- source: data/captain.md -->\n- Rule Alpha\n' > "$gen_dir/core.md"
  write_note "$gen_dir/notes" n1 'Note 1' 'test' 2026-08-20 'data/source.md'

  out=$(FM_HOME="$home" "$PUBLISH" 1 --dry-run)
  assert_contains "$out" 'publish: --dry-run' 'publish dry run did not report dry run'
  assert_absent "$home/data/memory/HEAD" 'publish dry run wrote HEAD'

  pass 'publish --dry-run verifies all checks and leaves HEAD unchanged'
}

# --- Run All Tests ----------------------------------------------------------

test_drop_tray_capture_basic
test_drop_tray_idempotence_and_merge
test_drop_tray_graceful_missing_records
test_drop_tray_safety_and_path_traversal
test_verify_refuses_oversized_generation
test_verify_refuses_missing_or_unresolvable_citations
test_verify_refuses_silent_standing_rule_deletion
test_verify_refuses_excessive_deletion_diff_bounds
test_atomic_publish_and_compiler_integration
test_publish_dry_run_leaves_head_unchanged

printf '# all fm-memory-verify tests passed\n'
exit 0
