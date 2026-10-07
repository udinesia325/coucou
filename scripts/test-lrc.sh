#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/coucou-lrc.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
swiftc NotchBuddy/Sources/CoucouKit/LRC.swift \
    tests/LRCTests.swift -o "$TEST_DIR/lrc-tests"
"$TEST_DIR/lrc-tests"
