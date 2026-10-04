#!/usr/bin/env bash
# Tests for bin/fm-merge-local.sh: fast-forwards the local default branch to the
# crewmate's fm/<id> branch for local-only projects and for Firstmate's own
# repository (where local main is authoritative).
#
# Matrix:
#   (a) fast-forwards a clean local-only project branch
#   (b) fast-forwards a no-mistakes task on Firstmate's own repository (FM_ROOT)
#   (c) fast-forwards a direct-PR task on Firstmate's own repository (FM_ROOT)
#   (c2) fast-forwards when that repository is reached through a symlinked path
#   (d) refuses a no-mistakes task on an ordinary project (not local-only)
#   (e) refuses a direct-PR task on an ordinary project (not local-only)
#   (f) refuses when task meta is missing
#   (g) refuses when project directory does not exist or is not a git repo
#   (h) refuses when branch fm/<id> does not exist
#   (i) refuses when project checkout is not on its default branch
#   (j) refuses when project checkout is dirty
#   (k) refuses when branch has diverged (not a fast-forward)
#   (l) Firstmate's own repository pushes the landing to origin as a fast-forward
#   (m) Firstmate's own repository keeps the landing but reports, exit 3, an
#       origin that local main does not contain, and leaves origin untouched
#   (n) Firstmate's own repository keeps the landing but reports, exit 3, a
#       push the remote rejects
#   (o) Firstmate's own repository reads a recorded PR back as merged, and
#       reports, exit 3, one that does not read back merged
#   (p) Firstmate's own repository skips a checkout with no configured fork
#   (q) Firstmate's own repository refuses an incomplete or unsafe fork remap
#   (r) Firstmate's own repository does not read back a non-GitHub PR
#
# "Firstmate's own repository" is one shared predicate, bin/fm-self-repo-lib.sh,
# used identically by fm-merge-local.sh, fm-pr-merge.sh, fm-fleet-sync.sh, and
# fm-spawn.sh. Each of those has its own case for the branch it takes; this
# suite, the lightest of the four, also pins the predicate's own contract so a
# change to it has one owner test rather than four indirect ones.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-self-repo-lib.sh
. "$ROOT/bin/fm-self-repo-lib.sh"
fm_git_identity fmtest fmtest@example.invalid

MERGE_LOCAL="$ROOT/bin/fm-merge-local.sh"
TMP_ROOT=$(fm_test_tmproot fm-merge-local-tests)

run_merge_local() {
  # A bootstrapped home has a resolvable data directory for captain holds.
  mkdir -p "$FM_HOME/data"
  "$MERGE_LOCAL" "$@"
}

make_repo() {
  local dir=$1 default=${2:-main}
  mkdir -p "$dir"
  git -C "$dir" init --quiet --initial-branch="$default"
  echo "initial" > "$dir/file.txt"
  git -C "$dir" add file.txt
  git -C "$dir" commit --quiet -m "initial commit"
}

test_shared_firstmate_repo_predicate_contract() {
  local case_dir root home other
  case_dir="$TMP_ROOT/predicate-contract"
  root="$case_dir/root"
  home="$case_dir/home"
  other="$case_dir/other"
  mkdir -p "$root" "$home" "$other"
  ln -s "$root" "$case_dir/root-link"
  ln -s "$home" "$case_dir/home-link"

  fm_is_firstmate_repo "$root" "$root" "$home" \
    || fail "the code root was not recognized as firstmate's own repository"
  fm_is_firstmate_repo "$home" "$root" "$home" \
    || fail "the operational home was not recognized as firstmate's own repository"
  fm_is_firstmate_repo "$case_dir/root-link" "$root" "$home" \
    || fail "a symlinked code root was not recognized as firstmate's own repository"
  fm_is_firstmate_repo "$root" "$case_dir/root-link" "$home" \
    || fail "a symlinked FM_ROOT did not match the real code root"
  fm_is_firstmate_repo "$case_dir/home-link" "$root" "$home" \
    || fail "a symlinked operational home was not recognized as firstmate's own repository"
  fm_is_firstmate_repo "$root/" "$root" "$home" \
    || fail "a trailing slash defeated the code-root match"
  fm_is_firstmate_repo "$root/../root" "$root" "$home" \
    || fail "a .. segment defeated the code-root match"

  # An ordinary project must never take a firstmate branch, and neither must an
  # empty project field: an unreadable or missing project is not a licence to
  # merge into, skip syncing, or reset the fleet's own tree.
  ! fm_is_firstmate_repo "$other" "$root" "$home" \
    || fail "an ordinary project directory was mistaken for firstmate's own repository"
  ! fm_is_firstmate_repo "" "$root" "$home" \
    || fail "an empty project directory was mistaken for firstmate's own repository"

  # Two different paths that both fail to resolve must stay different. Collapsing
  # an unresolvable path to the empty string would make every missing project
  # match every other one.
  ! fm_is_firstmate_repo "$case_dir/absent-a" "$case_dir/absent-b" "$case_dir/absent-c" \
    || fail "two different unresolvable paths compared equal"

  pass "the shared firstmate-repo predicate matches by physical path and nothing else"
}

