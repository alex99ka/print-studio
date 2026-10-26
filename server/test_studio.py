"""studio.py against the Firestore emulator (skipped without it). Run from server/:
npx -y firebase-tools@15.15.0 emulators:exec --only firestore --project demo-print-studio \
    --config ../firebase.json ".venv/Scripts/pytest -q"
"""

import io
import json
import os
import zipfile

os.environ.setdefault("GOOGLE_CLOUD_PROJECT", "demo-print-studio")
os.environ.setdefault("GITHUB_REPO", "alex99ka/print-studio")
os.environ["RUN_JOBS"] = "0"

import pytest
import requests
from fastapi.testclient import TestClient
from google.auth.credentials import AnonymousCredentials
from google.cloud import firestore as gfirestore

from app import firebase, jobs, main, studio

PNG = b"\x89PNG\r\n\x1a\n" + b"0" * 32
GLB = b"glTF" + b"\x02\x00\x00\x00" + b"0" * 32
TOKEN_A = "a" * 22
TOKEN_B = "b" * 22


def three_mf() -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("3D/3dmodel.model", "<model/>")
    return buf.getvalue()


def test_money_rounds_vat_half_up():
    assert studio.money(18000, 2, 18) == {"unit": 18000, "qty": 2, "vatPercent": 18, "net": 36000, "vat": 6480, "total": 42480}
    assert studio.money(1, 1, 18)["vat"] == 0  # 0.18 agora
    assert studio.money(3, 1, 18)["vat"] == 1  # 0.54 agora
    assert studio.money(18000, 2, 0)["total"] == 36000  # VAT off
    assert studio.money(0, 5, 18)["total"] == 0


@pytest.fixture
def db(tmp_path, monkeypatch):
    if not os.environ.get("FIRESTORE_EMULATOR_HOST"):
        pytest.skip("needs the Firestore emulator")
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    host = os.environ["FIRESTORE_EMULATOR_HOST"]
    requests.delete(f"http://{host}/emulator/v1/projects/demo-print-studio/databases/(default)/documents", timeout=10)
    # The emulator needs no credentials; CI has none, so don't let Admin look for them.
    d = gfirestore.Client(project="demo-print-studio", credentials=AnonymousCredentials())
    monkeypatch.setattr(firebase, "db", lambda: d)
    d.document("customers/c1").set({"name": "INTERVIEW", "lang": "he", "portalToken": TOKEN_A})
    d.document("customers/c2").set({"name": "Other", "lang": "en", "portalToken": TOKEN_B})
    d.document("requests/r1").set({"customerId": "c1", "customerName": "INTERVIEW", "title": "אלכס ❤ אביטל",
                                   "qty": 2, "status": "draft", "latestVersion": 0})
    studio._posts.clear()
    return d


@pytest.fixture
def pushes(monkeypatch):
    out = []
    monkeypatch.setattr(jobs, "users", lambda: [("alex", {"fcmTokens": ["t"]})])
    monkeypatch.setattr(jobs, "send_to", lambda people, kind, title, body, data=None: out.append((kind, title, body)))
    return out


@pytest.fixture
def client(db):
    main.app.dependency_overrides[firebase.current_user] = lambda: {"email": "alex@example.com"}
    yield TestClient(main.app)
    main.app.dependency_overrides.clear()


def files(**extra):
    out = {"preview": ("p.png", PNG, "image/png"), "model": ("m.3mf", three_mf(), "application/octet-stream"),
           "recipe": ("r.json", json.dumps({"first": "אלכס"}).encode(), "application/json"),
           "plate": ("p.glb", GLB, "model/gltf-binary")}
    out.update(extra)
    return out


def paired(client) -> dict:
    return {"X-Studio-Key": client.post("/studio/flagmaker-key").json()["key"]}


def publish(db, vid, quote_unit=18000):
    """What the app does when Alex presses "פרסם ללקוח" (its own write, checked by the rules)."""
    db.document(f"versions/{vid}").update({"state": "published"})
    db.document("quotes/q1").set({"requestId": "r1", "customerId": "c1", "unit": quote_unit, "qty": 2, "vatPercent": 18})
    db.document("requests/r1").update({"status": "waiting", "publishedVersionId": vid, "quoteId": "q1"})


def test_flagmaker_needs_its_key(client):
    assert client.get("/fm/requests").status_code == 401
    key = paired(client)
    assert client.get("/fm/requests", headers=key).status_code == 200
    assert client.get("/fm/requests", headers={"X-Studio-Key": "wrong"}).status_code == 401
    paired(client)  # pairing again revokes the old key
    assert client.get("/fm/requests", headers=key).status_code == 401


def test_flagmaker_uploads_numbered_versions(client, db):
    key = paired(client)
    assert [r["id"] for r in client.get("/fm/requests", headers=key).json()] == ["r1"]
    v1 = client.post("/fm/requests/r1/versions", headers=key, files=files(), data={"note": "first"}).json()
    v2 = client.post("/fm/requests/r1/versions", headers=key, files=files()).json()
    assert (v1["n"], v2["n"]) == (1, 2)
    v = db.document(f"versions/{v1['id']}").get().to_dict()
    assert v["state"] == "draft" and v["customerId"] == "c1" and v["note"] == "first" and "model.3mf" in v["files"]
    assert db.document("requests/r1").get().to_dict()["latestVersion"] == 2
    r = client.get(f"/fm/versions/{v1['id']}/recipe", headers=key)
    assert r.json() == {"first": "אלכס"}


