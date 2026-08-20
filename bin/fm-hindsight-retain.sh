#!/usr/bin/env bash
# fm-hindsight-retain.sh - retain finished investigation reports and decisions in Hindsight.
#
# Semantic policy:
# - Captain boundary: Investigation reports (data/*/report.md) and decision
#   records (data/decisions/*.md). Nothing else.
# - Explicitly prohibited: captain.md, captain-shared.md, data/memory/*,
#   data/backlog.md, data/done-archive.md, and state/*.
# - Never send credentials, tokens, or .env secrets. Files containing them are
#   skipped and reported.
# - Retain is fire-and-forget on critical paths: never blocks teardown, session
#   start, or worker lifecycle.
# - Idempotent on document_id (report:<task-id> or decision:<slug>).
#
# Usage:
#   fm-hindsight-retain.sh <file> [--fire-and-forget] [--url <url>] [--bank <bank>]
#   fm-hindsight-retain.sh --backfill [--url <url>] [--bank <bank>]

set -u

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_HOME="${FM_HOME:-$(pwd)}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
HINDSIGHT_URL="${FM_HINDSIGHT_URL:-${HINDSIGHT_URL:-http://hindsight-1:8888}}"
HINDSIGHT_BANK="${FM_HINDSIGHT_BANK:-${HINDSIGHT_BANK:-firstmate}}"

DOC_ID=""
CONTEXT=""
TAGS_JSON="[]"
REL_PATH=""

usage() {
  cat << 'EOF'
Usage:
  fm-hindsight-retain.sh <file> [--fire-and-forget] [--url <url>] [--bank <bank>]
  fm-hindsight-retain.sh --backfill [--url <url>] [--bank <bank>]

Options:
  --fire-and-forget, -f  Run retain in background and return immediately
  --backfill             Backfill all reports and decisions in data/
  --url <url>            Hindsight base URL (default: http://hindsight-1:8888)
  --bank <bank>          Hindsight bank ID (default: firstmate)
  -h, --help             Show this help message
EOF
}

# Resolve canonical path
canonical_path() {
  local p=$1
  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$p" 2>/dev/null || readlink -f "$p" 2>/dev/null || printf '%s\n' "$p"
  elif command -v readlink >/dev/null 2>&1; then
    readlink -f "$p" 2>/dev/null || printf '%s\n' "$p"
  else
    printf '%s\n' "$p"
  fi
}

# Validate that a path is strictly inside the authorized corpus:
# data/*/report.md (excluding memory/ and decisions/) OR data/decisions/*.md
validate_corpus() {
  local file=$1 canon_file canon_data rel
  canon_file=$(canonical_path "$file")
  canon_data=$(canonical_path "$DATA")

  case "$canon_file" in
    "$canon_data"/decisions/*.md)
      return 0
      ;;
    "$canon_data"/*/report.md)
      rel=${canon_file#"$canon_data"/}
      case "$rel" in
        memory/*|decisions/*)
          return 1
          ;;
        *)
          return 0
          ;;
      esac
      ;;
    *)
      return 1
      ;;
  esac
}

# Scan content for credentials and tokens
contains_credentials() {
  local file=$1 content
  content=$(cat "$file" 2>/dev/null || true)

  # Check standard API key / token patterns
  if printf '%s' "$content" | grep -E -q \
    'sk-[-a-zA-Z0-9_]{20,}|ghp_[a-zA-Z0-9]{30,}|gho_[a-zA-Z0-9]{30,}|github_pat_[-a-zA-Z0-9_]{30,}|AIza[-0-9A-Za-z_]{35}|nvapi-[-a-zA-Z0-9_]{20,}|xai-[-a-zA-Z0-9_]{20,}|eyJ[-a-zA-Z0-9_]{30,}\.eyJ[-a-zA-Z0-9_]{30,}'; then
    return 0
  fi

  # Check bearer token pattern
  if printf '%s' "$content" | grep -E -i -q 'bearer[[:space:]]+[-a-zA-Z0-9_.-]{25,}'; then
    return 0
  fi

  # Check against local .env if present
  if [ -f "$FM_HOME/.env" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        ''|'#'*) continue ;;
        *'='*)
          local val
          val=$(printf '%s' "${line#*=}" | tr -d '"' | tr -d "'" | xargs)
          if [ "${#val}" -ge 12 ] && printf '%s' "$content" | grep -F -q "$val"; then
            return 0
          fi
          ;;
      esac
    done < "$FM_HOME/.env"
  fi

  return 1
}

# Derive document_id, context, tags, and relative path
derive_metadata() {
  local file=$1 canon_file canon_data rel
  canon_file=$(canonical_path "$file")
  canon_data=$(canonical_path "$DATA")
  rel=${canon_file#"$canon_data"/}

  case "$canon_file" in
    "$canon_data"/decisions/*.md)
      local slug
      slug=$(basename "$file" .md)
      DOC_ID="decision:$slug"
      CONTEXT="decision record: $slug"
      TAGS_JSON=$(jq -n --arg s "$slug" '["decision", $s]')
      REL_PATH="data/decisions/$slug.md"
      ;;
    "$canon_data"/*/report.md)
      local task_id
      task_id=$(basename "$(dirname "$canon_file")")
      DOC_ID="report:$task_id"
      CONTEXT="investigation report: $task_id"
      TAGS_JSON=$(jq -n --arg t "$task_id" '["report", $t]')
      REL_PATH="data/$task_id/report.md"
      ;;
    *)
      return 1
      ;;
  esac
}

