#!/usr/bin/env python3
"""
Mock governance backend for the Coal Mine Inspector app.

Stands in for the real web platform during development and the hackathon demo.
Pure Python standard library - no pip install, no Node.

Endpoints
---------
POST /api/v1/inspections/sync   multipart/form-data from the app's SyncService.
                                Fields: client_id, operation, payload,
                                inspection columns, media_meta[<id>] JSON blobs,
                                and media[] file parts.
                                Returns {"server_id": "...",
                                         "media":[{"client_id","remote_url"}]}.
                                Idempotent on client_id (re-sync is a no-op upsert).
GET  /api/v1/inspections        JSON list of everything received (newest first).
GET  /media/<file>              Serves an uploaded photo.
GET  /                          Live control-room dashboard (auto-refreshing,
                                list + map). A local stand-in for the real site.

Run
---
    python mock_backend/server.py            # binds 0.0.0.0:8080
    python mock_backend/server.py --port 9000
Point the app at it:
    flutter run --dart-define=API_BASE_URL=http://<your-lan-ip>:8080
"""
from __future__ import annotations

import argparse
import email
import json
import mimetypes
import os
import threading
import time
import uuid
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(HERE, "_data")
MEDIA_DIR = os.path.join(DATA_DIR, "media")
STORE_FILE = os.path.join(DATA_DIR, "inspections.json")

os.makedirs(MEDIA_DIR, exist_ok=True)

_LOCK = threading.Lock()
# client_id -> inspection dict
_STORE: dict[str, dict] = {}


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def _load_store() -> None:
    global _STORE
    if os.path.exists(STORE_FILE):
        try:
            with open(STORE_FILE, "r", encoding="utf-8") as fh:
                rows = json.load(fh)
            _STORE = {r["client_id"]: r for r in rows}
            print(f"[store] loaded {len(_STORE)} inspection(s)")
        except Exception as exc:  # pragma: no cover - dev tool
            print(f"[store] could not load: {exc}")


def _save_store() -> None:
    rows = sorted(_STORE.values(), key=lambda r: r.get("received_at", ""), reverse=True)
    tmp = STORE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(rows, fh, indent=2)
    os.replace(tmp, STORE_FILE)


def _parse_multipart(content_type: str, body: bytes) -> tuple[dict[str, str], list[dict]]:
    """Return (fields, files) from a multipart/form-data body using stdlib email."""
    header = f"Content-Type: {content_type}\r\nMIME-Version: 1.0\r\n\r\n".encode()
    msg = email.message_from_bytes(header + body)

    fields: dict[str, str] = {}
    files: list[dict] = []
    if not msg.is_multipart():
        return fields, files

    for part in msg.get_payload():
        disp = part.get("Content-Disposition", "")
        if "form-data" not in disp:
            continue
        name = part.get_param("name", header="Content-Disposition")
        filename = part.get_param("filename", header="Content-Disposition")
        payload = part.get_payload(decode=True) or b""
        if filename:
            files.append(
                {
                    "field": name,
                    "filename": filename,
                    "content_type": part.get_content_type(),
                    "data": payload,
                }
            )
        else:
            fields[name] = payload.decode("utf-8", "replace")
    return fields, files


