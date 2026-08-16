---
name: sync-axi
description: >-
  Update cloned repositories and firstmate from origin using local patch stacks, reporting conflicts before applying clean changes.
  Use when the captain invokes /sync-axi or asks to sync or update cloned axi repositories.
user-invocable: true
metadata:
  internal: true
---

# sync-axi

Update every repository cloned from an upstream author while keeping local patch stacks intact.
Origin remotes are treated as read-only upstream sources - this skill never pushes to origin, never opens pull requests, and never creates forks.
Updates are evaluated on a scratch copy before touching real working trees, so the captain is never surprised by unexpected merge or rebase conflicts.
Repositories with unlanded work, dirty working trees, or no origin remote are left untouched and reported plainly.

## Operating model

- Repositories under `projects/` and the `firstmate` repository itself are maintained as local patch stacks on top of upstream origin.
- Origin remotes are read-only; firstmate never pushes to them.
- Updating fetches upstream changes and tests integration on a scratch copy first.
- If rebase ("replay ours on top") succeeds cleanly, it is preferred.
- If rebase conflicts but a real `git merge` ("take theirs on top") succeeds cleanly, merge is used.
- If both conflict, neither is applied and hands-on resolution is reported.

## What it does

1. **Run the sync engine:**
   ```sh
   bin/fm-sync-axi.sh
   ```
   It discovers all target repositories, fetches origin, tests scratch integration, applies only clean updates, rebuilds globally installed tools whose sources changed, and outputs plain-English per-repository status lines.

2. **Check for instruction updates if firstmate advanced.**
   When `firstmate` is updated and incoming commits touch `bin/` or `.agents/skills/`, the running instruction surface changed.
   Re-read `AGENTS.md` to refresh operating instructions.
   If incoming commits touch only docs, tests, or CI configuration, no instruction re-read is needed.

3. **Report outcomes to the captain.**
   Report each repository's outcome to the captain in plain English using project outcomes rather than git mechanics, per `AGENTS.md` section 9.
