# Phase 3: Window/ visual integration (apollo)

**Result:** in real copy screenshots (dark mode, Screen Recording available), the seam is gone. Every metric in the dark-mode table below (Finder active and inactive, collapsed and expanded) is within ±2 per channel, or within 2/255 in alpha.

Light mode is verified only offline: I can't switch the system appearance. Without Screen Recording permission the background is 3 units off (details below).

## Screenshots

| | Path |
|---|---|
| Before | `build/captures/before/shot-2.png`, `build/captures/before/seam-zoom.png` |
| After, Finder active, expanded (body 116 pt) | `build/captures/apollo-final-active/shot.png`, `…/seam-left-zoom.png`, `…/seam-right-zoom.png`, `…/report.txt` |
| After, Finder inactive, collapsed (body 44 pt) | `build/captures/apollo-final-inactive/shot.png`, `…/seam-left-zoom.png`, `…/report.txt` |
| After, Finder active, collapsed | `build/captures/apollo-a2/shot.png` (and zooms) |
| After, expanded via a real click on the chevron | `build/captures/apollo-e1/shot.png` |
| Material fallback (no Screen Recording) | `build/captures/apollo-fallback/shot.png`, `…/report.txt` |

Each `apollo-*` folder has:
- `shot.png`: copy running;
- `clean.png`: the same region after everything closed;
- `windows.json` and `region.txt`;
- `report.txt`.

The checks were made with `spikes/window/phase3/seam_check.sh <dir> [--inactive] [--expand]`. It starts a real Finder copy, captures the region, waits until all the windows are gone, captures the clean wallpaper, then runs `seam_check.py`. Shadow alpha is computed per pixel as `1 − shot/clean`.

## Pixel numbers (real screenshots, dark mode, 1x display)

