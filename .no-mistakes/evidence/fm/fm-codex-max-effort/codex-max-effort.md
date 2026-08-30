# Evidence: codex crewmates now launch at max reasoning effort

Intent: 'firstmate --effort max' on a codex crewmate must reach codex as
model_reasoning_effort="max" instead of being silently dropped.

## 1. The command firstmate types into the codex pane

Real bin/fm-spawn.sh, fake tmux pane captures the literal 'send-keys -l' line.
(notify hook and brief-encode tail trimmed for readability)

```
BEFORE (base 672c6d0 / HEAD^) -- fm-spawn.sh <id> <project> --model gpt-5.6-luna --effort max
  pane launch line : env -u CURSOR_AGENT -u CURSOR_INVOKED_AS env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID codex --model 'gpt-5.6-luna' --dangerously-bypass-approvals-and-sandbox

AFTER (f846341) -- same command
  pane launch line : env -u CURSOR_AGENT -u CURSOR_INVOKED_AS env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID codex --model 'gpt-5.6-luna' -c 'model_reasoning_effort="max"' --dangerously-bypass-approvals-and-sandbox
```

All five codex efforts after the change:

```
codex --model 'gpt-5.6-luna' -c 'model_reasoning_effort="low"' --dangerously-bypass-approvals-and-sandbox
codex --model 'gpt-5.6-luna' -c 'model_reasoning_effort="medium"' --dangerously-bypass-approvals-and-sandbox
codex --model 'gpt-5.6-luna' -c 'model_reasoning_effort="high"' --dangerously-bypass-approvals-and-sandbox
codex --model 'gpt-5.6-luna' -c 'model_reasoning_effort="xhigh"' --dangerously-bypass-approvals-and-sandbox
codex --model 'gpt-5.6-luna' -c 'model_reasoning_effort="max"' --dangerously-bypass-approvals-and-sandbox
```

## 2. The real codex CLI accepts that flag

codex-cli 0.150.1, logged in, run from /tmp/fm-evi.

```
$ codex exec --model gpt-5.6-luna -c 'model_reasoning_effort="bogus"' 'Reply with the single word OK.'
ERROR: [ReasoningEffortParam] [reasoning.effort] [invalid_enum_value] Invalid value: 'bogus'.
       Supported values are: 'none', 'minimal', 'low', 'medium', 'high', 'xhigh', and 'max'.

$ codex exec --model gpt-5.6-luna -c 'model_reasoning_effort="max"' 'Reply with the single word OK.'
codex
OK
tokens used
8,926
```

## 3. A crew-dispatch config that asks for codex max is no longer rejected

config/crew-dispatch.json:
```json
{"rules":[{"when":"deep refactor","use":{"harness":"codex","model":"gpt-5.6-luna","effort":"max"}}]}
```

```
$ fm-bootstrap.sh   # BEFORE (base)
CREW_DISPATCH: invalid config/crew-dispatch.json - invalid effort: codex:max

$ fm-bootstrap.sh   # AFTER (f846341)
(silence: the config validates, so bootstrap prints nothing about it)
```
