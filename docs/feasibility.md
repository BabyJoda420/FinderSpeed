# Feasibility Analysis: Finder Copy Speed & Graph

## Overview & User Question

**Can macOS Finder's native file-copy progress window display a live transfer speed readout and an expandable speed-over-time graph (similar to the Windows Explorer copy dialog)?**

While Finder natively shows bytes copied and an estimated time remaining, it does not expose instantaneous transfer throughput (MB/s or GB/s) or historical transfer rate graphs. This document evaluates how to deliver that experience on modern macOS (macOS 27.0.1, Apple Silicon arm64, SIP enabled).

---

## Why Patching Finder Directly Was Rejected

Modifying Finder's built-in progress window in-place requires runtime code injection (e.g., `DYLD_INSERT_LIBRARIES`, Mach task injection, or method swizzling inside `/System/Library/CoreServices/Finder.app`). We explicitly rejected this approach for three reasons:

1. **System Integrity Protection (SIP):** Finder is a system-protected binary signed by Apple with hardened runtime and restricted entitlements. Injecting code into Finder requires disabling SIP (`csrutil disable` from Recovery OS), which is enabled on the target machine and unacceptable for a clean user experience.
2. **Code-Signing & Pointer Authentication (arm64e):** Apple Silicon enforces strict code-signing and PAC/arm64e protections on system binaries, requiring boot-arg overrides (`amfi_get_out_of_my_way=1`) that weaken system security.
3. **Fragility Across macOS Updates:** Any patch relying on private Finder view hierarchies or internal symbols breaks across minor and major macOS updates.

---

## Chosen Architecture: Native Companion App

Instead of injecting code into Finder, **finder-speed** is designed as a lightweight, native macOS companion application built with Swift 6.4, AppKit, and SwiftUI:

- **Menu Bar Presence:** Runs unintrusively as a background/menu bar utility without requiring SIP to be disabled.
- **Window Detection & Tracking:** Detects when Finder opens its native copy-progress window and tracks its position and lifecycle in real time.
- **Attached Native-Look Panel:** Positions a borderless/HUD-style companion panel directly beneath Finder's copy window so that it moves seamlessly with the window and feels like a native extension.
- **Live Readout & Expandable Graph:** Always displays the current transfer speed (e.g., `412 MB/s`), with a collapsible/expandable speed-over-time sparkline/area graph underneath.

---

## Spike Results

Three technical spikes are currently underway to validate data acquisition and window tracking mechanisms, using a 2 GB test payload (`testdata/big_2g.bin`) copied to `/Volumes/FinderSpeedTest`.

### Spike A: `NSProgress` Subscription (`spikes/progress/` — Athena)

- **Objective:** Determine whether subscribing to Finder's published file-operation progress via `Progress.addSubscriber(forFileURL:withPublishingHandler:)` provides accurate, high-frequency byte counts and throughput metrics during Finder copies.
- **Does it work?** **YES.** On macOS 27.0.1, Finder publishes exact byte-level copy progress (`kind = NSProgressKindFile`, `fileOpKind = NSProgressFileOperationKindCopying`) that any plain, unsandboxed process can subscribe to.
- **Key Numbers & Update Behavior:**
  - **Where the bytes live:** `completedUnitCount` / `totalUnitCount` are always per-mille (`0`–`1000`), not bytes, and `throughput` / `estimatedTimeRemaining` are always `nil`. The actual byte counters live in `userInfo` under `NSProgressByteCompletedCountKey` and `NSProgressByteTotalCountKey` (which includes ~32 KB of metadata/xattrs overhead, e.g., `2,147,516,416` vs `2,147,483,648` bytes). Throughput must be computed by differentiating `NSProgressByteCompletedCountKey` over time.
  - **Update cadence:** Steady **2 Hz** (median interval `0.500`–`0.502 s`, min `0.489 s`, max `0.530 s`). Because updates arrive every ~500 ms, the engine must timestamp actual counter changes rather than differentiating on a fixed fast timer; smoothing (EMA or 2–3 s window) is recommended for the numeric readout while raw 0.5 s deltas drive the graph.
  - **Accuracy:** Exact (`0.0 MiB` lag vs. `st_size` on disk for single files; `≤ 8 MiB` lag for multi-file folder copies).
  - **Startup & teardown latency:** Published ~`160 ms` after the copy starts (`isIndeterminate = true` with `-1` counts for the first `5`–`200 ms`; folder copies may stay at `bytes = 0` for ~3 s while preparing). Unpublished within ~`0.5 s` of completion after reaching `1000/1000`.
