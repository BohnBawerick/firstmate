#!/usr/bin/env bash
set -euo pipefail
E=/home/bohn/.no-mistakes/evidence/01M511MJZT6SK2GSXCKTH7TNKX
cp "$FM_HOME/state/coder.meta" "$E/shared-coder-before.meta"
CPANE=$(sed -n 's/^herdr_pane_id=//p' "$FM_HOME/state/coder.meta")
CSPACE=$(sed -n 's/^herdr_workspace_id=//p' "$FM_HOME/state/coder.meta")
herdr pane send-keys "$CPANE" Escape
sleep .3
extra=$(herdr tab create --workspace "$CSPACE" --cwd "$ROOT/.nm-live-test/live/project" --label extra-shell --no-focus)
extra_pane=$(printf '%s' "$extra" | jq -r .result.root_pane.pane_id)
if "$ROOT/bin/fm-spawn.sh" coder --relaunch --harness codex > "$E/shared-relaunch-refusal.log" 2>&1; then
 printf 'ERROR: shared workspace relaunch succeeded\n'; exit 1
fi
cmp "$FM_HOME/state/coder.meta" "$E/shared-coder-before.meta"
cat "$E/shared-relaunch-refusal.log"
herdr pane close "$extra_pane" >/dev/null
token=$(sed -n 's/^projection_id=//p' "$FM_HOME/state/coder.herdr-presentation")
herdr workspace rename "$CSPACE" "2ndmate-alpha/coder · p:$token" >/dev/null
"$ROOT/bin/fm-spawn.sh" coder --relaunch --harness codex > "$E/legacy-child-relaunch.log" 2>&1
cat "$E/legacy-child-relaunch.log"
herdr workspace get "$CSPACE" > "$E/legacy-child-workspace.json"
printf 'Legacy child workspace and renamed tab both reused\n'
