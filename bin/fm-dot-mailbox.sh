#!/usr/bin/env bash
# fm-dot-mailbox.sh - local operator interface for Firstmate dot MCP mailbox.
#
# Usage:
#   bin/fm-dot-mailbox.sh submit [--queue <q>] [--correlation-id <id>] [--idempotency-key <key>] <content | ->
#   bin/fm-dot-mailbox.sh get <message_id>
#   bin/fm-dot-mailbox.sh list [--queue <q>] [--status <pending|replied|all>] [--cursor <c>] [--limit <n>]
#   bin/fm-dot-mailbox.sh reply <message_id> <reply_text | -> [--correlation-id <id>]
#   bin/fm-dot-mailbox.sh status
#   bin/fm-dot-mailbox.sh serve [--host <host>] [--port <port>] [--allow-local-callbacks]
#   bin/fm-dot-mailbox.sh --help
#
# Environment:
#   FM_DOT_MAILBOX_DB              Explicit SQLite database path.
#   FM_HOME                        Owning home when no database path is supplied.
#   FM_DOT_MCP_ALLOW_LOCAL_CALLBACK Allow loopback callback URLs (testing).
#   FM_DOT_MCP_PORT                Default HTTP listen port (default: 8765).
#   FM_DOT_MCP_HOST                Default HTTP host (default: 127.0.0.1).
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PYTHON_ENGINE="$ROOT/bin/fm-dot-mailbox.py"

usage() {
  cat <<'EOF'
Usage:
  fm-dot-mailbox.sh submit [--queue <q>] [--correlation-id <id>] [--idempotency-key <key>] <content | ->
  fm-dot-mailbox.sh get <message_id>
  fm-dot-mailbox.sh list [--queue <q>] [--status <pending|replied|all>] [--cursor <c>] [--limit <n>]
  fm-dot-mailbox.sh reply <message_id> <reply_text | -> [--correlation-id <id>]
  fm-dot-mailbox.sh status
  fm-dot-mailbox.sh serve [--host <host>] [--port <port>] [--allow-local-callbacks]
  fm-dot-mailbox.sh --help

Commands:
  submit   Submit a message or work assignment to the mailbox queue.
  get      Retrieve message details, status, and reply by message ID.
  list     List messages with optional queue/status filters and pagination cursor.
  reply    Record an answer or completion report for a message.
  status   Show summary counts for messages and active subscriptions.
  serve    Start the MCP HTTP server.
EOF
}

DB_ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --db)
      if [ $# -lt 2 ]; then
        echo "fm-dot-mailbox.sh: --db requires an argument" >&2
        exit 1
      fi
      DB_ARGS=(--db "$2")
      shift 2
      ;;
    --db=*)
      DB_ARGS=(--db "${1#*=}")
      shift
      ;;
    --help|-h|help)
      usage
      exit 0
      ;;
    submit|get|list|reply|status|serve)
      exec python3 "$PYTHON_ENGINE" "${DB_ARGS[@]}" "$@"
      ;;
    *)
      echo "fm-dot-mailbox.sh: unknown command '$1'" >&2
      usage >&2
      exit 1
      ;;
  esac
done

usage >&2
exit 1
