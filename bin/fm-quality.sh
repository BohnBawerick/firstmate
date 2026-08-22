#!/usr/bin/env bash
# fm-quality.sh - the quality-gate pre-flight loop controller.
#
# Runs a project's own quality commands, reads the receipt they print, enforces
# bounds, and reports one outcome. It knows nothing about any language, any
# metric, or any mutation tool.
#
# Usage:
#   fm-quality.sh run <task-id> --phase <clean|harden> [--dry-run]
#   fm-quality.sh status <task-id>
#   fm-quality.sh receipt <task-id> [--phase <clean|harden>]
#   fm-quality.sh -h | --help
#
# Contract owners elsewhere, not restated here:
#   docs/quality-gate.md          .quality-gate.yaml (D1) and the receipt (D2)
#   docs/quality-receipt.schema.json  the receipt's JSON shape
#   bin/fm-quality-receipt.sh     the receipt validator this script calls
#
# TWO MODES, ONE SCRIPT. The task's recorded quality posture picks the mode.
#   hardened   the full loop: measure, agent turn, re-measure, and a threshold
#              that BLOCKS. Only "pass" continues.
#   read-only  one measurement, no agent turn, no commit, nothing blocked. The
#              scores are reported so a project has real numbers before anyone
#              commits to a threshold.
# Measurement and reporting are always on wherever they can run; only BLOCKING
# is gated on the hardened posture. A read-only run reports outcome "read-only",
# never "pass", so no caller can mistake a score that was merely reported for a
# gate that ran and approved.
#
# OUTCOMES AND EXIT CODES. The exit code is a pure function of the outcome, so a
# shell caller branches without parsing. This table is the single owner:
#
#   0  pass            threshold met on the diff against base_sha
#   1  exhausted       rounds or the wall-clock bound ran out below threshold
#   1  stuck           no_progress_limit rounds moved the same findings by nothing
#   2  (usage error)   bad arguments, missing task record, unreadable contract
#   3  blocked         could not measure: toolchain, red or flaky suite, drift
#   4  not-applicable  nothing to measure here, or no contract in this project
#   5  defect-found    a finding exposes a real product bug, not a missing test
#   6  read-only       measured and reported, nothing gated
#
# "Could not measure" is `blocked`, never `pass`. A gate that reports pass when
# it measured nothing manufactures confidence, which is worse than no gate.
#
# WALL CLOCK IS ENFORCED, NOT ASSUMED. bounds.budget_minutes (default 20) bounds
# the whole phase. Every measurement and every agent turn runs under the
# remaining budget as a hard timeout, so a slow engine reports `exhausted`
# rather than running for hours. A host with no timeout, gtimeout, or perl
# cannot enforce that bound and is refused as `blocked`.
#
# THE ORDINARY SUITE IS CHECKED FIRST. A mutation or complexity score measured
# over a red or flaky suite is meaningless, and its failure mode is silent and
# flattering rather than loud. When the contract names a `test` command, it runs
# once before the first measurement: red twice is `blocked`, and red then green
# on identical code is a flaky suite and also `blocked`.
#
# RECEIPTS. A receipt is proof of a measurement, so one is written only when a
# measurement produced one:
#
#   data/<id>/quality-clean-receipt.json
#   data/<id>/quality-harden-receipt.json
#
# Each receipt records the exclude list the run actually measured against, so a
# pass earned by excluding the diff is not byte-identical to a pass earned by
# writing tests.
#
# One file per phase, each a complete D2 phase receipt. The parked spec named a
# single data/<id>/quality-receipt.json holding both; the landed schema requires
# a verify envelope's children to share its head_sha, and the harden loop commits
# after the clean receipt is written, so the two phases never share a head. Each
# run deletes its own phase's receipt first, so a receipt always describes the
# current run and a stale pass can never outlive it.
#
# A ROUND. Measure against the fixed base_sha; a pass, a blocked, a
# not-applicable, or a defect ends the phase. Below threshold with room left:
# one bounded agent turn, then the ordinary suite. Red reverts the round, so a
# failed round costs budget and nothing else; green commits it. A round that
# ends the phase before the suite can judge it - a defect report, or a harness
# that never ran - is reverted too, so no exit leaves work no test ever saw. A survivor that
# is a real defect leaves the loop entirely, because writing a test that passes
# against a defect is exactly how a score gets gamed. "No progress" means the
# same finding ids, not the same count.
#
# THE AGENT TURN NEEDS A SCHEMA-VALIDATED ANSWER. Only claude and codex have a
# recipe here, and the resolved binary must still advertise its structured-output
# flag in its own --help; a harness that does not is refused as `blocked` naming
# the harness and its version. The loop never falls back to parsing prose. This
# check applies to hardened mode alone: read-only makes no agent call, so it runs
# on any harness. bounds.budget_usd is handed to the harness, so it is a real
# ceiling on claude and an unenforced declaration on codex, which has no spend
# flag to give it to; the wall-clock bound is what bounds a codex turn.
#
# STATUS LINES. A hardened run appends the sparse supervisor-actionable lines the
# firstmate status contract expects: one when the phase starts and one for its
# outcome. A read-only run appends none - a reported score is not something a
# supervisor acts on - and reports on stdout and in its receipt instead.
#
# Environment the phase command is given, from the repo root through the platform
# shell: FM_QUALITY_PHASE, FM_QUALITY_BASE_SHA, FM_QUALITY_HEAD_SHA,
# FM_QUALITY_MODE, FM_QUALITY_THRESHOLD (key=value lines), FM_QUALITY_EXCLUDE
# (one path glob per line).
#
# Overrides: FM_HOME, FM_STATE_OVERRIDE, FM_DATA_OVERRIDE.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SELF="$SCRIPT_DIR/fm-quality.sh"
RECEIPT_TOOL="$SCRIPT_DIR/fm-quality-receipt.sh"

