#!/usr/bin/env bash
# Live drive: real fm-watch.sh + real fm-crew-state.sh + real tmux (private socket).
set -u
ROOT=$1; LAB=/tmp/nmtest-watch; SOCK=nmtest-watch-$$
rm -rf "$LAB"; mkdir -p "$LAB/state" "$LAB/shim" "$LAB/agent"
REAL_TMUX=$(command -v tmux)
printf '#!/usr/bin/env bash\nexec %s -L %s "$@"\n' "$REAL_TMUX" "$SOCK" > "$LAB/shim/tmux"; chmod +x "$LAB/shim/tmux"
# A quiet "grok" agent: prints one line and then produces no output.
printf '#!/usr/bin/env bash\necho "waiting at the gate"\nwhile :; do read -r -t 3600 _ || :; done\n' > "$LAB/agent/grok"; chmod +x "$LAB/agent/grok"
trap '"$REAL_TMUX" -L "$SOCK" kill-server 2>/dev/null' EXIT
"$REAL_TMUX" -L "$SOCK" new-session -d -s wedgelab -n fm-wedge -x 160 -y 40 "$LAB/agent/grok"
sleep 1
echo "pane command: $("$REAL_TMUX" -L "$SOCK" display-message -p -t wedgelab:fm-wedge '#{pane_current_command}')"
past=$(date -u -d "@$(( $(date +%s) - 7200 ))" +%Y-%m-%dT%H:%M:%SZ)
printf 'window=wedgelab:fm-wedge\nkind=ship\nharness=grok\nbackend=tmux\n' > "$LAB/state/wedge.meta"
printf 'paused: waiting on the build queue until %s\n' "$past" > "$LAB/state/wedge.status"
echo "status: $(cat "$LAB/state/wedge.status")"
ack() {
  local err=$LAB/drain.err seq gen
  FM_STATE_OVERRIDE="$LAB/state" "$ROOT/bin/fm-wake-drain.sh" 2> "$err" | sed 's/^/  drain: /'
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && FM_STATE_OVERRIDE="$LAB/state" "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
for round in 1 2 3 4 5 6; do
  echo "=== watcher run $round"
  PATH="$LAB/shim:$PATH" FM_STATE_OVERRIDE="$LAB/state" FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_PAUSE_RESURFACE_SECS=999 FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 timeout 90 "$ROOT/bin/fm-watch.sh" > "$LAB/watch.out" 2>&1
  echo "  exit=$?"; sed 's/^/  watch: /' "$LAB/watch.out"
  if grep -qF 'declared clearing time has passed' "$LAB/watch.out" || grep -qF 'possible wedge' "$LAB/watch.out"; then break; fi
  ack
done
echo "=== verdict"
grep -F 'declared clearing time has passed' "$LAB/watch.out" >/dev/null && echo "expired-wait recheck surfaced: yes" || echo "expired-wait recheck surfaced: no"
grep -F 'possible wedge' "$LAB/watch.out" >/dev/null && echo "generic wedge escalation first: yes" || echo "generic wedge escalation first: no"
