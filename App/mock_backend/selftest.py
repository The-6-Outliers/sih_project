"""Smoke test for the mock backend: fires a multipart sync like the app does."""
import io
import json
import urllib.request
import uuid

BASE = "http://localhost:8080"


def multipart(fields: dict, files: list[tuple[str, str, bytes]]) -> tuple[bytes, str]:
    boundary = "----coalmine" + uuid.uuid4().hex
    buf = io.BytesIO()

    def w(s):
        buf.write(s if isinstance(s, bytes) else s.encode())

    for k, v in fields.items():
        w(f"--{boundary}\r\n")
        w(f'Content-Disposition: form-data; name="{k}"\r\n\r\n')
        w(f"{v}\r\n")
    for field, filename, data in files:
        w(f"--{boundary}\r\n")
        w(f'Content-Disposition: form-data; name="{field}"; filename="{filename}"\r\n')
        w("Content-Type: image/jpeg\r\n\r\n")
        w(data)
        w("\r\n")
    w(f"--{boundary}--\r\n")
    return buf.getvalue(), f"multipart/form-data; boundary={boundary}"


def post_sync(client_id, mid):
    fields = {
        "operation": "create",
        "client_id": client_id,
        "mine_code": "WCL-UNIT-01",
        "inspector_id": "INSP-SELF",
        "inspection_type": "strata_control",
        "title": "Loose roof strata near junction B4",
        "notes": "Seam: Seam V - Shift: Night",
        "severity": "high",
        "latitude": "23.7420",
        "longitude": "86.4100",
        "accuracy": "4.5",
        "is_mocked": "false",
        "created_at": "2026-09-03T04:00:00Z",
        f"media_meta[{mid}]": json.dumps({"client_id": mid, "file_name": f"{mid}.jpg"}),
    }
    body, ctype = multipart(fields, [("media[]", f"{mid}.jpg", b"\xff\xd8\xff\xe0FAKEJPEGDATA")])
    req = urllib.request.Request(f"{BASE}/api/v1/inspections/sync", data=body,
                                 headers={"Content-Type": ctype}, method="POST")
    with urllib.request.urlopen(req) as r:
        return r.status, json.load(r)


cid = str(uuid.uuid4())
mid = str(uuid.uuid4())
print("first  sync:", post_sync(cid, mid))
print("resync same:", post_sync(cid, mid))
with urllib.request.urlopen(f"{BASE}/api/v1/inspections") as r:
    data = json.load(r)
print("stored count:", data["count"])
assert data["count"] == 1, "resync must upsert, not duplicate"
print("OK")
