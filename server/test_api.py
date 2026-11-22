"""Run: .venv/Scripts/pytest -q (from server/). No network, no Firebase."""

import os

os.environ.setdefault("GOOGLE_CLOUD_PROJECT", "demo-print-studio")
os.environ.setdefault("GITHUB_REPO", "alex99ka/print-studio")
os.environ["RUN_JOBS"] = "0"

import pytest
from fastapi.testclient import TestClient

from app import backup, firebase, jobs, main, telegram


@pytest.fixture
def sent(monkeypatch):
    out = []
    monkeypatch.setattr(telegram, "send", out.append)
    return out


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    return TestClient(main.app)


def test_health_has_no_secrets(client):
    r = client.get("/health")
    assert r.status_code == 200
    assert set(r.json()) == {"ok", "last_backup", "backup", "telegram", "version", "gf_backup"}
    assert r.json()["gf_backup"] is None  # no Gift Factory zip yet
    assert r.headers["X-Content-Type-Options"] == "nosniff"


def test_health_version_is_the_release():
    from pathlib import Path

    pubspec = Path(__file__).parent.parent / "pubspec.yaml"
    if pubspec.exists():  # not on the Pi (only server/ is deployed)
        assert f"version: {main.VERSION}+" in pubspec.read_text()


def test_restore_reminder_on_the_first_only(sent):
    from datetime import date

    assert not jobs.restore_reminder(date(2026, 12, 2)) and sent == []
    assert jobs.restore_reminder(date(2026, 12, 1)) and "restore_check.py" in sent[0]


def test_restore_check_takes_only_the_drive_lines_of_the_env(monkeypatch):
    import sys
    from pathlib import Path

    sys.path.insert(0, str(Path(__file__).parent / "tools"))
    import restore_check

    for k in ("DRIVE_CLIENT_ID", "APP_NAME", "TELEGRAM_BOT_TOKEN"):
        monkeypatch.delenv(k, raising=False)
    restore_check.env_from('DRIVE_CLIENT_ID="abc"\nAPP_NAME=סטודיו\nTELEGRAM_BOT_TOKEN=secret\n# x')
    assert os.environ["DRIVE_CLIENT_ID"] == "abc" and os.environ["APP_NAME"] == "סטודיו"
    assert "TELEGRAM_BOT_TOKEN" not in os.environ


def test_report_needs_a_token(client):
    assert client.post("/report", json={"text": "x"}).status_code in (401, 403)


def test_report_goes_to_telegram(client, sent):
    main.app.dependency_overrides[firebase.current_user] = lambda: {"email": "alex@example.com"}
    try:
        r = client.post(
            "/report",
            json={"text": "לא נטען", "version": "1.2.0 (3)", "platform": "android", "errors": ["N1 x"], "diagnostics": ["גרסה: 1.2.0"]},
        )
    finally:
        main.app.dependency_overrides.clear()
    assert r.status_code == 200
    assert "alex@example.com" in sent[0] and "לא נטען" in sent[0] and "N1 x" in sent[0]


def test_report_size_is_bounded(client, sent):
    main.app.dependency_overrides[firebase.current_user] = lambda: {"email": "a"}
    try:
        assert client.post("/report", json={"text": "x" * 5000}).status_code == 422
    finally:
        main.app.dependency_overrides.clear()
    assert sent == []


def test_send_to_respects_switches_and_drops_dead_tokens(monkeypatch):
    pushed, removed = [], []
    monkeypatch.setattr(firebase, "push", lambda tokens, *a, **k: pushed.append(tokens) or ["dead"])

    class Doc:
        def __init__(self, path):
            self.path = path

        def update(self, data):
            removed.append(self.path)

    class Db:
        def document(self, path):
            return Doc(path)

    monkeypatch.setattr(firebase, "db", lambda: Db())
    people = [
        ("a", {"fcmTokens": ["t1", "dead"]}),
        ("b", {"fcmTokens": ["t2"], "notify": {"client": False}}),
        ("c", {}),
    ]
    jobs.send_to(people, "client", "title", "body")
    assert pushed == [["t1", "dead"], []]  # b turned client pushes off; c has no tokens
    assert removed == ["users/a", "users/c"]


