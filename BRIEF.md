# finder-speed: Team Brief (read this first)

## The goal

The user wants the **transfer speed to be visible while Finder copies files on macOS**, like Windows' copy dialog does. The speed number should always be shown. Under it there should be a **speed-over-time graph that can be expanded and collapsed**.

## Feasibility decision (from Zeus, the leader)

- **Patching Finder's own progress window** needs code injection into Finder. That means turning off SIP (it is enabled on this Mac) plus code-signing protections, and it breaks with every macOS update. **We are not doing this.**
- **What we are doing:** a small native **companion app** written in Swift with AppKit or SwiftUI. It runs in the menu bar, detects Finder's copy-progress window, and **attaches a panel to it that looks native**: it sits right below the window and moves with it. The panel shows the live speed, and the graph expands and collapses.

## The open questions (the spike phase answers them)

1. **Where does the speed data come from?**
   - Finder publishes `NSProgress` for file operations (this is what draws the progress bars on file icons). Can we subscribe to it with `Progress.addSubscriber(forFileURL:withPublishingHandler:)` and get byte counts and throughput?
   - Or can we read per-process disk input/output counters with `proc_pid_rusage` on Finder and `DesktopServicesHelper`?
2. **How do we find and follow Finder's copy window?** Options are `CGWindowListCopyWindowInfo` and the accessibility API (`AXUIElement`). What permissions does each need?

## Environment

- **System:** macOS 27.0.1 on Apple Silicon (arm64), Xcode 27, Swift 6.4, SIP enabled.
- **Project root:** `/Users/mauriziolol/Projects/finder-speed`
  - `spikes/progress/`, `spikes/rusage/`, `spikes/window/`: one spike per agent
  - `docs/`: owned by **saga** only
  - `testdata/big_2g.bin`: a 2 GB random file to use as the copy source
- **Test destination volume:** `/Volumes/FinderSpeedTest`, which has one folder per agent: `athena/`, `thor/`, `apollo/`.
  - Always copy **to this separate volume**. A copy on the same APFS disk is an instant clone with no real transfer.
  - Delete your copy after each run so the volume doesn't fill up.
