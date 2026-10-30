"""giftfactory.py: Gift Factory's routes (contract v1, GIFT_FACTORY.md) and the portal's guest list.
The parser, template and contract shapes run anywhere; the routes need the Firestore emulator (test_studio.py)."""

import io
import json

import openpyxl
import pytest
from fastapi import HTTPException
from PIL import Image
from pydantic import ValidationError

from app import giftfactory, studio
from test_studio import PNG, TOKEN_A, TOKEN_B, client, db, files, paired, picture, publish, pushes  # noqa: F401 (fixtures)

XLSX = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
PRODUCTION = {  # the example in GIFT_FACTORY.md
    "contract": 1, "job": "Cart-Coin-20261029-1153",
    "quote": {"units": 105, "plates": 4, "printHours": 12.5, "finishDate": "2026-11-12", "unitCost": 193, "unitPrice": 271,
              "total": 28455, "breakdown": {"filament": 61, "power": 9, "wear": 14, "packaging": 50, "labour": 100, "failureMarginPct": 5}},
    "progress": {"platesDone": 1, "platesTotal": 4, "unitsOk": 25, "unitsTarget": 105, "failedUnits": 2,
                 "finishDate": "2026-11-12", "lastEvent": "done"},
    "actualCost": {"filament": 5210, "power": 610, "wear": 1150, "packaging": 5250, "labour": 10500, "total": 22720},
}


def filled(rows) -> bytes:
    """The portal's template with the client's rows typed in."""
    wb = openpyxl.load_workbook(io.BytesIO(giftfactory.guest_template()))
    for row in rows:
        wb.active.append(list(row))
    out = io.BytesIO()
    wb.save(out)
    return out.getvalue()


def refused(ext, data) -> str:
    with pytest.raises(HTTPException) as e:
        giftfactory.parse_guests(ext, data)
    return e.value.detail


# --- anywhere --------------------------------------------------------------------------


def test_template_is_two_headers_and_a_grey_note():
    ws = openpyxl.load_workbook(io.BytesIO(giftfactory.guest_template())).worksheets
    assert len(ws) == 1
    ws = ws[0]
    assert ws.sheet_view.rightToLeft and [[c.value for c in r] for r in ws.iter_rows()] == [
        ["שם / Name", "כמות / Amount"], [giftfactory.NOTE, None]]
    assert ws["A2"].font.color.rgb.endswith("808080") and ws.column_dimensions["A"].width == 40


def test_guest_list_from_the_template():
    got = giftfactory.parse_guests(".xlsx", filled([("דנה", None), ("רון", 2), ("גיל ושירה", ""), ("לא בא", 0), (None, 3)]))
    # rows: 1 header, 2 note, 3 דנה ... 6 not coming, 7 no name
    assert got == {"names": 3, "gifts": 4, "skipped": [[6, "amount 0"], [7, "no name"]]}


def test_guest_list_csv_utf8_and_windows_hebrew_and_columns_a_b():
    text = "Guest,Copies\nדנה,\nרון,3\n"  # no known header words: columns A and B
    for data in (text.encode("utf-8-sig"), text.encode("utf-8"), text.encode("cp1255")):
        assert giftfactory.parse_guests(".csv", data) == {"names": 2, "gifts": 4, "skipped": []}
    # Headers are found wherever they are, after empty rows.
    assert giftfactory.parse_guests(".csv", "\n,\nTable,Qty,First name\n1,2,דנה\n".encode())["gifts"] == 2


def test_guest_list_refusals_name_the_row():
    assert refused(".xlsx", filled([("דנה", 1), ("רון", "two")])) == 'Row 4: the amount "two" is not a whole number'
    assert "Row 2" in refused(".csv", "שם,כמות\nדנה,-1\n".encode())
    assert "Row 2" in refused(".csv", "שם,כמות\nדנה,1.5\n".encode())
    assert refused(".xlsx", b"PK not really") == "The file could not be read as .xlsx"
    assert refused(".csv", b"") == "The file is empty"
    assert refused(".xlsx", giftfactory.guest_template()) == "No names in the file"
    assert refused(".csv", ("name\n" + "x\n" * 5001).encode()) == "Over 5000 rows"
    assert giftfactory.parse_guests(".csv", ("name\n" + "x\n" * 5000).encode())["gifts"] == 5000


