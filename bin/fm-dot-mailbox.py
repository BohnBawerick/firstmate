#!/usr/bin/env python3
# fm-dot-mailbox.py - Persistent private MCP mailbox and MCP 2.0 event bridge.
#
# Usage:
#   fm-dot-mailbox.py submit [--queue <q>] [--correlation-id <id>] [--idempotency-key <key>] <content | ->
#   fm-dot-mailbox.py get <message_id>
#   fm-dot-mailbox.py list [--queue <q>] [--status <pending|replied|all>] [--cursor <c>] [--limit <n>]
#   fm-dot-mailbox.py reply <message_id> <reply_text | -> [--correlation-id <id>]
#   fm-dot-mailbox.py status
#   fm-dot-mailbox.py serve [--host <host>] [--port <port>] [--allow-local-callbacks]
#
# Environment:
#   FM_HOME                       Owning home when no database path is supplied.
#   FM_DOT_MCP_ALLOW_LOCAL_CALLBACK  Allow loopback/http callback URLs (for tests).
#   FM_DOT_MCP_PORT               Default port for serve (default: 8765).
#   FM_DOT_MCP_HOST               Default host for serve (default: 127.0.0.1).
import argparse
import base64
import datetime
import hashlib
import hmac
import http.client
import http.server
import ipaddress
import json
import os
import secrets
import socket
import sqlite3
import ssl
import stat
import threading
from contextlib import contextmanager
import sys
import time
import urllib.parse

PROTOCOL_VERSION = "2026-07-28"
DEFAULT_QUEUE = "default"
MAX_BODY_BYTES = 256 * 1024  # 256 KiB
MAX_TEXT_BYTES = 16 * 1024
MAX_FIELD_BYTES = 256
DEFAULT_SUB_LIFETIME_MS = 24 * 60 * 60 * 1000
MAX_SUB_LIFETIME_MS = DEFAULT_SUB_LIFETIME_MS
SECRET_ROTATION_SEC = 300
MAX_DELIVERY_ATTEMPTS = 4
CALLBACK_TIMEOUT_SEC = 10


def default_db_path():
    """Resolve default database path outside tracked source."""
    fm_home = os.environ.get("FM_HOME")
    if fm_home:
        return os.path.join(fm_home, "data", "dot-mcp", "mailbox.sqlite3")
    raise ValueError("Set --db or FM_HOME")


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def now_unix():
    return int(time.time())


def json_bytes(value):
    return json.dumps(value, ensure_ascii=False).encode("utf-8")


def bounded_json(value):
    result = json_bytes(value)
    if len(result) > MAX_BODY_BYTES:
        raise ValueError("Serialized result exceeds 256 KiB")
    return result


def validate_text(name, value, limit=MAX_FIELD_BYTES, optional=False, allow_empty=False):
    if optional and value is None:
        return
    if not isinstance(value, str) or (not value and not allow_empty):
        raise ValueError(f"{name} must be a {'nonempty ' if not allow_empty else ''}string")
    if len(value.encode("utf-8")) > limit:
        raise ValueError(f"{name} exceeds {limit} UTF-8 bytes")


def tool_result(value, req_id=None):
    return {
        "jsonrpc": "2.0", "id": req_id,
        "result": {"content": [{"type": "text", "text": json_bytes(value).decode("utf-8")}], "isError": False},
    }


def check_private_path(path, directory=False):
    info = os.lstat(path)
    expected_type = stat.S_ISDIR if directory else stat.S_ISREG
    if (not expected_type(info.st_mode) or info.st_uid != os.getuid()
            or info.st_mode & 0o077 or (not directory and info.st_nlink != 1)):
        raise ValueError(f"Unsafe mailbox storage permissions or ownership: {path}")


