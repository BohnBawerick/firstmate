#!/usr/bin/env bash
set -euo pipefail
E=/home/bohn/.no-mistakes/evidence/01M511MJZT6SK2GSXCKTH7TNKX
"$ROOT/bin/fm-spawn.sh" ctracked --relaunch --harness codex > "$E/claimant-recovery.log" 2>&1
TWT=$(sed -n 's/^worktree=//p' "$FM_HOME/state/ctracked.meta")
TPANE=$(sed -n 's/^herdr_pane_id=//p' "$FM_HOME/state/ctracked.meta")
for id in ctracked superseded; do
 mkdir -p "$FM_HOME/data/$id"
 printf 'Disposable launch check complete.\n' > "$FM_HOME/data/$id/report.md"
 "$ROOT/bin/fm-captain-hold.sh" complete "$id" --none > "$E/$id-completion.txt"
done
python3 - "$FM_HOME/state/ctracked.meta" "$FM_HOME/state/superseded.meta" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
lines=[]
for line in s.splitlines():
 if line.startswith('endpoint_task_id='): line='endpoint_task_id=superseded'
 elif line.startswith('window='): line=line.rsplit(':w',1)[0]+':w999:p999'
 elif line.startswith('herdr_pane_id='): line='herdr_pane_id=w999:p999'
 elif line.startswith('herdr_tab_id='): line='herdr_tab_id=w999:t999'
 elif line.startswith('herdr_workspace_id='): line='herdr_workspace_id=w999'
 lines.append(line)
s='\n'.join(lines)+'\n'
Path(sys.argv[2]).write_text(s)
PY
if "$ROOT/bin/fm-teardown.sh" ctracked > "$E/shared-worktree-refusal.log" 2>&1; then
 printf 'ERROR: claimant teardown unexpectedly accepted a competing record\n'
 exit 1
fi
cat "$E/shared-worktree-refusal.log"
test -d "$TWT"
test -f "$FM_HOME/state/ctracked.meta"
"$ROOT/bin/fm-teardown.sh" superseded > "$E/stale-record-teardown.log" 2>&1
cat "$E/stale-record-teardown.log"
test ! -e "$FM_HOME/state/superseded.meta"
test -d "$TWT"
herdr pane get "$TPANE" > "$E/claimant-survives.json"
# Restore only this driver's deliberate fixture edits before the clean-return check.
git -C "$TWT" restore .claude/settings.local.json
cp "$TWT/.claude/settings.local.json" "$E/tracked-settings-at-teardown.json"
"$ROOT/bin/fm-teardown.sh" ctracked > "$E/claimant-teardown.log" 2>&1
cat "$E/claimant-teardown.log"
test ! -e "$FM_HOME/state/ctracked.meta"
cmp "$TWT/.claude/settings.local.json" "$E/tracked-settings-at-teardown.json"
git -C "$TWT" diff --exit-code -- .claude/settings.local.json
printf 'Returned pool copy keeps tracked settings and has no tracked deletion\n'
git -C "$TWT" status --porcelain
