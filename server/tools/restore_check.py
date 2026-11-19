"""Monthly restore check (C-7): proves the Drive backup can be read back. Run on the PC:

    ssh -i ~/.ssh/pi5 alex99ka@pi5-home-server "cat ~/docker/print-studio/.env" | server/.venv/Scripts/python server/tools/restore_check.py

It reads the Pi's .env from stdin (only DRIVE_* and APP_NAME are used; nothing is printed or kept), downloads the
newest backup JSON, the newest logo-photos zip and the newest Gift Factory zip into a folder in %TEMP%, opens each,
and prints what is inside. Exit code 1 when the backup is missing, has no customers, is over 2 days old, or a zip
does not open.
"""

import json
import os
import sys
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from app import backup  # noqa: E402

FOLDER = "application/vnd.google-apps.folder"


def env_from(text: str) -> None:
    for line in text.splitlines():
        key, _, value = line.partition("=")
        if key.startswith("DRIVE_") or key == "APP_NAME":
            os.environ[key.strip()] = value.strip().strip('"').strip("'")


def listing(s, q: str) -> list[dict]:
    """Every match, newest name first (paged)."""
    out, page = [], None
    while True:
        r = s.get(backup.DRIVE, params={"q": q + " and trashed = false", "orderBy": "name desc", "pageSize": 1000,
                                        "fields": "nextPageToken,files(id,name,size)", **({"pageToken": page} if page else {})}, timeout=60)
        r.raise_for_status()
        out += r.json()["files"]
        if not (page := r.json().get("nextPageToken")):
            return out


def download(s, f: dict, into: Path) -> Path:
    r = s.get(f"{backup.DRIVE}/{f['id']}", params={"alt": "media"}, timeout=600)
    r.raise_for_status()
    (path := into / f["name"]).write_bytes(r.content)
    return path


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")  # Hebrew names on a Windows console
    env_from(sys.stdin.buffer.read().decode("utf-8"))
    if not backup.configured():
        print("!! no DRIVE_* lines came in on stdin (see the docstring for the command)")
        return 1
    s, bad = backup._session(), []
    name = f"{os.environ.get('APP_NAME') or 'app'} גיבוי"
    top = listing(s, f"name = '{name}' and mimeType = '{FOLDER}'")
    if not top:
        print(f"!! no folder '{name}' in Drive")
        return 1
    into = Path(tempfile.gettempdir()) / f"restore-check-{datetime.now():%Y-%m-%d}"
    into.mkdir(exist_ok=True)

    days = listing(s, f"'{top[0]['id']}' in parents and mimeType != '{FOLDER}' and name contains 'backup-'")
    if not days:
        print("!! no daily backup file")
        return 1
    data = json.loads(download(s, days[0], into).read_text(encoding="utf-8"))
    age = (datetime.now(timezone.utc).date() - datetime.strptime(days[0]["name"][7:17], "%Y-%m-%d").date()).days
    print(f"{days[0]['name']} ({len(days)} kept, {age} days old): "
          + ", ".join(f"{len(v)} {k}" for k, v in data.items()))
    if age > 2:
        bad.append("the newest backup is over 2 days old")
    if not data.get("customers"):
        bad.append("no customers in the backup")

    sub = listing(s, f"'{top[0]['id']}' in parents and name = 'files' and mimeType = '{FOLDER}'")
    files = listing(s, f"'{sub[0]['id']}' in parents") if sub else []
    kinds: dict[str, int] = {}
    for f in files:
        kind = next((k for k in ("logos", "photos", "guests", "giftfactory") if f["name"].startswith(k + "-")), "versions")
        kinds[kind] = kinds.get(kind, 0) + 1
    print("files: " + (", ".join(f"{n} {k}" for k, n in sorted(kinds.items())) or "none"))
    for kind, what in (("logos", "logo photos"), ("giftfactory", "Gift Factory zip")):
        newest = max((f for f in files if f["name"].startswith(kind + "-")), key=lambda f: f["name"].rsplit("-", 1)[-1], default=None)
        if not newest:  # not an error by itself: none may exist on the Pi yet (19.11: no logo photos yet)
            print(f"no {what} in Drive yet")
            continue
        path = download(s, newest, into)
        try:
            with zipfile.ZipFile(path) as z:
                if broken := z.testzip():
                    raise zipfile.BadZipFile(broken)
                print(f"{newest['name']}: opens, {len(z.namelist())} files ({', '.join(z.namelist()[:4])})")
        except zipfile.BadZipFile as e:
            bad.append(f"{newest['name']} does not open ({e})")
    print(f"downloaded to {into}")
    for b in bad:
        print("!! " + b)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
