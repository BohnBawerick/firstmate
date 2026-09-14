import json, re
from pathlib import Path
root = Path(__file__).parent
logs = ["targeted-tests.log", "teardown-diagnostic.log", "agy-retest.log", "teardown-retest.log", "watch-retest.log"]
latest = {}
attempts = []
for name in logs:
    for line in (root / name).read_text().splitlines():
        match = re.match(r"FM_TEST_END (\S+) (\S+) exit=(\d+) duration_ms=(\d+) gate_skip=(\w+)", line)
        if not match:
            continue
        stamp, test, code, duration, skipped = match.groups()
        row = {"test": test, "finished": stamp, "exit": int(code), "duration_ms": int(duration), "skipped": skipped == "true", "log": name}
        attempts.append(row)
        if test not in latest or stamp > latest[test]["finished"]:
            latest[test] = row
result = {"latest": list(latest.values()), "attempts": attempts}
(root / "final-targeted-results.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps({"completed_scripts": len(latest), "remaining_failures": [r["test"] for r in latest.values() if r["exit"] != 0]}))
