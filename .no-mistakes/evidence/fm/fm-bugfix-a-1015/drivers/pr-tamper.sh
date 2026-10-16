#!/usr/bin/env bash
set -euo pipefail
E=/home/bohn/.no-mistakes/evidence/01M511MJZT6SK2GSXCKTH7TNKX
P_HOME="$ROOT/.nm-live-test/pr-tamper-home"
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
FM_HOME="$P_HOME" "$ROOT/bin/fm-pr-check.sh" poll https://github.com/cli/cli/pull/1 > "$E/pr-tamper-arm.log" 2>&1
cat "$E/pr-tamper-arm.log"
cp "$P_HOME/state/poll.pr-poll-registration" "$E/pr-tamper-registration-live-before.txt"
python3 - "$P_HOME/state/poll.pr-poll-registration" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); lines=p.read_text().splitlines()
for i in (9,):
 device,inode=lines[i].split(':'); lines[i]=str(int(device)+1)+':'+inode
p.write_text('\n'.join(lines)+'\n')
PY
cp "$P_HOME/state/poll.pr-poll-registration" "$E/pr-tamper-registration-shifted.txt"
FM_HOME="$P_HOME" "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 20 > "$E/pr-tamper-watch.log" 2>&1 || true
cat "$E/pr-tamper-watch.log"
if [ -f "$P_HOME/state/.watch-triage.log" ]; then cat "$P_HOME/state/.watch-triage.log" > "$E/pr-tamper-triage.log"; fi
cat "$P_HOME/state/.wake-queue" > "$E/pr-tamper-wakes.log"
if [ -f "$E/pr-tamper-triage.log" ]; then cat "$E/pr-tamper-triage.log"; fi
