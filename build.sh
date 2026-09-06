#!/bin/bash

# Define custom build output folder to avoid DerivedData confusion
BUILD_DIR="$(pwd)/build"

echo "🧹 Cleaning previous build artifacts..."
rm -rf "$BUILD_DIR" ~/Desktop/Payload ~/Desktop/TVisualiser.ipa

echo "🔨 Building TVisualiser for physical tvOS device (arm64)..."
xcodebuild -project TVisualiser.xcodeproj \
           -scheme TVisualiser \
           -sdk appletvos \
           -configuration Release \
           -derivedDataPath "$BUILD_DIR" \
           CODE_SIGN_IDENTITY="" \
           CODE_SIGNING_REQUIRED=NO \
           CODE_SIGNING_ALLOWED=NO \
           build

# Locate the exact device app binary
APP_PATH=$(find "$BUILD_DIR/Build/Products/Release-appletvos" -name "TVisualiser.app" -type d | head -n 1)

if [ -n "$APP_PATH" ] && [ -d "$APP_PATH" ]; then
    echo "📦 Found built app at: $APP_PATH"
    
    # Create Payload folder and copy .app
    mkdir -p ~/Desktop/Payload
    cp -R "$APP_PATH" ~/Desktop/Payload/
    
    # Navigate to Desktop to perform clean compression
    cd ~/Desktop || exit 1
    
    echo "🗜️ Compressing into TVisualiser.ipa..."
    zip -r -y TVisualiser.ipa Payload
    
    # Clean up Payload folder
    rm -rf Payload
    
    echo "✅ Success! TVisualiser.ipa is on your Desktop."
    open ~/Desktop
else
    echo "❌ Error: Failed to find TVisualiser.app in Release-appletvos build directory."
    exit 1
fi


