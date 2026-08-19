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

# --- 7. Regression Coverage -------------------------------------------------

test_publish_path_form_target_writes_resolvable_head() {
  local home gen_dir publish_out head_content compile_out out
  home=$(new_home publish-path-form 7500)
  printf 'SOURCE\n' > "$home/data/source.md"
  printf '# Captain\n- Rule One: always test\n' > "$home/data/captain.md"

  gen_dir="$home/data/memory/gen/1"
  mkdir -p "$gen_dir/notes"
  printf '# Core\n<!-- source: data/captain.md -->\n- Rule One: always test\n' > "$gen_dir/core.md"
  write_note "$gen_dir/notes" pathnote 'Path Form Note' 'pathform' 2026-08-20 'data/source.md' 'BODY-OF-PATH-FORM-NOTE'

  # Publish by the directory path rather than the bare generation number.
  publish_out=$(cd "$home" && FM_HOME="$home" "$PUBLISH" data/memory/gen/1)
  assert_contains "$publish_out" 'memory: published generation gen/1' \
    'path-form publish did not normalise the identifier'

  head_content=$(head -n 1 "$home/data/memory/HEAD")
  [ "$head_content" = "gen/1" ] || fail "HEAD holds an unresolvable pointer: $head_content"

  compile_out=$(FM_HOME="$home" "$COMPILE" compile)
  assert_contains "$compile_out" 'COMPILED WORKING MEMORY (data/memory/gen/1)' \
    'compiler did not resolve HEAD written by a path-form publish'
  assert_contains "$compile_out" 'Path Form Note (pathnote.md' \
    'compiler did not catalogue the published generation note'

  # An absolute path to the same directory normalises identically.
  rm -f "$home/data/memory/HEAD"
  publish_out=$(FM_HOME="$home" "$PUBLISH" "$gen_dir")
  head_content=$(head -n 1 "$home/data/memory/HEAD")
  [ "$head_content" = "gen/1" ] || fail "absolute-path publish wrote an unresolvable pointer: $head_content"

  # A generation outside data/memory can never become a resolvable pointer.
  mkdir -p "$home/outside/notes"
  printf '# Core\n<!-- source: data/captain.md -->\n- Rule One: always test\n' > "$home/outside/core.md"
  write_note "$home/outside/notes" n1 'Outside Note' 'outside' 2026-08-20 'data/source.md'
  if out=$(FM_HOME="$home" "$PUBLISH" "$home/outside" 2>&1); then
    fail "publish accepted a generation outside data/memory: $out"
  fi
  assert_contains "$out" 'must live under data/memory' \
    'publish did not explain why an out-of-tree generation is refused'

  pass 'publish normalises any target form into a data/memory-relative HEAD pointer the compiler resolves'
}

test_compile_reports_unresolvable_head_pointer() {
  local home compile_out
  home=$(new_home head-dangling 7500)
  printf 'SOURCE\n' > "$home/data/source.md"
  write_note "$home/data/memory/notes" fallback 'Fallback Note' 'fallback' 2026-08-20 'data/source.md'
  printf 'gen/42\n' > "$home/data/memory/HEAD"

  compile_out=$(FM_HOME="$home" "$COMPILE" compile)
  assert_contains "$compile_out" 'COMPILED WORKING MEMORY (data/memory)' \
    'compiler did not fall back to data/memory for a dangling HEAD'
  assert_contains "$compile_out" 'MEMORY_NOTICE: data/memory/HEAD names "gen/42"' \
    'compiler silently ignored an unresolvable HEAD pointer'

  pass 'compiler surfaces an unresolvable data/memory/HEAD pointer as a notice instead of degrading silently'
}

