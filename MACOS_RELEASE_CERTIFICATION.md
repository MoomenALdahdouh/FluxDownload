# macOS release certification

Product: FluxDownload 0.1.0  
Bundle ID: `app.fluxdownload.macos`  
Date: 2026-08-15

## Implemented

- Native SPM macOS app (SwiftUI + AppKit), window-close does not quit
- SQLite WAL persistence, categories, queues, schedules, history, grabber projects
- HTTP(S) engine with Range acceleration, single-stream fallback, pause/resume metadata, retries, atomic `.fluxpart` finalize
- Local test HTTP server covering Range / no-Range / redirect / 404
- Scheduler (in-process; survives relaunch via SQLite; does not run after full Quit unless Launch at Login)
- Site grabber with robots.txt, depth/count/throttle, cancel
- HLS/DASH parsers; protected media rejected
- Chrome MV3 extension + native messaging host + Unix-socket IPC allowlist
- Clipboard opt-in, notifications, menu bar extra, onboarding, settings, diagnostics, config import/export (no credentials)
- CLI `fluxdownload` talking to a running app

## Verified (automated)

43/43 FluxDownloadTestRunner checks, including interrupted resume and multi-connection Range against the local server. See `TEST_REPORT.md`.

`build/FluxDownload.app` builds and is ad-hoc signed.

## Limitations (honest)

- Safari: NOT IMPLEMENTED — BLOCKED BY VERIFIED PLATFORM LIMITATION (Xcode required for `.appex`)
- Chrome live capture was not driven in a headed browser in this certification run; protocol/IPC tests passed. Load `Extensions/Chrome` and confirm the popup says connected before calling capture done.
- Tiny Chrome downloads may complete before `chrome.downloads.cancel`
- No DRM / EME / Widevine / FairPlay
- Scheduler does not fire while the process is fully quit
- Packaged build is **ad-hoc signed**, not Developer ID, **not notarized** — not a shipping release artifact
- `swift test` / XCTest unavailable without Xcode

## Browser compatibility

- Chrome 151: extension + host designed and unit-tested
- Chromium: same MV3 sources, host manifest path differs
- Safari: not implemented

## Architecture portability

Reusable later on Windows: Core, Persistence, Engine, Scheduler, Media, Grabber, BrowserProtocol. Replace IPC (named pipe), Keychain, SwiftUI/AppKit, SMAppService, and the native messaging host install path.

## Recommended Windows architecture (not started)

Same Swift modules if Windows Swift is adopted, or a Rust/C# engine speaking the same SQLite schema and JSON protocol. Do not start until this macOS certification is explicitly accepted.

## Known issues

- Ad-hoc signature will be blocked by Gatekeeper for other users
- Per-task URLSession delegates are used for chunked writes; keep watching for session configuration edge cases on unusual proxies
