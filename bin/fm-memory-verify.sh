#!/usr/bin/env bash
# fm-memory-verify.sh - mechanical safety verifier and generation publication guard.
#
# Usage:
#   fm-memory-verify.sh [verify] <generation-or-dir> [options]
#   fm-memory-verify.sh publish <generation-or-dir> [options]
#   fm-memory-verify.sh -h | --help
#
# Commands:
#   verify      run all mechanical safety checks on the proposed generation (default)
#   publish     verify and atomically update data/memory/HEAD to point to the generation
#
# Options:
#   --max-diff-ratio <pct>   maximum allowed note deletion percentage (default: 50)
#   --dry-run                for publish: verify without updating data/memory/HEAD
#   -h, --help               show this help message
#
# SAFETY CHECKS.  Every proposed generation must pass four mechanical checks:
#   1. Budget: the compiled bundle must fit within config/startup-memory-budget
#      using bin/fm-memory-compile.sh and bin/fm-startup-memory-budget-lib.sh;
#   2. Citations: every note and core claim must cite an existing source file,
#      report, or task record on disk;
#   3. Constitution: standing captain preferences in data/captain.md must be
#      preserved in core.md and never silently dropped or deleted;
#   4. Diff bounds: a single generation cannot replace or delete excessive
#      proportions of memory (default: max 50% deletion of baseline notes).
#
# ATOMIC PUBLICATION.  When publishing, data/memory/HEAD is updated via atomic
# file swap (.HEAD.tmp -> HEAD) only after all four checks pass.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
MEMORY="$DATA/memory"

# shellcheck source=bin/fm-startup-memory-budget-lib.sh
. "$SCRIPT_DIR/fm-startup-memory-budget-lib.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() {
  printf 'fm-memory-verify: %s\n' "$1" >&2
  exit 1
}

MODE=verify
TARGET=""
MAX_DIFF_RATIO=50
DRY_RUN=0

case "${1:-}" in
  verify|publish)
    MODE="$1"
    shift
    ;;
  -h|--help)
    usage; exit 0 ;;
esac

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
      if [ -z "$TARGET" ]; then
        TARGET="$1"
        shift
      else
        usage >&2; exit 2
      fi
      ;;
  esac
done

[ -n "$TARGET" ] || die 'missing required generation target or directory'

# Validate diff ratio parameter
case "$MAX_DIFF_RATIO" in
  ''|*[!0-9]*) die "invalid max-diff-ratio: '$MAX_DIFF_RATIO' (expected integer percentage 1-100)" ;;
esac
[ "$MAX_DIFF_RATIO" -ge 1 ] && [ "$MAX_DIFF_RATIO" -le 100 ] || die "max-diff-ratio must be between 1 and 100"

# Resolve proposed generation directory
GEN_DIR=""
GEN_IDENTIFIER=""

# Check if target is a simple number or gen/<N> or explicit path
if [ -d "$DATA/memory/gen/$TARGET" ] && [ ! -L "$DATA/memory/gen/$TARGET" ]; then
  GEN_DIR="$DATA/memory/gen/$TARGET"
  GEN_IDENTIFIER="gen/$TARGET"
elif [ -d "$DATA/memory/$TARGET" ] && [ ! -L "$DATA/memory/$TARGET" ]; then
  GEN_DIR="$DATA/memory/$TARGET"
  GEN_IDENTIFIER="$TARGET"
elif [ -d "$TARGET" ] && [ ! -L "$TARGET" ]; then
  GEN_DIR="$TARGET"
  case "$TARGET" in
    "$DATA/memory/"*)
      GEN_IDENTIFIER="${TARGET#"$DATA/memory/"}"
      ;;
    *)
      GEN_IDENTIFIER="$TARGET"
      ;;
  esac
else
  die "proposed generation directory does not exist or is a symlink: '$TARGET'"
fi

# Canonical check: generation directory must not be a symlink
[ ! -L "$GEN_DIR" ] || die "generation directory is a symlink: '$GEN_DIR'"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/.fm-memory-verify.XXXXXX") || die 'could not create temporary directory'
# shellcheck disable=SC2329 # Registered by EXIT trap
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# --- 1. Budget Verification -------------------------------------------------

