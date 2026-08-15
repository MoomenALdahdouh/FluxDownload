# Architecture

FluxDownload is a Swift 6 SPM package. UI never talks to SQLite or URLSession.

- `FluxDownloadCore` — models, state machine, sanitization, logging
- `FluxDownloadPersistence` — sqlite3 WAL actor + migrations
- `FluxDownloadEngine` — ranged `pwrite` downloader + URLSession
- `FluxDownloadScheduler` — queues and in-process schedules
- `FluxDownloadMedia` — HLS/DASH parsers
- `FluxDownloadGrabber` — bounded crawler
- `FluxDownloadBrowserProtocol` / `FluxDownloadIPC` — Chrome bridge
- `FluxDownloadApp` — AppKit + SwiftUI
- `FluxDownloadNativeHost` / `fluxdownload` — stdio host and CLI

Windows is not implemented. Core/engine/persistence are the portable slice.

ADRs live in `docs/adr/`.
