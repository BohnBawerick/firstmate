#!/usr/bin/env bash
# fm-dot-secondmate.sh - register and address a ChatGPT dot without a terminal.
#
# Usage (FM_HOME must name the parent Firstmate home):
#   fm-dot-secondmate.sh register <id> <db> <home> <queue> <mailbox-health-url> <tunnel-health-url> <scope> <charter-file>
#   fm-dot-secondmate.sh send <id> <correlation-id> <idempotency-key>  # content on stdin
#   fm-dot-secondmate.sh health <id>
#   fm-dot-secondmate.sh snapshot <id> [--child <child-id> ...]
#   fm-dot-secondmate.sh history <id> [--cursor <revision>] [--limit <1..50>]
#   fm-dot-secondmate.sh publish-child <id> <home> <db> <child> <state> <revision> <note> <report>
#   fm-dot-secondmate.sh validate <id>
#   fm-dot-secondmate.sh publish <id> <home> <db> <status-line>       # mailbox outbox only
#
# Registration creates a private, non-executable secondmate home containing its
# charter and ordinary parent-channel binding. It never launches a process,
# clones a project, creates a tunnel, or changes a credential. Use fm-send for
# work routing; send is its durable mailbox leg. Registration and send require
# the parent's session lock. Publication uses the existing parent status channel
# and its idempotent append contract, not a terminal or a second wake mechanism.
set -euo pipefail
case "${1:-}" in
  --help|-h|help)
    printf '%s\n' \
      'Usage (FM_HOME is the parent home):' \
      '  fm-dot-secondmate.sh register <id> <db> <home> <queue> <mailbox-health-url> <tunnel-health-url> <scope> <charter-file>' \
      '  fm-dot-secondmate.sh health <id>' \
      '  fm-dot-secondmate.sh validate <id>' \
      '  fm-dot-secondmate.sh snapshot <id> [--child <child-id> ...]' \
      '  fm-dot-secondmate.sh history <id> [--cursor <revision>] [--limit <1..50>]' \
      'Route work with fm-send.sh. send and publish are internal transport commands.'
    exit 0
    ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -n "${FM_HOME:-}" ] || { echo 'error: FM_HOME is required' >&2; exit 1; }
PARENT_HOME=$(cd "$FM_HOME" && pwd -P)
export FM_HOME=$PARENT_HOME
STATE="$PARENT_HOME/state"
DATA="$PARENT_HOME/data"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

fail() { printf 'error: %s\n' "$*" >&2; exit 1; }
[ "$#" -ge 2 ] || fail 'see the script header for usage'
COMMAND=$1 ID=$2
shift 2
case "$ID" in ''|.*|*[!A-Za-z0-9._-]*) fail 'invalid secondmate id' ;; esac
META="$STATE/$ID.meta"
DOT_HOME='' DOT_DB='' META_LOCK='' REG_LOCK=''
cleanup() {
  [ -z "$REG_LOCK" ] || fm_lock_release "$REG_LOCK"
  [ -z "$META_LOCK" ] || fm_lock_release "$META_LOCK"
}
trap cleanup EXIT

