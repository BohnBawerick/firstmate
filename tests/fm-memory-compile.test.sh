#!/usr/bin/env bash
# Behavioral coverage for the compiled, capped startup working-memory bundle and
# for the mechanical split of data/learnings.md into atomic notes.
#
# Every assertion here goes through bin/fm-memory-compile.sh or
# bin/fm-memory-migrate.sh and reads their real output or the real files they
# leave on disk.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-memory-compile)
# A literal backtick, so a quoted assertion never has to carry one.
BACKTICK=$(printf '\140')
COMPILE="$ROOT/bin/fm-memory-compile.sh"
MIGRATE="$ROOT/bin/fm-memory-migrate.sh"

# new_home <name> [budget]: a home with the budget published and nothing else,
# so each test states exactly the memory it is exercising.
new_home() {
  local budget=${2:-7500} home="$TMP_ROOT/$1"
  mkdir -p "$home/config" "$home/data" "$home/state" "$home/data/memory"
  printf '%s\n' "$budget" > "$home/config/startup-memory-budget"
  printf '%s\n' "$home"
}

# write_now <home> <date> [content] [key] [padding-lines]
write_now() {
  local home=$1 date=$2 content=${3:-"STANDING-NOW-TEXT"} key=${4:-"date"} pad=${5:-0} i
  mkdir -p "$home/data/memory"
  {
    printf -- '---\n'
    printf '%s: %s\n' "$key" "$date"
    printf -- '---\n\n'
    printf '%s\n' "$content"
    i=0
    while [ "$i" -lt "$pad" ]; do
      printf 'pinned ceiling %s aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' "$i"
      i=$((i + 1))
    done
  } > "$home/data/memory/now.md"
}

# write_note <home> <slug> <title> <triggers> <updated> [padding-lines]
write_note() {
  local home=$1 slug=$2 title=$3 triggers=$4 updated=$5 pad=${6:-0} i
  mkdir -p "$home/data/memory/notes"
  {
    printf -- '---\n'
    printf 'title: %s\n' "$title"
    printf 'triggers: %s\n' "$triggers"
    printf 'updated: %s\n' "$updated"
    printf -- '---\n\n'
    printf 'BODY-OF-%s\n' "$slug"
    i=0
    while [ "$i" -lt "$pad" ]; do
      printf 'padding line %s aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' "$i"
      i=$((i + 1))
    done
  } > "$home/data/memory/notes/$slug.md"
}

compile() {
  local home=$1
  shift
  FM_HOME="$home" "$COMPILE" compile "$@"
}

# accounting_field <output> <name>: one value from the MEMORY_ACCOUNTING line.
accounting_field() {
  printf '%s\n' "$1" | awk -v key="$2" '
    /^MEMORY_ACCOUNTING:/ {
      for (i = 2; i <= NF; i++) {
        split($i, kv, "=")
        if (kv[1] == key) { print kv[2]; exit }
      }
    }'
}

# --- bundle shape -----------------------------------------------------------

test_bundle_is_core_catalog_and_matched_notes_only() {
  local home out
  home=$(new_home bundle-shape)
  mkdir -p "$home/data/memory/notes" "$home/data/memory/drop"
  printf '# core\n\nSTANDING-CORE-TEXT\n' > "$home/data/memory/core.md"
  printf 'CAPTAIN-FILE-TEXT\n' > "$home/data/captain.md"
  printf -- '- healthlog [no-mistakes] - a project\n' > "$home/data/projects.md"
  write_note "$home" matched 'A matched claim' 'healthlog' 2026-08-18
  write_note "$home" unmatched 'An unmatched claim' 'penguin' 2026-08-01
  printf 'DROP-TRAY-CANDIDATE\n' > "$home/data/memory/drop/candidate.md"

  out=$(compile "$home")

  assert_contains "$out" 'STANDING-CORE-TEXT' 'core.md body was not injected'
  assert_not_contains "$out" 'CAPTAIN-FILE-TEXT' \
    'captain.md was injected even though data/memory/core.md exists'
  assert_contains "$out" 'A matched claim' 'catalog did not list the matched note'
  assert_contains "$out" 'An unmatched claim' \
    'catalog omitted a note that exists - the catalog must list every note'
  assert_contains "$out" 'BODY-OF-matched' 'trigger-matched note body was not injected'
  assert_not_contains "$out" 'BODY-OF-unmatched' \
    'a note whose triggers did not match was injected anyway'
  assert_not_contains "$out" 'DROP-TRAY-CANDIDATE' \
    'the drop tray was injected; the compiler must ignore it'
  [ "$(accounting_field "$out" status)" = within-budget ] \
    || fail "an unconstrained compile did not report within-budget: $out"
  [ "$(accounting_field "$out" hot_notes)" = 1 ] \
    || fail "expected exactly one hot note: $out"
  [ "$(accounting_field "$out" notes_total)" = 2 ] \
    || fail "accounting did not count every note on disk: $out"
  pass 'the bundle is core plus a catalog of every note plus only the matched note bodies'
}

test_core_falls_back_to_captain_then_reports_absence() {
  local home out
  home=$(new_home core-fallback)
  mkdir -p "$home/data/memory/notes"
  printf 'CAPTAIN-FILE-TEXT\n' > "$home/data/captain.md"

  out=$(compile "$home")
  assert_contains "$out" 'CAPTAIN-FILE-TEXT' \
    'captain.md was not used as the core while data/memory/core.md is absent'
  assert_contains "$out" 'data/memory/core.md is ABSENT' \
    'the bundle did not say which file was standing in as the core'

  rm -f "$home/data/captain.md"
  out=$(compile "$home")
  assert_contains "$out" 'MEMORY_NOTICE: no core memory' \
    'a home with no core at all did not say so'
  [ "$(accounting_field "$out" core)" = 0 ] || fail "absent core was not accounted as 0: $out"
  pass 'the core is core.md, then captain.md, and its total absence is reported'
}

# --- trigger matching -------------------------------------------------------

