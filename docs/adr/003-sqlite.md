# ADR-003: System sqlite3, no GRDB

## Status
Accepted

## Context
The product requires crash-safe download metadata, explicit migrations, and WAL. Third-party Swift dependencies must be justified. `libsqlite3` is already on macOS.

## Decision
Wrap `libsqlite3` in an internal `DatabaseActor`. Use WAL, `foreign_keys=ON`, `busy_timeout`, and numbered SQL migrations. No GRDB/SwiftData in v1.

## Consequences
- Zero Swift package dependencies.
- Repositories own SQL; the UI never imports SQLite.
- Credentials never enter SQLite (ADR-010).
