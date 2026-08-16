# Privacy

FluxDownload does not include analytics, crash telemetry, or accounts. History stays in local SQLite under `~/Library/Application Support/FluxDownload`.

Clipboard monitoring is off until you enable it. When on, only `http` / `https` URLs are parsed; the rest of the clipboard is discarded.

The optional Chrome extension can send the current page URL, referrer, and cookies so authenticated media (for example LinkedIn) can download. Those cookies are stored with that download as request headers. They are not uploaded anywhere. Optional proxy credentials use Keychain.

Configuration export omits credential references.
