#!/usr/bin/env bash
set -euo pipefail
ROOT=$1
LAB=$2
EVIDENCE=$(cd "$(dirname "$0")" && pwd)
export FM_HOME="$LAB" TMPDIR="$ROOT/.test-phase/runtime"

unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
bash "$ROOT/bin/fm-lock.sh" | tee "$EVIDENCE/primary-lock.txt"
OWNER=$(cat "$LAB/state/.lock")
FM_HOME="$LAB" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$2"; touch "$2.held"; sleep 120' _ "$ROOT" "$LAB/state/.home-summary-refresh.lock" &
HOLDER=$!
cleanup() { kill "$HOLDER" 2>/dev/null || true; }
trap cleanup EXIT
for i in {1..60}; do [ ! -f "$LAB/state/.home-summary-refresh.lock.held" ] || break; sleep 0.1; done
START=$SECONDS
FM_HOME_SUMMARY_TIMEOUT=60 bash "$ROOT/bin/fm-session-start.sh" > "$EVIDENCE/primary-startup.txt" 2>&1
ELAPSED=$((SECONDS - START))
printf 'Real primary startup with blocked summary: elapsed=%ss\n' "$ELAPSED"
grep -F 'The digest above is complete for this session start' "$EVIDENCE/primary-startup.txt"
[ "$ELAPSED" -lt 45 ]
[ ! -s "$LAB/state/home-summary.json" ]
kill "$HOLDER" 2>/dev/null || true
wait "$HOLDER" 2>/dev/null || true
# Release the test-owned summary mutex through its production owner.
bash -c '. "$1/bin/fm-wake-lib.sh"; fm_lock_release "$2"' _ "$ROOT" "$LAB/state/.home-summary-refresh.lock"
for i in {1..150}; do [ ! -s "$LAB/state/home-summary.json" ] || break; sleep 0.1; done
jq -e '.schema == "fm-secondmate-home-summary.v1"' "$LAB/state/home-summary.json"
cp "$LAB/state/home-summary.json" "$EVIDENCE/primary-home-summary.json"
echo 'Detached summary published after its lock cleared'
ln -s "$LAB/state/missing-autoarm-owner" "$LAB/state/.claude-autoarm.lock"
ln -s "$LAB/state/missing-steal-owner" "$LAB/state/.claude-autoarm.lock.steal"
touch -h -t 200001010000 "$LAB/state/.claude-autoarm.lock" "$LAB/state/.claude-autoarm.lock.steal"
bash -c '. "$1/bin/fm-wake-lib.sh"; fm_autoarm_claim_next "$2" || exit 1; printf "reclaimed auto-arm generation=%s\n" "$FM_AUTOARM_MY_GEN"; cat "$2/.claude-autoarm-epoch"; test ! -L "$2/.claude-autoarm.lock"; test ! -L "$2/.claude-autoarm.lock.steal"' _ "$ROOT" "$LAB/state" | tee "$EVIDENCE/autoarm-live.txt"
{
  printf 'needs-decision [key=one]: first unresolved choice\nblocked [key=two]: second unresolved blocker\n'
  for ((i=0;i<10000;i++)); do printf 'working: later progress %s\n' "$i"; done
} > "$LAB/state/lab-status.status"
bash "$ROOT/bin/fm-wake-drain.sh" > "$EVIDENCE/decision-drain-live.txt" 2>&1
grep -F 'one' "$EVIDENCE/decision-drain-live.txt"
grep -F 'two' "$EVIDENCE/decision-drain-live.txt"

bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append stale live-primary "stale: lab wake for the supervision branch"' _ "$ROOT"
ROW=$(cat "$LAB/state/.wake-queue.seq")
bash "$ROOT/bin/fm-wake-grant.sh" activate "$$" live-primary
bash "$ROOT/bin/fm-wake-grant.sh" publish live-primary "$ROW"
for mode in delegate foreign; do
  if [ "$mode" = delegate ]; then export FM_SUPERVISION_ACTOR=branch FM_LEASE_HOLDER_PID="$OWNER"; else unset FM_SUPERVISION_ACTOR FM_LEASE_HOLDER_PID; fi
  PROMPT="Run exactly this one Bash command and then stop: bash $ROOT/bin/fm-wake-drain.sh > $EVIDENCE/$mode-drain.txt 2>&1; echo \$? > $EVIDENCE/$mode-drain-code.txt"
  claude -p "$PROMPT" --model haiku --dangerously-skip-permissions --setting-sources '' --no-session-persistence --tools Bash --system-prompt 'Execute the requested command with Bash. Do not run other commands.' --output-format stream-json --verbose > "$EVIDENCE/$mode-engine.jsonl" 2>&1
  printf '%s engine drain exit: %s\n' "$mode" "$(cat "$EVIDENCE/$mode-drain-code.txt")"
  cat "$EVIDENCE/$mode-drain.txt"
done
[ "$(cat "$EVIDENCE/delegate-drain-code.txt")" = 0 ]
[ "$(cat "$EVIDENCE/foreign-drain-code.txt")" != 0 ]
grep -F 'does not hold the fleet lock' "$EVIDENCE/foreign-drain.txt"
[ "$(cat "$LAB/state/.lock")" = "$OWNER" ]
echo 'Real nested Claude delegate admitted; unbound nested Claude refused; lock unchanged'
echo 'LIVE PRIMARY SCENARIOS PASSED'
