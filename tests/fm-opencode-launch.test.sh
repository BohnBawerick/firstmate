#!/usr/bin/env bash
# OpenCode version parsing and selected-session launch through the real helper.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-opencode-launch)
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/opencode" <<'SH'
#!/usr/bin/env bash
set -eu
case "$1" in
  --version) printf '%s\n' "${FM_OC_VERSION:-opencode v2.0.30}" ;;
  api)
    [ "$2" = --standalone ] || exit 10
    shift
    case "$2" in
      GET)
        if [ "${FM_OC_BAD_CATALOG:-0}" = 1 ]; then printf '{bad'; exit; fi
        printf '%s\n' '{"data":[{"providerID":"opencode","id":"deepseek-v4.1-flash-free","variants":[{"id":"low"},{"id":"high"},{"id":"max"}]}]}'
        ;;
      session.create)
        printf '%s\n' "$4" > "$FM_OC_RECORD/create.json"
        [ "${FM_OC_FAIL_CREATE:-0}" = 0 ] || exit 7
        printf '%s\n' '{"data":{"id":"ses_selected"}}'
        ;;
      *) exit 8 ;;
    esac
    ;;
  --standalone) [ "$FM_OPENCODE_SESSION" = ses_selected ] || exit 11; jq -cn --args '$ARGS.positional' -- "$@" > "$FM_OC_RECORD/attach.json" ;;
  *) exit 9 ;;
esac
SH
chmod +x "$TMP_ROOT/bin/opencode"
export PATH="$TMP_ROOT/bin:$PATH" FM_OC_RECORD="$TMP_ROOT"
LAUNCH="$ROOT/bin/fm-opencode-launch.sh"
for version in 1.18.33 'opencode v2.0.30' 2.0.30-dev; do
  case "$version" in 1*) want=1 ;; *) want=2 ;; esac
  got=$(FM_OC_VERSION="$version" bash "$LAUNCH" --major-version) || fail "probe rejected $version"
  [ "$got" = "$want" ] || fail "$version resolved to $got"
done
for version in unknown 3.0.0 12.0.30; do
  if FM_OC_VERSION="$version" bash "$LAUNCH" --major-version >/dev/null 2>&1; then fail "probe accepted $version"; fi
done
pass 'OpenCode probes support plain and prefixed versions and refuse unknown majors'
bash "$LAUNCH" --model opencode/deepseek-v4.1-flash-free --effort high --prompt 'Read the brief' || fail 'v2 launch failed'
jq -e --arg cwd "$(pwd -P)" '.location.directory == $cwd and .agent == "build" and .model == {providerID:"opencode",id:"deepseek-v4.1-flash-free",variant:"high"}' "$TMP_ROOT/create.json" >/dev/null || fail 'session did not carry the selected model/effort/location'
jq -e '. == ["--standalone","--auto","--session","ses_selected","--prompt","Read the brief"]' "$TMP_ROOT/attach.json" >/dev/null || fail 'TUI did not attach with the launch prompt'
pass 'OpenCode v2 selects the model and advertised effort before interactive prompt submission'
for effort in low max; do
  bash "$LAUNCH" --model opencode/deepseek-v4.1-flash-free --effort "$effort" --prompt variants || fail "$effort launch failed"
  jq -e --arg effort "$effort" '.model.variant == $effort' "$TMP_ROOT/create.json" >/dev/null || fail "$effort was not carried to the session"
done
bash "$LAUNCH" --model opencode/deepseek-v4.1-flash-free --effort medium --prompt fallback > "$TMP_ROOT/fallback.log" 2>&1 || fail 'unsupported effort should fall back'
jq -e '.model | has("variant") | not' "$TMP_ROOT/create.json" >/dev/null || fail 'unsupported effort must be omitted'
assert_grep 'does not advertise effort medium' "$TMP_ROOT/fallback.log" 'fallback must be visible'
rm -f "$TMP_ROOT/attach.json"
if FM_OC_BAD_CATALOG=1 bash "$LAUNCH" --model opencode/deepseek-v4.1-flash-free --effort high --prompt nope > "$TMP_ROOT/bad.log" 2>&1; then fail 'malformed catalog must refuse'; fi
[ ! -e "$TMP_ROOT/attach.json" ] || fail 'malformed catalog attached the TUI'
if FM_OC_FAIL_CREATE=1 bash "$LAUNCH" --model default --effort default --prompt nope > "$TMP_ROOT/create-failure.log" 2>&1; then fail 'failed creation must refuse'; fi
[ ! -e "$TMP_ROOT/attach.json" ] || fail 'failed creation attached the TUI'
pass 'OpenCode v2 reports unsupported effort and refuses broken API responses before attachment'

