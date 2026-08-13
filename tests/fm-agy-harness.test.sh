#!/usr/bin/env bash
# Behavior tests for the verified agy (Antigravity CLI) crewmate/scout adapter:
# harness detection, launch shape and model pin, the secondmate refusal, the
# claude-model refusal, and the guarded global Stop hook.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
HARNESS="$ROOT/bin/fm-harness.sh"
AGY_HOOK="$ROOT/bin/fm-agy-turnend-hook.sh"
TMP_ROOT=$(fm_test_tmproot fm-agy-harness)
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
JQ_BIN=$(command -v jq) || fail "test needs jq"

trap 'rm -rf "$TMP_ROOT"' EXIT

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window) exit 0 ;;
  capture-pane)
    printf '? for shortcuts                                          Gemini 3.1 Pro · high\n'
    exit 0
    ;;
  send-keys)
    prev=
    for arg in "$@"; do
      if [ "$prev" = -l ]; then
        printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"
        break
      fi
      prev=$arg
    done
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/agy" <<'SH'
#!/usr/bin/env bash
set -u
[ -n "${FM_FAKE_HARNESS_RESULT:-}" ] || exit 0
exec bash -c 'result=$($FM_FAKE_HARNESS_PROBE); printf "%s" "$result" > "$FM_FAKE_HARNESS_RESULT"'
SH
  chmod +x "$fakebin/agy"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  ln -s "$JQ_BIN" "$fakebin/jq"
  printf '%s\n' "$fakebin"
}

make_spawn_case() {
  local name=$1 case_dir home proj wt fakebin id
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="agy-$name-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" \
    "$home/.gemini/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "fm/$id"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$id"
}

run_agy_spawn() {  # <home> <proj> <wt> <fakebin> <id> [extra args...]
  local home=$1 proj=$2 wt=$3 fakebin=$4 id=$5
  shift 5
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_AGY_TRUST_POLLS=0 \
    FM_FAKE_LAUNCH_LOG="$home/launch.log" \
    HOME="$home" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" agy "$@" 2>&1
}

# --- detection --------------------------------------------------------------

test_detects_agy_process_ancestor() {
  local dir out
  dir="$TMP_ROOT/detect"
  mkdir -p "$dir"
  cp "$(command -v bash)" "$dir/agy"
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u CURSOR_AGENT \
    -u CURSOR_INVOKED_AS \
    "$dir/agy" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
  [ "$out" = agy ] || fail "fm-harness.sh under process agy reported '$out', expected agy"
  pass "agy is detected through an agy process ancestor"
}

test_detection_does_not_claim_agy_substrings() {
  local dir out
  dir="$TMP_ROOT/detect-neg"
  mkdir -p "$dir"
  for bin in magy agy-bin notagy; do
    cp "$(command -v bash)" "$dir/$bin"
    out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT \
      "$dir/$bin" -c "r=\$(\"$HARNESS\"); printf '%s' \"\$r\"")
    [ "$out" != agy ] || fail "fm-harness.sh misdetected unrelated process '$bin' as agy"
  done
  pass "agy detection does not claim unrelated agy-containing commands"
}

# --- spawn ------------------------------------------------------------------

test_spawn_launch_shape_pins_gemini_and_omits_effort() {
  local rec case_dir home proj wt fakebin id out status launch
  rec=$(make_spawn_case launch)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "agy spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=agy" "agy spawn did not report success"
  launch=$(cat "$home/launch.log")
  assert_contains "$launch" '--dangerously-skip-permissions' "agy launch omitted autonomy"
  assert_contains "$launch" "--model 'gemini-3.1-pro-high'" "agy launch did not pin gemini-3.1-pro-high"
  assert_contains "$launch" '--prompt-interactive' "agy launch omitted --prompt-interactive"
  assert_contains "$launch" 'encode launch-brief' "agy launch did not deliver the brief"
  assert_not_contains "$launch" '--effort' "agy launch passed --effort, which conflicts with *-high model ids"
  assert_grep 'harness=agy' "$home/state/$id.meta" "agy harness was not recorded in meta"
  assert_grep 'model=gemini-3.1-pro-high' "$home/state/$id.meta" "agy default model was not recorded"
  # The prompt must come AFTER the flags; --prompt-interactive --model swallows --model as the prompt.
  case "$launch" in
    *'--prompt-interactive'*'--model'*)
      fail "agy launch placed --prompt-interactive before --model, which consumes --model as the prompt"
      ;;
  esac
  pass "agy spawn pins gemini-3.1-pro-high, skips --effort, and keeps --prompt-interactive last"
}