test_fast_forward_local_only_project() {
  local case_dir proj_dir state_dir rc before after
  case_dir="$TMP_ROOT/local-only-clean"
  proj_dir="$case_dir/projects/myproj"
  state_dir="$case_dir/state"
  mkdir -p "$state_dir"
  make_repo "$proj_dir" main

  git -C "$proj_dir" checkout -b fm/task-loc1 --quiet
  echo "feature" >> "$proj_dir/file.txt"
  git -C "$proj_dir" commit --quiet -am "feature commit"
  git -C "$proj_dir" checkout main --quiet

  fm_write_meta "$state_dir/task-loc1.meta" \
    "window=fm-task-loc1" \
    "worktree=$case_dir/wt" \
    "project=$proj_dir" \
    "kind=ship" \
    "mode=local-only"

  before=$(git -C "$proj_dir" rev-parse HEAD)

  set +e
  FM_ROOT_OVERRIDE="$case_dir/fmroot" \
  FM_HOME="$case_dir/fmroot" \
  FM_STATE_OVERRIDE="$state_dir" \
    run_merge_local task-loc1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "local-only: fm-merge-local should succeed: $(cat "$case_dir/stderr")"
  after=$(git -C "$proj_dir" rev-parse HEAD)
  [ "$before" != "$after" ] || fail "local-only: default branch was not advanced"
  assert_grep "merged fm/task-loc1 into local main" "$case_dir/stdout" \
    "local-only: success message was not printed"
  pass "fm-merge-local fast-forwards a clean local-only project branch"
}

test_fast_forward_no_mistakes_firstmate_repo() {
  local case_dir fm_root state_dir rc before after
  case_dir="$TMP_ROOT/fm-no-mistakes"
  fm_root="$case_dir/firstmate"
  state_dir="$case_dir/state"
  mkdir -p "$state_dir"
  make_repo "$fm_root" main

  git -C "$fm_root" checkout -b fm/task-fm1 --quiet
  echo "firstmate feature" >> "$fm_root/file.txt"
  git -C "$fm_root" commit --quiet -am "firstmate fix"
  git -C "$fm_root" checkout main --quiet

  fm_write_meta "$state_dir/task-fm1.meta" \
    "window=fm-task-fm1" \
    "worktree=$case_dir/wt" \
    "project=$fm_root" \
    "kind=ship" \
    "mode=no-mistakes"

  before=$(git -C "$fm_root" rev-parse HEAD)

  set +e
  FM_ROOT_OVERRIDE="$fm_root" \
  FM_HOME="$fm_root" \
  FM_STATE_OVERRIDE="$state_dir" \
    run_merge_local task-fm1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "firstmate no-mistakes: fm-merge-local should succeed"
  after=$(git -C "$fm_root" rev-parse HEAD)
  [ "$before" != "$after" ] || fail "firstmate no-mistakes: default branch was not advanced"
  assert_grep "merged fm/task-fm1 into local main" "$case_dir/stdout" \
    "firstmate no-mistakes: success message was not printed"
  pass "fm-merge-local fast-forwards a no-mistakes task on Firstmate's own repository"
}

test_fast_forward_direct_pr_firstmate_repo() {
  local case_dir fm_root state_dir rc before after
  case_dir="$TMP_ROOT/fm-direct-pr"
  fm_root="$case_dir/firstmate"
  state_dir="$case_dir/state"
  mkdir -p "$state_dir"
  make_repo "$fm_root" main

  git -C "$fm_root" checkout -b fm/task-fm2 --quiet
  echo "direct PR fix" >> "$fm_root/file.txt"
  git -C "$fm_root" commit --quiet -am "direct pr fix"
  git -C "$fm_root" checkout main --quiet

  fm_write_meta "$state_dir/task-fm2.meta" \
    "window=fm-task-fm2" \
    "worktree=$case_dir/wt" \
    "project=$fm_root" \
    "kind=ship" \
    "mode=direct-PR"

  before=$(git -C "$fm_root" rev-parse HEAD)

  set +e
  FM_ROOT_OVERRIDE="$fm_root" \
  FM_HOME="$fm_root" \
  FM_STATE_OVERRIDE="$state_dir" \
    run_merge_local task-fm2 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "firstmate direct-PR: fm-merge-local should succeed"
  after=$(git -C "$fm_root" rev-parse HEAD)
  [ "$before" != "$after" ] || fail "firstmate direct-PR: default branch was not advanced"
  assert_grep "merged fm/task-fm2 into local main" "$case_dir/stdout" \
    "firstmate direct-PR: success message was not printed"
  pass "fm-merge-local fast-forwards a direct-PR task on Firstmate's own repository"
}

test_fast_forward_symlinked_firstmate_repo() {
  local case_dir fm_root fm_link state_dir rc before after
  case_dir="$TMP_ROOT/fm-symlinked"
  fm_root="$case_dir/firstmate"
  fm_link="$case_dir/firstmate-link"
  state_dir="$case_dir/state"
  mkdir -p "$state_dir"
  make_repo "$fm_root" main
  ln -s "$fm_root" "$fm_link"

  git -C "$fm_root" checkout -b fm/task-fm-link --quiet
  echo "firstmate feature" >> "$fm_root/file.txt"
  git -C "$fm_root" commit --quiet -am "firstmate fix"
  git -C "$fm_root" checkout main --quiet

  # The task records the project through a symlink while the home names the real
  # path. Only a physical-path comparison sees these as one repository; a literal
  # one would refuse this merge as a PR-mode task on an ordinary project, and the
  # approved firstmate merge would never reach the running tree.
  fm_write_meta "$state_dir/task-fm-link.meta" \
    "window=fm-task-fm-link" \
    "worktree=$case_dir/wt" \
    "project=$fm_link" \
    "kind=ship" \
    "mode=no-mistakes"

  before=$(git -C "$fm_root" rev-parse HEAD)

  set +e
  FM_ROOT_OVERRIDE="$fm_root" \
  FM_HOME="$fm_root" \
  FM_STATE_OVERRIDE="$state_dir" \
    run_merge_local task-fm-link > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "symlinked firstmate repo: fm-merge-local should succeed: $(cat "$case_dir/stderr")"
  after=$(git -C "$fm_root" rev-parse HEAD)
  [ "$before" != "$after" ] || fail "symlinked firstmate repo: default branch was not advanced"
  pass "fm-merge-local recognizes Firstmate's own repository reached through a symlink"
}

