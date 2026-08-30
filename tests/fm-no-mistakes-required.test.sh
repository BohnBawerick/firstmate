#!/usr/bin/env bash
# Regression tests for the pinned shared no-mistakes gate action.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTION_REF=32d396ac0f29135daf7fcb9964aba9d5f4e796d6
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-required)
VERIFY="$TMP_ROOT/verify.py"
OLD_SHA=1111111111111111111111111111111111111111
NEW_SHA=2222222222222222222222222222222222222222
SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
COMPLETED_STEPS='[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]'

# The verifier under test lives in another repository, so this suite can only
# assert against it when the network reaches that repository. Not reaching it is
# an absent prerequisite, not a verdict on this branch: the run says so on the
# suite's skip line and exits clean, the way the live-harness suites do. When the
# fetch does succeed every assertion below runs against the real verifier.
fetch_shared_verifier() {
  local reason
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to exercise the pinned shared action"
  if ! command -v curl >/dev/null 2>&1; then
    echo "skip: curl is required to fetch the pinned shared no-mistakes action verifier"
    exit 0
  fi
  if ! curl --fail --silent --show-error --location --max-time 30 \
    "https://raw.githubusercontent.com/kunchenguid/no-mistakes/${ACTION_REF}/.github/actions/require-no-mistakes/verify.py" \
    > "$VERIFY" 2>"$TMP_ROOT/fetch.err"; then
    reason=$(tr '\n\r\t' '   ' < "$TMP_ROOT/fetch.err" | tr -s ' ' | sed -e 's/^ *//' -e 's/ *$//')
    echo "skip: could not fetch the pinned shared action verifier at $ACTION_REF: ${reason:-no detail from curl}"
    exit 0
  fi
  if [ ! -s "$VERIFY" ]; then
    echo "skip: the pinned shared action verifier at $ACTION_REF came back empty"
    exit 0
  fi
}

run_verifier() {
  local body=$1 head=$2
  PR_BODY="$body" PR_HEAD_SHA="$head" PR_AUTHOR=regression PR_NUMBER=3006 \
    python3 "$VERIFY" 2>&1
}

test_matching_head_and_completed_steps_pass() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$NEW_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "shared action rejected an attestation bound to the current PR head"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "shared action did not report the matching attestation as compliant"
  pass "shared action accepts a matching head_sha with completed required steps"
}

test_mismatched_head_fails_with_both_shas() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$OLD_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation from a different PR head"
  assert_contains "$output" "$OLD_SHA" \
    "mismatched-head failure did not name the attestation head SHA"
  assert_contains "$output" "$NEW_SHA" \
    "mismatched-head failure did not name the actual PR head SHA"
  pass "shared action rejects a mismatched head_sha and names both SHAs"
}

test_missing_head_fails() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation without head_sha"
  assert_contains "$output" "structured pipeline step attestation" \
    "missing-head failure did not explain that the attestation is invalid"
  pass "shared action rejects an attestation with no head_sha"
}

# --- the workflow must judge the pull request as it stands now ---------------
#
# A push and the body re-attestation that follows it are two separate forge
# writes. A synchronize event payload can therefore carry the new head beside
# the previous body, and the gate then rejects an attestation the pull request
# no longer has - a verdict no re-run can clear, because a re-run replays the
# same payload. The workflow reads body and head back from the API for that
# reason, so these cases drive the workflow's own step, not a copy of it.

WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"
STALE_EVENT="$TMP_ROOT/event.json"
RESOLVE_DIR="$TMP_ROOT/resolve"

# Build the pull request body a pipeline run publishes for a given attested head.
attested_body() {
  python3 - "$SIGNATURE" "$1" "$COMPLETED_STEPS" <<'PY'
import json
import sys

signature, head_sha, steps = sys.argv[1:4]
attestation = json.dumps({"head_sha": head_sha, "steps": json.loads(steps)})
sys.stdout.write(
    signature + "\n<!-- no-mistakes-pipeline-attestation:v1 " + attestation + " -->"
)
PY
}

write_json_file() {
  local path=$1 shape=$2 body=$3
  python3 - "$path" "$shape" "$body" "$NEW_SHA" <<'PY'
import json
import sys

path, shape, body, head_sha = sys.argv[1:5]
pull_request = {
    "number": 3006,
    "body": body,
    "head": {"sha": head_sha, "ref": "feature/topic"},
    "user": {"login": "regression"},
}
payload = {"pull_request": pull_request} if shape == "event" else pull_request
with open(path, "w", encoding="utf-8") as handle:
    json.dump(payload, handle)
PY
}

