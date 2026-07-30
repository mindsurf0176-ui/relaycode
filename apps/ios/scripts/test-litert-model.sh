#!/usr/bin/env bash
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$IOS_DIR/../.." && pwd)"
ARTIFACT_DIR="$REPO_DIR/artifacts/on-device-model"
RUNTIME_CACHE_DIR="$REPO_DIR/artifacts/litertlm-macos"
MODEL_VARIANT="${RELAYCODE_GEMMA_MODEL:-e4}"
case "$MODEL_VARIANT" in
  e4)
    MODEL_FILENAME="gemma-4-E4B-it.litertlm"
    MODEL_URL="https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/f7ad3343bd6ebc9607f4dc3bc4f2398bd5749bc5/gemma-4-E4B-it.litertlm?download=true"
    MODEL_SHA256="0b2a8980ce155fd97673d8e820b4d29d9c7d99b8fa6806f425d969b145bd52e0"
    MODEL_BYTES="3659530240"
    ;;
  e2)
    MODEL_FILENAME="gemma-4-E2B-it.litertlm"
    MODEL_URL="https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/6e5c4f1e395deb959c494953478fa5cec4b8008f/gemma-4-E2B-it.litertlm?download=true"
    MODEL_SHA256="181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c"
    MODEL_BYTES="2588147712"
    ;;
  *)
    echo "RELAYCODE_GEMMA_MODEL must be e4 or e2." >&2
    exit 2
    ;;
esac
RUNTIME_URL="https://github.com/google-ai-edge/LiteRT-LM/releases/download/v0.14.0/CLiteRTLM_mac.xcframework.zip"
RUNTIME_SHA256="450615483509aaa6d34b321fdc6862e41a224b674468ab10aff64ebe113d21b7"
MODEL_PATH="$ARTIFACT_DIR/$MODEL_FILENAME"
MODEL_PARTIAL="$MODEL_PATH.partial"
RUNTIME_ARCHIVE="$RUNTIME_CACHE_DIR/CLiteRTLM_mac.xcframework.zip"
RUNTIME_FRAMEWORK="$RUNTIME_CACHE_DIR/CLiteRTLM_mac.xcframework"
RUNTIME_SLICE="$RUNTIME_FRAMEWORK/macos-arm64_x86_64"
BUILD_DIR="$(mktemp -d /tmp/relaycode-litert-smoke.XXXXXX)"
SOURCE_DIR="$BUILD_DIR/Sources"

trap 'rm -rf "$BUILD_DIR"' EXIT

"$IOS_DIR/scripts/prepare-litert-runtime.sh"
mkdir -p "$ARTIFACT_DIR" "$RUNTIME_CACHE_DIR"
mkdir -p "$SOURCE_DIR/RelayCodeCore"
find "$IOS_DIR/RelayCodeCore" -maxdepth 1 -type f -name '*.swift' \
  ! -name '* [0-9]*.swift' -exec cp {} "$SOURCE_DIR/RelayCodeCore/" \;

if [ ! -f "$RUNTIME_ARCHIVE" ] \
  || ! echo "$RUNTIME_SHA256  $RUNTIME_ARCHIVE" \
    | shasum -a 256 -c - >/dev/null 2>&1; then
  curl --fail --location --show-error \
    "$RUNTIME_URL" \
    --output "$RUNTIME_ARCHIVE.partial"
  echo "$RUNTIME_SHA256  $RUNTIME_ARCHIVE.partial" | shasum -a 256 -c -
  mv "$RUNTIME_ARCHIVE.partial" "$RUNTIME_ARCHIVE"
fi

if [ ! -f "$RUNTIME_SLICE/libCLiteRTLM_mac.dylib" ]; then
  extraction="$(mktemp -d /tmp/relaycode-litert-mac.XXXXXX)"
  unzip -q "$RUNTIME_ARCHIVE" -d "$extraction"
  extracted_framework="$extraction/CLiteRTLM_mac.xcframework"
  test -f "$extracted_framework/macos-arm64_x86_64/libCLiteRTLM_mac.dylib"
  rm -rf "$RUNTIME_FRAMEWORK"
  mv "$extracted_framework" "$RUNTIME_FRAMEWORK"
  rm -rf "$extraction"
fi

if [ ! -f "$MODEL_PATH" ] \
  || [ "$(stat -f %z "$MODEL_PATH")" != "$MODEL_BYTES" ] \
  || ! echo "$MODEL_SHA256  $MODEL_PATH" \
    | shasum -a 256 -c - >/dev/null 2>&1; then
  curl --fail --location --show-error \
    --continue-at - \
    "$MODEL_URL" \
    --output "$MODEL_PARTIAL"
  test "$(stat -f %z "$MODEL_PARTIAL")" = "$MODEL_BYTES"
  echo "$MODEL_SHA256  $MODEL_PARTIAL" | shasum -a 256 -c -
  mv "$MODEL_PARTIAL" "$MODEL_PATH"
fi

xcrun swiftc \
  -emit-library \
  -emit-module \
  -parse-as-library \
  -swift-version 5 \
  -module-name LiteRTLM \
  -I "$RUNTIME_SLICE/Headers" \
  -L "$RUNTIME_SLICE" \
  -lCLiteRTLM_mac \
  -emit-module-path "$BUILD_DIR/LiteRTLM.swiftmodule" \
  -o "$BUILD_DIR/libLiteRTLM.dylib" \
  "$IOS_DIR"/RelayCodeLiteRTRuntime/Sources/LiteRTLM/*.swift

xcrun swiftc \
  -emit-module \
  -emit-object \
  -whole-module-optimization \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=targeted \
  -module-name RelayCodeCore \
  -emit-module-path "$BUILD_DIR/RelayCodeCore.swiftmodule" \
  -o "$BUILD_DIR/RelayCodeCore.o" \
  "$SOURCE_DIR"/RelayCodeCore/*.swift

xcrun swiftc \
  -parse-as-library \
  -swift-version 6 \
  -strict-concurrency=targeted \
  -module-name RelayCodeLiteRTSmoke \
  -I "$BUILD_DIR" \
  -I "$RUNTIME_SLICE/Headers" \
  -L "$BUILD_DIR" \
  -L "$RUNTIME_SLICE" \
  "$IOS_DIR/RelayCode/OnDeviceInferenceShared.swift" \
  "$IOS_DIR/RelayCode/OnDeviceLiteRTInferenceEngine.swift" \
  "$IOS_DIR/scripts/litert-model-smoke.swift" \
  "$BUILD_DIR/RelayCodeCore.o" \
  -lLiteRTLM \
  -lCLiteRTLM_mac \
  -Xlinker -rpath \
  -Xlinker "$BUILD_DIR" \
  -Xlinker -rpath \
  -Xlinker "$RUNTIME_SLICE" \
  -o "$BUILD_DIR/relaycode-litert-smoke"

"$BUILD_DIR/relaycode-litert-smoke" "$MODEL_PATH"
