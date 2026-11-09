# Handoff (Zeus)

**State on 2026-11-09:**
- BUG-001 fixes are implemented and verified on the Mac Studio (1x). See `spikes/window/BUG-001.md` and `spikes/progress/BUG-001-engine.md`.
- `0.1.1-diag` is published as a GitHub pre-release (DMG + zip). The diagnostic log `~/Library/Logs/FinderSpeed.log` is on by default in that build.

**Waiting for:** the user to run 0.1.1-diag on their **MacBook (Retina)** during a slow move to an external drive, then send:
- `~/Library/Logs/FinderSpeed.log`
- a screenshot

**Then:**
1. Check the log for slow or failing AX calls, show/hide flapping, opacity values, and the backingScaleFactor.
2. If clean, release `0.1.1` with `FINDERSPEED_VERSION=0.1.1 scripts/build-app.sh release --universal --zip --dmg`, without diag.
