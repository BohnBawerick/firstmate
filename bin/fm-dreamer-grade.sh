#!/usr/bin/env bash
# fm-dreamer-grade.sh - independent grader rubric for proposed core memory diffs.
#
# Usage:
#   fm-dreamer-grade.sh grade <old-gen-or-dir> <new-gen-or-dir> [options]
#   fm-dreamer-grade.sh scout <task-id> <repo-name> <old-gen-or-dir> <new-gen-or-dir>
#   fm-dreamer-grade.sh -h | --help
#
# WHY THIS EXISTS.  A dreamer that rewrites the core cannot be the one that says
# the rewrite is safe: a context that did the work cannot grade the work, and
# concise poison is more dangerous than a long messy file. This helper is the
# grader's mechanical rubric. Firstmate runs `grade` directly for the
# deterministic checks, and scaffolds a fresh-context grader scout with `scout`
# when a core diff needs human-grade judgment (whether a claim is a durable
# abstraction rather than a tactical recap).
#
# grade
#   Runs the mechanical rubric on the proposed new generation against the old
#   one and prints one PASS/FAIL line per check. All checks must pass for a
#   PASS overall. The checks:
#     1. Mechanical safety  - delegate to bin/fm-memory-verify.sh, which owns
#        budget, citations, constitution preservation, and diff bounds. A
#        generation that fails the mechanical verifier is rejected outright.
#     2. Tactical scraps    - every changed or newly added statement in the new
#        core.md (and in changed notes) is inspected for tactical-scrap
#        patterns: a bare task id, a dated incident recap, or a claim whose
#        whole substance is one task's event. Such a statement is not a durable
#        abstraction and is flagged for the grader's judgment.
#     3. Contradiction      - every standing bullet rule in the old core must
#        still hold in the new core; a new statement that reverses a standing
#        rule (a negation of a rule's own wording, or an outright removal) is
#        rejected as a contradiction with standing rules.
#   A statement the old generation already carries verbatim is not a proposed
#   statement and is not inspected by (2) or (3): the mechanical verifier
#   requires every standing rule to survive, so a preserved rule must not be
#   read as a new claim about itself.
#   The rubric flags (2) and (3) with evidence; the final PASS/FAIL for the
#   whole generation requires (1) to pass and no (3) contradictions. Flags of
#   type (2) are surfaced for the grader scout to decide, because only a fresh
#   context can judge whether a claim generalises.
#
# scout
#   Scaffolds an independent grader scout brief at data/<task-id>/brief.md whose
#   ONLY input is the old generation, the new generation, and the cited files -
#   never the dreamer's chain of thought. The scout applies the judgment half
#   of the rubric and writes a pass/fail verdict to its report. It never writes
#   memory and never addresses the captain.
#
# OPTIONS (grade):
#   --max-diff-ratio <pct>  passed through to the mechanical verifier (default 50)
#   --dry-run               forwarded to the verifier for call-site symmetry with
#                           publish; grade never publishes, so it changes nothing
#   -h, --help              show this help message
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
MEMORY="$DATA/memory"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() {
  printf 'fm-dreamer-grade: %s\n' "$1" >&2
  exit 2
}

shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

CMD=""
OLD_TARGET=""
NEW_TARGET=""
MAX_DIFF_RATIO=50
DRY_RUN=0

case "${1:-}" in
  grade|scout) CMD=$1; shift ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

if [ "$CMD" = scout ]; then
  [ "$#" -ge 4 ] || { usage >&2; exit 2; }
  TASK_ID=$1
  REPO=$2
  OLD_TARGET=$3
  NEW_TARGET=$4
  shift 4
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
else
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --max-diff-ratio)
        [ "$#" -ge 2 ] || { usage >&2; exit 2; }
        MAX_DIFF_RATIO="$2"; shift 2 ;;
      --dry-run)
        DRY_RUN=1; shift ;;
      -h|--help)
        usage; exit 0 ;;
      -*)
        usage >&2; exit 2 ;;
      *)
        if [ -z "$OLD_TARGET" ]; then
          OLD_TARGET="$1"; shift
        elif [ -z "$NEW_TARGET" ]; then
          NEW_TARGET="$1"; shift
        else
          usage >&2; exit 2
        fi
        ;;
    esac
  done
  [ -n "$OLD_TARGET" ] && [ -n "$NEW_TARGET" ] || die "grade requires <old> and <new> generation targets"
fi

