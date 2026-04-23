# Cort:EX ver.02a f5

<img src="assets/preview.png" alt="CortEX Preview">

**Unified E-Hentai / EXhentai / nhentai Viewer for iOS / iPadOS**

[English](README.md) | [中文](README_zh.md) | [日本語](README_ja.md)

---

## Demo

https://github.com/CielDevApp/CortEX/raw/main/assets/demo.mp4

> *Content blurred for privacy*

---

## Features

### Multi-Site Integration
- **E-Hentai / EXhentai** — Auto-switches based on login state. E-Hentai browsable without login
- **nhentai** — Full API integration, automatic Cloudflare bypass (WKWebView cf_clearance), WebP support
- **4-Layer Deleted Gallery Recovery** — nhentai (in-app search) → nyahentai.one → hitomi.la → title copy

### Reader
- **4 Modes** — Vertical scroll / Horizontal paging / iPad spread view / Pinch zoom
- **iPad Spread** — Auto landscape detection, 2-page composite rendering (zero-gap), wide images displayed solo
- **RTL / LTR** — Right-to-left and left-to-right binding with edge-tap page turning
- **Double-tap Zoom** — Live Text (text selection) support

### Image Processing (3 Engines)
- **CIFilter** — Tone curve, sharpening, noise reduction
- **Metal Compute Shader** — Direct GPU pipeline
- **CoreML Real-ESRGAN** — Neural Engine 4x super-resolution (tiled processing)
- **4-Level Quality** — Low → Low+Super-Res → Standard → Standard+Filter
- **HDR Enhancement** — Shadow detail recovery + vibrance + contrast

### Downloads
- **Bidirectional DL (Extreme Pincer)** — Simultaneous forward + backward download
- **Second Pass** — Auto-retry failed pages with exponential backoff
- **Live Activity** — Lock screen + Dynamic Island progress display
- **Read/Download Separation** — "Download remaining?" prompt on close

### Favorites
- **Dual Cache** — Independent E-Hentai / nhentai cache with disk persistence
- **nhentai Sync** — WKWebView SPA rendering → JavaScript ID extraction → API resolution
- **Search / Sort** — Date added (newest/oldest) / Title

### nhentai Detail View
- Title / Cover / Info (language, pages, circle, artist, parody)
- **Tag-tap Search** — One-tap search by artist:name, group:name, etc.
- Thumbnail grid → Tap to jump to page
- Filter pipeline (denoise / enhance / HDR)

### Security
- **Face ID / Touch ID** — Authentication on launch and resume
- **4-digit PIN** — Biometric fallback
- **App Switcher Blur** — Content hidden in task switcher
- **Keychain Encryption** — Secure cookie and credential storage

### Backup
- **PHOENIX MODE** — E-Hentai + nhentai unified JSON favorites backup
- **Extreme Safety Lock** — EXTREME MODE requires backup first
- **.cortex Export** — Gallery ZIP package

### Performance
- **ECO Mode** — NPU/GPU disabled, 30Hz, iOS Low Power Mode sync
- **EXTREME MODE** — All limiters removed (20 parallel, zero delay)
- **CDN Fallback** — i/i1/i2/i3 auto-switch + extension fallback (webp→jpg→png)

### Translation
- **Vision OCR** → Apple Translation API → Image burn-in
- 5 languages (JA/EN/ZH/KO/Auto)

### AI (iOS 26+)
- **Foundation Models** — Auto genre classification, tag recommendations

### UI/UX
- **TipKit (11 tips)** — Operation hints for all features, re-displayable from settings
- **8 Languages** — JA / EN / ZH-Hans / ZH-Hant / KO / DE / FR / ES
- **Dynamic Tabs** — Auto-switch E-Hentai ↔ EXhentai based on login
- **Benchmark** — CIFilter vs Metal speed test with device model display
- **Lock Screen Wallpaper** — Favorites gallery covers automatically appear as lock screen background (blurred until unlock)

<img src="assets/lockscreen.png" width="300" alt="Lock Screen Wallpaper">
- **Tab Bar Auto-Hide** — Scrolling down hides the tab bar for more content space

---

## Architecture

Single codebase running on iPhone / iPad / Mac. Built entirely on 20 native Apple frameworks with zero external library dependencies.

**9-Layer Stack:**

| # | Layer | Contents |
|---|---|---|
| 01 | PRESENTATION | 4-mode reader (vertical scroll / horizontal paging / iPad spread / pinch-zoom) |
| 02 | MODES | SAFETY (default) / EXTREME / ECO / SPARE tiers |
| 03 | INGESTION | E-Hentai / EXhentai dynamic switch, nhentai v2 API with Cloudflare Turnstile bypass |
| 04 | TRANSPORT | BackgroundDownloadManager, URLSession background DL, 6-path BAN containment, 2ndpass concurrency 5 |
| 05 | COMPUTE | Three image pipelines (CIFilter / Metal Compute / CoreML Real-ESRGAN) |
| 06 | MEDIA | Animated WebP / HEVC conversion, HDR enhancement, VideoToolbox hardware encoding |
| 07 | SILICON | Full CPU / GPU (Metal) / NPU (CoreML) / Media Engine utilization across iPhone A17 Pro / iPad A17 Pro / Mac M1–M4 |
| 08 | TRUST | Face ID / Touch ID / PIN / Keychain / App Switcher blur |
| 09 | PLATFORM | iOS 18+ / iPadOS 18+ / macOS 14+ Mac Catalyst, 8-language localization |

