#!/usr/bin/env bash
# Update cloned repositories and firstmate from origin using local patch stacks.
#
# Discovers all clone targets under $FM_HOME/projects (or $FM_PROJECTS_OVERRIDE)
# plus the firstmate repository itself ($FM_ROOT). Fetches from origin without
# mutating working trees, tests scratch integration (preferring rebase "replay ours
# on top", falling back to merge "take theirs on top"), applies only clean updates,
# rebuilds globally installed tools that resolve into updated clones, and reports
# plain-English per-repository outcomes.
#
# HARD SAFETY GUARANTEES:
# - Never pushes to any remote, never opens PRs, never forks.
# - Never stashes, forces, resets, or discards unlanded work or dirty trees.
# - Evaluates updates on a scratch worktree first; never mutates a real tree if
#   conflicts occur.
# - Reports dirty trees, unlanded work, fetch failures, and conflict states
#   without changing them.
#
# Usage: fm-sync-axi.sh [--help] [<project-dir-or-name>]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"

usage() {
  cat << 'EOF'
usage: fm-sync-axi.sh [--help] [<project-dir-or-name>]

Update cloned repositories and firstmate from origin using local patch stacks.

Arguments:
  <project-dir-or-name>   Optional project directory or bare name under $FM_HOME/projects.
                          If omitted, syncs all clones under $PROJECTS plus firstmate.

Mechanics per repository:
  1. Discover target repositories and skip targets with no origin remote.
  2. Refuse dirty working trees or unlanded local branches.
  3. Fetch origin without mutating working trees.
  4. Test scratch integration on a detached scratch worktree:
     - Replay ours on top (rebase our commits onto origin/<default>).
     - Take theirs on top (merge origin/<default> into our default branch).
     - If both conflict, leave real repository untouched and report conflicts.
  5. Apply clean update to real repository.
  6. Rebuild globally installed commands that resolve into updated clones.
  7. Report plain-English status per repository, including firstmate restart note
     when bin/ or .agents/skills/ are updated.

Safety guarantees:
  - Never pushes to any remote, never opens PRs, never forks.
  - Never stashes, forces, resets, or discards unlanded work or dirty trees.
  - Evaluates updates on a scratch worktree first; never mutates a real tree if
    conflicts occur.
EOF
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -le 1 ] || { usage; exit 1; }

