"""The public shop site (C:\\claude projects\\3d\\website, Next.js on Vercel): its products,
their pictures, its wording and its call-back requests, managed from the app's "אתר" tab.

The contract is the website's supabase/schema.sql, src/data/site.ts and src/data/gifts.ts.
- Supabase holds the tables (gifts, site_texts, leads). Only this server has the service
  role key (SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY in the Pi's .env); it talks plain PostgREST.
- The pictures live here, in DATA_DIR/gifts/<slug>/, and anyone may read them at
  /gifts/<slug>/<file> (the site's NEXT_PUBLIC_ASSET_BASE, through the Pi's Tailscale Funnel until there is a domain).
  Pictures only: a name outside PICTURES is never stored or served, so no model file can be.
- Leads are personal data: signed-in studio users only.

The messages are Hebrew: the app shows them to Alex as they are.
"""

import io
import json
import os
import re
import secrets
import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Annotated, Literal

import requests
from fastapi import APIRouter, Depends, File, Header, HTTPException, Request, UploadFile
from fastapi.responses import FileResponse
from PIL import Image, ImageOps
from pydantic import BaseModel, ConfigDict, Field, ValidationError

from . import jobs
from .studio import STATIC, User, _check, _data, check_key, pair

router = APIRouter()
SLUG = re.compile(r"[a-z0-9-]{1,60}")  # gifts.slug in schema.sql
RENDERS = ("still.jpg", "top.jpg", *(f"spin-{i}.jpg" for i in range(7)))  # Gift Factory 1.1.0 › Shop pictures
PICTURES = {"photo.jpg", *RENDERS}
MAX_PICTURE = 15 * 1024 * 1024
PHOTO_SIDE = 2000
NEW_SPIN = {"cols": 24, "rows": 7, "start": [0, 0], "tile": 640}  # until the renderer sends the real one
LEAD_STATUSES = ("new", "called", "opened", "dropped")  # leads.status: new / called / request opened / dropped
DEFAULTS: dict[str, dict[str, str]] = json.loads((STATIC / "site_texts.json").read_text(encoding="utf-8"))  # tool/site_texts.mjs


# --- Supabase ---------------------------------------------------------------------

# Postgres / PostgREST codes -> what happened, in plain words.
PLAIN = {
    "23505": (409, "כבר קיימת רשומה עם המזהה הזה"),
    "23514": (422, "ערך לא עומד בכללים של הטבלה באתר"),
    "23502": (422, "חסר שדה חובה"),
    "22P02": (422, "ערך בצורה לא נכונה (מספר או תאריך)"),
    "42P01": (502, "הטבלה לא קיימת ב-Supabase: מריצים שם את website/supabase/schema.sql"),
    "PGRST205": (502, "הטבלה לא קיימת ב-Supabase: מריצים שם את website/supabase/schema.sql"),
}


def _sb(method: str, path: str, body=None, prefer: str = "return=representation") -> list[dict]:
    """One PostgREST call with the service role key; the rows it returns."""
    url, key = os.environ.get("SUPABASE_URL"), os.environ.get("SUPABASE_SERVICE_ROLE_KEY")
    if not (url and key):
        raise HTTPException(503, "השרת עוד לא מחובר ל-Supabase (SUPABASE_URL ו-SUPABASE_SERVICE_ROLE_KEY ב-.env שלו)")
    try:
        r = requests.request(method, f"{url.rstrip('/')}/rest/v1/{path}", json=body, timeout=20,
                             headers={"apikey": key, "Authorization": f"Bearer {key}", "Prefer": prefer})
    except requests.RequestException:
        raise HTTPException(502, "Supabase לא ענה") from None
    if r.ok:
        return r.json() if r.content else []
    try:
        err = r.json()
    except ValueError:
        err = {}
    if r.status_code in (401, 403):
        raise HTTPException(502, "Supabase דחה את המפתח של השרת (SUPABASE_SERVICE_ROLE_KEY)")
    status, text = PLAIN.get(str(err.get("code")), (502, f"Supabase החזיר שגיאה {r.status_code}"))
    detail = str(err.get("message") or "")[:200]
    raise HTTPException(status, f"{text} ({detail})" if detail else text)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()  # updated_at has no trigger in schema.sql


# --- products ---------------------------------------------------------------------


def _folder(slug: str) -> Path:
    if not SLUG.fullmatch(slug):
        raise HTTPException(422, "מזהה מוצר: אותיות אנגליות קטנות, ספרות ומקפים, עד 60 תווים")
    return _data() / "gifts" / slug