- **Starting a real Finder copy from the shell** (this shows Finder's native progress window):
  ```bash
  osascript -e 'tell application "Finder" to duplicate (POSIX file "/Users/mauriziolol/Projects/finder-speed/testdata/big_2g.bin" as alias) to (POSIX file "/Volumes/FinderSpeedTest/<yourname>" as alias) with replacing'
  ```
  The first time, macOS may show a permission dialog for controlling Finder. The user or Zeus will click it.

## The team (mythology names)

| Name | Kind | Role |
|---|---|---|
| **zeus** | Claude Code | Leader: coordinates, integrates, architecture |
| **athena** | Claude Code | Spike A: NSProgress subscription. Then the data/engine layer |
| **apollo** | Claude Code | Spike C: finding and tracking the Finder window. Then the attached panel |
| **thor** | agy | Spike B: per-process input/output throughput. Then the graph UI |
| **saga** | agy | Documentation: owns `docs/`, `README.md` and `CHANGELOG.md` |

## Rules for everyone

- Only edit files in your own folder. Never edit `docs/` or `README.md`; that's Saga's job.
- Don't commit, don't push, don't install system-wide tools, and don't change system settings.
- Don't use `sudo`.
- When you finish, reply with a **short report**:
  - **Does it work?** yes, no, or partly.
  - **The evidence:** actual numbers or log lines.
  - **Permissions needed.**
  - **Files you created.**
  - **Open questions.**
- If the report is long, write it to `spikes/<area>/REPORT.md` and reply with the path.

## Phase 2: Build (added by Zeus once spike A succeeded)

This is a Swift package at the project root (`Package.swift`) with a single executable target `FinderSpeed`. Build it with `swift build`.

**Module ownership.** Only edit your own folder:

| Folder | Owner | What goes there |
|---|---|---|
| `Sources/FinderSpeed/Engine/` | **athena** | NSProgress subscription, destination discovery, speed calculation, sample history |
| `Sources/FinderSpeed/Window/` | **apollo** | Finding and tracking Finder's copy window, the attached panel window that follows it |
| `Sources/FinderSpeed/UI/` | **thor** | SwiftUI views: the speed label (always visible) and the collapsible speed graph |
| `Sources/FinderSpeed/App/` | **zeus** | `main.swift`, the menu bar item, wiring the parts together |
| `docs/`, `README.md`, `CHANGELOG.md` | **saga** | Documentation |

**Shared contract.** The Engine exposes a `@MainActor final class TransferMonitor: ObservableObject` with:
- `@Published var transfers: [Transfer]`, the active Finder operations grouped by destination folder;
- each `Transfer` has: `id`, `destinationFolder: URL`, `displayName`, `bytesCompleted`, `bytesTotal`, `bytesPerSecond` (smoothed), `samples: [SpeedSample]` (time + bytes/sec, raw), `isPreparing`, `startedAt`;
- a `start()` method and a `watch(folder: URL)` method.

The UI takes a `Transfer` and renders it. Window decides where the panel goes. App wires the three together.

## Phase 3: Make the panel look like PART of Finder's window (added by Zeus)

**User feedback:** "It works, but it doesn't look integrated. It looks like something stuck onto Finder's window."

**Evidence:**
- Screenshot: `build/captures/before/shot-2.png`
- Zoomed seam: `build/captures/before/seam-zoom.png`
- Finder window alone: `build/captures/finder/{noshadow,shadow}.png`

The user is in **dark mode**. Everything must still be correct in light mode.

### What's wrong now
1. **Separate shapes.** Finder's window has 16 px rounded **bottom** corners. Our square-topped panel butts against them, so the wallpaper shows through two notches at the seam.
2. **A 1 px light line** (62,57,55) along the panel's top edge. This is the `Divider()` at the top of SpeedPanelView.
3. **Background mismatch.** Finder's background is an opaque, wallpaper-tinted (45,41,36). Ours is (49,44,41) and more translucent.
4. **The panel's own window shadow** reads as a second window.
5. **Content doesn't follow Finder's layout:**
   - a big bold 20+pt headline, different insets, no icon column;
   - it repeats information Finder already shows ("6.18 GB of 8.59 GB", "~31 s left", "name → dest");
   - the graph sits in a bordered box.

### Measured Finder geometry (Progress window, 1 row, 1x display, window-relative, top-left origin)

| Element | Measurement |
|---|---|
| Window | 404 × 88 |
| Title bar | y 0–32 |
| Content area | y 32–88 |
| Icon (`AXImage`) | x 17, y 39, 34 × 34 |
| Title text, 13pt | x 61, y 33, w 311, h 16 |
| Progress bar | x 62, y 46, w 309, h 20 |
| Stop button | x 378, y 51, 15 × 10 (centre x ≈ 385.5) |
| Status text, about 11pt secondary | x 61, y 64, w 311, h 16 |
| Margin below the status text | only **8 px** |
| Bottom corner radius | **16 px** |
| Background (dark) | (45,41,36), opaque, wallpaper-tinted |
| Outline | a 1 px ring **outside** the window, black at alpha ~0.86–0.90, on all sides |
| Shadow (black) | spread ~23 px left and right, ~30 px below, ~16 px above (offset downward) |

Shadow alpha profile, outward from the ring:

| Direction | Alpha, step by step |
|---|---|
| Below | 87, 82, 77, 72, 66, 60, 55, 49, 44, 38, 34, 29, 24, 21, 17, 14, 11, 9, 6, 6, 4, 3, 1 |
| Left and right | 49, 43, 39, 33, 28, 24, 21, 16, 14, 11, 9, 7, 5, 4, 4, 2, 1, 1 |

Re-measure with `scripts/tools/axframes` (an AX element dump) and `scripts/tools/winlist`.

### Target design: one continuous window

**Window/ (apollo)**

**Panel geometry.** The panel's **top edge sits 16 px ABOVE Finder's bottom edge**, the "cap band":
- In that band, paint only:
  - the two **16 × 16 corner squares**, so Finder's rounded bottom corners become square;
  - a **4 px strip** along Finder's bottom edge, which covers Finder's bottom outline/seam.
- The rest of the band is **fully transparent (alpha 0)**. Finder's status text (it ends 8 px above the bottom) stays visible, and clicks there pass through to Finder.
- Below Finder's bottom edge is our body. It has Finder's exact width, square top corners and **16 px rounded bottom corners**.

**Panel window setup:**
- `isOpaque = false`, `backgroundColor = .clear`, **`hasShadow = false`**.
- **Draw our own outline and shadow** with the measured profiles:
  - the outline on the left, right and bottom only, continuing Finder's ring;
  - the shadow on the sides and bottom only, faded in over the first ~16 px at the top so it blends into Finder's side shadow without a doubled band.
- The window frame is larger than the body to make room for the shadow (about 24 px on the left and right, about 32 px below).
- Shadow pixels should not swallow clicks. If needed, set `ignoresMouseEvents` when the mouse is outside the body. The body itself must take clicks (the chevron).

**Background must match Finder's pixel for pixel** (within ±2 per channel), whether Finder's window is active or inactive.
- Try `NSVisualEffectView` with `.windowBackground`, `.behindWindow` blending and the state following Finder's window. Mirror whether Finder's Progress window is main/key via AX (`AXMain`/`AXFocused`), or use `.inactive` if Finder's copy window is never key.
- Measure with `screencapture` during a copy (`scripts/capture-copy.sh` saves screenshots) and compare pixels. Iterate until the colours match.

**Content origin.** Hand the SwiftUI content a rect whose `y = 0` is exactly Finder's bottom edge and whose `x = 0` is exactly Finder's left edge, 404 wide. The cap band and the shadow padding are internal to Window/.

**Also:** a panel 1 px tall was seen at startup (h=1 in the window list). Make sure the panel never shows before its content has a real fitting height.

**UI/ (thor)**

- **No top `Divider`.** No background of our own (Window/ draws it).
- **Columns follow Finder's columns:**
  - icon column x 17–51: an SF Symbol such as `gauge.with.dots.needle.67percent` (or `speedometer`), hierarchical, secondary, sized to visually match Finder's 34 pt item icon but lighter (about 22–24 pt glyph, centred in the 34 pt column);
  - text column from x 61, width 311;
  - control column centred at x 385.5, which holds the expand/collapse chevron (a small borderless `chevron.down`/`chevron.right`, secondary, the size of Finder's stop button area, with a hit target of at least 20 × 20).
- **Line 1:** 13 pt regular (Finder's title font, `.system(size: 13)`), e.g. "Speed: 77.1 MB/s", with monospaced digits.
- **Line 2:** 11 pt secondary (Finder's status font), e.g. "Average 142 MB/s · Peak 719 MB/s". Show "Preparing…" or "Finished · average 680 MB/s" when appropriate.
- **Don't repeat** bytes, ETA or the destination. Finder already shows them. If **more than one** transfer is shown, append "→ <destination>" to line 2 so the rows can be told apart.
- **Vertical rhythm** should match Finder's row: Finder's lines sit at 33 / 46 (bar) / 64 within a 56 px content area. Our collapsed state is the two lines with about the same spacing, ~4 px top padding (Finder already leaves 8 px), and ~12 px bottom padding. That gives roughly 44 px collapsed.
- **Expanded graph:**
  - It sits in the text column (x 61, width 311), about 64 px tall, with **no box or border**.
  - Very faint horizontal grid lines, and the y-axis labels at 9–10 pt in the control column area (right side) or omitted.
  - Area plus line in the accent colour; the average as a dashed `.secondary` rule.
  - Smooth `.easeInOut` expand/collapse.
- Must look right in light and dark mode.
- Keep `UISnapshot.renderDemo` working. Update it to render on a Finder-like background (`.windowBackgroundColor`) at 404 wide.

**Engine/ (athena):** the graph showed a single 719 MB/s spike during a copy that really ran at 61 MB/s (true average measured by the copy-test script). Find the cause and fix it.

**App/ (zeus):** integration, plus the capture/compare test loop (`scripts/capture-copy.sh`, `scripts/tools/`).

### Definition of done (Zeus checks this with real screenshots)
- In a real copy screenshot there is **no visible seam**:
  - no wallpaper notch at the corners;
  - no line between Finder's content and ours;
  - background pixels equal within ±2;
  - one continuous outline and shadow around the combined shape;
  - our text column lines up with Finder's text (x 61) and our chevron with Finder's stop button column.
- Collapsed and expanded both look right, and expanding animates the panel height smoothly.
