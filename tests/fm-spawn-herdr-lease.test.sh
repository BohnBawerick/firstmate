#!/usr/bin/env bash
# fm-spawn.sh on the Herdr backend: a fresh task copy is leased durably and the
# pane's TOP-LEVEL shell is moved into it.
#
# Herdr restores a pane from the cwd of its top-level shell, and the pane's
# `cwd` field does not follow a nested shell (only `foreground_cwd` does). The
# interactive `treehouse get` runs a subshell, so the later `cd` landed inside
# it and a host restart reopened every worker in the primary clone. These cases
# pin the replacement: `treehouse get --lease`, then a cd the stub applies to
# the top-level shell, never the interactive form.
#
# Canned/stateful fakes only - never a real herdr session or a real pool.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-herdr-lease)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# make_lease_case <name>: a home, a project, and the leased task copy.
# The fake herdr models the two cwd fields: `cd` sent to the pane moves the
# restorable top-level cwd ($D/cwd) and, unless a nested shell is running,
# the foreground cwd with it. The fake treehouse opens that nested shell for
# the interactive form, which is exactly what must not be used.
make_lease_case() {
  local name=$1 harness=${2:-codex} dir home proj wt fb d
  dir="$TMP_ROOT/$name"
  home="$dir/home"
  proj="$dir/project"
  wt="$dir/slot"
  d="$dir/fake"
  fb="$dir/fakebin"
  mkdir -p "$d" "$fb" "$dir/user-home"
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "slot-$name"
  fm_test_spawn_brief "$home" "$name" "Exercise the Herdr task-copy lease for $name."
  printf '%s' "$proj" > "$d/cwd"
  printf '%s' "$proj" > "$d/fg"
  : > "$d/treehouse-log"
  : > "$d/herdr-log"
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/treehouse-log"
case "$*" in
  'get --lease '*) : > "$D/lease-attempted"
    [ ! -f "$D/lease-fails" ] || { echo 'lease failed' >&2; exit 1; }
    printf '%s\n' "$FM_FAKE_SLOT" ;;
  'get') printf '%s' "$FM_FAKE_SLOT" > "$D/fg" ;;
  'return --force '*) : > "$D/returned" ;;
esac
exit 0
SH
  printf '{"workspaces":[],"tabs":[]}\n' > "$d/topology.json"
  cat > "$fb/herdr" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/herdr-log"
jq_state() { jq "$@" "$D/topology.json"; }
save_state() { cat > "$D/topology.tmp.$$" && mv "$D/topology.tmp.$$" "$D/topology.json"; }
workspace= label= cwd=
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --workspace) workspace=${args[$((i+1))]:-} ;;
    --label) label=${args[$((i+1))]:-} ;;
    --cwd) cwd=${args[$((i+1))]:-} ;;
  esac
done
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  printf '{"client":{"version":"0.9.0","protocol":22},"server":{"running":true,"version":"0.9.0","protocol":22}}\n'
  exit 0
