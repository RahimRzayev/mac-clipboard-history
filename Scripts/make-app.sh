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