- **Granularity & Subscription Matching Rules:**
  - **Per top-level item, not per operation:** Copying a single file yields 1 `Progress`; copying a folder of 4 files yields 1 aggregated `Progress` for the folder (`FileSystemItemsTotal = 5`, no child `Progress` published for inner files); copying 2 top-level items in a single Finder action publishes 2 simultaneous `Progress` objects that transfer sequentially. Because `FIOperationUUID` is always all-zeros (`00000000-0000-0000-0000-000000000000`), the engine must group and sum active `Progress` objects by destination parent folder.
  - **Non-recursive parent/item matching:** Subscriptions fire **only** when subscribed to the exact destination item URL or the **direct parent folder** of the destination item (e.g., `/Volumes/FinderSpeedTest/athena`). Subscribing to grandparents, volume roots (`/Volumes/FinderSpeedTest`), `/Volumes`, or source URLs does **not** fire.
  - **Late subscriptions work:** Subscribing mid-copy (tested at 27.7% / 600 MB transferred) invokes the publishing handler within `1 ms` with live progress, followed by normal 2 Hz updates. Thus, the engine can dynamically subscribe to destination folders discovered via Finder windows, Accessibility, or FSEvents after a copy begins.
- **Cancel Detection & APFS-Clone Total Quirk (Phase 2 Addendum):**
  - **Cancel detection:** Clicking the `"stop progress"` button in Finder's progress window sets `isCancelled == true` on the `Progress` proxy at unpublish time with `bytesCompleted < bytesTotal` (e.g., `4.80 GB / 8.59 GB`), allowing the Engine to reliably flag cancelled transfers on real files.
  - **APFS-clone folder total quirk:** When copying a folder made of APFS clones (`cp -c`), Finder's `NSProgressByteTotalCountKey` counts the shared blocks only once (e.g., reporting `2.15 GB` total for a folder containing `5 × 2 GB` clones = `10.74 GB` logical size) and stops incrementing `NSProgressByteCompletedCountKey` at the first file's size (`2.15 GB`). By contrast, Finder's progress window text (`Row.statusBytesCompleted`) continues counting up to `10.74 GB`. For clone-heavy folder copies, `NSProgress` percentage and cancel detection are unreliable on their own, so the Engine automatically switches to `noteWindowRow` byte counts if the window text leads `NSProgress` for `≥ 1.5 s`.
- **Permissions & Sandbox Findings (including TCC Verification):**
  - **Unsandboxed binary (Developer ID or ad-hoc):** Requires **zero entitlements and triggers no TCC prompts**.
  - **Verified no TCC needed for protected folders (`~/Desktop`, `~/Documents`, `~/Downloads`):** Tested with a standalone, ad-hoc signed app bundle (`TCCProbe.app`, launched via `open` with `ppid = 1` / `launchd` so it was its own responsible process and inherited no Terminal grants). Subscribing to `~/Desktop`, `~/Documents`, and `~/Downloads` received live byte updates immediately and generated **zero TCC authorization requests** in `com.apple.TCC` system logs—provided the app only subscribes to the URLs and does not enumerate directory contents.
  - **App Sandbox without file access:** Subscribes silently without error, but receives **0 events**.
  - **App Sandbox with read access to destination folder:** Works normally at 2 Hz when granted read access (e.g., via security-scoped bookmarks or read-only path exceptions). Because arbitrary destination access is impractical in the sandbox, we will distribute the app **unsandboxed** (Developer ID + notarization).
