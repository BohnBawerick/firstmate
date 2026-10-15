#!/usr/bin/env python3
# fm-dot-mailbox.py - Persistent private MCP mailbox and MCP 2.0 event bridge.
#
# Usage:
#   fm-dot-mailbox.py submit [--queue <q>] [--correlation-id <id>] [--idempotency-key <key>] <content | ->
#   fm-dot-mailbox.py get <message_id>
#   fm-dot-mailbox.py list [--queue <q>] [--status <pending|replied|all>] [--cursor <c>] [--limit <n>]
#   fm-dot-mailbox.py reply <message_id> <reply_text | -> [--correlation-id <id>]
#   fm-dot-mailbox.py status
#   fm-dot-mailbox.py serve [--host <host>] [--port <port>] [--stdio] [--allow-local-callbacks]
#
# Environment:
#   FM_DOT_MAILBOX_DB             Path to SQLite database file.
#   FM_DOT_MCP_ALLOW_LOCAL_CALLBACK  Allow loopback/http callback URLs (for tests).
#   FM_DOT_MCP_PORT               Default port for serve (default: 8765).
#   FM_DOT_MCP_HOST               Default host for serve (default: 127.0.0.1).
import argparse
import base64
import datetime
import hashlib
import hmac
import http.server
import ipaddress
import json
import os
import secrets
import select
import socket
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid

PROTOCOL_VERSION = "2026-07-28"
DEFAULT_QUEUE = "default"
MAX_BODY_BYTES = 256 * 1024  # 256 KiB
DEFAULT_SUB_LIFETIME_SEC = 86400  # 24 hours


def default_db_path():
    """Resolve default database path outside tracked source."""
    env_db = os.environ.get("FM_DOT_MAILBOX_DB")
    if env_db:
        return env_db
    fm_home = os.environ.get("FM_HOME")
    if fm_home:
        return os.path.join(fm_home, "data", "dot-mcp", "mailbox.sqlite3")
    return os.path.join(os.path.expanduser("~"), ".local", "share", "firstmate", "dot-mcp", "mailbox.sqlite3")


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")


def now_unix():
    return int(time.time())


