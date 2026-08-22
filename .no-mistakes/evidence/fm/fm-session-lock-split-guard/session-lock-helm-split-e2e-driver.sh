#!/usr/bin/env bash
# End-to-end demo of the session-lock helm split fix, driven exactly as a
# firstmate session would drive it.
set -u
ROOT=${1:?repo root}
D=$(mktemp -d /tmp/fmdemo/home.XXXXXX)
HOME_DIR="$D/home"
FAKEBIN="$D/bin"
mkdir -p "$FAKEBIN" "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
ln -sf /bin/bash "$FAKEBIN/claude"
CLAUDE="$FAKEBIN/claude"
git init -q "$HOME_DIR"; git -C "$HOME_DIR" -c user.email=d@e.invalid -c user.name=d commit -q --allow-empty -m init
: > "$HOME_DIR/AGENTS.md"
cp -R "$ROOT/bin" "$HOME_DIR/bin"
cat > "$HOME_DIR/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
printf 'watcher: arm fixture, no actionable reason\n'
SH
chmod +x "$HOME_DIR/bin/fm-watch-arm.sh"
printf 'id=demo\nproject=demo\n' > "$HOME_DIR/state/demo.meta"

PIDS=()
start_session() {  # <pidfile>
  "$CLAUDE" -c 'printf "%s\n" "$$" > "$1"; sleep 300; :' _ "$1" >/dev/null 2>&1 &
  PIDS+=($!)
  while [ ! -s "$1" ]; do sleep 0.05; done
  cat "$1"
}
cleanup() {
  local p k
  for p in "${PIDS[@]}"; do
    for k in $(ps -eo pid=,ppid= | awk -v r="$p" '$2==r{print $1}'); do kill -9 "$k" 2>/dev/null; done
    kill -9 "$p" 2>/dev/null
  done
  rm -rf "$D"
}
trap cleanup EXIT

# The captain's foreground Claude Code session.
A=$(start_session "$D/a.pid")
# A background continuation of that SAME conversation: separate process tree,
# different harness pid, same CLAUDE_CODE_SESSION_ID.
B=$(start_session "$D/b.pid")
# An unrelated second session in the same home.
C=$(start_session "$D/c.pid")

as() {  # <pid> <session-id> <command...>
  local pid=$1 sid=$2; shift 2
  env CLAUDE_PID="$pid" CLAUDE_CODE_SESSION_ID="$sid" \
    FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$HOME_DIR" \
    FM_CLAUDE_AUTOARM_SYNC_WAIT_MS=100 "$@" 2>&1
}
banner() { printf '\n=== %s ===\n' "$*"; }
show() { printf '$ %s\n' "$1"; shift; "$@"; printf '[exit %s]\n' "$?"; }

banner "SETUP"
printf 'foreground session A : harness pid %s, conversation conv-alpha\n' "$A"
printf 'background continuation of A : harness pid %s, conversation conv-alpha\n' "$B"
printf 'unrelated session C : harness pid %s, conversation conv-charlie\n' "$C"

banner "PART 2 - session A takes the helm, and the output says so in words"
show "fm-lock.sh   (as session A)" as "$A" conv-alpha "$HOME_DIR/bin/fm-lock.sh"
printf 'state/.lock         -> %s\n' "$(cat "$HOME_DIR/state/.lock")"
printf 'state/.lock.session -> %s\n' "$(cat "$HOME_DIR/state/.lock.session")"

banner "PART 1a - the background continuation inherits the helm and may mutate"
show "fm-lock.sh   (as background continuation B)" as "$B" conv-alpha "$HOME_DIR/bin/fm-lock.sh"
show "fm-lock.sh status   (as B)" as "$B" conv-alpha "$HOME_DIR/bin/fm-lock.sh" status
show "fm-wake-drain.sh   (as B)" as "$B" conv-alpha "$HOME_DIR/bin/fm-wake-drain.sh"

banner "PART 2 - the unrelated session is told it does NOT hold the home"
show "fm-lock.sh   (as session C)" as "$C" conv-charlie "$HOME_DIR/bin/fm-lock.sh"
show "fm-lock.sh status   (as C)" as "$C" conv-charlie "$HOME_DIR/bin/fm-lock.sh" status

banner "PART 1b - every mutating fleet path refuses session C"
for s in fm-wake-drain.sh fm-send.sh fm-spawn.sh fm-teardown.sh fm-promote.sh \
         fm-merge-local.sh fm-pr-merge.sh fm-control.sh; do
  show "$s   (as C)" as "$C" conv-charlie "$HOME_DIR/bin/$s"
done

banner "PART 3 - the turn-end guard reports the decline once, then stands down"
for t in 1 2 3 4; do
  printf -- '--- session C ends turn %s ---\n' "$t"
  printf '{"session_id":"conv-charlie","stop_hook_active":false}' \
    | as "$C" conv-charlie "$HOME_DIR/bin/fm-turnend-guard.sh" --claude
  printf '[exit %s]\n' "$?"
done
printf '\nauto-arm block budget file state/.turnend-claude-blocks: '
if [ -e "$HOME_DIR/state/.turnend-claude-blocks" ]; then
  printf 'PRESENT (%s) - budget was spent\n' "$(cat "$HOME_DIR/state/.turnend-claude-blocks")"
else
  printf 'absent - a clean stand-down spent none of it\n'
fi

banner "PART 3 - the helm holder is unaffected: session B ends a turn"
printf '{"session_id":"conv-alpha","stop_hook_active":false}' \
  | as "$B" conv-alpha "$HOME_DIR/bin/fm-turnend-guard.sh" --claude
printf '[exit %s]\n' "$?"

banner "PART 2 - the session-start digest, as the reading agent sees it"
printf -- '--- LOCK section, session C (does not hold the home) ---\n'
as "$C" conv-charlie timeout 120 "$HOME_DIR/bin/fm-session-start.sh" 2>&1 \
  | grep -n -A 12 '^LOCK$'
printf -- '--- LOCK section, session B (background continuation of the holder) ---\n'
as "$B" conv-alpha timeout 120 "$HOME_DIR/bin/fm-session-start.sh" 2>&1 \
  | grep -n -A 12 '^LOCK$'
