#!/usr/bin/env bash
# Live drive of bin/fm-lock.sh and the fleet-mutation gate from a real Claude
# Code shell (CLAUDE_PID / CLAUDE_CODE_SESSION_ID come from the live harness).
# Usage: drive-session-lock.sh <firstmate-root> <workdir>
set -u
ROOT=$1; W=$2; rm -rf "$W"; mkdir -p "$W/home/state"
export FM_HOME="$W/home"; S="$W/home/state"
show() { echo "    .lock line1=$(head -1 "$S/.lock" 2>/dev/null)  .lock-session=$(cat "$S/.lock-session" 2>/dev/null | head -c 12)...  (CLAUDE_PID=$CLAUDE_PID)"; }
echo "## 1. acquire from this live Claude session"
"$ROOT/bin/fm-lock.sh"; echo "    exit=$?"; show
echo "## 2. same session re-acquires from a fresh shell"
bash -c "'$ROOT/bin/fm-lock.sh'"; echo "    exit=$?"; show
"$ROOT/bin/fm-lock.sh" status
echo "## 3. another live Claude-shaped harness holds the lock"
cp /usr/bin/sleep "$W/claude"; "$W/claude" 120 & OTHER=$!
printf '%s\n' "$OTHER" > "$S/.lock"; printf 'other-session-id\n' > "$S/.lock-session"
"$ROOT/bin/fm-lock.sh"; echo "    exit=$?"
"$ROOT/bin/fm-lock.sh" status
echo "## 3b. fleet mutation (fm-send.sh) is refused while another session holds the lock"
(cd "$W" && env -u NO_MISTAKES_GATE "$ROOT/bin/fm-send.sh" demo "hello"); echo "    exit=$?"
echo "## 4. adversarial: caller copies the holder's session id but names a CLAUDE_PID outside its own ancestry"
printf '%s\n' "$CLAUDE_CODE_SESSION_ID" > "$S/.lock-session"
CLAUDE_PID=$OTHER "$ROOT/bin/fm-lock.sh"; echo "    exit=$?"
echo "## 5. holder dies; this session reclaims"
kill $OTHER; wait $OTHER 2>/dev/null
"$ROOT/bin/fm-lock.sh"; echo "    exit=$?"; show