def test_upload_checks_the_files(client, tmp_path):
    bad = client.post("/studio/requests/r1/versions", files=files(preview=("p.png", b"<html>", "image/png")))
    assert bad.status_code == 422
    assert client.post("/studio/requests/nope/versions", files=files()).status_code == 404
    assert not (tmp_path / "files").exists() or not any((tmp_path / "files").iterdir())


def test_upload_needs_sign_in(db):
    assert TestClient(main.app).post("/studio/requests/r1/versions", files=files()).status_code in (401, 403)


def test_portal_shows_only_published(client, db):
    assert client.get(f"/p/{'x' * 22}/data").status_code == 404
    assert client.get(f"/p/{TOKEN_A}/data").json()["requests"] == []  # nothing published yet
    vid = client.post("/studio/requests/r1/versions", files=files()).json()["id"]
    assert client.get(f"/p/{TOKEN_A}/data").json()["requests"] == []  # a draft
    assert len(client.get(f"/p/{TOKEN_A}/data?preview={vid}").json()["requests"]) == 1  # the studio's preview
    publish(db, vid)
    r = client.get(f"/p/{TOKEN_A}/data").json()["requests"][0]
    assert r["currentVersionId"] == vid and r["quote"]["total"] == 42480 and r["status"] == "waiting"
    assert client.get(f"/p/{TOKEN_B}/data").json()["requests"] == []
    assert client.get(f"/p/{TOKEN_A}/f/{vid}/preview.png").content == PNG
    assert client.get(f"/p/{TOKEN_B}/f/{vid}/preview.png").status_code == 404  # another customer's file
    assert client.get(f"/p/{TOKEN_A}/f/{vid}/..%2Fflagmaker_key.json").status_code == 404
    page = client.get(f"/p/{TOKEN_A}")
    assert page.status_code == 200 and "Content-Security-Policy" in page.headers


def test_customer_comments_and_pins(client, db, pushes):
    vid = client.post("/studio/requests/r1/versions", files=files()).json()["id"]
    body = {"versionId": vid, "text": "אפשר להגדיל את הלב?", "pin": {"view": "2d", "x": 0.4, "y": 0.6}}
    assert client.post(f"/p/{TOKEN_A}/requests/r1/comments", json=body).status_code == 404  # not published
    publish(db, vid)
    assert client.post(f"/p/{TOKEN_B}/requests/r1/comments", json=body).status_code == 404
    assert client.post(f"/p/{TOKEN_A}/requests/r1/comments", json={**body, "text": "   "}).status_code == 422
    assert client.post(f"/p/{TOKEN_A}/requests/r1/comments", json=body).status_code == 200
    c = client.get(f"/p/{TOKEN_A}/data").json()["requests"][0]["comments"][0]
    assert c["from"] == "client" and c["pin"]["view"] == "2d" and c["versionN"] == 1
    assert db.document("requests/r1").get().to_dict()["needsReply"] is True
    assert pushes and pushes[0][0] == "client" and "INTERVIEW" in pushes[0][1]


def test_approval_is_one_step_and_checks_what_is_current(client, db, pushes):
    v1 = client.post("/studio/requests/r1/versions", files=files()).json()["id"]
    publish(db, v1)
    stale = client.post(f"/p/{TOKEN_A}/requests/r1/approve", json={"versionId": v1, "quoteId": "old"})
    assert stale.status_code == 409
    assert client.post(f"/p/{TOKEN_B}/requests/r1/approve", json={"versionId": v1, "quoteId": "q1"}).status_code == 404
    assert client.post(f"/p/{TOKEN_A}/requests/r1/approve", json={"versionId": v1, "quoteId": "q1"}).status_code == 200
    r = db.document("requests/r1").get().to_dict()
    assert r["status"] == "approved" and r["approvedVersionId"] == v1 and r["approvedQuoteId"] == "q1"
    assert db.document(f"versions/{v1}").get().to_dict()["state"] == "approved"
    assert "424.80" in pushes[-1][2]
    assert client.post(f"/p/{TOKEN_A}/requests/r1/approve", json={"versionId": v1, "quoteId": "q1"}).status_code == 409
    # An approved request is locked: no new versions.
    assert client.post("/studio/requests/r1/versions", files=files()).status_code == 409


def test_portal_posts_are_rate_limited(client, db, pushes, monkeypatch):
    vid = client.post("/studio/requests/r1/versions", files=files()).json()["id"]
    publish(db, vid)
    for _ in range(60):
        studio._limit(TOKEN_A)
    assert client.post(f"/p/{TOKEN_A}/requests/r1/comments", json={"versionId": vid, "text": "x"}).status_code == 429