def test_a_failed_push_never_raises(monkeypatch):
    """Callers push after their write is saved: FCM down must not turn that into a 500."""
    tried = []

    def push(tokens, *a, **k):
        tried.append(tokens)
        if tokens == ["t1"]:
            raise ConnectionError("FCM down")
        return []

    monkeypatch.setattr(firebase, "push", push)
    assert jobs.send_to([("a", {"fcmTokens": ["t1"]}), ("b", {"fcmTokens": ["t2"]})], "client", "t", "b") == 1
    assert tried == [["t1"], ["t2"]]  # the next person still gets it


def test_a_push_seen_on_one_device_leaves_the_others(monkeypatch, tmp_path):
    tags, dismissed = [], []
    monkeypatch.setattr(firebase, "push", lambda tokens, *a, tag="", **k: tags.append(tag) or [])
    monkeypatch.setattr(firebase, "dismiss", lambda tokens, t: dismissed.append((tokens, t)) or [])

    class Db:
        def document(self, path):
            class Doc:
                def get(self):
                    return type("Snap", (), {"to_dict": lambda _: {"fcmTokens": ["phone", "web"]}})()
            return Doc()

    monkeypatch.setattr(firebase, "db", lambda: Db())
    monkeypatch.setattr(jobs, "_unseen", {})
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    me = [("alex", {"fcmTokens": ["phone", "web"]})]
    jobs.send_to(me, "client", "a", "b")
    jobs.send_to(me, "client", "c", "d")
    assert len(set(tags)) == 2 and all(tags)  # one tag per push, the same on every device
    jobs.seen("someone", "phone", "android")  # the phone said what it is once
    assert jobs.seen("alex", "pc", "windows") == 2
    assert dismissed == [(["phone"], tags)]  # never a silent push to the web app (Safari revokes those)
    assert jobs.seen("alex") == 0 and len(dismissed) == 1  # nothing new: no message


def test_pushes_seen_needs_sign_in(client, monkeypatch):
    assert client.post("/pushes/seen").status_code in (401, 403)
    monkeypatch.setattr(jobs, "seen", lambda uid, token, platform: 3 if (uid, platform) == ("alex", "android") else 0)
    main.app.dependency_overrides[firebase.current_user] = lambda: {"uid": "alex"}
    try:
        assert client.post("/pushes/seen", json={"token": "t", "platform": "android"}).json() == {"cleared": 3}
        assert client.post("/pushes/seen").json() == {"cleared": 0}
    finally:
        main.app.dependency_overrides.clear()


def test_print_days_left_from_gift_factory():
    def r(hours=None, done=0, total=0):
        return {"production": {"quote": {"printHours": hours}, "progress": {"platesDone": done, "platesTotal": total}}}

    assert jobs.print_days_left({}) == 1  # a microphone flag: no Gift Factory numbers
    assert jobs.print_days_left(r(7 * 24)) == 7  # a phone stand run
    assert jobs.print_days_left(r(70.5)) == 3  # key chains, rounded up
    assert jobs.print_days_left(r(7 * 24, done=4, total=7)) == 3  # 3 of 7 plates still to go
    assert jobs.print_days_left(r(7 * 24, done=7, total=7)) == 0


