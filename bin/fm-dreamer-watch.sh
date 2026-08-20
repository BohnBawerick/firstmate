#!/usr/bin/env bash
# fm-dreamer-watch.sh - evaluate whether an offline dream (memory consolidation)
# pass is due, and arm the idle-notification watch for it.
#
# Usage:
#   fm-dreamer-watch.sh check [options]
#   fm-dreamer-watch.sh arm [options]
#   fm-dreamer-watch.sh mark-due <source-id> [options]
#   fm-dreamer-watch.sh -h | --help
#
# check
#   Evaluate the dream-due condition for the home selected by --home, or by
#   FM_HOME when no --home is given, and print
#   one machine-readable verdict line:
#     DREAM_DUE: due reason=<one-line reason>
#     DREAM_DUE: not-due reason=<one-line reason>
#   The exit code is the when-adapter contract: 0 for due (true), 1 for a clean
#   not-due (false), and 2 for a usage error. The condition is true exactly when
#   the fleet has no live non-dreamer worker AND either the drop tray holds an
#   unconsumed candidate file OR data/memory/HEAD is older than the threshold.
#
# arm
#   Register the deterministic condition->action watch that wakes firstmate when
#   a dream pass is due, via bin/fm-procevent-when.sh. The condition is this
#   script's `check`; the action is this script's `mark-due`, which writes a
#   durable marker so a later dispatch decision has evidence. Arm only from a
#   firstmate turn; the watch fires at most once and firstmate re-arms it after
#   handling the `done:` of a dream scout. The action only marks due and wakes
#   firstmate; it never spawns an agent, because dispatch needs judgment (quota,
#   whether the core changed and must be graded).
#
# mark-due
#   The safe, deterministic action the armed watch runs. It atomically writes a
#   durable marker file state/.dream-due with fixed content and exits 0. It is
#   idempotent and reversible (removing the marker file), so it is a legal when
#   action. The runner captures its output and wakes firstmate.
#
# OPTIONS (all commands accept --home; the rest apply to check and arm):
#   --home <path>           the firstmate home to evaluate, pinned explicitly
#                           instead of inherited from FM_HOME. `arm` places its
#                           own resolved home in both registered argv vectors so
#                           the watch does not depend on the runner environment.
#   --head-age <hours>      HEAD age threshold (default: FM_DREAM_HEAD_AGE_HOURS
#                           or 12)
#   --interval <secs>       arm only: when poll cadence (default 3600)
#   --stable <n>            arm only: consecutive true polls before firing
#                           (default 2)
#   --dry-run               arm only: print the when registration argv without
#                           registering (default off)
#
# A worker is live when its state/<id>.meta endpoint exists via
# bin/fm-backend.sh's fm_backend_target_exists - the same liveness read the
# session-start fleet digest uses. An unsupported backend, an unresolvable
# endpoint, or a remote worker whose endpoint lives on another host treats that
# worker as live (block), which is fail-safe for "never dream while a worker may
# be active". Dream tasks are identified by the
# conventional fm-dream- prefix on the task id and are excluded from the
# live-worker count. A missing FM_HOME, a home with no state/ or data/memory/, or
# a home whose data/memory is a symlink reports not-due with a reason rather than
# a hard error, so the watch can sit on a not-yet-initialized or unevaluable home
# without alarming.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
MEMORY="$DATA/memory"

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die() {
  printf 'fm-dreamer-watch: %s\n' "$1" >&2
  exit 2
}

# resolve_home <path>: print the physical directory a home names, resolving a
# symlinked home rather than refusing it. A symlinked home is ordinary and every
# other firstmate script accepts one; refusing it here would let `arm` register
# a spec whose own `check` then exits 2, which the when runner counts as a
# condition ERROR against its error budget instead of a plain false.
resolve_home() {
  local raw=$1 resolved
  resolved=$(CDPATH='' cd -- "$raw" 2>/dev/null && pwd -P) || return 1
  [ -n "$resolved" ] || return 1
  printf '%s' "$resolved"
}

HOME_OPT=""
HEAD_AGE_HOURS=${FM_DREAM_HEAD_AGE_HOURS:-12}
INTERVAL=${FM_DREAM_WATCH_INTERVAL:-3600}
STABLE=2
DRY_RUN=0
SOURCE_ID=""
CMD=""

