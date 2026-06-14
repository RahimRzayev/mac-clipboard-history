#!/bin/bash
# Builds ClipboardHistory.app and packages it into a distributable .dmg using only
# built-in macOS tools (hdiutil) — no Homebrew/create-dmg dependency.
#
# WHY THIS DOESN'T JUST CALL make-app.sh:
# When the repo lives in an iCloud-synced folder (e.g. ~/Desktop with "Desktop & Documents"
# sync on), the file provider continuously re-stamps com.apple.FinderInfo onto the bundle.
# codesign then refuses to sign ("resource fork, Finder information, or similar detritus not
# allowed") because the attrs reappear faster than `xattr -cr` strips them. So we assemble,
# strip, and sign the bundle in a temp dir OUTSIDE the synced tree, freeze it into the
# read-only DMG there, and copy only the finished .dmg back into build/.
#
# NOTE: The bundled app is ad-hoc signed, NOT notarized. On another Mac, Gatekeeper rejects
# it ("cannot check it for malicious software"); the user must right-click -> Open once, or:
#   xattr -dr com.apple.quarantine /Applications/ClipboardHistory.app
# A warning-free download requires a paid Apple Developer ID cert + notarization.
#
# Usage: Scripts/make-dmg.sh [debug|release]   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
VOLNAME="Clipboard History"
DMG="build/ClipboardHistory.dmg"
BIN=".build/$CONFIG/ClipboardHistory"

# 1. Compile.
swift build -c "$CONFIG"

# 2. Assemble the .app in a temp dir outside the synced tree (mktemp -> /var/folders, which
#    no file provider touches). ditto --noextattr copies each file attribute-free.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
APP="$TMP/ClipboardHistory.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

ditto --noextattr --noqtn "$BIN" "$APP/Contents/MacOS/ClipboardHistory"
ditto --noextattr --noqtn Scripts/Info.plist "$APP/Contents/Info.plist"

# App icon: build AppIcon.icns from the 1024px master via sips/iconutil.
if [ -f Resources/AppIcon.png ]; then
  ICONSET="$TMP/AppIcon.iconset"; mkdir -p "$ICONSET"
  for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" "128:128x128" \
              "256:128x128@2x" "256:256x256" "512:256x256@2x" "512:512x512" "1024:512x512@2x"; do
    px="${spec%%:*}"; name="${spec##*:}"
    sips -z "$px" "$px" Resources/AppIcon.png --out "$ICONSET/icon_${name}.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

# SwiftPM resource bundles (KeyboardShortcuts localizations), attribute-free.
# -H: .build/$CONFIG is a symlink to .build/<arch>/<config>; follow it.
for b in $(find -H ".build/$CONFIG" -maxdepth 1 -name '*.bundle'); do
  ditto --noextattr --noqtn "$b" "$APP/Contents/Resources/$(basename "$b")"
done

# 3. Strip residual attrs (writable first so read-only bundle files don't error) and ad-hoc
#    sign. Inside $TMP nothing re-stamps the attrs, so codesign succeeds and strict-verifies.
chmod -R u+w "$APP"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

# 4. Stage (app + drag-to-Applications shortcut) and build a compressed read-only DMG.
STAGE="$TMP/stage"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/ClipboardHistory.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDZO "$TMP/dmg.dmg" >/dev/null

# 5. Copy only the finished DMG back into build/ (the app inside is already frozen + signed).
mkdir -p build
cp "$TMP/dmg.dmg" "$DMG"

echo "Built $DMG"
echo "Share it, or test locally with: open \"$DMG\""
