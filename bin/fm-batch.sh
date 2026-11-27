#!/usr/bin/env bash
# Batch checked local task branches into one GitHub pull request per repository and account.
#
#   fm-batch.sh <project> enqueue <task-id> <checked-head>
#   fm-batch.sh <project> dequeue <task-id>
#   fm-batch.sh <project> run
#   fm-batch.sh <project> fix <task-id> <checked-head>
#   fm-batch.sh <project> refresh
#   fm-batch.sh <project> merge <reviewed-batch-head>
#   fm-batch.sh <project> release <branch>
#   fm-batch.sh <project> status
#
# Use a registered direct-PR GitHub project with push access to origin.
# Enqueue only after build and lint pass at the supplied full commit ID. The
# task must have recorded a local-only ready head in this home. The optional
# config/batch-task-checks/<project> is a heavy check that must also pass at
# that head before the task joins a batch. Enqueue and fix run it in a
# temporary detached checkout with FM_TASK_ID, FM_TASK_HEAD and FM_TASK_BRANCH
# set. Exit 0 lets the task in. Exit 75 means the check still runs elsewhere;
# run and the watcher ask again until it answers, so the script must be
# idempotent per head. Any other exit keeps the task out until its ready head
# changes or an explicit enqueue retries it.
# After a task's batch merges, enqueue a descendant of its latest merged member
# head on the same task branch. To assemble a follow-up after a squash merge,
# run uses the landed member as the merge base (Git 2.40 or newer).
# Run publishes the waiting tasks against the current default branch or
# resumes a prior publish. While a batch is open, run stacks the waiting tasks
# into one batch built on the open batch's published head, with its pull
# request into the open batch's branch, so its CI runs while the open batch
# waits. Later tasks stay queued while two batches are open. A change to the
# open batch merges into the stacked batch, which then needs fresh checks.
# After the open batch lands, run moves the stacked pull request onto the
# default branch. It keeps the tested head, and so its CI result, only when the
# default branch holds exactly the landed tree it was built on; otherwise it
# merges the default branch in using the landed batch's head as the merge base
# after a squash (Git 2.40 or newer). A stacked batch merges only after promotion.
# Fix adds one checked task to a batch or updates an existing member after
# fm-ready-head.sh records its revised head. A member returns to its own
# batch; a new task joins the stacked batch only when built on its head, and
# the open batch otherwise. A task branch based on the current batch head
# advances the batch directly. The optional config/batch-checks/<project> runs
# against each assembled head before push. A closed, unmerged batch needs to
# be reopened before either batch can proceed.
# If a queued task conflicts, dequeue it before retrying. Its branch is kept.
# Dequeue also drops a waiting or failed heavy check.
# Refresh merges the current default into the open batch if the merge gate
# reports that it is behind. The updated head needs its own green checks.
# Release starts a local branch at GitHub's exact merge commit for the latest
# landed batch. The same step applies to a batch with one task.
#
# Merge requires the same approval or standing authority as fm-pr-merge.sh.
# Use the reviewed head from status. The merge gate checks the live head, CI,
# and each member's hold. Status prints the durable queue, heavy checks, and
# batch history, including task IDs, branch names, checked heads, stacked
# bases, and pull request URLs.
# The ledger lives under data/batches/<host>/<owner>/<repo>/<login>/ledger.json.
# This command serializes publishers that share a Firstmate home. Another
# publisher using the same account must use that home to share the queue.
# The watcher invokes the internal check action for opted-in projects.
set -euo pipefail
umask 077

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=${FM_ROOT_OVERRIDE:-${dir%/*}}
home=${FM_HOME:-$root}
state=${FM_STATE_OVERRIDE:-$home/state}
data=${FM_DATA_OVERRIDE:-$home/data}
config="${FM_CONFIG_OVERRIDE:-$home/config}"
auto_projects="$config/batch-projects"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}
fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}
case "${1:-}" in -h|--help) usage; exit 0 ;; esac
[ "$#" -ge 2 ] || { usage >&2; exit 2; }
name=$1 action=$2
shift 2
case "$action:$#" in
  enqueue:2|dequeue:1|fix:2|refresh:0|run:0|merge:1|release:1|status:0|check:0) ;;
  *) usage >&2; exit 2 ;;
esac
case "$name" in ''|.|..|*/*|*$'\n'*) fail "invalid project name" ;; esac

# shellcheck source=bin/fm-dod-lib.sh
. "$dir/fm-dod-lib.sh"
# shellcheck source=bin/fm-role-lib.sh
. "$dir/fm-role-lib.sh"
# shellcheck source=bin/fm-self-repo-lib.sh
. "$dir/fm-self-repo-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$dir/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$dir/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$dir/fm-wake-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$dir/fm-lease-lib.sh"

check_opt_in() {
  [ -f "$auto_projects" ] && [ ! -L "$auto_projects" ] &&
    grep -Fxq -- "$name" "$auto_projects"
}
if [ "$action" = check ]; then
  check_opt_in || exit 0
  watcher_pid=$(cat "$state/.watch.lock/pid")
  if ! fm_pid_descends_from "$$" "$watcher_pid" ||
    ! fm_watcher_lock_matches_pid "$state" "$dir/fm-watch.sh" "$watcher_pid" "$home"; then
    fail "the batch check must run under this home's watcher"
  fi
fi

posture=$("$dir/fm-project-mode.sh" "$name")
[ "${posture%% *}" = direct-PR ] || fail "$name must be registered as direct-PR"
[ "$("$dir/fm-project-mode.sh" --forge "$name")" = none ] || fail "$name must use GitHub"
project=$(cd "${FM_PROJECTS_OVERRIDE:-$home/projects}/$name" && pwd -P)
fm_is_firstmate_repo "$project" "$root" "$home" && fail "Firstmate lands through its local merge path"
git_project() { git -C "$project" "$@"; }

origin=$(git_project remote get-url origin)
identity=$(fm_role_remote_identity "$origin" "$project" nolocal)
host=${identity%%/*}
repo=${identity#*/}
fm_pr_url_parse "https://$identity/pull/1" ||
  fail "$name must have a GitHub origin on an allowed host"
push_urls=$(git_project remote get-url --push --all origin)
[[ "$push_urls" != *$'\n'* ]] &&
  [ "$(fm_role_remote_identity "$push_urls" "$project" nolocal)" = "$identity" ] ||
  fail "origin must have one push URL for $identity"
export GH_HOST=$host

# Prefix each page before gh-axi renders it, then decode the full JSON locally.
api() {
  local output
  output=$(gh-axi api "$@" --full --jq '"FMJSON:" + tojson') || return
  printf '%s\n' "$output" | jq -R '
    if startswith("FMJSON:") then ltrimstr("FMJSON:") | fromjson
    else error("invalid GitHub API output") end'
}
account=$(api /user | jq -er '.login | select(test("^[A-Za-z0-9][A-Za-z0-9-]*$"))')
account=$(printf '%s' "$account" | tr '[:upper:]' '[:lower:]')
batch_root="$data/batches/$host/$repo/$account"
ledger="$batch_root/ledger.json"
empty='{"queue":[],"batches":[]}'
records=$empty
if [ "$action" != status ]; then
  [ "$action" = check ] || fm_require_session_lock "$state" "manage a batch pull request"
  if [ "$action" = merge ]; then
    fm_lease_forbid_branch "batch merge (fm-batch)" --away-relocated
  elif [ "$action" != check ]; then
    fm_lease_forbid_branch "batch publication (fm-batch)"
  fi
  mkdir -p -- "$batch_root"
  lock="$batch_root/.lock"
  fm_lock_acquire_wait "$lock"
  unset temporary
  trap 'if [ -n "${temporary:-}" ]; then unlink "$temporary" || true; fi; if [ -n "${check_dir:-}" ]; then rm -rf -- "$check_dir" || true; fi; fm_lock_release "$lock"' EXIT
  trap 'exit 1' HUP INT TERM
fi
if [ -e "$ledger" ] || [ -L "$ledger" ]; then
  [ -f "$ledger" ] && [ ! -L "$ledger" ] || fail "batch ledger is not a regular file"
  records=$(jq -ec 'select((.queue | type) == "array" and (.batches | type) == "array")' "$ledger")
fi
if [ "$action" = status ]; then
  jq . <<< "$records"
  exit 0
fi

save() {
  records=$(jq -ce "$@" <<< "$records")
  temporary=$(mktemp "$batch_root/.ledger.XXXXXX")
  printf '%s\n' "$records" > "$temporary"
  mv -f -- "$temporary" "$ledger"
  unset temporary
}

checked_member() {
  local task=$1 checked=$2 meta branch pinned ref
  if ! fm_pr_task_id_valid "$task" || ! fm_pr_head_valid "$checked"; then
    fail "invalid task ID or checked head"
  fi
  meta="$state/$task.meta"
  [ -f "$meta" ] && [ ! -L "$meta" ] || fail "missing task metadata for $task"
  [ "$(fm_dod_meta_value "$meta" kind)" = ship ] &&
    [ "$(fm_dod_meta_value "$meta" mode)" = local-only ] &&
    [ "$(fm_backlog_canonical_existing "$(fm_dod_meta_value "$meta" project)")" = "$project" ] &&
    [ -z "$(fm_dod_meta_value "$meta" pr)" ] ||
    fail "$task must be an unpublished local-only ship for $name"
  pinned=$(fm_dod_local_done_head "$meta") || fail "$task has no recorded ready head"
  branch=$(fm_dod_meta_value "$meta" branch)
  git check-ref-format "refs/heads/$branch" ||
    fail "$task has an invalid branch"
  ref=$(git_project rev-parse --verify "refs/heads/$branch^{commit}")
  [ "$ref" = "$checked" ] && [ "$pinned" = "$checked" ] ||
    fail "$task's branch and recorded ready head must both match $checked"
  jq -nc --arg task "$task" --arg branch "$branch" --arg head "$checked" \
    '{task:$task, branch:$branch, head:$head}'
}

# Configured checks run in a temporary detached checkout of one commit.
check_dir=
checkout_commit() {
  check_dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-batch-check.XXXXXX") || fail "cannot create a check directory"
  git clone --quiet --shared --no-checkout -- "$project" "$check_dir/checkout" ||
    fail "cannot clone $name for a check"
  git -C "$check_dir/checkout" -c core.hooksPath=/dev/null checkout --quiet --detach "$1" ||
    fail "cannot check out $1 for a check"
}
drop_checkout() {
  rm -rf -- "$check_dir"
  check_dir=
}
# The watcher reads only stdout, so a check failure is also printed there.
check_fail() {
  if [ "$action" = check ]; then printf 'error: %s\n' "$*"; fi
  fail "$*"
}
# Set check_path to the absolute path of a configured check script, or empty.
find_check() {
  check_path=$1
  if [ ! -e "$check_path" ] && [ ! -L "$check_path" ]; then
    check_path=
    return 0
  fi
  [ -f "$check_path" ] && [ ! -L "$check_path" ] && [ -r "$check_path" ] ||
    check_fail "$check_path must be a readable regular file"
  case "$check_path" in /*) ;; *) check_path="$PWD/$check_path" ;; esac
}

check_batch_head() {
  local rc=0
  find_check "$config/batch-checks/$name"
  [ -n "$check_path" ] || return 0
  checkout_commit "$1"
  (cd "$check_dir/checkout" && FM_BATCH_HEAD="$1" bash "$check_path") > "$check_dir/output" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$action" = check ]; then cat -- "$check_dir/output"; else cat -- "$check_dir/output" >&2; fi
    drop_checkout
    check_fail "pre-publish check failed for $1 (exit $rc)"
  fi
  drop_checkout
}

# Run the project's heavy task check at one ready head. Set check_rc to 0 when
# it passed, 75 while it still runs elsewhere, or 1 after reporting a failure.
task_check() {
  local task=$1 head=$2 branch=$3
  check_rc=0
  find_check "$config/batch-task-checks/$name"
  [ -n "$check_path" ] || return 0
  checkout_commit "$head"
  (cd "$check_dir/checkout" &&
    FM_TASK_ID="$task" FM_TASK_HEAD="$head" FM_TASK_BRANCH="$branch" bash "$check_path") \
    > "$check_dir/output" 2>&1 || check_rc=$?
  case "$check_rc" in
    0|75) ;;
    *)
      if [ "$action" = check ]; then
        printf 'heavy check failed for %s at %s (exit %s)\n' "$task" "$head" "$check_rc"
        cat -- "$check_dir/output"
      else
        cat -- "$check_dir/output" >&2
        printf 'error: heavy check failed for %s at %s (exit %s)\n' "$task" "$head" "$check_rc" >&2
      fi
      check_rc=1
      ;;
  esac
  drop_checkout
}

# Queue a checked member once its heavy check passes; otherwise record why it waits.
# shellcheck disable=SC2016 # jq binds the member.
admit() {
  local member=$1
  task_check "$(jq -r '.task' <<< "$member")" "$(jq -r '.head' <<< "$member")" \
    "$(jq -r '.branch' <<< "$member")"
  case "$check_rc" in
    0)
      save --argjson member "$member" '
        .checks = ((.checks // []) | map(select(.task != $member.task))) |
        .queue += [$member] | .excluded = ((.excluded // []) - [$member.task])'
      ;;
    75)
      save --argjson member "$member" '
        .checks = ((.checks // []) | map(select(.task != $member.task))) + [$member + {state:"running"}]'
      ;;
    *)
      save --argjson member "$member" '
        .checks = ((.checks // []) | map(select(.task != $member.task))) + [$member + {state:"failed"}]'
      ;;
  esac
}

# Ask each running heavy check again. A task whose ready head moved drops its
# entry, so the next discovery checks the new head.
# shellcheck disable=SC2016 # jq binds the entry.
poll_task_checks() {
  local entry member
  while IFS= read -r entry; do
    if member=$(checked_member "$(jq -r '.task' <<< "$entry")" "$(jq -r '.head' <<< "$entry")" 2>/dev/null); then
      admit "$member"
    else
      save --argjson entry "$entry" '.checks -= [$entry]'
    fi
  done < <(jq -c '(.checks // [])[] | select(.state == "running")' <<< "$records")
}

# shellcheck disable=SC2016 # jq binds the task and member variables.
if [ "$action" = dequeue ]; then
  fm_pr_task_id_valid "$1" || fail "invalid task ID"
  save --arg task "$1" '
    if any(.queue[], (.checks // [])[]; .task == $task) then
      (.queue |= map(select(.task != $task))) |
      .checks = ((.checks // []) | map(select(.task != $task))) |
      .excluded = ((.excluded // []) + [$task] | unique)
    else . end'
  exit 0
elif [ "$action" = enqueue ] || [ "$action" = fix ]; then
  member=$(checked_member "$1" "$2")
  if [ "$action" = enqueue ]; then
    existing=$(jq -c --arg task "$1" '
      first((.queue[], (.batches[] | select(.state != "merged") | .members[])) |
        select(.task == $task)) // null' <<< "$records")
    if [ "$existing" != null ]; then
      [ "$existing" = "$member" ] || fail "$1 already has a different checked head"
      exit 0
    fi
    landed_member=$(jq -c --arg task "$1" '
      last(.batches[] | select(.state == "merged") | .members[] |
        select(.task == $task)) // null' <<< "$records")
    if [ "$landed_member" != null ]; then
      [ "$landed_member" != "$member" ] || exit 0
      landed_head=$(jq -er '.head' <<< "$landed_member")
      if ! fm_pr_head_valid "$landed_head" ||
        [ "$(jq -er '.branch' <<< "$landed_member")" != "$(jq -er '.branch' <<< "$member")" ] ||
        ! git_project merge-base --is-ancestor "$landed_head" "$2"; then
        fail "$1 must advance its latest merged batch member on the same branch"
      fi
    fi
    admit "$member"
    case "$check_rc" in
      0) exit 0 ;;
      75)
        printf '%s waits for its heavy check; run queues it once the check passes\n' "$1"
        exit 0
        ;;
      *) exit 1 ;;
    esac
  fi
  existing=$(jq -c --arg task "$1" '[.queue[], .batches[].members[]] | map(select(.task == $task)) | first // null' <<< "$records")
fi

discover_ready() {
  local meta task status line branch worktree sha candidate
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    [ "$(fm_dod_meta_value "$meta" kind)" = ship ] &&
      [ "$(fm_dod_meta_value "$meta" mode)" = local-only ] &&
      [ "$(fm_backlog_canonical_existing "$(fm_dod_meta_value "$meta" project)")" = "$project" ] || continue
    task=${meta##*/}
    task=${task%.meta}
    fm_pr_task_id_valid "$task" || continue
    # shellcheck disable=SC2016 # jq binds the task ID.
    jq -e --arg task "$task" '
      ((.excluded // []) | index($task)) != null or
      any(.queue[], .batches[].members[]; .task == $task)' <<< "$records" >/dev/null && continue
    status="$state/$task.status"
    [ -f "$status" ] && [ ! -L "$status" ] || continue
    line=$(status_current_line "$status" ship) || continue
    branch=$(fm_dod_meta_value "$meta" branch)
    [ "$(status_line_verb "$line")" = "done" ] &&
      [ "$(status_line_note "$line")" = "ready in branch $branch" ] || continue
    if ! sha=$(fm_dod_local_done_head "$meta"); then
      worktree=$(fm_dod_meta_value "$meta" worktree)
      fm_dod_accept_ship_done ship local-only "$worktree" "$project" "$line" "$state" "$task" "$meta" >/dev/null || continue
      sha=$(fm_dod_local_done_head "$meta") || continue
    fi
    candidate=$(checked_member "$task" "$sha" 2>/dev/null) || continue
    # A heavy check recorded for this exact head is polled or kept out instead.
    # shellcheck disable=SC2016 # jq binds the candidate.
    jq -e --argjson candidate "$candidate" '
      any((.checks // [])[]; .task == $candidate.task and .head == $candidate.head)
    ' <<< "$records" >/dev/null && continue
    admit "$candidate"
  done
}
if [ "$action" = check ] || [ "$action" = run ]; then
  poll_task_checks
fi
if [ "$action" = check ]; then
  discover_ready
fi

# The ledger holds at most two unmerged batches: the open batch, based on the
# default branch, and one batch stacked on the open batch's head.
unmerged=$(jq -c '[.batches | to_entries[] | select(.value.state != "merged") | .key]' <<< "$records")
# shellcheck disable=SC2016 # jq binds the batch count.
jq -e --argjson total "$(jq '.batches | length' <<< "$records")" '
  length <= 2 and (length == 0 or .[-1] == $total - 1) and (length < 2 or .[0] == $total - 2)
' <<< "$unmerged" >/dev/null || fail "the batch ledger has an unexpected set of unmerged batches"
lower=$(jq -r '.[0] // empty' <<< "$unmerged")
upper=$(jq -r '.[1] // empty' <<< "$unmerged")
bidx='' id='' branch='' base='' head='' published='' url='' number=''
stacked_on='' stacked_head='' retarget_from='' alt_base='' checked_heads=''

# Load one ledger batch into the working variables and validate it.
# shellcheck disable=SC2016 # jq binds the index and IDs.
load_batch() {
  local batch below
  bidx=$1
  batch=$(jq -c --argjson i "$bidx" '.batches[$i]' <<< "$records")
  id=$(jq -r '.id' <<< "$batch")
  branch=$(jq -r '.branch' <<< "$batch")
  base=$(jq -r '.base' <<< "$batch")
  head=$(jq -r '.head' <<< "$batch")
  published=$(jq -r '.published' <<< "$batch")
  url=$(jq -r '.url' <<< "$batch")
  number=$(jq -r '.number' <<< "$batch")
  stacked_on=$(jq -r '.stacked_on // ""' <<< "$batch")
  stacked_head=$(jq -r '.stacked_head // ""' <<< "$batch")
  retarget_from=$(jq -r '.retarget_from // ""' <<< "$batch")
  fm_pr_task_id_valid "$id" || fail "invalid batch ID"
  case "$branch" in "fm/batch/$account/"*) ;; *) fail "invalid recorded batch branch" ;; esac
  if ! git check-ref-format "refs/heads/$branch" || ! git check-ref-format "refs/heads/$base"; then
    fail "invalid recorded batch branch or base"
  fi
  fm_pr_head_valid "$head" || fail "invalid recorded batch head"
  if [ -n "$published" ]; then
    fm_pr_head_valid "$published" || fail "invalid published batch head"
  fi
  if [ -n "$url" ]; then
    fm_pr_url_parse "$url" && [ "$FM_PR_NUMBER" = "$number" ] ||
      fail "invalid recorded batch pull request"
  fi
  alt_base=$retarget_from
  if [ -n "$alt_base" ]; then
    git check-ref-format "refs/heads/$alt_base" || fail "invalid recorded batch base"
  fi
  if [ -n "$stacked_on" ]; then
    fm_pr_head_valid "$stacked_head" || fail "invalid recorded stacked head"
    below=$(jq -ce --argjson i "$((bidx - 1))" --arg id "$stacked_on" --arg base "$base" '
      if $i >= 0 then .batches[$i] | select(.id == $id and .branch == $base) else empty end
    ' <<< "$records") || fail "stacked batch $id does not follow the batch it is stacked on"
    # GitHub may move the pull request itself once the lower batch lands.
    if [ "$(jq -r '.state' <<< "$below")" = merged ]; then
      alt_base=$(jq -r '.base' <<< "$below")
    fi
  fi
}

read_pull() {
  local pull=$1
  jq -e --arg account "$account" --arg repo "$repo" --arg branch "$branch" \
    --arg base "$base" --arg alt "$alt_base" --arg url "$url" --arg head "$head" --arg published "$published" '
    (.user.login | ascii_downcase) == $account and
    (.head.repo.full_name | ascii_downcase) == $repo and
    (.base.repo.full_name | ascii_downcase) == $repo and
    .head.ref == $branch and (.base.ref == $base or ($alt != "" and .base.ref == $alt)) and
    ($url == "" or .html_url == $url) and
    (.head.sha == $head or (.state == "open" and .head.sha == $published))
  ' <<< "$pull" >/dev/null || fail "pull request identity or head differs from the recorded batch"
  url=$(jq -er '.html_url' <<< "$pull")
  number=$(jq -er '.number | select(type == "number" and . > 0)' <<< "$pull")
  fm_pr_url_parse "$url" &&
    [ "$FM_PR_HOST" = "$host" ] && [ "$(printf '%s' "$FM_PR_PATH" | tr '[:upper:]' '[:lower:]')" = "$repo" ] &&
    [ "$FM_PR_NUMBER" = "$number" ] || fail "GitHub returned an unexpected pull request URL"
}

remember_merge() {
  local landed
  landed=$(jq -er '.merge_commit_sha' <<< "$pull")
  fm_pr_head_valid "$landed" || fail "$url has no valid merge commit"
  # shellcheck disable=SC2016 # jq binds the exact landed commit.
  save --argjson i "$bidx" --arg landed "$landed" '.batches[$i] |= (.state = "merged" | .merged_commit = $landed)'
}

# Read the loaded batch's pull request. Record a merge, or refuse a closed one.
sync_batch() {
  landed_now=
  [ -n "$url" ] || return 0
  pull=$(api "/repos/$repo/pulls/$number")
  read_pull "$pull"
  if jq -e '.merged == true' <<< "$pull" >/dev/null; then
    # shellcheck disable=SC2016 # jq binds the lower batch's branch.
    if [ -n "$stacked_on" ] && jq -e --arg base "$base" '.base.ref == $base' <<< "$pull" >/dev/null; then
      fail "$url merged into $base instead of the default branch"
    fi
    remember_merge
    printf 'merged %s\n' "$url"
    landed_now=1
  elif [ "$action" != release ]; then
    jq -e '.state == "open"' <<< "$pull" >/dev/null || fail "reopen $url to continue its batch"
  fi
}

# Read after every forge write. Retain the planned head before publishing so
# a failed response can be retried without selecting a different set of tasks.
while [ -n "$lower" ]; do
  load_batch "$lower"
  sync_batch
  [ -n "$landed_now" ] || break
  [ "$action" != merge ] || exit 0
  lower=$upper upper=
done

if [ "$action" = release ]; then
  landed_batch=$(jq -ce '.batches | map(select(.state == "merged")) | last' <<< "$records") ||
    fail "no landed batch for $name"
  landed=$(jq -er '.merged_commit' <<< "$landed_batch")
  fm_pr_head_valid "$landed" || fail "no exact merge commit recorded for $name"
  release_ref="refs/heads/$1"
  git check-ref-format "$release_ref" &&
    [ "$1" != "$(jq -r '.base' <<< "$landed_batch")" ] || fail "invalid release branch"
  git_project fetch --quiet --no-write-fetch-head origin "$landed"
  [ "$(git_project cat-file -t "$landed")" = commit ] || fail "merge object is not a commit"
  if [ "$(git_project rev-parse --verify --quiet "$release_ref" || true)" != "$landed" ]; then
    git_project update-ref "$release_ref" "$landed" ""
  fi
  printf '%s %s\n' "$1" "$landed"
  exit 0
fi

if [ "$action" = merge ]; then
  [ -n "$lower" ] && [ -n "$url" ] && [ "$head" = "$published" ] ||
    fail "publish the batch before merging"
  [ -z "$stacked_on" ] && [ -z "$retarget_from" ] ||
    fail "run must move $url onto the default branch before merging"
  if [ "$1" != "$head" ] && [ -n "$upper" ] &&
    [ "$1" = "$(jq -r --argjson i "$upper" '.batches[$i].head' <<< "$records")" ]; then
    fail "merge $url first; the batch stacked on it lands after it"
  fi
  fm_pr_head_valid "$1" && [ "$1" = "$head" ] || fail "reviewed head differs from the published batch"
  merge_dir="$state/.batch-merges"
  mkdir -p -- "$merge_dir"
  meta="$merge_dir/$id.meta"
  members=$(jq -c --argjson i "$bidx" '.batches[$i].members' <<< "$records")
  (
    control="$state/.control-$id.lock"
    fm_lock_acquire_wait "$control"
    trap 'if [ -n "${temporary:-}" ]; then unlink "$temporary" || true; fi; fm_lock_release "$control"' EXIT
    if [ -e "$meta" ] || [ -L "$meta" ]; then
      fm_backlog_record_present "$meta" "batch merge record" "$state" &&
        [ "$(fm_dod_meta_value "$meta" kind)" = batch ] &&
        [ "$(fm_dod_meta_value "$meta" pr)" = "$url" ] || fail "batch task ID is already in use"
    fi
    temporary=$(mktemp "$merge_dir/.batch-meta.XXXXXX")
    {
      printf 'kind=batch\nproject=%s\nbatch_head=%s\n' "$project" "$head"
      jq -r '.[] | "batch_member=\(.task) \(.head)"' <<< "$members"
      printf 'pr=%s\n' "$url"
    } > "$temporary"
    fm_backlog_record_publish "$temporary" "$meta" "batch merge record" "$state"
    unset temporary
  )
  "$dir/fm-pr-merge.sh" "$id" "$url" --expected-head "$head"
  pull=$(api "/repos/$repo/pulls/$number")
  read_pull "$pull"
  if jq -e '.merged == true' <<< "$pull" >/dev/null; then
    remember_merge
  fi
  exit 0
fi

if [ -n "$upper" ]; then
  load_batch "$upper"
  sync_batch
  [ -z "$landed_now" ] || fail "$url landed before the batch it is stacked on"
fi

current_base_head() {
  local base_ref sha
  git check-ref-format "refs/heads/$base"
  base_ref=$(git_project ls-remote --exit-code origin "refs/heads/$base")
  sha=${base_ref%%$'\t'*}
  fm_pr_head_valid "$sha" && [ "${base_ref#*$'\t'}" = "refs/heads/$base" ] ||
    fail "cannot resolve the current head of $base"
  git_project fetch --quiet --no-write-fetch-head origin "$sha"
  printf '%s\n' "$sha"
}

add_commit() {
  local parent=$1 commit=$2 label=$3 landed_head=${4:-} tree
  local merge_args=(--write-tree)
  if git_project merge-base --is-ancestor "$commit" "$parent"; then
    printf '%s\n' "$parent"
    return
  fi
  # A squash can land changes without retaining the commit that carried them.
  if [ -n "$landed_head" ] &&
    { ! git_project merge-base --is-ancestor "$landed_head" "$parent" ||
      ! git_project merge-base --is-ancestor "$landed_head" "$commit"; }; then
    merge_args+=(--merge-base="$landed_head")
  fi
  tree=$(git_project merge-tree "${merge_args[@]}" "$parent" "$commit") ||
    fail "cannot add $label to the batch: $tree"
  tree=${tree%%$'\n'*}
  git_project commit-tree "$tree" -p "$parent" -p "$commit" -m "Batch: $label"
}

# Record a new head for the loaded batch after its pre-publish check passes.
# shellcheck disable=SC2016 # jq binds the index and head.
advance_batch() {
  check_batch_head "$1"
  checked_heads="$checked_heads $1"
  git_project update-ref "refs/firstmate/batches/$id" "$1"
  save --argjson i "$bidx" --arg head "$1" '.batches[$i].head = $head'
  head=$1
}

# Move a stacked batch onto the default branch once the batch below it landed.
# GitHub squashes that batch, so its merge commit is never an ancestor of this
# head. Keep the tested head, and its CI result, only when the default branch
# holds exactly the landed tree this batch was built on. Otherwise merge the
# default branch in, which needs fresh checks.
# shellcheck disable=SC2016 # jq binds the index, base and source branch.
promote_batch() {
  local below below_base below_head default start merge_base next
  below=$(jq -c --argjson i "$((bidx - 1))" '.batches[$i]' <<< "$records")
  below_base=$(jq -r '.base' <<< "$below")
  below_head=$(jq -r '.head' <<< "$below")
  default=$(api "/repos/$repo" | jq -er '.default_branch')
  [ "$default" = "$below_base" ] || fail "default branch changed from $below_base to $default"
  retarget_from=$base
  base=$default
  alt_base=$retarget_from
  start=$(current_base_head)
  if [ "$stacked_head" != "$below_head" ] ||
    [ "$start" != "$(jq -r '.merged_commit' <<< "$below")" ] ||
    [ "$(git_project rev-parse "$start^{tree}")" != "$(git_project rev-parse "$stacked_head^{tree}")" ]; then
    merge_base=$below_head
    # If the lower batch advanced before the upper batch could follow it,
    # use the older base so the changes the upper batch missed are kept.
    if [ "$stacked_head" != "$below_head" ] &&
      ! git_project merge-base --is-ancestor "$below_head" "$head"; then
      merge_base=$stacked_head
    fi
    next=$(add_commit "$head" "$start" "$base" "$merge_base")
    advance_batch "$next"
  fi
  save --argjson i "$bidx" --arg base "$base" --arg from "$retarget_from" '
    .batches[$i] |= (.base = $base | .retarget_from = $from | del(.stacked_on, .stacked_head))'
  stacked_on='' stacked_head=''
}

# Plan a batch from the queue on top of a start commit.
# shellcheck disable=SC2016 # jq binds the batch fields.
plan_batch() {
  local start=$1 on_branch=$2 below_id=$3 next item serial repo_key
  next=$start
  while IFS= read -r item; do
    next=$(add_commit "$next" "$(jq -er '.head' <<< "$item")" "$(jq -er '.task' <<< "$item")" \
      "$(jq -r '.landed_head' <<< "$item")")
  done < <(jq -c '
    (reduce (.batches[] | select(.state == "merged") | .members[]) as $member
      ({}; .[$member.task] = $member.head)) as $landed |
    .queue[] | . + {landed_head: ($landed[.task] // "")}
  ' <<< "$records")
  [ "$next" != "$start" ] &&
    [ "$(git_project rev-parse "$next^{tree}")" != "$(git_project rev-parse "$start^{tree}")" ] ||
    fail "the queued tasks add no changes to $on_branch"
  check_batch_head "$next"
  checked_heads="$checked_heads $next"
  serial=$(jq '.batches | length + 1' <<< "$records")
  repo_key=$(printf '%s\n' "$identity/$account" | fm_role_sha256_stdin)
  id="batch-${repo_key:0:16}-${next:0:12}-$serial"
  git_project update-ref "refs/firstmate/batches/$id" "$next"
  save --arg id "$id" --arg branch "fm/batch/$account/$serial-${next:0:12}" --arg base "$on_branch" \
    --arg head "$next" --arg below "$below_id" --arg start "$start" '
    .batches += [{id:$id, branch:$branch, base:$base, head:$head, published:"", state:"planned",
      url:"", number:"", members:.queue} +
      (if $below == "" then {} else {stacked_on:$below, stacked_head:$start} end)] | .queue = []'
  load_batch "$((serial - 1))"
}

# Push the loaded batch and open or update its pull request, then move a
# promoted batch's pull request onto the default branch.
# shellcheck disable=SC2016 # jq binds the pull request fields.
publish_batch() {
  local query_head pulls serial body below_url
  if [ "$head" != "$published" ]; then
    if [ -z "$url" ]; then
      query_head=$(jq -rn --arg head "${repo%%/*}:$branch" '$head | @uri')
      pulls=$(api "/repos/$repo/pulls?state=open&head=$query_head&per_page=100" --paginate |
        jq -sc --arg branch "$branch" 'add // [] | map(select(.head.ref == $branch))')
      case "$(jq 'length' <<< "$pulls")" in
        0) ;;
        1)
          pull=$(jq -c '.[0]' <<< "$pulls")
          read_pull "$pull"
          ;;
        *) fail "multiple open pull requests match batch branch $branch in $repo" ;;
      esac
    fi
    # Push without force. A lost response can be retried at the same head.
    [ "$action" != check ] || check_opt_in || exit 0
    case " $checked_heads " in *" $head "*) ;; *) check_batch_head "$head" ;; esac
    git_project push --quiet --no-follow-tags --recurse-submodules=no origin "$head:refs/heads/$branch"
    if [ -z "$url" ]; then
      serial=$((bidx + 1))
      body=$(jq -r --argjson i "$bidx" '.batches[$i].members[] | "- \(.task) (\(.branch))"' <<< "$records")
      if [ -n "$stacked_on" ]; then
        below_url=$(jq -r --argjson i "$((bidx - 1))" '.batches[$i].url' <<< "$records")
        body="$body"$'\n\n'"Stacked on $below_url, which lands first."
        body="$body"$'\n'"After it lands, this pull request moves onto $(jq -r --argjson i "$((bidx - 1))" '.batches[$i].base' <<< "$records") and its diff may also list that batch's squashed changes."
      fi
      pull=$(api POST "/repos/$repo/pulls" --raw-field "title=Batch $account / $serial" \
        --raw-field "base=$base" --raw-field "head=$branch" --raw-field "body=$body")
    else
      pull=$(api "/repos/$repo/pulls/$number")
    fi
    read_pull "$pull"
    jq -e --arg head "$head" '.state == "open" and .head.sha == $head' <<< "$pull" >/dev/null ||
      fail "$url has not reported the planned head yet"
    save --argjson i "$bidx" --arg url "$url" --arg number "$number" --arg head "$head" '
      .batches[$i] |= (.url = $url | .number = $number | .published = $head | .state = "open")'
    published=$head
    if [ "$action" = check ]; then
      if [ -n "$stacked_on" ]; then
        printf 'published %s stacked on %s\n' "$url" "$(jq -r --argjson i "$((bidx - 1))" '.batches[$i].url' <<< "$records")"
      else
        printf 'published %s\n' "$url"
      fi
    fi
  fi
  [ -n "$retarget_from" ] || return 0
  pull=$(api "/repos/$repo/pulls/$number")
  read_pull "$pull"
  if ! jq -e --arg base "$base" '.base.ref == $base' <<< "$pull" >/dev/null; then
    pull=$(api PATCH "/repos/$repo/pulls/$number" --raw-field "base=$base")
    read_pull "$pull"
    jq -e --arg base "$base" '.base.ref == $base' <<< "$pull" >/dev/null ||
      fail "$url still targets $retarget_from"
  fi
  save --argjson i "$bidx" '.batches[$i] |= del(.retarget_from)'
  retarget_from='' alt_base=''
  if [ "$action" = check ]; then printf 'moved %s onto %s\n' "$url" "$base"; fi
}

promoted_from_published=
if [ -n "$lower" ]; then
  load_batch "$lower"
  if [ -n "$stacked_on" ]; then
    if [ "$head" = "$published" ]; then promoted_from_published=$id; fi
    promote_batch
  fi
fi

# shellcheck disable=SC2016 # jq binds the head and membership variables.
if [ "$action" = refresh ]; then
  [ -n "$lower" ] && [ -n "$url" ] || fail "refresh requires an open batch"
  if [ "$head" = "$published" ]; then
    default_branch=$(api "/repos/$repo" | jq -er '.default_branch')
    [ "$default_branch" = "$base" ] || fail "default branch changed from $base to $default_branch"
    next=$(add_commit "$head" "$(current_base_head)" "$base")
    [ "$next" = "$head" ] || advance_batch "$next"
  fi
elif [ "$action" = fix ]; then
  # A member returns to its own batch. A new task joins the stacked batch only
  # when it is built on that batch's head; otherwise it joins the open batch.
  target=$lower
  if [ -n "$upper" ]; then
    if jq -e --argjson i "$upper" --arg task "$1" 'any(.batches[$i].members[]; .task == $task)' \
      <<< "$records" >/dev/null; then
      target=$upper
    elif ! jq -e --argjson i "$lower" --arg task "$1" 'any(.batches[$i].members[]; .task == $task)' \
      <<< "$records" >/dev/null &&
      git_project merge-base --is-ancestor "$(jq -r --argjson i "$upper" '.batches[$i].head' <<< "$records")" "$2"; then
      target=$upper
    fi
  fi
  [ -n "$target" ] || fail "fix requires an open batch"
  load_batch "$target"
  [ -n "$url" ] || fail "fix requires an open batch"
  previous=$(jq -c --argjson i "$bidx" --arg task "$1" 'first(.batches[$i].members[] | select(.task == $task)) // null' <<< "$records")
  if [ "$previous" != "$member" ]; then
    # A promotion in this invocation can be published together with the fix.
    [ "$head" = "$published" ] || [ "$id" = "$promoted_from_published" ] ||
      fail "run must finish publishing the current batch update first"
    if [ "$previous" != null ]; then
      old=$(jq -er '.head' <<< "$previous")
      if ! fm_pr_head_valid "$old" ||
        [ "$(jq -er '.branch' <<< "$previous")" != "$(jq -er '.branch' <<< "$member")" ] ||
        ! git_project merge-base --is-ancestor "$old" "$2"; then
        fail "$1 must advance its existing batch member on the same branch"
      fi
    else
      [ "$existing" = null ] ||
        jq -e --argjson member "$member" '.queue | index($member) != null' <<< "$records" >/dev/null ||
        fail "$1 already has a different checked head or belongs to another batch"
    fi
    task_check "$1" "$2" "$(jq -r '.branch' <<< "$member")"
    case "$check_rc" in
      0) ;;
      75) fail "the heavy check for $1 at $2 is still running; repeat the fix once it passes" ;;
      *) exit 1 ;;
    esac
    if git_project merge-base --is-ancestor "$head" "$2"; then
      next=$2
    else
      next=$(add_commit "$head" "$2" "$1")
    fi
    [ "$next" != "$head" ] || fail "$1 adds no commits to the batch"
    advance_batch "$next"
    save --argjson i "$bidx" --argjson member "$member" --argjson previous "$previous" '
      .queue -= [$member] | .checks = ((.checks // []) | map(select(.task != $member.task))) |
      .batches[$i].members |=
        if $previous == null then . + [$member]
        else map(if . == $previous then $member else . end) end'
  fi
fi

# Publish the open batch, then rebuild the stacked batch on its current head.
if [ -n "$lower" ]; then
  load_batch "$lower"
  publish_batch
fi
if [ -n "$upper" ]; then
  lower_id=$id lower_head=$head
  load_batch "$upper"
  if [ "$stacked_head" != "$lower_head" ]; then
    next=$(add_commit "$head" "$lower_head" "batch $lower_id")
    advance_batch "$next"
    # shellcheck disable=SC2016 # jq binds the index and lower head.
    save --argjson i "$bidx" --arg on "$lower_head" '.batches[$i].stacked_head = $on'
    stacked_head=$lower_head
  fi
  publish_batch
fi

# Assemble waiting tasks: on the default branch when no batch is open, or on
# the open batch's published head when nothing is stacked on it yet.
if { [ "$action" = run ] || [ "$action" = check ]; } && [ -z "$upper" ] &&
  jq -e '.queue | length > 0' <<< "$records" >/dev/null; then
  if [ -z "$lower" ]; then
    base=$(api "/repos/$repo" | jq -er '.default_branch')
    plan_batch "$(current_base_head)" "$base" ""
    publish_batch
  elif [ -n "$url" ] && [ "$head" = "$published" ] && [ -z "$retarget_from" ]; then
    plan_batch "$head" "$branch" "$id"
    publish_batch
  fi
fi

if [ "$action" != check ]; then
  jq -r '.batches[] | select(.state != "merged" and .url != "") | .url' <<< "$records"
fi
