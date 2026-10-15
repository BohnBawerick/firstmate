#!/usr/bin/env bash
set -euo pipefail
EVIDENCE=/home/bohn/.no-mistakes/evidence/01M50CWGPF8YPNBTQRHJHZRNM6/round2
source <(sed 's@\. "$(dirname "${BASH_SOURCE\[0\]}")/fixtures.sh"@. "$PWD/tests/fixtures.sh"@; /^for harness in claude opencode pi pi-signed omp grok codex; do$/,$d' tests/fm-secondmate-busy-contract-live-e2e.test.sh)
ORIGINAL_ROOT=$ROOT
mkdir -p "$ORIGINAL_ROOT/.test-phase/product"
cp -a "$ORIGINAL_ROOT/bin" "$ORIGINAL_ROOT/.pi" "$ORIGINAL_ROOT/AGENTS.md" "$ORIGINAL_ROOT/.gitignore" "$ORIGINAL_ROOT/.test-phase/product/"
ROOT="$ORIGINAL_ROOT/.test-phase/product"
REAL_PI=$(command -v pi)
CASE_DIR="$LAB/pi"
ID=sm-pi
install_sleeper "$CASE_DIR/sleeper" pi "$REAL_PI"
install_tmux_shim "$CASE_DIR/shim"
"$ROOT/bin/fm-lab-home.sh" create "$CASE_DIR/primary" >/dev/null
"$ROOT/bin/fm-lab-home.sh" create "$CASE_DIR/sm" >/dev/null
export TMUX_TMPDIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$CASE_DIR/primary")
"$REAL_TMUX" -L "$SOCKET" new-session -d -s firstmate -x 160 -y 45 -c "$ROOT"
"$REAL_TMUX" -L "$SOCKET" set-option -g remain-on-exit on
spawn_mate "$CASE_DIR" "$ID" pi "$CASE_DIR/sleeper" "$CASE_DIR/shim" > "$EVIDENCE/pi-spawn-setup.log" 2>&1
STATE="$CASE_DIR/primary/state"
cp "$STATE/$ID.pi-ext.ts" "$EVIDENCE/pi-generated-extension.ts"
"$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "firstmate:fm-$ID" > "$EVIDENCE/pi-sleeper-pane.txt"
"$REAL_TMUX" -L "$SOCKET" kill-window -t "firstmate:fm-$ID"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t firstmate: -n "fm-$ID" -c "$CASE_DIR/sm" -- \
  env -u FM_GATE_REFUSE_BYPASS -u FM_TEST_SEAM FM_HOME="$CASE_DIR/sm" \
  "$REAL_PI" --provider openai-codex --model gpt-6-luna --no-session --no-extensions --no-context-files \
  --no-skills --no-mcp --no-prompt-templates --no-themes \
  -e "$STATE/$ID.pi-ext.ts" -e "$ROOT/.pi/extensions/fm-calm.ts"
TARGET="firstmate:fm-$ID"
for i in {1..60}; do
  screen=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET")
  case "$screen" in *'Trust project folder?'*) "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape ;; esac
  case "$screen" in *'gpt-6-luna'*) break ;; esac
  sleep 0.5
done
"$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" > "$EVIDENCE/pi-idle-before.txt"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l 'Reply with exactly PI_SEMANTIC_OK and nothing else.'
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
busy=0
for i in {1..240}; do
  record=$(cat "$STATE/$ID.busy-state")
  case "$record" in *'state=busy'*'source=pi-ext'*) busy=1; printf '%s\n' "$record" > "$EVIDENCE/pi-busy-record.txt"; break ;; esac
  sleep 0.05
