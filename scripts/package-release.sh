#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(node -p "require('$REPO_DIR/package.json').version")"
ARTIFACT_DIR="$REPO_DIR/artifacts"
STAGE_DIR="$(mktemp -d /tmp/relaycode-release.XXXXXX)"
ARCHIVE="$ARTIFACT_DIR/relaycode-v$VERSION.tar.gz"

cd "$REPO_DIR"
npm run build
npm run build:cli

mkdir -p \
  "$ARTIFACT_DIR" \
  "$STAGE_DIR/bin" \
  "$STAGE_DIR/share/relaycode/mobile"

cp "$REPO_DIR/dist/relaycode" "$STAGE_DIR/bin/relaycode"
cp -R "$REPO_DIR/apps/mobile/dist/." "$STAGE_DIR/share/relaycode/mobile/"
cp \
  "$REPO_DIR/LICENSE" \
  "$REPO_DIR/README.md" \
  "$REPO_DIR/SECURITY.md" \
  "$STAGE_DIR/"

tar -C "$STAGE_DIR" -czf "$ARCHIVE" .
(
  cd "$ARTIFACT_DIR"
  shasum -a 256 "$(basename "$ARCHIVE")" >"$(basename "$ARCHIVE").sha256"
)

"$STAGE_DIR/bin/relaycode" --version
test -f "$STAGE_DIR/share/relaycode/mobile/index.html"

echo "Created $ARCHIVE"
echo "Created $ARCHIVE.sha256"
