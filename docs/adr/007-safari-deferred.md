# ADR-007: Safari deferred

## Status
Accepted

## Context
Safari Web Extensions are packaged as an `.appex` inside a containing macOS app. Native messaging is handled by `SafariWebExtensionHandler` (`NSExtensionRequestHandling`). That packaging path requires Xcode. This environment has Command Line Tools only.

## Decision
Safari is **not** implemented in v1.

```
NOT IMPLEMENTED — BLOCKED BY VERIFIED PLATFORM LIMITATION
Xcode is not installed; Safari Web Extensions cannot be packaged with Swift Package Manager alone.
```

Chrome is the browser integration gate.

## Consequences
- `Extensions/Safari/README.md` states the limitation.
- Settings must not claim Safari is connected.
- The shared browser protocol is Safari-ready when Xcode exists.
