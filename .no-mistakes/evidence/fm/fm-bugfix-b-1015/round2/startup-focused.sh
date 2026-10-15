#!/usr/bin/env bash
set -u
source <(sed 's@\. "$(dirname "${BASH_SOURCE\[0\]}")/lib.sh"@. "$PWD/tests/lib.sh"@; s@\. "$(dirname "${BASH_SOURCE\[0\]}")/wake-helpers.sh"@. "$PWD/tests/wake-helpers.sh"@; /^test_context_digest_absent_empty_present$/,$d' tests/fm-session-start.test.sh)
test_slow_home_summary_refresh_does_not_hold_session_start
test_endpoint_read_hang_is_bounded_and_reported
test_endpoint_bound_rejects_padded_zero
