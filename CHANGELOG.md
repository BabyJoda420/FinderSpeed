# Changelog

All notable changes to **finder-speed** will be documented in this file.

## [Unreleased]

## [0.1.1-diag] - 2026-11-09 (pre-release)

- **BUG-001 fixes & diagnostic pre-release:**
  - **Window stability (`apollo`, `BUG-001.md`):** Moved all AX reads off the main thread to prevent UI lockups and freezing fades during busy operations. Transient AX timeouts and errors are no longer treated as "window gone", eliminating panel flapping. Replaced main-thread alpha animation with a stall-proof fade. Split the cap band into distinct corner and strip subviews to prevent full-width band visual glitches. Added Retina-scale chrome rendering.
  - **Engine cadence adaptation (`athena`, `BUG-001-engine.md`):** TransferMonitor now learns Finder's real byte counter update interval per transfer (adapting to 8 MiB granular updates on slow drives or USB disks) so slow transfers no longer decay to near 0 KB/s. Real calculation for average and peak throughput.
  - **UI & Graph (`thor`):** Restored the speed graph to a full-width time axis.
  - **Packaging & Assets (`zeus`):** Added the new Icon Composer macOS application icon and the drag-to-Applications DMG installer (`FinderSpeed.dmg`).
  - **Diagnostics:** Enabled diagnostic logging by default in diagnostic builds, writing to `~/Library/Logs/FinderSpeed.log`.

## [0.1.0] - 2026-11-09

- **First test release (v0.1.0):**
  - Distributed as a universal binary (`arm64` + `x86_64`) supporting macOS 14+ on Apple Silicon and Intel Macs.
  - Added DMG installer (`FinderSpeed.dmg`) with drag-to-Applications layout.
  - Added "Launch at Login" menu bar option for automatic startup.
  - Released under the MIT license.

### 2026-11-09

- **Final polish (zeus; written by the leader because the documentation agent hit its usage quota):**
  - **Engine (`athena`, `spikes/progress/DUP_ROW.md`):** The "duplicate row" seen during two concurrent copies was not an engine duplicate. It was the same transfer drawn at two moments during the 1 → 2 row animation. The engine now sets `Transfer.isMeasuring` for about 1 s after attaching to a running copy, instead of reporting 0 KB/s. Opt-in event log: `FINDERSPEED_ENGINE_LOG=1`. Added `DupRowReplayTests.swift`.
  - **UI (`thor`):** Shows "Measuring…" while `isMeasuring`. Rows have stable IDs, one opacity transition, and one animated layout change. Brighter accent fill on the graph.
  - **App (`zeus`):** Panel rows follow the order of Finder's rows (`FinderRowOrder`). Window rows that go to the same destination are summed before `noteWindowRow`.
  - **Tooling:** `scripts/capture-copy.sh` no longer uses `screencapture -o`, which stripped Finder's own outline and shadow and showed a false seam. `docs/images/after.png` was refreshed from the final release build. `swift test` passes 43 tests in 7 suites.

- **Phase 3 visual integration completed — "One Continuous Window" (`Sources/FinderSpeed/Window/`, `Sources/FinderSpeed/UI/`, `Sources/FinderSpeed/Engine/`, `docs/visual-design.md`, `docs/images/`):**
  - **Window (`apollo`, `spikes/window/PHASE3.md`):** Replaced the single-panel chrome with a two-window architecture (`hasShadow = false`): a click-through Chrome Window rendering a 24-row cap band, `1 px` outer ring, `1 px` inner rim, and complementary active/inactive window shadow (`0.46 ms`/frame), plus a non-activating Body Window anchored at Finder's exact bottom edge. Added `FinderBackgroundSampler` (`ScreenCaptureKit` `8 × 8` margin sampler when Screen Recording is already granted, never prompting, achieving `0` RGB diff across 1-row and 2-row Finder windows; `.windowBackground` fallback within `~3` RGB units otherwise). Fixed the `1 px` startup panel flash (`minimumContentHeight = 8`).
  - **UI (`thor`):** Aligned `TransferSpeedRow` and `SpeedGraphView` to Finder's exact columns (`x = 17` gauge icon, `x = 61, w = 311` `13 pt` speed + `11 pt` average/peak text and borderless `64 pt` graph, `cx = 385.5` chevron), removed duplicate byte/ETA strings and the top divider, and mapped the graph's X-axis to `0...1` fraction completed so the curve aligns with Finder's progress bar above it.
  - **Engine (`athena`, `spikes/progress/SPIKE_719.md`):** Eliminated delivery-lag and inner-file catch-up graph spikes via `RateHistory` (`medianWidth = 5` rolling median filter, `rawRateWindow = 0.6 s` windowed rates, non-resetting stall history, and post-preparing baseline anchoring). Added `SpikeReplayTests.swift` (`41/41` tests passing across 6 suites).
  - **Documentation (`saga`):** Added `docs/images/before.png` and `docs/images/after.png`, completed `docs/visual-design.md`, and updated `README.md` with the new screenshot, Screen Recording optional permission notes, and updated limitations.
- **Phase 3 visual integration started (`docs/visual-design.md`, `scripts/capture-copy.sh`, `scripts/tools/`):**
  - Documented the "stuck-on" visual defects from `build/captures/before/shot-2.png` and `seam-zoom.png`, the `axresize` experiment proving Finder's `"Progress"` window ignores `AXSize` height changes (staying fixed at `88 px`), the measured Finder geometry and shadow alpha profile table, the "one continuous window" design (16 px cap band, custom outline/shadow, pixel-matched background, and `x = 17 / 61 / 385.5` column alignment), and the visual capture/inspection tools (`scripts/capture-copy.sh`, `winlist`, `axframes`, `axresize`).