test_triggers_match_whole_words_case_insensitively() {
  local home out
  home=$(new_home triggers)
  printf 'CORE\n' > "$home/data/memory/core.md"
  write_note "$home" boundary 'Bounded claim' 'lint' 2026-08-18
  write_note "$home" untriggered 'Claim with no triggers' '' 2026-08-18
  write_note "$home" multiword 'Multi word claim' 'host clock' 2026-08-18

  out=$(compile "$home" --no-auto-context --context 'the repo left commands.lint unset')
  assert_contains "$out" 'BODY-OF-boundary' \
    'trigger "lint" did not match "commands.lint", where a dot is a word boundary'

  out=$(compile "$home" --no-auto-context --context 'we spent the day linting')
  assert_not_contains "$out" 'BODY-OF-boundary' \
    'trigger "lint" matched inside the word "linting"'

  out=$(compile "$home" --no-auto-context --context 'Commands.LINT is unset')
  assert_contains "$out" 'BODY-OF-boundary' 'trigger matching was case sensitive'

  out=$(compile "$home" --no-auto-context --context 'the HOST CLOCK stepped backwards')
  assert_contains "$out" 'BODY-OF-multiword' 'a multi-word trigger did not match'

  out=$(compile "$home" --no-auto-context --context 'claim with no triggers lint host clock'
)
  assert_not_contains "$out" 'BODY-OF-untriggered' \
    'a note with no triggers became hot; only the catalog should carry it'
  assert_contains "$out" 'Claim with no triggers' \
    'a note with no triggers fell out of the catalog too'
  pass 'triggers match on word boundaries, ignore case, allow several words, and are required'
}

test_auto_context_reads_live_fleet_work() {
  local home out
  home=$(new_home auto-context)
  printf 'CORE\n' > "$home/data/memory/core.md"
  write_note "$home" fromproject 'Project claim' 'healthlog' 2026-08-18
  write_note "$home" frombacklog 'Backlog claim' 'voicemaster' 2026-08-18
  write_note "$home" frommeta 'Runtime claim' 'opencode' 2026-08-18
  write_note "$home" fromnowhere 'Unrelated claim' 'penguin' 2026-08-18

  printf -- '- healthlog [no-mistakes] - a project\n' > "$home/data/projects.md"
  printf '## In flight\n\n- fix the voicemaster suite\n' > "$home/data/backlog.md"
  printf 'harness=opencode\nwindow=firstmate:x\n' > "$home/state/x.meta"

  out=$(compile "$home")
  assert_contains "$out" 'BODY-OF-fromproject' 'a project name did not pull its note hot'
  assert_contains "$out" 'BODY-OF-frombacklog' 'a backlog title did not pull its note hot'
  assert_contains "$out" 'BODY-OF-frommeta' 'live task metadata did not pull its note hot'
  assert_not_contains "$out" 'BODY-OF-fromnowhere' 'an unrelated note was pulled hot'

  out=$(compile "$home" --no-auto-context)
  assert_not_contains "$out" 'BODY-OF-fromproject' \
    '--no-auto-context still read the fleet for match terms'
  pass 'auto context is the project registry, the backlog, and live task metadata'
}

# --- budget cap -------------------------------------------------------------

test_budget_cap_drops_notes_first_then_the_catalog_and_never_the_core() {
  local home out full core_tokens catalog_tokens small_tokens budget
  home=$(new_home budget 1000000)
  printf '# core\n\nSTANDING-CORE-TEXT\n' > "$home/data/memory/core.md"
  write_note "$home" big 'Big claim' 'bigtrig' 2026-08-18 200
  write_note "$home" small 'Small claim' 'smalltrig' 2026-08-17 1

  full=$(compile "$home" --no-auto-context --context 'bigtrig smalltrig')
  [ "$(accounting_field "$full" hot_notes)" = 2 ] \
    || fail "an unconstrained compile did not take both matched notes: $full"
  core_tokens=$(accounting_field "$full" core)
  catalog_tokens=$(accounting_field "$full" catalog)
  small_tokens=$(accounting_field "$(compile "$home" --no-auto-context --context smalltrig)" hot_notes_tokens)

  # Exactly enough room for the core, the catalog, and the small note - and the
  # big note is offered FIRST, because it is the newer of the two.
  budget=$((core_tokens + catalog_tokens + small_tokens))
  printf '%s\n' "$budget" > "$home/config/startup-memory-budget"
  out=$(compile "$home" --no-auto-context --context 'bigtrig smalltrig')
  assert_contains "$out" 'STANDING-CORE-TEXT' 'the core was dropped under budget pressure'
  assert_contains "$out" 'Big claim' 'a dropped note left the catalog'
  assert_contains "$out" 'BODY-OF-small' \
    'a large note that did not fit starved the small note behind it'
  assert_not_contains "$out" 'BODY-OF-big' 'a note that did not fit was injected anyway'
  assert_contains "$out" 'MEMORY_BUDGET_NOTICE:' 'dropping a note was silent'
  [ "$(accounting_field "$out" status)" = capped ] \
    || fail "dropping a note was not reported as capped: $out"
  [ "$(accounting_field "$out" hot_dropped)" = 1 ] || fail "hot_dropped was wrong: $out"
  [ "$(accounting_field "$out" injected_total)" -le "$budget" ] \
    || fail "the injected total exceeded the budget: $out"

  # Room for the core but not the catalog: the catalog goes, and loudly.
  printf '%s\n' "$((core_tokens + 1))" > "$home/config/startup-memory-budget"
  out=$(compile "$home" --no-auto-context --context 'bigtrig smalltrig')
  assert_contains "$out" 'STANDING-CORE-TEXT' 'the core was dropped to fit the catalog'
  assert_contains "$out" 'MEMORY_BUDGET_WARNING:' 'dropping the catalog was silent'
  assert_not_contains "$out" 'Big claim' 'the catalog was printed after being accounted as dropped'
  [ "$(accounting_field "$out" catalog)" = 0 ] || fail "a dropped catalog was still accounted: $out"

  # Not even room for the core: it is still printed, in full, and alone.
  printf '1\n' > "$home/config/startup-memory-budget"
  out=$(compile "$home" --no-auto-context --context 'bigtrig smalltrig')
  assert_contains "$out" 'STANDING-CORE-TEXT' 'an over-budget core was truncated or dropped'
  assert_contains "$out" 'MEMORY_BUDGET_WARNING: the core alone is' \
    'an over-budget core did not produce an explicit warning'
  assert_not_contains "$out" 'Big claim' 'notes were listed under an over-budget core'
  assert_not_contains "$out" 'BODY-OF-small' 'a note was injected under an over-budget core'
  [ "$(accounting_field "$out" status)" = over-budget ] \
    || fail "an over-budget core did not report over-budget: $out"
  expect_code 0 "$(compile "$home" --no-auto-context >/dev/null 2>&1; echo $?)" \
    'an over-budget core must warn without failing the session'
  pass 'the cap drops notes first, then the catalog, and never the core'
}