case "${1:-}" in
  check|arm|mark-due) CMD=$1; shift ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --home)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      HOME_OPT="$2"; shift 2 ;;
    --home=*)
      HOME_OPT=${1#*=}; shift ;;
    --head-age)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      HEAD_AGE_HOURS="$2"; shift 2 ;;
    --head-age=*)
      HEAD_AGE_HOURS=${1#*=}; shift ;;
    --interval)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      INTERVAL="$2"; shift 2 ;;
    --interval=*)
      INTERVAL=${1#*=}; shift ;;
    --stable)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      STABLE="$2"; shift 2 ;;
    --stable=*)
      STABLE=${1#*=}; shift ;;
    --dry-run)
      DRY_RUN=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    -*)
      usage >&2; exit 2 ;;
    *)
      if [ "$CMD" = mark-due ] && [ -z "$SOURCE_ID" ]; then
        SOURCE_ID="$1"; shift
      else
        usage >&2; exit 2
      fi
      ;;
  esac
done

case "$HEAD_AGE_HOURS" in
  ''|*[!0-9.]*) die "invalid --head-age: '$HEAD_AGE_HOURS' (expected hours)" ;;
esac
case "$INTERVAL" in
  ''|*[!0-9.]*) die "invalid --interval: '$INTERVAL' (expected seconds)" ;;
esac
case "$STABLE" in
  ''|*[!0-9]*) die "invalid --stable: '$STABLE' (expected an integer)" ;;
esac
[ "$STABLE" -ge 1 ] || die "--stable must be at least 1"

# An explicit --home is authoritative for every path this script reads or
# writes, so a registered watch evaluates the home it was armed for no matter
# what environment the runner happens to carry.
if [ -n "$HOME_OPT" ]; then
  FM_HOME=$(resolve_home "$HOME_OPT") \
    || die "--home must name an existing directory, got '$HOME_OPT'"
  STATE="$FM_HOME/state"
  DATA="$FM_HOME/data"
  MEMORY="$DATA/memory"
fi

# --- mark-due ----------------------------------------------------------------

if [ "$CMD" = mark-due ]; then
  [ -n "${SOURCE_ID:-}" ] || die "mark-due requires a <source-id> argument"
  [ -d "$STATE" ] || mkdir -p "$STATE" || die "could not create $STATE"
  printf 'dream due: %s\n' "$SOURCE_ID" > "$STATE/.dream-due.tmp"
  mv -f "$STATE/.dream-due.tmp" "$STATE/.dream-due" || die "could not write $STATE/.dream-due"
  printf 'dream due marker written for %s\n' "$SOURCE_ID"
  exit 0
fi

# --- shared condition helpers ------------------------------------------------

