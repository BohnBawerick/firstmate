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
# task must have recorded a local-only ready head in this home. Run publishes
# the waiting tasks against the current default branch or resumes a prior
# publish. While a batch is open, run leaves later tasks queued. Fix adds
# one checked task to the open batch or updates an existing member after
# fm-ready-head.sh records its revised head. A task branch based on the
# current batch head advances the batch directly. The optional
# config/batch-checks/<project> runs against the assembled head before push.
# After a merge, run can publish the next batch. A closed, unmerged batch
# needs to be reopened before it can proceed.
# If a queued task conflicts, dequeue it before retrying. Its branch is kept.
# Refresh merges the current default into the open batch if the merge gate
# reports that it is behind. The updated head needs its own green checks.
# Release starts a local branch at GitHub's exact merge commit for the latest
# landed batch. The same step applies to a batch with one task.
#
# Merge requires the same approval or standing authority as fm-pr-merge.sh.
# Use the reviewed head from status. The merge gate checks the live head, CI,
# and each member's hold. Status prints the durable queue and batch history,
# including task IDs, branch names, checked heads, and pull request URLs.
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
  trap 'if [ -n "${temporary:-}" ]; then unlink "$temporary" || true; fi; fm_lock_release "$lock"' EXIT
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

# shellcheck disable=SC2016 # jq binds the task and member variables.
if [ "$action" = dequeue ]; then
  fm_pr_task_id_valid "$1" || fail "invalid task ID"
  save --arg task "$1" '
    if any(.queue[]; .task == $task) then
      (.queue |= map(select(.task != $task))) | .excluded = ((.excluded // []) + [$task] | unique)
    else . end'
  exit 0
elif [ "$action" = enqueue ] || [ "$action" = fix ]; then
  member=$(checked_member "$1" "$2")
  existing=$(jq -c --arg task "$1" '[.queue[], .batches[].members[]] | map(select(.task == $task)) | first // null' <<< "$records")
  if [ "$action" = enqueue ]; then
    if [ "$existing" != null ]; then
      [ "$existing" = "$member" ] || fail "$1 already has a different checked head"
      exit 0
    fi
    save --argjson member "$member" '
      .queue += [$member] | .excluded = ((.excluded // []) - [$member.task])'
    exit 0
  fi
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
    # shellcheck disable=SC2016 # jq binds the ready queue entry.
    save --argjson candidate "$candidate" '.queue += [$candidate]'
  done
}
if [ "$action" = check ]; then
  discover_ready
fi

active=$(jq -c '.batches[-1] | select(. != null and .state != "merged")' <<< "$records")
if [ -n "$active" ]; then
  branch=$(jq -r '.branch' <<< "$active")
  base=$(jq -r '.base' <<< "$active")
  head=$(jq -r '.head' <<< "$active")
  published=$(jq -r '.published' <<< "$active")
  url=$(jq -r '.url' <<< "$active")
  number=$(jq -r '.number' <<< "$active")
  case "$branch" in "fm/batch/$account/"*) ;; *) fail "invalid recorded batch branch" ;; esac
  git check-ref-format "refs/heads/$branch" ||
    fail "invalid recorded batch branch or head"
  fm_pr_head_valid "$head" || fail "invalid recorded batch head"
  if [ -n "$published" ]; then
    fm_pr_head_valid "$published" || fail "invalid published batch head"
  fi
  if [ -n "$url" ]; then
    fm_pr_url_parse "$url" && [ "$FM_PR_NUMBER" = "$number" ] ||
      fail "invalid recorded batch pull request"
  fi
fi

read_pull() {
  local pull=$1
  jq -e --arg account "$account" --arg repo "$repo" --arg branch "$branch" \
    --arg base "$base" --arg url "$url" --arg head "$head" --arg published "$published" '
    (.user.login | ascii_downcase) == $account and
    (.head.repo.full_name | ascii_downcase) == $repo and
    (.base.repo.full_name | ascii_downcase) == $repo and
    .head.ref == $branch and .base.ref == $base and
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
  save --arg landed "$landed" '.batches[-1] |= (.state = "merged" | .merged_commit = $landed)'
}

# Read after every forge write. Retain the planned head before publishing so
# a failed response can be retried without selecting a different set of tasks.
if [ -n "$active" ] && [ -n "$url" ]; then
  pull=$(api "/repos/$repo/pulls/$number")
  read_pull "$pull"
  if jq -e '.merged == true' <<< "$pull" >/dev/null; then
    remember_merge
    printf 'merged %s\n' "$url"
    case "$action" in
      merge) exit 0 ;;
      fix|refresh) fail "$action requires an open batch" ;;
    esac
    active=
  elif [ "$action" != release ]; then
    jq -e '.state == "open"' <<< "$pull" >/dev/null || fail "reopen $url to continue its batch"
  fi
