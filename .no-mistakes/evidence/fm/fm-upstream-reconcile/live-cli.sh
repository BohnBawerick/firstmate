#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$ROOT/.test-phase-tmp/manual3
mkdir -p "$LAB/home"/{state,data,config}
export FM_HOME=$LAB/home FM_STATE_OVERRIDE=$LAB/home/state FM_DATA_OVERRIDE=$LAB/home/data TMPDIR=$ROOT/.test-phase-tmp
export FM_PROCEVENT_CLAIM_ROOT=$LAB/claims
unset TASKS_AXI_FILE TASKS_AXI_BACKEND
run() { printf '\n$'; printf ' %q' "$@"; printf '\n'; "$@"; }
cat > "$FM_HOME/data/learnings.md" <<'DOC'
# Learnings

## api-cache eviction
Preserve the cache key when retrying.

## glacier-store retention
Keep cold archives for thirty days.
DOC
printf 'api-cache\n' > "$FM_HOME/data/projects.md"
printf 'Keep claims backed by evidence.\n' > "$FM_HOME/data/captain.md"
printf '7500\n' > "$FM_HOME/config/startup-memory-budget"
run bin/fm-memory-migrate.sh --dry-run
[ -f "$FM_HOME/data/learnings.md" ]
run bin/fm-memory-migrate.sh
[ ! -f "$FM_HOME/data/learnings.md" ]
run bin/fm-memory-compile.sh compile
run bin/fm-memory-migrate.sh
printf '\nMemory archives:\n'
find "$FM_HOME/data/memory" -type f | sort
export FM_PI_HARNESS=pi PI_CODING_AGENT=true
unset CLAUDECODE CLAUDE_PID CLAUDE_CODE_SESSION_ID
run bin/fm-afk-launch.sh quiet on
run bin/fm-afk-launch.sh quiet status
[ ! -e "$FM_HOME/state/.afk-contract" ]
printf 'No away authority record exists after quiet entry.\n'
run bin/fm-afk-launch.sh propose --words 'Away for lunch. Merge only task api-cache when green.' --grant api-cache --action merge --object 'api-cache' --when 'all checks green'
run bin/fm-afk-launch.sh confirm
run bin/fm-afk-contract.sh grants
run bin/fm-afk-launch.sh quiet off
run bin/fm-afk-contract.sh validate
printf 'Quiet exit preserved the separate away contract.\n'
set +e
run bin/fm-afk-launch.sh start
rc=$?
set -e
[ "$rc" -ne 0 ]
printf 'Pi daemon launch refused with exit %s.\n' "$rc"
run bin/fm-afk-launch.sh stop
[ ! -e "$FM_HOME/state/.afk-contract" ]
printf '\nArchived posture records:\n'
find "$FM_HOME/state/afk-contracts" -type f
set +e
run bin/fm-afk-contract.sh propose --action merge --object api-cache
rc=$?
set -e
[ "$rc" -eq 3 ]
printf 'Incomplete clause refused with exit %s.\n' "$rc"
