Your scout task has been promoted to a ship task, mode=no-mistakes. Your window, worktree, and context stay as they are; only the contract below changes.

# Task
## Captain's intent
Fix the identity check while preserving active shell tools.

## Firstmate spec
1. **Verify isolation before anything else.** Run `pwd -P` and `git rev-parse --show-toplevel`; both must resolve to the disposable task worktree you were launched in, such as a treehouse pool path or an Orca-managed worktree, not the primary checkout firstmate operates from. If either does not resolve to the worktree you were launched in, stop and escalate to firstmate.
2. Inventory this worktree's scratch state with `git status` and `git log` before changing anything.
3. Return to a clean default-branch base, then create your branch: `git checkout -b fm/audit`.
4. Carry over only the intended fix changes. Leave scratch commits, debug edits, and experiment files behind.
5. If you reproduced a bug, turn that reproduction into a regression test.
6. These ship instructions supersede the scout delivery rules and report-based Definition of done. Everything else in your original instructions carries over unchanged: the status protocol; the instruction inbox and its acknowledgement; the escalation rules, including ask-user; and every safety rule.
   For a no-mistakes ask-user gate specifically, escalate all ask-user findings as one event plus one snapshot file, using that same shape even when the gate holds only a single ask-user finding: write only the ask-user findings, verbatim and unparaphrased (id, severity, file, line, description, authority), to `/home/bohn/.no-mistakes/worktrees/842a31c92d33/01M2FSAP36PE8TM5G7KKWCZCFM/.test-phase-tmp/promotion-manual/home/data/audit/nm-<run>-findings.txt`, then report the gate with
   `needs-decision [key=nm-<run>-<step>]: ask-user findings=<id1>,<id2>,... file=/home/bohn/.no-mistakes/worktrees/842a31c92d33/01M2FSAP36PE8TM5G7KKWCZCFM/.test-phase-tmp/promotion-manual/home/data/audit/nm-<run>-findings.txt`
   naming every ask-user finding id from that gate. The status line only points at the file; it never restates or summarizes a finding's content.
7. Preserve every applicable task-specific requirement and accepted steering from the original brief and subsequent instructions, with its original provenance.
Only scout investigation and delivery instructions that this promotion explicitly replaces are superseded.
The inherited text below remains Firstmate-supplied specification unless it explicitly attributes words to the captain.

### Inherited task requirements and steering
Ship the identity-check fix without adding a classifier.
Accepted captain steering: unknown ownership must leave the worker running.

# Definition of done
Delivery contract: mode=no-mistakes
This mode is complete only when the no-mistakes pipeline has shipped a PR whose checks are green.
When implementation is committed on your branch, start the no-mistakes pipeline yourself immediately.
Append `working: starting no-mistakes validation` to the status file, then run the `no-mistakes` CLI on your `PATH`: `no-mistakes axi run --intent "<...>"` to start, and `no-mistakes axi respond` for each gate.
Do not append `done:` until there is a PR.

You drive no-mistakes by responding to its gates, not by implementing fixes.
Follow the guidance no-mistakes itself provides for the mechanics: `no-mistakes axi run --help` plus the `help` lines in each `axi` response are authoritative and version-matched to the installed binary.
When starting no-mistakes, include this brief's `## Captain's intent` and `## Firstmate spec` in `--intent`, with their provenance labels, plus every later accepted requirement, clarification, constraint, exclusion, and supersession.
For a legacy brief, preserve its accepted `# Task` requirements as Firstmate specification and label separately any explicitly attributed captain words.
Never present Firstmate-authored requirements as the captain's literal words.
Retain only each requirement's current accepted form and exclude generic operational boilerplate and unaccepted worker decisions and tradeoffs.
The `--intent` string you pass must be self-sufficient: that string plus the codebase must let a reader reconstruct the accepted specification.
When a requirement refers to a report, decision, or PR, write the substance of the referenced items into `--intent` instead of passing only the pointer.
This replaces the no-mistakes skill's advice to enrich `--intent` with decisions and tradeoffs: only accepted requirements belong in this task's validation contract.
Do not hand-edit, commit, or fix findings yourself while a run is active - the pipeline applies every fix.

One drive call blocks until the next gate or outcome, which routinely outlives what your harness lets a single command run: Claude Code kills a command at ten minutes maximum, while one fix round is capped around thirty minutes and up to three rounds chain.
So background the drive call and poll `no-mistakes axi status` from a separate call instead of sitting in one blocking hold your harness will kill.
Where a harness's own command limit is not established, assume it bounds commands and use that same background-and-poll shape.
A killed or timed-out call is never evidence the daemon died: the daemon accepts your response immediately and runs the round in the background, so the call was only ever waiting for a read while the run kept working.
Reattach and keep going rather than reporting the pipeline blocked; rule 7 owns the checks that decide when a pipeline block is real.

Two firstmate-specific rules layer on top of that guidance:
- ask-user findings are never yours to answer: escalate to firstmate using rule 6's ask-user format and stop.
  Firstmate applies `ask-user-authority` and obtains any required captain decision.
  When the decision comes back, feed it to the gate with `no-mistakes axi respond` and let the pipeline apply it - do not route the question to "the user" or implement the fix yourself.
- NEVER pass `--yes` (or `-y`) to `no-mistakes axi run` or `no-mistakes axi respond`. It is banned fleet-wide.
  It auto-resolves every gate including ask-user findings with no escalation, and answering your own ask-user finding is a hard rule violation.

If you cannot start or continue the run after checking its actual daemon state, append `blocked: {the exact error}` and stop, never `done:`.
If the run dies mid-pipeline, append `failed: {the exact error}` and stop, never `done:`.
After the run reports CI green (the CI-ready return point - do not wait for it to keep monitoring in the background until merge), append `done: PR {url} checks green` and stop. You are finished.
