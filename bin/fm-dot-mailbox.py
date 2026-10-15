#!/usr/bin/env python3
# fm-dot-mailbox.py - Persistent private MCP mailbox and MCP 2.0 event bridge.
#
# Usage:
#   fm-dot-mailbox.py [--db <path>] <command> [options]
#   fm-dot-mailbox.py submit [--queue <q>] [--correlation-id <id>] [--idempotency-key <key>] <content | ->
#   fm-dot-mailbox.py get <message_id>
#   fm-dot-mailbox.py list [--queue <q>] [--status <pending|replied|all>] [--cursor <c>] [--limit <n>]
#   fm-dot-mailbox.py reply <message_id> <reply_text | -> [--correlation-id <id>]
#   fm-dot-mailbox.py status
#   fm-dot-mailbox.py serve [--host <host>] [--port <port>] [--allow-local-callbacks]
#
# Environment:
#   FM_HOME                       Owning home when no database path is supplied.
# Serve logs one JSON record per MCP POST to stderr: known method/tool names,
# HTTP status, result and JSON-RPC error code. Payloads, IDs, URLs and secrets
# are never logged; unrecognized method/tool names are replaced with "unknown".
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
from pathlib import Path
import re
import secrets
import socket
import sqlite3
import ssl
import stat
import subprocess
import tempfile
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
VERIFICATION_CACHE_SEC = 300
MAX_DELIVERY_ATTEMPTS = 4
CALLBACK_TIMEOUT_SEC = 10


def terminal_text(value):
    # Never let reported activity inject terminal escapes or status metadata.
    return ''.join(c for c in ' '.join(value.split()) if c.isprintable()).replace('[', '(').replace(']', ')')


def assignment_subject(content):
    body = content.partition("\n\n## Routed assignment\n")[2] or content
    body = re.sub(r"^\[fm-from-firstmate\]\u2063(?:corr=[a-fA-F0-9]{16}[ \t]*)?", "", body)
    first_line = next((line.strip() for line in body.splitlines() if line.strip()), "Assignment")
    return terminal_text(re.sub(r"^Subject:\s*", "", first_line, flags=re.IGNORECASE))[:256]


