"""What the Pi does on its own, since Firebase's free plan has no Cloud
Functions:

- every minute: push a new release (prereleases to early users only),
  forward Firestore `reports` to Telegram (customer comments and approvals
  are pushed as they happen, from studio.py);
- every day at 03:00 Israel time: back up Firestore to Drive;
- every day at 09:00: remind of request deadlines (when printing must start, the
  day before, on the day, and the day after when it was missed).

A job that fails sends one Telegram alert and the loop carries on.
"""

import asyncio
import json
import math
import logging
import os
import uuid
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import requests
from google.cloud.firestore_v1 import ArrayRemove

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


# Pushes each person has not seen yet (uid -> tags), so seen() clears them on all their devices.
# shortcut: in memory, lost on a restart (those notifications then stay until swiped); fine for one Pi.
_unseen: dict[str, list[str]] = {}


def send_to(people: list[tuple[str, dict]], kind: str, title: str, body: str, data: dict | None = None) -> int:
    """Pushes to everyone in [people] who hasn't turned [kind] off, and drops
    tokens FCM says are gone. Never raises: callers push after their write is
    saved, and a lost alert must not turn a saved comment or approval into an error."""
    sent = 0
    tag = uuid.uuid4().hex[:16]
    for uid, u in people:
        if (u.get("notify") or {}).get(kind) is False:
            continue
        tokens = u.get("fcmTokens") or []
        try:
            gone = firebase.push(tokens, title, body, data, tag=tag)
        except Exception:  # noqa: BLE001 - FCM or the network down: the record is saved, only the alert is lost
            log.exception("Push failed: %s", title)
            continue
        sent += len(tokens) - len(gone)
        if tokens:
            _unseen[uid] = [*_unseen.get(uid, [])[-49:], tag]
        if gone:
            firebase.db().document(f"users/{uid}").update({"fcmTokens": ArrayRemove(gone)})
    return sent


def _android_file() -> Path:
    return Path(os.environ.get("DATA_DIR", ".")) / "android_tokens.json"


def seen(uid: str, token: str = "", platform: str = "") -> int:
    """Seen on one device (the app opened or in use there): gone from the others too.
    Only Android phones get the silent "remove" message: Safari revokes a web app's
    pushes after a few that show nothing. Each phone says what it is when it reports."""
    android = set(json.loads(_android_file().read_text())) if _android_file().exists() else set()
    if platform == "android" and token and token not in android:
        _android_file().write_text(json.dumps(sorted(android | {token})))
        android.add(token)
    tags = _unseen.pop(uid, [])
    if tags:
        u = firebase.db().document(f"users/{uid}").get().to_dict() or {}
        firebase.dismiss([t for t in u.get("fcmTokens") or [] if t in android], tags)
    return len(tags)


# --- the minute loop ------------------------------------------------------------


def new_release(state: dict) -> None:
    # GitHub allows a home connection 60 unsigned calls an hour, shared with the
    # phones' own update checks. Asking "changed since this ETag?" costs nothing
    # when the answer is 304, so polling every minute no longer uses them up.
    headers = {"Accept": "application/vnd.github+json"}
    if state.get("releases_etag"):
        headers["If-None-Match"] = state["releases_etag"]
    r = requests.get(
        f"https://api.github.com/repos/{os.environ['GITHUB_REPO']}/releases?per_page=5",
        headers=headers,
        timeout=20,
    )
    if r.status_code == 304:
        return
    r.raise_for_status()
    state["releases_etag"] = r.headers.get("ETag", "")
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


MINUTE_JOBS = [("הודעה על גרסה", new_release), ("העברת דיווחים", forward_reports)]


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


async def every_day(job, hour: int, name: str = "הגיבוי היומי") -> None:
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
            alert(name, e)
        at += timedelta(days=1)


def daily_backup() -> None:
    if backup.configured():
        backup.run()


# Days before the deadline that remind besides the "start printing" one; -1 = it passed
# yesterday and the order isn't out.
REMIND = {1: "מחר", 0: "היום", -1: "עבר אתמול"}
SPARE_DAYS = 2  # the first reminder: the printing still ahead plus 2 days


