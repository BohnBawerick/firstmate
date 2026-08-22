#!/usr/bin/env bash
# End-to-end reproduction of the 2026-08-22 away-mode escalation wedge.
#
# Runs the REAL bin/fm-supervise-daemon.sh process against a scripted `herdr`
# CLI that models a Claude supervisor pane sitting idle between turns:
#   * `pane read --source recent` returns the emitted-output stream. Its last
#     20 rows are partial repaints that carry the idle glyph and the closing
#     rule but not the opening rule - the clip the incident log recorded as
#     1555 composer=unknown defers.
#   * `pane read --source visible` returns the live viewport, which always
#     carries the whole composer.
#   * `pane send-text` appends to the composer buffer; `pane send-keys enter`
#     submits it (logged), flips native agent-state to working for 3s, then
#     back to idle - herdr's native submit confirmation.
#
# Usage: afk-wedge-e2e.sh <repo-root> <scenario>
#   scenario = idle-claude | dead-shell | human-typing
set -u
ROOT=$1
SCENARIO=$2
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-wedge.XXXXXX")
STATE="$WORK/state"; mkdir -p "$STATE"
PANE="$WORK/pane"; mkdir -p "$PANE"
: > "$PANE/buf"
: > "$PANE/submitted.log"
echo idle > "$PANE/agent"
echo 0 > "$PANE/working_until"
if [ "$SCENARIO" = wedge-then-return ]; then echo dead-shell > "$PANE/scenario"; else echo "$SCENARIO" > "$PANE/scenario"; fi

FB="$WORK/fakebin"; mkdir -p "$FB"
cat > "$FB/herdr" <<'SH'
#!/usr/bin/env bash
set -u
P="${FM_FAKE_PANE:?}"
log() { printf '%s\n' "$*" >> "$P/calls.log"; }
now() { date +%s; }
scenario=$(cat "$P/scenario")
buf=$(cat "$P/buf")

render_composer() {  # <source>
  local src=$1 line
  case "$scenario" in
    dead-shell)
      # The harness exited; the pane is a bare login shell prompt.
      printf 'paiva@box firstmate %% \n'
      return 0
      ;;
  esac
  line="❯ $buf"
  if [ "$src" = visible ]; then
    # Live viewport: transcript above, then the WHOLE composer pair.
    printf '● Landed the docs pass; two workers are parked on gate decisions.\n'
    printf '\n'
    printf '────────────────────────────────────────────────\n'
    printf '%s\n' "$line"
    printf '────────────────────────────────────────────────\n'
    printf '  firstmate on  main · Opus 5\n'
    printf '  ⏵⏵ bypass permissions on\n'
  else
    # Emitted-output scrollback. The most recent repaint started BELOW the
    # opening rule, so the 20-row tail the adapter used to take carries the
    # glyph and the closing rule but not the opening one - the exact clipped
    # fragment the 2026-08-22 daemon log classified as composer=unknown.
    printf '%s\n' "$line"
    printf '────────────────────────────────────────────────\n'
    printf '  firstmate on  main · Opus 5\n'
    printf '  ⏵⏵ bypass permissions on\n'
  fi
}

cmd=${1:-}; sub=${2:-}
case "$cmd $sub" in
  "status --json")
    printf '{"client":{"version":"0.8.0","protocol":14},"server":{"running":true}}\n' ;;
  "pane get")
    printf '{"result":{"pane":{"pane_id":"%s"}}}\n' "${3:-}" ;;
  "pane read")
    src=recent
    prev=""
    for a in "$@"; do
      if [ "$prev" = --source ]; then src=$a; fi
      prev=$a
    done
    log "pane read --source $src"
    render_composer "$src" ;;
  "agent get")
    st=$(cat "$P/agent")
    if [ "$st" = working ] && [ "$(now)" -ge "$(cat "$P/working_until")" ]; then
      st=idle; echo idle > "$P/agent"
    fi
    case "$scenario" in
      dead-shell) printf '{"result":{"agent":{"agent":"claude","agent_status":"done"}}}\n' ;;
      *) printf '{"result":{"agent":{"agent":"claude","agent_status":"%s"}}}\n' "$st" ;;
    esac ;;
  "pane send-text")
    log "pane send-text"
    printf '%s' "${4:-}" >> "$P/buf" ;;
  "pane send-keys")
    log "pane send-keys ${4:-}"
    if [ "$(cat "$P/buf")" != "" ]; then
      printf '%s\n' "$(cat "$P/buf")" >> "$P/submitted.log"
      : > "$P/buf"
      echo working > "$P/agent"
      echo $(( $(now) + 3 )) > "$P/working_until"
    fi ;;
  *) : ;;
