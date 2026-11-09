# Engine review + copy-test script (apollo)

This covers both tasks from Zeus: (1) `scripts/finder-copy-test.sh` and (2) a read-only review of `Sources/FinderSpeed/Engine/*.swift` and `Tests/FinderSpeedTests/*.swift`. I edited no Engine or Test files. The scratch programs used for verification are outside the repo, in the session scratchpad.

---

## Task 1: `scripts/finder-copy-test.sh`

```
scripts/finder-copy-test.sh [-m file|folder] [-s MB] [-n COUNT] [-d SUBDIR] [-l LOOPS] [-b] [-k] [-r]
                            [--max-total-gb G] [--clean] [-h]
```

**Source data**
- The script writes real random data with `dd if=/dev/urandom` into `testdata/finder-copy-test/`. There are no clones and no sparse files.
- File mode makes `real_<MB>m.bin`. Folder mode makes `real_<N>x<MB>m/file_NN.bin`.
- A `.complete` marker means "already generated", so later runs reuse the data. `-r` regenerates it.
- Only one source set is kept: creating a new one deletes the old ones. `--clean` deletes all of them.

**Disk budget**
- While a copy runs, source and copy exist at the same time. So `2 × payload` must fit in `--max-total-gb`, which defaults to 8. That allows payloads up to 4 GiB.
- Before writing anything, the script checks `df` on the internal disk (payload + 1 GiB) and on the test volume (payload + 512 MiB).

**The copy**
- It runs Finder's `duplicate ... with replacing` through `osascript`, passing paths as `argv` (no quoting problems), to `/Volumes/FinderSpeedTest/<SUBDIR>`. The default subdir is `copytest`, created if missing.
- Afterwards it checks that the destination's byte total equals the source's, then deletes the destination unless you pass `-k`. Ctrl-C also deletes it.

**Measurements**
- Wall-clock time of the `osascript` call.
- "First byte → done": the time from when the destination item first appears (a 20 ms watcher) until the copy finishes. This excludes the Apple Event latency.
- MB/s for both (10⁶ bytes, as Finder counts), plus MiB/s.

**Other flags**
- `-b` creates the data in the foreground, then starts the copy in the background, returns at once and prints the log path. Use it to test the app during a copy.
- `-l N` repeats the copy N times.

**Evidence**

| Run | Output |
|---|---|
| default (2 GiB file) | `created in 4.2 s` · `wall-clock 2.92 s -> 735.3 MB/s` · `first byte -> done 2.75 s -> 781.3 MB/s, start latency 0.17 s` · `deleted …/real_2048m.bin` |
| `-m folder -n 4 -s 1024 -b` | returned at once with `copy running in the background (pid 70404), log: …/finder-copy-test.20261109-140601.log`; log: `wall-clock 4.77 s -> 901.0 MB/s`, `first byte -> done 4.60 s -> 934.6 MB/s` |
| `-m folder -n 5 -s 1024` | `source + copy = 10240 MiB exceeds the budget of 8192 MiB` (exit 1) |

**Real data does not trigger the clone quirk.** During the background folder copy, `FinderSpeed --engine-debug` showed `4.3 GB/4.3 GB (100.0%) FINISHED`. NSProgress totals are correct for a folder of real (non-clone) files.

**Limits of the script**
- With the 8 GB budget, a copy lasts only about 5 s at about 900 MB/s, and Finder's window shows for about 2 s of it. For app testing, use `-l` to repeat, or raise `--max-total-gb` if there is room.
- The "true avg" starts its clock when Finder creates the destination item. That includes Finder's short preparing phase, so it is a lower bound. The Engine's own average for the same run (1.02 GB/s) is about 9% higher. That gap is explained by the different start points, not by an Engine bug.
- The 4 GiB source set `testdata/finder-copy-test/real_4x1024m` stays on disk for reuse. Remove it with `--clean`.

---

## Task 2: Engine review

**Baseline:** `swift test` passes 20/20 tests in 3 suites.

**Verdict markers:**
- **CONFIRMED**: reproduced by a scratch simulation or a real run.
- **CODE**: found by reading the code, not executed.
- **PLAUSIBLE**: depends on Finder or Foundation behaviour I could not pin down.

### 1. [High] `noteWindowRow` is per row, but the state is per folder: two rows into one folder break the fallback (CONFIRMED)

`noteWindowRow` stores **one** `windowBytes` per `TransferState`. But Finder's window has **one row per operation**, and the Engine groups all operations into the same folder into **one** transfer. When two rows map to the same transfer (two drags into the same folder):
- `windowBytes` takes whichever row was fed last. The switch test `wb > s.bytesCompleted + windowTolerance` then compares **one row** with the **sum of all handles**, so it never fires.
- If the switch does happen (both rows ahead), samples are only computed from the first row of each burst. The second row arrives under 50 ms later and is skipped by the `dt >= 0.05` guard, but it still overwrites `windowBytes`. The displayed bytes then flip to the last row's count, and the speed counts only one operation.

