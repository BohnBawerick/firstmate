#!/usr/bin/env bash
# Behavior tests for bin/fm-quality-receipt.sh and the D2 receipt schema.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-quality-receipt)
RECEIPT="$ROOT/bin/fm-quality-receipt.sh"

validate() {
  "$RECEIPT" validate "$@"
}

# Build a JSON receipt from a python literal on stdin.
write_receipt() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(eval(sys.stdin.read())))' >"$1" \
    || fail "could not write receipt $1"
}

BASE=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
HEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

# A valid clean pass. Callers override fields by name.
clean_pass_py() {
  cat <<PY
{
  "schema_version": 1,
  "phase": "clean",
  "outcome": "pass",
  "base_sha": "$BASE",
  "head_sha": "$HEAD",
  "duration_ms": 1200,
  "engine": {"name": "eslint", "version": "10.1.0"},
  "threshold": {"crap_max": 15},
  "metrics": {"crap_max_observed": 9.0, "functions_changed": 4},
  "findings": [],
}
PY
}

harden_exhausted_py() {
  cat <<PY
{
  "schema_version": 1,
  "phase": "harden",
  "outcome": "exhausted",
  "base_sha": "$BASE",
  "head_sha": "$HEAD",
  "duration_ms": 54636,
  "engine": {"name": "@stryker-mutator/core", "version": "10.0.0"},
  "threshold": {"kill_rate_min": 0.80},
  "metrics": {"kill_rate": 0.7053, "mutants_total": 95},
  "findings": [
    {
      "id": "42",
      "file": "src/cache.ts",
      "line": 64,
      "detail": "ConditionalExpression: false",
      "classification": "killable",
    },
    {
      "id": "43",
      "file": "src/cache.ts",
      "line": 64,
      "detail": "ConditionalExpression: true",
      "classification": "killable",
    },
  ],
}
PY
}

expect_fail_field() {  # <file> <field-fragment> <label>
  local file=$1 field=$2 label=$3 out rc
  out=$(validate "$file" 2>&1); rc=$?
  expect_code 1 "$rc" "$label"
  assert_contains "$out" "$field" "$label did not name $field"$'\n'"$out"
}

test_valid_clean_pass() {
  local rec
  rec="$TMP_ROOT/clean-pass.json"
  clean_pass_py | write_receipt "$rec"
  validate "$rec" >/dev/null 2>&1 || fail "valid clean pass was rejected"
  pass "fm-quality-receipt: a clean pass with distinct head_sha is valid"
}

test_valid_harden_same_line_distinct_ids() {
  local rec
  rec="$TMP_ROOT/harden-ids.json"
  harden_exhausted_py | write_receipt "$rec"
  validate "$rec" >/dev/null 2>&1 || fail "two findings on one line with distinct ids were rejected"
  pass "fm-quality-receipt: two findings on the same file:line stay distinct by id"
}

test_valid_verify_envelope() {
  local rec
  rec="$TMP_ROOT/verify.json"
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "verify",
  "outcome": "exhausted",
  "base_sha": "$BASE",
  "head_sha": "$HEAD",
  "duration_ms": 68000,
  "phases": [
    {
      "schema_version": 1,
      "phase": "clean",
      "outcome": "pass",
      "base_sha": "$BASE",
      "head_sha": "$HEAD",
      "duration_ms": 13197,
      "engine": {"name": "eslint", "version": "10.1.0"},
      "threshold": {"crap_max": 15},
      "findings": [],
    },
    {
      "schema_version": 1,
      "phase": "harden",
      "outcome": "exhausted",
      "base_sha": "$BASE",
      "head_sha": "$HEAD",
      "duration_ms": 54636,
      "engine": {"name": "@stryker-mutator/core", "version": "10.0.0"},
      "threshold": {"kill_rate_min": 0.80},
      "findings": [
        {
          "id": "42",
          "file": "src/cache.ts",
          "line": 64,
          "detail": "ConditionalExpression: false",
          "classification": "killable",
        },
      ],
    },
  ],
}
PY
  validate "$rec" >/dev/null 2>&1 || fail "valid verify envelope was rejected: $(validate "$rec" 2>&1)"
  pass "fm-quality-receipt: verify is one envelope with per-phase children"
}