test_refuses_no_mistakes_ordinary_project() {
  local case_dir proj_dir state_dir rc
  case_dir="$TMP_ROOT/ordinary-no-mistakes"
  proj_dir="$case_dir/projects/otherproj"
  state_dir="$case_dir/state"
  mkdir -p "$state_dir"
  make_repo "$proj_dir" main

  git -C "$proj_dir" checkout -b fm/task-ord1 --quiet
  echo "change" >> "$proj_dir/file.txt"
  git -C "$proj_dir" commit --quiet -am "change"
  git -C "$proj_dir" checkout main --quiet

  fm_write_meta "$state_dir/task-ord1.meta" \
    "window=fm-task-ord1" \
    "worktree=$case_dir/wt" \
    "project=$proj_dir" \
    "kind=ship" \
    "mode=no-mistakes"

  set +e
  FM_ROOT_OVERRIDE="$case_dir/fmroot" \
  FM_HOME="$case_dir/fmroot" \
  FM_STATE_OVERRIDE="$state_dir" \
    run_merge_local task-ord1 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "ordinary no-mistakes: fm-merge-local should refuse"
  assert_grep "is mode=no-mistakes on $proj_dir, not local-only; merge PR tasks with bin/fm-pr-merge.sh" "$case_dir/stderr" \
    "ordinary no-mistakes: refusal did not explain mode"
  pass "fm-merge-local refuses a no-mistakes task on an ordinary project"
}

test_refuses_direct_pr_ordinary_project() {
  local case_dir proj_dir state_dir rc
  case_dir="$TMP_ROOT/ordinary-direct-pr"
  proj_dir="$case_dir/projects/otherproj2"
  state_dir="$case_dir/state"
  mkdir -p "$state_dir"
  make_repo "$proj_dir" main

  git -C "$proj_dir" checkout -b fm/task-ord2 --quiet
  echo "change" >> "$proj_dir/file.txt"
  git -C "$proj_dir" commit --quiet -am "change"
  git -C "$proj_dir" checkout main --quiet

  fm_write_meta "$state_dir/task-ord2.meta" \
    "window=fm-task-ord2" \
    "worktree=$case_dir/wt" \
    "project=$proj_dir" \
    "kind=ship" \
    "mode=direct-PR"

  set +e
  FM_ROOT_OVERRIDE="$case_dir/fmroot" \
  FM_HOME="$case_dir/fmroot" \
  FM_STATE_OVERRIDE="$state_dir" \
    run_merge_local task-ord2 > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "ordinary direct-PR: fm-merge-local should refuse"
  assert_grep "is mode=direct-PR on $proj_dir, not local-only; merge PR tasks with bin/fm-pr-merge.sh" "$case_dir/stderr" \
    "ordinary direct-PR: refusal did not explain mode"
  pass "fm-merge-local refuses a direct-PR task on an ordinary project"
}

test_refuses_missing_meta() {
  local case_dir state_dir rc
  case_dir="$TMP_ROOT/missing-meta"
  state_dir="$case_dir/state"
  mkdir -p "$state_dir"

  set +e
  FM_ROOT_OVERRIDE="$case_dir/fmroot" \
  FM_HOME="$case_dir/fmroot" \
  FM_STATE_OVERRIDE="$state_dir" \
    run_merge_local missing-task > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-meta: fm-merge-local should refuse"
  assert_grep "error: no meta for task missing-task" "$case_dir/stderr" \
    "missing-meta: refusal did not explain missing meta"
  pass "fm-merge-local refuses when task meta is missing"
}

test_refuses_missing_project() {
  local case_dir state_dir rc
  case_dir="$TMP_ROOT/missing-proj"
  state_dir="$case_dir/state"
  mkdir -p "$state_dir"

  fm_write_meta "$state_dir/task-missproj.meta" \
    "window=fm-task-missproj" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/nonexistent" \
    "kind=ship" \
    "mode=local-only"

  set +e
  FM_ROOT_OVERRIDE="$case_dir/fmroot" \
  FM_HOME="$case_dir/fmroot" \
  FM_STATE_OVERRIDE="$state_dir" \
    run_merge_local task-missproj > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-proj: fm-merge-local should refuse"
  assert_grep "project directory '$case_dir/nonexistent' does not exist" "$case_dir/stderr" \
    "missing-proj: refusal did not explain missing project"
  pass "fm-merge-local refuses when project directory does not exist"
}

test_refuses_missing_branch() {
  local case_dir proj_dir state_dir rc
  case_dir="$TMP_ROOT/missing-branch"
  proj_dir="$case_dir/projects/myproj"
  state_dir="$case_dir/state"
  mkdir -p "$state_dir"
  make_repo "$proj_dir" main

  fm_write_meta "$state_dir/task-nobranch.meta" \
    "window=fm-task-nobranch" \
    "worktree=$case_dir/wt" \
    "project=$proj_dir" \
    "kind=ship" \
    "mode=local-only"

  set +e
  FM_ROOT_OVERRIDE="$case_dir/fmroot" \
  FM_HOME="$case_dir/fmroot" \
  FM_STATE_OVERRIDE="$state_dir" \
    run_merge_local task-nobranch > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "missing-branch: fm-merge-local should refuse"
  assert_grep "branch fm/task-nobranch does not exist in $proj_dir" "$case_dir/stderr" \
    "missing-branch: refusal did not explain missing branch"
  pass "fm-merge-local refuses when branch fm/<id> does not exist"
}