# --- resolve a generation directory -----------------------------------------
#
# resolve_gen_dir <target>: sets GEN_DIR_RESOLVED to the directory a target
# names, accepting data/memory/gen/<N>, a bare <N>, a data/memory-relative
# path, or an absolute path, mirroring the verifier's resolution. Returns 1
# when it does not resolve to a real, non-symlinked directory.
GEN_DIR_RESOLVED=""
resolve_gen_dir() {
  local target=$1 cand
  GEN_DIR_RESOLVED=""
  [ -n "$target" ] || return 1
  for cand in \
    "$MEMORY/gen/$target" \
    "$MEMORY/$target" \
    "$target"; do
    if [ -d "$cand" ] && [ ! -L "$cand" ]; then
      GEN_DIR_RESOLVED="$cand"
      return 0
    fi
  done
  return 1
}

# --- tactical scrap heuristic ------------------------------------------------
#
# is_scrap_statement <line>: returns 0 when the line looks like a tactical
# recap rather than a durable abstraction. Heuristic, and deliberately so: it
# only FLAGS candidates for the grader's judgment; it never rejects alone.
# Patterns: a bare task id like fm-xxxx-123, a dated incident anchor (a
# YYYY-MM-DD inside the statement), or a statement that is entirely one task's
# event with no generalisation signal ("failed", "timed out", "did not run").
is_scrap_statement() {
  local line=$1
  # A dated incident anchor (YYYY-MM-DD inside the statement) is a recap, not
  # a durable abstraction.
  case "$line" in
    *[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*)
      return 0 ;;
  esac
  # A task-id-shaped token inside the statement is a provenance anchor, not a
  # claim: it names one task's event and cannot generalise. Only flag the
  # statement when it also carries an event verb, so a citation path that
  # happens to contain a task id is not mistaken for a claim.
  case "$line" in
    *fm-[a-zA-Z0-9-]*)
      case "$line" in
        *" failed"*|*" timed out"*|*" did not"*|*" was "*|*" is "*)
          return 0 ;;
      esac
      ;;
  esac
  return 1
}

# --- contradiction with standing rules ---------------------------------------
#
# The old core's statements are parsed once into STANDING_KEYWORDS, one
# space-separated keyword list per rule, so the per-statement check below costs
# no subprocess at all. Re-parsing per statement is quadratic in core size and
# makes `grade` look hung on a realistic constitution.
STANDING_KEYWORDS=()

# load_standing_rules <old-core>: fill STANDING_KEYWORDS from the old core's
# standing rules. A standing rule is a bullet line, exactly the predicate
# bin/fm-memory-verify.sh's constitution check uses, so the grader and the
# verifier cannot disagree about what a rule is. A heading, a prose line, or the
# mandatory `<!-- source: ... -->` citation marker is not a rule, and loading one
# as a rule would hard-reject any new statement that echoes two of its words.
# A rule contributes its substantive words (four characters or more), lowercased,
# with bullet markers and punctuation stripped.
load_standing_rules() {
  local old_file=$1 rule clean keywords
  [ -n "$old_file" ] && [ -f "$old_file" ] && [ ! -L "$old_file" ] || return 0
  while IFS= read -r rule || [ -n "$rule" ]; do
    clean=$(printf '%s\n' "$rule" | sed -e 's/^[[:space:]]*[-*][[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$clean" ] || continue
    [ "${#clean}" -ge 5 ] || continue
    keywords=$(printf '%s\n' "$clean" | LC_ALL=C tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' ' ' | awk '{ for(i=1;i<=NF;i++) if(length($i)>=4) printf "%s ", $i }')
    [ -n "$keywords" ] || continue
    STANDING_KEYWORDS+=("$keywords")
  done < <(grep '^[[:space:]]*[-*][[:space:]]' "$old_file" || true)
}

# contradicts_standing <lowercased-statement>: returns 0 when the statement
# reverses a standing rule loaded by load_standing_rules: it shares the rule's
# substance (two or more of the rule's keywords) and negates it. The statement
# is matched lowercased throughout, so an ordinary sentence-case "Never ..." is
# caught exactly like a lowercase one. This is heuristic and surfaces evidence
# for the grader; a true removal is already caught by the mechanical
# constitution check (which requires every standing rule to survive).
contradicts_standing() {
  local line_lc=$1 keywords kw matched neg i=0
  while [ "$i" -lt "${#STANDING_KEYWORDS[@]}" ]; do
    keywords=${STANDING_KEYWORDS[$i]}
    i=$((i + 1))
    # Count how many of the old rule's keywords the new statement echoes.
    matched=0
    for kw in $keywords; do
      case "$line_lc" in
        *"$kw"*) matched=$((matched + 1)) ;;
      esac
    done
    # A contradiction is a new statement that shares the rule's substance but
    # reverses it: an explicit "never" / "do not" / "no longer" against a
    # standing "always" / "do" rule.
    [ "$matched" -ge 2 ] || continue
    for neg in 'never' 'do not' 'no longer' 'must not' 'refuse to'; do
      case "$line_lc" in
        *"$neg"*) return 0 ;;
      esac
    done
  done
  return 1
}

