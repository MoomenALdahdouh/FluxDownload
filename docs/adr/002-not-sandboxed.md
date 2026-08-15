# ADR-002: Not App Sandboxed

## Status
Accepted

## Context
Users choose arbitrary save folders. A download manager that cannot write outside a container is not useful for Developer ID / DMG distribution. App Store sandboxing would require security-scoped bookmarks for every destination.

## Decision
v1 is not App Sandboxed. Hardened Runtime is enabled on packaged builds. App Store distribution is a future ADR.

## Consequences
- Direct writes to user-chosen directories.
- Native messaging host can live at `FluxDownload.app/Contents/MacOS/FluxDownloadNativeHost`.
- Privilege boundary is the user account, not a sandbox. IPC and filename checks remain mandatory (ADR-006, ADR-010).
