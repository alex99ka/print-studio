# print-studio: context

This is the **starter** for every new app (the `make-an-app` skill in
`~/.claude/skills/make-an-app` points here). A change here changes every
future app, so keep it generic: no app-specific features, only the core in the
skill's `references/checklist.md`. Read that checklist and
`references/lessons.md` before changing an area.

- `lib/config.dart` is the only per-app file in `lib/`; `tool/new_app.py`
  renames everything else. If you add a file that names the app, add it to the
  script's replacements and re-test the script on a copy.
- `lib/core/` = the standard (auth, lock, update, errors, tour, notifications,
  diagnostics, report, export, home widgets). `lib/ui/` = screens.
  The example feature is `items`.
- Keep green: `flutter analyze`, `flutter test`, `firestore-tests`, `server`
  pytest. CI runs all four.
- Decisions already made (2026-10-15, don't re-ask): Flutter; Firebase Spark +
  Pi when needed; Android + Web + Windows; Hebrew RTL, light + dark; Google
  sign-in + opt-in fingerprint; silent updates from GitHub Releases;
  tag-triggered releases; prerelease → promote (patient zero).
- Firebase packages are pinned to firebase_core 4 / auth 6 (proven in other
  apps). Moving to core 5 / auth 7 is a planned upgrade: it also clears the
  Kotlin Gradle Plugin warning.
