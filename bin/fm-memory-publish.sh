#!/usr/bin/env bash
# fm-memory-publish.sh - verify and atomically publish a proposed memory generation.
#
# Usage:
#   fm-memory-publish.sh <generation-or-dir> [options]
#   fm-memory-publish.sh -h | --help
#
# Runs mechanical verification via bin/fm-memory-verify.sh and updates
# data/memory/HEAD atomically only after all checks pass.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/fm-memory-verify.sh" publish "$@"
