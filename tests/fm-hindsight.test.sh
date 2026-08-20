#!/usr/bin/env bash
# Behavioral coverage for Hindsight retention, recall, and corpus boundary.
#
# Every assertion here exercises bin/fm-hindsight-retain.sh and
# bin/fm-hindsight-recall.sh through their executable interfaces.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-hindsight)
RETAIN="$ROOT/bin/fm-hindsight-retain.sh"
RECALL="$ROOT/bin/fm-hindsight-recall.sh"

new_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/data/decisions" "$home/state" "$home/config" "$home/data/memory/notes"
  printf '%s\n' "$home"
}

make_fake_hindsight_curl() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
method=GET
url=""
data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift 2 ;;
    -d|--data|--data-raw|--data-binary)
      case "$2" in
        @*) data=$(cat -- "${2#@}") ;;
        *) data=$2 ;;
      esac
      shift 2
      ;;
    -H|-s|-S|--connect-timeout|--max-time) shift ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done

if [ -n "${FAKE_CURL_LOG:-}" ]; then
  {
    echo "method=$method"
    echo "url=$url"
    echo "data=$data"
  } >> "$FAKE_CURL_LOG"
fi

case "$url" in
  */v1/default/banks/*)
    case "$url" in
      */memories/recall)
        if [ -n "${FAKE_RECALL_RESPONSE:-}" ]; then
          printf '%s\n' "$FAKE_RECALL_RESPONSE"
        else
          printf '{"results":[{"id":"res1","text":"Sample recalled memory text","type":"experience","document_id":"report:task-1"}]}\n'
        fi
        exit 0
        ;;
      */memories)
        if [ "$method" = "POST" ]; then
          printf '{"success":true,"bank_id":"firstmate","items_count":1,"async":false,"usage":{"input_tokens":100,"output_tokens":50,"total_tokens":150}}\n'
          exit 0
        fi
        ;;
      */documents*)
        if [ -n "${FAKE_DOCUMENTS_RESPONSE:-}" ]; then
          printf '%s\n' "$FAKE_DOCUMENTS_RESPONSE"
        else
          printf '{"items":[],"total":0,"limit":100,"offset":0}\n'
        fi
        exit 0
        ;;
      *)
        if [ "$method" = "PUT" ]; then
          printf '{"bank_id":"firstmate","name":"firstmate"}\n'
          exit 0
        fi
        ;;
    esac
    ;;
esac
printf '{"detail":"Not Found"}\n'
exit 1
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

# --- 1. Corpus boundary enforcement -----------------------------------------

test_corpus_boundary_enforcement() {
  local home out rc
  home=$(new_home boundary)
  mkdir -p "$home/data/scout-1" "$home/data/decisions" "$home/data/memory" "$home/state"

  # Valid corpus files
  printf '# Scout Report\nBody content\n' > "$home/data/scout-1/report.md"
  printf '# Decision\nDecision text\n' > "$home/data/decisions/dec-1.md"

  # Invalid files outside corpus
  printf 'captain text\n' > "$home/data/captain.md"
  printf 'shared captain\n' > "$home/data/captain-shared.md"
  printf 'core memory\n' > "$home/data/memory/core.md"
  printf 'note memory\n' > "$home/data/memory/notes/note-1.md"
  printf 'backlog\n' > "$home/data/backlog.md"
  printf 'archive\n' > "$home/data/done-archive.md"
  printf 'meta\n' > "$home/state/scout-1.meta"

  # Test each prohibited file path
  local invalid_files=(
    "$home/data/captain.md"
    "$home/data/captain-shared.md"
    "$home/data/memory/core.md"
    "$home/data/memory/notes/note-1.md"
    "$home/data/backlog.md"
    "$home/data/done-archive.md"
    "$home/state/scout-1.meta"
  )

  for file in "${invalid_files[@]}"; do
    out=$(FM_HOME="$home" "$RETAIN" "$file" 2>&1) && rc=0 || rc=$?
    [ "$rc" -ne 0 ] || fail "expected refusal for $file, but got exit 0"
    assert_contains "$out" "REFUSED" "refusal message missing for $file"
    assert_contains "$out" "outside authorized Hindsight corpus" "expected boundary explanation for $file"
  done

  pass "corpus boundary enforcement rejects all files outside data/*/report.md and data/decisions/*.md"
}

# --- 2. Credential and secret skipping --------------------------------------