# Perform synchronous retain of one file
retain_single_file() {
  local file=$1 tmp_payload resp rc=0 url

  if ! validate_corpus "$file"; then
    printf 'REFUSED: path '\''%s'\'' is outside authorized Hindsight corpus (data/*/report.md and data/decisions/*.md only)\n' "$file" >&2
    return 1
  fi

  if [ ! -f "$file" ]; then
    printf 'error: file not found: %s\n' "$file" >&2
    return 1
  fi

  if contains_credentials "$file"; then
    printf 'SKIP: '\''%s'\'' contains potential credentials/tokens; skipped from Hindsight retention.\n' "$file" >&2
    return 0
  fi

  derive_metadata "$file" || return 1
  tmp_payload=$(mktemp)

  jq -n \
    --rawfile content "$file" \
    --arg doc_id "$DOC_ID" \
    --arg context "$CONTEXT" \
    --arg path "$REL_PATH" \
    --argjson tags "$TAGS_JSON" \
    '{
      items: [
        {
          content: $content,
          document_id: $doc_id,
          context: $context,
          tags: $tags,
          metadata: {path: $path}
        }
      ],
      async: false
    }' > "$tmp_payload"

  url="$HINDSIGHT_URL/v1/default/banks/$HINDSIGHT_BANK/memories"
  resp=$(curl -s -S --connect-timeout 3 --max-time 300 \
    -X POST "$url" \
    -H "Content-Type: application/json" \
    --data-binary @"$tmp_payload" 2>&1) || rc=$?
  rm -f "$tmp_payload"

  if [ "$rc" -ne 0 ]; then
    printf 'error: retain request failed (exit %s): %s\n' "$rc" "$resp" >&2
    return 1
  fi

  if printf '%s' "$resp" | grep -q '"success":true'; then
    printf 'retained: %s (%s)\n' "$DOC_ID" "$REL_PATH"
    return 0
  else
    printf 'error: retain failed for %s: %s\n' "$file" "$resp" >&2
    return 1
  fi
}

# Retain a batch of files asynchronously
retain_batch() {
  local files=("$@") tmp_payload url resp rc=0
  tmp_payload=$(mktemp)

  python3 - "${files[@]}" > "$tmp_payload" << 'PY'
import sys, json, os

items = []
for file_path in sys.argv[1:]:
    with open(file_path, 'r', errors='ignore') as fp:
        content = fp.read()
    
    canon_file = os.path.realpath(file_path)
    if "/decisions/" in canon_file and canon_file.endswith(".md"):
        slug = os.path.basename(file_path)[:-3]
        doc_id = f"decision:{slug}"
        context = f"decision record: {slug}"
        tags = ["decision", slug]
        rel_path = f"data/decisions/{slug}.md"
    else:
        task_id = os.path.basename(os.path.dirname(canon_file))
        doc_id = f"report:{task_id}"
        context = f"investigation report: {task_id}"
        tags = ["report", task_id]
        rel_path = f"data/{task_id}/report.md"
        
    items.append({
        "content": content,
        "document_id": doc_id,
        "context": context,
        "tags": tags,
        "metadata": {"path": rel_path}
    })

json.dump({"items": items, "async": True}, sys.stdout)
PY

  url="$HINDSIGHT_URL/v1/default/banks/$HINDSIGHT_BANK/memories"
  resp=$(curl -s -S --connect-timeout 5 --max-time 120 \
    -X POST "$url" \
    -H "Content-Type: application/json" \
    --data-binary @"$tmp_payload" 2>&1) || rc=$?
  rm -f "$tmp_payload"

  if [ "$rc" -ne 0 ]; then
    printf 'error: batch retain request failed (exit %s): %s\n' "$rc" "$resp" >&2
    return 1
  fi

  if printf '%s' "$resp" | grep -q '"success":true'; then
    for file in "${files[@]}"; do
      derive_metadata "$file" || continue
      printf 'retained: %s (%s)\n' "$DOC_ID" "$REL_PATH"
    done
    return 0
  else
    printf 'error: batch retain failed: %s\n' "$resp" >&2
    return 1
  fi
}

# Ensure bank exists
ensure_bank() {
  local url="$HINDSIGHT_URL/v1/default/banks/$HINDSIGHT_BANK"
  curl -s -S --connect-timeout 3 --max-time 10 \
    -X PUT "$url" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg name "$HINDSIGHT_BANK" '{name: $name}')" >/dev/null 2>&1 || true
}

# Fetch currently retained document IDs
fetch_existing_docs() {
  local url="$HINDSIGHT_URL/v1/default/banks/$HINDSIGHT_BANK/documents?limit=1000"
  curl -s --connect-timeout 3 --max-time 30 "$url" 2>/dev/null | jq -r '.items[].id' 2>/dev/null || true
}

# Wait for operations to complete
wait_for_operations() {
  local url="$HINDSIGHT_URL/v1/default/banks/$HINDSIGHT_BANK/operations"
  local start_time now elapsed ops_json pending_count
  start_time=$(date +%s)

  while true; do
    ops_json=$(curl -s --connect-timeout 3 --max-time 10 "$url" 2>/dev/null || true)
    if [ -z "$ops_json" ]; then
      break
    fi

    pending_count=$(printf '%s' "$ops_json" | jq '[.operations[]? | select(.status == "pending" or .status == "processing")] | length' 2>/dev/null || echo 0)
    if [ "$pending_count" -eq 0 ]; then
      break
    fi

    now=$(date +%s)
    elapsed=$((now - start_time))
    if [ "$elapsed" -ge 900 ]; then
      printf 'warning: operations wait timed out after %ss (%s operations still in progress)\n' "$elapsed" "$pending_count" >&2
      break
    fi

    sleep 3
  done
}

# Perform backfill
run_backfill() {
  local existing_docs candidate_files missing_items=() file
  local total=0 retained=0 skipped_existing=0 skipped_cred=0 failed=0

  ensure_bank
  existing_docs=$(fetch_existing_docs)

  candidate_files=()
  if [ -d "$DATA" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] && candidate_files+=("$f")
    done < <(find "$DATA" -mindepth 2 -maxdepth 2 -type f -name report.md 2>/dev/null | grep -v "/memory/" | grep -v "/decisions/" | sort)

    if [ -d "$DATA/decisions" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] && candidate_files+=("$f")
      done < <(find "$DATA/decisions" -maxdepth 1 -type f -name "*.md" 2>/dev/null | sort)
    fi
  fi

  for file in "${candidate_files[@]}"; do
    total=$((total + 1))
    if ! validate_corpus "$file"; then
      continue
    fi

    if contains_credentials "$file"; then
      printf 'SKIP: '\''%s'\'' contains potential credentials/tokens; skipped from Hindsight retention.\n' "$file" >&2
      skipped_cred=$((skipped_cred + 1))
      continue
    fi

    derive_metadata "$file" || continue

    if printf '%s\n' "$existing_docs" | grep -F -x -q "$DOC_ID"; then
      printf 'already present: %s (%s)\n' "$DOC_ID" "$REL_PATH"
      skipped_existing=$((skipped_existing + 1))
      continue
    fi

    missing_items+=("$file")
  done

  if [ "${#missing_items[@]}" -gt 0 ]; then
    local batch_size=10 batch=()
    for file in "${missing_items[@]}"; do
      batch+=("$file")
      if [ "${#batch[@]}" -ge "$batch_size" ]; then
        if retain_batch "${batch[@]}"; then
          retained=$((retained + ${#batch[@]}))
        else
          failed=$((failed + ${#batch[@]}))
        fi
        batch=()
      fi
    done

    if [ "${#batch[@]}" -gt 0 ]; then
      if retain_batch "${batch[@]}"; then
        retained=$((retained + ${#batch[@]}))
      else
        failed=$((failed + ${#batch[@]}))
      fi
    fi

    wait_for_operations
  fi

  printf 'backfill summary: %s retained, %s already present, %s skipped for credentials, %s failed, %s total\n' \
    "$retained" "$skipped_existing" "$skipped_cred" "$failed" "$total"

  [ "$failed" -eq 0 ]
}

# Entrypoint argument parsing
TARGET_FILE=""
FIRE_AND_FORGET=0
IS_BACKFILL=0

while [ $# -gt 0 ]; do
  case "$1" in
    --backfill|backfill)
      IS_BACKFILL=1
      shift
      ;;
    --fire-and-forget|-f)
      FIRE_AND_FORGET=1
      shift
      ;;
    --url)
      HINDSIGHT_URL=$2
      shift 2
      ;;
    --bank)
      HINDSIGHT_BANK=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      printf 'unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -z "$TARGET_FILE" ]; then
        TARGET_FILE=$1
      else
        printf 'unexpected extra argument: %s\n' "$1" >&2
        usage >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [ "$IS_BACKFILL" -eq 1 ]; then
  run_backfill
  exit $?
fi

if [ -z "$TARGET_FILE" ]; then
  usage >&2
  exit 2
fi

if [ "$FIRE_AND_FORGET" -eq 1 ]; then
  # Pre-validate boundary and existence synchronously so invalid calls fail fast
  if ! validate_corpus "$TARGET_FILE"; then
    printf 'REFUSED: path '\''%s'\'' is outside authorized Hindsight corpus (data/*/report.md and data/decisions/*.md only)\n' "$TARGET_FILE" >&2
    exit 1
  fi
  if [ ! -f "$TARGET_FILE" ]; then
    printf 'error: file not found: %s\n' "$TARGET_FILE" >&2
    exit 1
  fi

  # Detach in background
  (
    FM_HOME="$FM_HOME" FM_DATA_OVERRIDE="$DATA" FM_HINDSIGHT_URL="$HINDSIGHT_URL" FM_HINDSIGHT_BANK="$HINDSIGHT_BANK" \
      "$SCRIPT_DIR/fm-hindsight-retain.sh" "$TARGET_FILE" --url "$HINDSIGHT_URL" --bank "$HINDSIGHT_BANK" >/dev/null 2>&1
  ) >/dev/null 2>&1 &
  disown $! 2>/dev/null || true
  exit 0
fi

retain_single_file "$TARGET_FILE"
