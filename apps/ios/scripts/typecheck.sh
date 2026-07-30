#!/usr/bin/env bash
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
MODULE_DIR="$(mktemp -d /tmp/relaycode-ios-typecheck.XXXXXX)"
LLAMA_FRAMEWORKS="$IOS_DIR/RelayCodeLlamaRuntime/vendor/llama.xcframework/ios-arm64"
LITERT_FRAMEWORKS="$IOS_DIR/RelayCodeLiteRTRuntime/vendor/CLiteRTLM.xcframework/ios-arm64"
SOURCE_DIR="$MODULE_DIR/Sources"

"$IOS_DIR/scripts/prepare-linux-runtime.sh"
"$IOS_DIR/scripts/prepare-llama-runtime.sh"
"$IOS_DIR/scripts/prepare-litert-runtime.sh"
mkdir -p "$SOURCE_DIR/RelayCodeCore" "$SOURCE_DIR/RelayCode"
find "$IOS_DIR/RelayCodeCore" -maxdepth 1 -type f -name '*.swift' \
  ! -name '* [0-9]*.swift' -exec cp {} "$SOURCE_DIR/RelayCodeCore/" \;
find "$IOS_DIR/RelayCode" -maxdepth 1 -type f -name '*.swift' \
  ! -name '* [0-9]*.swift' -exec cp {} "$SOURCE_DIR/RelayCode/" \;

xcrun --sdk iphoneos swiftc \
  -emit-module \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=targeted \
  -module-name RelayCodeCore \
  -target arm64-apple-ios17.0 \
  -sdk "$IOS_SDK" \
  -emit-module-path "$MODULE_DIR/RelayCodeCore.swiftmodule" \
  "$SOURCE_DIR"/RelayCodeCore/*.swift

xcrun --sdk iphoneos swiftc \
  -emit-module \
  -parse-as-library \
  -swift-version 5 \
  -module-name LiteRTLM \
  -target arm64-apple-ios17.0 \
  -sdk "$IOS_SDK" \
  -F "$LITERT_FRAMEWORKS" \
  -emit-module-path "$MODULE_DIR/LiteRTLM.swiftmodule" \
  "$IOS_DIR"/RelayCodeLiteRTRuntime/Sources/LiteRTLM/*.swift

xcrun --sdk iphoneos swiftc \
  -typecheck \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=targeted \
  -module-name RelayCode \
  -target arm64-apple-ios17.0 \
  -sdk "$IOS_SDK" \
  -I "$MODULE_DIR" \
  -F "$LLAMA_FRAMEWORKS" \
  -F "$LITERT_FRAMEWORKS" \
  -import-objc-header "$IOS_DIR/RelayCode/RelayCode-Bridging-Header.h" \
  -Xcc -I"$IOS_DIR/RelayCodeLinuxRuntime/include" \
  "$SOURCE_DIR"/RelayCode/*.swift

echo "RelayCode iOS sources typecheck passed."
