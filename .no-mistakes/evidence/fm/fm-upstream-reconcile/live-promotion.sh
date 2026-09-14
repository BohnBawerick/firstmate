#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$ROOT/.test-phase-tmp/promotion-manual
mkdir -p "$LAB/home"/{state,data/audit,config} "$LAB/worktree"
export FM_HOME=$LAB/home TMPDIR=$ROOT/.test-phase-tmp
unset TASKS_AXI_FILE TASKS_AXI_BACKEND
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf 'window=lab:fm-audit\nkind=scout\nworktree=%s\n' "$LAB/worktree" > "$FM_HOME/state/audit.meta"
cat > "$FM_HOME/data/audit/brief.md" <<'DOC'
# Task
## Captain's intent
Fix the identity check while preserving active shell tools.
## Firstmate spec
Ship the identity-check fix without adding a classifier.
Accepted captain steering: unknown ownership must leave the worker running.
# Definition of done
Produce a scout report.
DOC
printf '$ bin/fm-promote.sh audit --mode no-mistakes --yolo off\n'
bin/fm-promote.sh audit --mode no-mistakes --yolo off
cat "$FM_HOME/state/audit.meta"
cat "$FM_HOME/data/audit/ship-instructions.md"
cp "$FM_HOME/data/audit/ship-instructions.md" /home/bohn/.no-mistakes/evidence/01M2FSAP36PE8TM5G7KKWCZCFM/promoted-instructions.md
mkdir -p "$FM_HOME/data/unproven"
printf 'window=lab:fm-unproven\nkind=scout\nworktree=%s\n' "$LAB/worktree" > "$FM_HOME/state/unproven.meta"
printf '# Task\nAn instruction with no author provenance.\n' > "$FM_HOME/data/unproven/brief.md"
printf '\n$ bin/fm-promote.sh unproven --mode no-mistakes --yolo off\n'
set +e
bin/fm-promote.sh unproven --mode no-mistakes --yolo off
rc=$?
set -e
[ "$rc" -ne 0 ]
[ ! -e "$FM_HOME/data/unproven/ship-instructions.md" ]
grep -q '^kind=scout$' "$FM_HOME/state/unproven.meta"
printf 'Missing intent provenance refused with exit %s; scout record preserved.\n' "$rc"
