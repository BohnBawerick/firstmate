# ChatGPT dot MCP mailbox bridge

This bridge connects Firstmate to a ChatGPT dot through a private SQLite mailbox and an HTTP MCP endpoint.
Firstmate submits assignments, a signed callback wakes the dot, and the dot retrieves work and replies.
The tools expose mailbox operations only.
The local commands require Bash and Python 3 with SQLite support.
The HTTP endpoint accepts requests without authentication and uses a shared `dot-worker` principal for subscriptions.
Keep the listener on loopback and use the private tunnel for remote access.

## Mailbox operations and limits

Operator submissions create assignments with a stable message ID and optional correlation and idempotency keys.
The MCP `submit_message` tool creates dot-origin notes for Firstmate, not new assignments for the dot itself.
Notes remain readable but do not trigger `message.created`, preventing a self-notification loop.
Repeated submissions with the same idempotency key return the original assignment.
`get_messages` returns assignments in sequence order with queue and status filters, a continuation cursor, and a maximum of 50 records.
`reply` requires the exact message ID; a supplied correlation ID must match that assignment.
Repeating the same reply is idempotent.

Both the operator CLI and MCP tools enforce UTF-8 byte limits of 16 KiB for content and reply, and 256 bytes for queue, correlation ID, and idempotency key.
Serialized responses and callback bodies cannot exceed 256 KiB, including JSON escaping and the MCP envelope.
Pagination stops at the byte budget and returns the last included sequence as its cursor.
Oversized writes fail before committing.

Storage resolves from `--db` or `$FM_HOME/data/dot-mcp/mailbox.sqlite3`.
Without an explicit database or `FM_HOME`, commands fail.
The storage directory must belong to the current user with owner-only permissions.
New database files use mode `0600`, including SQLite sidecars; unsafe existing storage is rejected.

## Event delivery

