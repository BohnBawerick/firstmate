#!/usr/bin/env bash
set -euo pipefail
EVIDENCE=/home/bohn/.no-mistakes/evidence/01M50CWGPF8YPNBTQRHJHZRNM6
source <(sed 's@\. "$(dirname "${BASH_SOURCE\[0\]}")/fixtures.sh"@. "$PWD/tests/fixtures.sh"@; /^for harness in claude opencode pi pi-signed omp grok codex; do$/,$d' tests/fm-secondmate-busy-contract-live-e2e.test.sh)
REAL_PI=/home/bohn/.local/share/mise/installs/pi/latest/pi/pi
CASE_DIR="$LAB/pi"
ID=sm-pi
install_sleeper "$CASE_DIR/sleeper" pi "$REAL_PI"
install_tmux_shim "$CASE_DIR/shim"
"$REAL_TMUX" -L "$SOCKET" new-session -d -s firstmate -x 160 -y 45 -c "$ROOT"
spawn_mate "$CASE_DIR" "$ID" pi "$CASE_DIR/sleeper" "$CASE_DIR/shim" > "$EVIDENCE/pi-spawn-setup.log" 2>&1
STATE="$CASE_DIR/primary/state"
cp "$STATE/$ID.pi-ext.ts" "$EVIDENCE/pi-generated-extension.ts"
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