test_missing_head_sha_is_the_fail_open() {
  local rec out rc
  rec="$TMP_ROOT/drifted.json"
  # The Stage 0a fail-open: not-applicable, a base_sha, no head_sha, exit 0.
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "clean",
  "outcome": "not-applicable",
  "base_sha": "$BASE",
  "duration_ms": 12,
  "engine": {"name": "eslint", "version": "10.1.0"},
  "threshold": {"crap_max": 15},
  "findings": [],
}
PY
  out=$(validate "$rec" 2>&1); rc=$?
  expect_code 1 "$rc" "missing head_sha fail-open"
  assert_contains "$out" "head_sha" "fail-open rejection did not name head_sha"$'\n'"$out"
  pass "fm-quality-receipt: the old not-applicable receipt without head_sha is rejected"
}

test_docs_only_not_applicable_needs_both_shas() {
  local rec
  rec="$TMP_ROOT/docs-only.json"
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "clean",
  "outcome": "not-applicable",
  "base_sha": "$BASE",
  "head_sha": "$HEAD",
  "duration_ms": 40,
  "engine": {"name": "eslint", "version": "10.1.0"},
  "threshold": {"crap_max": 15},
  "notes": "No changed TypeScript source lines under src/.",
  "findings": [],
}
PY
  validate "$rec" >/dev/null 2>&1 || fail "docs-only not-applicable with both shas was rejected"
  pass "fm-quality-receipt: a genuine empty-src diff stays valid when both shas are present"
}

test_duration_ms_required_at_top_level() {
  local rec
  rec="$TMP_ROOT/duration-in-metrics.json"
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "clean",
  "outcome": "pass",
  "base_sha": "$BASE",
  "head_sha": "$HEAD",
  "engine": {"name": "eslint", "version": "10.1.0"},
  "threshold": {"crap_max": 15},
  "metrics": {"duration_ms": 1200},
  "findings": [],
}
PY
  expect_fail_field "$rec" "duration_ms" "duration_ms only inside metrics"
  rec="$TMP_ROOT/duration-negative.json"
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "clean",
  "outcome": "pass",
  "base_sha": "$BASE",
  "head_sha": "$HEAD",
  "duration_ms": -1,
  "engine": {"name": "eslint", "version": "10.1.0"},
  "threshold": {"crap_max": 15},
  "findings": [],
}
PY
  expect_fail_field "$rec" "duration_ms" "negative duration_ms"
  rec="$TMP_ROOT/duration-zero.json"
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "clean",
  "outcome": "not-applicable",
  "base_sha": "$BASE",
  "head_sha": "$HEAD",
  "duration_ms": 0,
  "engine": {"name": "eslint", "version": "10.1.0"},
  "threshold": {"crap_max": 15},
  "findings": [],
}
PY
  validate "$rec" >/dev/null 2>&1 || fail "duration_ms 0 was rejected"
  rec="$TMP_ROOT/duration-other.json"
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "clean",
  "outcome": "pass",
  "base_sha": "$BASE",
  "head_sha": "$HEAD",
  "duration_ms": 99999,
  "engine": {"name": "eslint", "version": "10.1.0"},
  "threshold": {"crap_max": 15},
  "findings": [],
}
PY
  validate "$rec" >/dev/null 2>&1 || fail "duration_ms 99999 was rejected; a constant 0 would still pass the zero case"
  pass "fm-quality-receipt: duration_ms is required at the top level and is not a constant"
}

test_survivors_and_mutant_are_gone() {
  local rec
  rec="$TMP_ROOT/survivors.json"
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "harden",
  "outcome": "exhausted",
  "base_sha": "$BASE",
  "head_sha": "$HEAD",
  "duration_ms": 10,
  "engine": {"name": "@stryker-mutator/core", "version": "10.0.0"},
  "threshold": {"kill_rate_min": 0.80},
  "findings": [],
  "survivors": [],
}
PY
  expect_fail_field "$rec" "survivors" "old survivors key"
  rec="$TMP_ROOT/mutant.json"
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "harden",
  "outcome": "exhausted",
  "base_sha": "$BASE",
  "head_sha": "$HEAD",
  "duration_ms": 10,
  "engine": {"name": "@stryker-mutator/core", "version": "10.0.0"},
  "threshold": {"kill_rate_min": 0.80},
  "findings": [
    {
      "id": "1",
      "file": "src/a.ts",
      "line": 1,
      "mutant": "ConditionalExpression: false",
      "classification": "killable",
    },
  ],
}
PY
  expect_fail_field "$rec" "mutant" "old mutant key"
  pass "fm-quality-receipt: survivors[] and mutant are rejected"
}

