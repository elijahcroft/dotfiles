#!/usr/bin/env python3
"""Video Wall - Jam server.

Serves the wall (index.html), the phone "add a link" page (jam.html), and a
tiny JSON API that holds the *shared* lineup so friends on the same Wi-Fi can
add YouTube links from their phones, Spotify-Jam style. Submitted links go on
the wall instantly.

    server.py --port 8787 --host 0.0.0.0 --dir /path/to/videowall

The lineup is kept in jam-state.json next to this script so it survives
restarts. Everything is Python stdlib (plus optional `qrencode` for offline QR
codes) - no pip installs, to match the rest of this setup.
"""

import argparse
import json
import mimetypes
import os
import re
import shutil
import socket
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote, quote, quote_plus
from urllib.request import Request, urlopen
from urllib.error import URLError, HTTPError

LOCK = threading.Lock()
STATE = {"rev": 0, "items": []}      # items: [{"id", "by", "t"}]
STATE_PATH = None
FUNNEL_URL_PATH = None               # launcher writes the public Tailscale Funnel URL here
HAS_QRENCODE = False

ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
YT_SEARCH_LIMIT = 12


# ---------------------------------------------------------------- URL parsing
def extract_id(raw):
    """Pull an 11-char YouTube id out of a URL or bare id. Mirrors index.html."""
    s = (raw or "").strip()
    if not s:
        return None
    if ID_RE.match(s):
        return s
    try:
        u = urlparse(s if "://" in s else "https://" + s)
        host = (u.hostname or "")
        if host.startswith("www."):
            host = host[4:]
        if host == "youtu.be":
            cand = u.path.lstrip("/")[:11]
            if ID_RE.match(cand):
                return cand
        v = (parse_qs(u.query).get("v") or [None])[0]
        if v and ID_RE.match(v):
            return v
        m = re.search(r"/(?:embed|shorts|live|v)/([A-Za-z0-9_-]{11})", u.path)
        if m:
            return m.group(1)
    except Exception:
        pass
    m = re.search(r"([A-Za-z0-9_-]{11})", s)
    return m.group(1) if m else None


def parse_ids(text):
    out, seen = [], set()
    for tok in re.split(r"[\s,]+", text or ""):
        vid = extract_id(tok)
        if vid and vid not in seen:
            seen.add(vid)
            out.append(vid)
    return out


def _collect_text(value):
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        if isinstance(value.get("simpleText"), str):
            return value["simpleText"]
        runs = value.get("runs")
        if isinstance(runs, list):
            parts = []
            for run in runs:
                if isinstance(run, dict):
                    txt = run.get("text")
                    if isinstance(txt, str):
                        parts.append(txt)
            if parts:
                return "".join(parts)
        txt = value.get("text")
        if isinstance(txt, str):
            return txt
    if isinstance(value, list):
        parts = [_collect_text(v) for v in value]
        return "".join(part for part in parts if part)
    return ""


def _walk_video_renderers(node):
    if isinstance(node, dict):
        vr = node.get("videoRenderer")
        if isinstance(vr, dict):
            yield vr
        for val in node.values():
            yield from _walk_video_renderers(val)
    elif isinstance(node, list):
        for item in node:
            yield from _walk_video_renderers(item)


def _extract_js_object(html, marker):
    idx = html.find(marker)
    if idx < 0:
        return None
    idx = html.find("{", idx)
    if idx < 0:
        return None
    depth = 0
    in_str = False
    escape = False
    for pos in range(idx, len(html)):
        ch = html[pos]
        if in_str:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return html[idx:pos + 1]
    return None