fi
[ "${1:-}" != server ] || exit 0
case "${1:-} ${2:-}" in
  'session list')
    printf '{"sessions":[{"name":"default","running":true,"socket_path":"%s/herdr.sock"}]}\n' "$D"
    exit 0 ;;
  'terminal title') printf '{"result":{"reason":"no_foreground_client"}}\n'; exit 0 ;;
  'pane close')
    if [ -f "$D/lease-attempted" ] && [ ! -f "$D/close-allowed" ]; then exit 1; fi
    jq_state --arg p "${3:-}" '.tabs |= [.[] | select(.pane_id != $p)]' | save_state
    [ "${3:-}" != w2:p2 ] || : > "$D/task-pane-closed"
    exit 0 ;;
  'pane get')
    if ! jq_state -e --arg p "${3:-}" '[.tabs[] | select(.pane_id == $p)] | length == 1' >/dev/null; then
      printf '{"error":{"code":"pane_not_found"}}\n'
    else
      jq_state --arg p "${3:-}" --arg cwd "$(cat "$D/cwd")" --arg fg "$(cat "$D/fg")" \
        '{result:{pane:(.tabs[] | select(.pane_id == $p) | . + {cwd:$cwd,foreground_cwd:$fg})}}'
    fi
    exit 0 ;;
  'pane run' | 'pane send-text')
    payload=${4:-}
    case "$payload" in
      ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; [ ! -f "$staged" ] || payload=$(cat "$staged") ;;
    esac
    case "$payload" in
      'cd -- '*) path=${payload#cd -- }; path=${path#\'}; path=${path%\'}
        printf '%s' "$path" > "$D/cwd"; printf '%s' "$path" > "$D/fg" ;;
      *'encode launch-brief'* | *'Firstmate operational input waiting: read'*)
        [ ! -f "$D/launch-send-fails" ] || exit 1
        printf '%s\n' "$payload" > "$D/launched-command"
        : > "$D/herdr-agent-live" ;;
    esac
    exit 0 ;;
  'agent get')
    if [ -f "$D/herdr-agent-live" ]; then
      printf '{"result":{"agent":{"agent_status":"idle"}}}\n'
    else
      printf '{"error":{"code":"agent_not_found"}}\n'
    fi
    exit 0 ;;
  'workspace list') jq_state '{result:{workspaces:.workspaces}}'; exit 0 ;;
  'workspace create')
    n=$(jq_state '.workspaces | length + 1')
    ws="w$n"; tab="$ws:t1"; pane="$ws:p1"
    jq_state --arg w "$ws" --arg t "$tab" --arg p "$pane" --arg label "$label" --arg cwd "$cwd" \
      '.workspaces += [{workspace_id:$w,label:$label,focused:(.workspaces|length == 0),active_tab_id:$t}]
       | .tabs += [{workspace_id:$w,tab_id:$t,pane_id:$p,label:"1",cwd:$cwd,focused:($w == "w1")}]' | save_state
    jq -n --arg w "$ws" --arg t "$tab" --arg p "$pane" \
      '{result:{workspace:{workspace_id:$w},tab:{tab_id:$t},root_pane:{pane_id:$p}}}'
    exit 0 ;;
  'tab list') jq_state --arg w "$workspace" '{result:{tabs:[.tabs[] | select(.workspace_id == $w)]}}'; exit 0 ;;
  'pane list')
    jq_state --arg w "$workspace" '{result:{panes:[.tabs[] | select(.workspace_id == $w) | {pane_id,tab_id,workspace_id}]}}'
    exit 0 ;;
  'tab get') jq_state --arg t "${3:-}" '{result:{tab:(.tabs[] | select(.tab_id == $t))}}'; exit 0 ;;
  'tab close')
    jq_state --arg t "${3:-}" '.tabs |= [.[] | select(.tab_id != $t)]
      | .tabs as $tabs | .workspaces |= map(. as $w | .active_tab_id = ([$tabs[] | select(.workspace_id == $w.workspace_id)][0].tab_id))' | save_state
    exit 0 ;;
  'tab create')
    tab="$workspace:t2"; pane="$workspace:p2"
    jq_state --arg w "$workspace" --arg t "$tab" --arg p "$pane" --arg label "$label" --arg cwd "$cwd" \
      '.tabs += [{workspace_id:$w,tab_id:$t,pane_id:$p,label:$label,cwd:$cwd,focused:false}]' | save_state
    jq -n --arg t "$tab" --arg p "$pane" '{result:{tab:{tab_id:$t},root_pane:{pane_id:$p}}}'
    exit 0 ;;
esac
exit 0
SH
  cat > "$fb/polytoken" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"print models"*) printf 'zai/glm-5.3-flash\nzai/glm-5.3-flash(low)\n' ;;
esac
exit 0
SH
  chmod +x "$fb/treehouse" "$fb/herdr" "$fb/polytoken"
  fm_test_fake_sleep_noop "$fb"
  printf '%s\n' "$dir"
}

run_lease_spawn() {  # <case-dir> <id> [extra spawn args...]
  local dir=$1 id=$2
  shift 2
  env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH \
    -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_FAKE_SLOT="$dir/slot" HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$id" "$dir/project" --backend herdr --mode no-mistakes --yolo off "$@" 2>&1
}

test_fresh_spawn_leases_and_moves_the_top_level_shell() {
  local id=lease-top-level dir out status
  dir=$(make_lease_case "$id")
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed"$'\n'"$out"
  assert_grep "get --lease --lease-holder $id" "$dir/fake/treehouse-log" \
    "the task copy was not leased durably under the task id"
  ! grep -qx 'get' "$dir/fake/treehouse-log" \
    || fail "the interactive treehouse get opened a nested shell the restore cannot see"
  [ "$(cat "$dir/fake/cwd")" = "$dir/slot" ] \
    || fail "the pane's restorable top-level cwd is '$(cat "$dir/fake/cwd")', not the task copy"
  assert_grep "worktree=$dir/slot" "$dir/home/state/$id.meta" "meta did not record the leased copy"
  pass "a fresh herdr spawn leases the copy and moves the pane's top-level shell into it"
}

test_failed_lease_refuses_without_a_record() {
  local id=lease-refused dir out status
  dir=$(make_lease_case "$id")
  : > "$dir/fake/lease-fails"
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn went on without a leased copy"$'\n'"$out"
  assert_contains "$out" "treehouse get --lease failed" "the refusal did not name the failed lease"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "refused spawn published task metadata"
  ! grep -qx 'get' "$dir/fake/treehouse-log" || fail "a refused lease fell back to the interactive form"
  pass "a failed lease refuses the spawn and falls back to nothing"
}

test_aborted_spawn_names_the_lease_it_keeps() {
  local id=lease-aborted dir out status
  dir=$(make_lease_case "$id")
  echo dirty >> "$dir/slot/README.md"
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched into a dirty leased copy"$'\n'"$out"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "refused spawn published task metadata"
  assert_contains "$out" "stays leased to $id" "an abort did not name the lease that outlives the pane"
  assert_contains "$out" "treehouse return --force $dir/slot" "an abort did not name the command that releases it"
  [ ! -e "$dir/fake/returned" ] || fail "an abort with the endpoint still open returned a slot the operator may want to inspect"
  pass "an aborted spawn keeps the lease and names the command that releases it"
}

