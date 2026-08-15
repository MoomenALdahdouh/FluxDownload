# Testing

Command Line Tools do not provide XCTest. Use the package test runner:

```bash
swift build --product FluxDownloadTestRunner
"$(swift build --show-bin-path)/FluxDownloadTestRunner"
```

or `bash Scripts/run-tests.sh`.

Latest local result: 43 passed, 0 failed (`TEST_REPORT.md`).

- Core: state machine, sanitizer, URL rules, categories
- Persistence: migrations, round-trip, transaction rollback
- Engine: local `TestHTTPServer` for Range, no-Range, resume, 404, redirect
- Media: HLS/DASH fixtures including protected rejection
- Grabber: domain/robots limits and cancel
- IPC: token rejection and ping

Chrome end-to-end requires Chrome + the unpacked extension + a packaged or running app. That gate is manual; see `MACOS_RELEASE_CERTIFICATION.md`.