# Run the workflow's own resolve step, with `gh` stubbed to serve one payload
# per call. The last payload repeats once the list runs out, so a single body
# models a pull request whose body never moves.
run_resolve_step() {
  local body index=0
  rm -rf "$RESOLVE_DIR"
  mkdir -p "$RESOLVE_DIR/bin" "$RESOLVE_DIR/work"
  python3 - "$WORKFLOW" "$RESOLVE_DIR/step.sh" <<'PY' || fail "could not read the resolve step out of the workflow"
import sys

import yaml

workflow, destination = sys.argv[1:3]
with open(workflow, encoding="utf-8") as handle:
    document = yaml.safe_load(handle)
step = next(s for s in document["jobs"]["check"]["steps"] if s.get("id") == "pr")
with open(destination, "w", encoding="utf-8") as handle:
    handle.write(step["run"])
PY
  for body in "$@"; do
    index=$((index + 1))
    write_json_file "$RESOLVE_DIR/api-payload-$index.json" pull-request "$body"
  done
  cat > "$RESOLVE_DIR/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_ARGS_LOG"
[ "$1" = api ] || { echo "unexpected gh subcommand: $1" >&2; exit 9; }
call=$(wc -l < "$GH_ARGS_LOG" | tr -d ' ')
[ "$call" -le "$GH_PAYLOAD_COUNT" ] || call=$GH_PAYLOAD_COUNT
cat "$GH_PAYLOAD_DIR/api-payload-$call.json"
EOF
  chmod +x "$RESOLVE_DIR/bin/gh"
  (
    cd "$RESOLVE_DIR/work" || exit 1
    PATH="$RESOLVE_DIR/bin:$PATH" \
      GH_ARGS_LOG="$RESOLVE_DIR/gh-args" GH_PAYLOAD_DIR="$RESOLVE_DIR" \
      GH_PAYLOAD_COUNT="$index" \
      NM_BODY_SYNC_ATTEMPTS="${RESOLVE_ATTEMPTS:-2}" NM_BODY_SYNC_DELAY_SECONDS=0 \
      GH_TOKEN=stub PR_NUMBER=3006 PR_REPO=acme/widgets \
      GITHUB_OUTPUT="$RESOLVE_DIR/outputs" \
      bash "$RESOLVE_DIR/step.sh"
  )
}

# How many times the resolve step asked the API for the pull request.
resolve_step_reads() {
  wc -l < "$RESOLVE_DIR/gh-args" | tr -d ' '
}

# Hand the resolve step's outputs to the verifier the way the action does,
# with the stale event payload still on disk underneath.
verify_from_resolved_outputs() {
  python3 - "$VERIFY" "$RESOLVE_DIR/outputs" "$STALE_EVENT" <<'PY'
import os
import subprocess
import sys

verify, outputs_path, event_path = sys.argv[1:4]
with open(outputs_path, encoding="utf-8") as handle:
    lines = handle.read().splitlines()

resolved = {}
index = 0
while index < len(lines):
    line = lines[index]
    if "<<" in line:
        name, delimiter = line.split("<<", 1)
        index += 1
        chunk = []
        while lines[index] != delimiter:
            chunk.append(lines[index])
            index += 1
        resolved[name] = "\n".join(chunk)
    else:
        name, _, value = line.partition("=")
        resolved[name] = value
    index += 1

inputs = {
    "body": "PR_BODY",
    "head-sha": "PR_HEAD_SHA",
    "head-ref": "PR_HEAD_REF",
    "author": "PR_AUTHOR",
}
env = dict(os.environ)
for name, value in resolved.items():
    if name in inputs:
        env[inputs[name]] = value
env["PR_NUMBER"] = "3006"
env["GITHUB_EVENT_PATH"] = event_path
env.pop("GITHUB_OUTPUT", None)

result = subprocess.run([sys.executable, verify], env=env, capture_output=True, text=True)
sys.stdout.write(result.stdout + result.stderr)
raise SystemExit(result.returncode)
PY
}

