"""The shop website's routes (app/website.py) against a pretend Supabase. No network, no Firebase.
Run: .venv/Scripts/pytest -q test_website.py (from server/)."""

import io
import json
import os
import re

os.environ.setdefault("GOOGLE_CLOUD_PROJECT", "demo-print-studio")
os.environ.setdefault("GITHUB_REPO", "alex99ka/print-studio")
os.environ["RUN_JOBS"] = "0"

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app import firebase, jobs, main, website

KEYS = {"gifts": "slug", "site_texts": "key", "leads": "id"}
GIFT = {"name": {"he": "מטבע", "en": "Coin", "ru": "Жетон"}, "text": {"he": "א", "en": "a", "ru": "я"},
        "kind": "pocket", "min_qty": 30, "lead_days": 14}
META = {"size_mm": [27, 42, 5], "spin": {"cols": 24, "rows": 7, "start": [1, 0], "tile": 640}}


class Reply:
    def __init__(self, status, body):
        self.status_code, self.ok, self.content, self._body = status, status < 400, json.dumps(body).encode(), body

    def json(self):
        return self._body


class Supabase:
    """PostgREST as website.py uses it: one table, an optional <key>=eq.<value> filter."""

    def __init__(self):
        self.tables = {t: {} for t in KEYS}
        self.calls = []

    def __call__(self, method, url, json=None, headers=None, timeout=None):
        assert headers["apikey"] == "service-key" and timeout
        table, _, query = url.split("/rest/v1/")[1].partition("?")
        rows, key = self.tables[table], KEYS[table]
        self.calls.append((method, table))
        want = re.search(rf"{key}=eq\.([^&]+)", query)
        hit = [k for k in rows if not want or str(k) == want.group(1)]
        if method == "GET":
            return Reply(200, [rows[k] for k in hit])
        if method == "POST":
            if json[key] in rows and "merge-duplicates" not in headers["Prefer"]:
                return Reply(409, {"code": "23505", "message": "duplicate key value"})
            rows[json[key]] = {**rows.get(json[key], {}), **json}
            return Reply(201, [rows[json[key]]])
        if method == "PATCH":
            for k in hit:
                rows[k].update(json)
            return Reply(200, [rows[k] for k in hit])
        return Reply(200, [rows.pop(k) for k in hit])


