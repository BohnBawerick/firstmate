# Primary turn-end supervision guard

This doc explains the check that stops a primary Firstmate session from ending a turn while its work has no live supervision, and how each harness enforces that check at its turn boundary.
It is for operators working out why a turn end was blocked or followed up, and for anyone changing a harness turn-end hook.

This is the authoritative current contract for the "no turn ends blind" primary backstop referenced from AGENTS.md section 8.
The predicate lives in `bin/fm-turnend-guard.sh`.
Primary scope lives in `bin/fm-primary-scope-lib.sh`, shared with the native session-start adapters in [`sessionstart-nudge.md`](sessionstart-nudge.md).
Harness hook files adapt each enabled primary harness integration's turn-end mechanism to that shared predicate.

Related PreToolUse guards deny unsafe commands before execution rather than detecting a blind turn end afterward.
Their separate owners are [`arm-pretool-check.md`](arm-pretool-check.md), [`cd-guard.md`](cd-guard.md), and [`subagent-guard.md`](subagent-guard.md).
Do not infer this guard's scope, loop safety, or compatibility tradeoffs for those guards.

## Find a topic

| Question | Start here |
| --- | --- |
| What the guard enforces | [Current invariant](#current-invariant) |
| Which sessions are in scope and what counts as supervision need | [Primary scope](#primary-scope) and [supervision need](#supervision-need) |
| How the turn-end check and the mid-turn pull warning judge watcher health | [Strict watcher check at the turn boundary](#strict-watcher-check-at-the-turn-boundary) and [pull-warning verdict by supervision model](#pull-warning-verdict-by-supervision-model) |
| Away and quiet mode | [Away and quiet mode daemon ownership](#away-and-quiet-mode-daemon-ownership) |
| How long a beacon stays fresh | [Guard grace and the poll cadence](#guard-grace-and-the-poll-cadence) |
| How each harness blocks or follows up | [Harness integrations](#harness-integrations) |
| Claude's Stop auto-arm cooperation, block budget, and fail-open | [Claude cooperative mode](#claude-cooperative-mode) |
| Cursor's parked hook | [Cursor park](#cursor-park) |
| Known gaps | [Compatibility limits](#compatibility-limits) |
| Tests and live evidence | [Regression coverage](#regression-coverage) |

## Current invariant

`bin/fm-guard.sh` is a pull-based warning that runs only when another supervision command invokes it.
The turn-end guard closes the remaining gap at the primary's own turn boundary.

The guard acts at that boundary when both of these hold:

- Work, a process-event source, a registered custom check, or Relay polling needs supervision.
- No identity-matched watcher has a fresh beacon.

The beacon is `state/.last-watcher-beat`, which `bin/fm-watch.sh` touches every cycle, as [Guard grace and the poll cadence](#guard-grace-and-the-poll-cadence) describes.
When the guard acts, the harness integration must do one of two things:

- Block the turn end.
- Force one bounded follow-up that uses the recovery instruction from the emitted session-start protocol.

Both guards use the model-aware supervision vocabulary described below.
Outside away mode the turn-end guard's model still resolves to the PID-strict watcher predicate.

The guard remains a backstop.
[`watcher-continuity.md`](watcher-continuity.md) owns normal continuity.

## Guard predicates

The turn-end guard checks primary scope first, then supervision need, then watcher health.
The mid-turn pull warning in `bin/fm-guard.sh` judges watcher health differently, as described under [pull-warning verdict by supervision model](#pull-warning-verdict-by-supervision-model).

### Primary scope

The guard first calls the shared primary scope.
A secondmate home runs its own primary Firstmate session, so a genuine `.fm-secondmate-home` marker includes it whether the home is a linked worktree or plain clone.
The marker must meet both of these conditions:

- It is a regular non-symlink file.
- Its whitespace-stripped first line is a non-empty identifier containing only letters, digits, dots, underscores, and dashes.

An unmarked checkout or invalid marker falls through to the git-dir check.
That check keeps crewmate and scout linked worktrees inert because their git dir differs from their git common dir.
It also requires `AGENTS.md`, `bin/`, and the effective state directory.

### Supervision need

For an in-scope primary, the guard counts in-flight work from `state/*.meta`.
These sources also count toward supervision need:

- Registered `state/procevent/*.source` records require supervision even though they have no task metadata.
- Every mode treats `state/x-watch.check.sh` as supervision need, so Relay polling remains guarded without an in-flight task.
- A custom check registered with `bin/fm-check-register.sh` counts the same way, so an operator's home-level poll keeps running after the last task is torn down.

The default cross-harness mode exits silently with no supervision need.

### Strict watcher check at the turn boundary

Otherwise the guard calls `fm_turnend_supervision_healthy <state-dir> <watch-path> [grace-seconds] [home]` from `bin/fm-wake-lib.sh`.
Outside away mode that resolves to `fm_watcher_healthy`, the same PID-strict identity-matched lock and fresh-beacon check used by `bin/fm-watch-arm.sh`.
Under that check:

- A stale beacon blocks even when a watcher pid is live.
- A fresh leftover beacon blocks when the lock is missing, dead, or identity-mismatched.

The turn-end guard needs that strict check because it fires at the turn boundary.
At that boundary the auto-arm is bringing a fresh watcher up for the upcoming idle period.
The guard cooperates with that arm rather than trusting a beacon left by the cycle that just ended.

### Away and quiet mode daemon ownership

Away mode is the one model whose healthy shape differs at that boundary.
While `state/.afk` exists the away daemon owns supervision for every primary harness and runs the watcher as its own child, which exits on each wake so the daemon can handle it and is restarted afterwards, so between cycles the singleton lock is genuinely unheld by design and the PID-strict check would report a perfectly supervised fleet as blind.
Under that model the guard tests the daemon instead, through `fm_away_daemon_healthy`: this home's `state/.supervise-daemon.lock` must be held by a live process whose identity matches the `pid-identity` the daemon recorded there at startup, so a stale pid file or a recycled pid is a mismatch, and the daemon's loop must still be turning.
A lock written by an older daemon that recorded no identity falls back to matching the process command.
The turning-loop evidence is the freshest of the daemon's own housekeeping tick (`state/.subsuper-last-housekeep`), the beat of the watcher child it runs (`state/.last-watcher-beat`), and its startup stamp (`state/.supervise-daemon.pid`), which covers the window before a just-started daemon's first tick.
Taking the freshest of the three is what keeps the check quiet through a normal cycle, because the watcher is deliberately down while a wake is handled and housekeeping is skipped while the daemon backs off.
`FM_AWAY_TICK_GRACE` bounds that freshness and defaults to 180 seconds, taken from the daemon's own cadence rather than guessed: its loop runs housekeeping every `FM_HOUSEKEEPING_TICK` seconds (default 15) and its longest healthy quiet stretch is the crash-spin backoff `FM_CRASH_BACKOFF` (default 60) plus the following housekeeping gate, about 75 seconds.
A home that raises either daemon tunable far above its default must raise `FM_AWAY_TICK_GRACE` with it; the failure direction is a loud false alarm, never silence.
A dead, exited, recycled-pid, or wedged daemon therefore still blocks the turn end, with a banner that names the daemon and distinguishes "no live daemon" from "alive but stopped ticking" instead of telling the session to arm a watcher.
The Stop-owned auto-arm stands down entirely while `state/.afk` exists, so under away mode `--claude` blocks directly rather than waiting for a claim that can never come or spending a bounded continuation.
`bin/fm-afk-start.sh`'s already-running check calls the same `fm_away_daemon_lock_alive`, so entering away mode and guarding it cannot disagree about whether a daemon is live.
Away mode outranks an explicit `FM_SUPERVISION_MODEL` harness pin, because it is a runtime state of the home rather than a harness fact, and `bin/fm-spawn.sh` bakes such a pin into every secondmate launch.

### Foreign session-lock owner

When an active home instead has a live session lock held by a verified harness that the current session does not own, the Claude guard emits a read-only ownership diagnostic and allows the turn to end safely.

Ownership is the shared `fm_session_lock_owned_by_self` verdict in `bin/fm-session-lock-lib.sh`.
The current session owns the lock when either of these holds:

- The recorded pid is a member of the current session's contiguous harness ancestry.
- The trusted Claude session id recorded beside the lock in `state/.lock-session` matches this hook's own environment while the recorded pid is still a live harness.

That second signal keeps a background Claude session owning its own lock after the transient helper chain between its hooks and its recorded owner is recycled.
The library's header owns the trust gate (`CLAUDE_PID` must be a Claude-shaped member of the current run).
`bin/fm-lock.sh` owns the sidecar and the line-1 anchor it records for such a session.

A Claude session that does not own the lock cannot arm or repair the home without stealing the live owner's lock, so blocking it would create an unbounded loop.
The lock-owning session remains responsible for restoring supervision.

The exception has these limits:

- Malformed, absent, dead, or ancestry-uncertain lock records do not satisfy this Claude-specific exception and retain the ordinary guard behavior.
- A missing or mismatched sidecar or an untrusted id adds nothing to the verdict, so a live owner outside the ancestry still takes this exit exactly as before.

### Pull-warning verdict by supervision model

`bin/fm-guard.sh`, the pull warning, instead uses the model-aware `fm_watcher_supervision_verdict` from `bin/fm-wake-lib.sh`.
It needs a different verdict because it fires mid-turn, when the auto-arm model runs no watcher at all.
The verdict depends on the supervision model.
It answers the away model the same way the turn-end guard does, because away mode replaces whatever the primary harness would otherwise run.

#### Claude Stop auto-arm model

Under the Claude Stop auto-arm model a beacon fresh within grace is healthy even with no live watcher process.
A stale beacon is still healthy while `fm_autoarm_midturn_healthy` in `bin/fm-wake-lib.sh` proves a Claude rewake explains the mid-turn gap.
That proof requires both of these:

- The rewake is bound to the current recovery generation and live session-lock owner.
- No later watcher beacon or exhausted-failure marker supersedes it.

The tolerance holds because that session's turn-end will re-arm.
Without that proof a stale or absent beacon is a genuine lapse and alarms.

#### Extension model

Under the extension model (Pi, pi-signed, and omp) a live identity-matched watcher is the ordinary healthy state.
A genuinely unheld lock with a beacon fresh within grace is also healthy while a live Pi or omp session provably owns continuity.
That hand-off is benign because `.pi/extensions/fm-primary-pi-watch.ts` and `.omp/extensions/fm-primary-omp-watch.ts` tear the watcher down on every actionable wake and spawn the replacement themselves.

A lock is genuinely unheld only in one of these cases:

- The lock directory or its symlinked owner directory is absent.
- The existing lock records no pid at all.

Any lock with a recorded pid remains down when its pid, home, watcher path, or process identity fails the strict watcher health check.

That ownership proof is `fm_extension_owns_supervision` in `bin/fm-wake-lib.sh`.
It accepts either the Pi pair (`fm_pi_extension_owns_supervision`) or the omp pair (`fm_omp_extension_owns_supervision`).
The proof requires all of these:

- Both primary extensions of one family must be recorded in their state markers at their current on-disk builds by the process named in `state/.lock`.
- That process must still be alive.
- Pi's watcher marker must additionally name an active generation rather than a retiring handoff.

omp never inherits the Pi tolerance because its proof is keyed on its own two files and markers.
Requiring the turn-end guard extension as well as the watch extension is deliberate, because a home without that structural backstop has no benign hand-off to tolerate.

Without that proof an unheld lock alarms exactly as it did before.
An unloaded, version-drifted, or exited Pi or omp session is therefore loud immediately.
A cycle the extension never restores is loud once the beacon passes grace.

#### Persistent-watcher harnesses

Under every persistent-watcher harness a live identity-matched watcher with a fresh beacon is still required, so the pull guard keeps the same strict semantics there.
Its banner names the true failing condition, either a stopped away daemon, a missing live watcher process, or a genuinely stale beacon with its real age.
It keys the once-per-episode dedup on that condition rather than the beacon mtime.

### State directory, grace, and missing input

- `FM_STATE_OVERRIDE` wins over `FM_HOME/state`, and `FM_HOME` wins over repository-root `state/`.
- `FM_GUARD_GRACE` controls beacon freshness and defaults to 300 seconds, and `FM_AWAY_TICK_GRACE` controls away-daemon tick freshness and defaults to 180 seconds.
- If `jq` is missing or hook stdin is empty, the guard exits 0 because it cannot safely read loop-guard fields.

### Guard grace and the poll cadence

`bin/fm-watch.sh` touches `state/.last-watcher-beat` once per cycle, immediately before its terminal wait (`event_wait_or_sleep`) as well as at the top of the next cycle.
A healthy watcher's beacon can therefore legitimately age up to `FM_POLL` seconds between touches.

A fixed 300-second grace default stops correctly bounding staleness once a home's `FM_POLL` reaches or exceeds it.
A perfectly healthy watcher mid-wait would then read stale at the edge of every full poll cycle by definition.
That is exactly what a long-poll home (`FM_POLL=300`) hit against the Claude Stop-hook auto-arm (`bin/fm-claude-stop-autoarm.sh`).

Two readers derive their default grace from the configured poll instead of a bare constant:

- That hook.
- `bin/fm-watch.sh`'s own pre-acquisition staleness check (the "lock held by live pid but heartbeat is stale" refusal).

Both use `max(300, FM_POLL + 60)`.
The default never drops below the historical 300-second floor for the common short-poll case, but grows with the poll cadence once that cadence would otherwise outrun it.
`fm_poll_derived_grace` in `bin/fm-wake-lib.sh` is the single owner of that formula.

That refusal has a ceiling.
Once the live holder's beacon is stale past `FM_WATCHER_STALL_BOUND` (default three times the grace), the re-arm takes these steps:

1. It re-verifies the holder against the lock's recorded identity.
2. It retires the holder with TERM.
3. It starts in the holder's place.

A watcher wedged mid-cycle can therefore no longer refuse every replacement indefinitely.
`bin/fm-watch.sh`'s header owns the exact wording and the survives-TERM fallback.
Below that bound a stale beacon alone does not end an attached arm's watch of a live, identity-matched holder; a changed lock can end it sooner.
At the bound the arm reports a typed stalled-holder failure so its owner's retry can replace the holder.
`fm_watcher_stall_bound` in `bin/fm-wake-lib.sh` owns the shared derivation; `bin/fm-watch-arm.sh`'s header owns the exact attached-arm close behavior.

The auto-arm hook additionally exports its resolved `FM_GUARD_GRACE` when it forks `bin/fm-watch-arm.sh`.
The arm wrapper and the watcher it may start then judge staleness with the exact same value the hook just judged it with, whether that value came from an operator override or the poll-derived default.

The turn-end guard uses the daemon tick contract above while the legacy daemon flag exists.

Every other direct `FM_GUARD_GRACE` reader still falls back to the bare 300-second default unless `FM_GUARD_GRACE` is set explicitly in the environment.
Those readers are:

- `bin/fm-guard.sh`.
- The strict-watcher checks in `bin/fm-turnend-guard.sh` and its harness-specific wrappers.
- `bin/fm-wake-lib.sh`.

## Harness integrations

Each enabled primary harness adapts its own turn-end mechanism to the shared guard.

| Harness | Turn-end hook | How it enforces the guard |
| --- | --- | --- |
| Claude | Two `Stop` hooks in `.claude/settings.json` | Blocks with exit status 2, cooperating with the Stop auto-arm |
| Codex | `Stop` hook in `.codex/hooks.json` | Blocks with exit status 2 |
| OpenCode | `session.idle` in `.opencode/plugins/fm-primary-turnend-guard.js` | Passive callback that schedules one follow-up |
| Pi | `agent_settled` in `.pi/extensions/fm-primary-turnend-guard.ts` | Passive callback that schedules one follow-up |
| omp | `session_stop` in `.omp/extensions/fm-primary-turnend-guard.ts` | Blocking hook that compels one continuation |
| Cursor | `stop` hook in `.cursor/hooks.json` | Cannot block, so it parks and returns at most one follow-up |
| Grok | `Stop` hook in `.grok/hooks/fm-primary-turnend-guard.json` | Native blocking, or one legacy `grok --resume` fallback |

The registrations in detail:

- Claude registers two `Stop` hooks in `.claude/settings.json`, both anchored through `CLAUDE_PROJECT_DIR`: `bin/fm-turnend-guard.sh --claude`, and `bin/fm-claude-stop-autoarm.sh` with `asyncRewake: true` and `timeout: 28800`.
- Codex registers a `Stop` hook in `.codex/hooks.json`, anchors the executable to the hook process working directory, verifies a Firstmate-shaped hook-bearing root, and passes the original payload to the shared guard.
- OpenCode listens for `session.idle` in `.opencode/plugins/fm-primary-turnend-guard.js`, lets the watcher coordinator act first, and calls `client.session.promptAsync` once when the guard returns 2.
- Pi listens for `agent_settled` in `.pi/extensions/fm-primary-turnend-guard.ts`, runs once per logical agent run, and calls `pi.sendUserMessage(..., { deliverAs: "followUp" })` once when the guard returns 2.
- omp answers its blocking `session_stop` hook in `.omp/extensions/fm-primary-turnend-guard.ts`, passing the payload's own `stop_hook_active` to the shared guard.
  When the guard returns 2, it returns `{ continue: true, additionalContext }`, so the continuation is compelled rather than requested.
  The continuation's stop carries `stop_hook_active: true`, which bounds it to one per turn, and omp's own cap of eight consecutive continuations is the second backstop.
  `session_stop` never fires for an interrupted turn or a task session, so those boundaries are deliberately unguarded.
- Cursor registers a `stop` hook in `.cursor/hooks.json` and delegates the whole turn boundary to `bin/fm-turnend-guard-cursor.sh`, the park described below.
  Cursor also loads `<project>/.claude/settings.json`, so every tracked Claude-shaped entrypoint whose event Cursor covers stands down on a Cursor-delivered payload through `bin/fm-hook-host-lib.sh`.
  That predicate reads the delivered payload's own `cursor_version`, never the environment.
  Cursor exports `CURSOR_INVOKED_AS`, `CURSOR_PROJECT_DIR`, and `CURSOR_VERSION` into every child process, so an environment guard would also disable the hooks of a Claude session started by hand from a Cursor pane, which is the hazard the `GROK_SESSION_ID` exclusion below records.
  The guarded set is the `SessionStart` entry, the two `PreToolUse` Bash entries, and both `Stop` entries.
  Cursor 2026.08.11-e8db854 does not fire the Claude-shaped `Stop` entry at all, but it is guarded anyway because Cursor has no `asyncRewake`.
  If a later build did fire it, `bin/fm-claude-stop-autoarm.sh` would run synchronously inside Cursor's stop step and hold that turn open for its declared multi-hour timeout, exactly the wedge grok 1.0.0 produced.
- Grok registers a `Stop` hook in `.grok/hooks/fm-primary-turnend-guard.json` and delegates capability selection to `bin/fm-turnend-guard-grok.sh`.
  The tracked Claude Stop entries are inert when `GROK_AGENT` or `GROK_HOOK_EVENT` is present, so Grok's Claude-compatible settings loading cannot create a second continuation path.
  Both markers are required because Grok does not inject the same variables into every process kind.
  grok 0.2.73 set `GROK_AGENT` for child and tool processes, while grok 1.0.0 hook processes carry `GROK_HOOK_EVENT`, `GROK_HOOK_NAME`, `GROK_SESSION_ID`, and `GROK_WORKSPACE_ROOT` but no `GROK_AGENT`.
  A guard keyed on `GROK_AGENT` alone therefore stopped firing on grok 1.0.0, and the resulting Claude-only auto-arm ran synchronously under Grok.
  Grok has no `asyncRewake`, so it waited on the foregrounded watcher for the declared 28800-second timeout and the Grok turn never ended.
  Do NOT widen this guard to `GROK_SESSION_ID`: Grok injects that into every child process, so it can survive into a Claude session that Grok launched and would silently disable Claude's own continuity.
  The same marker guard carries every tracked `.claude/settings.json` entry whose event Grok already covers through its own `.grok/hooks/` registration, which is both `Stop` entries, the `SessionStart` entry, and the two `PreToolUse` Bash entries.
  `bin/fm-subagent-pretool-check.sh` is the one deliberate unguarded exception because no Grok registration covers the subagent-spawn event, recorded in [`subagent-guard.md`](subagent-guard.md) "Known residual gap".
  `tests/fm-turnend-guard.test.sh` pins that inventory so neither the guarded set nor the exception can change silently.
- pi-code, Pi's Claude-hook compatibility extension, also loads `<project>/.claude/settings.json` and has no `asyncRewake`, so it awaits every Stop hook it delivers.
  `bin/fm-claude-stop-autoarm.sh` therefore stands down on a pi-code-delivered payload.
  Otherwise its foreground arm would run synchronously and hold Pi's turn open for the declared multi-hour timeout, exactly the wedge Cursor and grok 1.0.0 would produce (issue #3343).
  Pi's own native extensions own its supervision.
  The discriminator is the payload's own `transcript_path`, not the environment and not the shared foreign-host predicate above.
  pi-code stamps it with Pi's session file under `/.pi/`, a path component a Claude transcript never carries.
  The stand-down fails toward running, matching the guards above, so no payload, no `jq`, or no `transcript_path` still arms, and every other Claude-shaped hook pi-code delivers keeps running.

### Claude and Codex blocking

Claude and Codex can block a Stop directly with exit status 2 and stderr.
Both payloads carry `stop_hook_active`.
In the default Codex mode, a true value lets the second stop finish after one forced continuation.

### Claude cooperative mode

Claude runs the guard with `--claude`, which ignores `stop_hook_active` and cooperates with the Stop-owned auto-arm.
Claude Code sets `stop_hook_active=true` on every stop after any stop-hook continuation, including `asyncRewake` rewakes.
Under the default one-shot behavior, that re-opened the 2026-07-21 blind window.

Before the Claude cooperative budget can re-block a Stop, the guard checks for a live foreign session-lock owner and takes the same safe diagnostic exit described under "Guard predicates" ([foreign session-lock owner](#foreign-session-lock-owner)).

The Claude mode waits up to `FM_CLAUDE_AUTOARM_SYNC_WAIT_MS` (default 800 milliseconds).
It allows the stop when any of these holds:

- The watcher is healthy.
- The auto-arm's generation claim is open.
- `state/.claude-autoarm-epoch` contains a fresh actionable rewake owned by this event epoch.

#### Auto-arm generation claim

The claim is the ledger entry itself.
The ledger is `state/.claude-autoarm-epoch`:

- Its epoch sequence is a monotonic claim generation.
- Line 1 records the claim and terminal outcome.
- Line 2 records the claiming process's mandatory pid-identity.

`fm_autoarm_claim_open` and `fm_autoarm_claim_next` in `bin/fm-wake-lib.sh` own the format contract.

A claim is open while all of these hold:

- Its outcome is `arming`.
- Its owner pid is alive.
- Its recorded identity successfully recomputes and matches that pid.
- It is not stuck.

Stuck means the entry and the watcher beacon are both older than the guard grace, which proves the owner hung mid-arm.
A healthy hours-long foregrounded cycle keeps the beacon beating, and every arming phase with no watcher is bounded in seconds.

Anything else lets the next Stop-owned firing take the next generation and arm.
That covers a finished outcome, a dead or identity-mismatched owner, a stuck owner, an identityless entry, or no entry.
Taking a newer generation is the reclaim, and a steady-state predecessor is never signalled or revoked.

No mutex is held across arming or output.
`state/.claude-autoarm.lock` survives only as a micro-mutex serializing individual ledger writes.
A superseded owner goes completely silent.
Ownership is re-verified before every arm invocation, episode-state mutation, ledger write, and continuation.

#### Exit status as the commit point

The irrevocable commit point of a translation is the exit status, because the harness delivers the collected stderr banner only on exit 2.
An owned terminal commit therefore decides the exit:

- Markerless outcomes commit with the ledger write.
- The once-per-episode failure notice commits only when its marker is created after the winning failed write in the same critical section.

A generation whose required marker cannot be created is refused and exits 0 silently even after printing.
Its terminal ledger entry is superseded by a later firing, which retries the notice.

#### Why the claim boundaries exist

Without those boundaries, two failures occurred:

- A cycle that armed, delivered one rewake, and exited left both Stop participants deferring to its leftover lock indefinitely.
  On 2026-08-14 two tasks were in flight, a beacon was 40 minutes cold, and every turn was blind until an operator intervened.
- A hook that hung mid-arm kept a live pid on the lock, so the watcher was never auto-re-armed again (2026-08-26).

Two bounded residuals are accepted intent, each costing at most one extra continuation turn absorbed by the durable idempotent wake queue:

- An owner that dies between its owned terminal write and its own process exit.
- A hung old-build owner that resumes during the one legacy upgrade window.

A legacy build's lock-holding claim (recognizable by its `autoarm` role file) still defers or reclaims under the legacy abandonment proof.
A live identity-verified stuck legacy owner is retired via TERM before its lock is removed, and an unverified pid is never signalled.
An upgrade mid-session can therefore neither double-arm nor deadlock, and a failed reclaim re-blocks rather than allowing a blind stop.

#### Failure progression and block budget

Fresh `failed` and `failed-suppressed` outcomes enter or advance the failure progression instead of acting as unconditional recovery proof.
The auto-arm itself rechecks the healthy watcher predicate and retries a bounded number of times before reporting a genuine failure.

The foreground arm legitimately follows a healthy watcher until its next wake.
The hook therefore catches HUP, TERM, and INT from host timeout or teardown and commits the ordinary durable failed outcome and failure-notice marker before exiting 2 for a recovery turn.
Claude drops that exit 2 when it terminated the hook at the configured timeout itself, so a park that outlives the timeout ends without a rewake (`bin/fm-claude-stop-autoarm.sh` header).

The first fresh exhausted-failure epoch preserves its handoff without consuming a blocked-stop count.
Later fresh failed epochs advance the same monotonic progression instead of resetting it.
When none of those proofs appears, the guard re-blocks up to `FM_CLAUDE_TURNEND_BLOCK_BUDGET` times (default 3, below Claude's 8-block override).
In Claude mode, positive watcher recovery clears the block budget, failure notice, and attended alarm together under the existing budget lock before either hook reports ordinary recovery.

The block budget is charged by two rules:

- Each epoch identity is charged at most once per Stop under the budget lock.
- A re-block against an epoch the auto-arm did not advance past the previous re-block is charged as well.

That second rule still bounds an inert auto-arm when a hook never fires or fails before its generation claim and therefore leaves the ledger frozen at its last outcome.
Charging only epoch changes let the count freeze with that ledger, so the remaining inert-hook cases could re-block without limit and make the attended fail-open unreachable.
`budget_account_current_epoch` in `bin/fm-turnend-guard.sh` owns the rule.
A verified live foreign session-lock owner takes the earlier diagnostic safe exit instead and never reaches this budget path.
Whenever both coordination locks are needed, positive auto-arm recovery and the terminal check acquire the auto-arm owner lock before the budget lock.

#### Attended fail-open

The one loud attended fail-open is available only when all of these hold:

- The auto-arm has recorded an exhausted failure.
- Its one notice is already consumed.
- The block budget is exhausted.
- A final check finds neither a healthy watcher nor an automatic continuation.

After that alarm, the Stop auto-arm suppresses further exit-2 continuations until positive watcher recovery, so the final fail-open remains reachable.
The alarm cannot repeat during that failure episode, and a later unhealthy stop blocks again.
A positively verified healthy watcher clears the failure notice, alarm, and block budget for a future independent episode.
A Claude failure notice describes the automatic mechanism as broken and does not direct a routine manual background arm.

### Passive adapters

OpenCode, Pi, and pi-signed expose passive callbacks for this purpose.
Their adapters fail open at the hook boundary to protect the user session.
When the predicate blocks, they schedule one bounded follow-up.
omp is the exception among the Pi-derived harnesses: its `session_stop` hook blocks like Codex's `Stop` hook, so no passive latch is needed and the `stop_hook_active` loop guard applies unchanged.

The generated prompts use the canonical `turn-end-guard` kind after the U+2063 `FIRSTMATE_OP: ` prefix, so Ahoy does not treat them as captain messages.
Each passive adapter owns a loop latch:

- Pi keeps the latch across internal tool turns and clears it only when the generated follow-up settles or delivery fails.
- OpenCode's forced follow-up is supported for persistent TUI sessions and remains fail-open in headless `opencode run`.

### Grok capability selection

Grok makes exactly one typed capability decision from each running Stop payload:

- A boolean `stopHookActive` selects native blocking, including both false on the initial stop and true on the bounded continuation.
- The camel-case field has precedence when both spellings appear.
- When it is absent, a boolean `stop_hook_active` selects the same native path for compatibility.
- When both capability spellings are absent, the adapter preserves one pre-native `grok --resume` fallback guarded by `GROK_TURNEND_GUARD_ACTIVE` and intentionally omits `--permission-mode`.
- Malformed JSON, a selected field with a non-boolean type, missing `jq`, missing hook prerequisites, or an already-active legacy guard allows the stop without starting either continuation path.

The native path returns the shared guard's status and stderr to the same Grok process and never starts `grok --resume`.
Grok's project hook requires the checkout to be trusted with `/hooks-trust` or launch-time `--trust`.
Genuine pre-native builds can run the same tracked hook from an isolated global hook directory.

### Cursor park

Cursor cannot block a turn end at all.
Its blocked-response mapper returns an empty object for the `stop` step, so exit 2 is a silent no-op, verified both statically and live.
`bin/fm-turnend-guard-cursor.sh` therefore never exits 2 and never writes a banner expecting it to be read.
Every path exits 0, and its only channel is at most one `followup_message` on stdout.
Cursor runs that hook synchronously and awaits it, so one script owns both halves of the boundary.

While supervision is needed it PARKS:

1. It runs `bin/fm-watch-arm.sh` as its own tracked child.
2. It holds the boundary open until the watcher closes.
3. It returns an actionable close as one `watcher`-kind follow-up.

It spends no model tokens while parked.
This is the same between-turns shape as Claude's Stop auto-arm, so `fm_supervision_model` classifies Cursor as `autoarm` and the mid-turn pull guard accepts a fresh beacon without a live watcher.

#### Cursor park under a Pi host

The park stands down without arming when `PI_CODING_AGENT=true` and neither `CURSOR_AGENT` nor `CURSOR_INVOKED_AS` is set.
Pi-with-Cursor-provider sessions (pi-cursor-sdk) load project `.cursor/hooks.json` into the Pi process.
A Cursor park there would race Pi's extension-owned `fm_watch_arm_pi` continuity, resurface rearm wakes, and abort in-flight asks.
`fm-spawn`'s cursor launch clears `PI_CODING_AGENT`.
A hand-started cursor-agent may still inherit it.
When either Cursor identity marker is present, the park still runs despite a leaked `PI_CODING_AGENT`.

#### Cursor repair nag and loop bounds

When the park cannot establish a cycle it asks this shared guard with `--cursor` and renders a returned exit 2 as one bounded `turn-end-guard` follow-up.
Those nags are capped by `FM_CURSOR_TURNEND_BLOCK_BUDGET` (default 3) consecutive unproductive nags per session.
A delivered wake resets that budget because it is productive work.

The follow-up loop is bounded TWICE, because either bound alone is insufficient:

- `loop_limit` in `.cursor/hooks.json` is Cursor's own ceiling and the only one that still holds if the adapter is broken or replaced.
  Once `loop_count` reaches it Cursor stops invoking the hook, verified live.
- `FM_CURSOR_TURNEND_LOOP_CEILING` (default 180) bounds the payload's `loop_count` from inside and sits deliberately BELOW the registered `loop_limit`.
  Firstmate's bound therefore bites first and emits one final loud notice instead of supervision going silently dark at Cursor's ceiling.

`loop_count` is Cursor's richer analogue of `stop_hook_active`.
Its behavior was verified live:

- It is 0 on the first stop after a real user message.
- It increases by +1 per follow-up-driven stop.
- The next real user message resets it to 0.

### Captain messages during a Cursor park

A captain message typed while the hook is parked is accepted and runs its turn immediately, and Cursor does NOT terminate the parked hook.
The older park remains the recorded owner until that captain turn ends and the next `stop` hook claims the baton.
An actionable watcher close in that window can therefore still be delivered by the older park as one follow-up.
That delivery is bounded and safe.
Only one park exists before the next `stop` claim, so it is a real wake and never a stale duplicate of another park's wake, while the durable wake queue makes handling idempotent.

Each invocation publishes its sequence in `state/.cursor-park-owner` under the short publication and commit lock `state/.cursor-park-owner.lock`.
The same bounded critical section covers the final owner and away-mode checks, follow-up output, and repair-budget commit.
The next `stop` claim therefore makes an older park that is still running stand down without emitting or changing shared state.
The lock is never held while the arm is sleeping, while the hook is polling, or while output is prepared.

The park revalidates session ownership while polling and again inside the final commit section.
It deliberately does not hold the fleet session lock across output, because an awaited hook must not block home-wide session acquisition.
The remaining microsecond takeover window can produce at most one harmless wake that drains the durable queue.
Without those records an older park still running after the next `stop` could leak one process and one stale duplicate wake.

Cursor's `beforeSubmitPrompt` step fires once on a real captain message and does not fire for hook-driven follow-ups, so invalidating the park baton there would close the pre-claim window exactly.
The step is now registered only for the [dialog mirror](supervision-host.md#the-dialog-mirror); it does not invalidate the park baton.
Baton invalidation and the `preCompact` surface remain deferred.

### Adapter failures in the pull guard

If a passive adapter cannot invoke its SDK, or the Grok legacy fallback cannot find `grok` or a session id, the next pull-based `fm-guard.sh` call reports the problem.
That warning uses `bin/fm-supervision-instructions.sh --repair-line`, so it always points to the active harness protocol rather than embedding another repair command.

### Not this session

A stand-down is not a failure, and the guard separates the two before any blocking path in any mode.
When another live session holds this home's fleet lock, the Stop auto-arm correctly stands down at its ownership gate and writes no epoch, no failure notice, and no alarm, so the bounded progression above cannot advance and the attended fail-open it ends in is unreachable by construction.
Without that separation a session that can never legitimately arm blocks on every turn, with `state/.turnend-claude-blocks` pinned at its first count while the guard waits for a failure record a clean stand-down never writes.
Supervision belongs to the session that holds the lock, so there is nothing here to arm or repair.
The guard states the decline once per (session, lock owner) pair and stands down on every later turn; a change of either half reports again.
The owner it already reported is recorded per session in `state/.turnend-unowned-notice.<session>`, one slot each, so two non-owning sessions in one home cannot overwrite each other's slot and block each other forever.
The slot is keyed on the stop payload's session id, in either spelling, falling back to the caller's own resolved harness pid for Pi, which sends no session id at all and would otherwise share one slot across every session the home ever runs.
Each record also carries the writer's `fm_pid_identity`, so a recycled pid reads as a mismatch and reports again rather than letting a new session mistake a retired one's record for its own; a record whose identity no longer resolves to a live process is retired on the next decline, and nothing is ever removed on age or count.
The decline spends none of the auto-arm block budget, which stays reserved for a genuinely broken arm in a home this session actually holds.
[`watcher-continuity.md`](watcher-continuity.md#session-lock-ownership) owns the ownership verdict itself.

## Compatibility limits

- Child crewmate and scout worktrees are outside scope.
- A valid secondmate home is in scope.
  An idle secondmate endpoint with no Relay poll remains healthy because it has no supervision need.
- The blocking and bounded-follow-up mechanisms are limited to the primary integrations listed above.
- OpenCode headless mode and untrusted Grok project hooks remain fail-open at the host boundary.
- Cursor's `stop` step does not fire in headless `cursor-agent -p`, the same class of limit as OpenCode headless; firstmate primaries run interactive.
- A Cursor primary must be launched with `--trust`, or its project hooks never load and the whole integration is inert.
- Cursor's `preCompact` step is deliberately unregistered.
  Its response can return only `user_message` and it is absent from Cursor's `additional_context` step set, so a post-compaction re-emit needs its own design and is deferred to a follow-up ([`sessionstart-nudge.md`](sessionstart-nudge.md) owns that uncovered surface).
- Kimi Code CLI 0.29.1 exposes only global `[[hooks]]` configuration in `~/.kimi-code/config.toml`, including a `Stop` event with snake_case payload fields `hook_event_name`, `session_id`, `cwd`, and `stop_hook_active`.
- Kimi has no project-level hook configuration and remains outside the primary guard integrations above.
- Captain-approved Kimi crew wake support uses `bin/fm-kimi-turnend-hook.sh` to edit only one marker-delimited Firstmate region in that global config and install a silent always-zero hook.
- The hook remains inert unless the payload `cwd` contains a per-task token pointer that resolves through Firstmate's private registry to one `state/<id>.turn-ended` marker.
- Installation refuses before writing unless `python3` with `tomllib` and `jq` are available.
- If `jq` is removed after installation, the hook remains silent and exits 0, turn-end wakes stop, and Kimi crews fall back to idle detection.
- Antigravity CLI (`agy`) 1.1.12 exposes only global hook configuration in `~/.gemini/config/hooks.json`, including a `Stop` event whose payload carries a `workspacePaths` array; a project-local `.agents/hooks.json` loaded zero files.
- agy has no project-level hook configuration and remains outside the primary guard integrations above.
- Captain-approved agy crew wake support uses `bin/fm-agy-turnend-hook.sh` to upsert only one surgically named Firstmate key in that global config and install a silent always-zero hook.
- That hook checks every `workspacePaths` entry rather than only the first, so a multi-root payload still wakes the task whose worktree it lists at any index.
- Each candidate must still hold a per-task token pointer that resolves through Firstmate's private registry to one `state/<id>.turn-ended` marker, and a payload carrying no such pointer leaves the hook inert.
- Its installation refuses before writing unless `python3` and `jq` are available, unless `hooks.json` is either absent or a regular non-symlink file holding a JSON object, unless `~/.gemini/config` and the `fm-agy-turn-end.d` token registry are absent or real non-symlink directories, and unless `fm-agy-turn-end.sh` is absent or holds a Firstmate-authored hook.
- Removal de-registers the key before those file guards run, so an unrecognized hook script is always unwired from agy even when Firstmate refuses to delete it.
- If `jq` is removed after installation, the agy hook stays silent and exits 0, turn-end wakes stop, and agy crews fall back to idle detection.
- Teardown retires the agy registry entry, the per-task state token, and the worktree pointer alongside grok's and kimi's.
- Unreadable hook input remains fail-open.
- No harness adapter uses a shell ampersand to manufacture supervision.

## Regression coverage

`tests/fm-turnend-guard.test.sh` covers:

- The predicate.
- Main and secondmate primary scope.
- Child-worktree exclusion.
- `FM_HOME` and `FM_STATE_OVERRIDE` precedence.
- The live-lock and fresh-beacon guard predicate.
- The cooperative `--claude` open-generation claim wait.
- Monotonic failed-epoch progression.
- Bounded attended fail-open.
- The same bound against a ledger frozen by an inert auto-arm with and without a verified failure episode.
- Post-alarm continuation suppression.
- Positive recovery reset.
- Generation and legacy claim cases that must block or clear instead of allowing a blind stop.
- The away model in both directions: a live ticking daemon with no watcher stays silent in default and `--claude` mode, while a dead pid, a recycled pid, and a daemon that stopped ticking each still block with daemon-specific wording, and a live daemon without `state/.afk` changes nothing.
- Pi logical-run latching.
- Missing-`jq` behavior.
- All five primary registrations.
- Grok native and legacy selection.
- Typed field precedence.
- Malformed input.
- Exactly-one-path safety.

`tests/fm-turnend-foreign-owner-arm-fix.test.sh` runs the extracted isolated executable reproduction against real auto-arm and turn-end guard scripts.
It proves that a live foreign owner still prevents arming while repeated non-owner Stops receive a diagnostic and exit safely.

`tests/fm-guard-stale-banner.test.sh` covers the pull-guard predicate for each supervision model:

- Away-daemon identity and tick freshness, and precedence over pinned harness models.
- The persistent model's fresh-leftover-beacon negative control.
- The auto-arm model's healthy fresh-beacon-without-a-watcher case, session-and-recovery-bound long-turn rewake tolerance, independently broken tolerance signals, open-claim negative control, stale-beacon alarm, and isolation from other models.
- The extension model's live-watcher path, ownership-qualified fresh hand-off, held-lock failures, independently broken ownership signals, stale-beacon alarm, queued-wake warning, and Pi and pi-signed harness routing.

It also covers true-reason banner wording and reason-keyed episode dedup surviving a beacon mtime change.

`tests/fm-cursor-primary.test.sh` covers the Cursor park end to end over real processes with no harness installed:

- Each tracked Claude-shaped entrypoint standing down on a Cursor payload.
- Both follow-up sources.
- The bounded repair nag and its reset.
- The nested loop bounds.
- Supersession.
- Away-mode and lock-ownership inertness.
- Pi-host stand-down without Cursor identity and continued parking when `PI_CODING_AGENT` leaks alongside `CURSOR_AGENT` or `CURSOR_INVOKED_AS`.
- Child-worktree exclusion.
- That the adapter never exits 2.

`tests/fm-kimi-harness.test.sh` covers the separate Kimi crew hook's format preservation, idempotence, refusal cases, token guard, spawn registration, and teardown cleanup.
`tests/fm-agy-harness.test.sh` covers the separate agy crew hook's surgical install, idempotence, foreign-key preservation, pointer and token gating, single-line, pretty-printed, and multi-root payload framings, spawn registration, and teardown cleanup.
`tests/fm-supervision-instructions.test.sh` covers recovery-line ownership and pi-signed's identity-preserving reuse of Pi's protocol.
`tests/fm-omp-harness.test.sh` covers the omp extension pair over a fake omp API (forced continuation on exit 2, the `stop_hook_active` bound, the seatbelt block, the ownership proof).
`tests/fm-session-lock-ownership.test.sh` covers the not-this-session decline against real competing live processes; [`watcher-continuity.md`](watcher-continuity.md#regression-coverage) owns that suite.

The opt-in live tests are:

- `FM_CURSOR_PRIMARY_LIVE_E2E=1 tests/fm-cursor-primary-live-e2e.test.sh` is the opt-in guard that proves the Cursor park behavior covered by `tests/fm-cursor-primary.test.sh` against the installed cursor-agent and fails naming the harness and version.
- `FM_PI_LIVE_E2E=1 tests/fm-pi-primary-live-e2e.test.sh` is the opt-in isolated Pi path.
- `FM_OMP_LIVE_E2E=1 tests/fm-omp-primary-live-e2e.test.sh` is the opt-in isolated omp path.

[`verification/supervision.md`](verification/supervision.md#turn-end-guard) records the active cross-harness empirical evidence, including the current Claude `asyncRewake` revalidation.
