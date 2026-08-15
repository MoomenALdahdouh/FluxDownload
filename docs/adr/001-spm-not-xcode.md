# ADR-001: Swift Package Manager, not Xcode

## Status
Accepted

## Context
This machine has Apple Command Line Tools and Swift 6.3.3. Xcode is not installed, so `xcodebuild` cannot be used. Safari Web Extensions require an `.appex` target produced by Xcode.

## Decision
Ship FluxDownload as a Swift Package that produces executables, then assemble `FluxDownload.app` with `Scripts/package-app.sh`, matching the proven local MacMedia workflow.

## Consequences
- Debug and test with `swift build` / `swift test`.
- Safari support is blocked until Xcode is available (ADR-007).
- Code signing uses `codesign` from Command Line Tools. Notarization is attempted only when a Developer ID identity exists.
