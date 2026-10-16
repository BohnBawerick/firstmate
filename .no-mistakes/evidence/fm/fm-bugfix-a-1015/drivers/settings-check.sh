#!/usr/bin/env bash
set -euo pipefail
E=/home/bohn/.no-mistakes/evidence/01M511MJZT6SK2GSXCKTH7TNKX
TPANE=$(sed -n 's/^herdr_pane_id=//p' "$FM_HOME/state/ctracked.meta")
TWT=$(sed -n 's/^worktree=//p' "$FM_HOME/state/ctracked.meta")
herdr pane process-info --pane "$TPANE" > "$E/tracked-process-before.json"
for pid in $(jq -r '.result.process_info.foreground_processes[]? | select(.name == "claude") | .pid' "$E/tracked-process-before.json"); do kill -TERM "$pid"; done
python3 - "$TWT/.claude/settings.local.json" "$FM_HOME/user-stop.log" <<'PY'
import json,sys,shlex
p=sys.argv[1]
x=json.load(open(p))
x['env']['FM_LAB_KEEP']='worker-value'
x['workerAdded']={'keep':True}
x['hooks']={'Stop':[{'hooks':[{'type':'command','command':'printf user-stop >> '+shlex.quote(sys.argv[2])}]}]}
open(p,'w').write(json.dumps(x)+'\n')
PY
cp "$TWT/.claude/settings.local.json" "$E/worker-settings-before.json"
herdr pane run "$TPANE" "export PATH='$ROOT/.nm-live-test/live/bin':\$PATH"
CLAUDE_CONFIG_DIR="$FM_HOME/claude-config" DISABLE_AUTOUPDATER=1 "$ROOT/bin/fm-spawn.sh" ctracked --relaunch --harness claude > "$E/tracked-relaunch.log" 2>&1
cmp "$TWT/.claude/settings.local.json" "$E/worker-settings-before.json"
printf 'Worker settings survived relaunch byte-for-byte\n'
herdr pane process-info --pane "$TPANE" > "$E/tracked-process-after.json"
(cd "$TWT" && env -u CLAUDE_CONFIG_DIR DISABLE_AUTOUPDATER=1 timeout 90 "$ROOT/.nm-live-test/live/bin/claude" -p --dangerously-skip-permissions --settings "$FM_HOME/state/ctracked.claude-settings.json" 'Use Bash once to run printf "%s\n" "$FM_LAB_KEEP". Report the printed value. Do not edit any files.') > "$E/tracked-claude-consumer.log" 2>&1
cat "$E/tracked-claude-consumer.log"
test -s "$FM_HOME/user-stop.log"
test -f "$FM_HOME/state/ctracked.turn-ended"
printf '\nProject Stop hook and Firstmate turn-ended hook both fired\n'
cat "$FM_HOME/user-stop.log"
cat "$FM_HOME/state/ctracked.busy-state"
