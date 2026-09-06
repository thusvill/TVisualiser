# 1. Clean & Build for real tvOS device architecture
xcodebuild -project TVisualiser.xcodeproj \
  -scheme TVisualiser \
  -sdk appletvos \
  -configuration Release \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

# 2. Package into TrollStore IPA
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "TVisualiser.app" -type d | head -n 1)

if [ -n "$APP_PATH" ]; then
  mkdir -p ~/Desktop/Payload
  cp -r "$APP_PATH" ~/Desktop/Payload/
  cd ~/Desktop
  zip -r TVisualiser.ipa Payload
  rm -rf Payload
  echo " success! TVisualiser.ipa is on your Desktop."
else
  echo " error: Could not find built TVisualiser.app bundle."
fi