def test_production_shapes_are_contract_v1():
    assert giftfactory.Production.model_validate(PRODUCTION).quote.printHours == 12.5
    assert giftfactory.Production.model_validate({"contract": 1, "progress": {**PRODUCTION["progress"], "finishDate": None}})
    for bad in ({**PRODUCTION, "contract": 2}, {**PRODUCTION, "extra": 1},
                {**PRODUCTION, "quote": {**PRODUCTION["quote"], "unitPrice": 2.71}},
                {**PRODUCTION, "quote": {**PRODUCTION["quote"], "unitPrice": "271"}},
                {**PRODUCTION, "progress": {**PRODUCTION["progress"], "lastEvent": "exploded"}},
                {**PRODUCTION, "progress": {**PRODUCTION["progress"], "finishDate": "12.11.2026"}},
                {**PRODUCTION, "actualCost": {"total": 1}}):
        with pytest.raises(ValidationError):
            giftfactory.Production.model_validate(bad)


def test_a_tall_name_check_is_watermarked_down_its_length(tmp_path):
    path = tmp_path / "names.jpg"
    path.write_bytes(picture("JPEG", (400, 4000)))
    studio._watermark(path)
    with Image.open(path) as im:
        assert im.size == (400, 4000)
        assert im.crop((0, 3600, 400, 4000)).convert("L").getextrema()[0] < 235  # stamped at the bottom too


# --- the routes (emulator) ---------------------------------------------------------------


def gf(client) -> dict:
    return {"X-Studio-Key": client.post("/studio/giftfactory-key").json()["key"]}


def test_giftfactory_has_its_own_key(client):
    assert client.get("/gf/requests").status_code == 401
    assert client.get("/gf/requests").json()["detail"] == "Gift Factory is not paired"
    fm = paired(client)
    assert client.get("/gf/requests", headers=fm).status_code == 401  # the Flag Maker's key is not Gift Factory's
    key = gf(client)
    assert client.get("/gf/requests", headers={"X-Studio-Key": "wrong"}).json()["detail"] == "Wrong Gift Factory key"
    assert client.get("/gf/requests", headers=key).status_code == 200
    assert client.get("/fm/requests", headers=fm).status_code == 200  # pairing one never unpairs the other
    assert client.get("/fm/requests", headers=key).status_code == 401
    for method, path in (("POST", "/gf/requests/r1/versions"), ("PUT", "/gf/requests/r1/production"), ("GET", "/gf/requests/r1/guests")):
        assert client.request(method, path).status_code == 401, path


def test_request_list_with_guests(client, db):
    key = gf(client)
    db.document("requests/r2").set({"customerId": "c2", "title": "done", "qty": 1, "status": "ready", "latestVersion": 1})
    db.document("requests/r3").set({"customerId": "c2", "title": "printing", "qty": 50, "status": "printing", "latestVersion": 2,
                                    "guests": {"names": 3, "gifts": 4, "fileName": "x.csv"}})
    got = {r["id"]: r for r in client.get("/gf/requests", headers=key).json()}
    assert set(got) == {"r1", "r3"}
    assert got["r1"]["guests"] is None and got["r1"]["status"] == "draft"
    assert got["r3"]["guests"] == {"names": 3, "gifts": 4, "uploadedAt": None} and got["r3"]["customer"] == ""


