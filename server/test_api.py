"""Run: .venv/Scripts/pytest -q (from server/). No network, no Firebase."""

import os

os.environ.setdefault("GOOGLE_CLOUD_PROJECT", "demo-print-studio")
os.environ.setdefault("GITHUB_REPO", "alex99ka/print-studio")
os.environ["RUN_JOBS"] = "0"

import pytest
from fastapi.testclient import TestClient

from app import firebase, jobs, main, telegram


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
    assert set(r.json()) == {"ok", "last_backup", "backup", "telegram"}
    assert r.headers["X-Content-Type-Options"] == "nosniff"


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
    monkeypatch.setattr(jobs, "send_to", lambda people, kind, title, body, data: sends.append((kind, title, body, data["id"])))
    assert jobs.deadline_reminders(date(2026, 10, 29)) == 5
    assert [s[3] for s in sends] == ["soon", "stand", "tomorrow", "today", "missed"]
    # A microphone flag prints in a day: 3 days before.
    assert sends[0] == ("deadlines", "🖨️ להתחיל להדפיס: דגל", "תאריך היעד בעוד 3 ימים (01.11) · נשאר כיום הדפסה אחד · נועה", "soon")
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
