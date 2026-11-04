#!/usr/bin/env python3
"""fm-a2a-client.py - A2A transport for a terminal-less second mate.

Internal helper for bin/fm-a2a-secondmate.sh and bin/fm-procevent-a2a-reply.sh;
route work with bin/fm-send.sh instead of calling this directly.

Usage (FM_HOME must name the parent Firstmate home):
  fm-a2a-client.py register <id> --home <dir> --url <a2a-url> --credentials <file>
                   --token-var <name> --scope <text> --charter <file> [--turn-cap <1..20>]
  fm-a2a-client.py prepare <id> --corr <16hex>          # message on stdin
  fm-a2a-client.py deliver <id> <request-id>            # blocking; prints one result
  fm-a2a-client.py health <id>
  fm-a2a-client.py snapshot <id>
  fm-a2a-client.py request <id> <request-id>

The mate home holds config/a2a.json (endpoint, credential file path, turn cap),
state/a2a/context.json (the current Firstmate conversation) and one
state/a2a/requests/<request-id>.json record per routed message. The credential
itself stays in the named owner-only file and is read at send time.

Conversation keys: every message carries the current A2A contextId, so turns
share one Hermes gateway session. Hermes refuses more than its per-context turn
cap (A2A_MAX_PINGPONG_TURNS, default 5) and forgets a context's count after one
idle hour. prepare rotates to a new contextId before the cap and resets the
count after an idle hour plus a margin. A send the server still rejects with
anti-loop protection never ran, so deliver rotates once and resends it.

Delivery is at most once. deliver marks the record "sending" before the HTTP
call. A rerun that finds "sending" never resends: the outcome is reported as
unknown and the request needs an explicit resend. A connection that was refused
or an authentication failure before any reply marks the request undelivered, and
prepare with the same correlation and text queues it again.

Every outbound message starts with OUTBOUND_PREFIX so the receiving profile can
tell Firstmate's words from the captain's in its memory.
"""

import argparse
import datetime
import fcntl
import hashlib
import json
import os
import re
import secrets
import stat
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

OUTBOUND_PREFIX = "Message from Firstmate (the captain's coding orchestrator, not the captain):"
FROM_FIRSTMATE_MARK = "[fm-from-firstmate]⁣"  # fm-operational-input.sh FM_FROMFIRST_MARK; stripped here
CONFIG_SCHEMA = "fm-a2a-mate.v1"
REQUEST_SCHEMA = "fm-a2a-request.v1"
RESULT_SCHEMA = "fm-a2a-reply.v1"
DEFAULT_TURN_CAP = 5
HARD_TURN_CAP = 20
IDLE_RESET_SECONDS = 3600 + 300  # Hermes prunes an idle context after 3600 s
SERVER_REPLY_SECONDS = 300  # Hermes A2A_REPLY_TIMEOUT default
CLIENT_GRACE_SECONDS = 60
HEALTH_TIMEOUT = 8
MAX_MESSAGE_BYTES = 16 * 1024
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
TERMINAL = ("completed", "input-required", "failed", "rejected", "canceled", "unknown", "undelivered")
STATE_MAP = {
    "TASK_STATE_COMPLETED": "completed", "completed": "completed",
    "TASK_STATE_INPUT_REQUIRED": "input-required", "input-required": "input-required",
    "TASK_STATE_FAILED": "failed", "failed": "failed",
    "TASK_STATE_REJECTED": "rejected", "rejected": "rejected",
    "TASK_STATE_CANCELED": "canceled", "canceled": "canceled", "cancelled": "canceled",
}
ID_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,31}")
CORR_RE = re.compile(r"[a-f0-9]{16}")
REQUEST_RE = re.compile(r"[a-f0-9]{16}-[a-f0-9]{8}")


