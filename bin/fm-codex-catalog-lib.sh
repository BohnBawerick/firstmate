#!/usr/bin/env bash

fm_codex_catalog_path() {
  printf '%s\n' "${CODEX_HOME:-$HOME/.codex}/models_cache.json"
}

fm_codex_catalog_supports_effort() {
  local model=$1 effort=$2 catalog
  [ -n "$model" ] && [ "$model" != default ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  catalog=$(fm_codex_catalog_path)
  jq -e --arg model "$model" --arg effort "$effort" '
    any(.models[]?;
      ((.slug? // .id? // .model?) == $model)
      and any(.supported_reasoning_levels[]?; .effort? == $effort)
    )
  ' "$catalog" >/dev/null 2>&1
}

fm_codex_catalog_models_supporting_effort() {
  local effort=$1 catalog
  command -v jq >/dev/null 2>&1 || return 1
  catalog=$(fm_codex_catalog_path)
  jq -r --arg effort "$effort" '
    .models[]?
    | select(any(.supported_reasoning_levels[]?; .effort? == $effort))
    | (.slug? // .id? // .model?)
    | select(type == "string" and length > 0)
  ' "$catalog" 2>/dev/null
}

fm_codex_catalog_warn_dropped_effort() {
  printf 'warning: dropped codex effort %s for model %s; catalog does not advertise it\n' \
    "$1" "${2:-default}" >&2
}
