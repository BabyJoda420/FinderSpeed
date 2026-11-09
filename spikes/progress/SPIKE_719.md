# The 719 MB/s graph spike (Phase 3, athena)

**Status:** fixed in `Sources/FinderSpeed/Engine/TransferMonitor.swift`. `swift test` passes **41 tests in 6 suites**. The cause was found with replays and screenshot analysis. No real Finder copies were started (Apollo was taking screenshots), and the app logs no samples, so the cause has **not yet been confirmed on real data**. See the last section.

## What the evidence actually shows

- **The "true average 61 MB/s" was wrong.**
  - The copy-test log for that run (`$TMPDIR/finder-copy-test.20261109-144229.log`) ends with `WARNING: destination has 4353687552 bytes, source has 8589934592`.
  - A second capture run started a second copy into the same `capture` folder at 14:43:10. That run's log shows error `-37`. `shot-3.png` and `clip.mov` show two "Copying … to “capture”" rows.
  - The overlapping copy damaged the destination, and the script divided what was left by the elapsed time.
- **The real speed was about 146 MB/s.** `shot-2.png` was taken at 14:43:13, 42.4 s into the copy (first byte at 14:42:30.65). Finder's own text read "6.18 GB of 8.59 GB" then: 6.18 GB ÷ 42.4 s ≈ 146 MB/s. The two clean runs of the same 8 × 1 GiB folder measured 139–141 MB/s. So the graph's "avg 142 MB/s" was correct; only the spikes were wrong.
- **The spike's shape** (a 10× zoom of shot-2): a plateau at about 1.3× the average, then **one** sample at about 5×. There is **no dip to 0** before it, so it is not a ≥ 2 s stall.
- **The smaller bumps** (about 1.7×) recur every ~7.3 s. That matches one 1 GiB inner file finishing every 7.3 s at 140 MB/s, i.e. Finder's catch-up when a file completes.
- **The window-row fallback was not involved before 14:43:20.** It only engaged when the second copy's row started adding bytes (the clip shows the summed "7.96 GB of 17.2 GB").

## Cause

**Each raw sample was bytes ÷ time over ONE ~0.5 s segment, timestamped when *we* saw Finder's counter, not when Finder produced it.** That moment includes:
- the 0.1 s poll phase;
- cross-process delivery of the progress proxy;
- main-thread delays.

When that delivery lag **changes**, the bytes and the time stop matching:
- **A steady lag that clears.** Values arrive ~1.5 s late for a while, then fresh. One 0.5 s segment then carries about 2 s of bytes, giving a single 4–5× sample after a normal plateau with no dip. This matches the screenshot.
- **A stall of 2 s or more.** The engine's synthetic 0 samples reset the segment start, so the burst after the stall was divided by the last 0.5 s (replay: **4.94×**). This shape includes a 0 dip, so it is a second, related bug.
- **The first value after "preparing" arriving late.** It carries several ticks, but was timed as one tick (replay: 3×).
- **Plain poll-phase noise.** A 0.5 s tick is measured as 0.4–0.6 s (±25 %, 1.35× peaks even on clean input).
- **Inner-file catch-up bursts** (1.56×) explain the regular smaller bumps.

## Fix

All of this is in `TransferMonitor.swift`. The new `RateHistory` type holds the real counter observations.

1. **A median over the last 5 raw rates** (`medianWidth = 5`) removes outliers up to 2 samples long. A real speed change shows about 2 samples (~1 s) later.
2. **Windowed rates:** each raw rate covers at least `rawRateWindow = 0.6 s` of **real** counter history, instead of a single segment.
3. **Stall zeros stay out of the history.** The synthetic 0 samples are still shown (they skip the median, so a stall appears at once), but they no longer reset the rate history. The burst after a stall is spread over the real elapsed time.
4. **The first value after preparing only starts the history.** It is still used for the average's start time (assumed to arrive within one tick). Until the first graphed sample exists (about 1 s after the first bytes), `bytesPerSecond` shows a provisional rate instead of 0.

Replay peaks (sample ÷ true rate), old engine → fixed:

| Scenario | Old | Fixed |
|---|---|---|
| Delivery lag of 1.5 s that clears (the screenshot case) | 3.0× | **1.02×** |
| 2.4 s delivery stall | 4.94× | **< 1.3×** (also with the median off) |
| 5 % of updates 0.8–1.6 s late | 2.5× | **1.13×** |
| Heavy jitter, 0–0.6 s on every update | 1.8× | 1.27× |
| Inner-file catch-up bursts | 1.56× | **1.02×** |
| Window fallback, 10 MB text steps at 61 MB/s | 2.0× | ≤ 1.5× |
| First value after preparing arrives late | 3.0× | ~1.0× |

**Side effects:**
- **Slower reaction:** the graph reacts to a real speed change about 1 s later, and the first graphed point appears about 1 s after the copy starts.
- **Heavy jitter (0–0.6 s on every update):** the graphed samples read about 15 % low, with or without the median, because the 0.3 s minimum spacing skips the quick catch-up changes. The engine's `averageBytesPerSecond` (the dashed line) stays within 3 %, and with realistic jitter the samples are unbiased.

## Tests

- **`Tests/FinderSpeedTests/SpikeReplayTests.swift`**, suite "Spike replays (Phase 3)". It models Finder's 2 Hz counter (8 MiB steps, per-file holdback) and delivery delays (seeded RNG), and feeds them through the real 0.1 s poll.
  - `clearingDeliveryLagDoesNotSpike`: **the screenshot case.**
  - `oneLateUpdateDoesNotSpike`
  - `deliveryStallDoesNotSpikeAfterwards(medianWidth:)`, run with the median both on and off.
  - `jitterStaysBounded(seed:)`, 20 seeds, mild and rare-large delays.
  - `innerFileCatchUpBurstsAreDamped`
  - `windowFallbackQuantisedTextStaysBounded(seed:)`
  - `averagesStayUnbiased(seed:)`
- **`ReviewFixTests.lateFirstValueAfterPreparingDoesNotSpike`**
- **Updated to the new timing:**
  - `TransferMonitorTests.preparingUntilFirstRealBytes`
  - `TransferMonitorTests.longPreparingDoesNotDiluteSpeedOrAverage` (replaces `firstSampleAfterLongPreparingIsCappedToOneFinderTick`)
  - `TransferMonitorTests.emaTracksConstantSpeedAndFollowsAStep`
  - `ReviewFixTests.revivedTransferDoesNotRampFromZero`
- **Mutation check:** I reverted each part of the fix (median, window, stall-history rule, first-value rule, zero bypass) once, and each time at least one of these tests failed.

## Is a real-data confirmation still needed?

**Yes, as a check, not as a blocker.** The mechanism is inferred: the replays reproduce the spike's size and shape, but we have no recording of the samples from that copy.

**Suggested check (one copy, once Apollo is done):**
- Run a clean 8 × 1 GiB folder copy to `/Volumes/FinderSpeedTest/athena` (`scripts/finder-copy-test.sh -m folder -n 8 -s 1024 --max-total-gb 18 -d athena`).
- At the same time, run `FinderSpeed --engine-debug /Volumes/FinderSpeedTest/athena`. It prints all raw samples when the transfer finishes.
- **Don't let a second copy overlap.**
- **Pass:** no sample above about 1.5× the script's "first byte → done" average. Ideally also run it once with the panel visible, since main-thread load from the UI is the suspected source of the delivery lag.