**Reproduction.** A scratch program compiles `TransferMonitor.swift` and `Transfer.swift` with a fake clock. It simulates two ops into `/V/dest`, both with NSProgress frozen at 2 GB (the clone quirk), with window rows at 600 and 300 MB/s fed per row, the way an App loop over `observer.window.rows` would:

```
t= 3.0s window=N bytesCompleted= 2.70 GB (true  2.70 GB)  speed= 900 MB/s (true 900)
t= 5.0s window=N bytesCompleted= 3.50 GB (true  4.50 GB)  speed= 753 MB/s (true 900)
t= 8.0s window=N bytesCompleted= 4.00 GB (true  7.20 GB)  speed= 273 MB/s (true 900)
t=10.0s window=N bytesCompleted= 4.00 GB (true  9.00 GB)  speed=  97 MB/s (true 900)
```

The fallback never switches: the transfer freezes at 4 GB and the speed decays toward 0, which is exactly the case the fallback exists for.

**Fix options:**
- (a) Zeus sums all rows that resolve to the same folder (bytes and totals) and calls `noteWindowRow` **once per folder per snapshot**. This needs no Engine change, just a rule for the App.
- (b) The Engine gets `noteWindowRows(_ rows: [(destination: URL?, name: String?, bytes: Int64, total: Int64?)], timestamp:)` and aggregates per state itself. That is safer, because the API can't be misused.

Either way, add a test with two rows into one folder.

### 2. [Medium] Short segments, especially the final one at unpublish, produce raw-sample spikes (CONFIRMED in a real run)

Real 4 × 1 GiB folder copy, raw samples from `--engine-debug`:

```
+0.61s:839 +1.11s:919 +1.61s:939 +2.11s:937 +2.60s:1014 +3.11s:1030 +3.61s:1129 +4.11s:1179 +4.31s:1484 MB/s
```

The last sample covers only 0.2 s and is about 26% above its neighbour.

**Cause.** Segment times are when *we polled* (every 0.1 s) and when the unpublish was delivered, not when Finder updated its counter. On a 0.5 s segment, the 0–0.1 s detection lag at each end gives up to ±20% error. On a short segment the same absolute error is amplified: a 0.2 s segment gets up to ±50%, and the 50 ms minimum allows up to ±200%. The final segment at unpublish is the common short one.

**Effect.** It is only cosmetic for the speed shown at the end (the EMA is set to 0 at finish), but the graph gets a spike at the end of almost every copy.

**Fix:**
- Fold the final segment into the previous sample when `dt < ~0.6 × nominalCadence`, or don't emit it.
- Raise the mid-copy minimum from 0.05 s to about 0.25 s. The bytes are not lost: they roll into the next segment.

### 3. [Medium] The window tolerance is absolute (20 MB) while Finder's text precision is relative (PLAUSIBLE)

Finder prints about 3 significant digits: "947.9 MB", "1.52 GB" and "10.15 GB" are 10 MB steps. At larger sizes the step grows: "1.23 TB" is a 10 GB step, and possibly "123.4 GB" is a 100 MB step (I have not seen that format yet). If Finder rounds to nearest, the window count can lead NSProgress by up to half a step all the time. With a step above about 40 MB, that lead exceeds `windowTolerance` for good, which causes:
- a false switch after 1.5 s on a perfectly healthy copy;
- afterwards, speed samples computed from coarse steps, alternating between 0 and huge values.

**Fix.** Make the tolerance `max(20 MB, displayStep)`. I can add `Row.statusBytesResolution` (the step implied by the printed digits) to the Window module if Athena wants it. A quick real check of the ≥100 GB format would settle the threshold.

### 4. [Low] Mixed clock domains on the window path (CODE)

`noteWindowRow` uses the caller's `timestamp` for `windowChangedAt`, `windowFirst` and samples. `poll()` and `updateWindowFallback` from `poll` use `clock()`. `emitSample` silently drops a sample whose time is not later than the last one. But `noteWindowRow` advances `windowSampledBytes`/`windowSampledAt` even when that happens, so that segment's bytes vanish from the graph. In production both clocks are `Date()`, so this only bites if the App passes a cached or event time. **Rule for the App:** pass `Date()` at the moment the row is read. A cleaner fix: ignore the parameter, use `clock()`, or clamp the timestamp to `max(timestamp, lastSample)`.

### 5. [Low] Cancellation is not detected in window-fallback mode (CODE)

`wasCancelled` comes only from NSProgress (`isCancelled`, or `bytes < total` at unpublish). In the clone quirk, NSProgress ends at "2.15 GB of 2.15 GB", so a copy the user cancels halfway reads `FINISHED`, not cancelled. **Fix:** when `usesWindowBytes`, also compare `windowBytes` with `windowTotal` at finish.

### 6. [Low] Subscriptions made before `start()` or after `stop()` can't be removed (CODE)

