#!/usr/bin/env bash
set -euo pipefail

require_cmd() {
  local name="$1"

  if ! command -v "$name" >/dev/null 2>&1; then
    printf 'Missing required command: %s\n' "$name" >&2
    exit 1
  fi
}

require_cmd hyprctl
require_cmd jq

active_workspace="$(
  hyprctl -j activeworkspace 2>/dev/null | jq -r '.id // empty' || true
)"
clients_json="$(hyprctl -j clients)"

mapfile -t moves < <(
  jq -r '
    [
      .[]
      | select((.workspace.id? | type) == "number" and .workspace.id > 0)
      | { address, src: .workspace.id }
    ] as $clients
    | ($clients | map(.src) | unique | sort) as $sources
    | $sources
    | to_entries[]
    | .key as $index
    | .value as $src
    | ($index + 1) as $target
    | select($src != $target)
    | $clients[]
    | select(.src == $src)
    | "\($src)\t\($target)\t\(.address)"
  ' <<<"$clients_json"
)

if ((${#moves[@]} == 0)); then
  exit 0
fi

new_active_workspace="$active_workspace"

for move in "${moves[@]}"; do
  IFS=$'\t' read -r src target address <<<"$move"

  if [[ -n "$active_workspace" && "$src" == "$active_workspace" ]]; then
    new_active_workspace="$target"
  fi

  hyprctl --quiet dispatch movetoworkspacesilent "$target,address:$address"
done

if [[ -n "$new_active_workspace" && "$new_active_workspace" != "$active_workspace" ]]; then
  hyprctl --quiet dispatch workspace "$new_active_workspace"
fi
