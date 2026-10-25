"""What the Pi does on its own, since Firebase's free plan has no Cloud
Functions:

- every minute: push "someone added X" to the other members, push a new
  release (prereleases to early users only), forward Firestore `reports`
  to Telegram;
- every day at 03:00 Israel time: back up Firestore to Drive.

A job that fails sends one Telegram alert and the loop carries on.
"""

import asyncio
import json
import logging
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import requests
from google.cloud.firestore_v1 import ArrayRemove, FieldFilter

from . import backup, firebase, telegram

log = logging.getLogger(__name__)
ISRAEL = ZoneInfo("Asia/Jerusalem")
APP = os.environ.get("APP_NAME") or "האפליקציה"


def _state_file() -> Path:
    return Path(os.environ.get("DATA_DIR", ".")) / "state.json"


def load_state() -> dict:
    try:
        return json.loads(_state_file().read_text())
    except (OSError, ValueError):
        return {}


def save_state(state: dict) -> None:
    _state_file().write_text(json.dumps(state))


def alert(what: str, error: Exception) -> None:
    try:
        telegram.send(f"⚠️ {APP}: {what} נכשל\n{type(error).__name__}: {error}")
    except Exception:
        log.exception("Could not even send the alert")


# --- recipients ---------------------------------------------------------------


def users() -> list[tuple[str, dict]]:
    return [(d.id, d.to_dict() or {}) for d in firebase.db().collection("users").stream()]


def send_to(people: list[tuple[str, dict]], kind: str, title: str, body: str, data: dict | None = None) -> int:
    """Pushes to everyone in [people] who hasn't turned [kind] off, and drops
    tokens FCM says are gone."""
    sent = 0
    for uid, u in people:
        if (u.get("notify") or {}).get(kind) is False:
            continue
        tokens = u.get("fcmTokens") or []
        gone = firebase.push(tokens, title, body, data)
        sent += len(tokens) - len(gone)
        if gone:
            firebase.db().document(f"users/{uid}").update({"fcmTokens": ArrayRemove(gone)})
    return sent


# --- the minute loop ------------------------------------------------------------


def new_items(state: dict) -> None:
    since = datetime.fromisoformat(state.get("items_since") or datetime.now(timezone.utc).isoformat())
    docs = (
        firebase.db()
        .collection("items")
        .where(filter=FieldFilter("createdAt", ">", since))
        .order_by("createdAt")
        .stream()
    )
    people = None
    for d in docs:
        item = d.to_dict()
        people = people or users()
        others = [(uid, u) for uid, u in people if uid != item.get("by")]
        send_to(others, "items", f"{item.get('byName') or 'מישהו'} הוסיף", item.get("title", ""), {"route": "/items", "id": d.id})
        since = item["createdAt"]
    state["items_since"] = since.isoformat()


def new_release(state: dict) -> None:
    r = requests.get(
        f"https://api.github.com/repos/{os.environ['GITHUB_REPO']}/releases?per_page=5",
        headers={"Accept": "application/vnd.github+json"},
        timeout=20,
    )
    r.raise_for_status()
    releases = [x for x in r.json() if not x.get("draft")]
    if not releases:
        return
    _, early = firebase.access()
    seen = state.setdefault("releases_seen", {})
    for rel in releases[:1] + [x for x in releases[1:] if not x.get("prerelease")][:1]:
        tag, pre = rel["tag_name"], rel.get("prerelease", False)
        key = f"{tag}:{'pre' if pre else 'full'}"
        if seen.get(key):
            continue
        seen[key] = True
        if not state.get("releases_primed"):
            continue  # first run: remember what exists, announce nothing
        people = [(uid, u) for uid, u in users() if not pre or (u.get("email") or "").lower() in early]
        send_to(people, "updates", f"גרסה {tag} של {APP}", "מתעדכנת לבד ברקע. פותחים כדי לראות מה חדש.")
    state["releases_primed"] = True


def forward_reports(state: dict) -> None:
    for d in firebase.db().collection("reports").limit(20).stream():
        r = d.to_dict() or {}
        telegram.send(
            f"🐞 {APP} · {r.get('email')} · {r.get('version')} {r.get('platform')}\n{r.get('text')}\n\n"
            + "\n".join(r.get("diagnostics") or [])
            + ("\n\nשגיאות:\n" + "\n".join(r.get("errors") or []) if r.get("errors") else "")
        )
        d.reference.delete()


MINUTE_JOBS = [("התראות על פריטים", new_items), ("הודעה על גרסה", new_release), ("העברת דיווחים", forward_reports)]


async def every_minute() -> None:
    failing: set[str] = set()
    while True:
        state = load_state()
        for name, job in MINUTE_JOBS:
            try:
                await asyncio.to_thread(job, state)
                failing.discard(name)
            except Exception as e:  # noqa: BLE001 - every failure is reported
                log.exception("%s failed", name)
                if name not in failing:  # one alert per outage, not one a minute
                    failing.add(name)
                    alert(name, e)
        save_state(state)
        await asyncio.sleep(60)


# --- the daily loop --------------------------------------------------------------


async def every_day(job, hour: int) -> None:
    """Runs [job] once a day at [hour]:00 Israel time, also on the nights the
    clocks change, and after a run that failed."""
    at = datetime.now(ISRAEL).replace(hour=hour, minute=0, second=0, microsecond=0)
    while True:
        now = datetime.now(ISRAEL)
        while at <= now:
            at += timedelta(days=1)  # the same hour on the clock, summer or winter
        # Timestamps: subtracting two Israel times ignores a clock change between them.
        await asyncio.sleep(at.timestamp() - now.timestamp())
        try:
            await asyncio.to_thread(job)
        except Exception as e:  # noqa: BLE001
            log.exception("Daily job failed")
            alert("הגיבוי היומי", e)
        at += timedelta(days=1)


def daily_backup() -> None:
    if backup.configured():
        backup.run()
