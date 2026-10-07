#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-stocks.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/App/StocksWatchlist.swift \
    tests/StocksWatchlistTests.swift -o "$TEST_DIR/stocks-tests"
"$TEST_DIR/stocks-tests" "$@"