def init_db(db_path):
    os.makedirs(os.path.dirname(os.path.abspath(db_path)), exist_ok=True)
    conn = sqlite3.connect(db_path, timeout=10.0, check_same_thread=False)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    with conn:
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
        conn.execute("CREATE INDEX IF NOT EXISTS idx_messages_id ON messages(id)")
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
            CREATE TABLE IF NOT EXISTS delivery_attempts (
                id TEXT PRIMARY KEY,
                event_id TEXT NOT NULL,
                subscription_id TEXT NOT NULL,
                message_id TEXT NOT NULL,
                status_code INTEGER,
                error TEXT,
                attempted_at TEXT NOT NULL
            )
        """)
    return conn


# --- Security and Webhook Helpers ---

class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, f"Redirects not permitted ({code})", headers, fp)


def check_ip_allowed(ip_str, allow_local=False):
    try:
        ip = ipaddress.ip_address(ip_str)
    except ValueError:
        return False, f"Invalid IP address: {ip_str}"
    if allow_local:
        return True, None
    if ip.is_loopback:
        return False, f"Loopback address blocked: {ip_str}"
    if ip.is_private:
        return False, f"Private network address blocked: {ip_str}"
    if ip.is_link_local:
        return False, f"Link-local address blocked: {ip_str}"
    if ip.is_multicast:
        return False, f"Multicast address blocked: {ip_str}"
    if ip.is_reserved or ip.is_unspecified:
        return False, f"Reserved/unspecified address blocked: {ip_str}"
    return True, None


def validate_destination_url(url, allow_local=False):
    try:
        parsed = urllib.parse.urlsplit(url)
    except Exception as e:
        return False, f"Invalid URL: {e}"
    if not allow_local:
        if parsed.scheme.lower() != "https":
            return False, "Destination URL must use HTTPS"
    else:
        if parsed.scheme.lower() not in ("http", "https"):
            return False, "Destination URL must use HTTP or HTTPS"
    hostname = parsed.hostname
    if not hostname:
        return False, "Destination URL missing hostname"
    try:
        port = parsed.port or (443 if parsed.scheme.lower() == "https" else 80)
        addrs = socket.getaddrinfo(hostname, port, proto=socket.IPPROTO_TCP)
        for _, _, _, _, sockaddr in addrs:
            ip_str = sockaddr[0]
            ok, err = check_ip_allowed(ip_str, allow_local=allow_local)
            if not ok:
                return False, err
    except socket.gaierror as e:
        return False, f"Cannot resolve destination host {hostname}: {e}"
    return True, None


def validate_signing_secret(secret_str):
    if not isinstance(secret_str, str) or not secret_str.startswith("whsec_"):
        return None, "Signing secret must start with whsec_"
    b64_part = secret_str[6:]
    try:
        raw_key = base64.b64decode(b64_part, validate=True)
    except Exception:
        try:
            raw_key = base64.b64decode(b64_part + "===")
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
        self.conn = init_db(db_path)

    def submit_message(self, content, queue=DEFAULT_QUEUE, correlation_id=None, idempotency_key=None):
        if not content:
            raise ValueError("content is required")
        queue = queue or DEFAULT_QUEUE
        with self.conn:
            if idempotency_key:
                cur = self.conn.execute("SELECT seq, id, queue, content, correlation_id, idempotency_key, status, reply, created_at, updated_at FROM messages WHERE idempotency_key = ?", (idempotency_key,))
                row = cur.fetchone()
                if row:
                    return self._row_to_msg(row)
            msg_id = f"msg_{secrets.token_hex(8)}"
            ts = now_iso()
            self.conn.execute(
                """
                INSERT INTO messages (id, queue, content, correlation_id, idempotency_key, status, reply, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 'pending', NULL, ?, ?)
                """,
                (msg_id, queue, content, correlation_id, idempotency_key, ts, ts),
            )
            cur = self.conn.execute("SELECT seq, id, queue, content, correlation_id, idempotency_key, status, reply, created_at, updated_at FROM messages WHERE id = ?", (msg_id,))
            msg = self._row_to_msg(cur.fetchone())

        # Trigger event delivery for matching subscriptions
        self.deliver_message_created_event(msg)
        return msg

    def get_messages(self, queue=None, status=None, cursor=None, limit=10):
        limit = max(1, min(int(limit or 10), 50))
        query = "SELECT seq, id, queue, content, correlation_id, idempotency_key, status, reply, created_at, updated_at FROM messages WHERE 1=1"
        params = []
        if queue:
            query += " AND queue = ?"
            params.append(queue)
        if status and status != "all":
            query += " AND status = ?"
            params.append(status)
        if cursor is not None and str(cursor).strip():
            try:
                seq_cursor = int(cursor)
                query += " AND seq > ?"
                params.append(seq_cursor)
            except ValueError:
                pass
        query += " ORDER BY seq ASC LIMIT ?"
        params.append(limit)

        cur = self.conn.execute(query, params)
        rows = cur.fetchall()
        messages = [self._row_to_msg(r) for r in rows]
        next_cursor = str(messages[-1]["seq"]) if messages else None
        return {"messages": messages, "next_cursor": next_cursor}

    def get_message_by_id(self, msg_id):
        cur = self.conn.execute("SELECT seq, id, queue, content, correlation_id, idempotency_key, status, reply, created_at, updated_at FROM messages WHERE id = ?", (msg_id,))
        row = cur.fetchone()
        return self._row_to_msg(row) if row else None

    def reply_message(self, msg_id, reply_text, correlation_id=None):
        if not msg_id or reply_text is None:
            raise ValueError("msg_id and reply_text are required")
        with self.conn:
            cur = self.conn.execute("SELECT seq, id, queue, content, correlation_id, idempotency_key, status, reply, created_at, updated_at FROM messages WHERE id = ? OR (correlation_id = ? AND ? != '')", (msg_id, msg_id, msg_id))
            row = cur.fetchone()
            if not row:
                raise ValueError(f"Message not found: {msg_id}")
            msg = self._row_to_msg(row)
            if msg["status"] == "replied" and msg["reply"] == reply_text:
                return {"status": "ok", "message_id": msg["id"], "idempotent": True}
            ts = now_iso()
            self.conn.execute("UPDATE messages SET reply = ?, status = 'replied', updated_at = ? WHERE id = ?", (reply_text, ts, msg["id"]))
            return {"status": "ok", "message_id": msg["id"]}

    def get_status(self):
        cur = self.conn.execute("SELECT COUNT(*), SUM(CASE WHEN status='pending' THEN 1 ELSE 0 END), SUM(CASE WHEN status='replied' THEN 1 ELSE 0 END) FROM messages")
        row = cur.fetchone()
        total, pending, replied = row[0] or 0, row[1] or 0, row[2] or 0
        cur = self.conn.execute("SELECT COUNT(*) FROM subscriptions WHERE refresh_before > ?", (now_iso(),))
        active_subs = cur.fetchone()[0] or 0
        return {
            "database": self.db_path,
            "total_messages": total,
            "pending_messages": pending,
            "replied_messages": replied,
            "active_subscriptions": active_subs,
        }

    def _row_to_msg(self, r):
        return {
            "seq": r[0],
            "id": r[1],
            "queue": r[2],
            "content": r[3],
            "correlation_id": r[4],
            "idempotency_key": r[5],
            "status": r[6],
            "reply": r[7],
            "created_at": r[8],
            "updated_at": r[9],
        }

    # --- Subscription and Event Delivery ---

    def subscribe_event(self, name, arguments, delivery, principal="dot-worker"):
        if name != "message.created":
            raise ValueError(f"Unsupported event: {name}")
        if not isinstance(delivery, dict) or delivery.get("mode") != "webhook":
            raise ValueError("delivery.mode must be 'webhook'")
        url = delivery.get("url")
        secret = delivery.get("secret")
        if not url:
            raise ValueError("delivery.url is required")
        raw_key, err = validate_signing_secret(secret)
        if err:
            raise ValueError(err)

        ok, url_err = validate_destination_url(url, allow_local=self.allow_local_callbacks)
        if not ok:
            raise ValueError(f"Callback destination rejected: {url_err}")

        filter_queue = (arguments or {}).get("queue")
        sub_id = derive_subscription_id(principal, url, name, arguments)

        # Callback verification challenge
        challenge_token = secrets.token_hex(16)
        verification_body = json.dumps({"type": "verification", "challenge": challenge_token}).encode("utf-8")
        webhook_id = f"msg_verification_{secrets.token_hex(8)}"
        ts_str = str(now_unix())
        sig = sign_standard_webhook(raw_key, webhook_id, ts_str, verification_body)

        headers = {
            "Content-Type": "application/json",
            "webhook-id": webhook_id,
            "webhook-timestamp": ts_str,
            "webhook-signature": sig,
            "X-MCP-Subscription-Id": sub_id,
        }

        opener = urllib.request.build_opener(NoRedirectHandler)
        req = urllib.request.Request(url, data=verification_body, headers=headers, method="POST")
        try:
            with opener.open(req, timeout=10.0) as resp:
                if not (200 <= resp.status < 300):
                    raise ValueError(f"Verification challenge returned status {resp.status}")
                resp_bytes = resp.read(MAX_BODY_BYTES)
                resp_data = json.loads(resp_bytes.decode("utf-8"))
                returned_challenge = resp_data.get("challenge", "")
                if not hmac.compare_digest(returned_challenge, challenge_token):
                    raise ValueError("Verification challenge echo mismatch")
        except urllib.error.HTTPError as e:
            raise ValueError(f"Verification challenge HTTP error {e.code}: {e.reason}")
        except urllib.error.URLError as e:
            raise ValueError(f"Verification challenge network error: {e.reason}")
        except Exception as e:
            raise ValueError(f"Verification challenge failed: {e}")

        # Store subscription
        refresh_before = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=DEFAULT_SUB_LIFETIME_SEC)).isoformat().replace("+00:00", "Z")
        now_ts = now_iso()
        with self.conn:
            self.conn.execute(
                """
                INSERT INTO subscriptions (id, event_name, filter_queue, callback_url, signing_secret, refresh_before, created_at, verified_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    signing_secret = excluded.signing_secret,
                    refresh_before = excluded.refresh_before,
                    verified_at = excluded.verified_at
                """,
                (sub_id, name, filter_queue, url, secret, refresh_before, now_ts, now_ts),
            )

        return {
            "id": sub_id,
            "refreshBefore": refresh_before,
            "cursor": None,
            "truncated": False,
        }

    def unsubscribe_event(self, name, arguments, delivery, principal="dot-worker"):
        url = (delivery or {}).get("url") if isinstance(delivery, dict) else None
        if not url:
            return {}
        sub_id = derive_subscription_id(principal, url, name, arguments)
        with self.conn:
            self.conn.execute("DELETE FROM subscriptions WHERE id = ?", (sub_id,))
        return {}

    def deliver_message_created_event(self, msg):
        cur = self.conn.execute(
            """
            SELECT id, callback_url, signing_secret, filter_queue
            FROM subscriptions
            WHERE event_name = 'message.created' AND refresh_before > ?
            """,
            (now_iso(),),
        )
        subs = cur.fetchall()
        for sub_id, url, secret, filter_q in subs:
            if filter_q and filter_q != msg["queue"]:
                continue
            raw_key, err = validate_signing_secret(secret)
            if err:
                continue
            event_id = f"evt_{secrets.token_hex(8)}"
            ts_iso = now_iso()
            payload = {
                "eventId": event_id,
                "name": "message.created",
                "timestamp": ts_iso,
                "data": {
                    "message_id": msg["id"],
                    "queue": msg["queue"],
                    "content": msg["content"],
                    "correlation_id": msg["correlation_id"],
                    "created_at": msg["created_at"],
                },
                "cursor": None,
            }
            body_bytes = json.dumps(payload).encode("utf-8")
            ts_str = str(now_unix())
            sig = sign_standard_webhook(raw_key, event_id, ts_str, body_bytes)
            headers = {
                "Content-Type": "application/json",
                "webhook-id": event_id,
                "webhook-timestamp": ts_str,
                "webhook-signature": sig,
                "X-MCP-Subscription-Id": sub_id,
            }

            status_code = None
            error_str = None
            try:
                opener = urllib.request.build_opener(NoRedirectHandler)
                req = urllib.request.Request(url, data=body_bytes, headers=headers, method="POST")
                with opener.open(req, timeout=10.0) as resp:
                    status_code = resp.status
            except urllib.error.HTTPError as e:
                status_code = e.code
                error_str = f"HTTP {e.code}"
            except Exception as e:
                error_str = str(e)

            with self.conn:
                attempt_id = f"att_{secrets.token_hex(8)}"
                self.conn.execute(
                    """
                    INSERT INTO delivery_attempts (id, event_id, subscription_id, message_id, status_code, error, attempted_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    (attempt_id, event_id, sub_id, msg["id"], status_code, error_str, now_iso()),
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
                    return {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {
                            "content": [{"type": "text", "text": json.dumps(res)}],
                            "isError": False,
                        },
                    }
                elif tool_name == "get_messages":
                    res = self.mailbox.get_messages(
                        queue=args.get("queue"),
                        status=args.get("status"),
                        cursor=args.get("cursor"),
                        limit=args.get("limit", 10),
                    )
                    return {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {
                            "content": [{"type": "text", "text": json.dumps(res)}],
                            "isError": False,
                        },
                    }
                elif tool_name == "reply":
                    res = self.mailbox.reply_message(
                        msg_id=args.get("message_id"),
                        reply_text=args.get("reply"),
                        correlation_id=args.get("correlation_id"),
                    )
                    return {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {
                            "content": [{"type": "text", "text": json.dumps(res)}],
                            "isError": False,
                        },
                    }
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
        if self.path in ("/mcp", "/health", "/"):
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
        if self.path not in ("/mcp", "/"):
            self.send_error(404)
            return

        content_length = int(self.headers.get("Content-Length", 0))
        if content_length > MAX_BODY_BYTES:
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
            resp_bytes = json.dumps(resp).encode("utf-8")
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
    print(f"fm-dot-mailbox: listening on http://{host}:{port}/mcp (database: {mailbox.db_path})", file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def run_stdio_server(mailbox):
    dispatcher = MCPDispatcher(mailbox)
    print("fm-dot-mailbox: stdio mode ready", file=sys.stderr)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            req_data = json.loads(line)
        except Exception:
            err_resp = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}
            sys.stdout.write(json.dumps(err_resp) + "\n")
            sys.stdout.flush()
            continue

        resp = dispatcher.dispatch(req_data)
        if resp is not None:
            sys.stdout.write(json.dumps(resp) + "\n")
            sys.stdout.flush()


# --- CLI Commands ---

def main():
    parser = argparse.ArgumentParser(description="Firstmate dot MCP Mailbox & Event Bridge")
    parser.add_argument("--db", default=default_db_path(), help="SQLite database path")
    parser.add_argument("--allow-local-callbacks", action="store_true", default=bool(os.environ.get("FM_DOT_MCP_ALLOW_LOCAL_CALLBACK")), help="Allow local/loopback callback destinations (testing)")

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
    p_reply.add_argument("message_id", help="Message ID or correlation ID")
    p_reply.add_argument("reply_text", help="Reply content, or '-' to read from stdin")
    p_reply.add_argument("--correlation-id", help="Optional correlation ID")

    # status
    subparsers.add_parser("status", help="Print mailbox status summary")

    # serve
    p_serve = subparsers.add_parser("serve", help="Run the MCP server")
    p_serve.add_argument("--host", default=os.environ.get("FM_DOT_MCP_HOST", "127.0.0.1"), help="Host to bind (default 127.0.0.1)")
    p_serve.add_argument("--port", type=int, default=int(os.environ.get("FM_DOT_MCP_PORT", 8765)), help="Port to listen (default 8765)")
    p_serve.add_argument("--stdio", action="store_true", help="Run in stdio mode instead of HTTP")

    args = parser.parse_args()
    if not args.command:
        parser.print_help(sys.stderr)
        sys.exit(1)

    mailbox = Mailbox(args.db, allow_local_callbacks=args.allow_local_callbacks)

    if args.command == "submit":
        content = args.content
        if content == "-":
            content = sys.stdin.read().strip()
        msg = mailbox.submit_message(
            content=content,
            queue=args.queue,
            correlation_id=args.correlation_id,
            idempotency_key=args.idempotency_key,
        )
        print(json.dumps(msg, indent=2))

    elif args.command == "get":
        msg = mailbox.get_message_by_id(args.message_id)
        if not msg:
            print(f"Error: message {args.message_id} not found", file=sys.stderr)
            sys.exit(1)
        print(json.dumps(msg, indent=2))

    elif args.command == "list":
        res = mailbox.get_messages(
            queue=args.queue,
            status=args.status,
            cursor=args.cursor,
            limit=args.limit,
        )
        print(json.dumps(res, indent=2))

    elif args.command == "reply":
        reply_text = args.reply_text
        if reply_text == "-":
            reply_text = sys.stdin.read().strip()
        res = mailbox.reply_message(
            msg_id=args.message_id,
            reply_text=reply_text,
            correlation_id=args.correlation_id,
        )
        print(json.dumps(res, indent=2))

    elif args.command == "status":
        st = mailbox.get_status()
        print(f"database: {st['database']}")
        print(f"messages: total={st['total_messages']} pending={st['pending_messages']} replied={st['replied_messages']}")
        print(f"subscriptions: active={st['active_subscriptions']}")

    elif args.command == "serve":
        if args.stdio:
            run_stdio_server(mailbox)
        else:
            run_http_server(mailbox, host=args.host, port=args.port)


if __name__ == "__main__":
    main()
