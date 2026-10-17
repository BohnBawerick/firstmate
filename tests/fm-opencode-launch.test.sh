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

ROOT="$ROOT" TMP_ROOT="$TMP_ROOT" node --input-type=module <<'JS' || fail 'v1/v2 primary plugin boundary failed'
import { pathToFileURL } from "node:url";
import { mkdirSync, writeFileSync } from "node:fs";
const url = pathToFileURL(`${process.env.ROOT}/.opencode/plugins/lib/fm-v2-worker-only.js`).href;
process.env.FM_OC_VERSION = "1.18.33";
const legacy = (await import(`${url}?v1`)).v2WorkerOnly("firstmate.test");
if (typeof legacy !== "function" || Object.keys(await legacy({})).length) throw new Error("v1 shim must be a callable no-op");
process.env.FM_OPENCODE_V2_WORKER = "1";
const shim = (await import(`${url}?v2`)).v2WorkerOnly("firstmate.test");
let refused = false;
try { shim.setup({location:{directory:process.env.TMP_ROOT}}); } catch (e) { refused = e.message.includes("primary supervision is not supported"); }
if (!refused) throw new Error("bare v2 primary must refuse");
mkdirSync(`${process.env.TMP_ROOT}/.opencode/plugins`, {recursive:true});
writeFileSync(`${process.env.TMP_ROOT}/.opencode/plugins/fm-busy-state.js`, "// worker fixture");
shim.setup({location:{directory:process.env.TMP_ROOT}});
JS
pass 'primary compatibility entrypoints stay callable on v1 and refuse v2 primaries'
