#!/usr/bin/env bash
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR_DIR="$IOS_DIR/RelayCodeLinuxRuntime/vendor"
RESOURCE_DIR="$IOS_DIR/RelayCode/Resources/Linux"
RUNTIME_COMMIT="84858f58cb41899705e2ff2d6ee3b2d5c0795bfe"
IMAGE_COMMIT="25fb23e7635c485c08de4437e91f15b8e1805770"

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
  temporary="$(mktemp /tmp/relaycode-runtime-download.XXXXXX)"
  curl --fail --location --silent --show-error "$url" --output "$temporary"
  echo "$expected_sha  $temporary" | shasum -a 256 -c -
  mv "$temporary" "$destination"
}

fetch_verified \
  "https://raw.githubusercontent.com/cnlohr/mini-rv32ima/$RUNTIME_COMMIT/mini-rv32ima/mini-rv32ima.h" \
  "049b916d9ad628fbe9f67fd3401412c0100b0369efc93acdf81c0c0d51293dc1" \
  "$VENDOR_DIR/mini-rv32ima.h"

fetch_verified \
  "https://raw.githubusercontent.com/cnlohr/mini-rv32ima/$RUNTIME_COMMIT/mini-rv32ima/default64mbdtc.h" \
  "1ba7a0af834dfbd4e5c24260e33f05779feea897b8f963c84ac4c81a0ea03745" \
  "$VENDOR_DIR/default64mbdtc.h"

fetch_verified \
  "https://raw.githubusercontent.com/cnlohr/mini-rv32ima-images/$IMAGE_COMMIT/LICENSE" \
  "3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986" \
  "$RESOURCE_DIR/linux-guest-license.txt"

if [ -f "$RESOURCE_DIR/linux-rv32.img" ] \
  && echo "5f596134705d5aa8e7c8c406695a560d08faaff4a86bc715659e53cbebba6c7e  $RESOURCE_DIR/linux-rv32.img" \
    | shasum -a 256 -c - >/dev/null 2>&1; then
  echo "RelayCode Linux runtime assets are ready."
  exit 0
fi

image_archive="$(mktemp /tmp/relaycode-linux-image.XXXXXX)"
trap 'rm -f "$image_archive"' EXIT

fetch_verified \
  "https://raw.githubusercontent.com/cnlohr/mini-rv32ima-images/$IMAGE_COMMIT/images/linux-6.1.14-rv32nommu-cnl-1.zip" \
  "add651195348b538c309becb39c5f8ef4f9d15ec275a2954b02016fc38091393" \
  "$image_archive"

temporary_image="$(mktemp /tmp/relaycode-linux-kernel.XXXXXX)"
unzip -p "$image_archive" Image >"$temporary_image"
echo "5f596134705d5aa8e7c8c406695a560d08faaff4a86bc715659e53cbebba6c7e  $temporary_image" \
  | shasum -a 256 -c -
mv "$temporary_image" "$RESOURCE_DIR/linux-rv32.img"

echo "RelayCode Linux runtime assets are ready."
