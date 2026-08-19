# Firstmate Memory Slice 1 - End-to-End Verification Evidence

This directory contains product-level verification transcripts demonstrating all deliverables and acceptance criteria of Memory Slice 1:

1. **`01-fm-memory-migrate.transcript.txt`**:
   - Mechanical split of `data/learnings.md` into atomic notes under `data/memory/notes/`.
   - Derivation of YAML front matter (titles, triggers, updated dates, tiers, source).
   - Generation and publishing of `data/memory/catalog.md`.
   - Freezing original to `data/memory/raw/learnings-YYYY-MM-DD.md` and appending to `data/memory-archive.md`.
   - Verification of idempotent re-run behavior.

2. **`02-fm-memory-compile.transcript.txt`**:
   - Working memory bundle compilation (`bin/fm-memory-compile.sh compile`).
   - Constitution selection (`data/memory/core.md` taking precedence over `data/captain.md` fallback).
   - Dynamic trigger matching against active projects and backlog keywords.
   - Ignore behavior for drop tray (`data/memory/drop/`).
   - On-demand and fresh catalog publishing (`bin/fm-memory-compile.sh catalog`).

3. **`03-fm-memory-budget-cap.transcript.txt`**:
   - Strict budget cap accounting using conservative `ceil(UTF-8 bytes / 3)` token formula.
   - Within-budget execution (`status=within-budget`).
   - Capped execution dropping hot notes to preserve catalog and core under pressure (`status=capped`).
   - Loud over-budget warning when core exceeds budget without silent failure.
   - Refusal on unreadable or corrupted budget values.

4. **`04-fm-session-start.transcript.txt`**:
   - End-to-end integration into `bin/fm-session-start.sh` startup digest.
   - Capped curated memory injection replacing unconditional raw file dumps.
   - Startup token consumption dramatically reduced from >35k tokens down to within the 7,500 token budget.
