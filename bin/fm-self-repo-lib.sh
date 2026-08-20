# shellcheck shell=bash
# Shared "is this project directory firstmate's own repository?" predicate.
# Usage: . bin/fm-self-repo-lib.sh
#
# Firstmate ships work on itself, so its tracked code root (FM_ROOT) and its
# operational home (FM_HOME) both turn up as a task's project directory. Four
# decisions branch on that fact and must agree exactly:
#   bin/fm-merge-local.sh   accepts a PR-mode task for the local fast-forward
#   bin/fm-pr-merge.sh      follows a merged PR with that same local landing
#   bin/fm-fleet-sync.sh    leaves the checkout alone (upstream sync is manual)
#   bin/fm-spawn.sh         refreshes a task worktree from the LOCAL default
#                           branch instead of fetching origin
# A project that counts as firstmate for one of them and not another is how a
# worker gets reset onto a remote tip the fleet never reviewed, or how a merged
# firstmate PR silently fails to reach the running tree. One predicate here
# keeps a later fix from reaching three call sites and missing the fourth.
#
# Comparison is by resolved PHYSICAL path, so a symlinked home, a trailing
# slash, or a `..` segment cannot make one directory look like two. A path that
# cannot be resolved keeps its literal spelling rather than collapsing to the
# empty string, which would make two different unresolvable paths compare equal.

# Echo the physical path of <dir>, or the input verbatim when it cannot be
# resolved.
fm_canonical_dir() {  # <dir>
  local target=${1-}
  ( cd "$target" 2>/dev/null && pwd -P ) || printf '%s\n' "$target"
}

# Return 0 when <project-dir> is firstmate's own tracked code root or its
# operational home. An empty project directory is never firstmate's own repo.
fm_is_firstmate_repo() {  # <project-dir> <fm-root> <fm-home>
  local proj_real root_real home_real
  [ -n "${1-}" ] || return 1
  proj_real=$(fm_canonical_dir "$1")
  root_real=$(fm_canonical_dir "${2-}")
  home_real=$(fm_canonical_dir "${3-}")
  [ "$proj_real" = "$root_real" ] || [ "$proj_real" = "$home_real" ]
}
