#!/usr/bin/env bash
# fm-a2a-secondmate.sh - register and address an A2A agent as a second mate.
#
# Usage (FM_HOME must name the parent Firstmate home):
#   fm-a2a-secondmate.sh register <id> <home> <a2a-url> <credential-file> <token-var> <scope> <charter-file> [<turn-cap>]
#   fm-a2a-secondmate.sh send <id> <correlation-id> <idempotency-key>   # content on stdin
#   fm-a2a-secondmate.sh health <id>
#   fm-a2a-secondmate.sh snapshot <id>
#   fm-a2a-secondmate.sh validate <id>
#   fm-a2a-secondmate.sh publish <id> <home> <status-line>               # reply adapter only
#
# The agent is reached over the A2A protocol (JSON-RPC SendMessage), for
# example a Hermes profile with its A2A platform enabled. Registration creates a
# private, non-executable secondmate home with its charter, the endpoint
# configuration and the ordinary parent-channel binding. It stores the path of
# an owner-only credential file and the variable name inside it, never the
# credential. It never launches a process, clones a project, or changes the
# remote agent. <turn-cap> must not exceed the agent's per-conversation turn cap
# (Hermes A2A_MAX_PINGPONG_TURNS, default 5).
#
# Route work with fm-send; send is its delivery leg. send records the request in
# the mate home, then registers one bin/fm-procevent-a2a-reply.sh source that
# performs the blocking A2A call outside the caller's turn and publishes the
# reply through the parent status channel. bin/fm-a2a-client.py owns the wire
# protocol, the conversation-key rotation and the at-most-once delivery rule.
# Registration and send require the parent's session lock.
set -euo pipefail
case "${1:-}" in
  --help|-h|help)
    printf '%s\n' \
      'Usage (FM_HOME is the parent home):' \
      '  fm-a2a-secondmate.sh register <id> <home> <a2a-url> <credential-file> <token-var> <scope> <charter-file> [<turn-cap>]' \
      '  fm-a2a-secondmate.sh health <id>' \
      '  fm-a2a-secondmate.sh snapshot <id>' \
      '  fm-a2a-secondmate.sh validate <id>' \
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
CLIENT="$SCRIPT_DIR/fm-a2a-client.py"
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
MATE_HOME='' META_LOCK=''
cleanup() { [ -z "$META_LOCK" ] || fm_lock_release "$META_LOCK"; }
trap cleanup EXIT

lock_meta() {
  local path
  path=$(fm_meta_lock_path "$META")
  fm_task_inbox_lock_acquire "$path" || fail 'secondmate metadata is busy'
  META_LOCK=$path
}
validate_route() {
  [ -f "$META" ] && [ ! -L "$META" ] || fail 'missing or unsafe a2a metadata'
  [ "$(fm_meta_get "$META" kind)" = secondmate ] &&
    [ "$(fm_meta_get "$META" transport)" = a2a ] || fail 'target is not an a2a secondmate'
  MATE_HOME=$(fm_meta_get "$META" home)
  case "$MATE_HOME" in /*) ;; *) fail 'a2a home must be absolute' ;; esac
  secondmate_registry_line_for_id "$DATA/secondmates.md" "$ID" || fail 'a2a registry entry is missing or ambiguous'
  [ "$SECONDMATE_REGISTRY_REMOTE" = 0 ] && [ "$SECONDMATE_REGISTRY_HOME" = "$MATE_HOME" ] || fail 'a2a registry and metadata disagree'
  [ "$(secondmate_home_transport "$MATE_HOME")" = a2a ] || fail 'a2a transport marker is missing or unsafe'
  [ "$(fm_parent_channel_home_id "$MATE_HOME")" = "$ID" ] || fail 'a2a identity does not match'
  [ "$(fm_parent_channel_destination "$MATE_HOME" "$MATE_HOME/state")" = "$STATE/$ID.status" ] || fail 'a2a parent channel does not match'
}

case "$COMMAND" in
  register)
    [ "$#" -eq 6 ] || [ "$#" -eq 7 ] || fail 'register expects home, url, credential file, token variable, scope, charter file and an optional turn cap'
    fm_require_session_lock "$STATE" 'register an a2a secondmate' || exit 1
    lock_meta
    registry_lock=$(secondmate_registry_lock_path "$STATE")
    fm_task_inbox_lock_acquire "$registry_lock" || fail 'secondmate registry is busy'
    if secondmate_registry_line_for_id "$DATA/secondmates.md" "$ID" 2>/dev/null &&
      [ "$SECONDMATE_REGISTRY_SCOPE" != "$5" ]; then
      fm_lock_release "$registry_lock"
      fail 'existing scope differs; registration does not overwrite it'
    fi
    rc=0
    python3 "$CLIENT" register "$ID" --home "$1" --url "$2" --credentials "$3" --token-var "$4" \
      --scope "$5" --charter "$6" --turn-cap "${7:-5}" || rc=$?
    fm_lock_release "$registry_lock"
    [ "$rc" -eq 0 ] || exit "$rc"
    validate_route
    ;;
  validate)
    [ "$#" -eq 0 ] || fail 'validate takes only an id'
    validate_route
    ;;
  send)
    [ "$#" -eq 2 ] || fail 'send expects correlation and idempotency key; message on stdin'
    fm_require_session_lock "$STATE" 'route work to an a2a secondmate' || exit 1
    lock_meta
    validate_route
    prepared=$(python3 "$CLIENT" prepare "$ID" --corr "$1")
    request=$(printf '%s' "$prepared" | jq -r '.request')
    # The reply runner publishes under this same lock; release it first.
    fm_lock_release "$META_LOCK"
    META_LOCK=''
    case "$(printf '%s' "$prepared" | jq -r '.state')" in
      queued)
        source_id=$("$SCRIPT_DIR/fm-procevent-a2a-reply.sh" source-id "$ID" "$request")
        "$SCRIPT_DIR/fm-procevent.sh" register a2a-reply "$source_id" -- \
          "$SCRIPT_DIR/fm-procevent-a2a-reply.sh" run "$ID" "$request" >/dev/null
        # Start now rather than on the watcher's next cycle; reconcile retries
        # a start that does not confirm, and delivery stays at most once.
        "$SCRIPT_DIR/fm-procevent.sh" ensure-listening "$source_id" >/dev/null 2>&1 || true
        ;;
    esac
    printf '%s\n' "$prepared"
    ;;
  health)
    [ "$#" -eq 0 ] || fail 'health takes only an id'
    validate_route
    python3 "$CLIENT" health "$ID"
    ;;
  snapshot)
    [ "$#" -eq 0 ] || fail 'snapshot takes only an id'
    validate_route
    python3 "$CLIENT" snapshot "$ID"
    ;;
  publish)
    [ "$#" -eq 2 ] || fail 'publish expects home and status line'
    lock_meta
    validate_route
    [ "$MATE_HOME" = "$1" ] || fail 'a2a route changed'
    case "$2" in *$'\n'*|*$'\r'*) fail 'multiline status line' ;; esac
    fm_parent_channel_report "$MATE_HOME" "$MATE_HOME/state" "$2"
    if [ -e "$PARENT_HOME/config/fleet-ledger" ]; then
      "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$PARENT_HOME/config" "$STATE/$ID.status" >/dev/null 2>&1 || true
    fi
    ;;
  *) fail "unknown a2a secondmate command: $COMMAND" ;;
esac