test_verify_refuses_full_deletion_of_small_baseline() {
  local home gen0_dir gen1_dir out
  home=$(new_home diff-bounds-small 7500)
  printf 'SOURCE\n' > "$home/data/source.md"
  printf '# Captain\n- Rule A\n' > "$home/data/captain.md"

  gen0_dir="$home/data/memory/gen/0"
  mkdir -p "$gen0_dir/notes"
  printf '# Core\n<!-- source: data/captain.md -->\n- Rule A\n' > "$gen0_dir/core.md"
  write_note "$gen0_dir/notes" a 'Note A' 'a' 2026-08-01 'data/source.md'
  write_note "$gen0_dir/notes" b 'Note B' 'b' 2026-08-02 'data/source.md'
  printf 'gen/0\n' > "$home/data/memory/HEAD"

  # Two baseline notes replaced wholesale by two unrelated notes.
  gen1_dir="$home/data/memory/gen/1"
  mkdir -p "$gen1_dir/notes"
  printf '# Core\n<!-- source: data/captain.md -->\n- Rule A\n' > "$gen1_dir/core.md"
  write_note "$gen1_dir/notes" x 'Note X' 'x' 2026-08-03 'data/source.md'
  write_note "$gen1_dir/notes" y 'Note Y' 'y' 2026-08-04 'data/source.md'

  if out=$(FM_HOME="$home" "$VERIFY" 1 2>&1); then
    fail "verify passed a generation that deleted every baseline note: $out"
  fi
  assert_contains "$out" 'FAIL diff-bounds' 'verifier did not report diff-bounds failure'
  assert_contains "$out" 'deletes every one of the 2 baseline note(s)' \
    'error did not name the wholesale baseline deletion'

  pass 'verifier refuses a generation that deletes every note of a baseline too small for the percentage cap'
}

test_verify_resolves_citations_frozen_by_migration() {
  local home gen_dir out
  home=$(new_home citations-migrated 7500)
  printf '# Captain\n- Rule A\n' > "$home/data/captain.md"

  # bin/fm-memory-migrate.sh stamps notes with data/learnings.md, freezes the
  # original under data/memory/raw/, and only then removes it from data/.
  mkdir -p "$home/data/memory/raw"
  printf '# Learnings\nOriginal content.\n' > "$home/data/memory/raw/learnings-2026-08-20.md"
  printf 'archived under a dated banner\n' > "$home/data/memory-archive.md"
  assert_absent "$home/data/learnings.md" 'test fixture left the pre-migration file in place'

  gen_dir="$home/data/memory/gen/1"
  mkdir -p "$gen_dir/notes"
  printf '# Core\n<!-- source: data/captain.md -->\n- Rule A\n' > "$gen_dir/core.md"
  write_note "$gen_dir/notes" migrated 'Migrated Note' 'migrated' 2026-08-20 'data/learnings.md'

  out=$(FM_HOME="$home" "$VERIFY" 1) \
    || fail "verify rejected a generation built from a migrated home: $out"
  assert_contains "$out" 'PASS citations' 'migrated provenance did not resolve'

  # A citation that was never frozen anywhere is still refused.
  write_note "$gen_dir/notes" bogus 'Bogus Note' 'bogus' 2026-08-20 'data/never-existed.md'
  if out=$(FM_HOME="$home" "$VERIFY" 1 2>&1); then
    fail "verify passed an unfrozen, non-existent citation: $out"
  fi
  assert_contains "$out" 'data/never-existed.md' 'error did not name the unresolvable citation'

  pass 'verifier resolves note provenance that bin/fm-memory-migrate.sh froze under data/memory/raw'
}

test_verify_accepts_bare_path_citation_in_note_body() {
  local home gen_dir out
  home=$(new_home citations-bare-path 7500)
  printf 'SOURCE\n' > "$home/data/source.md"
  printf '# Captain\n- Rule A\n' > "$home/data/captain.md"

  gen_dir="$home/data/memory/gen/1"
  mkdir -p "$gen_dir/notes"
  printf '# Core\n<!-- source: data/captain.md -->\n- Rule A\n' > "$gen_dir/core.md"

  # No source frontmatter at all: the only citation is a bare path in the body.
  cat <<'NOTE' > "$gen_dir/notes/barepath.md"
---
title: Bare path claim
triggers: barepath
updated: 2026-08-20
---

# Bare path claim

Observed while reading data/source.md during the run.
NOTE

  out=$(FM_HOME="$home" "$VERIFY" 1) \
    || fail "verify rejected a note whose only citation is a bare body path: $out"
  assert_contains "$out" 'PASS citations' 'bare body path was not extracted as a citation'

  pass 'verifier extracts bare data/ paths from a note body regardless of the host awk implementation'
}

