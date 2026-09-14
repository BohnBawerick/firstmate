#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$ROOT/.test-phase-tmp/cadence-manual
mkdir -p "$LAB/home"/{state,data,config} "$LAB/bin"
export FM_HOME=$LAB/home TMPDIR=$ROOT/.test-phase-tmp FM_PROCEVENT_CLAIM_ROOT=$LAB/claims
export FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_PAUSE_RESURFACE_SECS=10
SOCKET=$ROOT/.test-phase-tmp/c.sock
watch_pid=
cleanup() { [ -z "$watch_pid" ] || { kill "$watch_pid" 2>/dev/null || true; wait "$watch_pid" 2>/dev/null || true; }; /usr/bin/tmux -S "$SOCKET" kill-server >/dev/null 2>&1 || true; }
trap cleanup EXIT
cat > "$LAB/bin/tmux" <<SH
#!/usr/bin/env bash
exec /usr/bin/tmux -S "$SOCKET" "\$@"
SH
chmod +x "$LAB/bin/tmux"
export PATH="$LAB/bin:$PATH"
printf 'tmux\n' > "$FM_HOME/config/backend"
tmux -f /dev/null new-session -d -s lab-c -n fm-until -c "$LAB/home" 'sleep 180'
printf 'window=lab-c:fm-until\nkind=secondmate\nbackend=tmux\n' > "$FM_HOME/state/until.meta"
deadline=$(( $(date +%s) + 16 ))
printf 'paused: waiting for reset, until %s, then resuming\n' "$(date -u -d "@$deadline" +%Y-%m-%dT%H:%M:%SZ)" > "$FM_HOME/state/until.status"
printf 'Configured cadence=10 seconds; deadline=%s\n' "$deadline"
start_watch() { bin/fm-watch.sh > "$LAB/$1.out" 2>&1 & watch_pid=$!; }
wait_exit() { for _ in $(seq 1 300); do kill -0 "$watch_pid" 2>/dev/null || { wait "$watch_pid"; watch_pid=; cat "$LAB/$1.out"; return; }; sleep 0.1; done; return 1; }
ack() {
  bin/fm-wake-drain.sh > "$LAB/drain.out" 2> "$LAB/drain.err"
  cat "$LAB/drain.out" "$LAB/drain.err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$LAB/drain.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$LAB/drain.err")
  bin/fm-wake-drain.sh --ack-through "$seq" --recovery-generation "$generation"
}
start_watch initial
wait_exit initial
ack
start_watch first-reminder
wait_exit first-reminder
first=$(date +%s)
grep -q 'stale:' "$LAB/first-reminder.out"
printf 'First reminder observed=%s\n' "$first"
[ "$first" -lt "$deadline" ]
ack
start_watch second-reminder
while [ "$(date +%s)" -le "$deadline" ]; do sleep 0.2; done
kill -0 "$watch_pid"
printf 'Deadline crossed at %s without a second reminder.\n' "$(date +%s)"
wait_exit second-reminder
second=$(date +%s)
printf 'Second reminder observed=%s; interval=%s seconds\n' "$second" "$((second-first))"
[ "$((second-first))" -ge 10 ]
cat "$FM_HOME/state/.watch-triage.log"
