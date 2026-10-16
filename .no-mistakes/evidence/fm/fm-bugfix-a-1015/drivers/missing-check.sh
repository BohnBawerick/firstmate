#!/usr/bin/env bash
set -euo pipefail
E=/home/bohn/.no-mistakes/evidence/01M511MJZT6SK2GSXCKTH7TNKX
oldpane=$(sed -n 's/^herdr_pane_id=//p' "$FM_HOME/state/coder.meta")
oldwt=$(sed -n 's/^worktree=//p' "$FM_HOME/state/coder.meta")
cp "$FM_HOME/state/coder.meta" "$E/missing-endpoint-before.meta"
herdr pane close "$oldpane" > "$E/missing-endpoint-close.json"
"$ROOT/bin/fm-spawn.sh" coder --relaunch --harness codex > "$E/missing-endpoint-recovery.log" 2>&1
newpane=$(sed -n 's/^herdr_pane_id=//p' "$FM_HOME/state/coder.meta")
newwt=$(sed -n 's/^worktree=//p' "$FM_HOME/state/coder.meta")
newspace=$(sed -n 's/^herdr_workspace_id=//p' "$FM_HOME/state/coder.meta")
[ "$newpane" != "$oldpane" ]
[ "$newwt" = "$oldwt" ]
test -f "$FM_HOME/state/coder.herdr-presentation"
herdr tab list --workspace "$newspace" > "$E/missing-endpoint-tabs.json"
herdr pane list --workspace "$newspace" > "$E/missing-endpoint-panes.json"
jq -e '.result.tabs|length==1' "$E/missing-endpoint-tabs.json" >/dev/null
jq -e '.result.panes|length==1' "$E/missing-endpoint-panes.json" >/dev/null
cp "$FM_HOME/state/coder.meta" "$E/missing-endpoint-after.meta"
cat "$E/missing-endpoint-recovery.log"
printf 'Missing endpoint recreated in a new one-tab one-pane workspace, with the same worktree\n'
duplicate=$(herdr workspace create --cwd "$ROOT/.nm-live-test/live/project" --label firstmate --no-focus)
dup_pane=$(printf '%s' "$duplicate" | jq -r .result.root_pane.pane_id)
if "$ROOT/bin/fm-spawn.sh" missing "$ROOT/.nm-live-test/live/project" --scout --harness codex --backend herdr > "$E/duplicate-parent-refusal.log" 2>&1; then
 printf 'ERROR: duplicate parents did not refuse\n'; exit 1
fi
test ! -f "$FM_HOME/state/missing.meta"
cat "$E/duplicate-parent-refusal.log"
herdr pane close "$dup_pane" >/dev/null