def test_deadline_reminders_when_printing_must_start_the_day_before_on_the_day_and_once_missed(monkeypatch):
    from datetime import date

    rows = {
        "soon": {"title": "דגל", "customerName": "נועה", "deadline": "2026-11-01", "status": "printing"},
        "stand": {"title": "מעמד", "deadline": "2026-11-07", "status": "approved",
                  "production": {"quote": {"printHours": 168}}},  # 7 days of printing: 9 days before
        "stand_late": {"title": "מעמד", "deadline": "2026-11-06", "status": "approved",
                       "production": {"quote": {"printHours": 168}}},
        "tomorrow": {"title": "מטבעות", "deadline": "2026-10-30", "status": "approved"},
        "today": {"title": "x", "deadline": "2026-10-29", "status": "draft"},
        "missed": {"title": "y", "deadline": "2026-10-28", "status": "ready"},
        "long_ago": {"title": "z", "deadline": "2026-10-20", "status": "ready"},
        "far": {"title": "w", "deadline": "2026-11-20", "status": "draft"},
        "delivered": {"title": "v", "deadline": "2026-10-30", "status": "delivered"},
        "none": {"title": "u", "deadline": None, "status": "draft"},
        "junk": {"title": "t", "deadline": "soon", "status": "draft"},
    }

    class Db:
        def collection(self, name):
            assert name == "requests"
            return self

        def stream(self):
            return [type("D", (), {"id": k, "to_dict": lambda _, v=v: v})() for k, v in rows.items()]

    monkeypatch.setattr(firebase, "db", lambda: Db())
    monkeypatch.setattr(jobs, "users", lambda: [("alex", {})])
    sends = []
    monkeypatch.setattr(jobs, "send_to", lambda people, kind, title, body, data: sends.append((kind, title, body, data.get("id"))))
    assert jobs.deadline_reminders(date(2026, 10, 29)) == 5
    # One printer (C-2): the two stands fill it, so what is due before them can no longer fit ("soon" is on it already).
    assert [s[3] for s in sends] == [None, "stand", "tomorrow", "today", "missed"]
    assert sends[0] == ("deadlines", "⚠️ המדפסת לא תספיק בזמן", "מעמד · מטבעות · x", None)
    assert sends[1][2] == "תאריך היעד בעוד 9 ימים (07.11) · נשארו כ-7 ימי הדפסה · "
    assert sends[4][1] == "⏰ תאריך יעד עבר אתמול: y"


def test_release_announced_once_prereleases_to_early_users_only(monkeypatch):
    releases = [
        {"tag_name": "1.3.0", "prerelease": True},
        {"tag_name": "1.2.0", "prerelease": False},
    ]

    class Res:
        status_code = 200
        headers = {"ETag": '"v1"'}

        def raise_for_status(self):
            pass

        def json(self):
            return releases

    asked = []
    monkeypatch.setattr(jobs.requests, "get", lambda *a, **k: asked.append(k["headers"].get("If-None-Match")) or Res())
    monkeypatch.setattr(firebase, "access", lambda: ({"alex@x", "avital@x"}, {"alex@x"}))
    monkeypatch.setattr(jobs, "users", lambda: [("a", {"email": "alex@x"}), ("v", {"email": "avital@x"})])
    sends = []
    monkeypatch.setattr(jobs, "send_to", lambda people, kind, title, *a, **k: sends.append((title, [u for u, _ in people])))

    state = {}
    jobs.new_release(state)  # first run only learns what exists
    assert sends == []
    releases.insert(0, {"tag_name": "1.4.0", "prerelease": True})
    jobs.new_release(state)
    jobs.new_release(state)  # nothing new: no repeat
    assert sends == [("גרסה 1.4.0 של האפליקציה", ["a"])]
    releases[0]["prerelease"] = False  # promoted: everyone hears about it
    jobs.new_release(state)
    assert sends[-1] == ("גרסה 1.4.0 של האפליקציה", ["a", "v"])
    # After the first answer every check is conditional: a 304 is free and changes nothing.
    assert asked[0] is None and set(asked[1:]) == {'"v1"'}
    Res.status_code = 304
    jobs.new_release(state)
    assert sends[-1] == ("גרסה 1.4.0 של האפליקציה", ["a", "v"]) and len(sends) == 2


def test_backup_takes_version_files_once_and_each_new_guest_list(monkeypatch, tmp_path):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    (tmp_path / "files" / "v1").mkdir(parents=True)
    (tmp_path / "files" / "v1" / "preview.png").write_bytes(b"png")
    guests = tmp_path / "guests" / "r1"
    guests.mkdir(parents=True)
    (guests / "guests.xlsx").write_bytes(b"xlsx")
    (tmp_path / "guests" / "r2").mkdir()  # empty: nothing to back up
    up = []
    monkeypatch.setattr(backup, "_folder", lambda s, name=None, parent=None: "f")
    monkeypatch.setattr(backup, "_upload", lambda s, folder, name, data, mime: up.append(name))
    assert backup.files(None, "root") == 2
    assert up[0] == "v1.zip" and up[1].startswith("guests-r1-")
    assert backup.files(None, "root") == 0  # nothing new
    os.utime(guests / "guests.xlsx", (2_000_000_000, 2_000_000_000))  # the client sent a new list
    assert backup.files(None, "root") == 1 and up[-1] == "guests-r1-2000000000.zip"


