# BUG-001, engine part: "Speed: 46.7 KB/s" with "Average 3.40 MB/s · Peak 3.40 MB/s" (athena)

**Status:** fixed in `Sources/FinderSpeed/Engine/TransferMonitor.swift`. `swift test` passes **48 tests in 8 suites**. The cause was reproduced exactly in a replay on the old engine. It could **not** be checked on a real slow device (see "Open").

## Cause (suspects a and b confirmed)

- **Finder's update granularity.** Finder's byte counter moves in **8 MiB granules**: every value in the spike-A logs is a multiple of 8 MiB. At 3.4 MB/s, a step takes ~2.5 s, so the counter only changes every ~2.5 s.
- **(a) Fake stalls.** The old engine called any gap of 2 s or more a stall and emitted 0 samples. So between *every* two real updates it emitted a zero, and the EMA decayed the displayed speed toward 0.
- **(b) The median swallowed the real rates.** Stall zeros entered the median-of-5 history: median of [0, 3.4, 0, 3.4, 0] = 0. So the graph was almost all zeros. The UI's peak is the maximum sample, so it fell back to the average (**avg == peak**).
- **Replay on the old engine** (3.4 MB/s, 8 MiB steps, 120 s): the displayed speed swung between **0 and 2.78 MB/s**, and **47 of 92** samples were fake zeros. That matches the screenshot.

## (c) Moves: real data

- **The user's case:** the panel showed a 3.40 MB/s average, which can only come from Finder's byte counter. So the move was tracked with bytes like a copy. The operation kind doesn't matter to the engine, which filters on `FIOperationUUID` and the byte keys.
- **Same-volume move** (athena/mv1 → mv2, real Finder `move`): an instant rename. **No progress is published at all.**
- **Cross-volume move via AppleScript `move`:** Finder actually **copied**. The source stayed and the operation kind was `NSProgressFileOperationKindCopying`. A real cross-volume "Moving" needs UI scripting (⌘-drag or ⌥⌘V), which I didn't do on the user's desktop.
- **Copying 4,003 small files** (4,000 × 16 KiB + 3 × 100 MiB, real data) to the test volume:
  - the counter still updated about every 0.5 s (median interval 0.521 s, max 1.10 s);
  - the speed was 30–60 MB/s;
  - the total includes about 32 KB of per-file overhead (506 MB counted for about 380 MB of data).

## Fix

1. **The update interval is learned per copy** (`UpdateIntervals`, the last 20 gaps between real counter changes). This is done separately for the NSProgress counter and the window-text count.
2. **The last rate is held until the next update.** A stall is declared only after `max(2 s, 3 × the median gap, 1.5 × the longest recent normal gap)`. Before any gap is known, the threshold is 5 s.
3. **Learning only from normal gaps.**
   - A gap that was shown as a stall is still learned if the bytes arriving with it show copying went on (≥ 50 % of the last real rate): Finder's counter was just quiet.
   - A genuine pause is not learned, so it can't hide the next one.
4. **Stall zeros don't enter the median's history.** They are still shown immediately, but they no longer suppress the real rates around them.
5. **Switching to the window-text fallback restarts the smoothing**, so an EMA that the frozen NSProgress had decayed isn't carried over.

**Average and peak are now real:** the average is bytes ÷ elapsed copy time, and the peak is the maximum of real graph samples.

## Tests (`Tests/FinderSpeedTests/SlowCopyReplayTests.swift`)

- **`slowGranularCopyShowsSteadySpeed`** (3.4 MB/s, 8 MiB steps): the displayed speed holds steady at **3.36 MB/s** at every 0.1 s poll, with **0** fake zeros, peak 3.36 and average 3.46 MB/s.
- **`burstyUpdatesAreHeldNotZeroed(seed:)`** (10 seeds, irregular gaps of 0.5–6 s): after a 20 s learning phase, no zeros, the speed stays within 0.5–1.8× the true rate, and the average and peak are real. The very first gap longer than anything seen so far can still show as a brief pause; nothing can predict it.
- **`realStallOnSlowCopyIsShownLateAndRecovers`**: a 20 s pause during a slow copy shows as 0 after about 7.5 s (3 × 2.5 s), and the real rate is back right after it resumes.
- **`secondRealStallIsStillShown`**: two real 20 s pauses in a row. The second one still shows as 0 within ~7.5 s, which proves the first pause was not learned as a normal gap.
- **`slowWindowFallbackIsHeld`**: the window text at 3.4 MB/s (10 MB steps, every ~3 s) is held, with no zeros.

**Mutation check:** I reverted each part once, and every revert is caught: a fixed 2 s stall, no longest-gap term, never learning from shown stalls, learning genuine pauses too (caught by `secondRealStallIsStillShown`), zeros entering the median, and no EMA restart on switch.

## Open

- **No real slow device.** I couldn't run a real slow copy (no slow device or throttling available without touching the user's drives or system settings). The 8 MiB-granule → 2.5 s cadence at 3.4 MB/s is inferred from fast-copy logs.
  - **Suggested confirmation:** on the user's next slow copy or move, run the app with `FINDERSPEED_ENGINE_LOG=1`, plus `spikes/progress/progresswatch <dest folder>` for the raw counter cadence.
- **Real cross-volume "Moving"** wasn't tested (it needs UI scripting; ask the user first).

**Cleanup:** all test data in `athena/` and the scratch source were deleted.
