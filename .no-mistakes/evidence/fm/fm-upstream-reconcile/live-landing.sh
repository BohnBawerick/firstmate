#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$ROOT/.test-phase-tmp/landing-manual
mkdir -p "$LAB/home"/{state,data,config} "$LAB/project"
export FM_HOME=$LAB/home TMPDIR=$ROOT/.test-phase-tmp
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME='Firstmate test' GIT_COMMITTER_NAME='Firstmate test' GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_EMAIL=test@example.invalid
unset FM_STATE_OVERRIDE FM_DATA_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND
run() { printf '\n$'; printf ' %q' "$@"; printf '\n'; "$@"; }
run git -C "$LAB/project" init -q --initial-branch=main
printf 'base\n' > "$LAB/project/content"
git -C "$LAB/project" add content
git -C "$LAB/project" commit -qm 'Seed isolated landing lab'
git -C "$LAB/project" checkout -qb fm/landing
printf 'accepted change\n' >> "$LAB/project/content"
git -C "$LAB/project" commit -qam 'Add isolated change'
git -C "$LAB/project" checkout -q main
cat > "$FM_HOME/state/landing.meta" <<EOF
window=lab:fm-landing
worktree=$LAB/project
project=$LAB/project
kind=ship
mode=local-only
EOF
run bin/fm-merge-local.sh landing
run git -C "$LAB/project" log -2 --oneline
run cat "$LAB/project/content"
[ "$(git -C "$LAB/project" rev-parse main)" = "$(git -C "$LAB/project" rev-parse fm/landing)" ]
git -C "$LAB/project" checkout -q fm/landing
printf 'next change\n' >> "$LAB/project/content"
git -C "$LAB/project" commit -qam 'Prepare next isolated change'
git -C "$LAB/project" checkout -q main
printf 'uncommitted user work\n' >> "$LAB/project/content"
before=$(git -C "$LAB/project" rev-parse HEAD)
set +e
run bin/fm-merge-local.sh landing
rc=$?
set -e
[ "$rc" -ne 0 ]
[ "$before" = "$(git -C "$LAB/project" rev-parse HEAD)" ]
printf 'Dirty checkout refused with exit %s; HEAD and user work preserved.\n' "$rc"
run git -C "$LAB/project" diff