check_budget() {
  local compile_out accounting status budget core catalog injected
  if ! compile_out=$("$SCRIPT_DIR/fm-memory-compile.sh" compile --memory-dir "$GEN_DIR" 2>"$TMP/compile_err"); then
    printf 'FAIL budget: compiler exited non-zero on proposed generation: %s\n' \
      "$(tr '\n' ' ' < "$TMP/compile_err")" >&2
    return 1
  fi

  accounting=$(printf '%s\n' "$compile_out" | grep '^MEMORY_ACCOUNTING:' || true)
  if [ -z "$accounting" ]; then
    printf 'FAIL budget: compiler did not emit MEMORY_ACCOUNTING line\n' >&2
    return 1
  fi

  status=$(printf '%s\n' "$accounting" | awk '{ for(i=1;i<=NF;i++) if($i ~ /^status=/) { split($i,a,"="); print a[2] } }')
  budget=$(printf '%s\n' "$accounting" | awk '{ for(i=1;i<=NF;i++) if($i ~ /^budget=/) { split($i,a,"="); print a[2] } }')
  core=$(printf '%s\n' "$accounting" | awk '{ for(i=1;i<=NF;i++) if($i ~ /^core=/) { split($i,a,"="); print a[2] } }')
  catalog=$(printf '%s\n' "$accounting" | awk '{ for(i=1;i<=NF;i++) if($i ~ /^catalog=/) { split($i,a,"="); print a[2] } }')
  injected=$(printf '%s\n' "$accounting" | awk '{ for(i=1;i<=NF;i++) if($i ~ /^injected_total=/) { split($i,a,"="); print a[2] } }')

  if [ "$status" = "over-budget" ]; then
    printf 'FAIL budget: core alone (%s tokens) exceeds startup budget (%s tokens)\n' \
      "$core" "$budget" >&2
    return 1
  fi

  if ! fm_startup_memory_decimal_le "$injected" "$budget"; then
    printf 'FAIL budget: compiled bundle is %s estimated tokens > %s budget\n' \
      "$injected" "$budget" >&2
    return 1
  fi

  printf 'PASS budget: compiled bundle is %s estimated tokens <= %s cap (core=%s catalog=%s status=%s)\n' \
    "$injected" "$budget" "$core" "$catalog" "$status"
  return 0
}

# --- 2. Citation Check ------------------------------------------------------

# resolve_source_path <path>: test if cited file path exists in home or repo
resolve_source_path() {
  local p=$1 candidate
  [ -n "$p" ] || return 1

  # Strip leading/trailing quotes, parentheses, brackets, whitespace, punctuation
  p=$(printf '%s\n' "$p" | sed -e 's/^[][[:space:]"'\'')(`><.,:;]*//' -e 's/[][[:space:]"'\'')(`><.,:;]*$//')
  [ -n "$p" ] || return 1

  # If absolute path
  if [ -e "$p" ] || [ -L "$p" ]; then
    return 0
  fi

  # Relative to FM_HOME
  if [ -e "$FM_HOME/$p" ] || [ -L "$FM_HOME/$p" ]; then
    return 0
  fi

  # Relative to FM_ROOT
  if [ -e "$FM_ROOT/$p" ] || [ -L "$FM_ROOT/$p" ]; then
    return 0
  fi

  # Relative to DATA
  if [ -e "$DATA/$p" ] || [ -L "$DATA/$p" ]; then
    return 0
  fi

  # Check if git commit object
  if [ "${#p}" -ge 7 ] && [ "${#p}" -le 40 ]; then
    case "$p" in
      *[!0-9a-fA-F]*) ;;
      *)
        if (cd "$FM_ROOT" && git cat-file -e "$p" 2>/dev/null); then
          return 0
        fi
        ;;
    esac
  fi

  return 1
}

