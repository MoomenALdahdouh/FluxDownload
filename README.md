<p align="center">
  <img src="Resources/AppIcon.png" width="144" alt="FluxDownload">
</p>

<h1 align="center">FluxDownload</h1>

<p align="center">Native macOS download manager with a ranged HTTP engine and Chrome capture.</p>

<p align="center">
  <a href="https://github.com/MoomenALdahdouh/FluxDownload/actions"><img src="https://img.shields.io/github/actions/workflow/status/MoomenALdahdouh/FluxDownload/ci.yml?branch=master&label=build" alt="build"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT"></a>
  <a href="CHANGELOG.md"><img src="https://img.shields.io/badge/release-v0.1.12-blue" alt="v0.1.12"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14+">
  <img src="https://img.shields.io/badge/arch-arm64-lightgrey" alt="arm64">
</p>

---

## Overview

FluxDownload is a native AppKit download manager for Apple Silicon. The UI stays small; transfers are delegated to a Swift 6 engine (`URLSession`, Range/`pwrite`, SQLite). Chrome capture uses native messaging. No accounts, ads, telemetry, or cloud at runtime.

<p align="center">
  <img src="docs/screenshots/main-window.png" alt="FluxDownload main window" width="880">
</p>

## Features

- HTTP(S) downloads with concurrent Range segments and a single-stream fallback
- Pause / resume, queues, and an in-process scheduler
- Chrome native messaging for captured downloads and media URLs (including many HLS streams)
- YouTube progressive MP4 (itag 18) and higher video-only qualities with companion audio when needed
- LinkedIn / `licdn` HLS assembled as `.mp4` from signed fMP4 segments
- Site grabber with `robots.txt` limits
- Local SQLite history — no analytics

Protected / DRM streams are detected and refused ([ADR-009](docs/adr/009-no-drm.md)).

## Architecture

Swift 6 Swift Package. The UI never talks to SQLite or `URLSession` directly.

| Module | Role |
|--------|------|
| `FluxDownloadCore` | Models, sanitization, logging |
| `FluxDownloadPersistence` | sqlite3 WAL actor |
| `FluxDownloadEngine` | Ranged `pwrite` downloader |
| `FluxDownloadMedia` | HLS / DASH parsing |
| `FluxDownloadIPC` | Chrome native-messaging bridge |
| `FluxDownloadApp` | AppKit + SwiftUI shell |

See [ARCHITECTURE.md](ARCHITECTURE.md) and [`docs/adr/`](docs/adr/).

## Requirements

- macOS 14 or later (Apple Silicon)
- Swift 6 (Xcode Command Line Tools are enough)
- Optional: Google Chrome for capture

## Build

```bash
git clone https://github.com/MoomenALdahdouh/FluxDownload.git
cd FluxDownload
bash Scripts/package-app.sh
open build/FluxDownload.app
```

The script builds `build/FluxDownload.app`, ad-hoc signs it, and registers the Chrome native host. If Gatekeeper blocks the first launch, right-click the app and choose **Open**.

Closing the window does not quit downloads. Use **FluxDownload → Quit**.

```bash
swift run FluxDownloadTestRunner
swift run fluxdownload-cli --help
```

## Chrome capture

1. Launch FluxDownload once so the native host is registered.
2. Chrome → `chrome://extensions` → Developer mode → **Load unpacked** → `Extensions/Chrome`.
3. Play media (or start a download), then send it from the overlay or popup.

The unpacked extension ID must stay `cdhmompibjahkccghpbepifodgcallpi`.

## Documentation

- [CONTRIBUTING.md](CONTRIBUTING.md) — build, layout, invariants
- [BROWSER_INTEGRATION.md](BROWSER_INTEGRATION.md) — native messaging
- [DOWNLOAD_ENGINE.md](DOWNLOAD_ENGINE.md) — Range / HLS engine
- [SECURITY.md](SECURITY.md) — trust boundaries
- [PRIVACY.md](PRIVACY.md) — what stays on disk
- [CHANGELOG.md](CHANGELOG.md) — version history

## License

MIT © Moomen Aldahdouh. See [LICENSE](LICENSE).
