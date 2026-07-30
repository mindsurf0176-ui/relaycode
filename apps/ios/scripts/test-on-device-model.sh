#!/usr/bin/env bash
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$IOS_DIR/../.." && pwd)"
MODEL_DIR="$REPO_DIR/artifacts/on-device-model"
MODEL_VARIANT="${RELAYCODE_ON_DEVICE_MODEL:-speed}"
case "$MODEL_VARIANT" in
  speed)
    MODEL_FILENAME="qwen2.5-coder-1.5b-instruct-q4_k_m.gguf"
    MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/resolve/f86cb2c1fa58255f8052cc32aeede1b7482d4361/qwen2.5-coder-1.5b-instruct-q4_k_m.gguf?download=true"
    MODEL_SHA256="cc324af070c2ecbfd324a30884d2f951a7ff756aba85cb811a6ec436933bb046"
    MODEL_BYTES="1117320768"
    ;;
  quality)
    MODEL_FILENAME="qwen2.5-coder-3b-instruct-q4_k_m.gguf"
    MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-Coder-3B-Instruct-GGUF/resolve/f74adce6aa16316c625447af059dbebe4983757c/qwen2.5-coder-3b-instruct-q4_k_m.gguf?download=true"
    MODEL_SHA256="724fb256bec1ff062b2f65e4569e871ad2e95ab2a3989723d1769c54294730b7"
    MODEL_BYTES="2104932800"
    ;;
  *)
    echo "RELAYCODE_ON_DEVICE_MODEL must be speed or quality." >&2
    exit 2
    ;;
esac
MODEL_PATH="$MODEL_DIR/$MODEL_FILENAME"
MODEL_PARTIAL="$MODEL_PATH.partial"
BUILD_DIR="$(mktemp -d /tmp/relaycode-on-device-smoke.XXXXXX)"
LLAMA_FRAMEWORKS="$IOS_DIR/RelayCodeLlamaRuntime/vendor/llama.xcframework/macos-arm64_x86_64"
SOURCE_DIR="$BUILD_DIR/Sources"

trap 'rm -rf "$BUILD_DIR"' EXIT

"$IOS_DIR/scripts/prepare-llama-runtime.sh"
mkdir -p "$MODEL_DIR"
mkdir -p "$SOURCE_DIR/RelayCodeCore" "$SOURCE_DIR/RelayCode"
find "$IOS_DIR/RelayCodeCore" -maxdepth 1 -type f -name '*.swift' \
  ! -name '* [0-9]*.swift' -exec cp {} "$SOURCE_DIR/RelayCodeCore/" \;
cp "$IOS_DIR/RelayCode/OnDeviceInferenceEngine.swift" "$SOURCE_DIR/RelayCode/"
cp "$IOS_DIR/scripts/on-device-model-smoke.swift" "$SOURCE_DIR/"

if [ ! -f "$MODEL_PATH" ] \
  || [ "$(stat -f %z "$MODEL_PATH")" != "$MODEL_BYTES" ] \
  || ! echo "$MODEL_SHA256  $MODEL_PATH" | shasum -a 256 -c - >/dev/null 2>&1; then
  curl --fail --location --show-error \
    --continue-at - \
    "$MODEL_URL" \
    --output "$MODEL_PARTIAL"
  test "$(stat -f %z "$MODEL_PARTIAL")" = "$MODEL_BYTES"
  echo "$MODEL_SHA256  $MODEL_PARTIAL" | shasum -a 256 -c -
  mv "$MODEL_PARTIAL" "$MODEL_PATH"
fi

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
  -module-name RelayCodeOnDeviceSmoke \
  -I "$BUILD_DIR" \
  -F "$LLAMA_FRAMEWORKS" \
  "$SOURCE_DIR/RelayCode/OnDeviceInferenceEngine.swift" \
  "$SOURCE_DIR/on-device-model-smoke.swift" \
  "$BUILD_DIR/RelayCodeCore.o" \
  -framework llama \
  -Xlinker -rpath \
  -Xlinker "$LLAMA_FRAMEWORKS" \
  -o "$BUILD_DIR/relaycode-on-device-smoke"

"$BUILD_DIR/relaycode-on-device-smoke" "$MODEL_PATH"
