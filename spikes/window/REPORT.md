# Spike C: Finding and tracking Finder's copy window (apollo)

**Does it work? Yes.** With the Accessibility permission we can detect the window, follow it, and read the copied bytes as text. Without it, `CGWindowListCopyWindowInfo` can only guess which window it is.

Test setup: macOS 27.0.1 (26A434), Finder pid 764, destination `/Volumes/FinderSpeedTest/apollo` (an APFS sparse disk image).

## 1. Timing: a single 2 GB file is too fast to see the window

- `big_2g.bin` copied in **3.0 s** (about 700 MB/s) and **no progress window appeared at all** (`logs/run1_2g_no_window.log`).
- Finder only shows the window about **3.1–3.3 s after the copy starts**: 4188 ms and 4099 ms after the observer started, with the copy starting at about 1000 ms. So short copies never get a window.
- To get a longer copy, I made `testsrc/` with 5 APFS clones of `big_2g.bin` (`cp -c`, so no extra disk space) and copied the folder. That is 10.74 GB in about 15 s. I deleted `testsrc/` afterwards. To recreate it: `mkdir testsrc; for i in 1 2 3 4 5; do cp -c ../../testdata/big_2g.bin testsrc/big_$i.bin; done`.
- **Consequence for the product:** for copies under about 3 s there is no window to attach a panel to.

## 2. CGWindowListCopyWindowInfo (no permission needed)

Here is what the copy window looks like (`logs/run3_10g_cg_ax.log`):
```
cg #5819 layer=0 onscreen=Y alpha=1.00 bounds=(74,319 404x88)  name=<nil>   one copy row
cg #5819 layer=0 onscreen=Y alpha=1.00 bounds=(74,319 404x149) name=<nil>   two concurrent copies (athena's + mine)
cg #5819 layer=0 onscreen=Y alpha=0.91 -> 0.00 bounds=(78,320 396x86)      fade-out when closing, then it disappears
```
- **`kCGWindowName` is nil for every Finder window**, including browser windows. `CGPreflightScreenCaptureAccess()` was `false` the whole time, so **the name is hidden without the Screen Recording permission.** I could not test with Screen Recording granted, because changing settings is not allowed.
- **Layer is 0**, the same as Finder's browser windows, so the layer does not tell them apart. Owner name and PID are Finder's in both cases.
- **The window number changes on every copy session** (5798, 5819, 5822, 5829, 5831).
- **One window holds all concurrent copies.** Each copy is a row: the height is 88 px for one row and about 61 px more for each extra row (149 = 88 + 61). The width stays at 404.
- **With CG alone, the only way to recognize it is a guess:** owner is Finder, layer 0, onscreen, width 404, height 88 + 61·n. That is fragile: it could break with another macOS version, localization, or a user resizing the window.
- CG bounds are the same as the AX frame (both use a top-left global origin). So AX → CG can also be matched by frame.
- A sample costs about 1–4 ms.

## 3. Accessibility (AXUIElement)

**Permission state:** at the start `AXIsProcessTrusted() == false`, and AX calls returned `-25211` (kAXErrorAPIDisabled). During run 2 (at about 13:32:36) **Accessibility was granted** to the host process, presumably by the user or Zeus. Since then `AXIsProcessTrusted() == true`. Note that the grant applies to the *responsible* process (the terminal or Claude host), not to the binary itself. The real app will need its own grant.

**The copy window as AX sees it:**
```
AXWindow subrole=AXStandardWindow title="Copy" AXIdentifier="Progress" cgid=5819 pos=(74,319) size=404x88
  AXScrollArea id=_NS:30
    AXStaticText        id=_NS:59 value="Copying 6 items to “apollo”"                 one block per copy row
    AXProgressIndicator id=_NS:81 value=0.4413 min=0 max=1
    AXButton            id=_NS:8  desc="stop progress"
    AXStaticText        id=_NS:89 value="947.9 MB of 2.15 GB – About 5 seconds"
    ...the next row repeats the same 4 elements (id=_NS:59/_NS:81/_NS:8/_NS:89)
  AXButton/AXCloseButton, AXZoomButton, AXMinimizeButton
```
Finder's browser windows look like this instead: `subrole=AXDialog id=FinderWindow title="<folder>"`. (Oddly they are AXDialog, not AXStandardWindow, on macOS 27.)

**A reliable way to tell the windows apart: `AXIdentifier == "Progress"`.** It is not localized, unlike the title "Copy" (which would also be "Move" or "Delete" for those operations; I did not test them). To get the CGWindowID I used the private `_AXUIElementGetWindow` (cgid 5819 matched the CG list), with frame matching as the public fallback.