esac
exit 0
SH
chmod +x "$FB/herdr"
export FM_FAKE_PANE="$PANE"

# --- the away run ------------------------------------------------------------
# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervise-daemon.sh"
afk_enter "$STATE"                      # captain sets state/.afk at 02:23
if [ "$SCENARIO" = human-typing ]; then
  printf 'land the parked workers' > "$PANE/buf"   # captain left a half-typed line
fi
escalate_add "$STATE" "fm-c1 needs a gate decision: approve the schema drop?"
escalate_add "$STATE" "fm-c2 done: PR https://github.com/BohnBawerick/firstmate/pull/15"

PATH="$FB:$PATH" \
FM_STATE_OVERRIDE="$STATE" \
FM_SUPERVISOR_TARGET="default:w1:p2" \
FM_SUPERVISOR_BACKEND=herdr \
FM_ESCALATE_BATCH_SECS=2 \
FM_HOUSEKEEPING_TICK=1 \
FM_POLL=1 \
FM_HEARTBEAT=999999 \
FM_CHECK_INTERVAL=999999 \
FM_STALE_ESCALATE_SECS=999999 \
FM_MAX_DEFER_SECS=8 \
FM_INJECT_CONFIRM_SLEEP=0.3 \
FM_BACKEND_HERDR_SUBMIT_MIN_SLEEP=0 \
FM_WEDGE_ALARM_EXEC=discard \
nohup "$ROOT/bin/fm-supervise-daemon.sh" >"$WORK/daemon.out" 2>"$WORK/daemon.err" &
DPID=$!

if [ "$SCENARIO" = wedge-then-return ]; then
  # Overnight: the harness had exited, so every tick deferred and the
  # max-defer alarm fired. At 09:10 the captain restarts Claude in the same
  # pane and leaves away mode - the return catch-up must still deliver.
  sleep 12
  echo "  [captain returns 09:10: harness restarted, away mode off]"
  echo idle-claude > "$PANE/scenario"
  echo "  --- bin/fm-afk-return.sh (the return catch-up the captain sees) ---"
  PATH="$FB:$PATH" FM_STATE_OVERRIDE="$STATE" FM_SUPERVISOR_TARGET="default:w1:p2" \
    FM_SUPERVISOR_BACKEND=herdr \
    "$ROOT/bin/fm-afk-return.sh" 2>&1 | sed -e 's/^/  /' | head -25
  sleep 2
else
  i=0
  while [ $i -lt 30 ]; do
    [ -s "$PANE/submitted.log" ] && break
    sleep 1; i=$((i+1))
  done
  sleep 2
fi
kill "$DPID" 2>/dev/null; wait "$DPID" 2>/dev/null
sleep 1

echo "=== scenario: $SCENARIO ==="
echo "--- daemon log (state/.supervise-daemon.log) ---"
grep -E "daemon starting|inject|escalat|flush|wedge|max-defer" "$STATE/.supervise-daemon.log" 2>/dev/null \
  | sed -e 's/^/  /' | head -30
echo "--- what actually reached the supervisor pane ---"
if [ -s "$PANE/submitted.log" ]; then
  sed -e 's/^/  SUBMITTED: /' "$PANE/submitted.log"
else
  echo "  (nothing submitted)"
fi
echo "--- undelivered escalation buffer ---"
if [ -s "$STATE/.subsuper-escalations" ]; then
  sed -e 's/^/  STILL BUFFERED: /' "$STATE/.subsuper-escalations"
else
  echo "  (empty - everything delivered)"
fi
echo "--- wedge alarm marker ---"
if [ -e "$STATE/.subsuper-inject-wedged" ]; then echo "  PRESENT"; else echo "  absent"; fi
echo "--- composer capture source used ---"
sort "$PANE/calls.log" 2>/dev/null | uniq -c | grep "pane read" | sed -e 's/^/  /'
rm -rf "$WORK"
