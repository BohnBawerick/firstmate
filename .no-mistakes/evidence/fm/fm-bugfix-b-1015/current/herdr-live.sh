#!/usr/bin/env bash
set -euo pipefail
ROOT=$1
EVIDENCE=$(cd "$(dirname "$0")" && pwd)
export TMPDIR="$ROOT/.test-phase/runtime"
export FM_HERDR_LAB_STATE_DIR="$ROOT/.test-phase/herdr-state"

export CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0
ORIGINAL_PATH=$PATH
HELPER="$ROOT/bin/fm-herdr-lab.sh"
SESSION=$(bash "$HELPER" name bundle-b-proof)
LAB="$ROOT/.test-phase/herdr-home-final"
bash "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
unset FM_HOME
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
mkdir -p "$ROOT/.test-phase/herdr-bin"
cleanup() { env PATH="$ORIGINAL_PATH" bash "$HELPER" teardown "$SESSION"; }
trap cleanup EXIT
bash "$HELPER" provision "$SESSION"
cat > "$ROOT/.test-phase/herdr-bin/herdr" <<EOF
#!/usr/bin/env bash
args=("\$@")
n=\${#args[@]}
[ "\${args[\$((n-2))]}" = --session ] && [ "\${args[\$((n-1))]}" = '$SESSION' ] || exit 98
exec env PATH='$ORIGINAL_PATH' bash '$HELPER' run '$SESSION' "\${args[@]:0:\$((n-2))}"
EOF
chmod +x "$ROOT/.test-phase/herdr-bin/herdr"
export PATH="$ROOT/.test-phase/herdr-bin:$ORIGINAL_PATH"
. "$ROOT/bin/backends/herdr.sh"
lab() { env PATH="$ORIGINAL_PATH" bash "$HELPER" run "$SESSION" "$@"; }
CJSON=$(lab workspace create --cwd "$ROOT" --label codex-idle-proof --no-focus)
CPANE=$(jq -er '.result.root_pane.pane_id' <<< "$CJSON")
CTARGET="$SESSION:$CPANE"
lab pane run "$CPANE" "codex -m gpt-6-astra -c 'projects.\"$ROOT\".trust_level=\"trusted\"'" >/dev/null
env PATH="$ORIGINAL_PATH" bash "$HELPER" viewer start "$SESSION" >/dev/null
ready=0
for i in {1..80}; do
  screen=$(lab pane read "$CPANE" --source visible)
  case "$screen" in
    *'Hooks need review'*) lab pane send-keys "$CPANE" 3 enter >/dev/null ;;
  esac
  case "$screen" in *'for shortcuts'*) ready=1; break ;; esac
  sleep 0.5
done
[ "$ready" = 1 ] || { printf '%s\n' "$screen"; echo 'Codex did not reach its real composer'; exit 1; }
state=$(fm_backend_herdr_composer_state "$CTARGET")
lab pane read "$CPANE" --source visible > "$EVIDENCE/codex-idle-pane.txt"
printf 'Codex idle through actual Herdr adapter after onboarding: %s\n' "$state"
cat "$EVIDENCE/codex-idle-pane.txt"
[ "$state" = empty ]
fm_backend_herdr_send_literal "$CTARGET" 'UNSUBMITTED_DRAFT_LIVE_GUARD'
sleep 0.5
state=$(fm_backend_herdr_composer_state "$CTARGET")
printf 'Real literal draft is pending: %s\n' "$state"
[ "$state" = pending ]
lab pane read "$CPANE" --source visible > "$EVIDENCE/codex-pending-draft.txt"
JSON=$(lab workspace create --cwd "$ROOT" --label claude-composer-proof --no-focus)
PANE=$(jq -er '.result.root_pane.pane_id' <<< "$JSON")
TARGET="$SESSION:$PANE"
lab pane run "$PANE" "claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null
for i in {1..60}; do
  screen=$(lab pane read "$PANE" --source visible)
  case "$screen" in
    *'Yes, I trust this folder'*) lab pane send-keys "$PANE" down enter >/dev/null ;;
    *'bypass permissions on'*) [ "$(fm_backend_herdr_composer_state "$TARGET")" != empty ] || break ;;
  esac
  sleep 1
done
[ "$(fm_backend_herdr_composer_state "$TARGET")" = empty ]
periodic=$(printf 'abcdefgh%.0s' {1..30})
short=$(printf 'abcdefgh%.0s' {1..20})
fm_backend_herdr_send_literal "$TARGET" "$short"
sleep 1
seen=$(fm_backend_herdr_composer_content "$TARGET")
printf 'Ambiguous periodic draft: expected=%s bytes; typed=%s; observed=%s\n' "${#periodic}" "${#short}" "${#seen}"
if fm_backend_herdr_composer_scrolled_payload_shown "$TARGET" "$periodic" "$seen"; then
  echo 'ERROR: truncated periodic composer was accepted'; exit 1
fi
printf 'Real Claude periodic draft proof: refused; Enter withheld\n'
lab pane read "$PANE" --source visible > "$EVIDENCE/claude-periodic-draft.txt"
fm_backend_herdr_composer_clear "$TARGET" "$short"
RIGHT=$(lab pane split "$PANE" --direction right --ratio 0.4 --cwd "$ROOT" | jq -er '.result.pane.pane_id')
DOWN=$(lab pane split "$PANE" --direction down --ratio 0.55 --cwd "$ROOT" | jq -er '.result.pane.pane_id')
sleep 2
TOKEN="NARROWLIVE${RANDOM}PONG"
TEXT="Reply with exactly $TOKEN and nothing else. This sentence only pads the request so that it wraps past the composer's visible rows in a narrow pane, and this one pads it a little further."
fm_backend_herdr_send_literal "$TARGET" "$TEXT"
sleep 1
seen=$(fm_backend_herdr_composer_content "$TARGET")
printf 'Narrow expected payload: %s\nNarrow observed composer tail: %s\n' "$TEXT" "$seen"
if fm_backend_herdr_composer_payload_shown "$TEXT" "$seen"; then echo 'ERROR: pane not narrow enough'; exit 1; fi
lab pane read "$PANE" --source visible > "$EVIDENCE/claude-narrow-before.txt"
fm_backend_herdr_composer_clear "$TARGET" "$TEXT"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$TEXT" 3 0.4 0.4)
printf 'Narrow send result: %s\n' "$verdict"
[ "$verdict" = empty ]
for i in {1..45}; do
  screen=$(lab pane read "$PANE" --source recent --lines 200)
  [ "$(grep -Fc "$TOKEN" <<< "$screen")" -lt 2 ] || break
  sleep 1
done
[ "$(grep -Fc "$TOKEN" <<< "$screen")" -ge 2 ]
printf '%s\n' "$screen" > "$EVIDENCE/claude-narrow-reply.txt"
cat "$EVIDENCE/claude-narrow-reply.txt"
echo 'LIVE HERDR SCENARIOS PASSED'
