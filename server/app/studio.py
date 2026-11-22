"""Print Studio: design versions, the Flag Maker link and the customer portal.

Firestore holds the records; the Pi holds the files (Firebase Storage needs a
paid plan) and is the customer's only way in. The customer has no account: the
portal link's token is the key, and every portal route resolves it to one
customer and checks that whatever is asked for belongs to them.

Who writes what:
- the app (checked by firestore.rules): customers, requests, quotes, the
  studio's comments, payments received, publishing a version (request.publishedVersionId);
- here (Admin SDK): versions (uploads from the app, the Flag Maker or Gift
  Factory), the customer's comments and the approval; giftfactory.py adds a
  request's production and guests.
"""

import hashlib
import hmac
import io
import json
import os
import secrets
import shutil
import tempfile
import time
import zipfile
from collections import defaultdict, deque
from datetime import datetime, timezone
from pathlib import Path
from typing import Annotated, Literal

from fastapi import APIRouter, Cookie, Depends, File, Form, Header, HTTPException, Response, UploadFile
from fastapi.responses import FileResponse, HTMLResponse
from PIL import Image, ImageDraw, ImageFont, ImageOps
from firebase_admin import firestore
from google.cloud.firestore_v1 import FieldFilter
from pydantic import BaseModel, Field

from . import firebase, jobs, telegram

router = APIRouter()
User = Annotated[dict, Depends(firebase.current_user)]

# Upload field -> the name it is stored under, and how it is served.
FILES = {
    "preview": ("preview.png", "image/png"),
    "model": ("model.3mf", "application/vnd.ms-package.3dmanufacturing-3dmodel+xml"),
    "recipe": ("recipe.json", "application/json"),
    # The 3D views are pictures, never meshes: 36 turns of 10 degrees on one sheet.
    "spin": ("spin.jpg", "image/jpeg"),
    "spin_asm": ("spin_asm.jpg", "image/jpeg"),
    # Gift Factory's name check: every guest's name as printed, pages stacked in one tall picture.
    "names": ("names.jpg", "image/jpeg"),
}
# Gift Factory's plate tabs (views): tab k (2..20) has its own picture and all-round sheet.
TABS = {f"{kind}_{k}": (f"{kind}_{k}.{ext}", t) for k in range(2, 21)
        for kind, ext, t in (("preview", "png", "image/png"), ("spin", "jpg", "image/jpeg"))}
FILES |= TABS
SPIN_GRID = 6  # 6 x 6 tiles, frame i at row i // 6, column i % 6 (the Flag Maker's crm_link.spin)
GF_SPIN_GRID = 10  # Gift Factory: 100 turns of 3.6 degrees; stored on each version as spinGrid
TYPES = dict(FILES.values())
# What the client's link serves: watermarked pictures only, never the print file, the recipe or a mesh.
CLIENT_FILES = {"preview.png", "spin.jpg", "spin_asm.jpg", "names.jpg"} | {n for n, _ in TABS.values()}
MAX_FILE = 60 * 1024 * 1024
OPEN = ("draft", "waiting")  # a request takes new versions only before approval
STATIC = Path(__file__).parent / "static"


def _data() -> Path:
    return Path(os.environ.get("DATA_DIR", "."))


