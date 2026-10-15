#!/usr/bin/env bash
# Live Herdr submit-confirmation guard (live-harness-optin family).
#
# Herdr's native agent_status can stay idle for a whole landed Claude turn, and
# a busy-queued Enter can keep proven pending text visible. A stub cannot prove
# either signal. This guard launches real Claude Code in an isolated Herdr lab
# and requires fm_backend_herdr_send_text_submit to report empty for a landed
# idle steer. It then requires the same submit path to prove and submit a
# typed /exit slash command behind the command popup Claude renders below the
# composer (the fm-control exit breakage on 2.1.283) and verifies the agent
# actually exited. It fails naming the harness and version rather than
# degrading quietly.
#
# Run explicitly with FM_HERDR_SUBMIT_CONFIRM_LIVE=1 after a Herdr or Claude
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Herdr submit confirmation" entry.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$PWD/tests/lib.sh"

ROOT="$PWD"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_HERDR_SUBMIT_CONFIRM_LIVE herdr jq claude

[ -x "$LAB_HELPER" ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name herdr-submit-confirm-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-submit-confirm-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
CHECKED=0
"$ROOT/bin/fm-lab-home.sh" create "$TMP_ROOT/home" >/dev/null || exit 1

cleanup() {
  local rc=$?
  trap - EXIT
  lab pane read "$PANE" --source recent --lines 200 > "$FM_GATE_EVIDENCE/r2-draft-final-pane.txt" 2>/dev/null || true
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
out=\$(env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}")
rc=\$?
if [ "\${args[0]:-}" = pane ] && [ "\${args[1]:-}" = read ]; then
  printf '%s' "\$out" | jq -Rs '{frame:.}' >> "$FM_GATE_EVIDENCE/r2-draft-frames.jsonl"
fi
printf '%s\n' "\$out"
exit "\$rc"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
mkdir -p "$TMP_ROOT/project"
git -C "$TMP_ROOT/project" init -q -b main
git -C "$TMP_ROOT/project" -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty -qm 'lab root'
WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-submitlive --no-focus) \
  || fail "could not create the isolated submit-confirm workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
VERSION=$("$ROOT/.no-mistakes/live-tools/claude-current/node_modules/.bin/claude" --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

lab pane run "$PANE" "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME='$TMP_ROOT/home' CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 '/home/bohn/.no-mistakes/worktrees/842a31c92d33/01M4ZWV8H0KM2V907GBD81WBZV/.no-mistakes/live-tools/claude-current/node_modules/.bin/claude' --setting-sources project,local --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null \
  || fail "could not launch Claude Code ($VERSION) in the isolated Herdr pane"

idle=0
trusted=0
i=0
while [ "$i" -lt 60 ]; do
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  case "$screen" in
    *'bypass permissions on'*)
      # The composer footer means Claude is past any folder-trust prompt. Herdr
      # can report the agent idle while that prompt is still up, so the wait
      # keys off the rendered composer rather than the native status alone.
      st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
      case "$st" in idle|done) idle=1; break ;; esac
      ;;
    *'Yes, I trust this folder'*)
      # A fresh checkout path stops on Claude's folder-trust prompt, which the
      # pre-send proof would read as a non-empty composer. Accept it once and
      # keep waiting for a real idle composer; the accepted dialog stays in the
      # viewport. The prompt preselects "No, exit", so move to "Yes" before
      # confirming; a bare Enter quits Claude.
      if [ "$trusted" = 0 ]; then
        trusted=1
        lab pane send-keys "$PANE" down enter >/dev/null \
          || fail "could not accept Claude's folder-trust prompt"
      fi
      ;;
  esac
  i=$((i + 1))
  sleep 1
done
[ "$idle" = 1 ] || fail "Claude Code ($VERSION) on $HERDR_VER never rendered an idle composer in the lab pane"

for i in $(seq 1 45); do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in idle|done) break ;; esac
  sleep 1
done
cat > "$TMP_ROOT/home/state/draft.meta" <<EOF
kind=ship
endpoint_task_id=draft
harness=claude
backend=herdr
window=$TARGET
herdr_session=$SESSION
herdr_workspace_id=$(printf '%s' "$WS_JSON" | jq -r '.result.workspace.workspace_id')
herdr_tab_id=$(printf '%s' "$WS_JSON" | jq -r '.result.tab.tab_id')
herdr_pane_id=$PANE
worktree=$ROOT
project=$ROOT
branch=main
EOF
lab pane send-text "$PANE" '/exit unsent draft' >/dev/null || fail 'could not type the adversarial draft'
sleep 1
state=$(fm_backend_herdr_composer_state "$TARGET")
[ "$state" = pending ] || fail "draft read $state, expected pending"
lab pane read "$PANE" --source visible > "$FM_GATE_EVIDENCE/r2-draft-before.txt"
rc=0
out=$(FM_HOME="$TMP_ROOT/home" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-control.sh" draft exit 2>&1) || rc=$?
printf 'fm-control draft exit: exit=%s\n%s\n' "$rc" "$out"
[ "$rc" != 0 ] || fail 'public exit accepted an unsent draft'
case "$out" in *"composer visibly holds pending text"*) : ;; *) fail "unexpected refusal: $out" ;; esac
lab pane read "$PANE" --source visible > "$FM_GATE_EVIDENCE/r2-draft-after-refusal.txt"
grep -Fq '/exit unsent draft' "$FM_GATE_EVIDENCE/r2-draft-after-refusal.txt" || fail 'refused exit changed the draft'
lab agent get "$PANE" >/dev/null || fail 'refused exit stopped the agent'
pass 'public fm-control refuses exit and preserves the visible draft and live agent'
lab pane send-keys "$PANE" ctrl+u >/dev/null || fail 'could not clear test draft'
sleep 1
out=$(FM_HOME="$TMP_ROOT/home" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-control.sh" draft exit 2>&1) || fail "public exit failed on an empty composer: $out"
printf '%s\n' "$out"
if lab agent get "$PANE" >/dev/null 2>&1; then fail 'public exit returned before the agent stopped'; fi
pass 'public fm-control exits the agent after the draft is cleared'