test_verify_requires_citations_in_non_empty_core() {
  local home gen_dir out
  home=$(new_home core-citations 7500)
  printf 'SOURCE\n' > "$home/data/source.md"

  gen_dir="$home/data/memory/gen/1"
  mkdir -p "$gen_dir/notes"
  printf '# Core Memory\n\n- Always run the validation gate before delivery.\n' > "$gen_dir/core.md"
  write_note "$gen_dir/notes" n1 'Note 1' 'one' 2026-08-20 'data/source.md'

  if out=$(FM_HOME="$home" "$VERIFY" 1 2>&1); then
    fail "verify passed a non-empty core.md carrying no citations: $out"
  fi
  assert_contains "$out" 'FAIL citations: core.md has no citations or source metadata' \
    'verifier did not require a citation on a non-empty core.md'

  # Adding a resolvable citation clears the failure.
  printf '<!-- source: data/source.md -->\n' >> "$gen_dir/core.md"
  out=$(FM_HOME="$home" "$VERIFY" 1) \
    || fail "verify rejected a cited core.md: $out"
  assert_contains "$out" 'PASS citations' 'cited core.md did not pass'

  pass 'verifier requires a resolvable citation on a non-empty core.md, matching its documented contract'
}

test_verify_refuses_generation_whose_catalog_is_dropped() {
  local home gen_dir out i accounting
  home=$(new_home catalog-dropped 340)
  printf 'SOURCE\n' > "$home/data/source.md"

  gen_dir="$home/data/memory/gen/1"
  mkdir -p "$gen_dir/notes"

  # Core fits on its own but leaves no room for the catalog, so the compiler
  # drops the catalog and every note and reports catalog=0.
  printf '# Core Memory\n<!-- source: data/source.md -->\n' > "$gen_dir/core.md"
  for i in $(seq 1 12); do
    printf -- '- Standing rule number %s with a fair amount of explanatory wording attached.\n' "$i" \
      >> "$gen_dir/core.md"
  done
  for i in $(seq 1 12); do
    write_note "$gen_dir/notes" "note$i" "Catalogued Note $i" "trigger$i" 2026-08-20 'data/source.md'
  done

  accounting=$(FM_HOME="$home" "$COMPILE" compile --memory-dir "$gen_dir" | grep '^MEMORY_ACCOUNTING:')
  assert_contains "$accounting" 'catalog=0' 'fixture did not produce a dropped catalog'
  assert_contains "$accounting" 'status=capped' 'fixture was over-budget rather than capped'

  if out=$(FM_HOME="$home" "$VERIFY" 1 2>&1); then
    fail "verify passed a generation whose catalog and every note were dropped: $out"
  fi
  assert_contains "$out" 'FAIL budget' 'verifier accepted a fully capped generation'
  assert_contains "$out" 'no note is reachable' 'error did not explain the unusable bundle'

  pass 'verifier refuses a capped generation whose catalog was dropped, leaving no note reachable'
}

test_drop_tray_keeps_claim_matching_two_adjacent_claims() {
  local home drop_file content out
  home=$(new_home drop-dedup-collision)

  out=$(FM_HOME="$home" "$DROP" fm-task-dedup \
    --claim "First" \
    --claim "Second" \
    --claim "First Second")

  assert_contains "$out" '(3 claim(s))' "drop discarded a distinct claim: $out"

  drop_file="$home/data/memory/drop/fm-task-dedup.md"
  content=$(cat "$drop_file")
  assert_contains "$content" '- First Second' 'drop file lost the claim that concatenates two earlier claims'

  # A genuine repeat is still collapsed.
  out=$(FM_HOME="$home" "$DROP" fm-task-dedup --claim "First")
  assert_contains "$out" '(3 claim(s))' "drop stopped deduplicating exact repeats: $out"

  pass 'drop tray dedup keeps a claim that merely concatenates two already captured claims'
}

