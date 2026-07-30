#!/usr/bin/env bash
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$IOS_DIR/../.." && pwd)"
MODEL_DIR="$REPO_DIR/artifacts/on-device-model"
MODEL_PATH="$MODEL_DIR/qwen2.5-coder-0.5b-instruct-q4_0.gguf"
MODEL_PARTIAL="$MODEL_PATH.partial"
MODEL_URL="https://huggingface.co/Qwen/Qwen2.5-Coder-0.5B-Instruct-GGUF/resolve/ebb2015119c907b064c512bf053e945850b5875f/qwen2.5-coder-0.5b-instruct-q4_0.gguf?download=true"
MODEL_SHA256="9739055e046d62a937e5b7879012209ef40ebea8a1569a96028de491f3f091d5"
MODEL_BYTES="428730240"
BUILD_DIR="$(mktemp -d /tmp/relaycode-on-device-smoke.XXXXXX)"
LLAMA_FRAMEWORKS="$IOS_DIR/RelayCodeLlamaRuntime/vendor/llama.xcframework/macos-arm64_x86_64"

trap 'rm -rf "$BUILD_DIR"' EXIT

"$IOS_DIR/scripts/prepare-llama-runtime.sh"
mkdir -p "$MODEL_DIR"

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
  -module-name RelayCodeCore \
  -emit-module-path "$BUILD_DIR/RelayCodeCore.swiftmodule" \
  -o "$BUILD_DIR/RelayCodeCore.o" \
  "$IOS_DIR"/RelayCodeCore/*.swift

xcrun swiftc \
  -parse-as-library \
  -module-name RelayCodeOnDeviceSmoke \
  -I "$BUILD_DIR" \
  -F "$LLAMA_FRAMEWORKS" \
  "$IOS_DIR/RelayCode/OnDeviceInferenceEngine.swift" \
  "$IOS_DIR/scripts/on-device-model-smoke.swift" \
  "$BUILD_DIR/RelayCodeCore.o" \
  -framework llama \
  -Xlinker -rpath \
  -Xlinker "$LLAMA_FRAMEWORKS" \
  -o "$BUILD_DIR/relaycode-on-device-smoke"

"$BUILD_DIR/relaycode-on-device-smoke" "$MODEL_PATH"