test_event_payload_alone_fails_on_a_re_attested_pull_request() {
  local output rc=0
  write_json_file "$STALE_EVENT" event "$(attested_body "$OLD_SHA")"
  output=$(PR_BODY='' PR_HEAD_SHA='' PR_HEAD_REF='' PR_AUTHOR='' PR_NUMBER='' \
    GITHUB_EVENT_PATH="$STALE_EVENT" python3 "$VERIFY" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "an event payload whose body is out of date should not pass"
  assert_contains "$output" "$OLD_SHA" \
    "the stale-payload failure did not name the attestation it read"
  pass "the event payload alone fails once the pull request body has moved on"
}

test_resolve_step_supplies_the_current_body() {
  local output rc=0
  write_json_file "$STALE_EVENT" event "$(attested_body "$OLD_SHA")"
  run_resolve_step "$(attested_body "$NEW_SHA")" \
    || fail "the workflow resolve step failed against a stubbed gh"
  assert_grep "repos/acme/widgets/pulls/3006" "$RESOLVE_DIR/gh-args" \
    "the resolve step did not ask the API for this repository's pull request"
  output=$(verify_from_resolved_outputs 2>&1) || rc=$?
  expect_code 0 "$rc" "the resolved body and head were rejected: $output"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "the resolved inputs did not reach the shared verifier"
  pass "the resolve step hands the verifier the body the pull request has now"
}

test_resolve_step_keeps_an_out_of_date_body_failing() {
  local output rc=0
  write_json_file "$STALE_EVENT" event "$(attested_body "$OLD_SHA")"
  run_resolve_step "$(attested_body "$OLD_SHA")" \
    || fail "the workflow resolve step failed against a stubbed gh"
  output=$(verify_from_resolved_outputs 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a body still bound to an older head must not pass"
  assert_contains "$output" "$NEW_SHA" \
    "the failure did not name the head the pull request actually has"
  pass "reading the pull request live does not excuse an older attestation"
}

# --- the body catches up a moment after the push ----------------------------
#
# The push wakes this workflow and the body re-attestation lands right after it,
# so even a live read can arrive in the gap between the two writes. The resolve
# step re-reads the pull request while the attestation still names an older
# head, and stops once it catches up, once its bound runs out, or at once when
# there is no attestation to wait for.

test_resolve_step_waits_for_the_body_to_catch_up() {
  local output rc=0 reads
  write_json_file "$STALE_EVENT" event "$(attested_body "$OLD_SHA")"
  RESOLVE_ATTEMPTS=3 run_resolve_step "$(attested_body "$OLD_SHA")" "$(attested_body "$NEW_SHA")" \
    || fail "the workflow resolve step failed against a stubbed gh"
  reads=$(resolve_step_reads)
  [ "$reads" -eq 2 ] || fail "expected one re-read of the pull request, saw $reads read(s)"
  output=$(verify_from_resolved_outputs 2>&1) || rc=$?
  expect_code 0 "$rc" "the re-attested body was rejected: $output"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "the re-read body did not reach the shared verifier"
  pass "the resolve step waits for a body that is still catching up with the head"
}

test_resolve_step_stops_re_reading_at_its_bound() {
  local output rc=0 reads
  write_json_file "$STALE_EVENT" event "$(attested_body "$OLD_SHA")"
  RESOLVE_ATTEMPTS=3 run_resolve_step "$(attested_body "$OLD_SHA")" \
    || fail "the workflow resolve step failed against a stubbed gh"
  reads=$(resolve_step_reads)
  [ "$reads" -eq 3 ] || fail "expected 3 reads of the pull request, saw $reads"
  output=$(verify_from_resolved_outputs 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a body that never catches up must not pass"
  assert_contains "$output" "$NEW_SHA" \
    "the failure did not name the head the pull request actually has"
  pass "the resolve step gives up on its bound and lets the older attestation fail"
}

test_resolve_step_does_not_wait_without_an_attestation() {
  local output rc=0 reads
  write_json_file "$STALE_EVENT" event "$(attested_body "$OLD_SHA")"
  RESOLVE_ATTEMPTS=3 run_resolve_step "$SIGNATURE" \
    || fail "the workflow resolve step failed against a stubbed gh"
  reads=$(resolve_step_reads)
  [ "$reads" -eq 1 ] || fail "expected a single read for a body with no attestation, saw $reads"
  output=$(verify_from_resolved_outputs 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a body with no attestation must not pass"
  pass "a body carrying no attestation fails at once instead of waiting"
}

fetch_shared_verifier
test_matching_head_and_completed_steps_pass
test_mismatched_head_fails_with_both_shas
test_missing_head_fails
test_event_payload_alone_fails_on_a_re_attested_pull_request
test_resolve_step_supplies_the_current_body
test_resolve_step_keeps_an_out_of_date_body_failing
test_resolve_step_waits_for_the_body_to_catch_up
test_resolve_step_stops_re_reading_at_its_bound
test_resolve_step_does_not_wait_without_an_attestation