test_refuses_dirty_project() {
  local case_dir proj_dir state_dir rc
  case_dir="$TMP_ROOT/dirty-proj"
  proj_dir="$case_dir/projects/myproj"
  state_dir="$case_dir/state"
  mkdir -p "$state_dir"
  make_repo "$proj_dir" main

  git -C "$proj_dir" checkout -b fm/task-dirty --quiet
  echo "change" >> "$proj_dir/file.txt"
  git -C "$proj_dir" commit --quiet -am "change"
  git -C "$proj_dir" checkout main --quiet
  echo "uncommitted edit" >> "$proj_dir/file.txt"

  fm_write_meta "$state_dir/task-dirty.meta" \
    "window=fm-task-dirty" \
    "worktree=$case_dir/wt" \
    "project=$proj_dir" \
    "kind=ship" \
    "mode=local-only"

  set +e
  FM_ROOT_OVERRIDE="$case_dir/fmroot" \
  FM_HOME="$case_dir/fmroot" \
  FM_STATE_OVERRIDE="$state_dir" \
    run_merge_local task-dirty > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-proj: fm-merge-local should refuse"
  assert_grep "has a dirty working tree; refusing to merge into it" "$case_dir/stderr" \
    "dirty-proj: refusal did not explain dirty working tree"
  pass "fm-merge-local refuses when project checkout is dirty"
}

test_refuses_off_default_project() {
  local case_dir proj_dir state_dir rc
  case_dir="$TMP_ROOT/off-default-proj"
  proj_dir="$case_dir/projects/myproj"
  state_dir="$case_dir/state"
  mkdir -p "$state_dir"
  make_repo "$proj_dir" main

  git -C "$proj_dir" checkout -b other-branch --quiet
  git -C "$proj_dir" checkout -b fm/task-offdef --quiet
  echo "change" >> "$proj_dir/file.txt"
  git -C "$proj_dir" commit --quiet -am "change"
  git -C "$proj_dir" checkout other-branch --quiet

  fm_write_meta "$state_dir/task-offdef.meta" \
    "window=fm-task-offdef" \
    "worktree=$case_dir/wt" \
    "project=$proj_dir" \
    "kind=ship" \
    "mode=local-only"

  set +e
  FM_ROOT_OVERRIDE="$case_dir/fmroot" \
  FM_HOME="$case_dir/fmroot" \
  FM_STATE_OVERRIDE="$state_dir" \
    run_merge_local task-offdef > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "off-default: fm-merge-local should refuse"
  assert_grep "expected default branch 'main'; cannot merge safely" "$case_dir/stderr" \
    "off-default: refusal did not explain non-default branch"
  pass "fm-merge-local refuses when project checkout is not on its default branch"
}

test_refuses_diverged_branch() {
  local case_dir proj_dir state_dir rc
  case_dir="$TMP_ROOT/diverged-branch"
  proj_dir="$case_dir/projects/myproj"
  state_dir="$case_dir/state"
  mkdir -p "$state_dir"
  make_repo "$proj_dir" main

  git -C "$proj_dir" checkout -b fm/task-div --quiet
  echo "task change" >> "$proj_dir/file.txt"
  git -C "$proj_dir" commit --quiet -am "task change"
  git -C "$proj_dir" checkout main --quiet
  echo "competing change" >> "$proj_dir/other.txt"
  git -C "$proj_dir" add other.txt
  git -C "$proj_dir" commit --quiet -m "competing change on main"

  fm_write_meta "$state_dir/task-div.meta" \
    "window=fm-task-div" \
    "worktree=$case_dir/wt" \
    "project=$proj_dir" \
    "kind=ship" \
    "mode=local-only"

  set +e
  FM_ROOT_OVERRIDE="$case_dir/fmroot" \
  FM_HOME="$case_dir/fmroot" \
  FM_STATE_OVERRIDE="$state_dir" \
    run_merge_local task-div > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "diverged-branch: fm-merge-local should refuse"
  assert_grep "REFUSED: fm/task-div is not a fast-forward of main (it has diverged)" "$case_dir/stderr" \
    "diverged-branch: refusal did not explain divergence"
  pass "fm-merge-local refuses when branch has diverged (not a fast-forward)"
}

# A remapped firstmate repository whose origin and upstream are local bare
# clones, plus one ship branch ahead of main. Prints origin's path.
make_fm_repo_with_origin() {
  local case_dir=$1 id=$2 fm_root="$1/firstmate" remote="$1/origin.git" upstream="$1/upstream.git"
  mkdir -p "$case_dir/state"
  make_repo "$fm_root" main
  fm_git_add_origin "$fm_root" "$remote"
  git clone --quiet --bare "$fm_root" "$upstream"
  git -C "$fm_root" remote add upstream "file://$upstream"
  git -C "$fm_root" config checkout.defaultRemote origin
  git -C "$fm_root" config remote.pushDefault origin
  git -C "$fm_root" config remote.origin.gh-resolved base
  git -C "$fm_root" checkout -b "fm/$id" --quiet
  echo "firstmate feature $id" >> "$fm_root/file.txt"
  git -C "$fm_root" commit --quiet -am "firstmate fix $id"
  git -C "$fm_root" checkout main --quiet
  printf '%s\n' "$remote"
}

