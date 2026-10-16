#!/usr/bin/env bash
set -euo pipefail
E=/home/bohn/.no-mistakes/evidence/01M511MJZT6SK2GSXCKTH7TNKX
cp "$FM_HERDR_LAB_STATE_DIR/$HERDR_SESSION.fleet-state.json" "$E/default-session-before.json"
PATH=${PATH#*:} "$ROOT/bin/fm-herdr-lab.sh" teardown "$HERDR_SESSION"
PATH=${PATH#*:} "$ROOT/bin/fm-herdr-lab.sh" run "$HERDR_SESSION" session list --json | jq -c '.sessions[] | select(.default == true) | {name, default, running, socket_path}' > "$E/default-session-after.json"
cmp "$E/default-session-before.json" "$E/default-session-after.json"
printf 'Named lab removed. Default-session tripwire unchanged.\n'
cat "$E/default-session-after.json"
