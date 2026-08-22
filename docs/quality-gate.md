# Quality gate contract and receipt

The project-owned quality-gate file and the receipt its commands print.
This is the moved owner for those two contracts from the parked Stage 0 spec, revised after the Stage 0a pilot on quota-axi.

This page describes a capability.
Firstmate itself is not a project the bar is applied to, and this repository does not ship a `.quality-gate.yaml`.

`bin/fm-quality.sh`, the loop controller, is not in this revision.
It consumes the receipt schema defined here, so the schema had to land first.

## D1. `.quality-gate.yaml`

Lives at the root of a hardened project, committed.
The name is vendor-neutral on purpose.
Nothing in the file mentions firstmate, so the file and its CI job survive if firstmate is never used on that repo again.

```yaml
# .quality-gate.yaml
version: 1

# The one command CI runs. Exit 0 or 1. Prints one D2 verify receipt on stdout.
verify: "make quality"

# The ordinary test suite. The loop runs this after every round's edits
# and reverts the round if it goes red.
test: "pnpm test"

# The two phases, for the pre-flight loop only. CI does not read these.
clean:
  command: "pnpm run quality:complexity"
  threshold:
    crap_max: 15

harden:
  command: "pnpm run quality:mutation"
  threshold:
    kill_rate_min: 0.80
  exclude:
    - "src/generated/**"

bounds:
  max_iterations: 4
  no_progress_limit: 2
  budget_usd: 8
  budget_minutes: 20
```

The two threshold numbers in that example are the original design values.
They are captain decisions, not part of this revision, and this page does not change them.

Field rules:

- `version` is required and is refused if unknown, so a future schema change fails loudly rather than being half-read.
- `verify` is required. Everything else is optional, and a missing phase means that phase reports `not-applicable`.
- Thresholds are per project. There is no universal default, and `fm-quality.sh` must not invent one.
- `bounds` has the defaults listed above, applied when the key is absent.
- Commands run through the platform shell from the repo root, the same convention no-mistakes uses for `commands.*`.

### `bounds.budget_minutes`

The parked spec gave `max_iterations`, `no_progress_limit`, and `budget_usd` only.
Stage 0a showed the cost that actually decides affordability is measurement wall clock, and it is spent before any harness call exists to enforce spend against.
A two-hour measurement costs nothing in tokens.

`budget_minutes` is the missing bound.
The default of 20 is the Stage 0a-affordable window: four vitest-runner measurements on the diffs that were timed.
A project whose engine is slower must set a higher number rather than overrunning a bound that was never written down.
`budget_usd` stays, because the agent-turn spend is a different resource and is still unmeasured.

## D2. The receipt

Every phase command prints one JSON object matching [`quality-receipt.schema.json`](quality-receipt.schema.json).
`bin/fm-quality-receipt.sh` is the check, and `bin/fm-quality-receipt.sh schema` reprints that file.

`schema_version` stays `1`.
This revises unpublished v1 in place.
No production receipts exist yet.
The Stage 0a pilot objects that passed the old checker are not valid against this revision, and that is intentional.

What breaks, and why:

- `head_sha` is now required.
  Without it a drifted `base_sha` reports `not-applicable` and exits 0, which is the silent miss the design called easiest to get wrong and hardest to notice.
  A docs-only change still has a distinct head and base.
  A receipt that cannot show both cannot tell those apart from an anchor that drifted onto `HEAD`.
- `survivors[]` is now `findings[]`.
  A complexity offender is not a survivor, has no mutant, and is not `killable`.
  The required classification enum was forcing a lie.
- Each finding has a stable `id`.
  `file` plus `line` collide.
  The pilot saw two distinct surviving mutants on one line, and three on another.
  "No progress" has to mean the same findings, not the same count.
- `detail` replaces `mutant`, because the field is not mutation-specific.
- `engine` (name and version) and `threshold` (the numbers this outcome was judged against) are required on `clean` and `harden`.
  The same code scored 2 to 37 points apart on two runners.
  A receipt with no engine identity is not comparable to any other receipt.
- `duration_ms` is a required top-level integer.
  Wall clock is the resource the bound is for, so it is not an optional key inside `metrics`.
- `phase: "verify"` is no longer a flat object with mixed findings.

`outcome` is still the one field a caller reads to decide anything.
`metrics` is still an open map of numbers, because a Python project and a TypeScript project will not report the same keys.

### Classification

`clean` findings use `over-threshold`.
`harden` findings use `killable`, `equivalent`, `unreachable`, `unsupported`, or `defect`.
A clean finding classified `killable` is invalid, which is the point of splitting the vocabulary.

Harden `id` values come from the engine's own stable mutant id when it has one.
Clean `id` values are a per-function identity the phase command controls, typically `file:line:name`.
Ids are unique inside one `findings` array.
They are not unique across the two phases of a verify receipt, because the two engines do not share an id space.

### Verify emits one object, with `phases[]`

`verify` prints one envelope object, not two objects, and not a flattened mix.

One command is still the CI contract.
It exits 0 or 1, prints one JSON document on stdout, and exposes one `outcome` to branch on.
Two raw objects would preserve per-phase mapping and lose that single outcome.
One flat object with mixed `findings[]` preserves the single outcome and loses the mapping.
That is what the pilot had to do, prefixing metric keys by hand and filing complexity rows next to mutants under the same `killable` label.

The envelope therefore carries `phase: "verify"`, the folded `outcome`, the same `base_sha` and `head_sha`, the wall-clock `duration_ms` of the wrapper, and a `phases[]` array of complete `clean` and `harden` receipts.
It does not carry `findings`, `engine`, or `threshold` of its own: those belong on the child that produced them.

Phase commands still emit one `clean` or `harden` object each.
Only the verify wrapper builds the envelope.
Each child's `base_sha` and `head_sha` must equal the envelope's, so a wrapper cannot glue receipts from two trees.

The folded `outcome` is a D4 rule, not a schema constraint.
`blocked` outranks `defect-found`, which outranks `exhausted` and `stuck`, which outrank `pass`.
`not-applicable` is the envelope outcome only when every child is `not-applicable`.

## Checking a receipt

```sh
bin/fm-quality-receipt.sh validate <receipt.json>
bin/fm-quality-receipt.sh validate --check-head <git-dir> <receipt.json>
bin/fm-quality-receipt.sh schema
```

Exit 0 is a valid receipt, 1 an invalid one, 2 a usage or tool error.
The split matters to the loop controller: a receipt that is read but is not JSON, or does not fit the schema, is the phase command's fault.
A receipt path that cannot be read at all, git failing to run, or a schema keyword the checker cannot enforce, is a wiring fault and must not be read as a verdict on the change.

The receipt may arrive as a file operand, as `-`, or on stdin with no operand, so a phase command that prints its receipt on stdout can be piped straight in.

`--check-head` resolves `head_sha` in that tree and requires it to be that tree's `HEAD`.
A receipt that stuffed a constant in `head_sha` fails as soon as `HEAD` moves.
The Stage 0a fail-open, a `not-applicable` object with no `head_sha` at all, fails even without that flag.

`FM_QUALITY_RECEIPT_SCHEMA` may point the validator at a different schema file.
That seam exists so tests can prove the committed schema is the owner rather than a list of constants inside the script.