# --- 8. Portability And Reporting Regressions -------------------------------

# Stock macOS ships Bash 3.2, which has neither `mapfile` nor `readarray`. The
# CI parse sweep only runs `bash -n`, so a Bash 4 builtin survives it and fails
# at runtime. Sourcing the verifier from a shell with those builtins disabled
# reproduces that host without needing a 3.2 interpreter here.
test_verify_runs_without_bash4_builtins() {
  local home gen_dir sim out
  home=$(new_home bash32-sim 7500)
  printf 'SOURCE\n' > "$home/data/source.md"
  printf '# Captain\n- Rule A\n' > "$home/data/captain.md"

  gen_dir="$home/data/memory/gen/1"
  mkdir -p "$gen_dir/notes"
  printf '# Core\n<!-- source: data/captain.md -->\n- Rule A\n' > "$gen_dir/core.md"
  write_note "$gen_dir/notes" n1 'Note 1' 'one' 2026-08-20 'data/source.md'

  sim="$home/bash32-sim.sh"
  cat <<'SIM' > "$sim"
#!/usr/bin/env bash
enable -n mapfile 2>/dev/null || true
enable -n readarray 2>/dev/null || true
. "$FM_SIM_TARGET"
SIM
  chmod +x "$sim"

  out=$(FM_SIM_TARGET="$VERIFY" FM_HOME="$home" bash "$sim" 1 2>&1) \
    || fail "verifier failed with Bash 4 builtins disabled: $out"
  assert_contains "$out" 'PASS citations' 'citation check did not run without Bash 4 builtins'
  assert_contains "$out" 'VERIFICATION PASSED' 'verification did not pass without Bash 4 builtins'
  assert_not_contains "$out" 'has no citations or source metadata' \
    'cited notes were falsely reported as uncited without Bash 4 builtins'

  pass 'verifier runs its citation check on a shell without the Bash 4 mapfile builtin'
}

test_verify_accepts_note_with_incidental_unresolvable_prose_path() {
  local home gen_dir out
  home=$(new_home citations-incidental 7500)
  printf 'SOURCE\n' > "$home/data/source.md"
  printf '# Captain\n- Rule A\n' > "$home/data/captain.md"

  gen_dir="$home/data/memory/gen/1"
  mkdir -p "$gen_dir/notes"
  printf '# Core\n<!-- source: data/captain.md -->\n- Rule A\n' > "$gen_dir/core.md"
  write_note "$gen_dir/notes" mixed 'Mixed Note' 'mixed' 2026-08-20 'data/source.md' \
    'We hit this while cleaning up data/old-report.md last month.'

  out=$(FM_HOME="$home" "$VERIFY" 1 2>&1) \
    || fail "verify refused a note that cites a resolvable source alongside prose: $out"
  assert_contains "$out" 'PASS citations' 'note with one resolvable citation did not pass'
  assert_contains "$out" 'WARN citations: note notes/mixed.md mentions unresolvable path(s): "data/old-report.md"' \
    'the incidental path was dropped from the report instead of being surfaced'

  # A note whose every extracted path is unresolvable is still refused.
  write_note "$gen_dir/notes" broken 'Broken Note' 'broken' 2026-08-20 'data/gone.md'
  if out=$(FM_HOME="$home" "$VERIFY" 1 2>&1); then
    fail "verify passed a note with no resolvable citation at all: $out"
  fi
  assert_contains "$out" 'FAIL citations: note notes/broken.md cites missing or unresolvable source' \
    'a wholly uncited note was not refused'

  pass 'a note is accepted when at least one citation resolves, and an incidental prose path is reported not fatal'
}

