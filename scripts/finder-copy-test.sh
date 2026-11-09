#!/bin/zsh
# scripts/finder-copy-test.sh (owner: apollo)
#
# Runs a REAL Finder copy (Finder's own copy engine and progress window) of real, non-clone test
# data to /Volumes/FinderSpeedTest/<subdir>, measures it, then deletes the destination copy.
#
# Usage:
#   scripts/finder-copy-test.sh [options]
#
# Options:
#   -m, --mode file|folder   one big file, or a folder of N files (default: file)
#   -s, --size MB            size of each file in MiB (default: 2048 for file mode, 1024 for folder mode)
#   -n, --count N            number of files in folder mode (default: 3)
#   -d, --dest SUBDIR        destination folder under /Volumes/FinderSpeedTest (default: copytest)
#   -l, --loops N            repeat the copy N times (default: 1)
#   -b, --background         prepare the data in the foreground, then run the copy in the background
#                            and return at once (log file path is printed); use this to test the app
#   -k, --keep               do not delete the destination copy afterwards
#   -r, --regenerate         recreate the source data even if it exists
#       --max-total-gb G     disk budget for source + destination copy (default: 8)
#       --clean              delete all generated source data and exit
#   -h, --help
#
# Disk budget: the source data stays on the internal disk and the destination copy exists at
# the same time on the test volume, so source + copy (2 x payload) must fit in --max-total-gb.
# With the default 8 GB that allows payloads up to 4 GB. Only one source set is kept: making a new
# one deletes the old ones. The script also checks df on both disks before writing anything.
#
# Output: wall-clock time of the whole osascript call, the time from the first destination byte
# appearing to completion (excludes Apple Event / Finder "preparing" latency), and the average MB/s
# for both (MB = 10^6 bytes, as Finder shows it; MiB/s too).

set -euo pipefail
zmodload zsh/datetime

SCRIPT=${0:A}
ROOT=${SCRIPT:h:h}
SRC_BASE="$ROOT/testdata/finder-copy-test"
VOLUME=/Volumes/FinderSpeedTest

MODE=file
SIZE_MB=""
COUNT=3
SUBDIR=copytest
LOOPS=1
BACKGROUND=0
KEEP=0
REGEN=0
MAX_TOTAL_GB=8
CLEAN=0

die() { print -u2 "finder-copy-test: $*"; exit 1; }
usage() { sed -n '2,/^$/p' "$SCRIPT" | sed 's/^# \{0,1\}//'; exit 0; }

while (( $# )); do
  case $1 in
    -m|--mode) MODE=$2; shift 2 ;;
    -s|--size) SIZE_MB=$2; shift 2 ;;
    -n|--count) COUNT=$2; shift 2 ;;
    -d|--dest) SUBDIR=$2; shift 2 ;;
    -l|--loops) LOOPS=$2; shift 2 ;;
    -b|--background) BACKGROUND=1; shift ;;
    -k|--keep) KEEP=1; shift ;;
    -r|--regenerate) REGEN=1; shift ;;
    --max-total-gb) MAX_TOTAL_GB=$2; shift 2 ;;
    --clean) CLEAN=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
done

if (( CLEAN )); then
  rm -rf "$SRC_BASE"
  print "removed $SRC_BASE"
  exit 0
fi

[[ $MODE == file || $MODE == folder ]] || die "--mode must be file or folder"
[[ -z $SIZE_MB ]] && { [[ $MODE == file ]] && SIZE_MB=2048 || SIZE_MB=1024; }
[[ $SIZE_MB == <1-> && $COUNT == <1-> && $LOOPS == <1-> && $MAX_TOTAL_GB == <1-> ]] \
  || die "--size, --count, --loops and --max-total-gb must be positive integers"
