#!/usr/bin/env bash
# tests/fm-session-identity-live-e2e.test.sh - the live session-identity guard
# (live-harness-optin family; task fm-session-lock-split-guard).
#
# bin/fm-session-lock-lib.sh decides who holds a home from two values the
# VENDOR emits into every tool shell and every hook process: CLAUDE_PID (the
# session's own harness process) and CLAUDE_CODE_SESSION_ID (the conversation).
# Per .agents/skills/firstmate-coding-guidelines that class of check must be
# proven against the real harness, because a fixture can only confirm the
# assumption already written into the fixture.
#
# This guard launches the real installed Claude Code once in an isolated lab,
# records the declared identity from a hook process, and then proves against
# those real values that:
#   - both the session's start and its stop declare the same identity;
#   - CLAUDE_PID names a live process the shared harness predicate accepts,
#     and fm_session_lock_self_pid prefers it over the ancestry walk;
#   - a process holding only the recorded conversation id inherits the helm
#     (the background-continuation case this task exists to fix);
#   - a different conversation id does not.
#
# Run explicitly with FM_SESSION_IDENTITY_LIVE=1. One tiny no-tool prompt is
# issued, so the model cost is negligible. An absent harness is reported and
# then FAILS rather than passing vacuously, because Claude Code is the only
# verified harness that declares this identity. Refresh
# docs/verification/runtime-backends.md ("Session identity") from this guard's
# output after any Claude Code upgrade.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ "${FM_SESSION_IDENTITY_LIVE:-0}" != 1 ]; then
  echo "skip: set FM_SESSION_IDENTITY_LIVE=1 to run the live session-identity guard"
  exit 0
fi

CLAUDE_VERSION=unknown
fail() { printf 'not ok - %s (harness claude %s)\n' "$1" "$CLAUDE_VERSION" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

if ! command -v claude >/dev/null 2>&1; then
  note "claude: NOT INSTALLED"
  fail "the live session-identity guard verified nothing"
fi
CLAUDE_VERSION=$(claude --version 2>/dev/null || echo unknown)
note "claude: $CLAUDE_VERSION"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-session-identity-live.XXXXXX") || exit 1
cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT

PROJECT="$LAB/project"
mkdir -p "$PROJECT/bin" "$PROJECT/.claude" "$LAB/probe"
cp "$ROOT/bin/fm-session-lock-lib.sh" "$ROOT/bin/fm-cursor-lib.sh" "$PROJECT/bin/"

# The probe runs as a real hook process, so it reads exactly what the vendor
# exports to the hooks and tool shells firstmate's scripts run in.
cat > "$PROJECT/bin/identity-probe.sh" <<'PROBE'
#!/usr/bin/env bash
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
cat >/dev/null 2>&1 || true
{
  printf 'declared_pid=%s\n' "${CLAUDE_PID:-}"
  printf 'declared_session=%s\n' "${CLAUDE_CODE_SESSION_ID:-}"
  printf 'session_pid=%s\n' "$(fm_harness_session_pid 2>/dev/null || echo NONE)"
  printf 'session_id=%s\n' "$(fm_harness_session_id 2>/dev/null || echo NONE)"
  printf 'self_pid=%s\n' "$(fm_session_lock_self_pid 2>/dev/null || echo NONE)"
  printf 'ancestry_pid=%s\n' "$(fm_harness_ancestry_pid 2>/dev/null || echo NONE)"
  if fm_harness_pid_alive "${CLAUDE_PID:-0}" 2>/dev/null; then
    printf 'declared_pid_is_live_harness=yes\n'
  else
    printf 'declared_pid_is_live_harness=no\n'
  fi
} > "$FM_IDENTITY_PROBE_DIR/$1"
exit 0
PROBE
chmod +x "$PROJECT/bin/identity-probe.sh"

cat > "$PROJECT/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/bin/identity-probe.sh start" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/bin/identity-probe.sh stop" } ] }
    ]
  }
}
JSON

(
  cd "$PROJECT" || exit 1
  FM_IDENTITY_PROBE_DIR="$LAB/probe" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
    claude -p 'Reply with exactly OK and stop. Use no tools.' \
      --dangerously-skip-permissions --effort low
) > "$LAB/claude.log" 2>&1 || fail "live Claude session failed: $(tail -5 "$LAB/claude.log")"

field() { sed -n "s/^$2=//p" "$LAB/probe/$1" 2>/dev/null; }

for phase in start stop; do
  [ -s "$LAB/probe/$phase" ] || fail "the $phase hook recorded no session identity at all"
done

START_PID=$(field start declared_pid)
START_ID=$(field start declared_session)
STOP_PID=$(field stop declared_pid)
STOP_ID=$(field stop declared_session)

case "$START_PID" in
  ''|*[!0-9]*) fail "CLAUDE_PID is not a pid at session start: '$START_PID'" ;;
esac
[ -n "$START_ID" ] || fail "CLAUDE_CODE_SESSION_ID is empty at session start"
[ "$START_PID" = "$STOP_PID" ] || fail "CLAUDE_PID changed within one session: $START_PID then $STOP_PID"
[ "$START_ID" = "$STOP_ID" ] || fail "CLAUDE_CODE_SESSION_ID changed within one session: $START_ID then $STOP_ID"
pass "the real harness declares one session identity to every hook process"

[ "$(field start declared_pid_is_live_harness)" = yes ] \
  || fail "CLAUDE_PID $START_PID is not a live harness process by the shared predicate"
[ "$(field start session_pid)" = "$START_PID" ] || fail "fm_harness_session_pid did not return CLAUDE_PID"
[ "$(field start session_id)" = "$START_ID" ] || fail "fm_harness_session_id did not return CLAUDE_CODE_SESSION_ID"
[ "$(field start self_pid)" = "$START_PID" ] \
  || fail "fm_session_lock_self_pid preferred the ancestry walk over the declared pid"
note "ancestry walk from the hook process resolved: $(field start ancestry_pid)"
pass "the declared identity is live, and the shared resolver prefers it over the ancestry walk"

# The background-continuation case, replayed against the values the real
# harness just produced: a process that holds the conversation id but is
# nowhere in the lock owner's process tree still holds the helm.
STATE="$LAB/state"
mkdir -p "$STATE"
printf '%s\n' "$START_PID" > "$STATE/.lock"
printf '%s\n' "$START_ID" > "$STATE/.lock.session"

owned_with() {
  env -u CLAUDE_PID CLAUDE_CODE_SESSION_ID="$1" bash -c '
    . "$1/bin/fm-session-lock-lib.sh"
    fm_session_lock_owned_by_self "$2"
  ' _ "$PROJECT" "$STATE"
}

owned_with "$START_ID" \
  || fail "a continuation of the real conversation $START_ID was refused the helm"
if owned_with "${START_ID}-not-this-conversation"; then
  fail "a different conversation id was granted the helm"
fi
pass "a continuation of the real conversation inherits the helm, and a stranger does not"

printf '# fm-session-identity-live-e2e: verified against claude %s\n' "$CLAUDE_VERSION"
