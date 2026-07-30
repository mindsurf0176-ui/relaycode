#!/usr/bin/env bash
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MODULE_DIR="$(mktemp -d /tmp/relaycode-ios-typecheck.XXXXXX)"

"$IOS_DIR/scripts/prepare-linux-runtime.sh"

xcrun --sdk iphoneos clang \
  -target arm64-apple-ios17.0 \
  -isysroot "$IOS_SDK" \
  -I "$IOS_DIR/RelayCodeLinuxRuntime/include" \
  -I "$IOS_DIR/RelayCodeLinuxRuntime/vendor" \
  -c "$IOS_DIR/RelayCodeLinuxRuntime/RelayCodeLinuxRuntime.c" \
  -o "$MODULE_DIR/RelayCodeLinuxRuntime.o"

xcrun --sdk iphoneos swiftc \
  -emit-module \
  -parse-as-library \
  -module-name RelayCodeCore \
  -target arm64-apple-ios17.0 \
  -sdk "$IOS_SDK" \
  -emit-module-path "$MODULE_DIR/RelayCodeCore.swiftmodule" \
  "$IOS_DIR"/RelayCodeCore/*.swift

xcrun --sdk iphoneos swiftc \
  -typecheck \
  -parse-as-library \
  -module-name RelayCode \
  -target arm64-apple-ios17.0 \
  -sdk "$IOS_SDK" \
  -I "$MODULE_DIR" \
  -import-objc-header "$IOS_DIR/RelayCode/RelayCode-Bridging-Header.h" \
  -Xcc -I"$IOS_DIR/RelayCodeLinuxRuntime/include" \
  "$IOS_DIR"/RelayCode/*.swift

echo "RelayCode iOS sources typecheck passed."
