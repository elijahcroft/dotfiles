#!/usr/bin/env bash
set -euo pipefail

config="${HYPR_CONFIG:-$HOME/.config/hypr/hyprland.conf}"

# Parse hyprland.conf into "KEYS<TAB>action" rows. The TAB lets us align the
# keys column with pango markup in wofi while still filtering on the whole line.
parse() {
  awk '
  function trim(value) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
    return value
  }

  function pretty_mods(value) {
    value = trim(value)
    gsub(/\$mainMod/, "SUPER", value)
    gsub(/SUPER_SHIFT/, "SUPER SHIFT", value)
    gsub(/[[:space:]]+/, "+", value)
    return value
  }

  function pretty_action(dispatcher, args, comment) {
    dispatcher = trim(dispatcher)
    args = trim(args)
    comment = trim(comment)

    if (args != "")
      action = dispatcher " " args
    else
      action = dispatcher

    if (comment != "") {
      if (comment ~ /->/) {
        sub(/^.*->[[:space:]]*/, "", comment)
        return comment
      }
      return action " (" comment ")"
    }

    return action
  }

  /^[[:space:]]*bind[[:alnum:]]*[[:space:]]*=/ {
    line = $0

    comment = ""
    hash = index(line, "#")
    if (hash > 0) {
      comment = substr(line, hash + 1)
      line = substr(line, 1, hash - 1)
    }

    sub(/^[^=]*=[[:space:]]*/, "", line)
    count = split(line, parts, ",")

    mods = pretty_mods(parts[1])
    key = trim(parts[2])
    dispatcher = count >= 3 ? parts[3] : ""
    args = ""

    if (count >= 4) {
      args = parts[4]
      for (i = 5; i <= count; i++)
        args = args "," parts[i]
    }

    if (mods == "")
      binding = key
    else
      binding = mods "+" key

    printf "%s\t%s\n", binding, pretty_action(dispatcher, args, comment)
  }
  ' "$config"
}

# Plain aligned text for terminals / piping.
if [[ "${1:-}" == "--print" ]]; then
  {
    printf '%-26s %s\n' "Keys" "Action"
    printf '%-26s %s\n' "----" "------"
    parse | while IFS=$'\t' read -r keys action; do
      printf '%-26s %s\n' "$keys" "$action"
    done
  }
  exit 0
fi

# Escape pango markup specials so binds with & < > render correctly.
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# Build the wofi menu: keys in bold white, action dimmed after a separator.
menu=$(parse | while IFS=$'\t' read -r keys action; do
  k=$(printf '%s' "$keys" | esc)
  a=$(printf '%s' "$action" | esc)
  printf '<b>%s</b>   <span alpha="60%%">%s</span>\n' "$k" "$a"
done)

# Reuse the themed wofi (same glass style as the SUPER+R launcher). dmenu mode,
# markup on, no selection action — this is a read-only cheatsheet.
printf '%s\n' "$menu" | wofi \
  --dmenu \
  --prompt "Keybinds" \
  --width 720 --height 560 \
  --lines 14 \
  --allow-markup \
  --insensitive \
  --hide-scroll \
  --cache-file /dev/null \
  >/dev/null || true