The server implements MCP `2026-07-28` discovery, tools, and `message.created` subscriptions as described in the [official MCP Events contract](https://developers.openai.com/plugins/build/mcp-events).
Legacy `initialize` and `notifications/initialized` handling remains for compatibility with ChatGPT custom MCP connectors.
The HTTP routes are `POST /mcp` for MCP and `GET /health` for readiness.
Request diagnostics go to stderr; the `bin/fm-dot-mailbox.py` header owns their fields and redaction rules.

Matching subscriptions and assignments commit with durable event records in one transaction.
The foreground HTTP server processes pending events on startup and every quarter second.
Delivery uses at most four attempts with waits of one, two, and four seconds after failures.
An interrupted attempt can remain claimed for up to eleven seconds before recovery.
Each retry keeps the event ID and body and creates a fresh signing timestamp and signature.
HTTP `410` and `413` stop retries immediately.
Any `2xx` response acknowledges application delivery without reading its response body.
After exhaustion, the event remains undelivered and the assignment remains readable.
Operator `status` and each returned assignment expose pending, delivered, and undelivered event counts.
Expired or unsubscribed destinations stop receiving queued events.

Subscription lifetimes default to 24 hours and honor positive `ttlMs` values up to that maximum.
A null lifetime request also receives a finite 24-hour grant.
Renewal preserves the subscription ID.
Replaced signing keys remain valid for five minutes, and callbacks carry space-separated signatures for the current key and all keys still inside that rotation window.

Verification sends a signed, single-use challenge and requires a matching JSON echo with a `2xx` response before storing the subscription.
Subscriptions reuse successful verification for the same principal and callback URL for five minutes, including across retries, filter changes, renewals, and restarts.
Cache hits preserve the original verification time; failed challenges do not refresh it.
An absent correlation ID is omitted from the event payload.
Both verification and delivery resolve the destination once, reject every non-public address, and connect directly to an address from that validated set.
If an address fails to connect, subsequent validated candidates share the remaining ten-second connection budget.
TLS checks the original hostname.
Redirects are not followed, and environment proxy settings do not redirect callback connections.
The explicit local-testing option permits HTTP and loopback destinations; it does not permit other non-public addresses.

## Local operator interface

Use a private operational home inside the isolated copy:

```sh
export FM_HOME="$PWD"
DOT_ASSIGNMENT=$(bin/fm-dot-mailbox.sh submit --queue worker-tasks --correlation-id task-101 --idempotency-key task-101 "Execute analysis task")
DOT_MESSAGE_ID=$(printf '%s\n' "$DOT_ASSIGNMENT" | python3 -c 'import json, sys; print(json.load(sys.stdin)["id"])')
bin/fm-dot-mailbox.sh list --queue worker-tasks --status pending
bin/fm-dot-mailbox.sh get "$DOT_MESSAGE_ID"
bin/fm-dot-mailbox.sh reply "$DOT_MESSAGE_ID" "Task completed" --correlation-id task-101
bin/fm-dot-mailbox.sh get "$DOT_MESSAGE_ID"
bin/fm-dot-mailbox.sh status
```

The script headers and `--help` own the command reference, including the local callback testing option.

## Prepare a Secure MCP Tunnel connection

The following live steps remain for Firstmate after review.
They create a tunnel profile, connect a plugin, and contact the dot only when the operator executes them.
Use an existing official `tunnel-client` binary; these commands use the verified v0.0.16 flag names.

Follow the [Secure MCP Tunnel setup guide](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels) to obtain a tunnel identifier in Platform tunnel settings and associate the Platform organization and ChatGPT workspace.
Creating or editing a tunnel requires Tunnels Read and Manage permissions.
The runtime API key and the operator adding the ChatGPT connection need Tunnels Read and Use permissions.
No credential values belong in tracked files or shell history.

In the first terminal, from the isolated copy, keep the mailbox in the foreground:

```sh
export FM_HOME="$PWD"
bin/fm-dot-mailbox.sh serve --host 127.0.0.1 --port 8765
```

In a second Bash terminal, also from the isolated copy, create a private profile under the ignored `data/` directory:

```bash
umask 077
DOT_TUNNEL_PROFILE_DIR="$PWD/data/dot-mcp-tunnel"
mkdir -p "$DOT_TUNNEL_PROFILE_DIR"
chmod 700 "$DOT_TUNNEL_PROFILE_DIR"
tunnel-client init \
  --sample sample_mcp_remote_no_auth \
  --profile-dir "$DOT_TUNNEL_PROFILE_DIR" \
  --profile dot-bridge \
  --tunnel-id "<tunnel-id>" \
  --mcp-server-url "http://127.0.0.1:8765/mcp"
read -rsp "Enter CONTROL_PLANE_API_KEY: " CONTROL_PLANE_API_KEY
printf '\n'
export CONTROL_PLANE_API_KEY
tunnel-client doctor --profile-dir "$DOT_TUNNEL_PROFILE_DIR" --profile dot-bridge --explain && \
  tunnel-client run --profile-dir "$DOT_TUNNEL_PROFILE_DIR" --profile dot-bridge
```

The sample references `env:CONTROL_PLANE_API_KEY`, so credential entry, doctor, and run must share this terminal.
Start run only after doctor succeeds.

Open [ChatGPT Plugins](https://chatgpt.com/plugins), select the plus button, then Add custom MCP server.
Following the [custom MCP connection steps](https://developers.openai.com/plugins/deploy/connect-chatgpt#add-the-mcp-server), enter a name and description, select Connection Tunnel, and enter the tunnel identifier.
Select no authentication for this mailbox server, review the risk warning, and create the plugin.
Review the discovered tools and enable the plugin in the dot conversation.
Account and workspace UI availability remain unverified.
In the dot conversation, request a `message.created` subscription on the connector for queue `worker-tasks`, with instructions to retrieve assignments and reply to their exact message IDs.
Confirm challenge verification and the subscription before submitting a unique hello nonce.
Read the nonce through MCP, reply with its correlation ID, and inspect the result with the operator CLI.
A local controlled receiver proves callback behavior only; it does not prove an authenticated remote connection or a real dot wake.

To stop, use Ctrl-C in both foreground terminals.
In the tunnel terminal, clear the credential and remove only this run's profile directory from the isolated copy:

```bash
unset CONTROL_PLANE_API_KEY
rm -r -- "$DOT_TUNNEL_PROFILE_DIR"
unset DOT_TUNNEL_PROFILE_DIR
```

Mailbox records remain under `data/dot-mcp/` for inspection.
Remove that directory only when its assignments and subscription secrets are no longer needed.
Revoke any runtime key and remove the account-side connection when retiring the live setup.

## Register an existing dot as a second mate

A dot uses a mailbox transport, not a terminal backend.
Registration keeps the ordinary home and scope entry in `data/secondmates.md`, creates `kind=secondmate` metadata with `transport=dot-mcp`, and stores the route in the existing mailbox database.
The private home contains its charter and the standard parent-channel binding, not a Firstmate executable copy or project clones.
Its `.fm-secondmate-transport` marker keeps code updates and process lifecycle operations separate from ordinary local second mates.
Registration creates no Herdr pane; the optional reported-activity view below is separate from the dot's execution and liveness.

Use the existing mailbox database, loopback health endpoints and subscribed queue.
Do not create another tunnel or plugin for registration.
Write a task-specific charter in a private file, with these rules:

- Remain idle until Firstmate routes work through a new assignment event.
- Read only assigned work, not dot-origin notes or old setup messages.
- Follow the requested scope and named cloud environment; never substitute a connected personal computer for cloud execution.
- Own routine upkeep of assigned cloud environments and tools, including setup scripts, packages and caches; fix those as needed for assigned work without asking the owner to repair them.
- Preserve user work and the assignment's repository and data boundaries during upkeep.
- Report only through `reply`, using the assignment's exact message ID and correlation ID.
- Start each reply with `working:`, `done:`, `blocked:`, `needs-decision:` or `paused:`.
- Include actual results and native thread/turn IDs when cloud work runs; include a URL only when the native tool supplies one.
- Escalate only account, credential, billing or permission changes, or work outside the charter, through Firstmate rather than the user directly.
- Do not call `submit_message` to answer assignments or invent work while idle.

From the parent home, register the route with the script whose `--help` owns these arguments:

```sh
export FM_HOME="/absolute/parent/home"
bin/fm-dot-secondmate.sh register dot-cloud \
  /absolute/private/mailbox.sqlite3 /absolute/private/dot-home default \
  http://127.0.0.1:8765/health http://127.0.0.1:18765/readyz \
  "Cloud tasks explicitly routed by Firstmate" /absolute/private/dot-charter.md
bin/fm-dot-secondmate.sh health dot-cloud
bin/fm-send.sh dot-cloud "Return a harmless proof nonce through the mailbox."
bin/fm-crew-state.sh dot-cloud
```

The home must be new and separate from the parent home and code root.
Registration refuses existing unrelated records or a changed route instead of replacing them.
It requires the parent's session ownership, as does ordinary `fm-send`.
The mailbox service must run this version of the server to publish routed replies.
Every new routed assignment reads the registered home's `data/charter.md` and carries it with the ordinary parent correlation token.
Firstmate updates that private charter when its authorized scope changes; editing the original registration input does not update the registered copy.
Existing assignments retain the instructions sent with them, so steer active work through `fm-send` when a change must apply immediately.
Exact retransmissions deduplicate; a new recovery instruction with the same correlation creates a new event.
Routed replies require that correlation and a supported outcome prefix or the activity-note format below.
A durable reply outbox publishes through the existing parent-channel helper, preserving retries across crashes without duplicating a status line.
Full replies are retained under the parent home's private `data/<mate-id>/mailbox-replies/` directory.
A blocked or decision reply opens a `dot-<message-id>` key, which Firstmate answers with ordinary `fm-send --resolve-key`.

Health reports mailbox readiness, tunnel readiness, an active subscription, last tool contact, pending assignments and undelivered events.
It never claims the dot's process is online: an idle dot is externally hosted and its current process state is not observable.
`fm-peek` returns those health facts rather than chat or a simulated pane.
Fleet summaries include reported cloud children, their native IDs, observation ages and `dot-reported` provenance.
No local process or pane stands in for cloud liveness.
An unavailable tunnel is not evidence that a local agent should be spawned.
Process interrupts, relaunches and generic cleanup refuse dot routes; registration and mailbox records remain intact.

Subscription expiry is the server's granted `refreshBefore`, not proof that ChatGPT has renewed it.
To prove live renewal, observe a new successful `events/subscribe` request, verify the existing subscription identity has a later expiry, and verify another fresh event and correlated reply.
Local expiry/renewal tests do not prove the hosted scheduler renewed a live subscription.

## Reported cloud activity

The dot can publish typed observations inside the existing `reply` text without changing the MCP tool schema.
The text starts with `activity-note:` followed by one JSON object:

```json
{
  "schema": "fm.activity-note.v1",
  "event_id": "proof-started-1",
  "observed_at": "2026-10-15T12:20:00Z",
  "kind": "task-created",
  "summary": "Read-only corpus proof admitted",
  "task_id": "native-thread-id",
  "turn_id": "native-turn-id"
}
```

`event_id` identifies one observation and must remain unchanged on retry.
Reusing it with different content or another assignment is rejected.
Distinct observations need distinct IDs even when their summary text matches.
Identifiers accept 1 to 128 ASCII letters, digits, dots, underscores or hyphens, beginning with a letter or digit.
`observed_at` must be UTC and no more than five minutes ahead of the server clock.
`summary` is limited to 1600 UTF-8 bytes and must contain no credentials, secret data or unrequested private content.
Optional `task_title` carries the native cloud task title when the tool supplies one, limited to 256 UTF-8 bytes.
The optional `url` is limited to 2048 bytes and must be an HTTPS URL actually supplied by the native tool, never assembled from IDs.
Unknown fields and schema versions are rejected.

Kinds are `pickup`, `task-created`, `milestone`, `blocked`, `needs-decision`, `done` and `failed`.
Use `pickup` without task/turn IDs, a task title or URL to acknowledge the assignment through its original correlation.
Every other kind requires both native IDs.
The native task ID identifies the reported child across turns; observations and history retain each native turn ID.
Use milestones only for observed changes, not timer ticks.
The mailbox stores server revisions in the append-only `mate_replies` history and keeps legacy text replies there too.
The message's `replied` flag means acknowledged, not that its cloud work finished.

The initial pickup reaches the parent channel; routine cloud activity does not send a notification per note.
Actionable and terminal child outcomes use the shared child-outcome publisher and its durable delivery receipts.
Every distinct `blocked`, `needs-decision`, `done` and `failed` observation reaches the parent once, regardless of later observations in the same or another turn.
For display state, terminal observations dominate late progress for the same native turn.
The latest observation among those turn states supplies the task's current state, so a later turn updates the existing child.
Nonterminal observations older than fifteen minutes display current state as unknown without inventing a completion or cancelling anything.
The child and activity lists are bounded; a truncated child inventory refuses display cleanup rather than guessing which tasks finished.
Use the cursor-based `history` command from `bin/fm-dot-secondmate.sh --help` to read all stored revisions.

## Read-only Herdr view

`bin/fm-dot-view.sh --help` owns launch arguments.
Run its `watch` command from the parent home with an explicit Herdr session to maintain the `2ndmate-<mate-id>` workspace.
This process reconciles displays only; it never dispatches work, changes the fleet presentation setting, allocates an isolated copy, or starts or stops Herdr sessions.
It requires an already running compatible Herdr session.

The mate console shows a compact connection summary, subscription expiry, last contact, pending assignments and active-child count.
Each timestamped feed entry is one short task/description/state line; full replies remain in durable history and reports.
Descriptions are capped at 40 characters including an ellipsis, or less when the pane needs room for the state.
Descriptions use the routed assignment's first nonempty line, stripping an optional `Subject:` prefix, or the native `task_title` on that observation when supplied.
Start routed work with a short subject line when a long request needs a clearer label.
All display times use the machine's local timezone; stored observations remain UTC.
Each active native task gets one read-only display with its task ID, current turn ID, status, milestones and result, plus activity from all its turns.
These are mailbox reports, not the ChatGPT conversation, a cloud shell or live build output.
Display input is discarded.
Closing a display never cancels cloud work.
A terminal display closes automatically only after its result is stored and the parent outcome is delivered; its history stays available.

Display bindings are separate from worker metadata and scoped to the parent home and exact session, workspace, tab and pane IDs.
Presentation locks and focus guards protect unrelated tabs.
A renamed or ambiguous display is left alone and reported as an error.
Stopping the view process leaves displays and all cloud work untouched.
Restarting it reuses confirmed bindings and replays durable history; missing observations remain unknown.
Refresh an existing turn-scoped view after its tracked tasks have durable terminal results and delivered parent outcomes.
Stop `watch`, close only the dedicated view workspace, then restart `watch` to rebuild its bindings with task-scoped IDs.
After restart, Firstmate must use ordinary `fm-send` to ask the dot to paginate its direct children and report each nonterminal child's current native status, outcome and recent milestones.
Only the dot performs those native reads.

## Focused local verification

```sh
bash bin/fm-test-run.sh tests/fm-dot-mailbox.test.sh tests/fm-dot-view-herdr-e2e.test.sh
```

The suite exercises the mailbox round trip, duplicate and restart behavior, callback validation, signing, bounded retries, renewal, and storage limits.
It also drives `fm-send` through a registered mailbox route, receives MCP replies through the parent status channel, reads the wake drain and fleet view, and checks health failures without a terminal.
Activity cases cover retry conflicts, pagination, out-of-order updates, task identity across turns, stale observations, restart replay, terminal-safe rendering and parent-delivery receipts.
The Herdr test uses a named isolated lab to check display ownership, focus, ignored input and delivery-before-close without touching the default session.