`watch(folder:)` and `noteFinderDestination` call `addReason` whether or not the monitor is started. `stop()` begins with `guard started else { return }`. If the App feeds hints before `monitor.start()`, or after `stop()`, those subscriptions, their handles and the 10 Hz poll timer live on until the next start/stop cycle. **Fix:** ignore calls while not started, or make `stop()` always clean up.

### 7. [Low] `unwatch(folder:)` during a copy marks a running copy as cancelled (CONFIRMED mechanism)

`Progress.removeSubscriber` calls the unpublish handler **synchronously on the main thread** (verified below). So removing the subscription that delivered a running copy's handle runs `handleUnpublished`: `bytes < total` makes the transfer finished and cancelled, while Finder keeps copying. A duplicate handle of the same item from another subscription stays `isDuplicate` and is never promoted, so the transfer disappears even though the copy is still visible to the Engine through that other subscription.

**When it can happen:**
- `unwatch` mid-copy, and nothing else. For a volume unmount, Finder aborts the copy anyway, so "cancelled" is correct.
- Hint expiry is protected by the busy check.

**Fix:** when removing a subscription, don't count our own removal as a cancel. Promote a duplicate handle if one exists.

### 8. [Low] A revived transfer's EMA restarts from 0 (CODE)

At finish, `s.ema = 0` but `emaInitialized` stays true. When a new item arrives within `reviveWindow` (1 s), the transfer is revived and the EMA ramps up from 0 with τ = 1.5 s. The speed reads low for about 2–3 s right after the second drag. **Fix:** reset `emaInitialized = false` on revive.

### 9. [Low] Mount handling is inconsistent with start-up (CODE)

`start()` lists volumes with `.skipHiddenVolumes`, but the `didMount` handler subscribes to **every** mounted volume, hidden ones included (e.g. Time Machine snapshots, simulator runtimes). This is harmless apart from extra subscriptions. **Fix:** check `URLResourceValues.volumeIsBrowsable` in the mount handler.

### 10. [Low] No `deinit` cleanup (CODE)

If a `TransferMonitor` is released without `stop()`, the Progress subscriptions stay registered (Foundation holds the handlers; they hold only a `WeakMonitor`, so they turn into no-ops), and the workspace observers and housekeeping timer keep firing into nil. The monitor lives as long as the app, so this matters only for tests or re-creation.

### 11. [Low] Edge cases in grouping and dedupe (CODE)

- **Possible double count.** If `fileURL` stays nil for more than 2 s, the fallback groups by `subscribedPath`. The same item delivered by two subscriptions (the item itself and its parent) then lands in two different transfers.
- **Path matching is exact text.** Keys are `standardizedFileURL.path`, which doesn't resolve symlinks or firmlinks (`/tmp` vs `/private/tmp`, `/System/Volumes/Data/...`, iCloud "Desktop & Documents"). Grouping, dedupe, hint matching and `noteWindowRow(destination:)` all rely on exact string equality with Finder's `fileURL`. I saw no problem in practice, but this Mac has iCloud Desktop items, so a copy to `~/Desktop` is worth one real check.

### 12. [Info] Performance (CODE)

`publish()` builds every `Transfer`, including up to 2400 samples each, and compares the whole array every 0.1 s. `@Published` then sends the whole array, so the graph re-renders on every counter change (about 2 Hz). That is fine at the current scale. If the UI ever stutters, publish samples separately or throttle publishing to counter changes.

### Checked and found correct

- **Unsubscribing does not leave ghost transfers (verified).** A scratch subscriber on `/Volumes/FinderSpeedTest/apollo`, with a real 4 GiB Finder copy and `removeSubscriber` 1.5 s into it, logged `[2.11s] removeSubscriber now` followed by `[2.11s] UNPUBLISH handler called main=true`. So `stop()`, unmount and hint expiry don't leave ghost handles, and `pendingUnpublish` doesn't leak. The proxy kept its stale value (`bytes=1392541696`) afterwards.
- **The publish handler runs on the main thread** (`published nil main=true`), with `fileURL` nil at first, as the code assumes. `onMain` takes its synchronous path.
- **Unpublish arriving before publish** across threads is handled by `pendingUnpublish`.
- **Threading:** all mutable state is on the main actor. Timers and workspace observers run on main and use `assumeIsolated` correctly. `WeakMonitor` and `UncheckedBox` are used soundly.
- **EMA math:** `alpha = 1 − e^(−dt/τ)` is correct for irregular spacing, and negative dt is clamped. The late-attach priming (skipping the first change) and the capped first interval after preparing are sound and tested.
- **Stall handling:** zero samples at the nominal cadence after 2 s without a change decay the EMA as intended.
- **Expiring hints** while iterating `hintLastUsed` is safe, because Swift iterates over a copy.

### Gaps in the tests

There are no tests for:
- two window rows into one folder (#1);
- the final short segment (#2);
- revive within `reviveWindow` (#8);
- unpublish before publish;
- dedupe when `fileURL` is nil;
- a stop/start cycle;
- removing a subscription mid-copy (#7);
- `noteFinderDestination` before `start()` (#6).
