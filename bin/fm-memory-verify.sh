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
#      using bin/fm-memory-compile.sh and bin/fm-startup-memory-budget-lib.sh,
#      and the catalog must survive the cap so every note stays reachable;
#   2. Citations: every note and a non-empty core.md must cite at least one
#      existing source file, report, or task record on disk. Incidental paths
#      mentioned in prose are reported but do not block publication.
#   3. Constitution: the standing constitution a session sees today must still
#      be there tomorrow. Both sides are resolved by the one predicate
#      bin/fm-memory-compile.sh applies to pick a core - the generation's own
#      core.md whenever that file exists at all, and data/captain.md only when
#      it does not. Today's side is read from the generation data/memory/HEAD
#      publishes, tomorrow's from the proposed generation. A standing rule
#      counts as preserved only when its wording survives inside one statement
#      of the proposed core, not merely somewhere in the document;
#   4. Diff bounds: a single generation cannot replace or delete excessive
#      proportions of memory (default: max 50% deletion of baseline notes) and
#      can never delete every baseline note, however small the baseline is.
#      The baseline is the notes the live generation shows a session, so notes
#      the compiler does not read cannot bound what a new generation may drop.
#
# The generation must live under data/memory: data/memory/HEAD holds the
# data/memory-relative identifier, which is the only form the compiler resolves.
#
# ATOMIC PUBLICATION.  When publishing, data/memory/HEAD is updated via atomic
# file swap (.HEAD.tmp -> HEAD) only after all four checks pass.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
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

# A symlinked data/memory defeats every per-file guard below in one step, so no
# verdict is issued for such a home at all rather than a green one measured
# through the link.
[ ! -L "$MEMORY" ] || die 'data/memory is a symlink; refusing to verify through it'

# Resolve proposed generation directory
GEN_DIR=""
GEN_IDENTIFIER=""

# Check if target is a simple number or gen/<N> or explicit path
if [ -d "$MEMORY/gen/$TARGET" ] && [ ! -L "$MEMORY/gen/$TARGET" ]; then
  GEN_DIR="$MEMORY/gen/$TARGET"
elif [ -d "$MEMORY/$TARGET" ] && [ ! -L "$MEMORY/$TARGET" ]; then
  GEN_DIR="$MEMORY/$TARGET"
elif [ -d "$TARGET" ] && [ ! -L "$TARGET" ]; then
  GEN_DIR="$TARGET"
else
  die "proposed generation directory does not exist or is a symlink: '$TARGET'"
fi

# Canonical check: generation directory must not be a symlink
[ ! -L "$GEN_DIR" ] || die "generation directory is a symlink: '$GEN_DIR'"
[ ! -L "$GEN_DIR/notes" ] \
  || die "proposed generation's notes/ is a symlink, which the compiler refuses to read: '$GEN_DIR/notes'"

# bin/fm-memory-compile.sh resolves data/memory/HEAD relative to data/memory,
# so the identifier written there is derived once from the canonical location
# of the generation rather than from whatever form the target was typed in.
# A target outside data/memory can never become a resolvable pointer.
MEMORY_CANON=$(cd "$MEMORY" 2>/dev/null && pwd -P) \
  || die "data/memory does not exist; cannot resolve a generation pointer"
GEN_CANON=$(cd "$GEN_DIR" 2>/dev/null && pwd -P) \
  || die "could not resolve generation directory: '$TARGET'"
if [ "$GEN_CANON" = "$MEMORY_CANON" ]; then
  GEN_IDENTIFIER=""
