#!/usr/bin/env bash
set -euo pipefail
real=/home/bohn/.no-mistakes/worktrees/842a31c92d33/01M50DPBG3H9SMSTA1C87NNP2P/bin/fm-herdr-lab.sh
if [ "${1:-}" = name ]; then printf 'fm-lab-d%s\n' "$RANDOM"; exit; fi
if [ "${1:-}" = provision ]; then
  "$real" "$@"
  "$real" run "$2" status --json >&2
  exit
fi
if [ "${1:-}" = teardown ]; then
  "$real" run "$2" session list --json >&2
fi
exec "$real" "$@"