detect_installed_command() {
  local repo_dir="$1"
  local repo_real
  repo_real=$(cd "$repo_dir" 2>/dev/null && pwd -P)
  [ -n "$repo_real" ] || return 1

  local bin_dir bin_file real_file
  IFS=':' read -r -a path_dirs <<< "${PATH:-}"
  for bin_dir in "${path_dirs[@]}"; do
    [ -d "$bin_dir" ] || continue
    for bin_file in "$bin_dir"/*; do
      [ -x "$bin_file" ] || continue
      real_file=$(realpath "$bin_file" 2>/dev/null || true)
      case "$real_file" in
        "$repo_real"/*)
          basename "$bin_file"
          return 0
          ;;
      esac
    done
  done
  return 1
}

get_default_branch() {
  local dir="$1"
  local def=""
  def=$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
  if [ -z "$def" ]; then
    if git -C "$dir" rev-parse --verify origin/main >/dev/null 2>&1; then
      def="main"
    elif git -C "$dir" rev-parse --verify origin/master >/dev/null 2>&1; then
      def="master"
    else
      def=$(git -C "$dir" branch --show-current 2>/dev/null)
    fi
  fi
  [ -n "$def" ] || def="main"
  printf '%s' "$def"
}

sync_repo() {
  local target_dir="$1"
  local repo_name="$2"

  if [ ! -d "$target_dir" ] || ! git -C "$target_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    return 0
  fi

  if ! git -C "$target_dir" remote 2>/dev/null | grep -qx "origin"; then
    echo "$repo_name: skipped (no origin remote)"
    return 0
  fi

  local default_branch
  default_branch=$(get_default_branch "$target_dir")

  local status_out
  status_out=$(git -C "$target_dir" status --porcelain 2>/dev/null || true)
  if [ -n "$status_out" ]; then
    echo "$repo_name: uncommitted changes - not applied"
    return 0
  fi

  local curr_branch
  curr_branch=$(git -C "$target_dir" branch --show-current 2>/dev/null || true)
  if [ "$curr_branch" != "$default_branch" ]; then
    echo "$repo_name: unlanded work in progress - not applied"
    return 0
  fi

  local local_branches b unlanded_found=0
  local_branches=$(git -C "$target_dir" for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null || true)
  for b in $local_branches; do
    [ "$b" = "$default_branch" ] && continue
    if ! git -C "$target_dir" merge-base --is-ancestor "$b" "$default_branch" 2>/dev/null; then
      unlanded_found=1
      break
    fi
  done
  if [ "$unlanded_found" -eq 1 ]; then
    echo "$repo_name: unlanded work in progress - not applied"
    return 0
  fi

  if ! git -C "$target_dir" fetch -q origin 2>/dev/null; then
    echo "$repo_name: fetch failed - not applied"
    return 0
  fi

  local old_sha upstream_sha behind_count
  old_sha=$(git -C "$target_dir" rev-parse HEAD 2>/dev/null)
  upstream_sha=$(git -C "$target_dir" rev-parse "origin/$default_branch" 2>/dev/null || echo "")

  if [ -z "$upstream_sha" ]; then
    echo "$repo_name: skipped (origin/$default_branch missing)"
    return 0
  fi

  if [ "$old_sha" = "$upstream_sha" ]; then
    echo "$repo_name: already current"
    return 0
  fi

  behind_count=$(git -C "$target_dir" rev-list --count "HEAD..origin/$default_branch" 2>/dev/null || echo 0)
  if [ "$behind_count" -eq 0 ]; then
    echo "$repo_name: already current"
    return 0
  fi

  local wt_dir scratch_strategy="" conflict_files=0
  wt_dir=$(mktemp -d)
  if ! git -C "$target_dir" worktree add -q --detach "$wt_dir" HEAD >/dev/null 2>&1; then
    rm -rf "$wt_dir"
    echo "$repo_name: scratch setup failed - not applied"
    return 0
  fi

  if git -C "$wt_dir" rebase "origin/$default_branch" >/dev/null 2>&1; then
    scratch_strategy="rebase"
  else
    git -C "$wt_dir" rebase --abort >/dev/null 2>&1 || true
    git -C "$wt_dir" reset --hard "$old_sha" >/dev/null 2>&1
    if git -C "$wt_dir" merge --no-edit "origin/$default_branch" >/dev/null 2>&1; then
      scratch_strategy="merge"
    else
      conflict_files=$(git -C "$wt_dir" diff --name-only --diff-filter=U 2>/dev/null | wc -l | tr -d ' ')
      git -C "$wt_dir" merge --abort >/dev/null 2>&1 || true
      scratch_strategy="conflict"
    fi
  fi

  git -C "$target_dir" worktree remove --force "$wt_dir" >/dev/null 2>&1 || rm -rf "$wt_dir"
  git -C "$target_dir" worktree prune >/dev/null 2>&1 || true

  if [ "$scratch_strategy" = "conflict" ]; then
    local file_word="files"
    [ "$conflict_files" -eq 1 ] && file_word="file"
    echo "$repo_name: CONFLICTS in $conflict_files $file_word - not applied"
    return 0
  fi

  if [ "$scratch_strategy" = "rebase" ]; then
    git -C "$target_dir" rebase -q "origin/$default_branch"
  elif [ "$scratch_strategy" = "merge" ]; then
    git -C "$target_dir" merge -q --no-edit "origin/$default_branch"
  fi

  local new_sha
  new_sha=$(git -C "$target_dir" rev-parse HEAD 2>/dev/null)

  local rebuilt_tool="" installed_cmd
  if [ "$old_sha" != "$new_sha" ]; then
    installed_cmd=$(detect_installed_command "$target_dir" || echo "")
    if [ -n "$installed_cmd" ] && [ -f "$target_dir/package.json" ]; then
      if grep -q '"build"' "$target_dir/package.json" 2>/dev/null || grep -q '"compile"' "$target_dir/package.json" 2>/dev/null; then
        if (cd "$target_dir" && npm run build >/dev/null 2>&1); then
          rebuilt_tool="$installed_cmd"
        fi
      fi
    fi
  fi

  local restart_note="" changed_files
  local target_real fm_real
  target_real=$(cd "$target_dir" 2>/dev/null && pwd -P)
  fm_real=$(cd "$FM_ROOT" 2>/dev/null && pwd -P)
  if [ "$target_real" = "$fm_real" ] && [ "$old_sha" != "$new_sha" ]; then
    changed_files=$(git -C "$target_dir" diff --name-only "$old_sha..$new_sha" 2>/dev/null || true)
    if echo "$changed_files" | grep -q -E '^(bin/|\.agents/skills/)'; then
      restart_note="restart warranted: instruction surface or bin/ updated"
    else
      restart_note="no restart needed: only docs/tests/CI changed"
    fi
  fi

  local commit_word="commits"
  [ "$behind_count" -eq 1 ] && commit_word="commit"
  local out_line="$repo_name: updated, $behind_count new $commit_word from upstream"
  if [ -n "$rebuilt_tool" ]; then
    out_line="$out_line (rebuilt $rebuilt_tool)"
  fi
  if [ -n "$restart_note" ]; then
    out_line="$out_line ($restart_note)"
  fi
  echo "$out_line"
}

if [ $# -eq 1 ]; then
  arg="$1"
  target_path=""
  target_name=""
  if [ "$arg" = "firstmate" ] || [ "$(realpath "$arg" 2>/dev/null)" = "$(realpath "$FM_ROOT" 2>/dev/null)" ]; then
    target_path="$FM_ROOT"
    target_name="firstmate"
  elif [ -d "$PROJECTS/${arg#projects/}" ]; then
    target_path="$PROJECTS/${arg#projects/}"
    target_name=$(basename "$target_path")
  elif [ -d "$arg" ]; then
    target_path="$arg"
    target_name=$(basename "$arg")
  else
    echo "$arg: not found" >&2
    exit 1
  fi
  sync_repo "$target_path" "$target_name"
else
  if [ -d "$PROJECTS" ]; then
    for proj in "$PROJECTS"/*; do
      [ -d "$proj" ] || continue
      sync_repo "$proj" "$(basename "$proj")"
    done
  fi
  sync_repo "$FM_ROOT" "firstmate"
fi
