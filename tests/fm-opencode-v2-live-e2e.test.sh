#!/usr/bin/env bash
# Opt-in OpenCode v2 worker guard in a named, guarded Herdr lab.
# Exercises the production launcher and generated busy plugin, composer input,
# busy steering, interrupt, /exit, native --continue, and plugin re-generation.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_OPENCODE_V2_LIVE herdr jq opencode
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane
VERSION=$(opencode --version)
[ "$(bash "$ROOT/bin/fm-opencode-launch.sh" --major-version)" = 2 ] || {
  echo "skip: OpenCode v2 guard requires 2.x, installed $VERSION"
  exit 0
}
ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name opencode-v2-live)
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-opencode-v2-live.XXXXXX")
WORK="$TMP_ROOT/project"
STATE="$TMP_ROOT/state"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$WORK/.opencode/plugins/lib" "$STATE" "$FAKEBIN"
cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then rc=1; fi
  if [ "${FM_OPENCODE_V2_KEEP_PROOF:-0}" = 1 ]; then
    printf '# OpenCode v2 proof retained at %s\n' "$TMP_ROOT"
  else
    rm -rf "$TMP_ROOT"
  fi
  exit "$rc"
}
trap cleanup EXIT
cat > "$FAKEBIN/herdr" <<SH
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
[ "\$n" -ge 2 ] && [ "\${args[n-2]}" = --session ] && [ "\${args[n-1]}" = "$SESSION" ] || exit 97
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]:0:n-2}"
SH
chmod +x "$FAKEBIN/herdr"
"$LAB_HELPER" provision "$SESSION" || fail 'could not provision guarded Herdr lab'
export PATH="$FAKEBIN:$ORIGINAL_PATH"
# shellcheck source=bin/backends/herdr.sh
. "$ROOT/bin/backends/herdr.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=bin/fm-opencode-busy-lib.sh
. "$ROOT/bin/fm-opencode-busy-lib.sh"
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
# Include every tracked primary plugin to prove a Firstmate worker checkout can load.
cp "$ROOT"/.opencode/plugins/fm-primary-*.js "$ROOT/.opencode/plugins/package.json" "$WORK/.opencode/plugins/"
cp "$ROOT"/.opencode/plugins/lib/*.js "$WORK/.opencode/plugins/lib/"
gen=$(bash "$ROOT/bin/fm-busy-event.sh" arm "$STATE" live)
fm_opencode_write_busy_plugin "$WORK/.opencode/plugins/fm-busy-state.js" 2 "$ROOT" "$STATE" live "$gen" "$STATE/live.turn-ended" true
workspace=$(lab workspace create --cwd "$WORK" --label opencode-v2 --no-focus) || fail 'could not create lab workspace'
PANE=$(printf '%s' "$workspace" | jq -er '.result.root_pane.pane_id') || fail 'missing lab pane'
TARGET="$SESSION:$PANE"
# Shell-quote paths because the native pane runs its own shell.
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
launch="$(quote "$ROOT/bin/fm-opencode-launch.sh") --model opencode/deepseek-v4.1-flash-free --effort high --prompt 'Reply exactly V2LAUNCHOK. Do not use tools or delegate.'"
lab pane run "$PANE" "$launch" >/dev/null || fail "could not launch $VERSION"
screen() { lab pane read "$PANE" --source visible; }
wait_text() {
  local pattern=$1 i
  for ((i=0; i<160; i++)); do
    screen > "$TMP_ROOT/screen.txt"
    grep -Eq "$pattern" "$TMP_ROOT/screen.txt" && return 0
    sleep 0.5
  done
  fail "$VERSION never rendered $pattern; proof $TMP_ROOT/screen.txt"
}
wait_busy() {
  local want=$1 i
  for ((i=0; i<160; i++)); do
    if grep -q "state=$want source=opencode-plugin" "$STATE/live.busy-state"; then return 0; fi
    sleep 0.5
  done
  fail "$VERSION plugin did not report $want"
}
wait_composer() {
  local want=$1 i verdict
  for ((i=0; i<60; i++)); do
    verdict=$(fm_backend_herdr_composer_state "$TARGET")
    [ "$verdict" = "$want" ] && return 0
    sleep 0.1
  done
  fm_backend_herdr_visible_capture_ansi "$TARGET" > "$TMP_ROOT/composer-failure.ansi"
  fail "$VERSION expected $want composer, got $verdict; proof $TMP_ROOT/composer-failure.ansi"
}
wait_text '^[[:space:]]+V2LAUNCHOK[[:space:]]*$'
wait_text 'Build auto .* high'
wait_busy idle
[ -f "$STATE/live.turn-ended" ] || fail "$VERSION did not notify turn end"
wait_composer empty
fm_backend_herdr_visible_capture_ansi "$TARGET" > "$TMP_ROOT/idle.ansi"
pass "$VERSION launch submits its prompt at DeepSeek high and plugin settles idle"
lab pane send-text "$PANE" 'Draft for composer proof' >/dev/null
wait_text 'Draft for composer proof'
wait_composer pending
fm_backend_herdr_visible_capture_ansi "$TARGET" > "$TMP_ROOT/pending.ansi"
lab pane send-keys "$PANE" ctrl+u >/dev/null
sleep 0.3
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" 'Without tools or delegation, write a detailed 2000 word explanation of parsing JSON.' 3 0.4 0.4)
[ "$verdict" = empty ] || fail "$VERSION idle steer returned $verdict"
wait_busy busy
[ "$(fm_backend_herdr_composer_state "$TARGET")" = empty ] || fail "$VERSION busy furniture is not empty"
fm_backend_herdr_visible_capture_ansi "$TARGET" > "$TMP_ROOT/busy.ansi"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" 'Stop that explanation and reply exactly V2BUSYSTEEROK.' 3 0.4 0.4)
[ "$verdict" = empty ] || fail "$VERSION busy Enter returned $verdict"
wait_text '^[[:space:]]+V2BUSYSTEEROK[[:space:]]*$'
wait_busy idle
pass "$VERSION idle and busy steering clear the composer and reach the model"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" 'Without tools or delegation, write a detailed 2000 word explanation of parsing XML.' 3 0.4 0.4)
[ "$verdict" = empty ] || fail "$VERSION interrupt probe submission returned $verdict"
wait_busy busy
lab pane send-keys "$PANE" escape >/dev/null
sleep 0.2
lab pane send-keys "$PANE" escape >/dev/null
wait_busy idle
pass "$VERSION Double Escape interrupts and plugin settles idle"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" '/exit' 3 0.4 0.4)
case "$verdict" in empty|unknown-confirmed) ;; *) fail "$VERSION /exit submission returned $verdict" ;; esac
wait_text 'Continue[[:space:]]+opencode -s ses_'
# Regenerate the plugin under a fresh incarnation, then resume the same session.
# The private server must load this new generation, not a service-cached module.
gen=$(bash "$ROOT/bin/fm-busy-event.sh" arm "$STATE" live)
fm_opencode_write_busy_plugin "$WORK/.opencode/plugins/fm-busy-state.js" 2 "$ROOT" "$STATE" live "$gen" "$STATE/live.turn-ended" true
lab pane run "$PANE" "opencode --standalone --auto --continue --prompt 'Reply exactly V2RESUMEOK. Do not use tools or delegate.'" >/dev/null || fail "$VERSION --continue launch failed"
wait_text '^[[:space:]]+V2RESUMEOK[[:space:]]*$'
wait_busy idle
pass "$VERSION /exit and --continue preserve the session and refresh the busy generation"

verdict=$(fm_backend_herdr_send_text_submit "$TARGET" '/exit' 3 0.4 0.4)
case "$verdict" in empty|unknown-confirmed) ;; *) fail "$VERSION second /exit returned $verdict" ;; esac
wait_text 'Continue[[:space:]]+opencode -s ses_'
launch="$(quote "$ROOT/bin/fm-opencode-launch.sh") --model opencode/deepseek-v4.1-flash-free --effort max --prompt 'Reply exactly V2MAXOK. Do not use tools or delegate.'"
lab pane run "$PANE" "$launch" >/dev/null || fail "$VERSION max-effort launch failed"
wait_text '^[[:space:]]+V2MAXOK[[:space:]]*$'
wait_text 'Build auto .* max'
wait_busy idle
pass "$VERSION requested max and high both reach the pane through session model.variant"
