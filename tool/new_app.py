"""Turns a copy of the starter into a new app, in place.

    python tool/new_app.py --name "ספר מתכונים" --slug recipe-book \
        --id com.alex99ka.recipebook [--repo alex99ka/recipe-book]

--name  the Hebrew app name (title bar, launcher, installer, notifications)
--slug  lower-case-with-dashes: repo name, file names, Dart package (dashes → _)
--id    the Android application id. Final once anything is installed: an
        update must keep it (and the signing key) or users reinstall.
--repo  owner/name on GitHub, where releases and so updates live
        (default alex99ka/<slug>)

New random ids for the Windows installer and notifications. Run from the
repo root of the copy, never in the starter itself.
"""

import argparse
import re
import shutil
import sys
import uuid
from pathlib import Path

OLD_NAME = "אפליקציית בסיס"
SKIP_DIRS = {".git", "build", ".dart_tool", "node_modules", ".venv", "dist", ".gradle", ".idea", "__pycache__", "ephemeral"}
TEXT = {".dart", ".kt", ".kts", ".xml", ".yaml", ".yml", ".json", ".md", ".py", ".mjs", ".iss", ".html", ".js",
        ".cmake", ".txt", ".rc", ".cpp", ".h", ".rules", ".gitignore"}


def escaped(text: str) -> str:
    """C++ wide literal: MSVC reads main.cpp without a BOM."""
    return "".join(c if ord(c) < 128 else "\\u%04x" % ord(c) for c in text)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--name", required=True)
    p.add_argument("--slug", required=True)
    p.add_argument("--id", required=True)
    p.add_argument("--repo")
    a = p.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")  # Windows consoles default to cp1252

    root = Path.cwd()
    if not (root / "tool" / "new_app.py").exists() or not (root / "pubspec.yaml").exists():
        sys.exit("Run from the root of the copied repo.")
    if not re.fullmatch(r"[a-z][a-z0-9]*(-[a-z0-9]+)*", a.slug):
        sys.exit("--slug: lower-case letters, digits and dashes")
    if not re.fullmatch(r"[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)+", a.id):
        sys.exit("--id: like com.alex99ka.recipebook")
    repo = a.repo or f"alex99ka/{a.slug}"
    dart = a.slug.replace("-", "_")
    camel = "".join(w.capitalize() for w in a.slug.split("-"))
    scheme = a.slug.replace("-", "")

    # Longest first, so a short key never eats part of a longer one.
    pairs = [
        ("com.alex99ka.app_shell", a.id),
        ("com.alex99ka.appshell", a.id),
        ("alex99ka/app-shell", repo),
        (escaped(OLD_NAME), escaped(a.name)),
        (OLD_NAME, a.name),
        ("appshell://", f"{scheme}://"),
        ("AppShell", camel),
        ("app-shell", a.slug),
        ("app_shell", dart),
        ("C64D2407-A1F7-47D3-BC7F-B53E4ADB513D", str(uuid.uuid4()).upper()),
        ("5f0c3b8e-3d55-4a7e-9a39-2a3c7f0e6b11", str(uuid.uuid4())),
    ]
    changed = 0
    for f in root.rglob("*"):
        if not f.is_file() or SKIP_DIRS & set(f.relative_to(root).parts):
            continue
        if f.suffix not in TEXT and f.name not in {".gitignore", "Dockerfile"}:
            continue
        if f.name in {"new_app.py", "pubspec.lock", "package-lock.json"}:
            continue
        raw = f.read_bytes()
        bom = raw.startswith(b"\xef\xbb\xbf")  # app.iss must keep its BOM
        text = raw.decode("utf-8-sig")
        new = text
        for old, rep in pairs:
            new = new.replace(old, rep)
        if new != text:
            f.write_bytes((b"\xef\xbb\xbf" if bom else b"") + new.encode())
            changed += 1

    kotlin = root / "android/app/src/main/kotlin"
    old_dir = kotlin / "com/alex99ka/app_shell"
    if old_dir.exists():
        new_dir = kotlin.joinpath(*a.id.split("."))
        new_dir.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(old_dir), str(new_dir))
        for empty in [old_dir.parent, old_dir.parent.parent]:
            if empty.exists() and not any(empty.iterdir()):
                empty.rmdir()

    print(f"Renamed in {changed} files: {a.name} · {a.id} · {repo}")
    print("Next: flutter pub get, then the checklist in README (Firebase project, keys, secrets).")


if __name__ == "__main__":
    main()
