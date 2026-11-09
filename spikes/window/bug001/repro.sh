#!/bin/zsh
# BUG-001 reproduction under the user's conditions (apollo).
# Usage: spikes/window/bug001/repro.sh <out_dir> [app binary] [--sampled]
#  * our app (default: release build) in fallback mode (FINDERSPEED_NO_SAMPLE=1) unless --sampled,
#    with FINDERSPEED_DEBUG_WINDOW=1 (log: ~/Library/Logs/FinderSpeed.log, copied to <out_dir>)
#  * a slow copy: 40,000 small files (testdata/apollo-small) to /Volumes/FinderSpeedTest/apollo
#  * a Finder browser window partly under the copy window
#  * Finder's active state toggled via a window-less helper app (no clicks)
#  * our windows' CGWindowList alpha/frames sampled every 100 ms (samples.jsonl), screenshots every 3 s
# Restores: the frontmost app, the user's installed FinderSpeed.app, deletes the copy, closes the
# browser window it opened.
set -uo pipefail
zmodload zsh/datetime
setopt null_glob
cd "${0:A:h}/../../.."
OUT=${1:?out dir}; BIN=${2:-.build/release/FinderSpeed}; SAMPLED=0
[[ "${3:-}" == --sampled || "${2:-}" == --sampled ]] && SAMPLED=1
[[ "$BIN" == --sampled ]] && BIN=.build/release/FinderSpeed
mkdir -p "$OUT"; rm -f "$OUT"/*.png "$OUT"/samples.jsonl
TOOLS=scripts/tools; ACT=spikes/window/phase3/activator
FRONT=$(osascript -e 'tell application "System Events" to get name of first process whose frontmost is true')
INSTALLED=$(pgrep -f /Applications/FinderSpeed.app/Contents/MacOS/FinderSpeed)
[[ -n "$INSTALLED" ]] && kill $INSTALLED
pkill -x FinderSpeed; sleep 0.5
LOG=$HOME/Library/Logs/FinderSpeed.log; : > "$LOG"
if (( SAMPLED )); then FINDERSPEED_DEBUG_WINDOW=1 "$BIN" > /dev/null 2>&1 &
else FINDERSPEED_NO_SAMPLE=1 FINDERSPEED_DEBUG_WINDOW=1 "$BIN" > /dev/null 2>&1 & fi
APP=$!
sleep 1.5
# Browser window partly under the copy window (which appears at about CG 74,319 404x88).
osascript -e 'tell application "Finder"
  set w to make new Finder window to (POSIX file "/Volumes/FinderSpeedTest" as alias)
  set bounds of w to {300, 330, 900, 700}
end tell' >/dev/null
rm -rf /Volumes/FinderSpeedTest/apollo/apollo-small
T0=$EPOCHREALTIME
osascript -e 'tell application "Finder" to duplicate (POSIX file "'$PWD'/testdata/apollo-small" as alias) to (POSIX file "/Volumes/FinderSpeedTest/apollo" as alias) with replacing' >/dev/null 2>&1 &
COPY=$!
zmodload zsh/datetime
( while kill -0 $COPY 2>/dev/null; do
    print -n "{\"t\": $(( EPOCHREALTIME - T0 )), \"w\": ["; $TOOLS/winlist | tr '\n' ',' | sed 's/,$//'; print "]}"
    perl -e 'select(undef,undef,undef,0.1)'
  done ) > "$OUT/samples.jsonl" &
SAMP=$!
toggle_inactive() { $ACT 3 & local p=$!; perl -e 'select(undef,undef,undef,0.3)'
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $p) to true" >/dev/null; }
toggle_finder() { osascript -e 'tell application "System Events" to set frontmost of process "Finder" to true' >/dev/null; }
n=0
for step in $(seq 1 30); do
  kill -0 $COPY 2>/dev/null || break
  sleep 1.5
  case $(( step % 4 )) in 1) toggle_inactive ;; 3) toggle_finder ;; esac
  sleep 1.5
  n=$((n + 1)); screencapture -x -R0,240,980,520 "$OUT/shot-$(printf %02d $n).png"
done
wait $COPY 2>/dev/null; sleep 1; kill $SAMP 2>/dev/null
print "copy took $(( EPOCHREALTIME - T0 )) s"
# Restore.
osascript -e 'tell application "Finder"
  repeat with w in (get every Finder window)
    try
      if name of w is "FinderSpeedTest" then close w
    end try
  end repeat
end tell' >/dev/null 2>&1
rm -rf /Volumes/FinderSpeedTest/apollo/apollo-small
kill $APP 2>/dev/null
cp "$LOG" "$OUT/FinderSpeed.log"
[[ -n "$INSTALLED" ]] && open -g -a /Applications/FinderSpeed.app
[[ -n "$FRONT" ]] && osascript -e "tell application \"System Events\" to set frontmost of process \"$FRONT\" to true" >/dev/null 2>&1
print "restored frontmost: $FRONT; installed app relaunched: $([[ -n $INSTALLED ]] && echo yes || echo no)"
