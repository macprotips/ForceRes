# macOS display-mode selection and forced resolutions on Apple Silicon

Working notes for ForceRes, started 2026-09-13. Sources: Apple SDK headers,
Apple docs, open-source projects, BetterDisplay's issue tracker, and direct
measurements on the development Mac (macOS 27.0 build 26A5425a, Apple M4 Mac mini, one external
Samsung Odyssey G80SD 4K 240 Hz, no built-in panel). The raw local dump is
`docs/probes/local-mode-dump-m4-g80sd.txt`.

Tags: **[verified]** primary source or measured here; **[reported]**
credible secondary or community source; **[inference]** our reasoning.

Note: an unrelated open-source GPL-3 menu bar app named "SimpleDisplay"
(https://simpledisplay.app, https://github.com/SamuelRioTz/SimpleDisplay)
already does resolution switching with the same private APIs. Its published
test notes are cited below as evidence; its code is not to be copied.

---

## 1. Public CoreGraphics API

**Enumeration [verified, SDK header + measurement].** `CGDisplayCopyAllDisplayModes(display, options)`; the header still says the options dict is "reserved for future expansion; pass NULL for now", but the exported constant `kCGDisplayShowDuplicateLowResolutionModes` (macOS 10.8+) is honored. On the M4/G80SD: **116 modes without the flag, 242 with it**. The extra modes all have `ioFlags == 0x00000001` (`kDisplayModeValidFlag` only, no `kDisplayModeSafeFlag`) and `CGDisplayModeIsUsableForDesktopGUI() == false`. Modes System Settings shows have `0x03` (Valid|Safe); the display's default mode has `0x07` (…|Default). Modes whose *pixel* output equals the panel's native timing carry `0x02000000 = kDisplayModeNativeFlag` (IOGraphicsTypes.h). On the G80SD that is `1920x1080 HiDPI (3840x2160 px)` and `3840x2160@1x`.

**HiDPI identification [verified].** `CGDisplayModeGetPixelWidth/Height` (backing pixels) vs `GetWidth/Height` (points). HiDPI "looks like" mode ⇔ `pixelWidth == 2*width` (`CGDisplayModeGetPixelDensity` is exported but unofficial). Example rows from the local dump:
```
1920x1080  px 3840x2160  240Hz flags=0x02000003 gui=1   <- HiDPI "looks like 1080p"
1920x1080  px 1920x1080  240Hz flags=0x00000003 gui=1   <- true low-res 1080p
1280x720   px 2560x1440  240Hz flags=0x00000003 gui=1
1280x720   px 1280x720   240Hz flags=0x00000003 gui=1
3840x2160  px 3840x2160  240Hz flags=0x02000003 gui=1
```
So on a 4K external display **all four target resolutions exist in both low-res and HiDPI variants at the panel's max refresh**, and they are all Safe/GUI-usable. The public API is sufficient for externals. Pixel encoding is `--------RRRRRRRRGGGGGGGGBBBBBBBB` (32 bpp) for everything.

**Setting a mode [verified, SDK header].**
- `CGDisplaySetDisplayMode(display, mode, NULL)`: "persists for the life of the program, and automatically reverts to the permanent setting when the program terminates." Useless for a menu bar utility unless the app stays resident.
- Transaction: `CGBeginDisplayConfiguration` → `CGConfigureDisplayWithDisplayMode(config, display, mode, NULL)` → `CGCompleteDisplayConfiguration(config, scope)` with `kCGConfigureForAppOnly = 0`, `kCGConfigureForSession = 1`, `kCGConfigurePermanently = 2`. Header (CGDisplayConfiguration.h): "If a request is made to make a change permanent, and the change cannot be supported by Mac OS X user interface, then the configuration change lasts only for the current login session… This operation may fail if an unsupported display mode is requested, or if another app is running in full-screen mode." Modes in a mirror set get coerced to a compatible mode.

**Persistence [verified].** `kCGConfigurePermanently` is what displayplacer (DisplayPlacer.c lines 180, 513, 561) and SimpleDisplay (`DisplayService.setDisplayMode(permanently:)`) use. The result lands in `/Library/Preferences/com.apple.windowserver.displays.plist` (inspected locally: per-display-UUID `CurrentInfo {Wide, High, Hz, Scale, IsVRR, Depth}` keyed by *connected-display configuration*), so macOS itself restores the mode on reboot/reconnect as long as the topology is the same. SimpleDisplay's testing notes confirm "macOS stores mode preferences per connected-display configuration, causing mode reversion when topology changes" and that a "permanent" commit while mirroring is active bakes mirror state into prefs. Commit permanently only when no mirrors are active.

**"Unavailable" flag.** There is no `kCGDisplayModeIsUnavailable` key in the current SDK; the dictionary keys that exist are `kCGDisplayModeIsSafeForHardware`, `IsInterlaced`, `IsStretched`, `IsTelevisionOutput` (legacy, CGDirectDisplay.h). The practical "unavailable" signal is `ioFlags & kDisplayModeSafeFlag == 0` ⇔ `!CGDisplayModeIsUsableForDesktopGUI()` (measured: they matched 1:1 on 242 modes). Other IOKit flags worth reading: `kDisplayModeStretchedFlag 0x800`, `kDisplayModeInterlacedFlag 0x40`, `kDisplayModeNeverShowFlag 0x80`, `kDisplayModeBuiltInFlag 0x400`.

**Can the public API set a mode System Settings hides?** [verified] Yes for the "duplicate low-res" set: SimpleDisplay, EasyRes, and "Any Screen Resolution" (a sandboxed Mac App Store app) all set modes from that list via `CGConfigureDisplayWithDisplayMode`. [reported] Setting non-Safe (flag 0x1) modes may be refused or auto-substituted; displayplacer's README warns "some of the resolutions listed may not work… displayplacer will default to another working resolution". [inference] Applying an unsafe mode was not tested here. The private CGS enumeration (`CGSGetNumberOfDisplayModes`) returned **267** modes on the same display: the extra 25 (flags `0x40000000`) are invisible to the public API, so the private list is a strict superset.

## 2. Built-in laptop panels

Concrete stock lists found:
- **M1 MacBook Air (2560x1600)**, `displayplacer list` in jakehilborn/displayplacer#81 [verified quote]: 16 modes — 800x600, 825x525 (HiDPI), 840x525, 1024x640 (HiDPI), 1024x768, 1152x720, 1280x800 (HiDPI+1x), 1440x900 (HiDPI+1x), 1650x1050, 1680x1050 (HiDPI), 2048x1280, 2560x1600, 640x480, 720x450 (HiDPI). **No 1920x1080, no 1280x720.** The tool failed with "could not find res:1920x1080 scaling:off"; the user notes 1080p appears only when an external/AirPlay display is attached. Issue is open, no maintainer fix.
- **14" MacBook Pro (3024x1964)**, `betterdisplaycli … -displayModeList` published at cechacek.com [verified by grep of the page]: 1,544 entries (clearly with BetterDisplay flexible scaling enabled: 4:3 800x600 etc. and "Unsafe" 400x300 HiDPI entries). **Even in that list there is no 1920x1080, 1280x720, 2560x1440 or 3840x2160 entry.** Entries look like `556 - 1512x982 HiDPI ProMotion 10bpc Default Native`, `557 - 1512x982 ProMotion`, `558 - 1512x982 HiDPI 60Hz`, … 48 Hz variants; `1437 - 3024x1964 ProMotion 10bpc Native`. Refresh choices per resolution: ProMotion, 60, 50, 48 Hz.
- **16" M1 Max (3456x2234)**, BetterDisplay #4920 [reported]: `betterdisplaycli` list showed only HiDPI 1728x1117; no 1x variant; macOS "forced a switch to 1920x1080@1x" when HiDPI was disabled, so some 16:9 1x timing appears to exist on that machine (possibly injected by BetterDisplay; unclear).
- **Intel Retina MBP (2880x1800, 2020 post)** [verified quote]: stock list *did* include 1920x1080 and 1280x720 non-scaled modes. So Apple Silicon panels lost the 16:9 low-res timings that Intel panels exposed [inference from these two data points].

**Aspect-ratio handling [reported].** Apple forum thread 693753 (14" MBP): an Apple Arcade game offered 3024x1890 (draws under the notch) and 3024x1964 which produced **black bars on the sides**; non-notch-aware games squished 1964 into 1890. BetterDisplay #1878 (M2, external QHD): an "Unsafe" 1920x1080 timing gives a "black border… shrinks the viewing space", and even that often doesn't take on Sonoma+: "Recent Apple Silicon devices increasingly reject non-native timings"; the maintainer now recommends custom EDID. BetterDisplay's own guidance for 16:9 on a MacBook (#2507, #3080, exlima.net writeup on M2 Pro) is a **custom scaled resolution (HiDPI framebuffer) or a 16:9 virtual screen mirrored/PIP'd**; the exlima author reports sharp HiDPI 1920x1080 and 1600x900 with the app switching between 16:10 and 16:9 (black bars are avoided in the *recording*, not stretched on the panel). [inference] macOS never anisotropically stretches; a 16:9 framebuffer on a 16:10 panel is letterboxed by the display pipeline, and truly unlisted timings are refused rather than approximated.

**Bottom line for Q2:** on Apple Silicon built-ins, exact 1920x1080 / 1280x720 / 2560x1440 / 3840x2160 are **not** in the public (or private CGS) mode list; the public API cannot set them. They must be *created* (override/flexible scaling) or *simulated* (virtual display + mirror).

## 3. How BetterDisplay and SwitchResX do it

**BetterDisplay [reported, wiki + maintainer statements].**
- *Flexible scaling*: writes a per-model **display override** ("Edit the default system configuration of this display model" → reboot). Override plists live at `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-XXXX/DisplayProductID-XXXX` with `scale-resolutions` entries (`/Library/Displays` is admin-writable, not SIP-protected; this machine has none). This generates the ~1,500-entry mode lists above, including custom aspect ratios on the built-in panel. Requires Pro license and admin credentials; on Sequoia the "native resolution override" can corrupt and needs re-setting (#3401). Framebuffer caps: 6K horizontal for base M1/M2, 8K for Pro/Max, and (smcleod.net, macOS 26.4) M4/M5 cap the single-stream sub-pipe at **6720 px**, so 3840x2160 HiDPI (7680 px backing) is not offered on 4K displays with M4/M5; max HiDPI is 3360x1890. The local M4 list is consistent: largest HiDPI is 3008x1692 (6016 px), and 3360x1890 appears only at 1x.
- *Virtual screens*: private `CGVirtualDisplay` classes (see §5); the virtual screen is either **mirrored** to the physical display (hardware mirror via `CGConfigureDisplayMirrorOfDisplay`) or **streamed** (BetterDisplay captures the virtual screen and draws it full-screen on the real one, which needs Screen Recording). This "also enables scaling beyond the native resolution of the display panel on Apple Silicon". Documented drawbacks: sleep issues ("macOS keeps the display that has a mirrored virtual display on"), flicker/color issues, cursor glitches (#261, #711, #2152, wiki).
- *EDID override* for adding true timings (the recommended path when "Unsafe" timings are rejected).
- Virtual display refresh cap: 60 Hz (#133); VRR discussion #3500.
- macOS 26: v4.0.0 was the Tahoe-compat release; **BetterDisplay 5 requires macOS 26/27** (v5.0.5, Sep 2025). Tahoe issues listed by the author (#4418): Auto-Brightness fighting the app, HDR detection on first connect, OSD placement, Liquid Glass icon redesign; a WindowServer-crash-at-login report on 26.0.1 (#4752) was attributed to a specific config, and on 26.4.1 an NSStatusItem visibility loop with Control Center (#5314).

**SwitchResX [reported].** Adds custom resolutions by writing override files under a new `DisplayVendorID`; since macOS 10.15.2 no SIP disable is needed (SwitchResX ≥ 4.10). On Apple Silicon: "Activate Immediately" may not work on M1, custom *timings* are largely rejected ("invalid flag"), custom *scaled* resolutions work "before Ventura" per some users, and "custom resolutions don't work with … the internal one on Apple Silicon". SwitchResX lacks HiDPI custom modes on modern MacBooks; guides for 16:9 on M1 recommend BetterDummy/BetterDisplay instead. Treat SwitchResX's built-in-panel path as unreliable on current macOS.

## 4. Open-source references (what they call, what they admit)

| Project | Enumerate | Set | Notes/limits |
|---|---|---|---|
| **displayplacer** (C) [verified source] | private `CGSGetNumberOfDisplayModes` / `CGSGetDisplayModeDescriptionOfLength(…, 0xD4)` into a `modes_D4` union (`width,height,depth,freq,density`) | private `CGSConfigureDisplayMode(config, id, modeNum)` inside a public `CGBeginDisplayConfiguration` … `CGCompleteDisplayConfiguration(kCGConfigurePermanently)`; also `CGSConfigureDisplayEnabled`, `CGConfigureDisplayMirrorOfDisplay`, `CGConfigureDisplayOrigin` | picks highest hz then depth when unspecified; `scaling:on` ⇔ density==2.0; README: some listed modes "do not work"; rotating internal screen "may crash computer"; no way to add modes (#81) |
| **SimpleDisplay** (Swift, GPL-3) [verified source] | public `CGDisplayCopyAllDisplayModes` + `kCGDisplayShowDuplicateLowResolutionModes`, filtered by `isUsableForDesktopGUI()`, HiDPI = `pixelWidth != width` | public transaction, `.permanently` by default; matches by pixelWidth + refresh ±0.1 | private `CGVirtualDisplay*`, `CGSConfigureDisplayEnabled`; sandbox off; notarized; macOS 14+; virtual display 60 Hz cap; virtual display **cannot be a mirror target** on 26 (WindowServer crash) |
| **screenresolution** (jhford) | `CGDisplayCopyAllDisplayModes(display, NULL)` | transaction, `kCGConfigureForSession` | Retina PR #23 never merged |
| **RDM** (avibrazil) | `CGDisplayCopyAllDisplayModes` | — | archived Dec 2023; ⚡ marks HiDPI |
| **displaymode** (p00ya) | public | public | README notes Ventura+ System Settings covers most needs |
| **ResolutionMenu** (robbertkl) | "CoreGraphics private APIs… to access the HiDPI display modes" | — | "might not get accepted into the App Store"; uses deprecated `CGDisplayIOServicePort` |
| **EasyRes / Any Screen Resolution / Display Menu** (Mac App Store) | public with duplicate flag | public | EasyRes: "does not have privileges to create new or alternate resolution modes"; Jibapps' *Displays* left MAS because it "could not live… without breaking support for Retina resolutions" |
| **KhaosT/CGVirtualDisplay, go-macos/virtualdisplay, node-mac-virtual-display, DeskPad, opendisplay** | — | — | all `CGVirtualDisplay`; none App Store |

`cscreen` and `DisplayModeSwitcher` did not surface as maintained projects.

## 5. Private/virtual display route

**Classes [verified: dumped headers + `dyld_info` on macOS 27.0]:** `CGVirtualDisplayDescriptor` (`name, vendorID, productID, serialNum, sizeInMillimeters, maxPixelsWide/High, dispatchQueue, terminationHandler`), `CGVirtualDisplay(initWithDescriptor:)` (readonly `displayID, modes, hiDPI…`), `CGVirtualDisplaySettings` (`hiDPI` uint, `modes` array), `CGVirtualDisplayMode(initWithWidth:height:refreshRate:)`, `-[CGVirtualDisplay applySettings:]`. All four `OBJC_CLASS_$_…` symbols plus `CGVirtualDisplaySettingsRefreshDeadlineNone` and `kCGSVirtualDisplay*` keys are **still exported by CoreGraphics on macOS 27.0 (26A5425a)**. Also still exported: `CGSConfigureDisplayMode/Enabled/MirrorOfDisplay/Origin`, `CGSGetDisplayList` (re-exported from SkyLight as `SLS*`).

**Behaviour [reported, go-macos + SimpleDisplay tests on 26.x]:** release the object to destroy the display, unless its mode was ever changed, in which case it lives until process exit; displays vanish on crash/SIGKILL (no phantoms); macOS remembers arrangement/mode by (vendor, product, serial) so use stable identity; a process that enumerated displays *before* creating a virtual one can't get `CGDisplayMode` for it (other processes can); `hiDPI=1` makes macOS *advertise* 2x modes; refresh accepted 1–240 but effectively 60 Hz; removal is async (~2 s). `terminationHandler` blocks can crash at shutdown; leave nil.

**Mirroring the built-in panel to a virtual display [reported, critical]:** SimpleDisplay's 81-scenario matrix on macOS 26.6.2: `CGConfigureDisplayMirrorOfDisplay` with a **virtual display as the mirror (slave)**, whether master is physical or virtual, **crashes WindowServer**; **virtual master → physical slave works** ("physical adopts master's resolution"). That is exactly BetterDisplay's direction ("mirror the virtual screen *to* your real screen", #3467), and it is the direction ForceRes must use: create virtual 1920x1080 (hiDPI as desired) → make the MacBook panel a mirror of it. Known macOS bugs in that state: panel can't sleep, occasional flicker, brightness sync bug (fixed in-app by BetterDisplay #3931), Sequoia betas crashed WindowServer for odd aspect ratios (#3198/#3199). Also macOS 26.4 broke DriverKit virtual HID for built-in keyboards (forum 817009), a reminder that Apple churns these layers.

**App Store / notarization [verified].** App Review rejects private API (go-macos, opendisplay, SimpleDisplay all say MAS is impossible). Notarization is not App Review: Apple DTS (thread 702740) confirms the notary service "does not currently do any sort of quality checks". Developer ID + notarization works (SimpleDisplay 1.6.1 is notarized), but "we can't predict the future".

## 6. HiDPI vs low-res: which "1080p" do users want?

- **Low-res 1920x1080 (px 1920x1080):** framebuffer and (on externals) the signal are 1080p; UI is 1x, tiny/blurry on Retina; 4x fewer pixels to composite. On externals the monitor may still receive native timing with GPU upscaling (BetterDisplay #1878).
- **HiDPI "looks like 1920x1080" (px 3840x2160):** 2x UI, identical layout metrics to 1080p (NSScreen frame is 1920x1080 points), crisp, but full 4K GPU/compositor cost.

Recommendations: (a) **gaming performance → low-res** (fewer pixels; note macOS games often pick their own modes and full-screen apps make `CGCompleteDisplayConfiguration` fail). (b) **recording/streaming at exact size → HiDPI "looks like"** for a sharp master that downsamples cleanly to 1080p, *or* low-res if the capture must be 1:1 pixels (ScreenCaptureKit captures backing pixels, so HiDPI 1080p captures at 3840x2160; set the stream size explicitly). (c) **apps that misbehave at odd resolutions → HiDPI** (they see a standard 1920x1080 point grid and scale 2). **Decision: HiDPI when a 2x variant exists, with a "Low resolution (1x)" toggle**, matching System Settings' own convention (`Scale=2` in the prefs plist) and BetterDisplay's advice. On a 1080p-native external monitor only the 1x variant exists (Apple Silicon offers no HiDPI on sub-4K panels); fall back automatically.

## 7. 4K on displays that can't do 4K natively

[verified] Public API cannot: no mode with pixelWidth 3840 will be listed for a 1440p or MacBook panel (M1 MBA list tops at 2560x1600; 14" list at 3024x1964). [reported] BetterDisplay does it two ways: (1) flexible-scaling override adds a 3840x2160 HiDPI (7680x4320 backing) or 3840x2160 1x framebuffer that the DCP downsamples to the panel, subject to the 6K/8K/6720-px caps, so 4K HiDPI is impossible on base M1/M2 and on all M4/M5 non-8K setups, while 3840x2160@1x (supersampled to the panel) is within budget; (2) virtual 3840x2160 screen mirrored to the panel ("enables scaling beyond the native resolution of the display panel on Apple Silicon"). smcleod.net built exactly this workaround app (virtual display + hardware mirror) to get 4K HiDPI on an M5 Max. For ForceRes, "4K" on a non-4K display = virtual display route only; expect 60 Hz and letterboxing on 16:10 panels.

## 8. Sandbox, entitlements, TCC

- [verified] No entitlement exists for display configuration; sandboxed MAS apps (Any Screen Resolution, EasyRes, Display Menu) do call `CGDisplayCopyAllDisplayModes` + `CGConfigureDisplayWithDisplayMode`; session-scope switching works in the sandbox.
- [reported, unanswered Apple thread 47302] since 10.11.5 `kCGConfigurePermanently` **does not persist across reboot from a sandboxed app**; switching works, persistence doesn't. Mitigation: re-apply on launch/login-item, or ship non-sandboxed with Developer ID.
- Private APIs (`CGVirtualDisplay`, `CGSConfigureDisplayMode`, `CGSConfigureDisplayEnabled`) ⇒ no sandbox/MAS at all (SimpleDisplay ships `com.apple.security.app-sandbox = false`).
- TCC: mode switching, mirroring and virtual-display creation need **no** Accessibility or Screen Recording permission (SimpleDisplay requests none). Screen Recording is needed only if you *capture* a display (`CGDisplayStream`/ScreenCaptureKit) to draw the virtual screen in a window; DeskPad and BetterDisplay's "streaming"/PIP modes need it. Writing `/Library/Displays/...` overrides needs admin auth (BetterDisplay prompts), not SIP disable.

## 9. macOS 26 Tahoe / macOS 27

[verified from Apple RC release-notes JSON] macOS 27: "menu bar and context menus present a reduced set of menu item images… do not display images set on menu elements by default" (review HIG for which items keep images); fix for "connecting two identical displays (same model and serial number)… the second display might not light up"; "Accessory Access does not work inside App Sandbox" fixed. Nothing in either notes list deprecates Quartz Display Services; all CG display symbols above still export on 27.0. [reported] macOS 27 adds 5K@120 Hz and "improved display-position persistence", HDR UI, 5K mirroring; macOS 26 added HDMI 2.1 high-refresh modes; macOS 27 is the last Rosetta release (ship arm64). Community reports on Tahoe: WindowServer instability (26.2/26.3), `CGSetDisplayTransferByTable` broken on 26.3.1/26.4 with M5 (forum 819331), `CGVirtualDisplay`-as-mirror-target crash (SimpleDisplay), identical-serial ColorSync deadlock (SimpleDisplay docs).

**Menu bar/Liquid Glass [reported]:** Tahoe's transparent menu bar needs **template images** (set `isTemplate`, monochrome) for contrast (ControlPlane #89, Maccy #1224); several apps hit NSStatusItem never being hosted / visibility loops with Control Center (BetterDisplay #5314 on 26.4.1, CodexBar #3377 on 26.6.2, paneru #392); `NSStatusItem.isVisible` can be true while hidden behind the notch; macOS 27 tightens which menu items show images. Use `MenuBarExtra` (or `NSStatusItem` with a template SF Symbol), keep the menu icon-free except where HIG allows, and don't rely on `isVisible`.

## 10. Refresh rate handling

- [verified measurement] On a 4K 240 Hz external, every resolution is enumerated at 240/120/60/30 Hz (plus 75/72/70 for legacy 4:3), in both 1x and HiDPI; so preserve the rate by filtering candidates to `pixelWidth/Height` match and choosing `max(refreshRate)`, tie-break on `kDisplayModeSafeFlag` then depth (displayplacer's exact policy: "highest hz and then the highest color_depth"). Compare rates with tolerance (59.94 vs 60). The prefs plist records `IsVRR = true` for the current mode; Apple's options for VRR show as "Variable/Adaptive". [reported] Sequoia+ enforces a conservative framebuffer pixel-clock limit: some HiDPI modes disappear at 120–240 Hz or in HDR (BetterDisplay #3406: e.g., 3440x1440 HiDPI@240 capped to 3168x1782; QHD@120 HiDPI only 1920x1080). The enumeration itself tells the truth per chip; do not hardcode.
- [reported] **ProMotion built-ins** expose per resolution: `ProMotion` (adaptive up to 120), 60, 50, 48 Hz (cechacek list; Apple HT102297 lists 120/60/59.94/50/48/47.95). `CGDisplayMode.refreshRate` for the adaptive entry is not documented; BetterDisplay users could not force a fixed 120 (#1267). [inference] Treat refreshRate==0 or the max as "ProMotion" and prefer it; label it as such.
- Virtual displays are stuck at 60 Hz regardless of `CGVirtualDisplayMode.refreshRate` (#133, SimpleDisplay).

---

## Recommended architecture for ForceRes

**Tier 1, public API only (works sandboxed, App Store-safe):**
1. Enumerate with `CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true])`; keep `isUsableForDesktopGUI()` modes by default.
2. For each target (720p/1080p/1440p/4K) build two candidates: HiDPI (`width==W && pixelWidth==2W`) and 1x (`pixelWidth==W`); pick the highest refresh, prefer Safe.
3. Apply via `CGBeginDisplayConfiguration` / `CGConfigureDisplayWithDisplayMode` / `CGCompleteDisplayConfiguration(.permanently)`; on failure retry `.forSession`; re-apply saved choice on launch and on `CGDisplayRegisterReconfigurationCallback` topology changes (covers sandbox non-persistence and per-topology reversion). Identify displays by `CGDisplayCreateUUIDFromDisplayID`, never by `CGDirectDisplayID`.
4. Grey out unavailable presets instead of hiding them, with a short reason.

**Tier 2, private, Developer ID + notarized, non-sandboxed:** "Virtual mode" for MacBook panels and for 4K-on-non-4K. Create `CGVirtualDisplay` (stable vendor/product/serial per preset, name e.g. "ForceRes 1080p", sizeInMillimeters chosen for the target DPI, `hiDPI` per user toggle, single `CGVirtualDisplayMode` at 60 Hz), then `CGConfigureDisplayMirrorOfDisplay(config, builtinID, virtualID)` (**virtual = master, physical = mirror**; never the reverse), commit `.forSession`, dissolve mirrors before sleep and on quit. Runtime-guard with `NSClassFromString` and behind a feature flag so a future macOS can degrade to Tier 1. Optionally use `CGSConfigureDisplayMode` to reach the ~10% of modes the public API hides.

**Impossible via public API:** adding any mode not enumerated (16:9 on Apple Silicon built-ins, 4K on sub-4K panels), creating virtual displays, disabling a display, refresh >60 Hz on virtual displays, reliable reboot persistence from a sandbox.

## Risks and unknowns

- Private symbols can vanish in any point release; macOS 26.x already broke adjacent private layers. Ship with runtime checks and a Tier 1 fallback.
- Virtual-mirror side effects on laptops: no panel sleep, flicker, brightness sync, letterboxing on 16:10 panels, 60 Hz cap, and cursor glitches. Document them in-app.
- No MacBook built-in was measured on macOS 26/27 (the dev Mac has no internal panel); the built-in mode lists come from an M1 Air (2021), a BetterDisplay-augmented 14" list, and a 16" M1 Max report. Verify on a real 14"/16" with a fresh `CGDisplayCopyAllDisplayModes` dump before finalizing UI copy.
- Whether committing a non-Safe (flag 0x1) mode is accepted, and what the private-only `0x40000000` modes are, is untested.
- `kCGConfigurePermanently` + sandbox behaviour rests on one unanswered 2016 Apple thread.
- Full-screen apps cause `CGCompleteDisplayConfiguration` failures; handle and surface the error.

## Sources

- Apple SDK headers on this machine: `CoreGraphics/CGDirectDisplay.h`, `CGDisplayConfiguration.h`, `IOKit/graphics/IOGraphicsTypes.h` (Command Line Tools SDK); `dyld_info -exports` of CoreGraphics/SkyLight on macOS 27.0 26A5425a; `/Library/Preferences/com.apple.windowserver.displays.plist`.
- Apple docs: https://developer.apple.com/documentation/coregraphics/cgcompletedisplayconfiguration(_:_:) · https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/QuartzDisplayServicesConceptual/Articles/DisplayModes.html · https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/QuartzDisplayServicesConceptual/Articles/DisplayTransactions.html · https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes · https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes · https://support.apple.com/en-us/102297 · https://developer.apple.com/macos/whats-new/
- Apple forums: https://developer.apple.com/forums/thread/47302 (sandbox + permanent config) · https://developer.apple.com/forums/thread/702740 (notarization + private API) · https://developer.apple.com/forums/thread/693753 (14" MBP 3024x1964 vs 1890) · https://developer.apple.com/forums/thread/668252 · https://developer.apple.com/forums/thread/709586 · https://developer.apple.com/forums/thread/819331
- displayplacer: https://github.com/jakehilborn/displayplacer (src/DisplayPlacer.c, src/Header.h) · https://github.com/jakehilborn/displayplacer/issues/81
- SimpleDisplay (unrelated existing app): https://simpledisplay.app/ · https://github.com/SamuelRioTz/SimpleDisplay (Sources/SimpleDisplay/Services/DisplayService.swift, Sources/VirtualDisplayBridge/VirtualDisplayWrapper.m, Entitlements.plist, docs/real-disable-vm/README.md)
- CGVirtualDisplay: https://github.com/KhaosT/CGVirtualDisplay (CGVirtualDisplayPrivate.h, ViewController.swift) · https://github.com/w0lfschild/macOS_headers/blob/master/macOS/Frameworks/CoreGraphics/1336/CGVirtualDisplay.h · https://pkg.go.dev/github.com/go-macos/virtualdisplay · https://github.com/enfp-dev-studio/node-mac-virtual-display · https://github.com/Stengo/DeskPad · https://github.com/peetzweg/opendisplay · https://news.ycombinator.com/item?id=45201767
- Private CGS: https://github.com/NUIKit/CGSInternal/blob/master/CGSDisplays.h
- BetterDisplay: https://github.com/waydabber/BetterDisplay · wiki https://github.com/waydabber/BetterDisplay/wiki/Fully-scalable-HiDPI-desktop · https://github.com/waydabber/BetterDisplay/wiki/MacOS-scaling,-HiDPI,-LoDPI-explanation · discussions/issues #121, #133, #261, #1267, #1878, #2152, #2507, #3080, #3198, #3199, #3401, #3406, #3467, #3500, #3931, #4418, #4752, #4920, #5314 · releases https://github.com/waydabber/BetterDisplay/releases · CLI list https://cechacek.com/betterdisplay-cli-command-line-interface
- BetterDummy: https://github.com/aonez/BetterDummy (fork of waydabber/BetterDummy)
- SwitchResX: https://www.madrau.com/support/support/srx_1011.html · https://www.madrau.com/support/support/faq_files/ns_Is_SwitchResX_compatible_with_A.html · https://discussions.apple.com/thread/252103337 · https://howtoegghead.com/instructor/style-guide/convert-screen-res-mac-m1/
- Other tools: https://github.com/jhford/screenresolution/blob/master/cg_utils.c · https://github.com/avibrazil/RDM · https://github.com/p00ya/displaymode · https://github.com/robbertkl/ResolutionMenu · https://github.com/th507/screen-resolution-switcher · https://github.com/danXNU/DisplayManager · https://apps.apple.com/us/app/any-screen-resolution/id6444128384 · https://apps.apple.com/us/app/display-menu/id549083868 · https://easyres.softwar.io/ · https://www.jibapps.com/apps/displays/
- M4/M5 HiDPI cap: https://smcleod.net/2026/03/new-apple-silicon-m4-m5-hidpi-limitation-on-4k-external-displays/
- 16:9 on MacBooks: https://junian.dev/tech/macos-16-9-screen-resolution · https://exlima.net/how-to-change-macbook-resolution-to-widescreen-169-for-screen-recording/ · https://pslabo.hatenablog.com/entry/2020/07/20/120928 (Intel MBP list)
- Tahoe/menu bar: https://github.com/scottdensmore/ControlPlane/issues/89 · https://github.com/p0deje/Maccy/issues/1224 · https://github.com/steipete/CodexBar/issues/3377 · https://github.com/karinushka/paneru/issues/392 · https://appaddict.app/post/mac-menu-bar-chaos
- macOS 27 coverage: https://www.macworld.com/article/3139330/macos-27-mac-features-siri-apple-intelligence-release-date-compatibility.html · https://9to5mac.com/2026/09/09/macos-27-golden-gate-here-are-apples-full-release-notes/
- Display prefs plist: https://kb.plugable.com/docking-stations-and-video/how-do-i-remove-display-configurations-or-reset-display-persistence-in-macos

---

## Addendum: live findings on this Mac (macOS 27.0, M4, 2026-09-13)

Measured with `forceres-dev` (internal tool) on the Odyssey G80SD. All **[verified]**.

- `CGConfigureDisplayWithDisplayMode` to 1920x1080 HiDPI @240 Hz (mode id 102) with
  `kCGConfigureForSession` applies instantly and reverts instantly to 2560x1440 HiDPI @240.
- A `CGVirtualDisplay` created with a single 1920x1080 mode and `hiDPI = 0` comes online in
  ~0.35 s, defaults to 1920x1080 @60, and macOS adds its own stock modes (800x600 … 1600x1200).
- With `hiDPI = 1` and only a 3840x2160 mode, macOS advertises **no** "looks like 1920x1080"
  mode; the display defaults to a stock 1920x1080 1x mode. Supplying modes
  `[3840x2160, 1920x1080]` with `hiDPI = 1` makes the display **default to 1920x1080 HiDPI
  (3840x2160 backing)** with the native + default flags. No mode switch is needed.
- Per-process mode cache: if the process called `CGDisplayCopyAllDisplayModes` (on any display)
  before creating a virtual display, then for that virtual display `CGDisplayCopyAllDisplayModes`
  returns an empty array and `CGDisplayCopyDisplayMode` returns nil, permanently. Pumping the run
  loop for 5 s does not help. `CGDisplayBounds`, `CGDisplayPixelsWide/High` and
  `CGDisplayMirrorsDisplay` still work. Consequence: the app must never depend on enumerating its
  own virtual displays; correctness comes from choosing the mode list at creation.
- Mirroring the physical display onto a 1x 1920x1080 virtual master (`CGConfigureDisplayMirrorOfDisplay`,
  session scope) works: the Odyssey switched to 1920x1080 1x **at 240 Hz** (a new mode id, 267,
  appeared in an expanded 272-entry list), `CGDisplayMirrorsDisplay` reported the virtual id,
  and removing the mirror restored 2560x1440 HiDPI @240. The un-mirror took ~7 s to settle.
- **Teardown after mirroring:** a virtual display that was never mirrored disappears ~2.5 s after
  its `CGVirtualDisplay` object is released. A virtual display that has been a mirror master does
  **not** disappear when released, even after un-mirroring and settling for 2 s and waiting 30 s.
  It disappears the moment the owning process exits. Hence virtual displays are owned by the
  `forceres-vdhost` helper process, one per display, and "destroy" means "terminate the helper".
- Once, a freshly created virtual display became the main display (bounds at 0,0) and took >10 s
  to remove; not reproduced in later runs. Treat display arrangement as untrusted after creation.
- **Per-process display list goes stale after this process changes configuration.** Once a
  process has completed a `CGBeginDisplayConfiguration`/`CGCompleteDisplayConfiguration`
  transaction, its `CGGetOnlineDisplayList` and `CGDisplayGetDisplayIDFromUUID` stop picking up
  displays that other processes add or remove: a virtual display created by the helper stayed
  invisible to the parent for 15 s (with a registered reconfiguration callback and a pumped main
  run loop), `CGConfigureDisplayMirrorOfDisplay` then failed with `kCGErrorIllegalArgument`
  (1001), and a removed display stayed listed for 30 s. The reconfiguration callback announcing
  the new display fired only *after* the failed transaction. **Cure:** an empty transaction
  (`CGBeginDisplayConfiguration` + `CGCompleteDisplayConfiguration(.forSession)` with no changes)
  refreshes the list immediately (measured 1 → 2 displays), after which the mirror succeeds.
  `CoreGraphicsDisplayService.refreshDisplayList()` does exactly this; the controller calls it
  after the helper publishes and two seconds after a helper is stopped.
- **Physical vs virtual displays.** Every physical panel (built-in or external) has an
  `IOMobileFramebuffer` service whose `DisplayAttributes.ProductAttributes` carries
  `LegacyManufacturerID` and `ProductID` equal to `CGDisplayVendorNumber` and
  `CGDisplayModelNumber` (Odyssey: 19501 / 57397). A `CGVirtualDisplay` (ours: vendor 0x4652) has
  no framebuffer service at all. `PhysicalDisplayDetector` uses this to prove a mirror target is
  physical; anything else is refused with `DisplayError.notAPhysicalDisplay`, which keeps
  third-party virtual displays out of the virtual-to-virtual mirror crash.
- **Empty configuration transactions are silent.** Three runs of
  `forceres-dev virtual 1920x1080 --observe --refresh` showed no reconfiguration callback between
  the refresh markers, while the same process did receive `began`/`ended` for its own mirror and
  un-mirror transactions. Also observed: no callback fires in one process when *another* process
  creates or removes a virtual display. So `refreshDisplayList()` needs no self-event suppression.

---

## 11. Refresh rate and variable refresh (measured 2026-09-14)

- **Rates are per mode entry.** Every (point size, pixel size) family on the Odyssey lists 240,
  120, 60 and 30 Hz as separate entries; CoreGraphics reports whole Hz here even though the EDID
  carries 59.94/119.88 timings. 144 Hz never appears because the EDID has no 144 Hz timing:
  the offered list must come from enumeration, never a hard-coded set. **[verified]**
- **The byte-identical duplicate pairs are fixed/variable twins.** Applying 132 permanently
  set `IsVRR = 0` in cfprefsd; 133 restores `IsVRR = 1`. For 1080p HiDPI the order is reversed
  (102 variable, 103 fixed), so id order means nothing. Nothing public distinguishes an inactive
  pair member: `refreshRate`, `ioFlags`, `CFCopyDescription`, IOKit attributes and displayplacer's
  private mode struct are identical. **[verified]**
- **Two ways to tell.** (1) SkyLight's private `SLSIsDisplayModeVRR(displayID, modeID)` (resolved
  with `dlsym`, never linked) answered correctly for all 14 ids tested; `SLSIsDisplayModeProMotion`
  is false for every external mode. (2) Public, but only for the *active* mode: `NSScreen`
  `displayUpdateGranularity == 0` with `minimumRefreshInterval != maximumRefreshInterval` means
  variable. A VRR twin exists only at the top rate of a timing family (240 here); there is no
  variable 120. **[verified]**
- **VRR range** comes from `IOMobileFramebuffer` `DisplayAttributes`: `SupportsVariableRefreshRate`,
  `MinimumVariableRefreshRate`/`MaximumVariableRefreshRate` in 16.16 fixed point (48–240 here).
  Apple's labels: "Variable (48-240 Hertz)" on third-party displays, "Adaptive (…)" on Apple
  displays, "ProMotion" on MacBook Pro panels. **[verified/reported]**
- **ProMotion panels** list one 120 Hz entry per size and it *is* the adaptive one; a fixed 120 Hz
  cannot be forced through any API (BetterDisplay #1267). **[reported]** ForceRes therefore treats
  `SLSIsDisplayModeProMotion == true` as adaptive (`DisplayModeInfo.isAdaptiveRefresh`), but the
  MacBook measurement that would confirm this is still pending; no ProMotion dump has been captured.
- **A rate change is a full mode set** (`kCGDisplaySetModeFlag`), ~0.75 s for fixed rates and
  ~1 s whenever the VRR state flips (link re-train). Treat it like a resolution change: previous
  mode saved, countdown, auto-revert. `kCGConfigurePermanently` persists `Hz` and `IsVRR`; macOS
  harmonises mirror targets to the source, so the virtual-mirror path has no rate choice. **[verified]**
- **Live-test hygiene.** Session-scoped applies never touch
  `com.apple.windowserver.displays`; permanent ones do. Swift Testing runs suites in parallel,
  so any live test that switches modes must live in the `.serialized` live suite, otherwise a
  concurrent virtual-display test can bake a transient mode into the preferences. **[verified]**

---

## 12. Which display a menu bar click belongs to

- **One status item, one window per screen.** With "Displays have separate Spaces" on, AppKit
  backs a single `NSStatusItem` with an `NSStatusBarWindow` per display; the inactive ones hold an
  `NSStatusItemReplicant`. So inside the button's action, `button.window?.screen` is the screen
  that received the click, not the primary. This is how MenuBarExtraAccess and Ice treat it.
  **[reported]** Apple documents no contract for it, so it is a best-effort primary signal.
  https://github.com/orchetect/MenuBarExtraAccess/discussions/1
- **With separate Spaces off** the menu bar exists only on the primary display, so the click can
  only come from there and the question does not arise. **[reported]**
- **`NSScreen.main` is the wrong answer.** Apple documents it as "the screen object containing the
  window with the keyboard focus… not necessarily the same screen that contains the menu bar". It
  names the wrong display whenever another app is active elsewhere. **[verified, Apple docs]**
  https://developer.apple.com/documentation/appkit/nsscreen/1388371-main
- **Pointer fallback.** `NSEvent.mouseLocation` is in AppKit's global space (bottom-left origin at
  the primary screen) and `NSScreen.frame` uses the same space, so
  `screens.first { $0.frame.contains(point) }` needs no flip and holds for displays placed left,
  right, above or below. ForceRes uses it when the button has no window yet. **[verified]**
- **Screen to display id.** `NSScreen.cgDirectDisplayID` exists from macOS 26; before that the
  route is `deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]`. ForceRes uses the new
  API when available and the dictionary otherwise. A `CGDirectDisplayID` is not promised to
  survive a reconnect, so it is resolved fresh on every click and mapped straight to a UUID.
  **[verified, Apple docs + BetterDisplay #3628]**
- **Untested here:** this Mac has one display, so the per-screen behaviour is covered by unit
  tests over screen frames, not by a real two-display click. Worth one manual check.
