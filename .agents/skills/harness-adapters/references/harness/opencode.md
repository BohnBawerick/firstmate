# OpenCode

Verified on 2026-06-11 across versions 1.15.7 through 1.17.6, with busy-queue behavior re-verified on 2026-07-20 using 1.18.4 and composer furniture re-verified on 2026-09-18 using 1.18.31.
The v2 worker adapter was live-verified on 2026-10-17 using 2.0.32 through the guarded Herdr lab; 2.0.30 also reproduced the removed interactive `--model` flag.

## Operating facts

| Fact | Value |
|---|---|
| Busy state | The Firstmate-owned plugin uses v1 `session.status`, with `busy` and `retry` active and `idle` inactive. V2 uses `session.execution.started` and settles on `succeeded`, `failed`, or `interrupted`; it does not emit the v1 status event. Both implementations bind activity to the worker session. |
| Exit command | `/exit`. |
| Interrupt | Double Escape; it is known to be flaky while a long shell command runs, so use `../../../bin/fm-control.sh <task-id> relaunch` for a wedged pane. |
| Skill invocation | No separate verified form beyond normal slash-command behavior; use natural language when the exact command is uncertain. |
| Resume | V1: relaunch with `--continue`, then send the next instruction after the TUI is ready because `--prompt` does not auto-submit alongside it. V2: `opencode --standalone --auto --continue --prompt <instruction>` resumes and submits that instruction. |
| Model selection | V1 uses `--model <provider/model>`. V2 rejects that flag on the interactive command; `../../../../../bin/fm-opencode-launch.sh` creates a session with an explicit model through the native API, then attaches the interactive TUI with its session ID and launch prompt. |
| Effort | V1 has no interactive effort flag; the launch's `OPENCODE_CONFIG_CONTENT` JSON sets `agent.build.variant`, keyed to the resolved model. That mapping is verified for `anthropic/*` high/max and `openai/*` low/medium/high/xhigh; other providers or unsupported values are recorded and omitted. V2 reads the selected model's advertised variants and sets the requested effort as the created session's `model.variant` when advertised, otherwise warns and retains the model default. DeepSeek `opencode/deepseek-v4.1-flash-free` advertises low/high/max, and high and max were verified live. |
| Model discovery | V1: `opencode models [provider]`. V2: `opencode models`; the native API's `model.list` supplies variant metadata. |
| Trust dialog | None. |
| Marker | None; OpenCode publishes no identity marker, so `../../../bin/fm-harness.sh` identifies it from process ancestry. |

OpenCode can auto-upgrade in the background, and the running TUI can exit mid-task.
That behavior was observed live during an upgrade from 1.15.7 to 1.17.3.
If the pane shows the exit banner, use the verified resume path above.

V2 ignores the v1 `OPENCODE_CONFIG_CONTENT` and `OPENCODE_CONFIG` overlays in the verified launch.
Root or agent model configuration also did not override the TUI's remembered variant, whereas explicit session creation selected `high` and submitted the launch prompt at that effort.
The v2 launcher uses a private `--standalone` server so each worker receives its own launch environment and freshly generated busy plugin; it never reloads the shared service.
The generated v2 plugin binds to that launch's exact session ID, while native `--continue` without a binding admits only top-level activity in the worker's directory.
The v1 launch command and plugin entrypoint remain unchanged.
`fm-opencode-launch.sh --major-version` accepts plain or `opencode v`-prefixed 1.x/2.x versions and refuses unknown or unsupported versions.

