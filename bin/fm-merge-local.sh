#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's immutable ship branch recorded in
# state/<task-id>.meta ("fm/<id>" for records created before that field existed).
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
# The task's existing per-task control lock serializes the captain-hold check
# through that fast-forward. A still-held or unreadable row refuses before the
# merge, so a captain approval must be recorded as an `answer --release` before
# this entrypoint is invoked. The lock ends when the fast-forward returns;
# docs/captain-hold-lifecycle.md owns the accepted merge-to-cleanup residual.
#
# For firstmate's own repository (bin/fm-self-repo-lib.sh), the landing also
# updates the fork: after the local fast-forward it pushes local default to the
# landing remote `origin` only after bin/fm-landing-remote.sh proves the remap
# and every effective origin push URL names that same remote, as a plain
# fast-forward, never forced and never anywhere else, then reads the remote
# branch back. When the task records a GitHub pr=, that PR must then read back
# merged through the same forge read bin/fm-pr-merge.sh uses, retried a bounded
# number of times while the forge catches up. A checkout with no `upstream`
# remote has no configured fork, so it reports that nothing was pushed.
# Exit status: 0 landed (and any configured fork was synced and proved);
# 3 landed locally but the fork sync or PR read-back was not proved - the local
# landing stays, and the message names why and the exact command to finish;
# any other non-zero value means nothing was landed.
# Project landings never push: local-only projects have no remote by design.
# Usage: fm-merge-local.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-self-repo-lib.sh
. "$SCRIPT_DIR/fm-self-repo-lib.sh"
# Fail closed before any fleet mutation: AGENTS.md section 3 makes a session that
# could not verify lock ownership read-only, and bin/fm-session-lock-lib.sh is
# the single owner of that verdict and its refusal.
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
fm_require_session_lock "$STATE" "merge work into local main" || exit 1
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid local merge request" >&2
  exit 2
fi
ID=$1
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
META="$STATE/$ID.meta"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness and never lands (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor). This action is deliberately NOT
# relocated under the away-posture record: unlike the PR merge it has no
# record-side grant gate of its own, so a parked main keeps it held for the
# captain's return. This precedes reading the task record, because the wrong
# actor is refused for its role whatever it says.
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)"

[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
MERGE_EXPECTED_SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN

MERGE_CONTROL_LOCK=
merge_control_cleanup() {
  [ -z "$MERGE_CONTROL_LOCK" ] || fm_lock_release "$MERGE_CONTROL_LOCK" || true
}
trap merge_control_cleanup EXIT
MERGE_CONTROL_LOCK="$STATE/.control-$ID.lock"
fm_lock_acquire_wait "$MERGE_CONTROL_LOCK"
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: task $ID changed while waiting to merge; refusing: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
if [ "$FM_BACKLOG_META_SPAWN_GEN" != "$MERGE_EXPECTED_SPAWN_GEN" ]; then
  echo "error: task $ID changed incarnation while waiting to merge; refusing" >&2
  exit 1
fi

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
PR_URL=$(grep '^pr=' "$META" | tail -n 1 | cut -d= -f2- || true)

if [ "$MODE" != "local-only" ] && ! fm_is_firstmate_repo "$PROJ" "$FM_ROOT" "$FM_HOME"; then
  echo "error: task $ID is mode=$MODE on $PROJ, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2
  exit 1
fi

[ -n "$PROJ" ] && [ -d "$PROJ" ] || { echo "error: project directory '$PROJ' does not exist" >&2; exit 1; }
git -C "$PROJ" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "error: '$PROJ' is not a git repository" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

BRANCH=$(grep '^branch=' "$META" | cut -d= -f2- || true)
[ -n "$BRANCH" ] || BRANCH="fm/$ID"
if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  echo "error: task $ID has an invalid recorded ship branch '$BRANCH'" >&2
  exit 1
fi
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
hold_status=0
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" --distinguish-absent || hold_status=$?
case "$hold_status" in
  0)
    echo "error: task $ID is still held for the captain; release it before merging" >&2
    exit 1
    ;;
  1|3) ;;
  *)
    echo "error: could not determine whether task $ID is still held for the captain; refusing to merge" >&2
    exit 1
    ;;
