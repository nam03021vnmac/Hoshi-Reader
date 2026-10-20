#!/usr/bin/env bash
#
#  make-dmg.sh
#  Hoshi Reader
#
#  Copyright © 2026 Manhhao.
#  SPDX-License-Identifier: GPL-3.0-or-later
#
#  Builds a Release copy of the Mac app, ad-hoc signs it with the sandbox entitlements and packs it
#  into a drag-to-install DMG.
#
#  Usage: Scripts/make-dmg.sh [out_dir]          (default: build)
#
#  Output:
#    <out>/Hoshi Reader <version>.dmg
#
#  The signature is ad-hoc, so the DMG is not notarized: on another Mac, open the app once, then
#  allow it under System Settings → Privacy & Security → Open Anyway.
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT="$(mkdir -p "${1:-$ROOT/build}" && cd "${1:-$ROOT/build}" && pwd)"

SCHEME="Hoshi Reader"
ENTITLEMENTS="$ROOT/App/macOS/HoshiReader-macOS.entitlements"
DERIVED="$OUT/DerivedData"
STAGING="$OUT/dmg"

echo "==> Building $SCHEME (Release)"
xcodebuild -project "$ROOT/Hoshi Reader.xcodeproj" -scheme "$SCHEME" -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO -quiet build

APP="$DERIVED/Build/Products/Release/$SCHEME.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="$OUT/$SCHEME $VERSION.dmg"

echo "==> Signing (ad-hoc, sandboxed)"
# Nested code gets a plain signature; only the app itself carries the entitlements.
for dir in Frameworks PlugIns; do
  [[ -d "$APP/Contents/$dir" ]] || continue
  find "$APP/Contents/$dir" -mindepth 1 -maxdepth 1 -print0 |
    while IFS= read -r -d '' item; do
      codesign --force --sign - "$item"
    done
done
codesign --force --sign - --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --deep --strict "$APP"

echo "==> Packing $DMG"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$SCHEME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo "==> Done: $DMG"