[[ $SUBDIR != */* && $SUBDIR != .* && -n $SUBDIR ]] || die "--dest must be a plain folder name"
[[ -d $VOLUME ]] || die "$VOLUME is not mounted"
[[ $MODE == file ]] && COUNT=1

# MARK: sizes and disk budget (all in MiB)
PAYLOAD_MB=$(( SIZE_MB * COUNT ))
BUDGET_MB=$(( MAX_TOTAL_GB * 1024 ))
(( 2 * PAYLOAD_MB <= BUDGET_MB )) || die "source + copy = $(( 2 * PAYLOAD_MB )) MiB exceeds the budget of $BUDGET_MB MiB (--max-total-gb $MAX_TOTAL_GB)"

free_mb() { df -m "$1" | awk 'NR==2 { print $4 }'; }

if [[ $MODE == file ]]; then
  SET_NAME="real_${SIZE_MB}m.bin"
else
  SET_NAME="real_${COUNT}x${SIZE_MB}m"
fi
SRC="$SRC_BASE/$SET_NAME"
MARKER="$SRC_BASE/$SET_NAME.complete"
DEST_DIR="$VOLUME/$SUBDIR"
DEST="$DEST_DIR/$SET_NAME"

# MARK: source data (real random bytes, written with dd: no clones, no sparse files)
make_source() {
  mkdir -p "$SRC_BASE"
  # Keep only one source set: delete the others first (frees space before writing).
  for old in "$SRC_BASE"/*(N); do
    [[ $old == "$SRC" || $old == "$MARKER" ]] && continue
    rm -rf "$old"
  done
  rm -rf "$SRC" "$MARKER"
  local need=$(( PAYLOAD_MB + 1024 ))
  local have=$(free_mb "$ROOT")
  (( have >= need )) || die "internal disk: need $need MiB free for the source, have $have MiB"
  print "creating $PAYLOAD_MB MiB of random data in $SRC ..."
  local t0=$EPOCHREALTIME
  if [[ $MODE == file ]]; then
    dd if=/dev/urandom of="$SRC" bs=1m count=$SIZE_MB 2>/dev/null
  else
    mkdir -p "$SRC"
    local i
    for (( i = 1; i <= COUNT; i++ )); do
      dd if=/dev/urandom of="$SRC/$(printf 'file_%02d.bin' $i)" bs=1m count=$SIZE_MB 2>/dev/null
    done
  fi
  touch "$MARKER"
  printf 'created in %.1f s\n' $(( EPOCHREALTIME - t0 ))
}

if (( REGEN )) || [[ ! -e $MARKER || ! -e $SRC ]]; then
  make_source
else
  print "using existing source $SRC"
fi

total_bytes() {   # sum of regular file sizes under $1 (or of the file itself)
  if [[ -d $1 ]]; then
    find "$1" -type f -exec stat -f %z {} + | awk '{ s += $1 } END { printf "%d\n", s }'
  elif [[ -f $1 ]]; then
    stat -f %z "$1"
  else
    print 0
  fi
}
SRC_BYTES=$(total_bytes "$SRC")

# MARK: one copy run
mkdir -p "$DEST_DIR"

cleanup_dest() { (( KEEP )) || rm -rf "$DEST"; }

run_copy() {   # $1 = run number
  local run=$1
  local need=$(( PAYLOAD_MB + 512 ))
  local have=$(free_mb "$VOLUME")
  (( have >= need )) || die "$VOLUME: need $need MiB free, have $have MiB"
  rm -rf "$DEST"

  # Watcher: records when the destination item first appears (Finder has started writing).
  local appear_file=${TMPDIR:-/tmp}/finder-copy-test.$$.appear
  rm -f "$appear_file"
  (
    zmodload zsh/datetime
    while [[ ! -e $DEST ]]; do sleep 0.02; done
    print $EPOCHREALTIME > "$appear_file"
  ) &
  local watcher=$!

  printf '[run %d/%d] %s  Finder copy %s (%d bytes) -> %s\n' $run $LOOPS "$(date +%T)" "$SET_NAME" $SRC_BYTES "$DEST_DIR"
  local t0=$EPOCHREALTIME
  if ! osascript -e 'on run argv
      tell application "Finder" to duplicate (POSIX file (item 1 of argv) as alias) to (POSIX file (item 2 of argv) as alias) with replacing
    end run' "$SRC" "$DEST_DIR" >/dev/null; then
    kill $watcher 2>/dev/null || true
    rm -f "$appear_file"
    die "osascript failed (Automation permission for Finder? Volume full?)"
  fi
  local t1=$EPOCHREALTIME
  kill $watcher 2>/dev/null || true
  wait $watcher 2>/dev/null || true
  local ta=$t0
  [[ -s $appear_file ]] && ta=$(<"$appear_file")
  rm -f "$appear_file"

  local copied=$(total_bytes "$DEST")
  local wall=$(( t1 - t0 ))
  local active=$(( t1 - ta ))
  printf '  wall-clock (osascript):        %7.2f s  -> %7.1f MB/s  (%7.1f MiB/s)\n' \
    $wall $(( copied / wall / 1e6 )) $(( copied / wall / 1048576.0 ))
  if (( active > 0.05 )); then
    printf '  first byte -> done (true avg): %7.2f s  -> %7.1f MB/s  (%7.1f MiB/s)   start latency %.2f s\n' \
      $active $(( copied / active / 1e6 )) $(( copied / active / 1048576.0 )) $(( ta - t0 ))
  fi
  if (( copied != SRC_BYTES )); then
    print "  WARNING: destination has $copied bytes, source has $SRC_BYTES"
  fi
  cleanup_dest
  (( KEEP )) && print "  kept $DEST" || print "  deleted $DEST"
}

main() {
  trap 'print "interrupted: removing $DEST (Finder may still be copying)"; cleanup_dest; exit 130' INT TERM
  local r
  for (( r = 1; r <= LOOPS; r++ )); do run_copy $r; done
  print "done"
}

if (( BACKGROUND )); then
  LOG="${TMPDIR:-/tmp}/finder-copy-test.$(date +%Y%m%d-%H%M%S).log"
  main > "$LOG" 2>&1 &!
  print "copy running in the background (pid $!), log: $LOG"
  print "Finder's progress window appears about 3 s after the copy starts."
else
  main
fi