else
  case "$GEN_CANON" in
    "$MEMORY_CANON"/*)
      GEN_IDENTIFIER="${GEN_CANON#"$MEMORY_CANON"/}" ;;
    *)
      die "generation directory must live under data/memory to be publishable: '$TARGET'" ;;
  esac
  case "$GEN_IDENTIFIER" in
    *..*|*[[:space:]]*)
      die "generation identifier is not a usable HEAD pointer: '$GEN_IDENTIFIER'" ;;
  esac
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/.fm-memory-verify.XXXXXX") || die 'could not create temporary directory'
# shellcheck disable=SC2329 # Registered by EXIT trap
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# resolve_baseline_gen_dir: sets BASELINE_GEN_DIR to the generation directory
# data/memory/HEAD currently publishes, or to data/memory when HEAD names
# nothing resolvable. Both the constitution and the diff-bounds check need the
# same answer to "what is live right now", so it is resolved in one place.
# dir_inside_memory <dir>: true when the directory physically lives under
# data/memory. A path can name only real directories at its two ends and still
# be a link in the middle, so containment is settled physically.
dir_inside_memory() {
  local d_phys root_phys
  d_phys=$(cd "$1" 2>/dev/null && pwd -P) || return 1
  root_phys=$(cd "$MEMORY" 2>/dev/null && pwd -P) || return 1
  case "$d_phys" in
    "$root_phys"|"$root_phys"/*) return 0 ;;
  esac
  return 1
}

# compiler_notes_dir <generation-dir>: sets NOTES_DIR_FOR to the notes directory
# bin/fm-memory-compile.sh would enumerate for that generation, and returns
# non-zero when it would enumerate nothing. A symlinked notes/ is refused there,
# so counting notes through one here would measure a bound over notes no session
# will ever see.
NOTES_DIR_FOR=""
compiler_notes_dir() {
  NOTES_DIR_FOR=""
  [ -n "$1" ] || return 1
  [ -d "$1/notes" ] && [ ! -L "$1/notes" ] || return 1
  NOTES_DIR_FOR="$1/notes"
  return 0
}

BASELINE_GEN_DIR=""
resolve_baseline_gen_dir() {
  local head_target
  BASELINE_GEN_DIR=""

  if [ -f "$MEMORY/HEAD" ] && [ ! -L "$MEMORY/HEAD" ]; then
    head_target=$(head -n 1 "$MEMORY/HEAD" | tr -d '\r\n[:space:]')
    case "$head_target" in
      ''|*..*|/*) ;;
      *)
        if [ -d "$MEMORY/$head_target" ] && [ ! -L "$MEMORY/$head_target" ] \
          && dir_inside_memory "$MEMORY/$head_target"; then
          BASELINE_GEN_DIR="$MEMORY/$head_target"
        elif [ -d "$MEMORY/gen/$head_target" ] && [ ! -L "$MEMORY/gen/$head_target" ] \
          && dir_inside_memory "$MEMORY/gen/$head_target"; then
          BASELINE_GEN_DIR="$MEMORY/gen/$head_target"
        fi
        ;;
    esac
  fi

  if [ -z "$BASELINE_GEN_DIR" ] && [ -d "$MEMORY" ] && [ ! -L "$MEMORY" ]; then
    BASELINE_GEN_DIR="$MEMORY"
  fi
}

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

  if [ "$catalog" = "0" ]; then
    printf 'FAIL budget: core (%s tokens) leaves no room for the catalog within the %s token budget, so the catalog and every note were dropped and no note is reachable\n' \
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

  # A citation names provenance inside the home or the repo, so a parent
  # traversal is never legitimate: it would let fabricated provenance resolve
  # against any file on the host.
  case "$p" in
    ..|../*|*/../*|*/..) return 1 ;;
  esac

  # Only an absolute citation may be probed as written. A relative one belongs
  # to the home, not to whatever directory the operator happens to stand in.
  case "$p" in
    /*)
      if [ -e "$p" ] || [ -L "$p" ]; then
        return 0
      fi
      return 1
      ;;
  esac

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

  # Provenance frozen by bin/fm-memory-migrate.sh: it stamps notes with the
  # pre-migration path (for example data/learnings.md), copies the original to
  # data/memory/raw/<stem>-<date>.<ext>, and only then removes it from data/.
  # The cited path is therefore gone while its content is still durably on
  # disk, so the frozen copy is what makes such a citation resolvable.
  local base stem
  base=${p##*/}
  stem=${base%.*}
  if [ -n "$stem" ]; then
    for candidate in "$MEMORY/raw/$stem"-*.* "$MEMORY/raw/$base"; do
      if [ -f "$candidate" ] && [ ! -L "$candidate" ]; then
        return 0
      fi
    done
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
      # `\<` is a GNU extension: mawk and BSD awk never match it, so the
      # boundary is spelled out as an explicit leading character class.
      while (match(line, /(^|[^A-Za-z0-9_\/])(data|state|docs|bin|tests|projects|\.agents)\/[A-Za-z0-9_.\/-]+/)) {
        cstart = RSTART
        clen = RLENGTH
        cite = substr(line, cstart, clen)
        if (cite !~ /^(data|state|docs|bin|tests|projects|\.agents)\//) {
          cstart = cstart + 1
          clen = clen - 1
          cite = substr(line, cstart, clen)
        }
        print cite
        line = substr(line, cstart + clen)
      }
    }
  ' "$file" | sed -e 's/^[][[:space:]"'\'')(`><.,:;]*//' -e 's/[][[:space:]"'\'')(`><.,:;]*$//' \
           | awk 'NF > 0 && !seen[$0]++'
}

# tally_citations <file>: writes CITED_COUNT, CITED_VALID and CITED_UNRESOLVED
# for one file. Arrays and `mapfile` are avoided throughout: stock macOS ships
# Bash 3.2, which has neither, and the CI parse sweep cannot catch a runtime
# builtin lookup.
tally_citations() {
  local file=$1 cited
  CITED_COUNT=0
  CITED_VALID=0
  CITED_UNRESOLVED=""

  extract_citations_from_file "$file" > "$TMP/cited"
  while IFS= read -r cited; do
    [ -n "$cited" ] || continue
    CITED_COUNT=$((CITED_COUNT + 1))
    if resolve_source_path "$cited"; then
      CITED_VALID=$((CITED_VALID + 1))
    else
      CITED_UNRESOLVED="$CITED_UNRESOLVED \"$cited\""
    fi
  done < "$TMP/cited"
}

check_citations() {
  local note_count=0 valid_citations=0 note
  local file_err=0

  if compiler_notes_dir "$GEN_DIR"; then
    for note in "$NOTES_DIR_FOR"/*.md; do
      [ -f "$note" ] && [ ! -L "$note" ] || continue
      note_count=$((note_count + 1))
      local note_slug
      note_slug=$(basename "$note")

      tally_citations "$note"
      valid_citations=$((valid_citations + CITED_VALID))

      if [ "$CITED_COUNT" -eq 0 ]; then
        printf 'FAIL citations: note notes/%s has no citations or source metadata\n' \
          "$note_slug" >&2
        file_err=$((file_err + 1))
      elif [ "$CITED_VALID" -eq 0 ]; then
        printf 'FAIL citations: note notes/%s cites missing or unresolvable source:%s\n' \
          "$note_slug" "$CITED_UNRESOLVED" >&2
        file_err=$((file_err + 1))
      elif [ -n "$CITED_UNRESOLVED" ]; then
        printf 'WARN citations: note notes/%s mentions unresolvable path(s):%s; accepted because the note also cites a resolvable source\n' \
          "$note_slug" "$CITED_UNRESOLVED" >&2
      fi
    done
  fi

  # Check core.md citations if present
  if [ -f "$GEN_DIR/core.md" ] && [ ! -L "$GEN_DIR/core.md" ] && [ -s "$GEN_DIR/core.md" ]; then
    tally_citations "$GEN_DIR/core.md"
    valid_citations=$((valid_citations + CITED_VALID))

    if [ "$CITED_COUNT" -eq 0 ]; then
      printf 'FAIL citations: core.md has no citations or source metadata\n' >&2
      file_err=$((file_err + 1))
    elif [ "$CITED_VALID" -eq 0 ]; then
      printf 'FAIL citations: core.md cites missing or unresolvable source:%s\n' \
        "$CITED_UNRESOLVED" >&2
      file_err=$((file_err + 1))
    elif [ -n "$CITED_UNRESOLVED" ]; then
      printf 'WARN citations: core.md mentions unresolvable path(s):%s; accepted because core.md also cites a resolvable source\n' \
        "$CITED_UNRESOLVED" >&2
    fi
  fi

  if [ "$file_err" -gt 0 ]; then
    return 1
  fi

  printf 'PASS citations: all claims cite existing sources (%s verified citations across %s note(s))\n' \
    "$valid_citations" "$note_count"
  return 0
}

# --- 3. Standing Constitution Safety ----------------------------------------

# compiler_core_file <path>: exactly the test bin/fm-memory-compile.sh applies
# when it picks a core, and nothing more. Emptiness is deliberately not part of
# it: the compiler injects a 0-byte core.md and suppresses data/captain.md
# behind it, so treating an empty core as "no core here" is what would let a
# whole standing constitution vanish behind a PASS.
compiler_core_file() {
  [ -f "$1" ] && [ ! -L "$1" ]
}

# standing_core_for <generation-dir>: sets STANDING_CORE to the file
# bin/fm-memory-compile.sh would inject as that generation's core, and
# STANDING_CORE_IS_GEN to 1 when it is the generation's own core.md. Both the
# live and the proposed side must be resolved by this one rule: resolving them
# differently is what lets a rule that lives in only one of them disappear.
STANDING_CORE=""
STANDING_CORE_IS_GEN=0
standing_core_for() {
  STANDING_CORE=""
  STANDING_CORE_IS_GEN=0

  if [ -n "$1" ] && compiler_core_file "$1/core.md"; then
    STANDING_CORE="$1/core.md"
    STANDING_CORE_IS_GEN=1
    return 0
  fi

  if compiler_core_file "$DATA/captain.md"; then
    STANDING_CORE="$DATA/captain.md"
    return 0
  fi

  return 1
}

check_constitution() {
  local baseline_file="" baseline_label="" target_file="" target_label=""

  resolve_baseline_gen_dir
  if standing_core_for "$BASELINE_GEN_DIR"; then
    baseline_file="$STANDING_CORE"
    if [ "$STANDING_CORE_IS_GEN" -eq 1 ]; then
      baseline_label='the published core.md'
    else
      baseline_label='data/captain.md'
    fi
  fi

  if [ -z "$baseline_file" ]; then
    printf 'PASS constitution: no standing baseline on disk; data/captain.md is absent and no published generation carries a core.md\n'
    return 0
  fi

  if standing_core_for "$GEN_DIR"; then
    target_file="$STANDING_CORE"
    if [ "$STANDING_CORE_IS_GEN" -eq 1 ]; then
      target_label='core.md'
    else
      target_label='data/captain.md (the compiler core while the generation has no core.md)'
    fi
  else
    printf 'FAIL constitution: %s carries standing preferences but the proposed generation has no core.md and no data/captain.md to fall back to\n' \
      "$baseline_label" >&2
    return 1
  fi

  if [ "$target_file" = "$baseline_file" ]; then
    printf 'PASS constitution: this generation does not change the standing constitution (%s)\n' \
      "$baseline_label"
    return 0
  fi

  # Every heading and bullet rule in the baseline must survive into the target
  local missing=0 heading rule clean_rule core_text
  core_text=$(LC_ALL=C tr '[:upper:]' '[:lower:]' < "$target_file")

  # One standing statement per line, continuations folded in, so a rule counts
  # as preserved only when its wording survives inside a single statement.
  # Scoring against the whole document instead lets vocabulary scattered across
  # unrelated rules stand in for the rule that was deleted.
  awk '
    function flush() { if (block != "") { print block; block = "" } }
    /^[[:space:]]*$/ { flush(); next }
    /^[[:space:]]*[-*][[:space:]]/ { flush(); block = $0; next }
    /^#/ { flush(); block = $0; next }
    { block = (block == "" ? $0 : block " " $0) }
    END { flush() }
  ' > "$TMP/core_blocks" <<CORE_BLOCKS
$core_text
CORE_BLOCKS

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
    case "$core_text" in
      *"$heading"*) ;;
      *)
        printf 'FAIL constitution: standing section heading "%s" from %s is missing in %s\n' \
          "$heading" "$baseline_label" "$target_label" >&2
        missing=$((missing + 1))
        ;;
    esac
  done < <(grep '^#\{1,4\}[[:space:]]' "$baseline_file" || true)

  # 2. Check bullet rules and standing directives
  while IFS= read -r rule; do
    clean_rule=$(printf '%s\n' "$rule" | sed -e 's/^[[:space:]]*[-*][[:space:]]*//' -e 's/[[:space:]]*$//')
    [ -n "$clean_rule" ] || continue
    [ "${#clean_rule}" -ge 5 ] || continue
    
    # Extract substantive keywords from the rule to verify it wasn't dropped
    local keywords
    keywords=$(printf '%s\n' "$clean_rule" | LC_ALL=C tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' ' ' | awk '{ for(i=1;i<=NF;i++) if(length($i)>=4) printf "%s ", $i }')
    [ -n "$keywords" ] || continue

    local token total_tokens=0
    for token in $keywords; do
      total_tokens=$((total_tokens + 1))
    done
    [ "$total_tokens" -gt 0 ] || continue

    # The best single standing statement has to carry the rule, not the document
    local needed=$(( (total_tokens + 1) / 2 ))
    local match_count=0 block_hits target_block
    while IFS= read -r target_block || [ -n "$target_block" ]; do
      [ -n "$target_block" ] || continue
      block_hits=0
      for token in $keywords; do
        case "$target_block" in
          *"$token"*) block_hits=$((block_hits + 1)) ;;
        esac
      done
      if [ "$block_hits" -gt "$match_count" ]; then
        match_count=$block_hits
        [ "$match_count" -lt "$needed" ] || break
      fi
    done < "$TMP/core_blocks"

    if [ "$match_count" -lt "$needed" ]; then
      printf 'FAIL constitution: standing preference rule from %s was silently dropped or truncated in %s: "%s"\n' \
        "$baseline_label" "$target_label" "$clean_rule" >&2
      missing=$((missing + 1))
    fi
  done < <(grep '^[[:space:]]*[-*][[:space:]]' "$baseline_file" || true)

  if [ "$missing" -gt 0 ]; then
    return 1
  fi

  printf 'PASS constitution: standing preferences from %s are preserved in %s\n' \
    "$baseline_label" "$target_label"
  return 0
}

# --- 4. Diff Bounds Check ---------------------------------------------------

check_diff_bounds() {
  local base_dir="" base_notes=() gen_notes=() note
  local base_count=0 gen_count=0 deleted_count=0 modified_count=0 added_count=0

  # The baseline is whatever the live generation shows a session, and nothing
  # else. resolve_baseline_gen_dir already falls back to data/memory when
  # data/memory/HEAD names nothing, so a second fallback here would only fire
  # when HEAD does resolve, and would then bound the change against notes the
  # compiler already ignores.
  resolve_baseline_gen_dir
  if compiler_notes_dir "$BASELINE_GEN_DIR"; then
    base_dir="$NOTES_DIR_FOR"
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
  if compiler_notes_dir "$GEN_DIR"; then
    for note in "$NOTES_DIR_FOR"/*.md; do
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

  # Absolute floor first: a percentage cap is too coarse to catch a baseline of
  # one or two notes being replaced wholesale, so no generation may drop every
  # baseline note regardless of how small the baseline is.
  if [ "$deleted_count" -eq "$base_count" ]; then
    printf 'FAIL diff-bounds: proposed generation deletes every one of the %s baseline note(s)\n' \
      "$base_count" >&2
    return 1
  fi

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
  [ -n "$GEN_IDENTIFIER" ] \
    || die "data/memory itself is not a publishable generation; publish a directory under it"
  printf 'publish: --dry-run, all checks passed; would update data/memory/HEAD to point to %s\n' \
    "$GEN_IDENTIFIER"
  exit 0
fi

# Atomic pointer swap to data/memory/HEAD
[ -n "$GEN_IDENTIFIER" ] \
  || die "data/memory itself is not a publishable generation; publish a directory under it"
[ ! -L "$DATA/memory" ] || die "data/memory is a symlink; refusing to publish"
[ -d "$DATA/memory" ] || mkdir -p "$DATA/memory" || die "could not create data/memory"

if [ -L "$DATA/memory/HEAD" ]; then
  die "data/memory/HEAD is a symlink; refusing to overwrite"
fi

printf '%s\n' "$GEN_IDENTIFIER" > "$DATA/memory/.HEAD.tmp" || die "could not stage HEAD pointer"
mv -f "$DATA/memory/.HEAD.tmp" "$DATA/memory/HEAD" || die "could not update data/memory/HEAD"

printf 'memory: published generation %s to data/memory/HEAD\n' "$GEN_IDENTIFIER"
exit 0
