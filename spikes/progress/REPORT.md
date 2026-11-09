# Spike A: Subscribing to Finder's NSProgress (athena)

**Does it work? YES.** On macOS 27.0.1, Finder publishes byte-level copy progress. A plain, unsandboxed process with no entitlements can subscribe to it with `Progress.addSubscriber(forFileURL:)`. The byte counts are exact, but there are three catches, covered in sections 1 to 3 below:
- the bytes are in `userInfo`, not in `completedUnitCount`;
- `throughput` is always nil;
- updates come at a fixed 2 Hz.

Tool: `progresswatch.swift`. Build it with `swiftc -O -swift-version 5 progresswatch.swift -o progresswatch`. Run it as `./progresswatch [--quiet] [--truth <dest path>] <path>...`.
Every copy was started with the `osascript` "duplicate" command from the brief, to `/Volumes/FinderSpeedTest/athena`. Each copy was deleted after its run. Raw logs are in `logs/run1.log` to `logs/run7-*.log`.

## 1. What the published Progress looks like

Captured from the end of run 2:

```
kind=NSProgressKindFile  fileOpKind=NSProgressFileOperationKindCopying
fileURL=/Volumes/FinderSpeedTest/athena/big_2g.bin   (the DESTINATION URL)
completedUnitCount=1000 totalUnitCount=1000           <- per-mille, NOT bytes
throughput=nil  estimatedTimeRemaining=nil            <- Finder never sets these
userInfo = {
  NSProgressByteCompletedCountKey = 2147516416        <- real byte counter
  NSProgressByteTotalCountKey     = 2147516416
  NSProgressFileCompletedCountKey = 1, NSProgressFileTotalCountKey = 1
  FileSystemItemsCompleted/Total  = 1/1   (run 3, a folder of 4 files: 5/5)
  VisibleFileSystemItemsCompleted/Total
  NSProgressFileDisplayNameKey    = big_2g.bin
  NSProgressFileURLKey            = file:///Volumes/FinderSpeedTest/athena/big_2g.bin
  FIOperationUUID                 = 00000000-0000-0000-0000-000000000000  (always zero)
}
```

- When the progress object is first published, everything is `-1` and `isIndeterminate=true`. About 5 to 200 ms later the totals arrive.
- `NSProgressByteTotalCountKey` is 32 KB larger than the file size (2147516416 vs 2147483648). This is probably extended attributes or metadata. Ignore it, or note it in the UI.
- **The speed has to be derived by us** from changes in `NSProgressByteCompletedCountKey` over time.

## 2. Accuracy, update rate, latency

| Metric | Value | Evidence |
|---|---|---|
| Byte counter update rate | **2 Hz, steady** (median interval 0.500 to 0.502 s, min 0.45, max 0.53) | run 2: `n=8 min=0.489 median=0.501 max=0.530`; runs 5 and 7 are the same |
| Accuracy versus `st_size` on disk at each update | **exact** (lag 0.0 MiB) in single-file runs; at most 8 MiB in the folder copy | run 2: `lag n=9 median=0.000 max=0.000` |
| Time from starting `osascript` to `PUBLISHED` | **~160 ms** (run 2: osascript at t=0.877, published at t=1.040) | run 2 |
| Time from `PUBLISHED` to the first real bytes | ~0.5 s (the first update tick) | run 2: `1.044 -> 0`, `1.573 -> 226 MB` |
| `UNPUBLISHED` after the copy ends | within about 0.5 s of the last update; final state is 1000/1000 and bytes = total | all runs |
| Observed speed | 460 to 930 MiB/s APFS→disk image (varies a lot, probably other agents copying at the same time) | |

