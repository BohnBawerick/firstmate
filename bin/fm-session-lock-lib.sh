#!/usr/bin/env bash
# Shared session-lock harness identity and the fleet-mutation gate built on it.
#
# ONE owner of the "does the current process belong to the session that holds
# this home's session lock?" decision, and of the refusal every fleet-mutation
# entry point prints when it does not. bin/fm-lock.sh uses it to acquire and
# inspect state/.lock; bin/fm-claude-stop-autoarm.sh uses it to prove a Stop
# hook fires inside the lock-owning primary session before it may arm or rewake;
# bin/fm-turnend-guard.sh uses it to tell a genuine supervision failure apart
# from a session that simply does not hold this home; and every mutating fleet
# script calls fm_require_session_lock so a non-owning session refuses instead
# of proceeding on an instruction it may not have read.
# This file is sourced by scripts and has no side effects on source.
#
# IDENTITY, in order of authority. The ancestry walk below is a heuristic that
# answers a slightly different question at each call site: it climbs until the
# first harness match and then stops at the first non-harness ancestor, so how
# deep the caller sits inside the harness's own worker chain decides which pid
# it reports. A Claude Code background continuation of an existing conversation
# runs in a detached process tree, so the walk from its hooks stops short of the
# session that took the helm while the walk from its ordinary tool shells can
# climb past it into an unrelated harness further up the real tree. Two call
# sites in one session then disagree about who holds the helm - the exact split
# that let a background continuation mutate fleet state all night while
# supervision stayed off (docs/watcher-continuity.md).
# So a vendor-declared identity wins wherever the harness publishes one, because
# it is the same value at every call site of a session, hooks included:
#   1. CLAUDE_PID - the pid of the Claude Code session process itself.
#   2. CLAUDE_CODE_SESSION_ID - the conversation. A background continuation of a
#      conversation is that same conversation, so it inherits the helm rather
#      than fighting the session that took it.
#   3. the ancestry walk, unchanged, for every harness that publishes neither.

# Cursor process identity is NOT expressible as a command-name pattern and is
# deliberately not added to the tables below: Cursor's installed names are
# cursor-agent and the far-too-generic legacy alias `agent`, and it runs as a
# bundled node script. bin/fm-cursor-lib.sh is the fleet's single owner of that
# decision, so this file delegates to it rather than widening the name match.
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"

# Known harness command names; extend when a new adapter is verified.
FM_HARNESS_RE='claude|codex|opencode|grok|kimi|^agy$|^pi$|^pi-signed$'

