# macOS display-mode selection and forced resolutions on Apple Silicon

Technical notes for the display code in ForceRes: what the public CoreGraphics API can set, what Apple Silicon built-in panels enumerate, and how the private `CGVirtualDisplay` route behaves. Tags: **[verified]** primary source or measured here, **[reported]** credible secondary source, **[inference]** reasoning. Measurements come from an Apple M4 Mac mini on macOS 27.0 with one external Samsung Odyssey G80SD (4K, 240 Hz) and no built-in panel.

---

## 1. Public CoreGraphics API

**Enumeration [verified].** `CGDisplayCopyAllDisplayModes(display, options)` honours `kCGDisplayShowDuplicateLowResolutionModes` even though the header calls the options dictionary reserved. On the M4/G80SD: 116 modes without the flag, 242 with it. The extra modes have `ioFlags == 0x1` (`kDisplayModeValidFlag` only) and `CGDisplayModeIsUsableForDesktopGUI() == false`. Modes System Settings shows have `0x3` (Valid|Safe); the display's default mode has `0x7` (|Default); modes whose pixel output equals the panel's native timing carry `0x02000000` (`kDisplayModeNativeFlag`), here `1920x1080 HiDPI (3840x2160 px)` and `3840x2160@1x`. Every mode reports the same 32 bpp encoding, so colour depth is never a tie-break.

**HiDPI identification [verified].** Compare `CGDisplayModeGetPixelWidth/Height` (pixels) with `GetWidth/Height` (points): a "looks like" mode has `pixelWidth == 2*width` (`CGDisplayModeGetPixelDensity` is exported but unofficial). On the G80SD all four targets exist in both variants at 240 Hz, all Safe and GUI-usable:
```
1920x1080  px 3840x2160  240Hz flags=0x02000003 gui=1   HiDPI "looks like 1080p"
1920x1080  px 1920x1080  240Hz flags=0x00000003 gui=1   1x 1080p
1280x720   px 2560x1440  240Hz flags=0x00000003 gui=1
1280x720   px 1280x720   240Hz flags=0x00000003 gui=1
3840x2160  px 3840x2160  240Hz flags=0x02000003 gui=1
```
The public API is sufficient for external displays.

**Setting a mode [verified, SDK header].** `CGDisplaySetDisplayMode` lasts only for the life of the process. The transaction route is `CGBeginDisplayConfiguration`, `CGConfigureDisplayWithDisplayMode(config, display, mode, NULL)`, `CGCompleteDisplayConfiguration(config, scope)` with `kCGConfigureForAppOnly = 0`, `kCGConfigureForSession = 1`, `kCGConfigurePermanently = 2`. A permanent change the UI cannot support silently becomes session-scoped; the call fails for unsupported modes or while another app is full screen; modes in a mirror set are coerced to a compatible mode.

**Persistence [verified].** `kCGConfigurePermanently` (used by displayplacer and SimpleDisplay) writes `/Library/Preferences/com.apple.windowserver.displays.plist`: per display UUID, `CurrentInfo {Wide, High, Hz, Scale, IsVRR, Depth}`, keyed by the connected-display configuration. macOS restores the mode on reboot and reconnect only while the topology matches; a topology change reverts it. A permanent commit while mirroring bakes the mirror into the plist, so commit permanently only when no mirror set is active.

**"Unavailable" flag [verified].** The SDK has no `kCGDisplayModeIsUnavailable`. `ioFlags & kDisplayModeSafeFlag == 0` matched `!CGDisplayModeIsUsableForDesktopGUI()` on all 242 modes. Other IOKit flags: `kDisplayModeStretchedFlag 0x800`, `kDisplayModeInterlacedFlag 0x40`, `kDisplayModeNeverShowFlag 0x80`, `kDisplayModeBuiltInFlag 0x400`.

**Hidden modes [verified].** The duplicate low-res set can be applied with `CGConfigureDisplayWithDisplayMode` (SimpleDisplay, EasyRes and Any Screen Resolution all do). [reported] Non-Safe (flag `0x1`) modes may be refused or substituted (displayplacer README). [inference] Applying an unsafe mode was not tested here. The private `CGSGetNumberOfDisplayModes` returned 267 modes on the same display; the extra 25 carry flags `0x40000000` and are invisible to the public API.

## 2. Built-in laptop panels

