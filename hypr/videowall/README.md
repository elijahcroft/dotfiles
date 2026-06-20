# Video Wall + Jam

A tiling YouTube multiviewer that opens borderless/fullscreen on Hyprland, plus
a **Spotify-Jam-style** shared session: friends on the same Wi-Fi scan a QR and
add links from their phones — they land on the wall instantly. The phone page
now works like a small browser: search YouTube, preview the selected clip
inline, then add it to the wall with one tap.

## Use it

- **SUPER+Y** — open the wall (fullscreen)
- **SUPER+SHIFT+Y** — close it (and stop the server)
- On the wall:
  - **E** — editor: paste URLs to add, delete videos, clear the wall
  - **J** — jam: shows the QR + join URL for phones
  - **1–9 / 0 / M** — solo a channel's audio / mute all
  - **C** — fill ↔ fit · **?** — key help

Friends open the QR (or `http://<your-lan-ip>:8787/jam`) and either search
YouTube directly or paste a link. The lineup is shared and updates live for
everyone.

## How it works

- `scripts/video-wall.sh` starts `server.py` and opens the wall in a Chromium
  `--app` window pointed at `http://127.0.0.1:8787/index.html`.
- `server.py` — stdlib-only HTTP server. Serves the pages and a tiny JSON API
  that holds the shared lineup; bound to `0.0.0.0` so LAN phones can reach it.
  - `GET /api/state` · `POST /api/add|remove|clear|set` · `GET /api/info` · `GET /api/qr` · `GET /api/yt-search`
  - Lineup persists in `jam-state.json` (gitignored).
  - QR codes are generated offline via `qrencode` when present, else a public
    renderer is used as a fallback.
- `index.html` — the wall. Talks to the server when it's up (live polling every
  2s); falls back to a private, browser-only lineup if opened as a plain file.
- `jam.html` — the phone "add a link" page (served at `/jam`). It now includes
  YouTube search, an inline embed preview, and manual paste fallback.

## Notes / gotchas

- **Same Wi-Fi required.** The join URL uses your machine's LAN address. The
  server skips Tailscale/VPN/docker interfaces by name when picking it.
- If your Wi-Fi uses **client isolation** (common on guest/public networks),
  phones can't reach your machine — use a normal/home network or a tunnel.
- The server binds to all interfaces, so anyone on your LAN can add or remove
  videos. That's the point of a jam; only run it on networks you trust.
- Firewall: if you run one, allow inbound TCP `8787`.