lock_meta() {
  local path
  path=$(fm_meta_lock_path "$META")
  fm_task_inbox_lock_acquire "$path" || fail 'secondmate metadata is busy'
  META_LOCK=$path
}
validate_route() {
  [ -f "$META" ] && [ ! -L "$META" ] || fail 'missing or unsafe dot metadata'
  [ "$(fm_meta_get "$META" kind)" = secondmate ] &&
    [ "$(fm_meta_get "$META" transport)" = dot-mcp ] || fail 'target is not a dot secondmate'
  DOT_HOME=$(fm_meta_get "$META" home)
  DOT_DB=$(fm_meta_get "$META" dot_mailbox_db)
  case "$DOT_HOME:$DOT_DB" in /*:/*) ;; *) fail 'dot home and database must be absolute' ;; esac
  secondmate_registry_line_for_id "$DATA/secondmates.md" "$ID" || fail 'dot registry entry is missing or ambiguous'
  [ "$SECONDMATE_REGISTRY_REMOTE" = 0 ] && [ "$SECONDMATE_REGISTRY_HOME" = "$DOT_HOME" ] || fail 'dot registry and metadata disagree'
  [ -f "$DOT_HOME/.fm-secondmate-transport" ] && [ ! -L "$DOT_HOME/.fm-secondmate-transport" ] &&
    [ "$(<"$DOT_HOME/.fm-secondmate-transport")" = dot-mcp ] || fail 'dot transport marker is missing or unsafe'
  [ "$(fm_parent_channel_home_id "$DOT_HOME")" = "$ID" ] || fail 'dot identity does not match'
  [ "$(fm_parent_channel_destination "$DOT_HOME" "$DOT_HOME/state")" = "$STATE/$ID.status" ] || fail 'dot parent channel does not match'
}

case "$COMMAND" in
  register)
    [ "$#" -eq 7 ] || fail 'register expects db, home, queue, two health URLs, scope and charter file'
    fm_require_session_lock "$STATE" 'register a dot secondmate' || exit 1
    lock_meta
    registry_lock=$(secondmate_registry_lock_path "$STATE")
    fm_task_inbox_lock_acquire "$registry_lock" || fail 'secondmate registry is busy'
    REG_LOCK=$registry_lock
    if secondmate_registry_line_for_id "$DATA/secondmates.md" "$ID" 2>/dev/null; then
      [ "$SECONDMATE_REGISTRY_SCOPE" = "$6" ] || fail 'existing scope differs; registration does not overwrite it'
    fi
    python3 "$SCRIPT_DIR/fm-dot-mailbox.py" --db "$1" mate-register "$ID" \
      --home "$2" --queue "$3" --mailbox-url "$4" --tunnel-url "$5" --scope "$6" --charter "$7"
    validate_route
    ;;
  validate)
    [ "$#" -eq 0 ] || fail 'validate takes only an id'
    validate_route
    ;;
  send)
    [ "$#" -eq 2 ] || fail 'send expects correlation and idempotency key; message on stdin'
    fm_require_session_lock "$STATE" 'route work to a dot secondmate' || exit 1
    lock_meta
    validate_route
    python3 "$SCRIPT_DIR/fm-dot-mailbox.py" --db "$DOT_DB" mate-send "$ID" --correlation-id "$1" --idempotency-key "$2" -
    ;;
  health)
    [ "$#" -eq 0 ] || fail 'health takes only an id'
    validate_route
    python3 "$SCRIPT_DIR/fm-dot-mailbox.py" --db "$DOT_DB" mate-health "$ID"
    ;;
  snapshot|history)
    validate_route
    python3 "$SCRIPT_DIR/fm-dot-mailbox.py" --db "$DOT_DB" "mate-$COMMAND" "$ID" "$@"
    ;;
  publish-child)
    [ "$#" -eq 7 ] || fail 'publish-child expects home, database, child, state, revision, note and report'
    lock_meta
    validate_route
    [ "$DOT_HOME" = "$1" ] && [ "$DOT_DB" = "$2" ] || fail 'mailbox outbox route changed'
    child=$3 outcome=$4 revision=$5 note=$6 report=$7
    [[ "$child" =~ ^cloud-[a-f0-9]{24}$ ]] || fail 'invalid reported child id'
    [[ "$revision" =~ ^[0-9]+$ ]] || fail 'invalid activity revision'
    case "$outcome" in done|failed|blocked|needs-decision) ;; *) fail 'invalid child outcome' ;; esac
    case "$note$report" in *$'\n'*|*$'\r'*) fail 'multiline child outcome' ;; esac
    # shellcheck source=bin/fm-child-outcome-lib.sh
    . "$SCRIPT_DIR/fm-child-outcome-lib.sh"
    OUTCOME_DIR="$DOT_HOME/state/terminal-outcomes"
    reconcile_now() { date +%s; }
    fingerprint="$child-$revision"
    key="child-outcome-$child-$outcome-$revision"
    ensure_record "$fingerprint" "$child" "$child" "$outcome" "$key" dot-reported upstream ''
    if [ -n "$RECORD_PENDING" ]; then
      line=$(fm_child_outcome_line "$child" "$outcome" "$key" "$note" '' '' '' "$report")
      fm_child_outcome_publish "$DOT_HOME" "$DOT_HOME/state" "$RECORD_PENDING" "$line"
    fi
    ;;
  publish)
    [ "$#" -eq 3 ] || fail 'publish expects home, database and status line'
    lock_meta
    validate_route
    [ "$DOT_HOME" = "$1" ] && [ "$DOT_DB" = "$2" ] || fail 'mailbox outbox route changed'
    fm_parent_channel_report "$DOT_HOME" "$DOT_HOME/state" "$3"
    ;;
  *) fail "unknown dot secondmate command: $COMMAND" ;;
esac
case "$COMMAND" in
  publish|publish-child)
    if [ -e "$PARENT_HOME/config/fleet-ledger" ]; then
      "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$PARENT_HOME/config" "$STATE/$ID.status" >/dev/null 2>&1 || true
    fi
    ;;
esac