test_spawn_omits_requested_effort_and_keeps_model_pin() {
  local rec case_dir home proj wt fakebin id launch
  rec=$(make_spawn_case effort)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off --effort low >/dev/null \
    || fail "agy spawn with effort low failed"
  launch=$(cat "$home/launch.log")
  assert_contains "$launch" "--model 'gemini-3.1-pro-high'" "agy effort spawn dropped the model pin"
  assert_not_contains "$launch" '--effort' "agy spawn forwarded --effort low, which conflicts with gemini-3.1-pro-high"
  assert_grep 'effort=low' "$home/state/$id.meta" "requested effort was not recorded in meta"
  pass "agy records requested effort in meta and omits it from the launch"
}

test_spawn_refuses_claude_model() {
  local rec case_dir home proj wt fakebin id out status
  rec=$(make_spawn_case claude-model)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  out=$(run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" \
    --mode no-mistakes --yolo off --model claude-sonnet-4-6)
  status=$?
  [ "$status" -ne 0 ] || fail "agy spawn accepted a claude model"
  assert_contains "$out" "claude" "agy claude-model refusal did not name the blocked model family"
  assert_absent "$home/state/$id.meta" "refused agy spawn still published task metadata"
  pass "agy spawn refuses claude-* models"
}

test_spawn_refuses_secondmate() {
  local case_dir home fakebin id out status
  case_dir="$TMP_ROOT/secondmate"
  home="$case_dir/home"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  id="agy-secondmate-x1"
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" \
    "$home/.gemini/config"
  printf 'charter\n' > "$home/data/$id/brief.md"
  out=$(cd "$case_dir" && FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" HOME="$home" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" agy --secondmate 2>&1)
  status=$?
  [ "$status" -ne 0 ] || fail "agy was accepted as a secondmate harness"
  assert_contains "$out" "crewmate/scout adapter only" "agy secondmate refusal did not explain the boundary"
  pass "agy is refused as a secondmate harness"
}

test_spawn_clears_inherited_foreign_harness_markers() {
  local rec case_dir home proj wt fakebin id result out status
  rec=$(make_spawn_case inherited-markers)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  result="$case_dir/harness-result"
  out=$(CLAUDECODE=1 PI_CODING_AGENT=true GROK_AGENT=1 FM_PI_HARNESS=pi-signed \
    FM_FAKE_HARNESS_RESULT="$result" FM_FAKE_HARNESS_PROBE="$HARNESS" \
    run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "agy spawn from a marked backend should succeed: $out"
  launch=$(cat "$home/launch.log")
  assert_contains "$launch" '-u CLAUDECODE' "agy launch did not clear an inherited CLAUDECODE"
  pass "agy launch clears foreign harness markers"
}

# --- turn-end hook ----------------------------------------------------------

test_hook_install_is_surgical_and_gated() {
  local home config hook registry
  home="$TMP_ROOT/hook-home"
  config="$home/.gemini/config/hooks.json"
  hook="$home/.gemini/config/fm-agy-turn-end.sh"
  registry="$home/.gemini/config/fm-agy-turn-end.d"
  mkdir -p "$home/.gemini/config"
  printf '%s\n' '{"captain-hook":{"Stop":[{"type":"command","command":"true"}]}}' > "$config"

  HOME="$home" "$AGY_HOOK" install || fail "agy hook install failed"
  assert_present "$hook" "install did not write the hook script"
  assert_present "$registry" "install did not create the token registry"
  "$PYTHON_BIN" - "$config" <<'PY' || fail "installed hooks.json is not valid JSON with both keys"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert "captain-hook" in data, data
assert "fm-agy-turn-end" in data, data
PY
  HOME="$home" "$AGY_HOOK" install || fail "second agy hook install failed"
  count=$("$PYTHON_BIN" - "$config" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
print(list(data).count("fm-agy-turn-end") + (1 if "fm-agy-turn-end" in data else 0) - 1)
PY
)
  # The key exists once.
  "$PYTHON_BIN" - "$config" <<'PY' || fail "idempotent install duplicated the Firstmate hook key"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert list(data.keys()).count("fm-agy-turn-end") == 1
PY

  HOME="$home" "$AGY_HOOK" remove || fail "agy hook removal failed"
  "$PYTHON_BIN" - "$config" <<'PY' || fail "removal dropped the captain hook or left the Firstmate key"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert "captain-hook" in data, data
assert "fm-agy-turn-end" not in data, data
PY
  assert_absent "$hook" "removal left the Firstmate hook script"
  pass "agy hook install is surgical and removal keeps foreign hooks"
}

test_hook_script_touches_only_a_matching_pointer() {
  local home hook wt token target payload
  home="$TMP_ROOT/hook-fire"
  mkdir -p "$home/.gemini/config/fm-agy-turn-end.d"
  HOME="$home" "$AGY_HOOK" install || fail "hook install for fire test failed"
  hook="$home/.gemini/config/fm-agy-turn-end.sh"
  wt="$home/wt"
  mkdir -p "$wt"
  token="fm.abcdefghijkl"
  target="$home/state/agy-fire.turn-ended"
  mkdir -p "$home/state"
  printf '%s\n' "$target" > "$home/.gemini/config/fm-agy-turn-end.d/$token"
  printf 'token=%s\n' "$token" > "$wt/.fm-agy-turnend"
  payload=$(printf '%s' "{\"workspacePaths\":[\"$wt\"]}")
  HOME="$home" "$hook" <<<"$payload"
  assert_present "$target" "matching pointer did not touch the turn-end marker"

  rm -f "$target"
  payload=$(printf '%s' '{"workspacePaths":["/tmp/not-a-firstmate-worktree"]}')
  HOME="$home" "$hook" <<<"$payload"
  assert_absent "$target" "a workspace without a pointer still touched the turn-end marker"
  pass "agy Stop hook is gated by the worktree pointer and registry token"
}

test_spawn_writes_turnend_pointer() {
  local rec case_dir home proj wt fakebin id
  rec=$(make_spawn_case turnend)
  IFS='|' read -r case_dir home proj wt fakebin id <<EOF
$rec
EOF
  run_agy_spawn "$home" "$proj" "$wt" "$fakebin" "$id" --mode no-mistakes --yolo off >/dev/null \
    || fail "agy spawn for turnend pointer failed"
  assert_present "$wt/.fm-agy-turnend" "agy spawn did not write the turn-end pointer"
  assert_present "$home/state/$id.agy-turnend-token" "agy spawn did not record the turn-end token"
  assert_present "$home/.gemini/config/hooks.json" "agy spawn did not install the global Stop hook"
  pass "agy spawn installs the gated global Stop hook and per-task pointer"
}

test_detects_agy_process_ancestor
test_detection_does_not_claim_agy_substrings
test_spawn_launch_shape_pins_gemini_and_omits_effort
test_spawn_omits_requested_effort_and_keeps_model_pin
test_spawn_refuses_claude_model
test_spawn_refuses_secondmate
test_spawn_clears_inherited_foreign_harness_markers
test_hook_install_is_surgical_and_gated
test_hook_script_touches_only_a_matching_pointer
test_spawn_writes_turnend_pointer
