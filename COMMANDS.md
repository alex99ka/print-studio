# Commands

Run from the repo root unless noted. Flutter: `/c/src/flutter/bin/flutter` (not on PATH).

| Command | What it does |
|---|---|
| `flutter run -d windows` | Runs the app with hot reload (`r`, `R`, `q`). |
| `flutter analyze && flutter test` | Static checks and the unit tests. Must be clean. |
| `cd firestore-tests && npm test` | Every allow/deny of the rules, in the emulator. On Windows, kill the java process left on :8080 afterwards. |
| `cd server && .venv/Scripts/pytest -q` | Server tests without Firestore (the studio tests skip). |
| `cd server && npx -y firebase-tools@15.15.0 emulators:exec --only firestore --project demo-print-studio --config ../firebase.json ".venv\Scripts\pytest.exe -q"` | All server tests, studio included, against the emulator. Kill the java on :8080 afterwards. |
| `git archive HEAD:server \| ssh -i ~/.ssh/pi5 alex99ka@pi5-home-server "tar -x -C ~/docker/print-studio"` then on the Pi `docker compose up -d --build` | Deploys the server (README › The home server). |
| `firebase.cmd deploy --only firestore:rules --project <id>` | Deploys the rules. Before the release that needs them. |
| `git tag X.Y.Z && git push --atomic origin main X.Y.Z` | Releases: the latest release and the live web, straight away. |
| `MSYS_NO_PATHCONV=1 iscc /Q /DAppVersion=X.Y.Z installer/app.iss` | Builds the Windows installer locally (Git Bash mangles `/Q` without the prefix). |

## Don't

| | Why |
|---|---|
| Change `applicationId`, the signing key or the installer `AppId` after a release | Installed apps can no longer update; users reinstall and lose local data. |
| Edit `installer/app.iss` with a tool that drops the BOM | Inno Setup then garbles the Hebrew. |
| Add a field to a synced collection without its rule | `hasOnly()` rejects every write. |
