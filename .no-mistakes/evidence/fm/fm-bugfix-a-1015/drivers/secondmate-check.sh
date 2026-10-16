#!/usr/bin/env bash
set -euo pipefail
E=/home/bohn/.no-mistakes/evidence/01M511MJZT6SK2GSXCKTH7TNKX
SM="$ROOT/.nm-live-test/live/mate-home"
mkdir -p "$SM"
git archive 6196d452d5fa924a86dc9a3e9c92dde7356109ed | tar -x -C "$SM"
mkdir -p "$SM/state" "$SM/config" "$SM/data" "$SM/projects"
printf 'mate\n' > "$SM/.fm-secondmate-home"
printf 'This disposable mate remains idle.\n' > "$SM/data/charter.md"
git -C "$SM" init -q -b main
git -C "$SM" -c core.excludesFile=/dev/null add .
git -C "$SM" -c user.name=Validation -c user.email=validation@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm fixture
FM_SECONDMATE_CHARTER='Remain idle for a disposable launch check.' FM_ROOT_OVERRIDE="$ROOT/.nm-live-test/code" "$ROOT/.nm-live-test/code/bin/fm-brief.sh" mate --secondmate --no-projects >/dev/null
cat > "$FM_HOME/state/mate.meta" <<EOF
window=$HERDR_SESSION:gone
kind=secondmate
harness=sh
home=$SM
custom_metadata=preserve-this
pr=https://github.com/cli/cli/pull/1
pr_head=0123456789abcdef0123456789abcdef01234567
EOF
(
 . "$ROOT/bin/fm-pr-lib.sh"
 fm_pr_poll_prepare "$FM_HOME/state" mate github https://github.com/cli/cli/pull/1 github.com cli/cli 1 "$ROOT/bin/fm-pr-poll.sh"
 fm_pr_poll_publish_prepared
 fm_pr_poll_cleanup
 fm_pr_poll_artifacts_valid "$FM_HOME/state" mate "$ROOT/bin/fm-pr-poll.sh"
)
cp "$FM_HOME/state/mate.pr-poll-registration" "$E/mate-registration-before.txt"
FM_ROOT_OVERRIDE="$ROOT/.nm-live-test/code" "$ROOT/.nm-live-test/code/bin/fm-spawn.sh" mate "$SM" "sh -c 'printf MATE_READY; sleep 300'" --secondmate --backend herdr > "$E/mate-respawn.log" 2>&1
cat "$E/mate-respawn.log"
cp "$FM_HOME/state/mate.meta" "$E/mate-meta-after.txt"
cmp "$FM_HOME/state/mate.pr-poll-registration" "$E/mate-registration-before.txt"
(
 . "$ROOT/bin/fm-pr-lib.sh"
 fm_pr_poll_artifacts_valid "$FM_HOME/state" mate "$ROOT/bin/fm-pr-poll.sh"
)
printf 'Respawn preserved the metadata and the authenticated armed poll\n'
MPANE=$(sed -n 's/^herdr_pane_id=//p' "$FM_HOME/state/mate.meta")
herdr pane read "$MPANE" --source recent --lines 200
