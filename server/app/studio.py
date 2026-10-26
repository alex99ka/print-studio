"""Print Studio: design versions, the Flag Maker link and the customer portal.

Firestore holds the records; the Pi holds the files (Firebase Storage needs a
paid plan) and is the customer's only way in. The customer has no account: the
portal link's token is the key, and every portal route resolves it to one
customer and checks that whatever is asked for belongs to them.

Who writes what:
- the app (checked by firestore.rules): customers, requests, quotes, the
  studio's comments, payments received, publishing a version (request.publishedVersionId);
- here (Admin SDK): versions (uploads from the app or the Flag Maker), the
  customer's comments and the approval.
"""

import hashlib
import json
import os
import secrets
import shutil
import tempfile
import time
import zipfile
from collections import defaultdict, deque
from datetime import datetime
from pathlib import Path
from typing import Annotated, Literal

from fastapi import APIRouter, Depends, File, Form, Header, HTTPException, UploadFile
from fastapi.responses import FileResponse, HTMLResponse
from PIL import Image, ImageDraw, ImageFont
from firebase_admin import firestore
from google.cloud.firestore_v1 import FieldFilter
from pydantic import BaseModel, Field

from . import firebase, jobs

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
}
SPIN_GRID = 6  # 6 x 6 tiles, frame i at row i // 6, column i % 6 (the Flag Maker's crm_link.spin)
TYPES = dict(FILES.values())
# What the client's link serves: watermarked pictures only, never the print file, the recipe or a mesh.
CLIENT_FILES = {"preview.png", "spin.jpg", "spin_asm.jpg"}
MAX_FILE = 60 * 1024 * 1024
OPEN = ("draft", "waiting")  # a request takes new versions only before approval
STATIC = Path(__file__).parent / "static"


def _data() -> Path:
    return Path(os.environ.get("DATA_DIR", "."))


def _sha(s: str) -> str:
    return hashlib.sha256(s.encode()).hexdigest()


def money(unit: int, qty: int, vat_percent: int) -> dict:
    """Agorot in, agorot out; VAT rounded half up to the agora. The app's
    lib/studio/money.dart computes the same."""
    net = unit * qty
    vat = (net * vat_percent + 50) // 100
    return {"unit": unit, "qty": qty, "vatPercent": vat_percent, "net": net, "vat": vat, "total": net + vat}


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