done
[ "$busy" = 1 ] || { cat "$EVIDENCE/pi-idle-before.txt"; echo 'real Pi never emitted busy'; exit 1; }
PATH="$CASE_DIR/shim:$PATH" FM_HOME="$CASE_DIR/primary" bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-busy-lib.sh"; fm_busy_classify_meta "$2/$3.meta" "$3" "$2"' _ "$ROOT" "$STATE" "$ID" | tee "$EVIDENCE/pi-busy-verdict.txt"
idle=0
for i in {1..240}; do
  record=$(cat "$STATE/$ID.busy-state")
  case "$record" in *'state=idle'*'source=pi-ext'*) idle=1; printf '%s\n' "$record" > "$EVIDENCE/pi-idle-record.txt"; break ;; esac
  sleep 0.25
done
"$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" > "$EVIDENCE/pi-idle-after.txt"
[ "$idle" = 1 ] || { cat "$EVIDENCE/pi-idle-after.txt"; echo 'real Pi never emitted idle'; exit 1; }
verdict=$(PATH="$CASE_DIR/shim:$PATH" FM_HOME="$CASE_DIR/primary" bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-busy-lib.sh"; fm_busy_classify_meta "$2/$3.meta" "$3" "$2"' _ "$ROOT" "$STATE" "$ID")
printf 'actual Pi semantic idle verdict: %s\n' "$verdict"
case "$verdict" in 'idle pi-ext'*) ;; *) exit 1 ;; esac
cat "$EVIDENCE/pi-idle-after.txt"
echo 'LIVE PI SEMANTIC SCENARIO PASSED'

# Drive the watcher against the genuine idle record emitted by this live Pi.

printf 'paused: waiting on the disposable release host\n' > "$STATE/$ID.status"
seen=$(FM_HOME="$CASE_DIR/primary" bash -c '. "$1/bin/fm-classify-lib.sh"; printf "v2\t%s\t%s@%s" "$(status_observed_signature "$2")" "$(wc -c < "$2" | tr -d " ")" "$(_fm_open_decisions_file_ident "$2")"' _ "$ROOT" "$STATE/$ID.status")
printf '%s' "$seen" > "$STATE/.seen-${ID}_status"
PATH="$CASE_DIR/shim:$PATH" FM_HOME="$CASE_DIR/primary" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$STATE" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_PAUSE_RESURFACE_SECS=30 FM_STALE_ESCALATE_SECS=2 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 "$ROOT/bin/fm-watch.sh" > "$EVIDENCE/pi-paused-watch.txt" 2>&1 &
WATCH_PID=$!
key=firstmate_fm-sm-pi
for i in {1..120}; do
  [ ! -e "$STATE/.paused-$key" ] || break
  kill -0 "$WATCH_PID" 2>/dev/null || { cat "$EVIDENCE/pi-paused-watch.txt"; exit 1; }
  sleep 0.1
done
[ -e "$STATE/.paused-$key" ] || { kill "$WATCH_PID"; echo 'watcher did not classify the live pause'; exit 1; }
sleep 5
cp "$STATE/.watch-triage.log" "$EVIDENCE/pi-paused-triage.txt" 2>/dev/null || true
kill -0 "$WATCH_PID"
[ ! -s "$EVIDENCE/pi-paused-watch.txt" ]
[ ! -s "$STATE/.wake-queue" ]
echo 'Real Pi pause stayed quiet across stale polls inside its recheck cadence'
"$REAL_TMUX" -L "$SOCKET" respawn-pane -k -t "$TARGET" 'sleep 120'
printf 'paused: waiting on a new disposable release condition\n' >> "$STATE/$ID.status"
for i in {1..200}; do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.1
done
if kill -0 "$WATCH_PID" 2>/dev/null; then kill "$WATCH_PID"; echo 'dead agent remained hidden by its pause'; exit 1; fi
wait "$WATCH_PID" || true
cat "$EVIDENCE/pi-paused-watch.txt"
cat "$STATE/.wake-queue"
echo 'A fresh pause without a live Pi agent did not gain pause suppression'
echo 'LIVE PAUSE LIVENESS SCENARIOS PASSED'
