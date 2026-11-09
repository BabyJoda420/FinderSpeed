#!/bin/zsh
# Phase 3 seam check (apollo). Starts a real Finder copy, waits for Finder's progress window and our
# panel, captures the region, then captures the same region again after both are gone (clean
# wallpaper), and runs seam_check.py on the pair.
# Usage: spikes/window/phase3/seam_check.sh <out_dir> [--inactive] [--expand] [--two]
#   --inactive  a window-less helper app takes activation during the copy (Finder's window turns inactive)
#   --expand    clicks the panel's chevron (expanded graph) before capturing
#   --two       two concurrent copies (capture-a, capture-b; 1 s apart): Finder's window has 2 rows
set -uo pipefail
cd "${0:A:h}/../../.."
OUT=${1:?out dir}; shift
INACTIVE=0; EXPAND=0
TWO=0; MINH=0
for a in "$@"; do [[ $a == --inactive ]] && INACTIVE=1; [[ $a == --expand ]] && EXPAND=1; [[ $a == --two ]] && TWO=1 && MINH=140; done
mkdir -p "$OUT"
TOOLS=scripts/tools
if (( TWO )); then
  # Two concurrent copies to different folders, 1 s apart: Finder's window gets 2 rows (149 pt).
  scripts/finder-copy-test.sh -m folder -n 8 -s 1024 --max-total-gb 18 -d capture-a -b >/dev/null 2>&1
  perl -e 'select(undef,undef,undef,1.0)'
  scripts/finder-copy-test.sh -m folder -n 8 -s 1024 --max-total-gb 18 -d capture-b -b >/dev/null 2>&1
else
  scripts/finder-copy-test.sh -m folder -n 8 -s 1024 --max-total-gb 18 -d capture -b >/dev/null 2>&1
fi
for i in $(seq 1 200); do
  J=$($TOOLS/winlist | python3 -I -c 'import sys,json
ws=[json.loads(l) for l in sys.stdin if l.strip()]
f=[w for w in ws if w["owner"]=="Finder" and 380<=w["w"]<=440 and int(sys.argv[1])<=w["h"]<400]
p=[w for w in ws if w["owner"]=="FinderSpeed" and w["alpha"]>0.99]
if f and len(p)>=2: print(json.dumps({"finder":f[0],"panel":p}))' $MINH)
  [[ -n "$J" ]] && break
  perl -e 'select(undef,undef,undef,0.1)'
done
[[ -z "$J" ]] && { echo "windows not found"; exit 1; }
if (( INACTIVE )); then
  spikes/window/phase3/activator 8 &
  APID=$!
  perl -e 'select(undef,undef,undef,0.4)'
  osascript -e "tell application \"System Events\" to set frontmost of (first process whose unix id is $APID) to true" >/dev/null
  perl -e 'select(undef,undef,undef,1.2)'
  osascript -e 'tell application "System Events" to get name of first process whose frontmost is true'

  J=$($TOOLS/winlist | python3 -I -c 'import sys,json
ws=[json.loads(l) for l in sys.stdin if l.strip()]
f=[w for w in ws if w["owner"]=="Finder" and 380<=w["w"]<=440 and w["h"]<400]
p=[w for w in ws if w["owner"]=="FinderSpeed" and w["alpha"]>0.99]
print(json.dumps({"finder":f[0],"panel":p}))')
fi
if (( EXPAND )); then
  # Click our chevron: control column x = 385, first line of the panel (~20 px below Finder's bottom).
  P=$(echo "$J" | python3 -I -c 'import sys,json; f=json.load(sys.stdin)["finder"]; print(int(f["x"]) + 385, int(f["y"] + f["h"]) + 20)')
  spikes/window/phase3/click ${=P}
  perl -e 'select(undef,undef,undef,0.9)'
  J=$($TOOLS/winlist | python3 -I -c 'import sys,json
ws=[json.loads(l) for l in sys.stdin if l.strip()]
f=[w for w in ws if w["owner"]=="Finder" and 380<=w["w"]<=440 and w["h"]<400]
p=[w for w in ws if w["owner"]=="FinderSpeed" and w["alpha"]>0.99]
print(json.dumps({"finder":f[0],"panel":p}))')
fi
# Wait until Finder's window and our panel keep the same frames for 1.5 s (content transitions).
PREV=""; STABLE=0
for i in $(seq 1 80); do
  J=$($TOOLS/winlist | python3 -I -c 'import sys,json
ws=[json.loads(l) for l in sys.stdin if l.strip()]
f=[w for w in ws if w["owner"]=="Finder" and 380<=w["w"]<=440 and w["h"]<400]
p=sorted([w for w in ws if w["owner"]=="FinderSpeed" and w["alpha"]>0.99], key=lambda w: w["w"])
if f and len(p)>=2: print(json.dumps({"finder":f[0],"panel":p}))')
  KEY=$(echo "$J" | python3 -I -c 'import sys,json
try:
  j=json.load(sys.stdin); print([(w["x"],w["y"],w["w"],w["h"]) for w in [j["finder"]]+j["panel"]])
except Exception: print("none")')
  if [[ "$KEY" == "$PREV" && "$KEY" != none ]]; then STABLE=$((STABLE+1)); else STABLE=0; fi
  PREV=$KEY
  (( STABLE >= 6 )) && break
  perl -e 'select(undef,undef,undef,0.25)'
done
echo "$J" > "$OUT/windows.json"
F=$(python3 -I -c 'import json,sys
f=json.load(open(sys.argv[1]))["finder"]
x0 = max(0, int(f["x"]) - 80); y0 = max(0, int(f["y"]) - 60)
print("%d,%d,%d,%d" % (x0, y0, int(f["x"]) + int(f["w"]) + 80 - x0, int(f["y"]) + int(f["h"]) + 380 - y0))' "$OUT/windows.json")
echo "$F" > "$OUT/region.txt"
perl -e 'select(undef,undef,undef,0.8)'
screencapture -x -R"$F" "$OUT/shot.png"
echo "region $F"
# Wait until Finder's window and our panel are gone, then capture the clean background.
for i in $(seq 1 600); do
  N=$($TOOLS/winlist | python3 -I -c 'import sys,json
ws=[json.loads(l) for l in sys.stdin if l.strip()]
print(len([w for w in ws if (w["owner"]=="Finder" and 380<=w["w"]<=440 and w["h"]<400) or (w["owner"]=="FinderSpeed" and w["alpha"]>0.01)]))')
  [[ "$N" == 0 ]] && break
  perl -e 'select(undef,undef,undef,0.2)'
done
perl -e 'select(undef,undef,undef,0.6)'
screencapture -x -R"$F" "$OUT/clean.png"
python3 -I spikes/window/phase3/seam_check.py "$OUT"
