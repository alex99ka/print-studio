[![CI](https://github.com/alex99ka/print-studio/actions/workflows/ci.yml/badge.svg)](https://github.com/alex99ka/print-studio/actions/workflows/ci.yml)

# סטודיו הדפסה

The starter every new app is built from (the `make-an-app` skill). One Flutter
codebase for **Android, Web (installable, the iPad) and Windows**, with the core
already working: Google sign-in, fingerprint unlock, silent in-app updates from
GitHub Releases, a patient-zero rollout, minimum-version kill switch, push
notifications, Hebrew error codes, problem reports to Telegram, a diagnostics
screen, an interactive walkthrough with what's-new per release, home widgets,
data export, daily Drive backups, light and dark themes, RTL.

The example feature is one shared list (`items`). A new app replaces it.

## Start a new app from this

```sh
git clone https://github.com/alex99ka/print-studio <slug> && cd <slug>
rm -rf .git && git init
python tool/new_app.py --name "שם האפליקציה" --slug <slug> --id com.alex99ka.<id>
flutter pub get
```

Then the one-time setup below, in order. Everything is on free tiers.

1. **Firebase project** (Spark): `firebase.cmd projects:create <id>`. In the console:
   Authentication → Google on; Firestore (me-west1) with delete protection.
   Register a web app and an Android app; put both configs in
   `lib/firebase_options.dart` and the web one in `web/firebase-messaging-sw.js`.
2. **Allowlist**: create `config/access` = `{emails: [...], earlyUsers: [<you>]}`
   and `config/app` = `{minVersion: "0.0.0"}` in the console. Deploy the rules:
   `firebase.cmd deploy --only firestore:rules --project <id>`.
3. **Google sign-in clients** (Google Cloud console → APIs & Services →
   Credentials, same project): the *Web client* Firebase created (its id is
   `GOOGLE_WEB_CLIENT_ID`), and a new *Desktop app* client for Windows
   (`GOOGLE_DESKTOP_CLIENT_ID` / `_SECRET`). Add the release key's SHA-1 and
   SHA-256 to the Android app in Firebase.
4. **Release key**: `keytool -genkeypair -keystore ~/.keystores/<slug>.p12
   -storetype PKCS12 -alias <slug> -keyalg RSA -keysize 4096 -validity 10000`.
   **Back it up to Drive now.** `android/key.properties` (gitignored) points
   at it for local builds.
5. **GitHub** (public repo, so updates need no token): secrets
   `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`,
   `GOOGLE_DESKTOP_CLIENT_SECRET`, `FIREBASE_SERVICE_ACCOUNT` (a key with only
   *Firebase Hosting Admin*); variables `ANDROID_KEY_ALIAS`,
   `GOOGLE_WEB_CLIENT_ID`, `GOOGLE_DESKTOP_CLIENT_ID`, `FIREBASE_PROJECT`,
   `SERVER_URL` (empty without a server).
6. **The home server** (optional, `server/`): see below.
7. **First release**: CHANGELOG section, tag, push. Install the APK on your
   phone by hand once; from then on it updates itself.

## How it fits together

```
Android / Windows / Web ── Firebase Auth (Google) · Firestore (rules = backend) · FCM
        │  updates                                   ▲
        ▼                                            │ Admin SDK
GitHub Releases ◄── release.yml (tag)        Pi: server/ (Docker, Tailscale Funnel)
  prerelease → early users                     /health · /report → Telegram
  promote.yml → everyone + live web            pushes · daily Drive backup
```

- **Updates.** Android and Windows read GitHub's releases list, pick the newest
  build for their platform (prereleases only for `earlyUsers`), check its
  SHA-256 and download it in the background (Android: Wi-Fi only, with a
  progress notification). Android 12+ installs it 10 minutes after the app
  leaves the screen; Windows when the window closes. Play Protect still asks
  "Scan app" once per build: that's normal for sideloaded apps. The web
  checks `version.json` and offers a reload.
- **Kill switch.** Raise `config/app.minVersion` and every older build shows
  only "צריך לעדכן" and stops writing. Do it whenever a release changes the
  shape of synced data.
- **Patient zero.** A tag publishes a *prerelease* and deploys the web build to
  the Hosting channel `next`. When it's good on your phone:
  `gh workflow run promote.yml -f version=X.Y.Z`.
- **Errors** (`lib/core/errors.dart`): what failed, why, what to do, and a
  letter code. **Diagnostics** and **problem report** are in Settings.

## Cost

| Service | Free limit | What uses it |
|---|---|---|
| Firestore | 50k reads, 20k writes a day; 1 GiB | The apps; the server polls every minute (≥ 1,440 reads a day per poller), and every rules check reads `config/access` once per request. |
| Hosting | 10 GB stored, 360 MB a day | The web app, and the `next` channel (expires after 30 days). |
| Auth, FCM | Free | |
| GitHub Actions, Releases | Free for a public repo | CI, builds, downloads. |
| GitHub API | 60 unauthenticated calls an hour per IP | The update check: at start and at most every 6 hours. |
| Drive | The account's own space | One JSON a day, 30 kept. |
| Pi | Electricity | `server/`. |

## Security

- **Firestore rules** are the boundary; `firestore-tests/` checks every allow
  and deny in the emulator. The allowlist is `config/access.emails`, read by
  the rules, the app and the server alike.
- **Secrets are never in the repo**: keystores in `~/.keystores`, the server's
  key and `.env` on the Pi (mode 600). `.gitignore` blocks them as a backstop.
  The Firebase config files are public by design.
- **Service accounts** get one job each: the server's (*Cloud Datastore User* +
  *Firebase Cloud Messaging API Admin*), Hosting deploys (*Firebase Hosting
  Admin*). The Drive backup token has only `drive.file`.
- **Signing**: the keystore is decoded only on a runner that runs no project
  code, then deleted. A lost key means every user must uninstall to update.
- **Updates** install only if the SHA-256 matches the release and, on
  Android, the signature matches the installed app.

Known limits, accepted for a household app: anyone who can publish releases
on the GitHub repo can ship an update (keep 2FA on); an item's "added by" is
not enforced by the rules (undo restores others' items); the Windows installer
is unsigned, so SmartScreen warns on first install.

## Versioning

SemVer in `pubspec.yaml`; the tag must equal it. Bump in the commit that
ships. The Android versionCode is `MAJOR*1000000 + MINOR*1000 + PATCH`.
Settings and the sign-in screen show the version.

## Releasing

Move `[Unreleased]` in CHANGELOG.md under the new version (in Hebrew, for the
users: it becomes the release notes and the in-app what's-new), add walkthrough
steps tagged with the version for anything user-facing (`lib/core/tour.dart`),
bump `pubspec.yaml`, commit, then:

```sh
git tag X.Y.Z && git push --atomic origin main X.Y.Z
```

Rules changes are deployed **before** the tag.

## The home server (`server/`)

FastAPI in Docker on the Pi, published by Tailscale Funnel. On the Pi:

```sh
mkdir -p ~/docker/<slug>/data && cd ~/docker/<slug>
# from the PC: git archive HEAD:server | ssh pi5 "tar -x -C ~/docker/<slug>"
nano .env   # GOOGLE_CLOUD_PROJECT, GITHUB_REPO, APP_NAME, PORT, TELEGRAM_*, DRIVE_*
chmod 600 .env data/service-account.json
docker compose up -d --build
```

- Telegram: **every app uses the same shared bot**; don't make a new one.
  Copy `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` from another app's `.env` on
  the Pi. Each message starts with `APP_NAME`, which is how you tell apps
  apart. Servers only call `sendMessage`, never `getUpdates` or a webhook,
  because another service may be reading the bot's updates. Only the first
  time ever: create the bot with @BotFather, message it once, and read your chat
  id from `https://api.telegram.org/bot<token>/getUpdates`.
- Drive: `python server/tools/drive_token.py <desktop client id> <secret>` on
  the PC prints the three `DRIVE_*` lines.
- Add an Uptime Kuma HTTP monitor for `<SERVER_URL>/health`.

## Develop

```sh
flutter run -d windows        # or chrome, or a phone
flutter analyze && flutter test
cd firestore-tests && npm ci && npm test
cd server && python -m venv .venv && .venv/Scripts/pip install -r requirements-dev.txt && .venv/Scripts/pytest -q
```

Flutter is at `C:\src\flutter\bin` on this PC (not on PATH).