| Check | Before (Zeus's notes) | After: active, expanded | After: inactive, collapsed |
|---|---|---|---|
| Background, Finder vs panel | (45,41,36) vs (49,44,41), translucent | (45,41,36) vs (45,41,36), **diff 0** | (45,41,36) vs (45,41,36), **diff 0** |
| Rows −7…+3 around Finder's bottom edge (inner columns) | 1 px line (62,57,55) | **100% of pixels within ±2, max deviation 0** | **100% within ±2, max 0** |
| Corner area (x 1–15 / 388–402, rows −24…+5) | wallpaper notch on both sides | **0 of 900 pixels** off the background by more than 2 | **0 of 900** |
| Outline ring alpha (x = −1): Finder / band / body | separate shapes | 0.96–0.97 / 0.96–0.97 / 0.92–0.97 | 0.87–0.88 / 0.88–0.89 / 0.88 |
| Rim brightness (x = 0): Finder / band / body | no rim | 62 / 62 / 62 | 58 / 57 / 57 |
| Side shadow vs reference (28 px; rows: Finder −40 / band −10 / body 5 / body middle) | second window shadow | 8* / 2 / 2 / 2 (out of 255) | 2 / 2 / 1 / 2 |
| Bottom shadow vs reference (centre column) | n/a | 2/255 | 5/255 |

\* The "Finder −40" row is Finder's own shadow, which we don't draw. The 8 is the difference between the live screen and the reference capture there (this row is already 2/255 in the inactive run).

**Material fallback** (`FINDERSPEED_NO_SAMPLE=1`, Finder active): panel (48,41,37) vs Finder (45,41,36), a **max channel difference of 3**. The seam rows and corners are therefore 3 off. All the chrome numbers are unchanged.

**Offline check of the chrome model.** `spikes/window/phase3/verify_composite.py` composites Finder's window alone + our shadow + our body and compares the result with a real single window of the combined height (52 pt body):

| Variant | Pixels within ±2 | Max difference |
|---|---|---|
| dark, inactive | 99.94% | 5 |
| dark, active | 99.87% | 8 |
| light, inactive | 99.97% | 9 |
| light, active | 99.98% | 5 |

The maxima are inside our own bottom corners, or in rows where the two reference windows themselves differ.

## How it works

### 1. Measuring the chrome

My own titled `NSWindow` (`phase3/refwin.swift`) has exactly the chrome of Finder's progress window: alpha max difference 1 and corner coverage max difference 1 against `build/captures/finder/shadow.png`. That let me capture all four variants (dark/light × key/non-key) at heights 88, 140, 200 and 320 without touching the system appearance.

| Element | Key (active) window | Non-key (inactive) window |
|---|---|---|
| Shadow extent (sides / above / below) | 56 / 38 / 74 px | 23 / 16 / 30 px |
| Outline ring (dark mode) | alpha 246/255 | alpha 224/255 |
| Inner rim (dark mode) | background + 22 | background + 17 |

The bottom corner is a continuous ("squircle") curve: coverage is still partial 18 rows up, so an arc of radius 16 would not match.

Two facts make the combined shadow computable:
- A tall window's side profile is constant more than about 44 rows from its bottom (≤3/255 variation).
- Its bottom block is the same for any height (≤2/255).

`phase3/gen_profile.py` turns the captures into `Window/WindowChromeData.swift` (generated, 92 KB): the steady side profile, the bottom block of a tall window, Finder's own bottom block, and the corner coverage plus a rim/edge overlay.

### 2. Shadow model (`Window/WindowChrome.swift`)

- The target `A_T` is the chrome of one window with the combined shape.
- `A_F` is what the window server already draws around Finder.
- Our black alpha is `s = 1 − (1 − u)/(1 − A_F)`, with `u = (A_T − cov)/(1 − cov)`.
- Edge pixels of the body get a white overlay (the rim) or a black overlay on the fill. This reproduces the reference for **any** fill colour: the light rim follows the background, as Finder's does.
- Rendering costs **0.46 ms per frame** in a release build and 12–17 ms in debug. It is redone for every frame of the height animation.

### 3. Two windows, both `hasShadow = false`, level `.normal`

**Chrome window**: `ignoresMouseEvents = true`, ordered directly above Finder's window. It holds:
- the computed outline and shadow;
- the **cap band**: the 24 rows above Finder's bottom edge. There it paints only Finder's corner curve (per row, measured from the corner table, so it stays clear of Finder's icon) and the 4 px strip over Finder's bottom rim, plus the rim on the side columns. The rest of the band is transparent.

The band is 24 rows instead of 16 because Finder's curve starts about 18–20 rows above its bottom edge. A 16-row band left a sliver of the curve.

**Body window**: takes clicks, ordered directly above the chrome window. Its frame is the content rect: **x and width are Finder's, the top is Finder's bottom edge**. It holds the fill, Thor's SwiftUI content (top-left = Finder's bottom-left, width 404) and the edge overlay. The window and frame are larger than the body only in the chrome window.

**Click-through (verified with synthetic clicks while Finder was inactive):**

| Where I clicked | Result |
|---|---|
| A transparent band pixel over Finder's status text | went to Finder |
| A painted band corner | went to Finder |
| Our shadow over the desktop | went to Finder (desktop) |
| Our body | caught by the panel; no app activated (non-activating) |

My first version had the band inside the body window, and the masked material there **swallowed** clicks. That is why the band now lives in the click-through chrome window.

### 4. Background

The `NSVisualEffectView` wallpaper tint is **one colour per window, computed from the desktop region under that window's frame**. I measured `.windowBackground` in three places:

| Window position | Colour |
|---|---|
| Finder's frame | (59,54,48) |
| Below Finder | (54,47,40) |
| Elsewhere | (50,52,54) |

(Those values come from window captures. On screen it is (41,36,32) below Finder against Finder's (45,41,36).)

A window spanning Finder + below gets (43,38,34). So **no material in our own window can reproduce Finder's exact colour**. `.underWindowBackground`, `.contentBackground`, `.sheet` and solid `windowBackgroundColor` don't match either.

So `Window/FinderBackgroundSampler.swift` works like this:
- If Screen Recording is **already** granted (it never asks for it), it reads Finder's on-screen background through ScreenCaptureKit, with our windows excluded. The sample is the median of an 8×8 patch in Finder's left margin, in the display's colour space. That takes 35–110 ms.
- It samples when the window appears (the panel waits up to 0.4 s so it doesn't fade in with the wrong colour), after moves (0.3 s debounce), after an active-state change (0.35 s) and after an appearance change.
- If Screen Recording is not granted, it falls back to `.windowBackground`, with the state following Finder's window. That is the 3-unit mismatch above.

### 5. Active / inactive

`WindowInfo.isActive` means Finder is frontmost and the window is AX-main. A new event `.activationChanged` switches between the key and non-key chrome. It is re-read on AX focus and main-window changes and on NSWorkspace activation changes.

I verified both live:
- osascript copies leave Finder active, so its window is key and gets the large shadow;
- with another app frontmost, the window is inactive and gets the small shadow.

### 6. Other fixes

- **The 1 px panel:** the panel never shows while the content's fitting height is below `minimumContentHeight` (8). The window list, polled about every 50 ms during start-up and the first ~8 s of a copy, showed **no** FinderSpeed window shorter than 8 px, and none at all before Finder's window appeared.
- **Height animation:** a 60 Hz ease-in-out over 0.25 s. The content is anchored at the top (Finder's bottom edge). Example: 68 → 91 → 137 → 140.
- **Light/dark:** the appearance is observed through KVO on `NSApp.effectiveAppearance`, which re-renders the chrome and re-samples the background.

## API changes (Window/)

| Type | Change |
|---|---|
| `FinderProgressWindowObserver.WindowInfo` | new `isActive` |
| `FinderProgressWindowObserver.Event` | new case `.activationChanged`. I grepped for `switch` over Event: nothing outside Window/ needs updating, and `swift test` passes 38/38. |
| `SpeedPanelController` | `init(content:)` / `attach(to:)` are unchanged. Removed: `gap`, `bottomCornerRadius`, `flipsAboveWhenOffscreen` (they conflict with the cap band). Added: `minimumContentHeight`, `contentFrame`, `shadowWindowNumber`, `usesSampledBackground`. Environment switches: `FINDERSPEED_DEBUG_WINDOW=1` (logging), `FINDERSPEED_NO_SAMPLE=1` (force the material fallback). |
| New files | `Window/WindowChrome.swift`, `Window/WindowChromeData.swift` (generated), `Window/FinderBackgroundSampler.swift` |

**For Thor:** the hosting view's top-left is Finder's bottom-left edge and its width is Finder's (404). Window/ draws the background, outline, rim and shadow. Don't draw your own background or a top divider. A 1 px rim is drawn **over** the content at x = 0 and x = 403 and along the bottom row, as Finder's window does.

## Notes for Zeus

1. **`scripts/capture-copy.sh` uses `screencapture -o`.** For region captures that removes the window server's decoration from Finder's window: the shadow, the outline ring and the light rim. Our chrome is window content, so it stays. Screenshots taken with `-o` therefore show a false mismatch. I measured this in `apollo-a1`: no ring and no rim along Finder's rows. Please drop `-o`. My `seam_check.sh` doesn't use it.
2. During the real-click tests I used a window-less helper app (`phase3/activator`) to make Finder inactive, plus synthetic clicks. One click on the shadow over the desktop selected the "Tatt" desktop icon.
3. A browser window then opened over the capture region, so someone is using the Mac. I stopped all focus-stealing and click tests at that point. The `apollo-final-expanded` capture is invalid for that reason; the expanded state is covered by `apollo-e1` and `apollo-final-active`.
4. All test copies went to `/Volumes/FinderSpeedTest/capture` (your script's folder), and the script deleted each copy afterwards. The volume is empty. Your 8 GiB source set `testdata/finder-copy-test/real_8x1024m` is still there.
5. The debug app is running again (`.build/debug/FinderSpeed` with `FINDERSPEED_DEBUG_WINDOW=1`, normal background sampling).

## Open questions

1. **Screen Recording for the product.** It is the only way to an exact (±0) background. Without it the difference is about 3, which is faintly measurable and hard to see. Should the app ask for Screen Recording (an optional setting, "pixel-perfect background")? The sampler never prompts. Note that ScreenCaptureKit may show the system's screen-capture privacy indicator briefly while it samples; I didn't see it in screenshots, but I didn't check the menu bar.
2. **Light mode live.** The model is verified offline (99.97–99.98% within ±2). A live check needs the system appearance switched to Light, which I'm not allowed to do. Can the user or Zeus switch it for one run of `seam_check.sh`?
3. **Retina (2x).** The chrome images are rendered at 1 pt per pixel and scaled up with linear filtering, so on 2x displays the ring and corners will be slightly soft. This display is 1x, so it's untested. 2x reference captures and a 2x data set would fix it if needed.
4. **Two-row Finder windows** (two concurrent copies, 149 pt): the band and chrome are anchored to Finder's bottom edge and width, so they should work, but this is untested live in phase 3.

---

## Addendum: two concurrent copies (Finder window with 2 rows, 149 pt)

**Setup.** `spikes/window/phase3/seam_check.sh <dir> --two` starts two real Finder copies (8 × 1 GiB each), to `/Volumes/FinderSpeedTest/capture-a` and `…/capture-b`, 1 s apart. It waits for Finder's window to be at least 140 pt tall and for all frames to stay unchanged for 1.5 s, then captures. There were no clicks and no focus changes. Both destination copies were deleted afterwards, and the volume is empty.

**Result: everything still holds.** Final capture: `build/captures/apollo-two3/shot.png`, plus `seam-left-zoom.png`, `seam-right-zoom.png` and `report.txt`.

| Check | Result (2 rows; Finder active; our body 232 pt = two expanded transfers) |
|---|---|
| Geometry | Finder 404×149, bottom at y 468 (CG). Body window 404×232 starting **exactly** at y 468. Chrome window 516×330. Z-order: body 4, chrome 5, Finder 6, so both are directly above Finder. |
| Background, Finder vs panel | (43,38,33) vs (43,38,33), **diff 0** |
| Seam rows −7…+3 | 100% within ±2, max deviation 0 |
| Corner area | 0 of 900 pixels off by more than 2 |
| Ring alpha, Finder / band / body | 0.96–0.97 / 0.96–0.97 / 0.92–0.97 |
| Rim brightness, band / body | 60 / 60 (Finder: 60, and 79 where its row divider meets the edge) |
| Side shadow vs reference | ≤2/255 (Finder row −40, band −10, body rows 5 and 116) |
| Bottom shadow vs reference | 2/255 |
| Panel content | 2 transfer rows, **"… → capture-a"** and **"… → capture-b"**, each with its own speed line and graph |

**Click-through (by construction; no click tests this time).** The band lives only in the chrome window (`ignoresMouseEvents = true`), and the body window starts exactly at Finder's bottom edge. So no click-taking pixel of ours overlaps Finder's window. These are the same structures the earlier click test verified.

**Bug found and fixed.** Finder's wallpaper tint follows its window frame, **height included**. At 2 rows the background changes from (45,41,36) to (43,38,33). The panel only re-sampled on width changes, so the first run (`build/captures/apollo-two`) showed the panel at (44,39,35), 2 units off. It now re-samples on every `.resized`. The log shows the panel following Finder: `[45,41,36] → [43,38,33] → [45,41,36]` (1 row, 2 rows, back to 1 row).

**Tooling fixes in `seam_check.sh`:**
- It waits for stable frames before capturing. The first run caught the panel mid-transition, which produced a bogus 177/255 "bottom shadow" error measured inside the still-growing body.
- The region now extends 380 px below Finder, for tall expanded panels.

**Observations for App/UI and Engine (not Window/):**
1. The first run caught a transitional frame: a fading extra row, "Speed: 0 KB/s · Average 337 MB/s → capture-a", overlapped a second "→ capture-a" row showing "Average 0 KB/s · Peak 0 KB/s". It looks like the second transfer appearing (or capture-a's transfer being replaced) while the UI animates, and capture-a briefly read 0 KB/s with 679 MB already copied. Shot: `build/captures/apollo-two/shot.png`.
2. The row order differs: Finder lists capture-b first, while our panel lists capture-a first.
