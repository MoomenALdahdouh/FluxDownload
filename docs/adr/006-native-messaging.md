# ADR-006: Chrome native messaging bridge

## Status
Accepted

## Context
Chrome native messaging is a documented stdio protocol: 32-bit native-endian length prefix plus UTF-8 JSON. Host manifests live at `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/` for user installs. Maximum inbound size is 64 MiB; outbound is 1 MiB.

## Decision
Ship `FluxDownloadNativeHost`. Chrome launches it; the host authenticates to the running app over a `0600` Unix socket at `~/Library/Application Support/FluxDownload/ipc.sock`. If the app is not running, the host launches `FluxDownload.app` and waits with a timeout. Commands are an allowlist. Only `http` and `https` URLs are accepted.

## Consequences
- Shared `FluxDownloadBrowserProtocol` types for app, host, CLI, and tests.
- Unpacked Chrome extensions need a stable manifest `key` so `allowed_origins` is deterministic.
- Malformed messages are rejected; they never reach the download engine.
