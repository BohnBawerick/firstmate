# ChatGPT dot MCP mailbox bridge

This bridge connects Firstmate to a ChatGPT dot through a private SQLite mailbox and an HTTP MCP endpoint.
Firstmate submits assignments, a signed callback wakes the dot, and the dot retrieves work and replies.
The tools expose mailbox operations only.

## Mailbox operations and limits

`submit_message` creates an assignment with a stable message ID and optional correlation and idempotency keys.
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
bin/fm-dot-mailbox.sh submit --queue worker-tasks --correlation-id task-101 --idempotency-key task-101 "Execute analysis task"
bin/fm-dot-mailbox.sh list --queue worker-tasks --status pending
bin/fm-dot-mailbox.sh get msg_0123456789abcdef
bin/fm-dot-mailbox.sh reply msg_0123456789abcdef "Task completed"
bin/fm-dot-mailbox.sh status
```

The script headers and `--help` own the command reference, including the local callback testing option.

## Prepare a Secure MCP Tunnel connection

The following live steps remain for Firstmate after review.
They create a tunnel profile, connect a plugin, and contact the dot only when the operator executes them.
Use an existing official `tunnel-client` binary; these commands use the verified v0.0.16 flag names.

Obtain a tunnel identifier in OpenAI Platform tunnel settings, associate the Platform organization and ChatGPT workspace, and generate a runtime API key with Tunnels Read and Use permissions.
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
Select Connection Tunnel, enter the tunnel identifier, review permissions, and create the plugin.
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

## Focused local verification

```sh
bash bin/fm-test-run.sh tests/fm-dot-mailbox.test.sh
```

The suite exercises the mailbox round trip, duplicate and restart behavior, callback validation, signing, bounded retries, renewal, and storage limits.
