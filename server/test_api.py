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


def test_release_announced_once_prereleases_to_early_users_only(monkeypatch):
    releases = [
        {"tag_name": "1.3.0", "prerelease": True},
        {"tag_name": "1.2.0", "prerelease": False},
    ]

    class Res:
        def raise_for_status(self):
            pass

        def json(self):
            return releases

    monkeypatch.setattr(jobs.requests, "get", lambda *a, **k: Res())
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