test_clean_cannot_use_killable() {
  local rec
  rec="$TMP_ROOT/clean-lie.json"
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "clean",
  "outcome": "exhausted",
  "base_sha": "$BASE",
  "head_sha": "$HEAD",
  "duration_ms": 30187,
  "engine": {"name": "eslint", "version": "10.1.0"},
  "threshold": {"crap_max": 15},
  "findings": [
    {
      "id": "src/providers/agy.ts:200:normalizeAgyUserStatus",
      "file": "src/providers/agy.ts",
      "line": 200,
      "detail": "normalizeAgyUserStatus crap=15.08 cyclomatic=15 coverage=0.9286",
      "classification": "killable",
    },
  ],
}
PY
  expect_fail_field "$rec" "classification" "clean finding classified killable"
  rec="$TMP_ROOT/clean-over.json"
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "clean",
  "outcome": "exhausted",
  "base_sha": "$BASE",
  "head_sha": "$HEAD",
  "duration_ms": 30187,
  "engine": {"name": "eslint", "version": "10.1.0"},
  "threshold": {"crap_max": 15},
  "findings": [
    {
      "id": "src/providers/agy.ts:200:normalizeAgyUserStatus",
      "file": "src/providers/agy.ts",
      "line": 200,
      "detail": "normalizeAgyUserStatus crap=15.08 cyclomatic=15 coverage=0.9286",
      "classification": "over-threshold",
    },
  ],
}
PY
  validate "$rec" >/dev/null 2>&1 || fail "clean over-threshold finding was rejected"
  pass "fm-quality-receipt: a complexity offender cannot be filed as killable"
}

test_harden_cannot_use_over_threshold() {
  local rec
  rec="$TMP_ROOT/harden-over.json"
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "harden",
  "outcome": "exhausted",
  "base_sha": "$BASE",
  "head_sha": "$HEAD",
  "duration_ms": 10,
  "engine": {"name": "@stryker-mutator/core", "version": "10.0.0"},
  "threshold": {"kill_rate_min": 0.80},
  "findings": [
    {
      "id": "42",
      "file": "src/cache.ts",
      "line": 64,
      "classification": "over-threshold",
    },
  ],
}
PY
  expect_fail_field "$rec" "classification" "harden finding classified over-threshold"
  pass "fm-quality-receipt: a mutant cannot be filed as over-threshold"
}

test_finding_id_required_and_unique() {
  local rec
  rec="$TMP_ROOT/no-id.json"
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "harden",
  "outcome": "exhausted",
  "base_sha": "$BASE",
  "head_sha": "$HEAD",
  "duration_ms": 10,
  "engine": {"name": "@stryker-mutator/core", "version": "10.0.0"},
  "threshold": {"kill_rate_min": 0.80},
  "findings": [
    {"file": "src/a.ts", "line": 1, "classification": "killable"},
  ],
}
PY
  expect_fail_field "$rec" "id" "finding without id"
  rec="$TMP_ROOT/dup-id.json"
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "harden",
  "outcome": "exhausted",
  "base_sha": "$BASE",
  "head_sha": "$HEAD",
  "duration_ms": 10,
  "engine": {"name": "@stryker-mutator/core", "version": "10.0.0"},
  "threshold": {"kill_rate_min": 0.80},
  "findings": [
    {"id": "same", "file": "src/a.ts", "line": 1, "classification": "killable"},
    {"id": "same", "file": "src/b.ts", "line": 2, "classification": "killable"},
  ],
}
PY
  expect_fail_field "$rec" "duplicate id" "duplicate finding ids"
  pass "fm-quality-receipt: finding id is required and unique per phase"
}