- **App integrated & packaged (`Sources/FinderSpeed/App/`, `Sources/FinderSpeed/UI/`, `scripts/build-app.sh`):**
  - Built the SwiftUI companion panel UI (`SpeedPanelView`, `TransferSpeedRow`, `SpeedGraphView`, `SpeedFormatting`, `DemoTransfers`, `UISnapshot`) with live decimal throughput, ETA, collapsible Swift Charts speed-over-time graph, and `--render-demo` 2x Retina snapshot rendering.
  - Wired `Engine`, `Window`, and `UI` together in `AppDelegate` and `PanelWiring` with a live `NSStatusItem` menu bar speedometer readout (covering copies under ~3 s before Finder's progress window appears), per-destination row byte summing for `noteWindowRow`, and an interactive **Show Demo Panel** (`⌘D`).
  - Added `scripts/build-app.sh` to package and sign `build/FinderSpeed.app` with a stable designated requirement (`identifier "com.mauriziolol.finderspeed"`) so Accessibility permission persists across rebuilds.
- **Engine review, fixes & copy-test harness (`spikes/window/ENGINE_REVIEW.md`, `spikes/progress/REVIEW_FIXES.md`, `scripts/finder-copy-test.sh`):**
  - Added `scripts/finder-copy-test.sh` to benchmark real (non-clone `/dev/urandom`) Finder file and folder copies with disk-budget guards and dual wall-clock / first-byte timing.
  - Hardened `TransferMonitor` against short-segment and completion-burst graph spikes, relative window-fallback tolerances on >100 GB copies (`max(20 MB, 2% × windowBytes)`), fallback-mode cancellation, mid-copy `unwatch` duplicate promotion, revived-transfer EMA resets, and `isolated deinit` cleanup (31/31 tests passing across 4 suites in `swift test`).
- **Documentation completed (`README.md`, `docs/testing.md`, `docs/architecture.md`, `docs/feasibility.md`):**
  - Wrote full user and developer documentation covering screenshots, build/run steps, permissions, CLI flags (`--engine-debug`, `--render-demo`), unit and real-copy testing (`docs/testing.md`), and complete module architecture.
- **Spike B completed (`spikes/rusage/`):** Confirmed that per-process I/O monitoring via `proc_pid_rusage` is not viable without root (`euid == 0`): `Finder` performs zero copy I/O itself, while `DesktopServicesHelper` and `DesktopServicesScriptingHelper` run as `root` (`uid = 0`) and return `EPERM (errno = 1)` to unprivileged processes (`docs/feasibility.md`).
- **Engine & Window Phase 2 details and known limitations documented:** Updated `docs/feasibility.md` and `docs/architecture.md` with Athena's cancel/TCC/APFS-clone addendum (no TCC prompt for `~/Desktop`, `~/Documents`, `~/Downloads` subscriptions; `isCancelled` detection; `noteWindowRow` fallback for APFS-clone folder undercounting), Apollo's Phase 2 Window module public API (`FinderProgressWindowObserver`, `FinderDestinationHints`, `SpeedPanelController`, `AccessibilityPermission`), and the `Known limitations` section.
- **Spike C completed (`spikes/window/`):** Confirmed that an `AXObserver` on Finder reliably detects the copy progress window via `AXIdentifier == "Progress"` (appearing ~3.1–3.3 s into a copy), tracks `AXMoved` / `AXResized` / `AXUIElementDestroyed` events, and extracts progress/destination text (`docs/feasibility.md`).
- **Final design verdict & Window architecture documented:** Added the final `Verdict & chosen design` section to `docs/feasibility.md` (`NSProgress` + `AXObserver` + attached `NSPanel`) and updated `docs/architecture.md` with the Window module design (`FinderProgressWindowObserver`, destination hints via AppleScript, `SpeedPanelController`) and required macOS permissions (Accessibility required; Automation for Finder for destination hints).
- **Spike A completed (`spikes/progress/`):** Confirmed that unsandboxed `Progress.addSubscriber(forFileURL:)` receives exact byte-level Finder copy progress at a steady 2 Hz via `userInfo[NSProgressByteCompletedCountKey]`, with zero entitlements and working late-subscription support (`docs/feasibility.md`).
- **Phase 2 architecture defined:** Documented the `FinderSpeed` Swift package structure (`Engine`, `Window`, `UI`, `App`), module ownership, and the `@MainActor TransferMonitor` / `Transfer` contract (`docs/architecture.md`).
- **Project setup:** Initialized repository layout (`docs/`, `spikes/`, `testdata/`) and team brief (`BRIEF.md`).
- **Feasibility analysis:** Documented the decision to build a SIP-compatible native companion app rather than injecting code into Finder (`docs/feasibility.md`).
- **Spikes started:** Launched three parallel feasibility spikes:
  - **Spike A (`spikes/progress/`):** `NSProgress` subscription for Finder file copies.
  - **Spike B (`spikes/rusage/`):** Per-process I/O counters via `proc_pid_rusage` on `Finder` and `DesktopServicesHelper`.
  - **Spike C (`spikes/window/`):** Finder copy window discovery and frame tracking via `CGWindowListCopyWindowInfo` and `AXUIElement`.