# --- statement inspection ----------------------------------------------------
#
# inspect_statements <old-file> <new-file> <label>: run the scrap and
# contradiction checks over the statements the new file adds or changes. Every
# line is compared and reported with its surrounding whitespace stripped, so a
# nested bullet is inspected like a top-level one (bin/fm-memory-verify.sh
# treats both as standing rules) and a pure re-indentation is not a new claim.
# A statement the old file already carries is not a proposed statement and is
# skipped: the mechanical verifier REQUIRES every standing rule to survive into
# the new generation, so inspecting a preserved rule would make the grader
# reject exactly the input the verifier demands. Headings, source markers, and
# note frontmatter are metadata rather than claims and are skipped too. An empty
# <old-file> means every statement in <new-file> is new.
inspect_statements() {
  local old_file=$1 new_file=$2 label=$3
  local line statement statement_lc haystack="" in_frontmatter=0 first=1
  [ -f "$new_file" ] && [ ! -L "$new_file" ] || return 0
  if [ -n "$old_file" ] && [ -f "$old_file" ] && [ ! -L "$old_file" ]; then
    haystack=$'\n'"$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$old_file")"$'\n'
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    statement=${line#"${line%%[![:space:]]*}"}
    statement=${statement%"${statement##*[![:space:]]}"}
    if [ "$first" -eq 1 ]; then
      first=0
      if [ "$statement" = '---' ]; then
        in_frontmatter=1
        continue
      fi
    fi
    if [ "$in_frontmatter" -eq 1 ]; then
      [ "$statement" = '---' ] && in_frontmatter=0
      continue
    fi
    [ -n "$statement" ] || continue
    case "$statement" in
      '#'*|'---'*|'<!--'*) continue ;;
    esac
    if [ -n "$haystack" ]; then
      case "$haystack" in
        *$'\n'"$statement"$'\n'*) continue ;;
      esac
    fi
    if is_scrap_statement "$statement"; then
      printf 'WARN grade: possible tactical scrap in %s: %s\n' "$label" "$statement" >&2
      GRADE_WARNINGS=$((GRADE_WARNINGS + 1))
    fi
    statement_lc=$(printf '%s\n' "$statement" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    if contradicts_standing "$statement_lc"; then
      printf 'FAIL grade: %s contradicts a standing rule: %s\n' "$label" "$statement" >&2
      ERRORS=$((ERRORS + 1))
    fi
  done < "$new_file"
}

if [ "$CMD" = scout ]; then
  # --- grader scout scaffold -------------------------------------------------
  if [ -e "$DATA/$TASK_ID" ]; then
    die "task id '$TASK_ID' already exists at $DATA/$TASK_ID; choose a distinct id"
  fi
  BRIEF="$DATA/$TASK_ID/brief.md"
  mkdir -p "$DATA/$TASK_ID"
  STATUS_FILE=$(shell_quote "$STATE/$TASK_ID.status")
  cat > "$BRIEF" <<EOF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
You are the INDEPENDENT GRADER for a proposed memory-core change. Firstmate has already run the
mechanical verifier and this rubric's deterministic checks. Your job is the judgment half of the rubric,
in a fresh context with no memory of the dreamer's reasoning.

## Your worktree
You are in a disposable git worktree of $REPO, at a detached HEAD on a clean default branch.

## Inputs - and only these
- The OLD generation: $OLD_TARGET
- The NEW generation: $NEW_TARGET
- The cited source files those generations reference.
You must NOT read the dreamer's chain of thought, its chat, or any conversation.

## Rubric
Approve only when every changed or added statement in the new core.md (and in changed notes) is a durable
abstraction that will still be true in a session that never heard of the task that produced it. Reject:
- tactical scraps (a bare task id event, a dated incident recap, "X timed out" with no generalisation);
- uncited claims (every claim must resolve to a real source file on disk);
- contradictions of standing rules (a new statement that reverses a standing preference or safety rule).

## Deliverable
Write your verdict to $DATA/$TASK_ID/report.md: a clear APPROVE or REJECT, the evidence (file:line for each
flaw, or a note that no flaw was found), and a one-line recommendation. Do NOT write any memory file. Do NOT
point data/memory/HEAD anywhere. Do NOT address the captain.

