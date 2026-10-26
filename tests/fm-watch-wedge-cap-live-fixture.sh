#!/usr/bin/env bash
drain_lab_wakes() {
  local out="$TMP_ROOT/drain.out" err="$TMP_ROOT/drain.err"
  FM_HOME="$LAB_HOME" "$ROOT/bin/fm-wake-drain.sh" > "$out" 2> "$err" \
    || fail "could not present the lab wake queue: $(cat "$err")"
  if grep -q '^WAKE_ACK_REQUIRED:' "$err"; then
    FM_HOME="$LAB_HOME" ack_drain_err "$STATE" "$err" >> "$TRANSCRIPT" 2>&1 \
      || fail "could not acknowledge the lab wake queue"
  fi
}

watcher_cycle() {
  local label=$1 expected=$2 out rc pid beat checkpoint i=0 threshold_beats=0 silence_after=0 reason
  cycle=$((cycle + 1))
  out="$TMP_ROOT/cycle-$cycle.out"
  beat="$STATE/.last-watcher-beat"
  checkpoint="$TMP_ROOT/cycle-$cycle.beat"
  CYCLE_WOKE=0
  CYCLE_REASON=''
  rm -f "$beat" "$checkpoint"
  FM_HOME="$LAB_HOME" TMUX_TMPDIR="$LAB_TMUX_DIR" \
    FM_WEDGE_MAX_ESCALATIONS="$MAX" \
    FM_CAP_HORIZON_SECS="$HORIZON_SECS" \
    FM_STALE_ESCALATE_SECS="$STALE_SECS" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_BUSY_TURN_MAX_SECS=1 \
    "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt $(( CYCLE_BOUND * 10 )) ]; do
    if [ -e "$checkpoint" ]; then
      if [ "$beat" -nt "$checkpoint" ]; then
        if [ "$expected" = silence ]; then
          if [ "$silence_after" -eq 0 ]; then
            silence_after=$(( $(date +%s) + STALE_SECS + 1 ))
          elif [ "$(date +%s)" -ge "$silence_after" ]; then
            threshold_beats=$((threshold_beats + 1))
            [ "$threshold_beats" -lt 3 ] || break
          fi
          touch "$checkpoint"
        fi
      fi
    elif [ -e "$beat" ]; then
      touch "$checkpoint"
    fi
    sleep 0.1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    rc=alive
  else
    wait "$pid" 2>/dev/null
    rc=$?
    [ "$rc" -eq 0 ] || fail "$label: watcher failed with exit $rc: $(cat "$out")"
  fi
  rm -f "$beat" "$checkpoint"
  reason=$(head -1 "$out" 2>/dev/null)
  if [ "$rc" = alive ] && [ "$threshold_beats" -ge 3 ] && [ "$expected" = silence ]; then
    [ -z "$reason" ] || fail "$label: watcher printed output without completing a wake: $reason"
  else
    [ "$rc" = 0 ] && [ -n "$reason" ] \
      || fail "$label: watcher did not complete a poll with the expected outcome within ${CYCLE_BOUND}s"
    CYCLE_WOKE=1
  fi
  # shellcheck disable=SC2034 # Read by the live guard and isolated fixture tests.
  CYCLE_REASON="$reason"
  say "$label -> exit=$rc woke=$CYCLE_WOKE reason=${reason:-none}"
  cat "$out" >> "$TRANSCRIPT"
  drain_lab_wakes
}

reset_lab_state() {
  drain_lab_wakes
  rm -f "$STATE"/.wedge-permanent-* "$STATE"/.wedge-rollback-failed-* \
    "$STATE"/.wedge-escalations-* "$STATE"/.stale-since-* "$STATE"/.stale-* \
    "$STATE"/.count-* "$STATE"/.hash-*
  printf '%s' "$(hash_text "$PANE_TEXT")" > "$STATE/.hash-$KEY"
  printf '1\n' > "$STATE/.count-$KEY"
  touch -d '5 seconds ago' "$STATE/$TASK.meta" 2>/dev/null \
    || perl -e 'utime(time()-5, time()-5, $ARGV[0])' "$STATE/$TASK.meta"
}
