# What's left

## עליך (Alex)

In order (README › Start a new app, steps 1–5). The code is ready and tested;
without these the app connects to nothing.

1. ✅ Firebase project `print-studio-1786a`, Google sign-in on. (Claude
   registered the Web and Android apps and filled the configs.)
2. ✅ Firestore `(default)` in `me-west1`.
3. ✅ (Claude created them 26.10.2026.) In Firestore:
   - `config/access` = `{emails: ["alex99ka@gmail.com", "alex98ka@gmail.com"], earlyUsers: ["alex99ka@gmail.com"]}`
   - `config/app` = `{minVersion: "0.0.0"}`

   Then (or tell Claude to): `firebase.cmd deploy --only firestore:rules`
4. **OAuth clients** (Google Cloud › APIs & Services › Credentials, project
   print-studio-1786a):
   - ✅ Web client ID: `256993487907-nfkq6n19l6e2brnqav8vtm8uc2c88s2v.apps.googleusercontent.com`
     (public; GitHub variable `GOOGLE_WEB_CLIENT_ID`). Rules deployed 26.10.2026.
   - Create a new client of type **Desktop app** for Windows. Its ID is public;
     its secret goes only into GitHub secrets (step 6), not to Claude.
5. **Signing key** (`keytool`, README step 4) in `~/.keystores/print-studio.p12`,
   **and back it up to Drive right away**.
6. **GitHub repo** `alex99ka/print-studio` (public) + the secrets and
   variables from README step 5.
7. ✅ **Pi**, live 26.10 (key + Funnel done by Alex; app runs with
   `--dart-define=SERVER_URL=https://pi5-home-server-ts.tail4f470e.ts.net:8443/print-studio`).
   Setup notes (Claude did: `~/docker/print-studio` with code, `.env` without
   secrets, image built; service account `print-studio-server` with Datastore
   User + FCM Admin). Address decided 26.10:
   `https://pi5-home-server-ts.tail4f470e.ts.net:8443/print-studio` (a path on
   virmeshulka's port; the Pi is moving to another server soon). Left for you,
   from Git Bash on the PC:
   - key straight onto the Pi: `gcloud iam service-accounts keys create - --iam-account=print-studio-server@print-studio-1786a.iam.gserviceaccount.com | ssh -i ~/.ssh/pi5 alex99ka@pi5-home-server "umask 077; cat > ~/docker/print-studio/data/service-account.json"`
   - publish: `ssh -i ~/.ssh/pi5 alex99ka@pi5-home-server "docker exec tailscale tailscale funnel --bg --https=8443 --set-path /print-studio http://127.0.0.1:8010"`
   - optional: Telegram lines (`TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID`) in its `.env`.
7a. **H1 backups** (Drive API enabled by Claude 26.10). Left for you:
   - Google Cloud › OAuth consent screen: publishing status **In production** (in
     Testing the Drive token dies after 7 days).
   - Git Bash, in `C:\claude projects\CRM`: `python server/tools/drive_token.py <desktop client id> <desktop client secret>`;
     it prints three `DRIVE_*` lines.
   - Paste them into the Pi's `~/docker/print-studio/.env`, then `docker compose up -d` there.
8. Once the server is up: CRM › Settings › "חיבור ה-Flag Maker", then paste the
   address and key in Flag Maker › Send to CRM.

## אצל Claude

1. ✅ Server, portal, rules, file backup, tests (server 15, rules 12).
2. ✅ App: palette A, tabs + ribbon, requests, customers, quotes, comments, PC
   (Bambu, Flag Maker). 20 tests. **Not yet seen on a screen**: needs
   Firestore + the web client ID (steps 2–4). Then: run on Windows and the
   phone, screenshots, fixes.
3. ✅ Firebase configs filled (`lib/firebase_options.dart`,
   `web/firebase-messaging-sw.js`, `.firebaserc`).
4. ✅ Flag Maker code (`3d/app/crm_link.py`, Send to CRM button,
   `--crm-version`). Tested end to end against a local server. **Not committed
   in the 3d repo and no 5.6.0 build**: after the server is live, run the Flag
   Maker acceptance suite and package.
5. ✅ Web live 26.10 at https://print-studio-1786a.web.app (manual
   `flutter build web` + `firebase deploy --only hosting`; CI takes over once
   the GitHub repo exists). Android next, when Alex is home (steps 5–6).
6. ✅ Release 0.1.0 (26.10): APK, Windows installer, web, all green in CI.
   Next: Alex installs the APK; then a 0.1.1 to verify the in-app update.
7. ✅ 26.10 security: the client's link serves only watermarked pictures;
   3D is 36 picture turns (Flag Maker `crm_link.spin`), never a mesh; 3MF via
   the signed-in route. Released 0.1.1 (lock + icon) and 0.1.2 (spin view).
8. ✅ 0.1.3: Alex's printer icon (cut out, `tool/make_icon.py`); the Pi's
   release check is conditional (ETag), so it no longer eats the home
   connection's 60 GitHub calls/hour (that caused the phone's update error).
   Same fix in app-shell `server/app/jobs.py` (uncommitted there).
9. ✅ Flag Maker 5.6.0 released 26.10 (Send to CRM, spin views; packaged, committed, pushed).
   CRM 0.1.4–0.1.6: in-app 3D, handled comments, every pin visible, delete request/customer.
10. After Firebase: icon, first release (tag) on the phone, a second release to
   check the in-app update, Uptime Kuma monitor for `/health`, privacy page.

11. ✅ 29.10 Gift Factory link C1–C6 built and tested (CRM 0.2.0, `server/GIFT_FACTORY.md`). Deployed 29.10:
   rules, server on the Pi, 0.2.0 prerelease (APK + Windows). Left: promote 0.2.0 once it's good on the
   phone; pair Gift Factory (הגדרות › חיבור Gift Factory) and run its `tests/check_crm_link.py`.

12. 29.10 CRM 0.3.0 built and tested: customer page (requests, paid, left), deadlines with print-time-aware
   reminders, notifications that close (X / swipe) and are seen once, Gift Factory spin 10 × 10. Deployed
   29.10 (rules, server, 0.3.0 pre-release). Next: Gift Factory sets `proof.SPIN_GRID = 10`, `SPIN_TILE = 400`.

13. 30.10 C2b built and tested (CRM 0.3.1): `GET /gf/info`, `views` on Gift Factory versions (plate tabs,
   all-round sheet cols × rows), portal tabs and up/down dragging (`server/GIFT_FACTORY.md` › Views). Next:
   deploy the server, then Gift Factory 0.4.2 can send proofs.

## For Gift Factory (differences from the handoff's Contract v1, all compatible)

See `server/GIFT_FACTORY.md` › As built. In short: PUT bodies are checked strictly (422 off contract;
`finishDate: null` is fine); `production.updatedAt` is set, not the request's `updatedAt`; timestamps end
`+00:00`, not `Z`; the portal refuses a guest file with a bad amount (Gift Factory skips that row); a request
shows on the portal (and takes a guest list) only after a version is published.

## After the MVP (not built, to decide)

- Image attachment on a portal comment (the design had a button; not built).
- Client sign-in with Google (instead of link only).
- Search in the request list; reopening an approved request.
