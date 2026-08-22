#!/usr/bin/env bash
# fm-quality-receipt.sh - validate a quality-gate receipt against the D2 schema.
#
# The committed schema at docs/quality-receipt.schema.json is the owner of the
# JSON shape. This script is the check. docs/quality-gate.md owns the rationale,
# the D1 bounds including budget_minutes, and the verify-envelope decision.
#
# Usage:
#   fm-quality-receipt.sh validate [--check-head <git-dir>] [<file>|-]
#   fm-quality-receipt.sh schema
#   fm-quality-receipt.sh -h | --help
#
# validate reads one JSON document from <file> or stdin.
# Exit 0 on a valid receipt, 1 on an invalid one, 2 on usage or tool errors.
#
# Post-schema rules, because JSON Schema cannot state them:
#   - finding ids are unique inside each findings array
#   - each verify child's base_sha and head_sha equal the envelope's
# --check-head <git-dir> then requires head_sha to resolve to that tree's HEAD.
# FM_QUALITY_RECEIPT_SCHEMA overrides the schema path (test seam).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SCHEMA="${FM_QUALITY_RECEIPT_SCHEMA:-$FM_ROOT/docs/quality-receipt.schema.json}"
SELF="$SCRIPT_DIR/fm-quality-receipt.sh"

fm_quality_receipt_usage() {
  sed -n '2,21{s/^# \{0,1\}//;p;}' "$SELF"
}

if ! command -v python3 >/dev/null 2>&1; then
  printf 'fm-quality-receipt: python3 is required\n' >&2
  exit 2
fi

CMD=""
CHECK_HEAD=""
FILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      fm_quality_receipt_usage
      exit 0
      ;;
    schema)
      [ -z "$CMD" ] || {
        printf 'fm-quality-receipt: unexpected extra command %s\n' "$1" >&2
        exit 2
      }
      CMD=schema
      shift
      ;;
    validate)
      [ -z "$CMD" ] || {
        printf 'fm-quality-receipt: unexpected extra command %s\n' "$1" >&2
        exit 2
      }
      CMD=validate
      shift
      ;;
    --check-head)
      [ "$#" -ge 2 ] || {
        printf 'fm-quality-receipt: --check-head requires a git dir\n' >&2
        exit 2
      }
      CHECK_HEAD=$2
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -)
      [ -z "$FILE" ] || {
        printf 'fm-quality-receipt: unexpected extra argument %s\n' "$1" >&2
        exit 2
      }
      FILE=-
      shift
      ;;
    -*)
      printf 'fm-quality-receipt: unknown option %s\n' "$1" >&2
      exit 2
      ;;
    *)
      [ -z "$FILE" ] || {
        printf 'fm-quality-receipt: unexpected extra argument %s\n' "$1" >&2
        exit 2
      }
      FILE=$1
      shift
      ;;
  esac
done

[ -z "$CMD" ] && {
  fm_quality_receipt_usage >&2
  exit 2
}

if [ "$CMD" = schema ]; then
  [ -z "$CHECK_HEAD" ] && [ -z "$FILE" ] || {
    printf 'fm-quality-receipt: schema takes no extra arguments\n' >&2
    exit 2
  }
  [ -f "$SCHEMA" ] || {
    printf 'fm-quality-receipt: schema file missing: %s\n' "$SCHEMA" >&2
    exit 2
  }
  cat "$SCHEMA"
  exit 0
fi

[ "$CMD" = validate ] || {
  printf 'fm-quality-receipt: unknown command %s\n' "$CMD" >&2
  exit 2
}

[ -f "$SCHEMA" ] || {
  printf 'fm-quality-receipt: schema file missing: %s\n' "$SCHEMA" >&2
  exit 2
}

[ -n "$FILE" ] || FILE=-

exec python3 - "$SCHEMA" "$CHECK_HEAD" "$FILE" <<'PY'
from __future__ import annotations

import json
import re
import subprocess
import sys


class SchemaError(Exception):
    def __init__(self, path: str, message: str) -> None:
        super().__init__(f"{path}: {message}")
        self.path = path
        self.message = message


def is_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def is_number(value: object) -> bool:
    return is_int(value) or isinstance(value, float)


def unescape(part: str) -> str:
    return part.replace("~1", "/").replace("~0", "~")


def resolve(ref: str, root: dict) -> dict:
    if not ref.startswith("#/"):
        raise SchemaError("$", f"unsupported $ref {ref}")
    cur: object = root
    for part in ref[2:].split("/"):
        if not isinstance(cur, dict):
            raise SchemaError("$", f"broken $ref {ref}")
        key = unescape(part)
        if key not in cur:
            raise SchemaError("$", f"broken $ref {ref}")
        cur = cur[key]
    if not isinstance(cur, dict) and not isinstance(cur, bool):
        raise SchemaError("$", f"broken $ref {ref}")
    return cur  # type: ignore[return-value]


def matches(instance: object, schema: object, root: dict) -> bool:
    try:
        validate(instance, schema, root, "$")
    except SchemaError:
        return False
    return True


