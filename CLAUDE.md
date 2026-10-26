# print-studio: context

Alex's CRM for the 3D-printing studio (README › What it does). Built from the
`app-shell` starter (`make-an-app` skill): read that skill's
`references/checklist.md` and `references/lessons.md` before changing an area.
Improvements to `lib/core/` go back into the starter.

- `lib/core/` = the standard. `lib/studio/` = records, money, links (and
  `desktop.dart`, PC only). `lib/ui/` = screens: `home_screen` (tabs + ribbon),
  `requests_view`, `customers_view`, `ribbon`, `studio_actions`, `studio_dialogs`.
- Server: `server/app/studio.py` (versions, Flag Maker key, portal) and
  `server/app/static/portal.html`. Flag Maker side: `C:\claude projects\3d\app\crm_link.py`
  (follow that repo's AGENTS.md: its releases need its acceptance suite, including
  `app/tests/check_crm_link.py`, the contract with `studio.py`).
- Money is integer **agorot**; VAT 18% rounded half up, computed identically in
  `lib/studio/studio.dart` and `studio.py` (both have the same test cases).
- Keep green: `flutter analyze`, `flutter test`, `firestore-tests`, server
  pytest (`test_studio.py` needs the Firestore emulator; COMMANDS.md). CI runs all.

## Decided 25.10.2026 (don't re-ask)

Multiple customers, one permanent portal link each (token only; client Google
sign-in later). Request → versions; only Alex creates requests. Versions land
as drafts; Alex publishes. Comments: thread + pins on 2D/3D/assembled. Quote
(VAT 18% is a switch per quote, off by default, decided 26.10) + total, re-quote until accepted, one-step approval of design
+ price, then locked. Statuses טיוטה → ממתין לאישור → אושר → בהדפסה → מוכן →
נמסר → שולם. Alerts to Alex: FCM push only; the client is told by a WhatsApp
link Alex sends. Portal Hebrew + English toggle. Flag Maker ↔ CRM two-way, PC
only. Allowlist: alex99ka@gmail.com, alex98ka@gmail.com. Palette A (graphite +
blue, green only for the client's approve button), Heebo, Word-style top tabs
+ ribbon. Design: https://claude.ai/artifact/XGArLBxz3caJm9xYcBRFaf

Firebase packages stay on core 4 / auth 6 (the starter's pin).

Clients never get a printable file (26.10): the portal serves only watermarked
pictures (preview.png, spin.jpg, spin_asm.jpg = 36 turns on a 6x6 sheet); the
3MF/recipe go through the signed-in `/studio/versions/...` route. No meshes in the browser.
