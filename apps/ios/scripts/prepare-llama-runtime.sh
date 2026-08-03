#!/usr/bin/env bash
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$IOS_DIR/RelayCodeLlamaRuntime/vendor"
FRAMEWORK_DIR="$VENDOR_DIR/llama.xcframework"
RESOURCE_DIR="$IOS_DIR/RelayCode/Resources/OnDeviceModel"
LLAMA_TAG="b10182"
LLAMA_COMMIT="afeebe103bd99cda8f5dfaefcabadf890db7fda7"
LLAMA_ARCHIVE_SHA256="cb687436cf0e3856a83ac0cae64915ae3f3de4afdbd2e1bf3e219074c01f947c"
STAMP_CONTENT="$LLAMA_TAG $LLAMA_COMMIT $LLAMA_ARCHIVE_SHA256"

mkdir -p "$VENDOR_DIR" "$RESOURCE_DIR"

fetch_verified() {
  local url="$1"
  local expected_sha="$2"
  local destination="$3"

  if [ -f "$destination" ] \
    && echo "$expected_sha  $destination" | shasum -a 256 -c - >/dev/null 2>&1; then
    return
  fi

  local temporary
  temporary="$(mktemp /tmp/relaycode-llama-download.XXXXXX)"
  curl --fail --location --silent --show-error "$url" --output "$temporary"
  echo "$expected_sha  $temporary" | shasum -a 256 -c -
  mv "$temporary" "$destination"
}

fetch_verified \
  "https://raw.githubusercontent.com/ggml-org/llama.cpp/$LLAMA_COMMIT/LICENSE" \
  "94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d" \
  "$RESOURCE_DIR/llama-cpp-license.txt"

fetch_verified \
  "https://huggingface.co/Qwen/Qwen2.5-Coder-1.5B-Instruct-GGUF/raw/f86cb2c1fa58255f8052cc32aeede1b7482d4361/LICENSE" \
  "832dd9e00a68dd83b3c3fb9f5588dad7dcf337a0db50f7d9483f310cd292e92e" \
  "$RESOURCE_DIR/qwen-model-license.txt"

fetch_verified \
  "https://raw.githubusercontent.com/google-ai-edge/LiteRT-LM/v0.14.0/LICENSE" \
  "c71d239df91726fc519c6eb72d318ec65820627232b2f796219e87dcf35d0ab4" \
  "$RESOURCE_DIR/litertlm-license.txt"

if [ -f "$VENDOR_DIR/runtime-version.txt" ] \
  && [ "$(cat "$VENDOR_DIR/runtime-version.txt")" = "$STAMP_CONTENT" ] \
  && [ -f "$FRAMEWORK_DIR/Info.plist" ]; then
  echo "RelayCode llama.cpp runtime is ready."
  exit 0
fi

archive="$(mktemp /tmp/relaycode-llama-xcframework.XXXXXX.zip)"
extraction="$(mktemp -d /tmp/relaycode-llama-extract.XXXXXX)"
trap 'rm -f "$archive"; rm -rf "$extraction"' EXIT

curl --fail --location --silent --show-error \
  "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_TAG/llama-$LLAMA_TAG-xcframework.zip" \
  --output "$archive"
echo "$LLAMA_ARCHIVE_SHA256  $archive" | shasum -a 256 -c -
unzip -q "$archive" -d "$extraction"

extracted_framework="$(find "$extraction" -type d -name llama.xcframework -print -quit)"
if [ -z "$extracted_framework" ] || [ ! -f "$extracted_framework/Info.plist" ]; then
  echo "Verified llama.cpp archive did not contain llama.xcframework." >&2
  exit 1
fi

if [ -e "$FRAMEWORK_DIR" ]; then
  rm -rf "$FRAMEWORK_DIR"
fi
mv "$extracted_framework" "$FRAMEWORK_DIR"
echo "$STAMP_CONTENT" >"$VENDOR_DIR/runtime-version.txt"

echo "RelayCode llama.cpp runtime is ready."
