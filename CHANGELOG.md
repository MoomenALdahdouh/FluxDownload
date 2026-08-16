# Changelog

## 0.1.12

- Chrome capture downloads LinkedIn HLS as signed fMP4 segments (`.mp4`), without rewriting CDN query tokens.
- Native host launches this app build when an older FluxDownload instance is already running.
- Session cookies travel with the download headers instead of creating a Keychain item per job.
- Overlay chip is icon-only; duplicate format rows on LinkedIn are merged.

## 0.1.0

- Initial macOS implementation: engine, persistence, UI, scheduler, grabber, Chrome bridge, media parsers.
