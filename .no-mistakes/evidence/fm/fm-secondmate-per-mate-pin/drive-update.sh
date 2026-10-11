#!/usr/bin/env bash
set -eu
cd /home/bohn/.no-mistakes/worktrees/842a31c92d33/01M4MXE3H360EQJY80HJE7X9TZ
source .test-pin-tmp/live/env.sh
cd "$PIN_CODE"
FM_SECONDMATE_PERSIST_WAIT=90 FM_SECONDMATE_PERSIST_POLL=1 bash "$PIN_CODE/bin/fm-secondmate-restart.sh" mac > "$PIN_EVIDENCE/live-update-restart.log" 2>&1
