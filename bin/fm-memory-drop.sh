#!/usr/bin/env bash
# fm-memory-drop.sh - deposit candidate claims from completed tasks into the drop tray.
#
# Usage:
#   fm-memory-drop.sh <task-id> [options]
#   fm-memory-drop.sh --task <task-id> [options]
#   fm-memory-drop.sh -h | --help
#
# Options:
#   --project <name>        project name (auto-detected from state/<id>.meta if omitted)
#   --report <path>         path to scout/task report (auto-detected if omitted)
#   --commit <hash>         commit hash pointer (auto-detected if omitted)
#   --claim <text>          candidate claim or finding (can be specified multiple times)
#   --claims-file <path>    file containing candidate claims (one per line or markdown)
#   --date <YYYY-MM-DD>     date for metadata (default: today UTC)
#   --dry-run               print proposed drop entry to stdout without writing to disk
#   -h, --help              show this help message
#
# WHY THIS EXISTS.  Tasks produce tactical discoveries, gotchas, and candidate
# claims that may or may not survive global curation.  This helper captures
# those claims in data/memory/drop/<task-id>.md so a later dream pass can
# evaluate, promote, or discard them without polluting working memory in RAM.
#
# IDEMPOTENT.  Running this helper multiple times for the same task updates the
# metadata and merges candidate claims without losing previously recorded claims.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
MEMORY="$DATA/memory"
DROP_DIR="$MEMORY/drop"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() {
  printf 'fm-memory-drop: %s\n' "$1" >&2
  exit 1
}

TASK_ID=""
PROJECT=""
REPORT=""
COMMIT=""
CLAIMS=()
CLAIMS_FILE=""
DATE_OVERRIDE=""
DRY_RUN=0

# Parse arguments
while [ "$#" -gt 0 ]; do
  case "$1" in
    --task)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      TASK_ID="$2"; shift 2 ;;
    --project)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      PROJECT="$2"; shift 2 ;;
    --report)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      REPORT="$2"; shift 2 ;;
    --commit)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      COMMIT="$2"; shift 2 ;;
    --claim)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      CLAIMS+=("$2"); shift 2 ;;
    --claims-file|--file)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      CLAIMS_FILE="$2"; shift 2 ;;
    --date)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      DATE_OVERRIDE="$2"; shift 2 ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    -*)
      usage >&2; exit 2 ;;
    *)
      if [ -z "$TASK_ID" ]; then
        TASK_ID="$1"
        shift
      else
        usage >&2; exit 2
      fi
      ;;
  esac
done

[ -n "$TASK_ID" ] || die 'missing required task-id'

# Validate task ID against path traversal and dangerous characters
case "$TASK_ID" in
  ''|*[!A-Za-z0-9._-]*|'.'|'..')
    die "invalid task-id: '$TASK_ID'"
    ;;
esac

# Validate date if supplied, or default to UTC today
TODAY="${DATE_OVERRIDE:-$(date -u +%Y-%m-%d)}"
case "$TODAY" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
  *) die "invalid date format: '$TODAY' (expected YYYY-MM-DD)" ;;
esac

# Auto-detect missing metadata gracefully from state/<task-id>.meta if present
META_FILE="$STATE/$TASK_ID.meta"
if [ -f "$META_FILE" ] && [ ! -L "$META_FILE" ]; then
  if [ -z "$PROJECT" ]; then
    PROJECT=$(awk -F= '$1 == "project" { print $2; exit }' "$META_FILE" 2>/dev/null || true)
  fi
  if [ -z "$REPORT" ]; then
    REPORT=$(awk -F= '$1 == "report" { print $2; exit }' "$META_FILE" 2>/dev/null || true)
  fi
  if [ -z "$COMMIT" ]; then
    COMMIT=$(awk -F= '$1 ~ /^(commit|head|pr_head)$/ { print $2; exit }' "$META_FILE" 2>/dev/null || true)
  fi
fi

# Auto-detect report path if still empty
if [ -z "$REPORT" ]; then
  if [ -f "$DATA/$TASK_ID/report.md" ] && [ ! -L "$DATA/$TASK_ID/report.md" ]; then
    REPORT="data/$TASK_ID/report.md"
  fi
fi

# Load claims from claims-file if specified
if [ -n "$CLAIMS_FILE" ]; then
  [ -f "$CLAIMS_FILE" ] || die "claims file not found: '$CLAIMS_FILE'"
  while IFS= read -r line; do
    # Strip leading markdown bullet or whitespace if present
    line=$(printf '%s\n' "$line" | sed -e 's/^[[:space:]]*[-*][[:space:]]*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$line" ] || continue
    # Skip markdown headings or horizontal rules
    case "$line" in
      '#'*|'---'*|'==='*) continue ;;
    esac
    CLAIMS+=("$line")
  done < "$CLAIMS_FILE"
