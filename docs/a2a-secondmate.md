# A2A second mates

An A2A second mate is an agent that Firstmate reaches over the [A2A protocol](https://a2a-protocol.org), such as a Hermes profile with its A2A platform enabled.
It has no terminal, home checkout or local process.
Firstmate routes work to it with ordinary `fm-send`, and each reply comes back as one correlated line in the mate's parent status channel, which wakes Firstmate like any other second-mate report.
The local commands need Bash, `jq` and Python 3.

## How a message travels

1. `fm-send <mate> "<text>"` records the parent's pending-reply expectation, as for any second mate.
2. `bin/fm-a2a-secondmate.sh send` stores the request in the mate home and registers one `a2a-reply` process-event source for it.
3. The process-event runner runs the blocking A2A `SendMessage` call outside the caller's turn.
4. When the agent answers, the adapter stores the full reply under the parent's private `data/<mate>/a2a-replies/` and appends one line to `state/<mate>.status`.

Every outbound message starts with `Message from Firstmate (the captain's coding orchestrator, not the captain):`, followed by the routed text and the mate's charter.
The receiving agent stores Firstmate's words in its memory as user turns, so this prefix is what tells them apart from the captain's own words.
Give the receiving agent a standing rule about that prefix, for example that such messages are requests from the orchestrator and never carry payment authority.

Reply lines map the A2A task state as follows.

| Task state | Status line |
|---|---|
| completed | `done [corr=...]` with a reply excerpt and a `report=` pointer to the full reply |
| input required | `needs-decision [corr=...] [key=a2a-<request>]` |
| failed, rejected or canceled | `failed [corr=...]` |
| not delivered, or outcome unknown | `blocked [corr=...] [key=a2a-<request>]` |

## Conversations and the turn cap

Each message carries an A2A `contextId`, so consecutive messages share one conversation on the agent side.
On Hermes, each `contextId` is its own gateway session, and every session of the profile shares the profile's memory.
Hermes refuses more than `A2A_MAX_PINGPONG_TURNS` turns per `contextId` (default 5, maximum 20) and resets that count after an idle hour.
The client starts a new `contextId` before it reaches the registered turn cap, and resets its own count after an idle hour.
Register a turn cap no higher than the agent's.
If the agent still refuses a turn with its anti-loop message, that turn never ran, so the client starts a new conversation and sends it once more.

## Delivery guarantees

Delivery is at most once.
The client marks a request as sending before the call.
If a send is interrupted before a reply arrives, a rerun reports the outcome as unknown and never sends it again, because the agent may already be working on it.
Check the agent's conversation before you repeat such a request.
A refused connection or a refused credential means the message never reached the agent; the blocked line says "undelivered", and it is safe to send the message again.
Hermes waits up to its `A2A_REPLY_TIMEOUT` (default 300 seconds) for the agent's answer; a slower answer arrives as a failed line, and the agent may still finish the work in its own session.

## Prepare a Hermes profile

These steps run on the Hermes host for one profile, shown here as `<profile>`.
In the profile's `.env`, set:

```sh
A2A_PEER_TOKENS=firstmate:<token>
A2A_TRUSTED_PEERS=firstmate
A2A_HOST=<tailnet address of the Hermes host>
A2A_PORT=<free port>
A2A_AGENT_NAME=<profile>
```

Enable the platform with `hermes -p <profile> config set platforms.a2a.enabled true`, then restart the gateway that serves the profile.
Hermes binds A2A to loopback unless a token is set, and refuses every dispatch on a wider bind without `A2A_TRUSTED_PEERS`.
Under a multi-profile gateway these settings are read from the profile's own `.env`, so each profile has its own listener and token.
`A2A_MAX_PINGPONG_TURNS` and `A2A_REPLY_TIMEOUT` are read from the gateway process environment, not the profile.

Check the endpoint from the Firstmate host:

```sh
curl -s http://<host>:<port>/.well-known/agent-card.json
```

An authenticated `ListTasks` call returns 200, and the same call without the token returns 401.

## Register the mate

Store the token in an owner-only file outside every repository, for example `~/.config/hermes/<profile>-a2a.env` containing `<PROFILE>_A2A_TOKEN=<token>`.
Write a short private charter that tells the agent how to answer, for example to reply in plain text and to start the reply with `[INPUT_REQUIRED]` when it needs the captain's decision.
From the parent home:

```sh
export FM_HOME="/absolute/parent/home"
bin/fm-a2a-secondmate.sh register scrooge /absolute/private/scrooge-home \
  http://<host>:<port>/ "$HOME/.config/hermes/scrooge-a2a.env" SCROOGE_A2A_TOKEN \
  "Money questions routed by Firstmate" /absolute/private/scrooge-charter.md 5
bin/fm-a2a-secondmate.sh health scrooge
bin/fm-send.sh scrooge "Subject: Connectivity check
Reply with one word."
```

`bin/fm-a2a-secondmate.sh --help` owns the arguments.
Registration writes `kind=secondmate` metadata with `transport=a2a`, the registry line, and a private home with the charter, endpoint configuration and parent-channel binding.
The home stores the credential file path and variable name, never the credential.
Registration refuses an existing record or a changed route instead of replacing it, and it requires the parent's session ownership, as does `fm-send`.

## Health and lifecycle

`health` reads the agent card and makes one authenticated `ListTasks` call.
It reports the current `contextId`, the turn count and the requests still in flight.
It never claims the agent's process is online.
`fm-peek` returns these health facts, and `fm-crew-state` reports in-flight requests as working children.
Interrupt, exit, relaunch, spawn, teardown and backlog handoff refuse an A2A route, and terminal keys are refused.
To retire a route, remove its registry line, its `state/<mate>.meta` file and its home after its replies have been read.

## Focused local verification

```sh
bash bin/fm-test-run.sh tests/fm-a2a-secondmate.test.sh
```

The suite runs a local fake A2A agent and covers registration, routing through `fm-send`, the reply line and stored report, conversation rotation, the anti-loop resend, failed replies, the no-resend rule for an interrupted send, an unreachable agent, and the lifecycle refusals.
