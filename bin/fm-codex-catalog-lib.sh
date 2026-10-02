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
      (.slug? == $model)
      and any(.supported_reasoning_levels[]?; .effort? == $effort)
    )
  ' "$catalog" >/dev/null 2>&1
}

fm_codex_catalog_models_supporting_effort() {
  local effort=$1 catalog models
  command -v jq >/dev/null 2>&1 || return 1
  catalog=$(fm_codex_catalog_path)
  models=$(jq -r --arg effort "$effort" '
    .models[]?
    | select(any(.supported_reasoning_levels[]?; .effort? == $effort))
    | .slug?
    | select(type == "string" and length > 0)
  ' "$catalog" 2>/dev/null) || return 1
  [ -z "$models" ] || printf '%s\n' "$models"
}

fm_codex_catalog_warn_dropped_effort() {
  printf 'warning: dropped codex effort %s for model %s; catalog does not advertise it\n' \
    "$1" "${2:-default}" >&2
}

fm_codex_catalog_relay_dropped_effort_warnings() {
  local output=$1 line
  while IFS= read -r line; do
    case "$line" in
      warning:\ dropped\ codex\ effort\ max\ for\ model\ *\;\ catalog\ does\ not\ advertise\ it)
        printf '%s\n' "$line" >&2
        ;;
    esac
  done <<< "$output"
}
