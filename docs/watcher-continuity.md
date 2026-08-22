# Watcher continuity

The watcher remains intentionally one-shot: one actionable reason closes one watcher cycle.
Must-work continuity now lives above that process boundary instead of depending on the model remembering a re-arm step.

## Ownership

Pi's `.pi/extensions/fm-primary-pi-watch.ts` and OpenCode's `.opencode/plugins/fm-primary-watch-arm.js` own continuous re-arm after an actionable child close.
Each adapter starts the next arm before delivering the wake prompt, checks current session-lock ownership at launch, preserves one child or scheduled retry at a time, and applies bounded exponential retry after an unexpected or failed close.
A failed follow-up never cancels continuity restoration.
Pi same-process session replacement follows the generation-owner contract in `.pi/extensions/fm-primary-pi-watch.ts`.
Cursor's `.cursor/hooks.json` `stop` hook (`bin/fm-turnend-guard-cursor.sh`) owns routine tokenless re-arm for a Cursor primary by parking that awaited hook on `bin/fm-watch-arm.sh` and returning an actionable close as one follow-up; [`turnend-guard.md`](turnend-guard.md#harness-integrations) owns its loop bounds and supersession baton.
Claude's `.claude/settings.json` Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns routine tokenless re-arm.
The hook fires on every Stop, and an eligible primary with supervision need admits one home-scoped owner that foregrounds `bin/fm-watch-arm.sh` inside the hook-owned process tree.
A numeric session-lock owner that fails the shared `fm_harness_pid_alive` predicate is reclaimed through `bin/fm-lock.sh` before auto-arm state changes, while a live owner, absent lock, or malformed lock keeps the competing hook inert.
The stale-owner claim occurs only after the existing AFK and supervision-need gates pass.
After each non-actionable arm close, the hook rechecks the identity-matched watcher lock and fresh beacon before retrying a bounded number of times.
A cycle-end failure is benign when that live-watcher predicate is true, and the hook suppresses the arm output and continues silently.
Only an exhausted failure with no verified watcher emits one last-resort notice for the continuous failure episode; later consecutive Stop cycles exit 2 to guarantee another Stop-owned retry without repeating the notice until the turn-end guard consumes the attended fail-open.
The Claude turn-end guard owns the monotonic failure progression, one-time attended fail-open, post-alarm continuation suppression, and positive recovery reset described in [`turnend-guard.md`](turnend-guard.md#harness-integrations).
While supervision is still needed and away mode remains inactive, an actionable close wakes the idle session through exit 2.
While away mode (`state/.afk`) is active, the sub-supervisor daemon owns fleet supervision and triage, and primary watcher adapters stand down so wakes and arm processes are not duplicated.

## Session-lock ownership

`bin/fm-session-lock-lib.sh` is the single owner of "does this process belong to the session that holds this home's fleet lock", and of the refusal a session that does not hold it prints.

Identity is answered in three tiers, and the first that applies wins.
`CLAUDE_PID` names the Claude Code session process; `CLAUDE_CODE_SESSION_ID` names the conversation; the harness-ancestry walk answers for every harness that publishes neither.
The two declared values win because a harness exports them identically into every tool shell and every hook process of a session, while the ancestry walk answers a slightly different question at each call site: it climbs to the first harness match and then stops at the first non-harness ancestor, so how deep the caller sits inside the harness's own worker chain decides which pid it reports.
A Claude Code background continuation runs in a detached process tree, where that walk from a hook stops short of the session that took the helm while the walk from an ordinary tool shell can climb past it into an unrelated harness further up the real tree.
`bin/fm-lock.sh` records the conversation in `state/.lock.session` beside the pid in `state/.lock`, replacing or removing it whenever it takes or re-confirms the home as its own, so a continuation of the lock-holding conversation inherits the helm and an unrelated session never can.
Which tier granted ownership is decided before that record is written, and an ancestry grant is the one case that does not write it: such a caller inherits an existing owner's record because the recorded holder happens to sit above it in the real process tree, and renaming the conversation there would lock that owner's own background continuation out of a home it still holds.
Liveness is the only evidence another process has that the home is held at all, so a dead recorded pid reads as a free home fleet-wide, and inheriting the helm by conversation id is what makes a dead pid reachable while a session still holds the home.
`bin/fm-lock.sh` rewrites a dead pid at every acquisition, and `bin/fm-claude-stop-autoarm.sh` - the only caller that fires on an ordinary turn - reclaims through it whenever it finds one, whether or not this session already owns the home.
That reclaim stays behind the away-mode and supervision-need gates by design, so an away home and an idle home keep a dead pid indefinitely and read as free; a dead recorded pid is therefore rarer than before but never impossible, and no predicate may assume it away.

What the two declared tiers recognise is an accidentally inherited identity, not a hostile one.
Both values come from the environment and every descendant of a session inherits them, so they are a correctness guard against a forked continuation being misread as a stranger, never a trust boundary against a process that sets them deliberately.
A worker firstmate launches is such a descendant, so `bin/fm-spawn.sh` clears both from every worker's launch environment, for every runtime, rather than the predicate second-guessing what it reads.

That one verdict now decides both halves of the contract, so no path can enforce a different answer than another.
`bin/fm-claude-stop-autoarm.sh` and `bin/fm-turnend-guard-cursor.sh` use it to decide whether they may arm, and every fleet-mutation entry point - `bin/fm-wake-drain.sh`, `bin/fm-send.sh`, `bin/fm-spawn.sh`, `bin/fm-teardown.sh`, `bin/fm-promote.sh`, `bin/fm-merge-local.sh`, `bin/fm-pr-merge.sh`, and `bin/fm-control.sh` - calls `fm_require_session_lock` before argument validation, so AGENTS.md section 3's read-only rule is enforced where the mutation happens rather than trusted to a banner the session may never have read.
The refusal names the holder and what to do instead.

It refuses only on the full conjunction: a live lock owner, that owner not being this session, and this caller belonging to a harness session of its own.
A missing, stale, or malformed lock is no competing session, and `bin/fm-lock.sh` already turns those into a fresh acquisition.
A caller outside any harness session is no competing session either - that is the parent home reaching into a secondmate's endpoint over ssh, a detached job, or CI, none of which can produce the two-agents-one-home split.

`bin/fm-session-start.sh`'s LOCK section states the verdict in words on its own `HELM:` line, so a reading agent never has to compare pids by hand.
The line reads the acquisition's exit code rather than recomputing ownership, because `bin/fm-lock.sh` owns that decision and exits 0 only after verifying it; the helm line can therefore never contradict the acquisition line above it or the read-only banner below it.
The resolver is consulted only to explain a failed acquisition, where ownership can still resolve to this session while the lock cannot be written at all.
That branch says read-only by instruction rather than as an enforced fact, because the gate refuses only a live foreign owner and there is none here, so nothing would actually stop the session.
Narrowing the gate to acquisition success instead would refuse the parent home reaching into a secondmate's endpoint over ssh, detached jobs, and CI, so the restraint stays with the reading agent and the digest says so plainly.

## Actionable wake ordering

After an actionable Pi or OpenCode child close, the adapter starts and verifies one singleton successor before it delivers the original wake.
It waits at most one readiness timeout per attempt, then sends TERM and waits a bounded retirement confirmation before the next lock-verified exponential retry.
If the unready arm does not retire within that bound, the adapter keeps ownership, starts no overlapping retry, and delivers the typed fallback immediately.
When that retained arm later closes, its actual close is classified as a new supervised event without replaying the earlier fallback.
After the configured retry bound is exhausted, it delivers the original wake with a typed continuity-restoration failure even if every successor arm hung without reporting readiness.
This is deliberate Option B ordering: the fleet is protected before the model handles the wake whenever restoration succeeds, but the model is never left blind when it does not.

Claude's Stop hook starts the successor arm at the next Stop after the handling turn, rather than before notification as Pi and OpenCode do.
The durable wake queue preserves actionable events during the residual active-turn window, and the bounded turn-end guard enforces recovery at Stop when no watcher or auto-arm claim is present.
For every supported arm path, a successor that observes an accepted down stretch emits `check: rearm-resurface` through the ordinary durable handling path before settling into its live wait.
That recovery presentation includes all unacknowledged queue rows, the cursor-folded OPEN DECISIONS set, and still-unread informational status lines, so a still-open decision or a buried `note:` answer reappears even when recovery has no queue row of its own.
The model no longer re-arms after ordinary wakes.
No PreToolUse hook denies fleet commands based on watcher status.
A genuine auto-arm failure describes the automatic mechanism as broken and never directs a routine manual background arm.
Terminal arm-output classification (`started`, `attached`, or `FAILED`) remains defense in depth for the manual recovery path.
Codex retains its bounded foreground checkpoint protocol.
Grok retains its tracked background-task notification protocol.
No adapter starts a replacement with shell `&`.

The turn-end guard remains the final backstop rather than the normal continuity mechanism and cooperates with the auto-arm in its `--claude` mode.

## Recovery episode acknowledgement

A recovery episode is one generation of `state/.watcher-down`, and it is retired only by the generation-bound acknowledgement the drain prints as `WAKE_ACK_REQUIRED`.
Every watcher close and every durable queue append publishes downtime, so a downtime republication of any pending episode reuses its generation instead of minting a new one.
That reuse keeps a watcher close inside the handling window from orphaning the acknowledgement already presented and trapping later arms in repeated recovery presentation.
An acknowledgement carries two separable facts: queue-row consumption is bound to the monotonic `--ack-through` sequence, while only retiring the episode is bound to `--recovery-generation`.
A generation mismatch therefore does not block consumption of rows through that sequence; it is a non-fatal result that names its own remedy - re-drain, then acknowledge the newer episode.
The acknowledgement retires the marker only when no rows remain after sequence-bound consumption.
A concurrently appended wake has a higher sequence, remains queued, and keeps the episode pending for presentation.
Consequently, an empty-queue downtime publication during handling can be retired by the outstanding acknowledgement without a dedicated recovery turn.
An acknowledged episode does not freeze the generation, because the next downtime after it opens an episode of its own.

## Arm-layer cycle contract

`bin/fm-watch-arm.sh` never returns a clean empty success.
An actionable child output returns that reason normally.
A zero/empty child return rechecks the home lock and beacon, attaches to a verified healthy successor when one exists, or resolves the close against the watcher's bounded terminal-delivery ledger.
An attached arm follows verified identity-matched successors and resolves the same way when that chain ends without one, because it holds no handle on the watcher's stdout and cannot read the reason line itself.
Before releasing its singleton lock after printing an actionable reason, the watcher records that reason with its PID and process identity in `state/.watch-deliveries.log`.
A matching PID and identity lets an attached arm report the delivered reason and exit zero even after its durable wake was handled and acknowledged, while an unrelated queue producer or a recycled PID cannot satisfy the match.
Only a cycle with no matching delivery record emits `watcher: FAILED - cycle ended without an actionable reason` and exits nonzero.

The arm layer appends one tab-separated record per observed cycle to `state/.watch-cycle-exits.log`.
Each record includes arm and watcher PIDs, start and end timestamps, exit code and signal, classified reason, beacon age, lock identity before and after close, and successor disposition.
The file is size-capped through `FM_WATCH_CYCLE_LOG_MAX_BYTES` and `FM_WATCH_CYCLE_LOG_KEEP_LINES`.
`state/.watch-triage.log` remains only the watcher's bounded absorbed-wake debug log and carries no lifecycle semantics.

The default 300-second grace is unchanged.
Only the watcher process touches `state/.last-watcher-beat`; no helper process can make a wedged watcher appear healthy.

## Regression coverage

`tests/fm-pi-watch-extension.test.sh` checks Pi's first-cycle-or-explicit-repair tool metadata and ownership-based redundant-call no-ops, then simulates actionable and empty child closes against the actual Pi and OpenCode close handlers, blocks prompt delivery to prove the successor launches first, verifies single-flight behavior, changes the session lock before close to prove ownership is rechecked, and hangs each successor arm to prove bounded fallback delivery includes the typed restoration failure.
The same suite covers away-mode wake suppression and arm inhibition, ordinary same-process session replacement for `/new`, `/resume`, and `/fork`, same-instance shutdown-plus-start, stale prior-generation callbacks, repeated transitions with exactly one live cycle, disappearance of the shutting-down refusal after a valid replacement activates, and terminal quit still refusing late rearm.
`tests/fm-watch-arm.test.sh` covers durable queue replay, real remote parent-replies ingestion into the authoritative status log, decision-only OPEN DECISIONS recovery, interrupted handling replay, generation-bound acknowledgement, a persistent live successor after recovery, a watcher close inside the handling window that must leave the printed acknowledgement valid, and the self-healing moved-generation acknowledgement that consumes its handled rows and names its remedy.
`tests/fm-watcher-lock.test.sh` covers verified-successor attach, recovery publication before stale-lock removal, the typed self-eviction failure, bounded and successor-linked lifecycle rows, and a SIGSTOP counterfactual that distinguishes a live PID from a stale beacon before classifying termination.
`tests/fm-subagent-pretool-check.test.sh` proves Claude retains only the non-status Bash seatbelts.
`tests/fm-claude-stop-autoarm.test.sh` covers the auto-arm's scope, stale and live session owners, unchanged AFK and need boundaries, single-flight, bounded failure retries, benign live-watcher cycle ends, one-notice failure episodes, and exit-2 translation.
`FM_CLAUDE_LIVE_E2E=1 tests/fm-claude-stop-autoarm-live-e2e.test.sh` starts with the reproduced stale-lock state, runs session start first, completes two tokenless cycles, and checks the competing-live-owner negative control.
`tests/fm-turnend-guard.test.sh` covers the cooperative `--claude` guard, including monotonic failed-epoch progression, the integrated bounded fail-open, post-alarm continuation suppression, and positive recovery reset.
`tests/fm-session-lock-ownership.test.sh` drives real competing live processes against real entry points: every mutating path refusing a non-owning session, the holder and a background continuation of its conversation passing untouched, an unrelated conversation and a non-owning session being refused, a caller outside any harness session not being treated as a competitor, the lock path's ownership wording, the auto-arm's silent record-free decline, and the turn-end guard reporting that decline once before standing down.
That suite runs with no harness at all, so the two declared values it drives are pinned by `tests/fm-session-identity-live-e2e.test.sh`, the opt-in guard that proves them against the real installed Claude Code; [`verification/runtime-backends.md`](verification/runtime-backends.md#session-identity) carries its dated result and names it as the command that refreshes it.

## Active limits and verification

The goal is continuity without a Pi or OpenCode model-memory re-arm step.
No zero-latency guarantee is claimed because lock verification, watcher startup, and bounded retry delays remain deliberate safety work.
OpenCode support targets persistent TUI sessions rather than headless `opencode run`.
Claude depends on the Stop `asyncRewake` rewake, Cursor depends on its awaited stop-hook park, Grok retains native background-completion notifications, and Codex retains bounded foreground checkpoints.

[`verification/supervision.md`](verification/supervision.md#watcher-continuity) records the current five-harness live evidence, the 2026-07-24 Stop-owned Claude auto-arm results, and exact opt-in commands.
