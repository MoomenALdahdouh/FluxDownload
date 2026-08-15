# FluxDownload

Native macOS download manager for HTTP and HTTPS. Original product — not an IDM clone.

## Requirements

- macOS 14+
- Swift 6 (Apple Command Line Tools or Xcode)
- Optional: Google Chrome for browser capture

Xcode is **not** required to build or run the app. Safari support **is** blocked without Xcode.

## Build

```bash
swift build
swift test
Scripts/package-app.sh
```

Run from the package:

```bash
swift run FluxDownload
```

The packaged app is `build/FluxDownload.app`. Closing the window does not quit downloads. Use FluxDownload → Quit to stop the engine.

## Chrome

1. Start FluxDownload once so it registers the native messaging host.
2. Chrome → `chrome://extensions` → Developer mode → Load unpacked → `Extensions/Chrome`.
3. Extension ID must be `cdhmompibjahkccghpbepifodgcallpi`.

## What works in this tree

Download engine (Range + single-stream fallback), pause/resume metadata, queues, scheduler (while the process is running), grabber with robots.txt limits, HLS/DASH detection without DRM circumvention, Chrome native messaging, clipboard opt-in, settings, diagnostics.

See `MACOS_RELEASE_CERTIFICATION.md` after a full test run for the live matrix.

## Privacy

History stays on disk under `~/Library/Application Support/FluxDownload`. No analytics. Credentials go to Keychain. Clipboard is read only when the setting is on.