# extract_citations_from_file <filepath>
extract_citations_from_file() {
  local file=$1
  awk '
    BEGIN { in_fm = 0 }
    NR == 1 && /^---/ { in_fm = 1; next }
    in_fm && /^---/ { in_fm = 0; next }
    in_fm {
      if ($0 ~ /^(source|sources|citation|citations|report):/) {
        val = $0
        sub(/^[A-Za-z]+:[[:space:]]*/, "", val)
        # Split comma or whitespace
        n = split(val, parts, /[,[:space:]]+/)
        for (i = 1; i <= n; i++) {
          if (parts[i] != "") print parts[i]
        }
      }
      next
    }
    {
      # Look for parenthetical citations: (data/...), (reports/...), (see path)
      line = $0
      while (match(line, /\([[:space:]]*(source:[[:space:]]*|see[[:space:]]*|cited:[[:space:]]*)?[A-Za-z0-9_.\/-]+\.[A-Za-z0-9]+\)/)) {
        cite = substr(line, RSTART + 1, RLENGTH - 2)
        sub(/^(source:[[:space:]]*|see[[:space:]]*|cited:[[:space:]]*)/, "", cite)
        print cite
        line = substr(line, RSTART + RLENGTH)
      }
      # Look for markdown links: [...](path)
      line = $0
      while (match(line, /\[[^]]*\]\([^)]+\)/)) {
        link = substr(line, RSTART, RLENGTH)
        sub(/^\[[^]]*\]\(/, "", link)
        sub(/\)$/, "", link)
        if (link !~ /^https?:/) print link
        line = substr(line, RSTART + RLENGTH)
      }
      # Look for explicit data/... state/... docs/... bin/... tests/... paths
      line = $0
      while (match(line, /\<(data|state|docs|bin|tests|projects|\.agents)\/[A-Za-z0-9_.\/-]+/)) {
        cite = substr(line, RSTART, RLENGTH)
        print cite
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$file" | sed -e 's/^[][[:space:]"'\'')(`><.,:;]*//' -e 's/[][[:space:]"'\'')(`><.,:;]*$//' \
           | awk 'NF > 0 && !seen[$0]++'
}