**Event-driven tracking works** (`FinderAXObserve.swift`, `logs/obs1_*`, `logs/obs2_*`). An `AXObserver` on Finder's pid gives these notifications:
- `AXWindowCreated` for the Progress window, at about 3.1 s into the copy.
- `AXValueChanged`, registered on the app element, fires for the `_NS:89` text **about every 500 ms**.
- `AXMoved` fires. I checked by moving the window 40 px through AX and back: `AXMoved ... frame=(114,319 404x88)`.
- `AXUIElementDestroyed` fires when the window closes, about 150 ms after the last update.
- `AXResized` was **registered but not seen firing**, because the observer runs only had one row. The polling run did show the 88→149 resize, so it very probably fires.
- A full poll of the AX tree costs about 15–35 ms, so prefer the observer.

## 4. Finder's progress text as a speed source

The text looks like `"<copied> of <total> – About N seconds"`, in decimal units (2147483648 B shows as "2.15 GB"). It updates about every 500 ms with 10 MB resolution (0.01 GB). Speeds derived from consecutive updates (obs1):
```
2.75 GB -> 796 MB/s, 3.10 -> 697, 3.52 -> 841, 3.98 -> 920, 4.76 -> 693, 5.12 -> 721 ... 10.56 -> 794 MB/s
whole run: 2.18 GB @6.35 s -> 10.55 GB @17.19 s = about 773 MB/s on average
```
Caveats:
- **Folder copies: the total is wrong.** It reads "X of X" while copying, with the bar stuck at 0.9999. The total counts up along with the copied amount. Only single-file copies had a correct total ("1.17 GB of 2.15 GB", bar 0.54).
- **The ETA is useless:** it said "About 5 seconds" the whole time.
- **The row title changes during the copy** ("Copying 6 items" → 5 → … → "0 items"), so a row must be tracked by position or element, not by its title. My observer keys on the title, which is why a few speed values are missing at the item changes. That is a bug in the spike tool only.
- The text is localized (separators "of" and "–", unit names, and the decimal comma in other locales), so the parser has to be locale-aware.
- **0.5 s updates are coarse but good enough** for a speed number plus a graph, and this source gives per-copy-row numbers.

## 5. Alternative without Accessibility: Finder AppleScript

`tell application "Finder" to get {name, class, bounds} of every window` lists the copy window as `Copy, window, {74,351,478,407}`. It has class `window`, not `Finder window`, and the bounds start below the 32 px title bar. This needs only the **Automation** permission for Finder, which was already granted. It gives presence and position but no text. System Events UI scripting needs Accessibility (error -1728 before the grant). Each osascript call takes about 0.4 s here (one loop of two calls plus a 0.5 s sleep took about 1.35 s), so this is only useful as a fallback.

## Permissions needed

- **Accessibility**: required for identification, the AX text and bar values, and the move/resize/close events. This is the recommended path.
- **Screen Recording**: only to see `kCGWindowName`. Not needed if we use AX.
- **Automation (Finder)**: only for the AppleScript fallback, and for starting test copies.

## Recommendation for the panel phase

Use an `AXObserver` on Finder: `AXWindowCreated`, then filter on `AXIdentifier == "Progress"`, then attach the panel and follow it with `AXMoved`, `AXResized` and `AXUIElementDestroyed`. Read the `_NS:89` text from `AXValueChanged` events. Use CG (`_AXUIElementGetWindow`, or matching frames) only to order the panel relative to the window number, and as a sanity check.

## Files

- `FinderWindowProbe.swift` / `finder-window-probe`: polls the CG and AX windows every 200 ms and logs changes.
- `FinderAXObserve.swift` / `finder-ax-observe`: an event-driven AXObserver that parses the progress text into MB/s. `--nudge` is a test-only flag that moves the window to test `AXMoved`.
- `logs/`: raw output from all runs.

## Open questions

1. Are `AXResized` events reliable when rows are added or removed, and are `AXMoved` events throttled while the user drags the window? Not tested.
2. What do the move, delete, network-volume and "preparing" phases look like? Is the identifier still `Progress`? Not tested.
3. Should the panel cover the about 3 s before the window appears (when the panel has nothing to attach to), for example with a menu-bar readout?
4. `_AXUIElementGetWindow` is private API. Is that fine for us (no App Store), or should we only match by frame?
5. Do the `_NS:xx` identifiers stay stable across macOS updates? Matching by role order (text, bar, button, text) is the safer option.