# The same harnesses as exact executable names. Keep in sync with
# FM_HARNESS_RE. Used only for the stricter path evidence below, where the
# loose regex would also match ordinary firstmate paths such as
# bin/fm-claude-stop-autoarm.sh.
FM_HARNESS_NAMES=(claude codex opencode grok kimi agy pi-signed pi)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because Claude Code's native installer names the per-session
# executable by its version (~/.local/share/claude/versions/2.1.220), so the
# basename identifies nothing while the install path still says claude. Matching
# whole path components only is what keeps that widening safe: an ordinary path
# such as bin/fm-claude-stop-autoarm.sh or ~/.claude/hooks/notify.sh has no
# "claude" component and is correctly not a harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified harness. Sets FM_HARNESS_IS_CLAUDE for the ancestry walk.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely, so a version-named Claude Code binary
#      is identified by its install path on macOS and by argv[0] on Linux.
#   3. a bare interpreter (node, python) running a harness script path.
#   4. Cursor's own structural identity, owned by bin/fm-cursor-lib.sh.
FM_HARNESS_IS_CLAUDE=0
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  FM_HARNESS_IS_CLAUDE=0
  base=$(basename -- "$comm")
  if printf '%s' "$base" | grep -qE "$FM_HARNESS_RE"; then
    case "$base" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    case "$name" in claude) FM_HARNESS_IS_CLAUDE=1 ;; esac
    return 0
  fi
  # Bare interpreter (e.g. node): match the harness name in its script path.
  case "$comm" in
    *node*|*python*)
      if printf '%s' "$args" | grep -qE "$FM_HARNESS_RE"; then
        case "$args" in *claude*) FM_HARNESS_IS_CLAUDE=1 ;; esac
        return 0
      fi
      ;;
  esac
  # Cursor: its own owner decides, from Cursor's name or versioned install tree
  # in the command path or argv[0]. Without this a Cursor primary can never
  # locate its own harness in the ancestry, so every session start refuses the
  # fleet lock as read-only and the park can never arm.
  fm_cursor_process_matches "$comm" "$args" "$argv0" && return 0
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# contiguous verified-harness ancestry, innermost pid first.
#
# The walk climbs freely until the first harness match, because the caller is
# normally an ordinary shell several levels below its session. After that first
# match it stops at the first non-harness ancestor, so it can never cross a gap
# into an unrelated harness further up the real process tree - for example the
# live session that launched a test as its own subprocess.
#
# For every harness except Claude the innermost match is the session, which is
# where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner. Claude Code
# instead runs hooks several levels below the session inside its own nested
# worker chain (hook shell -> claude bg-spare -> claude bg-pty-host -> claude ->
# claude), with no non-harness process between them. Which pid in that run is the
# session cannot be read off the ancestry at all, so the whole contiguous run is
# reported and the callers below decide what they need from it.
fm_harness_ancestry_pids() {
  local pid=$$ comm args extending=0 printed=0
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      printed=1
      [ "$FM_HARNESS_IS_CLAUDE" -eq 1 ] || break
      extending=1
    elif [ "$extending" -eq 1 ]; then
      break
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  done
  [ "$printed" -eq 1 ]
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN: the outermost pid of the contiguous run. That is the pid that lives as
# long as the session - a Claude worker several levels in is reaped when its hook
# returns, and a lock naming it would look stale moments later while the session
# is still running. Every non-Claude harness reports a single pid, so this is its
# innermost match unchanged.
fm_harness_ancestry_pid() {
  local pids pid outermost=''
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ -n "$pid" ] && outermost=$pid
  done <<EOF
$pids
EOF
  [ -n "$outermost" ] || return 1
  printf '%s\n' "$outermost"
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# Print this session's vendor-declared conversation id, or return 1.
#
# Claude Code exports it into every tool-call shell AND every hook process of a
# session, so it is the one identity that is identical at both call sites and
# survives a background continuation running in a detached process tree. The
# charset check keeps a hostile or truncated value from ever matching a
# recorded id by accident.
fm_harness_session_id() {
  local id=${CLAUDE_CODE_SESSION_ID:-}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s\n' "$id"
}

# Print the pid of this session's own harness process as the harness itself
# declares it, or return 1. Verified against the same liveness predicate as any
# recorded lock owner, so a stale inherited value can never stand in for a live
# session.
fm_harness_session_pid() {
  local pid=${CLAUDE_PID:-}
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  fm_harness_pid_alive "$pid" || return 1
  printf '%s\n' "$pid"
}

# Print the pid to RECORD as this session's lock owner: the declared session pid
# when the harness publishes one, otherwise the ancestry walk's outermost pid.
# Preferring the declared pid is what stops the recorded owner and the ownership
# test from being computed by two different means in one session.
fm_session_lock_self_pid() {
  fm_harness_session_pid && return 0
  fm_harness_ancestry_pid
}

# Path of the conversation-id sidecar for state dir $1. Written next to the lock
# by bin/fm-lock.sh at every acquisition, and removed there whenever the
# acquiring session publishes no conversation id, so a stale id can never grant
# ownership to an unrelated session.
fm_session_lock_id_file() {  # <state-dir>
  printf '%s\n' "$1/.lock.session"
}

# Print the conversation id recorded alongside the lock in state dir $1, or
# return 1.
fm_session_lock_recorded_id() {  # <state-dir>
  local id
  id=$(cat "$(fm_session_lock_id_file "$1")" 2>/dev/null) || return 1
  id=${id%%[[:space:]]*}
  [ -n "$id" ] || return 1
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  printf '%s\n' "$id"
}

# Print the numeric pid recorded in state dir $1's session lock, or return 1.
fm_session_lock_pid() {  # <state-dir>
  local lock_pid
  lock_pid=$(cat "$1/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$lock_pid"
}

# True when this process belongs to the session that owns state dir $1's fleet
# lock, by the three-tier identity contract in this file's header. A missing
# lock, a malformed lock, a lock held by another session, or an identity that
# cannot be resolved at all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid self_pid self_id recorded_id pids pid
  lock_pid=$(fm_session_lock_pid "$state") || return 1

  # 1. this session's own declared process.
  if self_pid=$(fm_harness_session_pid); then
    [ "$self_pid" = "$lock_pid" ] && return 0
  fi

  # 2. the same conversation, including a background continuation of it.
  if self_id=$(fm_harness_session_id) && recorded_id=$(fm_session_lock_recorded_id "$state"); then
    [ "$self_id" = "$recorded_id" ] && return 0
  fi

  # 3. harness ancestry, for every harness that declares neither. Membership is
  # the honest test there, because the lock owner sits at an unknown depth in a
  # contiguous Claude run - the outermost pid when the hook fires inside the
  # session's own nested worker chain, an inner pid when a harness-named daemon
  # parents the session.
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}

# True when the current process belongs to SOME verified harness session, by
# either its declared identity or a resolvable harness ancestry.
fm_process_in_harness_session() {
  fm_harness_session_pid >/dev/null 2>&1 && return 0
  fm_harness_ancestry_pids >/dev/null 2>&1
}

# True when a DIFFERENT live firstmate session demonstrably holds state dir $1's
# fleet lock while the current process belongs to a harness session of its own,
# so this session must not mutate that home's fleet state.
#
# Every part of that conjunction is load-bearing, and only the conjunction
# refuses:
#   - a missing, stale, or malformed lock means no competing session exists to
#     split the helm with, and bin/fm-lock.sh already owns turning those cases
#     into a fresh acquisition.
#   - a caller that is not inside a harness session at all is not a competing
#     session either. That is the parent home reaching into a secondmate's
#     endpoint over ssh (bin/fm-remote-secondmate-control.sh), a detached job,
#     or a test - none of which can produce the two-agents-one-home split this
#     gate exists to stop, and all of which would break for nothing.
fm_session_lock_held_by_other() {  # <state-dir>
  local state=$1 lock_pid
  lock_pid=$(fm_session_lock_pid "$state") || return 1
  fm_harness_pid_alive "$lock_pid" || return 1
  fm_session_lock_owned_by_self "$state" && return 1
  fm_process_in_harness_session || return 1
  return 0
}

# Gate for every fleet-mutation entry point: return 0 when $2 may proceed
# against state dir $1, or print the refusal on stderr and return 1.
#
# AGENTS.md section 3 makes a session that could not verify lock ownership
# read-only. This is that rule enforced where the mutation actually happens,
# rather than trusted to a banner the session may never have read.
fm_require_session_lock() {  # <state-dir> <action>
  local state=$1 action=$2 lock_pid
  fm_session_lock_held_by_other "$state" || return 0
  lock_pid=$(fm_session_lock_pid "$state" 2>/dev/null || true)
  {
    printf 'error: refusing to %s - this session does not hold the fleet lock for %s.\n' \
      "$action" "$state"
    printf 'Another live firstmate session (harness pid %s) holds it, and only that session\n' \
      "${lock_pid:-unknown}"
    printf 'may change fleet state. Operate read-only from here, or end that session first.\n'
  } >&2
  return 1
}
