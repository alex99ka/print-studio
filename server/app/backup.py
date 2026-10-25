"""Daily backup of Firestore to Google Drive: one dated JSON file per day in
"<APP_NAME> גיבוי", the newest 30 kept. Uses a refresh token with the
`drive.file` scope (tools/drive_token.py): it can touch only the files this
backup created, nothing else in the Drive."""

import io
import json
import os
import zipfile
from datetime import datetime, timezone
from pathlib import Path

from google.oauth2.credentials import Credentials
from google.auth.transport.requests import AuthorizedSession

from . import firebase

DRIVE = "https://www.googleapis.com/drive/v3/files"
UPLOAD = "https://www.googleapis.com/upload/drive/v3/files"
KEEP = 30

# A new app lists its own collections (users holds push tokens: left out).
COLLECTIONS = ["customers", "requests", "versions", "quotes", "comments", "config"]


def configured() -> bool:
    return all(os.environ.get(k) for k in ("DRIVE_CLIENT_ID", "DRIVE_CLIENT_SECRET", "DRIVE_REFRESH_TOKEN"))


def _session() -> AuthorizedSession:
    return AuthorizedSession(
        Credentials(
            None,
            refresh_token=os.environ["DRIVE_REFRESH_TOKEN"],
            client_id=os.environ["DRIVE_CLIENT_ID"],
            client_secret=os.environ["DRIVE_CLIENT_SECRET"],
            token_uri="https://oauth2.googleapis.com/token",
            scopes=["https://www.googleapis.com/auth/drive.file"],
        )
    )


def _plain(v):
    return v.isoformat() if isinstance(v, datetime) else str(v)


def snapshot() -> bytes:
    db = firebase.db()
    data = {
        name: {d.id: d.to_dict() for d in db.collection(name).stream()} for name in COLLECTIONS
    }
    return json.dumps(data, ensure_ascii=False, indent=1, default=_plain).encode()


def _folder(s: AuthorizedSession, name: str | None = None, parent: str | None = None) -> str:
    name = name or f"{os.environ.get('APP_NAME') or 'app'} גיבוי"
    q = f"name = '{name}' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
    if parent:
        q += f" and '{parent}' in parents"
    r = s.get(DRIVE, params={"q": q, "fields": "files(id)"}, timeout=30)
    r.raise_for_status()
    if found := r.json()["files"]:
        return found[0]["id"]
    meta = {"name": name, "mimeType": "application/vnd.google-apps.folder"} | ({"parents": [parent]} if parent else {})
    r = s.post(DRIVE, json=meta, timeout=30)
    r.raise_for_status()
    return r.json()["id"]


def _upload(s: AuthorizedSession, folder: str, name: str, data: bytes, mime: str) -> None:
    r = s.post(
        UPLOAD,
        params={"uploadType": "multipart", "fields": "id"},
        files={
            "metadata": (None, json.dumps({"name": name, "parents": [folder]}), "application/json; charset=UTF-8"),
            "file": (name, data, mime),
        },
        timeout=300,
    )
    r.raise_for_status()


def files(s: AuthorizedSession, parent: str) -> int:
    """The design files live only on the Pi (an SD card): each version's
    folder goes to Drive once, zipped, into "<backup folder>/files", never
    pruned. Returns how many went up."""
    data = Path(os.environ.get("DATA_DIR", "."))
    done_file = data / "files_backed_up.json"
    done = set(json.loads(done_file.read_text())) if done_file.exists() else set()
    root = data / "files"
    todo = [d for d in sorted(root.iterdir()) if d.is_dir() and d.name not in done] if root.exists() else []
    if not todo:
        return 0
    folder = _folder(s, "files", parent)
    for d in todo:
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
            for f in sorted(d.iterdir()):
                z.write(f, f.name)
        _upload(s, folder, f"{d.name}.zip", buf.getvalue(), "application/zip")
        done.add(d.name)
        done_file.write_text(json.dumps(sorted(done)))  # after each, so a failure resumes
    return len(todo)


def run() -> str:
    """Backs up now; returns the file name. Raises on any failure, so the
    scheduler alerts."""
    s = _session()
    folder = _folder(s)
    name = f"backup-{datetime.now(timezone.utc):%Y-%m-%d}.json"
    _upload(s, folder, name, snapshot(), "application/json")
    # Keep the newest KEEP.
    r = s.get(
        DRIVE,
        params={"q": f"'{folder}' in parents and trashed = false and mimeType != 'application/vnd.google-apps.folder'", "orderBy": "name desc", "fields": "files(id,name)", "pageSize": 200},
        timeout=30,
    )
    r.raise_for_status()
    for old in r.json()["files"][KEEP:]:
        s.delete(f"{DRIVE}/{old['id']}", timeout=30)
    files(s, folder)
    mark(name)
    return name


def _marker() -> Path:
    return Path(os.environ.get("DATA_DIR", ".")) / "last_backup"


def mark(name: str) -> None:
    _marker().write_text(datetime.now(timezone.utc).isoformat())


def last() -> str | None:
    """ISO time of the last good backup, for /health and the app's diagnostics."""
    try:
        return _marker().read_text().strip()
    except OSError:
        return None
