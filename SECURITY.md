# Security

- http/https only
- Filename sanitizer rejects `..` and NUL
- IPC allowlist + token file mode 0600 + socket mode 0600
- Native messaging origin allowlist is the stable Chrome extension ID
- Passwords/cookies never stored in SQLite; Keychain only
- Logs redact Authorization/Cookie
- Downloaded files are never executed
- No DRM circumvention
- App is not sandboxed (ADR-002); Hardened Runtime is applied on packaged builds
