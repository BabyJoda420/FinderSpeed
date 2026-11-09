#!/bin/zsh
# Visual test: starts a real Finder copy, waits for Finder's "Copy" window + the FinderSpeed panel,
# then saves screenshots (and optionally a short video) of the region around both. Owner: zeus.
# Usage: scripts/capture-copy.sh [out_dir] [--video SECONDS] [--expand]
set -uo pipefail
cd "${0:A:h}/.."
OUT=${1:-build/captures}; shift || true
VIDEO=0; [[ "${1:-}" == --video ]] && VIDEO=${2:-6}
mkdir -p "$OUT"; TOOLS=scripts/tools
[[ -x $TOOLS/winlist ]] || swiftc -O $TOOLS/winlist.swift -o $TOOLS/winlist
scripts/finder-copy-test.sh -m folder -n 8 -s 1024 --max-total-gb 18 -d capture -b >/dev/null 2>&1
# Wait for Finder's progress window (width ~404) and our panel.
for i in $(seq 1 150); do
  W=$($TOOLS/winlist)
  F=$(echo "$W" | python3 -c 'import sys,json
ws=[json.loads(l) for l in sys.stdin if l.strip()]
f=[w for w in ws if w["owner"]=="Finder" and 380<=w["w"]<=440 and w["h"]<400]
p=[w for w in ws if w["owner"]=="FinderSpeed" and w["alpha"]>0.9]
if f and p:
  xs=[w["x"] for w in f+p]; ys=[w["y"] for w in f+p]; xe=[w["x"]+w["w"] for w in f+p]; ye=[w["y"]+w["h"] for w in f+p]
  m=40; print(f"{int(min(xs)-m)},{int(min(ys)-m)},{int(max(xe)-min(xs)+2*m)},{int(max(ye)-min(ys)+2*m)}")
  for w in f+p: print(w, file=sys.stderr)')
  [[ -n "$F" ]] && break
  perl -e 'select(undef,undef,undef,0.1)'
done
[[ -z "$F" ]] && { echo "Finder window + panel not found"; exit 1; }
echo "region $F"
perl -e 'select(undef,undef,undef,1.0)'   # let the panel fade in and get a few samples
for n in 1 2 3; do screencapture -x -R"$F" "$OUT/shot-$n.png"; perl -e 'select(undef,undef,undef,1.2)'; done
if (( VIDEO > 0 )); then screencapture -x -v -V "$VIDEO" -R"$F" "$OUT/clip.mov"; fi
echo "saved to $OUT"; ls "$OUT"
