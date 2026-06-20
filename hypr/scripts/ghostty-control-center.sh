#!/usr/bin/env bash
set -euo pipefail

CLASS="ghostty-control-center"
TITLE="QOL Center"
SPECIAL="controlcenter"
QOL="$HOME/.local/bin/qol"   # absolute: Hyprland's PATH may lack ~/.local/bin

client_address() {
  hyprctl clients -j 2>/dev/null \
    | jq -r --arg class "$CLASS" '.[] | select(.class == $class) | .address' \
    | head -n 1
}

special_shown() {
  hyprctl monitors -j 2>/dev/null \
    | jq -e --arg name "special:$SPECIAL" 'any(.[]; .specialWorkspace.name == $name)' >/dev/null
}

close_center() {
  local addr
  addr="$(client_address || true)"
  [ -n "$addr" ] && hyprctl --quiet dispatch closewindow "address:$addr"
}

spawn_ghostty() {
  ghostty \
    --class="$CLASS" \
    --title="$TITLE" \
    --font-size=11 \
    --window-padding-x=8 \
    --window-padding-y=6 \
    -e "$QOL"
}

if [ "${1:-}" = "--close" ]; then
  close_center
  exit 0
fi

# No Hyprland helpers available: just open a plain window.
if ! command -v hyprctl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  exec spawn_ghostty
fi

# Already running: just toggle the scratchpad visibility.
if addr="$(client_address)" && [ -n "$addr" ]; then
  hyprctl --quiet dispatch togglespecialworkspace "$SPECIAL"
  exit 0
fi

# First launch: spawn, then tuck the window into the special workspace.
spawn_ghostty &

for _ in {1..80}; do
  addr="$(client_address || true)"
  if [ -n "$addr" ]; then
    hyprctl --quiet dispatch movetoworkspacesilent "special:$SPECIAL,address:$addr"
    special_shown || hyprctl --quiet dispatch togglespecialworkspace "$SPECIAL"
    exit 0
  fi
  sleep 0.05
done

exit 0
