#!/bin/zsh
# BUG-001: run the app with simulated slow/failing AX (FINDERSPEED_SIMULATE_AX) during the slow
# small-files copy (to the volume root, which the Engine always watches), sample our windows' alpha every 100 ms for SECS seconds, screenshot every 2 s.
# Usage: spikes/window/bug001/simulate.sh <out_dir> "<delay=..,fail=..>" [secs] [--sampled]
set -uo pipefail
zmodload zsh/datetime
setopt null_glob
cd "${0:A:h}/../../.."
OUT=${1:?out}; SIM=${2:?sim spec}; SECS=${3:-60}; SAMPLED=0; [[ "${4:-}" == --sampled ]] && SAMPLED=1
BIN=.build/release/FinderSpeed
mkdir -p "$OUT"; rm -f "$OUT"/*.png "$OUT"/samples.jsonl
pkill -x FinderSpeed; sleep 0.5
LOG=$HOME/Library/Logs/FinderSpeed.log; : > "$LOG"
if (( SAMPLED )); then FINDERSPEED_SIMULATE_AX="$SIM" FINDERSPEED_DEBUG_WINDOW=1 "$BIN" >/dev/null 2>&1 &
else FINDERSPEED_SIMULATE_AX="$SIM" FINDERSPEED_NO_SAMPLE=1 FINDERSPEED_DEBUG_WINDOW=1 "$BIN" >/dev/null 2>&1 & fi
APP=$!; sleep 1.5
rm -rf /Volumes/FinderSpeedTest/apollo-small
osascript -e 'tell application "Finder" to duplicate (POSIX file "'$PWD'/testdata/apollo-small" as alias) to (POSIX file "/Volumes/FinderSpeedTest" as alias) with replacing' >/dev/null 2>&1 &
COPY=$!; T0=$EPOCHREALTIME
( while (( EPOCHREALTIME - T0 < SECS )); do
    print -n "{\"t\": $(( EPOCHREALTIME - T0 )), \"w\": ["; scripts/tools/winlist | tr '\n' ',' | sed 's/,$//'; print "]}"
    perl -e 'select(undef,undef,undef,0.1)'
  done ) > "$OUT/samples.jsonl" &
SAMP=$!
n=0; while (( EPOCHREALTIME - T0 < SECS )); do sleep 2; n=$((n+1)); screencapture -x -R0,240,980,520 "$OUT/shot-$(printf %02d $n).png"; done
wait $SAMP; kill $APP 2>/dev/null; cp "$LOG" "$OUT/FinderSpeed.log"
wait $COPY 2>/dev/null; rm -rf /Volumes/FinderSpeedTest/apollo-small
python3 -I - "$OUT" <<'EOF'
import json, sys
D = sys.argv[1]
rows = [json.loads(l) for l in open(D + '/samples.jsonl') if l.strip()]
vis = [r for r in rows if any(w['owner'] == 'FinderSpeed' for w in r['w'])]
partial = [r for r in rows if any(w['owner'] == 'FinderSpeed' and 0.02 < w['alpha'] < 0.98 for w in r['w'])]
first = vis[0]['t'] if vis else None
after = [r for r in rows if first is not None and r['t'] >= first]
gaps = 0; prev = True
for r in after:
    cur = any(w['owner'] == 'FinderSpeed' and w['alpha'] > 0.98 for w in r['w'])
    if prev and not cur: gaps += 1
    prev = cur
alphas = sorted({round(w['alpha'], 2) for r in rows for w in r['w'] if w['owner'] == 'FinderSpeed'})
log = open(D + '/FinderSpeed.log').read()
print(f"samples {len(rows)}; panel first visible at {first if first is None else round(first, 1)} s; "
      f"samples with partial alpha (0.02-0.98): {len(partial)} of {len(after)}; times it dropped from fully visible: {gaps}")
print(f"alpha values seen: {alphas}")
print(f"log: show {log.count('] show:')}, hide {log.count('] hide:')}, readInfo failed {log.count('readInfo failed')}, "
      f"disappeared {log.count('event disappeared')}, activationChanged {log.count('event activationChanged')}, "
      f"simulated AX failures {log.count('(simulated)')}")
EOF