test_catalog_mode_reports_the_generation_it_wrote() {
  local home gen_dir out catalog_body
  home=$(new_home catalog-paths 7500)
  printf 'SOURCE\n' > "$home/data/source.md"
  printf '# Captain\n- Rule A\n' > "$home/data/captain.md"

  gen_dir="$home/data/memory/gen/1"
  mkdir -p "$gen_dir/notes"
  printf '# Core\n<!-- source: data/captain.md -->\n- Rule A\n' > "$gen_dir/core.md"
  write_note "$gen_dir/notes" n1 'Catalogued Note' 'catalogued' 2026-08-20 'data/source.md'
  FM_HOME="$home" "$PUBLISH" 1 >/dev/null

  out=$(FM_HOME="$home" "$COMPILE" catalog)
  assert_contains "$out" 'catalog: published data/memory/gen/1/catalog.md' \
    'catalog mode named a path it did not write'
  assert_present "$gen_dir/catalog.md" 'catalog was not written into the active generation'
  assert_absent "$home/data/memory/catalog.md" 'catalog was written outside the active generation'

  # data/memory/gen/1/catalog.md is the compiler's own generated output, so its
  # provenance header is part of that generated contract.
  catalog_body=$(cat "$gen_dir/catalog.md")
  assert_contains "$catalog_body" 'from data/memory/gen/1/notes/' \
    'the published catalog claims provenance from the wrong notes directory'

  pass 'catalog mode names and labels the active generation it actually wrote'
}

test_compile_reads_resolved_dir_when_data_memory_is_a_symlink() {
  local home gen_dir out
  home=$(new_home memory-symlink 7500)
  printf 'SOURCE\n' > "$home/data/source.md"

  # data/memory itself is a symlink, but the generation handed to --memory-dir
  # is a real directory: exactly how fm-memory-verify.sh calls the compiler.
  rmdir "$home/data/memory/drop" "$home/data/memory"
  mkdir -p "$home/data/real-memory/gen/1/notes"
  ln -s "$home/data/real-memory" "$home/data/memory"
  gen_dir="$home/data/real-memory/gen/1"
  printf '# Core\n<!-- source: data/source.md -->\n- Rule A\n' > "$gen_dir/core.md"
  write_note "$gen_dir/notes" n1 'Symlinked Home Note' 'symlinked' 2026-08-20 'data/source.md'

  out=$(FM_HOME="$home" "$COMPILE" compile --memory-dir "$gen_dir")
  assert_contains "$out" 'Symlinked Home Note' \
    'compiler skipped the note inventory of a real directory under a symlinked data/memory'
  assert_contains "$out" 'notes_total=1' \
    'compiler measured an empty bundle for a real generation directory'
  assert_not_contains "$out" 'core: ABSENT' \
    'compiler skipped core.md of a real directory under a symlinked data/memory'

  pass 'compiler measures the resolved generation even when data/memory itself is a symlink'
}

# --- 9. Symlinked Memory Root And Citation Provenance ------------------------

