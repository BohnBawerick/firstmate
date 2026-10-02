#!/usr/bin/env bash
set -eu

ROOT=/home/bohn/.no-mistakes/worktrees/842a31c92d33/01M3YW1NJAFGA6XK0751N9NFXN
export TMPDIR="$ROOT/.test-codex-catalog-tmp"
mkdir -p "$TMPDIR"

. "$ROOT/tests/lib.sh"
. "$ROOT/tests/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot codex-catalog-guard)

run_case() {
  local name=$1 mode=$2 world home project worktree fakebin codex_home launchlog output count warning
  world="$TMP_ROOT/$name"
  home="$world/home"
  project="$world/project"
  worktree="$world/worktree"
  codex_home="$world/codex-home"
  launchlog="$world/launch.log"

  fakebin=$(fm_test_make_spawn_fakebin "$world/fake" codex)
  fm_test_spawn_home "$home" codex
  fm_test_spawn_brief "$home" "$name"
  fm_git_worktree "$project" "$worktree" "branch-$name"
  mkdir -p "$codex_home"

  case "$mode" in
    missing) ;;
    unreadable)
      printf '%s\n' '{"models":[]}' > "$codex_home/models_cache.json"
      chmod 000 "$codex_home/models_cache.json"
      ;;
    unsupported)
      printf '%s\n' '{"models":[{"slug":"gpt-6-astra","supported_reasoning_levels":[{"effort":"high"}]}]}' \
        > "$codex_home/models_cache.json"
      ;;
  esac

  : > "$launchlog"
  output=$(CODEX_HOME="$codex_home" FM_FAKE_LAUNCH_LOG="$launchlog" \
    fm_test_run_spawn "$home" "$worktree" "$fakebin" \
      "$name" "$project" --scout --harness codex --model gpt-6-astra --effort max)

  count=$(printf '%s\n' "$output" | grep -Fxc \
    'warning: dropped codex effort max for model gpt-6-astra; catalog does not advertise it' || true)
  [ "$count" -eq 1 ] || fail "$mode catalog case emitted $count matching warnings"
  warning=$(printf '%s\n' "$output" | grep -Fx \
    'warning: dropped codex effort max for model gpt-6-astra; catalog does not advertise it')
  assert_not_contains "$(cat "$launchlog")" 'model_reasoning_effort' \
    "$mode catalog case passed max after warning"
  assert_contains "$(cat "$launchlog")" "codex --model 'gpt-6-astra'" \
    "$mode catalog case lost the selected model"

  printf '%s: %s; warning_count=%s; effort_setting=omitted\n' "$mode" "$warning" "$count"
}

run_case missing missing
run_case unreadable unreadable
run_case unsupported unsupported
printf '%s\n' 'catalog downgrade guard: pass'
