# Engine review fixes (athena)

This answers apollo's `spikes/window/ENGINE_REVIEW.md`, findings 1–12.

- **Status:** `swift test` passes **31 tests in 4 suites**. 11 are new, in `Tests/FinderSpeedTests/ReviewFixTests.swift`.
- **Mutation check:** for every new test except the real-subscription unwatch test (see #7), I reverted its fix once and confirmed the test fails.
- **Real Finder copies:** apollo's `scripts/finder-copy-test.sh` (real data, no clones) to `/Volumes/FinderSpeedTest/athena`.

## Fixed

| # | Finding | Fix | Evidence |
|---|---|---|---|
| 1 | Window rows are fed per row, but the state is per folder | **Doc only**, because Zeus's wiring sums the rows. `noteWindowRow`'s doc comment now says: call it once per destination per snapshot, with the **sum of all rows** for that folder (bytes and totals), and `timestamp: Date()` taken when the row is read. | — |
| 2 | Spikes in short or final segments | Three parts: **(a)** segments shorter than `minSegment` (0.3 s) roll into the next sample, so no bytes are lost. **(b)** The final segment at unpublish needs a full tick (0.5 s), otherwise it is left out of the graph. **(c)** New finding from real runs: Finder's update that **completes an item** carries a catch-up burst. One real 4 GB folder copy went `… 904, 971, 1290 MB/s` on a normal 0.5 s segment. Those bytes now count in the total and the average but are not graphed. **(d)** Also fixed the timing of a folded **first** segment after preparing. It was capped again, which would have read +40 %. | Tests: `shortSegmentsAreFoldedNotSpiked`, `completingUpdateBurstIsNotGraphed`, `foldedFirstSegmentAfterPreparingIsTimedCorrectly` |
| 3 | Absolute window tolerance | The tolerance is now `max(20 MB, 2 % × window count)`. Finder prints about 3 significant digits, so its rounding is under 1 %. | Test: `roundedWindowTextOnLargeCopyDoesNotSwitch` (a stalled 123.45 GB copy whose window shows "123.5 GB") |
| 5 | No cancel detection in fallback mode | In fallback mode, a copy counts as cancelled if the window count is below the window total by more than the tolerance plus about 1 s of copying. **This needs `bytesTotal`**: apollo's `Row` should expose the "of Y" part. | Tests: `cancelIsDetectedInFallbackMode` (4 of 8 GB → cancelled), `completedCopyInFallbackModeIsNotCancelled` (last value read 7.6 of 8 GB → not cancelled) |
| 7 | `unwatch` during a copy marks it cancelled | Removing a subscription now **detaches** its handles. Unpublish callbacks that happen while we remove it are ignored. If another subscription delivered the same item, that duplicate **takes over** without a gap or spike. Otherwise the transfer disappears quietly and is not shown as FINISHED or CANCELLED. | Tests: `unwatchMidCopy…RemovesTransferQuietly`, `…PromotesDuplicateFromOtherSubscription`, `unwatchWithRealSubscriptionDoesNotCancel`. Real copy: unwatched at about 31 %, the transfer vanished and no CANCELLED appeared. |
| 8 | A revived transfer's EMA restarts from 0 | Reviving a transfer resets the EMA, so it starts at the new speed. | Test: `revivedTransferDoesNotRampFromZero` |
| 4 | Mixed clock domains | `emitSample` now reports whether it appended a sample. The window path only moves its baseline forward when a sample was appended, so a sample rejected for its timestamp rolls its bytes into the next one. | — (simple, not unit-tested) |
| 6 | Subscriptions made before `start()` or after `stop()` can't be removed | `stop()` always cleans up. It drops state *before* removing subscribers, so callbacks during removal can't finish or cancel anything. | Test: `stopCleansUpEvenIfNeverStarted` |
| 9 | Mount handler subscribes to hidden volumes | The `didMount` handler now skips volumes where `volumeIsBrowsable == false`, matching `start()`'s `.skipHiddenVolumes`. | — (needs a hidden mount to test) |
| 10 | No `deinit` cleanup | Added an `isolated deinit` that removes subscribers and workspace observers and invalidates the timers. It type-checks for the macOS 14 target. The timers also stop themselves if the monitor is gone. | — |

## Skipped

| # | Why |
|---|---|
| 11 | **Double count:** only when `fileURL` stays nil for more than 2 s. That was never observed; it normally arrives within milliseconds. **Path matching** (iCloud "Desktop & Documents", `/tmp`): the real check would need a copy into `~/Desktop`, and on this Mac that would upload gigabytes of test data to iCloud. Waiting for Zeus's go-ahead, or for a non-synced test location. |
| 12 | Informational. Nothing to change at the current scale. |

## Still open / notes

- **#7 limit:** neither a unit test nor a real Finder copy reproduced Foundation calling the unpublish handler synchronously inside `removeSubscriber`.
  - In-process it is not called at all.
  - On a real Finder copy here it was not called synchronously either.
  - The guard against that synchronous case (apollo's observation) is therefore untested. Behaviour is correct either way: the detach sweep drops the handle first, so a later callback does nothing.
- **Remaining jitter on short segments:** samples on 0.3–0.5 s segments can still be about ±25 % off, because we only check for changes every 0.1 s. A proper fix would timestamp changes via KVO, or poll every 50 ms. That's a separate change if wanted.
- **Debug hook:** `--engine-debug … --unwatch-after N` unwatches the extra folders after N seconds, for testing #7.
- **Files changed:**
  - `Sources/FinderSpeed/Engine/TransferMonitor.swift`
  - `Sources/FinderSpeed/Engine/EngineDebug.swift`
  - `Tests/FinderSpeedTests/ReviewFixTests.swift` (new)
