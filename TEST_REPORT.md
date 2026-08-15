# Test report

Date: 2026-08-15  
Platform: macOS 26.5.2 (arm64)  
Swift: 6.3.3 (Command Line Tools, no Xcode)  
Browser: Chrome 151 installed; Safari present  

## Runner

Command Line Tools do not ship XCTest or the Swift Testing module. Tests run via `FluxDownloadTestRunner`.

```bash
swift build --product FluxDownloadTestRunner
$(swift build --show-bin-path)/FluxDownloadTestRunner
```

## Result

- Passed: 43
- Failed: 0
- Skipped: 0
- Coverage: not collected (llvm-cov not wired)

## Suites

| Area | Status |
| --- | --- |
| State machine, sanitizer, URL rules, categories, redaction | pass |
| Browser protocol + native messaging framing | pass |
| SQLite migrations, seed, crash-safe round-trip, rollback | pass |
| Range multi-connection vs local server | pass |
| Non-Range fallback | pass |
| Interrupted resume | pass |
| HTTP 404 | pass |
| Redirect follow | pass |
| HLS/DASH parse + protected rejection | pass |
| Grabber domain/robots/cancel | pass |
| IPC token rejection + ping | pass |

## Not automated here

- Live Chrome extension load + native messaging against a signed `.app`
- Sleep/wake on hardware
- 10 GB files
- VoiceOver pass
- Notarization (no Developer ID in this environment)