test_engine_and_threshold_required() {
  local rec
  rec="$TMP_ROOT/no-engine.json"
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "clean",
  "outcome": "pass",
  "base_sha": "$BASE",
  "head_sha": "$HEAD",
  "duration_ms": 10,
  "threshold": {"crap_max": 15},
  "findings": [],
}
PY
  expect_fail_field "$rec" "engine" "missing engine"
  rec="$TMP_ROOT/engine-other-version.json"
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "clean",
  "outcome": "pass",
  "base_sha": "$BASE",
  "head_sha": "$HEAD",
  "duration_ms": 10,
  "engine": {"name": "eslint", "version": "9.0.0"},
  "threshold": {"crap_max": 30},
  "findings": [],
}
PY
  validate "$rec" >/dev/null 2>&1 || fail "a different engine version and threshold were rejected; those fields are not constants"
  rec="$TMP_ROOT/empty-threshold.json"
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "clean",
  "outcome": "pass",
  "base_sha": "$BASE",
  "head_sha": "$HEAD",
  "duration_ms": 10,
  "engine": {"name": "eslint", "version": "10.1.0"},
  "threshold": {},
  "findings": [],
}
PY
  expect_fail_field "$rec" "threshold" "empty threshold"
  pass "fm-quality-receipt: engine and threshold are required and not constants"
}

test_verify_forbids_flat_findings() {
  local rec out rc
  rec="$TMP_ROOT/verify-flat.json"
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "verify",
  "outcome": "exhausted",
  "base_sha": "$BASE",
  "head_sha": "$HEAD",
  "duration_ms": 10,
  "findings": [
    {"id": "1", "file": "src/a.ts", "classification": "killable"},
  ],
}
PY
  out=$(validate "$rec" 2>&1); rc=$?
  expect_code 1 "$rc" "verify with flat findings"
  rec="$TMP_ROOT/verify-no-phases.json"
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "verify",
  "outcome": "pass",
  "base_sha": "$BASE",
  "head_sha": "$HEAD",
  "duration_ms": 10,
}
PY
  expect_fail_field "$rec" "phases" "verify without phases"
  rec="$TMP_ROOT/clean-with-phases.json"
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "clean",
  "outcome": "pass",
  "base_sha": "$BASE",
  "head_sha": "$HEAD",
  "duration_ms": 10,
  "engine": {"name": "eslint", "version": "10.1.0"},
  "threshold": {"crap_max": 15},
  "findings": [],
  "phases": [],
}
PY
  expect_fail_field "$rec" "phases" "clean with phases"
  pass "fm-quality-receipt: verify cannot flatten two phases into one findings list"
}

test_verify_child_shas_must_match_envelope() {
  local rec
  rec="$TMP_ROOT/verify-mismatch.json"
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "verify",
  "outcome": "pass",
  "base_sha": "$BASE",
  "head_sha": "$HEAD",
  "duration_ms": 10,
  "phases": [
    {
      "schema_version": 1,
      "phase": "clean",
      "outcome": "pass",
      "base_sha": "$BASE",
      "head_sha": "cccccccccccccccccccccccccccccccccccccccc",
      "duration_ms": 10,
      "engine": {"name": "eslint", "version": "10.1.0"},
      "threshold": {"crap_max": 15},
      "findings": [],
    },
  ],
}
PY
  expect_fail_field "$rec" "head_sha" "verify child head_sha mismatch"
  pass "fm-quality-receipt: a verify wrapper cannot glue receipts from two trees"
}

