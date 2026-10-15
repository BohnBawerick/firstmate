#!/usr/bin/env bash
# Behavioral tests for bin/fm-dot-mailbox.sh and bin/fm-dot-mailbox.py.
#
# Covers:
#   1. CLI usage and help plumbing.
#   2. Local mailbox message submission, idempotency, cursors, and replies.
#   3. MCP 2.0 (version 2026-07-28) server discovery, tools, and events.
#   4. Callback verification challenge and signed Standard Webhook event delivery.
#   5. Server restart persistence and database recovery.
#   6. Security contract: strict rejection of non-HTTPS and private/loopback callbacks.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MAILBOX="$ROOT/bin/fm-dot-mailbox.sh"
PYTHON_ENGINE="$ROOT/bin/fm-dot-mailbox.py"
TMP_ROOT=$(fm_test_tmproot fm-dot-mailbox)
DB_PATH="$TMP_ROOT/mailbox.sqlite3"

get_free_port() {
  python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

test_help_plumbing() {
  local out rc
  out=$("$MAILBOX" --help 2>&1)
  rc=$?
  expect_code 0 "$rc" "--help must exit 0"
  assert_contains "$out" "submit" "--help lists submit command"
  assert_contains "$out" "get" "--help lists get command"
  assert_contains "$out" "list" "--help lists list command"
  assert_contains "$out" "reply" "--help lists reply command"
  assert_contains "$out" "status" "--help lists status command"
  assert_contains "$out" "serve" "--help lists serve command"
  pass "fm-dot-mailbox: --help prints usage for all commands"
}

test_unknown_command_fails() {
  local out rc
  out=$("$MAILBOX" bogus 2>&1 || true)
  assert_contains "$out" "unknown command 'bogus'" "unknown command reports error"
  pass "fm-dot-mailbox: unknown command exits non-zero"
}

test_mailbox_crud_and_idempotency() {
  local out rc msg_id
  export FM_DOT_MAILBOX_DB="$DB_PATH"

  # Initial status
  out=$("$MAILBOX" status)
  assert_contains "$out" "messages: total=0 pending=0 replied=0" "empty mailbox starts at zero"

  # Submit message
  out=$("$MAILBOX" submit --queue "tasks" --correlation-id "corr-001" --idempotency-key "idem-001" "hello world nonce 12345")
  assert_contains "$out" "\"status\": \"pending\"" "message starts pending"
  assert_contains "$out" "\"queue\": \"tasks\"" "queue matches"
  assert_contains "$out" "hello world nonce 12345" "content matches"
  msg_id=$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])["id"])' "$out")

  # Idempotent resubmission
  out=$("$MAILBOX" submit --queue "tasks" --correlation-id "corr-001" --idempotency-key "idem-001" "hello world nonce 12345")
  assert_contains "$out" "\"id\": \"$msg_id\"" "resubmitting with same key returns original message id"

  # List messages
  out=$("$MAILBOX" list --queue "tasks")
  assert_contains "$out" "\"id\": \"$msg_id\"" "list includes submitted message"
  assert_contains "$out" "\"next_cursor\": \"1\"" "list returns valid next_cursor"

  # Reply to message
  out=$("$MAILBOX" reply "$msg_id" "all checks passed")
  assert_contains "$out" "\"status\": \"ok\"" "reply succeeds"
  assert_contains "$out" "\"message_id\": \"$msg_id\"" "reply references correct id"

  # Get message
  out=$("$MAILBOX" get "$msg_id")
  assert_contains "$out" "\"status\": \"replied\"" "status updated to replied"
  assert_contains "$out" "\"reply\": \"all checks passed\"" "reply stored correctly"

  # Status after reply
  out=$("$MAILBOX" status)
  assert_contains "$out" "messages: total=1 pending=0 replied=1" "status reflects replied message"

  pass "fm-dot-mailbox: CLI submit, idempotency, list, reply, get, and status succeed"
}

test_mcp_http_and_event_callback_delivery() {
  local srv_port rcv_port srv_pid rcv_pid srv_db log_dir out res_file secret
  export FM_DOT_MCP_ALLOW_LOCAL_CALLBACK=1

  srv_port=$(get_free_port)
  rcv_port=$(get_free_port)
  srv_db="$TMP_ROOT/mcp_server.sqlite3"
  log_dir="$TMP_ROOT/mcp_logs"
  mkdir -p "$log_dir"
  res_file="$log_dir/receiver.json"

  # Start mock event receiver in background
  python3 -c '
import http.server, json, sys, os, base64, hmac, hashlib

res_file = sys.argv[1]
port = int(sys.argv[2])
secret_b64 = sys.argv[3]
raw_key = base64.b64decode(secret_b64)

state = {"verifications": [], "events": []}

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format, *args): pass
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        msg_id = self.headers.get("webhook-id")
        ts = self.headers.get("webhook-timestamp")
        sig = self.headers.get("webhook-signature")

        # Verify HMAC signature
        to_sign = f"{msg_id}.{ts}.".encode("utf-8") + body
        expected_sig = "v1," + base64.b64encode(hmac.new(raw_key, to_sign, hashlib.sha256).digest()).decode("utf-8")
        if sig != expected_sig:
            self.send_response(401, "Bad Signature")
            self.end_headers()
            return

        payload = json.loads(body.decode("utf-8"))
        if payload.get("type") == "verification":
            state["verifications"].append(payload)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"challenge": payload["challenge"]}).encode("utf-8"))
        else:
            state["events"].append(payload)
            self.send_response(200)
            self.end_headers()

        with open(res_file, "w") as f:
            json.dump(state, f)

server = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
server.serve_forever()
' "$res_file" "$rcv_port" "MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIz" >"$log_dir/rcv.log" 2>&1 &
  rcv_pid=$!
  fm_test_track_pid "$rcv_pid"

  # Start mailbox MCP server in background
  python3 "$PYTHON_ENGINE" --db "$srv_db" --allow-local-callbacks serve --host 127.0.0.1 --port "$srv_port" >"$log_dir/srv.log" 2>&1 &
  srv_pid=$!
  fm_test_track_pid "$srv_pid"

  # Wait for server readiness
  local ready=0 i=0
  while [ "$i" -lt 50 ]; do
    if curl -s "http://127.0.0.1:$srv_port/health" | grep -q '"status": "ok"'; then
      ready=1
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  [ "$ready" -eq 1 ] || fail "mcp server failed to start within 5 seconds"

  # 1. MCP server/discover
  out=$(curl -s -X POST "http://127.0.0.1:$srv_port/mcp" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc": "2.0", "id": 1, "method": "server/discover"}')
  assert_contains "$out" '"supportedVersions": ["2026-07-28"]' "MCP discover reports version 2026-07-28"
  assert_contains "$out" '"events": {}' "MCP discover reports events capability"

  # 2. MCP events/list
  out=$(curl -s -X POST "http://127.0.0.1:$srv_port/mcp" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc": "2.0", "id": 2, "method": "events/list"}')
  assert_contains "$out" '"name": "message.created"' "events/list includes message.created"

  # 3. MCP events/subscribe (triggers challenge verification)
  out=$(curl -s -X POST "http://127.0.0.1:$srv_port/mcp" \
    -H "Content-Type: application/json" \
    -d '{
      "jsonrpc": "2.0",
      "id": 3,
      "method": "events/subscribe",
      "params": {
        "name": "message.created",
        "arguments": {"queue": "proof-queue"},
        "delivery": {
          "mode": "webhook",
          "url": "http://127.0.0.1:'"$rcv_port"'/callback",
          "secret": "whsec_MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIz"
        }
      }
    }')
  assert_contains "$out" '"id": "sub_' "events/subscribe returns subscription id"
  assert_contains "$out" '"refreshBefore"' "events/subscribe returns refreshBefore"

  # 4. Submit message via operator CLI and assert event webhook delivered
  out=$("$MAILBOX" --db "$srv_db" submit --queue "proof-queue" --correlation-id "nonce-987" "execute line-plane visible proof")
  assert_contains "$out" "execute line-plane visible proof" "operator submit succeeded"

  # Wait for event in receiver JSON
  local delivered=0
  i=0
  while [ "$i" -lt 30 ]; do
    if [ -f "$res_file" ] && grep -q "nonce-987" "$res_file" 2>/dev/null; then
      delivered=1
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  [ "$delivered" -eq 1 ] || fail "event delivery was not received by callback receiver"

  # 5. Retrieve via MCP get_messages tool
  out=$(curl -s -X POST "http://127.0.0.1:$srv_port/mcp" \
    -H "Content-Type: application/json" \
    -d '{
      "jsonrpc": "2.0",
      "id": 4,
      "method": "tools/call",
      "params": {
        "name": "get_messages",
        "arguments": {"queue": "proof-queue", "status": "pending"}
      }
    }')
  assert_contains "$out" "nonce-987" "MCP get_messages retrieves pending message"

  local msg_id
  msg_id=$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
text = json.loads(data["result"]["content"][0]["text"])
print(text["messages"][0]["id"])
' "$out")

  # 6. Reply via MCP reply tool
  out=$(curl -s -X POST "http://127.0.0.1:$srv_port/mcp" \
    -H "Content-Type: application/json" \
    -d '{
      "jsonrpc": "2.0",
      "id": 5,
      "method": "tools/call",
      "params": {
        "name": "reply",
        "arguments": {
          "message_id": "'"$msg_id"'",
          "reply": "visible proof result: 11,390 matched, 0 mismatches"
        }
      }
    }')
  assert_contains "$out" '"isError": false' "MCP reply succeeded without error"
  assert_contains "$out" 'status' "MCP reply returned status"

  # 7. Verify via operator CLI get
  out=$("$MAILBOX" --db "$srv_db" get "$msg_id")
  assert_contains "$out" "\"status\": \"replied\"" "operator reads replied status"
  assert_contains "$out" "11,390 matched, 0 mismatches" "operator reads full reply"

  # 8. Unsubscribe via MCP
  out=$(curl -s -X POST "http://127.0.0.1:$srv_port/mcp" \
    -H "Content-Type: application/json" \
    -d '{
      "jsonrpc": "2.0",
      "id": 6,
      "method": "events/unsubscribe",
      "params": {
        "name": "message.created",
        "arguments": {"queue": "proof-queue"},
        "delivery": {
          "mode": "webhook",
          "url": "http://127.0.0.1:'"$rcv_port"'/callback"
        }
      }
    }')
  assert_contains "$out" '"result": {}' "events/unsubscribe succeeded"

  # Cleanup background processes
  fm_test_reap_pid "$srv_pid"
  fm_test_reap_pid "$rcv_pid"
  pass "fm-dot-mailbox: MCP HTTP discovery, subscription challenge, signed webhook delivery, tools, and reply work end-to-end"
}

test_security_callback_contract() {
  local srv_port srv_pid srv_db log_dir out
  unset FM_DOT_MCP_ALLOW_LOCAL_CALLBACK

  srv_port=$(get_free_port)
  srv_db="$TMP_ROOT/mcp_security.sqlite3"
  log_dir="$TMP_ROOT/mcp_sec_logs"
  mkdir -p "$log_dir"

  # Start mailbox MCP server in default strict security mode
  python3 "$PYTHON_ENGINE" --db "$srv_db" serve --host 127.0.0.1 --port "$srv_port" >"$log_dir/srv.log" 2>&1 &
  srv_pid=$!
  fm_test_track_pid "$srv_pid"

  local ready=0 i=0
  while [ "$i" -lt 50 ]; do
    if curl -s "http://127.0.0.1:$srv_port/health" | grep -q '"status": "ok"'; then
      ready=1
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  [ "$ready" -eq 1 ] || fail "mcp security server failed to start"

  # 1. Non-HTTPS callback must be rejected
  out=$(curl -s -X POST "http://127.0.0.1:$srv_port/mcp" \
    -H "Content-Type: application/json" \
    -d '{
      "jsonrpc": "2.0",
      "id": 1,
      "method": "events/subscribe",
      "params": {
        "name": "message.created",
        "delivery": {
          "mode": "webhook",
          "url": "http://example.com/callback",
          "secret": "whsec_MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIz"
        }
      }
    }')
  assert_contains "$out" '"code": -32015' "non-HTTPS callback rejected with -32015"
  assert_contains "$out" "must use HTTPS" "error explains HTTPS requirement"

  # 2. Local loopback / private IP must be rejected
  out=$(curl -s -X POST "http://127.0.0.1:$srv_port/mcp" \
    -H "Content-Type: application/json" \
    -d '{
      "jsonrpc": "2.0",
      "id": 2,
      "method": "events/subscribe",
      "params": {
        "name": "message.created",
        "delivery": {
          "mode": "webhook",
          "url": "https://127.0.0.1:8443/callback",
          "secret": "whsec_MDEyMzQ1Njc4OTAxMjM0NTY3ODkwMTIz"
        }
      }
    }')
  assert_contains "$out" '"code": -32015' "loopback IP rejected with -32015"
  assert_contains "$out" "blocked" "error explains blocked address"

  # 3. Invalid secret (not whsec_) must be rejected
  out=$(curl -s -X POST "http://127.0.0.1:$srv_port/mcp" \
    -H "Content-Type: application/json" \
    -d '{
      "jsonrpc": "2.0",
      "id": 3,
      "method": "events/subscribe",
      "params": {
        "name": "message.created",
        "delivery": {
          "mode": "webhook",
          "url": "https://example.com/callback",
          "secret": "invalid_secret"
        }
      }
    }')
  assert_contains "$out" '"code": -32015' "invalid secret rejected with -32015"
  assert_contains "$out" "whsec_" "error mentions whsec_ prefix requirement"

  fm_test_reap_pid "$srv_pid"
  pass "fm-dot-mailbox: security contract enforces HTTPS, blocks private IPs, and validates secrets"
}

test_server_restart_persistence() {
  local restart_db out msg_id
  restart_db="$TMP_ROOT/restart.sqlite3"

  # Submit message
  out=$("$MAILBOX" --db "$restart_db" submit --queue "persist" "restart test message")
  msg_id=$(python3 -c 'import json, sys; print(json.loads(sys.argv[1])["id"])' "$out")

  # Reply
  "$MAILBOX" --db "$restart_db" reply "$msg_id" "reply before restart" >/dev/null

  # Verify state survives across processes
  out=$("$MAILBOX" --db "$restart_db" get "$msg_id")
  assert_contains "$out" "\"reply\": \"reply before restart\"" "reply persists in database"
  assert_contains "$out" "\"status\": \"replied\"" "status persists in database"

  # Cursors survive
  out=$("$MAILBOX" --db "$restart_db" list --queue "persist")
  assert_contains "$out" "\"id\": \"$msg_id\"" "list reads from persisted database"

  pass "fm-dot-mailbox: state and cursors persist across process restarts"
}

test_help_plumbing
test_unknown_command_fails
test_mailbox_crud_and_idempotency
test_mcp_http_and_event_callback_delivery
test_security_callback_contract
test_server_restart_persistence
