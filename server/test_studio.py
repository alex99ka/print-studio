"""studio.py against the Firestore emulator (skipped without it). Run from server/:
npx -y firebase-tools@15.15.0 emulators:exec --only firestore --project demo-print-studio \
    --config ../firebase.json ".venv/Scripts/pytest -q"
"""

import io
from datetime import datetime, timezone
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
from PIL import Image

from app import firebase, jobs, main, studio

def picture(fmt: str, size: tuple[int, int]) -> bytes:
    out = io.BytesIO()
    Image.new("RGB", size, (240, 240, 240)).save(out, fmt)
    return out.getvalue()


PNG = picture("PNG", (200, 120))
SPIN = picture("JPEG", (600, 600))  # 6 x 6 tiles of 100 px
TOKEN_A = "a" * 22
TOKEN_B = "b" * 22


def three_mf() -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("3D/3dmodel.model", "<model/>")
    return buf.getvalue()


def test_money_rounds_vat_half_up():
    assert studio.money(18000, 2, 18) == {"unit": 18000, "qty": 2, "vatPercent": 18, "discount": 0, "net": 36000, "vat": 6480, "total": 42480}
    assert studio.money(1, 1, 18)["vat"] == 0  # 0.18 agora
    assert studio.money(3, 1, 18)["vat"] == 1  # 0.54 agora
    assert studio.money(18000, 2, 0)["total"] == 36000  # VAT off
    assert studio.money(0, 5, 18)["total"] == 0
    # A discount comes off before VAT, never below zero (same cases as test/studio_test.dart).
    assert {k: studio.money(18000, 2, 18, 3600)[k] for k in ("net", "vat", "total")} == {"net": 32400, "vat": 5832, "total": 38232}
    assert studio.money(18000, 2, 0, 40000)["total"] == 0
    assert studio.quote_total({"unit": 18000, "qty": 2, "vatPercent": 18}) == 42480  # a quote from before discounts


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
           "spin": ("s.jpg", SPIN, "image/jpeg")}
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
    assert client.get(f"/p/{TOKEN_A}/f/{vid}/preview.png").status_code == 404  # its pictures too
    assert client.get(f"/p/{TOKEN_A}/f/{vid}/preview.png?preview={vid}").status_code == 200  # the studio's preview
    assert len(client.get(f"/p/{TOKEN_A}/data?preview={vid}").json()["requests"]) == 1  # the studio's preview
    publish(db, vid)
    r = client.get(f"/p/{TOKEN_A}/data").json()["requests"][0]
    assert r["currentVersionId"] == vid and r["quote"]["total"] == 42480 and r["status"] == "waiting"
    assert r["versions"][0]["spinGrid"] == 6  # the Flag Maker's sheet, as before
    # A discounted quote: the client gets the final price only, never the unit price, the discount or the math.
    db.document("quotes/q1").update({"discount": 3600, "discountPct": 10})
    q = client.get(f"/p/{TOKEN_A}/data").json()["requests"][0]["quote"]
    assert q["total"] == 38232 and q["withVat"] and not {"unit", "qty", "discount", "discountPct", "vat", "net"} & q.keys()
    assert client.get(f"/p/{TOKEN_B}/data").json()["requests"] == []
    # A wrong price, then the right one: shown as earlier, unless the new one is a correction.
    at = lambda day: datetime(2026, 11, day, tzinfo=timezone.utc)  # noqa: E731
    db.document("quotes/q1").update({"createdAt": at(10)})
    db.document("quotes/q2").set({"requestId": "r1", "customerId": "c1", "unit": 15000, "qty": 2, "vatPercent": 0, "createdAt": at(11)})
    db.document("requests/r1").update({"quoteId": "q2"})
    assert [q["id"] for q in client.get(f"/p/{TOKEN_A}/data").json()["requests"][0]["previousQuotes"]] == ["q1"]
    db.document("quotes/q3").set({"requestId": "r1", "customerId": "c1", "unit": 15000, "qty": 2, "vatPercent": 0,
                                  "createdAt": at(12), "correction": True})
    db.document("requests/r1").update({"quoteId": "q3"})
    r = client.get(f"/p/{TOKEN_A}/data").json()["requests"][0]
    assert r["quote"]["id"] == "q3" and r["previousQuotes"] == []
    db.document("quotes/q4").set({"requestId": "r1", "customerId": "c1", "unit": 16000, "qty": 2, "vatPercent": 0, "createdAt": at(13)})
    db.document("requests/r1").update({"quoteId": "q4"})  # a real re-quote after it shows the correction only
    assert [q["id"] for q in client.get(f"/p/{TOKEN_A}/data").json()["requests"][0]["previousQuotes"]] == ["q3"]
    db.document("requests/r1").update({"quoteId": "q1"})
    # The client gets the pictures, watermarked (same size, different pixels).
    shown = client.get(f"/p/{TOKEN_A}/f/{vid}/preview.png").content
    assert shown != PNG and Image.open(io.BytesIO(shown)).size == (200, 120)
    spin = client.get(f"/p/{TOKEN_A}/f/{vid}/spin.jpg")
    assert spin.status_code == 200 and Image.open(io.BytesIO(spin.content)).size == (600, 600)
    assert client.get(f"/p/{TOKEN_B}/f/{vid}/preview.png").status_code == 404  # another customer's file
    assert client.get(f"/p/{TOKEN_A}/f/{vid}/..%2Fflagmaker_key.json").status_code == 404
    # The client never gets the print file or the recipe; the signed-in studio does.
    assert client.get(f"/p/{TOKEN_A}/f/{vid}/model.3mf").status_code == 404
    assert client.get(f"/p/{TOKEN_A}/f/{vid}/recipe.json").status_code == 404
    assert "model.3mf" not in client.get(f"/p/{TOKEN_A}/data").json()["requests"][0]["versions"][0]["files"]
    assert client.get(f"/studio/versions/{vid}/model.3mf").content.startswith(b"PK")
    db.document(f"versions/{vid}").update({"state": "draft"})  # Alex takes it back
    assert client.get(f"/p/{TOKEN_A}/f/{vid}/preview.png").status_code == 404
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


