#!/usr/bin/env bash
# Behavior tests for the A2A second-mate transport: bin/fm-a2a-secondmate.sh,
# bin/fm-a2a-client.py and bin/fm-procevent-a2a-reply.sh.
#
# A local fake A2A server stands in for the remote agent. It speaks the
# JSON-RPC methods the client uses (SendMessage, ListTasks), checks the bearer
# token, and enforces a per-context turn cap the way Hermes does. Every
# scenario goes through the public commands: registration, fm-send routing, the
# process-event runner, the parent status channel and the lifecycle guards.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-a2a-secondmate)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"
PARENT="$TMP_ROOT/parent"
MATE_HOME="$TMP_ROOT/mate-home"
SERVER_DIR="$TMP_ROOT/server"
mkdir -p "$PARENT/state" "$PARENT/data" "$PARENT/config" "$SERVER_DIR"
fm_test_track_procevent_home "$PARENT"
TOKEN=test-token-$$
CRED="$TMP_ROOT/cred.env"
(umask 077; printf 'FAKE_A2A_TOKEN=%s\n' "$TOKEN" > "$CRED")
CHARTER="$TMP_ROOT/charter.md"
printf 'Reply in plain text; Firstmate reads your reply.\n' > "$CHARTER"

# Fake A2A agent. Behaviour switches are files in $SERVER_DIR: cap (turns per
# context, default 5) and mode (reply|fail). Every accepted SendMessage is
# appended to received.jsonl.
cat > "$SERVER_DIR/server.py" <<'PY'
import http.server, json, os, sys, threading
directory, token = sys.argv[1], sys.argv[2]
turns, lock = {}, threading.Lock()
def setting(name, default):
    try:
        return open(os.path.join(directory, name)).read().strip()
    except OSError:
        return default
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def reply(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        self.reply(200, {"name": "fake-scrooge", "url": "http://127.0.0.1/"})
    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.headers.get("Authorization") != f"Bearer {token}":
            return self.reply(401, {"jsonrpc": "2.0", "id": None, "error": {"code": -32050, "message": "unauthorized"}})
        if request["method"] == "ListTasks":
            return self.reply(200, {"jsonrpc": "2.0", "id": request["id"], "result": {"tasks": []}})
        message = request["params"]["message"]
        context = message["contextId"]
        with lock:
            turns[context] = turns.get(context, 0) + 1
            count = turns[context]
            with open(os.path.join(directory, "received.jsonl"), "a") as log:
                log.write(json.dumps(message) + "\n")
        task = {"id": f"task-{count}", "contextId": context}
        if count > int(setting("cap", "5")):
            task["status"] = {"state": "TASK_STATE_REJECTED", "message": {"parts": [{"text": f"Anti-loop protection: context {context} exceeded."}]}}
        elif setting("mode", "reply") == "fail":
            task["status"] = {"state": "TASK_STATE_FAILED", "message": {"parts": [{"text": "[agent processing failed]"}]}}
        else:
            text = "pong for " + message["parts"][0]["text"].splitlines()[2]
            task["status"] = {"state": "TASK_STATE_COMPLETED"}
            task["artifacts"] = [{"artifactId": "a1", "parts": [{"text": text}]}]
        self.reply(200, {"jsonrpc": "2.0", "id": request["id"], "result": {"task": task}})
server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
open(os.path.join(directory, "port.tmp"), "w").write(str(server.server_port))
os.replace(os.path.join(directory, "port.tmp"), os.path.join(directory, "port"))
server.serve_forever()
PY
python3 "$SERVER_DIR/server.py" "$SERVER_DIR" "$TOKEN" &
SERVER_PID=$!
fm_test_track_pid "$SERVER_PID"
for _ in $(seq 1 100); do [ -s "$SERVER_DIR/port" ] && break; sleep 0.05; done
[ -s "$SERVER_DIR/port" ] || fail "fake A2A server did not start"
URL="http://127.0.0.1:$(cat "$SERVER_DIR/port")/"

a2a() { FM_HOME="$PARENT" "$ROOT/bin/fm-a2a-secondmate.sh" "$@"; }
send() { FM_HOME="$PARENT" "$ROOT/bin/fm-send.sh" "$@"; }
status_lines() { cat "$PARENT/state/scrooge-test.status" 2>/dev/null; }
received() { wc -l < "$SERVER_DIR/received.jsonl" 2>/dev/null | tr -d ' ' || printf 0; }
contexts() { jq -r '.contextId' "$SERVER_DIR/received.jsonl"; }
wait_for_lines() {  # <count> [tries]
  local n=${2:-200}
  for _ in $(seq 1 "$n"); do
    [ "$(status_lines | grep -c '^[a-z-]* \[corr=')" -ge "$1" ] && return 0
    sleep 0.1
  done
  return 1
}

wait_for_handled() {  # <count> [tries]
  local n=${2:-100}
  for _ in $(seq 1 "$n"); do
    [ "$(find "$PARENT/state/procevent-inbox" -name 'a2a-*.handled' 2>/dev/null | wc -l)" -ge "$1" ] && return 0
    sleep 0.1
  done
  return 1
}

test_register_and_validate() {
  local out
  out=$(a2a register scrooge-test "$MATE_HOME" "$URL" "$CRED" FAKE_A2A_TOKEN "Money questions routed by Firstmate" "$CHARTER" 3) ||
    fail "register failed"
  assert_contains "$out" '"id": "scrooge-test"' "register reports the mate"
  assert_contains "$(cat "$PARENT/state/scrooge-test.meta")" 'transport=a2a' "metadata records the a2a transport"
  assert_contains "$(cat "$PARENT/data/secondmates.md")" '- scrooge-test - Hermes profile over A2A' "registry carries the mate"
  assert_not_contains "$(cat "$MATE_HOME/config/a2a.json")" "$TOKEN" "the credential is never copied into the mate home"
  a2a validate scrooge-test || fail "validate refused a fresh registration"
  out=$(a2a register scrooge-test "$MATE_HOME" "$URL" "$CRED" FAKE_A2A_TOKEN "Money questions routed by Firstmate" "$CHARTER" 3) ||
    fail "identical re-registration must succeed"
  assert_contains "$out" '"already_registered": true' "identical re-registration is idempotent"
  out=$(a2a register scrooge-test "$MATE_HOME" "${URL}other" "$CRED" FAKE_A2A_TOKEN "Money questions routed by Firstmate" "$CHARTER" 3 2>&1) &&
    fail "a changed route must be refused"
  assert_contains "$out" 'differs' "a changed route is refused without overwriting"
  out=$(a2a health scrooge-test) || fail "health must be ready: $out"
  assert_contains "$out" 'a2a=ready auth=ok agent=fake-scrooge' "health checks the card and the credential"
  pass "a2a: register, idempotent re-register, refused overwrite, validate and health"
}

test_send_reply_becomes_status_line() {
  local first report corr text out
  send scrooge-test "Subject: ping one
Say pong." || fail "fm-send to the a2a mate failed"
  wait_for_lines 1 || fail "no correlated status line arrived: $(status_lines)"
  first=$(status_lines | grep '^done \[corr=' | head -1)
  assert_contains "$first" 'scrooge-test completed: pong for Subject: ping one' "the reply lands as one done line"
  corr=$(printf '%s' "$first" | sed -E 's/^done \[corr=([a-f0-9]{16})\].*/\1/')
  [ -f "$PARENT/state/pending-replies/$corr" ] || fail "the correlation must match a pending-reply record"
  report=$(printf '%s' "$first" | sed -E 's/.*\(report=([^)]*)\)$/\1/')
  assert_contains "$(cat "$PARENT/$report")" 'pong for Subject: ping one' "the full reply is stored in the parent home"
  text=$(jq -r '.parts[0].text' "$SERVER_DIR/received.jsonl" | head -3)
  assert_contains "$text" "Message from Firstmate (the captain's coding orchestrator, not the captain):" "outbound text names Firstmate"
  assert_not_contains "$text" '[fm-from-firstmate]' "the internal routing marker is stripped"
  assert_contains "$(jq -r '.parts[0].text' "$SERVER_DIR/received.jsonl")" 'Reply in plain text' "the charter rides with the message"
  wait_for_handled 1 || fail "the reply capture must be acknowledged by the adapter"
  assert_not_contains "$(cat "$PARENT/state/.wake-queue" 2>/dev/null)" 'procevent a2a-reply' "a published reply raises no second process-event wake"
  out=$(FM_HOME="$PARENT" "$ROOT/bin/fm-peek.sh" scrooge-test 2>/dev/null)
  assert_contains "$out" 'a2a=ready auth=ok' "peek reports transport health instead of a pane"
  out=$(FM_HOME="$PARENT" "$ROOT/bin/fm-crew-state.sh" scrooge-test 2>/dev/null)
  assert_contains "$out" 'state: done' "crew state folds the reply line"
  assert_contains "$out" 'a2a=ready' "crew state carries transport health"
  pass "a2a: fm-send delivers once and the reply arrives as a correlated status line"
}

test_context_is_stable_then_rotates_before_cap() {
  send scrooge-test "Subject: ping two
Second turn." || fail "second send failed"
  send scrooge-test "Subject: ping three
Third turn." || fail "third send failed"
  wait_for_lines 3 || fail "missing replies: $(status_lines)"
  send scrooge-test "Subject: ping four
Fourth turn rotates." || fail "fourth send failed"
  wait_for_lines 4 || fail "missing fourth reply: $(status_lines)"
  [ "$(contexts | head -3 | sort -u | wc -l)" -eq 1 ] || fail "the first three turns must share one conversation"
  [ "$(contexts | sort -u | wc -l)" -eq 2 ] || fail "the fourth turn must start a new conversation at the client cap of 3"
  pass "a2a: one conversation key per turn cap, rotated before the cap"
}

test_server_rejection_rotates_once() {
  local before after
  printf '1\n' > "$SERVER_DIR/cap"
  before=$(received)
  send scrooge-test "Subject: ping five
Server cap is lower than ours." || fail "fifth send failed"
  wait_for_lines 5 || fail "no reply after the anti-loop retry: $(status_lines)"
  after=$(received)
  [ "$((after - before))" -eq 2 ] || fail "a rejected turn is resent exactly once on a new conversation (sent $((after - before)))"
  assert_contains "$(status_lines | tail -1)" 'pong for Subject: ping five' "the resent turn's reply is published"
  rm -f "$SERVER_DIR/cap"
  pass "a2a: a server anti-loop rejection rotates the conversation and resends once"
}

test_failed_reply_and_interrupted_send() {
  local record before out line
  printf 'fail\n' > "$SERVER_DIR/mode"
  send scrooge-test "Subject: ping six
This one fails." || fail "sixth send failed"
  wait_for_lines 6 || fail "no failed line: $(status_lines)"
  assert_contains "$(status_lines | tail -1)" 'failed [corr=' "an agent failure becomes a failed line"
  rm -f "$SERVER_DIR/mode"
  # An interrupted earlier attempt: the record says sending. Delivery must not resend.
  record=$(find "$MATE_HOME/state/a2a/requests" -maxdepth 1 -name "*.json" -printf "%f\n" | sort | head -1)
  jq '.state = "sending"' "$MATE_HOME/state/a2a/requests/$record" > "$TMP_ROOT/rec.json"
  cp "$TMP_ROOT/rec.json" "$MATE_HOME/state/a2a/requests/$record"
  before=$(received)
  out=$(FM_HOME="$PARENT" python3 "$ROOT/bin/fm-a2a-client.py" deliver scrooge-test "${record%.json}")
  assert_contains "$out" '"outcome": "unknown"' "an interrupted send reports an unknown outcome"
  [ "$(received)" -eq "$before" ] || fail "an interrupted send must never be resent automatically"
  line=$(printf '%s\n' "$out" > "$TMP_ROOT/unknown.result"; FM_HOME="$PARENT" "$ROOT/bin/fm-procevent-a2a-reply.sh" classify "$TMP_ROOT/unknown.result")
  assert_equals "unknown" "$line" "classify reports the unknown outcome"
  pass "a2a: agent failures publish failed; an interrupted send is never resent"
}

test_unreachable_is_undelivered_and_resendable() {
  local out corr
  kill "$SERVER_PID" 2>/dev/null
  wait "$SERVER_PID" 2>/dev/null
  send scrooge-test "Subject: ping seven
Nobody is listening." || fail "the send itself must still be accepted"
  wait_for_lines 7 || fail "no blocked line: $(status_lines)"
  out=$(status_lines | tail -1)
  assert_contains "$out" 'blocked [corr=' "an unreachable agent opens a blocker"
  assert_contains "$out" '[key=a2a-' "the blocker carries an a2a key"
  assert_contains "$out" 'undelivered' "the line says the message was not delivered"
  corr=$(printf '%s' "$out" | sed -E 's/^blocked \[corr=([a-f0-9]{16})\].*/\1/')
  out=$(printf 'x' | FM_HOME="$PARENT" python3 "$ROOT/bin/fm-a2a-client.py" prepare scrooge-test --corr "$corr")
  assert_contains "$out" '"state": "queued"' "a new message on the same correlation is queued"
  pass "a2a: an unreachable agent publishes an undelivered blocker that can be resent"
}

test_lifecycle_guards_refuse() {
  local out
  out=$(FM_HOME="$PARENT" "$ROOT/bin/fm-control.sh" scrooge-test interrupt 2>&1) && fail "interrupt must be refused"
  assert_contains "$out" 'no local process' "fm-control refuses an a2a mate"
  out=$(FM_HOME="$PARENT" "$ROOT/bin/fm-teardown.sh" scrooge-test 2>&1) && fail "teardown must be refused"
  assert_contains "$out" 'REFUSED' "teardown refuses an a2a mate"
  out=$(FM_HOME="$PARENT" "$ROOT/bin/fm-send.sh" scrooge-test --key Enter 2>&1) && fail "terminal keys must be refused"
  assert_contains "$out" 'no terminal keys' "fm-send refuses terminal keys"
  pass "a2a: control, teardown and terminal keys refuse a transport mate"
}

test_register_and_validate
test_send_reply_becomes_status_line
test_context_is_stable_then_rotates_before_cap
test_server_rejection_rotates_once
test_failed_reply_and_interrupted_send
test_unreachable_is_undelivered_and_resendable
test_lifecycle_guards_refuse
