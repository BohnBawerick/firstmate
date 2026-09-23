#!/usr/bin/env bash
# Live drive: a no-mistakes ship worker appends `done: PR <url> ready` while
# its head exists only in its disposable copy. Run the real fm-crew-state.sh.
# Usage: drive-dod-gate.sh <firstmate-root> <workdir>
set -u
ROOT=$1; W=$2; rm -rf "$W"; mkdir -p "$W/state" "$W/fakebin"
git init -q --bare "$W/origin.git"
git clone -q "$W/origin.git" "$W/wt" 2>/dev/null
git -C "$W/wt" commit -q --allow-empty -m init && git -C "$W/wt" push -q origin HEAD:main
git -C "$W/wt" checkout -q -b fm/demo
git -C "$W/wt" commit -q --allow-empty -m 'fix only in the worker copy'
# External CLIs the product shells out to: no no-mistakes run recorded, idle tmux pane.
printf '#!/bin/sh\ncase "$1" in daemon) echo "daemon running";; esac\nexit 0\n' > "$W/fakebin/no-mistakes"
printf '#!/bin/sh\ncase "$1" in display-message) echo %%1;; capture-pane) printf "all quiet\\n> \\n";; esac\nexit 0\n' > "$W/fakebin/tmux"
chmod +x "$W/fakebin/"*
printf '%s\n' window=fm:fm-demo "worktree=$W/wt" "project=$W/wt" kind=ship mode=no-mistakes harness=claude > "$W/state/demo.meta"
printf 'done: PR https://github.com/o/r/pull/7 ready\n' > "$W/state/demo.status"
gen=$("$ROOT/bin/fm-busy-event.sh" arm "$W/state" demo)
"$ROOT/bin/fm-busy-event.sh" apply "$W/state" demo idle --gen "$gen" --source claude-hook --event stop
echo "--- status line: $(cat "$W/state/demo.status")"
echo "--- worker HEAD $(git -C "$W/wt" rev-parse --short HEAD) on origin? $(git -C "$W/origin.git" branch --contains "$(git -C "$W/wt" rev-parse HEAD)" 2>/dev/null | wc -l) branches"
echo "--- fm-crew-state.sh demo:"
NM_HOME="$W/nm" PATH="$W/fakebin:$PATH" FM_STATE_OVERRIDE="$W/state" "$ROOT/bin/fm-crew-state.sh" demo
echo "--- now push the head so it is reachable outside the copy"
git -C "$W/wt" push -q origin fm/demo
NM_HOME="$W/nm" PATH="$W/fakebin:$PATH" FM_STATE_OVERRIDE="$W/state" "$ROOT/bin/fm-crew-state.sh" demo
