#!/usr/bin/env bash
set -eu
ROOT=$PWD
CASE_ROOT="$ROOT/.test-pin-tmp/resolution"
mkdir -p "$CASE_ROOT"
trap 'rm -rf "$CASE_ROOT"' EXIT
unset FM_CONFIG_OVERRIDE FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$CASE_ROOT"
mkdir -p "$FM_HOME/config/secondmate-harness.d"
printf 'claude\n' > "$FM_HOME/config/crew-harness"
printf 'pi opencode-go/deepseek-v4.1-flash high\n' > "$FM_HOME/config/secondmate-harness"
printf 'codex gpt-6.1-sol low\n' > "$FM_HOME/config/secondmate-harness.d/mac-air"
profile() {
  local id=$1 expected=$2 actual='' value verb
  for verb in secondmate secondmate-model secondmate-effort secondmate-source; do
    value=$(bash "$ROOT/bin/fm-harness.sh" "$verb" "$id")
    actual="${actual}${actual:+|}$value"
  done
  printf '%s -> %s\n' "${id:-no id}" "$actual"
  [ "$actual" = "$expected" ] || { printf 'Expected %s\n' "$expected"; exit 1; }
}
profile mac-air 'codex|gpt-6.1-sol|low|config/secondmate-harness.d/mac-air'
profile work-pc 'pi|opencode-go/deepseek-v4.1-flash|high|config/secondmate-harness'
profile '' 'pi|opencode-go/deepseek-v4.1-flash|high|config/secondmate-harness'
for state in absent blank comment default; do
  case "$state" in
    absent) rm -f "$FM_HOME/config/secondmate-harness.d/mac-air";;
    blank) printf '\n' > "$FM_HOME/config/secondmate-harness.d/mac-air";;
    comment) printf '# no per-mate pin\n' > "$FM_HOME/config/secondmate-harness.d/mac-air";;
    default) printf 'default\n' > "$FM_HOME/config/secondmate-harness.d/mac-air";;
  esac
  printf 'Per-mate state: %s\n' "$state"
  profile mac-air 'pi|opencode-go/deepseek-v4.1-flash|high|config/secondmate-harness'
done
printf 'codex\n' > "$FM_HOME/config/secondmate-harness.d/mac-air"
profile mac-air 'codex|||config/secondmate-harness.d/mac-air'
rm "$FM_HOME/config/secondmate-harness.d/mac-air" "$FM_HOME/config/secondmate-harness"
profile mac-air 'claude|||'
rm "$FM_HOME/config/crew-harness"
actual=$(bash "$ROOT/bin/fm-harness.sh" secondmate mac-air)
own=$(bash "$ROOT/bin/fm-harness.sh")
printf 'No pins or crew setting -> %s; own harness -> %s\n' "$actual" "$own"
[ "$actual" = "$own" ]
for invalid in ../outside . .. 'nested/name'; do
  status=0
  bash "$ROOT/bin/fm-harness.sh" secondmate "$invalid" > "$CASE_ROOT/out" 2> "$CASE_ROOT/err" || status=$?
  printf 'Invalid id %s: exit=%s; ' "$invalid" "$status"
  cat "$CASE_ROOT/err"
  [ "$status" -eq 2 ] && [ ! -s "$CASE_ROOT/out" ]
done
