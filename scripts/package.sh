#!/bin/bash
# Packt die App als ZIP für den Download auf wallpapers.reez.cc und gibt die Angaben für die Seite aus.
#   scripts/package.sh [zielordner]    Standard: build/
# Die Seite erwartet die Datei unter public/downloads/ReeZ-Wallpapers-mac.zip und die Angaben in src/lib/mac-app.json
# (Repository der Seite). Die Versionsnummer steht in Resources/Info.plist; die laufenden Apps vergleichen sie mit
# /mac/version.json der Seite und zeigen im Menü einen Update-Hinweis.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh >/dev/null
APP="build/ReeZ Wallpapers.app"
OUT="${1:-build}/ReeZ-Wallpapers-mac.zip"
rm -f "$OUT"
# Ohne erweiterte Attribute packen (sonst landet zu jeder Datei ein ._-Begleiter im ZIP); die Signatur steckt
# in der App selbst und bleibt gültig
xattr -cr "$APP"
ditto -c -k --norsrc --keepParent "$APP" "$OUT"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
MINOS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")
cat <<JSON
{
  "version": "$VERSION",
  "file": "ReeZ-Wallpapers-mac.zip",
  "size": $(stat -f %z "$OUT"),
  "sha256": "$(shasum -a 256 "$OUT" | cut -d' ' -f1)",
  "minOS": "$MINOS",
  "released": "$(date +%Y-%m-%d)"
}
JSON