def test_client_picks_one_of_the_versions_offered_side_by_side(client, db, pushes):
    v1, v2, v3 = (client.post("/studio/requests/r1/versions", files=files()).json()["id"] for _ in range(3))
    for v in (v1, v2, v3):
        publish(db, v)
    # v3 alone: v1 and v2 are history, not on offer.
    assert client.get(f"/p/{TOKEN_A}/data").json()["requests"][0]["offered"] == [v3]
    assert client.post(f"/p/{TOKEN_A}/requests/r1/approve", json={"versionId": v1, "quoteId": "q1"}).status_code == 409
    db.document("requests/r1").update({"offeredVersionIds": [v1, v3]})  # "לצד" in the app
    assert client.get(f"/p/{TOKEN_A}/data").json()["requests"][0]["offered"] == [v1, v3]
    assert client.post(f"/p/{TOKEN_A}/requests/r1/approve", json={"versionId": v2, "quoteId": "q1"}).status_code == 409
    assert client.post(f"/p/{TOKEN_A}/requests/r1/approve", json={"versionId": v1, "quoteId": "q1"}).status_code == 200
    r = db.document("requests/r1").get().to_dict()
    assert r["approvedVersionId"] == v1 and db.document(f"versions/{v1}").get().to_dict()["state"] == "approved"


