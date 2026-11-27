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

from app import billing, firebase, jobs, main, studio

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


def test_bill_lines_finished_orders_less_paid():
    q = {"unit": 10000, "qty": 2, "vatPercent": 18, "discount": 0}
    reqs = [("r1", {"status": "delivered", "quoteId": "q1", "title": "דגל", "createdAt": "2"}),
            ("r2", {"status": "ready", "quoteId": "q2", "title": "מתנה", "createdAt": "1"}),
            ("r3", {"status": "printing", "quoteId": "q1"}),  # not finished: not billed yet
            ("r4", {"status": "delivered", "quoteId": "q1"}),  # paid in full
            ("r5", {"status": "delivered"})]  # no price
    lines = billing.bill_lines(reqs, {"q1": q, "q2": {**q, "vatPercent": 0}}, {"r1": 5000, "r4": 23600})
    assert [x["requestId"] for x in lines] == ["r2", "r1"]  # oldest first
    assert lines[1] == {"requestId": "r1", "title": "דגל", "qty": 2, "net": 20000, "vat": 3600, "total": 23600, "paid": 5000, "due": 18600}
    assert lines[0]["due"] == 20000
    # A receipt for a past payment: exactly the chosen requests, paid in full ones too.
    past = billing.bill_lines(reqs, {"q1": q}, {"r4": 23600}, only={"r4", "r3"})
    assert [(x["requestId"], x["due"]) for x in past] == [("r3", 23600), ("r4", 0)]


def test_bill_page_shows_only_switched_on_ways_and_escapes():
    b = {"number": 1001, "customerName": "<b>דנה</b>", "lang": "he", "state": "open", "net": 100, "vat": 0, "total": 100, "paid": 0, "due": 100,
         "lines": [{"requestId": "r", "title": "x", "qty": 1, "net": 100, "vat": 0, "total": 100, "paid": 0, "due": 100}]}
    page = billing.bill_html(b, {"account": "123456", "bitOn": False, "bitPhone": "0501111111", "payboxOn": True, "payboxLink": "https://pay.example/x"})
    assert "123456" in page and "0501111111" not in page and "https://pay.example/x" in page
    assert "&lt;b&gt;דנה" in page and "מע״מ" not in page  # no VAT on the bill: no VAT column
    paid = billing.bill_html({**b, "state": "paid", "receipt": {"number": "60021", "url": "https://yeshbe.co/x"}}, {"account": "123456"})
    assert "https://yeshbe.co/x" in paid and "123456" not in paid


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


def test_a_comment_with_a_picture(client, db, pushes, tmp_path):
    vid = client.post("/studio/requests/r1/versions", files=files()).json()["id"]
    publish(db, vid)
    photo = io.BytesIO()
    exif = Image.Exif()
    exif[0x010F] = "PhoneMaker"  # EXIF the client's phone added
    Image.new("RGB", (3000, 1000), (10, 120, 200)).save(photo, "JPEG", exif=exif)
    send = lambda pic=photo.getvalue(), token=TOKEN_A, **form: client.post(  # noqa: E731
        f"/p/{token}/requests/r1/comments/picture", files={"picture": ("me.jpg", pic, "image/jpeg")}, data={"versionId": vid, **form})
    assert send(token=TOKEN_B).status_code == 404
    assert send(pic=b"not a picture").status_code == 422
    assert send(pic=b"\0" * (15 * 1024 * 1024 + 1)).status_code == 413
    assert send(pin="{bad").status_code == 422
    assert send(text="כזה לוגו", pin=json.dumps({"view": "2d", "x": 0.5, "y": 0.5})).status_code == 200
    assert send().status_code == 200  # a picture alone
    cs = client.get(f"/p/{TOKEN_A}/data").json()["requests"][0]["comments"]
    assert [(c["text"], c["picture"], bool(c["pin"])) for c in cs] == [("כזה לוגו", True, True), ("", True, False)]
    assert pushes[-1][2] == "📷 תמונה"
    got = client.get(f"/p/{TOKEN_A}/c/{cs[0]['id']}")
    with Image.open(io.BytesIO(got.content)) as im:
        assert got.headers["content-type"] == "image/jpeg" and im.size == (2000, 667) and not im.getexif()
    assert client.get(f"/p/{TOKEN_B}/c/{cs[0]['id']}").status_code == 404
    assert client.get(f"/studio/comments/{cs[0]['id']}/picture").status_code == 200
    client.post(f"/p/{TOKEN_A}/requests/r1/comments", json={"versionId": vid, "text": "בלי תמונה"})
    plain = client.get(f"/p/{TOKEN_A}/data").json()["requests"][0]["comments"][-1]
    assert plain["picture"] is False and client.get(f"/p/{TOKEN_A}/c/{plain['id']}").status_code == 404
    client.delete("/studio/requests/r1")
    assert not (tmp_path / "comment_pics" / "r1").exists()