def init_db(db_path):
    db_path = os.path.abspath(db_path)
    parent = os.path.dirname(db_path)
    os.makedirs(parent, mode=0o700, exist_ok=True)
    check_private_path(parent, directory=True)
    try:
        fd = os.open(db_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    except FileExistsError:
        check_private_path(db_path)
    else:
        os.close(fd)
    for suffix in ("-wal", "-shm", "-journal"):
        if os.path.lexists(db_path + suffix):
            check_private_path(db_path + suffix)
    conn = sqlite3.connect(db_path, timeout=10.0, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout=10000")
    conn.execute("PRAGMA journal_mode=WAL")
    with conn:
        conn.execute("BEGIN IMMEDIATE")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS messages (
                seq INTEGER PRIMARY KEY AUTOINCREMENT,
                id TEXT NOT NULL UNIQUE,
                queue TEXT NOT NULL DEFAULT 'default',
                content TEXT NOT NULL,
                correlation_id TEXT,
                idempotency_key TEXT UNIQUE,
                status TEXT NOT NULL DEFAULT 'pending',
                reply TEXT,
                created_at TEXT NOT NULL,
                updated_at TEXT NOT NULL
            )
        """)
        conn.execute("CREATE INDEX IF NOT EXISTS idx_messages_queue_status ON messages(queue, status)")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS subscriptions (
                id TEXT PRIMARY KEY,
                event_name TEXT NOT NULL,
                filter_queue TEXT,
                callback_url TEXT NOT NULL,
                signing_secret TEXT NOT NULL,
                refresh_before TEXT NOT NULL,
                created_at TEXT NOT NULL,
                verified_at TEXT NOT NULL
            )
        """)
        conn.execute("CREATE INDEX IF NOT EXISTS idx_subscriptions_event ON subscriptions(event_name, filter_queue)")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS retired_signing_keys (
                subscription_id TEXT NOT NULL,
                signing_secret TEXT NOT NULL,
                expires_at REAL NOT NULL,
                PRIMARY KEY (subscription_id, signing_secret)
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS pending_events (
                id TEXT PRIMARY KEY,
                subscription_id TEXT NOT NULL,
                message_id TEXT NOT NULL,
                body TEXT NOT NULL,
                state TEXT NOT NULL DEFAULT 'pending',
                attempts INTEGER NOT NULL DEFAULT 0,
                next_attempt_at REAL NOT NULL DEFAULT 0,
                last_error TEXT
            )
        """)
        conn.execute("CREATE INDEX IF NOT EXISTS idx_events_due ON pending_events(state, next_attempt_at)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_events_message ON pending_events(message_id)")
    return conn


def check_ip_allowed(ip_str, allow_local=False):
    try:
        ip = ipaddress.ip_address(ip_str)
    except ValueError:
        return False, f"Invalid IP address: {ip_str}"
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    if allow_local and ip.is_loopback:
        return True, None
    if not ip.is_global or ip.is_multicast or ip.is_reserved:
        return False, f"Non-public address blocked: {ip_str}"
    return True, None


def post_callback(url, body, headers, allow_local=False, *, read_response=False):
    validate_text("delivery.url", url, 4096)
    if len(body) > MAX_BODY_BYTES:
        raise ValueError("Event payload exceeds 256 KiB")
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in (("https", "http") if allow_local else ("https",)):
        raise ValueError("Destination URL must use HTTPS")
    if not parsed.hostname or parsed.username is not None or parsed.password is not None or parsed.fragment:
        raise ValueError("Destination URL requires a hostname without credentials or fragment")
    hostname = parsed.hostname.encode("idna").decode("ascii")
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    addresses = socket.getaddrinfo(hostname, port, type=socket.SOCK_STREAM, proto=socket.IPPROTO_TCP)
    if not addresses:
        raise ValueError("Destination has no addresses")
    for _, _, _, _, address in addresses:
        ok, error = check_ip_allowed(address[0], allow_local)
        if not ok:
            raise ValueError(error)
    tls_context = ssl.create_default_context() if parsed.scheme == "https" else None
    conn = http.client.HTTPConnection(hostname, port, timeout=CALLBACK_TIMEOUT_SEC)
    deadline = time.monotonic() + CALLBACK_TIMEOUT_SEC
    sock = None
    try:
        for index, (family, kind, proto, _, address) in enumerate(addresses):
            current = time.monotonic()
            remaining = deadline - current
            if remaining <= 0:
                raise TimeoutError("Callback connection budget exhausted")
            candidate_deadline = current + remaining / (len(addresses) - index)
            try:
                sock = socket.socket(family, kind, proto)
                remaining = candidate_deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("Callback connection budget exhausted")
                sock.settimeout(remaining)
                sock.connect(address)
                if parsed.scheme == "https":
                    remaining = candidate_deadline - time.monotonic()
                    if remaining <= 0:
                        raise TimeoutError("Callback connection budget exhausted")
                    sock.settimeout(remaining)
                    sock = tls_context.wrap_socket(sock, server_hostname=hostname)
                conn.sock = sock
                break
            except OSError:
                if sock is not None:
                    sock.close()
                    sock = None
                if index == len(addresses) - 1:
                    raise
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("Callback connection budget exhausted")
        sock.settimeout(remaining)
        target = parsed.path or "/"
        if parsed.query:
            target += "?" + parsed.query
        conn.request("POST", target, body=body, headers=headers)
        with conn.getresponse() as response:
            if not read_response or not 200 <= response.status < 300:
                return response.status, b""
            response_body = response.read(MAX_BODY_BYTES + 1)
            if len(response_body) > MAX_BODY_BYTES:
                raise ValueError("Callback response exceeds 256 KiB")
            return response.status, response_body
    finally:
        conn.close()
        if sock is not None:
            sock.close()


def validate_signing_secret(secret_str):
    if not isinstance(secret_str, str) or not secret_str.startswith("whsec_"):
        return None, "Signing secret must start with whsec_"
    b64_part = secret_str[6:]
    try:
        raw_key = base64.b64decode(b64_part, validate=True)
    except Exception:
        return None, "Signing secret contains invalid base64 encoding"
    if not (24 <= len(raw_key) <= 64):
        return None, f"Signing secret decoded length must be 24-64 bytes (got {len(raw_key)})"
    return raw_key, None


def sign_standard_webhook(raw_key, webhook_id, timestamp_str, payload_bytes):
    to_sign = f"{webhook_id}.{timestamp_str}.".encode("utf-8") + payload_bytes
    sig = hmac.new(raw_key, to_sign, hashlib.sha256).digest()
    return f"v1,{base64.b64encode(sig).decode('utf-8')}"


def derive_subscription_id(principal, callback_url, event_name, arguments):
    norm_args = json.dumps(arguments or {}, sort_keys=True)
    identity = f"{principal}:{callback_url}:{event_name}:{norm_args}".encode("utf-8")
    return f"sub_{hashlib.sha256(identity).hexdigest()[:16]}"


# --- Mailbox Core ---

class Mailbox:
    def __init__(self, db_path, allow_local_callbacks=False):
        self.db_path = db_path
        self.allow_local_callbacks = allow_local_callbacks
        self.lock = threading.RLock()
        self.conn = init_db(db_path)

    @contextmanager
    def transaction(self):
        with self.lock, self.conn:
            self.conn.execute("BEGIN IMMEDIATE")
            yield

    def submit_message(self, content, queue=DEFAULT_QUEUE, correlation_id=None, idempotency_key=None):
        validate_text("content", content, MAX_TEXT_BYTES)
        validate_text("queue", queue)
        validate_text("correlation_id", correlation_id, optional=True)
        validate_text("idempotency_key", idempotency_key, optional=True)
        with self.transaction():
            if idempotency_key is not None:
                row = self.conn.execute("SELECT * FROM messages WHERE idempotency_key = ?", (idempotency_key,)).fetchone()
                if row:
                    return self._row_to_msg(row)
            msg_id = f"msg_{secrets.token_hex(8)}"
            ts = now_iso()
            self.conn.execute(
                """
                INSERT INTO messages (id, queue, content, correlation_id, idempotency_key, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (msg_id, queue, content, correlation_id, idempotency_key, ts, ts),
            )
            msg = self._row_to_msg(self.conn.execute("SELECT * FROM messages WHERE id = ?", (msg_id,)).fetchone())
            body = self._event_body(msg)
            subscriptions = self.conn.execute(
                """SELECT id FROM subscriptions WHERE event_name = 'message.created' AND refresh_before > ?
                   AND (filter_queue IS NULL OR filter_queue = ?)""", (ts, queue),
            ).fetchall()
            for sub in subscriptions:
                event_id = f"evt_{secrets.token_hex(8)}"
                body["eventId"] = event_id
                self.conn.execute(
                    "INSERT INTO pending_events (id, subscription_id, message_id, body) VALUES (?, ?, ?, ?)",
                    (event_id, sub["id"], msg_id, bounded_json(body).decode("utf-8")),
                )
            msg = self._row_to_msg(self.conn.execute("SELECT * FROM messages WHERE id = ?", (msg_id,)).fetchone())
            bounded_json(tool_result(msg))
            return msg

    def get_messages(self, queue=None, status=None, cursor=None, limit=10):
        validate_text("queue", queue, optional=True)
        if status not in (None, "pending", "replied", "all"):
            raise ValueError("Invalid message status")
        limit = max(1, min(int(limit), 50))
        query = "SELECT * FROM messages WHERE 1=1"
        params = []
        if queue is not None:
            query += " AND queue = ?"
            params.append(queue)
        if status and status != "all":
            query += " AND status = ?"
            params.append(status)
        if cursor is not None:
            validate_text("cursor", cursor)
            query += " AND seq > ?"
            params.append(int(cursor))
        query += " ORDER BY seq ASC LIMIT ?"
        params.append(limit)
        result = {"messages": [], "next_cursor": None}
        with self.lock:
            rows = self.conn.execute(query, params).fetchall()
            for row in rows:
                msg = self._row_to_msg(row)
                candidate = {"messages": result["messages"] + [msg], "next_cursor": str(msg["seq"])}
                if len(json_bytes(tool_result(candidate))) > MAX_BODY_BYTES - 4096:
                    if not result["messages"]:
                        raise ValueError("Stored message exceeds the response byte limit")
                    break
                result = candidate
        return result

    def get_message_by_id(self, msg_id):
        validate_text("message_id", msg_id)
        with self.lock:
            row = self.conn.execute("SELECT * FROM messages WHERE id = ?", (msg_id,)).fetchone()
            result = self._row_to_msg(row) if row else None
            bounded_json(tool_result(result))
            return result

    def reply_message(self, msg_id, reply_text, correlation_id=None):
        validate_text("message_id", msg_id)
        validate_text("reply", reply_text, MAX_TEXT_BYTES, allow_empty=True)
        validate_text("correlation_id", correlation_id, optional=True)
        with self.transaction():
            row = self.conn.execute("SELECT * FROM messages WHERE id = ?", (msg_id,)).fetchone()
            if not row:
                raise ValueError(f"Message not found: {msg_id}")
            if correlation_id is not None and correlation_id != row["correlation_id"]:
                raise ValueError("correlation_id does not match the message")
            if row["status"] == "replied" and row["reply"] == reply_text:
                return {"status": "ok", "message_id": row["id"], "idempotent": True}
            self.conn.execute("UPDATE messages SET reply = ?, status = 'replied', updated_at = ? WHERE id = ?", (reply_text, now_iso(), msg_id))
            bounded_json(tool_result(self._row_to_msg(self.conn.execute("SELECT * FROM messages WHERE id = ?", (msg_id,)).fetchone())))
            return {"status": "ok", "message_id": msg_id}

    def get_status(self):
        with self.lock:
            row = self.conn.execute("SELECT COUNT(*), SUM(status='pending'), SUM(status='replied') FROM messages").fetchone()
            active = self.conn.execute("SELECT COUNT(*) FROM subscriptions WHERE refresh_before > ?", (now_iso(),)).fetchone()[0]
            return {
                "database": self.db_path,
                "total_messages": row[0] or 0, "pending_messages": row[1] or 0, "replied_messages": row[2] or 0,
                "active_subscriptions": active, "events": self._event_counts(),
            }

    def _event_counts(self, message_id=None):
        query = "SELECT state, COUNT(*) FROM pending_events"
        params = ()
        if message_id is not None:
            query += " WHERE message_id = ?"
            params = (message_id,)
        counts = {"pending": 0, "delivered": 0, "undelivered": 0}
        counts.update(dict(self.conn.execute(query + " GROUP BY state", params).fetchall()))
        return counts

    def _row_to_msg(self, row):
        msg = dict(row)
        msg["delivery"] = self._event_counts(msg["id"])
        return msg

    def _event_body(self, msg):
        data = {key: msg[key] for key in ("queue", "content", "created_at")}
        data["message_id"] = msg["id"]
        if msg["correlation_id"] is not None:
            data["correlation_id"] = msg["correlation_id"]
        return {"name": "message.created", "timestamp": msg["created_at"], "data": data, "cursor": None}

    def subscribe_event(self, name, arguments, delivery, principal="dot-worker", ttl_ms=DEFAULT_SUB_LIFETIME_MS):
        if name != "message.created":
            raise ValueError(f"Unsupported event: {name}")
        if arguments is None:
            arguments = {}
        if not isinstance(arguments, dict) or set(arguments) - {"queue"}:
            raise ValueError("Event arguments support only queue")
        filter_queue = arguments.get("queue")
        validate_text("queue", filter_queue, optional=True)
        if "queue" in arguments and filter_queue is None:
            raise ValueError("queue must be a string")
        if not isinstance(delivery, dict) or delivery.get("mode") != "webhook":
            raise ValueError("delivery.mode must be 'webhook'")
        if ttl_ms is None:
            ttl_ms = DEFAULT_SUB_LIFETIME_MS
        if type(ttl_ms) is not int or ttl_ms <= 0:
            raise ValueError("ttlMs must be a positive integer or null")
        ttl_ms = min(ttl_ms, MAX_SUB_LIFETIME_MS)
        url = delivery.get("url")
        secret = delivery.get("secret")
        raw_key, error = validate_signing_secret(secret)
        if error:
            raise ValueError(error)
        validate_text("delivery.url", url, 4096)
        sub_id = derive_subscription_id(principal, url, name, arguments)
        challenge = secrets.token_hex(16)
        body = json_bytes({"type": "verification", "challenge": challenge})
        webhook_id = f"msg_verification_{secrets.token_hex(8)}"
        timestamp = str(now_unix())
        headers = {
            "Content-Type": "application/json", "webhook-id": webhook_id, "webhook-timestamp": timestamp,
            "webhook-signature": sign_standard_webhook(raw_key, webhook_id, timestamp, body),
            "X-MCP-Subscription-Id": sub_id,
        }
        try:
            status, response = post_callback(url, body, headers, self.allow_local_callbacks, read_response=True)
            if not 200 <= status < 300:
                raise ValueError(f"Verification challenge returned status {status}")
            returned = json.loads(response).get("challenge")
            if not isinstance(returned, str) or not hmac.compare_digest(returned, challenge):
                raise ValueError("Verification challenge echo mismatch")
        except Exception as error:
            raise ValueError(f"Verification challenge failed: {error}") from error
        refresh_before = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(milliseconds=ttl_ms)).isoformat(timespec="microseconds").replace("+00:00", "Z")
        ts = now_iso()
        with self.transaction():
            old = self.conn.execute("SELECT signing_secret, refresh_before FROM subscriptions WHERE id = ?", (sub_id,)).fetchone()
            if old and old["signing_secret"] != secret and old["refresh_before"] > ts:
                self.conn.execute(
                    """INSERT INTO retired_signing_keys VALUES (?, ?, ?)
                       ON CONFLICT(subscription_id, signing_secret) DO UPDATE SET expires_at=excluded.expires_at""",
                    (sub_id, old["signing_secret"], time.time() + SECRET_ROTATION_SEC),
                )
            self.conn.execute("DELETE FROM retired_signing_keys WHERE expires_at <= ?", (time.time(),))
            self.conn.execute(
                """INSERT INTO subscriptions (id, event_name, filter_queue, callback_url, signing_secret, refresh_before, created_at, verified_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(id) DO UPDATE SET signing_secret=excluded.signing_secret,
                       refresh_before=excluded.refresh_before, verified_at=excluded.verified_at""",
                (sub_id, name, filter_queue, url, secret, refresh_before, ts, ts),
            )
        return {"id": sub_id, "refreshBefore": refresh_before, "cursor": None, "truncated": False}

    def unsubscribe_event(self, name, arguments, delivery, principal="dot-worker"):
        url = (delivery or {}).get("url") if isinstance(delivery, dict) else None
        if not url:
            return {}
        sub_id = derive_subscription_id(principal, url, name, arguments)
        with self.transaction():
            self.conn.execute("DELETE FROM subscriptions WHERE id = ?", (sub_id,))
            self.conn.execute("DELETE FROM retired_signing_keys WHERE subscription_id = ?", (sub_id,))
            self.conn.execute("UPDATE pending_events SET state='undelivered', last_error='Subscription stopped' WHERE subscription_id=? AND state='pending'", (sub_id,))
        return {}

    def deliver_pending_events(self):
        for _ in range(16):
            with self.transaction():
                self.conn.execute(
                    """UPDATE pending_events SET state='undelivered', last_error=COALESCE(last_error, 'Delivery interrupted or subscription expired')
                       WHERE state='pending' AND ((attempts >= ? AND next_attempt_at <= ?) OR NOT EXISTS
                       (SELECT 1 FROM subscriptions WHERE id=subscription_id AND refresh_before > ?))""",
                    (MAX_DELIVERY_ATTEMPTS, time.time(), now_iso()),
                )
                event = self.conn.execute(
                    """SELECT e.*, s.callback_url, s.signing_secret FROM pending_events e
                       JOIN subscriptions s ON s.id=e.subscription_id
                       WHERE e.state='pending' AND e.attempts < ? AND e.next_attempt_at <= ? AND s.refresh_before > ?
                       ORDER BY e.next_attempt_at LIMIT 1""", (MAX_DELIVERY_ATTEMPTS, time.time(), now_iso()),
                ).fetchone()
                if not event:
                    return
                self.conn.execute("UPDATE pending_events SET attempts=attempts+1, next_attempt_at=? WHERE id=?", (time.time() + CALLBACK_TIMEOUT_SEC + 1, event["id"]))
                old_keys = self.conn.execute("SELECT signing_secret FROM retired_signing_keys WHERE subscription_id=? AND expires_at>?", (event["subscription_id"], time.time())).fetchall()
            body = event["body"].encode("utf-8")
            timestamp = str(now_unix())
            signatures = []
            for secret in dict.fromkeys([event["signing_secret"]] + [row[0] for row in old_keys]):
                key, error = validate_signing_secret(secret)
                if error:
                    raise ValueError(error)
                signatures.append(sign_standard_webhook(key, event["id"], timestamp, body))
            headers = {
                "Content-Type": "application/json", "webhook-id": event["id"], "webhook-timestamp": timestamp,
                "webhook-signature": " ".join(signatures), "X-MCP-Subscription-Id": event["subscription_id"],
            }
            status = None
            error = None
            try:
                status, _ = post_callback(event["callback_url"], body, headers, self.allow_local_callbacks)
                if not 200 <= status < 300:
                    error = f"HTTP {status}"
            except Exception as failure:
                error = str(failure)[:512]
            attempts = event["attempts"] + 1
            state = "delivered" if error is None else "undelivered" if status in (410, 413) or attempts >= MAX_DELIVERY_ATTEMPTS else "pending"
            with self.transaction():
                self.conn.execute(
                    "UPDATE pending_events SET state=?, next_attempt_at=?, last_error=? WHERE id=? AND state='pending' AND attempts=?",
                    (state, time.time() + 2 ** (attempts - 1), error, event["id"], attempts),
                )


# --- MCP Protocol Dispatcher ---

class MCPDispatcher:
    def __init__(self, mailbox: Mailbox):
        self.mailbox = mailbox

    def dispatch(self, req: dict) -> dict:
        if not isinstance(req, dict) or req.get("jsonrpc") != "2.0":
            return {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Invalid Request"}}

        req_id = req.get("id")
        method = req.get("method")
        params = req.get("params") or {}
        if not isinstance(params, dict) or (req_id is not None and type(req_id) not in (str, int)):
            return {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Invalid Request"}}
        if len(json_bytes(req_id)) > MAX_FIELD_BYTES:
            return {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "Request ID exceeds byte limit"}}

        try:
            if method == "server/discover":
                return {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "resultType": "complete",
                        "supportedVersions": [PROTOCOL_VERSION],
                        "protocolVersion": PROTOCOL_VERSION,
                        "capabilities": {
                            "tools": {},
                            "events": {},
                        },
                        "serverInfo": {
                            "name": "fm-dot-mailbox",
                            "version": "1.0.0",
                        },
                    },
                }

            elif method == "initialize":
                return {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "protocolVersion": PROTOCOL_VERSION,
                        "capabilities": {
                            "tools": {},
                            "events": {},
                        },
                        "serverInfo": {
                            "name": "fm-dot-mailbox",
                            "version": "1.0.0",
                        },
                    },
                }

            elif method == "notifications/initialized":
                return None

            elif method == "tools/list":
                return {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "tools": [
                            {
                                "name": "submit_message",
                                "description": "Submit a message or work assignment to the mailbox queue.",
                                "inputSchema": {
                                    "type": "object",
                                    "properties": {
                                        "content": {"type": "string", "description": "Message content or work specification."},
                                        "queue": {"type": "string", "description": "Queue name (default 'default')."},
                                        "correlation_id": {"type": "string", "description": "Optional correlation ID."},
                                        "idempotency_key": {"type": "string", "description": "Optional idempotency key to prevent duplicates."},
                                    },
                                    "required": ["content"],
                                    "additionalProperties": False,
                                },
                            },
                            {
                                "name": "get_messages",
                                "description": "Retrieve messages from the mailbox queue.",
                                "inputSchema": {
                                    "type": "object",
                                    "properties": {
                                        "queue": {"type": "string", "description": "Filter by queue name."},
                                        "status": {"type": "string", "enum": ["pending", "replied", "all"], "description": "Filter by status."},
                                        "cursor": {"type": "string", "description": "Pagination cursor."},
                                        "limit": {"type": "integer", "description": "Maximum number of messages (1-50, default 10)."},
                                    },
                                    "additionalProperties": False,
                                },
                            },
                            {
                                "name": "reply",
                                "description": "Reply to a message in the mailbox.",
                                "inputSchema": {
                                    "type": "object",
                                    "properties": {
                                        "message_id": {"type": "string", "description": "Message identifier."},
                                        "reply": {"type": "string", "description": "Reply content or task outcome."},
                                        "correlation_id": {"type": "string", "description": "Optional correlation ID."},
                                    },
                                    "required": ["message_id", "reply"],
                                    "additionalProperties": False,
                                },
                            },
                        ]
                    },
                }

            elif method == "tools/call":
                tool_name = params.get("name")
                args = params.get("arguments") or {}
                if tool_name == "submit_message":
                    res = self.mailbox.submit_message(
                        content=args.get("content"),
                        queue=args.get("queue", DEFAULT_QUEUE),
                        correlation_id=args.get("correlation_id"),
                        idempotency_key=args.get("idempotency_key"),
                    )
                    return tool_result(res, req_id)
                elif tool_name == "get_messages":
                    res = self.mailbox.get_messages(
                        queue=args.get("queue"),
                        status=args.get("status"),
                        cursor=args.get("cursor"),
                        limit=args.get("limit", 10),
                    )
                    return tool_result(res, req_id)
                elif tool_name == "reply":
                    res = self.mailbox.reply_message(
                        msg_id=args.get("message_id"),
                        reply_text=args.get("reply"),
                        correlation_id=args.get("correlation_id"),
                    )
                    return tool_result(res, req_id)
                else:
                    return {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "error": {"code": -32601, "message": f"Tool not found: {tool_name}"},
                    }

            elif method == "events/list":
                return {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {
                        "events": [
                            {
                                "name": "message.created",
                                "description": "A new work assignment or message was submitted to the mailbox.",
                                "delivery": ["webhook"],
                                "inputSchema": {
                                    "type": "object",
                                    "properties": {
                                        "queue": {
                                            "type": "string",
                                            "description": "Mailbox queue to monitor for new assignments.",
                                        }
                                    },
                                    "additionalProperties": False,
                                },
                                "payloadSchema": {
                                    "type": "object",
                                    "properties": {
                                        "message_id": {"type": "string"},
                                        "queue": {"type": "string"},
                                        "content": {"type": "string"},
                                        "correlation_id": {"type": "string"},
                                        "created_at": {"type": "string"},
                                    },
                                    "required": ["message_id", "queue", "content", "created_at"],
                                    "additionalProperties": False,
                                },
                            }
                        ]
                    },
                }

            elif method == "events/subscribe":
                try:
                    sub_res = self.mailbox.subscribe_event(
                        name=params.get("name"),
                        arguments=params.get("arguments"),
                        delivery=params.get("delivery"),
                        ttl_ms=params.get("ttlMs", DEFAULT_SUB_LIFETIME_MS),
                    )
                    return {"jsonrpc": "2.0", "id": req_id, "result": sub_res}
                except ValueError as e:
                    return {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "error": {
                            "code": -32015,
                            "message": f"CallbackEndpointError: {e}",
                            "data": {"reason": "challenge_failed", "details": str(e)},
                        },
                    }

            elif method == "events/unsubscribe":
                res = self.mailbox.unsubscribe_event(
                    name=params.get("name"),
                    arguments=params.get("arguments"),
                    delivery=params.get("delivery"),
                )
                return {"jsonrpc": "2.0", "id": req_id, "result": res}

            else:
                return {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "error": {"code": -32601, "message": f"Method not found: {method}"},
                }

        except Exception as e:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32603, "message": f"Internal error: {e}"},
            }