def _ingest(fields: dict[str, str], files: list[dict]) -> dict:
    """Upsert one inspection bundle. Returns the sync response dict."""
    client_id = fields.get("client_id") or fields.get("id") or str(uuid.uuid4())

    with _LOCK:
        existing = _STORE.get(client_id)
        server_id = existing["server_id"] if existing else f"SRV-{uuid.uuid4().hex[:12]}"

        # media_meta[<mediaId>] -> {...}
        media_meta: dict[str, dict] = {}
        for key, raw in fields.items():
            if key.startswith("media_meta[") and key.endswith("]"):
                mid = key[len("media_meta[") : -1]
                try:
                    media_meta[mid] = json.loads(raw)
                except json.JSONDecodeError:
                    media_meta[mid] = {"raw": raw}

        saved_media: list[dict] = []
        file_iter = iter(files)
        for mid, meta in media_meta.items():
            f = next(file_iter, None)
            remote_url = None
            if f is not None:
                ext = os.path.splitext(f["filename"])[1] or ".jpg"
                disk_name = f"{mid}{ext}"
                with open(os.path.join(MEDIA_DIR, disk_name), "wb") as out:
                    out.write(f["data"])
                remote_url = f"/media/{disk_name}"
            saved_media.append(
                {
                    "client_id": mid,
                    "remote_url": remote_url,
                    "meta": meta,
                    "bytes": len(f["data"]) if f else 0,
                }
            )

        def num(v, default=0.0):
            try:
                return float(v)
            except (TypeError, ValueError):
                return default

        row = {
            "client_id": client_id,
            "server_id": server_id,
            "operation": fields.get("operation", "create"),
            "mine_code": fields.get("mine_code", "?"),
            "inspector_id": fields.get("inspector_id", "?"),
            "inspection_type": fields.get("inspection_type", "?"),
            "title": fields.get("title", "(no title)"),
            "notes": fields.get("notes", ""),
            "severity": fields.get("severity", "low"),
            "latitude": num(fields.get("latitude")),
            "longitude": num(fields.get("longitude")),
            "accuracy": num(fields.get("accuracy")),
            "is_mocked": str(fields.get("is_mocked", "false")).lower() == "true",
            "location_timestamp": fields.get("location_timestamp"),
            "created_at": fields.get("created_at"),
            "media": saved_media,
            "received_at": _now_iso(),
            "resync_count": (existing["resync_count"] + 1) if existing else 0,
        }
        _STORE[client_id] = row
        _save_store()

    flag = " [RESYNC]" if row["resync_count"] else ""
    print(
        f"[sync]{flag} {row['severity'].upper():8} {row['title'][:48]!r} "
        f"({len(saved_media)} photo(s))  client={client_id[:8]} -> {server_id}"
    )
    return {
        "server_id": server_id,
        "id": server_id,
        "media": [{"client_id": m["client_id"], "remote_url": m["remote_url"]} for m in saved_media],
        "received_at": row["received_at"],
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "CoalMineMock/1.0"

    # --- helpers -----------------------------------------------------------
    def _send(self, code: int, body: bytes, ctype: str = "application/json") -> None:
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code: int, obj) -> None:
        self._send(code, json.dumps(obj).encode("utf-8"))

    def log_message(self, fmt, *args):  # quieter console
        return

    # --- verbs -----------------------------------------------------------
    def do_OPTIONS(self):
        self._send(204, b"")

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/" or path == "/index.html":
            self._send(200, DASHBOARD_HTML.encode("utf-8"), "text/html; charset=utf-8")
            return
        if path == "/api/v1/inspections":
            with _LOCK:
                rows = sorted(
                    _STORE.values(), key=lambda r: r.get("received_at", ""), reverse=True
                )
            self._json(200, {"count": len(rows), "inspections": rows})
            return
        if path == "/api/v1/health":
            self._json(200, {"ok": True, "time": _now_iso(), "stored": len(_STORE)})
            return
        if path.startswith("/media/"):
            fname = os.path.basename(path[len("/media/") :])
            fpath = os.path.join(MEDIA_DIR, fname)
            if os.path.isfile(fpath):
                ctype = mimetypes.guess_type(fpath)[0] or "application/octet-stream"
                with open(fpath, "rb") as fh:
                    self._send(200, fh.read(), ctype)
            else:
                self._json(404, {"error": "not found"})
            return
        self._json(404, {"error": "not found", "path": path})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        ctype = self.headers.get("Content-Type", "")

        if path.rstrip("/") == "/api/v1/inspections/sync":
            try:
                if "multipart/form-data" in ctype:
                    fields, files = _parse_multipart(ctype, body)
                elif "application/json" in ctype:
                    payload = json.loads(body or b"{}")
                    insp = payload.get("inspection", payload)
                    fields = {k: (json.dumps(v) if isinstance(v, (dict, list)) else str(v))
                              for k, v in insp.items()}
                    files = []
                else:
                    fields, files = {}, []
                resp = _ingest(fields, files)
                self._json(200, resp)
            except Exception as exc:  # pragma: no cover - dev tool
                import traceback

                traceback.print_exc()
                self._json(500, {"error": str(exc)})
            return
        self._json(404, {"error": "not found", "path": path})