def youtube_search(query, limit=YT_SEARCH_LIMIT):
    q = " ".join(str(query or "").split())
    if not q:
        return []
    url = "https://www.youtube.com/results?search_query=" + quote_plus(q)
    req = Request(url, headers={
        "User-Agent": ("Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
                       "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"),
        "Accept-Language": "en-US,en;q=0.9",
    })
    try:
        with urlopen(req, timeout=6) as resp:
            html = resp.read().decode("utf-8", "ignore")
    except (URLError, HTTPError, TimeoutError, OSError, ValueError):
        return []
    raw = (_extract_js_object(html, "var ytInitialData =")
           or _extract_js_object(html, "window[\"ytInitialData\"] =")
           or _extract_js_object(html, "ytInitialData ="))
    if not raw:
        return []
    try:
        data = json.loads(raw)
    except Exception:
        return []
    items = []
    seen = set()
    for vr in _walk_video_renderers(data):
        vid = str(vr.get("videoId", ""))
        if not ID_RE.match(vid) or vid in seen:
            continue
        seen.add(vid)
        thumbs = (((vr.get("thumbnail") or {}).get("thumbnails")) or [])
        thumb = thumbs[-1]["url"] if thumbs and isinstance(thumbs[-1], dict) \
            and isinstance(thumbs[-1].get("url"), str) else ""
        item = {
            "id": vid,
            "title": _collect_text(vr.get("title")),
            "channel": _collect_text(vr.get("ownerText")),
            "duration": _collect_text(vr.get("lengthText")),
            "views": _collect_text(vr.get("viewCountText")),
            "published": _collect_text(vr.get("publishedTimeText")),
            "thumb": thumb,
        }
        items.append(item)
        if len(items) >= limit:
            break
    return items


# ---------------------------------------------------------------- state store
def load_state():
    global STATE
    try:
        with open(STATE_PATH) as f:
            data = json.load(f)
        if isinstance(data, dict) and isinstance(data.get("items"), list):
            items = []
            for it in data["items"]:
                vid = str((it or {}).get("id", ""))
                if ID_RE.match(vid):
                    items.append({"id": vid, "by": str(it.get("by", ""))[:40],
                                  "t": int(it.get("t", 0) or 0)})
            STATE = {"rev": int(data.get("rev", 0) or 0), "items": items}
    except FileNotFoundError:
        pass
    except Exception:
        pass


def save_state():
    if not STATE_PATH:
        return
    try:
        tmp = STATE_PATH + ".tmp"
        with open(tmp, "w") as f:
            json.dump(STATE, f)
        os.replace(tmp, STATE_PATH)
    except Exception:
        pass


def bump():
    STATE["rev"] += 1
    save_state()


def add_ids(ids, by):
    have = {it["id"] for it in STATE["items"]}
    now = int(time.time())
    added = 0
    for vid in ids:
        if vid not in have:
            STATE["items"].append({"id": vid, "by": (by or "")[:40], "t": now})
            have.add(vid)
            added += 1
    if added:
        bump()
    return added


def remove_id(vid):
    before = len(STATE["items"])
    STATE["items"] = [it for it in STATE["items"] if it["id"] != vid]
    if len(STATE["items"]) != before:
        bump()


def set_ids(ids, by):
    old = {it["id"]: it for it in STATE["items"]}
    now = int(time.time())
    STATE["items"] = [old.get(vid, {"id": vid, "by": (by or "")[:40], "t": now})
                      for vid in ids]
    bump()


def clear_all():
    if STATE["items"]:
        STATE["items"] = []
        bump()


def snapshot():
    return {"rev": STATE["rev"], "count": len(STATE["items"]),
            "items": [dict(it) for it in STATE["items"]]}


# ---------------------------------------------------------------- networking
def _ip_score(ip):
    """Rank an address by how likely a phone on the same Wi-Fi can reach it.
    Note 100.64/10 (CGNAT) is a *valid* LAN range on some networks, so we keep
    it as a real candidate - the Tailscale address is excluded by interface name,
    not by range (see SKIP_IFACE), which is the only reliable signal."""
    if ip.startswith("192.168."):
        return 100
    if any(ip.startswith("172.%d." % i) for i in range(16, 32)):
        return 80
    if ip.startswith("10."):
        return 60
    if ip.startswith("100."):                 # CGNAT-addressed LAN / hotspot
        a, b = (int(x) for x in ip.split(".")[:2])
        return 40 if (a == 100 and 64 <= b <= 127) else 10
    return 10


