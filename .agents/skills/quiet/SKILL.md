---
name: quiet
description: >-
  Enter quiet supervision when the captain invokes /quiet or asks for fewer routine updates while remaining present.
  Ordinary chat preserves quiet mode; explicit /quiet off exits it.
user-invocable: true
metadata:
  internal: true
---

# quiet

Quiet mode batches routine updates while the captain stays present.
Decisions, failures, credentials, and review-ready work still surface.
It changes presentation and never grants away-mode authority or expands approval authority.

## Native Pi supervision

On `pi` and `pi-signed`, use the `quiet` command in `bin/fm-afk-launch.sh`; its help owns the command syntax and durable presentation record.
Entry requires no away proposal or confirmation and starts no daemon.
Native supervision continues reading the presentation record on each main turn, including after session restart.
Ordinary captain chat leaves the record in place.
An explicit `/quiet off`, or a plain request to resume normal presentation, uses that command's `off` action.
Do not run the away return path to exit native quiet mode.
If a separate away contract exists, `/afk` continues to own its return lifecycle independently.

## Other harnesses

Follow the `afk` skill's daemon entry with `FM_AFK_MODE=quiet` for harnesses that still use the daemon.
The legacy daemon flag preserves its mode on refresh.
Explicit `/quiet off` uses the return procedure owned by `/afk`.
Ordinary chat and marked escalations preserve quiet mode.

## Acknowledge the mode

Tell the captain that quiet mode is active, routine updates will be batched, and ordinary chat will preserve it until explicit `/quiet off`.
A refresh preserves the current mode.
Keep merge authority under `AGENTS.md` section 7 and findings under `ask-user-authority`.
