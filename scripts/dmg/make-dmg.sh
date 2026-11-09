#!/bin/zsh
# Builds build/FinderSpeed-<version>.dmg with the classic drag-to-Applications window. Owner: zeus.
# Usage: scripts/dmg/make-dmg.sh <path/to/FinderSpeed.app> <version>
# Needs Finder automation (it lays out the window via AppleScript).
set -euo pipefail
APP=${1:?app path}; VERSION=${2:?version}
cd "${0:A:h}/../.."
VOL="FinderSpeed"; OUT="build/FinderSpeed-$VERSION.dmg"
STAGE=$(mktemp -d); RW=$(mktemp -u).dmg
ditto "$APP" "$STAGE/FinderSpeed.app"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"; cp scripts/dmg/background.tiff "$STAGE/.background/background.tiff"
# Detach a leftover volume with the same name so ours mounts at /Volumes/FinderSpeed.
[[ -d "/Volumes/$VOL" ]] && hdiutil detach "/Volumes/$VOL" -quiet || true
hdiutil create -quiet -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk '/Apple_HFS/ {print $1}')
sleep 1
osascript <<APPLESCRIPT
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 800, 500}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 128
    set text size of opts to 13
    set background picture of opts to file ".background:background.tiff"
    set extension hidden of item "FinderSpeed.app" of container window to true
    set position of item "FinderSpeed.app" of container window to {160, 190}
    set position of item "Applications" of container window to {440, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
APPLESCRIPT
sync
hdiutil detach "$DEV" -quiet
rm -f "$OUT"
hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT"
rm -rf "$STAGE" "$RW"
echo "DMG $PWD/$OUT"