# Virtual / VPN / container interfaces a guest's phone can't route to. The
# Tailscale (tailscale0) address lives here and must never be the join URL.
SKIP_IFACE = ("tailscale", "wg", "zt", "docker", "br-", "veth", "virbr",
              "tun", "tap", "lo")


def lan_ip():
    """The address a phone on the same Wi-Fi should dial.

    Routing to the internet on this box can go through Tailscale, so the naive
    connect-to-8.8.8.8 trick may return the (guest-unreachable) tailnet IP.
    Instead we enumerate physical interfaces and pick the best LAN address,
    skipping VPN/virtual interfaces by name.
    """
    candidates = []
    try:
        res = subprocess.run(
            ["ip", "-o", "-4", "addr", "show", "scope", "global"],
            capture_output=True, text=True, timeout=3)
        for line in res.stdout.splitlines():
            parts = line.split()
            if "inet" not in parts:
                continue
            dev = parts[1]
            if dev.startswith(SKIP_IFACE):
                continue
            ip = parts[parts.index("inet") + 1].split("/")[0]
            candidates.append((_ip_score(ip), ip))
    except Exception:
        pass
    if candidates:
        candidates.sort(reverse=True)
        return candidates[0][1]

    # Fallback: ask the routing table (may be the tailnet IP, but better than nothing).
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("8.8.8.8", 80))
        return s.getsockname()[0]
    except Exception:
        return "127.0.0.1"
    finally:
        s.close()


def public_base():
    """Public base URL (Tailscale Funnel) if the launcher published one.

    The launcher writes e.g. ``https://host.tailnet.ts.net`` to funnel-url.txt
    once Funnel is up, and deletes it on close. When present, friends on any
    network can reach the jam via that URL; otherwise we fall back to the LAN IP.
    """
    if not FUNNEL_URL_PATH:
        return None
    try:
        with open(FUNNEL_URL_PATH) as f:
            url = f.read().strip()
        return url or None
    except OSError:
        return None


def qr_svg(data):
    if not (HAS_QRENCODE and data):
        return None
    try:
        out = subprocess.run(
            ["qrencode", "-t", "SVG", "-m", "1", "-o", "-", data],
            capture_output=True, timeout=4)
        if out.returncode == 0 and out.stdout:
            return out.stdout
    except Exception:
        pass
    return None


