# OpenCode 2 primary-plugin port

The primary-plugin port is implemented.
The [OpenCode adapter reference](../.agents/skills/harness-adapters/references/harness/opencode.md) owns current operating behavior, and [turn-end guard](turnend-guard.md) owns the primary supervision contract.
[Runtime backend verification](verification/runtime-backends.md#opencode-2-launch-and-brief-delivery) records native plugin, tool-hook, turn-end, startup, and launch evidence and its refresh command.
The [shared OpenCode 2 adapter](../.opencode/plugins/lib/fm-opencode2.js) owns event subscription and tool-hook plumbing.
