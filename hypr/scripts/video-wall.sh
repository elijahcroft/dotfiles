#!/usr/bin/env bash
# Video Wall - a tiling YouTube multiviewer with a Spotify-Jam-style shared
# session (friends scan a QR to add links from their phones).
#
# It lives on its own Hyprland *special workspace* ("videowall"), so SUPER+Y
# toggles it up and away like a scratchpad:
#
#   video-wall.sh           toggle the wall on / off   (SUPER+Y)
#   video-wall.sh --close   fully quit it (kill window + local server)  (SUPER+Shift+Y)
#
# The first toggle launches the server + a borderless Chromium app window and
# parks it on the special workspace. Later toggles just show/hide that
# workspace, so the jam keeps running in the background while it's hidden.
#
# Served over http (not file://) on purpose: YouTube's embed rejects file://
# origins ("Error 153") but accepts a real http origin. The server binds to
# 0.0.0.0 so phones on the LAN can reach the add page.

set -euo pipefail

APP_DIR="$HOME/.config/hypr/videowall"
APP_FILE="$APP_DIR/index.html"
SERVER="$APP_DIR/server.py"
PROFILE="$APP_DIR/.profile"   # dedicated browser profile
PORT=8787
URL="http://127.0.0.1:${PORT}/index.html"
WIN_TITLE="VIDEO WALL"        # chromium --app ignores --class, so match on title
SPECIAL="videowall"           # name of the special (scratchpad) workspace
FUNNEL_FILE="$APP_DIR/funnel-url.txt"  # public Tailscale Funnel URL, while live

have_hypr() { command -v hyprctl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; }

# Public https URL for this node (e.g. https://host.tailnet.ts.net), or empty.
ts_funnel_url() {
  command -v tailscale >/dev/null 2>&1 || return 1
  local dns
  dns="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty')"
  dns="${dns%.}"   # strip the trailing dot MagicDNS includes
  [ -n "$dns" ] || return 1
  printf 'https://%s' "$dns"
}

notify() {
  if command -v notify-send >/dev/null 2>&1; then
    notify-send "Video wall" "$1"
  else
    printf '%s\n' "$1" >&2
  fi
}

# 0 if something is already listening on PORT (bash builtin, no deps).
port_open() { (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; }

# Address of the wall window, or empty if it isn't open.
wall_addr() {
  have_hypr || return 0
  hyprctl -j clients 2>/dev/null \
    | jq -r --arg t "$WIN_TITLE" 'first(.[] | select(.title == $t) | .address) // empty'
}

# Is the videowall special workspace currently shown on any monitor?
special_shown() {
  have_hypr || return 1
  hyprctl -j monitors 2>/dev/null \
    | jq -e --arg n "special:$SPECIAL" 'any(.[]; .specialWorkspace.name == $n)' >/dev/null 2>&1
}

close_wall() {
  if have_hypr; then
    hyprctl -j clients \
      | jq -r --arg t "$WIN_TITLE" '.[] | select(.title == $t) | .address' \
      | while read -r addr; do
          [ -n "$addr" ] && hyprctl --quiet dispatch closewindow "address:$addr"
        done
  fi
  pkill -f "$SERVER" 2>/dev/null || true
  pkill -f "http.server ${PORT}" 2>/dev/null || true   # legacy server (pre-jam)
  # take the public Funnel down with the wall so nothing stays exposed
  command -v tailscale >/dev/null 2>&1 && timeout 15 tailscale funnel reset >/dev/null 2>&1 || true
  rm -f "$FUNNEL_FILE"
}

case "${1:-}" in
  --close | close)
    close_wall
    exit 0
    ;;
esac

# ---- Already running? Just toggle the special workspace and bail. ----
if [ -n "$(wall_addr)" ]; then
  hyprctl --quiet dispatch togglespecialworkspace "$SPECIAL"
  exit 0
fi

[ -f "$APP_FILE" ] || { notify "Missing $APP_FILE"; exit 1; }
[ -f "$SERVER" ]   || { notify "Missing $SERVER"; exit 1; }

# ---- Bring up the jam server unless one is already running. ----
if ! port_open; then
  command -v python3 >/dev/null 2>&1 || { notify "python3 not found (needed to serve the app)."; exit 1; }
  setsid python3 "$SERVER" --port "$PORT" --host 0.0.0.0 --dir "$APP_DIR" >/dev/null 2>&1 &
  disown 2>/dev/null || true
  for _ in $(seq 1 25); do port_open && break; sleep 0.2; done
fi

# ---- Publish the jam on the internet via Tailscale Funnel, so friends on any
# network (not just this Wi-Fi) can scan the QR and add links. Best-effort and
# backgrounded: if Funnel isn't enabled on the tailnet the wall still works and
# the QR just falls back to the LAN URL. The server picks up funnel-url.txt the
# moment it appears; we tear it down again on --close. ----
rm -f "$FUNNEL_FILE"
(
  pub="$(ts_funnel_url)" || exit 0
  # Bring Funnel up, then *confirm* it's really serving our port before we
  # advertise the public URL — a denied or disabled Funnel must fall back to
  # the LAN URL, never hand phones a dead link. Reasons land in funnel.log.
  timeout 25 tailscale funnel --bg "$PORT" >"$APP_DIR/funnel.log" 2>&1 || true
  if tailscale funnel status 2>/dev/null | grep -q "127.0.0.1:$PORT"; then
    printf '%s' "$pub" > "$FUNNEL_FILE"
  fi
) >/dev/null 2>&1 &
disown 2>/dev/null || true

# Tell the user where friends can join (press SHARE / J on the wall for the QR).
JOIN_URL="$(python3 -c "import urllib.request, json
try:
    d = json.load(urllib.request.urlopen('http://127.0.0.1:${PORT}/api/info', timeout=3))
    print(d.get('join_url', ''))
except Exception:
    print('')" 2>/dev/null || true)"
if [ -n "$JOIN_URL" ]; then
  notify "Jam open · friends add at ${JOIN_URL}  (press SHARE / J on the wall for the QR)"
else
  notify "Video wall open (press SHARE / J for the jam QR)"
fi

# ---- First Chromium-based browser we can find. ----
browser=""
for b in chromium google-chrome-stable google-chrome brave brave-browser vivaldi-stable; do
  if command -v "$b" >/dev/null 2>&1; then browser="$b"; break; fi
done
[ -n "$browser" ] || { notify "No Chromium-based browser found."; exit 1; }

setsid "$browser" \
  --app="$URL" \
  --user-data-dir="$PROFILE" \
  --ozone-platform-hint=auto \
  --no-first-run \
  --no-default-browser-check \
  --disable-features=Translate,InfiniteSessionRestore \
  >/dev/null 2>&1 &
disown 2>/dev/null || true

# ---- Park the window on the special workspace, reveal it, go fullscreen. ----
if have_hypr; then
  addr=""
  for _ in $(seq 1 60); do
    addr="$(wall_addr)"; [ -n "$addr" ] && break
    sleep 0.2
  done
  if [ -n "$addr" ]; then
    hyprctl --quiet dispatch movetoworkspacesilent "special:$SPECIAL,address:$addr"
    special_shown || hyprctl --quiet dispatch togglespecialworkspace "$SPECIAL"
    hyprctl --quiet dispatch focuswindow "address:$addr"
    hyprctl --quiet dispatch fullscreen 0
  fi
fi