# ---------------------------------------------------------------- HTTP handler
class Handler(BaseHTTPRequestHandler):
    server_version = "VideoWallJam/1.0"
    DIR = None

    def _send(self, code, body=b"", ctype="application/json", extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        if extra:
            for k, v in extra.items():
                self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj), "application/json")

    def _via_funnel(self):
        """True if this request arrived through Tailscale Funnel/Serve, which
        proxies with an X-Forwarded-For header. The host's own wall talks to
        127.0.0.1 directly and never sets it."""
        return self.headers.get("X-Forwarded-For") is not None

    def _is_mobile(self):
        """Phones get the simple add-a-link page; the wall is for the big screen."""
        ua = self.headers.get("User-Agent", "")
        return bool(re.search(r"Mobi|Android|iPhone|iPad|iPod|Silk|Kindle", ua))

    # ---- GET ----
    def do_GET(self):
        u = urlparse(self.path)
        path = u.path

        if path == "/api/state":
            with LOCK:
                snap = snapshot()
            self._json(snap)
            return

        if path == "/api/info":
            port = self.server.server_address[1]
            base = public_base()
            if base:
                ip = base
                join = base.rstrip("/") + "/jam"
            else:
                ip = lan_ip()
                join = "http://%s:%d/jam" % (ip, port)
            self._json({"lan_ip": ip, "port": port, "join_url": join,
                        "public": bool(base),
                        "qr": "/api/qr?data=" + quote(join, safe=""),
                        "qr_offline": HAS_QRENCODE})
            return

        if path == "/api/qr":
            data = (parse_qs(u.query).get("data") or [""])[0]
            svg = qr_svg(data)
            if svg:
                self._send(200, svg, "image/svg+xml")
            else:
                self._send(404, b"{}")
            return

        if path == "/api/yt-search":
            q = (parse_qs(u.query).get("q") or [""])[0]
            items = youtube_search(q)
            self._json({"query": q, "items": items, "count": len(items)})
            return

        # A phone that lands on the wall (bare IP / Funnel root) gets bounced to
        # the add-a-link page; the wall itself only renders on the big screen.
        if path in ("/", "", "/index.html") and self._is_mobile():
            self._send(302, b"", "text/plain", {"Location": "/jam"})
            return
        if path in ("/jam", "/jam/"):
            path = "/jam.html"
        if path in ("/", ""):
            path = "/index.html"
        self._serve_file(path)

    def do_HEAD(self):
        self.do_GET()

    # ---- POST ----
    def do_POST(self):
        path = urlparse(self.path).path
        if not path.startswith("/api/"):
            self._send(404, b"{}")
            return
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw.decode("utf-8")) if raw else {}
        except Exception:
            body = {}
        if not isinstance(body, dict):
            body = {}

        # Friends reaching the wall over the internet (Tailscale Funnel) may
        # only ADD to the lineup; clearing / reordering / removing stays with
        # the host on the local machine.
        if path in ("/api/clear", "/api/set", "/api/remove") and self._via_funnel():
            self._send(403, b'{"error":"forbidden"}')
            return

        with LOCK:
            if path == "/api/add":
                text = str(body.get("url") or body.get("text") or "")
                urls = body.get("urls")
                if isinstance(urls, list):
                    text = " ".join(str(x) for x in urls) + " " + text
                added = add_ids(parse_ids(text), body.get("by"))
                snap = snapshot()
                snap["added"] = added
                self._json(snap)
                return
            if path == "/api/remove":
                remove_id(str(body.get("id", "")))
                self._json(snapshot())
                return
            if path == "/api/set":
                src = body.get("ids")
                text = " ".join(str(x) for x in src) if isinstance(src, list) \
                    else str(body.get("text", ""))
                set_ids(parse_ids(text), body.get("by"))
                self._json(snapshot())
                return
            if path == "/api/clear":
                clear_all()
                self._json(snapshot())
                return
        self._send(404, b"{}")

    # ---- static files: web assets only, never outside DIR ----
    SERVE_EXT = {".html", ".css", ".js", ".mjs", ".svg", ".png", ".jpg",
                 ".jpeg", ".gif", ".webp", ".ico", ".woff", ".woff2", ".txt"}

    def _serve_file(self, path):
        rel = unquote(path.lstrip("/"))
        # no dot-segments / dotfiles (blocks server.py, jam-state.json, .profile)
        if any(seg.startswith(".") for seg in rel.split("/") if seg):
            self._send(404, b"NOT FOUND", "text/plain")
            return
        full = os.path.normpath(os.path.join(self.DIR, rel))
        if not (full == self.DIR or full.startswith(self.DIR + os.sep)) \
                or not os.path.isfile(full) \
                or os.path.splitext(full)[1].lower() not in self.SERVE_EXT:
            self._send(404, b"NOT FOUND", "text/plain")
            return
        ctype = mimetypes.guess_type(full)[0] or "application/octet-stream"
        try:
            with open(full, "rb") as f:
                data = f.read()
        except Exception:
            self._send(404, b"NOT FOUND", "text/plain")
            return
        self._send(200, data, ctype)

    def log_message(self, *args):
        pass  # keep the launcher's stdout quiet


def main():
    global STATE_PATH, FUNNEL_URL_PATH, HAS_QRENCODE
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--dir", default=os.path.dirname(os.path.abspath(__file__)))
    args = ap.parse_args()

    directory = os.path.abspath(args.dir)
    Handler.DIR = directory
    STATE_PATH = os.path.join(directory, "jam-state.json")
    FUNNEL_URL_PATH = os.path.join(directory, "funnel-url.txt")
    HAS_QRENCODE = shutil.which("qrencode") is not None
    mimetypes.add_type("application/javascript", ".js")
    load_state()

    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    httpd.daemon_threads = True
    print("video-wall jam server on %s:%d  (dir=%s, qr=%s)"
          % (args.host, args.port, directory,
             "offline" if HAS_QRENCODE else "fallback"))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
