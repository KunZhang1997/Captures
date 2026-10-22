# Captures

[简体中文](README.md) · **English**

**An open-source macOS screenshot tool with annotation, scrolling capture, text recognition, and floating screenshots.**

Select what you want to capture, draw arrows, add text, or pixelate details, then copy, save, open the editor, or keep the screenshot floating while you work. Capture, OCR, and screenshot history are handled on your Mac. No account is required.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift 5.9](https://img.shields.io/badge/Swift-5.9-orange)
[![MIT License](https://img.shields.io/badge/License-MIT-green)](LICENSE)
[![Source checks](https://github.com/KunZhang1997/Captures/actions/workflows/ci.yml/badge.svg)](https://github.com/KunZhang1997/Captures/actions/workflows/ci.yml)

<img src="Captures/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" alt="Captures app icon" width="128" />

The current release is **0.0.2, a public preview**. The universal installer supports Apple silicon and Intel Macs, is signed with Apple Developer ID, and is notarized by Apple. Features are still evolving; feedback is welcome.

## Download and install

**[Download Captures (DMG)](https://github.com/KunZhang1997/Captures/releases/latest/download/Captures-latest.dmg)** · [All releases and ZIP downloads](https://github.com/KunZhang1997/Captures/releases)

Requires **macOS 14 or later**. The same installer works on Apple silicon and Intel Macs.

1. Download and open the DMG, then drag `Captures.app` into `Applications`.
2. Open Captures from Applications. It runs in the menu bar; use its menu or a keyboard shortcut to start a capture.
3. Grant Screen Recording permission when prompted. If macOS asks you to reopen the app, follow the prompt.

Accessibility permission is optional and helps resolve shortcut conflicts. See the [release notes and verification record](docs/releases/0.0.2.en.md) for the scope of installer checks. Each release includes SHA256 checksums. To update, download the new version manually and replace the app.

## What you can do

| Task | How it works |
| --- | --- |
| Capture screen content | Capture a region, window, or full screen. In region mode, click a highlighted window or drag to select any area. |
| Explain a screenshot immediately | Draw rectangles, ellipses, arrows, freehand strokes, text, or pixelation directly on the selection, with undo and redo. |
| Save long content | Select a region and scroll down manually. Captures stitches together visually confirmed downward movement. |
| Extract text from an image | Recognize text locally with Apple Vision, then copy it. |
| Keep a reference visible | Keep screenshots in floating windows, optionally pinned above other windows. |
| Continue editing | Crop, rotate, annotate, obscure details, add backgrounds, and more. Use `⌘O` to open an existing image. |
| Find previous screenshots | Browse local history, search by recognized text or type, and configure retention and storage. |

The interface supports Simplified Chinese and English. Captures runs in the menu bar, with settings for shortcuts, image format, save location, and file naming.

**Settings → About** shows the full GitHub repository URL. Click it to open the repository in your default browser.

## Getting started

1. Launch Captures and grant Screen Recording permission in System Settings.
2. Press `⌘⇧A`, then drag to select a region or click a highlighted window.
3. Add annotations if needed, then choose Copy, Save, OCR, Edit, or a floating screenshot.

For manual scrolling capture, use `⌥⌘S` or start from a selection with no annotations. After selecting a region, scroll down with your mouse or trackpad. Choosing Copy, Save, OCR, or Edit ends capture; Close cancels it.

| Default shortcut | Action |
| --- | --- |
| `⌘⇧A` | Region capture / quick window selection |
| `⌥⌘F` | Full-screen capture |
| `⌥⌘W` | Window capture |
| `⌥⌘S` | Manual scrolling capture |
| `⌘O` | Open an image for editing |

Capture shortcuts can be changed in Settings. Within a selection, `V / R / E / A / P / T / X` activate Select Annotation, Rectangle, Ellipse, Arrow, Pencil, Text, and Pixelate, respectively.

## Permissions and data

- **Screen Recording:** required to read screen content for screenshots.
- **Accessibility:** optional, used to handle shortcuts already occupied by other apps. Without it, Captures uses system shortcut registration and reports conflicts.
- **Data storage:** screenshot history and OCR are handled locally. App data is stored in `~/Library/Application Support/Captures/` by default; the export location is configurable.

## Build from source

Requires macOS 14+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), and a valid Apple Developer signing certificate.

```bash
git clone https://github.com/KunZhang1997/Captures.git
cd Captures
brew install xcodegen
xcodegen generate
open Captures.xcodeproj
```

Select the `Captures` scheme in Xcode. Choose your own development team and a valid Apple certificate in the Signing settings for both the app and test targets, then build and run. `project.yml` contains the maintainer's signing defaults; other developers need to use their own configuration.

You can also override signing settings explicitly from the command line:

```bash
xcodebuild build \
  -project Captures.xcodeproj \
  -scheme Captures \
  -configuration Debug \
  -destination 'platform=macOS' \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Apple Development: Your Name (YOUR_CERTIFICATE_ID)"
```

Replace the team and certificate placeholders with your own values. All builds must use a valid Apple signing identity.

## Development and contributions

Report problems through [Issues](https://github.com/KunZhang1997/Captures/issues), or submit a pull request. Include reproduction steps, your macOS version, and examples without personal information.

| Directory | Contents |
| --- | --- |
| `Captures/` | Native macOS app: capture, selection annotations, editor, OCR, floating windows, and history |
| `CapturesTests/` | Existing automated tests |
| `design/` | Shared interaction prototype and fictional sample content |
| `website/` | Optional Astro introduction site; no production domain is configured for this fork |
| `scripts/` | Release artifact verification scripts |

See the [contribution guide](CONTRIBUTING.en.md) for testing and signing requirements. The [prototype guide](docs/prototype-guide.md) retains the full visual and interaction contract. To view the prototype, run this from the project root:

```bash
python3 -m http.server 8123
```

Then open the [All in One prototype](http://127.0.0.1:8123/design/all-in-one-prototype.html). The HTML prototype demonstrates interaction design; native app behavior is established through source code, tests, and hands-on verification.

## Credits and license

Maintained by [KunZhang1997](https://github.com/KunZhang1997), based on [Snapper by Nick Shatilo](https://github.com/nickshatilo/snapper), with upstream commit history preserved. This fork uses the Captures name and continues to refine post-capture annotation, scrolling capture, OCR, floating windows, Chinese localization, and image editing.

The project follows the **MIT** license declared in the upstream README. See [LICENSE](LICENSE) for the full text, [NOTICE](NOTICE) for upstream attribution and third-party information, and [ThirdPartyNotices.txt](Captures/Resources/ImageEditor/ThirdPartyNotices.txt) for the bundled Filerobot Image Editor license.