def test_version_with_the_name_check(client, db):
    key = gf(client)
    names = picture("JPEG", (300, 900))
    v = client.post("/gf/requests/r1/versions", headers=key, files={"preview": ("p.png", PNG, "image/png"),
                                                                     "names": ("n.jpg", names, "image/jpeg")}).json()
    doc = db.document(f"versions/{v['id']}").get().to_dict()
    assert v["n"] == 1 and doc["source"] == "giftfactory" and set(doc["files"]) == {"preview.png", "names.jpg"}
    assert doc["spinGrid"] == 10  # 100 turns; the Flag Maker's stay 6 x 6
    publish(db, v["id"])
    shown = client.get(f"/p/{TOKEN_A}/f/{v['id']}/names.jpg").content
    assert shown != names and Image.open(io.BytesIO(shown)).size == (300, 900)  # watermarked, whole
    shown_v = client.get(f"/p/{TOKEN_A}/data").json()["requests"][0]["versions"][0]
    assert "names.jpg" in shown_v["files"] and shown_v["spinGrid"] == 10
    bad = client.post("/gf/requests/r1/versions", headers=key, files={"preview": ("p.png", PNG, "image/png"),
                                                                       "names": ("n.jpg", PNG, "image/jpeg")})
    assert bad.status_code == 422  # a PNG called names.jpg
    assert client.post("/gf/requests/nope/versions", headers=key, files={"preview": ("p.png", PNG, "image/png")}).status_code == 404
    db.document("requests/r1").update({"status": "approved"})
    assert client.post("/gf/requests/r1/versions", headers=key, files={"preview": ("p.png", PNG, "image/png")}).status_code == 409
    # The Flag Maker's route stays as it was: it takes no name check.
    db.document("requests/r1").update({"status": "draft"})
    fm = client.post("/fm/requests/r1/versions", headers=paired(client), files=files(names=("n.jpg", names, "image/jpeg"))).json()
    assert "names.jpg" not in db.document(f"versions/{fm['id']}").get().to_dict()["files"]


# --- C2b: plate tabs and the all-round view --------------------------------------------

VIEWS = {"cols": 24, "pitches": [75, 50, 25, 0, -25, -50, -75], "start": [2, 0], "tabs": ["Plate 1 · דנה"]}
SHEET = picture("JPEG", (24 * 20, 7 * 20))  # 24 x 7 tiles of 20 px


def proof(client, key, views, extra=(), spin=SHEET):
    fs = [("preview", ("p.png", PNG, "image/png")), *([("spin", ("s.jpg", spin, "image/jpeg"))] if spin else []), *extra]
    return client.post("/gf/requests/r1/versions", headers=key, data={"views": json.dumps(views)}, files=fs)


def tab(k):
    return [(f"preview_{k}", ("p.png", PNG, "image/png")), (f"spin_{k}", ("s.jpg", SHEET, "image/jpeg"))]


def test_gf_info_says_views(client):
    assert client.get("/gf/info").status_code == 401
    assert client.get("/gf/info", headers={"X-Studio-Key": "wrong"}).status_code == 401
    assert client.get("/gf/info", headers=gf(client)).json() == {"contract": 1, "views": True}


def test_version_with_one_and_three_tabs(client, db):
    key = gf(client)
    one = proof(client, key, VIEWS).json()
    doc = db.document(f"versions/{one['id']}").get().to_dict()
    assert doc["views"]["cols"] == 24 and doc["views"]["start"] == [2, 0] and "spinGrid" not in doc
    three = proof(client, key, {**VIEWS, "tabs": ["Plate 1", "Plate 2", "Plate 3"]}, [*tab(2), *tab(3)]).json()
    doc = db.document(f"versions/{three['id']}").get().to_dict()
    assert set(doc["files"]) == {"preview.png", "spin.jpg", "preview_2.png", "spin_2.jpg", "preview_3.png", "spin_3.jpg"}
    publish(db, three["id"])
    shown = client.get(f"/p/{TOKEN_A}/data").json()["requests"][0]["versions"][0]
    assert shown["views"]["tabs"] == [{"title": "Plate 1", "preview": "preview.png", "spin": "spin.jpg"},
                                      {"title": "Plate 2", "preview": "preview_2.png", "spin": "spin_2.jpg"},
                                      {"title": "Plate 3", "preview": "preview_3.png", "spin": "spin_3.jpg"}]
    assert len(shown["views"]["pitches"]) == 7 and "spin_3.jpg" in shown["files"]
    got = client.get(f"/p/{TOKEN_A}/f/{three['id']}/spin_3.jpg")
    assert got.status_code == 200 and got.content != SHEET and Image.open(io.BytesIO(got.content)).size == (480, 140)
    assert client.get(f"/p/{TOKEN_B}/f/{three['id']}/spin_3.jpg").status_code == 404  # another customer's link