usage() {
  sed -n '2,13{s/^# \{0,1\}//;s/^#$//;p;}' "$SELF"
}

die() {  # <message>
  printf 'fm-quality: %s\n' "$1" >&2
  exit 2
}

WORK_DIR=""
make_work_dir() {
  WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-quality.XXXXXX") || die "cannot create a work dir"
  CFG="$WORK_DIR/contract.tsv"
}
cleanup() {
  [ -z "$WORK_DIR" ] || rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT INT TERM

command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v git >/dev/null 2>&1 || die "git is required"

# --- argument parsing -------------------------------------------------------

CMD=""
ID=""
PHASE=""
DRY_RUN=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    run|status|receipt)
      [ -z "$CMD" ] || die "unexpected extra command $1"
      CMD=$1; shift ;;
    --phase)
      [ "$#" -ge 2 ] || die "--phase requires a value"
      PHASE=$2; shift 2 ;;
    --phase=*) PHASE=${1#--phase=}; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; break ;;
    -*) die "unknown option $1" ;;
    *)
      [ -z "$ID" ] || die "unexpected extra argument $1"
      ID=$1; shift ;;
  esac
done

[ -n "$CMD" ] || { usage >&2; exit 2; }
[ -n "$ID" ] || die "$CMD requires a task id"
case "$ID" in
  */*|.|..|'') die "invalid task id: $ID" ;;
esac
case "$PHASE" in
  ''|clean|harden) ;;
  *) die "--phase must be clean or harden (got '$PHASE')" ;;
esac
if [ "$CMD" = run ]; then
  [ -n "$PHASE" ] || die "run requires --phase clean or --phase harden"
else
  [ "$DRY_RUN" -eq 0 ] || die "--dry-run applies only to run"
fi

# --- task record ------------------------------------------------------------

META="$STATE/$ID.meta"
[ -f "$META" ] || die "no task record for $ID at $META"

meta_value() {  # <key>
  grep "^$1=" "$META" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

WT=$(meta_value worktree)
KIND=$(meta_value kind)
[ -n "$KIND" ] || KIND=ship
QUALITY=$(meta_value quality)
[ -n "$QUALITY" ] || QUALITY=standard
BASE_SHA=$(meta_value base_sha)
HARNESS=$(meta_value harness)
MODEL=$(meta_value model)

[ "$KIND" = ship ] || die "$ID is kind=$KIND; the quality loop applies to ship tasks only"

# The posture picks the mode. hardened blocks; anything else reports.
MODE=read-only
[ "$QUALITY" = hardened ] && MODE=hardened

CLEAN_RECEIPT="$DATA/$ID/quality-clean-receipt.json"
HARDEN_RECEIPT="$DATA/$ID/quality-harden-receipt.json"
receipt_path() {  # <phase>
  case "$1" in
    clean) printf '%s' "$CLEAN_RECEIPT" ;;
    harden) printf '%s' "$HARDEN_RECEIPT" ;;
  esac
}

# --- the .quality-gate.yaml contract ----------------------------------------

# Flattens the contract into "key<TAB>value" lines. The accepted YAML is the
# subset docs/quality-gate.md's D1 example uses - nested maps, scalar values,
# and simple "- item" sequences - and anything outside it is refused rather than
# half-read, because a gate that silently ignored a key it did not understand
# would report a verdict nobody configured.
parse_contract() {  # <file> -> flattened lines on stdout, message on stderr
  python3 - "$1" <<'PY'
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as handle:
        raw = handle.read()
except OSError as exc:
    print(f"cannot read {path}: {exc}", file=sys.stderr)
    raise SystemExit(1)


def strip_comment(line):
    quote = None
    for i, ch in enumerate(line):
        if quote:
            if ch == quote:
                quote = None
            continue
        if ch in "\"'":
            quote = ch
            continue
        if ch == "#" and (i == 0 or line[i - 1] in " \t"):
            return line[:i]
    return line


def scalar(text, lineno):
    text = text.strip()
    if not text:
        return ""
    if text[0] in "[{|>&*":
        raise ValueError(f"line {lineno}: unsupported YAML value {text!r}")
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        return text[1:-1]
    return text


stack = []  # (indent, dotted-key)
seq_counts = {}
out = []
try:
    for lineno, original in enumerate(raw.splitlines(), 1):
        line = strip_comment(original).rstrip()
        if not line.strip():
            continue
        stripped = line.lstrip(" ")
        if line[: len(line) - len(stripped)].find("\t") >= 0:
            raise ValueError(f"line {lineno}: tab indentation is not supported")
        indent = len(line) - len(stripped)
        if stripped.startswith("- "):
            while stack and indent < stack[-1][0]:
                stack.pop()
            if not stack:
                raise ValueError(f"line {lineno}: list item outside any key")
            parent = stack[-1][1]
            index = seq_counts.get(parent, 0)
            seq_counts[parent] = index + 1
            out.append((f"{parent}.{index}", scalar(stripped[2:], lineno)))
            continue
        while stack and indent <= stack[-1][0]:
            stack.pop()
        if ":" not in stripped:
            raise ValueError(f"line {lineno}: expected 'key: value' or '- item'")
        key, _, rest = stripped.partition(":")
        key = key.strip()
        if not key or any(c in key for c in " \t"):
            raise ValueError(f"line {lineno}: unsupported key {key!r}")
        prefix = stack[-1][1] + "." if stack else ""
        full = prefix + key
        value = scalar(rest, lineno)
        if value == "":
            stack.append((indent, full))
        else:
            out.append((full, value))
except ValueError as exc:
    print(str(exc), file=sys.stderr)
    raise SystemExit(1)

for key, value in out:
    if "\t" in value:
        print(f"value for {key} contains a tab", file=sys.stderr)
        raise SystemExit(1)
    print(f"{key}\t{value}")
PY
}

# Set once, next to WORK_DIR. load_contract runs in a command substitution, so a
# subshell assignment here would never reach the caller - only the file does.
CFG=""
cfg_get() {  # <key> -> value or empty
  [ -f "$CFG" ] || return 0
  awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$CFG"
}
# substr, not sub: the prefix is a literal dotted key, and sub would read its
# dots as a regex.
cfg_keys_under() {  # <prefix> -> "leaf<TAB>value" lines
  [ -f "$CFG" ] || return 0
  awk -F'\t' -v p="$1." 'index($1,p)==1 {
    leaf=substr($1, length(p) + 1); if (leaf !~ /\./) print leaf "\t" $2
  }' "$CFG"
}
cfg_seq() {  # <key> -> one item per line, in order
  [ -f "$CFG" ] || return 0
  awk -F'\t' -v p="$1." 'index($1,p)==1 {
    n=substr($1, length(p) + 1); if (n ~ /^[0-9]+$/) print n "\t" $2
  }' "$CFG" | sort -n -k1,1 | cut -f2-
}

# Loads the contract into $CFG. Echoes one of: ok, absent, or "error <message>".
load_contract() {  # <worktree>
  local file="$1/.quality-gate.yaml" err
  if [ ! -f "$file" ]; then
    printf 'absent\n'
    return 0
  fi
  if ! err=$(parse_contract "$file" 2>&1 >"$CFG"); then
    printf 'error %s\n' "$err"
    return 0
  fi
  local version
  version=$(cfg_get version)
  if [ "$version" != 1 ]; then
    printf 'error unknown .quality-gate.yaml version %s (this firstmate reads version 1)\n' "${version:-<missing>}"
    return 0
  fi
  if [ -z "$(cfg_get verify)" ]; then
    printf 'error .quality-gate.yaml has no verify command\n'
    return 0
  fi
  printf 'ok\n'
}

# --- bounds -----------------------------------------------------------------

BOUND_MAX_ITERATIONS=4
BOUND_NO_PROGRESS=2
BOUND_BUDGET_USD=8
BOUND_BUDGET_MINUTES=20

positive_integer() {  # <value>
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$1" -gt 0 ]
}

# budget_minutes alone may be fractional, so a bound short enough to exercise
# can be written without inventing a seconds key the contract does not have.
positive_number() {  # <value>
  case "$1" in
    ''|*[!0-9.]*|.|*.*.*) return 1 ;;
  esac
  python3 -c 'import sys; sys.exit(0 if float(sys.argv[1]) > 0 else 1)' "$1" 2>/dev/null
}

load_bounds() {
  local v
  v=$(cfg_get bounds.max_iterations); [ -z "$v" ] || BOUND_MAX_ITERATIONS=$v
  v=$(cfg_get bounds.no_progress_limit); [ -z "$v" ] || BOUND_NO_PROGRESS=$v
  v=$(cfg_get bounds.budget_usd); [ -z "$v" ] || BOUND_BUDGET_USD=$v
  v=$(cfg_get bounds.budget_minutes); [ -z "$v" ] || BOUND_BUDGET_MINUTES=$v
  for v in "$BOUND_MAX_ITERATIONS" "$BOUND_NO_PROGRESS"; do
    positive_integer "$v" || die "bounds.max_iterations and bounds.no_progress_limit must be positive integers (got '$v')"
  done
  positive_number "$BOUND_BUDGET_MINUTES" \
    || die "bounds.budget_minutes must be a positive number (got '$BOUND_BUDGET_MINUTES')"
  positive_number "$BOUND_BUDGET_USD" \
    || die "bounds.budget_usd must be a positive number (got '$BOUND_BUDGET_USD')"
  BUDGET_SECONDS=$(python3 -c 'import sys; print(max(1, round(float(sys.argv[1]) * 60)))' "$BOUND_BUDGET_MINUTES")
}
BUDGET_SECONDS=1200

# --- clock and bounded execution --------------------------------------------

now_ms() {
  python3 -c 'import time; print(int(time.time() * 1000))'
}

START_MS=0
elapsed_ms() {
  local now
  now=$(now_ms)
  printf '%s' "$((now - START_MS))"
}
remaining_seconds() {
  local used
  used=$(( $(elapsed_ms) / 1000 ))
  printf '%s' "$(( BUDGET_SECONDS - used ))"
}

# The bound has to be enforceable before any measurement is trusted, so the
# tool is resolved once and its absence is a refusal rather than an unbounded
# run. Same three-way resolution as bin/fm-nm-run-lib.sh's bounded call.
TIMEOUT_TOOL=""
resolve_timeout_tool() {
  if command -v timeout >/dev/null 2>&1; then TIMEOUT_TOOL=timeout
  elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_TOOL=gtimeout
  elif command -v perl >/dev/null 2>&1; then TIMEOUT_TOOL=perl
  else TIMEOUT_TOOL=""
  fi
}

# Runs <command-string> in <dir> under a hard <secs> bound. Exit 124 means the
# bound killed it, exactly as GNU timeout reports.
bounded_sh() {  # <secs> <dir> <command-string>
  local secs=$1 dir=$2 cmd=$3
  case "$TIMEOUT_TOOL" in
    timeout|gtimeout) ( cd "$dir" && "$TIMEOUT_TOOL" -- "$secs" sh -c "$cmd" ) ;;
    perl) ( cd "$dir" && perl -e 'my $t = shift; my $pid = fork; die "fork failed" unless defined $pid; if (!$pid) { setpgrp(0, 0); exec @ARGV } local $SIG{ALRM} = sub { kill "TERM", -$pid; select undef, undef, undef, 0.2; kill "KILL", -$pid; exit 124 }; alarm $t; waitpid $pid, 0; exit($? & 127 ? 128 + ($? & 127) : $? >> 8)' "$secs" sh -c "$cmd" ) ;;
    *) return 127 ;;
  esac
}

# --- receipt helpers --------------------------------------------------------

receipt_field() {  # <file> <dotted-key>
  python3 - "$1" "$2" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        doc = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(1)
node = doc
for part in sys.argv[2].split("."):
    if not isinstance(node, dict) or part not in node:
        raise SystemExit(1)
    node = node[part]
if isinstance(node, (dict, list)):
    print(json.dumps(node, sort_keys=True))
else:
    print(node)
PY
}

# The finding-id fingerprint of a measurement. "No progress" means the same
# findings, not the same count: two distinct surviving mutants on one line are
# two findings, and a round that killed one of them made progress.
receipt_finding_ids() {  # <file>
  python3 - "$1" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        doc = json.load(handle)
except (OSError, ValueError):
    raise SystemExit(1)
ids = sorted(
    str(f.get("id", ""))
    for f in doc.get("findings", [])
    if isinstance(f, dict)
)
print("\n".join(ids))
PY
}

# Rewrites a measurement receipt as the phase's final receipt: the loop's own
# outcome, the loop's total wall clock, and the round count it took.
finalize_receipt() {  # <in> <outcome> <duration_ms> <rounds> <note> <out> <exclusions>
  python3 - "$@" <<'PY'
import json
import sys

src, outcome, duration_ms, rounds, note, dest, exclusions = sys.argv[1:8]
with open(src, encoding="utf-8") as handle:
    doc = json.load(handle)
doc["outcome"] = outcome
doc["duration_ms"] = int(duration_ms)
doc["exclusions"] = [line for line in exclusions.splitlines() if line]
metrics = doc.get("metrics")
if not isinstance(metrics, dict):
    metrics = {}
metrics["quality_loop_rounds"] = int(rounds)
doc["metrics"] = metrics
if note:
    existing = doc.get("notes")
    doc["notes"] = f"{existing} {note}".strip() if isinstance(existing, str) else note
with open(dest, "w", encoding="utf-8") as handle:
    json.dump(doc, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
}

validate_receipt() {  # <file> <worktree>
  "$RECEIPT_TOOL" validate --check-head "$2" "$1"
}

# --- outcome reporting ------------------------------------------------------

outcome_exit() {  # <outcome>
  case "$1" in
    pass) printf '0' ;;
    exhausted|stuck) printf '1' ;;
    blocked) printf '3' ;;
    not-applicable) printf '4' ;;
    defect-found) printf '5' ;;
    read-only) printf '6' ;;
    *) printf '2' ;;
  esac
}

status_append() {  # <line>
  [ "$DRY_RUN" -eq 0 ] || return 0
  [ "$MODE" = hardened ] || return 0
  [ -d "$STATE" ] || return 0
  printf '%s\n' "$1" >> "$STATE/$ID.status"
}

# The single exit point for `run`. Prints the machine-readable outcome line,
# appends the hardened status line, and exits with this outcome's code.
finish() {  # <outcome> <detail>
  local outcome=$1 detail=$2 code
  code=$(outcome_exit "$outcome")
  printf 'outcome: %s · phase: %s · mode: %s · %s\n' "$outcome" "$PHASE" "$MODE" "$detail"
  case "$outcome" in
    pass) status_append "working: quality $PHASE passed, $detail" ;;
    blocked) status_append "blocked: quality $PHASE could not measure, $detail" ;;
    defect-found) status_append "blocked: quality $PHASE defect-found, $detail" ;;
    exhausted|stuck) status_append "blocked: quality $PHASE $outcome, $detail" ;;
    not-applicable) status_append "working: quality $PHASE not-applicable, $detail" ;;
  esac
  exit "$code"
}

# --- the agent turn ---------------------------------------------------------

AGENT_SCHEMA='{"type":"object","additionalProperties":false,"required":["action"],"properties":{"action":{"enum":["tested","excluded","defect-found","no-change"]},"finding_id":{"type":"string"},"note":{"type":"string"}}}'

# The resolved harness binary's own version string, so a refusal names what
# actually failed rather than the harness the task record asked for.
harness_version() {  # <harness>
  local bin version=""
  bin=$(command -v "$1" 2>/dev/null) && version=$("$bin" --version 2>/dev/null | head -1)
  printf '%s' "${version:-unknown}"
}

# Only claude and codex have a recipe, and the resolved binary must still
# advertise its structured-output flag in its own --help. A renamed or removed
# flag then refuses loudly naming the harness and version rather than running a
# turn whose answer would have to be parsed out of prose.
# Echoes "ok <flag>" or "refuse <message>".
check_structured_output() {  # <harness>
  local harness=$1 flag bin version help_out
  # The help surface that carries the flag, which is not always the top-level
  # one: codex documents --output-schema under `codex exec`, not `codex`.
  local -a help_args
  case "$harness" in
    claude) flag=--json-schema; bin=claude; help_args=(--help) ;;
    codex) flag=--output-schema; bin=codex; help_args=(exec --help) ;;
    '') printf 'refuse the task record names no harness, so the hardened loop cannot resolve one with schema-validated output\n'; return 0 ;;
    *) printf 'refuse harness %s has no schema-validated final answer; the hardened loop runs on claude or codex only\n' "$harness"; return 0 ;;
  esac
  if ! command -v "$bin" >/dev/null 2>&1; then
    printf 'refuse harness %s is not installed here\n' "$harness"
    return 0
  fi
  version=$(harness_version "$bin")
  help_out=$("$bin" "${help_args[@]}" 2>&1) || true
  if ! printf '%s\n' "$help_out" | grep -q -- "$flag"; then
    printf 'refuse harness %s (%s) no longer advertises %s, so its final answer cannot be schema-validated\n' "$harness" "$version" "$flag"
    return 0
  fi
  printf 'ok %s\n' "$flag"
}

# One bounded headless turn. Writes the agent's structured answer's `action`
# to stdout, or nothing when the turn produced no readable answer. The harness
# exit status goes to $WORK_DIR/turn.rc, because a turn that never ran is a
# broken harness, not an agent that looked and changed nothing. It runs in a
# command substitution, so a file is what reaches the caller.
agent_turn() {  # <secs> <prompt-file> <round>
  local secs=$1 prompt=$2 round=$3 out="$WORK_DIR/turn.out" schema_file="$WORK_DIR/turn-schema.json"
  local rc=0 resume=""
  [ "$round" -gt 1 ] && resume=1
  printf '%s' "$AGENT_SCHEMA" > "$schema_file"
  case "$HARNESS" in
    claude)
      local cmd="claude --dangerously-skip-permissions -p --output-format json --json-schema \"\$FM_QUALITY_SCHEMA\" --max-budget-usd $BOUND_BUDGET_USD"
      [ -z "$MODEL" ] || cmd="$cmd --model $MODEL"
      [ -z "$resume" ] || cmd="$cmd --continue"
      cmd="$cmd < \"\$FM_QUALITY_PROMPT\""
      FM_QUALITY_SCHEMA="$AGENT_SCHEMA" FM_QUALITY_PROMPT="$prompt" \
        bounded_sh "$secs" "$WT" "$cmd" > "$out" 2>/dev/null || rc=$?
      ;;
    codex)
      local cmd="codex exec"
      [ -z "$resume" ] || cmd="$cmd resume --last"
      cmd="$cmd --output-schema \"\$FM_QUALITY_SCHEMA_FILE\" --sandbox danger-full-access"
      [ -z "$MODEL" ] || cmd="$cmd --model $MODEL"
      cmd="$cmd - < \"\$FM_QUALITY_PROMPT\""
      FM_QUALITY_SCHEMA_FILE="$schema_file" FM_QUALITY_PROMPT="$prompt" \
        bounded_sh "$secs" "$WT" "$cmd" > "$out" 2>/dev/null || rc=$?
      ;;
    *) return 0 ;;
  esac
  printf '%s\n' "$rc" > "$WORK_DIR/turn.rc"
  # Tolerant read: the structured object is either the whole document, the
  # `result` field of a harness envelope (as an object or as a JSON string), or
  # the last JSON object printed among streamed events. Anything else is an
  # unreadable turn, which the loop treats as no progress rather than a verdict.
  python3 - "$out" <<'PY'
import json
import sys


def action_of(node):
    if isinstance(node, dict) and isinstance(node.get("action"), str):
        return node["action"]
    return None


def candidates(text):
    try:
        doc = json.loads(text)
    except ValueError:
        doc = None
    if doc is not None:
        yield doc
        if isinstance(doc, dict):
            inner = doc.get("result")
            if isinstance(inner, dict):
                yield inner
            elif isinstance(inner, str):
                try:
                    yield json.loads(inner)
                except ValueError:
                    pass
        return
    for line in reversed(text.splitlines()):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            yield json.loads(line)
        except ValueError:
            continue


try:
    with open(sys.argv[1], encoding="utf-8") as handle:
        text = handle.read()
except OSError:
    raise SystemExit(0)
for candidate in candidates(text):
    action = action_of(candidate)
    if action:
        print(action)
        break
PY
}

write_turn_prompt() {  # <receipt-file> <prompt-file>
  local receipt=$1 dest=$2
  {
    cat <<EOF
You are one round of a quality pre-flight loop on this repository.

The $PHASE phase measured the diff between $BASE_SHA and the current HEAD and
came in below its threshold. The findings it reported are below, as the phase
command printed them.

Pick ONE finding and do exactly one of these, then stop:

- Write a behavioral test that kills it, run the ordinary test suite, and answer
  {"action":"tested","finding_id":"<id>"}.
- If it is equivalent, unreachable, or unsupported, add the narrowest possible
  entry to the exclude list in .quality-gate.yaml and answer
  {"action":"excluded","finding_id":"<id>","note":"<why>"}.
- If it exposes a REAL PRODUCT DEFECT rather than a missing test, change nothing
  and answer {"action":"defect-found","finding_id":"<id>","note":"<the bug>"}.
  A test written to pass against a defect is exactly how this score gets gamed,
  so reporting it is the correct answer, not a failure.
- If none of the above applies, change nothing and answer {"action":"no-change"}.

Do not commit; the loop commits the round. Do not weaken or delete an existing
test, and do not change the threshold.

--- findings ---
EOF
    cat "$receipt"
  } > "$dest"
}

# --- measurement ------------------------------------------------------------

# Runs one phase command and validates what it printed. Sets:
#   MEASURE_STATUS   receipt | timeout | no-receipt | invalid | drift | no-command
#   MEASURE_OUTCOME  the receipt's own outcome, when there is one
#   MEASURE_FILE     the validated receipt path, when there is one
#   MEASURE_DETAIL   a human-readable reason
MEASURE_STATUS=""
MEASURE_OUTCOME=""
MEASURE_FILE=""
MEASURE_DETAIL=""
measure() {  # <command> <secs>
  local cmd=$1 secs=$2 out="$WORK_DIR/measure.json" rc=0 head_sha receipt_base receipt_phase
  MEASURE_STATUS=""; MEASURE_OUTCOME=""; MEASURE_FILE=""; MEASURE_DETAIL=""
  head_sha=$(git -C "$WT" rev-parse HEAD 2>/dev/null || true)
  FM_QUALITY_PHASE="$PHASE" \
  FM_QUALITY_BASE_SHA="$BASE_SHA" \
  FM_QUALITY_HEAD_SHA="$head_sha" \
  FM_QUALITY_MODE="$MODE" \
  FM_QUALITY_THRESHOLD="$(cfg_keys_under "$PHASE.threshold" | tr '\t' '=')" \
  FM_QUALITY_EXCLUDE="$(cfg_seq "$PHASE.exclude")" \
    bounded_sh "$secs" "$WT" "$cmd" > "$out" 2>/dev/null || rc=$?
  if [ "$rc" -eq 124 ]; then
    MEASURE_STATUS=timeout
    MEASURE_DETAIL="the $PHASE command did not finish inside the ${BOUND_BUDGET_MINUTES}-minute wall-clock bound"
    return 0
  fi
  if [ "$rc" -eq 127 ] && [ ! -s "$out" ]; then
    MEASURE_STATUS=no-command
    MEASURE_DETAIL="the $PHASE command could not be run here (exit 127)"
    return 0
  fi
  if [ ! -s "$out" ]; then
    MEASURE_STATUS=no-receipt
    MEASURE_DETAIL="the $PHASE command printed no receipt (exit $rc)"
    return 0
  fi
  local err
  if ! err=$(validate_receipt "$out" "$WT" 2>&1); then
    MEASURE_STATUS=invalid
    MEASURE_DETAIL="the $PHASE command printed an invalid receipt: ${err#fm-quality-receipt: }"
    return 0
  fi
  receipt_base=$(receipt_field "$out" base_sha || true)
  if [ "$receipt_base" != "$BASE_SHA" ]; then
    MEASURE_STATUS=drift
    MEASURE_DETAIL="the $PHASE receipt measured against $receipt_base, not this task's base commit $BASE_SHA"
    return 0
  fi
  receipt_phase=$(receipt_field "$out" phase || true)
  if [ "$receipt_phase" != "$PHASE" ]; then
    MEASURE_STATUS=drift
    MEASURE_DETAIL="the $PHASE command printed a $receipt_phase receipt, and the two phases judge findings by different vocabularies"
    return 0
  fi
  MEASURE_STATUS=receipt
  MEASURE_FILE=$out
  MEASURE_OUTCOME=$(receipt_field "$out" outcome || true)
  MEASURE_DETAIL="measured"
  return 0
}

# --- the ordinary suite -----------------------------------------------------

# A score measured over a red or flaky suite is meaningless, and its failure is
# silent and flattering rather than loud. Echoes ok, or "blocked <message>".
check_suite() {  # <command> <secs>
  local cmd=$1 secs=$2 rc=0
  bounded_sh "$secs" "$WT" "$cmd" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'ok\n'
    return 0
  fi
  if [ "$rc" -eq 124 ]; then
    printf 'blocked the ordinary test suite did not finish inside the wall-clock bound\n'
    return 0
  fi
  # Red once. Run it again on identical code: red twice is a red suite, and red
  # then green is a flaky one. Both make the metric meaningless. The re-run
  # takes what is left of the bound, not another full copy of it.
  secs=$(remaining_seconds)
  if [ "$secs" -le 0 ]; then
    printf 'blocked the ordinary test suite is red before any quality work, and the bound ran out before red and flaky could be told apart\n'
    return 0
  fi
  rc=0
  bounded_sh "$secs" "$WT" "$cmd" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 124 ]; then
    printf 'blocked the ordinary test suite did not finish inside the wall-clock bound\n'
    return 0
  fi
  if [ "$rc" -eq 0 ]; then
    printf 'blocked the ordinary test suite is flaky (red then green on identical code), so the score would be noise\n'
  else
    printf 'blocked the ordinary test suite is red before any quality work, so the score would be meaningless\n'
  fi
}

# --- commands ---------------------------------------------------------------

cmd_status() {
  local verdict detail phases phase file outcome missing="" state
  if [ "$MODE" != hardened ]; then
    printf 'quality: not-required · mode: %s · this task ships standard, so no receipt gates it\n' "$MODE"
    return 0
  fi
  if [ -z "$WT" ] || [ ! -d "$WT" ]; then
    printf 'quality: unreadable · mode: hardened · the task copy is gone, so its quality contract cannot be read\n'
    return 0
  fi
  make_work_dir
  state=$(load_contract "$WT")
  case "$state" in
    absent)
      printf 'quality: missing · mode: hardened · this task ships hardened but the project has no .quality-gate.yaml\n'
      return 0 ;;
    error*)
      printf 'quality: unreadable · mode: hardened · %s\n' "${state#error }"
      return 0 ;;
  esac
  phases=""
  for phase in clean harden; do
    [ -n "$(cfg_get "$phase.command")" ] && phases="$phases $phase"
  done
  if [ -z "$phases" ]; then
    printf 'quality: satisfied · mode: hardened · the contract configures no pre-flight phase, so there is nothing to prove locally\n'
    return 0
  fi
  verdict=satisfied
  detail="every configured phase has a passing receipt"
  for phase in $phases; do
    file=$(receipt_path "$phase")
    if [ ! -f "$file" ]; then
      missing="$missing $phase"
      continue
    fi
    if ! "$RECEIPT_TOOL" validate "$file" >/dev/null 2>&1; then
      printf 'quality: unreadable · mode: hardened · the %s receipt is present but not a valid receipt\n' "$phase"
      return 0
    fi
    if [ "$(receipt_field "$file" base_sha || true)" != "$BASE_SHA" ]; then
      printf 'quality: unreadable · mode: hardened · the %s receipt measured a different base commit than this task\n' "$phase"
      return 0
    fi
    outcome=$(receipt_field "$file" outcome || true)
    case "$outcome" in
      pass|not-applicable) ;;
      *)
        printf 'quality: not-passed · mode: hardened · the %s phase reported %s\n' "$phase" "$outcome"
        return 0 ;;
    esac
  done
  if [ -n "$missing" ]; then
    verdict=missing
    detail="no receipt for:${missing}"
  fi
  printf 'quality: %s · mode: hardened · %s\n' "$verdict" "$detail"
}

cmd_receipt() {
  local phase list=""
  for phase in clean harden; do
    [ -z "$PHASE" ] || [ "$PHASE" = "$phase" ] || continue
    [ -f "$(receipt_path "$phase")" ] && list="$list $(receipt_path "$phase")"
  done
  # shellcheck disable=SC2086
  python3 - $list <<'PY'
import json
import sys

docs = []
for path in sys.argv[1:]:
    with open(path, encoding="utf-8") as handle:
        docs.append(json.load(handle))
json.dump(docs, sys.stdout, indent=2, sort_keys=True)
sys.stdout.write("\n")
PY
}

# A round that ends the phase costs budget and nothing else, so every exit that
# skips the ordinary suite's verdict puts the task copy back where the round
# started. Half-finished work no test ever saw is not something to leave behind.
revert_round() {  # <head-sha>
  git -C "$WT" reset --hard --quiet "$1" 2>/dev/null || true
  git -C "$WT" clean -fdq 2>/dev/null || true
}

cmd_run() {
  local state suite phase_cmd test_cmd secs rc detail
  local round=1 no_progress=0 prev_ids="" ids="" last_receipt="" turn_action="" turn_rc=0
  local have_prev=0
  local round_head="" pinned_threshold=""

  [ -n "$WT" ] || die "the task record for $ID names no worktree"
  [ -d "$WT" ] || die "the task copy for $ID is gone: $WT"
  git -C "$WT" rev-parse --git-dir >/dev/null 2>&1 || die "$WT is not a git repository"

  make_work_dir
  START_MS=$(now_ms)

  # A receipt is proof of THIS run's measurement, so the previous one for this
  # phase goes first. Otherwise a run that could not measure would leave an
  # older pass standing as if it still described the code.
  mkdir -p "$DATA/$ID" || die "cannot create the task record dir $DATA/$ID"
  [ "$DRY_RUN" -eq 1 ] || rm -f -- "$(receipt_path "$PHASE")"

  state=$(load_contract "$WT")
  case "$state" in
    absent) finish not-applicable "this project has no .quality-gate.yaml, so there is no quality contract to measure" ;;
    error*) die "${state#error }" ;;
  esac
  load_bounds

  phase_cmd=$(cfg_get "$PHASE.command")
  [ -n "$phase_cmd" ] || finish not-applicable "the contract configures no $PHASE phase"

  if [ -z "$BASE_SHA" ]; then
    finish blocked "this task's record has no base commit, so a diff-scoped measurement has no anchor"
  fi
  git -C "$WT" rev-parse --verify --quiet "$BASE_SHA^{commit}" >/dev/null 2>&1 \
    || finish blocked "this task's base commit $BASE_SHA does not resolve in the task copy"

  resolve_timeout_tool
  [ -n "$TIMEOUT_TOOL" ] || finish blocked "no timeout, gtimeout, or perl here, so the wall-clock bound cannot be enforced and no measurement can be trusted"

  local structured=""
  if [ "$MODE" = hardened ]; then
    structured=$(check_structured_output "$HARNESS")
    case "$structured" in
      refuse*) finish blocked "${structured#refuse }" ;;
    esac
    if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
      finish blocked "the task copy has uncommitted changes; the loop commits each round, so it needs a clean tree to revert a failed round against"
    fi
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    printf 'dry-run: phase %s · mode %s · base %s\n' "$PHASE" "$MODE" "$BASE_SHA"
    printf 'dry-run: command %s\n' "$phase_cmd"
    printf 'dry-run: bounds max_iterations=%s no_progress_limit=%s budget_usd=%s budget_minutes=%s\n' \
      "$BOUND_MAX_ITERATIONS" "$BOUND_NO_PROGRESS" "$BOUND_BUDGET_USD" "$BOUND_BUDGET_MINUTES"
    printf 'dry-run: nothing was run and no receipt was written\n'
    exit 0
  fi

  status_append "working: quality $PHASE started"

  pinned_threshold=$(cfg_keys_under "$PHASE.threshold" | tr '\t' '=')

  test_cmd=$(cfg_get test)
  if [ -n "$test_cmd" ]; then
    secs=$(remaining_seconds)
    [ "$secs" -gt 0 ] || finish exhausted "the wall-clock bound ran out before the ordinary test suite could be checked"
    suite=$(check_suite "$test_cmd" "$secs")
    case "$suite" in
      blocked*) finish blocked "${suite#blocked }" ;;
    esac
  fi

  while : ; do
    secs=$(remaining_seconds)
    if [ "$secs" -le 0 ]; then
      finish exhausted "the ${BOUND_BUDGET_MINUTES}-minute wall-clock bound ran out after $((round - 1)) round(s)"
    fi
    # A turn may have edited the exclude list, which is one of the four answers
    # the prompt asks for. Re-read the contract so the next measurement sees it.
    # Bounds and the phase command stay pinned to round 1: a run does not get to
    # extend its own wall clock or swap the command it is being measured by.
    if [ "$round" -gt 1 ]; then
      state=$(load_contract "$WT")
      case "$state" in
        absent) finish blocked "the .quality-gate.yaml was removed during round $((round - 1)), so the contract can no longer be read" ;;
        error*) finish blocked "round $((round - 1)) left .quality-gate.yaml unreadable: ${state#error }" ;;
      esac
      [ -n "$(cfg_get "$PHASE.command")" ] \
        || finish blocked "round $((round - 1)) removed the $PHASE command from .quality-gate.yaml"
      [ "$(cfg_keys_under "$PHASE.threshold" | tr '\t' '=')" = "$pinned_threshold" ] \
        || finish blocked "round $((round - 1)) changed the $PHASE threshold in .quality-gate.yaml, so the bar this run is measured against is no longer the one it started with"
    fi
    measure "$phase_cmd" "$secs"
    case "$MEASURE_STATUS" in
      timeout) finish exhausted "$MEASURE_DETAIL" ;;
      no-command|no-receipt|invalid|drift) finish blocked "$MEASURE_DETAIL" ;;
    esac
    last_receipt="$WORK_DIR/last.json"
    cp "$MEASURE_FILE" "$last_receipt"

    case "$MEASURE_OUTCOME" in
      not-applicable)
        write_final "$last_receipt" not-applicable "$round" "" \
          "the $PHASE phase found nothing to measure in this diff"
        ;;
      blocked)
        write_final "$last_receipt" blocked "$round" "" \
          "the $PHASE command reported it could not measure"
        ;;
      defect-found)
        write_final "$last_receipt" defect-found "$round" "" \
          "the $PHASE phase reported a real product defect"
        ;;
    esac

    if [ "$MODE" != hardened ]; then
      # Read-only: one measurement, reported and never gated. `pass` is not
      # available here even when the threshold was met, because nothing blocked.
      detail="scores reported, nothing gated (measured: $MEASURE_OUTCOME)"
      write_final "$last_receipt" read-only "$round" \
        "Read-only run: the measurement came back $MEASURE_OUTCOME and nothing was gated." "$detail"
    fi

    if [ "$MEASURE_OUTCOME" = pass ]; then
      write_final "$last_receipt" pass "$round" "" "threshold met in $round round(s)"
    fi

    # Below threshold. Bounds first, so an exhausted phase never spends a turn.
    ids=$(receipt_finding_ids "$last_receipt" || true)
    if [ "$have_prev" -eq 1 ] && [ "$ids" = "$prev_ids" ]; then
      no_progress=$((no_progress + 1))
    else
      no_progress=0
    fi
    prev_ids=$ids
    have_prev=1
    if [ "$no_progress" -ge "$BOUND_NO_PROGRESS" ]; then
      write_final "$last_receipt" stuck "$round" "" \
        "$BOUND_NO_PROGRESS consecutive rounds left the same findings untouched"
    fi
    if [ "$round" -ge "$BOUND_MAX_ITERATIONS" ]; then
      write_final "$last_receipt" exhausted "$round" "" \
        "$BOUND_MAX_ITERATIONS rounds ran out below the threshold"
    fi

    # One bounded agent turn, then the ordinary suite decides whether the round
    # is committed or reverted. A failed round costs budget and nothing else.
    secs=$(remaining_seconds)
    if [ "$secs" -le 0 ]; then
      write_final "$last_receipt" exhausted "$round" "" \
        "the ${BOUND_BUDGET_MINUTES}-minute wall-clock bound ran out after $round round(s)"
    fi
    round_head=$(git -C "$WT" rev-parse HEAD)
    write_turn_prompt "$last_receipt" "$WORK_DIR/turn-prompt.md"
    turn_action=$(agent_turn "$secs" "$WORK_DIR/turn-prompt.md" "$round")
    turn_rc=$(cat "$WORK_DIR/turn.rc" 2>/dev/null || printf '0')
    # 124 is the wall-clock bound doing its job, and the next round reports it
    # as exhausted. Any other failure with no answer is a harness that did not
    # run, which is not evidence about the code.
    if [ -z "$turn_action" ] && [ "$turn_rc" -ne 0 ] && [ "$turn_rc" -ne 124 ]; then
      revert_round "$round_head"
      write_final "$last_receipt" blocked "$round" \
        "The $HARNESS agent turn could not run, so no round of work happened." \
        "the $HARNESS harness ($(harness_version "$HARNESS")) exited $turn_rc with no readable answer, so no agent turn ran"
    fi
    if [ "$turn_action" = defect-found ]; then
      revert_round "$round_head"
      write_final "$last_receipt" defect-found "$round" \
        "A round reported a surviving finding as a real product defect." \
        "a surviving finding was reported as a real product defect, not a missing test"
    fi

    rc=0
    if [ -n "$test_cmd" ]; then
      secs=$(remaining_seconds)
      [ "$secs" -gt 0 ] || secs=1
      bounded_sh "$secs" "$WT" "$test_cmd" >/dev/null 2>&1 || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
      revert_round "$round_head"
    else
      git -C "$WT" add -A >/dev/null 2>&1 || true
      if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
        git -C "$WT" -c user.name='firstmate quality loop' -c user.email='quality@firstmate.invalid' \
          commit --quiet -m "quality($PHASE): round $round" >/dev/null 2>&1 || true
      fi
    fi
    round=$((round + 1))
  done
}

# Writes the phase's final receipt from the last measurement, then finishes.
write_final() {  # <receipt> <outcome> <rounds> <note> <detail>
  local src=$1 outcome=$2 rounds=$3 note=$4 detail=$5 dest err
  dest=$(receipt_path "$PHASE")
  if ! finalize_receipt "$src" "$outcome" "$(elapsed_ms)" "$rounds" "$note" "$WORK_DIR/final.json" \
      "$(cfg_seq "$PHASE.exclude")"; then
    finish blocked "the $PHASE receipt could not be finalized"
  fi
  if ! err=$(validate_receipt "$WORK_DIR/final.json" "$WT" 2>&1); then
    finish blocked "the finalized $PHASE receipt is not valid: ${err#fm-quality-receipt: }"
  fi
  mv -- "$WORK_DIR/final.json" "$dest"
  finish "$outcome" "$detail"
}

case "$CMD" in
  run) cmd_run ;;
  status) cmd_status ;;
  receipt) cmd_receipt ;;
esac