class Refusal(Exception):
    pass


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def private_write(path, text):
    """Atomically replace <path> with owner-only <text>."""
    path = Path(path)
    if path.is_symlink():
        raise Refusal(f"unsafe symlink: {path}")
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, 0o600)
        os.replace(tmp, path)
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def read_json(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise Refusal(f"missing or unsafe record: {path}")
    return json.loads(path.read_text())


def parent_home():
    value = os.environ.get("FM_HOME", "")
    if not value:
        raise Refusal("FM_HOME is required")
    return Path(value).resolve(strict=True)


def check_id(mate_id):
    if not ID_RE.fullmatch(mate_id):
        raise Refusal("invalid mate id")
    return mate_id


def meta_value(meta, key):
    value = ""
    for line in meta.read_text().splitlines():
        if line.startswith(key + "="):
            value = line[len(key) + 1:]
    return value


def mate_home(mate_id):
    parent = parent_home()
    meta = parent / "state" / f"{check_id(mate_id)}.meta"
    if meta.is_symlink() or not meta.is_file():
        raise Refusal("missing or unsafe a2a mate metadata")
    if meta_value(meta, "kind") != "secondmate" or meta_value(meta, "transport") != "a2a":
        raise Refusal("target is not an a2a secondmate")
    home = Path(meta_value(meta, "home"))
    if not home.is_absolute():
        raise Refusal("a2a mate home must be absolute")
    return home


def load_config(home):
    config = read_json(home / "config" / "a2a.json")
    if config.get("schema") != CONFIG_SCHEMA:
        raise Refusal("unsupported a2a mate configuration")
    return config


def read_token(config):
    path = Path(config["credentials_file"])
    try:
        info = path.stat()
    except OSError:
        raise Refusal(f"credential file is missing: {path}")
    if not stat.S_ISREG(info.st_mode) or path.is_symlink():
        raise Refusal(f"credential file is not a regular file: {path}")
    if info.st_mode & 0o077:
        raise Refusal(f"credential file must be owner-only (chmod 600): {path}")
    for line in path.read_text().splitlines():
        if line.startswith(config["token_var"] + "="):
            token = line.split("=", 1)[1].strip().strip('"').strip("'")
            if token:
                return token
    raise Refusal(f"credential {config['token_var']} is not set in {path}")


def rpc(config, method, params, *, timeout, token=None):
    """One JSON-RPC call. Returns (result, error); raises OSError on transport failure."""
    body = json.dumps({"jsonrpc": "2.0", "id": secrets.token_hex(6), "method": method, "params": params}).encode()
    request = urllib.request.Request(config["url"], data=body, method="POST",
                                     headers={"Content-Type": "application/json", "Accept": "application/json"})
    if token is not None:
        request.add_header("Authorization", f"Bearer {token}")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read(MAX_RESPONSE_BYTES))
    except urllib.error.HTTPError as exc:
        try:
            payload = json.loads(exc.read(MAX_RESPONSE_BYTES))
        except ValueError:
            payload = {}
        error = payload.get("error") if isinstance(payload, dict) else None
        return None, {"http_status": exc.code, **(error or {"message": f"HTTP {exc.code}"})}
    if not isinstance(payload, dict):
        return None, {"message": "malformed JSON-RPC response"}
    return payload.get("result"), payload.get("error")


def agent_card(config):
    url = config["url"].rstrip("/") + "/.well-known/agent-card.json"
    with urllib.request.urlopen(url, timeout=HEALTH_TIMEOUT) as response:
        card = json.loads(response.read(MAX_RESPONSE_BYTES))
    return card if isinstance(card, dict) else {}


def task_from_result(result):
    if isinstance(result, dict) and isinstance(result.get("task"), dict):
        return result["task"]
    if isinstance(result, dict) and result.get("status"):
        return result
    if isinstance(result, dict) and isinstance(result.get("message"), dict):
        return {"status": {"state": "TASK_STATE_COMPLETED", "message": result["message"]}}
    return {}


def task_text(task):
    texts = []
    for artifact in task.get("artifacts") or []:
        texts.extend(part.get("text", "") for part in artifact.get("parts") or [] if isinstance(part, dict))
    if not any(texts):
        message = (task.get("status") or {}).get("message") or {}
        texts = [part.get("text", "") for part in message.get("parts") or [] if isinstance(part, dict)]
    return "\n".join(t for t in texts if t).strip()


def routed_body(body):
    """The message without fm-send's routing marker and leading corr/delivery token."""
    if body.startswith(FROM_FIRSTMATE_MARK):
        body = body[len(FROM_FIRSTMATE_MARK):]
    return re.sub(r"^(corr|delivery)=[a-f0-9]{16}[ \t]*", "", body)


def outbound_text(home, body):
    body = routed_body(body)
    charter = (home / "data" / "charter.md").read_text().strip()
    text = f"{OUTBOUND_PREFIX}\n\n{body.strip()}\n\n---\n{charter}\n"
    if len(text.encode()) > MAX_MESSAGE_BYTES:
        raise Refusal(f"message exceeds {MAX_MESSAGE_BYTES} bytes")
    return text


def subject_of(body):
    for line in routed_body(body).splitlines():
        line = line.strip()
        if line:
            return re.sub(r"^Subject:\s*", "", line)[:80]
    return "(empty)"


def new_context(mate_id, generation):
    return {"context_id": f"firstmate-{mate_id}-{generation:04d}-{secrets.token_hex(4)}",
            "generation": generation, "turns": 0, "last_sent": 0}


