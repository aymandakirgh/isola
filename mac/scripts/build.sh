#!/bin/bash
# Builds build/Isola.app (ad-hoc signed) and build/Isola.dmg. Usage: scripts/build.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
VERSION=${ISOLA_VERSION:-1.4.7}
BUILD=${ISOLA_BUILD:-151}
swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)
APP=build/Isola.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Isola" "$APP/Contents/MacOS/Isola"
cp "$BIN/isolactl" build/isolactl
cp -R Resources/Sounds Resources/AppIcon.icns "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
if [[ "${DMG:-1}" == 1 ]]; then
  STAGE=$(mktemp -d)
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f build/Isola.dmg
  hdiutil create -quiet -volname Isola -srcfolder "$STAGE" -format UDZO build/Isola.dmg
fi
echo "built $APP ($VERSION/$BUILD)"
