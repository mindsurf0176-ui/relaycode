#!/usr/bin/env bash
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH_DIR="$(mktemp -d /tmp/relaycode-swiftpm.XXXXXX)"
PACKAGE_DIR="$SCRATCH_DIR/Package"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

mkdir -p "$PACKAGE_DIR/RelayCodeCore" "$PACKAGE_DIR/RelayCodeTests"
cp "$IOS_DIR/Package.swift" "$PACKAGE_DIR/Package.swift"
find "$IOS_DIR/RelayCodeCore" -maxdepth 1 -type f -name '*.swift' \
  ! -name '* [0-9]*.swift' -exec cp {} "$PACKAGE_DIR/RelayCodeCore/" \;
find "$IOS_DIR/RelayCodeTests" -maxdepth 1 -type f -name '*.swift' \
  ! -name '* [0-9]*.swift' -exec cp {} "$PACKAGE_DIR/RelayCodeTests/" \;

swift test \
  --package-path "$PACKAGE_DIR" \
  --scratch-path "$SCRATCH_DIR/Build"