test_rolled_back_spawn_after_launch_names_the_lease_it_keeps() {
  local id=lease-after-launch dir out status
  dir=$(make_lease_case "$id")
  : > "$dir/fake/launch-send-fails"
  out=$(run_lease_spawn "$dir" "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded although its launch was not delivered"$'\n'"$out"
  [ ! -e "$dir/home/state/$id.meta" ] || fail "the failed spawn kept its task record"
  assert_contains "$out" "stays leased to $id" "a rolled-back spawn after its launch left the lease unnamed"
  assert_contains "$out" "treehouse return --force $dir/slot" "a rolled-back spawn after its launch did not name the command that releases it"
  [ ! -e "$dir/fake/returned" ] || fail "an abort with the endpoint still open returned a slot the operator may want to inspect"
  pass "a spawn rolled back after its launch keeps the lease and names the command that releases it"
}

# abort_polytoken_spawn <id> <dirty|launch-fails> [close-allowed]: an abort
# tries to close its pane under the lock already held for initial placement.
# The fake can refuse that close, leaving the pane and its lease intact.
abort_polytoken_spawn() {
  local id=$1 dir
  dir=$(make_lease_case "$id" polytoken)
  case "$2" in
    dirty) echo dirty >> "$dir/slot/README.md" ;;
    launch-fails) : > "$dir/fake/launch-send-fails" ;;
  esac
  [ -z "${3:-}" ] || : > "$dir/fake/close-allowed"
  LEASE_OUT=$(run_lease_spawn "$dir" "$id" --model zai/glm-5.3-flash --effort low)
  LEASE_STATUS=$?
  LEASE_DIR=$dir
}

test_abort_returns_a_clean_lease_once_the_pane_is_gone() {
  local id=lease-pane-gone
  abort_polytoken_spawn "$id" launch-fails close-allowed
  [ "$LEASE_STATUS" -ne 0 ] || fail "spawn succeeded although its launch was not delivered"$'\n'"$LEASE_OUT"
  [ ! -e "$LEASE_DIR/home/state/$id.meta" ] || fail "the failed spawn kept its task record"
  assert_grep 'pane close' "$LEASE_DIR/fake/herdr-log" "the abort did not close its pane"$'\n'"$LEASE_OUT"
  [ -e "$LEASE_DIR/fake/returned" ] || fail "the abort kept a clean lease although its pane is gone"$'\n'"$LEASE_OUT"
  pass "an abort whose pane Herdr reports gone returns a clean lease"
}

test_abort_keeps_a_dirty_lease_once_the_pane_is_gone() {
  local id=lease-pane-gone-dirty
  abort_polytoken_spawn "$id" dirty close-allowed
  [ "$LEASE_STATUS" -ne 0 ] || fail "spawn launched into a dirty leased copy"$'\n'"$LEASE_OUT"
  assert_grep 'pane close' "$LEASE_DIR/fake/herdr-log" "the abort did not close its pane"$'\n'"$LEASE_OUT"
  [ ! -e "$LEASE_DIR/fake/returned" ] || fail "the abort returned a copy holding uncommitted work"
  assert_grep dirty "$LEASE_DIR/slot/README.md" "the abort discarded the copy's uncommitted work"
  assert_contains "$LEASE_OUT" "stays leased to $id" "an abort that kept a dirty copy did not name the lease it keeps"
  pass "an abort whose pane Herdr reports gone keeps a copy with uncommitted work leased"
}

test_abort_keeps_the_lease_while_the_pane_is_present() {
  local id=lease-close-refused
  abort_polytoken_spawn "$id" dirty
  [ "$LEASE_STATUS" -ne 0 ] || fail "spawn launched into a dirty leased copy"$'\n'"$LEASE_OUT"
  assert_grep 'pane close' "$LEASE_DIR/fake/herdr-log" "the abort did not attempt its locked pane close"
  [ ! -e "$LEASE_DIR/fake/task-pane-closed" ] || fail "the refused close removed its task pane"
  [ ! -e "$LEASE_DIR/fake/returned" ] || fail "the abort returned the lease while its pane is still present"
  assert_contains "$LEASE_OUT" "stays leased to $id" "an abort with its pane still present did not name the lease it keeps"
  pass "an abort whose pane is still present keeps the lease and names it"
}

test_fresh_spawn_leases_and_moves_the_top_level_shell
test_failed_lease_refuses_without_a_record
test_aborted_spawn_names_the_lease_it_keeps
test_rolled_back_spawn_after_launch_names_the_lease_it_keeps
test_abort_returns_a_clean_lease_once_the_pane_is_gone
test_abort_keeps_a_dirty_lease_once_the_pane_is_gone
test_abort_keeps_the_lease_while_the_pane_is_present

echo "# all fm-spawn-herdr-lease tests passed"