def _watermark(path: Path, grid: int = 1) -> None:
    """Stamps every picture the client sees, each tile of a spin sheet on its own,
    so a screenshot or a saved copy still says it is a preview."""
    with Image.open(path) as im:
        img = im.convert("RGB")
    tw, th = img.width // grid, img.height // grid
    side = 2 * max(tw, th)
    layer = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    font = ImageFont.truetype(str(STATIC / "Heebo.ttf"), max(12, tw // 14))
    step = max(24, th // 4)
    for i, y in enumerate(range(0, side, step)):
        draw.text((-(i % 2) * tw // 3, y), "PRINT STUDIO · PREVIEW ONLY     " * 4, font=font, fill=(90, 96, 110, 64))
    layer = layer.rotate(28, resample=Image.BICUBIC)
    left, top = (side - tw) // 2, (side - th) // 2
    tile = layer.crop((left, top, left + tw, top + th))
    for r in range(grid):
        for c in range(grid):
            img.paste(tile, (c * tw, r * th), tile)
    if path.suffix == ".png":
        img.save(path, "PNG", optimize=True)
    else:
        img.save(path, "JPEG", quality=85)


def _save(vid: str, up: Upload) -> list[str]:
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
            if name in CLIENT_FILES:
                _watermark(tmp / name, SPIN_GRID if name.endswith(".jpg") else 1)
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
    names = _save(ref.id, up)

    @firestore.transactional
    def number(t) -> int:
        r = req.get(transaction=t).to_dict() or {}
        if r.get("status", "draft") not in OPEN:
            raise HTTPException(409, "The request is approved and locked")
        n = int(r.get("latestVersion") or 0) + 1
        t.set(ref, {
            "requestId": rid, "customerId": r.get("customerId"), "n": n, "state": "draft",
            "files": names, "note": up.note, "source": source, "createdAt": firestore.SERVER_TIMESTAMP,
        })
        t.update(req, {"latestVersion": n, "updatedAt": firestore.SERVER_TIMESTAMP})
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
    db.document(f"customers/{cid}").delete()
    return {"ok": True}


# --- the Flag Maker (a desktop app with a paired key, not a Google account) ---------


def _key_file() -> Path:
    return _data() / "flagmaker_key.json"


@router.get("/studio/versions/{vid}/{name}")
def studio_file(vid: str, name: str, _: User) -> FileResponse:
    """Any file of a version, for the signed-in studio (the 3MF for the slicer)."""
    path = _file(vid, name)
    if not path:
        raise HTTPException(404, "No such file")
    return FileResponse(path, media_type=TYPES[name])


@router.post("/studio/flagmaker-key")
def pair_flagmaker(_: User) -> dict:
    """A new key replaces the old one, so pairing again also revokes it. Only
    its hash is kept; the app shows the key once."""
    key = secrets.token_urlsafe(24)
    _key_file().write_text(json.dumps({"sha256": _sha(key), "created": time.time()}))
    return {"key": key}


def flagmaker(x_studio_key: Annotated[str, Header()] = "") -> None:
    try:
        saved = json.loads(_key_file().read_text())["sha256"]
    except (OSError, ValueError, KeyError):
        raise HTTPException(401, "The Flag Maker is not paired") from None
    if not secrets.compare_digest(saved, _sha(x_studio_key)):
        raise HTTPException(401, "Wrong Flag Maker key")


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
def upload_from_flagmaker(rid: str, _: FlagMaker, up: Annotated[Upload, Depends()]) -> dict:
    return create_version(rid, up, "flagmaker")


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


# --- the customer portal ------------------------------------------------------------


def _customer(token: str) -> tuple[str, dict]:
    if not 16 <= len(token) <= 64:
        raise HTTPException(404, "Unknown link")
    found = firebase.db().collection("customers").where(filter=FieldFilter("portalToken", "==", token)).limit(1).get()
    if not found:
        raise HTTPException(404, "Unknown link")
    return found[0].id, found[0].to_dict() or {}


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
            "Content-Security-Policy": "default-src 'self'; script-src 'self' 'unsafe-inline'; "
            "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; "
            "img-src 'self' blob: data:; connect-src 'self' blob: data:",
        },
    )


@router.get("/p/{token}/data")
def portal_data(token: str, preview: str = "") -> dict:
    """Everything the customer sees. [preview] is a draft version id: the app
    opens the portal with it so the studio sees a draft as the customer will."""
    cid, c = _customer(token)
    versions, quotes, comments, payments = defaultdict(list), defaultdict(list), defaultdict(list), defaultdict(list)
    for vid, v in _mine(cid, "versions"):
        if v.get("state") in ("published", "approved") or vid == preview:
            versions[v.get("requestId")].append({
                "id": vid, "n": v.get("n"), "state": v.get("state"),
                "files": [f for f in v.get("files", []) if f in CLIENT_FILES],
                "note": v.get("note", ""), "at": _iso(v.get("publishedAt") or v.get("createdAt")),
            })
    for qid, q in _mine(cid, "quotes"):
        quotes[q.get("requestId")].append({
            "id": qid, "note": q.get("note", ""), "at": _iso(q.get("createdAt")),
            **money(int(q.get("unit", 0)), int(q.get("qty", 1)), int(q.get("vatPercent", 18))),
        })
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
            "updated": _iso(r.get("updatedAt")),
            "currentVersionId": r.get("publishedVersionId"),
            "versions": sorted(versions[rid], key=lambda v: v["n"] or 0),
            "quote": quote,
            "previousQuotes": [q for q in qs if q["id"] != r.get("quoteId")],
            "comments": sorted(comments[rid], key=lambda m: m["at"] or ""),
            "approved": {"versionId": r.get("approvedVersionId"), "at": _iso(r.get("approvedAt"))}
            if r.get("approvedVersionId") else None,
            # Owed once the client approved the price; until then the quote is only an offer.
            # Only what is left: Alex's payment records (dates, methods, notes) stay in the studio.
            "due": max(quote["total"] - paid, 0) if quote and r.get("status", "draft") not in OPEN else 0,
        })
    out.sort(key=lambda r: r["updated"] or "", reverse=True)
    return {"customer": {"name": c.get("name", ""), "lang": c.get("lang", "he")}, "requests": out}


@router.get("/p/{token}/f/{vid}/{name}")
def portal_file(token: str, vid: str, name: str) -> FileResponse:
    cid, _ = _customer(token)
    path = _file(vid, name) if name in CLIENT_FILES else None
    v = firebase.db().document(f"versions/{vid}").get() if path else None
    if not v or not v.exists or (v.to_dict() or {}).get("customerId") != cid:
        raise HTTPException(404, "No such file")
    # A version's files never change: the id is the cache key.
    return FileResponse(path, media_type=TYPES[name], headers={"Cache-Control": "private, max-age=86400"})


class Pin(BaseModel):
    view: Literal["2d", "3d", "asm"]
    x: float = Field(ge=-10000, le=10000)
    y: float = Field(ge=-10000, le=10000)
    z: float = Field(default=0, ge=-10000, le=10000)


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
def portal_comment(token: str, rid: str, body: Comment) -> dict:
    cid, c = _customer(token)
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


class Approval(BaseModel):
    versionId: str = Field(max_length=40)
    quoteId: str = Field(max_length=40)


@router.post("/p/{token}/requests/{rid}/approve")
def portal_approve(token: str, rid: str, body: Approval) -> dict:
    """One step: this version and this price. Both must still be the current
    ones, so a customer looking at an old page can't approve what changed."""
    cid, c = _customer(token)
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
        if r.get("publishedVersionId") != body.versionId or r.get("quoteId") != body.quoteId:
            raise HTTPException(409, "The design or the price changed; reload")
        q = db.document(f"quotes/{body.quoteId}").get(transaction=t).to_dict() or {}
        t.update(req, {
            "status": "approved", "approvedVersionId": body.versionId, "approvedQuoteId": body.quoteId,
            "approvedAt": firestore.SERVER_TIMESTAMP, "updatedAt": firestore.SERVER_TIMESTAMP,
        })
        t.update(db.document(f"versions/{body.versionId}"), {"state": "approved"})
        return {**r, "total": money(int(q.get("unit", 0)), int(q.get("qty", 1)), int(q.get("vatPercent", 18)))["total"]}

    r = approve(db.transaction())
    jobs.send_to(jobs.users(), "client", f"✅ {c.get('name', 'לקוח')} אישר/ה: {r.get('title', '')}",
                 f"₪{r['total'] / 100:,.2f} כולל מע״מ", {"route": "/request", "id": rid})
    return {"ok": True}