check_citations() {
  local notes_dir="$GEN_DIR/notes" note_count=0 valid_citations=0 note
  local cited_list=() cited file_err=0

  if [ -d "$notes_dir" ] && [ ! -L "$notes_dir" ]; then
    for note in "$notes_dir"/*.md; do
      [ -f "$note" ] && [ ! -L "$note" ] || continue
      note_count=$((note_count + 1))
      local note_slug
      note_slug=$(basename "$note")
      
      # Extract citations for this note
      mapfile -t cited_list < <(extract_citations_from_file "$note")
      
      if [ "${#cited_list[@]}" -eq 0 ]; then
        printf 'FAIL citations: note notes/%s has no citations or source metadata\n' \
          "$note_slug" >&2
        file_err=$((file_err + 1))
        continue
      fi

      local note_has_valid=0
      for cited in "${cited_list[@]}"; do
        [ -n "$cited" ] || continue
        if resolve_source_path "$cited"; then
          note_has_valid=1
          valid_citations=$((valid_citations + 1))
        else
          printf 'FAIL citations: note notes/%s cites missing or unresolvable source: "%s"\n' \
            "$note_slug" "$cited" >&2
          file_err=$((file_err + 1))
        fi
      done
      
      if [ "$note_has_valid" -eq 0 ]; then
        file_err=$((file_err + 1))
      fi
    done
  fi

  # Check core.md citations if present
  if [ -f "$GEN_DIR/core.md" ] && [ ! -L "$GEN_DIR/core.md" ] && [ -s "$GEN_DIR/core.md" ]; then
    mapfile -t cited_list < <(extract_citations_from_file "$GEN_DIR/core.md")
    for cited in "${cited_list[@]}"; do
      [ -n "$cited" ] || continue
      if resolve_source_path "$cited"; then
        valid_citations=$((valid_citations + 1))
      else
        printf 'FAIL citations: core.md cites missing or unresolvable source: "%s"\n' \
          "$cited" >&2
        file_err=$((file_err + 1))
      fi
    done
  fi

  if [ "$file_err" -gt 0 ]; then
    return 1
  fi

  printf 'PASS citations: all claims cite existing sources (%s verified citations across %s note(s))\n' \
    "$valid_citations" "$note_count"
  return 0
}

# --- 3. Standing Constitution Safety ----------------------------------------

check_constitution() {
  local captain_file="$DATA/captain.md"
  local core_file="$GEN_DIR/core.md"

  # If data/captain.md is absent or empty, constitution safety check passes
  if [ ! -f "$captain_file" ] || [ -L "$captain_file" ] || [ ! -s "$captain_file" ]; then
    printf 'PASS constitution: data/captain.md is absent or empty; no standing baseline to verify against\n'
    return 0
  fi

  # If data/captain.md exists and is non-empty, proposed core.md MUST exist and be non-empty
  if [ ! -f "$core_file" ] || [ -L "$core_file" ] || [ ! -s "$core_file" ]; then
    printf 'FAIL constitution: data/captain.md contains standing preferences but proposed generation lacks non-empty core.md\n' >&2
    return 1
  fi

  # Extract key standing rules and headings from data/captain.md
  # Every heading and bullet rule in captain.md must have representation in core.md
  local missing=0 heading rule clean_rule core_text
  core_text=$(cat "$core_file" | LC_ALL=C tr '[:upper:]' '[:lower:]')

  # 1. Check headings
  while IFS= read -r heading; do
    [ -n "$heading" ] || continue
    # Normalize heading text
    heading=$(printf '%s\n' "$heading" | sed -e 's/^#*[[:space:]]*//' -e 's/[[:space:]]*$//' | LC_ALL=C tr '[:upper:]' '[:lower:]')
    [ -n "$heading" ] || continue
    # Skip generic headings like "captain preferences"
    case "$heading" in
      'captain preferences'|'preferences'|'standing preferences'|'constitution') continue ;;
    esac
    if ! printf '%s\n' "$core_text" | grep -Fq "$heading"; then
      printf 'FAIL constitution: standing section heading "%s" from data/captain.md is missing in core.md\n' \
        "$heading" >&2
      missing=$((missing + 1))
    fi
  done < <(grep '^#\{1,4\}[[:space:]]' "$captain_file" || true)

  # 2. Check bullet rules and standing directives
  while IFS= read -r rule; do
    clean_rule=$(printf '%s\n' "$rule" | sed -e 's/^[[:space:]]*[-*][[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$clean_rule" ] || continue
    [ "${#clean_rule}" -ge 5 ] || continue
    
    # Extract substantive keywords from the rule to verify it wasn't dropped
    local keywords
    keywords=$(printf '%s\n' "$clean_rule" | LC_ALL=C tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' ' ' | awk '{ for(i=1;i<=NF;i++) if(length($i)>=4) printf "%s ", $i }')
    [ -n "$keywords" ] || continue

    # Check if key tokens are present in core.md
    local token match_count=0 total_tokens=0
    for token in $keywords; do
      total_tokens=$((total_tokens + 1))
      if printf '%s\n' "$core_text" | grep -Fq "$token"; then
        match_count=$((match_count + 1))
      fi
    done

    # If less than half of the rule's keywords are present, flag as potentially dropped rule
    if [ "$total_tokens" -gt 0 ] && [ "$match_count" -lt "$(( (total_tokens + 1) / 2 ))" ]; then
      printf 'FAIL constitution: standing preference rule from data/captain.md was silently dropped or truncated in core.md: "%s"\n' \
        "$clean_rule" >&2
      missing=$((missing + 1))
    fi
  done < <(grep '^[[:space:]]*[-*][[:space:]]' "$captain_file" || true)

  if [ "$missing" -gt 0 ]; then
    return 1
  fi

  printf 'PASS constitution: standing captain preferences from data/captain.md are preserved in core.md\n'
  return 0
}

# --- 4. Diff Bounds Check ---------------------------------------------------

check_diff_bounds() {
  local base_dir="" base_notes=() gen_notes=() note
  local base_count=0 gen_count=0 deleted_count=0 modified_count=0 added_count=0

  # Determine baseline generation
  if [ -f "$DATA/memory/HEAD" ] && [ ! -L "$DATA/memory/HEAD" ]; then
    local head_target
    head_target=$(head -n 1 "$DATA/memory/HEAD" | tr -d '\r\n[:space:]')
    case "$head_target" in
      ''|*..*|/*) ;;
      *)
        if [ -d "$DATA/memory/$head_target/notes" ]; then
          base_dir="$DATA/memory/$head_target/notes"
        elif [ -d "$DATA/memory/gen/$head_target/notes" ]; then
          base_dir="$DATA/memory/gen/$head_target/notes"
        fi
        ;;
    esac
  fi

  if [ -z "$base_dir" ] && [ -d "$DATA/memory/notes" ] && [ ! -L "$DATA/memory/notes" ]; then
    base_dir="$DATA/memory/notes"
  fi

  # If no baseline directory exists or baseline is the same directory as proposed generation
  if [ -z "$base_dir" ] || [ "$base_dir" = "$GEN_DIR/notes" ]; then
    printf 'PASS diff-bounds: initial generation (no baseline notes to compare against)\n'
    return 0
  fi

  # Collect baseline note names
  if [ -d "$base_dir" ]; then
    for note in "$base_dir"/*.md; do
      [ -f "$note" ] && [ ! -L "$note" ] || continue
      base_notes+=("$(basename "$note")")
      base_count=$((base_count + 1))
    done
  fi

  # If baseline has 0 notes, pass
  if [ "$base_count" -eq 0 ]; then
    printf 'PASS diff-bounds: initial generation (baseline has 0 notes)\n'
    return 0
  fi

  # Collect proposed generation note names
  if [ -d "$GEN_DIR/notes" ]; then
    for note in "$GEN_DIR/notes"/*.md; do
      [ -f "$note" ] && [ ! -L "$note" ] || continue
      gen_notes+=("$(basename "$note")")
      gen_count=$((gen_count + 1))
    done
  fi

  # If proposed generation wiped out all notes when baseline had notes
  if [ "$base_count" -gt 0 ] && [ "$gen_count" -eq 0 ]; then
    printf 'FAIL diff-bounds: proposed generation wipes out all %s baseline notes\n' \
      "$base_count" >&2
    return 1
  fi

  # Count deleted and modified notes
  local bn gn found
  for bn in "${base_notes[@]}"; do
    found=0
    for gn in "${gen_notes[@]}"; do
      if [ "$bn" = "$gn" ]; then
        found=1
        if ! cmp -s "$base_dir/$bn" "$GEN_DIR/notes/$gn"; then
          modified_count=$((modified_count + 1))
        fi
        break
      fi
    done
    if [ "$found" -eq 0 ]; then
      deleted_count=$((deleted_count + 1))
    fi
  done

  # Count added notes
  for gn in "${gen_notes[@]}"; do
    found=0
    for bn in "${base_notes[@]}"; do
      if [ "$gn" = "$bn" ]; then
        found=1
        break
      fi
    done
    if [ "$found" -eq 0 ]; then
      added_count=$((added_count + 1))
    fi
  done

  # Check deletion ratio
  local del_pct=$(( (deleted_count * 100) / base_count ))
  if [ "$base_count" -ge 3 ] && [ "$del_pct" -gt "$MAX_DIFF_RATIO" ]; then
    printf 'FAIL diff-bounds: proposed generation deletes %s of %s baseline notes (%s%% > %s%% allowed cap)\n' \
      "$deleted_count" "$base_count" "$del_pct" "$MAX_DIFF_RATIO" >&2
    return 1
  fi

  printf 'PASS diff-bounds: proposed generation changes are within bounds (%s deleted, %s modified, %s added of %s baseline notes)\n' \
    "$deleted_count" "$modified_count" "$added_count" "$base_count"
  return 0
}

# --- Run Verification Pipeline ----------------------------------------------

ERRORS=0

printf 'VERIFYING GENERATION: %s (%s)\n' "$TARGET" "$GEN_DIR"
printf '%s\n' '--------------------------------------------------------------------------------'

check_budget || ERRORS=$((ERRORS + 1))
check_citations || ERRORS=$((ERRORS + 1))
check_constitution || ERRORS=$((ERRORS + 1))
check_diff_bounds || ERRORS=$((ERRORS + 1))

printf '%s\n' '--------------------------------------------------------------------------------'

if [ "$ERRORS" -gt 0 ]; then
  printf 'VERIFICATION FAILED: %s check(s) failed\n' "$ERRORS" >&2
  exit 1
fi

printf 'VERIFICATION PASSED: all 4 safety checks passed\n'

# If verify mode, exit 0
if [ "$MODE" = "verify" ]; then
  exit 0
fi

# --- Publish Mode -----------------------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'publish: --dry-run, all checks passed; would update data/memory/HEAD to point to %s\n' \
    "$GEN_IDENTIFIER"
  exit 0
fi

# Atomic pointer swap to data/memory/HEAD
[ ! -L "$DATA/memory" ] || die "data/memory is a symlink; refusing to publish"
[ -d "$DATA/memory" ] || mkdir -p "$DATA/memory" || die "could not create data/memory"

if [ -L "$DATA/memory/HEAD" ]; then
  die "data/memory/HEAD is a symlink; refusing to overwrite"
fi

printf '%s\n' "$GEN_IDENTIFIER" > "$DATA/memory/.HEAD.tmp" || die "could not stage HEAD pointer"
mv -f "$DATA/memory/.HEAD.tmp" "$DATA/memory/HEAD" || die "could not update data/memory/HEAD"

printf 'memory: published generation %s to data/memory/HEAD\n' "$GEN_IDENTIFIER"
exit 0
