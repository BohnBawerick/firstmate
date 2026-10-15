#!/usr/bin/env bash
set -u
suite=$1
shift
selected=("$@")
shopt -s extdebug
trap 'case "$BASH_COMMAND" in test_*|\"\$test_name\"*|fail\ *|exit\ *) false ;; *) true ;; esac' DEBUG
. "$suite"
trap - DEBUG
shopt -u extdebug
if [ -n "${FM_GATE_INJECT_AFTER:-}" ]; then
  original_track=$(declare -f fm_test_track_pid)
  eval "${original_track/fm_test_track_pid/fm_test_track_pid_record}"
  injected_count=0
  fm_test_track_pid() {
    fm_test_track_pid_record "$@"
    printf '%s\n' "$@" >> "$FM_GATE_PID_EVIDENCE"
    injected_count=$((injected_count + 1))
    if [ "$injected_count" -eq "$FM_GATE_INJECT_AFTER" ]; then
      printf 'cleanup_registry=%s\npid_registry=%s\n' "$FM_TEST_CLEANUP_REGISTRY" "$FM_TEST_PID_REGISTRY"
      if [ "$FM_GATE_INJECT_MODE" = signal ]; then
        kill -TERM "$$"
      else
        fail 'injected assertion failure after child registration'
      fi
    fi
  }
fi
for selected_case in "${selected[@]}"; do
  printf 'selected: %s\n' "$selected_case"
  "$selected_case"
done
