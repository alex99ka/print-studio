# Commands

Run from the repo root unless noted. Flutter: `/c/src/flutter/bin/flutter` (not on PATH).

| Command | What it does |
|---|---|
| `python tool/new_app.py --name … --slug … --id …` | Turns a copy of the starter into a new app. |
| `flutter run -d windows` | Runs the app with hot reload (`r`, `R`, `q`). |
| `flutter analyze && flutter test` | Static checks and the unit tests. Must be clean. |
| `cd firestore-tests && npm test` | Every allow/deny of the rules, in the emulator. On Windows, kill the java process left on :8080 afterwards. |
| `cd server && .venv/Scripts/pytest -q` | Server tests (no network). |
| `firebase.cmd deploy --only firestore:rules --project <id>` | Deploys the rules. Before the release that needs them. |
| `git tag X.Y.Z && git push --atomic origin main X.Y.Z` | Releases (prerelease for early users). |
| `gh workflow run promote.yml -f version=X.Y.Z` | Makes a release everyone's, web included. |
| `MSYS_NO_PATHCONV=1 iscc /Q /DAppVersion=X.Y.Z installer/app.iss` | Builds the Windows installer locally (Git Bash mangles `/Q` without the prefix). |

## Don't

| | Why |
|---|---|
| Change `applicationId`, the signing key or the installer `AppId` after a release | Installed apps can no longer update; users reinstall and lose local data. |
| Edit `installer/app.iss` with a tool that drops the BOM | Inno Setup then garbles the Hebrew. |
| Add a field to a synced collection without its rule | `hasOnly()` rejects every write. |
