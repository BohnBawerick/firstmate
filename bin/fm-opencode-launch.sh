#!/usr/bin/env bash
# OpenCode version probe and v2 interactive worker launcher.
# Usage: fm-opencode-launch.sh --major-version
#        fm-opencode-launch.sh --model <provider/model|default> --effort <level|default> --prompt <text>
# V2 removed the interactive --model flag and the v1 config environment overlay.
# Create an explicitly selected session through its local API, then attach the
# TUI with the launch prompt. This preserves project configuration and avoids
# the TUI's remembered variant overriding the requested effort.
# Each v2 worker uses a private server so plugin generations and launch-time
# environment stay local to that worker. No shared service is reloaded.
set -eu

major_version() {
  local version
  version=$(opencode --version) || { echo 'error: cannot read OpenCode version' >&2; return 1; }
  if [[ "$version" =~ ^(opencode[[:space:]]+)?v?([12])\.[0-9]+\.[0-9]+([[:space:]+-].*)?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[2]}"
  else
    printf 'error: unverified OpenCode version: %s (expected 1.x or 2.x)\n' "$version" >&2
    return 1
  fi
}

if [ "${1:-}" = --major-version ] && [ "$#" -eq 1 ]; then
  major_version
  exit
fi

model=default effort=default prompt=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --model|--effort|--prompt)
      [ "$#" -ge 2 ] || { echo "error: $1 requires a value" >&2; exit 2; }
      case "$1" in --model) model=$2 ;; --effort) effort=$2 ;; --prompt) prompt=$2 ;; esac
      shift 2
      ;;
    *) echo "error: unknown OpenCode launch argument: $1" >&2; exit 2 ;;
  esac
done
[ "$(major_version)" = 2 ] || { echo 'error: this launcher requires OpenCode v2; respawn to select the installed adapter' >&2; exit 1; }
export FM_OPENCODE_V2_WORKER=1
command -v jq >/dev/null 2>&1 || { echo 'error: OpenCode v2 launch requires jq' >&2; exit 1; }
directory=$(pwd -P)
selection=null
if [ -n "$model" ] && [ "$model" != default ]; then
  case "$model" in
    */*) provider=${model%%/*}; model_id=${model#*/} ;;
    *) echo "error: OpenCode model must use provider/model: $model" >&2; exit 2 ;;
  esac
  variant=
  case "$model_id" in *'#'*) variant=${model_id#*#}; model_id=${model_id%%#*} ;; esac
  if [ -n "$effort" ] && [ "$effort" != default ]; then
    encoded_directory=$(jq -rn --arg value "$directory" '$value | @uri')
    # The vendor CLI can truncate a large catalog when stdout is a pipe.
    catalog=$(mktemp "${TMPDIR:-/tmp}/fm-opencode-models.XXXXXX")
    trap 'rm -f "$catalog"' EXIT
    opencode api --standalone GET "/api/model?location[directory]=$encoded_directory" >"$catalog" || exit 1
    jq -e '.data | type == "array"' "$catalog" >/dev/null || {
      echo 'error: OpenCode v2 returned an invalid model catalog' >&2
      exit 1
    }
    if jq -e --arg p "$provider" --arg m "$model_id" --arg e "$effort" \
      '.data[] | select(.providerID == $p and .id == $m) | .variants[]? | select(.id == $e)' "$catalog" >/dev/null; then
      variant=$effort
    else
      printf 'warning: OpenCode v2 model %s does not advertise effort %s; using its default\n' "$model" "$effort" >&2
    fi
    rm -f "$catalog"
    trap - EXIT
  fi
  selection=$(jq -cn --arg p "$provider" --arg m "$model_id" --arg v "$variant" \
    '{providerID:$p,id:$m} + if $v == "" then {} else {variant:$v} end')
fi
body=$(jq -cn --arg directory "$directory" --argjson model "$selection" \
  '{location:{directory:$directory},agent:"build",model:$model}')
created=$(opencode api --standalone session.create --data "$body") || exit 1
session=$(printf '%s' "$created" | jq -er '.data.id | select(type == "string" and startswith("ses_"))') || {
  echo 'error: OpenCode v2 session.create returned no session id; refusing an unselected launch' >&2
  exit 1
}
export FM_OPENCODE_SESSION="$session"
exec opencode --standalone --auto --session "$session" --prompt "$prompt"