# --- Server Transports ---

class MCPHTTPHandler(http.server.BaseHTTPRequestHandler):
    dispatcher: MCPDispatcher = None

    def log_message(self, format, *args):
        # Keep quiet on standard operations unless verbose
        pass

    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            info = {
                "status": "ok",
                "name": "fm-dot-mailbox",
                "protocolVersion": PROTOCOL_VERSION,
                "server": "fm-dot-mailbox",
            }
            self.wfile.write(json.dumps(info).encode("utf-8"))
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path != "/mcp":
            self.send_error(404)
            return

        try:
            content_length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            self.send_error(400, "Invalid Content-Length")
            return
        if content_length < 0 or content_length > MAX_BODY_BYTES:
            self.send_error(413, "Payload Too Large")
            return

        body = self.rfile.read(content_length)
        try:
            req_data = json.loads(body.decode("utf-8"))
        except Exception:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            err_resp = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}
            self.wfile.write(json.dumps(err_resp).encode("utf-8"))
            return

        resp = self.dispatcher.dispatch(req_data)
        if resp is not None:
            try:
                resp_bytes = bounded_json(resp)
            except ValueError:
                resp_bytes = json_bytes({"jsonrpc": "2.0", "id": None, "error": {"code": -32603, "message": "Response exceeds 256 KiB"}})
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp_bytes)))
            self.end_headers()
            self.wfile.write(resp_bytes)
        else:
            self.send_response(204)
            self.end_headers()