# Rules
1. Never push to any remote and never open a PR.
2. Stay inside this worktree; the only files you may write outside it are the report and the status file below.
3. Use gh-axi for GitHub operations and chrome-devtools-axi for browser operations.
4. Report status by appending one line:
   \`echo "{state}: {one short line}" >> $STATUS_FILE\`
   States: working, needs-decision, blocked, paused, done, failed.
   Each append wakes firstmate, so report sparingly: only phase changes a supervisor would act on.
5. If you hit the same obstacle twice, append \`blocked: {why}\` and stop.
6. If a decision belongs above you, append \`needs-decision: {summary}\` and stop.
7. Never stop, restart, or update the shared \`no-mistakes\` daemon.

# Definition of done
Append \`done: APPROVE\` or \`done: REJECT\` to the status file and stop.
EOF
  echo "scaffolded: $BRIEF (grader scout; APPROVE/REJECT)"
  exit 0
fi

# --- grade -------------------------------------------------------------------

# The ratio is validated here, before delegating, so a bad flag is reported as a
# usage error instead of reaching the operator as a memory-safety failure.
case "$MAX_DIFF_RATIO" in
  ''|*[!0-9]*) die "invalid --max-diff-ratio: '$MAX_DIFF_RATIO' (expected integer percentage 1-100)" ;;
esac
[ "$MAX_DIFF_RATIO" -ge 1 ] && [ "$MAX_DIFF_RATIO" -le 100 ] \
  || die "--max-diff-ratio must be between 1 and 100, got '$MAX_DIFF_RATIO'"

resolve_gen_dir "$OLD_TARGET" || die "old generation target does not resolve: '$OLD_TARGET'"
OLD_DIR=$GEN_DIR_RESOLVED
resolve_gen_dir "$NEW_TARGET" || die "new generation target does not resolve: '$NEW_TARGET'"
NEW_DIR=$GEN_DIR_RESOLVED

ERRORS=0
GRADE_WARNINGS=0

# 1. Mechanical safety via the verifier. Pass through max-diff-ratio and dry-run.
VERIFY_ARGS=("$SCRIPT_DIR/fm-memory-verify.sh" verify "$NEW_DIR" --max-diff-ratio "$MAX_DIFF_RATIO")
if [ "$DRY_RUN" -eq 1 ]; then
  VERIFY_ARGS+=("--dry-run")
fi
if ! VERIFY_OUT=$("${VERIFY_ARGS[@]}" 2>&1); then
  printf 'FAIL grade: proposed generation fails the mechanical verifier\n' >&2
  printf '%s\n' "$VERIFY_OUT" >&2
  ERRORS=$((ERRORS + 1))
else
  printf 'PASS grade: proposed generation passes the mechanical verifier\n'
fi

# 2/3. Rubric over the core diff. Resolve both core files by the compiler rule:
# a generation's core.md when present, else data/captain.md.
OLD_CORE=""
NEW_CORE=""
[ -f "$OLD_DIR/core.md" ] && [ ! -L "$OLD_DIR/core.md" ] && OLD_CORE="$OLD_DIR/core.md"
[ -z "$OLD_CORE" ] && [ -f "$DATA/captain.md" ] && [ ! -L "$DATA/captain.md" ] && OLD_CORE="$DATA/captain.md"
[ -f "$NEW_DIR/core.md" ] && [ ! -L "$NEW_DIR/core.md" ] && NEW_CORE="$NEW_DIR/core.md"
[ -z "$NEW_CORE" ] && [ -f "$DATA/captain.md" ] && [ ! -L "$DATA/captain.md" ] && NEW_CORE="$DATA/captain.md"

load_standing_rules "$OLD_CORE"

if [ -n "$NEW_CORE" ] && [ "$OLD_CORE" != "$NEW_CORE" ]; then
  inspect_statements "$OLD_CORE" "$NEW_CORE" "new core"
else
  printf 'INFO grade: no core change to rubric (new core resolves to %s)\n' \
    "${NEW_CORE:-ABSENT}" >&2
fi

# The same rubric runs over the generation's notes, because a claim smuggled
# into a note is published to every session exactly as a core statement is.
# A note the old generation already carries verbatim contributes no statement.
if [ -d "$NEW_DIR/notes" ] && [ ! -L "$NEW_DIR/notes" ]; then
  for note in "$NEW_DIR"/notes/*.md; do
    [ -f "$note" ] && [ ! -L "$note" ] || continue
    note_name=$(basename "$note")
    old_note="$OLD_DIR/notes/$note_name"
    [ -f "$old_note" ] && [ ! -L "$old_note" ] || old_note=""
    inspect_statements "$old_note" "$note" "changed note notes/$note_name"
  done
fi

if [ "$ERRORS" -gt 0 ]; then
  printf 'GRADE REJECTED: %s rubric violation(s) found\n' "$ERRORS" >&2
  exit 1
fi

printf 'GRADE APPROVED: no contradiction with standing rules%s\n' \
  "$([ "$GRADE_WARNINGS" -gt 0 ] && printf ' (%s tactical-scrap candidate(s) surfaced for grader judgment)' "$GRADE_WARNINGS" || printf '')"
exit 0
