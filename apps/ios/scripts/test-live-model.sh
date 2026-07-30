#!/usr/bin/env bash
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$(mktemp -d /tmp/relaycode-model-smoke.XXXXXX)"
trap 'rm -rf "$BUILD_DIR"' EXIT

MODEL_BASE_URL="${RELAYCODE_MODEL_BASE_URL:-http://127.0.0.1:11434/v1}"
MODEL_ID="${RELAYCODE_MODEL_ID:-qwen2.5-coder:0.5b}"

xcrun swiftc \
  -parse-as-library \
  "$IOS_DIR"/RelayCodeCore/*.swift \
  "$IOS_DIR/scripts/live-model-smoke.swift" \
  -o "$BUILD_DIR/live-model-smoke"

"$BUILD_DIR/live-model-smoke" "$MODEL_BASE_URL" "$MODEL_ID"
