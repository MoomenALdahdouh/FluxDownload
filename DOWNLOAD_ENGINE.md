# Download engine

`DownloadCoordinator` probes with HEAD, then `GET Range: bytes=0-0` if needed.

If the server returns `206` or `Accept-Ranges: bytes` and the file is at least 64 KB, the file is split into segments and fetched concurrently. Each segment is written with `pwrite` into `filename.fluxpart`. Completion `rename`s to the final name.

If Range is not supported, a single stream is used. Acceleration is never reported unless multiple connections actually ran (`connectionCount > 1`).

Crash recovery: incomplete rows are set to `paused` on launch, temp files and segment offsets are reused, then the user setting `autoResumeOnLaunch` decides whether to continue.