- **M1 MacBook Air (2560x1600)** [verified quote, displayplacer #81]: 16 modes: 800x600, 825x525 HiDPI, 840x525, 1024x640 HiDPI, 1024x768, 1152x720, 1280x800 (HiDPI and 1x), 1440x900 (HiDPI and 1x), 1650x1050, 1680x1050 HiDPI, 2048x1280, 2560x1600, 640x480, 720x450 HiDPI. No 1920x1080, no 1280x720. 1080p appears only with an external or AirPlay display attached.
- **14" MacBook Pro (3024x1964)** [verified, cechacek.com `betterdisplaycli` list]: 1,544 entries with BetterDisplay flexible scaling enabled, still no 1920x1080, 1280x720, 2560x1440 or 3840x2160. Entry form: `1512x982 HiDPI ProMotion 10bpc Default Native`, then 60, 50 and 48 Hz variants.
- **16" M1 Max (3456x2234)** [reported, BetterDisplay #4920]: only HiDPI 1728x1117 listed; macOS forced 1920x1080@1x when HiDPI was disabled, so a 16:9 1x timing may exist there (possibly injected by BetterDisplay).
- **Intel Retina MBP (2880x1800)** [verified quote]: stock list included 1920x1080 and 1280x720 1x modes. [inference] Apple Silicon panels dropped the 16:9 low-res timings Intel panels exposed.

**Aspect ratio [reported].** A 16:9 framebuffer on a 16:10 or notch panel is letterboxed (Apple forum 693753; BetterDisplay #1878 "Unsafe" 1920x1080 on a QHD panel shows a black border and is increasingly rejected on Sonoma and later). BetterDisplay's own guidance for 16:9 on a MacBook is a custom HiDPI scaled resolution or a 16:9 virtual screen mirrored to the panel (#2507, #3080, exlima.net). [inference] macOS never stretches anisotropically; unlisted timings are refused, not approximated.

**Conclusion:** on Apple Silicon built-ins the four targets are in neither the public nor the private CGS list and cannot be set; they must be created (override) or simulated (virtual display plus mirror).

## 3. How BetterDisplay and SwitchResX do it

**BetterDisplay [reported].**
- Flexible scaling writes a per-model override plist under `/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-XXXX/DisplayProductID-XXXX` (`scale-resolutions`; admin-writable, not SIP-protected). Needs a reboot, a Pro licence and admin credentials; on Sequoia the native override can corrupt (#3401). Framebuffer caps: 6K horizontal on base M1/M2, 8K on Pro/Max; M4/M5 cap the single-stream pipe at 6720 px (smcleod.net), so 3840x2160 HiDPI (7680 px backing) is not offered on 4K displays with M4/M5. The local M4 list agrees: largest HiDPI is 3008x1692 (6016 px); 3360x1890 appears only at 1x.
- Virtual screens use the private `CGVirtualDisplay` classes (section 5), either hardware-mirrored to the physical display via `CGConfigureDisplayMirrorOfDisplay` or streamed (captured and drawn full screen, which needs Screen Recording). Known drawbacks: the mirrored panel cannot sleep, flicker and colour issues, cursor glitches (#261, #711, #2152).
- EDID override is its recommended path when "Unsafe" timings are rejected. The 60 Hz virtual display cap it reports (#133) is refuted on macOS 27, section 13.
- BetterDisplay 5 requires macOS 26 or later; Tahoe issues it hit include a WindowServer crash at login on 26.0.1 tied to one configuration (#4752) and an NSStatusItem visibility loop with Control Center on 26.4.1 (#5314).

**SwitchResX [reported].** Writes override files under a new `DisplayVendorID` (no SIP change since 4.10). On Apple Silicon custom timings are mostly rejected ("invalid flag"), custom scaled resolutions stopped working around Ventura, and nothing works on the internal panel.

## 4. Open-source references (what they call, what they admit)

| Project | Enumerate | Set | Notes |
|---|---|---|---|
| **displayplacer** (C) [verified source] | private `CGSGetNumberOfDisplayModes` / `CGSGetDisplayModeDescriptionOfLength(…, 0xD4)` into a `modes_D4` union (`width, height, depth, freq, density`) | private `CGSConfigureDisplayMode` inside a public transaction committed `kCGConfigurePermanently`; also `CGSConfigureDisplayEnabled`, `CGConfigureDisplayMirrorOfDisplay`, `CGConfigureDisplayOrigin` | highest Hz then depth when unspecified; `scaling:on` means density 2.0; some listed modes "do not work"; cannot add modes (#81) |
| **SimpleDisplay** (Swift, GPL-3) [verified source] | public `CGDisplayCopyAllDisplayModes` with the duplicate flag, filtered by `isUsableForDesktopGUI()`, HiDPI = `pixelWidth != width` | public transaction, permanent by default; matches by pixel width and refresh ±0.1 | private `CGVirtualDisplay*` and `CGSConfigureDisplayEnabled`; not sandboxed; notarized; macOS 14+; virtual display cannot be a mirror target on macOS 26 (WindowServer crash) |
| **screenresolution** (jhford), **RDM**, **displaymode** (p00ya) | public, no duplicate flag | public, session scope or none | no HiDPI handling; RDM archived 2023 |
| **ResolutionMenu** (robbertkl) | private CG for HiDPI modes | none | uses deprecated `CGDisplayIOServicePort` |
| **EasyRes / Any Screen Resolution / Display Menu** (Mac App Store) | public with duplicate flag | public | EasyRes cannot create new modes; Jibapps' Displays left the App Store over Retina support |
| **KhaosT/CGVirtualDisplay, go-macos/virtualdisplay, node-mac-virtual-display, DeskPad, opendisplay** | none | none | all `CGVirtualDisplay`; none on the App Store |

## 5. Private/virtual display route

**Classes [verified, dumped headers and `dyld_info` on macOS 27.0].** `CGVirtualDisplayDescriptor` (`name, vendorID, productID, serialNum, sizeInMillimeters, maxPixelsWide/High, dispatchQueue, terminationHandler`), `CGVirtualDisplay(initWithDescriptor:)` (readonly `displayID, modes, hiDPI`), `CGVirtualDisplaySettings` (`hiDPI`, `modes`), `CGVirtualDisplayMode(initWithWidth:height:refreshRate:)`, `-[CGVirtualDisplay applySettings:]`. All four classes, `CGVirtualDisplaySettingsRefreshDeadlineNone`, the `kCGSVirtualDisplay*` keys, `CGSConfigureDisplayMode/Enabled/MirrorOfDisplay/Origin` and `CGSGetDisplayList` (re-exported from SkyLight as `SLS*`) are still exported by CoreGraphics on macOS 27.0.

**Behaviour [reported, go-macos and SimpleDisplay on 26.x; refined by the addendum].** Releasing the object destroys the display unless it was ever reconfigured, in which case it lives until process exit; displays vanish on crash or SIGKILL (no phantoms); macOS remembers arrangement and mode by (vendor, product, serial), so use stable identities; `hiDPI = 1` makes macOS advertise 2x modes; removal is asynchronous (about 2 s). `terminationHandler` blocks can crash at shutdown; leave it nil.

**Mirror direction [reported, critical].** SimpleDisplay's 81-scenario matrix on macOS 26.6.2: `CGConfigureDisplayMirrorOfDisplay` with a virtual display as the mirror (slave) crashes WindowServer whether the master is physical or virtual. Virtual master with physical mirror works: the physical display adopts the master's resolution. This is also BetterDisplay's direction (#3467) and the only one ForceRes uses. Known side effects of that state: the panel cannot sleep, occasional flicker, a brightness sync bug (#3931), and Sequoia betas crashed WindowServer on odd aspect ratios (#3198, #3199).

**Distribution [verified].** App Review rejects private API. Notarization performs no such check (Apple DTS, thread 702740); Developer ID plus notarization works for SimpleDisplay.

## 6. HiDPI vs low-res: which "1080p" do users want?

- **1x 1920x1080 (px 1920x1080):** 1080p framebuffer, 1x UI, blurry on Retina, a quarter of the pixels to composite. An external monitor may still receive native timing with GPU upscaling (BetterDisplay #1878).
- **HiDPI "looks like 1920x1080" (px 3840x2160):** 2x UI with 1080p point metrics, crisp, full 4K compositor cost. ScreenCaptureKit captures backing pixels (3840x2160) unless the stream size is set.

Decision: prefer HiDPI when a 2x variant exists (System Settings' convention, `Scale = 2` in the plist), with a "Low resolution (1x)" toggle for gaming performance and 1:1 capture. On a 1080p-native external only the 1x variant exists (Apple Silicon offers no HiDPI on sub-4K panels); fall back automatically.

## 7. 4K on displays that can't do 4K natively

[verified] The public API lists no 3840-pixel-wide mode on a 1440p or MacBook panel. [reported] BetterDisplay reaches it either with a flexible-scaling override (a 3840x2160 1x or HiDPI framebuffer that the DCP downsamples, subject to the 6K/8K/6720 px caps, so 4K HiDPI is impossible on base M1/M2 and on M4/M5) or with a virtual 3840x2160 screen mirrored to the panel; smcleod.net built the latter for 4K HiDPI on an M5 Max. For ForceRes, 4K on a non-4K display is the virtual display route only; expect letterboxing on 16:10 panels. The rate is not capped (section 13).

## 8. Sandbox, entitlements, TCC

- [verified] No entitlement covers display configuration; sandboxed App Store apps enumerate and switch modes at session scope.
- [reported, unanswered Apple thread 47302] since 10.11.5 `kCGConfigurePermanently` does not persist across reboot from a sandboxed app. Mitigation: re-apply on launch, or ship non-sandboxed with Developer ID.
- Private APIs (`CGVirtualDisplay`, `CGSConfigureDisplayMode`, `CGSConfigureDisplayEnabled`) rule out the sandbox and the App Store entirely.
- TCC: mode switching, mirroring and virtual-display creation need no Accessibility or Screen Recording permission. Screen Recording is needed only to capture a display (`CGDisplayStream`, ScreenCaptureKit), as DeskPad and BetterDisplay's streaming mode do. Writing `/Library/Displays/...` overrides needs admin authorisation, not a SIP change.

## 9. macOS 26 Tahoe / macOS 27

[verified, Apple release notes] macOS 27 shows a reduced set of menu item images by default and fixes two identical displays (same model and serial) where the second did not light up. Nothing deprecates Quartz Display Services; every CG display symbol above still exports on 27.0. [reported] macOS 27 adds 5K@120 Hz and 5K mirroring, macOS 26 added HDMI 2.1 high-refresh modes, and macOS 27 is the last Rosetta release (ship arm64). Tahoe community reports: WindowServer instability on 26.2/26.3, `CGSetDisplayTransferByTable` broken on 26.3.1/26.4 with M5 (forum 819331), the virtual-as-mirror-target crash (section 5), an identical-serial ColorSync deadlock (SimpleDisplay docs).

**Menu bar [reported].** Tahoe's transparent menu bar needs template images (ControlPlane #89, Maccy #1224); several apps hit `NSStatusItem` visibility loops with Control Center (BetterDisplay #5314, CodexBar #3377, paneru #392); `isVisible` can be true while the item is hidden behind the notch. Use a template SF Symbol and do not rely on `isVisible`.

## 10. Refresh rate handling

- [verified] On the 4K 240 Hz external every resolution is enumerated at 240, 120, 60 and 30 Hz (plus 75/72/70 for legacy 4:3 sizes), in both 1x and HiDPI. Preserve the rate by filtering candidates on pixel size and taking `max(refreshRate)`, tie-break on `kDisplayModeSafeFlag` (displayplacer's policy, minus depth). Compare rates with tolerance (59.94 vs 60). The plist records `IsVRR = true` for the current mode. [reported] Sequoia and later enforce a pixel-clock budget that drops some HiDPI modes at 120–240 Hz or in HDR (BetterDisplay #3406); enumeration is the only truth per chip, never a hard-coded list.
- [reported] ProMotion built-ins list `ProMotion` (adaptive up to 120), 60, 50 and 48 Hz per resolution (cechacek list; Apple HT102297 adds 59.94 and 47.95). A fixed 120 Hz cannot be forced (BetterDisplay #1267). See section 11 for how ForceRes classifies the adaptive entry.
- The community claim that virtual displays are stuck at 60 Hz is refuted on macOS 27, section 13.

---

## Recommended architecture for ForceRes

**Tier 1, public API only (externals):**
1. Enumerate with `CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true])`; keep `isUsableForDesktopGUI()` modes.
2. For each target build two candidates, HiDPI (`width == W && pixelWidth == 2W`) and 1x (`pixelWidth == W`); pick the highest refresh, prefer Safe.
3. Apply through the transaction API with `.permanently`, retry `.forSession` on failure; re-apply the saved choice on launch and on topology changes from `CGDisplayRegisterReconfigurationCallback`. Identify displays by `CGDisplayCreateUUIDFromDisplayID`, never by `CGDirectDisplayID`.
4. Grey out unavailable presets with a short reason; never hide them.

**Tier 2, private, Developer ID, notarized, not sandboxed (built-in panels and 4K on non-4K):** create a `CGVirtualDisplay` (stable vendor/product/serial per preset, `sizeInMillimeters` for the target DPI, `hiDPI` per the user toggle, modes `[2x, 1x]`, rate per section 13), then `CGConfigureDisplayMirrorOfDisplay(config, physicalID, virtualID)` with the virtual display as master and the physical panel as mirror, never the reverse. Commit `.forSession`; dissolve mirrors before sleep and on quit. Guard every private symbol at runtime (`NSClassFromString`, `dlsym`) and degrade to Tier 1 when any is missing. See the addendum for why the virtual display lives in a helper process.

**Impossible via the public API:** adding any unlisted mode (16:9 on Apple Silicon built-ins, 4K on sub-4K panels), creating virtual displays, disabling a display, reliable reboot persistence from a sandbox.

## Risks and unknowns

- Private symbols can vanish in any point release; ship runtime checks and the Tier 1 fallback.
- Virtual-mirror side effects on laptops: no panel sleep, flicker, brightness sync, letterboxing on 16:10 panels, cursor glitches. Say so in the UI.
- No MacBook built-in has been measured on macOS 26 or 27; the built-in mode lists in section 2 are second-hand. Capture a real `CGDisplayCopyAllDisplayModes` dump before finalising UI copy.
- Whether a non-Safe (flag `0x1`) mode is accepted, and what the private-only `0x40000000` modes are, is untested.
- The sandbox persistence claim rests on one unanswered 2016 Apple thread.
- Full-screen apps make `CGCompleteDisplayConfiguration` fail; surface the error.

## Sources

- Apple SDK headers: `CoreGraphics/CGDirectDisplay.h`, `CGDisplayConfiguration.h`, `IOKit/graphics/IOGraphicsTypes.h`; `dyld_info -exports` of CoreGraphics and SkyLight on macOS 27.0; `/Library/Preferences/com.apple.windowserver.displays.plist`.
- Apple docs: https://developer.apple.com/documentation/coregraphics/cgcompletedisplayconfiguration(_:_:) · https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/QuartzDisplayServicesConceptual/Articles/DisplayModes.html · https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/QuartzDisplayServicesConceptual/Articles/DisplayTransactions.html · https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes · https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes · https://support.apple.com/en-us/102297 · https://developer.apple.com/documentation/appkit/nsscreen/1388371-main
- Apple forums: https://developer.apple.com/forums/thread/47302 · https://developer.apple.com/forums/thread/702740 · https://developer.apple.com/forums/thread/693753 · https://developer.apple.com/forums/thread/668252 · https://developer.apple.com/forums/thread/709586 · https://developer.apple.com/forums/thread/819331
- displayplacer: https://github.com/jakehilborn/displayplacer (src/DisplayPlacer.c, src/Header.h) · https://github.com/jakehilborn/displayplacer/issues/81
- SimpleDisplay: https://simpledisplay.app/ · https://github.com/SamuelRioTz/SimpleDisplay (DisplayService.swift, VirtualDisplayWrapper.m, Entitlements.plist, docs/real-disable-vm/README.md)
- CGVirtualDisplay: https://github.com/KhaosT/CGVirtualDisplay · https://github.com/w0lfschild/macOS_headers/blob/master/macOS/Frameworks/CoreGraphics/1336/CGVirtualDisplay.h · https://pkg.go.dev/github.com/go-macos/virtualdisplay · https://github.com/enfp-dev-studio/node-mac-virtual-display · https://github.com/Stengo/DeskPad · https://github.com/peetzweg/opendisplay · https://news.ycombinator.com/item?id=45201767
- Private CGS: https://github.com/NUIKit/CGSInternal/blob/master/CGSDisplays.h
- BetterDisplay: https://github.com/waydabber/BetterDisplay · https://github.com/waydabber/BetterDisplay/wiki/Fully-scalable-HiDPI-desktop · https://github.com/waydabber/BetterDisplay/wiki/MacOS-scaling,-HiDPI,-LoDPI-explanation · issues and discussions #121, #133, #261, #711, #1267, #1878, #2152, #2507, #3080, #3198, #3199, #3401, #3406, #3467, #3500, #3628, #3931, #4418, #4752, #4920, #5314 · https://cechacek.com/betterdisplay-cli-command-line-interface
- BetterDummy: https://github.com/aonez/BetterDummy
- SwitchResX: https://www.madrau.com/support/support/srx_1011.html · https://www.madrau.com/support/support/faq_files/ns_Is_SwitchResX_compatible_with_A.html · https://discussions.apple.com/thread/252103337 · https://howtoegghead.com/instructor/style-guide/convert-screen-res-mac-m1/
- Other tools: https://github.com/jhford/screenresolution/blob/master/cg_utils.c · https://github.com/avibrazil/RDM · https://github.com/p00ya/displaymode · https://github.com/robbertkl/ResolutionMenu · https://github.com/th507/screen-resolution-switcher · https://github.com/danXNU/DisplayManager · https://apps.apple.com/us/app/any-screen-resolution/id6444128384 · https://apps.apple.com/us/app/display-menu/id549083868 · https://easyres.softwar.io/ · https://www.jibapps.com/apps/displays/
- M4/M5 HiDPI cap: https://smcleod.net/2026/03/new-apple-silicon-m4-m5-hidpi-limitation-on-4k-external-displays/
- 16:9 on MacBooks: https://junian.dev/tech/macos-16-9-screen-resolution · https://exlima.net/how-to-change-macbook-resolution-to-widescreen-169-for-screen-recording/ · https://pslabo.hatenablog.com/entry/2020/07/20/120928 (Intel MBP list)
- Menu bar on Tahoe: https://github.com/scottdensmore/ControlPlane/issues/89 · https://github.com/p0deje/Maccy/issues/1224 · https://github.com/steipete/CodexBar/issues/3377 · https://github.com/karinushka/paneru/issues/392 · https://github.com/orchetect/MenuBarExtraAccess/discussions/1
- Display prefs plist: https://kb.plugable.com/docking-stations-and-video/how-do-i-remove-display-configurations-or-reset-display-persistence-in-macos

---

## Addendum: live findings on this Mac (macOS 27.0, M4, 2026-09-13)

Measured with `forceres-dev` on the Odyssey G80SD. All **[verified]**.

- **Mode ids on the Odyssey.** The 242-entry list contains byte-identical duplicate pairs under different ids (fixed and variable-refresh twins, section 11). The user's running mode is id 133 (2560x1440 HiDPI @240, variable twin of 132); the default-flagged mode is 103 (1920x1080 HiDPI, the native pixel size), so the default flag is only a fallback, never the mode to restore to. Restore to the recorded id, and when selecting among equal candidates prefer the ids already in use.
- `CGConfigureDisplayWithDisplayMode` to 1920x1080 HiDPI @240 (id 102) at session scope applies instantly and reverts instantly.
- A `CGVirtualDisplay` with a single 1920x1080 mode and `hiDPI = 0` comes online in about 0.35 s at 1920x1080 @60, and macOS adds its own stock modes (800x600 to 1600x1200).
- With `hiDPI = 1` and only a 3840x2160 mode, macOS advertises no "looks like 1920x1080" mode and defaults to a stock 1920x1080 1x mode. Modes `[3840x2160, 1920x1080]` with `hiDPI = 1` make the display default to 1920x1080 HiDPI (3840x2160 backing) with the native and default flags, with no mode switch needed.
- **Per-process mode cache.** If a process called `CGDisplayCopyAllDisplayModes` on any display before creating a virtual display, then for that virtual display `CGDisplayCopyAllDisplayModes` returns an empty array and `CGDisplayCopyDisplayMode` returns nil, permanently; pumping the run loop for 5 s does not help. `CGDisplayBounds`, `CGDisplayPixelsWide/High` and `CGDisplayMirrorsDisplay` still work. The app therefore never depends on enumerating its own virtual displays; the helper reports geometry over stdout.
- **Mirroring** the Odyssey onto a 1x 1920x1080 virtual master (session scope) works: the panel switched to 1920x1080 1x at 240 Hz, a new mode id (267) appeared in a mirror-expanded 272-entry list, and `CGDisplayMirrorsDisplay` reported the virtual id. A mirrored display reports the master's expanded mode list, so a mode picked from a panel still inside or leaving a mirror set comes from the wrong list; the pre-mirror snapshot is the mode source while mirrored. Removing the mirror restored 2560x1440 HiDPI @240 by itself (macOS restores the panel's previous mode once it leaves the mirror set; no mode is applied). The un-mirror took about 7 s to settle.
- **Teardown after mirroring.** A virtual display that was never mirrored disappears about 2.5 s after its object is released. One that has been a mirror master does not disappear on release, even after un-mirroring and waiting 30 s; it disappears the moment the owning process exits. Hence `forceres-vdhost`: one helper process per virtual display, and "destroy" means "terminate the helper".
- Once, a new virtual display became the main display (bounds at 0,0) and took over 10 s to remove; not reproduced. Treat arrangement as untrusted after creation.
- **Stale per-process display list.** Once a process has completed a configuration transaction, its `CGGetOnlineDisplayList` and `CGDisplayGetDisplayIDFromUUID` stop picking up displays other processes add or remove: a helper-created virtual display stayed invisible to the parent for 15 s (with a reconfiguration callback registered and the run loop pumped), `CGConfigureDisplayMirrorOfDisplay` failed with `kCGErrorIllegalArgument` (1001), and a removed display stayed listed for about 30 s while every other process saw it vanish within a second. The callback for the new display fired only after the failed transaction. Cure: an empty transaction (`CGBeginDisplayConfiguration` plus `CGCompleteDisplayConfiguration(.forSession)` with no changes) refreshes the list immediately. `CoreGraphicsDisplayService.refreshDisplayList()` does this; the controller calls it after the helper publishes and two seconds after a helper stops. The app treats its own list as advisory for virtual displays it has retired.
- **Empty transactions are silent.** No reconfiguration callback fires for an empty transaction, and none fires in one process when another process creates or removes a virtual display, so `refreshDisplayList()` needs no self-event suppression.
- **Physical vs virtual.** Every physical panel has an `IOMobileFramebuffer` service whose `DisplayAttributes.ProductAttributes` carries `LegacyManufacturerID` and `ProductID` equal to `CGDisplayVendorNumber` and `CGDisplayModelNumber` (Odyssey: 19501 / 57397). A `CGVirtualDisplay` (ForceRes uses vendor 0x4652) has no framebuffer service. `PhysicalDisplayDetector` uses this to prove a mirror target is physical; anything else is refused with `DisplayError.notAPhysicalDisplay`, which keeps third-party virtual displays out of the virtual-to-virtual crash.

---

## 11. Refresh rate and variable refresh (measured 2026-09-14)

- **Rates are per mode entry [verified].** Every (point size, pixel size) family on the Odyssey lists 240, 120, 60 and 30 Hz as separate entries, reported as whole Hz although the EDID carries 59.94/119.88 timings. 144 Hz never appears because the EDID has no 144 Hz timing: the offered list comes from enumeration only.
- **Duplicate pairs are fixed/variable twins [verified].** Applying id 132 permanently sets `IsVRR = 0` in the plist; 133 restores `IsVRR = 1`. For 1080p HiDPI the order is reversed (102 variable, 103 fixed), so id order means nothing. Nothing public distinguishes an inactive pair member: `refreshRate`, `ioFlags`, `CFCopyDescription`, IOKit attributes and displayplacer's private mode struct are identical.
- **Two ways to tell [verified].** (1) SkyLight's private `SLSIsDisplayModeVRR(displayID, modeID)`, resolved with `dlsym`, answered correctly for all 14 ids tested; `SLSIsDisplayModeProMotion` is false for every external mode. (2) Public, for the active mode only: `NSScreen.displayUpdateGranularity == 0` with `minimumRefreshInterval != maximumRefreshInterval` means variable. A VRR twin exists only at the top rate of a family (240 here); there is no variable 120.
- **VRR range [verified/reported].** `IOMobileFramebuffer` `DisplayAttributes`: `SupportsVariableRefreshRate`, `MinimumVariableRefreshRate` / `MaximumVariableRefreshRate` in 16.16 fixed point (48–240 here). Apple's labels: "Variable (48-240 Hertz)" on third-party displays, "Adaptive" on Apple displays, "ProMotion" on MacBook Pro panels.
- **ProMotion panels [reported].** One 120 Hz entry per size, and it is the adaptive one; a fixed 120 cannot be forced (BetterDisplay #1267). ForceRes treats `SLSIsDisplayModeProMotion == true` as adaptive (`DisplayModeInfo.isAdaptiveRefresh`). Unconfirmed until a ProMotion dump is captured.
- **A rate change is a full mode set [verified]** (`kCGDisplaySetModeFlag`): about 0.75 s for fixed rates, about 1 s when the VRR state flips (link re-train). Treat it like a resolution change: previous mode saved, countdown, auto-revert. `kCGConfigurePermanently` persists `Hz` and `IsVRR`. macOS harmonises mirror targets to the master, so in the virtual-mirror path the rate is the virtual display's (section 13).
- **Live-test hygiene [verified].** Session-scoped applies never touch `com.apple.windowserver.displays`; permanent ones do. Swift Testing runs suites in parallel, so every live test that switches modes belongs in the `.serialized` live suite, or a concurrent virtual-display test can bake a transient mode into the preferences.

---

## 12. Which display a menu bar click belongs to

- **One status item, one window per screen [reported].** With "Displays have separate Spaces" on, AppKit backs a single `NSStatusItem` with an `NSStatusBarWindow` per display (inactive ones hold an `NSStatusItemReplicant`), so inside the button's action `button.window?.screen` is the screen that received the click. MenuBarExtraAccess and Ice rely on this; Apple documents no contract, so it is a best-effort primary signal.
- **With separate Spaces off [reported]** the menu bar exists only on the primary display.
- **`NSScreen.main` is wrong [verified, Apple docs]:** it is the screen with keyboard focus, not the one with the menu bar.
- **Pointer fallback [verified].** `NSEvent.mouseLocation` and `NSScreen.frame` share AppKit's global space (bottom-left origin on the primary screen), so `screens.first { $0.frame.contains(point) }` needs no flip. Used when the button has no window yet.
- **Screen to display id [verified, Apple docs and BetterDisplay #3628].** `NSScreen.cgDirectDisplayID` exists from macOS 26; before that use `deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]`. A `CGDirectDisplayID` may not survive a reconnect, so it is resolved on every click and mapped straight to a UUID.
- **Untested here:** this Mac has one display; per-screen behaviour is covered by unit tests over screen frames, not a real two-display click.

## 13. Virtual display refresh rate (measured 2026-10-25)

Measured with a standalone Objective-C probe and then through `forceres-vdhost`. All **[verified]**. The 60 Hz cap cited in sections 3, 4 and 10 comes from community reports against older releases and does not hold on macOS 27.

- A `CGVirtualDisplay` created with `CGVirtualDisplayMode(width:height:refreshRate:)` runs at exactly that rate. Tested 60, 120, 144, 165, 240, 360 and 480 Hz, 1x and HiDPI (3840x2160 backing): `CGDisplayModeGetRefreshRate` reports the rate and a `CVDisplayLink` on the virtual display ticks at it (120.5, 144.5, 240.5, 360.0, 481.0 ticks/s). 59.94 is listed as 60.
- Mirroring the Odyssey onto a 240 Hz HiDPI 1080p virtual master: the Odyssey runs 1920x1080 HiDPI @240 (id 267 in the mirror-expanded list) and the master's display link ticks 240/s. With a 60 Hz master the Odyssey still reports @240 and its own link ticks 240/s, but the master ticks 60/s. The physical scan-out never drops; what a slow virtual display caps is how often macOS draws it, which the panel then repeats. The rate the user sees is the virtual display's rate.
- Hence `VirtualDisplayPlan.refreshRate`: the panel's highest rate at its native pixel size (`ModeSelector.virtualRefreshRates`), or the saved fixed rate when the panel lists it. Rates offered only at small 4:3 sizes (70/72/75 Hz on the Odyssey) are left out. The helper takes `--hz` and reports the rate it got; the app rebuilds the virtual display to change it.
- Faster than the panel's own scan-out buys nothing; the helper's accepted range (1...1000 Hz) only rejects nonsense.
- A HiDPI virtual size whose 2x backing exceeds the display pipe cap is quietly run at 1x instead of refused (section 14); the settled mode is checked after every sharp build.
- `CGVirtualDisplaySettings` on macOS 27 also has `refreshDeadline` (default 0, `CGVirtualDisplaySettingsRefreshDeadlineNone`) and `isReference`; neither is set.
- **Not yet measured:** a MacBook built-in panel mirroring a 120 Hz virtual master (whether a ProMotion panel scans out at 120 or drops to a fixed timing), and battery cost.

## 14. Custom sizes and the display pipe cap (measured 2026-10-26)

- **[verified]** On this M4 with the Odyssey, `IOMFBMaxSrcPixels` / `MaxSrcRectWidthForPipe[0]` reads 6144 x 4320. The largest sharp (2x) custom size is therefore 3072 x 1728, which the panel does not list (its largest HiDPI mode is 3008 x 1692). Built as a HiDPI virtual display and mirrored, it runs at HiDPI (`LiveAppFlowTests.theLargestSharpCustomSizeMirrorsAtHiDPIAndReverts`).
- **[verified]** A custom size the panel lists (3008 x 1692 HiDPI) applies through public CoreGraphics like a preset and reverts to the recorded mode (`LiveAppFlowTests.aNativeCustomSizeAppliesAndReverts`).
- **[reported]** Past the pipe cap macOS substitutes the 1x twin instead of refusing the mode. ForceRes refuses sharp sizes past the cap up front (`CustomResolutionCheck`) and still checks the settled mode about two seconds into the countdown, telling the user when macOS chose 1x.
- **[inference]** Other chips report other caps (base M1/M2 6K, Pro/Max 8K, M4/M5 6720 or 6144 px). The cap is read per display at runtime rather than tabulated; a MacBook dump is still needed for the built-in panel's value.