test_an_unreadable_budget_is_a_hard_error() {
  local home out rc
  home=$(new_home unreadable-budget)
  printf 'CORE\n' > "$home/data/memory/core.md"
  printf 'not-a-number\n' > "$home/config/startup-memory-budget"
  set +e
  out=$(compile "$home" --no-auto-context 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'an unreadable budget must not compile a silently uncapped bundle'
  assert_contains "$out" 'value must be one positive decimal integer' \
    'the budget failure did not name what was wrong'
  pass 'a budget that cannot be read stops the compile instead of being assumed'
}

# --- degradation ------------------------------------------------------------

test_missing_memory_still_produces_a_bundle() {
  local home out
  home=$(new_home missing)
  printf 'CAPTAIN-FILE-TEXT\n' > "$home/data/captain.md"

  out=$(compile "$home" --no-auto-context)
  assert_contains "$out" 'CAPTAIN-FILE-TEXT' 'a home with no data/memory/ produced no core'
  assert_contains "$out" 'No notes filed yet' 'an empty note set was not stated plainly'
  assert_contains "$out" 'data/memory/catalog.md is ABSENT' 'an absent catalog file was not reported'

  printf 'OLD-LEARNINGS-TEXT\n' > "$home/data/learnings.md"
  out=$(compile "$home" --no-auto-context)
  assert_not_contains "$out" 'OLD-LEARNINGS-TEXT' \
    'data/learnings.md was injected; only migrated notes belong in the bundle'
  assert_contains "$out" 'data/learnings.md is still present' \
    'an unmigrated data/learnings.md was dropped without a word'
  pass 'a home missing memory files still compiles a bundle and names what is missing'
}

test_a_symlinked_note_is_skipped_not_followed() {
  local home out outside
  home=$(new_home symlink-note)
  printf 'CORE\n' > "$home/data/memory/core.md"
  write_note "$home" real 'Real claim' 'trigger' 2026-08-18
  outside="$TMP_ROOT/outside-note.md"
  printf 'OUTSIDE-SECRET\n' > "$outside"
  ln -s "$outside" "$home/data/memory/notes/linked.md"

  out=$(compile "$home" --no-auto-context --context trigger)
  assert_contains "$out" 'BODY-OF-real' 'the ordinary note was lost'
  assert_not_contains "$out" 'OUTSIDE-SECRET' 'a symlinked note was read out of the memory directory'
  [ "$(accounting_field "$out" notes_total)" = 1 ] || fail "a symlinked note was counted: $out"
  pass 'a symlinked note is skipped rather than followed out of data/memory/notes'
}

# --- catalog publication ----------------------------------------------------

test_catalog_publishes_and_reports_its_own_staleness() {
  local home out rc
  home=$(new_home catalog)
  printf 'CORE\n' > "$home/data/memory/core.md"
  write_note "$home" one 'First claim' 'alpha' 2026-08-18

  FM_HOME="$home" "$COMPILE" catalog >/dev/null || fail 'catalog publication failed'
  assert_contains "$(<"$home/data/memory/catalog.md")" 'First claim' \
    'the published catalog did not list the note'
  out=$(compile "$home" --no-auto-context)
  assert_not_contains "$out" 'catalog.md on disk is stale' \
    'a freshly published catalog was called stale'

  write_note "$home" two 'Second claim' 'beta' 2026-08-19
  out=$(compile "$home" --no-auto-context)
  assert_contains "$out" 'Second claim' \
    'the injected catalog was read from the stale file instead of the notes'
  assert_contains "$out" 'catalog.md on disk is stale' 'a stale catalog file was not reported'

  FM_HOME="$home" "$COMPILE" catalog >/dev/null
  out=$(compile "$home" --no-auto-context)
  assert_not_contains "$out" 'catalog.md on disk is stale' 'republishing did not clear the staleness'

  # Each mode takes only its own flags, so a mistyped invocation cannot be
  # silently ignored and read as a compile that simply matched nothing.
  set +e
  FM_HOME="$home" "$COMPILE" catalog --context alpha >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 2 "$rc" 'catalog mode accepted a compile-only flag'
  set +e
  FM_HOME="$home" "$COMPILE" compile --dry-run >/dev/null 2>&1
  rc=$?
  set -e
  expect_code 2 "$rc" 'compile mode accepted a catalog-only flag'
  FM_HOME="$home" "$COMPILE" catalog --dry-run >/dev/null 2>&1 \
    || fail 'catalog --dry-run was rejected'
  pass 'the catalog is published on demand, rendered fresh on every compile, and reports staleness'
}

# --- migration --------------------------------------------------------------

seed_learnings() {
  local home=$1
  cat > "$home/data/learnings.md" <<'LEARN'
<!-- memory tiers: see the stow skill -->

## An unset `commands.lint` sends the pipeline agent scanning the whole disk <!--a:2026-08-18-->

FIRST-BODY line one.
FIRST-BODY line two.

## 2026-08-15 - a conflicted PR silently gets NO checks at all <!--g-->

SECOND-BODY line.

## Healthlog browser tests cannot run two at a time (2026-08-13)

THIRD-BODY line.
LEARN
}

test_migration_splits_learnings_into_atomic_cited_notes() {
  local home out note
  home=$(new_home migrate)
  printf 'CAPTAIN\n' > "$home/data/captain.md"
  seed_learnings "$home"

  out=$(FM_HOME="$home" FM_MEMORY_MIGRATE_DATE=2026-08-20 "$MIGRATE") \
    || fail "migration failed: $out"
  assert_contains "$out" '3 note(s) created' 'the migration did not create one note per heading'

  note="$home/data/memory/notes/an-unset-commands-lint-sends-the-pipeline-agent-scanning-the.md"
  [ -f "$note" ] || fail "expected note file missing: $(ls "$home/data/memory/notes")"
  assert_contains "$(<"$note")" "title: An unset ${BACKTICK}commands.lint${BACKTICK} sends the pipeline agent scanning the whole disk" \
    'the note title was not the heading with its tier marker stripped'
  assert_contains "$(<"$note")" 'updated: 2026-08-18' 'the tier marker date did not become the updated date'
  assert_contains "$(<"$note")" 'tier: <!--a:2026-08-18-->' 'the raw tier marker was not preserved'
  assert_contains "$(<"$note")" 'source: data/learnings.md' 'the note carried no provenance'
  assert_contains "$(<"$note")" 'commands.lint' 'a backticked identifier did not become a trigger'
  assert_contains "$(<"$note")" 'FIRST-BODY line two.' 'the note body was truncated'

  assert_contains "$(cat "$home"/data/memory/notes/*conflicted*)" 'updated: 2026-08-15' \
    'a leading heading date did not become the updated date'
  assert_contains "$(cat "$home"/data/memory/notes/*two-at-a-time*)" 'updated: 2026-08-13' \
    'a trailing heading date did not become the updated date'
  assert_contains "$(cat "$home"/data/memory/notes/*two-at-a-time*)" 'healthlog' \
    'a proper noun in the heading did not become a trigger'

  assert_contains "$(<"$home/data/memory/catalog.md")" 'a conflicted PR silently gets NO checks' \
    'the migration did not publish a catalog covering every note'
  [ -d "$home/data/memory/drop" ] || fail 'the migration did not create the drop tray'
  pass 'migration turns each learnings heading into one cited, dated, triggered note'
}

test_migration_freezes_and_archives_before_removing_the_original() {
  local home original out
  home=$(new_home migrate-history)
  seed_learnings "$home"
  original=$(<"$home/data/learnings.md")
  printf '# archive\n' > "$home/data/memory-archive.md"

  FM_HOME="$home" FM_MEMORY_MIGRATE_DATE=2026-08-20 "$MIGRATE" >/dev/null \
    || fail 'migration failed'

  [ ! -e "$home/data/learnings.md" ] || fail 'the original was left in place by default'
  [ "$(<"$home/data/memory/raw/learnings-2026-08-20.md")" = "$original" ] \
    || fail 'the frozen copy is not byte-identical to the original'
  assert_contains "$(<"$home/data/memory-archive.md")" 'FIRST-BODY line one.' \
    'the original was not appended to the archive'
  assert_contains "$(<"$home/data/memory-archive.md")" 'archived from data/learnings.md' \
    'the archive append carried no dated banner'
  assert_contains "$(<"$home/data/memory-archive.md")" '# archive' \
    'the archive append replaced existing history instead of adding to it'

  # A second run must not duplicate history and must not lose the notes.
  seed_learnings "$home"
  out=$(FM_HOME="$home" FM_MEMORY_MIGRATE_DATE=2026-08-20 "$MIGRATE") || fail 'rerun failed'
  assert_contains "$out" '0 note(s) created, 3 already present' \
    'rerunning the migration rewrote notes that already existed'
  [ "$(grep -c 'archived from data/learnings.md' "$home/data/memory-archive.md")" = 1 ] \
    || fail 'rerunning the migration duplicated the archive banner'
  pass 'the original is frozen and archived, verified, and only then removed'
}

test_migration_dry_run_and_keep_learnings_write_nothing_away() {
  local home out
  home=$(new_home migrate-safe)
  seed_learnings "$home"

  out=$(FM_HOME="$home" FM_MEMORY_MIGRATE_DATE=2026-08-20 "$MIGRATE" --dry-run) \
    || fail 'dry run failed'
  assert_contains "$out" 'created notes/' 'the dry run did not report what it would create'
  assert_contains "$out" 'nothing was written' 'the dry run did not say it wrote nothing'
  [ ! -d "$home/data/memory/notes" ] || fail 'the dry run created notes'
  [ -f "$home/data/learnings.md" ] || fail 'the dry run removed the original'

  FM_HOME="$home" FM_MEMORY_MIGRATE_DATE=2026-08-20 "$MIGRATE" --keep-learnings >/dev/null \
    || fail 'keep-learnings run failed'
  [ -f "$home/data/learnings.md" ] || fail '--keep-learnings removed the original anyway'
  [ -f "$home/data/memory/raw/learnings-2026-08-20.md" ] \
    || fail '--keep-learnings skipped freezing the original'
  pass '--dry-run writes nothing and --keep-learnings leaves the original in place'
}

test_migration_refuses_to_remove_history_it_could_not_archive() {
  local home out rc
  home=$(new_home migrate-refuse)
  seed_learnings "$home"
  mkdir -p "$home/data/memory-archive.md"

  set +e
  out=$(FM_HOME="$home" FM_MEMORY_MIGRATE_DATE=2026-08-20 "$MIGRATE" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'an unusable archive must stop the migration'
  assert_contains "$out" 'data/memory-archive.md is not an ordinary regular file' \
    'the archive failure did not name the problem'
  [ -f "$home/data/learnings.md" ] || fail 'the original was removed despite an unusable archive'
  pass 'the migration refuses to remove the original when it cannot archive it'
}

test_core_shadowing_captain_emits_notice() {
  local home out
  home=$(new_home core-shadow-captain)
  printf '# core\n\nSTANDING-CORE-TEXT\n' > "$home/data/memory/core.md"
  printf 'CAPTAIN-PREFERENCES-TEXT\n' > "$home/data/captain.md"

  out=$(compile "$home" --no-auto-context)
  assert_contains "$out" 'STANDING-CORE-TEXT' 'core.md body was not injected'
  assert_not_contains "$out" 'CAPTAIN-PREFERENCES-TEXT' 'captain.md body was injected'
  assert_contains "$out" 'MEMORY_NOTICE: data/captain.md is still present' \
    'shadowed data/captain.md did not produce a notice'

  # An empty captain.md does not produce a notice
  : > "$home/data/captain.md"
  out=$(compile "$home" --no-auto-context)
  assert_not_contains "$out" 'MEMORY_NOTICE: data/captain.md is still present' \
    'an empty data/captain.md produced an unnecessary notice'
  pass 'data/memory/core.md shadowing a non-empty data/captain.md emits a notice naming its tokens'
}

test_missing_context_file_exits_nonzero() {
  local home out rc
  home=$(new_home missing-context-file)
  printf 'CORE\n' > "$home/data/memory/core.md"

  set +e
  out=$(compile "$home" --no-auto-context --context-file "$home/data/nonexistent.md" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'missing context-file should exit non-zero'
  assert_contains "$out" 'context file not found' 'error message did not identify missing context file'
  pass 'missing context file causes compiler to exit non-zero'
}

test_symlinked_memory_dir_is_guarded() {
  local home out outside
  home=$(new_home symlink-memdir)
  rm -rf "$home/data/memory"
  outside="$TMP_ROOT/outside-memory"
  mkdir -p "$outside/notes"
  printf 'OUTSIDE-CORE\n' > "$outside/core.md"
  ln -s "$outside" "$home/data/memory"

  out=$(compile "$home" --no-auto-context)
  assert_not_contains "$out" 'OUTSIDE-CORE' \
    'symlinked data/memory directory was read by compiler'
  pass 'symlinked data/memory directory is guarded and not trusted'
}

test_migration_handles_slug_collisions_and_refuses_when_headings_lost() {
  local home out note1 note2 rc
  home=$(new_home migrate-collision)
  cat > "$home/data/learnings.md" <<'LEARN'
## The `gh` CLI needs auth <!--a:2026-08-01-->

FIRST-CLAIM-BODY

## The `gh` CLI needs auth. <!--a:2026-08-02-->

SECOND-CLAIM-BODY
LEARN

  out=$(FM_HOME="$home" FM_MEMORY_MIGRATE_DATE=2026-08-20 "$MIGRATE") \
    || fail "migration with collisions failed: $out"
  assert_contains "$out" '2 note(s) created, 0 already present' \
    'slug collision was counted as already present rather than disambiguated'

  note1="$home/data/memory/notes/the-gh-cli-needs-auth.md"
  note2="$home/data/memory/notes/the-gh-cli-needs-auth-2.md"
  [ -f "$note1" ] || fail "first colliding note missing: $note1"
  [ -f "$note2" ] || fail "disambiguated note missing: $note2"
  assert_contains "$(<"$note1")" 'FIRST-CLAIM-BODY' 'first note body missing'
  assert_contains "$(<"$note2")" 'SECOND-CLAIM-BODY' 'disambiguated note body missing'

  # Idempotent re-run preserves both
  cat > "$home/data/learnings.md" <<'LEARN'
## The `gh` CLI needs auth <!--a:2026-08-01-->

FIRST-CLAIM-BODY

## The `gh` CLI needs auth. <!--a:2026-08-02-->

SECOND-CLAIM-BODY
LEARN
  out=$(FM_HOME="$home" FM_MEMORY_MIGRATE_DATE=2026-08-20 "$MIGRATE") \
    || fail "rerun failed: $out"
  assert_contains "$out" '0 note(s) created, 2 already present' \
    'rerun did not identify both notes as kept'

  # Refusal: learnings file with content but no valid headings
  cat > "$home/data/learnings.md" <<'LEARN'
No headings in this file, just raw text.
LEARN
  set +e
  out=$(FM_HOME="$home" FM_MEMORY_MIGRATE_DATE=2026-08-20 "$MIGRATE" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" 'migration should refuse to remove learnings when no headings found'
  assert_contains "$out" 'refusing to remove data/learnings.md' \
    'refusal error message was not emitted'
  [ -f "$home/data/learnings.md" ] || fail 'learnings.md was deleted despite no headings migrated'

  pass 'migration disambiguates slug collisions, preserves them on rerun, and refuses removal if headings are missing'
}

test_migration_on_a_home_with_no_learnings_still_builds_the_layout() {
  local home out
  home=$(new_home migrate-empty)
  out=$(FM_HOME="$home" FM_MEMORY_MIGRATE_DATE=2026-08-20 "$MIGRATE") || fail 'migration failed'
  assert_contains "$out" 'nothing to split' 'an absent learnings file was not reported plainly'
  [ -d "$home/data/memory/notes" ] || fail 'the notes directory was not created'
  [ -d "$home/data/memory/drop" ] || fail 'the drop tray was not created'
  pass 'a home with no learnings file still gets a compilable data/memory/ layout'
}

# --- operating picture (now.md) --------------------------------------------

test_operating_picture_dated_today_is_injected_ahead_of_catalog() {
  local home out core_pos now_pos cat_pos
  home=$(new_home now-today)
  printf '# core\n\nSTANDING-CORE-TEXT\n' > "$home/data/memory/core.md"
  write_now "$home" 2026-08-20 'PINS-AND-CEILINGS-TEXT'
  write_note "$home" matched 'A matched claim' 'healthlog' 2026-08-18
  printf -- '- healthlog [no-mistakes] - a project\n' > "$home/data/projects.md"

  out=$(FM_MEMORY_TODAY_OVERRIDE=2026-08-20 compile "$home")

  assert_contains "$out" 'STANDING-CORE-TEXT' 'core.md body was not injected'
  assert_contains "$out" 'PINS-AND-CEILINGS-TEXT' 'now.md body was not injected'
  assert_contains "$out" 'operating picture: data/memory/now.md' 'operating picture header was missing'
  assert_contains "$out" 'A matched claim' 'catalog was missing'
  assert_contains "$out" 'BODY-OF-matched' 'matched note was missing'

  core_pos=$(printf '%s\n' "$out" | grep -n '^core:' | cut -d: -f1)
  now_pos=$(printf '%s\n' "$out" | grep -n '^operating picture:' | cut -d: -f1)
  cat_pos=$(printf '%s\n' "$out" | grep -n '^catalog ' | cut -d: -f1)

  [ -n "$core_pos" ] && [ -n "$now_pos" ] && [ -n "$cat_pos" ] \
    || fail "could not find positions in output: $out"
  [ "$core_pos" -lt "$now_pos" ] \
    || fail "expected core ($core_pos) before operating picture ($now_pos)"
  [ "$now_pos" -lt "$cat_pos" ] \
    || fail "expected operating picture ($now_pos) before catalog ($cat_pos)"

  [ "$(accounting_field "$out" status)" = within-budget ] \
    || fail "expected within-budget status: $out"

  # Test with updated: in front matter as well
  write_now "$home" 2026-08-20 'UPDATED-PINS-TEXT' updated
  out=$(FM_MEMORY_TODAY_OVERRIDE=2026-08-20 compile "$home")
  assert_contains "$out" 'UPDATED-PINS-TEXT' 'now.md with updated: key was not injected'

  pass 'a now.md dated today appears in the bundle, clearly delimited, ahead of the catalog'
}

test_operating_picture_dated_other_day_is_dropped_and_reports_why() {
  local home out
  home=$(new_home now-stale)
  printf '# core\n\nSTANDING-CORE-TEXT\n' > "$home/data/memory/core.md"
  write_now "$home" 2026-08-19 'YESTERDAYS-CEILINGS'
  write_note "$home" matched 'A matched claim' 'healthlog' 2026-08-18
  printf -- '- healthlog [no-mistakes] - a project\n' > "$home/data/projects.md"

  out=$(FM_MEMORY_TODAY_OVERRIDE=2026-08-20 compile "$home")

  assert_contains "$out" 'STANDING-CORE-TEXT' 'core.md body was not injected'
  assert_not_contains "$out" 'YESTERDAYS-CEILINGS' 'stale now.md body was injected'
  assert_not_contains "$out" 'operating picture:' 'operating picture section was present for stale file'
  assert_contains "$out" 'MEMORY_NOTICE: data/memory/now.md is dated 2026-08-19' \
    'bundle did not explain why stale now.md was dropped'
  assert_contains "$out" 'not today' 'stale notice did not mention today date'
  assert_contains "$out" 'A matched claim' 'catalog was dropped when now.md was stale'
  assert_contains "$out" 'BODY-OF-matched' 'matched note was dropped when now.md was stale'

  pass 'a now.md dated any other day does not appear in the bundle, and the bundle says why'
}

test_operating_picture_with_no_date_is_dropped_and_reports_why() {
  local home out
  home=$(new_home now-nodate)
  printf '# core\n\nSTANDING-CORE-TEXT\n' > "$home/data/memory/core.md"
  printf '# Operating picture\n\nUNDATED-CEILINGS\n' > "$home/data/memory/now.md"

  out=$(FM_MEMORY_TODAY_OVERRIDE=2026-08-20 compile "$home" --no-auto-context)

  assert_not_contains "$out" 'UNDATED-CEILINGS' 'undated now.md body was injected'
  assert_not_contains "$out" 'operating picture:' 'operating picture section was present for undated file'
  assert_contains "$out" 'MEMORY_NOTICE: data/memory/now.md has no date in front matter' \
    'bundle did not explain why undated now.md was dropped'

  pass 'a now.md with no date in front matter is dropped and reported'
}

test_absent_now_md_produces_byte_identical_output_with_no_notice() {
  local home out
  home=$(new_home now-absent)
  printf '# core\n\nSTANDING-CORE-TEXT\n' > "$home/data/memory/core.md"
  write_note "$home" matched 'A matched claim' 'healthlog' 2026-08-18

  out=$(FM_MEMORY_TODAY_OVERRIDE=2026-08-20 compile "$home" --no-auto-context)

  assert_not_contains "$out" 'now.md' 'absent now.md was mentioned in output'
  assert_not_contains "$out" 'operating picture' 'absent now.md produced operating picture section'
  [ -z "$(accounting_field "$out" now)" ] \
    || fail "absent now.md added a now= field to MEMORY_ACCOUNTING: $out"

  pass 'no now.md produces output with no notice or operating picture section'
}

test_budget_cap_precedence_with_operating_picture() {
  local home out full core_tokens now_tokens catalog_tokens small_tokens budget
  home=$(new_home budget-now 1000000)
  printf '# core\n\nSTANDING-CORE-TEXT\n' > "$home/data/memory/core.md"
  write_now "$home" 2026-08-20 'NOW-PINS-TEXT'
  write_note "$home" big 'Big claim' 'bigtrig' 2026-08-18 200
  write_note "$home" small 'Small claim' 'smalltrig' 2026-08-17 1

  full=$(FM_MEMORY_TODAY_OVERRIDE=2026-08-20 compile "$home" --no-auto-context --context 'bigtrig smalltrig')
  [ "$(accounting_field "$full" hot_notes)" = 2 ] \
    || fail "an unconstrained compile did not take both matched notes: $full"
  core_tokens=$(accounting_field "$full" core)
  catalog_tokens=$(accounting_field "$full" catalog)
  small_tokens=$(accounting_field "$(FM_MEMORY_TODAY_OVERRIDE=2026-08-20 compile "$home" --no-auto-context --context smalltrig)" hot_notes_tokens)
  now_tokens=$(accounting_field "$full" now)

  [ -n "$now_tokens" ] && [ "$now_tokens" -gt 0 ] \
    || fail "now_tokens was not accounted: $full"

  # Case 1: Budget fits core + now + catalog + small note. Big note dropped.
  budget=$((core_tokens + now_tokens + catalog_tokens + small_tokens))
  printf '%s\n' "$budget" > "$home/config/startup-memory-budget"
  out=$(FM_MEMORY_TODAY_OVERRIDE=2026-08-20 compile "$home" --no-auto-context --context 'bigtrig smalltrig')
  assert_contains "$out" 'STANDING-CORE-TEXT' 'core was dropped'
  assert_contains "$out" 'NOW-PINS-TEXT' 'now was dropped'
  assert_contains "$out" 'Big claim' 'catalog was dropped'
  assert_contains "$out" 'BODY-OF-small' 'small note was dropped'
  assert_not_contains "$out" 'BODY-OF-big' 'big note was injected over budget'
  [ "$(accounting_field "$out" status)" = capped ] \
    || fail "dropping a note was not reported as capped: $out"

  # Case 2: Budget fits core + now, but NOT catalog. Catalog and notes dropped, now kept.
  printf '%s\n' "$((core_tokens + now_tokens))" > "$home/config/startup-memory-budget"
  out=$(FM_MEMORY_TODAY_OVERRIDE=2026-08-20 compile "$home" --no-auto-context --context 'bigtrig smalltrig')
  assert_contains "$out" 'STANDING-CORE-TEXT' 'core was dropped'
  assert_contains "$out" 'NOW-PINS-TEXT' 'now was dropped when catalog had no room'
  assert_not_contains "$out" 'Big claim' 'catalog was injected without room'
  assert_contains "$out" 'MEMORY_BUDGET_WARNING:' 'dropping catalog was silent'

  # Case 3: Budget fits core and nothing else. Now, catalog, and notes dropped.
  printf '%s\n' "$core_tokens" > "$home/config/startup-memory-budget"
  out=$(FM_MEMORY_TODAY_OVERRIDE=2026-08-20 compile "$home" --no-auto-context --context 'bigtrig smalltrig')
  assert_contains "$out" 'STANDING-CORE-TEXT' 'core was dropped'
  assert_not_contains "$out" 'NOW-PINS-TEXT' 'now was injected without room'
  assert_not_contains "$out" 'Big claim' 'catalog was injected without room'
  assert_contains "$out" 'MEMORY_BUDGET_WARNING:' 'dropping now was silent'
  [ "$(accounting_field "$out" now)" = 0 ] \
    || fail "a dropped operating picture was still accounted: $out"
  [ "$(accounting_field "$out" status)" = capped ] \
    || fail "dropping now was not reported as capped: $out"

  # Case 4: Not even room for core. Core alone printed with loud over-budget warning.
  printf '1\n' > "$home/config/startup-memory-budget"
  out=$(FM_MEMORY_TODAY_OVERRIDE=2026-08-20 compile "$home" --no-auto-context --context 'bigtrig smalltrig')
  assert_contains "$out" 'STANDING-CORE-TEXT' 'over-budget core was dropped'
  assert_contains "$out" 'MEMORY_BUDGET_WARNING: the core alone is' \
    'over-budget core did not emit warning'
  assert_not_contains "$out" 'NOW-PINS-TEXT' 'now was injected with over-budget core'
  [ "$(accounting_field "$out" status)" = over-budget ] \
    || fail "over-budget core did not report over-budget: $out"

  pass 'the budget cap drops notes first, then catalog, then operating picture, and never core'
}

test_oversized_operating_picture_is_dropped_but_the_catalog_survives() {
  local home full core_tokens catalog_tokens now_tokens out
  home=$(new_home now-oversized 1000000)
  printf '# core\n\nSTANDING-CORE-TEXT\n' > "$home/data/memory/core.md"
  write_now "$home" 2026-08-20 'NOW-PINS-TEXT' date 400
  write_note "$home" small 'Small claim' 'smalltrig' 2026-08-17 1

  full=$(FM_MEMORY_TODAY_OVERRIDE=2026-08-20 compile "$home" --no-auto-context --context smalltrig)
  core_tokens=$(accounting_field "$full" core)
  catalog_tokens=$(accounting_field "$full" catalog)
  now_tokens=$(accounting_field "$full" now)
  [ "$now_tokens" -gt "$catalog_tokens" ] \
    || fail "the oversized operating picture was not larger than the catalog: $full"

  # Room for core plus catalog, but not for core plus operating picture.
  printf '%s\n' "$((core_tokens + catalog_tokens))" > "$home/config/startup-memory-budget"
  out=$(FM_MEMORY_TODAY_OVERRIDE=2026-08-20 compile "$home" --no-auto-context --context smalltrig)

  assert_contains "$out" 'STANDING-CORE-TEXT' 'core was dropped'
  assert_not_contains "$out" 'NOW-PINS-TEXT' 'the oversized operating picture was injected'
  assert_contains "$out" 'MEMORY_BUDGET_WARNING: the core plus operating picture is' \
    'dropping the oversized operating picture was silent'
  assert_contains "$out" 'Small claim' 'the catalog went down with the operating picture'
  [ "$(accounting_field "$out" catalog)" = "$catalog_tokens" ] \
    || fail "the catalog was not accounted after the operating picture was dropped: $out"
  [ "$(accounting_field "$out" now)" = 0 ] \
    || fail "a dropped operating picture was still accounted: $out"
  [ "$(accounting_field "$out" status)" = capped ] \
    || fail "dropping the operating picture was not reported as capped: $out"
  assert_contains "$out" 'The catalog and notes below were filled from what remains.' \
    'the drop warning did not say the catalog was still filled'

  # Room for the core alone: the picture is dropped and so is the catalog, so
  # the warning must not promise a catalog that never follows.
  printf '%s\n' "$core_tokens" > "$home/config/startup-memory-budget"
  out=$(FM_MEMORY_TODAY_OVERRIDE=2026-08-20 compile "$home" --no-auto-context --context smalltrig)

  assert_contains "$out" 'MEMORY_BUDGET_WARNING: the core plus operating picture is' \
    'dropping the oversized operating picture was silent'
  assert_not_contains "$out" 'Small claim' 'the catalog was injected without room'
  assert_not_contains "$out" 'The catalog and notes below were filled from what remains.' \
    'the drop warning promised a catalog that was dropped in the same compile'

  pass 'an operating picture too large to fit is dropped alone and never takes the catalog with it'
}

test_operating_picture_is_read_from_the_home_in_a_generation_home() {
  local home out
  home=$(new_home now-generation)
  mkdir -p "$home/data/memory/gen/1/notes"
  printf '# core\n\nGENERATION-CORE-TEXT\n' > "$home/data/memory/gen/1/core.md"
  printf 'gen/1\n' > "$home/data/memory/HEAD"
  write_now "$home" 2026-08-20 'HOME-LEVEL-PINS'

  out=$(FM_MEMORY_TODAY_OVERRIDE=2026-08-20 compile "$home" --no-auto-context)

  assert_contains "$out" 'COMPILED WORKING MEMORY (data/memory/gen/1)' \
    'the generation was not the compiled memory directory'
  assert_contains "$out" 'GENERATION-CORE-TEXT' 'the generation core was not injected'
  assert_contains "$out" 'operating picture: data/memory/now.md' \
    'the home-level operating picture was not injected in a generation home'
  assert_contains "$out" 'HOME-LEVEL-PINS' 'the home-level operating picture body was missing'

  pass 'a generation home still reads the home-level data/memory/now.md'
}

test_an_explicit_memory_dir_never_reads_the_home_operating_picture() {
  local home out
  home=$(new_home now-explicit-dir)
  mkdir -p "$home/data/memory/gen/1/notes"
  printf '# core\n\nGENERATION-CORE-TEXT\n' > "$home/data/memory/gen/1/core.md"
  write_now "$home" 2026-08-20 'HOME-LEVEL-PINS'

  out=$(FM_MEMORY_TODAY_OVERRIDE=2026-08-20 compile "$home" --no-auto-context \
    --memory-dir "$home/data/memory/gen/1")

  assert_contains "$out" 'GENERATION-CORE-TEXT' 'the named generation core was not injected'
  assert_not_contains "$out" 'HOME-LEVEL-PINS' \
    'the home operating picture leaked into a compile of a named directory'
  assert_not_contains "$out" 'operating picture' \
    'a named directory with no now.md still emitted an operating picture section'
  [ -z "$(accounting_field "$out" now)" ] \
    || fail "the home operating picture was accounted against a named directory: $out"

  # The named directory's own now.md is the one it reads.
  printf -- '---\ndate: 2026-08-20\n---\n\nGENERATION-PINS\n' > "$home/data/memory/gen/1/now.md"
  out=$(FM_MEMORY_TODAY_OVERRIDE=2026-08-20 compile "$home" --no-auto-context \
    --memory-dir "$home/data/memory/gen/1")
  assert_contains "$out" 'GENERATION-PINS' 'the named directory own now.md was not injected'
  assert_contains "$out" 'operating picture: data/memory/gen/1/now.md' \
    'the operating picture was not labelled with the named directory'
  assert_not_contains "$out" 'HOME-LEVEL-PINS' \
    'the home operating picture leaked in beside the named directory own now.md'

  pass 'a compile of a named memory directory depends on that directory alone'
}

test_date_key_wins_over_updated_key_in_the_operating_picture() {
  local home out
  home=$(new_home now-date-precedence)
  printf '# core\n\nSTANDING-CORE-TEXT\n' > "$home/data/memory/core.md"
  {
    printf -- '---\n'
    printf 'date: 2026-08-20\n'
    printf 'updated: 2020-01-01\n'
    printf -- '---\n\n'
    printf 'DATE-KEY-PINS\n'
  } > "$home/data/memory/now.md"

  out=$(FM_MEMORY_TODAY_OVERRIDE=2026-08-20 compile "$home" --no-auto-context)

  assert_contains "$out" 'DATE-KEY-PINS' 'an updated: key overrode the authoritative date: key'
  assert_not_contains "$out" 'MEMORY_NOTICE: data/memory/now.md is dated' \
    'a now.md with an authoritative date: key was reported stale'

  pass 'the date: key is authoritative over updated: in the operating picture'
}

test_stale_operating_picture_notice_names_both_dates() {
  local home out
  home=$(new_home now-stale-dates)
  printf '# core\n\nSTANDING-CORE-TEXT\n' > "$home/data/memory/core.md"
  write_now "$home" 2026-08-19 'YESTERDAYS-CEILINGS'

  out=$(FM_MEMORY_TODAY_OVERRIDE=2026-08-20 compile "$home" --no-auto-context)

  assert_contains "$out" 'MEMORY_NOTICE: data/memory/now.md is dated 2026-08-19 (not today, 2026-08-20)' \
    'the stale notice did not name both the file date and today'

  pass 'the stale operating picture notice names the date the file carries and today'
}

test_shipped_example_operating_picture_compiles() {
  local home example_date out
  home=$(new_home now-example)
  printf '# core\n\nSTANDING-CORE-TEXT\n' > "$home/data/memory/core.md"
  cp "$ROOT/docs/examples/now.md" "$home/data/memory/now.md"

  example_date=$(awk 'NR > 1 && /^---[[:space:]]*$/ { exit } tolower($1) == "date:" { print $2; exit }' \
    "$ROOT/docs/examples/now.md")
  [ -n "$example_date" ] || fail 'docs/examples/now.md carries no date: key in its front matter'
  case "$example_date" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
    *) fail "docs/examples/now.md carries a non-ISO date, so a captain copying it is stale on day one: $example_date" ;;
  esac

  out=$(FM_MEMORY_TODAY_OVERRIDE="$example_date" compile "$home" --no-auto-context)

  assert_contains "$out" 'operating picture: data/memory/now.md' \
    'the shipped example template was not injected on the date it carries'
  assert_contains "$out" '# Operating picture' 'the example body was missing from the bundle'
  [ "$(accounting_field "$out" now)" -gt 0 ] \
    || fail "the example template was not accounted: $out"

  # The same shipped file on any other day must trip the stale gate, so the
  # date really is read rather than echoed back by the override.
  out=$(FM_MEMORY_TODAY_OVERRIDE=1999-12-31 compile "$home" --no-auto-context)
  assert_not_contains "$out" 'operating picture: data/memory/now.md' \
    'the shipped example template was injected on a day it is not dated'
  assert_contains "$out" "MEMORY_NOTICE: data/memory/now.md is dated $example_date (not today, 1999-12-31)" \
    'the shipped example template did not trip the stale notice on another day'

  pass 'the shipped docs/examples/now.md template compiles as a valid operating picture'
}

test_symlinked_now_md_is_guarded() {
  local home out outside
  home=$(new_home now-symlink)
  printf 'CORE\n' > "$home/data/memory/core.md"
  outside="$TMP_ROOT/outside-now.md"
  printf -- '---\ndate: 2026-08-20\n---\nOUTSIDE-NOW-SECRET\n' > "$outside"
  ln -s "$outside" "$home/data/memory/now.md"

  out=$(FM_MEMORY_TODAY_OVERRIDE=2026-08-20 compile "$home" --no-auto-context)
  assert_not_contains "$out" 'OUTSIDE-NOW-SECRET' 'symlinked now.md was read'
  assert_contains "$out" 'MEMORY_NOTICE: data/memory/now.md is a symlink' \
    'symlinked now.md did not emit notice'

  pass 'a symlinked now.md is skipped rather than followed'
}

test_bundle_is_core_catalog_and_matched_notes_only
test_core_falls_back_to_captain_then_reports_absence
test_core_shadowing_captain_emits_notice
test_triggers_match_whole_words_case_insensitively
test_auto_context_reads_live_fleet_work
test_missing_context_file_exits_nonzero
test_budget_cap_drops_notes_first_then_the_catalog_and_never_the_core
test_an_unreadable_budget_is_a_hard_error
test_missing_memory_still_produces_a_bundle
test_a_symlinked_note_is_skipped_not_followed
test_symlinked_memory_dir_is_guarded
test_catalog_publishes_and_reports_its_own_staleness
test_migration_splits_learnings_into_atomic_cited_notes
test_migration_handles_slug_collisions_and_refuses_when_headings_lost
test_migration_freezes_and_archives_before_removing_the_original
test_migration_dry_run_and_keep_learnings_write_nothing_away
test_migration_refuses_to_remove_history_it_could_not_archive
test_migration_on_a_home_with_no_learnings_still_builds_the_layout
test_operating_picture_dated_today_is_injected_ahead_of_catalog
test_operating_picture_dated_other_day_is_dropped_and_reports_why
test_operating_picture_with_no_date_is_dropped_and_reports_why
test_absent_now_md_produces_byte_identical_output_with_no_notice
test_budget_cap_precedence_with_operating_picture
test_oversized_operating_picture_is_dropped_but_the_catalog_survives
test_operating_picture_is_read_from_the_home_in_a_generation_home
test_an_explicit_memory_dir_never_reads_the_home_operating_picture
test_date_key_wins_over_updated_key_in_the_operating_picture
test_stale_operating_picture_notice_names_both_dates
test_shipped_example_operating_picture_compiles
test_symlinked_now_md_is_guarded

echo '# all fm-memory-compile tests passed'
