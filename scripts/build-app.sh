#!/bin/zsh
# Builds FinderSpeed.app (menu bar app, no Dock icon) into ./build/. Owner: zeus.
# Usage: scripts/build-app.sh [debug|release] [--universal] [--zip]   (default: release, native arch)
#   --universal  build for Apple Silicon + Intel (arm64 + x86_64)
#   --zip        also create build/FinderSpeed-<version>.zip for a GitHub release
#   --dmg        also create build/FinderSpeed-<version>.dmg (drag-to-Applications installer)
set -euo pipefail
cd "${0:A:h}/.."
CONFIG=release; ARCHS=(); ZIP=0; DMG=0
for a in "$@"; do case $a in debug|release) CONFIG=$a;; --universal) ARCHS=(--arch arm64 --arch x86_64);; --zip) ZIP=1;; --dmg) DMG=1;; esac; done
VERSION=${FINDERSPEED_VERSION:-}; [[ -n "$VERSION" ]] || VERSION=$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//'); VERSION=${VERSION:-0.1.0}
swift build -c "$CONFIG" $ARCHS
BIN=$(swift build -c "$CONFIG" $ARCHS --show-bin-path)/FinderSpeed
APP=build/FinderSpeed.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FinderSpeed"
# App icon: compile the Icon Composer bundle (macOS 26+ style, no grey "legacy" frame) into Assets.car,
# which also emits AppIcon.icns for older macOS. Falls back to the prebuilt .icns without Xcode.
if xcrun --find actool >/dev/null 2>&1; then
  xcrun actool "$PWD/scripts/icon/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon AppIcon --output-partial-info-plist "$(mktemp -u).plist" >/dev/null
else
  cp scripts/icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.mauriziolol.finderspeed</string>
  <key>CFBundleName</key><string>FinderSpeed</string>
  <key>CFBundleDisplayName</key><string>FinderSpeed</string>
  <key>CFBundleExecutable</key><string>FinderSpeed</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>FinderSpeed asks Finder which folders are open so it can find where a copy is going.</string>
</dict></plist>
PLIST
# Stable designated requirement keeps the Accessibility grant across rebuilds, as long as the identifier stays the same.
codesign --force --sign - --identifier com.mauriziolol.finderspeed \
  -r='designated => identifier "com.mauriziolol.finderspeed"' "$APP"
echo "Built $PWD/$APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/FinderSpeed"))"
if (( ZIP )); then
  rm -f "build/FinderSpeed-$VERSION.zip"
  ditto -c -k --keepParent "$APP" "build/FinderSpeed-$VERSION.zip"
  echo "Zipped $PWD/build/FinderSpeed-$VERSION.zip"
fi
if (( DMG )); then scripts/dmg/make-dmg.sh "$APP" "$VERSION"; fi