- **Artifacts:** Prototype and logs in [spikes/progress/REPORT.md](file:///Users/mauriziolol/Projects/finder-speed/spikes/progress/REPORT.md) and `spikes/progress/progresswatch.swift`.

### Spike B: Per-Process I/O Throughput via `proc_pid_rusage` (`spikes/rusage/` — Thor)

- **Objective:** Evaluate reading per-process disk I/O counters (`ri_diskio_bytesread` / `ri_diskio_byteswritten` via `proc_pid_rusage`) on `Finder` and `DesktopServicesHelper` processes to compute real-time transfer throughput.
- **Does it work?** **No (not viable without root for general drives; only works for user-mounted disk images).**
- **Root Cause & Evidence:**
  - **`Finder` (`uid = 502`) performs zero copy I/O:** During a 2 GiB (`2,147,483,648` B) file copy completed in `3.114 s` (`689.68 MB/s` average), `Finder` stayed at `R = 0 B/s, W = 0 B/s` (apart from an occasional 8 KB `.DS_Store` write).
  - **`DesktopServicesHelper` and `DesktopServicesScriptingHelper` run as `root` (`uid = 0`):** Finder delegates actual file copy I/O to system LaunchDaemons (`/System/Library/LaunchDaemons/com.apple.DesktopServicesHelper.plist` and `com.apple.DesktopServicesScriptingHelper.plist`), which `launchd` spawns as `uid = 0, ruid = 0`. Calling `proc_pid_rusage(pid, RUSAGE_INFO_V4, ...)` or `proc_pidinfo(PROC_PIDTASKINFO)` on them from an unprivileged user process (`uid = 502`) **fails with `errno = 1` (`EPERM: Operation not permitted`)**, as XNU's `bsd/kern/proc_info.c` requires either `euid == 0` or matching UIDs.
  - **Disk image exception (`diskimages-helper`, `uid = 502`):** When copying to a user-mounted disk image (like `/Volumes/FinderSpeedTest`), `diskimages-helper` runs under the user's UID (`502`) and records the backing-store writes (`2.20 GB` written, matching the `2.15 GB` file within ~2.3%, peaking at `962 MB/s`). However, `diskimages-helper` is not involved when copying to physical USB/Thunderbolt drives, SD cards, internal volumes, or network shares.
- **Permissions Needed:** Requires **`root` (`euid == 0`)** (e.g., a privileged `SMJobBless` / `SMAppService` LaunchDaemon helper) to inspect `DesktopServicesHelper`. Since we rule out requiring root/`sudo`, `proc_pid_rusage` is rejected as our data source.
- **Artifacts:** Prototype and logs in [spikes/rusage/REPORT.md](file:///Users/mauriziolol/Projects/finder-speed/spikes/rusage/REPORT.md) and `spikes/rusage/rusage_monitor.swift`.

### Spike C: Finder Copy Window Detection & Tracking (`spikes/window/` — Apollo)

- **Objective:** Compare `CGWindowListCopyWindowInfo` and the macOS Accessibility API (`AXUIElement`) for reliably identifying Finder's copy-progress window and tracking its frame/movement at interactive frame rates.
- **Does it work?** **YES (via Accessibility).** With Accessibility permission granted, an `AXObserver` on Finder reliably detects the copy-progress window, tracks its movement/resize/close events, and reads its static text rows. Without Accessibility, `CGWindowListCopyWindowInfo` can only guess which window is the progress window based on fragile geometry heuristics.
- **Identification via `AXIdentifier == "Progress"`:**
  - Finder's copy window exposes `AXRole = AXWindow`, `AXSubrole = AXStandardWindow`, and a non-localized **`AXIdentifier == "Progress"`** (in contrast to standard Finder browser windows, which expose `AXSubrole = AXDialog` and `AXIdentifier = "FinderWindow"` on macOS 27).
  - By contrast, `CGWindowListCopyWindowInfo` sets `kCGWindowName = nil` for all Finder windows unless Screen Recording permission is granted (`CGPreflightScreenCaptureAccess()`), and uses `layer = 0` for both browser and progress windows. Relying on CG alone would require fragile size heuristics (`width == 404`, `height == 88 + 61 * n` rows).
  - Using `AXObserver` on Finder's PID provides low-overhead, event-driven notifications: `AXWindowCreated`, `AXMoved`, `AXResized` (when concurrent copy rows are stacked: `88 px` for 1 row, `149 px` for 2 rows), `AXValueChanged` (~500 ms cadence), and `AXUIElementDestroyed` (~150 ms after completion), avoiding the `15–35 ms` cost of full AX tree polling.
  - CG window IDs can be correlated via `_AXUIElementGetWindow` or by matching global top-left bounds between AX and `CGWindowListCopyWindowInfo`.
- **Timing (~3 s Appearance Delay):**
  - Finder **only creates and displays its copy-progress window ~`3.1–3.3 s` after a copy starts**.
  - Consequently, fast copies that complete in under ~3 seconds (such as a single 2 GB file transferring at ~700 MB/s in `3.0 s`) never spawn a Finder progress window to attach a panel to. (However, `NSProgress` still fires within ~160 ms, so the menu bar status item can still reflect short transfers if desired.)
- **Permissions Needed:**
  - **Accessibility (`AXIsProcessTrusted`):** **Required** for reliable window identification (`AXIdentifier == "Progress"`), event-driven frame tracking (`AXMoved` / `AXResized` / `AXUIElementDestroyed`), and reading progress text.
  - **Screen Recording:** **Not needed** when using Accessibility (only required if attempting to read `kCGWindowName` via `CGWindowListCopyWindowInfo`).
  - **Automation (Finder AppleScript):** Optional / used for destination folder hints and AppleScript fallback (`tell application "Finder" to get {name, class, bounds} of every window`, ~0.4 s per call).
- **Progress-Text Fallback (`AXStaticText`):**
  - Each row inside the progress window's `AXScrollArea` exposes two `AXStaticText` elements: an operation header (e.g., `"Copying 6 items to “apollo”"`) and a byte progress string (`"947.9 MB of 2.15 GB – About 5 seconds"`), updated every ~500 ms with `0.01 GB` (~10 MB) resolution.
  - While differentiating this text yields usable throughput numbers (~773 MB/s average across a 10.74 GB copy), it has notable caveats: for folder copies Finder reports `"X of X"` (total counts up alongside completed bytes), the string is localized, and the row title mutates as remaining item counts decrement. Thus, `AXStaticText` serves best as a **fallback speed source and destination-name parser**, while `NSProgress` remains the primary telemetry source.
- **Artifacts:** Prototypes and logs in [spikes/window/REPORT.md](file:///Users/mauriziolol/Projects/finder-speed/spikes/window/REPORT.md), `spikes/window/FinderWindowProbe.swift`, and `spikes/window/FinderAXObserve.swift`.

---

## Verdict & Chosen Design

Based on the completed spikes, the companion-app architecture is **fully feasible** without disabling SIP or injecting code into Finder:

1. **Telemetry Data Source (`NSProgress`):** We use `Progress.addSubscriber(forFileURL:withPublishingHandler:)` to read exact byte progress (`NSProgressByteCompletedCountKey` / `NSProgressByteTotalCountKey`) at Finder's native **2 Hz** cadence. Because `NSProgress` subscriptions require knowing the destination item's direct parent folder (and support immediate ~1 ms late attachment mid-copy), the engine watches common destinations, mounted volume roots, open Finder windows (via AppleScript/Automation), and newly detected destinations from the copy window itself.
2. **Window Detection & Tracking (`AXObserver`):** We register an `AXObserver` on Finder's PID (`com.apple.finder`) and match windows with `AXIdentifier == "Progress"`. Event notifications (`AXWindowCreated`, `AXMoved`, `AXResized`, `AXUIElementDestroyed`) drive panel lifecycle and positioning, with parsed `AXStaticText` providing destination folder hints and a fallback speed source.
3. **Attached Companion Panel (`NSPanel` + SwiftUI):** When Finder's copy window appears (for copies lasting longer than ~3 s), a borderless/HUD-style `NSPanel` anchors directly below Finder's progress window (`width = 404 px`), moving in lockstep with it and hosting the always-visible live speed readout and collapsible speed-over-time graph.