def validate(instance: object, schema: object, root: dict, path: str) -> None:
    if schema is True:
        return
    if schema is False:
        raise SchemaError(path, "not allowed")
    if not isinstance(schema, dict):
        raise SchemaError(path, "invalid schema")
    if "$ref" in schema:
        validate(instance, resolve(schema["$ref"], root), root, path)
        return
    if "allOf" in schema:
        for sub in schema["allOf"]:
            validate(instance, sub, root, path)
    if "if" in schema:
        if matches(instance, schema["if"], root):
            if "then" in schema:
                validate(instance, schema["then"], root, path)
        elif "else" in schema:
            validate(instance, schema["else"], root, path)
    if "not" in schema:
        if matches(instance, schema["not"], root):
            raise SchemaError(path, "matched a forbidden schema")
    expected_type = schema.get("type")
    if expected_type == "object":
        if not isinstance(instance, dict):
            raise SchemaError(path, "expected object")
    elif expected_type == "array":
        if not isinstance(instance, list):
            raise SchemaError(path, "expected array")
    elif expected_type == "string":
        if not isinstance(instance, str):
            raise SchemaError(path, "expected string")
    elif expected_type == "integer":
        if not is_int(instance):
            raise SchemaError(path, "expected integer")
    elif expected_type == "number":
        if not is_number(instance):
            raise SchemaError(path, "expected number")
    elif expected_type is not None:
        raise SchemaError(path, f"unsupported type {expected_type}")
    if "const" in schema and instance != schema["const"]:
        raise SchemaError(path, f"expected {schema['const']!r}")
    if "enum" in schema and instance not in schema["enum"]:
        raise SchemaError(path, f"expected one of {schema['enum']!r}")
    if "pattern" in schema:
        if not isinstance(instance, str) or re.search(schema["pattern"], instance) is None:
            raise SchemaError(path, f"expected to match {schema['pattern']}")
    if "minLength" in schema:
        if not isinstance(instance, str) or len(instance) < schema["minLength"]:
            raise SchemaError(path, f"shorter than {schema['minLength']}")
    if "minimum" in schema and is_number(instance) and instance < schema["minimum"]:
        raise SchemaError(path, f"below minimum {schema['minimum']}")
    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            raise SchemaError(path, f"fewer than {schema['minItems']} items")
        item_schema = schema.get("items")
        if item_schema is not None:
            for i, item in enumerate(instance):
                validate(item, item_schema, root, f"{path}/{i}")
    if isinstance(instance, dict):
        if "minProperties" in schema and len(instance) < schema["minProperties"]:
            raise SchemaError(path, f"fewer than {schema['minProperties']} properties")
        props = schema.get("properties", {})
        required = schema.get("required", [])
        for key in required:
            if key not in instance:
                raise SchemaError(f"{path}/{key}", "required")
        additional = schema.get("additionalProperties", True)
        for key, value in instance.items():
            child = f"{path}/{key}"
            if key in props:
                validate(value, props[key], root, child)
            elif additional is False:
                raise SchemaError(child, "additional property")
            elif additional is not True:
                validate(value, additional, root, child)


def unique_finding_ids(node: object, path: str) -> None:
    if isinstance(node, list):
        for i, item in enumerate(node):
            unique_finding_ids(item, f"{path}/{i}")
        return
    if not isinstance(node, dict):
        return
    findings = node.get("findings")
    if isinstance(findings, list):
        seen: dict[str, int] = {}
        for i, item in enumerate(findings):
            if not isinstance(item, dict):
                continue
            finding_id = item.get("id")
            if not isinstance(finding_id, str):
                continue
            if finding_id in seen:
                raise SchemaError(
                    f"{path}/findings/{i}/id",
                    f"duplicate id {finding_id!r} (also {path}/findings/{seen[finding_id]}/id)",
                )
            seen[finding_id] = i
    for key, value in node.items():
        unique_finding_ids(value, f"{path}/{key}")


def verify_child_shas(receipt: object) -> None:
    if not isinstance(receipt, dict):
        return
    if receipt.get("phase") != "verify":
        return
    phases = receipt.get("phases")
    if not isinstance(phases, list):
        return
    for i, child in enumerate(phases):
        if not isinstance(child, dict):
            continue
        for field in ("base_sha", "head_sha"):
            if child.get(field) != receipt.get(field):
                raise SchemaError(
                    f"$/phases/{i}/{field}",
                    f"must equal envelope {field}",
                )


def git_rev_parse(git_dir: str, *args: str) -> str:
    proc = subprocess.run(
        ["git", "-C", git_dir, "rev-parse", *args],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if proc.returncode != 0:
        detail = proc.stderr.strip() or "git rev-parse failed"
        raise SchemaError("$/head_sha", detail)
    return proc.stdout.strip()


def check_head(receipt: object, git_dir: str) -> None:
    if not isinstance(receipt, dict):
        raise SchemaError("$", "expected object")
    head_sha = receipt.get("head_sha")
    if not isinstance(head_sha, str):
        raise SchemaError("$/head_sha", "required")
    actual = git_rev_parse(git_dir, "HEAD")
    try:
        resolved = git_rev_parse(git_dir, "--verify", f"{head_sha}^{{commit}}")
    except SchemaError as exc:
        raise SchemaError("$/head_sha", f"does not resolve in {git_dir}: {exc.message}") from exc
    if resolved != actual:
        raise SchemaError(
            "$/head_sha",
            f"{resolved} is not HEAD {actual}",
        )


def main() -> int:
    schema_path, check_head_dir, source = sys.argv[1], sys.argv[2], sys.argv[3]
    try:
        with open(schema_path, encoding="utf-8") as handle:
            schema = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"fm-quality-receipt: cannot read schema: {exc}", file=sys.stderr)
        return 2
    try:
        if source == "-":
            raw = sys.stdin.read()
        else:
            with open(source, encoding="utf-8") as handle:
                raw = handle.read()
        receipt = json.loads(raw)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"fm-quality-receipt: cannot read receipt: {exc}", file=sys.stderr)
        return 1
    try:
        validate(receipt, schema, schema, "$")
        unique_finding_ids(receipt, "$")
        verify_child_shas(receipt)
        if check_head_dir:
            check_head(receipt, check_head_dir)
    except SchemaError as exc:
        print(f"fm-quality-receipt: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
PY
