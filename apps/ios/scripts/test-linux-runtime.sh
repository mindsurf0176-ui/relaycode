#!/usr/bin/env bash
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d /tmp/relaycode-linux-smoke.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

"$IOS_DIR/scripts/prepare-linux-runtime.sh"

clang \
  -O2 \
  -Wall \
  -Wextra \
  -Werror \
  -I "$IOS_DIR/RelayCodeLinuxRuntime/include" \
  -I "$IOS_DIR/RelayCodeLinuxRuntime/vendor" \
  "$IOS_DIR/RelayCodeLinuxRuntime/RelayCodeLinuxRuntime.c" \
  "$IOS_DIR/scripts/linux-runtime-smoke.c" \
  -o "$BUILD_DIR/linux-runtime-smoke"

"$BUILD_DIR/linux-runtime-smoke" \
  "$IOS_DIR/RelayCode/Resources/Linux/linux-rv32.img"