# A gh stand-in that answers the PR read-back with FAKE_GH_STATE.
make_fake_gh() {
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case "${FAKE_GH_STATE:-MERGED}" in
  MERGED) printf 'state=MERGED\nmerged=true\n' ;;
  *) printf 'state=%s\nmerged=false\n' "$FAKE_GH_STATE" ;;
esac
SH
  chmod +x "$fakebin/gh"
  fm_fake_exit0 "$fakebin" sleep
  printf '%s\n' "$fakebin"
}

run_fm_merge_local() {  # <case-dir> <id>
  local case_dir=$1 fm_root="$1/firstmate"
  FM_ROOT_OVERRIDE="$fm_root" \
  FM_HOME="$fm_root" \
  FM_STATE_OVERRIDE="$case_dir/state" \
    run_merge_local "$2" > "$case_dir/stdout" 2> "$case_dir/stderr"
}

test_firstmate_repo_pushes_fork() {
  local case_dir fm_root remote rc local_sha
  case_dir="$TMP_ROOT/fm-push-fork"
  remote=$(make_fm_repo_with_origin "$case_dir" task-push)
  fm_root="$case_dir/firstmate"
  fm_write_meta "$case_dir/state/task-push.meta" \
    "window=fm-task-push" "worktree=$case_dir/wt" "project=$fm_root" \
    "kind=ship" "mode=no-mistakes"

  set +e
  run_fm_merge_local "$case_dir" task-push
  rc=$?
  set -e

  expect_code 0 "$rc" "push-fork: fm-merge-local should succeed: $(cat "$case_dir/stderr")"
  local_sha=$(git -C "$fm_root" rev-parse main)
  assert_equals "$(git -C "$fm_root" rev-parse fm/task-push)" "$local_sha" \
    "push-fork: local main was not fast-forwarded"
  assert_equals "$local_sha" "$(git -C "$remote" rev-parse main)" \
    "push-fork: origin main does not hold local main"
  assert_grep "pushed local main to origin/main" "$case_dir/stdout" \
    "push-fork: the push was not reported"
  pass "fm-merge-local pushes Firstmate's own landing to origin as a fast-forward"
}

test_firstmate_repo_refuses_non_fast_forward_push() {
  local case_dir fm_root remote other rc remote_before
  case_dir="$TMP_ROOT/fm-push-diverged"
  remote=$(make_fm_repo_with_origin "$case_dir" task-div2)
  fm_root="$case_dir/firstmate"
  other="$case_dir/other"
  git clone --quiet "$remote" "$other"
  echo "landed elsewhere" > "$other/elsewhere.txt"
  git -C "$other" add elsewhere.txt
  git -C "$other" commit --quiet -m "commit only the fork has"
  git -C "$other" push --quiet origin main
  remote_before=$(git -C "$remote" rev-parse main)
  fm_write_meta "$case_dir/state/task-div2.meta" \
    "window=fm-task-div2" "worktree=$case_dir/wt" "project=$fm_root" \
    "kind=ship" "mode=no-mistakes"

  set +e
  run_fm_merge_local "$case_dir" task-div2
  rc=$?
  set -e

  expect_code 3 "$rc" "push-diverged: an unsynced fork must exit 3"
  assert_equals "$(git -C "$fm_root" rev-parse fm/task-div2)" "$(git -C "$fm_root" rev-parse main)" \
    "push-diverged: the local landing was not kept"
  assert_equals "$remote_before" "$(git -C "$remote" rev-parse main)" \
    "push-diverged: origin main moved"
  assert_grep "fork not updated" "$case_dir/stderr" \
    "push-diverged: the unsynced fork was not reported"
  assert_grep "not a fast-forward" "$case_dir/stderr" \
    "push-diverged: the reason was not given"
  assert_grep "push origin refs/heads/main:refs/heads/main" "$case_dir/stderr" \
    "push-diverged: the finishing command was not given"
  assert_no_grep "pushed local main" "$case_dir/stdout" \
    "push-diverged: a push was claimed"
  pass "fm-merge-local keeps the landing and reports a fork it cannot fast-forward"
}

test_firstmate_repo_reports_push_failure() {
  local case_dir fm_root remote rc remote_before
  case_dir="$TMP_ROOT/fm-push-rejected"
  remote=$(make_fm_repo_with_origin "$case_dir" task-rej)
  fm_root="$case_dir/firstmate"
  printf '#!/bin/sh\necho "fork refuses pushes"\nexit 1\n' > "$remote/hooks/pre-receive"
  chmod +x "$remote/hooks/pre-receive"
  remote_before=$(git -C "$remote" rev-parse main)
  fm_write_meta "$case_dir/state/task-rej.meta" \
    "window=fm-task-rej" "worktree=$case_dir/wt" "project=$fm_root" \
    "kind=ship" "mode=direct-PR"

  set +e
  run_fm_merge_local "$case_dir" task-rej
  rc=$?
  set -e

  expect_code 3 "$rc" "push-rejected: a failed push must exit 3"
  assert_equals "$(git -C "$fm_root" rev-parse fm/task-rej)" "$(git -C "$fm_root" rev-parse main)" \
    "push-rejected: the local landing was not kept"
  assert_equals "$remote_before" "$(git -C "$remote" rev-parse main)" \
    "push-rejected: origin main moved"
  assert_grep "the push failed" "$case_dir/stderr" \
    "push-rejected: the failed push was not reported"
  assert_grep "fork refuses pushes" "$case_dir/stderr" \
    "push-rejected: the remote's reason was not passed on"
  assert_grep "push origin refs/heads/main:refs/heads/main" "$case_dir/stderr" \
    "push-rejected: the finishing command was not given"
  pass "fm-merge-local keeps the landing and reports a push the fork rejects"
}

