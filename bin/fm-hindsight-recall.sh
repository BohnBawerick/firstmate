#!/usr/bin/env bash
# fm-hindsight-recall.sh - query Hindsight memory bank for Firstmate on demand.
#
# Semantic policy:
# - On-demand recall for firstmate to search past investigations and decisions.
# - Never injected automatically into prompt or context.
# - Compact, greppable output format by default; JSON supported via --json.
#
# Usage:
#   fm-hindsight-recall.sh <query> [--bank <bank>] [--url <url>] [--limit <n>] [--json]

set -u

HINDSIGHT_URL="${FM_HINDSIGHT_URL:-${HINDSIGHT_URL:-http://hindsight-1:8888}}"
HINDSIGHT_BANK="${FM_HINDSIGHT_BANK:-${HINDSIGHT_BANK:-firstmate}}"
QUERY=""
FORMAT_JSON=0
MAX_TOKENS=4096

usage() {
  cat << 'EOF'
Usage:
  fm-hindsight-recall.sh <query> [--bank <bank>] [--url <url>] [--json]

Options:
  --bank <bank>  Hindsight bank ID (default: firstmate)
  --url <url>    Hindsight base URL (default: http://hindsight-1:8888)
  --json         Output raw JSON response
  -h, --help     Show this help message
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json)
      FORMAT_JSON=1
      shift
      ;;
    --bank)
      HINDSIGHT_BANK=$2
      shift 2
      ;;
    --url)
      HINDSIGHT_URL=$2
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
      if [ -z "$QUERY" ]; then
        QUERY=$1
      else
        QUERY="$QUERY $1"
      fi
      shift
      ;;
  esac
done

if [ -z "$QUERY" ]; then
  usage >&2
  exit 2
fi

payload=$(jq -n \
  --arg q "$QUERY" \
  --argjson max_tokens "$MAX_TOKENS" \
  '{
    query: $q,
    max_tokens: $max_tokens
  }')

url="$HINDSIGHT_URL/v1/default/banks/$HINDSIGHT_BANK/memories/recall"
resp=$(curl -s -S --connect-timeout 3 --max-time 60 \
  -X POST "$url" \
  -H "Content-Type: application/json" \
  -d "$payload" 2>&1) || rc=$?

if [ "${rc:-0}" -ne 0 ]; then
  printf 'error: recall request failed (exit %s): %s\n' "$rc" "$resp" >&2
  exit 1
fi

if [ "$FORMAT_JSON" -eq 1 ]; then
  printf '%s\n' "$resp" | jq .
  exit 0
fi

# Format output compactly: [<document_id>] (<type>) <text>
printf '%s\n' "$resp" | jq -r '
  if (.results | length) == 0 then
    "no memories found for query"
  else
    .results[] |
    "[" + (.document_id // "observation") + "] (" + .type + ") " + (.text | gsub("\n"; " "))
  end
'