def claim_turn(home, mate_id, config, now, *, force_rotate=False):
    """Reserve one turn in the current conversation, rotating first when needed."""
    path = home / "state" / "a2a" / "context.json"
    with open(home / "state" / "a2a" / ".context.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        context = read_json(path) if path.exists() else new_context(mate_id, 1)
        if context["last_sent"] and now - context["last_sent"] > IDLE_RESET_SECONDS:
            context["turns"] = 0
        if force_rotate or context["turns"] >= config["turn_cap"]:
            context = new_context(mate_id, context["generation"] + 1)
        context["turns"] += 1
        context["last_sent"] = now
        private_write(path, json.dumps(context, indent=1) + "\n")
    return context


def register(args):
    mate_id = check_id(args.mate_id)
    parent = parent_home()
    home = Path(args.home)
    if not home.is_absolute():
        raise Refusal("a2a mate home must be absolute")
    home = home.resolve()
    code_root = Path(__file__).resolve().parent.parent
    for root in (parent, code_root):
        if home == root or root in home.parents or home in root.parents:
            raise Refusal("a2a mate home must be separate from the parent home and code root")
    if any(c in str(home) for c in "\r\n\x00;)") or any(c in args.scope for c in "\r\n\x00"):
        raise Refusal("scope and home must fit a single registry record")
    if not re.fullmatch(r"https?://[^\s]+/?", args.url):
        raise Refusal("a2a url must be an http(s) URL")
    if not re.fullmatch(r"[A-Z][A-Z0-9_]*", args.token_var):
        raise Refusal("token variable must be an uppercase environment name")
    credentials = Path(args.credentials)
    if not credentials.is_absolute():
        raise Refusal("credential file must be absolute")
    if not 1 <= args.turn_cap <= HARD_TURN_CAP:
        raise Refusal(f"turn cap must be 1..{HARD_TURN_CAP}")
    charter = Path(args.charter).read_text()
    if not charter.strip() or len(charter.encode()) > 4096:
        raise Refusal("charter must be 1..4096 bytes")
    config = {"schema": CONFIG_SCHEMA, "url": args.url.rstrip("/") + "/", "credentials_file": str(credentials),
              "token_var": args.token_var, "turn_cap": args.turn_cap}
    meta = parent / "state" / f"{mate_id}.meta"
    registry = parent / "data" / "secondmates.md"
    if meta.exists() or meta.is_symlink():
        existing = home / "config" / "a2a.json"
        if (meta_value(meta, "transport") == "a2a" and Path(meta_value(meta, "home")) == home and existing.is_file()
                and read_json(existing) == config and (home / "data" / "charter.md").read_text() == charter):
            return {"id": mate_id, "home": str(home), "already_registered": True}
        raise Refusal("existing mate metadata differs; registration does not overwrite it")
    if registry.is_symlink():
        raise Refusal("unsafe secondmate registry")
    original = registry.read_text() if registry.exists() else "# Second mates\n\n"
    if any(line == f"- {mate_id}" or line.startswith(f"- {mate_id} ") for line in original.splitlines()):
        raise Refusal("mate id already exists in the registry")
    if home.exists() or home.is_symlink():
        raise Refusal("a2a mate home already exists; no files were changed")
    created, registry_changed = [], False
    try:
        home.mkdir(mode=0o700)
        for directory in ("data", "state", "config", "projects", "state/a2a", "state/a2a/requests"):
            (home / directory).mkdir(mode=0o700)
        files = {
            home / ".fm-secondmate-parent": f"schema=fm-secondmate-parent.v1\nroute=local\nparent_home={parent}\n",
            home / ".fm-secondmate-transport": "a2a\n",
            home / ".fm-secondmate-home": mate_id + "\n",
            home / "data" / "charter.md": charter,
            home / "config" / "a2a.json": json.dumps(config, indent=1) + "\n",
            home / "state" / "a2a" / "context.json": json.dumps(new_context(mate_id, 1), indent=1) + "\n",
            meta: f"kind=secondmate\ntransport=a2a\nhome={home}\n",
        }
        for path, content in files.items():
            if path.exists():
                raise Refusal(f"refusing to replace {path}")
            private_write(path, content)
            created.append(path)
        line = (f"- {mate_id} - Hermes profile over A2A (home: {home}; scope: {args.scope}; "
                f"projects: ; added {now_iso()[:10]})\n")
        proposed = original.rstrip() + "\n" + line
        with tempfile.NamedTemporaryFile(mode="w", dir=parent / "state") as candidate:
            candidate.write(proposed)
            candidate.flush()
            check = subprocess.run(["bash", "-c",
                '. "$1/fm-secondmate-registry-lib.sh"; secondmate_registry_validate_bindings "$2" secondmate_registry_path_key',
                "a2a-registry", str(Path(__file__).parent), candidate.name], capture_output=True, timeout=15)
            if check.returncode:
                raise Refusal("proposed secondmate registry is invalid or has overlapping homes")
        private_write(registry, proposed)
        registry_changed = True
    except BaseException:
        if registry_changed:
            private_write(registry, original)
        for path in reversed(created):
            path.unlink(missing_ok=True)
        for directory in ("state/a2a/requests", "state/a2a", "projects", "config", "state", "data", ""):
            try:
                (home / directory).rmdir()
            except OSError:
                pass
        raise
    return {"id": mate_id, "home": str(home), "url": config["url"]}


def prepare(args):
    mate_id = check_id(args.mate_id)
    if not CORR_RE.fullmatch(args.corr):
        raise Refusal("routed work requires a 16-hex parent correlation")
    home = mate_home(mate_id)
    config = load_config(home)
    body = sys.stdin.read()
    if not body.strip():
        raise Refusal("empty message")
    text = outbound_text(home, body)
    request_id = f"{args.corr}-{hashlib.sha256(body.encode()).hexdigest()[:8]}"
    path = home / "state" / "a2a" / "requests" / f"{request_id}.json"
    if path.exists():
        record = read_json(path)
        if record["state"] != "undelivered":
            return {"request": request_id, "state": record["state"], "context_id": record["context_id"], "existing": True}
        record.update(state="queued", requeued_at=now_iso())
        private_write(path, json.dumps(record, indent=1) + "\n")
        return {"request": request_id, "state": "queued", "context_id": record["context_id"], "existing": True}
    context = claim_turn(home, mate_id, config, int(time.time()))
    record = {"schema": REQUEST_SCHEMA, "request": request_id, "corr": args.corr, "mate": mate_id,
              "subject": subject_of(body), "text": text, "context_id": context["context_id"],
              "message_id": secrets.token_hex(16), "state": "queued", "created_at": now_iso()}
    private_write(path, json.dumps(record, indent=1) + "\n")
    return {"request": request_id, "state": "queued", "context_id": context["context_id"], "existing": False}


def finish(path, record, outcome, text, task_id=""):
    record.update(state=outcome, finished_at=now_iso(), reply=text, task_id=task_id)
    private_write(path, json.dumps(record, indent=1) + "\n")
    return result_of(record)


def result_of(record):
    return {"schema": RESULT_SCHEMA, "mate": record["mate"], "request": record["request"], "corr": record["corr"],
            "subject": record["subject"], "outcome": record["state"], "text": record.get("reply", ""),
            "task_id": record.get("task_id", ""), "context_id": record["context_id"]}


def deliver(args):
    mate_id = check_id(args.mate_id)
    if not REQUEST_RE.fullmatch(args.request_id):
        raise Refusal("invalid request id")
    home = mate_home(mate_id)
    config = load_config(home)
    path = home / "state" / "a2a" / "requests" / f"{args.request_id}.json"
    record = read_json(path)
    if record["state"] in TERMINAL:
        return result_of(record)
    if record["state"] == "sending":
        return finish(path, record, "unknown",
                      "An earlier delivery attempt was interrupted after the request may have reached the agent. "
                      f"It was not resent. Check the agent's conversation {record['context_id']} before resending.")
    try:
        token = read_token(config)
    except Refusal as exc:
        return finish(path, record, "undelivered", f"Not delivered: {exc}")
    for attempt in (1, 2):
        record.update(state="sending", attempt=attempt, sent_at=now_iso())
        private_write(path, json.dumps(record, indent=1) + "\n")
        params = {"message": {"messageId": record["message_id"], "role": "ROLE_USER",
                              "contextId": record["context_id"], "parts": [{"text": record["text"]}]}}
        try:
            result, error = rpc(config, "SendMessage", params, token=token,
                                timeout=SERVER_REPLY_SECONDS + CLIENT_GRACE_SECONDS)
        except ConnectionRefusedError as exc:
            return finish(path, record, "undelivered", f"Not delivered: connection refused ({exc})")
        except (OSError, ValueError) as exc:
            if isinstance(getattr(exc, "reason", None), ConnectionRefusedError):
                return finish(path, record, "undelivered", f"Not delivered: connection refused ({exc.reason})")
            return finish(path, record, "unknown",
                          f"The request was sent but no reply arrived ({type(exc).__name__}: {exc}). "
                          f"Check the agent's conversation {record['context_id']} before resending.")
        if error:
            if error.get("http_status") in (401, 403):
                return finish(path, record, "undelivered", f"Not delivered: the agent refused the credential ({error.get('message')})")
            return finish(path, record, "failed", f"The agent returned an error: {error.get('message', error)}")
        task = task_from_result(result)
        outcome = STATE_MAP.get(str((task.get("status") or {}).get("state", "")), "unknown")
        text = task_text(task)
        if outcome == "rejected" and "Anti-loop protection" in text and attempt == 1:
            context = claim_turn(home, mate_id, config, int(time.time()), force_rotate=True)
            record.update(context_id=context["context_id"], message_id=secrets.token_hex(16))
            continue
        return finish(path, record, outcome, text, str(task.get("id", "")))
    return finish(path, record, "rejected", "The agent kept refusing the conversation turn.")


def requests_of(home):
    directory = home / "state" / "a2a" / "requests"
    records = []
    for path in sorted(directory.glob("*.json")):
        try:
            records.append(read_json(path))
        except (Refusal, ValueError):
            continue
    return records


def health(mate_id):
    home = mate_home(mate_id)
    config = load_config(home)
    context = read_json(home / "state" / "a2a" / "context.json")
    in_flight = [r for r in requests_of(home) if r["state"] not in TERMINAL]
    card_state, auth_state = "unavailable", "unchecked"
    name = "unknown"
    try:
        name = str(agent_card(config).get("name") or "unnamed")
        card_state = "ready"
        result, error = rpc(config, "ListTasks", {"pageSize": 1}, token=read_token(config), timeout=HEALTH_TIMEOUT)
        auth_state = "ok" if error is None else f"refused({error.get('message', 'error')})"
    except Refusal as exc:
        auth_state = f"credential-missing({exc})"
    except (OSError, ValueError):
        pass
    ready = card_state == "ready" and auth_state == "ok"
    summary = (f"a2a={card_state} auth={auth_state} agent={name} context={context['context_id']} "
               f"turns={context['turns']}/{config['turn_cap']} in-flight={len(in_flight)} process-state=unknown")
    return ready, summary


def snapshot(mate_id):
    home = mate_home(mate_id)
    ready, summary = health(mate_id)
    now = time.time()
    children = []
    for record in requests_of(home):
        if record["state"] in TERMINAL:
            continue
        created = datetime.datetime.fromisoformat(record["created_at"].replace("Z", "+00:00")).timestamp()
        age = max(0, int(now - created))
        stale = age > SERVER_REPLY_SECONDS + CLIENT_GRACE_SECONDS * 2
        children.append({"id": f"a2a-{record['request']}", "kind": "request", "summary": record["subject"],
                         "state": "working", "current_state": "unknown" if stale else "working",
                         "terminal": False, "age_seconds": age, "provenance": "a2a-request",
                         "context_id": record["context_id"], "revision": 0})
    return {"id": mate_id, "ready": ready, "health": summary, "children": children, "children_truncated": False,
            "work_observation_fresh": all(child["current_state"] != "unknown" for child in children), "feed": []}


def main(argv):
    parser = argparse.ArgumentParser(prog="fm-a2a-client.py", description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("register")
    p.add_argument("mate_id")
    p.add_argument("--home", required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--credentials", required=True)
    p.add_argument("--token-var", required=True)
    p.add_argument("--scope", required=True)
    p.add_argument("--charter", required=True)
    p.add_argument("--turn-cap", type=int, default=DEFAULT_TURN_CAP)
    p = sub.add_parser("prepare")
    p.add_argument("mate_id")
    p.add_argument("--corr", required=True)
    for name in ("deliver", "request"):
        p = sub.add_parser(name)
        p.add_argument("mate_id")
        p.add_argument("request_id")
    for name in ("health", "snapshot"):
        sub.add_parser(name).add_argument("mate_id")
    args = parser.parse_args(argv)
    try:
        if args.command == "register":
            out = register(args)
        elif args.command == "prepare":
            out = prepare(args)
        elif args.command == "deliver":
            out = deliver(args)
        elif args.command == "request":
            home = mate_home(check_id(args.mate_id))
            if not REQUEST_RE.fullmatch(args.request_id):
                raise Refusal("invalid request id")
            out = read_json(home / "state" / "a2a" / "requests" / f"{args.request_id}.json")
        elif args.command == "health":
            ready, summary = health(check_id(args.mate_id))
            print(summary)
            return 0 if ready else 1
        else:
            out = snapshot(check_id(args.mate_id))
    except Refusal as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(out, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