**SAFETY MODE features:**
- 6-path BAN detection and containment
- Automatic 50-page / 60-second cooldown
- 2ndpass concurrency 5 for automatic page recovery
- Parallelism preserved — no speed sacrifice
- `disk prefix skip` + `reconcileGallery`

**Build facts:**
- 77 Swift files / ~20,000 lines
- External library dependencies: 0
- Apple native frameworks: 20
- Supports iOS 18+ / iPadOS 18+ / macOS 14+

---

## Requirements
- iOS 18.0+ / iPadOS 18.0+ (iOS 26 / iPadOS 26 tested)
- macOS 14.0+ (Mac Catalyst, Apple Silicon / Intel)
- iPhone / iPad (iPad spread mode supported) / Mac

## Installation

### iOS / iPadOS — Build from Source
1. Clone: `git clone https://github.com/CielDevApp/CortEX.git`
2. Open `EhViewer.xcodeproj` in Xcode 16+
3. Select your Team in Signing & Capabilities
4. Change Bundle Identifier to something unique (e.g. `com.yourname.cortex`)
5. Connect your device and hit Run

### iOS / iPadOS — Sideload (no Mac)
1. Grab `EhViewer-<version>.ipa` from [Releases](https://github.com/CielDevApp/CortEX/releases/latest)
2. Install via AltStore, Sideloadly, or TrollStore
   - AltStore / Sideloadly re-sign with your Personal Team on import, so the shipped signature is stripped — any recent IPA works.
   - TrollStore installs as-is (no re-sign needed).

> Note: Free Apple Developer accounts have a 7-day signing limit on sideloaded apps. Use AltStore for auto-refresh.

### Mac (Catalyst) — prebuilt
1. Grab `EhViewer-macOS-<version>.zip` from [Releases](https://github.com/CielDevApp/CortEX/releases/latest) (Developer ID signed + Apple notarized)
2. Unzip and drag `EhViewer.app` into `/Applications`
3. Double-click to launch — no `xattr` hacks needed, Gatekeeper passes cleanly

### Mac (Catalyst) — build from source
1. Clone: `git clone https://github.com/CielDevApp/CortEX.git`
2. Open `EhViewer.xcodeproj` in Xcode 16+
3. Scheme = `EhViewer`, Destination = `My Mac (Mac Catalyst)`
4. Select your Team in Signing & Capabilities and change the Bundle Identifier
5. Product → Run to launch, or Product → Archive to export a `.app` and drop it into `/Applications`
   - CLI: `xcodebuild -project EhViewer.xcodeproj -scheme EhViewer -destination 'platform=macOS,variant=Mac Catalyst' build`
6. The Mac build ships a custom 7-tab bar (Gallery / Favorites / Gacha / Downloads / History / Character / Settings) that stays horizontal at all window widths

## Built With
- Swift / SwiftUI
- 76 Swift files / ~20,000 lines
- Metal / CoreML / Vision / WebKit / ActivityKit / TipKit

## Changelog

### ver.02a f6 (2026-04-23)
- **Mac Catalyst Universal Build** — Full macOS 14+ support on Apple Silicon and Intel. Developer ID signed + Apple-notarized `.app` distributed via GitHub Releases; drop into `/Applications` and double-click to launch. The top tab bar was reimplemented as a custom HStack (replacing SwiftUI TabView to avoid the Catalyst overflow menu) so all 7 tabs stay horizontal with full-cell hit targets and arrow-key paging
- **EXTREME MODE → SAFETY MODE Redesign** — Pivoted from aggressive to defensive. 6-path BAN detection and containment, automatic 50-page / 60-second cooldown, parallelism preserved with no speed sacrifice. The transport layer now integrates 509 gif URL pattern detection, Cloudflare `cf-mitigated` header detection, HTML fallback detection, and home.php misredirect detection
- **Animated WebP Reader Upgrades** — Unified manual play mode (▶ tap to start conversion), HDR enhancement merged into the existing image filter settings, long-press menu for direct mode switching. Detection unified via the VP8X magic; raw bytes are offloaded from memory to disk URLs to reduce memory pressure
- **Animated WebP Hang Fix** — Fixed memory spike and UI hang caused by auto-playback in LocalReader / GalleryReader. AVPlayer promotion is now limited to the current page, cache promotion moved to init, PlayerContainerView no longer absorbs scroll gestures, and the cache-resurrection remount loop was eliminated
- **nhentai Login on Mac Catalyst** — Worked around the `-34018 errSecMissingEntitlement` Keychain error with a file-based fallback (`~/Documents/EhViewer/creds/`), fixed the Cloudflare bypass path, and restored persistent auth on Catalyst
- **iPad Tab Bar Tracking** — The auto-hide tab bar now reliably tracks downward scroll on iPad too, via a GeometryReader + PreferenceKey observation path
- **Local Cover Reuse Expansion** — Downloaded cover images are now reused not only in the detail view but also in history / gacha / settings, cutting CDN roundtrips
- **Release Automation** — Added `scripts/release-mac.sh` (archive → Developer ID sign → notarize → staple → zip) and `scripts/release-ios.sh` (archive → Development IPA export); a single tag argument builds both the Mac zip and the iOS IPA

### ver.02a f5 (2026-04-20)
- **Custom ZIP Stream Writer** — Replaced Apple's NSFileCoordinator.forUploading (59s main-thread freeze + Code=512 failure on large galleries) with a streaming stored+ZIP64 writer. 6× faster, real-time progress bar, 3GB+ galleries export successfully
- **Zombie Download Elimination** — Delete/cancel now properly stops URL resolution / stream consumer / 2ndpass retry loops (previously kept downloading to deleted directories). Guards against metadata resurrection on cleanup
- **Scroll Position Consistency** — LocalReaderView page counter now always matches the displayed page. Fixed LazyVStack `.onAppear` last-wins race + `.scrollPosition`/`scrollTo` API conflict that caused random page numbers (e.g. "1/47" while viewing page 13)
- **Downloaded Gallery Preview** — Long-press a saved gallery to see a thumbnail grid of all pages; tap to jump into the reader at that page. Portrait-fixed cells for uniform layout, animated WebP marked with purple border + play icon
- **0B Cache Corruption Guard** — Size check (≥10KB) in `isFullyConverted` prevents AVPlayer "item failed" cascades from race-condition-corrupted cached .mp4 files
- **DL Retry Strategy** — Cloudflare `cf-mitigated: challenge` header detection, 509 gif URL pattern detection, SpeedTracker byte-progress watchdog kills stuck tasks, retrying UI phase with remaining page count
- **Concurrent Gallery Downloads** — Releasing the URL resolve semaphore after fetch allows multiple galleries to download in parallel
- **Temp File Lifecycle** — Auto cleanup of `.cortex` after share sheet completion (AirDrop / Save to Files / cancel) in addition to launch-time sweep

### ver.02a f3 (2026-04-12)
- **GPU Sprite Pipeline** — Sprite decode, crop, and resize via Metal CIContext (single-pass GPU rendering)
- **Dedicated Image Queue** — All sprite processing moved to isolated DispatchQueue, eliminating cooperative thread pool starvation
- **Disk Cache Elimination** — Removed JPEG re-encoding for sprites and cropped thumbnails (memory-only cache, re-fetchable)
- **Startup Prefetch Optimization** — Reduced thumbnail prefetch from all favorites (2400+) to visible 30 items

### ver.02a f2 (2026-04-07)
- **Favorites Toggle Reliability** — 429 error page retry with backoff, disabled button detection, cookie deduplication fix
- **Cookie Management** — Complement-only injection preserving server-set cookie attributes (HttpOnly, Secure)
- **Rate Limit Hardening** — `fetch()` now retries on 429 with 3s/6s exponential backoff (max 3 attempts)

### ver.02a f1 (2026-04-05)
- **nhentai API v2 Migration** — Full migration from v1 to v2 API with Cloudflare TLS fingerprint bypass via WKWebView
- **nhentai Favorites Toggle** — Server-side add/remove via SPA `#favorite` button click with SvelteKit hydration polling
- **Favorites Sync Optimization** — Cache-aware sync skips already-fetched galleries; 429 retry with exponential backoff
- **v2 Auth Support** — `isLoggedIn()` now recognizes `access_token` (v2) in addition to legacy `sessionid`
- **Thumbnail / Cover v2** — `thumbnailPath` and cover `path` from v2 API, CDN fallback across i/i1/i2/i3
- **Deleted Gallery Recovery** — Fetches full detail via `fetchGallery` before opening reader
- **nhentai Detail View** — Tag-tap search, thumbnail grid, download, filter pipeline
- **Lock Screen Wallpaper** — Favorites covers as blurred lock screen background
- **Tab Bar Auto-Hide** — Hides on scroll for more content space

### ver.02a (Initial Release)
- E-Hentai / EXhentai / nhentai unified viewer
- 4-mode reader with iPad spread view
- 3-engine image processing (CIFilter / Metal / CoreML Real-ESRGAN)
- Bidirectional download with Live Activity
- Face ID / Touch ID / PIN security
- PHOENIX MODE backup, ECO / EXTREME performance modes
- Vision OCR translation, TipKit hints, 8-language localization

## License
This project is licensed under the GPL-3.0 License - see the [LICENSE](LICENSE) file for details.

## Support
Support development on [Patreon](https://www.patreon.com/c/Cielchan).