test_firstmate_repo_reads_pr_back_merged() {
  local case_dir fm_root fakebin rc
  case_dir="$TMP_ROOT/fm-pr-readback"
  make_fm_repo_with_origin "$case_dir" task-prm >/dev/null
  fm_root="$case_dir/firstmate"
  fakebin=$(make_fake_gh "$case_dir")
  fm_write_meta "$case_dir/state/task-prm.meta" \
    "window=fm-task-prm" "worktree=$case_dir/wt" "project=$fm_root" \
    "kind=ship" "mode=no-mistakes" "pr=https://github.com/example/firstmate/pull/7"

  set +e
  PATH="$fakebin:$PATH" FAKE_GH_STATE=MERGED FAKE_GH_LOG="$case_dir/gh.log" \
    run_fm_merge_local "$case_dir" task-prm
  rc=$?
  set -e

  expect_code 0 "$rc" "pr-readback: a merged PR should succeed: $(cat "$case_dir/stderr")"
  assert_grep "verified: https://github.com/example/firstmate/pull/7 is merged" "$case_dir/stdout" \
    "pr-readback: the merged PR was not verified"
  assert_grep "number=7" "$case_dir/gh.log" \
    "pr-readback: the recorded PR was not the one read"
  pass "fm-merge-local reads a recorded PR back as merged after the push"
}

test_firstmate_repo_reports_pr_not_merged() {
  local case_dir fm_root remote fakebin rc
  case_dir="$TMP_ROOT/fm-pr-open"
  remote=$(make_fm_repo_with_origin "$case_dir" task-pro)
  fm_root="$case_dir/firstmate"
  fakebin=$(make_fake_gh "$case_dir")
  fm_write_meta "$case_dir/state/task-pro.meta" \
    "window=fm-task-pro" "worktree=$case_dir/wt" "project=$fm_root" \
    "kind=ship" "mode=no-mistakes" "pr=https://github.com/example/firstmate/pull/8"

  set +e
  PATH="$fakebin:$PATH" FAKE_GH_STATE=OPEN FAKE_GH_LOG="$case_dir/gh.log" \
    run_fm_merge_local "$case_dir" task-pro
  rc=$?
  set -e

  expect_code 3 "$rc" "pr-open: a PR that does not read back merged must exit 3"
  assert_equals "$(git -C "$fm_root" rev-parse main)" "$(git -C "$remote" rev-parse main)" \
    "pr-open: the fork was not updated"
  assert_grep "does not read back as merged (state=OPEN)" "$case_dir/stderr" \
    "pr-open: the unproved merge was not reported"
  assert_no_grep "verified:" "$case_dir/stdout" \
    "pr-open: an unproved merge was claimed"
  pass "fm-merge-local reports a recorded PR that does not read back merged"
}

test_firstmate_repo_skips_single_origin_without_fork() {
  local case_dir fm_root remote rc remote_before
  case_dir="$TMP_ROOT/fm-no-configured-fork"
  fm_root="$case_dir/firstmate"
  remote="$case_dir/origin.git"
  mkdir -p "$case_dir/state"
  make_repo "$fm_root" main
  fm_git_add_origin "$fm_root" "$remote"
  git -C "$fm_root" checkout -b fm/task-no-fork --quiet
  echo "firstmate feature" >> "$fm_root/file.txt"
  git -C "$fm_root" commit --quiet -am "firstmate fix"
  git -C "$fm_root" checkout main --quiet
  remote_before=$(git -C "$remote" rev-parse main)
  fm_write_meta "$case_dir/state/task-no-fork.meta" \
    "window=fm-task-no-fork" "worktree=$case_dir/wt" "project=$fm_root" \
    "kind=ship" "mode=no-mistakes"

  set +e
  run_fm_merge_local "$case_dir" task-no-fork
  rc=$?
  set -e

  expect_code 0 "$rc" "no-configured-fork: a single-origin checkout should succeed"
  assert_equals "$remote_before" "$(git -C "$remote" rev-parse main)" \
    "no-configured-fork: origin was pushed"
  assert_grep "no fork is configured" "$case_dir/stdout" \
    "no-configured-fork: the skipped push was not explained"
  assert_grep "nothing was pushed" "$case_dir/stdout" \
    "no-configured-fork: the output did not say that nothing was pushed"
  pass "fm-merge-local skips a checkout with no configured fork"
}

test_firstmate_repo_refuses_missing_origin_after_remap() {
  local case_dir fm_root upstream rc upstream_before
  case_dir="$TMP_ROOT/fm-remap-missing-origin"
  make_fm_repo_with_origin "$case_dir" task-missing-origin >/dev/null
  fm_root="$case_dir/firstmate"
  upstream="$case_dir/upstream.git"
  upstream_before=$(git -C "$upstream" rev-parse main)
  git -C "$fm_root" remote remove origin
  fm_write_meta "$case_dir/state/task-missing-origin.meta" \
    "window=fm-task-missing-origin" "worktree=$case_dir/wt" "project=$fm_root" \
    "kind=ship" "mode=no-mistakes"

  set +e
  run_fm_merge_local "$case_dir" task-missing-origin
  rc=$?
  set -e

  expect_code 3 "$rc" "missing-origin: an incomplete remap must exit 3"
  assert_equals "$upstream_before" "$(git -C "$upstream" rev-parse main)" \
    "missing-origin: upstream main moved"
  assert_grep "fork not updated" "$case_dir/stderr" \
    "missing-origin: the unsynced fork was not reported"
  assert_grep "origin is absent" "$case_dir/stderr" \
    "missing-origin: the incomplete remap was not explained"
  pass "fm-merge-local reports a remapped checkout whose origin is missing"
}