test_compile_refuses_to_traverse_a_symlinked_memory_root() {
  local home gen_dir out rc
  home=$(new_home symlink-root 7500)
  printf 'SOURCE\n' > "$home/data/source.md"

  # The active generation is reached only by traversing a symlinked data/memory,
  # which defeats every per-file guard inside it in one step.
  rmdir "$home/data/memory/drop" "$home/data/memory"
  mkdir -p "$home/data/real/gen/1/notes"
  ln -s "$home/data/real" "$home/data/memory"
  gen_dir="$home/data/real/gen/1"
  printf 'gen/1\n' > "$home/data/real/HEAD"
  printf '# Core\n<!-- source: data/source.md -->\n- Rule A\n' > "$gen_dir/core.md"
  write_note "$gen_dir/notes" n1 'Through The Link' 'linked' 2026-08-20 'data/source.md'

  set +e
  out=$(FM_HOME="$home" "$COMPILE" catalog 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "catalog mode published through a symlinked data/memory: $out"
  assert_contains "$out" 'data/memory is a symlink; refusing to publish through it' \
    'the refusal did not name data/memory as the symlink'
  assert_absent "$gen_dir/catalog.md" 'catalog was written through the symlinked memory root'

  # compile mode degrades instead of dying, but must not read through the link.
  out=$(FM_HOME="$home" "$COMPILE" compile)
  assert_not_contains "$out" 'Through The Link' \
    'compiler injected a note read through a symlinked data/memory'
  assert_contains "$out" 'notes_total=0' \
    'compiler inventoried notes through a symlinked data/memory'

  pass 'a symlinked data/memory is refused even when data/memory/HEAD points past it'
}

test_verify_refuses_a_symlinked_memory_root() {
  local home gen_dir out rc
  home=$(new_home verify-symlink-root 7500)
  printf 'SOURCE\n' > "$home/data/source.md"

  rmdir "$home/data/memory/drop" "$home/data/memory"
  mkdir -p "$home/data/real/gen/1/notes"
  ln -s "$home/data/real" "$home/data/memory"
  gen_dir="$home/data/real/gen/1"
  printf '# Core\n<!-- source: data/source.md -->\n- Rule A\n' > "$gen_dir/core.md"
  write_note "$gen_dir/notes" n1 'Linked Note' 'linked' 2026-08-20 'data/source.md'

  set +e
  out=$(FM_HOME="$home" "$VERIFY" 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "verifier issued a verdict through a symlinked data/memory: $out"
  assert_contains "$out" 'data/memory is a symlink; refusing to verify through it' \
    'the verifier did not refuse a symlinked memory root'
  assert_not_contains "$out" 'PASS budget' \
    'the verifier reported a green budget check it measured through a symlink'

  pass 'the verifier refuses a home whose data/memory is a symlink instead of grading through it'
}

test_citation_resolution_ignores_the_callers_working_directory() {
  local home decoy out rc
  home=$(new_home citations-cwd 7500)
  decoy="$TMP_ROOT/citations-cwd-decoy"
  mkdir -p "$decoy/data" "$home/data/memory/gen/1/notes"
  printf 'DECOY\n' > "$decoy/data/decoy-source.md"

  # The cited path exists only in the caller's working directory, never in the
  # home or in the repo, so it is fabricated provenance.
  write_note "$home/data/memory/gen/1/notes" n1 'Decoy Note' 'decoy' 2026-08-20 'data/decoy-source.md'

  set +e
  out=$(cd "$decoy" && FM_HOME="$home" "$VERIFY" 1 2>&1)
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "verifier resolved a citation against the caller's cwd: $out"
  assert_contains "$out" 'data/decoy-source.md' 'the failure did not name the fabricated citation'

  # The same generation still passes once the cited file exists in the home.
  printf 'REAL\n' > "$home/data/decoy-source.md"
  out=$(cd "$decoy" && FM_HOME="$home" "$VERIFY" 1) \
    || fail "verifier refused a citation that resolves inside the home: $out"
  assert_contains "$out" 'PASS citations' 'a home-resolvable citation did not pass'

  pass 'citation provenance resolves against the home and repo, never the caller working directory'
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
test_publish_path_form_target_writes_resolvable_head
test_compile_reports_unresolvable_head_pointer
test_verify_refuses_full_deletion_of_small_baseline
test_verify_resolves_citations_frozen_by_migration
test_verify_accepts_bare_path_citation_in_note_body
test_verify_requires_citations_in_non_empty_core
test_verify_refuses_generation_whose_catalog_is_dropped
test_drop_tray_keeps_claim_matching_two_adjacent_claims
test_verify_runs_without_bash4_builtins
test_verify_accepts_note_with_incidental_unresolvable_prose_path
test_catalog_mode_reports_the_generation_it_wrote
test_compile_reads_resolved_dir_when_data_memory_is_a_symlink
test_compile_refuses_to_traverse_a_symlinked_memory_root
test_verify_refuses_a_symlinked_memory_root
test_citation_resolution_ignores_the_callers_working_directory

printf '# all fm-memory-verify tests passed\n'
exit 0
