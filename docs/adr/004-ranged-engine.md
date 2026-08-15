# ADR-004: Custom ranged engine, not URLSessionDownloadTask

## Status
Accepted

## Context
`URLSessionDownloadTask` downloads to a single system-managed temp file and does not expose honest multi-connection Range acceleration.

## Decision
Use `URLSession` data/byte streams with `Range` headers, `pwrite` at 64-bit offsets into a `.fluxpart` file, then `rename(2)` for atomic finalize. Probe with HEAD, then `GET Range: bytes=0-0`. If the server does not return `206` / `Accept-Ranges: bytes`, use one stream. Never report acceleration unless concurrent Range is actually in use.

## Consequences
- Segment rows in SQLite make crash resume exact.
- Concurrent writes to the same `FileHandle` via `seek` would race; `pwrite` is used instead.
- A local `FluxDownloadTestServer` is required to prove Range and non-Range paths.
