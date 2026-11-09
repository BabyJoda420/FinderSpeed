# Testing Guide: finder-speed

`finder-speed` combines a fast, deterministic Swift Testing suite (`swift test`) for the Engine and fallback logic with a real Finder file-copy harness (`scripts/finder-copy-test.sh`) and CLI diagnostic modes.

---

## 1. Unit & Regression Test Suite (`swift test`)

Run the package test suite from the repository root:

```bash
swift test
```

The suite contains **31 tests across 4 `@Suite` groups** in `Tests/FinderSpeedTests/`, using fake `Progress` objects and a deterministic `FakeClock` ([TestSupport.swift](file:///Users/mauriziolol/Projects/finder-speed/Tests/FinderSpeedTests/TestSupport.swift)) with `autoPoll = false` so tests run in milliseconds without timers or Finder side effects:

| Suite | File | Tests | What It Verifies |
|---|---|---|---|
| **`SpeedMath`** | [TransferMonitorTests.swift](file:///Users/mauriziolol/Projects/finder-speed/Tests/FinderSpeedTests/TransferMonitorTests.swift#L13-L31) | 2 | Continuous-time EMA smoothing ($\alpha = 1 - e^{-\Delta t / \tau}$), zero/negative $\Delta t$ clamping, and non-negative segment byte rates. |
| **`TransferMonitor`** | [TransferMonitorTests.swift](file:///Users/mauriziolol/Projects/finder-speed/Tests/FinderSpeedTests/TransferMonitorTests.swift#L35-L222) | 13 | `"Preparing…"` state transitions, first-tick capping after long folder preparation, EMA step response, stall decay (`0 B/s` emission after `2.0 s`), multi-item parent-folder grouping, separate destination isolation, duplicate subscription deduplication, ignoring non-Finder `Progress` objects (e.g., media players), `finishedLinger` (`4.0 s`) with average speed, cancel detection (`bytes < total` and `progress.cancel()`), sample ring-buffer cap (`maxSamples = 2400`), and spike-free late attachment mid-copy. |
| **`Window fallback`** | [WindowFallbackTests.swift](file:///Users/mauriziolol/Projects/finder-speed/Tests/FinderSpeedTests/WindowFallbackTests.swift#L28-L141) | 5 | `noteWindowRow(...)` behavior: staying on `NSProgress` during normal copies even when 2 Hz ticks are out of phase, switching to window byte counts (`usesWindowFallback`) when `NSProgress` freezes on APFS-clone folders, replacing undercounted totals or clearing unknown totals to `0`, decaying on window stalls, and matching rows by URL → folder name → sole active transfer. |
| **`Engine review fixes`** | [ReviewFixTests.swift](file:///Users/mauriziolol/Projects/finder-speed/Tests/FinderSpeedTests/ReviewFixTests.swift#L9-L216) | 11 | Regression tests for Apollo's engine review ([spikes/window/ENGINE_REVIEW.md](file:///Users/mauriziolol/Projects/finder-speed/spikes/window/ENGINE_REVIEW.md)) and Athena's fixes ([spikes/progress/REVIEW_FIXES.md](file:///Users/mauriziolol/Projects/finder-speed/spikes/progress/REVIEW_FIXES.md)): folding short segments (`< 0.3 s`) instead of spiking, omitting final completing-update catch-up bursts from the graph, accurate timing of folded first segments after preparation, relative window tolerance (`max(20 MB, 2% × windowBytes)`) on >100 GB copies, cancel detection in window-fallback mode, quiet transfer removal or duplicate promotion when `unwatch(folder:)` is called mid-copy (including a real in-process `Progress` subscription test), resetting EMA on revived transfers (`reviveWindow`), and `stop()` cleanup before `start()`. |

---

## 2. End-to-End Real Finder Copy Script (`scripts/finder-copy-test.sh`)

Because copying a file to the same APFS volume performs an instant metadata clone (`clonefile`) with no real I/O, and copying APFS-cloned files triggers Finder's `NSProgress` shared-block undercounting quirk, [scripts/finder-copy-test.sh](file:///Users/mauriziolol/Projects/finder-speed/scripts/finder-copy-test.sh) generates **true random bytes via `/dev/urandom`** and copies them through Finder's AppleScript interface to `/Volumes/FinderSpeedTest/<subdir>`.

### Usage & Options

```bash
scripts/finder-copy-test.sh [options]
```

| Flag | Default | Description |
|---|---|---|
| `-m, --mode file\|folder` | `file` | Copy a single large file (`real_<MB>m.bin`) or a folder of `N` files (`real_<N>x<MB>m/file_NN.bin`). |
| `-s, --size MB` | `2048` (`file`) / `1024` (`folder`) | Size of each file in MiB. |
| `-n, --count N` | `3` | Number of files when `--mode folder` is used. |
| `-d, --dest SUBDIR` | `copytest` | Destination subfolder inside `/Volumes/FinderSpeedTest`. |
| `-l, --loops N` | `1` | Repeat the copy `N` times sequentially. |
| `-b, --background` | off | Generate source data in the foreground, then run the Finder copy in the background and print the log file path immediately. Ideal for observing `FinderSpeed.app` or `--engine-debug`. |
| `-k, --keep` | off | Keep the destination copy on `/Volumes/FinderSpeedTest` after completion (by default it is deleted automatically, including on `Ctrl-C`). |
| `-r, --regenerate` | off | Regenerate the random source data even if a `.complete` marker already exists. |
| `--max-total-gb G` | `8` | Maximum combined disk budget (`2 × payload`, source + destination) in GiB. Default `8` GiB allows payloads up to `4 GiB`. |
| `--clean` | off | Delete all generated source sets under `testdata/finder-copy-test/` and exit. |
| `-h, --help` | — | Print usage summary. |

### How It Works

1. **Disk Budget & Free-Space Checks:** Verifies that `2 × payload` fits within `--max-total-gb` and checks `df -m` on both the internal disk (`payload + 1024 MiB` required) and `/Volumes/FinderSpeedTest` (`payload + 512 MiB` required) before writing. Only one generated source set is kept in `testdata/finder-copy-test/` at a time.
2. **Dual Timing Measurements:**
   - **Wall-clock (`osascript`):** Total elapsed time of the `tell application "Finder" to duplicate … with replacing` command.
   - **First byte → done (`true avg`):** Uses a `20 ms` background watcher to detect the exact timestamp when the destination item is created on `/Volumes/FinderSpeedTest`, isolating actual transfer time from Apple Event / Finder warm-up latency.
   - Prints throughput in both **decimal `MB/s`** ($10^6\text{ B/s}$, matching Finder and FinderSpeed) and **binary `MiB/s`** ($2^{20}\text{ B/s}$).

### Example Workflows

**Run a 4 GiB multi-file folder copy in the background while watching the headless Engine logger:**

```bash
scripts/finder-copy-test.sh -m folder -n 4 -s 1024 -b
.build/release/FinderSpeed --engine-debug /Volumes/FinderSpeedTest/copytest
```

**Clean up cached random source data when finished:**

```bash
scripts/finder-copy-test.sh --clean
```

---

## 3. UI Snapshot & Demo Verification

- **Interactive Demo Window:** Launch `build/FinderSpeed.app`, click the speedometer menu bar icon, and choose **Show Demo Panel** (`⌘D`) to inspect `SpeedPanelView` populated with `DemoTransfers` without starting a Finder copy.
- **Automated PNG Snapshots (`--render-demo`):**
  ```bash
  .build/release/FinderSpeed --render-demo build/snapshots
  ```
  Renders 4 Retina (`2x`, `404 pt` wide) PNG files (`panel-light-collapsed.png`, `panel-light-expanded.png`, `panel-dark-collapsed.png`, `panel-dark-expanded.png`) and restores the user's `graphExpanded` default afterwards.