# drop_has_candidates: 0 when data/memory/drop/ holds at least one candidate
# file. A symlinked tray is refused (no verdict), consistent with the memory
# guards, so a link cannot silently hide candidates or fabricate them.
drop_has_candidates() {
  [ -d "$DROP_DIR" ] && [ ! -L "$DROP_DIR" ] || return 1
  local f found=0
  for f in "$DROP_DIR"/*.md; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    found=1
    break
  done
  [ "$found" -eq 1 ]
}

# head_is_stale: 0 when data/memory/HEAD exists and is older than HEAD_AGE_HOURS.
# A missing HEAD (home not yet dreamed) is NOT stale here: the compiler falls
# back to data/memory and the home still works, so an uninitialized home must
# not alarm on age. Only a HEAD that exists and aged is stale.
head_is_stale() {
  [ -f "$MEMORY/HEAD" ] && [ ! -L "$MEMORY/HEAD" ] || return 1
  local mtime now age
  mtime=$(stat -c %Y "$MEMORY/HEAD" 2>/dev/null || stat -f %m "$MEMORY/HEAD" 2>/dev/null) || return 1
  now=$(date +%s) || return 1
  age=$((now - mtime))
  [ "$age" -ge 0 ] || return 1
  # Compare in seconds to avoid floating point in the shell.
  local max_seconds
  max_seconds=$(awk -v h="$HEAD_AGE_HOURS" 'BEGIN { printf "%.0f", h * 3600 }')
  [ "$age" -gt "$max_seconds" ]
}

# live_workers: prints the task id of every live NON-dreamer worker, one per
# line, and returns 0 when at least one was found. A dream task is one whose id
# starts with the conventional fm-dream- prefix. A worker whose endpoint cannot
# be positively confirmed gone is treated as live (fail-safe block): only a
# supported backend whose target does not exist counts as dead, because an
# unsupported backend returning "no" is not proof the worker is idle.
live_workers() {
  local meta id backend target remote_host live=0
  [ -d "$STATE" ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    case "$id" in
      fm-dream-*) continue ;;
    esac
    # A remote worker records its real endpoint in remote_backend/remote_target
    # on another host, and its local window= is the placeholder remote:<id>.
    # Probing that placeholder with the local backend proves nothing, and a real
    # probe would need an SSH round trip this bounded local condition must not
    # take, so a remote worker counts as live.
    remote_host=$(fm_meta_get "$meta" remote_host)
    if [ -n "$remote_host" ]; then
      printf '%s\n' "$id"
      live=1
      continue
    fi
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    case "$backend" in
      tmux|herdr|zellij|orca|cmux) ;;
      *)
        # Unsupported or unknown backend: cannot prove the worker is idle.
        printf '%s\n' "$id"
        live=1
        continue
        ;;
    esac
    # An empty target is a meta with no resolvable endpoint (for example a
    # partially written meta with no window= key). That is not proof the worker
    # is gone, so it counts as live, like an unsupported backend.
    if [ -z "$target" ] || fm_backend_target_exists "$backend" "$target" "fm-$id" >/dev/null 2>&1; then
      printf '%s\n' "$id"
      live=1
    fi
  done
  [ "$live" -eq 1 ]
}

DROP_DIR="$MEMORY/drop"

# --- check -------------------------------------------------------------------

if [ "$CMD" = check ]; then
  if [ -L "$MEMORY" ]; then
    # A symlinked data/memory defeats the per-file guards below in one step: the
    # tray and HEAD reached through the link are not themselves links, so this
    # home would be judged due on another home's evidence. bin/fm-memory-verify.sh
    # refuses the same shape rather than issuing a verdict through the link.
    printf 'DREAM_DUE: not-due reason=data/memory is a symlink; refusing to evaluate through it\n'
    exit 1
  fi
  if [ ! -d "$MEMORY" ]; then
    printf 'DREAM_DUE: not-due reason=no data/memory directory\n'
    exit 1
  fi
  if live_out=$(live_workers) && [ -n "$live_out" ]; then
    printf 'DREAM_DUE: not-due reason=live non-dreamer worker(s): %s\n' "$(printf '%s' "$live_out" | tr '\n' ' ')"
    exit 1
  fi
  if drop_has_candidates; then
    printf 'DREAM_DUE: due reason=unconsumed candidate files in data/memory/drop\n'
    exit 0
  fi
  if head_is_stale; then
    printf 'DREAM_DUE: due reason=data/memory/HEAD older than %s hours\n' "$HEAD_AGE_HOURS"
    exit 0
  fi
  printf 'DREAM_DUE: not-due reason=no unconsumed drops and HEAD not stale\n'
  exit 1
fi

# --- arm ---------------------------------------------------------------------

# The when condition argv must be exact and deterministic: run this script's
# `check` with the resolved home and threshold, both pinned as explicit tokens
# so the registered spec is self-contained. The home is resolved and validated
# here, at registration time, with the same rule `check --home` applies, so a
# spec that `check` would reject can never be registered. The action argv is `mark-due` with
# the resolved source id and the same pinned home. Both argv vectors are
# executed directly by the runner with no shell, so each token is passed as its
# own argument.
ARM_HOME_RAW=$FM_HOME
FM_HOME=$(resolve_home "$ARM_HOME_RAW") \
  || die "cannot arm: the home to watch is not an existing directory: '$ARM_HOME_RAW'"

WHEN_NAME="dream-due"
CONDITION_ARGV=("$SCRIPT_DIR/fm-dreamer-watch.sh" check --head-age "$HEAD_AGE_HOURS" --home "$FM_HOME")
SOURCE_ID="when-dream-due"
ACTION_ARGV=("$SCRIPT_DIR/fm-dreamer-watch.sh" mark-due "$SOURCE_ID" --home "$FM_HOME")

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'would arm: bin/fm-procevent-when.sh arm %s --interval %s --stable %s --condition' \
    "$WHEN_NAME" "$INTERVAL" "$STABLE"
  printf ' %q' "${CONDITION_ARGV[@]}"
  printf ' --action'
  printf ' %q' "${ACTION_ARGV[@]}"
  printf '\n'
  exit 0
fi

exec "$SCRIPT_DIR/fm-procevent-when.sh" arm "$WHEN_NAME" \
  --interval "$INTERVAL" \
  --stable "$STABLE" \
  --condition "${CONDITION_ARGV[@]}" \
  --action "${ACTION_ARGV[@]}"
