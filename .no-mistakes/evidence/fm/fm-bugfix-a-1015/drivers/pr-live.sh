#!/usr/bin/env bash
set -euo pipefail
E=/home/bohn/.no-mistakes/evidence/01M511MJZT6SK2GSXCKTH7TNKX
P_HOME="$ROOT/.nm-live-test/pr-home"
"$ROOT/bin/fm-lab-home.sh" create "$P_HOME" >/dev/null
mkdir -p "$P_HOME/state" "$P_HOME/data/poll"
cat > "$P_HOME/state/poll.meta" <<EOF
window=$HERDR_SESSION:gone
backend=herdr
endpoint_task_id=poll
kind=ship
mode=no-mistakes
worktree=$ROOT/.nm-live-test/live/project
project=$ROOT/.nm-live-test/live/project
EOF
FM_HOME="$P_HOME" "$ROOT/bin/fm-pr-check.sh" poll https://github.com/cli/cli/pull/1 > "$E/pr-live-arm.log" 2>&1
cat "$E/pr-live-arm.log"
cp "$P_HOME/state/poll.pr-poll-registration" "$E/pr-registration-live-before.txt"
python3 - "$P_HOME/state/poll.pr-poll-registration" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); lines=p.read_text().splitlines()
for i in (9,10):
 device,inode=lines[i].split(':'); lines[i]=str(int(device)+1)+':'+inode
p.write_text('\n'.join(lines)+'\n')
PY
cp "$P_HOME/state/poll.pr-poll-registration" "$E/pr-registration-shifted.txt"
FM_HOME="$P_HOME" "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 20 > "$E/pr-live-watch.log" 2>&1 || true
cat "$E/pr-live-watch.log"
cat "$P_HOME/state/.watch-triage.log" > "$E/pr-live-triage.log"
cat "$P_HOME/state/.wake-queue" > "$E/pr-live-wakes.log"
cat "$E/pr-live-triage.log"
