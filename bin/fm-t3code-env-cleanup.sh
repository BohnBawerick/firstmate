#!/usr/bin/env bash
# Remove a T3 task's environment and generated Claude hooks from its launch directory.
# Usage: fm-t3code-env-cleanup.sh <directory> <parent-state-directory> <task-id>
# Codex overlays use fm-t3code-codex-env.sh's cleanup contract. Claude environment
# ownership is the task's FM_TASK_INBOX and FM_TASK_ID; FM_T3CODE_ENV_KEYS names
# its environment keys. Generated hook commands come from the existing
# <parent-state-directory>/<task-id>.claude-settings.json. Other settings remain.
set -eu
[ "$#" -eq 3 ] || { echo "usage: fm-t3code-env-cleanup.sh <directory> <parent-state-directory> <task-id>" >&2; exit 2; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/fm-t3code-codex-env.sh" cleanup "$1"
settings="$1/.claude/settings.local.json"
generated="$2/$3.claude-settings.json"
[ ! -L "$1/.claude" ] && [ ! -L "$settings" ] && [ -f "$settings" ] || exit 0
if ! grep -q '"FM_T3CODE_ENV_KEYS"' "$settings" && [ ! -f "$generated" ]; then exit 0; fi
node - "$settings" "$2" "$3" <<'JS'
const fs = require("fs");
const path = require("path");
const [file, state, id] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(file, "utf8"));
const generated = path.join(state, `${id}.claude-settings.json`);
const wiring = fs.existsSync(generated) ? JSON.parse(fs.readFileSync(generated, "utf8")) : null;
const env = data.env;
const owned = env && typeof env.FM_T3CODE_ENV_KEYS === "string"
  && env.FM_TASK_INBOX === path.join(fs.realpathSync(state), `${id}.inbox`)
  && (env.FM_TASK_ID === undefined || env.FM_TASK_ID === id);
if (owned && env.FM_TASK_ID === id && Object.keys(data.hooks ?? {}).length && !wiring) {
  throw new Error(`cannot identify the generated hooks for ${id}: ${generated} is missing`);
}
let changed = false;
if (owned) {
  for (const key of env.FM_T3CODE_ENV_KEYS.split(",")) delete env[key];
  delete env.FM_T3CODE_ENV_KEYS;
  if (!Object.keys(env).length) delete data.env;
  changed = true;
}
for (const [event, entries] of Object.entries(wiring?.hooks ?? {})) {
  if (!Array.isArray(data.hooks?.[event])) continue;
  const commands = entries.flatMap(entry => entry.hooks ?? []);
  data.hooks[event] = data.hooks[event].flatMap(entry => {
    if (!Array.isArray(entry.hooks)) return [entry];
    const kept = entry.hooks.filter(hook => !commands.some(generated =>
      hook.type === "command" && generated.type === "command" && hook.command === generated.command));
    if (kept.length === entry.hooks.length) return [entry];
    changed = true;
    return kept.length ? [{ ...entry, hooks: kept }] : [];
  });
  if (!data.hooks[event].length) delete data.hooks[event];
}
if (data.hooks && !Object.keys(data.hooks).length) delete data.hooks;
if (changed) {
  if (Object.keys(data).length) fs.writeFileSync(file, JSON.stringify(data) + "\n");
  else fs.unlinkSync(file);
}
JS
