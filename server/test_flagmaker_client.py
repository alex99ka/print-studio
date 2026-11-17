"""C-4: the Flag Maker's own client (its app/crm_link.py, unchanged) against this server over real HTTP,
so a CRM change that would break "Send to CRM" fails here. Needs the Firestore emulator and the Flag Maker
code: FLAG_MAKER_APP = its app/ folder (CI checks the repo out). Skipped without them.
Run from server/: FLAG_MAKER_APP="../../Flag Maker/app" pytest -q test_flagmaker_client.py"""

import importlib.util
import json
import os
import socket
import threading
import time

import pytest
import uvicorn

from app import main
from test_studio import PNG, SPIN, client, db, three_mf  # noqa: F401 (fixtures)

APP = os.environ.get("FLAG_MAKER_APP", "")


def crm_link():
    path = os.path.join(APP, "crm_link.py")
    if not APP or not os.path.isfile(path) or not importlib.util.find_spec("numpy"):
        pytest.skip("needs FLAG_MAKER_APP (the Flag Maker's app/ folder) and numpy")
    spec = importlib.util.spec_from_file_location("crm_link", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


@pytest.fixture
def live(client):
    """This app on a real port (the signed-in override of the client fixture applies here too)."""
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    server = uvicorn.Server(uvicorn.Config(main.app, host="127.0.0.1", port=port, log_level="warning"))
    threading.Thread(target=server.run, daemon=True).start()
    while not server.started:
        time.sleep(0.05)
    yield f"http://127.0.0.1:{port}"
    server.should_exit = True


def test_send_to_crm_and_open_in_flag_maker(client, live, tmp_path):
    link = crm_link()
    cfg = {"url": live, "key": client.post("/studio/flagmaker-key").json()["key"]}
    assert [r["id"] for r in link.open_requests(cfg)] == ["r1"]
    files = {"preview": ("p.png", PNG), "model": ("m.3mf", three_mf()), "spin": ("spin.jpg", SPIN),
             "recipe": ("recipe.json", json.dumps({"first": "אלכס"}).encode())}
    for name, data in files.values():
        (tmp_path / name).write_bytes(data)
    got = link.send(cfg, "r1", {field: tmp_path / name for field, (name, _) in files.items()}, "from the Flag Maker")
    assert got["n"] == 1
    assert link.recipe(cfg, got["id"]) == {"first": "אלכס"}
    with pytest.raises(link.CrmError, match="did not accept the key"):
        link.open_requests({**cfg, "key": "wrong"})
