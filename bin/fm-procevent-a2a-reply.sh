#!/usr/bin/env bash
# A2A reply adapter for the generic process-event runner.
#
# Usage:
#   fm-procevent-a2a-reply.sh run <secondmate-id> <request-id>
#   fm-procevent-a2a-reply.sh autohandle <source-id> <sequence> <result-file>
#   fm-procevent-a2a-reply.sh classify <result-file>
#   fm-procevent-a2a-reply.sh terminal <result-file>
#   fm-procevent-a2a-reply.sh self-announcing
#   fm-procevent-a2a-reply.sh source-id <secondmate-id> <request-id>
#
# One source carries one routed message to an A2A second mate
# (bin/fm-a2a-secondmate.sh send registers it). `run` is the blocking child the
# runner executes: bin/fm-a2a-client.py deliver sends the message at most once,
# waits for the agent's reply and prints one fm-a2a-reply.v1 JSON result. Every
# result is terminal, so the runner retires the source after capture.
#
# `autohandle` applies the result without a firstmate turn: it stores the full
# reply under the parent's private data/<id>/a2a-replies/<request-id>.md and
# appends one correlated line to the parent's state/<id>.status through the
# parent channel, then acknowledges the capture. The line is the wake, which is
# why the adapter declares `self-announcing`; only a capture autohandle could
# not apply reaches firstmate as a process-event wake, and rerunning
# `autohandle` on it is idempotent.
#
# Outcome mapping (classify prints the outcome):
#   completed       -> done [corr=...]: the reply excerpt
#   input-required  -> needs-decision [corr=...] [key=a2a-<request-id>]
#   failed, rejected, canceled -> failed [corr=...]
#   unknown, undelivered       -> blocked [corr=...] [key=a2a-<request-id>]
# An undelivered request is resent with the same correlation through fm-send;
# an unknown outcome is never resent automatically (see fm-a2a-client.py).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
export FM_HOME

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; }

result_field() { jq -r --arg k "$2" '.[$k] // empty' "$1" 2>/dev/null; }

cmd_source_id() {
  local id=${1-} request=${2-} source
  case "$id" in ''|.*|*[!A-Za-z0-9._-]*) die 'invalid secondmate id' ;; esac
  printf '%s' "$request" | grep -Eq '^[a-f0-9]{16}-[a-f0-9]{8}$' || die 'invalid request id'
  source="a2a-$id-$request"
  [ "${#source}" -le 64 ] || source="a2a-$(printf '%s' "$id" | cksum | cut -d' ' -f1)-$request"
  printf '%s\n' "$source"
}

cmd_classify() {
  local outcome
  outcome=$(result_field "$1" outcome)
  case "$outcome" in
    completed|input-required|failed|rejected|canceled|unknown|undelivered) printf '%s\n' "$outcome" ;;
    *) printf 'unparsed\n' ;;
  esac
}

one_line() { printf '%s' "$1" | tr '\r\n\t' '   ' | sed 's/  */ /g; s/^ //; s/ $//' | cut -c "1-${2:-300}"; }

cmd_autohandle() {
  local source=${1-} seq=${2-} result=${3-} mate request corr outcome text subject rel report line verb key
  [ -f "$result" ] && [ ! -L "$result" ] || die 'missing result'
  [ "$(result_field "$result" schema)" = fm-a2a-reply.v1 ] || die 'not an a2a reply result'
  mate=$(result_field "$result" mate)
  request=$(result_field "$result" request)
  corr=$(result_field "$result" corr)
  [ "$(cmd_source_id "$mate" "$request")" = "$source" ] || die 'result does not belong to this source'
  printf '%s' "$corr" | grep -Eq '^[a-f0-9]{16}$' || die 'invalid correlation'
  if fm_procevent_is_handled "$STATE" "$source" "$seq"; then
    return 0
  fi
  outcome=$(cmd_classify "$result")
  text=$(result_field "$result" text)
  subject=$(result_field "$result" subject)
  rel="data/$mate/a2a-replies/$request.md"
  report="$FM_HOME/$rel"
  (umask 077; mkdir -p "${report%/*}") || die 'cannot create the reply directory'
  {
    printf '# A2A reply from %s\n\n' "$mate"
    printf -- '- Request: %s\n- Subject: %s\n- Outcome: %s\n' "$request" "$subject" "$outcome"
    printf -- '- Conversation: %s\n- Task: %s\n\n' "$(result_field "$result" context_id)" "$(result_field "$result" task_id)"
    printf '%s\n' "$text"
  } > "$report.tmp" || die 'cannot store the reply'
  mv -f "$report.tmp" "$report" || die 'cannot store the reply'
  key=''
  case "$outcome" in
    completed) verb='done' ;;
    input-required) verb=needs-decision key=" [key=a2a-$request]" ;;
    failed|rejected|canceled) verb=failed ;;
    *) verb=blocked key=" [key=a2a-$request]" ;;
  esac
  line="$verb [corr=$corr]$key: $mate $outcome: $(one_line "${text:-no reply text}") (report=$rel)"
  "$SCRIPT_DIR/fm-a2a-secondmate.sh" publish "$mate" "$(fm_a2a_mate_home "$mate")" "$line" >/dev/null ||
    die 'parent channel refused the reply'
  fm_procevent_mark_handled "$STATE" "$source" "$seq" || [ "$?" -eq 1 ] || die 'cannot acknowledge the capture'
}

fm_a2a_mate_home() { sed -n 's/^home=//p' "$STATE/$1.meta" | tail -1; }

case "${1:-}" in
  run)
    [ "$#" -eq 3 ] || die 'run expects a secondmate id and a request id'
    exec python3 "$SCRIPT_DIR/fm-a2a-client.py" deliver "$2" "$3"
    ;;
  autohandle) shift; [ "$#" -eq 3 ] || die 'autohandle expects source, sequence and result'; cmd_autohandle "$@" ;;
  classify) [ "$#" -eq 2 ] || die 'classify expects a result file'; cmd_classify "$2" ;;
  terminal) exit 0 ;;
  self-announcing) exit 0 ;;
  source-id) shift; cmd_source_id "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
