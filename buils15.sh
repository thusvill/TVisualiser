#!/bin/bash
set -e

PROJECT="TVisualiser.xcodeproj"
SCHEME="TVisualiser"
SIM_NAME="AppleTV15"
BUNDLE_ID="thusvill.TVisualiser"
UDID="35CF185E-973D-405C-BE50-FE1B401E89E6"

echo "==> Shutting down and resetting simulator (clean slate)..."
xcrun simctl shutdown "$UDID" 2>/dev/null || true

echo "==> Clearing derived data for this project..."
rm -rf ~/Library/Developer/Xcode/DerivedData/TVisualiser-*

echo "==> Resolving Swift Package dependencies..."
xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME"

echo "==> Checking for an internal workspace (SPM-managed projects use one)..."
WORKSPACE_PATH="$PROJECT/project.xcworkspace"
if [ -d "$WORKSPACE_PATH" ]; then
  echo "==> Found internal workspace, will use -workspace instead of -project"
  BUILD_TARGET_FLAG="-workspace"
  BUILD_TARGET_VALUE="$WORKSPACE_PATH"
else
  BUILD_TARGET_FLAG="-project"
  BUILD_TARGET_VALUE="$PROJECT"
fi

build_with_destination() {
  local DEST="$1"
  echo "==> Attempting build with destination: $DEST"
  xcodebuild "$BUILD_TARGET_FLAG" "$BUILD_TARGET_VALUE" \
    -scheme "$SCHEME" \
    -destination "$DEST" \
    -sdk appletvsimulator \
    build
}

# Try by UDID first, then by name, then generic simulator as last resort.
if build_with_destination "platform=tvOS Simulator,id=$UDID"; then
  DEST_USED="id=$UDID"
elif build_with_destination "platform=tvOS Simulator,name=$SIM_NAME"; then
  DEST_USED="name=$SIM_NAME"
elif build_with_destination "generic/platform=tvOS Simulator"; then
  DEST_USED="generic/platform=tvOS Simulator"
else
  echo "!! All destination formats failed. Check the error above."
  echo "!! Common fix: open Xcode once, let it finish indexing/resolving packages, then rerun this script."
  exit 1
fi

echo "==> Build succeeded using destination: $DEST_USED"

echo "==> Locating built .app..."
BUILD_DIR=$(xcodebuild "$BUILD_TARGET_FLAG" "$BUILD_TARGET_VALUE" \
  -scheme "$SCHEME" \
  -destination "platform=tvOS Simulator,id=$UDID" \
  -sdk appletvsimulator \
  -showBuildSettings 2>/dev/null | awk -F'= ' '/ TARGET_BUILD_DIR/{print $2; exit}')

APP_PATH="$BUILD_DIR/$SCHEME.app"

if [ ! -d "$APP_PATH" ]; then
  echo "!! Could not find .app at expected path: $APP_PATH"
  echo "!! Searching DerivedData instead..."
  APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "$SCHEME.app" -path "*appletvsimulator*" 2>/dev/null | head -n 1)
fi

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
  echo "!! Still couldn't find the built .app. Build may have failed silently."
  exit 1
fi

echo "==> Found app at: $APP_PATH"

echo "==> Booting simulator..."
xcrun simctl boot "$UDID" 2>/dev/null || echo "   (already booted)"

echo "==> Opening Simulator.app..."
open -a Simulator

echo "==> Waiting for simulator to finish booting..."
xcrun simctl bootstatus "$UDID" -b

echo "==> Installing app..."
xcrun simctl install "$UDID" "$APP_PATH"

echo "==> Launching app..."
xcrun simctl launch "$UDID" "$BUNDLE_ID"

echo "==> Done! TVisualiser should now be running on the tvOS 15.0 simulator."