fi

TARGET_FILE="$DROP_DIR/$TASK_ID.md"

# Collect existing claims if target file already exists (idempotency)
EXISTING_CLAIMS=()
if [ -f "$TARGET_FILE" ] && [ ! -L "$TARGET_FILE" ]; then
  in_body=0
  while IFS= read -r line; do
    if [ "$line" = "---" ]; then
      if [ "$in_body" -eq 0 ]; then
        in_body=1
        continue
      fi
    fi
    if [ "$in_body" -ge 1 ]; then
      # If line is a bullet item
      if printf '%s\n' "$line" | grep -q '^[[:space:]]*[-*][[:space:]]'; then
        clean_claim=$(printf '%s\n' "$line" | sed -e 's/^[[:space:]]*[-*][[:space:]]*//' -e 's/[[:space:]]*$//')
        [ -n "$clean_claim" ] && EXISTING_CLAIMS+=("$clean_claim")
      fi
    fi
  done < "$TARGET_FILE"
fi

# Merge claims with deduplication. The seen-set is newline delimited because a
# claim is always a single line, so no claim can straddle the delimiter and be
# mistaken for the concatenation of two claims already captured.
ALL_CLAIMS=()
NL=$'\n'
SEEN_CLAIMS="$NL"

# Add newly passed claims first
for c in "${CLAIMS[@]-}"; do
  [ -n "$c" ] || continue
  case "$SEEN_CLAIMS" in
    *"$NL$c$NL"*) continue ;;
  esac
  SEEN_CLAIMS="$SEEN_CLAIMS$c$NL"
  ALL_CLAIMS+=("$c")
done

# Add existing claims
for c in "${EXISTING_CLAIMS[@]-}"; do
  [ -n "$c" ] || continue
  case "$SEEN_CLAIMS" in
    *"$NL$c$NL"*) continue ;;
  esac
  SEEN_CLAIMS="$SEEN_CLAIMS$c$NL"
  ALL_CLAIMS+=("$c")
done

# If no claims were provided or found, fallback to placeholder
if [ "${#ALL_CLAIMS[@]}" -eq 0 ]; then
  if [ -n "$REPORT" ]; then
    ALL_CLAIMS+=("Task completed with report pointer: $REPORT")
  else
    ALL_CLAIMS+=("Task completed: $TASK_ID")
  fi
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/.fm-memory-drop.XXXXXX") || die 'could not create temporary directory'
# shellcheck disable=SC2329 # Registered by EXIT trap
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# Render drop entry
{
  printf -- '---\n'
  printf 'task: %s\n' "$TASK_ID"
  printf 'date: %s\n' "$TODAY"
  [ -n "$PROJECT" ] && printf 'project: %s\n' "$PROJECT"
  [ -n "$REPORT" ] && printf 'report: %s\n' "$REPORT"
  [ -n "$COMMIT" ] && printf 'commit: %s\n' "$COMMIT"
  printf -- '---\n\n'
  printf '# Candidate claims: %s\n\n' "$TASK_ID"
  for c in "${ALL_CLAIMS[@]}"; do
    printf -- '- %s\n' "$c"
  done
} > "$TMP/drop_entry.md"

if [ "$DRY_RUN" -eq 1 ]; then
  cat "$TMP/drop_entry.md"
  exit 0
fi

# Guard destination directory
[ ! -L "$MEMORY" ] || die "data/memory is a symlink; refusing to write"
[ ! -L "$DROP_DIR" ] || die "data/memory/drop is a symlink; refusing to write"
[ -d "$DROP_DIR" ] || mkdir -p "$DROP_DIR" || die "could not create $DROP_DIR"

if [ -L "$TARGET_FILE" ]; then
  die "refusing to overwrite symlinked target: $TARGET_FILE"
fi

cp "$TMP/drop_entry.md" "$DROP_DIR/.$TASK_ID.md.tmp" || die "could not stage drop file"
mv -f "$DROP_DIR/.$TASK_ID.md.tmp" "$TARGET_FILE" || die "could not publish drop file"

printf 'drop: deposited candidate claims for %s to data/memory/drop/%s.md (%s claim(s))\n' \
  "$TASK_ID" "$TASK_ID" "${#ALL_CLAIMS[@]}"
exit 0
