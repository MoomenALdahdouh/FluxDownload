# ADR-009: No DRM circumvention

## Status
Accepted

## Context
EME, Widevine, FairPlay, PlayReady, HLS `SAMPLE-AES`, and DASH `ContentProtection` exist to protect media. Circumventing them is not allowed.

## Decision
Detect protection signals and surface: "Protected or unsupported media source." AES-128 HLS with a fetchable key in the playlist is ordinary HTTP encryption, not DRM, and is allowed when the key URI is `http`/`https`.

## Consequences
- Format pickers show only detected, unprotected representations.
- Tests cover protected fixtures that must be rejected.
