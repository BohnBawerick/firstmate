#!/usr/bin/env bash
set -eu

ROOT=/home/bohn/.no-mistakes/worktrees/842a31c92d33/01M1ZH1EQSKEX5G9BB22ZWRDN4
EVIDENCE=/home/bohn/.no-mistakes/evidence/01M1ZH1EQSKEX5G9BB22ZWRDN4
BASE=379342f54f14057811d7fb9b3699380af3cfd153
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

export GIT_AUTHOR_NAME='No Mistakes Test'
export GIT_AUTHOR_EMAIL='test@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

commit_file() {
  repo=$1
  path=$2
  content=$3
  message=$4
  printf '%s\n' "$content" > "$repo/$path"
  git -C "$repo" add "$path"
  git -C "$repo" commit -qm "$message"
}

mkdir -p "$TMP_ROOT/base"
git -C "$ROOT" archive "$BASE" bin/fm-sync-axi.sh bin/fm-landing-remote.sh | tar -x -C "$TMP_ROOT/base"

origin="$TMP_ROOT/sync-origin.git"
publisher="$TMP_ROOT/sync-publisher"
clone="$TMP_ROOT/sync-clone"
git init -q --bare "$origin"
git -C "$origin" symbolic-ref HEAD refs/heads/main
git clone -q "$origin" "$publisher" 2>/dev/null
commit_file "$publisher" base.txt base base
git -C "$publisher" push -q origin main
git clone -q "$origin" "$clone" 2>/dev/null
git -C "$clone" checkout -qb feature/unmerged
commit_file "$clone" side.txt 'local side branch content' 'local side branch'
side_before=$(git -C "$clone" rev-parse feature/unmerged)
git -C "$clone" checkout -q main
main_before=$(git -C "$clone" rev-parse main)
commit_file "$publisher" upstream.txt 'upstream content' 'upstream update'
git -C "$publisher" push -q origin main

{
  printf 'Scenario: sync a clean main branch while an unmerged local branch exists\n\n'
  printf 'Before sync\n'
  printf '  checked-out branch: %s\n' "$(git -C "$clone" branch --show-current)"
  printf '  main: %s\n' "$main_before"
  printf '  feature/unmerged: %s\n' "$side_before"
  if git -C "$clone" merge-base --is-ancestor feature/unmerged main; then
    printf '  feature/unmerged is merged into main: yes\n'
  else
    printf '  feature/unmerged is merged into main: no\n'
  fi

  printf '\nPrevious behavior from base commit\n'
  baseline_out=$(FM_HOME="$TMP_ROOT" "$TMP_ROOT/base/bin/fm-sync-axi.sh" "$clone" 2>&1)
  printf '  %s\n' "$baseline_out"
  printf '  main changed: %s\n' "$([ "$(git -C "$clone" rev-parse main)" = "$main_before" ] && printf no || printf yes)"

  printf '\nCurrent behavior\n'
  current_out=$(FM_HOME="$TMP_ROOT" "$ROOT/bin/fm-sync-axi.sh" "$clone" 2>&1)
  printf '  %s\n' "$current_out"
  main_after=$(git -C "$clone" rev-parse main)
  side_after=$(git -C "$clone" rev-parse feature/unmerged)
  printf '  main now matches origin/main: %s\n' "$([ "$main_after" = "$(git -C "$clone" rev-parse origin/main)" ] && printf yes || printf no)"
  printf '  upstream file on main: %s\n' "$(git -C "$clone" show main:upstream.txt)"
  printf '  feature/unmerged still exists: %s\n' "$([ -n "$side_after" ] && printf yes || printf no)"
  printf '  feature/unmerged tip preserved in this default configuration: %s\n' "$([ "$side_after" = "$side_before" ] && printf yes || printf no)"
} > "$EVIDENCE/sync-unmerged-branch-transcript.txt"

dirty_before=$(git -C "$clone" rev-parse main)
commit_file "$publisher" later.txt 'later upstream content' 'later upstream update'
git -C "$publisher" push -q origin main
printf 'dirty local edit\n' >> "$clone/base.txt"
dirty_status_before=$(git -C "$clone" status --porcelain)
dirty_out=$(FM_HOME="$TMP_ROOT" "$ROOT/bin/fm-sync-axi.sh" "$clone" 2>&1)
dirty_after=$(git -C "$clone" rev-parse main)
dirty_status_after=$(git -C "$clone" status --porcelain)
git -C "$clone" restore base.txt

git -C "$clone" checkout -q feature/unmerged
branch_before=$(git -C "$clone" rev-parse HEAD)
branch_out=$(FM_HOME="$TMP_ROOT" "$ROOT/bin/fm-sync-axi.sh" "$clone" 2>&1)
branch_after=$(git -C "$clone" rev-parse HEAD)

