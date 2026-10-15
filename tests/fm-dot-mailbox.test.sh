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
#   7. Request diagnostics include methods and status without payloads or secrets.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MAILBOX="$ROOT/bin/fm-dot-mailbox.sh"
TMP_ROOT=$(fm_test_tmproot fm-dot-mailbox)

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
  out=$("$MAILBOX" bogus 2>&1)
  rc=$?
  expect_code 1 "$rc" "unknown command exits non-zero"
  assert_contains "$out" "unknown command 'bogus'" "unknown command reports error"
  pass "fm-dot-mailbox: unknown command exits non-zero"
}

test_mailbox_crud_and_idempotency() {
  local out rc msg_id
  export FM_HOME="$TMP_ROOT"

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
  local srv_port rcv_port srv_pid rcv_pid srv_db log_dir out res_file

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
  "$MAILBOX" --db "$srv_db" serve --allow-local-callbacks --host 127.0.0.1 --port "$srv_port" >"$log_dir/srv.log" 2>&1 &
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

  srv_port=$(get_free_port)
  srv_db="$TMP_ROOT/mcp_security.sqlite3"
  log_dir="$TMP_ROOT/mcp_sec_logs"
  mkdir -p "$log_dir"

  # Start mailbox MCP server in default strict security mode
  "$MAILBOX" --db "$srv_db" serve --host 127.0.0.1 --port "$srv_port" >"$log_dir/srv.log" 2>&1 &
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

python3 - "$ROOT" "$TMP_ROOT" <<'PY' || fail "mailbox regression cases failed"
import base64
import concurrent.futures
import datetime
import http.client
import http.server
import importlib.util
import json
import os
from pathlib import Path
import socket
import sqlite3
import ssl
import subprocess
import sys
import threading
import time
import unittest
from unittest.mock import patch

root, temporary = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("mailbox", root / "bin/fm-dot-mailbox.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
cli = ["bash", str(root / "bin/fm-dot-mailbox.sh")]
secret1 = "whsec_" + base64.b64encode(b"a" * 32).decode()
secret2 = "whsec_" + base64.b64encode(b"b" * 32).decode()
secret3 = "whsec_" + base64.b64encode(b"c" * 32).decode()


class Receiver(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.send_response(200 if self.server.ready else 503)
        self.end_headers()
        self.wfile.write(b"ready")

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        payload = json.loads(body)
        record = {"payload": payload, "body": body, "headers": dict(self.headers)}
        with self.server.guard:
            self.server.received.append(record)
            status = self.server.verification_status if payload.get("type") == "verification" else self.server.event_status
        self.send_response(status)
        self.end_headers()
        if payload.get("type") == "verification":
            self.wfile.write(json.dumps({"challenge": payload["challenge"]}).encode())


class MailboxRegressionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Receiver)
        cls.server.received = []
        cls.server.guard = threading.Lock()
        cls.server.event_status = 200
        cls.server.verification_status = 200
        cls.server.ready = True
        cls.receiver_thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.receiver_thread.start()
        cls.url = f"http://127.0.0.1:{cls.server.server_port}/callback"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.receiver_thread.join()

    def setUp(self):
        self.directory = temporary / self._testMethodName
        self.directory.mkdir(mode=0o700)
        self.box = m.Mailbox(str(self.directory / "mailbox.db"), allow_local_callbacks=True)
        self.addCleanup(self.box.conn.close)
        with self.server.guard:
            self.server.received.clear()
            self.server.event_status = 200
            self.server.verification_status = 200
            self.server.ready = True

    def subscribe(self, **overrides):
        params = {"name": "message.created", "arguments": {"queue": "work"},
                  "delivery": {"mode": "webhook", "url": self.url, "secret": secret1}}
        params.update(overrides)
        response = m.MCPDispatcher(self.box).dispatch({"jsonrpc": "2.0", "id": 1, "method": "events/subscribe", "params": params})
        self.assertNotIn("error", response)
        return response["result"]

    def events(self):
        with self.server.guard:
            return [record for record in self.server.received if "eventId" in record["payload"]]

    def test_activity_history_replay_and_reported_children(self):
        parent, home = self.directory / "parent", self.directory / "mate"
        (parent / "state").mkdir(parents=True)
        (parent / "data").mkdir()
        charter = self.directory / "charter.md"
        charter.write_text("Idle until routed work arrives. Report activity through the mailbox.\n")
        env = {**os.environ, "FM_HOME": str(parent), "FM_ROOT_OVERRIDE": str(parent)}
        for key in ("FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE"):
            env.pop(key, None)
        def run(script, *args):
            return subprocess.run(["bash", str(root / "bin" / script), *map(str, args)], env=env,
                capture_output=True, text=True, check=True, timeout=30).stdout
        run("fm-dot-secondmate.sh", "register", "dot-test", self.box.db_path, home, "work",
            "http://127.0.0.1:1/health", "http://127.0.0.1:1/readyz", "Cloud tests", charter)
        run("fm-send.sh", "dot-test", "Subject: activity-note test\nRun a read-only cloud proof")
        message = self.box.get_messages(queue="work")["messages"][0]
        def note(event_id, kind="milestone", observed_at="2026-01-01T00:00:00Z", **extra):
            payload = {"schema": "fm.activity-note.v1", "event_id": event_id, "kind": kind,
                "observed_at": observed_at, "summary": "visible corpus checked", **extra}
            if kind != "pickup":
                payload.update(task_id="native-thread", turn_id="native-turn")
            return "activity-note: " + json.dumps(payload)
        def reply(text):
            return self.box.reply_message(message["id"], text, message["correlation_id"])
        retained = []
        def snapshot():
            return json.loads(run("fm-dot-secondmate.sh", "snapshot", "dot-test", *retained))
        first = reply(note("pickup-1", "pickup"))
        self.assertEqual(reply(note("pickup-1", "pickup"))["revision"], first["revision"])
        with self.assertRaises(ValueError):
            reply(note("pickup-1", "pickup", summary="conflicting retry"))
        reply(note("created-1", "task-created"))
        reply(note("progress-1"))
        reply(note("progress-2"))  # Same text is still a distinct observation.
        self.box.publish_mate_replies()
        status = parent / "state/dot-test.status"
        self.assertEqual(len(status.read_text().splitlines()), 1)
        history = json.loads(run("fm-dot-secondmate.sh", "history", "dot-test", "--limit", "2"))
        self.assertEqual(len(history["events"]), 2)
        page = json.loads(run("fm-dot-secondmate.sh", "history", "dot-test", "--cursor", history["next_cursor"]))
        self.assertEqual(len(page["events"]), 2)
        child = snapshot()["children"][0]
        retained.extend(("--child", child["id"]))
        self.assertFalse(child["terminal"])
        self.assertEqual(child["current_state"], "unknown")
        self.assertTrue(child["display_required"])
        fleet = json.loads(run("fm-fleet-snapshot.sh", "--json"))
        mate = next(row for row in fleet["secondmate_current"]["records"] if row["id"] == "dot-test")
        self.assertEqual(mate["counts"]["active_children"], 1)
        self.assertEqual(mate["active_children"][0]["provenance"], "dot-reported")
        self.assertEqual(mate["active_children"][0]["state"], "unknown")
        self.assertEqual(mate["active_children"][0]["reported_state"], "working")
        self.assertIn("current unknown", mate["active_children"][0]["doing"])
        done = note("done-1", "done", "2026-01-01T00:02:00Z", summary="proof result returned", task_title="rust-brep visible proof")
        reply(done)
        self.assertTrue(snapshot()["children"][0]["display_required"])
        # A temporarily broken binding preserves the terminal result and keeps its tab owed.
        meta = parent / "state/dot-test.meta"
        original = meta.read_text()
        meta.write_text(original.replace("transport=dot-mcp", "transport=unavailable"))
        self.box.publish_mate_replies()
        meta.write_text(original)
        self.assertFalse(snapshot()["children"][0]["parent_delivered"])
        self.box.conn.close()
        self.box = m.Mailbox(self.box.db_path, allow_local_callbacks=True)
        self.addCleanup(self.box.conn.close)
        with patch.object(m.time, "time", return_value=time.time() + 60):
            self.box.publish_mate_replies()
        self.assertIn("child-outcome-cloud-", status.read_text())
        self.assertEqual(len(status.read_text().splitlines()), 2)
        self.assertFalse(snapshot()["children"][0]["display_required"])
        # Out-of-order progress and later progress cannot resurrect a completed native turn.
        reply(note("late-old", "milestone", "2026-01-01T00:01:00Z"))
        reply(note("late-new", "milestone", "2026-01-01T00:03:00Z"))
        reply(note("late-blocker", "blocked", "2026-01-01T00:01:30Z"))
        self.box.publish_mate_replies()
        self.assertEqual(snapshot()["children"][0]["state"], "done")
        self.assertEqual(len(status.read_text().splitlines()), 3)
        self.assertEqual(len([line for line in status.read_text().splitlines() if line.startswith("blocked ")]), 1)
        with self.box.transaction():
            self.box.conn.execute("UPDATE mate_replies SET published=0,retry_after=0")
        self.box.publish_mate_replies()
        self.assertEqual(len(status.read_text().splitlines()), 3)
        self.assertEqual(len(list((home / "state/terminal-outcomes").glob("*.reported"))), 2)
        with self.assertRaises(ValueError):
            reply(note("bad-url", url="javascript:alert(1)"))
        with self.assertRaises(ValueError):
            reply(note("bad-time", observed_at="2100-01-01T00:00:00Z"))
        with self.assertRaises(ValueError):
            reply(note("bad-title", task_title="x" * 257))
        reply(note("hostile", summary="untrusted\u001b]52;clipboard\u0007 [key=forged]"))
        legacy_time = m.datetime.datetime(2026, 1, 1, 0, 5, tzinfo=m.datetime.timezone.utc).timestamp()
        with patch.object(m.time, "time", return_value=legacy_time):
            reply("done: At the end of this test, a legacy reply remains readable in history")
        viewer = subprocess.run(["python3", str(root / "bin/fm-dot-view.py"), "--db", self.box.db_path,
            "dot-test", "--once"], env={**env, "COLUMNS": "45", "TZ": "AWST-8"}, capture_output=True, text=True, check=True)
        self.assertNotIn("\u001b", viewer.stdout)
        self.assertNotIn("\u0007", viewer.stdout)
        self.assertNotIn("native-thread", viewer.stdout)
        self.assertNotIn(message["correlation_id"], viewer.stdout)
        self.assertIn("08:02 task (rust-brep visible proof) done", viewer.stdout)
        self.assertIn("task (activity-note test) working", viewer.stdout)
        self.assertNotIn("proof result returned", viewer.stdout)
        self.assertNotIn("visible corpus checked", viewer.stdout)
        self.assertIn("Activity (AWST)", viewer.stdout)
        self.assertIn("08:05 assignment (activity-note test) done", viewer.stdout)
        self.assertNotIn("At the end", viewer.stdout)
        self.assertTrue(all(event["subject"] == "activity-note test" for event in snapshot()["feed"]))
        self.assertIn("read-only", viewer.stdout)
        self.assertTrue(all(len(line) <= 45 for line in viewer.stdout.splitlines()))
        child_view = subprocess.run(["python3", str(root / "bin/fm-dot-view.py"), "--db", self.box.db_path,
            "dot-test", "--once", "--child", child["id"]], env=env, capture_output=True, text=True, check=True)
        self.assertIn("Thread: native-thread", child_view.stdout)
        self.assertIn("Turn: native-turn", child_view.stdout)
        long_title = "Run the corrected visible corpus proof for both shipped variants in the assigned cloud environment " * 2
        run("fm-send.sh", "dot-test", long_title)
        long_assignment = self.box.get_messages(queue="work")["messages"][-1]
        self.box.reply_message(long_assignment["id"], "done: fixture result", long_assignment["correlation_id"])
        self.box.reply_message(long_assignment["id"], note("long-title", "task-created", task_title=long_title), long_assignment["correlation_id"])
        wide = subprocess.run(["python3", str(root / "bin/fm-dot-view.py"), "--db", self.box.db_path,
            "dot-test", "--once"], env={**env, "COLUMNS": "240"}, capture_output=True, text=True, check=True)
        entries = [line for line in wide.stdout.splitlines() if " (Run the corrected" in line]
        self.assertEqual(len(entries), 2)
        for line in entries:
            description = line.split(" (", 1)[1].rsplit(") ", 1)[0]
            self.assertLessEqual(len(description), 40)
            self.assertTrue(description.endswith("..."))
            self.assertRegex(line, r"\) (done|started)$")

    def test_native_task_child_survives_turn_changes(self):
        parent, home = self.directory / "parent", self.directory / "mate"
        (parent / "state").mkdir(parents=True)
        (parent / "data").mkdir()
        charter = self.directory / "charter.md"
        charter.write_text("Idle until routed work arrives. Report through the mailbox.\n")
        env = {**os.environ, "FM_HOME": str(parent), "FM_ROOT_OVERRIDE": str(parent)}
        for key in ("FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE"):
            env.pop(key, None)

        def run(script, *args):
            return subprocess.run(["bash", str(root / "bin" / script), *map(str, args)], env=env,
                capture_output=True, text=True, check=True, timeout=30).stdout

        run("fm-dot-secondmate.sh", "register", "dot-test", self.box.db_path, home, "work",
            "http://127.0.0.1:1/health", "http://127.0.0.1:1/readyz", "Cloud tests", charter)
        run("fm-send.sh", "dot-test", "Subject: task identity proof")
        message = self.box.get_messages(queue="work")["messages"][0]

        def reply(event_id, task_id, turn_id, kind, minute):
            note = {"schema": "fm.activity-note.v1", "event_id": event_id, "kind": kind,
                "observed_at": f"2026-01-01T00:{minute:02d}:00Z", "summary": event_id,
                "task_id": task_id, "turn_id": turn_id, "task_title": turn_id}
            text = "activity-note: " + json.dumps(note)
            result = self.box.reply_message(message["id"], text, message["correlation_id"])
            self.assertEqual(self.box.reply_message(message["id"], text, message["correlation_id"])["revision"], result["revision"])

        def children():
            snapshot = json.loads(run("fm-dot-secondmate.sh", "snapshot", "dot-test", "--child", first["id"]))
            self.assertEqual(len(snapshot["children"]), 2)
            return {child["task_id"]: child for child in snapshot["children"]}

        reply("created-A", "native-task", "turn-A", "task-created", 0)
        first = json.loads(run("fm-dot-secondmate.sh", "snapshot", "dot-test"))["children"][0]
        reply("other-created", "other-task", "other-turn", "task-created", 0)
        reply("reconciled-B", "native-task", "turn-B", "milestone", 2)
        current = children()["native-task"]
        self.assertEqual(current["id"], first["id"])
        self.assertEqual(current["turn_id"], "turn-B")
        self.assertFalse(current["terminal"])
        reply("old-blocker-A", "native-task", "turn-A", "blocked", 1)
        self.box.publish_mate_replies()
        status = parent / "state/dot-test.status"
        self.assertEqual(len(status.read_text().splitlines()), 1)
        self.assertIn("old-blocker-A", status.read_text())

        self.box.conn.close()
        self.box = m.Mailbox(self.box.db_path, allow_local_callbacks=True)
        self.addCleanup(self.box.conn.close)
        self.assertEqual(children()["native-task"]["id"], first["id"])
        viewer = subprocess.run(["python3", str(root / "bin/fm-dot-view.py"), "--db", self.box.db_path,
            "dot-test", "--once", "--child", first["id"]], env=env, capture_output=True, text=True, check=True)
        self.assertIn("Turn: turn-B", viewer.stdout)
        self.assertIn("task (turn-A) started", viewer.stdout)
        self.assertIn("task (turn-B) working", viewer.stdout)
        self.assertNotIn("other-turn", viewer.stdout)

        run("fm-send.sh", "dot-test", "Subject: follow up on the same task")
        message = self.box.get_messages(queue="work")["messages"][-1]
        reply("finished-B", "native-task", "turn-B", "done", 3)
        self.assertTrue(children()["native-task"]["display_required"])
        self.box.publish_mate_replies()
        self.assertFalse(children()["native-task"]["display_required"])
        self.assertEqual(len(status.read_text().splitlines()), 2)
        reply("late-finished-A", "native-task", "turn-A", "done", 1)
        reply("late-progress-A", "native-task", "turn-A", "milestone", 4)
        reply("late-progress-B", "native-task", "turn-B", "milestone", 5)
        self.box.publish_mate_replies()
        self.assertEqual(children()["native-task"]["turn_id"], "turn-B")
        self.assertEqual(children()["native-task"]["state"], "done")
        self.assertEqual(len(status.read_text().splitlines()), 3)
        self.assertIn("late-finished-A", status.read_text())

        reply("continued-C", "native-task", "turn-C", "task-created", 6)
        current = children()["native-task"]
        self.assertEqual(current["id"], first["id"])
        self.assertEqual(current["turn_id"], "turn-C")
        self.assertTrue(current["display_required"])
        reply("failed-C", "native-task", "turn-C", "failed", 7)
        self.box.publish_mate_replies()
        current = children()["native-task"]
        self.assertEqual(current["state"], "failed")
        self.assertFalse(current["display_required"])
        self.assertTrue(children()["other-task"]["display_required"])
        self.assertEqual(len(status.read_text().splitlines()), 4)
        self.assertTrue(all("child " + first["id"] in line for line in status.read_text().splitlines()))
        history = json.loads(run("fm-dot-secondmate.sh", "history", "dot-test"))["events"]
        self.assertEqual(len(history), 10)
        self.assertEqual({event["activity"]["turn_id"] for event in history}, {"turn-A", "turn-B", "turn-C", "other-turn"})
        self.assertTrue(all(event["activity"]["schema"] == "fm.activity-note.v1" for event in history))

    def test_outcomes_survive_later_observations_and_restart(self):
        parent, home = self.directory / "parent", self.directory / "mate"
        (parent / "state").mkdir(parents=True)
        (parent / "data").mkdir()
        charter = self.directory / "charter.md"
        charter.write_text("Idle until routed work arrives. Report through the mailbox.\n")
        env = {**os.environ, "FM_HOME": str(parent), "FM_ROOT_OVERRIDE": str(parent)}
        for key in ("FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE"):
            env.pop(key, None)

        def run(script, *args):
            return subprocess.run(["bash", str(root / "bin" / script), *map(str, args)], env=env,
                capture_output=True, text=True, check=True, timeout=30).stdout

        run("fm-dot-secondmate.sh", "register", "dot-test", self.box.db_path, home, "work",
            "http://127.0.0.1:1/health", "http://127.0.0.1:1/readyz", "Cloud tests", charter)
        run("fm-send.sh", "dot-test", "Subject: pending turn outcome proof")
        message = self.box.get_messages(queue="work")["messages"][0]
        meta = parent / "state/dot-test.meta"
        original = meta.read_text()
        status = parent / "state/dot-test.status"

        def activity(event_id, turn_id, kind, minute):
            return "activity-note: " + json.dumps({"schema": "fm.activity-note.v1", "event_id": event_id,
                "kind": kind, "observed_at": f"2026-01-01T00:{minute:02d}:00Z", "summary": event_id,
                "task_id": "native-task", "turn_id": turn_id})

        delivered_count = 0
        for index, kind in enumerate(("done", "failed", "blocked", "needs-decision")):
            with self.subTest(kind=kind):
                text = activity("outcome-" + kind, f"turn-{index}", kind, index * 3 + 1)
                result = self.box.reply_message(message["id"], text, message["correlation_id"])
                outcome_revisions = [result["revision"]]
                meta.write_text(original.replace("transport=dot-mcp", "transport=unavailable"))
                self.box.publish_mate_replies()
                self.assertNotIn("outcome-" + kind, status.read_text() if status.exists() else "")
                if kind in ("done", "failed"):
                    later = activity("later-" + kind, f"turn-{index}", "failed" if kind == "done" else "done", index * 3 + 2)
                    outcome_revisions.append(self.box.reply_message(message["id"], later, message["correlation_id"])["revision"])
                    current_turn = f"next-turn-{index}"
                    followup = activity("next-" + kind, current_turn, "task-created", index * 3 + 3)
                else:
                    current_turn = f"turn-{index}"
                    followup = activity("next-" + kind, current_turn, "milestone", index * 3 + 2)
                self.box.reply_message(message["id"], followup, message["correlation_id"])
                self.box.conn.close()
                self.box = m.Mailbox(self.box.db_path, allow_local_callbacks=True)
                self.addCleanup(self.box.conn.close)
                meta.write_text(original)
                history = json.loads(run("fm-dot-secondmate.sh", "history", "dot-test"))["events"]
                publications = {event["revision"]: event["published"] for event in history}
                self.assertTrue(all(not publications[revision] for revision in outcome_revisions))
                with patch.object(m.time, "time", return_value=time.time() + 60):
                    self.box.publish_mate_replies()
                self.assertIn("outcome-" + kind, status.read_text())
                if kind in ("done", "failed"):
                    self.assertIn("later-" + kind, status.read_text())
                delivered_count += len(outcome_revisions)
                self.assertEqual(len(status.read_text().splitlines()), delivered_count)
                history = json.loads(run("fm-dot-secondmate.sh", "history", "dot-test"))["events"]
                publications = {event["revision"]: event["published"] for event in history}
                self.assertTrue(all(publications[revision] for revision in outcome_revisions))
                snapshot = json.loads(run("fm-dot-secondmate.sh", "snapshot", "dot-test"))
                self.assertEqual(len(snapshot["children"]), 1)
                self.assertEqual(snapshot["children"][0]["turn_id"], current_turn)
                self.assertTrue(snapshot["children"][0]["display_required"])
                self.assertEqual(self.box.reply_message(message["id"], text, message["correlation_id"])["revision"], result["revision"])
                self.box.publish_mate_replies()
                self.assertEqual(len(status.read_text().splitlines()), delivered_count)
        with self.box.transaction():
            self.box.conn.execute("UPDATE mate_replies SET published=0,retry_after=0")
        self.box.publish_mate_replies()
        self.assertEqual(len(status.read_text().splitlines()), delivered_count)
        history = json.loads(run("fm-dot-secondmate.sh", "history", "dot-test"))["events"]
        self.assertTrue(all(event["published"] for event in history))
        self.assertEqual(len(list((home / "state/terminal-outcomes").glob("*.reported"))), 6)

    def routed_dot(self, health_urls=None):
        parent, home = self.directory / "parent", self.directory / "mate"
        (parent / "state").mkdir(parents=True)
        (parent / "data").mkdir()
        charter = self.directory / "charter.md"
        charter.write_text("Idle until routed work arrives. Report through the mailbox.\n")
        env = {**os.environ, "FM_HOME": str(parent), "FM_ROOT_OVERRIDE": str(parent)}
        for key in ("FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE"):
            env.pop(key, None)
        def run(script, *args):
            result = subprocess.run(["bash", str(root / "bin" / script), *map(str, args)], env=env,
                capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            return result.stdout
        urls = health_urls or ("http://127.0.0.1:1/health", "http://127.0.0.1:1/readyz")
        run("fm-dot-secondmate.sh", "register", "dot-test", self.box.db_path, home, "work", *urls, "Cloud tests", charter)
        run("fm-send.sh", "dot-test", "Subject: fixture assignment")
        return parent, home, env, run, self.box.get_messages(queue="work")["messages"][0]

    def test_completed_history_does_not_truncate_current_inventory(self):
        parent, home, env, run, message = self.routed_dot()
        for index in range(101):
            note = {"schema": "fm.activity-note.v1", "event_id": f"completed-{index}", "kind": "done",
                "observed_at": "2026-01-01T00:00:00Z", "summary": "durable historical result",
                "task_id": f"historical-task-{index}", "turn_id": "turn"}
            self.box.reply_message(message["id"], "activity-note: " + json.dumps(note), message["correlation_id"])
            if index == 0:
                first = json.loads(run("fm-dot-secondmate.sh", "snapshot", "dot-test"))["children"][0]["id"]
        with self.box.transaction():
            self.box.conn.execute("UPDATE mate_replies SET published=1")
        for event, kind in (("pending-result", "done"), ("current-task", "task-created")):
            note.update(event_id=event, task_id=event, kind=kind)
            self.box.reply_message(message["id"], "activity-note: " + json.dumps(note), message["correlation_id"])
        snapshot = json.loads(run("fm-dot-secondmate.sh", "snapshot", "dot-test"))
        self.assertFalse(snapshot["children_truncated"])
        self.assertEqual({child["task_id"] for child in snapshot["children"]}, {"pending-result", "current-task"})
        retained = json.loads(run("fm-dot-secondmate.sh", "snapshot", "dot-test", "--child", first))
        self.assertFalse(retained["children_truncated"])
        retired = next(child for child in retained["children"] if child["id"] == first)
        self.assertTrue(retired["terminal"] and retired["parent_delivered"])
        self.assertFalse(retired["display_required"])
        events, cursor = [], 0
        while True:
            page = json.loads(run("fm-dot-secondmate.sh", "history", "dot-test", "--cursor", cursor))
            events.extend(page["events"])
            if not page["events"]:
                break
            cursor = page["next_cursor"]
        self.assertEqual(len(events), 103)
        self.assertEqual(events[0]["activity"]["summary"], "durable historical result")

    def test_fire_and_forget_subject_uses_the_routed_assignment(self):
        parent, home, env, run, message = self.routed_dot()
        run("fm-send.sh", "dot-test", "--fire-and-forget", "0123456789abcdef", "Subject: Actual proof label")
        assignment = self.box.get_messages(queue="work")["messages"][-1]
        self.assertIn("delivery=0123456789abcdef", assignment["content"])
        self.box.reply_message(assignment["id"], "working: reply wording is unrelated", assignment["correlation_id"])
        note = {"schema": "fm.activity-note.v1", "event_id": "subject-created", "kind": "task-created",
            "observed_at": m.now_iso(), "summary": "different cloud reply", "task_id": "subject-task", "turn_id": "turn"}
        self.box.reply_message(assignment["id"], "activity-note: " + json.dumps(note), assignment["correlation_id"])
        snapshot = json.loads(run("fm-dot-secondmate.sh", "snapshot", "dot-test"))
        for child in (None, snapshot["children"][0]["id"]):
            viewer = subprocess.run(["python3", str(root / "bin/fm-dot-view.py"), "--db", self.box.db_path,
                "dot-test", "--once", *(["--child", child] if child else [])], env=env, capture_output=True, text=True, check=True)
            self.assertIn("(Actual proof label)", viewer.stdout)
            self.assertNotIn("delivery=", viewer.stdout)
            self.assertNotIn("reply wording", viewer.stdout)

    def test_only_explicit_blocker_clearances_resolve_original_parent_keys(self):
        parent, home, env, run, message = self.routed_dot()
        def reply(text):
            return self.box.reply_message(message["id"], text, message["correlation_id"])
        plain = reply("blocked: missing build tool")
        note = {"schema": "fm.activity-note.v1", "event_id": "child-blocker", "kind": "blocked",
            "observed_at": m.now_iso(), "summary": "cloud setup blocked", "task_id": "blocked-task", "turn_id": "turn"}
        text = "activity-note: " + json.dumps(note)
        typed = reply(text)
        self.assertEqual(reply(text)["blocker_key"], typed["blocker_key"])
        self.box.publish_mate_replies()
        status = parent / "state/dot-test.status"
        def open_keys():
            output = subprocess.run(["bash", "-c", '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2" secondmate',
                "_", str(root), str(status)], env=env, capture_output=True, text=True, check=True).stdout
            return {line.split("\t")[0] for line in output.splitlines()}
        reply("working: continuing other work")
        reply("done: another part completed")
        self.box.publish_mate_replies()
        self.assertEqual(open_keys(), {plain["blocker_key"], typed["blocker_key"]})
        run("fm-send.sh", "dot-test", "Subject: separate owner decision")
        question = self.box.get_messages(queue="work")["messages"][-1]
        self.box.reply_message(question["id"], "needs-decision: choose an account", question["correlation_id"])
        self.box.publish_mate_replies()
        question_key = "dot-" + question["id"]
        for outcome in (plain, typed):
            reply(f"resolved: [key={outcome['blocker_key']}] setup repaired")
            self.box.publish_mate_replies()
        self.assertEqual(open_keys(), {question_key})
        with self.assertRaises(ValueError):
            self.box.reply_message(question["id"], f"resolved: [key={question_key}] guessed answer", question["correlation_id"])
        with self.assertRaises(ValueError):
            reply("resolved: [key=unrelated-owner-key] pretend repair")
        count = len(status.read_text().splitlines())
        reply(f"resolved: [key={typed['blocker_key']}] setup repaired")
        self.box.publish_mate_replies()
        self.assertEqual(len(status.read_text().splitlines()), count)
        meta = parent / "state/dot-test.meta"
        original = meta.read_text()
        reply("blocked: another transient setup issue")
        meta.write_text(original.replace("transport=dot-mcp", "transport=unavailable"))
        self.box.publish_mate_replies()
        reply(f"resolved: [key={plain['blocker_key']}] transient issue cleared")
        meta.write_text(original)
        self.box.publish_mate_replies()
        self.assertNotIn("transient issue cleared", status.read_text())
        with patch.object(m.time, "time", return_value=time.time() + 60):
            self.box.publish_mate_replies()
        self.assertEqual(open_keys(), {question_key})
        self.assertIn("transient issue cleared", status.read_text())
        original_clearance = f"resolved: [key={plain['blocker_key']}] transient issue cleared"
        accepted = reply(original_clearance)
        reply("needs-decision: owner must choose the next account")
        self.box.publish_mate_replies()
        self.assertEqual(open_keys(), {question_key, plain["blocker_key"]})
        count = len(status.read_text().splitlines())
        self.assertEqual(reply(original_clearance)["revision"], accepted["revision"])
        self.assertEqual(self.box.get_message_by_id(message["id"])["reply"], "needs-decision: owner must choose the next account")
        self.box.publish_mate_replies()
        self.assertEqual(len(status.read_text().splitlines()), count)
        self.assertEqual(open_keys(), {question_key, plain["blocker_key"]})
        with self.assertRaises(ValueError):
            reply(f"resolved: [key={plain['blocker_key']}] a new unauthorized answer")

    def test_bridge_readiness_does_not_refresh_old_work_observations(self):
        class Health(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                self.wfile.write(b'ready' if self.path == '/readyz' else b'{"status":"ok","name":"fm-dot-mailbox"}')
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Health)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        urls = (f"http://127.0.0.1:{server.server_port}/health", f"http://127.0.0.1:{server.server_port}/readyz")
        parent, home, env, run, message = self.routed_dot(urls)
        self.subscribe()
        with patch.object(m.time, "time", return_value=time.time() - 1000):
            self.box.reply_message(message["id"], "working: old plain report", message["correlation_id"])
        self.box.publish_mate_replies()
        self.assertTrue(json.loads(run("fm-dot-secondmate.sh", "snapshot", "dot-test"))["ready"])
        self.assertIn("state: unknown", run("fm-crew-state.sh", "dot-test"))
        fleet = json.loads(run("fm-fleet-snapshot.sh", "--json"))
        self.assertEqual(next(row for row in fleet["secondmate_current"]["records"] if row["id"] == "dot-test")["current"]["state"], "unknown")
        self.box.reply_message(message["id"], "working: fresh plain report", message["correlation_id"])
        self.box.publish_mate_replies()
        self.assertIn("state: working", run("fm-crew-state.sh", "dot-test"))
        for event, kind in (("old-pickup", "pickup"), ("old-created", "task-created")):
            note = {"schema": "fm.activity-note.v1", "event_id": event, "kind": kind,
                "observed_at": "2026-01-01T00:00:00Z", "summary": "old observation"}
            if kind != "pickup":
                note.update(task_id="old-task", turn_id="turn")
            self.box.reply_message(message["id"], "activity-note: " + json.dumps(note), message["correlation_id"])
        self.box.publish_mate_replies()
        self.assertIn("state: unknown", run("fm-crew-state.sh", "dot-test"))
        snapshot = json.loads(run("fm-dot-secondmate.sh", "snapshot", "dot-test"))
        self.assertTrue(snapshot["ready"])
        self.assertEqual(snapshot["children"][0]["current_state"], "unknown")
        note.update(event_id="fresh-milestone", kind="milestone", observed_at=m.now_iso())
        self.box.reply_message(message["id"], "activity-note: " + json.dumps(note), message["correlation_id"])
        self.box.publish_mate_replies()
        self.assertIn("state: working", run("fm-crew-state.sh", "dot-test"))

    def test_dot_secondmate_routes_replies_and_reports_health_without_a_pane(self):
        parent, home = self.directory / "parent", self.directory / "mate"
        (parent / "state").mkdir(parents=True)
        (parent / "data").mkdir()
        charter = self.directory / "charter.md"
        charter.write_text("You are a second mate. Stay idle until routed work arrives. Reply through the mailbox, never directly to the user.\n")
        fakebin = self.directory / "fakebin"
        fakebin.mkdir()
        terminal_log = self.directory / "terminal.log"
        for tool in ("tmux", "herdr", "orca", "zellij", "cmux"):
            path = fakebin / tool
            path.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$DOT_TERMINAL_LOG"\nexit 1\n')
            path.chmod(0o755)
        env = {**os.environ, "FM_HOME": str(parent), "FM_ROOT_OVERRIDE": str(parent),
               "PATH": str(fakebin) + os.pathsep + os.environ["PATH"], "DOT_TERMINAL_LOG": str(terminal_log)}
        for key in ("FM_STATE_OVERRIDE", "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE"):
            env.pop(key, None)

        def run(script, *args, success=True, extra_env=None):
            result = subprocess.run(["bash", str(root / "bin" / script), *map(str, args)],
                                    env={**env, **(extra_env or {})}, capture_output=True, text=True, timeout=30)
            if success:
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            return result

        probe = socket.socket()
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]
        probe.close()
        process = subprocess.Popen(cli + ["--db", self.box.db_path, "serve", "--port", str(port), "--allow-local-callbacks"],
                                   env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        def rpc(method, params=None):
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
            try:
                connection.request("POST", "/mcp", json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}}),
                                   headers={"Content-Type": "application/json"})
                return json.loads(connection.getresponse().read())
            finally:
                connection.close()
        try:
            for _ in range(100):
                try:
                    if "result" in rpc("server/discover"):
                        break
                except OSError:
                    time.sleep(.05)
            else:
                self.fail("dot mailbox did not start")
            health_url = f"http://127.0.0.1:{port}/health"
            tunnel_url = f"http://127.0.0.1:{self.server.server_port}/readyz"
            registration = ("register", "dot-test", self.box.db_path, home, "work", health_url, tunnel_url, "Read-only cloud proof", charter)
            run("fm-dot-secondmate.sh", *registration)
            run("fm-dot-secondmate.sh", *registration)
            run("fm-dot-secondmate.sh", "validate", "dot-test")
            self.assertEqual((parent / "data/secondmates.md").read_text().count("- dot-test -"), 1)
            self.assertFalse((home / "AGENTS.md").exists())
            self.assertIn("subscription=missing", run("fm-dot-secondmate.sh", "health", "dot-test", success=False).stdout)
            result = rpc("events/subscribe", {"name": "message.created", "arguments": {"queue": "work"},
                         "delivery": {"mode": "webhook", "url": self.url, "secret": secret1}})
            self.assertIn("result", result)
            run("fm-send.sh", "fm-dot-test", "Return the read-only proof nonce")
            messages = json.loads(rpc("tools/call", {"name": "get_messages", "arguments": {"queue": "work"}})["result"]["content"][0]["text"])["messages"]
            self.assertEqual(len(messages), 1)
            assignment = messages[0]
            corr = assignment["correlation_id"]
            self.assertRegex(corr, r"^[a-f0-9]{16}$")
            self.assertIn("corr=" + corr, assignment["content"])
            self.assertIn("Stay idle until routed work arrives", assignment["content"])
            self.assertIn("Return the read-only proof nonce", assignment["content"])
            run("fm-send.sh", "dot-test", "Return the read-only proof nonce", extra_env={"FM_PENDING_REPLY_EXISTING_CORR": corr})
            self.assertEqual(len(self.box.get_messages(queue="work")["messages"]), 1)
            invalid = rpc("tools/call", {"name": "reply", "arguments": {"message_id": assignment["id"], "reply": "done: proof"}})
            self.assertIn("error", invalid)
            reply = {"name": "reply", "arguments": {"message_id": assignment["id"], "correlation_id": corr, "reply": "done: proof nonce returned"}}
            self.assertIn("result", rpc("tools/call", reply))
            status = parent / "state/dot-test.status"
            for _ in range(100):
                if status.exists() and "proof nonce returned" in status.read_text():
                    break
                time.sleep(.1)
            else:
                self.fail("dot reply did not reach the parent status channel")
            self.assertIn("corr=" + corr, status.read_text())
            self.assertIn("result", rpc("tools/call", reply))
            self.box.publish_mate_replies()
            self.assertEqual(len(status.read_text().splitlines()), 1)
            self.assertEqual(next((parent / "data/dot-test/mailbox-replies").glob("*.md")).read_text(), "done: proof nonce returned\n")
            health = run("fm-dot-secondmate.sh", "health", "dot-test").stdout
            self.assertIn("mailbox=ready tunnel=ready subscription=active", health)
            self.assertNotIn("last-contact=never", health)
            self.assertIn("dot-online=unknown", health)
            probe_script = '. "$1/bin/fm-secondmate-liveness-lib.sh"; fm_secondmate_liveness_probe "$2" dot-test poll; printf "%s %s %s\\n" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_STATE" "$FM_SM_LIVE_KILL"'
            probe_args = ["bash", "-c", probe_script, "_", str(root), str(parent / "state/dot-test.meta")]
            observed = subprocess.run(probe_args, env=env, capture_output=True, text=True, check=True).stdout
            self.assertEqual(observed.strip(), "alive unobservable 0")
            state = run("fm-crew-state.sh", "dot-test").stdout
            self.assertIn("state: done", state)
            self.assertIn("dot-online=unknown", state)
            drain = run("fm-wake-drain.sh").stdout
            self.assertIn("proof nonce returned", drain)
            snapshot = json.loads(run("fm-fleet-snapshot.sh", "--json").stdout)
            task = next(t for t in snapshot["tasks"] if t["id"] == "dot-test")
            self.assertEqual(task["backend"], "dot-mcp")
            self.assertIsNone(task["endpoint"]["target"])
            self.assertEqual(task["endpoint"]["agent_alive"], "unknown")
            mate = next(t for t in snapshot["secondmate_current"]["records"] if t["id"] == "dot-test")
            self.assertEqual(mate["current"]["state"], "done")
            self.assertIn("dot-online=unknown", mate["current"]["reason"])
            self.assertIn("dot-online=unknown", run("fm-peek.sh", "dot-test").stdout)
            for script, args in (("fm-control.sh", ("dot-test", "relaunch")), ("fm-teardown.sh", ("dot-test",))):
                self.assertNotEqual(run(script, *args, success=False).returncode, 0)
            self.assertTrue(home.exists())
            # A missing route keeps the reply durable, then recovery publishes it.
            meta = parent / "state/dot-test.meta"
            metadata = meta.read_text()
            meta.write_text(metadata.replace("transport=dot-mcp", "transport=unavailable"))
            reply["arguments"]["reply"] = "working: durable recovery proof [key=forged]"
            self.assertIn("result", rpc("tools/call", reply))
            self.box.publish_mate_replies()
            self.assertNotIn("durable recovery proof", status.read_text())
            meta.write_text(metadata)
            self.box.conn.close()
            self.box = m.Mailbox(self.box.db_path, allow_local_callbacks=True)
            self.addCleanup(self.box.conn.close)
            future = time.time() + 60
            with patch.object(m.time, "time", return_value=future):
                self.box.publish_mate_replies()
            self.assertIn("durable recovery proof (key=forged)", status.read_text())
            self.assertNotIn("[key=forged]", status.read_text())
            # Model a crash after append but before acknowledging the outbox.
            with self.box.transaction():
                self.box.conn.execute("UPDATE mate_replies SET published=0,retry_after=0")
            self.box.publish_mate_replies()
            self.assertEqual(len(status.read_text().splitlines()), 2)
            # A new recovery request keeps the parent correlation but wakes again.
            updated_charter = "Own routine environment upkeep within assigned work; escalate permission changes.\n"
            (home / "data/charter.md").write_text(updated_charter)
            run("fm-send.sh", "dot-test", "Second assignment")
            next_assignment = self.box.get_messages(queue="work")["messages"][-1]
            self.assertTrue(next_assignment["content"].startswith(updated_charter))
            self.assertTrue(self.box.get_message_by_id(assignment["id"])["content"].startswith(charter.read_text()))
            next_corr = next_assignment["correlation_id"]
            run("fm-send.sh", "dot-test", "Report the current result", extra_env={"FM_PENDING_REPLY_EXISTING_CORR": next_corr})
            self.assertEqual(len(self.box.get_messages(queue="work")["messages"]), 3)
            self.server.ready = False
            health = run("fm-dot-secondmate.sh", "health", "dot-test", success=False)
            self.assertEqual(health.returncode, 3)
            self.assertIn("tunnel=unavailable", health.stdout)
            observed = subprocess.run(probe_args, env=env, capture_output=True, text=True, check=True).stdout
            self.assertEqual(observed.strip(), "skipped unobservable 0")
            self.assertIn("state: unknown", run("fm-crew-state.sh", "dot-test").stdout)
            self.assertNotEqual(run("fm-send.sh", "dot-test", "--key", "Enter", success=False).returncode, 0)
            # Dot-origin notes must not create a new assignment event for itself.
            note = json.loads(rpc("tools/call", {"name": "submit_message", "arguments": {"queue": "work", "content": "outbound note"}})["result"]["content"][0]["text"])
            self.box.deliver_pending_events()
            self.assertEqual(note["origin"], "dot")
            self.assertEqual(self.box.get_message_by_id(note["id"])["delivery"], {"pending": 0, "delivered": 0, "undelivered": 0})
            if terminal_log.exists():
                self.assertNotIn("capture-pane", terminal_log.read_text())
                self.assertNotIn("send-keys", terminal_log.read_text())
        finally:
            process.terminate()
            process.communicate(timeout=10)

    def test_verification_cache_is_scoped_bounded_and_persistent(self):
        clock = [datetime.datetime.now(datetime.timezone.utc)]

        class ControlledDateTime(datetime.datetime):
            @classmethod
            def now(cls, tz=None):
                return clock[0] if tz else clock[0].replace(tzinfo=None)

        delivery = {"mode": "webhook", "url": self.url, "secret": secret1}

        def subscribe(queue="one", principal="worker-a", destination=None):
            return self.box.subscribe_event("message.created", {"queue": queue}, destination or delivery, principal=principal)

        def challenges():
            with self.server.guard:
                return sum(record["payload"].get("type") == "verification" for record in self.server.received)

        with patch.object(m.datetime, "datetime", ControlledDateTime):
            original_time = clock[0]
            original = subscribe()
            self.assertEqual(challenges(), 1)
            verified_at = self.box.conn.execute("SELECT verified_at FROM subscriptions WHERE id=?", (original["id"],)).fetchone()[0]
            clock[0] = original_time + datetime.timedelta(seconds=200)
            self.assertEqual(subscribe(destination={**delivery, "secret": secret2})["id"], original["id"])
            clock[0] = original_time + datetime.timedelta(seconds=299)
            subscribe(queue="two")
            self.box.conn.close()
            self.box = m.Mailbox(str(self.directory / "mailbox.db"), allow_local_callbacks=True)
            self.addCleanup(self.box.conn.close)
            subscribe()
            self.assertEqual(challenges(), 1)
            self.assertEqual({row[0] for row in self.box.conn.execute("SELECT verified_at FROM subscriptions")}, {verified_at})
            clock[0] = original_time + datetime.timedelta(seconds=301)
            subscribe()
            self.assertEqual(challenges(), 2)
            subscribe(principal="worker-b")
            self.assertEqual(challenges(), 3)
            subscribe(destination={**delivery, "url": self.url + "/other"})
            self.assertEqual(challenges(), 4)
            self.box.allow_local_callbacks = False
            with self.assertRaises(ValueError):
                subscribe()
            self.assertEqual(challenges(), 4)
            self.box.allow_local_callbacks = True
            clock[0] = original_time + datetime.timedelta(seconds=602)
            self.server.verification_status = 503
            with self.assertRaises(ValueError):
                subscribe()
            self.assertEqual(challenges(), 5)
            self.server.verification_status = 200
            subscribe()
            subscribe()
            self.assertEqual(challenges(), 6)

    def test_verification_cache_upgrades_legacy_subscription_storage(self):
        path = self.directory / "legacy.db"
        path.touch(mode=0o600)
        sub_id = m.derive_subscription_id("worker-a", self.url, "message.created", {"queue": "one"})
        with sqlite3.connect(path) as connection:
            connection.execute("""CREATE TABLE subscriptions (
                id TEXT PRIMARY KEY, event_name TEXT NOT NULL, filter_queue TEXT,
                callback_url TEXT NOT NULL, signing_secret TEXT NOT NULL,
                refresh_before TEXT NOT NULL, created_at TEXT NOT NULL, verified_at TEXT NOT NULL)""")
            connection.execute("INSERT INTO subscriptions VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                               (sub_id, "message.created", "one", self.url, secret1,
                                "2099-01-01T00:00:00.000000Z", m.now_iso(), m.now_iso()))
        connection.close()
        box = m.Mailbox(str(path), allow_local_callbacks=True)
        self.addCleanup(box.conn.close)
        delivery = {"mode": "webhook", "url": self.url, "secret": secret1}
        for _ in range(2):
            result = box.subscribe_event("message.created", {"queue": "one"}, delivery, principal="worker-a")
            self.assertEqual(result["id"], sub_id)
        with self.server.guard:
            self.assertEqual(len(self.server.received), 1)

    def test_cli_ignores_inherited_serve_configuration(self):
        env = {**os.environ, "FM_DOT_MCP_HOST": "203.0.113.1", "FM_DOT_MCP_PORT": "", "FM_DOT_MCP_ALLOW_LOCAL_CALLBACK": "1"}
        for engine in (cli, [sys.executable, str(root / "bin/fm-dot-mailbox.py")]):
            def run(*arguments):
                return subprocess.run(engine + list(arguments), env=env, capture_output=True, text=True, check=True).stdout

            self.assertIn("serve", run("--help"))
            message = json.loads(run("--db", self.box.db_path, "submit", "environment nonce"))
            self.assertEqual(json.loads(run("--db", self.box.db_path, "get", message["id"]))["content"], "environment nonce")
            self.assertTrue(json.loads(run("--db", self.box.db_path, "list"))["messages"])
            self.assertEqual(json.loads(run("--db", self.box.db_path, "reply", message["id"], "result"))["status"], "ok")
            self.assertIn("pending=0", run("--db", self.box.db_path, "status"))

    def test_serve_flags_and_private_request_logging(self):
        env = {**os.environ, "FM_DOT_MCP_HOST": "203.0.113.1", "FM_DOT_MCP_PORT": "", "FM_DOT_MCP_ALLOW_LOCAL_CALLBACK": "1"}
        for allow_local in (False, True):
            probe = socket.socket()
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
            probe.close()
            command = cli + ["--db", self.box.db_path, "serve", "--port", str(port)]
            if allow_local:
                command.append("--allow-local-callbacks")
            process = subprocess.Popen(command, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)

            def request(method, path, body=None):
                connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
                try:
                    connection.request(method, path, body=body if isinstance(body, bytes) else json.dumps(body),
                                       headers={"Content-Type": "application/json", "Authorization": "Bearer private-header"})
                    response = connection.getresponse()
                    return response.status, response.read()
                finally:
                    connection.close()

            try:
                for _ in range(100):
                    try:
                        if request("GET", "/health")[0] == 200:
                            break
                    except OSError:
                        pass
                    if process.poll() is not None:
                        self.fail(process.stderr.read())
                    time.sleep(.05)
                else:
                    self.fail("serve did not start with explicit flags")
                _, body = request("POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "method": "events/subscribe", "params": {
                    "name": "message.created", "arguments": {"queue": "work"},
                    "delivery": {"mode": "webhook", "url": self.url, "secret": secret1}}})
                result = json.loads(body)
                if allow_local:
                    self.assertIn("result", result)
                else:
                    self.assertEqual(result["error"]["code"], -32015)
                    with self.server.guard:
                        self.assertEqual(self.server.received, [])
                sensitive = "private-body-and-request-id"
                calls = [
                    ("server/discover", {}, None), ("events/list", {}, None),
                    ("tools/call", {"name": "submit_message", "arguments": {"content": sensitive}}, None),
                    ("tools/call", {"name": "reply", "arguments": {"message_id": sensitive, "reply": sensitive}}, -32603),
                    ("tools/call", {"name": sensitive}, -32601),
                    (sensitive, {}, -32601),
                    ("notifications/initialized", {}, None),
                ]
                for method, params, error in calls:
                    _, body = request("POST", "/mcp", {"jsonrpc": "2.0", "id": sensitive,
                                                         "method": method, "params": params})
                    if body:
                        self.assertEqual(json.loads(body).get("error", {}).get("code"), error)
                self.assertEqual(json.loads(request("POST", "/mcp", b"private-broken-json")[1])["error"]["code"], -32700)
                self.assertEqual(request("POST", "/private-url", {})[0], 404)
                self.assertEqual(request("POST", "/mcp", b"x" * (256 * 1024 + 1))[0], 413)
            finally:
                process.terminate()
                _, logs = process.communicate(timeout=10)
            for hidden in (secret1, self.url, sensitive, "private-header", "private-broken-json", "private-url"):
                self.assertNotIn(hidden, logs)
            records = [json.loads(line) for line in logs.splitlines() if line.startswith("{")]
            expected = [("events/subscribe", 200, "ok" if allow_local else "error", None if allow_local else -32015)]
            expected += [(method if method != sensitive else "unknown", 204 if method == "notifications/initialized" else 200,
                          "error" if error else "notification" if method == "notifications/initialized" else "ok", error)
                         for method, _, error in calls]
            expected += [("unknown", 200, "error", -32700), ("unknown", 404, "error", None), ("unknown", 413, "error", None)]
            self.assertEqual([(r["method"], r["http_status"], r["result"], r["error_code"]) for r in records], expected)
            self.assertEqual([r["tool"] for r in records if "tool" in r], ["submit_message", "reply", "unknown"])
            for record in records:
                self.assertEqual(record["event"], "mcp_request")
                self.assertTrue(record["timestamp"].endswith("Z"))

    def test_database_selection_ignores_inherited_override(self):
        env = os.environ.copy()
        home = self.directory / "owning-home"
        ignored_db = self.directory / "ignored.db"
        env["FM_HOME"] = str(home)
        env["FM_DOT_MAILBOX_DB"] = str(ignored_db)

        def run(*arguments):
            return subprocess.run(cli + list(arguments), env=env, capture_output=True, text=True, check=True).stdout

        message = json.loads(run("submit", "--idempotency-key", "home-key", "owning-home nonce"))
        self.assertTrue((home / "data/dot-mcp/mailbox.sqlite3").is_file())
        self.assertEqual(json.loads(run("get", message["id"]))["content"], "owning-home nonce")
        self.assertEqual(json.loads(run("list"))["messages"][0]["id"], message["id"])
        self.assertEqual(json.loads(run("reply", message["id"], "home result"))["status"], "ok")
        self.assertIn("total=1 pending=0 replied=1", run("status"))
        explicit_db = self.directory / "explicit.db"
        self.assertIn("total=0", run("--db", str(explicit_db), "status"))
        self.assertTrue(explicit_db.is_file())
        env.pop("FM_HOME")
        result = subprocess.run(cli + ["status"], env=env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Set --db or FM_HOME", result.stderr)
        self.assertFalse(ignored_db.exists())

    def test_delivery_acknowledgment_does_not_read_response_body(self):
        release = threading.Event()

        class AcknowledgingReceiver(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                payload = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                verification = payload.get("type") == "verification"
                if verification and not self.server.oversized_verification:
                    body = json.dumps({"challenge": payload["challenge"]}).encode()
                else:
                    body = b"x" * (256 * 1024 + 1)
                self.send_response(200 if verification else 202)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.flush()
                if not verification and self.server.stall:
                    release.wait(5)
                    return
                try:
                    self.wfile.write(body)
                except OSError:
                    pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), AcknowledgingReceiver)
        server.stall, server.oversized_verification = True, False
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        delivery = {"mode": "webhook", "url": f"http://127.0.0.1:{server.server_port}/callback", "secret": secret1}
        try:
            self.subscribe(delivery=delivery)
            for stalled in (True, False):
                server.stall = stalled
                message = self.box.submit_message("acknowledged", "work")
                with patch.object(m, "CALLBACK_TIMEOUT_SEC", .25):
                    self.box.deliver_pending_events()
                self.assertFalse(release.is_set())
                self.assertEqual(self.box.get_message_by_id(message["id"])["delivery"]["delivered"], 1)
                row = self.box.conn.execute("SELECT state, attempts FROM pending_events WHERE message_id=?", (message["id"],)).fetchone()
                self.assertEqual(tuple(row), ("delivered", 1))
            server.oversized_verification = True
            with self.assertRaisesRegex(ValueError, "response exceeds 256 KiB"):
                self.box.subscribe_event("message.created", {"queue": "other"}, {**delivery, "url": delivery["url"] + "/fresh"})
        finally:
            release.set()
            server.shutdown()
            server.server_close()
            thread.join()

    def test_delivery_state_has_one_owner(self):
        tables = {row[0] for row in self.box.conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        self.assertNotIn("delivery_attempts", tables)
        self.assertIn("pending_events", tables)
        self.subscribe()
        self.server.event_status = 503
        message = self.box.submit_message("record failed attempt", "work")
        self.box.deliver_pending_events()
        row = self.box.conn.execute("SELECT state, attempts, last_error FROM pending_events WHERE message_id=?", (message["id"],)).fetchone()
        self.assertEqual(tuple(row), ("pending", 1, "HTTP 503"))

    def test_connection_candidates_share_one_budget(self):
        clock = [1000.0]
        attempts, closed = [], []

        class UnreachableSocket:
            def __init__(self, *args):
                self.timeout = None

            def settimeout(self, timeout):
                self.timeout = timeout

            def connect(self, address):
                attempts.append((address, self.timeout))
                clock[0] += self.timeout
                raise TimeoutError("unreachable candidate")

            def close(self):
                closed.append(self)

        addresses = [
            (socket.AF_INET6, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", ("2606:4700::1111", 443, 0, 0)),
            (socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", ("93.184.216.34", 443)),
            (socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", ("93.184.216.35", 443)),
        ]
        with patch.object(m.socket, "getaddrinfo", return_value=addresses), patch.object(m.socket, "socket", UnreachableSocket):
            with patch.object(m.time, "monotonic", side_effect=lambda: clock[0]), patch.object(m, "CALLBACK_TIMEOUT_SEC", .3):
                with self.assertRaises(TimeoutError):
                    m.post_callback("https://callback.test/event", b"{}", {})
        self.assertEqual([address for address, _ in attempts], [entry[4] for entry in addresses])
        self.assertEqual(len(closed), len(addresses))
        self.assertLessEqual(clock[0] - 1000, .300001)

    def test_atomic_submission_restart_and_stable_retries(self):
        self.subscribe()
        self.server.event_status = 503
        original = self.box.submit_message("nonce", "work", idempotency_key="one")
        duplicate = self.box.submit_message("nonce", "work", idempotency_key="one")
        self.assertEqual(original["id"], duplicate["id"])
        self.assertEqual(original["delivery"], {"pending": 1, "delivered": 0, "undelivered": 0})
        self.assertEqual(self.events(), [])
        self.box.conn.close()
        self.box = m.Mailbox(str(self.directory / "mailbox.db"), allow_local_callbacks=True)
        self.addCleanup(self.box.conn.close)
        self.box.deliver_pending_events()
        event = self.events()[0]
        self.assertNotIn("correlation_id", event["payload"]["data"])
        catalog = m.MCPDispatcher(self.box).dispatch({"jsonrpc": "2.0", "id": 2, "method": "events/list"})
        schema = catalog["result"]["events"][0]["payloadSchema"]
        data = event["payload"]["data"]
        self.assertTrue(set(schema["required"]) <= data.keys())
        self.assertTrue(data.keys() <= schema["properties"].keys())
        self.assertTrue(all(isinstance(value, str) for value in data.values()))
        self.assertEqual(self.box.get_status()["events"]["pending"], 1)
        self.server.event_status = 200
        time.sleep(1.05)
        self.box.deliver_pending_events()
        repeated = self.events()[1]
        self.assertEqual(event["body"], repeated["body"])
        self.assertEqual(event["headers"]["webhook-id"], repeated["headers"]["webhook-id"])
        self.assertNotEqual(event["headers"]["webhook-timestamp"], repeated["headers"]["webhook-timestamp"])
        self.assertEqual(self.box.get_message_by_id(original["id"])["delivery"]["delivered"], 1)
        self.box.deliver_pending_events()
        self.assertEqual(len(self.events()), 2)
        self.assertEqual(self.box.get_messages(queue="work")["messages"][0]["id"], original["id"])

    def test_bounded_retries_and_terminal_responses(self):
        self.subscribe()
        self.server.event_status = 503
        message = self.box.submit_message("permanent failure", "work")
        self.box.deliver_pending_events()
        self.box.deliver_pending_events()
        self.assertEqual(len(self.events()), 1)
        for delay in (1.05, 2.05, 4.05):
            time.sleep(delay)
            self.box.deliver_pending_events()
        self.box.deliver_pending_events()
        self.assertEqual(len(self.events()), 4)
        self.assertEqual(self.box.get_message_by_id(message["id"])["delivery"]["undelivered"], 1)
        self.assertEqual(len({event["payload"]["eventId"] for event in self.events()}), 1)
        for status in (410, 413):
            self.server.event_status = status
            message = self.box.submit_message(f"terminal-{status}", "work")
            self.box.deliver_pending_events()
            self.box.deliver_pending_events()
            self.assertEqual(self.box.get_message_by_id(message["id"])["delivery"]["undelivered"], 1)
        self.assertEqual(len(self.events()), 6)

    def test_transaction_rolls_back_message_with_failed_event(self):
        self.subscribe()
        with self.box.conn:
            self.box.conn.execute("CREATE TRIGGER reject_event BEFORE INSERT ON pending_events BEGIN SELECT RAISE(ABORT, 'event failure'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            self.box.submit_message("must roll back", "work", idempotency_key="rollback")
        self.assertEqual(self.box.get_messages()["messages"], [])
        with self.box.conn:
            self.box.conn.execute("DROP TRIGGER reject_event")
        self.box.submit_message("must commit", "work", idempotency_key="rollback")
        self.assertEqual(self.box.get_status()["events"]["pending"], 1)

    def test_concurrent_threads_and_connections(self):
        self.subscribe()
        second = m.Mailbox(str(self.directory / "mailbox.db"), allow_local_callbacks=True)
        self.addCleanup(second.conn.close)
        with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
            futures = [pool.submit((self.box if i % 2 else second).submit_message,
                                   "one assignment", "work", "correlation", "one-key") for i in range(64)]
            ids = {future.result()["id"] for future in futures}
        self.assertEqual(len(ids), 1)
        self.assertEqual(self.box.get_status()["total_messages"], 1)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(lambda box: box.deliver_pending_events(), (self.box, second)))
        self.assertEqual(len(self.events()), 1)
        self.assertEqual(self.box.get_status()["events"]["delivered"], 1)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda i: (self.box if i % 2 else second).reply_message(next(iter(ids)), "result"), range(24)))
        self.assertEqual(self.box.get_message_by_id(next(iter(ids)))["reply"], "result")
        commands = [cli + ["--db", str(self.directory / "process.db"), "submit", "--idempotency-key", "same", "parallel"] for _ in range(12)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            processes = list(pool.map(lambda command: subprocess.run(command, capture_output=True, text=True), commands))
        self.assertTrue(all(process.returncode == 0 for process in processes), [p.stderr for p in processes])
        self.assertEqual(len({json.loads(p.stdout)["id"] for p in processes}), 1)

    def test_shared_byte_limits_pagination_and_exact_replies(self):
        for field in ("queue", "correlation_id", "idempotency_key"):
            with self.assertRaises(ValueError):
                self.box.submit_message("valid", **{field: "é" * 129})
        dispatcher = m.MCPDispatcher(self.box)
        response = dispatcher.dispatch({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
            "name": "submit_message", "arguments": {"content": "x" * (16 * 1024 + 1)}}})
        self.assertIn("error", response)
        oversized = subprocess.run(cli + ["--db", self.box.db_path, "submit", "-"], input=b"x" * (300 * 1024), capture_output=True)
        self.assertNotEqual(oversized.returncode, 0)
        self.assertEqual(self.box.get_status()["total_messages"], 0)
        self.subscribe()
        ids = []
        for i in range(4):
            message = self.box.submit_message("\x00" * (16 * 1024), "work", "shared")
            ids.append(message["id"])
            self.box.reply_message(message["id"], "\x00" * (16 * 1024), "shared")
        with self.assertRaises(ValueError):
            self.box.reply_message("shared", "must not target a correlation")
        with self.assertRaises(ValueError):
            self.box.reply_message(ids[0], "wrong correlation", "different")
        with self.assertRaises(ValueError):
            self.box.reply_message(ids[0], "x" * (16 * 1024 + 1))
        oversized = subprocess.run(cli + ["--db", self.box.db_path, "reply", ids[0], "-"], input=b"x" * (300 * 1024), capture_output=True)
        self.assertNotEqual(oversized.returncode, 0)
        seen = []
        cursor = None
        while True:
            response = dispatcher.dispatch({"jsonrpc": "2.0", "id": "request", "method": "tools/call", "params": {
                "name": "get_messages", "arguments": {"cursor": cursor, "limit": 50}}})
            self.assertLessEqual(len(m.json_bytes(response)), 256 * 1024)
            page = json.loads(response["result"]["content"][0]["text"])
            if not page["messages"]:
                break
            seen += [msg["id"] for msg in page["messages"]]
            cursor = page["next_cursor"]
        self.assertEqual(seen, ids)
        self.box.deliver_pending_events()
        for event in self.events():
            self.assertLessEqual(len(event["body"]), 256 * 1024)
            self.assertEqual(event["payload"]["data"]["correlation_id"], "shared")

    def test_owner_only_storage_and_no_home_fallback(self):
        self.assertEqual((self.directory / "mailbox.db").stat().st_mode & 0o777, 0o600)
        for suffix in ("-wal", "-shm"):
            self.assertEqual(Path(self.box.db_path + suffix).stat().st_mode & 0o777, 0o600)
        for kind in ("directory", "database", "sidecar", "symlink"):
            storage = self.directory / kind
            storage.mkdir(mode=0o700)
            path = storage / "unsafe.db"
            if kind == "directory":
                storage.chmod(0o755)
            elif kind == "database":
                path.touch(mode=0o644)
            elif kind == "sidecar":
                path.touch(mode=0o600)
                Path(str(path) + "-wal").touch(mode=0o644)
            else:
                path.symlink_to(self.box.db_path)
            process = subprocess.run(cli + ["--db", str(path), "status"], capture_output=True, text=True)
            self.assertNotEqual(process.returncode, 0)
            self.assertIn("Unsafe mailbox storage", process.stderr)
        env = {key: value for key, value in os.environ.items() if key not in ("FM_HOME", "FM_DOT_MAILBOX_DB")}
        process = subprocess.run(cli + ["status"], env=env, capture_output=True, text=True)
        self.assertNotEqual(process.returncode, 0)
        self.assertIn("Set --db", process.stderr)
        env["FM_HOME"] = str(self.directory / "home")
        process = subprocess.run(cli + ["status"], env=env, capture_output=True, text=True)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertTrue((Path(env["FM_HOME"]) / "data/dot-mcp/mailbox.sqlite3").is_file())

    def test_lifetime_rotation_and_expiration(self):
        started = datetime.datetime.now(datetime.timezone.utc)
        subscription = self.subscribe(ttlMs=1000)
        expiration = datetime.datetime.fromisoformat(subscription["refreshBefore"].replace("Z", "+00:00"))
        self.assertGreater((expiration - started).total_seconds(), 0)
        self.assertLess((expiration - started).total_seconds(), 1.5)
        for secret in (secret2, secret3):
            renewed = self.subscribe(ttlMs=2000, delivery={"mode": "webhook", "url": self.url, "secret": secret})
            self.assertEqual(renewed["id"], subscription["id"])
        self.box.conn.close()
        self.box = m.Mailbox(str(self.directory / "mailbox.db"), allow_local_callbacks=True)
        self.addCleanup(self.box.conn.close)
        self.box.submit_message("rotated", "work")
        self.box.deliver_pending_events()
        event = self.events()[0]
        for secret in (secret1, secret2, secret3):
            expected = m.sign_standard_webhook(base64.b64decode(secret[6:]), event["headers"]["webhook-id"],
                                              event["headers"]["webhook-timestamp"], event["body"])
            self.assertIn(expected, event["headers"]["webhook-signature"].split())
        future = time.time() + 301
        renewed = self.subscribe(ttlMs=86400 * 1000 * 100)
        expiration = datetime.datetime.fromisoformat(renewed["refreshBefore"].replace("Z", "+00:00"))
        self.assertLessEqual((expiration - datetime.datetime.now(datetime.timezone.utc)).total_seconds(), 86400)
        with patch.object(m.time, "time", return_value=future):
            self.box.submit_message("after rotation", "work")
            self.box.deliver_pending_events()
        self.assertEqual(len(self.events()[-1]["headers"]["webhook-signature"].split()), 1)
        self.subscribe(ttlMs=1)
        self.box.submit_message("expired", "work")
        time.sleep(.02)
        self.box.deliver_pending_events()
        self.assertEqual(len(self.events()), 2)
        self.box.submit_message("no active subscriber", "work")
        self.assertEqual(self.box.get_messages()["messages"][-1]["delivery"]["pending"], 0)

    def test_unsubscribe_stops_queued_delivery(self):
        self.subscribe()
        message = self.box.submit_message("queued", "work")
        for _ in range(2):
            self.box.unsubscribe_event("message.created", {"queue": "work"}, {"url": self.url})
        self.box.deliver_pending_events()
        self.assertEqual(self.events(), [])
        self.assertEqual(self.box.get_message_by_id(message["id"])["delivery"]["undelivered"], 1)

    def test_http_startup_recovery_routes_and_round_trip(self):
        self.subscribe()
        nonce = "hello-" + os.urandom(12).hex()
        message = self.box.submit_message(nonce, "work", nonce, nonce)
        self.box.conn.close()
        port_socket = socket.socket()
        port_socket.bind(("127.0.0.1", 0))
        port = port_socket.getsockname()[1]
        port_socket.close()
        process = subprocess.Popen(cli + ["--db", str(self.directory / "mailbox.db"), "serve",
                                          "--allow-local-callbacks", "--port", str(port)],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)

        def request(method, path, body=None):
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            try:
                connection.request(method, path, body=json.dumps(body) if body is not None else None,
                                   headers={"Content-Type": "application/json"})
                response = connection.getresponse()
                data = response.read()
                return response.status, data
            finally:
                connection.close()

        try:
            for _ in range(100):
                try:
                    if request("GET", "/health")[0] == 200 and self.events():
                        break
                except OSError:
                    pass
                if process.poll() is not None:
                    self.fail(process.stderr.read())
                time.sleep(.05)
            else:
                self.fail("foreground server did not recover the pending event")
            for method, path in (("GET", "/"), ("GET", "/mcp"), ("POST", "/")):
                self.assertEqual(request(method, path, {})[0], 404)
            for method in ("server/discover", "initialize"):
                status, data = request("POST", "/mcp", {"jsonrpc": "2.0", "id": 1, "method": method})
                self.assertEqual(status, 200)
                self.assertIn("result", json.loads(data))
            status, _ = request("POST", "/mcp", {"jsonrpc": "2.0", "method": "notifications/initialized"})
            self.assertEqual(status, 204)
            _, data = request("POST", "/mcp", {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {
                "name": "get_messages", "arguments": {"queue": "work"}}})
            assignments = json.loads(json.loads(data)["result"]["content"][0]["text"])["messages"]
            self.assertEqual(assignments[0]["content"], nonce)
            self.assertEqual(assignments[0]["id"], message["id"])
            _, data = request("POST", "/mcp", {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {
                "name": "reply", "arguments": {"message_id": message["id"], "correlation_id": nonce, "reply": nonce}}})
            self.assertFalse(json.loads(data)["result"]["isError"])
            result = subprocess.run(cli + ["--db", str(self.directory / "mailbox.db"), "get", message["id"]],
                                    capture_output=True, text=True, check=True)
            self.assertEqual(json.loads(result.stdout)["reply"], nonce)
            self.assertEqual(len(self.events()), 1)
        finally:
            process.terminate()
            process.communicate(timeout=10)

    def test_tls_destination_pinning_rebinding_and_no_redirects(self):
        certificate, key = self.directory / "cert.pem", self.directory / "key.pem"
        command = ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                   "-subj", "/CN=callback.test", "-addext", "subjectAltName=DNS:callback.test",
                   "-keyout", str(key), "-out", str(certificate)]
        subprocess.run(command, check=True, capture_output=True)
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Receiver)
        server.received, server.guard, server.event_status, server.verification_status = [], threading.Lock(), 200, 200
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certificate, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        client_context = ssl.create_default_context(cafile=str(certificate))
        real_socket = socket.socket
        connections = []

        class PinnedSocket(real_socket):
            def connect(self, address):
                connections.append(address)
                if address[0] == "2606:4700::1111":
                    raise ConnectionRefusedError("unavailable IPv6 candidate")
                return super().connect(("127.0.0.1", address[1]))

        public = [(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", ("93.184.216.34", server.server_port))]
        candidates = [(socket.AF_INET6, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", ("2606:4700::1111", server.server_port, 0, 0))] + public
        private = [(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", ("127.0.0.1", server.server_port))]
        self.box.allow_local_callbacks = False
        destination = {"mode": "webhook", "url": f"https://callback.test:{server.server_port}/callback", "secret": secret1}
        try:
            with patch.object(m.socket, "socket", PinnedSocket), patch.object(m.ssl, "create_default_context", return_value=client_context):
                with patch.object(m.socket, "getaddrinfo", side_effect=[candidates, private]) as dns:
                    self.subscribe(delivery=destination)
                    self.assertEqual(dns.call_count, 1)
                    self.box.submit_message("private delivery blocked", "work")
                    self.box.deliver_pending_events()
                    self.assertEqual(dns.call_count, 2)
                    self.assertEqual(len(server.received), 1)
                with patch.object(m.socket, "getaddrinfo", return_value=candidates) as dns:
                    before = len(connections)
                    self.subscribe(delivery=destination)
                    self.assertEqual(len(connections), before)
                    message = self.box.submit_message("second address works", "work")
                    self.box.deliver_pending_events()
                    self.assertEqual(self.box.get_message_by_id(message["id"])["delivery"]["delivered"], 1)
                    self.assertTrue(any(record["payload"].get("data", {}).get("message_id") == message["id"] for record in server.received))
                    self.assertEqual(connections[before:][-1], public[0][4])
                    self.assertGreaterEqual(dns.call_count, 2)
                with patch.object(m.socket, "getaddrinfo", return_value=public):
                    server.event_status = 302
                    status, _ = m.post_callback(destination["url"], b'{"eventId":"redirect"}', {})
                    self.assertEqual(status, 302)
                    with self.assertRaises(ssl.SSLCertVerificationError):
                        m.post_callback(destination["url"].replace("callback.test", "wrong.test"), b'{}', {})
            self.assertTrue(connections)
            self.assertTrue(all(address[0] in ("93.184.216.34", "2606:4700::1111") for address in connections))
            for address in ("100.64.0.1", "10.0.0.1", "127.0.0.1", "169.254.1.1", "::1", "::ffff:100.64.0.1"):
                blocked = [(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", (address, 443))]
                with patch.object(m.socket, "getaddrinfo", return_value=blocked):
                    with self.assertRaises(ValueError):
                        m.post_callback(destination["url"], b'{}', {})
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
