#!/usr/bin/env bash
set -u
source <(sed -n '1,165p' tests/fm-live-lab.test.sh | sed 's@\. "$(dirname "${BASH_SOURCE\[0\]}")/fixtures.sh"@. "$PWD/tests/fixtures.sh"@')
if [ "${1:-}" = base ]; then LIVE_LAB="$ROOT/.test-phase/base-bin/fm-live-lab.sh"; fi
source <(sed -n '462,487p' tests/fm-live-lab.test.sh)