def test_off_views_are_refused(client, db):
    key = gf(client)
    for bad in ({**VIEWS, "extra": 1}, {**VIEWS, "cols": 60}, {**VIEWS, "start": [7, 0]}, {**VIEWS, "start": [0, 24]},
                {**VIEWS, "tabs": []}, {**VIEWS, "tabs": ["t"] * 21}, {**VIEWS, "cols": "24"}, {**VIEWS, "pitches": []}):
        assert proof(client, key, bad).status_code == 400, bad
    assert client.post("/gf/requests/r1/versions", headers=key, data={"views": "not json"},
                       files={"preview": ("p.png", PNG, "image/png"), "spin": ("s.jpg", SHEET, "image/jpeg")}).status_code == 400
    two = {**VIEWS, "tabs": ["a", "b"]}
    assert proof(client, key, two, tab(2)[:1]).status_code == 400  # no spin_2
    assert proof(client, key, two, [*tab(2), *tab(3)]).status_code == 400  # a tab beyond the titles
    assert proof(client, key, two, [*tab(2), tab(2)[0]]).status_code == 400  # two preview_2
    assert proof(client, key, two, [("preview_2", ("p.png", PNG, "image/png"))], spin=None).status_code == 400  # tab 1 has no spin
    assert proof(client, key, VIEWS, spin=picture("JPEG", (600, 600))).status_code == 400  # not 24 x 7 tiles
    assert proof(client, key, VIEWS, spin=picture("JPEG", (24 * 20, 7 * 21))).status_code == 400  # not square tiles
    assert db.collection("versions").get() == []  # nothing stored


def test_flagmaker_versions_have_no_views(client, db):
    v = client.post("/fm/requests/r1/versions", headers=paired(client), data={"views": json.dumps(VIEWS)}, files=files()).json()
    doc = db.document(f"versions/{v['id']}").get().to_dict()
    assert "views" not in doc and doc["spinGrid"] == 6
    publish(db, v["id"])
    assert client.get(f"/p/{TOKEN_A}/data").json()["requests"][0]["versions"][0]["views"] is None


def test_production_merges_and_pushes_progress(client, db, pushes):
    key = gf(client)
    assert client.put("/gf/requests/nope/production", headers=key, json=PRODUCTION).status_code == 404
    assert client.put("/gf/requests/r1/production", headers=key, json={**PRODUCTION, "contract": 2}).status_code == 422
    assert client.put("/gf/requests/r1/production", headers=key, json={"contract": 1, "quote": PRODUCTION["quote"]}).status_code == 200
    assert pushes == []  # a quote pushes nothing
    p = {**PRODUCTION["progress"], "platesDone": 0, "failedUnits": 0, "lastEvent": "queued"}
    client.put("/gf/requests/r1/production", headers=key, json={"contract": 1, "progress": p})
    assert pushes == []
    client.put("/gf/requests/r1/production", headers=key, json={"contract": 1, "progress": {**p, "platesDone": 1, "lastEvent": "done"}})
    client.put("/gf/requests/r1/production", headers=key, json={"contract": 1, "progress": {**p, "platesDone": 1, "failedUnits": 2}})
    client.put("/gf/requests/r1/production", headers=key, json={"contract": 1, "progress": {**p, "platesDone": 2, "failedUnits": 3}})
    client.put("/gf/requests/r1/production", headers=key, json={"contract": 1, "progress": {**p, "platesDone": 2, "failedUnits": 3}})
    assert [t for _, t, _ in pushes] == ["Plate 1 of 4 done · אלכס ❤ אביטל", "2 units failed on אלכס ❤ אביטל",
                                         "Plate 2 of 4 done · 1 units failed on אלכס ❤ אביטל"]
    assert {k for k, _, _ in pushes} == {"production"}
    client.put("/gf/requests/r1/production", headers=key, json={"contract": 1, "job": "j2", "actualCost": PRODUCTION["actualCost"]})
    prod = db.document("requests/r1").get().to_dict()["production"]
    assert prod["quote"] == PRODUCTION["quote"] and prod["progress"]["platesDone"] == 2  # earlier parts stay
    assert prod["actualCost"]["total"] == 22720 and prod["job"] == "j2" and prod["updatedAt"]


