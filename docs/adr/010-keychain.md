# ADR-010: Credentials only in Keychain

## Status
Accepted

## Context
Download records need to remember that a site required authentication. SQLite is not an appropriate secret store. Logs must not leak cookies or `Authorization` headers.

## Decision
SQLite stores a Keychain account reference (`credentialRef` / `cookieRef`), never the secret. `Redactor` strips known sensitive header names. Diagnostic export uses the same redaction.

## Consequences
- Repositories refuse to bind password columns (there are none).
- Native messages may carry cookies from the browser; they are written to Keychain immediately and dropped from the in-memory record after the download starts.
