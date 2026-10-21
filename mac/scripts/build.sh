#!/bin/bash
# Builds build/Isola.app (ad-hoc signed) and build/Isola.dmg. Usage: scripts/build.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
VERSION=${ISOLA_VERSION:-1.4.7}
BUILD=${ISOLA_BUILD:-151}
# Release builds are universal (Apple silicon + Intel); debug builds stay native.
ARCHS=(); [[ "$CONFIG" == release ]] && ARCHS=(--arch arm64 --arch x86_64)
# ${ARCHS[@]+...}: bash 3.2 treats an empty array as unbound under set -u.
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"}
BIN=$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)
APP=build/Isola.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Isola" "$APP/Contents/MacOS/Isola"
cp "$BIN/isolactl" build/isolactl
cp -R Resources/Sounds Resources/AppIcon.icns "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Media"
cp ../public/videos/earbuds.mp4 "$APP/Contents/Resources/Media/"
# Now Playing helper hosted by /usr/bin/perl (see Helpers/MediaRemoteHelper.m).
clang -dynamiclib -fobjc-arc -O2 -arch arm64 -arch x86_64 -mmacosx-version-min=15.0 -framework Foundation Helpers/MediaRemoteHelper.m -o "$APP/Contents/Resources/MediaRemoteHelper.dylib"
cp Helpers/mediaremote.pl "$APP/Contents/Resources/"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" Resources/Info.plist > "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
if [[ "${DMG:-1}" == 1 ]]; then
  STAGE=$(mktemp -d)
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  # Ad-hoc signed, not notarized: tell people how to get past Gatekeeper the first time.
  cat > "$STAGE/First launch.txt" <<'TXT'
Isola is signed ad hoc and not notarized by Apple, so macOS blocks the first launch.

1. Drag Isola into Applications and open it once.
2. Open System Settings > Privacy & Security, scroll down and click "Open Anyway" next to Isola.

Or, in Terminal: xattr -dr com.apple.quarantine /Applications/Isola.app
TXT
  rm -f build/Isola.dmg
  hdiutil create -quiet -volname Isola -srcfolder "$STAGE" -format UDZO build/Isola.dmg
fi
echo "built $APP ($VERSION/$BUILD)"