Notes:
- The rate for a single 0.5 s update is noisy (674 to 1182 MiB/s within one copy, run 2). **The engine should timestamp each counter change, not use a fixed timer.** At a 250 ms tick, every other sample is 0 MiB/s (see the run-2 TICK lines). Use an EMA or a 2 to 3 s sliding window for the displayed number. Use the raw 0.5 s samples for the graph.
- Run 1 was the first Apple Event sent to Finder in the session and took 8.7 s from `osascript` to publish. That is Finder or AppleScript warming up, not the progress system. All later runs took about 0.16 s.
- A folder copy (run 3) sat at `bytes=0` for 3 s before the first bytes ("preparing"). The UI should show something like "preparing…" while bytes is 0 or -1.
- KVO on `completedUnitCount` works on the main thread and fires about once per byte update. It is per-mille, though, so a single update can theoretically fail to move it on very large copies. Polling `userInfo` every 100 ms is simple and cheap.

## 3. Granularity: per item, not per operation, and only matched against the parent folder

- **One Progress per top-level item** being copied, with `fileURL` = the destination of that item.
  - A single file gives one Progress (runs 1 and 2).
  - A folder of 4 files × 256 MB gives **one** Progress for the folder (`fileURL=.../multi`). Its bytes are summed (1,073,905,664 total) and `FileSystemItemsTotal=5`. **Nothing is published for the files inside it**: a subscription to `athena/multi/part2.bin` never fired (run 3).
  - 2 items in one Finder operation (a folder and a file) give **2 Progress objects**, both published at the same moment, copied **one after the other** (run 4: #1 finished at 2.48 s, then #2 ran from 2.48 to 3.97 s). `FIOperationUUID` is always zero, so **we cannot group them by operation**. To show one speed for the whole operation, the engine has to add up all active progresses for the same destination folder.
- **Which subscription URLs fire** (logged in runs 1 to 3):
  - ✅ the destination file URL itself;
  - ✅ the **direct parent folder** of the destination item (`/Volumes/FinderSpeedTest/athena`);
  - ✅ the destination folder URL itself, for folder copies (`athena/multi`, subscribed before it existed);
  - ❌ the grandparent or volume root (`/Volumes/FinderSpeedTest`), and ❌ `/Volumes`. **The match is not recursive.**
  - ❌ the source file and ❌ the source folder. Finder publishes only for the destination.
- **A late subscription works** (run 5). The subscriber started 1.2 s into the copy (27.7% done, 600 MB already on disk) and the handler fired **immediately** (t=0.001 s) with the live progress. After that the 2 Hz updates were normal.

**Consequence for the design:** we cannot subscribe once to "/" and see everything. The engine has to know the destination folder. Possible ways, in order of preference:
- Subscribe to a set of likely folders: Desktop, Downloads, Documents, home, the roots of every mounted volume, and the folders shown in open Finder windows (via AppleScript or AX).
- Get the destination from Finder's progress window ("Copying X to *athena*") through apollo's AX spike, then subscribe to it. Because late subscription works, attaching a few hundred ms after the copy starts is fine.
- FSEvents on the mounted volumes: a newly created item tells us its parent folder, and we subscribe to that.

## 4. Permissions and sandbox

- **Unsandboxed (Developer ID or ad-hoc) binary: no entitlements, no TCC prompt, no special permission.** Runs 1 to 5 used a plain `swiftc` binary (ad-hoc, linker-signed).
- **App Sandbox with no file access: subscribes without error but receives nothing.** Run 6: 0 progress objects during a full copy, no error. (A bare CLI with the sandbox entitlement crashes with SIGTRAP, exit 133. It must be inside an `.app` bundle with a bundle ID, see `SandboxedProgressWatch.app`.)
- **App Sandbox with read access to the subscribed folder: works.** Run 7 used `com.apple.security.temporary-exception.files.absolute-path.read-only` = `/Volumes/FinderSpeedTest/athena/` and got normal 2 Hz updates (`median=0.500`). So inside the sandbox, the gate is **file access to the subscribed URL**. That could come from a user-selected folder or a security-scoped bookmark. Arbitrary destinations would not be practical.
- **Recommendation: ship unsandboxed**, Developer ID plus notarization, not the Mac App Store.

## Files created (all in `spikes/progress/`)

- `progresswatch.swift`, `progresswatch`: the subscriber tool. It logs every 250 ms, polls bytes every 10 ms to measure the update rate, and compares against `--truth` on disk.
- `SandboxedProgressWatch.app`: the same binary in a bundle for the sandbox tests. Currently signed with the read-access exception entitlement.
- `sandbox.entitlements`, `sandbox-readaccess.entitlements`
- `logs/run1.log` … `logs/run7-sandbox-readaccess.log`, `logs/run5.osa.log`
- Nothing is left on the test volume except a `.DS_Store` that Finder created in `athena/`.

## Open questions

1. **TCC-protected destinations** (Desktop, Documents, Downloads, iCloud, network volumes): does subscribing to them need Files & Folders permission for an unsandboxed app? This was not tested, to avoid triggering prompts. The test volume is a disk image, and no prompt appeared for it. That may be because Claude Code's responsible process already holds the access.
2. Is the same NSProgress published for **Finder moves across volumes** (`fileOperationKind` moving?), **duplicate in place**, **network or SMB destinations**, **pause/cancel** from Finder's window (`isPaused`/`isCancelled` mirroring), and **copies started by drag and drop** rather than AppleScript? Drag and drop goes through the same Finder copy engine, so it should behave the same, but this is unverified.
3. Is 2 Hz fixed, or does it depend on throughput or slow media? Every run here was fast (≥ 450 MiB/s) and short (2.5 to 6 s).
4. Strategy for discovering the destination folder (section 3): this needs to be decided together with apollo's window spike.

---

## Addendum (2026-11-09, after Phase 2): cancel and TCC

### Cancelling a copy from Finder's window
I clicked the "stop progress" button through AX, using System Events. The script clicks only the row whose title contains “athena”. The source was a folder of 4 real 2 GB files.
- At unpublish, the proxy had **`isCancelled == true`** and bytes **4,798,349,312 of 8,590,098,432**. The engine reported `CANCELLED "cancelsrc" 4.8 GB/8.59 GB`.
- The files that were already complete stay at the destination (2 of 4). The partial file is removed. AppleScript `duplicate` still **returns success** after a cancel.
- **Quirk:** with a source made of **APFS clones** (`cp -c`), Finder's `NSProgressByteTotalCountKey` counted the shared blocks only once: 2.15 GB for 5 × 2 GB. Bytes reached that "total" early, so neither the bytes-vs-total check nor `isCancelled` flagged the cancel, and the engine showed FINISHED. For clone-heavy sources, both the percentage and cancel detection are unreliable.

### Does subscribing to ~/Desktop, ~/Documents or ~/Downloads need TCC? **No.**
- `tccprobe.swift` / `TCCProbe.app`: an unsandboxed app with no entitlements and an ad-hoc signature, launched with `open`.
  - It was **its own responsible process** (`ppid=1 launchd`, `responsible=<itself>`, bundle `com.finderspeed.athena.tccprobe`), so it did not inherit Terminal's or Claude Code's TCC grants.
- The progresses came from a publisher run in this shell, for files in each folder that don't exist (nothing was written).
- The fresh app **received all 4** (Desktop, Documents, Downloads and the control) with live byte updates.
- `log show` for subsystem `com.apple.TCC` captured activity in that window (33 lines, including another process's AUTHREQ) but **zero requests from the probe**. No prompt was shown.
- Caveats:
  - The publisher was my CLI, not Finder. The gate is on the subscriber side: the sandboxed build without file access got nothing, even for Finder's own progress (run 6). It is very likely the same for Finder.
  - The subscriber also never lists or reads those folders. If the app ever does (for example, to resolve folder names), that WILL be subject to TCC.
- Logs: `logs/tcc-subA-inherited.log`, `logs/tcc-subB-fresh.log`, `logs/tcc-pub*.log`.