def print_hours_left(r: dict) -> float:
    """Hours of printing still ahead: Gift Factory's printHours for the run (production.quote)
    less the plates already done (production.progress); else the Flag Maker's printMinutes per
    unit (request.estimate, B8) times the quantity; else one day. lib/studio/studio.dart counts the same."""
    p = r.get("production") or {}
    hours = (p.get("quote") or {}).get("printHours")
    if isinstance(hours, (int, float)) and hours > 0:
        prog = p.get("progress") or {}
        total, done = prog.get("platesTotal") or 0, prog.get("platesDone") or 0
        return hours * max(0, total - done) / total if total > 0 else hours
    minutes = (r.get("estimate") or {}).get("printMinutes")
    if isinstance(minutes, (int, float)) and minutes > 0:
        return minutes * max(1, int(r.get("qty") or 1)) / 60
    return 24


def print_days_left(r: dict) -> int:
    return math.ceil(print_hours_left(r) / 24)


UNSCHEDULED = ("ready", "delivered", "paid", "declined")  # nothing left to print


def print_schedule(rows: dict[str, dict]) -> dict[str, tuple[datetime, datetime]]:
    """C-2 (B9): one X2D for Gift Factory runs and Flag Maker flags alike. Every request with a
    deadline and printing still ahead gets (start, end): as late as it can, ending SPARE_DAYS
    before its deadline, and before the next one starts (latest deadline placed first), so two
    orders never share the printer. A start before today means the printer can no longer make it.
    The same as printSchedule() in lib/studio/studio.dart (same test cases)."""
    queue = []
    for rid, r in rows.items():
        try:
            due = date.fromisoformat(r.get("deadline") or "")
        except ValueError:
            continue
        if r.get("status") not in UNSCHEDULED:
            queue.append((due, rid, print_hours_left(r)))
    out, cursor = {}, None
    for due, rid, hours in sorted(queue, reverse=True):
        end = datetime.combine(due - timedelta(days=SPARE_DAYS), datetime.min.time())
        end = min(end, cursor) if cursor else end
        cursor = end - timedelta(hours=hours)
        out[rid] = (cursor, end)
    return out


def deadline_reminders(today: date | None = None) -> int:
    """One push per request whose printing must start today on the shared printer schedule
    (print_schedule; alone, its printing plus 2 days before the deadline: a 7-day run 9 days
    before), or whose deadline is tomorrow, today or was yesterday; none once it is delivered
    (or the client declined it). Plus one push naming every order the printer can no longer fit."""
    today = today or datetime.now(ISRAEL).date()
    rows = {d.id: d.to_dict() or {} for d in firebase.db().collection("requests").stream()}
    plan = print_schedule(rows)
    people, sent = None, 0
    late = [r.get("title", "") for rid, r in rows.items() if rid in plan and plan[rid][0].date() < today and r.get("status") != "printing"]
    if late:  # every morning until Alex moves a deadline or an order
        people = users()
        send_to(people, "deadlines", "⚠️ המדפסת לא תספיק בזמן", " · ".join(late)[:300], {"route": "/schedule"})
        sent += 1
    for rid, r in rows.items():
        if r.get("status") in ("delivered", "paid", "declined"):
            continue
        try:
            due = date.fromisoformat(r.get("deadline") or "")
        except ValueError:
            continue
        left, printing = (due - today).days, print_days_left(r)
        if rid in plan and plan[rid][0].date() == today and left not in REMIND:
            title = f"🖨️ להתחיל להדפיס: {r.get('title', '')}"
            ahead = {0: "ההדפסה הסתיימה", 1: "נשאר כיום הדפסה אחד"}.get(printing, f"נשארו כ-{printing} ימי הדפסה")
            body = f"תאריך היעד בעוד {left} ימים ({due:%d.%m}) · {ahead} · {r.get('customerName', '')}"
        elif left in REMIND:
            title = f"⏰ תאריך יעד {REMIND[left]}: {r.get('title', '')}"
            body = f"{r.get('customerName', '')} · {due:%d.%m}"
        else:
            continue
        people = people if people is not None else users()
        send_to(people, "deadlines", title, body, {"route": "/request", "id": rid})
        sent += 1
    return sent