test_check_head_rejects_a_constant_sha() {
  local repo rec out rc first second
  repo="$TMP_ROOT/repo"
  fm_git_init_commit "$repo"
  first=$(git -C "$repo" rev-parse HEAD)
  printf 'second\n' >"$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm second
  second=$(git -C "$repo" rev-parse HEAD)
  [ "$first" != "$second" ] || fail "fixture commits were not distinct"
  rec="$TMP_ROOT/check-head-ok.json"
  python3 - "$second" "$first" "$rec" <<'PY'
import json, sys
head, base, path = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump({
  "schema_version": 1,
  "phase": "clean",
  "outcome": "not-applicable",
  "base_sha": base,
  "head_sha": head,
  "duration_ms": 8,
  "engine": {"name": "eslint", "version": "10.1.0"},
  "threshold": {"crap_max": 15},
  "findings": [],
}, open(path, "w"))
PY
  validate --check-head "$repo" "$rec" >/dev/null 2>&1 \
    || fail "receipt whose head_sha is the real HEAD was rejected: $(validate --check-head "$repo" "$rec" 2>&1)"
  rec="$TMP_ROOT/check-head-constant.json"
  python3 - "$first" "$first" "$rec" <<'PY'
import json, sys
head, base, path = sys.argv[1], sys.argv[2], sys.argv[3]
json.dump({
  "schema_version": 1,
  "phase": "clean",
  "outcome": "not-applicable",
  "base_sha": base,
  "head_sha": head,
  "duration_ms": 8,
  "engine": {"name": "eslint", "version": "10.1.0"},
  "threshold": {"crap_max": 15},
  "findings": [],
}, open(path, "w"))
PY
  out=$(validate --check-head "$repo" "$rec" 2>&1); rc=$?
  expect_code 1 "$rc" "head_sha pinned to the parent commit"
  assert_contains "$out" "head_sha" "constant head_sha rejection did not name head_sha"$'\n'"$out"
  assert_contains "$out" "$second" "constant head_sha rejection did not name the real HEAD"$'\n'"$out"
  pass "fm-quality-receipt: --check-head fails when head_sha is a constant that is not HEAD"
}

test_schema_file_is_the_owner_not_a_constant_list() {
  local rec schema out rc
  rec="$TMP_ROOT/no-head.json"
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "clean",
  "outcome": "not-applicable",
  "base_sha": "$BASE",
  "duration_ms": 12,
  "engine": {"name": "eslint", "version": "10.1.0"},
  "threshold": {"crap_max": 15},
  "findings": [],
}
PY
  schema="$TMP_ROOT/schema-without-head.json"
  python3 - "$ROOT/docs/quality-receipt.schema.json" "$schema" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]

def strip_head(node):
    if isinstance(node, dict):
        if isinstance(node.get("required"), list):
            node["required"] = [k for k in node["required"] if k != "head_sha"]
        for value in node.values():
            strip_head(value)
    elif isinstance(node, list):
        for item in node:
            strip_head(item)

doc = json.load(open(src))
strip_head(doc)
json.dump(doc, open(dst, "w"))
PY
  out=$(FM_QUALITY_RECEIPT_SCHEMA="$schema" validate "$rec" 2>&1); rc=$?
  expect_code 0 "$rc" "receipt missing head_sha against a schema that dropped the requirement"$'\n'"$out"
  out=$(validate "$rec" 2>&1); rc=$?
  expect_code 1 "$rc" "committed schema still requires head_sha"
  assert_contains "$out" "head_sha" "committed schema rejection did not name head_sha"
  pass "fm-quality-receipt: dropping head_sha from the schema file is what lets the fail-open through"
}

test_usage_prints_the_header_and_no_shell_code() {
  local out rc
  out=$("$RECEIPT" --help); rc=$?
  expect_code 0 "$rc" "--help"
  assert_contains "$out" "Usage:" "--help did not print the usage block"$'\n'"$out"
  assert_contains "$out" "FM_QUALITY_RECEIPT_SCHEMA" "--help stopped before the last header line"$'\n'"$out"
  assert_not_contains "$out" "set -eu" "--help leaked a line of shell code"$'\n'"$out"
  out=$("$RECEIPT" 2>&1 >/dev/null); rc=$?
  expect_code 2 "$rc" "no command"
  assert_contains "$out" "Usage:" "the usage error did not print the usage block"$'\n'"$out"
  assert_not_contains "$out" "set -eu" "the usage error leaked a line of shell code"$'\n'"$out"
  pass "fm-quality-receipt: usage prints the header block and stops before the code"
}

