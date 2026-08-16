#!/usr/bin/env bash
# Behavior tests for fm-sync-axi.sh repository sync mechanics.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SYNC_SCRIPT="$ROOT/bin/fm-sync-axi.sh"

fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-sync-axi-tests)

commit_file() {
  local dir=$1 file=$2 content=$3 msg=$4
  printf '%s\n' "$content" > "$dir/$file"
  git -C "$dir" add "$file"
  git -C "$dir" commit -qm "$msg"
}

# --- Test 1: --help ---
help_out=$("$SYNC_SCRIPT" --help 2>&1)
case "$help_out" in
  *"usage: fm-sync-axi.sh"*) pass "--help prints usage" ;;
  *) fail "--help output incorrect: $help_out" ;;
esac

# --- Test 2: No origin remote ---
no_origin_dir="$TMP_ROOT/no-origin-repo"
git init -q "$no_origin_dir"
git -C "$no_origin_dir" symbolic-ref HEAD refs/heads/main
commit_file "$no_origin_dir" file.txt v1 C1

out=$("$SYNC_SCRIPT" "$no_origin_dir" 2>&1)
case "$out" in
  *"no-origin-repo: skipped (no origin remote)"*) pass "no origin remote skipped" ;;
  *) fail "expected skipped output, got: $out" ;;
esac

# --- Test 3: Already current ---
current_home="$TMP_ROOT/home-current"
mkdir -p "$current_home/projects" "$current_home/remotes"

git init -q --bare "$current_home/remotes/curr.git"
git -C "$current_home/remotes/curr.git" symbolic-ref HEAD refs/heads/main

work_dir="$TMP_ROOT/work-curr"
git clone -q "$current_home/remotes/curr.git" "$work_dir" 2>/dev/null
commit_file "$work_dir" file.txt v1 C1
git -C "$work_dir" push -q origin main

git clone -q "$current_home/remotes/curr.git" "$current_home/projects/curr" 2>/dev/null

out=$(FM_HOME="$current_home" "$SYNC_SCRIPT" "$current_home/projects/curr" 2>&1)
case "$out" in
  *"curr: already current"*) pass "already current repo reported" ;;
  *) fail "expected already current output, got: $out" ;;
esac

# --- Test 4: Clean rebase update ---
sync_home="$TMP_ROOT/home-sync"
mkdir -p "$sync_home/projects" "$sync_home/remotes"

git init -q --bare "$sync_home/remotes/repo1.git"
git -C "$sync_home/remotes/repo1.git" symbolic-ref HEAD refs/heads/main

work1="$TMP_ROOT/work-repo1"
git clone -q "$sync_home/remotes/repo1.git" "$work1" 2>/dev/null
commit_file "$work1" file1.txt base C0
git -C "$work1" push -q origin main

git clone -q "$sync_home/remotes/repo1.git" "$sync_home/projects/repo1" 2>/dev/null

# Make local commit in clone
commit_file "$sync_home/projects/repo1" local.txt local_v1 "C-local"

# Advance upstream origin with 2 commits
commit_file "$work1" file1.txt upstream_v1 "C-upstream-1"
commit_file "$work1" file2.txt upstream_v2 "C-upstream-2"
git -C "$work1" push -q origin main

out=$(FM_HOME="$sync_home" "$SYNC_SCRIPT" "$sync_home/projects/repo1" 2>&1)
case "$out" in
  *"repo1: updated, 2 new commits from upstream"*) pass "clean rebase update reported" ;;
  *) fail "expected updated output, got: $out" ;;
esac

head_msg=$(git -C "$sync_home/projects/repo1" log -1 --format='%s')
if [ "$head_msg" = "C-local" ]; then
  pass "local commit rebased on top of upstream"
else
  fail "expected top commit C-local, got: $head_msg"
fi

# --- Test 5: Conflicting repository left untouched ---
conflict_home="$TMP_ROOT/home-conflict"
mkdir -p "$conflict_home/projects" "$conflict_home/remotes"

git init -q --bare "$conflict_home/remotes/conf.git"
git -C "$conflict_home/remotes/conf.git" symbolic-ref HEAD refs/heads/main

work_conf="$TMP_ROOT/work-conf"
git clone -q "$conflict_home/remotes/conf.git" "$work_conf" 2>/dev/null
commit_file "$work_conf" shared.txt base C0
git -C "$work_conf" push -q origin main

git clone -q "$conflict_home/remotes/conf.git" "$conflict_home/projects/conf" 2>/dev/null

