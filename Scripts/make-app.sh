#!/bin/bash
# Assembles ClipboardHistory.app from the SwiftPM build product.
# Usage: Scripts/make-app.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
APP="build/ClipboardHistory.app"
BIN=".build/$CONFIG/ClipboardHistory"

swift build -c "$CONFIG"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ClipboardHistory"
cp Scripts/Info.plist "$APP/Contents/Info.plist"

# App icon: generate AppIcon.icns from the 1024px master (Resources/AppIcon.png) using the
# system sips/iconutil. Keeping only the PNG in the repo makes the icon set reproducible.
if [ -f Resources/AppIcon.png ]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
  for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" "128:128x128" \
              "256:128x128@2x" "256:256x256" "512:256x256@2x" "512:512x512" "1024:512x512@2x"; do
    px="${spec%%:*}"; name="${spec##*:}"
    sips -z "$px" "$px" Resources/AppIcon.png --out "$ICONSET/icon_${name}.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$(dirname "$ICONSET")"
fi

# SwiftPM resource bundles (KeyboardShortcuts localizations) must live in Contents/Resources.
# -H: .build/$CONFIG is a symlink to .build/<arch>/<config>; follow it.
find -H ".build/$CONFIG" -maxdepth 1 -name '*.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;

# Strip extended attributes (Finder info / provenance) — codesign rejects them as detritus.
# Copied SwiftPM resources are read-only; make them writable first so xattr can strip.
chmod -R u+w "$APP"
xattr -cr "$APP"

# Ad-hoc signature for local use. For distribution, re-sign with a Developer ID
# certificate and notarize (spec §2.1).
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP"
echo "Run with: open \"$APP\""