def test_reopen_moves_the_approval_to_history(client, db, pushes):
    v1 = client.post("/studio/requests/r1/versions", files=files()).json()["id"]
    publish(db, v1)
    assert client.post("/studio/requests/r1/reopen").status_code == 409  # waiting: nothing to reopen
    client.post(f"/p/{TOKEN_A}/requests/r1/approve", json={"versionId": v1, "quoteId": "q1"})
    db.document("requests/r1").update({"status": "printing"})
    assert client.post("/studio/requests/nope/reopen").status_code == 404
    assert client.post("/studio/requests/r1/reopen").json() == {"ok": True}
    r = db.document("requests/r1").get().to_dict()
    assert r["status"] == "waiting" and "approvedVersionId" not in r and "approvedAt" not in r and "approvedQuoteId" not in r
    assert [(a["versionId"], a["quoteId"]) for a in r["approvals"]] == [(v1, "q1")] and r["approvals"][0]["at"]
    assert db.document(f"versions/{v1}").get().to_dict()["state"] == "published"
    p = client.get(f"/p/{TOKEN_A}/data").json()["requests"][0]
    assert p["status"] == "waiting" and p["approved"] is None and p["due"] == 0
    # The client approves again; a paid one stays closed.
    assert client.post(f"/p/{TOKEN_A}/requests/r1/approve", json={"versionId": v1, "quoteId": "q1"}).status_code == 200
    db.document("requests/r1").update({"status": "paid"})
    assert client.post("/studio/requests/r1/reopen").status_code == 409


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


def test_product_photos_on_a_request(client, db):
    """A photo of the printed product, on the request (studio only; deleted with the request)."""
    jpg = picture("JPEG", (400, 300))
    [pid] = client.post("/studio/requests/r1/photos", files=[("photos", ("p.jpg", jpg, "image/jpeg"))]).json()["added"]
    assert [p["id"] for p in client.get("/studio/requests/r1/photos").json()] == [pid]
    assert client.get(f"/studio/requests/r1/photos/{pid}").content == jpg
    assert client.post("/studio/requests/nope/photos", files=[("photos", ("p.jpg", jpg, "image/jpeg"))]).status_code == 404
    assert client.get("/studio/customers/c1/logos").json() == []  # its own folder, not the customer's logos
    client.delete("/studio/requests/r1")
    assert client.get("/studio/requests/r1/photos").json() == []


def test_logo_photos_on_a_customer(client, db, tmp_path):
    jpg, webp = picture("JPEG", (900, 600)), picture("WEBP", (300, 300))
    added = client.post("/studio/customers/c2/logos", files=[("photos", ("a.jpg", jpg, "image/jpeg")),
                                                             ("photos", ("b.webp", webp, "image/webp"))]).json()["added"]
    listed = client.get("/studio/customers/c2/logos").json()
    assert [p["id"] for p in listed] == added and [p["type"] for p in listed] == ["image/jpeg", "image/webp"]
    assert client.get(f"/studio/customers/c2/logos/{added[0]}").content == jpg  # the original, as sent
    small = Image.open(io.BytesIO(client.get(f"/studio/customers/c2/logos/{added[0]}?thumb=200").content))
    assert small.size == (200, 133)
    # Not a picture, a missing customer, too many: nothing is kept.
    bad = client.post("/studio/customers/c2/logos", files=[("photos", ("x.jpg", jpg, "image/jpeg")), ("photos", ("y.jpg", b"<html>", "image/jpeg"))])
    assert bad.status_code == 422 and len(client.get("/studio/customers/c2/logos").json()) == 2
    assert client.post("/studio/customers/nope/logos", files=[("photos", ("a.jpg", jpg, "image/jpeg"))]).status_code == 404
    assert client.post("/studio/customers/c2/logos", files=[("photos", ("a.jpg", jpg, "image/jpeg"))] * 29).status_code == 413
    assert client.get("/studio/customers/c2/logos/..%2Fx").status_code == 404
    assert client.delete(f"/studio/customers/c2/logos/{added[1]}").json() == {"ok": True}
    assert [p["id"] for p in client.get("/studio/customers/c2/logos").json()] == added[:1]
    # The Flag Maker lists customers with photos (c2 has no request) and fetches the original with its key.
    assert client.get("/fm/logos").status_code == 401
    key = paired(client)
    [c] = client.get("/fm/logos", headers=key).json()
    assert (c["customerId"], c["name"], c["count"], c["updated"]) == ("c2", "Other", 1, listed[0]["uploaded"])
    assert client.get(f"/fm/customers/c2/logos/{added[0]}", headers=key).content == jpg
    assert client.get("/fm/customers/c2/logos/nope", headers=key).status_code == 404
    # Deleting the customer takes the photos.
    client.delete("/studio/customers/c2")
    assert not (tmp_path / "logos" / "c2").exists() and client.get("/fm/logos", headers=key).json() == []