def test_client_declines_only_while_waiting(client, db, pushes):
    vid = client.post("/studio/requests/r1/versions", files=files()).json()["id"]
    assert client.post(f"/p/{TOKEN_A}/requests/r1/decline", json={}).status_code == 409  # still a draft
    publish(db, vid)
    assert client.post(f"/p/{TOKEN_B}/requests/r1/decline", json={}).status_code == 404  # another customer
    assert client.post(f"/p/{TOKEN_A}/requests/r1/decline", json={"reason": " יקר מדי "}).json() == {"ok": True}
    r = db.document("requests/r1").get().to_dict()
    assert r["status"] == "declined" and r["declinedAt"] and r["needsReply"] is True
    said = [m.to_dict() for m in db.collection("comments").get()]
    assert [(m["text"], m["from"], m["versionId"], m["versionN"]) for m in said] == [("יקר מדי", "client", vid, 1)]
    assert pushes[-1][1].startswith("❌") and pushes[-1][2] == "יקר מדי"
    shown = client.get(f"/p/{TOKEN_A}/data").json()["requests"][0]
    assert shown["status"] == "declined" and shown["declinedAt"] and shown["due"] == 0
    assert client.post(f"/p/{TOKEN_A}/requests/r1/decline", json={}).status_code == 409  # once
    assert client.post(f"/p/{TOKEN_A}/requests/r1/approve", json={"versionId": vid, "quoteId": "q1"}).status_code == 409
    assert client.post("/studio/requests/r1/versions", files=files()).status_code == 409  # locked until Alex reopens it
    # Alex reopens it (the app sets the status back): it can be approved again, and declinedAt no longer shows.
    db.document("requests/r1").update({"status": "waiting"})
    assert client.get(f"/p/{TOKEN_A}/data").json()["requests"][0]["declinedAt"] is None
    assert client.post(f"/p/{TOKEN_A}/requests/r1/decline", json={}).json() == {"ok": True}
    assert pushes[-1][2] == "בלי סיבה" and len(db.collection("comments").get()) == 1  # no reason, no comment


def test_portal_posts_are_rate_limited(client, db, pushes, monkeypatch):
    vid = client.post("/studio/requests/r1/versions", files=files()).json()["id"]
    publish(db, vid)
    for _ in range(60):
        studio._limit(TOKEN_A)
    assert client.post(f"/p/{TOKEN_A}/requests/r1/comments", json={"versionId": vid, "text": "x"}).status_code == 429


def test_delete_request_and_customer_take_everything(client, db, tmp_path, pushes):
    vid = client.post("/studio/requests/r1/versions", files=files()).json()["id"]
    publish(db, vid)
    client.post(f"/p/{TOKEN_A}/requests/r1/comments", json={"versionId": vid, "text": "שלום"})
    db.document("requests/r2").set({"customerId": "c2", "title": "other", "qty": 1, "status": "draft", "latestVersion": 0})
    assert client.delete("/studio/requests/nope").status_code == 404
    assert client.delete("/studio/requests/r1").json() == {"ok": True}
    for col in ("versions", "quotes", "comments"):
        assert not list(db.collection(col).stream()), col
    assert not db.document("requests/r1").get().exists and not (tmp_path / "files" / vid).exists()
    assert db.document("requests/r2").get().exists  # another customer's request stays
    assert client.delete("/studio/customers/c2").json() == {"ok": True}
    assert not db.document("customers/c2").get().exists and not db.document("requests/r2").get().exists
    assert db.document("customers/c1").get().exists
    assert client.get(f"/p/{TOKEN_B}/data").status_code == 404  # the deleted customer's link is dead


def test_delete_needs_sign_in(db):
    assert TestClient(main.app).delete("/studio/customers/c1").status_code == 401


def test_portal_shows_payments_and_what_is_left(client, db, pushes):
    vid = client.post("/studio/requests/r1/versions", files=files()).json()["id"]
    publish(db, vid)  # 2 x 180.00 + 18% = 424.80
    r = client.get(f"/p/{TOKEN_A}/data").json()["requests"][0]
    assert r["due"] == 0  # not approved yet: an offer, nothing owed
    client.post(f"/p/{TOKEN_A}/requests/r1/approve", json={"versionId": vid, "quoteId": "q1"})
    db.document("payments/p1").set({"requestId": "r1", "customerId": "c1", "amount": 10000, "method": "bit", "note": "מקדמה",
                                     "at": datetime(2026, 10, 20, tzinfo=timezone.utc)})
    db.document("payments/p2").set({"requestId": "x", "customerId": "c2", "amount": 999, "method": "cash"})  # someone else's
    r = client.get(f"/p/{TOKEN_A}/data").json()["requests"][0]
    assert r["due"] == 32480
    assert "payments" not in r and "paid" not in r and "מקדמה" not in json.dumps(r, ensure_ascii=False)  # no history for the client
    client.delete("/studio/requests/r1")
    assert not db.document("payments/p1").get().exists


