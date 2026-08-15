#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
swift build --product FluxDownloadTestRunner
BIN="$(swift build --show-bin-path)/FluxDownloadTestRunner"
"$BIN"