test_credential_skipping() {
  local home fakebin log out rc
  home=$(new_home creds)
  fakebin=$(make_fake_hindsight_curl "$home")
  log="$home/curl.log"
  mkdir -p "$home/data/scout-cred"

  # Write a report with an API key
  cat > "$home/data/scout-cred/report.md" << 'EOF'
# Sensitive Report
The test worker configured sk-proj-12345678901234567890123456789012 for validation.
EOF

  out=$(PATH="$fakebin:$PATH" FAKE_CURL_LOG="$log" FM_HOME="$home" "$RETAIN" "$home/data/scout-cred/report.md" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "skipping credential-bearing report should exit cleanly"
  assert_contains "$out" "SKIP" "expected skip notice in output"
  assert_contains "$out" "scout-cred/report.md" "expected filename in skip notice"
  assert_contains "$out" "credentials" "expected mention of credentials in skip notice"

  # Verify curl was never called
  if [ -f "$log" ]; then
    fail "curl should never be called when credentials are detected in the document"
  fi

  pass "credential scanner skips document and never sends secrets to Hindsight"
}

# --- 3. Fire-and-forget unreachable Hindsight -------------------------------

test_unreachable_hindsight_fire_and_forget() {
  local home out rc start_ms end_ms elapsed_ms
  home=$(new_home unreachable)
  mkdir -p "$home/data/scout-1"
  printf '# Scout Report\nBody\n' > "$home/data/scout-1/report.md"

  # Point to dead port
  start_ms=$(date +%s%N 2>/dev/null || date +%s)
  out=$(FM_HOME="$home" FM_HINDSIGHT_URL="http://127.0.0.1:59999" "$RETAIN" "$home/data/scout-1/report.md" --fire-and-forget 2>&1) && rc=0 || rc=$?
  end_ms=$(date +%s%N 2>/dev/null || date +%s)

  # Clean up background job if still in flight
  sleep 0.1
  pkill -f "fm-hindsight-retain.sh.*127.0.0.1:59999" 2>/dev/null || true
  pkill -f "curl.*127.0.0.1:59999" 2>/dev/null || true
  wait 2>/dev/null || true

  [ "$rc" -eq 0 ] || fail "fire-and-forget should exit 0 even if Hindsight is unreachable"

  # If nanoseconds supported, assert duration < 500ms
  if [ "${#start_ms}" -gt 10 ]; then
    elapsed_ms=$(( (end_ms - start_ms) / 1000000 ))
    if [ "$elapsed_ms" -gt 500 ]; then
      fail "fire-and-forget took ${elapsed_ms}ms, exceeding measurable budget (500ms)"
    fi
  fi

  pass "fire-and-forget retain on unreachable host returns immediately with zero measurable delay"
}

# --- 4. Synchronous retention and document_id idempotency -------------------

test_synchronous_retention_and_idempotency() {
  local home fakebin log out rc
  home=$(new_home retain)
  fakebin=$(make_fake_hindsight_curl "$home")
  log="$home/curl.log"
  mkdir -p "$home/data/scout-1" "$home/data/decisions"
  printf '# Scout Report\nInvestigated bug causal factors.\n' > "$home/data/scout-1/report.md"
  printf '# Decision Record\nDecided to use tmux session backend.\n' > "$home/data/decisions/backend-choice.md"

  # Retain scout report
  out=$(PATH="$fakebin:$PATH" FAKE_CURL_LOG="$log" FM_HOME="$home" "$RETAIN" "$home/data/scout-1/report.md" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "retain scout report failed: $out"
  assert_contains "$out" "retained: report:scout-1" "expected report document_id in output"

  # Verify curl log has document_id report:scout-1
  assert_contains "$(cat "$log")" "report:scout-1" "curl payload missing report:scout-1 document_id"
  assert_contains "$(cat "$log")" "investigation report: scout-1" "curl payload missing context"

  # Retain decision record
  : > "$log"
  out=$(PATH="$fakebin:$PATH" FAKE_CURL_LOG="$log" FM_HOME="$home" "$RETAIN" "$home/data/decisions/backend-choice.md" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "retain decision record failed: $out"
  assert_contains "$out" "retained: decision:backend-choice" "expected decision document_id in output"
  assert_contains "$(cat "$log")" "decision:backend-choice" "curl payload missing decision:backend-choice document_id"

  pass "synchronous retain formats document_id and payload correctly for reports and decisions"
}

# --- 5. Recall formatting ---------------------------------------------------

test_recall_formatting() {
  local home fakebin out rc
  home=$(new_home recall)
  fakebin=$(make_fake_hindsight_curl "$home")

  # Default compact formatted output
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$RECALL" "sample query" 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "recall command failed: $out"
  assert_contains "$out" "[report:task-1]" "expected document_id tag in formatted output"
  assert_contains "$out" "(experience)" "expected memory type in formatted output"
  assert_contains "$out" "Sample recalled memory text" "expected memory text in formatted output"

  # JSON output mode
  out=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$RECALL" "sample query" --json 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "recall --json failed: $out"
  assert_contains "$out" '"results"' "expected JSON results object"

  pass "recall command outputs compact greppable results and supports --json"
}

# --- 6. Backfill resumability -----------------------------------------------

test_backfill_resumability() {
  local home fakebin log out rc docs_json
  home=$(new_home backfill)
  mkdir -p "$home/data/scout-1" "$home/data/scout-2" "$home/data/decisions"
  printf '# Scout 1\nBody 1\n' > "$home/data/scout-1/report.md"
  printf '# Scout 2\nBody 2\n' > "$home/data/scout-2/report.md"
  printf '# Decision 1\nDec 1\n' > "$home/data/decisions/dec-1.md"

  # Simulate Hindsight already having scout-1 and dec-1
  docs_json='{"items":[{"id":"report:scout-1"},{"id":"decision:dec-1"}],"total":2,"limit":100,"offset":0}'
  fakebin=$(make_fake_hindsight_curl "$home")
  log="$home/curl.log"

  out=$(PATH="$fakebin:$PATH" FAKE_DOCUMENTS_RESPONSE="$docs_json" FAKE_CURL_LOG="$log" FM_HOME="$home" "$RETAIN" --backfill 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "backfill failed: $out"
  assert_contains "$out" "already present: report:scout-1" "expected scout-1 to be skipped as already present"
  assert_contains "$out" "already present: decision:dec-1" "expected dec-1 to be skipped as already present"
  assert_contains "$out" "retained: report:scout-2" "expected scout-2 to be retained"
  assert_contains "$out" "backfill summary: 1 retained, 2 already present, 0 skipped for credentials, 0 failed, 3 total" "expected accurate backfill summary counts"

  pass "backfill detects already-retained documents and resumes by retaining only missing documents"
}

run_suite() {
  test_corpus_boundary_enforcement
  test_credential_skipping
  test_unreachable_hindsight_fire_and_forget
  test_synchronous_retention_and_idempotency
  test_recall_formatting
  test_backfill_resumability
}

run_suite