def _measured(slug: str) -> float | None:
    """B13: one unit's print minutes as Gift Factory measured it (kept on the Pi, not in Supabase)."""
    try:
        return json.loads((_folder(slug) / "measured.json").read_text())["unit_minutes"]
    except (OSError, ValueError, KeyError):
        return None


def _images(slug: str) -> dict[str, int]:
    """The pictures the Pi has for a product, each with its time (the version in its URL)."""
    folder = _folder(slug)
    return {n: int(p.stat().st_mtime) for n in sorted(PICTURES) if (p := folder / n).is_file()}


class Langs(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    he: str = Field(min_length=1, max_length=2000)
    en: str = Field(min_length=1, max_length=2000)
    ru: str = Field(min_length=1, max_length=2000)


class Gift(BaseModel):
    """What Alex edits. size_mm and spin are the renderer's; photo follows photo.jpg."""

    model_config = ConfigDict(extra="forbid")
    name: Langs
    text: Langs
    kind: Literal["table", "pocket", "play"]
    min_qty: int = Field(ge=1, le=100000)
    lead_days: int = Field(ge=0, le=365)
    published: bool = False
    feature: bool = False
    sort: int = Field(default=100, ge=0, le=100000)


class NewGift(Gift):
    slug: str = Field(pattern=f"^{SLUG.pattern}$")


def _shown(gift: Gift, slug: str, coming: tuple[str, ...] = ()) -> None:
    """A product on the site needs a picture: its photo or the drawn one."""
    if gift.published and not ({"photo.jpg", "still.jpg"} & (set(_images(slug)) | set(coming))):
        raise HTTPException(422, "למוצר עוד אין תמונה: מעלים צילום או שולחים את הציורים, ורק אז מציגים אותו באתר")


@router.get("/website/gifts")
def gifts(_: User) -> dict:
    rows = _sb("GET", "gifts?select=*&order=sort.asc,slug.asc")
    return {"gifts": [{**g, "images": _images(g["slug"]), "unit_minutes": _measured(g["slug"])} for g in rows]}


@router.post("/website/gifts")
def add_gift(body: NewGift, _: User) -> dict:
    _shown(body, body.slug)
    row = body.model_dump() | {"size_mm": [0, 0, 0], "spin": NEW_SPIN, "photo": "photo.jpg" in _images(body.slug),
                               "updated_at": _now()}
    return _sb("POST", "gifts", row)[0]


@router.put("/website/gifts/{slug}")
def edit_gift(slug: str, body: Gift, _: User) -> dict:
    _shown(body, slug)
    found = _sb("PATCH", f"gifts?slug=eq.{slug}", body.model_dump() | {"updated_at": _now()})
    if not found:
        raise HTTPException(404, "אין מוצר כזה באתר")
    return found[0]


@router.delete("/website/gifts/{slug}")
def delete_gift(slug: str, _: User) -> dict:
    """The row first: the site stops showing the product before its pictures go."""
    folder = _folder(slug)
    _sb("DELETE", f"gifts?slug=eq.{slug}")
    shutil.rmtree(folder, ignore_errors=True)
    return {"ok": True}


# --- pictures ---------------------------------------------------------------------


def _read(f: UploadFile, name: str) -> bytes:
    data = f.file.read(MAX_PICTURE + 1)
    if len(data) > MAX_PICTURE:
        raise HTTPException(413, f"{name} גדול מ-15MB")
    return data


def _photo(slug: str, on: bool) -> None:
    if not _sb("PATCH", f"gifts?slug=eq.{slug}", {"photo": on, "updated_at": _now()}):
        raise HTTPException(404, "אין מוצר כזה באתר")


@router.post("/website/gifts/{slug}/photo")
def put_photo(slug: str, _: User, file: Annotated[UploadFile, File()]) -> dict:
    """Alex's own picture of the gift: JPG, PNG or WebP in, a JPEG of at most 2000 px out."""
    folder = _folder(slug)
    data = _read(file, "הקובץ")
    try:
        with Image.open(io.BytesIO(data)) as im:
            if im.format not in ("JPEG", "PNG", "WEBP"):
                raise ValueError(im.format)
            im = ImageOps.exif_transpose(im).convert("RGBA")  # a phone's photo upright
            im.thumbnail((PHOTO_SIDE, PHOTO_SIDE))
            flat = Image.new("RGB", im.size, "white")  # JPEG has no transparency
            flat.paste(im, mask=im.getchannel("A"))
    except Exception:  # noqa: BLE001 - whatever Pillow raises for a file that is not a picture
        raise HTTPException(415, "הקובץ אינו תמונת JPG, PNG או WebP") from None
    if not _sb("GET", f"gifts?slug=eq.{slug}&select=slug"):
        raise HTTPException(404, "אין מוצר כזה באתר")
    folder.mkdir(parents=True, exist_ok=True)
    tmp = folder / "photo.tmp"
    flat.save(tmp, "JPEG", quality=88)
    tmp.replace(folder / "photo.jpg")
    _photo(slug, True)
    return {"images": _images(slug)}


@router.delete("/website/gifts/{slug}/photo")
def delete_photo(slug: str, _: User) -> dict:
    """The row first, so the site never asks for a picture that is gone."""
    folder = _folder(slug)
    g = _sb("GET", f"gifts?slug=eq.{slug}&select=published")
    if g and g[0]["published"] and "still.jpg" not in _images(slug):
        raise HTTPException(422, "זו התמונה היחידה של מוצר שמוצג באתר: קודם מסתירים אותו")
    _photo(slug, False)
    (folder / "photo.jpg").unlink(missing_ok=True)
    return {"images": _images(slug)}


@router.get("/gifts/{slug}/{name}")
def picture(slug: str, name: str, v: str = "") -> FileResponse:
    """Public and read-only. A URL with ?v= (the picture's time) never changes, so it is kept
    for a year; without it, an hour, so a replaced picture still shows up."""
    path = _data() / "gifts" / slug / name if SLUG.fullmatch(slug) and name in PICTURES else None
    if not path or not path.is_file():
        raise HTTPException(404, "No such picture")
    return FileResponse(path, media_type="image/jpeg", headers={
        "Cache-Control": "public, max-age=31536000, immutable" if v else "public, max-age=3600"})


# --- the drawn pictures, from Gift Factory › Shop pictures on the PC ---------------


@router.post("/website/render-key")
def pair_renders(_: User) -> dict:
    return pair("website")


def render_script(x_studio_key: Annotated[str, Header()] = "") -> None:
    check_key("website", "The picture script is not paired", "Wrong picture script key", x_studio_key)


class Spin(BaseModel):
    model_config = ConfigDict(extra="forbid")
    cols: int = Field(ge=1, le=360)
    rows: int = Field(ge=1, le=7)
    start: tuple[Annotated[int, Field(ge=0)], Annotated[int, Field(ge=0)]]
    tile: int = Field(ge=16, le=4096)


Mm = Annotated[float, Field(gt=0, le=2000)]
Frac = Annotated[float, Field(ge=0, le=1)]


class Spot(BaseModel):
    """Where `{name}` lands on a picture, in fractions of it: centre x, y and the width the name may fill (C-10)."""

    model_config = ConfigDict(extra="forbid")
    x: Frac
    y: Frac
    w: Annotated[float, Field(gt=0, le=1)]
    angle: float = Field(default=0, ge=-180, le=180)


class NameOn(BaseModel):
    model_config = ConfigDict(extra="forbid")
    still: Spot | None = None
    spin: Spot | None = None  # the spin's start view


class Meta(BaseModel):
    """What the renderer measured. [gift] is used only for a product the site does not have
    yet (the first import of the catalog): what Alex edited in the CRM is never overwritten."""

    model_config = ConfigDict(extra="forbid")
    size_mm: tuple[Mm, Mm, Mm]
    spin: Spin
    gift: Gift | None = None
    unit_minutes: float | None = Field(default=None, gt=0, le=10000)  # B13: one unit's print time, measured
    nameOn: NameOn | None = None  # noqa: N815 - the contract's spelling; Supabase column name_on


async def render_form(request: Request) -> dict:
    return dict(await request.form())


@router.post("/website/gifts/{slug}/renders")
def put_renders(slug: str, _: Annotated[None, Depends(render_script)], form: Annotated[dict, Depends(render_form)]) -> dict:
    """Fields: meta (JSON, see Meta) and any of still, top, spin-0 … spin-6, each a JPEG."""
    folder = _folder(slug)
    try:
        meta = Meta.model_validate_json(form.pop("meta", ""))
    except (ValidationError, TypeError) as e:
        raise HTTPException(422, f"meta: {e}") from None
    files = {f"{field}.jpg": f for field, f in form.items()}
    if extra := sorted(set(files) - set(RENDERS)):
        raise HTTPException(400, f"Pictures only (still, top, spin-0 … spin-6), not: {', '.join(extra)[:200]}")
    tmp = Path(tempfile.mkdtemp(dir=_data()))
    try:
        for name, f in files.items():
            if not getattr(f, "filename", ""):
                raise HTTPException(400, f"{name} is not a file")
            (tmp / name).write_bytes(_read(f, name))
            _check(tmp / name)  # a real JPEG, whatever it was called
        row = {"size_mm": list(meta.size_mm), "spin": meta.spin.model_dump(), "updated_at": _now()}
        if meta.nameOn:  # left as it was when the renderer doesn't send it (older Gift Factory)
            row["name_on"] = meta.nameOn.model_dump(exclude_none=True)
        created = False
        if not _sb("PATCH", f"gifts?slug=eq.{slug}", row):
            if not meta.gift:
                raise HTTPException(404, "No such product: add it in the CRM, or send meta.gift")
            _shown(meta.gift, slug, tuple(files))
            _sb("POST", "gifts", meta.gift.model_dump() | row | {"slug": slug, "photo": "photo.jpg" in _images(slug)})
            created = True
        folder.mkdir(parents=True, exist_ok=True)
        for name in files:
            (tmp / name).replace(folder / name)
        if meta.unit_minutes:
            (folder / "measured.json").write_text(json.dumps({"unit_minutes": meta.unit_minutes, "at": _now()}))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return {"created": created, "images": _images(slug)}


# --- wording ----------------------------------------------------------------------


class Wording(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)
    he: str = Field(default="", max_length=4000)
    en: str = Field(default="", max_length=4000)
    ru: str = Field(default="", max_length=4000)


def _key(key: str) -> str:
    if key not in DEFAULTS:
        raise HTTPException(404, "אין טקסט כזה באתר (אם האתר השתנה: node tool/site_texts.mjs ופריסת השרת)")
    return key


@router.get("/website/texts")
def texts(_: User) -> dict:
    return {"defaults": DEFAULTS, "overrides": {r["key"]: r["value"] for r in _sb("GET", "site_texts?select=key,value")}}


@router.put("/website/texts/{key}")
def put_text(key: str, body: Wording, _: User) -> dict:
    """A language left empty, or equal to the code's wording, keeps following the code."""
    value = {lang: v for lang, v in body.model_dump().items() if v and v != DEFAULTS[_key(key)][lang]}
    if not value:
        return reset_text(key, _)
    _sb("POST", "site_texts?on_conflict=key", {"key": key, "value": value, "updated_at": _now()},
        prefer="resolution=merge-duplicates,return=representation")
    return {"value": value}


@router.delete("/website/texts/{key}")
def reset_text(key: str, _: User) -> dict:
    _sb("DELETE", f"site_texts?key=eq.{_key(key)}")
    return {"value": {}}


# --- call-back requests -------------------------------------------------------------


@router.get("/website/leads")
def leads(_: User) -> dict:
    return {"leads": _sb("GET", "leads?select=*&order=created_at.desc&limit=500")}


class LeadStatus(BaseModel):
    status: Literal[LEAD_STATUSES]


@router.post("/website/leads/{lid}/status")
def lead_status(lid: int, body: LeadStatus, _: User) -> dict:
    if not _sb("PATCH", f"leads?id=eq.{lid}", {"status": body.status}):
        raise HTTPException(404, "הפנייה כבר לא קיימת")
    return {"ok": True}


class Lead(BaseModel):
    """What the site sends after it saved the lead; only what the alert shows is read."""

    name: str = Field(default="", max_length=80)
    guests: int | None = None
    wedding_date: str | None = Field(default=None, max_length=10)
    gift: str | None = Field(default=None, max_length=60)  # B3: the product the form was sent from (leads.gift)
    qty: int | None = None  # B3: how many they want (leads.qty)


@router.post("/website/lead")
def new_lead(body: Lead, x_key: Annotated[str, Header()] = "", x_site_key: Annotated[str, Header()] = "") -> dict:
    """The site's LEAD_WEBHOOK_URL. x-key is the contract; X-Site-Key is what the site sent on 15.11.2026."""
    want = os.environ.get("LEAD_WEBHOOK_KEY", "")
    if not want:
        raise HTTPException(503, "LEAD_WEBHOOK_KEY is not set on the server")
    if not secrets.compare_digest(want.encode(), (x_key or x_site_key).encode()):
        raise HTTPException(401, "Wrong key")
    about = [f"{body.qty} × {body.gift or 'מתנה'}" if body.qty else body.gift or "",
             f"{body.guests} אורחים" if body.guests else "", f"חתונה ב-{body.wedding_date}" if body.wedding_date else ""]
    jobs.send_to(jobs.users(), "client", f"פנייה חדשה מהאתר: {body.name}", " · ".join(filter(None, about)) or "מבקשים שנחזור אליהם",
                 {"route": "/leads"})
    return {"ok": True}
