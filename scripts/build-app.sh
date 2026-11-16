#!/bin/bash
# Baut „ReeZ Wallpapers.app“ nach build/.
#   scripts/build-app.sh            nur bauen
#   scripts/build-app.sh --install  bauen, nach /Applications kopieren und (neu) starten
set -euo pipefail
cd "$(dirname "$0")/.."

NAME="ReeZ Wallpapers"
APP="build/$NAME.app"

# Apple Silicon und Intel in einer Datei
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/ReeZWallpapers"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ReeZWallpapers"
cp Resources/Info.plist "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# Ohne Entwicklerzertifikat: Ad-hoc-Signatur, reicht für den eigenen Mac
codesign --force --sign - "$APP"
echo "Gebaut: $APP"

if [ "${1:-}" = "--install" ]; then
  DEST="/Applications/$NAME.app"
  osascript -e "tell application id \"cc.reez.wallpapers\" to quit" >/dev/null 2>&1 || true
  pkill -x ReeZWallpapers >/dev/null 2>&1 || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "Installiert und gestartet: $DEST"
fi
