# Away-Mode Housekeeping: Gone vs Unreadable Distinction Verification

This document provides product-level end-to-end evidence demonstrating that away-mode housekeeping in `bin/fm-supervise-daemon.sh` reliably distinguishes torn-down panes from unreadable or recovering panes at both the stale-persistence and pause-resurface call sites.

## Summary of Evaluated Behaviors

1. **Genuinely Gone Pane (Torn Down)**:
   - When capture fails after bounded retries and `agent_state` confirms `missing`, the marker is dropped cleanly with no false alarms or supervisor escalations.
2. **Present but Unreadable Pane**:
   - When capture fails after bounded retries but the pane remains present (`alive`, `unreadable`, `unverified`), housekeeping does not drop the marker. It escalates to the supervisor as `(pane present but unreadable)` and resets the marker timestamp so the worker continues to be watched.
3. **Transient Capture Hiccup (Retry Recovery)**:
   - When screen capture fails initially but succeeds on retry, housekeeping proceeds with the ordinary classification without querying agent state or corrupting marker lifecycle.
4. **Dead Shell (Agent-less Pane)**:
   - When `agent_state` returns `dead`, the pane is treated as ordinary idle rather than silently dropped as gone.

---

## End-to-End Execution Transcript

```text
=== Scenario 1: Genuinely Gone Pane (Torn Down) ===
[stale] Initial marker present: YES
[stale] Marker exists after housekeeping: NO (cleanly dropped)
[stale] Escalations generated: NONE (silent drop, no false alarm)
[pause] Initial marker present: YES
[pause] Marker exists after housekeeping: NO (cleanly dropped)
[pause] Escalations generated: NONE (silent drop, no false alarm)

=== Scenario 2: Present but Unreadable Pane ===
[stale][alive] Marker exists: YES (reset timestamp to retain supervision)
[stale][alive] Escalation: stale persisted 500s (pane present but unreadable): sess:fm-worker-stale-alive
[stale][unreadable] Marker exists: YES (reset timestamp to retain supervision)
[stale][unreadable] Escalation: stale persisted 500s (pane present but unreadable): sess:fm-worker-stale-unreadable
[stale][unverified] Marker exists: YES (reset timestamp to retain supervision)
[stale][unverified] Escalation: stale persisted 500s (pane present but unreadable): sess:fm-worker-stale-unverified
[pause][alive] Marker exists: YES (reset timestamp to retain supervision)
[pause][alive] Escalation: paused 5000s (pane present but unreadable, recheck whether the wait still holds): sess:fm-worker-pause-alive
[pause][unreadable] Marker exists: YES (reset timestamp to retain supervision)
[pause][unreadable] Escalation: paused 5000s (pane present but unreadable, recheck whether the wait still holds): sess:fm-worker-pause-unreadable
[pause][unverified] Marker exists: YES (reset timestamp to retain supervision)
[pause][unverified] Escalation: paused 5000s (pane present but unreadable, recheck whether the wait still holds): sess:fm-worker-pause-unverified

=== Scenario 3: Transient Capture Hiccup (Retry Success) ===
[stale] Capture attempts taken: 2
[stale] Escalation: stale persisted 500s (possible wedge): sess:fm-worker-stale-retry
[stale] Stale marker removed (ordinary idle wedge)? YES
[pause] Capture attempts taken: 2
[pause] Escalation: paused 5000s (awaiting external, recheck whether the wait still holds): sess:fm-worker-pause-retry
[pause] Pause marker reset for next cycle? YES

=== Scenario 4: Dead Shell (Agent-less Pane) ===
[stale] Escalation: stale persisted 500s (possible wedge): sess:fm-worker-stale-dead
[stale] Treated as gone? NO (surfaced as ordinary idle)
[pause] Escalation: paused 5000s (awaiting external, recheck whether the wait still holds): sess:fm-worker-pause-dead
[pause] Treated as gone? NO (surfaced as ordinary idle)
```

## Matrix of Verifications

| Scenario | Call Site | Capture Retries | Agent State Probe | Escalation Output | Marker State |
| :--- | :--- | :--- | :--- | :--- | :--- |
| Genuinely Gone | Stale persistence | 3 (1 initial + 2 retries) | `missing` | *None* | Dropped |
| Genuinely Gone | Pause resurface | 3 (1 initial + 2 retries) | `missing` | *None* | Dropped |
| Present Unreadable | Stale persistence | 3 (1 initial + 2 retries) | `alive` / `unreadable` / `unverified` | `stale persisted <age>s (pane present but unreadable): <win>` | Reset & kept |
| Present Unreadable | Pause resurface | 3 (1 initial + 2 retries) | `alive` / `unreadable` / `unverified` | `paused <age>s (pane present but unreadable, recheck whether the wait still holds): <win>` | Reset & kept |
| Retry Recovery | Stale persistence | 2 (succeeded on 2nd) | *Not called* | `stale persisted <age>s (possible wedge): <win>` (idle) | Dropped (wedge cleared) |
| Retry Recovery | Pause resurface | 2 (succeeded on 2nd) | *Not called* | `paused <age>s (awaiting external, recheck whether the wait still holds): <win>` | Reset for next interval |
| Dead Shell | Stale persistence | 3 (1 initial + 2 retries) | `dead` | `stale persisted <age>s (possible wedge): <win>` | Dropped (wedge cleared) |
| Dead Shell | Pause resurface | 3 (1 initial + 2 retries) | `dead` | `paused <age>s (awaiting external, recheck whether the wait still holds): <win>` | Reset for next interval |

---