# Local conflicting commit
commit_file "$conflict_home/projects/conf" shared.txt "local changes" "C-local-conf"
sha_before=$(git -C "$conflict_home/projects/conf" rev-parse HEAD)

# Upstream conflicting commit
commit_file "$work_conf" shared.txt "upstream changes" "C-upstream-conf"
git -C "$work_conf" push -q origin main

out=$(FM_HOME="$conflict_home" "$SYNC_SCRIPT" "$conflict_home/projects/conf" 2>&1)
case "$out" in
  *"conf: CONFLICTS in 1 file - not applied"*) pass "conflicting repo reported as non-applied" ;;
  *) fail "expected conflict output, got: $out" ;;
esac

sha_after=$(git -C "$conflict_home/projects/conf" rev-parse HEAD)
status_after=$(git -C "$conflict_home/projects/conf" status --porcelain)

if [ "$sha_before" = "$sha_after" ] && [ -z "$status_after" ]; then
  pass "conflicting working tree left completely untouched"
else
  fail "conflicting repo mutated! sha_before=$sha_before sha_after=$sha_after status=$status_after"
fi

# --- Test 6: Dirty working tree ---
dirty_home="$TMP_ROOT/home-dirty"
mkdir -p "$dirty_home/projects" "$dirty_home/remotes"

git init -q --bare "$dirty_home/remotes/dirty.git"
git -C "$dirty_home/remotes/dirty.git" symbolic-ref HEAD refs/heads/main

work_dirty="$TMP_ROOT/work-dirty"
git clone -q "$dirty_home/remotes/dirty.git" "$work_dirty" 2>/dev/null
commit_file "$work_dirty" file.txt v1 C1
git -C "$work_dirty" push -q origin main

git clone -q "$dirty_home/remotes/dirty.git" "$dirty_home/projects/dirty" 2>/dev/null
printf 'dirty edit\n' >> "$dirty_home/projects/dirty/file.txt"

sha_dirty_before=$(git -C "$dirty_home/projects/dirty" rev-parse HEAD)

out=$(FM_HOME="$dirty_home" "$SYNC_SCRIPT" "$dirty_home/projects/dirty" 2>&1)
case "$out" in
  *"dirty: uncommitted changes - not applied"*) pass "dirty working tree reported" ;;
  *) fail "expected dirty output, got: $out" ;;
esac

sha_dirty_after=$(git -C "$dirty_home/projects/dirty" rev-parse HEAD)
if [ "$sha_dirty_before" = "$sha_dirty_after" ] && [ -n "$(git -C "$dirty_home/projects/dirty" status --porcelain)" ]; then
  pass "dirty working tree left untouched"
else
  fail "dirty repo mutated unexpectedly"
fi

# --- Test 7a: Unlanded work on task branch ---
branch_home="$TMP_ROOT/home-branch"
mkdir -p "$branch_home/projects" "$branch_home/remotes"

git init -q --bare "$branch_home/remotes/taskrepo.git"
git -C "$branch_home/remotes/taskrepo.git" symbolic-ref HEAD refs/heads/main

work_task="$TMP_ROOT/work-task"
git clone -q "$branch_home/remotes/taskrepo.git" "$work_task" 2>/dev/null
commit_file "$work_task" file.txt v1 C1
git -C "$work_task" push -q origin main

git clone -q "$branch_home/remotes/taskrepo.git" "$branch_home/projects/taskrepo" 2>/dev/null
git -C "$branch_home/projects/taskrepo" checkout -q -b feature/work
commit_file "$branch_home/projects/taskrepo" feature.txt f1 C-feature

out=$(FM_HOME="$branch_home" "$SYNC_SCRIPT" "$branch_home/projects/taskrepo" 2>&1)
case "$out" in
  *"taskrepo: unlanded work in progress - not applied"*) pass "unlanded task branch reported" ;;
  *) fail "expected unlanded work output, got: $out" ;;
esac

# --- Test 7b: Merged task branch is NOT treated as unlanded ---
merged_home="$TMP_ROOT/home-merged-branch"
mkdir -p "$merged_home/projects" "$merged_home/remotes"

git init -q --bare "$merged_home/remotes/mergedrepo.git"
git -C "$merged_home/remotes/mergedrepo.git" symbolic-ref HEAD refs/heads/main

work_merged="$TMP_ROOT/work-merged"
git clone -q "$merged_home/remotes/mergedrepo.git" "$work_merged" 2>/dev/null
commit_file "$work_merged" file.txt v1 C1
git -C "$work_merged" push -q origin main

