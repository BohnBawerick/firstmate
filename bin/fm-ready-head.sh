#!/usr/bin/env bash
# Usage: fm-ready-head.sh <task-id> <previous-ready-head> <revised-ready-head>
# Record an unpublished local-only ship's revised done for the same branch.
# Both heads must be full commit IDs. The newer, timestamped ready report must
# name that branch, whose tip must descend from the old head and match the
# worker copy. Record the old and new heads with the date in the task metadata.
# Run from Firstmate before seeking approval to land the revised head.
set -euo pipefail

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
home=${FM_HOME:-${FM_ROOT_OVERRIDE:-${dir%/*}}}
state=${FM_STATE_OVERRIDE:-$home/state}
# shellcheck source=bin/fm-dod-lib.sh
. "$dir/fm-dod-lib.sh"
if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then
  sed -n '2,7s/^# //p' "$0"
  exit 0
fi
if [ "$#" -ne 3 ] || ! fm_pr_task_id_valid "$1" ||
  ! fm_pr_head_valid "$2" || ! fm_pr_head_valid "$3"; then
  echo "Usage: fm-ready-head.sh <task-id> <previous-ready-head> <revised-ready-head>" >&2
  exit 2
fi
# shellcheck source=bin/fm-session-lock-lib.sh
. "$dir/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$dir/fm-lease-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$dir/fm-wake-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$dir/fm-backlog-transition-lib.sh"

fm_require_session_lock "$state" "record a revised local ready head"
fm_lease_forbid_branch "recording a revised local ready head (fm-ready-head)"
fm_backlog_directory_present "$state" "state directory" || {
  printf 'error: %s\n' "$FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
control="$state/.control-$1.lock"
meta_lock=$(fm_meta_lock_path "$state/$1.meta")
fm_lock_acquire_wait "$control"
trap 'fm_lock_release "$control"' EXIT
fm_lock_acquire_wait "$meta_lock"
trap 'fm_lock_release "$meta_lock"; fm_lock_release "$control"' EXIT
trap 'exit 1' HUP INT TERM
fm_dod_rerecord_local_done_head "$state" "$@"
printf 'Recorded revised ready head for %s: %s -> %s\n' "$@"
