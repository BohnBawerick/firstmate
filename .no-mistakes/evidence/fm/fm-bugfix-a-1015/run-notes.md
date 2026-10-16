# Live validation

Validated target 6196d452d5fa924a86dc9a3e9c92dde7356109ed against base f2649e3ef55dbaa57c0c6a6e2ed24ad267ca9d53.

The manual run used a marked disposable Firstmate home, a local Git project and origin, a worktree pool, and the named Herdr session fm-lab-bundle-a-1783867-27742.
All Herdr mutations used bin/fm-herdr-lab.sh.
The controller terminal had a 40 by 120 grid.
The lab was removed and the default-session tripwire stayed identical.

Real Codex reached its folder-trust screen in an isolated workspace.
The trust screen was dismissed without saving trust.
Real OpenCode completed a turn, exited with its registration still marked done, and then recovered.
A real Claude print turn consumed the generated settings with the existing normal login.
Both the project Stop hook and Firstmate turn-ended hook fired.
The Claude launcher on PATH and the gh launcher invoked global mise setup, so those attempts were stopped.
The checks then used a workspace-local Claude 2.1.301 binary and the native gh executable already listed on PATH.
No login or credential store was edited by the drivers.
Claude spawn trust registration was redirected to a disposable CLAUDE_CONFIG_DIR.

The secondmate metadata checks launched a real shell through Firstmate's supported raw-command interface.
The fixture carried a legacy armed poll and custom metadata.
A monitor closed a newly published lab pane to cause a real launch-send failure.
The record and authenticated poll survived failure and retry.

The PR watcher used the real GitHub CLI and https://github.com/cli/cli/pull/1.
The remount fixture changed only the two stored device numbers, leaving the actual files, inodes and hashes intact.
The real watcher re-recorded the registration and emitted merged.
A separate fixture changed only one stored device number and the watcher rejected it as unauthenticated.

Initial fixtures under the original code root hit the existing nested-secondmate-home guard.
An exact Git archive of the target was placed beside the fixture homes inside the worktree and initialized as a disposable repository for tests that require tracked commands.
A host Git ignore pattern initially excluded settings.local.json, so the settings fixture was explicitly force-added before its tracked-file checks.
An initial shared-slot fixture incorrectly gave both records the same live endpoint, which belongs to the deliberately deferred pane-ownership concern.
The corrected scenario gave the superseded record a missing endpoint and proved safe retirement without touching the live claimant.

The metadata-lock regression used a plain directory as its worktree and failed when real Git cleanup ran.
The only retained source change adds the existing mark_case_as_treehouse_pool helper to that fixture.
No product code changed during this phase.

Final targeted runs passed for the Herdr presentation E2E, Herdr control smoke, control relaunch, secondmate liveness, captain-hold lifecycle, teardown endpoint safety, teardown settings, focused slot cases and focused PR-device cases.
The final Herdr presentation run completed on Herdr 0.9.3 and verified its own default-session tripwire during teardown.
Some optional Beads-specific captain-hold cases capability-skipped because the installed tasks-axi is markdown-only; the changed archived-Done behavior ran against real markdown storage and passed.
Evidence uses terminal captures and CLI/API transcripts because Herdr ran in isolated headless sessions.
Linters, the complete repository suite, publication and CI were outside this test phase.