test_dashdash_reads_the_named_file_not_stdin() {
  local good bad out rc
  good="$TMP_ROOT/dd-good.json"
  clean_pass_py | write_receipt "$good"
  bad="$TMP_ROOT/dd-bad.json"
  cat <<PY | write_receipt "$bad"
{
  "schema_version": 1,
  "phase": "clean",
  "outcome": "not-applicable",
  "base_sha": "$BASE",
  "duration_ms": 12,
  "engine": {"name": "eslint", "version": "10.1.0"},
  "threshold": {"crap_max": 15},
  "findings": [],
}
PY
  out=$(validate -- "$bad" <"$good" 2>&1); rc=$?
  expect_code 1 "$rc" "validate -- <invalid file> while stdin holds a valid receipt"$'\n'"$out"
  assert_contains "$out" "head_sha" "validate -- read stdin instead of the named file"$'\n'"$out"
  out=$(validate -- "$good" </dev/null 2>&1); rc=$?
  expect_code 0 "$rc" "validate -- <valid file> with empty stdin"$'\n'"$out"
  out=$(validate -- "$good" "$bad" </dev/null 2>&1); rc=$?
  expect_code 2 "$rc" "two operands after --"$'\n'"$out"
  pass "fm-quality-receipt: an operand after -- is the file to validate, not stdin"
}

test_sha_pattern_rejects_a_trailing_newline() {
  local rec out rc
  rec="$TMP_ROOT/sha-newline.json"
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "clean",
  "outcome": "pass",
  "base_sha": "$BASE",
  "head_sha": "$HEAD\n",
  "duration_ms": 10,
  "engine": {"name": "eslint", "version": "10.1.0"},
  "threshold": {"crap_max": 15},
  "findings": [],
}
PY
  out=$(validate "$rec" 2>&1); rc=$?
  expect_code 1 "$rc" "head_sha with a trailing newline"$'\n'"$out"
  assert_contains "$out" "head_sha" "trailing-newline rejection did not name head_sha"$'\n'"$out"
  rec="$TMP_ROOT/sha-clean.json"
  clean_pass_py | write_receipt "$rec"
  validate "$rec" >/dev/null 2>&1 || fail "the same sha without the newline was rejected"
  pass "fm-quality-receipt: a sha with trailing whitespace is not a sha"
}

test_a_schema_keyword_this_checker_cannot_enforce_is_refused() {
  local rec schema out rc
  rec="$TMP_ROOT/keyword-two-findings.json"
  harden_exhausted_py | write_receipt "$rec"
  validate "$rec" >/dev/null 2>&1 || fail "the fixture receipt is not valid against the committed schema"
  schema="$TMP_ROOT/schema-maxitems.json"
  python3 - "$ROOT/docs/quality-receipt.schema.json" "$schema" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
doc = json.load(open(src))
doc["$defs"]["phase_result"]["properties"]["findings"]["maxItems"] = 1
json.dump(doc, open(dst, "w"))
PY
  out=$(FM_QUALITY_RECEIPT_SCHEMA="$schema" validate "$rec" 2>&1); rc=$?
  expect_code 2 "$rc" "a schema tightened with maxItems, which this checker does not implement"$'\n'"$out"
  assert_contains "$out" "maxItems" "the refusal did not name the keyword"$'\n'"$out"
  pass "fm-quality-receipt: an unenforceable schema keyword is refused, not ignored"
}

test_check_head_separates_git_failure_from_a_bad_sha() {
  local repo rec out rc
  rec="$TMP_ROOT/check-head-tool.json"
  clean_pass_py | write_receipt "$rec"
  out=$(validate --check-head "$TMP_ROOT/not-a-git-tree" "$rec" 2>&1); rc=$?
  expect_code 2 "$rc" "--check-head pointed at a path that is not a git tree"$'\n'"$out"
  repo="$TMP_ROOT/check-head-repo"
  fm_git_init_commit "$repo"
  out=$(validate --check-head "$repo" "$rec" 2>&1); rc=$?
  expect_code 1 "$rc" "head_sha that git resolved and rejected"$'\n'"$out"
  assert_contains "$out" "head_sha" "the receipt rejection did not name head_sha"$'\n'"$out"
  pass "fm-quality-receipt: git failing to run is exit 2, a sha git disowns is exit 1"
}

