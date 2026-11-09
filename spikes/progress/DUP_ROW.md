# Duplicate "→ capture-a" row (apollo's 2-row test, PHASE3.md observation 1), athena

**Short answer:** the engine did **not** duplicate or replace capture-a's transfer. Both rows in `build/captures/apollo-two/shot.png` are, almost certainly, **the same transfer at two moments**, drawn during the panel's 1 → 2 row transition. The engine part that *was* wrong: right after joining a running copy (a "late attach"), it reported speed 0 and no average for about 1 s. The UI printed that as a real "0 KB/s". This is now fixed with `Transfer.isMeasuring`. The UI needs a one-line change (see "For Thor").

## How it was checked

**1. Finder side.** I subscribed a raw probe (`spikes/progress/progresswatch`) to `athena/cap-a` and `athena/cap-b` and ran two real 8 × 1 GiB copies started 2.5 s apart.
- Each copy got exactly **one** publish and **one** unpublish (about 28 s apart). Finder does not re-publish the first copy when the second starts.
- A second probe added subscriptions **mid-copy**, as the hints do. That delivers an extra proxy per new subscription (deduped by the engine), and never unpublishes the existing ones.

**2. Engine side, with the full app.** I added an opt-in event log, `FINDERSPEED_ENGINE_LOG=1`, which logs subscribe/publish/assign/new/duplicate/detach/unpublish/finish/remove/window-switch to stderr. With it I ran a copy of the real app (hints, window rows, panel) through **four** real two-copy runs into `athena/cap-a` and `athena/cap-b`, started 1 s apart:
- a fresh app;
- two rounds back to back, so the hint subscriptions already existed and capture-a was seen from its first byte;
- the app launched 0.5 s into the copies;
- the app launched 3.5 s into the copies.

Every run showed exactly one `new T…(cap-a)` and one `new T…(cap-b)`, then `finish`, then `remove`. There was no duplicate, detach, replacement or second transfer for the same folder. For example:
```
subscribe …/athena/cap-a (finderHint)
publish h3AFF[real_8x1024m via cap-a bytes=780140544]
new TEF24(cap-a) live=["TEF24(cap-a)"]
subscribe …/athena/cap-b (finderHint)
publish hB42E[real_8x1024m via cap-b bytes=1040187392]
new T0080(cap-b) live=["TEF24(cap-a)", "T0080(cap-b)"]
… unpublish/finish both 26 s later, removed after the 4 s linger
```

**3. The App code.**
- The hints only ever add subscriptions. The App never calls `stop`, `watch` or `unwatch`.
- `FinderRowOrder.sorted` only reorders transfers, so it can't produce duplicates.

## Why the screenshot shows two rows

The two rows' values are exactly the states a late-attached transfer goes through:
- **"Average 0 KB/s · Peak 0 KB/s":** before its first timed counter change (no `averageBytesPerSecond` yet, speed 0).
- **"Speed: 0 KB/s · Average 337 MB/s · Peak 337":** one Finder update later. The average now exists, but the build apollo ran (the app process before 15:30:32) had no provisional speed yet, so speed was still 0.

Seeing both at once means one row was rendered at two positions/contents during the panel's height/row-insertion animation, while capture-b's row was added. That transition is a Window/UI matter. The engine data behind it was a single transfer.

## Engine fix

- **New field `Transfer.isMeasuring`:** true while bytes are flowing but there is no speed estimate yet (no samples and no provisional rate). In that state `bytesPerSecond` is 0 and `averageBytesPerSecond` is nil, which means "unknown", not "zero".
- **How long it lasts:** about 1 s after a late attach (`measuringEndsWithinAboutOneSecondOfLateAttach`).
- The event log (`FINDERSPEED_ENGINE_LOG=1`) stays in. It is off by default and is the quickest way to answer "did the engine duplicate it?" next time.

## For Thor (UI, not changed by me)

In `SpeedFormatting`, treat `transfer.isMeasuring` like preparing:
- line 1: "Measuring…" instead of "Speed: 0 KB/s";
- line 2: no "Average 0 KB/s · Peak 0 KB/s".

## Tests

`Tests/FinderSpeedTests/DupRowReplayTests.swift`:
- **`secondCopyNeverDuplicatesOrReplacesTheFirst`** replays apollo's run with the App's exact call sequence:
  - capture-a is joined at 679 MB via its hint;
  - capture-b starts 1 s later, and its window row is matched by name until its hint resolves;
  - window rows are summed per destination at 2 Hz;
  - capture-a's item is delivered a **second time** through another subscription.
  
  At every 0.1 s step it checks: at most one transfer per destination, capture-a's id never changes, and never "speed 0" without `isMeasuring`.
- **`measuringEndsWithinAboutOneSecondOfLateAttach`**

The mutation check (removing `isMeasuring`, disabling dedupe, a new transfer per progress, wrong name-based window-row matching) is caught by these or by the existing tests. `swift test`: **43 tests in 7 suites pass**.

**Cleanup:** all test copies under `/Volumes/FinderSpeedTest/athena/cap-a|cap-b` were deleted (only Finder's `.DS_Store` files remain). My logging app instance was stopped, the temporary Finder window on `athena` was closed, and Zeus's running instance was left alone.

**Open:** I could not reproduce the transitional frame itself (I didn't capture screenshots). If it matters visually, apollo/thor should check the row insertion and height animation when a second transfer appears.