def test_logo_photos_need_sign_in(db):
    assert TestClient(main.app).get("/studio/customers/c1/logos").status_code == 401


def test_bill_made_once_replaced_when_owed_changes_and_trash_empties(client, db, pushes):
    db.document("quotes/q1").set({"requestId": "r1", "customerId": "c1", "unit": 10000, "qty": 2, "vatPercent": 0})
    assert client.post("/studio/customers/c1/bill").status_code == 409  # a draft owes nothing
    db.document("requests/r1").update({"status": "delivered", "quoteId": "q1"})
    first = client.post("/studio/customers/c1/bill").json()
    assert (first["number"], first["due"], first["new"]) == (1001, 20000, True)
    assert client.post("/studio/customers/c1/bill").json()["id"] == first["id"]  # nothing changed: the same bill
    page = client.get(f"/b/{first['token']}")
    assert page.status_code == 200 and "1001" in page.text and "₪200.00" in page.text
    db.document("payments/p1").set({"requestId": "r1", "customerId": "c1", "amount": 5000})
    second = client.post("/studio/customers/c1/bill").json()
    assert (second["number"], second["due"]) == (1002, 15000)
    assert db.document(f"bills/{first['id']}").get().to_dict()["state"] == "replaced"
    # The monthly run skips a customer whose bill hasn't changed, and one who turned it off.
    db.document("config/billing").set({"day": 1})
    assert billing.daily(datetime(2026, 12, 2).date()) == 0
    assert billing.daily(datetime(2026, 12, 1).date()) == 0 and pushes == []
    db.document("payments/p2").set({"requestId": "r1", "customerId": "c1", "amount": 1000})
    db.document("customers/c2").update({"billing": False})
    assert billing.daily(datetime(2026, 12, 1).date()) == 1 and pushes[0][0] == "billing"
    # In the trash: the link stops working; after 30 days the bill is gone.
    db.document(f"bills/{first['id']}").update({"deletedAt": datetime(2026, 1, 1, tzinfo=timezone.utc)})
    assert client.get(f"/b/{first['token']}").status_code == 404
    billing.daily(datetime(2026, 12, 2).date())
    assert not db.document(f"bills/{first['id']}").get().exists
    # A receipt for a payment made before bills: a bill for the chosen orders, open bills untouched.
    past = client.post("/studio/customers/c1/bill", json={"requestIds": ["r1"]}).json()
    b = db.document(f"bills/{past['id']}").get().to_dict()
    assert b["past"] is True and b["lines"][0]["total"] == 20000 and b["state"] == "open"
    assert client.post("/studio/customers/c1/bill", json={"requestIds": ["nope"]}).status_code == 400


def test_regular_customer_area_needs_google_and_lists_bills(db, monkeypatch):
    """Alex, 22.11: a regular customer (לקוח קבוע) signs up with Google from the invitation; their area lists bills."""
    monkeypatch.setattr(firebase.auth, "verify_id_token", lambda token, app=None: {"uid": "u-l", "email": "l@gmail.com", "email_verified": True})
    monkeypatch.setattr(firebase, "app", lambda: None)
    monkeypatch.setattr(firebase, "access", lambda: ({"alex@example.com"}, set()))
    db.document("customers/c1").update({"returning": True, "name": "לינוי רייזר"})
    db.document("bills/b1").set({"customerId": "c1", "number": 1001, "token": "t" * 22, "state": "paid", "total": 100, "due": 100,
                                 "lines": [{}], "receipt": {"number": "60021", "url": "https://yeshbe.co/x", "to": "x"}})
    db.document("bills/b2").set({"customerId": "c1", "number": 1000, "token": "u" * 22, "state": "replaced", "lines": []})
    db.document("bills/b3").set({"customerId": "c1", "number": 1002, "token": "v" * 22, "state": "open", "lines": [],
                                 "deletedAt": datetime(2026, 1, 1, tzinfo=timezone.utc)})
    browser = TestClient(main.app, base_url="https://testserver")
    r = browser.get(f"/p/{TOKEN_A}/data")
    assert r.status_code == 401 and r.json()["detail"] == {"signIn": True, "name": "לינוי", "invited": True, "returning": True, "lang": "he"}
    assert browser.post(f"/p/{TOKEN_A}/session", json={"idToken": "x"}).status_code == 200
    data = browser.get(f"/p/{TOKEN_A}/data").json()
    assert data["customer"]["returning"] and data["customer"]["email"] == "l@gmail.com"
    assert [b["number"] for b in data["bills"]] == [1001]  # never a replaced or trashed one
    assert data["bills"][0]["receipt"] == {"number": "60021", "url": "https://yeshbe.co/x"} and data["bills"][0]["url"] == "/b/" + "t" * 22
    # The consent's "this visit only": a cookie the browser drops when it closes (no Max-Age).
    once = TestClient(main.app, base_url="https://testserver")
    r = once.post(f"/p/{TOKEN_A}/session", json={"idToken": "x", "remember": False})
    assert r.status_code == 200 and "max-age" not in r.headers["set-cookie"].lower() and once.get(f"/p/{TOKEN_A}/data").status_code == 200
    assert "max-age=15552000" in browser.post(f"/p/{TOKEN_A}/session", json={"idToken": "x"}).headers["set-cookie"].lower()
    # Signed in again, the screen no longer says "invited"; signing out ends the session.
    browser.post(f"/p/{TOKEN_A}/logout")
    assert browser.get(f"/p/{TOKEN_A}/data").json()["detail"]["invited"] is False
    # A one-time customer keeps the bare link and sees their open bill too (its pay button on the portal).
    db.document("bills/b4").set({"customerId": "c2", "number": 1003, "token": "w" * 22, "state": "open", "lines": [{}], "due": 5000})
    assert [(b["number"], b["due"]) for b in TestClient(main.app).get(f"/p/{TOKEN_B}/data").json()["bills"]] == [(1003, 5000)]


