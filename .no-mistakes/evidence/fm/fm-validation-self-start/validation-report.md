# Validation Report: fm/fm-validation-self-start

## Executive Summary
This validation confirms Option (b) implementation from `fm-brief-no-mistakes-cli` removing the intermediate validation handoff from Firstmate's task lifecycle.

A worker agent now:
1. Immediately starts its own validation run after its implementation commit using the `no-mistakes` CLI on PATH (`no-mistakes axi run --intent "<...>"`).
2. Appends a nonterminal `working: starting no-mistakes validation` line to the status file when the run starts.
3. Does NOT append `done:` until there is a PR whose checks are green (`done: PR {url} checks green`).
4. Appends `blocked: {the exact error}` or `failed: {the exact error}` if the run dies mid-pipeline.
5. Handles ask-user findings via `needs-decision` escalation, never answers findings itself, and avoids `--yes`.
6. Uses `no-mistakes axi` CLI commands; references to the `/no-mistakes` skill (absent in crewmate worktrees) are removed.

## Test Proofs

### 1. Behavioral Test Suite
`./tests/fm-brief.test.sh` executes end-to-end scaffolding across modes (`no-mistakes`, `direct-PR`, `local-only`, `--scout`, `--secondmate`) and validates exact behavioral contracts via `test_no_mistakes_worker_starts_own_validation`.

All 21 test assertions pass cleanly.

### 2. Mutation / Sabotage Verification (Proving Both Directions)
- **Direction 1 (Old handoff text returns):**
  When the legacy handoff text (`Firstmate will then instruct you to run /no-mistakes`) was reintroduced, `tests/fm-brief.test.sh` went RED immediately (`not ok - explicit no-mistakes brief did not render the pipeline definition of done`).
- **Direction 2 (Self-start instruction missing):**
  When the self-start instruction (`When implementation is committed on your branch, start the no-mistakes pipeline yourself immediately.`) was removed, `tests/fm-brief.test.sh` went RED immediately (`not ok - explicit no-mistakes brief did not render the pipeline definition of done`).

### 3. Generated Brief Inspection
Generated brief output for `no-mistakes` mode confirms the exact Definition of Done:
```markdown
# Definition of done
Delivery contract: mode=no-mistakes
This mode is complete only when the no-mistakes pipeline has shipped a PR whose checks are green.
When implementation is committed on your branch, start the no-mistakes pipeline yourself immediately.
Append `working: starting no-mistakes validation` to the status file, then run the `no-mistakes` CLI on your `PATH`: `no-mistakes axi run --intent "<...>"` to start, and `no-mistakes axi respond` for each gate.
Do not append `done:` until there is a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, make `--intent` preserve all relevant content from this brief's `# Task` section plus every later accepted Firstmate requirement, clarification, constraint, exclusion, and supersession, carrying only each requirement's current accepted form; retain direct requirements instead of substituting a diff summary, and exclude generic operational, status, delivery, and other scaffold boilerplate unless it is task-specific.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate (rule 6) and stop.
  Firstmate applies the authority contract in its `AGENTS.md` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- Avoid `--yes`: it would silently bypass firstmate's authority check and any required captain escalation.

If you cannot start or continue the run, append `blocked: {the exact error}` and stop, never `done:`.
If the run dies mid-pipeline, append `failed: {the exact error}` and stop, never stay silent.
After the run reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append `done: PR {url} checks green` and stop. You are finished.
```
