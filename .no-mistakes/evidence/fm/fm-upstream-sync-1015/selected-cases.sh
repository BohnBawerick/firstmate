#!/usr/bin/env bash
set -u
suite=$1
shift
selected=("$@")
_gate_load_guard() {
  local raw=$1 name origin
  case "$raw" in
    test_*|\"\$*|fail\ *|exit\ *) return 1 ;;
  esac
  name=${raw%% *}
  origin=$(declare -F "$name" 2>/dev/null || true)
  case "$origin" in *" $suite") return 1 ;; esac
  return 0
}
shopt -s extdebug
trap '_gate_load_guard "$BASH_COMMAND"' DEBUG
. "$suite"
trap - DEBUG
shopt -u extdebug
for selected_case in "${selected[@]}"; do
  printf 'selected: %s\n' "$selected_case"
  "$selected_case"
done