def _sha(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def money(unit: int, qty: int, vat_percent: int, discount: int = 0) -> dict:
    """Agorot in, agorot out; the discount comes off before VAT, VAT rounded half up to the
    agora. The app's money() in lib/studio/studio.dart computes the same."""
    net = max(0, unit * qty - discount)
    vat = (net * vat_percent + 50) // 100
    return {"unit": unit, "qty": qty, "vatPercent": vat_percent, "discount": discount, "net": net, "vat": vat, "total": net + vat}


def quote_total(q: dict) -> int:
    """What the client pays for a saved quote (quotes before 0.3.5 have no discount)."""
    return money(int(q.get("unit", 0)), int(q.get("qty", 1)), int(q.get("vatPercent", 18)), int(q.get("discount", 0)))["total"]


# --- uploads ----------------------------------------------------------------------


class Upload:
    """The files of one design version, as the Flag Maker exports them."""

    def __init__(
        self,
        preview: Annotated[UploadFile, File()],
        model: Annotated[UploadFile | None, File()] = None,
        recipe: Annotated[UploadFile | None, File()] = None,
        spin: Annotated[UploadFile | None, File()] = None,
        spin_asm: Annotated[UploadFile | None, File()] = None,
        note: Annotated[str, Form(max_length=500)] = "",
    ):
        self.files = {"preview": preview, "model": model, "recipe": recipe, "spin": spin, "spin_asm": spin_asm}
        self.note = note.strip()
        self.views = None  # Gift Factory's plate tabs and all-round sheet (giftfactory.Views)
        self.estimate = {}  # B8: the Flag Maker's print time, grams and price (FlagUpload)


class FlagUpload(Upload):
    """B8: the Flag Maker may also send what one unit takes (all optional, agorot and whole minutes)."""

    def __init__(
        self,
        preview: Annotated[UploadFile, File()],
        model: Annotated[UploadFile | None, File()] = None,
        recipe: Annotated[UploadFile | None, File()] = None,
        spin: Annotated[UploadFile | None, File()] = None,
        spin_asm: Annotated[UploadFile | None, File()] = None,
        note: Annotated[str, Form(max_length=500)] = "",
        printMinutes: Annotated[int | None, Form(ge=0, le=100000)] = None,  # noqa: N803 (the contract's names)
        grams: Annotated[float | None, Form(ge=0, le=100000)] = None,
        costAgorot: Annotated[int | None, Form(ge=0, le=100_000_000)] = None,  # noqa: N803
        suggestedAgorot: Annotated[int | None, Form(ge=0, le=100_000_000)] = None,  # noqa: N803
    ):
        super().__init__(preview, model, recipe, spin, spin_asm, note)
        sent = {"printMinutes": printMinutes, "grams": grams, "costAgorot": costAgorot, "suggestedAgorot": suggestedAgorot}
        self.estimate = {k: v for k, v in sent.items() if v is not None}


def tab_field(kind: str, k: int) -> str:
    """Tab 1 is today's preview / spin, tab k the preview_k / spin_k (TABS)."""
    return kind if k == 1 else f"{kind}_{k}"


def _picture(path: Path, kind: str) -> bool:
    with Image.open(path) as im:
        im.verify()
        return im.format == kind


def _check(path: Path) -> None:
    """The content is what its name says: nothing else is ever served."""
    ok = {
        ".png": lambda: _picture(path, "PNG"),
        ".jpg": lambda: _picture(path, "JPEG"),
        ".3mf": lambda: zipfile.is_zipfile(path),
        ".json": lambda: isinstance(json.loads(path.read_text(encoding="utf-8")), dict),
    }[path.suffix]
    try:
        good = ok()
    except (ValueError, OSError, SyntaxError):  # Pillow's errors for a broken picture
        good = False
    if not good:
        raise HTTPException(422, f"{path.name} is not a valid {path.suffix[1:]} file")


def _watermark(path: Path, cols: int = 1, rows: int = 0) -> None:
    """Stamps every picture the client sees, each tile of a spin sheet on its own,
    so a screenshot or a saved copy still says it is a preview."""
    with Image.open(path) as im:
        img = im.convert("RGB")
    rows = rows or cols
    tw, th = img.width // cols, img.height // rows
    bh = min(th, tw)  # a tall picture (the name check) is stamped square by square down its length
    side = 2 * max(tw, bh)
    layer = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    font = ImageFont.truetype(str(STATIC / "Heebo.ttf"), max(12, tw // 14))
    step = max(24, bh // 4)
    for i, y in enumerate(range(0, side, step)):
        draw.text((-(i % 2) * tw // 3, y), "PRINT STUDIO · PREVIEW ONLY     " * 4, font=font, fill=(90, 96, 110, 64))
    layer = layer.rotate(28, resample=Image.BICUBIC)
    left, top = (side - tw) // 2, (side - bh) // 2
    tile = layer.crop((left, top, left + tw, top + bh))
    for r in range(rows):
        for c in range(cols):
            for y in range(0, th, bh):
                img.paste(tile, (c * tw, r * th + y), tile)
    if path.suffix == ".png":
        img.save(path, "PNG", optimize=True)
    else:
        img.save(path, "JPEG", quality=85)


def _tiles(path: Path, cols: int, rows: int) -> None:
    with Image.open(path) as im:
        w, h = im.size
    if w % cols or h % rows or w // cols != h // rows:
        raise HTTPException(400, f"{path.name} is not {cols} x {rows} square tiles")


def _save(vid: str, up: Upload, cols: int, rows: int) -> list[str]:
    tmp = Path(tempfile.mkdtemp(dir=_data()))
    try:
        names = []
        for field, f in up.files.items():
            if f is None or not f.filename:
                continue
            name = FILES[field][0]
            size = 0
            with open(tmp / name, "wb") as out:
                while chunk := f.file.read(1 << 20):
                    size += len(chunk)
                    if size > MAX_FILE:
                        raise HTTPException(413, f"{name} is over 60 MB")
                    out.write(chunk)
            _check(tmp / name)
            spin = name.startswith("spin")
            if spin and up.views:
                _tiles(tmp / name, cols, rows)
            if name in CLIENT_FILES:
                _watermark(tmp / name, *((cols, rows) if spin else (1, 1)))
            names.append(name)
        dest = _data() / "files" / vid
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp.rename(dest)
        return names
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise


def create_version(rid: str, up: Upload, source: str) -> dict:
    """Stores the files, then numbers the version inside a transaction, so two
    uploads at once still get v3 and v4."""
    db = firebase.db()
    ref = db.collection("versions").document()
    req = db.document(f"requests/{rid}")
    if not req.get().exists:
        raise HTTPException(404, "No such request")
    grid = GF_SPIN_GRID if source == "giftfactory" else SPIN_GRID
    cols, rows = (up.views["cols"], len(up.views["pitches"])) if up.views else (grid, grid)
    names = _save(ref.id, up, cols, rows)

    @firestore.transactional
    def number(t) -> int:
        r = req.get(transaction=t).to_dict() or {}
        if r.get("status", "draft") not in OPEN:
            raise HTTPException(409, "The request is approved and locked")
        n = int(r.get("latestVersion") or 0) + 1
        t.set(ref, {
            "requestId": rid, "customerId": r.get("customerId"), "n": n, "state": "draft",
            "files": names, **({"views": up.views} if up.views else {"spinGrid": grid}), "note": up.note, "source": source, "createdAt": firestore.SERVER_TIMESTAMP,
            **({"estimate": up.estimate} if up.estimate else {}),
        })
        # The newest estimate is the request's too: the printer schedule counts its printMinutes (C-2).
        t.update(req, {"latestVersion": n, "updatedAt": firestore.SERVER_TIMESTAMP, **({"estimate": up.estimate} if up.estimate else {})})
        return n

    try:
        n = number(db.transaction())
    except BaseException:
        shutil.rmtree(_data() / "files" / ref.id, ignore_errors=True)
        raise
    return {"id": ref.id, "n": n}


@router.post("/studio/requests/{rid}/versions")
def upload_from_app(rid: str, _: User, up: Annotated[Upload, Depends()]) -> dict:
    return create_version(rid, up, "app")


def _delete_request(db, rid: str) -> None:
    """A request with everything hanging off it: versions (and their files),
    quotes and comments. Records first, files last, so a failure halfway never
    leaves a version whose files are gone."""
    vids = []
    for col in ("versions", "quotes", "comments", "payments"):
        for d in db.collection(col).where(filter=FieldFilter("requestId", "==", rid)).stream():
            if col == "versions":
                vids.append(d.id)
            d.reference.delete()
    db.document(f"requests/{rid}").delete()
    for vid in vids:
        shutil.rmtree(_data() / "files" / vid, ignore_errors=True)
    shutil.rmtree(_data() / "guests" / rid, ignore_errors=True)
    shutil.rmtree(_data() / "photos" / rid, ignore_errors=True)


@router.delete("/studio/requests/{rid}")
def delete_request(rid: str, _: User) -> dict:
    db = firebase.db()
    if not db.document(f"requests/{rid}").get().exists:
        raise HTTPException(404, "No such request")
    _delete_request(db, rid)
    return {"ok": True}


@router.delete("/studio/customers/{cid}")
def delete_customer(cid: str, _: User) -> dict:
    """The customer, their portal link (the token is on their record) and all their requests."""
    db = firebase.db()
    if not db.document(f"customers/{cid}").get().exists:
        raise HTTPException(404, "No such customer")
    for d in db.collection("requests").where(filter=FieldFilter("customerId", "==", cid)).stream():
        _delete_request(db, d.id)
    for d in db.collection("bills").where(filter=FieldFilter("customerId", "==", cid)).stream():
        d.reference.delete()
    db.document(f"customers/{cid}").delete()
    shutil.rmtree(_data() / "logos" / cid, ignore_errors=True)
    return {"ok": True}


# --- the Flag Maker (a desktop app with a paired key, not a Google account) ---------


def pair(app: str) -> dict:
    """A new key for [app] ("flagmaker", "giftfactory") replaces its old one, so pairing
    again also revokes it; each app has its own. Only the hash is kept; the app shows the key once."""
    key = secrets.token_urlsafe(24)
    (_data() / f"{app}_key.json").write_text(json.dumps({"sha256": _sha(key), "created": time.time()}))
    return {"key": key}


def check_key(app: str, not_paired: str, wrong: str, key: str) -> None:
    try:
        saved = json.loads((_data() / f"{app}_key.json").read_text())["sha256"]
    except (OSError, ValueError, KeyError):
        raise HTTPException(401, not_paired) from None
    if not secrets.compare_digest(saved, _sha(key)):
        raise HTTPException(401, wrong)


@router.get("/studio/versions/{vid}/{name}")
def studio_file(vid: str, name: str, _: User) -> FileResponse:
    """Any file of a version, for the signed-in studio (the 3MF for the slicer)."""
    path = _file(vid, name)
    if not path:
        raise HTTPException(404, "No such file")
    return FileResponse(path, media_type=TYPES[name])


@router.post("/studio/flagmaker-key")
def pair_flagmaker(_: User) -> dict:
    return pair("flagmaker")


def flagmaker(x_studio_key: Annotated[str, Header()] = "") -> None:
    check_key("flagmaker", "The Flag Maker is not paired", "Wrong Flag Maker key", x_studio_key)


FlagMaker = Annotated[None, Depends(flagmaker)]


@router.get("/fm/requests")
def open_requests(_: FlagMaker) -> list[dict]:
    docs = firebase.db().collection("requests").where(filter=FieldFilter("status", "in", list(OPEN))).stream()
    out = [
        {"id": d.id, "title": r.get("title", ""), "customer": r.get("customerName", ""),
         "qty": r.get("qty", 1), "latestVersion": r.get("latestVersion", 0), "updated": _iso(r.get("updatedAt"))}
        for d in docs if (r := d.to_dict() or {})
    ]
    return sorted(out, key=lambda r: r["updated"] or "", reverse=True)


@router.post("/fm/requests/{rid}/versions")
def upload_from_flagmaker(rid: str, _: FlagMaker, up: Annotated[FlagUpload, Depends()]) -> dict:
    return create_version(rid, up, "flagmaker")


# --- B5: the status moves by itself (Gift Factory's reports, the Flag Maker's "printed") ----

MOVES = {"printing": ("approved",), "ready": ("approved", "printing")}  # to: from
MOVE_TEXT = {"printing": "🖨️ התחילה הדפסה", "ready": "✅ מוכן"}


def advance(rid: str, to: str) -> bool:
    """Moves the request to [to] if it is at a status before it; one push when it moved.
    Inside a transaction, so two reports at once push once."""
    db = firebase.db()
    req = db.document(f"requests/{rid}")

    @firestore.transactional
    def move(t) -> dict | None:
        r = req.get(transaction=t).to_dict() or {}
        if r.get("status") not in MOVES[to]:
            return None
        t.update(req, {"status": to, "updatedAt": firestore.SERVER_TIMESTAMP})
        return r

    r = move(db.transaction())
    if r is not None:
        jobs.send_to(jobs.users(), "production", f"{MOVE_TEXT[to]}: {r.get('title', '')}", r.get("customerName", ""),
                     {"route": "/request", "id": rid})
    return r is not None


@router.post("/fm/requests/{rid}/printed")
def flag_printed(rid: str, _: FlagMaker) -> dict:
    """The flag is printed: אושר / בהדפסה → מוכן. Anything else is 409 (not approved yet, or already further)."""
    if not rid.isalnum() or not firebase.db().document(f"requests/{rid}").get().exists:
        raise HTTPException(404, "No such request")
    if not advance(rid, "ready"):
        raise HTTPException(409, "The request is not approved or printing")
    return {"ok": True, "status": "ready"}


# --- B12: one problem channel for the desktop apps -----------------------------------


class Problem(BaseModel):
    version: str = Field(default="", max_length=50)
    code: str = Field(default="", max_length=50)
    message: str = Field(min_length=1, max_length=2000)
    title: str = Field(default="", max_length=200)  # what failed (ERRORS.md, CRM 0.6.0)
    todo: str = Field(default="", max_length=500)  # what to do


def problem_line(app: str, body: Problem) -> str:
    """`<code> <app> <version>: <title>. <message>. To do: <todo>` (root ERRORS.md); empty parts left out."""
    head = " ".join(p for p in (body.code or "no code", app, body.version) if p)
    parts = [p.strip().rstrip(".") for p in (body.title, body.message) if p.strip()]
    if body.todo.strip():
        parts.append("To do: " + body.todo.strip().rstrip("."))
    return f"🐞 {head}: " + ". ".join(parts) + "."


def problem(app: str, body: Problem) -> dict:
    """→ the builder's Telegram, at most 10 an hour per app (an app in a crash loop can't flood it)."""
    _limit(f"problem-{app}", 10)
    try:
        telegram.send(f"🐞 {app} {body.version} · {body.code or 'no code'}\n{body.message}")
    except Exception:  # noqa: BLE001 - Telegram or the network down
        raise HTTPException(502, "Telegram did not take the report") from None
    return {"ok": True, "sent": telegram.configured()}


@router.post("/fm/problem")
def fm_problem(_: FlagMaker, body: Problem) -> dict:
    return problem("Flag Maker", body)


@router.get("/fm/versions/{vid}/recipe")
def recipe(vid: str, _: FlagMaker) -> FileResponse:
    """For "open in Flag Maker": the recipe the version was exported with."""
    path = _file(vid, "recipe.json")
    if not path:
        raise HTTPException(404, "This version has no recipe")
    return FileResponse(path, media_type="application/json")


def _file(vid: str, name: str) -> Path | None:
    if name not in TYPES or not vid.isalnum():
        return None
    path = _data() / "files" / vid / name
    return path if path.is_file() else None


# --- C-6: logo photos on a customer (design sources: kept as sent, never shown to the client) ---

LOGO_TYPES = {"JPEG": ("jpg", "image/jpeg"), "PNG": ("png", "image/png"), "WEBP": ("webp", "image/webp")}
LOGO_MEDIA = dict(LOGO_TYPES.values())
MAX_LOGO = 25 * 1024 * 1024
MAX_LOGOS = 30  # per customer


# Folders on the Pi: "logos" (C-6, per customer) and "photos" (per request: the printed product, studio only).
OWNERS = {"logos": "customers", "photos": "requests"}


def _logo_dir(cid: str, folder: str = "logos") -> Path:
    if not cid.isalnum():
        raise HTTPException(404, "Not found")
    return _data() / folder / cid


def _logos(cid: str, folder: str = "logos") -> list[dict]:
    d = _logo_dir(cid, folder)
    files = sorted(f for f in d.iterdir() if f.suffix[1:] in LOGO_MEDIA) if d.is_dir() else []
    return [{"id": f.stem, "type": LOGO_MEDIA[f.suffix[1:]], "size": f.stat().st_size,
             "uploaded": datetime.fromtimestamp(int(f.stem[:13]) / 1000, timezone.utc).isoformat()} for f in files]


def _logo(cid: str, lid: str, folder: str = "logos") -> Path:
    if lid.isalnum():
        for f in _logo_dir(cid, folder).glob(f"{lid}.*"):
            if f.suffix[1:] in LOGO_MEDIA:
                return f
    raise HTTPException(404, "No such photo")


def _need(folder: str, oid: str) -> None:
    snap = firebase.db().document(f"{OWNERS[folder]}/{oid}").get() if oid.isalnum() else None
    if not snap or not snap.exists:
        raise HTTPException(404, "Not found")


def _add_photos(folder: str, oid: str, photos: list[UploadFile]) -> dict:
    """Several photos at once (phone camera, gallery or PC); each is checked to be a picture."""
    _need(folder, oid)
    d = _logo_dir(oid, folder)
    if len(_logos(oid, folder)) + len(photos) > MAX_LOGOS:
        raise HTTPException(413, f"At most {MAX_LOGOS} photos")
    d.mkdir(parents=True, exist_ok=True)
    added, ms = [], 0
    try:
        for f in photos:
            body = f.file.read(MAX_LOGO + 1)
            if len(body) > MAX_LOGO:
                raise HTTPException(413, f"{f.filename} is over 25 MB")
            try:
                with Image.open(io.BytesIO(body)) as im:
                    fmt = im.format
                    im.verify()
            except (ValueError, OSError, SyntaxError):
                fmt = None
            if fmt not in LOGO_TYPES:
                raise HTTPException(422, f"{f.filename} is not a JPEG, PNG or WebP picture")
            # The id starts with the upload time in ms (the list reads it back), then a random part;
            # one ms later than the previous photo of this upload, so they list in the order sent.
            ms = max(int(time.time() * 1000), ms + 1)
            lid = f"{ms}{secrets.token_hex(3)}"
            (d / f"{lid}.{LOGO_TYPES[fmt][0]}").write_bytes(body)
            added.append(lid)
    except BaseException:
        for lid in added:
            _logo(oid, lid, folder).unlink(missing_ok=True)
        raise
    return {"added": added}


def _get_photo(folder: str, oid: str, lid: str, thumb: int) -> Response:
    """The original, or with ?thumb=<px> a small upright JPEG for the app's thumbnails."""
    path = _logo(oid, lid, folder)
    if not thumb:
        return FileResponse(path, media_type=LOGO_MEDIA[path.suffix[1:]])
    # shortcut: drawn on every request, no cache; fine for a few photos per customer, cache if it gets slow.
    with Image.open(path) as im:
        img = ImageOps.exif_transpose(im).convert("RGB")
    img.thumbnail((min(max(thumb, 64), 800),) * 2)
    out = io.BytesIO()
    img.save(out, "JPEG", quality=80)
    return Response(out.getvalue(), media_type="image/jpeg")


# Same routes for a customer's logos and a request's product photos: /studio/{customers|requests}/{id}/{logos|photos}.
for _folder, _col in OWNERS.items():
    def _routes(folder: str = _folder, col: str = _col) -> None:
        @router.post(f"/studio/{col}/{{oid}}/{folder}")
        def add(oid: str, _: User, photos: Annotated[list[UploadFile], File()]) -> dict:
            return _add_photos(folder, oid, photos)

        @router.get(f"/studio/{col}/{{oid}}/{folder}")
        def listed(oid: str, _: User) -> list[dict]:
            return _logos(oid, folder)

        @router.get(f"/studio/{col}/{{oid}}/{folder}/{{lid}}")
        def get(oid: str, lid: str, _: User, thumb: int = 0) -> Response:
            return _get_photo(folder, oid, lid, thumb)

        @router.delete(f"/studio/{col}/{{oid}}/{folder}/{{lid}}")
        def delete(oid: str, lid: str, _: User) -> dict:
            _logo(oid, lid, folder).unlink()
            return {"ok": True}
    _routes()


@router.get("/fm/logos")
def fm_logos(_: FlagMaker) -> list[dict]:
    """Every customer with logo photos, also those with no request yet; newest upload first."""
    root = _data() / "logos"
    out = []
    for d in (sorted(p for p in root.iterdir() if p.is_dir()) if root.is_dir() else []):
        photos = _logos(d.name)
        snap = firebase.db().document(f"customers/{d.name}").get()
        if photos and snap.exists:
            c = snap.to_dict() or {}
            out.append({"customerId": d.name, "name": c.get("name", ""), "kind": c.get("kind"), "count": len(photos),
                        "updated": max(p["uploaded"] for p in photos), "photos": photos})
    return sorted(out, key=lambda c: c["updated"], reverse=True)


@router.get("/fm/customers/{cid}/logos/{lid}")
def fm_logo(cid: str, lid: str, _: FlagMaker) -> FileResponse:
    path = _logo(cid, lid)
    return FileResponse(path, media_type=LOGO_MEDIA[path.suffix[1:]])


# --- the customer portal ------------------------------------------------------------


def _find(token: str) -> tuple[str, dict]:
    if not 16 <= len(token) <= 64:
        raise HTTPException(404, "Unknown link")
    found = firebase.db().collection("customers").where(filter=FieldFilter("portalToken", "==", token)).limit(1).get()
    if not found:
        raise HTTPException(404, "Unknown link")
    return found[0].id, found[0].to_dict() or {}


# A gift customer's link, and a returning customer's personal area (Alex, 22.11: customer.returning), opens only
# after Google sign-in (Alex, 18.11): the first account to sign in owns the link (googleUid); the app's "reset"
# removes it, and the next account to sign in (the invited one) owns it; the browser then holds a signed cookie "ps" for this link's paths. Alex's own
# allowlisted accounts get in too, as "studio". Microphone customers keep the bare link.
SESSION_DAYS = 180


def _secret() -> bytes:
    path = _data() / "portal_secret"
    if not path.is_file():
        path.write_bytes(secrets.token_bytes(32))
    return path.read_bytes()


def _sign(token: str, who: str, exp: int) -> str:
    return hmac.new(_secret(), f"{token}|{who}|{exp}".encode(), hashlib.sha256).hexdigest()


def _session_who(token: str, ps: str | None) -> str | None:
    """Who the cookie says signed in on this link (a Google uid or "studio"), if it is valid."""
    who, _, rest = (ps or "").rpartition(".")
    who, _, exp = who.rpartition(".")
    if not exp.isdigit() or int(exp) < time.time():
        return None
    return who if hmac.compare_digest(rest, _sign(token, who, int(exp))) else None


def signs_in(c: dict) -> bool:
    return c.get("kind") == "gift" or c.get("returning") is True


def _customer(token: str, ps: str | None) -> tuple[str, dict]:
    cid, c = _find(token)
    if signs_in(c) and (who := _session_who(token, ps)) != "studio" and (not who or who != c.get("googleUid")):
        # The sign-in screen greets them by first name, and as invited while no account owns the link yet.
        raise HTTPException(401, {"signIn": True, "name": (c.get("name") or "").split(" ")[0],
                                  "invited": not c.get("googleUid"), "returning": c.get("returning") is True})
    return cid, c


class SignIn(BaseModel):
    idToken: str = Field(min_length=1, max_length=4096)
    # The portal's cookie consent (22.11): stay signed in (SESSION_DAYS) or this visit only (a browser-session
    # cookie, at most VISIT_HOURS).
    remember: bool = True


VISIT_HOURS = 12


@router.post("/p/{token}/session")
def portal_session(token: str, body: SignIn, response: Response) -> dict:
    """A Firebase ID token from the portal's Google sign-in. The first client account to
    sign in owns a gift link; another account is refused."""
    cid, c = _find(token)
    _limit(token)
    try:
        user = firebase.auth.verify_id_token(body.idToken, app=firebase.app())
    except (firebase.auth.InvalidIdTokenError, firebase.auth.ExpiredIdTokenError):
        raise HTTPException(401, "Invalid or expired token") from None
    email = (user.get("email") or "").lower()
    if not user.get("email_verified"):
        raise HTTPException(403, "Use a Google account with a verified email")
    if email in firebase.access()[0]:
        who = "studio"
    elif not c.get("googleUid"):
        who = user["uid"]
        firebase.db().document(f"customers/{cid}").update({"googleUid": who, "googleEmail": email})
    elif c["googleUid"] == user["uid"]:
        who = user["uid"]
    else:
        raise HTTPException(403, "This link belongs to another Google account")
    life = SESSION_DAYS * 86400 if body.remember else VISIT_HOURS * 3600
    exp = int(time.time()) + life
    # Signed for this link only (_sign includes the token); without max_age the browser drops it when it closes.
    response.set_cookie("ps", f"{who}.{exp}.{_sign(token, who, exp)}", max_age=life if body.remember else None,
                        httponly=True, secure=True, samesite="lax")
    return {"email": email, "studio": who == "studio"}


@router.post("/p/{token}/logout")
def portal_logout(token: str, response: Response) -> dict:
    response.delete_cookie("ps", secure=True, httponly=True, samesite="lax")
    return {"ok": True}


_posts: dict[str, deque] = defaultdict(deque)


def _limit(token: str, per_hour: int = 60) -> None:
    """A forwarded link can't flood the studio with comments and pushes."""
    q, now = _posts[token], time.time()
    while q and q[0] < now - 3600:
        q.popleft()
    if len(q) >= per_hour:
        raise HTTPException(429, "Too many messages, try again later")
    q.append(now)


def _iso(v) -> str | None:
    return v.isoformat() if isinstance(v, datetime) else None


def _mine(cid: str, collection: str) -> list[tuple[str, dict]]:
    docs = firebase.db().collection(collection).where(filter=FieldFilter("customerId", "==", cid)).stream()
    return [(d.id, d.to_dict() or {}) for d in docs]


@router.get("/p/{token}", response_class=HTMLResponse)
def portal_page(token: str) -> HTMLResponse:
    """The page asks for its data itself and says so when the link is dead."""
    return HTMLResponse(
        (STATIC / "portal.html").read_text(encoding="utf-8"),
        headers={
            "Cache-Control": "no-store",
            "X-Frame-Options": "DENY",
            # Google sign-in for gift customers: the Firebase Auth SDK, its popup and its helper frame.
            "Content-Security-Policy": "default-src 'self'; script-src 'self' 'unsafe-inline' https://www.gstatic.com https://apis.google.com; "
            "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; "
            "img-src 'self' blob: data:; connect-src 'self' blob: data: https://identitytoolkit.googleapis.com "
            "https://securetoken.googleapis.com https://www.googleapis.com; "
            "frame-src https://print-studio-1786a.firebaseapp.com https://accounts.google.com",
        },
    )


@router.get("/p/{token}/data")
def portal_data(token: str, preview: str = "", ps: Annotated[str | None, Cookie()] = None) -> dict:
    """Everything the customer sees. [preview] is a draft version id: the app
    opens the portal with it so the studio sees a draft as the customer will."""
    cid, c = _customer(token, ps)
    versions, quotes, comments, payments = defaultdict(list), defaultdict(list), defaultdict(list), defaultdict(list)
    for vid, v in _mine(cid, "versions"):
        if v.get("state") in ("published", "approved") or vid == preview:
            versions[v.get("requestId")].append({
                "id": vid, "n": v.get("n"), "state": v.get("state"),
                "files": [f for f in v.get("files", []) if f in CLIENT_FILES], "spinGrid": v.get("spinGrid", SPIN_GRID),
                "views": {**vw, "tabs": [{"title": title, **{kind: FILES[tab_field(kind, k)][0] for kind in ("preview", "spin")}}
                                         for k, title in enumerate(vw["tabs"], 1)]} if (vw := v.get("views")) else None,
                "note": v.get("note", ""), "at": _iso(v.get("publishedAt") or v.get("createdAt")),
            })
    corrected = {}  # request -> when its newest correction was saved: earlier prices were mistakes
    for qid, q in _mine(cid, "quotes"):
        # The final price only: unit price, discount and VAT amounts stay in the studio.
        quotes[q.get("requestId")].append({
            "id": qid, "note": q.get("note", ""), "at": _iso(q.get("createdAt")),
            "total": quote_total(q), "withVat": int(q.get("vatPercent", 18)) > 0,
        })
        if q.get("correction") and (at := _iso(q.get("createdAt"))):
            corrected[q.get("requestId")] = max(at, corrected.get(q.get("requestId"), at))
    for mid, m in _mine(cid, "comments"):
        comments[m.get("requestId")].append({
            "id": mid, "from": m.get("from"), "text": m.get("text", ""), "pin": m.get("pin"),
            "versionId": m.get("versionId"), "versionN": m.get("versionN"), "at": _iso(m.get("createdAt")),
        })
    for _, p in _mine(cid, "payments"):
        payments[p.get("requestId")].append(int(p.get("amount", 0)))
    out = []
    for rid, r in _mine(cid, "requests"):
        if not versions[rid]:
            continue  # nothing published yet
        qs = sorted(quotes[rid], key=lambda q: q["at"] or "")
        quote = next((q for q in qs if q["id"] == r.get("quoteId")), None)
        paid = sum(payments[rid])
        out.append({
            "id": rid, "title": r.get("title", ""), "qty": r.get("qty", 1), "status": r.get("status", "draft"),
            "updated": _iso(r.get("updatedAt")), "created": _iso(r.get("createdAt")),
            "currentVersionId": r.get("publishedVersionId"),
            "offered": offered(r),
            "versions": sorted(versions[rid], key=lambda v: v["n"] or 0),
            "quote": quote,
            "previousQuotes": [q for q in qs if q["id"] != r.get("quoteId") and (q["at"] or "") >= corrected.get(rid, "")],
            "comments": sorted(comments[rid], key=lambda m: m["at"] or ""),
            "approved": {"versionId": r.get("approvedVersionId"), "at": _iso(r.get("approvedAt"))}
            if r.get("approvedVersionId") else None,
            "declinedAt": _iso(r.get("declinedAt")) if r.get("status") == "declined" else None,
            # Owed once the client approved the price; until then the quote is only an offer.
            # Only what is left: Alex's payment records (dates, methods, notes) stay in the studio.
            "due": max(quote["total"] - paid, 0) if quote and r.get("status", "draft") not in (*OPEN, "declined") else 0,
            # The client's own guest list (giftfactory.py); never the file, only how many.
            "guests": {"names": g.get("names"), "gifts": g.get("gifts"), "at": _iso(g.get("uploadedAt"))}
            if (g := r.get("guests")) else None,
            # While printing: units and the day only; costs and plate details stay in the studio.
            "progress": {k: p.get(k) for k in ("unitsOk", "unitsTarget", "finishDate")}
            if (p := (r.get("production") or {}).get("progress")) and r.get("status") in ("approved", "printing") else None,
        })
    out.sort(key=lambda r: r["updated"] or "", reverse=True)
    returning = c.get("returning") is True
    # A returning customer's area also lists their bills and receipts (billing.py), never a trashed or replaced one.
    bills = sorted(({"number": b.get("number"), "at": _iso(b.get("createdAt")), "total": b.get("total", 0), "due": b.get("due", 0),
                     "state": b.get("state"), "items": len(b.get("lines") or []), "url": f"/b/{b.get('token')}",
                     "receipt": {k: (b.get("receipt") or {}).get(k) for k in ("number", "url")} if b.get("receipt") else None}
                    for _, b in _mine(cid, "bills") if returning and not b.get("deletedAt") and b.get("state") in ("open", "paid")),
                   key=lambda b: b["at"] or "", reverse=True)
    return {"customer": {"name": c.get("name", ""), "lang": c.get("lang", "he"), "kind": c.get("kind"), "returning": returning,
                         "signedIn": signs_in(c), "email": c.get("googleEmail") if returning else None},
            "requests": out, "bills": bills}


@router.get("/p/{token}/f/{vid}/{name}")
def portal_file(token: str, vid: str, name: str, preview: str = "", ps: Annotated[str | None, Cookie()] = None) -> FileResponse:
    """Published (or approved) versions only, so a version Alex takes back is gone from saved
    links too; a draft only in the studio's ?preview= of it, like portal_data."""
    cid, _ = _customer(token, ps)
    path = _file(vid, name) if name in CLIENT_FILES else None
    v = (firebase.db().document(f"versions/{vid}").get().to_dict() or {}) if path else {}
    if v.get("customerId") != cid or (v.get("state") not in ("published", "approved") and vid != preview):
        raise HTTPException(404, "No such file")
    # A version's files never change: the id is the cache key.
    return FileResponse(path, media_type=TYPES[name], headers={"Cache-Control": "private, max-age=86400"})


class Pin(BaseModel):
    view: Literal["2d", "3d", "asm"]
    x: float = Field(ge=-10000, le=10000)
    y: float = Field(ge=-10000, le=10000)
    z: float = Field(default=0, ge=-10000, le=10000)
    tab: int = Field(default=0, ge=0, le=19)  # the plate tab of a version with views, 0 = the first


class Comment(BaseModel):
    versionId: str = Field(max_length=40)
    text: str = Field(min_length=1, max_length=2000)
    pin: Pin | None = None


def _request(cid: str, rid: str) -> tuple[object, dict]:
    ref = firebase.db().document(f"requests/{rid}")
    r = ref.get().to_dict() or {}
    if r.get("customerId") != cid or r.get("status", "draft") == "draft":
        raise HTTPException(404, "No such request")
    return ref, r


@router.post("/p/{token}/requests/{rid}/comments")
def portal_comment(token: str, rid: str, body: Comment, ps: Annotated[str | None, Cookie()] = None) -> dict:
    cid, c = _customer(token, ps)
    _limit(token)
    ref, r = _request(cid, rid)
    v = firebase.db().document(f"versions/{body.versionId}").get().to_dict() or {}
    if v.get("requestId") != rid or v.get("state") not in ("published", "approved"):
        raise HTTPException(404, "No such version")
    text = body.text.strip()
    if not text:
        raise HTTPException(422, "Empty comment")
    firebase.db().collection("comments").add({
        "requestId": rid, "customerId": cid, "versionId": body.versionId, "versionN": v.get("n"),
        "from": "client", "text": text, "pin": body.pin.model_dump() if body.pin else None,
        "createdAt": firestore.SERVER_TIMESTAMP,
    })
    ref.update({"needsReply": True, "updatedAt": firestore.SERVER_TIMESTAMP})
    jobs.send_to(jobs.users(), "client", f"{c.get('name', 'לקוח')}: הערה על {r.get('title', '')}", text[:150],
                 {"route": "/request", "id": rid})
    return {"ok": True}


def offered(r: dict) -> list[str]:
    """The versions the client may approve: several when Alex published them side by side
    (offeredVersionIds), else only the current one; older ones are history."""
    return r.get("offeredVersionIds") or [v for v in [r.get("publishedVersionId")] if v]


class Approval(BaseModel):
    versionId: str = Field(max_length=40)
    quoteId: str = Field(max_length=40)


@router.post("/p/{token}/requests/{rid}/approve")
def portal_approve(token: str, rid: str, body: Approval, ps: Annotated[str | None, Cookie()] = None) -> dict:
    """One step: this version and this price. Both must still be on offer, so a
    customer looking at an old page can't approve what changed."""
    cid, c = _customer(token, ps)
    _limit(token)
    db = firebase.db()
    req = db.document(f"requests/{rid}")

    @firestore.transactional
    def approve(t) -> dict:
        r = req.get(transaction=t).to_dict() or {}
        if r.get("customerId") != cid:
            raise HTTPException(404, "No such request")
        if r.get("status") != "waiting":
            raise HTTPException(409, "Not waiting for approval")
        if body.versionId not in offered(r) or r.get("quoteId") != body.quoteId:
            raise HTTPException(409, "The design or the price changed; reload")
        q = db.document(f"quotes/{body.quoteId}").get(transaction=t).to_dict() or {}
        t.update(req, {
            "status": "approved", "approvedVersionId": body.versionId, "approvedQuoteId": body.quoteId,
            "approvedAt": firestore.SERVER_TIMESTAMP, "updatedAt": firestore.SERVER_TIMESTAMP,
        })
        t.update(db.document(f"versions/{body.versionId}"), {"state": "approved"})
        return {**r, "total": quote_total(q)}

    r = approve(db.transaction())
    jobs.send_to(jobs.users(), "client", f"✅ {c.get('name', 'לקוח')} אישר/ה: {r.get('title', '')}",
                 f"₪{r['total'] / 100:,.2f} כולל מע״מ", {"route": "/request", "id": rid})
    return {"ok": True}


class Decline(BaseModel):
    reason: str = Field(default="", max_length=2000)


@router.post("/p/{token}/requests/{rid}/decline")
def portal_decline(token: str, rid: str, body: Decline, ps: Annotated[str | None, Cookie()] = None) -> dict:
    """The client doesn't want the order at all (notes go in a comment instead; the
    portal says so before asking). Only while waiting; Alex can reopen it in the app."""
    cid, c = _customer(token, ps)
    _limit(token)
    db = firebase.db()
    req = db.document(f"requests/{rid}")

    @firestore.transactional
    def decline(t) -> dict:
        r = req.get(transaction=t).to_dict() or {}
        if r.get("customerId") != cid:
            raise HTTPException(404, "No such request")
        if r.get("status") != "waiting":
            raise HTTPException(409, "Not waiting for approval")
        t.update(req, {"status": "declined", "declinedAt": firestore.SERVER_TIMESTAMP, "needsReply": True,
                       "updatedAt": firestore.SERVER_TIMESTAMP})
        return r

    r = decline(db.transaction())
    reason = body.reason.strip()
    if reason:  # in the thread, where Alex reads the client
        db.collection("comments").add({
            "requestId": rid, "customerId": cid, "versionId": r.get("publishedVersionId"),
            "versionN": (db.document(f"versions/{r.get('publishedVersionId')}").get().to_dict() or {}).get("n"),
            "from": "client", "text": reason, "pin": None, "createdAt": firestore.SERVER_TIMESTAMP,
        })
    jobs.send_to(jobs.users(), "client", f"❌ {c.get('name', 'לקוח')} ביטל/ה את ההזמנה: {r.get('title', '')}",
                 reason[:150] or "בלי סיבה", {"route": "/request", "id": rid})
    return {"ok": True}