test_firstmate_repo_refuses_upstream_without_url() {
  local case_dir fm_root remote rc remote_before
  case_dir="$TMP_ROOT/fm-remap-upstream-without-url"
  remote=$(make_fm_repo_with_origin "$case_dir" task-upstream-url)
  fm_root="$case_dir/firstmate"
  remote_before=$(git -C "$remote" rev-parse main)
  git -C "$fm_root" config --unset-all remote.upstream.url
  fm_write_meta "$case_dir/state/task-upstream-url.meta" \
    "window=fm-task-upstream-url" "worktree=$case_dir/wt" "project=$fm_root" \
    "kind=ship" "mode=no-mistakes"

  set +e
  run_fm_merge_local "$case_dir" task-upstream-url
  rc=$?
  set -e

  expect_code 3 "$rc" "upstream-without-url: an incomplete remap must exit 3"
  assert_equals "$remote_before" "$(git -C "$remote" rev-parse main)" \
    "upstream-without-url: origin main moved"
  assert_equals "$(git -C "$fm_root" rev-parse fm/task-upstream-url)" \
    "$(git -C "$fm_root" rev-parse main)" \
    "upstream-without-url: local main was not landed"
  assert_grep "fork not updated" "$case_dir/stderr" \
    "upstream-without-url: the unsynced fork was not reported"
  assert_grep "upstream is present but has no configured URL" "$case_dir/stderr" \
    "upstream-without-url: the malformed remap was not explained"
  pass "fm-merge-local refuses a named upstream remote without a URL"
}

test_firstmate_repo_never_pushes_unproven_origin() {
  local case_dir fm_root remote rc remote_before
  case_dir="$TMP_ROOT/fm-push-unproven"
  remote=$(make_fm_repo_with_origin "$case_dir" task-unp)
  fm_root="$case_dir/firstmate"
  # A leftover fork remote means the remap is incomplete.
  git -C "$fm_root" remote add fork "file://$case_dir/elsewhere.git"
  remote_before=$(git -C "$remote" rev-parse main)
  fm_write_meta "$case_dir/state/task-unp.meta" \
    "window=fm-task-unp" "worktree=$case_dir/wt" "project=$fm_root" \
    "kind=ship" "mode=no-mistakes"

  set +e
  run_fm_merge_local "$case_dir" task-unp
  rc=$?
  set -e

  expect_code 3 "$rc" "push-unproven: an unproven origin must exit 3"
  assert_equals "$remote_before" "$(git -C "$remote" rev-parse main)" \
    "push-unproven: origin main moved"
  assert_grep "origin is not proven to be our fork" "$case_dir/stderr" \
    "push-unproven: the refusal was not explained"
  pass "fm-merge-local never pushes to an origin that may be the parent"
}

test_firstmate_repo_never_uses_mismatched_push_url() {
  local case_dir fm_root remote upstream rc remote_before upstream_before origin_url upstream_url
  case_dir="$TMP_ROOT/fm-mismatched-push-url"
  remote=$(make_fm_repo_with_origin "$case_dir" task-push-url)
  fm_root="$case_dir/firstmate"
  upstream="$case_dir/upstream.git"
  origin_url=$(git -C "$fm_root" remote get-url origin)
  upstream_url=$(git -C "$fm_root" remote get-url upstream)
  git -C "$fm_root" remote set-url --add --push origin "$origin_url"
  git -C "$fm_root" remote set-url --add --push origin "$upstream_url"
  remote_before=$(git -C "$remote" rev-parse main)
  upstream_before=$(git -C "$upstream" rev-parse main)
  fm_write_meta "$case_dir/state/task-push-url.meta" \
    "window=fm-task-push-url" "worktree=$case_dir/wt" "project=$fm_root" \
    "kind=ship" "mode=no-mistakes"

  set +e
  run_fm_merge_local "$case_dir" task-push-url
  rc=$?
  set -e

  expect_code 3 "$rc" "push-url: a mismatched push URL must exit 3"
  assert_equals "$remote_before" "$(git -C "$remote" rev-parse main)" \
    "push-url: origin main moved"
  assert_equals "$upstream_before" "$(git -C "$upstream" rev-parse main)" \
    "push-url: upstream main moved"
  assert_grep "would push to $upstream_url rather than its verified fetch URL" "$case_dir/stderr" \
    "push-url: the unsafe destination was not explained"
  pass "fm-merge-local checks every configured origin push URL before pushing"
}

test_firstmate_repo_skips_non_github_pr_readback() {
  local case_dir fm_root remote rc
  case_dir="$TMP_ROOT/fm-non-github-pr"
  remote=$(make_fm_repo_with_origin "$case_dir" task-non-github)
  fm_root="$case_dir/firstmate"
  fm_write_meta "$case_dir/state/task-non-github.meta" \
    "window=fm-task-non-github" "worktree=$case_dir/wt" "project=$fm_root" \
    "kind=ship" "mode=no-mistakes" \
    "pr=https://gitlab.example.com/group/firstmate/-/merge_requests/9"

  set +e
  run_fm_merge_local "$case_dir" task-non-github
  rc=$?
  set -e

  expect_code 0 "$rc" "non-github-pr: a proved fork push should succeed"
  assert_equals "$(git -C "$fm_root" rev-parse main)" "$(git -C "$remote" rev-parse main)" \
    "non-github-pr: the fork was not updated"
  assert_grep "PR state was not checked" "$case_dir/stdout" \
    "non-github-pr: the skipped provider read-back was not reported"
  pass "fm-merge-local stops after branch proof for a non-GitHub PR"
}

