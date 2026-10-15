#!/usr/bin/env bash
set -euo pipefail
EVIDENCE=/home/bohn/.no-mistakes/evidence/01M50CWGPF8YPNBTQRHJHZRNM6/current/pi-restart
source <(sed 's@\. "$(dirname "${BASH_SOURCE\[0\]}")/fixtures.sh"@. "$PWD/tests/fixtures.sh"@; /^for harness in claude opencode pi pi-signed omp grok codex; do$/,$d' tests/fm-secondmate-busy-contract-live-e2e.test.sh)
mkdir -p "$EVIDENCE"
ORIGINAL_ROOT=$ROOT
mkdir -p "$ORIGINAL_ROOT/.test-phase/product"
cp -a "$ORIGINAL_ROOT/bin" "$ORIGINAL_ROOT/.pi" "$ORIGINAL_ROOT/.claude" "$ORIGINAL_ROOT/AGENTS.md" "$ORIGINAL_ROOT/.gitignore" "$ORIGINAL_ROOT/.test-phase/product/"
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
cp -a "$ROOT/bin" "$ROOT/.claude" "$CASE_DIR/sm/"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$CASE_DIR/primary" > "$CASE_DIR/sm/.fm-secondmate-parent"
chmod 600 "$CASE_DIR/sm/.fm-secondmate-parent"
cp "$STATE/$ID.pi-ext.ts" "$EVIDENCE/pi-generated-extension.ts"
"$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "firstmate:fm-$ID" > "$EVIDENCE/pi-sleeper-pane.txt"
"$REAL_TMUX" -L "$SOCKET" kill-window -t "firstmate:fm-$ID"
mkdir -p "$CASE_DIR/sm/config"
printf 'on\n' > "$CASE_DIR/sm/config/calm"
"$REAL_TMUX" -L "$SOCKET" new-window -d -t firstmate: -n "fm-$ID" -c "$CASE_DIR/sm" 'bash --noprofile --norc'
printf -v command '%q ' env -u FM_GATE_REFUSE_BYPASS -u FM_TEST_SEAM FM_HOME="$CASE_DIR/sm" FM_TASK_INBOX="$STATE/$ID.inbox" \
  "$REAL_PI" --provider openai-codex --model gpt-6-luna --thinking minimal --no-session --no-extensions --no-context-files \
  --no-skills --no-mcp --no-prompt-templates --no-themes \
  -e "$STATE/$ID.pi-ext.ts" -e "$ROOT/.pi/extensions/fm-calm.ts"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "firstmate:fm-$ID" -l "$command"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "firstmate:fm-$ID" Enter
TARGET="firstmate:fm-$ID"
for i in {1..60}; do
  screen=$("$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET")
  case "$screen" in *'Trust project folder?'*) "$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Escape ;; esac
  case "$screen" in *'(openai-codex) gpt-6-luna'*) break ;; esac
  sleep 0.5
done
"$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" > "$EVIDENCE/pi-idle-before.txt"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" -l "Reply with exactly PI_SEMANTIC_OK now. For a later Firstmate instruction waiting doorbell, use Bash to read \"\$FM_TASK_INBOX\"/*.msg and extract its corr token. This disposable home has no open work. You MUST use the Bash tool to execute FM_HOME='$CASE_DIR/sm' bash '$ROOT/bin/fm-secondmate-report.sh' done CORR_TOKEN 'open records written down'. Chat alone does not report. Move handled messages into handled/. Do no other work."
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$TARGET" Enter
busy=0
for i in {1..240}; do
  record=$(cat "$STATE/$ID.busy-state")
  case "$record" in *'state=busy'*'source=pi-ext'*) busy=1; printf '%s\n' "$record" > "$EVIDENCE/pi-busy-record.txt"; break ;; esac
  sleep 0.05
done
"$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "$TARGET" > "$EVIDENCE/calm-busy-pane.txt"
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

# Execute the real persist, settle, and relaunch path against the live Pi.
rc=0
PATH="$CASE_DIR/shim:$PATH" FM_HOME="$CASE_DIR/primary" FM_ROOT_OVERRIDE="$ROOT" \
 FM_STATE_OVERRIDE="$STATE" FM_SPAWN_NO_GUARD=1 FM_SECONDMATE_PERSIST_WAIT=75 \
 FM_SECONDMATE_PERSIST_POLL=1 FM_SECONDMATE_SETTLE_WAIT=20 FM_SECONDMATE_SETTLE_POLL=1 \
 FM_CONTROL_EXIT_WAIT=15 FM_CONTROL_LAUNCH_WAIT=15 \
 "$ROOT/bin/fm-secondmate-restart.sh" "$ID" > "$EVIDENCE/restart-output.txt" 2>&1 || rc=$?
cat "$EVIDENCE/restart-output.txt"
"$REAL_TMUX" -L "$SOCKET" capture-pane -p -S -100 -t "$TARGET" > "$EVIDENCE/restart-pane.txt"
cp "$STATE/$ID.status" "$EVIDENCE/parent-status.txt"
cat "$EVIDENCE/parent-status.txt"
[ "$rc" = 0 ]
grep -F "restarted: $ID (pi)" "$EVIDENCE/restart-output.txt"
echo 'LIVE PI PERSIST AND RESTART PASSED'