def test_gift_portal_needs_the_google_account_that_signed_in_first(db, monkeypatch):
    """Alex, 18.11: a gift link opens only after Google sign-in; the first client account owns it."""
    accounts = {"dana": {"uid": "u-dana", "email": "Dana@gmail.com", "email_verified": True},
                "ron": {"uid": "u-ron", "email": "ron@gmail.com", "email_verified": True},
                "alex": {"uid": "u-alex", "email": "alex@example.com", "email_verified": True},
                "unverified": {"uid": "u-x", "email": "x@x.com", "email_verified": False}}

    def verify(token, app=None):
        if token not in accounts:
            raise firebase.auth.InvalidIdTokenError("bad", None)
        return accounts[token]
    monkeypatch.setattr(firebase.auth, "verify_id_token", verify)
    monkeypatch.setattr(firebase, "app", lambda: None)
    monkeypatch.setattr(firebase, "access", lambda: ({"alex@example.com"}, set()))
    browser = lambda: TestClient(main.app, base_url="https://testserver")  # noqa: E731 (the cookie is Secure)
    sign_in = lambda c, who, token=TOKEN_A: c.post(f"/p/{token}/session", json={"idToken": who})  # noqa: E731
    db.document("customers/c1").update({"kind": "gift"})

    dana = browser()
    assert dana.get(f"/p/{TOKEN_A}/data").status_code == 401
    assert dana.get(f"/p/{TOKEN_A}/guest-template.xlsx").status_code == 401
    assert browser().get(f"/p/{TOKEN_B}/data").status_code == 200  # no kind: the bare link, as before
    assert sign_in(dana, "nope").status_code == 401
    assert sign_in(dana, "unverified").status_code == 403
    assert sign_in(dana, "dana").json() == {"email": "dana@gmail.com", "studio": False}
    assert db.document("customers/c1").get().to_dict()["googleEmail"] == "dana@gmail.com"
    assert dana.get(f"/p/{TOKEN_A}/data").status_code == 200
    # Another account is refused, and Dana's link stays hers.
    ron = browser()
    assert sign_in(ron, "ron").status_code == 403
    assert ron.get(f"/p/{TOKEN_A}/data").status_code == 401
    assert db.document("customers/c1").get().to_dict()["googleUid"] == "u-dana"
    # A forged or altered cookie gets nothing; the cookie is for this link only.
    forged = browser()
    forged.cookies.set("ps", "u-dana.9999999999.0000")
    assert forged.get(f"/p/{TOKEN_A}/data").status_code == 401
    assert studio._session_who(TOKEN_B, dana.cookies.get("ps")) is None
    # Alex gets in with an allowlisted account without taking the link over.
    alex = browser()
    assert sign_in(alex, "alex").json()["studio"] is True
    assert alex.get(f"/p/{TOKEN_A}/data").status_code == 200
    assert db.document("customers/c1").get().to_dict()["googleUid"] == "u-dana"
    # The app releases the account: Dana's cookie stops working and the next account owns the link.
    db.document("customers/c1").update({"googleUid": gfirestore.DELETE_FIELD, "googleEmail": gfirestore.DELETE_FIELD})
    assert dana.get(f"/p/{TOKEN_A}/data").status_code == 401
    assert sign_in(ron, "ron").status_code == 200 and ron.get(f"/p/{TOKEN_A}/data").status_code == 200
    # A microphone customer keeps the bare link.
    db.document("customers/c1").update({"kind": "mic"})
    assert browser().get(f"/p/{TOKEN_A}/data").status_code == 200