test_firstmate_repo_uses_locked_pr_snapshot() {
  local case_dir fm_root remote fakebin real_git real_sleep ready release pid i rc
  case_dir="$TMP_ROOT/fm-locked-pr-snapshot"
  remote=$(make_fm_repo_with_origin "$case_dir" task-pr-snapshot)
  fm_root="$case_dir/firstmate"
  fakebin=$(make_fake_gh "$case_dir")
  real_git=$(command -v git)
  real_sleep=$(command -v sleep)
  ready="$case_dir/post-lock.ready"
  release="$case_dir/post-lock.release"
  fm_write_meta "$case_dir/state/task-pr-snapshot.meta" \
    "window=fm-task-pr-snapshot" "worktree=$case_dir/wt" "project=$fm_root" \
    "kind=ship" "mode=no-mistakes" "spawn_gen=original" \
    "pr=https://github.com/BohnBawerick/firstmate/pull/7"
  cat > "$fakebin/git" <<'SH'
#!/usr/bin/env bash
if [ "$*" = "-C ${FM_TEST_RACE_REPO} rev-parse refs/heads/main" ]; then
  output=$("$FM_TEST_REAL_GIT" "$@") || exit $?
  : > "$FM_TEST_RACE_READY"
  while [ ! -e "$FM_TEST_RACE_RELEASE" ]; do
    "$FM_TEST_REAL_SLEEP" 0.01
  done
  printf '%s\n' "$output"
  exit 0
fi
exec "$FM_TEST_REAL_GIT" "$@"
SH
  chmod +x "$fakebin/git"

  PATH="$fakebin:$PATH" \
  FAKE_GH_LOG="$case_dir/gh.log" \
  FAKE_GH_STATE=MERGED \
  FM_TEST_RACE_REPO="$fm_root" \
  FM_TEST_RACE_READY="$ready" \
  FM_TEST_RACE_RELEASE="$release" \
  FM_TEST_REAL_GIT="$real_git" \
  FM_TEST_REAL_SLEEP="$real_sleep" \
    run_fm_merge_local "$case_dir" task-pr-snapshot &
  pid=$!

  i=0
  while [ ! -e "$ready" ] && kill -0 "$pid" 2>/dev/null && [ "$i" -lt 500 ]; do
    "$real_sleep" 0.01
    i=$((i + 1))
  done
  if [ ! -e "$ready" ]; then
    : > "$release"
    wait "$pid" || true
    fail "locked-pr-snapshot: merge did not reach the post-lock fork read: $(cat "$case_dir/stderr")"
  fi
  if [ -e "$case_dir/state/.control-task-pr-snapshot.lock" ]; then
    : > "$release"
    wait "$pid" || true
    fail "locked-pr-snapshot: fork read began before the task control lock was released"
  fi

  fm_write_meta "$case_dir/state/task-pr-snapshot.meta" \
    "window=fm-task-pr-snapshot-reused" "worktree=$case_dir/reused-wt" "project=$fm_root" \
    "kind=ship" "mode=no-mistakes" "spawn_gen=replacement" \
    "pr=https://github.com/BohnBawerick/firstmate/pull/99"
  : > "$release"
  set +e
  wait "$pid"
  rc=$?
  set -e

  expect_code 0 "$rc" "locked-pr-snapshot: proved fork sync should succeed: $(cat "$case_dir/stderr")"
  assert_equals "$(git -C "$fm_root" rev-parse main)" "$(git -C "$remote" rev-parse main)" \
    "locked-pr-snapshot: the fork was not updated"
  assert_grep "number=7" "$case_dir/gh.log" \
    "locked-pr-snapshot: the original task PR was not read back"
  assert_no_grep "number=99" "$case_dir/gh.log" \
    "locked-pr-snapshot: the replacement task PR was read back"
  assert_grep "verified: https://github.com/BohnBawerick/firstmate/pull/7 is merged" "$case_dir/stdout" \
    "locked-pr-snapshot: the original task PR was not reported"
  pass "fm-merge-local keeps the locked task PR through fork sync"
}

test_shared_firstmate_repo_predicate_contract
test_fast_forward_local_only_project
test_fast_forward_no_mistakes_firstmate_repo
test_fast_forward_direct_pr_firstmate_repo
test_fast_forward_symlinked_firstmate_repo
test_refuses_no_mistakes_ordinary_project
test_refuses_direct_pr_ordinary_project
test_refuses_missing_meta
test_refuses_missing_project
test_refuses_missing_branch
test_refuses_dirty_project
test_refuses_off_default_project
test_refuses_diverged_branch
test_firstmate_repo_pushes_fork
test_firstmate_repo_refuses_non_fast_forward_push
test_firstmate_repo_reports_push_failure
test_firstmate_repo_reads_pr_back_merged
test_firstmate_repo_reports_pr_not_merged
test_firstmate_repo_skips_single_origin_without_fork
test_firstmate_repo_refuses_missing_origin_after_remap
test_firstmate_repo_refuses_upstream_without_url
test_firstmate_repo_never_pushes_unproven_origin
test_firstmate_repo_never_uses_mismatched_push_url
test_firstmate_repo_skips_non_github_pr_readback
test_firstmate_repo_uses_locked_pr_snapshot