def parse_activity(text):
    if not text.startswith("activity-note:"):
        return None
    note = json.loads(text[len("activity-note:"):])
    required = {"schema", "event_id", "observed_at", "kind", "summary"}
    if not isinstance(note, dict) or not required <= note.keys() or note.keys() - required - {"task_id", "turn_id", "task_title", "url"}:
        raise ValueError("Invalid activity-note fields")
    if note["schema"] != "fm.activity-note.v1":
        raise ValueError("Unsupported activity-note schema")
    for key in ("event_id", "task_id", "turn_id"):
        if key in note and (not isinstance(note[key], str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", note[key])):
            raise ValueError("Invalid activity-note identifier")
    validate_text("summary", note["summary"], 1600)
    if "task_title" in note:
        validate_text("task_title", note["task_title"], 256)
        if not note["task_title"].strip():
            raise ValueError("task_title must not be blank")
    validate_text("observed_at", note["observed_at"], 40)
    try:
        observed = datetime.datetime.fromisoformat(note["observed_at"].replace("Z", "+00:00"))
        if observed.utcoffset() != datetime.timedelta(0) or observed.timestamp() > time.time() + 300:
            raise ValueError()
    except (ValueError, OverflowError):
        raise ValueError("observed_at must be a UTC timestamp, not in the future") from None
    note["observed_at"] = observed.isoformat(timespec="microseconds").replace("+00:00", "Z")
    if note["kind"] not in ("pickup", "task-created", "milestone", "blocked", "needs-decision", "done", "failed"):
        raise ValueError("Unknown activity-note kind")
    if note["kind"] == "pickup":
        if {"task_id", "turn_id", "task_title", "url"} & note.keys():
            raise ValueError("pickup is an assignment acknowledgement, not a cloud task")
    elif not {"task_id", "turn_id"} <= note.keys():
        raise ValueError("Cloud activity requires native task_id and turn_id")
    if "url" in note:
        validate_text("url", note["url"], 2048)
        url = urllib.parse.urlsplit(note["url"])
        if url.scheme != "https" or not url.hostname or url.username or url.password or any(c.isspace() or not c.isprintable() for c in note["url"]):
            raise ValueError("Activity URL must be a tool-supplied HTTPS URL")
    return note


def activity_child_id(note):
    return "cloud-" + hashlib.sha256(note["task_id"].encode()).hexdigest()[:24]


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


def private_text(path, text, *, replace=False, identical_ok=False):
    path = Path(path)
    if os.path.realpath(path) != os.path.abspath(path):
        raise ValueError("Private bridge files must not traverse symlinks")
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    if path.exists():
        info = path.stat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            raise ValueError("Unsafe bridge file")
        if identical_ok and path.read_text() == text:
            return
        if not replace:
            raise ValueError("Bridge file already exists with different content")
    temporary = path.with_name(path.name + "." + secrets.token_hex(8))
    try:
        with os.fdopen(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        if replace:
            os.replace(temporary, path)
        else:
            os.link(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def local_health_url(url):
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in ("http", "https") or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("Health URL must be a local HTTP(S) URL without credentials or query")
    try:
        if not ipaddress.ip_address(parsed.hostname).is_loopback:
            raise ValueError("Health URL must use a loopback IP")
        parsed.port
    except (ValueError, TypeError) as error:
        raise ValueError("Health URL must use a loopback IP and valid port") from error
    return parsed


def check_local_health(url, kind):
    parsed = local_health_url(url)
    connection = (http.client.HTTPSConnection if parsed.scheme == "https" else http.client.HTTPConnection)(
        parsed.hostname, parsed.port, timeout=2)
    try:
        connection.request("GET", parsed.path or "/")
        response = connection.getresponse()
        body = response.read(4097)
        if response.status != 200 or len(body) > 4096:
            return False
        if kind == "tunnel":
            return body.strip() == b"ready"
        value = json.loads(body)
        return value.get("status") == "ok" and value.get("name") == "fm-dot-mailbox"
    except (OSError, ValueError, http.client.HTTPException):
        return False
    finally:
        connection.close()


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
        columns = {row["name"] for row in conn.execute("PRAGMA table_info(messages)")}
        if "origin" not in columns:
            conn.execute("ALTER TABLE messages ADD COLUMN origin TEXT NOT NULL DEFAULT 'firstmate'")
        if "mate_id" not in columns:
            conn.execute("ALTER TABLE messages ADD COLUMN mate_id TEXT")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_messages_queue_status ON messages(queue, status)")
        conn.execute("""CREATE TABLE IF NOT EXISTS mates (
            id TEXT PRIMARY KEY, parent_home TEXT NOT NULL, home TEXT NOT NULL UNIQUE,
            queue TEXT NOT NULL UNIQUE, mailbox_url TEXT NOT NULL, tunnel_url TEXT NOT NULL,
            last_contact TEXT)""")
        conn.execute("""CREATE TABLE IF NOT EXISTS mate_replies (
            seq INTEGER PRIMARY KEY AUTOINCREMENT, message_id TEXT NOT NULL, digest TEXT NOT NULL,
            body TEXT NOT NULL, line TEXT NOT NULL, published INTEGER NOT NULL DEFAULT 0,
            retry_after REAL NOT NULL DEFAULT 0, UNIQUE(message_id, digest))""")
        if "activity" not in {row["name"] for row in conn.execute("PRAGMA table_info(mate_replies)")}:
            conn.execute("ALTER TABLE mate_replies ADD COLUMN activity TEXT")
        conn.execute("""
            CREATE TABLE IF NOT EXISTS subscriptions (
                id TEXT PRIMARY KEY,
                principal TEXT,
                event_name TEXT NOT NULL,
                filter_queue TEXT,
                callback_url TEXT NOT NULL,
                signing_secret TEXT NOT NULL,
                refresh_before TEXT NOT NULL,
                created_at TEXT NOT NULL,
                verified_at TEXT NOT NULL
            )
        """)
        if "principal" not in {row["name"] for row in conn.execute("PRAGMA table_info(subscriptions)")}:
            conn.execute("ALTER TABLE subscriptions ADD COLUMN principal TEXT")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_subscriptions_event ON subscriptions(event_name, filter_queue)")
        conn.execute("CREATE INDEX IF NOT EXISTS idx_subscriptions_callback ON subscriptions(principal, callback_url, verified_at)")
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


def resolve_callback(url, allow_local=False):
    validate_text("delivery.url", url, 4096)
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
    return parsed, hostname, port, addresses


def post_callback(url, body, headers, allow_local=False, *, read_response=False):
    if len(body) > MAX_BODY_BYTES:
        raise ValueError("Event payload exceeds 256 KiB")
    parsed, hostname, port, addresses = resolve_callback(url, allow_local)
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
        self.db_path = os.path.abspath(db_path)
        self.allow_local_callbacks = allow_local_callbacks
        self.lock = threading.RLock()
        self.conn = init_db(self.db_path)

    @contextmanager
    def transaction(self):
        with self.lock, self.conn:
            self.conn.execute("BEGIN IMMEDIATE")
            yield

    def submit_message(self, content, queue=DEFAULT_QUEUE, correlation_id=None, idempotency_key=None, *, origin="firstmate", mate_id=None):
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
            self.conn.execute("UPDATE messages SET origin=?, mate_id=? WHERE id=?", (origin, mate_id, msg_id))
            msg = self._row_to_msg(self.conn.execute("SELECT * FROM messages WHERE id = ?", (msg_id,)).fetchone())
            body = self._event_body(msg)
            subscriptions = [] if origin != "firstmate" else self.conn.execute(
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
            if row["mate_id"]:
                if correlation_id != row["correlation_id"]:
                    raise ValueError("Routed replies require the assignment's correlation_id")
                activity = parse_activity(reply_text)
                digest = hashlib.sha256(reply_text.encode()).hexdigest()
                if activity:
                    digest = "event:" + activity["event_id"]
                    previous = self.conn.execute("""SELECT r.* FROM mate_replies r JOIN messages m ON m.id=r.message_id
                        WHERE m.mate_id=? AND r.digest=?""", (row["mate_id"], digest)).fetchone()
                    if previous:
                        if previous["message_id"] != msg_id or json.loads(previous["activity"]) != activity:
                            raise ValueError("Activity event_id already binds a different event or assignment")
                        self.conn.execute("UPDATE mates SET last_contact=? WHERE id=?", (now_iso(), row["mate_id"]))
                        return {"status": "ok", "message_id": msg_id, "idempotent": True, "revision": previous["seq"]}
                    verb = activity["kind"] if activity["kind"] in ("done", "failed", "blocked", "needs-decision") else "working"
                    note = activity["summary"]
                else:
                    match = re.fullmatch(r"(working|done|blocked|needs-decision|paused):\s*(.+)", reply_text, re.DOTALL)
                    if not match:
                        raise ValueError("Routed replies require a status prefix or activity-note payload")
                    verb, note = match.groups()
                key = f" [key=dot-{msg_id}]" if verb in ("blocked", "needs-decision") else ""
                summary = terminal_text(note)[:800]
                line = f"{verb} [corr={correlation_id}] [at={now_unix()}]{key}: {summary}"
                self.conn.execute("""INSERT OR IGNORE INTO mate_replies (message_id,digest,body,line,activity)
                                     VALUES (?,?,?,?,?)""", (msg_id, digest, reply_text, line, json.dumps(activity) if activity else None))
                self.conn.execute("UPDATE mates SET last_contact=? WHERE id=?", (now_iso(), row["mate_id"]))
            if row["status"] == "replied" and row["reply"] == reply_text:
                return {"status": "ok", "message_id": row["id"], "idempotent": True}
            self.conn.execute("UPDATE messages SET reply = ?, status = 'replied', updated_at = ? WHERE id = ?", (reply_text, now_iso(), msg_id))
            bounded_json(tool_result(self._row_to_msg(self.conn.execute("SELECT * FROM messages WHERE id = ?", (msg_id,)).fetchone())))
            revision = self.conn.execute("SELECT MAX(seq) FROM mate_replies WHERE message_id=?", (msg_id,)).fetchone()[0]
            return {"status": "ok", "message_id": msg_id, "revision": revision}

    def mate(self, mate_id):
        if not os.environ.get("FM_HOME"):
            raise ValueError("FM_HOME is required for a dot route")
        with self.lock:
            row = self.conn.execute("SELECT * FROM mates WHERE id=?", (mate_id,)).fetchone()
        if not row or row["parent_home"] != os.path.realpath(os.environ.get("FM_HOME", "")):
            raise ValueError("Dot route is not registered to this FM_HOME")
        return dict(row)

    def register_mate(self, args):
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", args.mate_id):
            raise ValueError("Invalid mate id")
        parent = Path(os.environ["FM_HOME"]).resolve(strict=True)
        home = Path(args.home)
        if not home.is_absolute():
            raise ValueError("Dot home must be absolute")
        home = home.resolve()
        code_root = Path(__file__).resolve().parent.parent
        for root in (parent, code_root):
            if home == root or root in home.parents or home in root.parents:
                raise ValueError("Dot home must be separate from the parent home and code root")
        if any(ord(c) < 32 for c in str(parent) + str(home) + self.db_path):
            raise ValueError("Bridge paths must not contain control characters")
        validate_text("queue", args.queue)
        validate_text("scope", args.scope, 2048)
        if any(c in args.scope for c in "\r\n\x00") or any(c in str(home) for c in "\r\n\x00;)"):
            raise ValueError("Scope and home must fit a single registry record")
        for url in (args.mailbox_url, args.tunnel_url):
            local_health_url(url)
        charter = Path(args.charter).read_text()
        validate_text("charter", charter, 8192)
        values = (args.mate_id, str(parent), str(home), args.queue, args.mailbox_url, args.tunnel_url)
        with self.transaction():
            existing = self.conn.execute("SELECT * FROM mates WHERE id=?", (args.mate_id,)).fetchone()
            if existing:
                if tuple(existing[k] for k in ("id", "parent_home", "home", "queue", "mailbox_url", "tunnel_url")) != values:
                    raise ValueError("Existing dot route differs; no files were changed")
                if (home / "data/charter.md").read_text() != charter:
                    raise ValueError("Existing charter differs; registration does not overwrite it")
                return {"id": args.mate_id, "home": str(home), "already_registered": True}
            if self.conn.execute("SELECT 1 FROM mates WHERE queue=? OR home=?", (args.queue, str(home))).fetchone():
                raise ValueError("Queue or home is already assigned to a dot")
            registry = parent / "data/secondmates.md"
            if registry.is_symlink():
                raise ValueError("Unsafe secondmate registry")
            original = registry.read_text() if registry.exists() else "# Second mates\n\n"
            if any(line == f"- {args.mate_id}" or line.startswith(f"- {args.mate_id} ") for line in original.splitlines()):
                raise ValueError("Mate id already exists in the registry")
            meta = parent / f"state/{args.mate_id}.meta"
            if home.exists() or home.is_symlink() or meta.exists() or meta.is_symlink():
                raise ValueError("Dot home or metadata already exists; no files were changed")
            created = []
            registry_changed = False
            try:
                home.mkdir(mode=0o700)
                for directory in ("data", "state", "config", "projects"):
                    (home / directory).mkdir(mode=0o700)
                files = {
                    home / ".fm-secondmate-parent": f"schema=fm-secondmate-parent.v1\nroute=local\nparent_home={parent}\n",
                    home / ".fm-secondmate-transport": "dot-mcp\n",
                    home / "data/charter.md": charter,
                    home / ".fm-secondmate-home": args.mate_id + "\n",
                    meta: f"kind=secondmate\ntransport=dot-mcp\nhome={home}\ndot_mailbox_db={self.db_path}\n",
                }
                for path, content in files.items():
                    private_text(path, content)
                    created.append(path)
                self.conn.execute("INSERT INTO mates(id,parent_home,home,queue,mailbox_url,tunnel_url) VALUES(?,?,?,?,?,?)", values)
                line = f"- {args.mate_id} - ChatGPT dot over MCP (home: {home}; scope: {args.scope}; projects: ; added {now_iso()[:10]})\n"
                proposed = original.rstrip() + "\n" + line
                with tempfile.NamedTemporaryFile(mode="w", dir=parent / "state") as candidate:
                    candidate.write(proposed)
                    candidate.flush()
                    check = subprocess.run(["bash", "-c",
                        '. "$1/fm-secondmate-registry-lib.sh"; secondmate_registry_validate_bindings "$2" secondmate_registry_path_key',
                        "dot-registry", str(Path(__file__).parent), candidate.name], capture_output=True, timeout=15)
                    if check.returncode:
                        raise ValueError("Proposed secondmate registry is invalid or has overlapping homes")
                private_text(registry, proposed, replace=True)
                registry_changed = True
            except Exception:
                if registry_changed:
                    private_text(registry, original, replace=True)
                for path in reversed(created):
                    path.unlink()
                for directory in ("projects", "config", "state", "data"):
                    try:
                        (home / directory).rmdir()
                    except OSError:
                        pass
                try:
                    home.rmdir()
                except OSError:
                    pass
                raise
        return {"id": args.mate_id, "home": str(home), "queue": args.queue}

    def send_mate(self, mate_id, content, correlation_id, idempotency_key):
        mate = self.mate(mate_id)
        if not re.fullmatch(r"[a-fA-F0-9]{16}", correlation_id):
            raise ValueError("Routed work requires a 16-hex parent correlation")
        # Exact retransmissions deduplicate; a recovery request with new text
        # and the same correlation is a new event, as on the remote inbox leg.
        idempotency_key += ":" + hashlib.sha256(content.encode()).hexdigest()
        charter = (Path(mate["home"]) / "data/charter.md").read_text()
        content = f"{charter.rstrip()}\n\n## Routed assignment\n{content}"
        return self.submit_message(content, mate["queue"], correlation_id, idempotency_key, mate_id=mate_id)

    def publish_mate_replies(self):
        # Lease before taking the parent's metadata lock, matching send's lock
        # order. A crash after append retries the same stamped status line.
        for _ in range(16):
            with self.transaction():
                row = self.conn.execute("""SELECT r.*, m.mate_id, p.home, p.parent_home FROM mate_replies r
                    JOIN messages m ON m.id=r.message_id JOIN mates p ON p.id=m.mate_id
                    WHERE r.published=0 AND r.retry_after<=? ORDER BY r.seq LIMIT 1""", (time.time(),)).fetchone()
                if row is None:
                    return
                self.conn.execute("UPDATE mate_replies SET retry_after=? WHERE seq=?", (time.time() + 30, row["seq"]))
            relative = f"data/{row['mate_id']}/mailbox-replies/{row['seq']}.md"
            try:
                env = {k: v for k, v in os.environ.items() if k not in ("FM_STATE_OVERRIDE", "FM_ROOT_OVERRIDE", "FM_DATA_OVERRIDE", "FM_CONFIG_OVERRIDE")}
                env["FM_HOME"] = row["parent_home"]
                command = ["bash", str(Path(__file__).with_name("fm-dot-secondmate.sh"))]
                if subprocess.run(command + ["validate", row["mate_id"]], env=env, capture_output=True, timeout=15).returncode:
                    raise ValueError("Parent route is unavailable")
                path = Path(row["parent_home"]) / relative
                private_text(path, row["body"] + "\n", identical_ok=True)
                line = f"{row['line']} (report={relative})"
                activity = json.loads(row["activity"]) if row["activity"] else None
                publish_args = ["publish", row["mate_id"], row["home"], self.db_path, line]
                if activity and activity["kind"] != "pickup":
                    if activity["kind"] in ("blocked", "needs-decision", "done", "failed"):
                        with self.lock:
                            current = self._current_children(row["mate_id"], activity["task_id"])[0]
                        publish_args = (["publish-child", row["mate_id"], row["home"], self.db_path,
                            activity_child_id(activity), activity["kind"], str(row["seq"]),
                            terminal_text(activity["summary"])[:800], relative] if current["seq"] == row["seq"] else None)
                    else:
                        publish_args = None
                if publish_args:
                    result = subprocess.run(command + publish_args, env=env, capture_output=True, timeout=15)
                    if result.returncode:
                        raise ValueError("Parent channel refused the reply")
            except (ValueError, OSError, subprocess.TimeoutExpired):
                print(json.dumps({"event": "mate_reply_publish", "result": "error"}), file=sys.stderr, flush=True)
            else:
                with self.transaction():
                    self.conn.execute("UPDATE mate_replies SET published=1 WHERE seq=?", (row["seq"],))

    @classmethod
    def reader(cls, db_path):
        box = cls.__new__(cls)
        box.db_path = os.path.abspath(db_path)
        box.lock = threading.RLock()
        check_private_path(box.db_path)
        box.conn = sqlite3.connect(Path(box.db_path).as_uri() + "?mode=ro", uri=True, timeout=10)
        box.conn.row_factory = sqlite3.Row
        box.conn.execute("PRAGMA query_only=ON")
        return box

    def mate_history(self, mate_id, cursor=0, limit=50):
        self.mate(mate_id)
        if int(cursor) < 0:
            raise ValueError("Cursor must be nonnegative")
        with self.lock:
            rows = self.conn.execute("""SELECT r.*, m.correlation_id FROM mate_replies r
                JOIN messages m ON m.id=r.message_id WHERE m.mate_id=? AND r.seq>? ORDER BY r.seq LIMIT ?""",
                (mate_id, int(cursor), max(1, min(int(limit), 50)))).fetchall()
        result = {"events": [], "next_cursor": int(cursor)}
        for row in rows:
            event = dict(row)
            event.pop("digest")
            event.pop("retry_after")
            event["activity"] = json.loads(event["activity"]) if event["activity"] else None
            event["revision"] = event.pop("seq")
            candidate = {"events": result["events"] + [event], "next_cursor": event["revision"]}
            if len(json_bytes(candidate)) > MAX_BODY_BYTES - 4096:
                break
            result = candidate
        return result

    def _current_children(self, mate_id, task_id=None):
        return self.conn.execute("""WITH turns AS (
                SELECT r.*, ROW_NUMBER() OVER (
                    PARTITION BY json_extract(activity,'$.task_id'),json_extract(activity,'$.turn_id')
                    ORDER BY (json_extract(activity,'$.kind') IN ('done','failed')) DESC,
                        json_extract(activity,'$.observed_at') DESC,r.seq DESC) AS turn_rank
                FROM mate_replies r JOIN messages m ON m.id=r.message_id
                WHERE m.mate_id=? AND activity IS NOT NULL AND json_extract(activity,'$.kind')!='pickup'
                    AND (? IS NULL OR json_extract(activity,'$.task_id')=?)),
            tasks AS (
                SELECT *, ROW_NUMBER() OVER (
                    PARTITION BY json_extract(activity,'$.task_id')
                    ORDER BY json_extract(activity,'$.observed_at') DESC,seq DESC) AS task_rank
                FROM turns WHERE turn_rank=1)
            SELECT * FROM tasks WHERE task_rank=1
            ORDER BY (json_extract(activity,'$.kind') IN ('done','failed')),seq DESC LIMIT 101""",
            (mate_id, task_id, task_id)).fetchall()

    def mate_snapshot(self, mate_id):
        mate = self.mate(mate_id)
        ready, health = self.mate_health(mate_id)
        with self.lock:
            expiry = self.conn.execute("""SELECT MAX(refresh_before) FROM subscriptions
                WHERE filter_queue=? OR filter_queue IS NULL""", (mate["queue"],)).fetchone()[0]
            children = self._current_children(mate_id)
            feed = self.conn.execute("""SELECT r.*, m.content AS assignment FROM mate_replies r JOIN messages m ON m.id=r.message_id
                WHERE m.mate_id=? ORDER BY r.seq DESC LIMIT 20""", (mate_id,)).fetchall()
        projected = []
        for row in children[:100]:
            note = json.loads(row["activity"])
            age = max(0, int(time.time() - datetime.datetime.fromisoformat(note["observed_at"].replace("Z", "+00:00")).timestamp()))
            terminal = note["kind"] in ("done", "failed")
            state = note["kind"] if note["kind"] in ("done", "failed", "blocked", "needs-decision") else "working"
            projected.append({**note, "id": activity_child_id(note), "revision": row["seq"],
                "state": state, "provenance": "dot-reported", "age_seconds": age,
                "current_state": "unknown" if age > 900 and not terminal else state,
                "terminal": terminal, "parent_delivered": bool(row["published"]),
                "display_required": not (terminal and row["published"])})
        result = {"id": mate_id, "ready": ready, "health": health, "last_contact": mate["last_contact"],
            "subscription_expiry": expiry, "children": projected, "children_truncated": len(children) > 100,
            "feed": [{"revision": r["seq"], "line": r["line"], "published": bool(r["published"]),
                      "subject": assignment_subject(r["assignment"]),
                      "activity": json.loads(r["activity"]) if r["activity"] else None} for r in reversed(feed)]}
        while len(json_bytes(result)) > MAX_BODY_BYTES - 4096 and result["children"]:
            result["children"].pop()
            result["children_truncated"] = True
        return result

    def mate_health(self, mate_id):
        mate = self.mate(mate_id)
        mailbox = check_local_health(mate["mailbox_url"], "mailbox")
        tunnel = check_local_health(mate["tunnel_url"], "tunnel")
        with self.lock:
            subscriptions = self.conn.execute("""SELECT COUNT(*) FROM subscriptions
                WHERE refresh_before>? AND (filter_queue=? OR filter_queue IS NULL)""", (now_iso(), mate["queue"])).fetchone()[0]
            unpublished = self.conn.execute("""SELECT COUNT(*) FROM mate_replies r JOIN messages m ON m.id=r.message_id
                WHERE m.mate_id=? AND r.published=0""", (mate_id,)).fetchone()[0]
            pending = self.conn.execute("SELECT COUNT(*) FROM messages WHERE mate_id=? AND status='pending'", (mate_id,)).fetchone()[0]
            undelivered = self.conn.execute("""SELECT COUNT(*) FROM pending_events e JOIN messages m ON m.id=e.message_id
                WHERE m.mate_id=? AND e.state='undelivered'""", (mate_id,)).fetchone()[0]
        summary = (f"mailbox={'ready' if mailbox else 'unavailable'} tunnel={'ready' if tunnel else 'unavailable'} "
                   f"subscription={'active' if subscriptions else 'missing'} last-contact={mate['last_contact'] or 'never'} "
                   f"dot-online=unknown assignments-pending={pending} events-undelivered={undelivered} replies-pending={unpublished}")
        return bool(mailbox and tunnel and subscriptions), summary

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
        with self.lock:
            checked_at = datetime.datetime.now(datetime.timezone.utc)
            cutoff = (checked_at - datetime.timedelta(seconds=VERIFICATION_CACHE_SEC)).isoformat(timespec="microseconds").replace("+00:00", "Z")
            cached = self.conn.execute(
                """SELECT verified_at FROM subscriptions WHERE principal=? AND callback_url=?
                   AND verified_at>? AND verified_at<=? ORDER BY verified_at DESC LIMIT 1""",
                (principal, url, cutoff, checked_at.isoformat(timespec="microseconds").replace("+00:00", "Z")),
            ).fetchone()
        verified_at = cached["verified_at"] if cached else None
        try:
            if verified_at is not None:
                resolve_callback(url, self.allow_local_callbacks)
            else:
                challenge = secrets.token_hex(16)
                body = json_bytes({"type": "verification", "challenge": challenge})
                webhook_id = f"msg_verification_{secrets.token_hex(8)}"
                timestamp = str(now_unix())
                headers = {
                    "Content-Type": "application/json", "webhook-id": webhook_id, "webhook-timestamp": timestamp,
                    "webhook-signature": sign_standard_webhook(raw_key, webhook_id, timestamp, body),
                    "X-MCP-Subscription-Id": sub_id,
                }
                status, response = post_callback(url, body, headers, self.allow_local_callbacks, read_response=True)
                if not 200 <= status < 300:
                    raise ValueError(f"Verification challenge returned status {status}")
                returned = json.loads(response).get("challenge")
                if not isinstance(returned, str) or not hmac.compare_digest(returned, challenge):
                    raise ValueError("Verification challenge echo mismatch")
                verified_at = now_iso()
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
                """INSERT INTO subscriptions (id, principal, event_name, filter_queue, callback_url, signing_secret, refresh_before, created_at, verified_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(id) DO UPDATE SET signing_secret=excluded.signing_secret,
                       principal=excluded.principal, refresh_before=excluded.refresh_before, verified_at=excluded.verified_at""",
                (sub_id, principal, name, filter_queue, url, secret, refresh_before, ts, verified_at),
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
                                "description": "Send a note to Firstmate. Dot-origin notes do not trigger assignment events; use reply to answer routed work.",
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
                        origin="dot",
                    )
                    return tool_result(res, req_id)
                elif tool_name == "get_messages":
                    res = self.mailbox.get_messages(
                        queue=args.get("queue"),
                        status=args.get("status"),
                        cursor=args.get("cursor"),
                        limit=args.get("limit", 10),
                    )
                    with self.mailbox.transaction():
                        self.mailbox.conn.execute("UPDATE mates SET last_contact=? WHERE queue=? OR ? IS NULL",
                                                  (now_iso(), args.get("queue"), args.get("queue")))
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
        # Base HTTP logs include untrusted paths and error text.
        pass

    def log_request(self, code="-", size="-"):
        record = getattr(self, "request_log", None)
        if record is not None:
            record.update(timestamp=now_iso(), http_status=int(code))
            if int(code) >= 400:
                record["result"] = "error"
            print(json.dumps(record), file=sys.stderr, flush=True)

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
        self.request_log = {"event": "mcp_request", "method": "unknown", "result": "error", "error_code": None}
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
            self.request_log["error_code"] = -32700
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            err_resp = {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "Parse error"}}
            self.wfile.write(json.dumps(err_resp).encode("utf-8"))
            return

        if isinstance(req_data, dict):
            method = req_data.get("method")
            if method in ("server/discover", "initialize", "notifications/initialized", "tools/list",
                          "tools/call", "events/list", "events/subscribe", "events/unsubscribe"):
                self.request_log["method"] = method
            params = req_data.get("params")
            if method == "tools/call" and isinstance(params, dict):
                tool = params.get("name")
                self.request_log["tool"] = tool if tool in ("submit_message", "get_messages", "reply") else "unknown"
        resp = self.dispatcher.dispatch(req_data)
        if resp is not None:
            try:
                resp_bytes = bounded_json(resp)
            except ValueError:
                resp = {"jsonrpc": "2.0", "id": None, "error": {"code": -32603, "message": "Response exceeds 256 KiB"}}
                resp_bytes = json_bytes(resp)
            self.request_log.update(result="error" if "error" in resp else "ok",
                                    error_code=resp.get("error", {}).get("code"))
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(resp_bytes)))
            self.end_headers()
            self.wfile.write(resp_bytes)
        else:
            self.request_log["result"] = "notification"
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
            mailbox.publish_mate_replies()
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

    p_register = subparsers.add_parser("mate-register", help="Internal local registration; use fm-dot-secondmate.sh")
    p_register.add_argument("mate_id")
    for option in ("home", "queue", "mailbox-url", "tunnel-url", "scope", "charter"):
        p_register.add_argument("--" + option, required=True)
    p_send = subparsers.add_parser("mate-send", help="Internal routed assignment; use fm-send.sh")
    p_send.add_argument("mate_id")
    p_send.add_argument("content")
    p_send.add_argument("--correlation-id", required=True)
    p_send.add_argument("--idempotency-key", required=True)
    p_health = subparsers.add_parser("mate-health", help="Internal dot health; use fm-dot-secondmate.sh")
    p_health.add_argument("mate_id")
    p_snapshot = subparsers.add_parser("mate-snapshot", help="Read reported cloud children and recent activity")
    p_snapshot.add_argument("mate_id")
    p_history = subparsers.add_parser("mate-history", help="Read append-only activity by server revision")
    p_history.add_argument("mate_id")
    p_history.add_argument("--cursor", type=int, default=0)
    p_history.add_argument("--limit", type=int, default=50)

    # serve
    p_serve = subparsers.add_parser("serve", help="Run the MCP server")
    p_serve.add_argument("--host", default="127.0.0.1", help="Host to bind (default 127.0.0.1)")
    p_serve.add_argument("--port", type=int, default=8765, help="Port to listen (default 8765)")
    p_serve.add_argument("--allow-local-callbacks", action="store_true", help="Allow HTTP and loopback callbacks for local testing")

    args = parser.parse_args()
    if not args.command:
        parser.print_help(sys.stderr)
        sys.exit(1)

    if args.command in ("mate-register", "mate-send"):
        if not os.environ.get("FM_HOME"):
            parser.error("FM_HOME is required for a dot route")
        guard = subprocess.run(["bash", "-c",
            '. "$1/fm-session-lock-lib.sh"; fm_require_session_lock "$2/state" "route dot work"',
            "dot-ownership", str(Path(__file__).parent), os.environ["FM_HOME"]], capture_output=True, text=True, timeout=15)
        if guard.returncode:
            parser.error(guard.stderr.strip() or "Parent session ownership could not be verified")

    try:
        db_path = args.db or default_db_path()
        allow_local = getattr(args, "allow_local_callbacks", False)
        mailbox = Mailbox(db_path, allow_local_callbacks=allow_local)
    except (ValueError, OSError, sqlite3.Error) as error:
        parser.error(str(error))

    if args.command == "mate-register":
        print(json.dumps(mailbox.register_mate(args)))

    elif args.command == "mate-send":
        content = read_stdin_text() if args.content == "-" else args.content
        print(json.dumps(mailbox.send_mate(args.mate_id, content, args.correlation_id, args.idempotency_key)))

    elif args.command == "mate-health":
        ready, summary = mailbox.mate_health(args.mate_id)
        print(summary)
        sys.exit(0 if ready else 3)

    elif args.command == "mate-snapshot":
        print(bounded_json(mailbox.mate_snapshot(args.mate_id)).decode())

    elif args.command == "mate-history":
        print(bounded_json(mailbox.mate_history(args.mate_id, args.cursor, args.limit)).decode())

    elif args.command == "submit":
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
    except (ValueError, OSError, sqlite3.Error, subprocess.TimeoutExpired) as error:
        print(f"fm-dot-mailbox: {error}", file=sys.stderr)
        sys.exit(1)
