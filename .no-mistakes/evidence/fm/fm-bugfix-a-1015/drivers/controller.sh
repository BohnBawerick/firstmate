#!/usr/bin/env bash
set -u
START_PATH=$PATH
stty rows 40 cols 120 -echo
if [ -f .nm-live-test/live/env.sh ]; then
  . .nm-live-test/live/env.sh
  PATH=${PATH#*:} bin/fm-herdr-lab.sh teardown "$HERDR_SESSION"
fi
export PATH=$START_PATH
python3 -c 'import shutil; shutil.rmtree(".nm-live-test/live")'
bash .nm-live-test/setup-live.sh || exit
. .nm-live-test/live/env.sh
cleanup() {
  PATH=${PATH#*:} "$ROOT/bin/fm-herdr-lab.sh" teardown "$HERDR_SESSION"
}
trap cleanup EXIT
printf '\nCONTROLLER READY\n'
while IFS= read -r action; do
  [ "$action" != exit ] || break
  eval "$action"
  printf '\nACTION COMPLETE status=%s\n' "$?"
done
