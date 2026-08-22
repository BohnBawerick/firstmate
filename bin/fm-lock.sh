#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the pid of the harness (agent) process that lives as long as the
# firstmate session - unlike the transient subshell PID of any one tool call,
# which is dead moments after it is written. bin/fm-session-lock-lib.sh owns how
# that pid is resolved and how a later caller proves it belongs to the same
# session; a session whose harness publishes a conversation id also records it
# in state/.lock.session, so a background continuation of that conversation
# inherits the helm instead of fighting for it.
# Every acquisition line states OWNERSHIP in words, never a bare pid: a reader
# must be able to tell "I hold this" from "someone else holds this" without
# comparing pids by hand.
# Usage: fm-lock.sh           acquire; exit 1 unless ownership is verified
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE" 2>/dev/null || {
  echo "error: cannot create session-lock state directory $STATE; operate read-only until resolved" >&2
  exit 1
}

# Harness identity (FM_HARNESS_RE, ancestry walk, holder liveness) is owned by
# the shared session-lock lib so the Claude Stop auto-arm applies the exact
# same identity contract.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "lock: unreadable"
    exit 0
  }
  if ! fm_harness_pid_alive "$old"; then
    echo "lock: stale (pid $old dead or not a harness)"
  elif fm_session_lock_owned_by_self "$STATE"; then
    echo "lock: held by THIS session (harness pid $old)"
  else
    echo "lock: held by ANOTHER live session (harness pid $old)"
  fi
  exit 0
fi

me=$(fm_session_lock_self_pid) || { echo "error: cannot identify this session harness process" >&2; exit 1; }

# Record the conversation alongside the pid, so a later background continuation
# of THIS conversation is recognized as the same helm. Publishing no id must
# clear any stale one rather than leave it to grant ownership to a stranger.
publish_session_id() {
  local id file
  file=$(fm_session_lock_id_file "$STATE")
  if id=$(fm_harness_session_id); then
    printf '%s\n' "$id" > "$file" 2>/dev/null || rm -f "$file" 2>/dev/null || true
  else
    rm -f "$file" 2>/dev/null || true
  fi
}

# One wording for every successful acquisition, so the ownership verdict never
# reads as a bare pid the caller has to interpret.
# The parenthetical names the tier that actually granted ownership, because
# tier 2 and tier 3 both reach this with a recorded pid that is not `me`, and
# claiming a conversation match the ancestry walk made would be wrong.
report_acquired() {
  local recorded=$1 self_id recorded_id
  if [ "$me" = "$recorded" ]; then
    echo "lock acquired: THIS session holds the fleet lock (harness pid $recorded)"
  elif self_id=$(fm_harness_session_id) \
    && recorded_id=$(fm_session_lock_recorded_id "$STATE") \
    && [ "$self_id" = "$recorded_id" ]; then
    echo "lock acquired: THIS session holds the fleet lock (recorded harness pid $recorded, same conversation as this session)"
  else
    echo "lock acquired: THIS session holds the fleet lock (recorded harness pid $recorded, inside this session's harness ancestry)"
  fi
}
probe=$(mktemp "$STATE/.lock-write.XXXXXX" 2>/dev/null) || {
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
}
rm -f "$probe" 2>/dev/null || {
  echo "error: cannot clean session-lock publication probe; operate read-only until resolved" >&2
  exit 1
}
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
CLAIM_LOCK="$STATE/.lock.acquire"
CLAIM_LOCK_HELD=0
release_claim_lock() {
  if [ "$CLAIM_LOCK_HELD" -eq 1 ]; then
    fm_lock_release "$CLAIM_LOCK"
    CLAIM_LOCK_HELD=0
  fi
}
trap release_claim_lock EXIT
trap 'exit 1' HUP INT TERM

# Ownership without a live recorded pid falls through to a fresh claim rather
# than exiting early, so the live-pid invariant bin/fm-session-lock-lib.sh states
# holds after every acquisition.
if [ -f "$LOCK" ] && [ ! -L "$LOCK" ]; then
  old=$(cat "$LOCK" 2>/dev/null || true)
  if fm_harness_pid_alive "$old"; then
    if fm_session_lock_owned_by_self "$STATE"; then
      publish_session_id
      report_acquired "$old"
      exit 0
    fi
    echo "error: NOT THIS SESSION - another live firstmate session holds the lock (harness pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi

if ! fm_lock_try_acquire "$CLAIM_LOCK"; then
  sweep_pid=$(sed -n 's/^pid=//p' "$STATE/.startup-network.status" 2>/dev/null | tail -1)
  if [ -n "${FM_LOCK_HELD_PID:-}" ] && [ "$FM_LOCK_HELD_PID" = "$sweep_pid" ]; then
    echo "error: the prior session's bounded startup sweep is finishing; operate read-only until it releases the fleet lock" >&2
    exit 1
  fi
  fm_lock_acquire_wait "$CLAIM_LOCK"
fi
CLAIM_LOCK_HELD=1

if [ -e "$LOCK" ] || [ -L "$LOCK" ]; then
  if [ ! -f "$LOCK" ] || [ -L "$LOCK" ]; then
    echo "error: session lock is not a regular file; operate read-only until resolved" >&2
    exit 1
  fi
  old=$(cat "$LOCK" 2>/dev/null) || {
    echo "error: session lock is unreadable; operate read-only until resolved" >&2
    exit 1
  }
  if fm_harness_pid_alive "$old" && ! fm_session_lock_owned_by_self "$STATE"; then
    echo "error: NOT THIS SESSION - another live firstmate session holds the lock (harness pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
if ! { printf '%s\n' "$me" > "$LOCK"; } 2>/dev/null; then
  echo "error: cannot write session lock; operate read-only until resolved" >&2
  exit 1
fi
written=$(cat "$LOCK" 2>/dev/null) || {
  echo "error: cannot verify session lock ownership; operate read-only until resolved" >&2
  exit 1
}
if [ ! -f "$LOCK" ] || [ -L "$LOCK" ] || [ "$written" != "$me" ]; then
  echo "error: session lock ownership verification failed; operate read-only until resolved" >&2
  exit 1
fi
publish_session_id
release_claim_lock
report_acquired "$me"