def test_backup_takes_each_gift_factory_zip_as_it_is(monkeypatch, tmp_path):
    monkeypatch.setenv("DATA_DIR", str(tmp_path))
    (tmp_path / "gf_backups").mkdir()
    z = tmp_path / "gf_backups" / "giftfactory-2026-11-17.zip"
    z.write_bytes(b"PK zip")
    up = []
    monkeypatch.setattr(backup, "_folder", lambda s, name=None, parent=None: "f")
    monkeypatch.setattr(backup, "_upload", lambda s, folder, name, data, mime: up.append((name, data)))
    assert backup.files(None, "root") == 1 and up[0][1] == b"PK zip" and up[0][0].startswith("giftfactory-2026-11-17-")
    assert backup.files(None, "root") == 0
    os.utime(z, (2_000_000_000, 2_000_000_000))  # sent again the same day
    assert backup.files(None, "root") == 1 and up[-1][0] == "giftfactory-2026-11-17-2000000000.zip"


def test_a_lone_flag_starts_3_days_before(monkeypatch):
    from datetime import date

    class Db:
        def collection(self, name):
            return self

        def stream(self):
            r = {"title": "דגל", "customerName": "נועה", "deadline": "2026-11-01", "status": "approved"}
            return [type("D", (), {"id": "soon", "to_dict": lambda _: r})()]

    monkeypatch.setattr(firebase, "db", lambda: Db())
    monkeypatch.setattr(jobs, "users", lambda: [("alex", {})])
    sends = []
    monkeypatch.setattr(jobs, "send_to", lambda people, kind, title, body, data: sends.append((title, body)))
    assert jobs.deadline_reminders(date(2026, 10, 29)) == 1
    assert sends == [("🖨️ להתחיל להדפיס: דגל", "תאריך היעד בעוד 3 ימים (01.11) · נשאר כיום הדפסה אחד · נועה")]


# The same cases as test/studio_test.dart's printSchedule.
SCHEDULE = {
    "gift": {"deadline": "2026-11-20", "status": "approved", "production": {"quote": {"printHours": 48}}},
    "flag": {"deadline": "2026-11-19", "status": "draft", "qty": 2, "estimate": {"printMinutes": 180}},
    "plain": {"deadline": "2026-11-25", "status": "waiting"},
    "done": {"deadline": "2026-11-21", "status": "ready"},
    "nodate": {"status": "approved"},
}


def test_print_hours_from_gift_factory_then_the_flag_maker_then_a_day():
    assert jobs.print_hours_left(SCHEDULE["gift"]) == 48
    assert jobs.print_hours_left(SCHEDULE["flag"]) == 6  # 180 minutes x 2
    assert jobs.print_hours_left(SCHEDULE["plain"]) == 24
    assert jobs.print_days_left(SCHEDULE["flag"]) == 1


def test_one_printer_schedule_backwards_from_the_deadlines():
    from datetime import datetime

    got = {rid: (a.isoformat(), b.isoformat()) for rid, (a, b) in jobs.print_schedule(SCHEDULE).items()}
    assert got == {
        "plain": ("2026-11-22T00:00:00", "2026-11-23T00:00:00"),
        "gift": ("2026-11-16T00:00:00", "2026-11-18T00:00:00"),
        "flag": ("2026-11-15T18:00:00", "2026-11-16T00:00:00"),  # ends where the gift run starts
    }
    assert isinstance(jobs.print_schedule(SCHEDULE)["gift"][0], datetime)


def test_portal_bill_links_keep_the_server_prefix():
    """Behind the Funnel the server lives under /print-studio; a bare /b/<token> link from the portal 404s."""
    import re
    from pathlib import Path
    html = (Path(__file__).parent / "app/static/portal.html").read_text(encoding="utf-8")
    pattern = re.search(r"const root = base\.replace\(/(.+?)/, ''\)", html).group(1)  # the portal's own JS regex
    assert re.sub(pattern, "", "/print-studio/p/" + "t" * 22) == "/print-studio"
    assert re.sub(pattern, "", "/p/" + "t" * 22) == ""
    assert "href: b.url" not in html and html.count("href: root + b.url") == 2