fi

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
  [ -n "$active" ] && [ -n "$url" ] && [ "$head" = "$published" ] ||
    fail "publish the batch before merging"
  fm_pr_head_valid "$1" && [ "$1" = "$head" ] || fail "reviewed head differs from the published batch"
  id=$(jq -r '.id' <<< "$active")
  fm_pr_task_id_valid "$id" || fail "invalid batch ID"
  merge_dir="$state/.batch-merges"
  mkdir -p -- "$merge_dir"
  meta="$merge_dir/$id.meta"
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
      jq -r '.members[] | "batch_member=\(.task) \(.head)"' <<< "$active"
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
  local parent=$1 commit=$2 label=$3 tree
  if git_project merge-base --is-ancestor "$commit" "$parent"; then
    printf '%s\n' "$parent"
    return
  fi
  tree=$(git_project merge-tree --write-tree "$parent" "$commit") ||
    fail "cannot add $label to the batch: $tree"
  tree=${tree%%$'\n'*}
  git_project commit-tree "$tree" -p "$parent" -p "$commit" -m "Batch: $label"
}

check_batch_head() (
  local check_file="$config/batch-checks/$name" candidate=$1 scratch rc=0
  [ -e "$check_file" ] || [ -L "$check_file" ] || return 0
  # The watcher captures this command's stdout for its check wake.
  if [ "$action" = check ]; then exec 2>&1; fi
  [ -f "$check_file" ] && [ ! -L "$check_file" ] && [ -r "$check_file" ] ||
    fail "$check_file must be a readable regular file"
  case "$check_file" in /*) ;; *) check_file="$PWD/$check_file" ;; esac
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-batch-check.XXXXXX")
  trap 'rm -rf -- "$scratch"' EXIT
  trap 'exit 1' HUP INT TERM
  git clone --quiet --shared --no-checkout -- "$project" "$scratch/checkout"
  git -C "$scratch/checkout" -c core.hooksPath=/dev/null checkout --quiet --detach "$candidate"
  (cd "$scratch/checkout" && FM_BATCH_HEAD="$candidate" bash "$check_file") > "$scratch/output" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    cat "$scratch/output" >&2
    fail "pre-publish check failed for $candidate (exit $rc)"
  fi
)

checked_head=
# shellcheck disable=SC2016 # jq binds the head and membership variables.
if [ "$action" = refresh ]; then
  [ -n "$active" ] && [ -n "$url" ] || fail "refresh requires an open batch"
  if [ "$head" = "$published" ]; then
    default_branch=$(api "/repos/$repo" | jq -er '.default_branch')
    [ "$default_branch" = "$base" ] || fail "default branch changed from $base to $default_branch"
    start=$(current_base_head)
    next=$(add_commit "$head" "$start" "$base")
    if [ "$next" != "$head" ]; then
      check_batch_head "$next"
      checked_head=$next
      id=$(jq -r '.id' <<< "$active")
      git_project update-ref "refs/firstmate/batches/$id" "$next"
      save --arg head "$next" '.batches[-1].head = $head'
      head=$next
    fi
  fi
elif [ "$action" = fix ]; then
  [ -n "$active" ] && [ -n "$url" ] || fail "fix requires an open batch"
  previous=$(jq -c --arg task "$1" 'first(.members[] | select(.task == $task)) // null' <<< "$active")
  if [ "$previous" != "$member" ]; then
    [ "$head" = "$published" ] || fail "run must finish publishing the current batch update first"
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
    if git_project merge-base --is-ancestor "$head" "$2"; then
      next=$2
    else
      next=$(add_commit "$head" "$2" "$1")
    fi
    [ "$next" != "$head" ] || fail "$1 adds no commits to the batch"
    check_batch_head "$next"
    checked_head=$next
    id=$(jq -r '.id' <<< "$active")
    git_project update-ref "refs/firstmate/batches/$id" "$next"
    save --argjson member "$member" --argjson previous "$previous" --arg head "$next" '
      .queue -= [$member] | .batches[-1] |= (
        .head = $head | .members |=
          if $previous == null then . + [$member]
          else map(if . == $previous then $member else . end) end)'
    head=$next
  fi
elif [ -z "$active" ]; then
  jq -e '.queue | length > 0' <<< "$records" >/dev/null || exit 0
  base=$(api "/repos/$repo" | jq -er '.default_branch')
  start=$(current_base_head)
  head=$start
  while IFS= read -r item; do
    head=$(add_commit "$head" "$(jq -er '.head' <<< "$item")" "$(jq -er '.task' <<< "$item")")
  done < <(jq -c '.queue[]' <<< "$records")
  [ "$head" != "$start" ] &&
    [ "$(git_project rev-parse "$head^{tree}")" != "$(git_project rev-parse "$start^{tree}")" ] ||
    fail "the queued tasks add no changes to $base"
  check_batch_head "$head"
  checked_head=$head
  serial=$(jq '.batches | length + 1' <<< "$records")
  repo_key=$(printf '%s\n' "$identity/$account" | fm_role_sha256_stdin)
  id="batch-${repo_key:0:16}-${head:0:12}-$serial"
  branch="fm/batch/$account/$serial-${head:0:12}"
  url='' number='' published=''
  git_project update-ref "refs/firstmate/batches/$id" "$head"
  save --arg id "$id" --arg branch "$branch" --arg base "$base" --arg head "$head" '
    .batches += [{id:$id, branch:$branch, base:$base, head:$head, published:"", state:"planned",
      url:"", number:"", members:.queue}] | .queue = []'
fi

if [ "$head" = "$published" ]; then
  [ "$action" = check ] || printf '%s\n' "$url"
  exit 0
fi

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
[ "$checked_head" = "$head" ] || check_batch_head "$head"
git_project push --quiet --no-follow-tags --recurse-submodules=no origin "$head:refs/heads/$branch"
if [ -z "$url" ]; then
  serial=$(jq '.batches | length' <<< "$records")
  body=$(jq -r '.batches[-1].members[] | "- \(.task) (\(.branch))"' <<< "$records")
  pull=$(api POST "/repos/$repo/pulls" --raw-field "title=Batch $account / $serial" \
    --raw-field "base=$base" --raw-field "head=$branch" --raw-field "body=$body")
else
  pull=$(api "/repos/$repo/pulls/$number")
fi
read_pull "$pull"
jq -e --arg head "$head" '.state == "open" and .head.sha == $head' <<< "$pull" >/dev/null ||
  fail "$url has not reported the planned head yet"
# shellcheck disable=SC2016 # jq binds the URL, number, and head.
save --arg url "$url" --arg number "$number" --arg head "$head" '
  .batches[-1] |= (.url = $url | .number = $number | .published = $head | .state = "open")'
if [ "$action" = check ]; then
  printf 'published %s\n' "$url"
else
  printf '%s\n' "$url"
fi
