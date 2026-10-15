#!/usr/bin/env python3
"""Read-only terminal projection of a dot's durable mailbox activity."""
import argparse
import importlib.util
import os
from pathlib import Path
import re
import select
import signal
import shutil
import sys
import termios
import textwrap
import time

spec = importlib.util.spec_from_file_location("mailbox", Path(__file__).with_name("fm-dot-mailbox.py"))
mailbox = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mailbox)


def local_time(value, pattern="%H:%M"):
    if not value:
        return "never"
    return mailbox.datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone().strftime(pattern)


def activity_line(event, width):
    note = event["activity"]
    subject = event["subject"]
    if note:
        clock = local_time(note["observed_at"])
        subject = note.get("task_title") or subject
        state = {"pickup": "accepted", "task-created": "started", "milestone": "working"}.get(note["kind"], note["kind"])
        task = "assignment" if note["kind"] == "pickup" else "task"
    else:
        line = event["line"]
        state = line.split()[0]
        stamp = re.search(r"\[at=(\d+)\]", line)
        clock = time.strftime("%H:%M", time.localtime(int(stamp[1]))) if stamp else "--:--"
        task = "assignment"
    prefix, suffix = f"{clock} {task} (", f") {state}"
    room = max(4, min(40, width - len(prefix) - len(suffix)))
    description = textwrap.shorten(mailbox.terminal_text(subject), width=room, placeholder="...")
    return prefix + description + suffix


def render(box, mate_id, child_id=None):
    snapshot = box.mate_snapshot(mate_id, [child_id] if child_id else [])
    width = max(32, shutil.get_terminal_size((80, 24)).columns)
    health = dict(part.split("=", 1) for part in snapshot["health"].split() if "=" in part)
    seen = local_time(snapshot["last_contact"])
    expiry = local_time(snapshot["subscription_expiry"], "%m-%d %H:%M")
    lines = [f"{mate_id} | connection {'ready' if snapshot['ready'] else 'unavailable'} | read-only",
             f"Seen {seen} | expiry {expiry}"]
    children = snapshot["children"]
    if child_id:
        children = [child for child in children if child["id"] == child_id]
        if not children:
            lines.append("No current observation available. This does not mean the task finished.")
    else:
        lines.append(f"{health.get('assignments-pending', '?')} pending | {sum(not child['terminal'] for child in children)} active")
    for child in children if child_id else []:
        lines.extend(["", f"Thread: {child['task_id']}", f"Turn: {child['turn_id']}",
                      f"Reported: {child['state']} at {local_time(child['observed_at'], '%m-%d %H:%M')} ({child['age_seconds']}s ago)",
                      f"Current: {child['current_state']} | parent delivered: {child['parent_delivered']}",
                      textwrap.shorten(mailbox.terminal_text(child["summary"]), width=width, placeholder="...")])
        if child.get("url"):
            lines.append(child["url"])
    if snapshot["children_truncated"]:
        lines.append("Child list truncated. Use history to read older observations.")
    lines.extend(["", f"Activity ({time.strftime('%Z')})"])
    if child_id:
        # Query only this child's history, not a second activity store.
        with box.lock:
            rows = box.conn.execute("""SELECT r.*, m.content AS assignment FROM mate_replies r JOIN messages m ON m.id=r.message_id
                WHERE m.mate_id=? AND json_extract(r.activity,'$.task_id')=?
                ORDER BY r.seq DESC LIMIT 30""",
                (mate_id, children[0]["task_id"])).fetchall() if children else []
        import json
        events = [{"revision": row["seq"], "activity": json.loads(row["activity"]), "line": row["line"],
                   "subject": mailbox.assignment_subject(row["assignment"])} for row in reversed(rows)]
    else:
        events = snapshot["feed"]
    header = '\n'.join(textwrap.fill(mailbox.terminal_text(line), width=width,
        break_long_words=False, break_on_hyphens=False) for line in lines)
    return header + '\n' + '\n'.join(activity_line(event, width) for event in events)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", required=True)
    parser.add_argument("mate")
    parser.add_argument("--child")
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    box = mailbox.Mailbox.reader(args.db)
    if args.once:
        print(render(box, args.mate, args.child))
        return
    original = None
    if sys.stdin.isatty():
        original = termios.tcgetattr(sys.stdin)
        settings = termios.tcgetattr(sys.stdin)
        settings[3] &= ~(termios.ECHO | termios.ICANON | termios.ISIG)
        termios.tcsetattr(sys.stdin, termios.TCSANOW, settings)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    try:
        while True:
            try:
                text = render(box, args.mate, args.child)
            except (ValueError, OSError, mailbox.sqlite3.Error):
                text = "Activity unavailable. No completion or cloud liveness can be inferred."
            print("\033[2J\033[H" + text, flush=True)
            # Discard input. This process has no shell or cloud-control path.
            end = time.monotonic() + 3
            while time.monotonic() < end:
                if original and select.select([sys.stdin], [], [], .2)[0]:
                    os.read(sys.stdin.fileno(), 4096)
                else:
                    time.sleep(.2)
    finally:
        box.conn.close()
        if original:
            termios.tcsetattr(sys.stdin, termios.TCSANOW, original)


if __name__ == "__main__":
    main()
