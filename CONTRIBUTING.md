# Contributing

FluxDownload is a Swift 6 SPM project. Xcode is not required.

## Build and test

```bash
swift --version          # Swift 6.0+
swift run FluxDownloadTestRunner
bash Scripts/package-app.sh
```

The packaged app is `build/FluxDownload.app` (ad-hoc signed unless `CODESIGN_IDENTITY` is set).

## Layout

| Path | Role |
|------|------|
| `Sources/FluxDownloadApp` | SwiftUI + AppKit shell |
| `Sources/FluxDownloadEngine` | HTTP(S) download engine |
| `Sources/FluxDownloadMedia` | HLS / DASH parsing (no DRM circumvention) |
| `Extensions/Chrome` | Unpacked Chrome extension |
| `docs/adr` | Architecture decisions |

Keep YouTube progressive itag 18 and googlevideo `omitRange` behavior intact unless you are deliberately changing that path.

Please do not commit `.cursor/`, `.build/`, `build/`, or Keychain material.
