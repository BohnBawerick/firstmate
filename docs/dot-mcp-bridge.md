# ChatGPT Dot MCP Mailbox Bridge

This document covers the private MCP mailbox and MCP 2.0 event bridge connecting Firstmate to ChatGPT dots.
It provides persistent queueing, callback wake events, and local operator interfaces for dispatching cloud work.

## Architecture

The bridge pairs a local persistent SQLite mailbox with an MCP 2.0 endpoint.
Firstmate submits assignments locally without exposing shell commands or file systems.
An MCP event callback wakes the dot, which retrieves the assignment, runs cloud work, and replies.

```text
[Firstmate / Operator]
        |
        v
 [fm-dot-mailbox.sh]
        |
        +---> [SQLite Mailbox Store] (messages, subscriptions, delivery logs)
        |
 [fm-dot-mailbox.py] (MCP 2.0 Server on loopback)
        |
        +--- stdio or HTTP (/mcp) <--- [tunnel-client] <--- [OpenAI Tunnel Control Plane]
        |                                                            |
        +---> Outbound Signed Webhook Callback (message.created) ---> [ChatGPT Dot Wake]
```

## Mailbox operations

The bridge exposes three MCP tools:

- `submit_message`: places a new assignment into the queue and triggers matching event deliveries.
- `get_messages`: lists queued assignments with status filtering and cursor-based pagination.
- `reply`: records task completion or progress for a specific message identifier.

The server does not expose shell tools, arbitrary code execution, or file system access.
Private data is stored in SQLite outside tracked source code.

## MCP 2.0 events and security contract

The server advertises the `message.created` event under MCP protocol version `2026-07-28`.
Subscribers receive webhook notifications when new messages match their queue filter.

### Callback verification challenge

Before accepting an event subscription, the server validates the callback destination.
It sends a POST request containing a short-lived random challenge to the destination URL.
The request is signed using the subscription's `whsec_` secret via Standard Webhooks HMAC-SHA256.
The subscriber must echo the challenge in a JSON response with status code 200.
The server verifies the echoed challenge in constant time before activating delivery.

### Destination restrictions

Production callbacks require HTTPS.
The server resolves hostnames at connection time and blocks loopback, private, link-local, and multicast IP ranges.
Redirects are rejected without following upstream targets.
For local testing and behavioral test suites, `FM_DOT_MCP_ALLOW_LOCAL_CALLBACK=1` enables loopback destinations.

## Operator CLI reference

The bash wrapper `bin/fm-dot-mailbox.sh` provides the local operator interface.

```sh
# Submit an assignment to a named queue
bin/fm-dot-mailbox.sh submit --queue worker-tasks --correlation-id task-101 "Execute analysis task"

# List pending messages
bin/fm-dot-mailbox.sh list --queue worker-tasks --status pending

# Inspect a message and its reply
bin/fm-dot-mailbox.sh get msg_0123456789abcdef

# Record a worker reply manually
bin/fm-dot-mailbox.sh reply msg_0123456789abcdef "Task completed successfully"

# View summary counts
bin/fm-dot-mailbox.sh status

# Start the local loopback MCP server
bin/fm-dot-mailbox.sh serve --host 127.0.0.1 --port 8765
```

## Connecting ChatGPT dot via Secure MCP Tunnel

Secure MCP Tunnel connects private local endpoints to OpenAI without inbound firewall ports.
Follow these steps to connect the dot:

1. Obtain a tunnel identifier from OpenAI Platform tunnel settings.
2. Ensure the tunnel has associations for both the Platform organization and ChatGPT workspace.
3. Generate a runtime API key with Tunnels Read and Use permissions.
4. Export the runtime credential in your current shell without writing it to script files:

```sh
read -rsp "Enter CONTROL_PLANE_API_KEY: " CONTROL_PLANE_API_KEY && export CONTROL_PLANE_API_KEY
```

5. Initialize the tunnel configuration profile using the official HTTP sample:

```sh
tunnel-client init \
  --sample sample_mcp_remote_no_auth \
  --profile dot-bridge \
  --tunnel-id "<tunnel-id>" \
  --mcp-server-url "http://127.0.0.1:8765/mcp"
```

6. Verify profile readiness before starting the daemon:

```sh
tunnel-client doctor --profile dot-bridge --explain
```

7. In a first terminal, start the mailbox server:

```sh
bin/fm-dot-mailbox.sh serve --host 127.0.0.1 --port 8765
```

8. In a second terminal, start the tunnel client in the foreground:

```sh
tunnel-client run --profile dot-bridge
```

9. In ChatGPT, open ChatGPT Plugins (https://chatgpt.com/plugins).
Account and workspace UI availability for custom plugins remain unverified until accessed with active credentials.
10. Select the plus button, then choose Add custom MCP server.
11. Under Connection, select Tunnel and enter the configured tunnel identifier.
12. Review the permissions and risk confirmation, then select Create as a plugin.
13. In your dot conversation, configure the monitoring task:
    "Subscribe to message.created on the dot-bridge connector for queue worker-tasks. When a message arrives, execute the brief in the target cloud environment and reply with the outcome."

## Smoke testing locally

Run the behavioral test suite to prove local mailbox round trips, challenge verification, signed callbacks, and restart persistence:

```sh
bin/fm-test-run.sh tests/fm-dot-mailbox.test.sh
```
