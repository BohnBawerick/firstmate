#!/usr/bin/env bash
# tests/fm-quality-structured-output-live-e2e.test.sh - opt-in drift guard
# proving every INSTALLED harness the hardened quality loop has a recipe for
# still advertises its structured-output flag.
#
# Why this file exists: the hardened loop refuses to run a round whose answer
# would have to be parsed out of prose, and the flag that makes a schema-validated
# answer possible is a surface the harness vendor controls and renames without
# notice. A stub can only confirm the name already written into the stub, so the
# real binaries have to be asked. The portable counterpart in
# tests/fm-quality.test.sh pins the classifier logic in CI, in both directions.
#
# This consumes no model tokens: it reads --version and --help only.
#
# Standard CI has no harness binaries, so this real-harness guard is opt-in and
# on-demand. Run it after any harness upgrade and before trusting refreshed
# per-harness evidence in docs/verification/runtime-backends.md.
set -u

if [ "${FM_QUALITY_STRUCTURED_OUTPUT_DRIFT:-0}" != 1 ]; then
  echo "skip: set FM_QUALITY_STRUCTURED_OUTPUT_DRIFT=1 to run the installed-harness structured-output drift guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

# The recipe set in bin/fm-quality.sh: harness name, binary, the flag, and the
# help surface that carries it - codex documents --output-schema under
# `codex exec`, not `codex`.
CHECKED=0
check_harness() {  # <harness> <binary> <flag> <help-args...>
  local harness=$1 bin=$2 flag=$3 version
  shift 3
  if ! command -v "$bin" >/dev/null 2>&1; then
    note "$harness is not installed here, so it was not checked"
    return 0
  fi
  version=$("$bin" --version 2>/dev/null | head -1)
  [ -n "$version" ] || version=unknown
  "$bin" "$@" 2>&1 | grep -q -- "$flag" \
    || fail "$harness ($version) no longer advertises $flag on \`$bin $*\`; the hardened quality loop refuses it and no round can run on it"
  CHECKED=$((CHECKED + 1))
  pass "$harness ($version) still advertises $flag"
}

check_harness claude claude --json-schema --help
check_harness codex codex --output-schema exec --help

[ "$CHECKED" -gt 0 ] \
  || fail "no harness with a hardened-loop recipe is installed here, so this guard checked nothing and must not report a pass"

note "checked $CHECKED installed harness(es) against $ROOT/bin/fm-quality.sh"
echo "all fm-quality structured-output drift checks passed"
