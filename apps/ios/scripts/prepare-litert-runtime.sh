#!/usr/bin/env bash
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_DIR="$IOS_DIR/RelayCodeLiteRTRuntime"
VENDOR_DIR="$RUNTIME_DIR/vendor"
SOURCE_DIR="$RUNTIME_DIR/Sources/LiteRTLM"
FRAMEWORK_DIR="$VENDOR_DIR/CLiteRTLM.xcframework"
LITERT_TAG="v0.14.0"
LITERT_COMMIT="80f301ff9a3b02c2c1e7be2dd1a567752f7b51b6"
LITERT_ARCHIVE_SHA256="dddac2f6713ed65eaf01c18e115d9fec22184adf575cc7856a21387e8ba937e1"
PATCHED_CONVERSATION_SHA256="6a40a9483372629df56ab5d1ee45634e69396c3d499da2717d59660ae3338f2b"
STAMP_CONTENT="$LITERT_TAG $LITERT_COMMIT $LITERT_ARCHIVE_SHA256"

mkdir -p "$VENDOR_DIR" "$SOURCE_DIR"

fetch_verified() {
  local url="$1"
  local expected_sha="$2"
  local destination="$3"

  if [ -f "$destination" ] \
    && echo "$expected_sha  $destination" | shasum -a 256 -c - >/dev/null 2>&1; then
    return
  fi

  local temporary
  temporary="$(mktemp /tmp/relaycode-litert-download.XXXXXX)"
  curl --fail --location --silent --show-error "$url" --output "$temporary"
  echo "$expected_sha  $temporary" | shasum -a 256 -c -
  mv "$temporary" "$destination"
}

fetch_source() {
  local filename="$1"
  local expected_sha="$2"
  fetch_verified \
    "https://raw.githubusercontent.com/google-ai-edge/LiteRT-LM/$LITERT_COMMIT/swift/$filename" \
    "$expected_sha" \
    "$SOURCE_DIR/$filename"
}

fetch_patched_source() {
  local filename="$1"
  local source_sha="$2"
  local patched_sha="$3"
  local destination="$SOURCE_DIR/$filename"

  if [ -f "$destination" ] \
    && echo "$patched_sha  $destination" | shasum -a 256 -c - >/dev/null 2>&1; then
    return
  fi

  fetch_verified \
    "https://raw.githubusercontent.com/google-ai-edge/LiteRT-LM/$LITERT_COMMIT/swift/$filename" \
    "$source_sha" \
    "$destination"
  patch -d "$SOURCE_DIR" -p1 \
    < "$IOS_DIR/patches/litertlm-maximum-output-tokens.patch"
  echo "$patched_sha  $destination" | shasum -a 256 -c -
}

fetch_source "Benchmark.swift" "33f131245456ceef8a2b8eaf8a5ea1ec310cec6124e3227f5e7a3ed35e0a3199"
fetch_source "Capabilities.swift" "30bc7cd1057f9100ef19249863266481a61e4c80d2a28ccb6098236318dee020"
fetch_source "Config.swift" "3f1c93449c679736b4e487376805161673b440c74244b07bb15c3c288e6aa929"
fetch_patched_source \
  "Conversation.swift" \
  "178a722d7727febd319f9852b33f7094d1e6d251541f9e0f3ad210ae6694eadf" \
  "$PATCHED_CONVERSATION_SHA256"
fetch_source "Engine.swift" "aae9f14109d8cc6aeec34c6c67e6b49f096bad4d54b81813e5901a0efd8eab2c"
fetch_source "ExperimentalFlags.swift" "bc2d554c686a0db84d553174d1acffbcd38e151a8f10f3f0b78e747a11400621"
fetch_source "LiteRTLMError.swift" "0ab54191c0f0a01ce03b69b411b968400bee295d4672fb51519713f3f275dc85"
fetch_source "Message.swift" "c9f3bcaa02897e406b8e3208c9c9657c8035d4830ee61dd0c5a2a6536f814d55"
fetch_source "Tool.swift" "d9698c6c7f8425cfa1f479cec5070fe94d9ca732b3e20b171e3dd90ca1545422"
fetch_source "ToolManager.swift" "7fed45d66e562a153dd61e57a8cc67cbd89fa063d1c09d9d20626ea48574d3f7"

if [ -f "$VENDOR_DIR/runtime-version.txt" ] \
  && [ "$(cat "$VENDOR_DIR/runtime-version.txt")" = "$STAMP_CONTENT" ] \
  && [ -f "$FRAMEWORK_DIR/Info.plist" ]; then
  echo "RelayCode LiteRT-LM runtime is ready."
  exit 0
fi

archive="$(mktemp /tmp/relaycode-litert-xcframework.XXXXXX.zip)"
extraction="$(mktemp -d /tmp/relaycode-litert-extract.XXXXXX)"
trap 'rm -f "$archive"; rm -rf "$extraction"' EXIT

curl --fail --location --silent --show-error \
  "https://github.com/google-ai-edge/LiteRT-LM/releases/download/$LITERT_TAG/CLiteRTLM.xcframework.zip" \
  --output "$archive"
echo "$LITERT_ARCHIVE_SHA256  $archive" | shasum -a 256 -c -
unzip -q "$archive" -d "$extraction"

extracted_framework="$(find "$extraction" -type d -name CLiteRTLM.xcframework -print -quit)"
if [ -z "$extracted_framework" ] || [ ! -f "$extracted_framework/Info.plist" ]; then
  echo "Verified LiteRT-LM archive did not contain CLiteRTLM.xcframework." >&2
  exit 1
fi

if [ -e "$FRAMEWORK_DIR" ]; then
  rm -rf "$FRAMEWORK_DIR"
fi
mv "$extracted_framework" "$FRAMEWORK_DIR"
echo "$STAMP_CONTENT" >"$VENDOR_DIR/runtime-version.txt"

echo "RelayCode LiteRT-LM runtime is ready."
