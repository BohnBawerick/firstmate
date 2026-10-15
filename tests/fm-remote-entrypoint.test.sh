#!/usr/bin/env bash
# fm-remote-entrypoint.sh installs as a PATH symlink under ~/.local/bin
# (docs/remote-secondmates.md). SCRIPT_DIR must resolve to the real bin/
# directory so it can source its sibling fm-remote-job-lib.sh, not to the
# symlink's own directory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-entrypoint)
REAL_BIN="$TMP_ROOT/real-root/bin"
LOCAL_BIN="$TMP_ROOT/local-bin"
mkdir -p "$REAL_BIN" "$LOCAL_BIN"
cp "$ROOT/bin/fm-remote-entrypoint.sh" "$ROOT/bin/fm-remote-job-lib.sh" "$REAL_BIN/"
chmod +x "$REAL_BIN/fm-remote-entrypoint.sh"
ln -s "$REAL_BIN/fm-remote-entrypoint.sh" "$LOCAL_BIN/fm-remote-entrypoint.sh"

run_entrypoint() { # <path> <stdout-file> <stderr-file>
  local path=$1 out=$2 err=$3 code
  "$path" >"$out" 2>"$err"
  code=$?
  printf '%s' "$code"
}

test_symlink_invocation_resolves_sibling_lib() {
  local out err code
  out="$TMP_ROOT/symlink.stdout"
  err="$TMP_ROOT/symlink.stderr"
  code=$(run_entrypoint "$LOCAL_BIN/fm-remote-entrypoint.sh" "$out" "$err")

  # A wrong SCRIPT_DIR fails while sourcing the sibling lib, before argv is
  # even checked, with a "No such file or directory" source error and exit 1.
  # Reaching the die() for missing protocol args proves the sibling lib
  # sourced from the real bin/, not from the symlink's own directory.
  assert_no_grep 'No such file or directory' "$err" \
    "invoking fm-remote-entrypoint.sh through a symlink failed to source its sibling lib"
  expect_code 64 "$code" "symlink invocation exit code"
  assert_grep 'remote entrypoint expects protocol, root, home, and argv' "$err" \
    "symlink invocation did not reach argument validation past sibling-lib sourcing"
  pass "fm-remote-entrypoint.sh invoked via a PATH symlink resolves SCRIPT_DIR to the real bin/ directory"
}

test_direct_invocation_still_works() {
  # Control: the same real script invoked directly (no symlink) must behave
  # identically, so the symlink coverage above is proven by contrast.
  local out err code
  out="$TMP_ROOT/direct.stdout"
  err="$TMP_ROOT/direct.stderr"
  code=$(run_entrypoint "$REAL_BIN/fm-remote-entrypoint.sh" "$out" "$err")

  expect_code 64 "$code" "direct invocation exit code"
  assert_grep 'remote entrypoint expects protocol, root, home, and argv' "$err" \
    "direct invocation did not reach argument validation"
  pass "fm-remote-entrypoint.sh invoked directly still resolves SCRIPT_DIR correctly"
}

test_missing_home_parent_is_named() {
  # A persistent remote home may be one absent leaf under an existing parent.
  # When the parent itself is missing, the refusal must name that parent so the
  # operator knows to create it, rather than calling the home unsafe.
  local root missing out err code
  root="$TMP_ROOT/parent-check-root"
  mkdir -p "$root/bin"
  printf 'firstmate\n' > "$root/AGENTS.md"
  missing="$TMP_ROOT/absent-parent/home"
  out="$TMP_ROOT/parent.stdout"
  err="$TMP_ROOT/parent.stderr"
  b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
  code=0
  "$REAL_BIN/fm-remote-entrypoint.sh" 1 "$(b64 "$root")" "$(b64 "$missing")" \
    "$(printf 'fm-remote-doctor.sh\0' | base64 | tr -d '\n')" >"$out" 2>"$err" || code=$?
  expect_code 64 "$code" "missing home parent exit code"
  assert_grep "remote home's parent directory does not exist: $TMP_ROOT/absent-parent" "$err" \
    "a missing home parent was not named as the cause"
  pass "fm-remote-entrypoint.sh names a missing remote home parent directory"
}

test_symlink_invocation_resolves_sibling_lib
test_direct_invocation_still_works
test_missing_home_parent_is_named
