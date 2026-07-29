#!/usr/bin/env bash
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MODULE_DIR="$(mktemp -d /tmp/relaycode-ios-typecheck.XXXXXX)"

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
  "$IOS_DIR"/RelayCode/*.swift

echo "RelayCode iOS sources typecheck passed."
