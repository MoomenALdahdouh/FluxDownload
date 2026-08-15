# ADR-008: Download capture uses chrome.downloads

## Status
Accepted

## Context
Manifest V3 does not provide a blocking network interceptor equivalent to old `webRequestBlocking` for all downloads. The supported API is `chrome.downloads` (`onCreated`, `onDeterminingFilename`, `pause`, `cancel`).

## Decision
The service worker pauses, then cancels, Chrome downloads that match capture rules and forwards metadata to the native host. Very small files may complete before cancel; those are left to Chrome to avoid duplicates. `blob:`, `file:`, `data:`, and `chrome:` URLs are not captured.

## Consequences
- Capture is best-effort, not a kernel-level interceptor.
- Users can disable capture or limit it by type/domain.
- Duplicate protection uses normalized URL plus `browserRequestId`.
