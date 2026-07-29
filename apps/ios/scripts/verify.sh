#!/usr/bin/env bash
set -euo pipefail

IOS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$IOS_DIR/../.." && pwd)"
IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
LINK_DIR="$(mktemp -d /tmp/relaycode-ios-link.XXXXXX)"
ASSET_DIR="$(mktemp -d /tmp/relaycode-ios-assets.XXXXXX)"

cd "$REPO_DIR"
npm run ios:typecheck
npm run ios:test

xcrun --sdk iphoneos swiftc \
  -emit-module \
  -emit-object \
  -parse-as-library \
  -module-name RelayCodeCore \
  -target arm64-apple-ios17.0 \
  -sdk "$IOS_SDK" \
  -emit-module-path "$LINK_DIR/RelayCodeCore.swiftmodule" \
  -o "$LINK_DIR/RelayCodeCore.o" \
  "$IOS_DIR"/RelayCodeCore/*.swift

xcrun --sdk iphoneos swiftc \
  -emit-executable \
  -parse-as-library \
  -module-name RelayCode \
  -target arm64-apple-ios17.0 \
  -sdk "$IOS_SDK" \
  -I "$LINK_DIR" \
  "$IOS_DIR"/RelayCode/*.swift \
  "$LINK_DIR/RelayCodeCore.o" \
  -o "$LINK_DIR/RelayCode"

ACTOOL_REPORT="$ASSET_DIR/actool-report.plist"

set +e
xcrun actool "$IOS_DIR/RelayCode/Assets.xcassets" \
  --compile "$ASSET_DIR" \
  --platform iphoneos \
  --minimum-deployment-target 17.0 \
  --app-icon AppIcon \
  --accent-color AccentColor \
  --output-partial-info-plist "$ASSET_DIR/asset-info.plist" \
  >"$ACTOOL_REPORT"
ACTOOL_STATUS=$?
set -e

if [ "$ACTOOL_STATUS" -ne 0 ]; then
  if rg -q "No available simulator runtimes for platform iphonesimulator" "$ACTOOL_REPORT" \
    && [ -f "$ASSET_DIR/asset-info.plist" ]; then
    echo "Asset outputs generated; simulator-runtime validation skipped because no iOS runtime is installed."
  else
    sed -n '1,220p' "$ACTOOL_REPORT"
    exit "$ACTOOL_STATUS"
  fi
fi

plutil -lint \
  "$IOS_DIR/RelayCode/Info.plist" \
  "$IOS_DIR/RelayCode/PrivacyInfo.xcprivacy" \
  "$ASSET_DIR/asset-info.plist"

file "$LINK_DIR/RelayCode"
echo "RelayCode iOS verification passed."
