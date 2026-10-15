#!/usr/bin/env bash
set -u
source <(sed 's@\. "$(dirname "${BASH_SOURCE\[0\]}")/lib.sh"@. "$PWD/tests/lib.sh"@; /^test_inert_in_child_worktree$/,$d' tests/fm-claude-stop-autoarm.test.sh)
test_dangling_owner_links_are_reclaimed_and_rearm
test_dangling_reapers_preserve_a_live_successor
test_dead_dangling_reaper_claim_keeps_its_election_until_unlink
test_arming_claim_with_fresh_beacon_is_never_reclaimed