conflict_origin="$TMP_ROOT/conflict-origin.git"
conflict_publisher="$TMP_ROOT/conflict-publisher"
conflict_clone="$TMP_ROOT/conflict-clone"
git init -q --bare "$conflict_origin"
git -C "$conflict_origin" symbolic-ref HEAD refs/heads/main
git clone -q "$conflict_origin" "$conflict_publisher" 2>/dev/null
commit_file "$conflict_publisher" shared.txt base base
git -C "$conflict_publisher" push -q origin main
git clone -q "$conflict_origin" "$conflict_clone" 2>/dev/null
commit_file "$conflict_clone" shared.txt local 'local conflicting update'
conflict_before=$(git -C "$conflict_clone" rev-parse HEAD)
commit_file "$conflict_publisher" shared.txt upstream 'upstream conflicting update'
git -C "$conflict_publisher" push -q origin main
conflict_out=$(FM_HOME="$TMP_ROOT" "$ROOT/bin/fm-sync-axi.sh" "$conflict_clone" 2>&1)
conflict_after=$(git -C "$conflict_clone" rev-parse HEAD)
conflict_status=$(git -C "$conflict_clone" status --porcelain)

{
  printf 'Scenario: retained sync safety checks\n\n'
  printf 'Dirty working tree\n'
  printf '  %s\n' "$dirty_out"
  printf '  main unchanged: %s\n' "$([ "$dirty_before" = "$dirty_after" ] && printf yes || printf no)"
  printf '  local edit preserved: %s\n' "$([ "$dirty_status_before" = "$dirty_status_after" ] && printf yes || printf no)"

  printf '\nCheckout on a non-default branch\n'
  printf '  %s\n' "$branch_out"
  printf '  checked-out branch unchanged: %s\n' "$([ "$branch_before" = "$branch_after" ] && printf yes || printf no)"

  printf '\nConflicting upstream and local updates\n'
  printf '  %s\n' "$conflict_out"
  printf '  main unchanged: %s\n' "$([ "$conflict_before" = "$conflict_after" ] && printf yes || printf no)"
  printf '  working tree clean after refusal: %s\n' "$([ -z "$conflict_status" ] && printf yes || printf no)"
} > "$EVIDENCE/sync-safety-transcript.txt"

landing_seed="$TMP_ROOT/landing-seed"
landing_parent="$TMP_ROOT/landing-parent.git"
landing_ours="$TMP_ROOT/landing-ours.git"
landing_clone="$TMP_ROOT/landing-clone"
mkdir -p "$landing_seed"
git -C "$landing_seed" init -q
git -C "$landing_seed" symbolic-ref HEAD refs/heads/main
commit_file "$landing_seed" README.md base base
git clone -q --bare "$landing_seed" "$landing_parent"
git clone -q --bare "$landing_seed" "$landing_ours"
git clone -q "file://$landing_parent" "$landing_clone"
git -C "$landing_clone" remote add fork "file://$landing_ours"

fakebin="$TMP_ROOT/fakebin"
mkdir -p "$fakebin"
tool_log="$TMP_ROOT/tool.log"
: > "$tool_log"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf '\''%s\n'\'' "gh $*" >> "$EVIDENCE_TOOL_LOG"' \
  'if [ "$1 $2 $3" = "repo set-default origin" ]; then' \
  '  git config remote.origin.gh-resolved base' \
  'fi' \
  'exit 0' > "$fakebin/gh"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf '\''%s\n'\'' "no-mistakes $*" >> "$EVIDENCE_TOOL_LOG"' \
  '[ "$*" = "init" ]' > "$fakebin/no-mistakes"
chmod +x "$fakebin/gh" "$fakebin/no-mistakes"

set +e
baseline_landing_out=$(EVIDENCE_TOOL_LOG="$tool_log" PATH="$fakebin:$PATH" "$TMP_ROOT/base/bin/fm-landing-remote.sh" apply \
  --ours "file://$landing_ours" \
  --upstream "file://$landing_parent" \
  --repo "$landing_clone" 2>&1)
baseline_landing_rc=$?
set -e
baseline_landing_calls=$(sed 's/^/  /' "$tool_log")
baseline_landing_origin=$(git -C "$landing_clone" remote get-url origin)
: > "$tool_log"

landing_out=$(EVIDENCE_TOOL_LOG="$tool_log" PATH="$fakebin:$PATH" "$ROOT/bin/fm-landing-remote.sh" apply \
  --ours "file://$landing_ours" \
  --upstream "file://$landing_parent" \
  --repo "$landing_clone" 2>&1)

{
  printf 'Scenario: remap a fork checkout onto its landing remote\n\n'
  printf 'Previous behavior from base commit\n'
  printf '  exit code: %s\n' "$baseline_landing_rc"
  printf '%s\n' "$baseline_landing_out" | sed 's/^/  /'
  printf '  Tool calls:\n%s\n' "$baseline_landing_calls"
  printf '  origin restored to parent: %s\n' "$([ "$baseline_landing_origin" = "file://$landing_parent" ] && printf yes || printf no)"

  printf '\nCurrent behavior\n%s\n' "$landing_out"
  printf '\nTool calls made by apply\n'
  sed 's/^/  /' "$tool_log"
  printf '\nPersisted repository settings\n'
  printf '  origin=%s\n' "$(git -C "$landing_clone" remote get-url origin)"
  printf '  upstream=%s\n' "$(git -C "$landing_clone" remote get-url upstream)"
  printf '  checkout.defaultRemote=%s\n' "$(git -C "$landing_clone" config --get checkout.defaultRemote)"
  printf '  remote.pushDefault=%s\n' "$(git -C "$landing_clone" config --get remote.pushDefault)"
  printf '  gh default=%s\n' "$(git -C "$landing_clone" config --get remote.origin.gh-resolved)"
} > "$EVIDENCE/landing-remote-transcript.txt"