V2 still loads `.opencode/plugins`, but its entrypoint is a default export with `id` and `setup`, and its event stream uses `event.data` rather than v1 `event.properties`.
The generator in `../../../../../bin/fm-opencode-busy-lib.sh` owns both implementations.
The tracked primary plugins select v2 object definitions for worker checkouts and callable no-op compatibility exports for older v1 loaders.
V2 primary and secondmate supervision is unsupported: `fm-spawn.sh` refuses v2 secondmates, and the compatibility entrypoints refuse a primary directory without the generated worker plugin.
The [vendor migration guide](https://opencode.ai/v2/docs/build/plugins/migrate-v1) describes the separate plugin APIs.

Portable version, launch, and lifecycle regressions are `../../../../../tests/fm-opencode-launch.test.sh`, `../../../../../tests/fm-spawn-dispatch-profile.test.sh`, and `../../../../../tests/fm-busy-adapter-wiring.test.sh`.
Refresh the v2 empirical result with `FM_OPENCODE_V2_LIVE=1 bash tests/fm-opencode-v2-live-e2e.test.sh` from the repository root; the dated output belongs to [runtime backend verification](../../../../../docs/verification/runtime-backends.md#opencode-v2-workers).

Since OpenCode 1.18.0 (upstream anomalyco/opencode#36457, merged 2026-07-11) the idle composer draws the pane's working directory and git branch right-aligned inside the composer rows above the Build footer, wrapped over up to three rail-width fragments whose final fragment continues onto the footer row's right end, whenever the pane has an active session and no higher-priority footer hint.
That cwd:branch indicator is composer furniture, never typed text, and the shared classifier in `../../../../../bin/fm-composer-lib.sh` (`_fm_composer_leftbar_cwd_start`) recognises it structurally by position and shape, for a cwd under `$HOME` (`~/...`) or an absolute cwd outside it, so an idle or busy pane still reads proven `empty`.
An earlier read treated those fragments as unsent typed input, which made every idle 1.18.x tmux worker unsteerable (observed live on 1.18.31) until the doorbell was typed by hand.
Without a cursor anchor a full-pane capture of this version still defers as `unknown` because the status rail below the composer floor row is contiguous, non-blank content; that deferral is the strict posture, not a misclassification.

## Busy-queued Enter

While OpenCode 1.18.4 is mid-turn, its composer accepts Enter as a "send when the turn ends" keystroke but does not clear the typed text until the turn finishes.
Without a conversion, every typed-plane send to a busy OpenCode pane falsely reports "Enter swallowed", and a daemon escalation that lands while the primary is mid-turn appears wedged.

Tmux and Herdr delegate this exception to the one `fm_composer_queued_enter_verdict` policy in `../../../bin/fm-composer-lib.sh`.
Backend-specific signals are documented in `../../../docs/tmux-backend.md` and `../../../docs/herdr-backend.md`.
Regression coverage is `../../../tests/fm-tmux-submit-busy.test.sh`, `../../../tests/fm-composer-lib.test.sh`, and `../../../tests/fm-backend-herdr.test.sh`.
The live Herdr guard is `FM_HERDR_SUBMIT_CONFIRM_LIVE=1 ../../../tests/fm-herdr-submit-confirm-live-e2e.test.sh`.

On v2.0.32, Enter during a busy turn cleared the composer immediately and the next instruction reached the model; the 1.x pending-text exception was unnecessary.
The v2 composer uses `Build auto` under `--auto` and puts its cwd or busy animation below the half-block floor beside command hints.
The shared classifier recognizes that single footer row while preserving pending drafts and refusing a lower shell prompt or unclaimed activity.
Real styled captures and signal-separation regressions live in `../../../../../tests/fixtures/opencode-v2/` and `../../../../../tests/fm-composer-lib.test.sh`.

## Primary integration

The primary integration was verified on 2026-07-08 with OpenCode 1.17.6.
These primary integration facts apply to 1.x only; the v2 worker boundary above is explicit.
`.opencode/plugins/fm-primary-turnend-guard.js` listens for `session.idle`.
Throwing from `session.idle` does not block `opencode run`, so the primary adapter treats the event as passive and uses `client.session.promptAsync` to force one follow-up turn when `../../../bin/fm-turnend-guard.sh` returns 2.
The follow-up was verified in the interactive TUI.
In a home with `config/supervision-host` and no `config/supervision-host-off` the watch-arm plugin spawns the supervision host instead of `../../../bin/fm-watch-arm.sh`, with Claude's print mode as its headless engine; [`supervision-host.md`](../../../../../docs/supervision-host.md) owns the host.
`opencode run` can exit before displaying a queued follow-up, so the adapter steps aside in headless mode.
On native Windows, the operational-input adapter runs its Bash helper through `bash`; macOS and Linux invoke it directly.

The companion `.opencode/plugins/fm-primary-watch-arm.js` owns normal TUI watcher supervision, wakes it with `client.session.promptAsync`, and coordinates with the guard before a blind-turn follow-up.
The PreToolUse-equivalent watcher-arm seatbelt blocks by throwing from `tool.execute.before`.
