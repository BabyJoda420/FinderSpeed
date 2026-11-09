# BUG-001: the panel "looks horrible" in real use (user report, 2026-11-09)

**Setup:**
- Installed app `/Applications/FinderSpeed.app`, v0.1.0 build, launched normally. It does **not** have the Screen Recording permission, so it uses the material fallback. Accessibility is granted.
- Same Mac as our tests (1x, 1440×900, dark mode).
- A real user operation: Finder **"Moving 28 items to “1_TB_WD_Blu”"**, a slow external USB hard disk. Finder shows "…18 minutes" remaining and the progress bar is at about 1%.
- A Finder **browser window** (sidebar: Applications, Downloads, Desktop; list: "Aloha pool", "Hörbücher") lies partly under and to the right of the copy window. Desktop widgets (circular battery-style widgets) are to the left.

**What the screenshot shows (it can't be attached; described here, all in points):**
1. **The whole cap band is filled, not just the corners.** A uniform, semi-transparent dark strip about 24 pt tall spans Finder's full width. It starts about 24 pt above Finder's bottom edge and cuts through Finder's status line: only "…18 minutes" is still readable, and the rest is darkened or covered.
2. **The whole panel (band and body) is uniformly SEMI-TRANSPARENT.** Through the body you can read, **sharp and not blurred**:
   - the Finder browser window's sidebar items ("App…", "Dow…", "Desktop" with icons);
   - text from another window behind ("311 K…", "Worl…", "Lach…");
   - the desktop widgets on the left.

   It looks like a dark overlay at roughly 50–70% opacity. This is NOT a vibrancy blur. Possibly the panel's alphaValue is stuck mid-fade, or the fill is drawn with partial alpha.
3. Our content itself renders fine: the gauge icon, "Speed: 46.7 KB/s", "Average 3.40 MB/s · Peak 3.40 MB/s", the chevron (expanded), a dashed average line, and a graph that is only a **tiny blue sliver at the far left**, because the x-axis is percent complete and the move is at about 1%.
4. The panel's outer outline and shadow look roughly right. The panel is the same width as Finder's window and attached below it.

**Not reproduced so far** (Zeus):
- a fallback-mode copy (FINDERSPEED_NO_SAMPLE=1) with a Finder browser window behind it: opaque and correct (`build/captures/repro-fallback/shot-2.png`);
- the browser window brought to the front over the copy window: the panel correctly hides (`build/captures/repro-order.png`).

The differences from the user's case: a **long, slow move** to an external HDD (Finder updates rarely), a "Moving" operation rather than "Copying", the panel visible for minutes, and possibly Finder's active state toggling or Spaces/visibility flapping.

## UPDATE (user): the screenshot is from the user's MacBook, not from the Mac Studio we test on
- **We test on:** a Mac Studio with a 1x external monitor (1440×900).
- **The bug happened on:** a **MacBook with a built-in Retina (2x) display**, possibly with a notch, a P3 colour space, a different scaled resolution, and possibly a different macOS build.
- Zeus's earlier note "same Mac as our tests (1x)" is WRONG. The matching desktop items come from iCloud Desktop sync.
- **The prime suspect is now Retina (2x):** the chrome/band data in `WindowChromeData.swift` is 1 pt = 1 px and scaled up with linear filtering, and the band mask may be scaled or offset wrongly at backingScaleFactor 2. The band and the alpha (an image drawn at the wrong scale, or a mask that didn't apply) look wrong. Also check `screen.backingScaleFactor` handling, frame conversion on a built-in display with a notch (`safeAreaInsets` / `auxiliaryTopLeftArea`), and colour-space conversion (P3).
- **We can't reproduce 2x on this hardware directly.** Options:
  1. render the chrome and band offscreen at scale 2 (an `NSBitmapImageRep` at 2x size, `cacheDisplay` / an `NSGraphicsContext` with a 2x scale);
  2. ask the user to temporarily switch the Mac Studio display to a HiDPI scaled mode;
  3. give the user a diagnostic build to run on the MacBook.