def guest_upload(client, data, name="guests.xlsx", token=TOKEN_A, rid="r1"):
    return client.post(f"/p/{token}/requests/{rid}/guests", files={"file": (name, data, XLSX)})


def test_portal_guest_list(client, db, pushes, tmp_path):
    t = client.get(f"/p/{TOKEN_A}/guest-template.xlsx")
    assert t.status_code == 200 and t.headers["content-type"] == XLSX and t.content.startswith(b"PK")
    assert client.get(f"/p/{'x' * 22}/guest-template.xlsx").status_code == 404
    good = filled([("דנה", None), ("רון", 2), ("לא בא", 0)])
    r = guest_upload(client, good, "אורחים.xlsx")
    assert r.json() == {"names": 2, "gifts": 3, "skipped": [[5, "amount 0"]]}
    g = db.document("requests/r1").get().to_dict()["guests"]
    assert (g["names"], g["gifts"], g["fileName"]) == (2, 3, "אורחים.xlsx") and g["uploadedAt"]
    assert pushes[-1][:2] == ("client", "Guest list from INTERVIEW: 3 gifts")
    # Refused, and the good list stays.
    assert guest_upload(client, good, token=TOKEN_B).status_code == 404  # someone else's request
    assert guest_upload(client, good, rid="nope").status_code == 404
    assert guest_upload(client, b"old", "guests.xls").json()["detail"] == "Save it as .xlsx or .csv"
    assert guest_upload(client, b"x", "guests.pdf").status_code == 400
    assert guest_upload(client, filled([("רון", "שניים")])).json()["detail"] == 'Row 3: the amount "שניים" is not a whole number'
    assert guest_upload(client, b"x" * (2 * 1024 * 1024 + 1), "g.csv").status_code == 413
    assert db.document("requests/r1").get().to_dict()["guests"]["gifts"] == 3
    # Gift Factory and the signed-in app get the file as it came, under its own name.
    key = gf(client)
    f = client.get("/gf/requests/r1/guests", headers=key)
    assert f.content == good and "filename*=UTF-8''%D7%90" in f.headers["content-disposition"]
    assert client.get("/studio/requests/r1/guests").content == good
    # A CSV replaces the xlsx.
    assert guest_upload(client, "name,amount\nדנה,5\n".encode(), "g.csv").json()["gifts"] == 5
    assert client.get("/gf/requests/r1/guests", headers=key).content.startswith(b"name")
    assert [p.name for p in (tmp_path / "guests" / "r1").iterdir()] == ["guests.csv"]
    # Locked once production starts.
    db.document("requests/r1").update({"status": "printing"})
    assert guest_upload(client, good).status_code == 409
    db.document("requests/r2").set({"customerId": "c1", "title": "x", "qty": 1, "status": "draft", "latestVersion": 0})
    assert client.get("/gf/requests/r2/guests", headers=key).status_code == 404
    client.delete("/studio/requests/r1")
    assert not (tmp_path / "guests" / "r1").exists()


def test_portal_guest_uploads_are_rate_limited(client, db):
    for _ in range(60):
        studio._limit(TOKEN_A)
    assert guest_upload(client, filled([("דנה", 1)])).status_code == 429


def test_portal_shows_guests_and_progress_but_no_costs(client, db, pushes):
    vid = client.post("/studio/requests/r1/versions", files=files()).json()["id"]
    publish(db, vid)
    guest_upload(client, filled([("דנה", 2)]))
    client.put("/gf/requests/r1/production", headers=gf(client), json=PRODUCTION)
    r = client.get(f"/p/{TOKEN_A}/data").json()["requests"][0]
    assert r["guests"]["gifts"] == 2 and r["progress"] is None  # waiting: not printing yet
    db.document("requests/r1").update({"status": "printing"})
    r = client.get(f"/p/{TOKEN_A}/data").json()["requests"][0]
    assert r["progress"] == {"unitsOk": 25, "unitsTarget": 105, "finishDate": "2026-11-12"}
    text = json.dumps(r)
    for secret in ("unitCost", "unitPrice", "actualCost", "platesDone", "Cart-Coin", "breakdown", "fileName"):
        assert secret not in text, secret