git clone -q "$merged_home/remotes/mergedrepo.git" "$merged_home/projects/mergedrepo" 2>/dev/null

# Create a task branch and merge it into main in the clone
git -C "$merged_home/projects/mergedrepo" checkout -q -b fm/landed-task
commit_file "$merged_home/projects/mergedrepo" landed.txt l1 C-landed
git -C "$merged_home/projects/mergedrepo" checkout -q main
git -C "$merged_home/projects/mergedrepo" merge -q fm/landed-task

# Advance upstream origin
commit_file "$work_merged" file.txt v2 C2-upstream
git -C "$work_merged" push -q origin main

out=$(FM_HOME="$merged_home" "$SYNC_SCRIPT" "$merged_home/projects/mergedrepo" 2>&1)
case "$out" in
  *"mergedrepo: updated, 1 new commit from upstream"*) pass "merged task branch allowed and updated cleanly" ;;
  *) fail "expected updated output for merged task branch, got: $out" ;;
esac

# --- Test 7c: Multiple merged branches plus one unmerged branch still refuses ---
mix_home="$TMP_ROOT/home-mix-branch"
mkdir -p "$mix_home/projects" "$mix_home/remotes"

git init -q --bare "$mix_home/remotes/mixrepo.git"
git -C "$mix_home/remotes/mixrepo.git" symbolic-ref HEAD refs/heads/main

work_mix="$TMP_ROOT/work-mix"
git clone -q "$mix_home/remotes/mixrepo.git" "$work_mix" 2>/dev/null
commit_file "$work_mix" file.txt v1 C1
git -C "$work_mix" push -q origin main

git clone -q "$mix_home/remotes/mixrepo.git" "$mix_home/projects/mixrepo" 2>/dev/null

# Create 2 merged branches
git -C "$mix_home/projects/mixrepo" checkout -q -b fm/merged1
commit_file "$mix_home/projects/mixrepo" m1.txt m1 C-m1
git -C "$mix_home/projects/mixrepo" checkout -q main
git -C "$mix_home/projects/mixrepo" merge -q fm/merged1

git -C "$mix_home/projects/mixrepo" checkout -q -b fm/merged2
commit_file "$mix_home/projects/mixrepo" m2.txt m2 C-m2
git -C "$mix_home/projects/mixrepo" checkout -q main
git -C "$mix_home/projects/mixrepo" merge -q fm/merged2

# Create 1 unmerged branch
git -C "$mix_home/projects/mixrepo" checkout -q -b fm/unmerged1
commit_file "$mix_home/projects/mixrepo" u1.txt u1 C-u1
git -C "$mix_home/projects/mixrepo" checkout -q main

out=$(FM_HOME="$mix_home" "$SYNC_SCRIPT" "$mix_home/projects/mixrepo" 2>&1)
case "$out" in
  *"mixrepo: unlanded work in progress - not applied"*) pass "mixed merged and unmerged branches correctly refused" ;;
  *) fail "expected unlanded output for mixed branches, got: $out" ;;
esac

# --- Test 8: Firstmate restart note ---
fm_world="$TMP_ROOT/fm-world"
mkdir -p "$fm_world/origin.git"
git init -q --bare "$fm_world/origin.git"
git -C "$fm_world/origin.git" symbolic-ref HEAD refs/heads/main

seed_fm="$TMP_ROOT/seed-fm"
git clone -q "$fm_world/origin.git" "$seed_fm" 2>/dev/null
commit_file "$seed_fm" README.md r1 C1
git -C "$seed_fm" push -q origin main

clone_fm="$TMP_ROOT/clone-fm"
git clone -q "$fm_world/origin.git" "$clone_fm" 2>/dev/null

# Advance origin with bin edit
mkdir -p "$seed_fm/bin"
commit_file "$seed_fm" bin/script.sh "echo 1" "C-bin"
git -C "$seed_fm" push -q origin main

out=$(FM_ROOT_OVERRIDE="$clone_fm" FM_HOME="$TMP_ROOT" "$SYNC_SCRIPT" "$clone_fm" 2>&1)
case "$out" in
  *"firstmate: updated, 1 new commit from upstream (restart warranted: instruction surface or bin/ updated)"*) pass "firstmate restart warranted note reported" ;;
  *) fail "expected restart note output, got: $out" ;;
esac

pass "all fm-sync-axi tests passed"
