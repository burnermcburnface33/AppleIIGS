<!--
  Note: GitHub strips <script> tags from Markdown, so the Buy Me a Coffee
  JavaScript widget can't run in a README. The linked image button below points
  at the same page (slug: burnermcburnface33) and renders everywhere.
-->

# 🍎 Apple IIGS for iOS

An **Apple IIGS / Apple ][** emulator for iPhone & iPad — the [KEGS](https://kegs.sourceforge.net/) /
ActiveGS core wrapped in a native SwiftUI/UIKit shell, with a from-scratch pixel-perfect renderer for
razor-sharp Apple ][ output.

<p align="center">
  <img src="https://img.shields.io/badge/platform-iOS%2017%2B-blue" alt="iOS 17+">
  <img src="https://img.shields.io/badge/iPhone%20%26%20iPad-portrait%20%2B%20landscape-brightgreen" alt="iPhone & iPad">
  <img src="https://img.shields.io/badge/core-KEGS%20%2F%20ActiveGS-orange" alt="KEGS / ActiveGS">
  <img src="https://img.shields.io/badge/build-XcodeGen-lightgrey" alt="XcodeGen">
</p>

<p align="center">
  <a href="https://www.buymeacoffee.com/burnermcburnface33" target="_blank">
    <img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="60" width="217">
  </a>
</p>

---

## 🖥️ The machine

The **KEGS/ActiveGS** Apple IIGS core, booting **ROM03** (falls back to ROM01), with six disk drives:
S5 D1/D2 (3.5″), S6 D1/D2 (5.25″), and S7 D1/D2 (SmartPort/HD), plus a disk write-back toggle. Rather than
scale KEGS's NTSC-fringed framebuffer, the app ships a **native apple2ts-style renderer**: it reads the
Apple ][ text/HGR/DHGR/LORES memory pages and soft switches directly and draws them at source resolution
with authentic fonts and color — so text and graphics stay crisp on a phone screen.

## ✨ Features

- **Seven touch input modes**, switchable from the toolbar:
  **Keyboard** (with a floating accessory bar and true hardware-keyboard support, ⌘→open-apple / ⌥→solid-apple) ·
  **Joystick** (analog paddles + buttons; translucent full-screen overlay in landscape) ·
  **D-Pad** (customizable draggable buttons; drives the paddles and/or arrow keys) ·
  **Trackpad Mouse** (relative pointer + buttons; split layout in landscape) ·
  **Direct Mouse** (the screen itself is the trackpad, with floating L/R buttons) ·
  **Side Keys** (split landscape keyboard) ·
  **Custom Panel** (landscape custom-key panels on both sides + an optional inverted-T arrow pad, with
  its own saved layouts).
- **Display modes** (color / green / amber / B&W) and an optional **CRT scanline** shader.
- **Audio** — Ensoniq DOC / Mockingboard, routed through `AVAudioEngine` with interruption handling.
- **Save states** (V2 format with delete UI + thumbnails), auto-save on backgrounding, and a
  "Resume last session?" prompt on cold launch.
- **Disk management** — import 2MG/DSK/PO/HDV/… via the Files app, a bundled-disks library, mount
  verification/rollback on bad images, and optional **iCloud Drive backup**.
- **MFi / Bluetooth game controllers**, configurable **haptics**, and adjustable **mouse sensitivity**.
- **iPhone & iPad, portrait & landscape** (layouts adapt by geometry, so they work correctly on iPad).

## 🔧 Requirements

- **macOS** with **Xcode 26** + command-line tools
- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** — `brew install xcodegen`
  (the `.xcodeproj` is generated from `project.yml`)
- An **Apple Developer** account for on-device signing; **iOS 17+** device or simulator
- **The IIGS ROM is not included** — supply `gs-rom03.bin` (or `gs-rom01.bin`). Disk images are yours too.

## 🚀 Build & run

The project is generated from `project.yml` at the repo root:

```sh
xcodegen generate --spec project.yml && \
xcodebuild -project AppleIIGS.xcodeproj -scheme AppleIIGS \
  -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/DerivedData ONLY_ACTIVE_ARCH=YES CODE_SIGNING_ALLOWED=NO build
```

The **first build is a slow full-KEGS compile**; subsequent builds are incremental. For a device build,
open `AppleIIGS.xcodeproj` in Xcode and run. **`build_adhoc.sh`** archives and exports a signed Ad-Hoc
`.ipa` plus an OTA install manifest.

> New Swift files under `AppleIIGS/UI/` require a fresh `xcodegen generate` before they compile.
> Some KEGS/ActiveGS core sources are latin-1 encoded — search them with `LC_ALL=C grep -a`.

## 🧱 Architecture

A SwiftUI shell (`MainView` + toolbar + per-mode input overlays) talks to an Objective-C++
`EmulatorBridge`, which owns **one background pthread** running KEGS and exposes framebuffer, keyboard,
disk, and save APIs. Keystrokes go through KEGS's async event queue (never direct main-thread updates).
A `MetalRenderer` drives the apple2ts renderer at 560×384 → device pixels. The screen view keeps one
stable identity across every input mode. See `CLAUDE.md` for the full change log.

## 🙏 Credits & license

Built on **KEGS** by Kent Dickey, with **ActiveGS** additions — consult the KEGS license before
redistributing. The Apple IIGS ROM and all disk images / software are **not** distributed here and remain
the property of their owners; use only what you're legally entitled to.

## 👥 Contributors

Maintained by **[@burnermcburnface33](https://github.com/burnermcburnface33)** — the iOS app, the native
apple2ts-style renderer, the SwiftUI/UIKit shell, and the touch input system. Built on **KEGS** by Kent
Dickey with **ActiveGS** additions.

<a href="https://github.com/burnermcburnface33/AppleIIGS/graphs/contributors">
  <img src="https://contrib.rocks/image?repo=burnermcburnface33/AppleIIGS" alt="Contributors">
</a>

Contributions are welcome — open an issue or a pull request.

## ☕ Support

<p align="center">
  <a href="https://www.buymeacoffee.com/burnermcburnface33" target="_blank">
    <img src="https://cdn.buymeacoffee.com/buttons/v2/default-yellow.png" alt="Buy Me A Coffee" height="60" width="217">
  </a>
</p>

<sub>A personal hobby project — provided as-is, with no warranty. Not affiliated with Apple.</sub>