def run_http_server(mailbox, host="127.0.0.1", port=8765):
    dispatcher = MCPDispatcher(mailbox)
    handler_cls = type("BoundHandler", (MCPHTTPHandler,), {"dispatcher": dispatcher})
    server = http.server.ThreadingHTTPServer((host, port), handler_cls)
    stop = threading.Event()

    def delivery_worker():
        while not stop.is_set():
            mailbox.deliver_pending_events()
            stop.wait(0.25)

    worker = threading.Thread(target=delivery_worker, daemon=True)
    worker.start()
    print(f"fm-dot-mailbox: listening on http://{host}:{port}/mcp (database: {mailbox.db_path})", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        stop.set()
        worker.join()


# --- CLI Commands ---

def read_stdin_text():
    data = sys.stdin.buffer.read(MAX_TEXT_BYTES + 1)
    if len(data) > MAX_TEXT_BYTES:
        raise ValueError(f"stdin exceeds {MAX_TEXT_BYTES} UTF-8 bytes")
    return data.decode("utf-8").strip()


def main():
    parser = argparse.ArgumentParser(description="Firstmate dot MCP Mailbox & Event Bridge")
    parser.add_argument("--db", help="SQLite database path; otherwise FM_HOME is required")

    subparsers = parser.add_subparsers(dest="command")

    # submit
    p_submit = subparsers.add_parser("submit", help="Submit a message to the mailbox")
    p_submit.add_argument("content", help="Message content, or '-' to read from stdin")
    p_submit.add_argument("--queue", default=DEFAULT_QUEUE, help="Target queue")
    p_submit.add_argument("--correlation-id", help="Correlation identifier")
    p_submit.add_argument("--idempotency-key", help="Idempotency key")

    # get
    p_get = subparsers.add_parser("get", help="Get a message by ID")
    p_get.add_argument("message_id", help="Message ID")

    # list
    p_list = subparsers.add_parser("list", help="List messages in the mailbox")
    p_list.add_argument("--queue", help="Filter by queue")
    p_list.add_argument("--status", choices=["pending", "replied", "all"], default="all", help="Filter by status")
    p_list.add_argument("--cursor", help="Pagination cursor")
    p_list.add_argument("--limit", type=int, default=10, help="Maximum messages to return")

    # reply
    p_reply = subparsers.add_parser("reply", help="Reply to a message")
    p_reply.add_argument("message_id", help="Exact message ID")
    p_reply.add_argument("reply_text", help="Reply content, or '-' to read from stdin")
    p_reply.add_argument("--correlation-id", help="Optional correlation ID")

    # status
    subparsers.add_parser("status", help="Print mailbox status summary")

    # serve
    p_serve = subparsers.add_parser("serve", help="Run the MCP server")
    p_serve.add_argument("--host", default=os.environ.get("FM_DOT_MCP_HOST", "127.0.0.1"), help="Host to bind (default 127.0.0.1)")
    p_serve.add_argument("--port", type=int, default=int(os.environ.get("FM_DOT_MCP_PORT", 8765)), help="Port to listen (default 8765)")
    p_serve.add_argument("--allow-local-callbacks", action="store_true", help="Allow HTTP and loopback callbacks for local testing")

    args = parser.parse_args()
    if not args.command:
        parser.print_help(sys.stderr)
        sys.exit(1)

    try:
        db_path = args.db or default_db_path()
        allow_local = getattr(args, "allow_local_callbacks", False) or os.environ.get("FM_DOT_MCP_ALLOW_LOCAL_CALLBACK") == "1"
        mailbox = Mailbox(db_path, allow_local_callbacks=allow_local)
    except (ValueError, OSError, sqlite3.Error) as error:
        parser.error(str(error))

    if args.command == "submit":
        content = args.content
        if content == "-":
            content = read_stdin_text()
        msg = mailbox.submit_message(
            content=content,
            queue=args.queue,
            correlation_id=args.correlation_id,
            idempotency_key=args.idempotency_key,
        )
        print(bounded_json(msg).decode("utf-8"))

    elif args.command == "get":
        msg = mailbox.get_message_by_id(args.message_id)
        if not msg:
            print(f"Error: message {args.message_id} not found", file=sys.stderr)
            sys.exit(1)
        print(bounded_json(msg).decode("utf-8"))

    elif args.command == "list":
        res = mailbox.get_messages(
            queue=args.queue,
            status=args.status,
            cursor=args.cursor,
            limit=args.limit,
        )
        print(bounded_json(res).decode("utf-8"))

    elif args.command == "reply":
        reply_text = args.reply_text
        if reply_text == "-":
            reply_text = read_stdin_text()
        res = mailbox.reply_message(
            msg_id=args.message_id,
            reply_text=reply_text,
            correlation_id=args.correlation_id,
        )
        print(bounded_json(res).decode("utf-8"))

    elif args.command == "status":
        st = mailbox.get_status()
        print(f"database: {st['database']}")
        print(f"messages: total={st['total_messages']} pending={st['pending_messages']} replied={st['replied_messages']}")
        print(f"subscriptions: active={st['active_subscriptions']}")
        print("events: " + " ".join(f"{key}={value}" for key, value in st["events"].items()))

    elif args.command == "serve":
        run_http_server(mailbox, host=args.host, port=args.port)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, sqlite3.Error) as error:
        print(f"fm-dot-mailbox: {error}", file=sys.stderr)
        sys.exit(1)