DASHBOARD_HTML = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Coal Mine Governance - Control Room (mock)</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<style>
  :root { color-scheme: light dark; }
  * { box-sizing: border-box; }
  body { margin: 0; font: 14px/1.5 system-ui, -apple-system, Segoe UI, Roboto, sans-serif;
         background: #0f1115; color: #e8eaed; }
  header { padding: 12px 18px; background: #1b5e20; color: #fff; display: flex;
           align-items: center; gap: 14px; }
  header h1 { font-size: 16px; margin: 0; font-weight: 600; }
  header .pill { background: rgba(255,255,255,.18); padding: 2px 10px; border-radius: 999px; font-size: 12px; }
  .wrap { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; padding: 12px; height: calc(100vh - 52px); }
  #map { border-radius: 10px; height: 100%; }
  .panel { background: #171a21; border-radius: 10px; overflow: auto; padding: 8px; }
  .card { border: 1px solid #262b36; border-left-width: 5px; border-radius: 8px;
          padding: 10px 12px; margin: 8px; background: #10131a; }
  .card h3 { margin: 0 0 4px; font-size: 14px; }
  .card .meta { color: #9aa0aa; font-size: 12px; }
  .row { display: flex; gap: 8px; flex-wrap: wrap; margin-top: 6px; }
  .row img { width: 84px; height: 84px; object-fit: cover; border-radius: 6px; border: 1px solid #262b36; }
  .tag { font-size: 11px; padding: 1px 8px; border-radius: 999px; background: #262b36; }
  .sev-low    { border-left-color: #43a047; }
  .sev-medium { border-left-color: #f9a825; }
  .sev-high   { border-left-color: #fb8c00; }
  .sev-critical { border-left-color: #e53935; }
  .mock { color: #ff6f60; font-weight: 600; }
  .empty { color: #9aa0aa; padding: 24px; text-align: center; }
</style>
</head>
<body>
<header>
  <h1>Coal Mine Governance - Control Room</h1>
  <span class="pill" id="count">0 inspections</span>
  <span class="pill">mock backend - stand-in for the real platform</span>
  <span class="pill" id="clock"></span>
</header>
<div class="wrap">
  <div id="map"></div>
  <div class="panel" id="list"><div class="empty">Waiting for the field app to sync...</div></div>
</div>
<script>
  const map = L.map('map').setView([23.75, 86.42], 6);   // Jharia coalfield-ish
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png',
    { attribution: '(c) OpenStreetMap', maxZoom: 19 }).addTo(map);
  let markers = [];
  const sevColor = { low:'#43a047', medium:'#f9a825', high:'#fb8c00', critical:'#e53935' };

  async function tick() {
    document.getElementById('clock').textContent = new Date().toLocaleTimeString();
    let data;
    try { data = await (await fetch('/api/v1/inspections')).json(); }
    catch (e) { return; }
    const rows = data.inspections || [];
    document.getElementById('count').textContent = rows.length + ' inspections';

    markers.forEach(m => map.removeLayer(m));
    markers = [];
    const list = document.getElementById('list');
    if (!rows.length) { list.innerHTML = '<div class="empty">Waiting for the field app to sync...</div>'; return; }

    list.innerHTML = '';
    const pts = [];
    for (const r of rows) {
      if (r.latitude || r.longitude) {
        const mk = L.circleMarker([r.latitude, r.longitude],
          { radius: 9, color: sevColor[r.severity] || '#888', fillOpacity: .8 })
          .addTo(map).bindPopup(`<b>${r.title}</b><br>${r.mine_code} - ${r.severity}`);
        markers.push(mk); pts.push([r.latitude, r.longitude]);
      }
      const imgs = (r.media || []).filter(m => m.remote_url)
        .map(m => `<img src="${m.remote_url}" alt="evidence">`).join('');
      const card = document.createElement('div');
      card.className = 'card sev-' + (r.severity || 'low');
      card.innerHTML = `
        <h3>${r.title}</h3>
        <div class="meta">${r.mine_code} &middot; ${r.inspection_type} &middot; ${r.inspector_id}
          &middot; server id ${r.server_id}${r.resync_count ? ' &middot; re-synced x' + r.resync_count : ''}</div>
        <div class="row">
          <span class="tag">${r.severity}</span>
          <span class="tag">lat ${(+r.latitude).toFixed(4)}, lng ${(+r.longitude).toFixed(4)}</span>
          <span class="tag">+/- ${(+r.accuracy).toFixed(0)} m</span>
          ${r.is_mocked ? '<span class="tag mock">MOCK GPS</span>' : ''}
        </div>
        <div class="meta" style="margin-top:6px">${(r.notes || '').replace(/</g,'&lt;')}</div>
        <div class="row">${imgs}</div>
        <div class="meta" style="margin-top:6px">received ${r.received_at}</div>`;
      list.appendChild(card);
    }
    if (pts.length) map.fitBounds(pts, { padding: [40, 40], maxZoom: 13 });
  }
  tick();
  setInterval(tick, 2000);
</script>
</body>
</html>
"""


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=8080)
    args = ap.parse_args()

    _load_store()
    httpd = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"Coal Mine Inspector mock backend")
    print(f"  dashboard : http://localhost:{args.port}/")
    print(f"  sync API  : POST http://<lan-ip>:{args.port}/api/v1/inspections/sync")
    print(f"  data dir  : {DATA_DIR}")
    print("Ctrl+C to stop.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