esac
merge_status=0
git -C "$PROJ" merge --ff-only "$BRANCH" >/dev/null || merge_status=$?
fm_lock_release "$MERGE_CONTROL_LOCK" || true
MERGE_CONTROL_LOCK=
[ "$merge_status" -eq 0 ] || exit "$merge_status"
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
# Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
[ ! -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fleet-ledger" ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-fleet-ledger.sh" merged "$ID" local || true
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"

# Firstmate's own repository also updates its landing remote, so the fork on
# the forge holds exactly what this home runs. Project landings stop here.
fm_is_firstmate_repo "$PROJ" "$FM_ROOT" "$FM_HOME" || exit 0

FORK_REMOTE=origin
LOCAL_SHA=$(git -C "$PROJ" rev-parse "refs/heads/$DEFAULT")
FINISH=$(printf 'git -C %q push %s refs/heads/%s:refs/heads/%s' "$PROJ" "$FORK_REMOTE" "$DEFAULT" "$DEFAULT")
# Never wait on a credential prompt nobody will answer.
export GIT_TERMINAL_PROMPT=0

# Report an unsynced fork and exit 3. The local landing above stays as it is.
fork_not_synced() {  # <why> [<next-step line>...]
  echo "fork not updated: local $DEFAULT landed at $after, but $FORK_REMOTE/$DEFAULT was not updated: $1" >&2
  shift
  local line
  for line in "$@"; do
    echo "$line" >&2
  done
  exit 3
}

if ! git -C "$PROJ" remote | grep -Fx upstream >/dev/null 2>&1; then
  echo "no fork is configured in $PROJ because there is no upstream remote; nothing was pushed"
  exit 0
fi
if ! upstream_url=$(git -C "$PROJ" config --local --get remote.upstream.url 2>&1) \
  || [ -z "$upstream_url" ]; then
  fork_not_synced "upstream is present but has no configured URL" \
    "Repair the remotes, then finish with: $FINISH"
fi
if ! git -C "$PROJ" remote get-url "$FORK_REMOTE" >/dev/null 2>&1; then
  fork_not_synced "$FORK_REMOTE is absent from this remapped checkout" \
    "Repair the remotes, then finish with: $FINISH"
fi
# bin/fm-landing-remote.sh owns whether origin is the landing remote rather
# than the parent we forked from; any doubt keeps the push from happening.
if ! verify_output=$("$SCRIPT_DIR/fm-landing-remote.sh" verify --repo "$PROJ" 2>&1); then
  fork_not_synced "$FORK_REMOTE is not proven to be our fork: $verify_output" \
    "Repair the remotes as described, then finish with: $FINISH"
fi
if ! push_urls=$(git -C "$PROJ" remote get-url --push --all "$FORK_REMOTE" 2>&1) \
  || [ -z "$push_urls" ]; then
  fork_not_synced "could not resolve where $FORK_REMOTE would push: $push_urls" \
    "Repair remote.$FORK_REMOTE.pushurl, then finish with: $FINISH"
fi
while IFS= read -r push_url; do
  if ! push_verify=$("$SCRIPT_DIR/fm-landing-remote.sh" verify --ours "$push_url" --repo "$PROJ" 2>&1); then
    fork_not_synced "$FORK_REMOTE would push to $push_url rather than its verified fetch URL: $push_verify" \
      "Remove or correct remote.$FORK_REMOTE.pushurl, then finish with: $FINISH"
  fi
done <<PUSH_URLS
$push_urls
PUSH_URLS
if ! remote_line=$(git -C "$PROJ" ls-remote "$FORK_REMOTE" "refs/heads/$DEFAULT" 2>&1); then
  fork_not_synced "could not read $FORK_REMOTE/$DEFAULT: $remote_line" \
    "Finish with: $FINISH"
fi
REMOTE_SHA=${remote_line%%[[:space:]]*}
if [ -n "$REMOTE_SHA" ] && [ "$REMOTE_SHA" != "$LOCAL_SHA" ]; then
  if ! git -C "$PROJ" cat-file -e "$REMOTE_SHA^{commit}" 2>/dev/null \
    && ! fetch_output=$(git -C "$PROJ" fetch --quiet "$FORK_REMOTE" "refs/heads/$DEFAULT" 2>&1); then
    fork_not_synced "could not fetch $FORK_REMOTE/$DEFAULT: $fetch_output" \
      "Finish with: $FINISH"
  fi
  if ! git -C "$PROJ" merge-base --is-ancestor "$REMOTE_SHA" "$LOCAL_SHA" 2>/dev/null; then
    fork_not_synced "it is not a fast-forward: $FORK_REMOTE/$DEFAULT is at ${REMOTE_SHA:0:8}, which local $DEFAULT does not contain" \
      "See the missing commits with: git -C $(printf '%q' "$PROJ") log --oneline $LOCAL_SHA..$REMOTE_SHA" \
      "Bring them into local $DEFAULT through a reviewed task, then finish with: $FINISH"
  fi
fi
if [ "$REMOTE_SHA" != "$LOCAL_SHA" ]; then
  # A plain refspec without "+": the remote itself refuses anything but a
  # fast-forward, even if its branch moved after the check above.
  if ! push_output=$(git -C "$PROJ" push --quiet "$FORK_REMOTE" "refs/heads/$DEFAULT:refs/heads/$DEFAULT" 2>&1); then
    fork_not_synced "the push failed: $push_output" \
      "Finish with: $FINISH"
  fi
  if ! remote_line=$(git -C "$PROJ" ls-remote "$FORK_REMOTE" "refs/heads/$DEFAULT" 2>&1) \
    || [ "${remote_line%%[[:space:]]*}" != "$LOCAL_SHA" ]; then
    fork_not_synced "the push returned, but $FORK_REMOTE/$DEFAULT does not read back as ${LOCAL_SHA:0:8}: $remote_line" \
      "Check it, and if needed finish with: $FINISH"
  fi
  echo "pushed local $DEFAULT to $FORK_REMOTE/$DEFAULT (${REMOTE_SHA:0:8} -> ${LOCAL_SHA:0:8})"
else
  echo "$FORK_REMOTE/$DEFAULT already at ${LOCAL_SHA:0:8}"
fi

# A recorded PR is proved merged by the same forge read the merge path uses.
[ -n "$PR_URL" ] || exit 0
if ! fm_pr_url_parse "$PR_URL" || [ "$FM_PR_PROVIDER" != github ]; then
  echo "$FORK_REMOTE/$DEFAULT now holds local $DEFAULT; PR state was not checked because '$PR_URL' is not a GitHub pull request"
  exit 0
fi
# The forge marks a PR merged shortly after its head reaches the base branch,
# so the read is retried a bounded number of times.
readback_attempt=1
while :; do
  FM_PR_RECORD_STATE=
  FM_PR_RECORD_MERGED=
  fm_pr_github_read_record "$FM_PR_OWNER" "$FM_PR_REPO" "$FM_PR_NUMBER" || true
  [ "$FM_PR_RECORD_MERGED" != true ] || break
  if [ "$readback_attempt" -ge 5 ]; then
    echo "error: $FORK_REMOTE/$DEFAULT now holds local $DEFAULT, but $PR_URL does not read back as merged (state=${FM_PR_RECORD_STATE:-unreadable})" >&2
    echo "Re-check that PR on the forge; the fork itself is up to date." >&2
    exit 3
  fi
  sleep 3
  readback_attempt=$((readback_attempt + 1))
done
echo "verified: $PR_URL is merged"
