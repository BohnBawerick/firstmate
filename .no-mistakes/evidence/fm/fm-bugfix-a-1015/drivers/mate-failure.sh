#!/usr/bin/env bash
set -euo pipefail
E=/home/bohn/.no-mistakes/evidence/01M511MJZT6SK2GSXCKTH7TNKX
SM="$ROOT/.nm-live-test/live/mate-home"
oldgen=$(sed -n 's/^spawn_gen=//p' "$FM_HOME/state/mate.meta")
MPANE=$(sed -n 's/^herdr_pane_id=//p' "$FM_HOME/state/mate.meta")
herdr pane close "$MPANE" >/dev/null
python3 - "$FM_HOME/state/mate.meta" "$oldgen" "$ROOT/bin/fm-herdr-lab.sh" "$HERDR_SESSION" <<'PY' > "$E/mate-failure-injection.log" 2>&1 &
import os,sys,time,subprocess
from pathlib import Path
p=Path(sys.argv[1]); previous=sys.argv[2]
for attempt in range(6000):
 try: meta=dict(line.split('=',1) for line in p.read_text().splitlines() if '=' in line)
 except FileNotFoundError: meta={}
 if meta.get('spawn_gen') and meta['spawn_gen']!=previous:
  env=dict(os.environ); env['PATH']=env['PATH'].split(':',1)[1]
  print('Closing newly published lab endpoint '+meta['herdr_pane_id'],flush=True)
  result=subprocess.run([sys.argv[3],'run',sys.argv[4],'pane','close',meta['herdr_pane_id']],env=env)
  raise SystemExit(result.returncode)
 time.sleep(.01)
raise SystemExit('Timed out waiting for replacement metadata')
PY
injector=$!
set +e
FM_ROOT_OVERRIDE="$ROOT/.nm-live-test/code" "$ROOT/.nm-live-test/code/bin/fm-spawn.sh" mate "$SM" "sh -c 'printf MATE_RETRY_READY; sleep 300'" --secondmate --backend herdr > "$E/mate-failed-respawn.log" 2>&1
status=$?
set -e
wait "$injector"
cat "$E/mate-failure-injection.log"
cat "$E/mate-failed-respawn.log"
[ "$status" -ne 0 ] || { printf 'Injection did not cause a launch failure\n'; exit 2; }
test -f "$FM_HOME/state/mate.meta"
cp "$FM_HOME/state/mate.meta" "$E/mate-meta-after-failure.txt"
(
 . "$ROOT/bin/fm-pr-lib.sh"
 fm_pr_poll_artifacts_valid "$FM_HOME/state" mate "$ROOT/bin/fm-pr-poll.sh"
)
printf 'Failed replacement kept the existing record and authenticated PR poll\n'
FM_ROOT_OVERRIDE="$ROOT/.nm-live-test/code" "$ROOT/.nm-live-test/code/bin/fm-spawn.sh" mate "$SM" "sh -c 'printf MATE_RETRY_READY; sleep 300'" --secondmate --backend herdr > "$E/mate-retry.log" 2>&1
cat "$E/mate-retry.log"
(
 . "$ROOT/bin/fm-pr-lib.sh"
 fm_pr_poll_artifacts_valid "$FM_HOME/state" mate "$ROOT/bin/fm-pr-poll.sh"
)
printf 'Retry succeeded with the same PR poll authenticated\n'
