#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
DERIVED="$BUILD/DerivedData"
OUTPUT="$ROOT/output"

rm -rf "$BUILD" "$OUTPUT/Payload" "$OUTPUT/SimulMeet-unsigned.ipa"
mkdir -p "$BUILD" "$OUTPUT/Payload"

xcodebuild \
  -project "$ROOT/SimulMeet.xcodeproj" \
  -scheme SimulMeet \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  clean build

APP="$DERIVED/Build/Products/Release-iphoneos/SimulMeet.app"
if [ ! -d "$APP" ]; then
  echo "Build finished but SimulMeet.app was not found: $APP" >&2
  exit 1
fi

cp -R "$APP" "$OUTPUT/Payload/SimulMeet.app"
cd "$OUTPUT"
/usr/bin/zip -qry "SimulMeet-unsigned.ipa" Payload
rm -rf Payload

echo "Created: $OUTPUT/SimulMeet-unsigned.ipa"
echo "This IPA is intentionally unsigned. Sign it with your certificate/profile before installation."