@pytest.fixture
def sb(monkeypatch, tmp_path):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    monkeypatch.setenv("SUPABASE_URL", "https://x.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "service-key")
    fake = Supabase()
    monkeypatch.setattr(website.requests, "request", fake)
    return fake


@pytest.fixture
def client(sb):
    main.app.dependency_overrides[firebase.current_user] = lambda: {"email": "alex@example.com"}
    yield TestClient(main.app)
    main.app.dependency_overrides.clear()


def picture(kind="JPEG", size=(40, 30), mode="RGB") -> bytes:
    out = io.BytesIO()
    Image.new(mode, size, "red").save(out, kind)
    return out.getvalue()


def add(client, slug="cart-coin", **changes):
    return client.post("/website/gifts", json={**GIFT, "slug": slug, **changes})


# --- who gets in ----------------------------------------------------------------------


def test_every_website_route_needs_a_signed_in_user_or_a_key(sb):
    """Nothing under /website answers a stranger; only the pictures are public."""
    c = TestClient(main.app)
    routes = [(m, r.path) for r in website.router.routes for m in r.methods]
    assert len(routes) >= 14
    for method, path in routes:
        r = c.request(method, path.replace("{slug}", "a").replace("{key}", "hero.h1").replace("{lid}", "1").replace("{name}", "photo.jpg"), json={})
        if path.startswith("/gifts/"):
            assert r.status_code == 404
        elif path == "/website/lead":
            assert r.status_code == 503  # no key set: refused, never open
        else:
            assert r.status_code in (401, 403), (method, path, r.status_code)
    assert sb.calls == []


def test_without_supabase_the_app_is_told_so(client, monkeypatch):
    monkeypatch.delenv("SUPABASE_URL")
    r = client.get("/website/gifts")
    assert r.status_code == 503 and "SUPABASE_URL" in r.json()["detail"]


# --- products -------------------------------------------------------------------------


def test_a_product_is_added_hidden_with_the_renderers_fields_filled(client, sb):
    assert add(client).status_code == 200
    g = sb.tables["gifts"]["cart-coin"]
    assert g["published"] is False and g["photo"] is False and g["size_mm"] == [0, 0, 0] and g["spin"]["cols"] == 24
    assert client.get("/website/gifts").json()["gifts"][0]["images"] == {}


@pytest.mark.parametrize("changes", [
    {"slug": "Cart Coin"}, {"slug": "x" * 61}, {"slug": "../etc"},
    {"kind": "garden"}, {"min_qty": 0}, {"min_qty": 2.5}, {"lead_days": -1}, {"sort": "first"},
    {"name": {"he": "מטבע", "en": "Coin"}}, {"name": {"he": "מטבע", "en": "Coin", "ru": "  "}},
    {"text": {"he": "א", "en": "a", "ru": "я", "fr": "b"}}, {"size_mm": [1, 2, 3]}, {"photo": True},
    {"published": True},  # no picture yet
])
def test_fields_off_the_schema_are_refused(client, sb, changes):
    assert add(client, **changes).status_code == 422
    assert sb.tables["gifts"] == {}


def test_a_taken_slug_says_so_in_plain_words(client):
    add(client)
    r = add(client)
    assert r.status_code == 409 and "כבר קיימת" in r.json()["detail"]


def test_edit_keeps_the_renderers_fields_and_a_missing_product_is_404(client, sb):
    add(client)
    sb.tables["gifts"]["cart-coin"]["size_mm"] = [27, 42, 5]
    assert client.put("/website/gifts/cart-coin", json={**GIFT, "min_qty": 50, "sort": 5}).status_code == 200
    g = sb.tables["gifts"]["cart-coin"]
    assert (g["min_qty"], g["sort"], g["size_mm"]) == (50, 5, [27, 42, 5])
    assert client.put("/website/gifts/nope", json=GIFT).status_code == 404
    assert client.put("/website/gifts/cart-coin", json={**GIFT, "slug": "other"}).status_code == 422


def test_delete_takes_the_row_and_the_pictures(client, sb, tmp_path):
    add(client)
    client.post("/website/gifts/cart-coin/photo", files={"file": ("a.jpg", picture())})
    assert client.delete("/website/gifts/cart-coin").status_code == 200
    assert sb.tables["gifts"] == {} and not (tmp_path / "gifts" / "cart-coin").exists()


# --- the photo ------------------------------------------------------------------------


@pytest.mark.parametrize("kind,mode", [("JPEG", "RGB"), ("PNG", "RGBA"), ("WEBP", "RGB")])
def test_a_photo_is_saved_as_a_jpeg_of_at_most_2000_px(client, sb, tmp_path, kind, mode):
    add(client)
    r = client.post("/website/gifts/cart-coin/photo", files={"file": ("p", picture(kind, (3000, 1500), mode))})
    assert r.status_code == 200 and "photo.jpg" in r.json()["images"]
    with Image.open(tmp_path / "gifts" / "cart-coin" / "photo.jpg") as im:
        assert (im.format, im.size) == ("JPEG", (2000, 1000))
    assert sb.tables["gifts"]["cart-coin"]["photo"] is True


@pytest.mark.parametrize("data,status", [
    (b"solid cube\nendsolid", 415), (b"PK\x03\x04 a 3mf is a zip", 415), (picture("GIF"), 415),
    (b"\xff\xd8\xff" + b"0" * (15 * 1024 * 1024), 413),
], ids=["stl", "3mf", "gif", "over 15 MB"])
def test_what_is_not_a_picture_or_is_over_15_mb_is_refused(client, sb, tmp_path, data, status):
    add(client)
    assert client.post("/website/gifts/cart-coin/photo", files={"file": ("model.jpg", data)}).status_code == status
    assert sb.tables["gifts"]["cart-coin"]["photo"] is False and not (tmp_path / "gifts").exists()


def test_a_photo_needs_its_product(client, tmp_path):
    assert client.post("/website/gifts/ghost/photo", files={"file": ("a.jpg", picture())}).status_code == 404
    assert not (tmp_path / "gifts").exists()


def test_removing_the_photo_follows_in_the_row_but_not_under_a_shown_product(client, sb, tmp_path):
    add(client)
    client.post("/website/gifts/cart-coin/photo", files={"file": ("a.jpg", picture())})
    assert client.put("/website/gifts/cart-coin", json={**GIFT, "published": True}).status_code == 200
    assert client.delete("/website/gifts/cart-coin/photo").status_code == 422  # its only picture
    client.put("/website/gifts/cart-coin", json=GIFT)
    assert client.delete("/website/gifts/cart-coin/photo").json() == {"images": {}}
    assert sb.tables["gifts"]["cart-coin"]["photo"] is False


def test_pictures_are_public_cached_and_nothing_else_is_served(client, tmp_path):
    add(client)
    client.post("/website/gifts/cart-coin/photo", files={"file": ("a.jpg", picture())})
    (tmp_path / "gifts" / "cart-coin" / "model.3mf").write_bytes(b"PK")
    c = TestClient(main.app)  # no sign-in
    main.app.dependency_overrides.clear()
    r = c.get("/gifts/cart-coin/photo.jpg?v=1")
    assert r.status_code == 200 and r.headers["content-type"] == "image/jpeg"
    assert r.headers["cache-control"] == "public, max-age=31536000, immutable"
    assert c.get("/gifts/cart-coin/photo.jpg").headers["cache-control"] == "public, max-age=3600"
    for name in ("model.3mf", "photo.tmp", "still.jpg", "..%2F..%2Fservice-account.json"):
        assert c.get(f"/gifts/cart-coin/{name}").status_code == 404
    assert c.post("/gifts/cart-coin/photo.jpg").status_code == 405


# --- the drawn pictures from the PC -----------------------------------------------------


@pytest.fixture
def key(client):
    return {"X-Studio-Key": client.post("/website/render-key").json()["key"]}


def renders(*names):
    return {n: (f"{n}.jpg", picture()) for n in names}


def test_the_script_sends_pictures_and_measures_with_its_key(client, sb, key, tmp_path):
    add(client)
    assert client.post("/website/gifts/cart-coin/renders", data={"meta": json.dumps(META)}, files=renders("still")).status_code == 401
    assert client.post("/website/gifts/cart-coin/renders", headers={"X-Studio-Key": "x"}, data={"meta": json.dumps(META)}).status_code == 401
    r = client.post("/website/gifts/cart-coin/renders", headers=key, data={"meta": json.dumps(META)}, files=renders("still", "top", "spin-0", "spin-6"))
    assert r.status_code == 200 and sorted(r.json()["images"]) == ["spin-0.jpg", "spin-6.jpg", "still.jpg", "top.jpg"]
    g = sb.tables["gifts"]["cart-coin"]
    assert g["size_mm"] == [27, 42, 5] and g["spin"]["tile"] == 640 and g["name"]["en"] == "Coin"
    assert client.put("/website/gifts/cart-coin", json={**GIFT, "published": True}).status_code == 200  # it has a picture now


def test_the_script_cannot_send_a_model_or_a_wrong_measure(client, sb, key, tmp_path):
    add(client)
    post = lambda meta, files: client.post("/website/gifts/cart-coin/renders", headers=key, data={"meta": json.dumps(meta)}, files=files).status_code  # noqa: E731
    assert post(META, {"model": ("model.3mf", b"PK\x03\x04")}) == 400
    assert post(META, {"spin-7": ("spin-7.jpg", picture())}) == 400
    assert post(META, {"still": ("still.jpg", b"PK\x03\x04 really a 3mf")}) == 422
    assert post(META, {"still": ("still.jpg", picture("PNG"))}) == 422
    assert post({**META, "size_mm": [1, 2]}, renders("still")) == 422
    assert post({"size_mm": [1, 2, 3]}, renders("still")) == 422
    assert not (tmp_path / "gifts").exists() and sb.tables["gifts"]["cart-coin"]["size_mm"] == [0, 0, 0]
    assert [p.name for p in tmp_path.iterdir() if p.is_dir()] == []  # no work folder left behind


def test_the_first_import_creates_the_product_and_never_overwrites_it_later(client, sb, key):
    post = lambda meta: client.post("/website/gifts/tulip/renders", headers=key, data={"meta": json.dumps(meta)}, files=renders("still"))  # noqa: E731
    assert post(META).status_code == 404
    r = post({**META, "gift": {**GIFT, "published": True}})
    assert r.json()["created"] is True and sb.tables["gifts"]["tulip"]["published"] is True
    client.put("/website/gifts/tulip", json={**GIFT, "min_qty": 99, "published": True})
    assert post({**META, "gift": GIFT}).json()["created"] is False
    assert sb.tables["gifts"]["tulip"]["min_qty"] == 99 and sb.tables["gifts"]["tulip"]["published"] is True


# --- wording ---------------------------------------------------------------------------


def test_texts_are_the_codes_wording_plus_the_overrides(client, sb):
    r = client.get("/website/texts").json()
    assert r["defaults"]["hero.h1"]["en"] == "A gift for every guest, with their name on it."
    assert r["defaults"]["how.steps.0.t"]["he"] and r["overrides"] == {}
    assert all(re.fullmatch(r"[A-Za-z0-9_.]{1,80}", k) and set(v) == {"he", "en", "ru"} for k, v in r["defaults"].items())


def test_an_override_keeps_only_what_differs_and_reset_deletes_the_row(client, sb):
    same = website.DEFAULTS["hero.h1"]["en"]
    assert client.put("/website/texts/hero.h1", json={"he": " מתנה לכל אורח ", "en": same, "ru": ""}).json() == {"value": {"he": "מתנה לכל אורח"}}
    assert sb.tables["site_texts"]["hero.h1"]["value"] == {"he": "מתנה לכל אורח"}
    client.put("/website/texts/hero.h1", json={"ru": "Подарок"})
    assert sb.tables["site_texts"]["hero.h1"]["value"] == {"ru": "Подарок"}
    assert client.put("/website/texts/hero.h1", json={"en": same}).json() == {"value": {}}  # nothing differs: the row goes
    client.put("/website/texts/hero.h1", json={"he": "x"})
    assert client.delete("/website/texts/hero.h1").status_code == 200 and sb.tables["site_texts"] == {}


def test_an_unknown_key_or_language_is_refused(client, sb):
    assert client.put("/website/texts/hero.nope", json={"he": "x"}).status_code == 404
    assert client.put("/website/texts/hero.h1", json={"fr": "x"}).status_code == 422
    assert client.put("/website/texts/hero.h1", json={"he": "x" * 4001}).status_code == 422
    assert client.delete("/website/texts/hero.nope").status_code == 404
    assert sb.tables["site_texts"] == {}


# --- call-back requests ------------------------------------------------------------------


def test_leads_are_listed_and_their_status_set(client, sb):
    sb.tables["leads"][7] = {"id": 7, "name": "דנה", "phone": "052-1234567", "status": "new"}
    assert client.get("/website/leads").json()["leads"][0]["name"] == "דנה"
    for status in website.LEAD_STATUSES:
        assert client.post("/website/leads/7/status", json={"status": status}).status_code == 200
        assert sb.tables["leads"][7]["status"] == status
    assert client.post("/website/leads/7/status", json={"status": "sold"}).status_code == 422
    assert client.post("/website/leads/7/status", json={}).status_code == 422
    assert client.post("/website/leads/8/status", json={"status": "called"}).status_code == 404
    assert client.post("/website/leads/x/status", json={"status": "called"}).status_code == 422
    assert sb.tables["leads"][7] == {"id": 7, "name": "דנה", "phone": "052-1234567", "status": "dropped"}


def test_a_lead_is_deleted(client, sb):
    sb.tables["leads"][7] = {"id": 7, "name": "דנה", "phone": "052-1234567", "status": "new"}
    assert client.delete("/website/leads/7").status_code == 200 and sb.tables["leads"] == {}
    assert client.delete("/website/leads/7").status_code == 404
    assert client.delete("/website/leads/x").status_code == 422


def test_a_new_lead_alerts_the_studio_only_with_the_shared_key(sb, monkeypatch):
    sent = []
    monkeypatch.setattr(jobs, "users", lambda: [("u", {})])
    monkeypatch.setattr(jobs, "send_to", lambda people, kind, title, body, data: sent.append((kind, title, body, data)))
    monkeypatch.setenv("LEAD_WEBHOOK_KEY", "shared")
    c = TestClient(main.app)
    lead = {"name": "דנה", "phone": "052-1234567", "guests": 200, "wedding_date": "2027-04-01", "call_time": "any", "gifts": [], "lang": "he"}
    assert c.post("/website/lead", json=lead).status_code == 401
    assert c.post("/website/lead", json=lead, headers={"x-key": "wrong"}).status_code == 401
    assert c.post("/website/lead", json=lead, headers={"x-key": "sharedx"}).status_code == 401
    assert sent == []
    assert c.post("/website/lead", json=lead, headers={"x-key": "shared"}).status_code == 200
    assert c.post("/website/lead", json=lead, headers={"X-Site-Key": "shared"}).status_code == 200
    assert sent[0] == ("client", "פנייה חדשה מהאתר: דנה", "200 אורחים · חתונה ב-2027-04-01", {"route": "/leads"})
    assert "052" not in str(sent)  # the phone number stays out of the push


# --- Supabase's errors -------------------------------------------------------------------


@pytest.mark.parametrize("status,body,want,words", [
    (401, {"message": "Invalid API key"}, 502, "המפתח"),
    (404, {"code": "PGRST205", "message": "Could not find the table"}, 502, "schema.sql"),
    (400, {"code": "23514", "message": 'violates check constraint "gifts_kind_check"'}, 422, "gifts_kind_check"),
    (500, {}, 502, "500"),
])
def test_supabase_errors_come_back_in_plain_words(client, monkeypatch, status, body, want, words):
    monkeypatch.setattr(website.requests, "request", lambda *a, **k: Reply(status, body))
    r = client.get("/website/leads")
    assert r.status_code == want and words in r.json()["detail"] and "service-key" not in r.text


def test_a_sleeping_supabase_is_a_502(client, monkeypatch):
    def down(*a, **k):
        raise website.requests.ConnectionError("no route")

    monkeypatch.setattr(website.requests, "request", down)
    assert client.get("/website/gifts").status_code == 502


def test_measured_print_minutes_are_kept_on_the_pi(client, sb, key, tmp_path):
    add(client)
    assert client.get("/website/gifts").json()["gifts"][0]["unit_minutes"] is None
    for bad in (0, -3, "x"):
        assert client.post("/website/gifts/cart-coin/renders", headers=key,
                           data={"meta": json.dumps({**META, "unit_minutes": bad})}).status_code == 422
    assert client.post("/website/gifts/cart-coin/renders", headers=key,
                       data={"meta": json.dumps({**META, "unit_minutes": 7.5})}, files=renders("still")).status_code == 200
    assert client.get("/website/gifts").json()["gifts"][0]["unit_minutes"] == 7.5
    assert "unit_minutes" not in sb.tables["gifts"]["cart-coin"]  # not a Supabase column


def test_the_name_spot_goes_to_supabase(client, sb, key):
    add(client)
    post = lambda meta: client.post("/website/gifts/cart-coin/renders", headers=key,  # noqa: E731
                                    data={"meta": json.dumps(meta)}, files=renders("still"))
    assert post(META).status_code == 200 and "name_on" not in sb.tables["gifts"]["cart-coin"]
    for bad in ({"still": {"x": 1.2, "y": 0.5, "w": 0.3}}, {"still": {"x": 0.5, "y": 0.5, "w": 0}}, {"top": {}}):
        assert post({**META, "nameOn": bad}).status_code == 422
    spot = {"still": {"x": 0.3, "y": 0.47, "w": 0.38}, "spin": {"x": 0.5, "y": 0.5, "w": 0.4, "angle": 30}}
    assert post({**META, "nameOn": spot}).status_code == 200
    assert sb.tables["gifts"]["cart-coin"]["name_on"] == {"still": {**spot["still"], "angle": 0}, "spin": spot["spin"]}
    assert post(META).status_code == 200 and "name_on" in sb.tables["gifts"]["cart-coin"]  # kept


def test_a_lead_with_a_gift_and_amount(sb, monkeypatch):
    sent = []
    monkeypatch.setattr(jobs, "users", lambda: [("u", {})])
    monkeypatch.setattr(jobs, "send_to", lambda people, kind, title, body, data: sent.append(body))
    monkeypatch.setenv("LEAD_WEBHOOK_KEY", "shared")
    c = TestClient(main.app)
    assert c.post("/website/lead", json={"name": "דנה", "gift": "cart-coin", "qty": 120}, headers={"x-key": "shared"}).status_code == 200
    assert c.post("/website/lead", json={"name": "דנה", "gift": "cart-coin"}, headers={"x-key": "shared"}).status_code == 200
    assert sent == ["120 × cart-coin", "cart-coin"]