test_live_mode_selection() {
  local generic specific out want
  (
    # shellcheck disable=SC2329 # Exported for the child fixture shell.
    fm_live_gate() { printf '%s %s\n' "$1" "$2"; exit 0; }
    export -f fm_live_gate
    for pair in unset:unset 1:unset 1:0 0:1 0:unset; do
      generic=${pair%:*}
      specific=${pair#*:}
      unset FM_LIVE FM_OPENCODE_LIVE_E2E
      [ "$generic" = unset ] || export FM_LIVE=$generic
      [ "$specific" = unset ] || export FM_OPENCODE_LIVE_E2E=$specific
      case "$pair" in
        1:unset|0:1) want='opt-in FM_OPENCODE_LIVE_E2E' ;;
        *) want='default-on FM_OPENCODE_V2_OFFLINE_LIVE' ;;
      esac
      out=$(FM_TEST_LIB_SOURCED=1 bash "$ROOT/tests/fm-opencode-primary-live-e2e.test.sh") \
        || fail "live mode selection failed for $pair"
      [ "$out" = "$want" ] || fail "$pair selected $out instead of $want"
    done
  ) || return 1
  pass 'OpenCode live mode honors the shared opt-in and per-guard overrides'
}
test_live_mode_selection || exit 1

test_offline_live_uses_selected_executable() (
  local selected="$TMP_ROOT/selected/opencode-v2" out
  mkdir -p "$(dirname "$selected")" "$TMP_ROOT/offline-bin"
  printf '#!/bin/sh\nprintf "2.0.30\\n"\n' > "$selected"
  cat > "$TMP_ROOT/offline-bin/python3" <<'STUB'
#!/usr/bin/env bash
[ "$2" = "$FM_TEST_SELECTED_OPENCODE" ] || exit 41
printf '%s\n' "$2" > "$FM_TEST_SELECTED_LOG"
STUB
  chmod +x "$selected" "$TMP_ROOT/offline-bin/python3"
  # shellcheck disable=SC2329 # Exported for the child fixture shell.
  command() {
    if [ "${1:-}" = -v ] && [ "${2:-}" = opencode ]; then return 1; fi
    builtin command "$@"
  }
  export -f command
  out=$(PATH="$TMP_ROOT/offline-bin:$PATH" FM_LIVE=0 FM_OPENCODE_LIVE_E2E=0 FM_OPENCODE_V2_OFFLINE_LIVE=1 \
    FM_OPENCODE_LIVE_BINS="$selected" FM_TEST_SELECTED_OPENCODE="$selected" FM_TEST_SELECTED_LOG="$TMP_ROOT/selected.log" \
    bash "$ROOT/tests/fm-opencode-primary-live-e2e.test.sh" 2>&1) || fail "the selected executable was not exercised: $out"
  assert_equals "$selected" "$(cat "$TMP_ROOT/selected.log")" 'the Python fixture received another executable'
  pass 'the offline gate accepts an explicit executable without ambient opencode and forwards its exact path'
)

test_native_fixture_executes_selected_binary() {
  python3 - "$ROOT" "$TMP_ROOT" <<'PY' || fail 'the native fixture launched another executable'
import importlib.util
from pathlib import Path
import subprocess
import sys
from unittest import mock
root, temporary = map(Path, sys.argv[1:])
selected = temporary / "native-selected"
marker = temporary / "native-started"
selected.write_text('#!/bin/sh\nprintf "%s\\n" "$0" > ' + str(marker) + '\n')
selected.chmod(0o700)
lab = temporary / "native-lab"
lab.mkdir()
spec = importlib.util.spec_from_file_location("fixture", root / "tests/opencode-v2-live-fixture.py")
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
original_popen = subprocess.Popen
original_server = fixture.http.server.ThreadingHTTPServer
servers = []
class Started(Exception):
    pass

def server(*args, **kwargs):
    result = original_server(*args, **kwargs)
    servers.append(result)
    return result

def launch(args, **kwargs):
    if len(args) > 1 and args[1] == "serve":
        assert args[0] == str(selected), args
        process = original_popen(args, **kwargs)
        assert process.wait(timeout=5) == 0
        raise Started()
    return original_popen(args, **kwargs)

try:
    with mock.patch.object(fixture.http.server, "ThreadingHTTPServer", side_effect=server), mock.patch.object(fixture.subprocess, "Popen", side_effect=launch):
        try:
            fixture.run(lab, str(selected))
        except Started:
            pass
        else:
            raise AssertionError("the fixture did not launch the selected executable")
    assert marker.read_text().strip() == str(selected)
finally:
    for item in servers:
        item.shutdown()
        item.server_close()
PY
  pass 'the native fixture executes the selected binary rather than resolving opencode again'
}

test_offline_live_uses_selected_executable || exit 1
test_native_fixture_executes_selected_binary || exit 1