test_a_receipt_arrives_on_stdin() {
  local good bad out rc
  good="$TMP_ROOT/stdin-good.json"
  clean_pass_py | write_receipt "$good"
  bad="$TMP_ROOT/stdin-bad.json"
  cat <<PY | write_receipt "$bad"
{
  "schema_version": 1,
  "phase": "clean",
  "outcome": "not-applicable",
  "base_sha": "$BASE",
  "duration_ms": 12,
  "engine": {"name": "eslint", "version": "10.1.0"},
  "threshold": {"crap_max": 15},
  "findings": [],
}
PY
  out=$(validate - <"$good" 2>&1); rc=$?
  expect_code 0 "$rc" "a valid receipt named on stdin with -"$'\n'"$out"
  out=$(validate <"$good" 2>&1); rc=$?
  expect_code 0 "$rc" "a valid receipt redirected onto stdin with no operand"$'\n'"$out"
  out=$(cat "$good" | validate 2>&1); rc=$?
  expect_code 0 "$rc" "a valid receipt piped in, the way a phase command emits one"$'\n'"$out"
  out=$(validate - <"$bad" 2>&1); rc=$?
  expect_code 1 "$rc" "an invalid receipt on stdin"$'\n'"$out"
  assert_contains "$out" "head_sha" "the stdin rejection did not name head_sha"$'\n'"$out"
  pass "fm-quality-receipt: a receipt piped in on stdin is read, not an empty string"
}

test_an_empty_argument_is_refused_rather_than_defaulted() {
  local rec out rc
  rec="$TMP_ROOT/empty-arg.json"
  cat <<PY | write_receipt "$rec"
{
  "schema_version": 1,
  "phase": "clean",
  "outcome": "pass",
  "base_sha": "$BASE",
  "head_sha": "cccccccccccccccccccccccccccccccccccccccc",
  "duration_ms": 10,
  "engine": {"name": "eslint", "version": "10.1.0"},
  "threshold": {"crap_max": 15},
  "findings": [],
}
PY
  out=$(validate --check-head "" "$rec" 2>&1); rc=$?
  expect_code 2 "$rc" "--check-head with an empty git dir"$'\n'"$out"
  out=$(validate "" </dev/null 2>&1); rc=$?
  expect_code 2 "$rc" "an empty file operand"$'\n'"$out"
  validate "$rec" >/dev/null 2>&1 || fail "the fixture receipt is not valid without --check-head"
  pass "fm-quality-receipt: an empty argument never silently becomes the default"
}

test_an_unreadable_receipt_path_is_a_tool_error() {
  local rec out rc
  out=$(validate "$TMP_ROOT/no-such-receipt.json" 2>&1); rc=$?
  expect_code 2 "$rc" "a receipt path that does not exist"$'\n'"$out"
  out=$(validate "$TMP_ROOT" 2>&1); rc=$?
  expect_code 2 "$rc" "a receipt path that is a directory"$'\n'"$out"
  rec="$TMP_ROOT/not-json.json"
  printf 'this is not json\n' >"$rec"
  out=$(validate "$rec" 2>&1); rc=$?
  expect_code 1 "$rc" "a receipt that was read but is not JSON"$'\n'"$out"
  pass "fm-quality-receipt: an unreadable path is exit 2, unparseable content is exit 1"
}

test_schema_command_prints_json() {
  local out rc
  out=$("$RECEIPT" schema); rc=$?
  expect_code 0 "$rc" "schema command"
  python3 -c 'import json,sys; json.loads(sys.stdin.read())' <<<"$out" \
    || fail "schema command did not print JSON"
  pass "fm-quality-receipt: schema prints the committed JSON Schema"
}

test_valid_clean_pass
test_valid_harden_same_line_distinct_ids
test_valid_verify_envelope
test_missing_head_sha_is_the_fail_open
test_docs_only_not_applicable_needs_both_shas
test_duration_ms_required_at_top_level
test_survivors_and_mutant_are_gone
test_clean_cannot_use_killable
test_harden_cannot_use_over_threshold
test_finding_id_required_and_unique
test_engine_and_threshold_required
test_verify_forbids_flat_findings
test_verify_child_shas_must_match_envelope
test_check_head_rejects_a_constant_sha
test_schema_file_is_the_owner_not_a_constant_list
test_usage_prints_the_header_and_no_shell_code
test_dashdash_reads_the_named_file_not_stdin
test_sha_pattern_rejects_a_trailing_newline
test_a_schema_keyword_this_checker_cannot_enforce_is_refused
test_check_head_separates_git_failure_from_a_bad_sha
test_a_receipt_arrives_on_stdin
test_an_empty_argument_is_refused_rather_than_defaulted
test_an_unreadable_receipt_path_is_a_tool_error
test_schema_command_prints_json
