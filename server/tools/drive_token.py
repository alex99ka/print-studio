"""Run once on the PC to let the server back up to your Google Drive:

    python server/tools/drive_token.py <client_id> <client_secret>

It opens Google's consent page in the browser (use a "Desktop app" OAuth
client of the app's Firebase project), then prints the three lines to put in
the Pi's .env. The scope is `drive.file`: the server can see and change only
the files it creates itself. Standard library only.
"""

import base64
import hashlib
import http.server
import json
import secrets
import sys
import urllib.parse
import urllib.request
import webbrowser

SCOPE = "https://www.googleapis.com/auth/drive.file"


def main(client_id: str, client_secret: str) -> None:
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_urlsafe(16)
    got: dict = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            got.update(urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query))
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write("אפשר לסגור את הלשונית ולחזור לטרמינל".encode())

        def log_message(self, *_):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    redirect = f"http://127.0.0.1:{server.server_port}"
    webbrowser.open(
        "https://accounts.google.com/o/oauth2/v2/auth?"
        + urllib.parse.urlencode(
            {
                "client_id": client_id,
                "redirect_uri": redirect,
                "response_type": "code",
                "scope": SCOPE,
                "access_type": "offline",
                "prompt": "consent",
                "code_challenge": challenge,
                "code_challenge_method": "S256",
                "state": state,
            }
        )
    )
    print("Waiting for the browser…")
    server.handle_request()
    if got.get("state", [""])[0] != state or "code" not in got:
        sys.exit(f"Not authorised: {got.get('error', ['no code'])[0]}")
    body = urllib.parse.urlencode(
        {
            "code": got["code"][0],
            "client_id": client_id,
            "client_secret": client_secret,
            "redirect_uri": redirect,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        }
    ).encode()
    tokens = json.load(urllib.request.urlopen("https://oauth2.googleapis.com/token", body, timeout=30))
    print("\nAdd to the Pi's .env (nano ~/docker/<app>/.env):\n")
    print(f"DRIVE_CLIENT_ID={client_id}")
    print(f"DRIVE_CLIENT_SECRET={client_secret}")
    print(f"DRIVE_REFRESH_TOKEN={tokens['refresh_token']}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