def test_e2e_bill_from_delivery_to_receipt(client, db, monkeypatch):
    """End to end, through the real routes: a delivered order with a part paid → the bill → its page → the
    regular customer's portal → the receipt (written as the app's payBill does) → paid everywhere → trash."""
    monkeypatch.setattr(firebase.auth, "verify_id_token", lambda token, app=None: {"uid": "u-l", "email": "l@gmail.com", "email_verified": True})
    monkeypatch.setattr(firebase, "app", lambda: None)
    monkeypatch.setattr(firebase, "access", lambda: ({"alex@example.com"}, set()))
    db.document("config/billing").set({"businessName": "סטודיו בדיקה", "account": "678901", "branch": "345", "bankNumber": "12",
                                       "bitOn": False, "bitPhone": "0501111111", "payboxOn": True, "payboxLink": "https://pay.example/x", "day": 1})
    db.document("customers/c1").update({"returning": True, "name": "לינוי רייזר"})
    db.document("quotes/q1").set({"requestId": "r1", "customerId": "c1", "unit": 10000, "qty": 2, "vatPercent": 18})
    db.document("requests/r1").update({"status": "delivered", "quoteId": "q1", "title": "דגל"})
    db.document("payments/p0").set({"requestId": "r1", "customerId": "c1", "amount": 3600})

    made = client.post("/studio/customers/c1/bill").json()
    assert (made["number"], made["due"]) == (1001, 20000)  # 236.00 with VAT, less 36.00 paid
    page = client.get(f"/b/{made['token']}").text
    assert all(x in page for x in ("סטודיו בדיקה", "678901", "https://pay.example/x", "₪200.00", "−₪36.00", "מע״מ"))
    assert "0501111111" not in page  # Bit is off

    browser = TestClient(main.app, base_url="https://testserver")
    assert browser.post(f"/p/{TOKEN_A}/session", json={"idToken": "x", "remember": True}).status_code == 200
    bills = browser.get(f"/p/{TOKEN_A}/data").json()["bills"]
    assert [(b["number"], b["state"], b["due"], b["url"]) for b in bills] == [(1001, "open", 20000, f"/b/{made['token']}")]

    # The receipt pasted in the app: a payment per line and the bill paid with its receipt (lib/studio payBill).
    bill = db.document(f"bills/{made['id']}")
    for line in bill.get().to_dict()["lines"]:
        db.collection("payments").add({"requestId": line["requestId"], "customerId": "c1", "amount": line["due"], "method": "transfer"})
    db.document("requests/r1").update({"status": "paid"})
    bill.update({"state": "paid", "paidAt": datetime.now(timezone.utc), "receipt": {"number": "60021", "url": "https://yeshbe.co/x", "to": "לינוי רייזר"}})

    page = client.get(f"/b/{made['token']}").text
    assert "https://yeshbe.co/x" in page and "60021" in page and "678901" not in page  # paid: the receipt, no payment details
    portal = browser.get(f"/p/{TOKEN_A}/data").json()
    assert portal["bills"][0]["state"] == "paid" and portal["bills"][0]["receipt"] == {"number": "60021", "url": "https://yeshbe.co/x"}
    assert portal["requests"] == [] or all(r["due"] == 0 for r in portal["requests"])
    assert client.post("/studio/customers/c1/bill").status_code == 409  # nothing owed any more

    bill.update({"deletedAt": datetime.now(timezone.utc)})
    assert client.get(f"/b/{made['token']}").status_code == 404
    assert browser.get(f"/p/{TOKEN_A}/data").json()["bills"] == []
