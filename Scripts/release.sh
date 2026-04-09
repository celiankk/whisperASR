#!/bin/bash
set -euo pipefail

# Release script: build → sign with Developer ID → notarize → staple
# Usage: bash Scripts/release.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="WhisperASR"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"
ZIP_PATH="$PROJECT_DIR/$APP_NAME.zip"
CODESIGN_IDENTITY="Developer ID Application: MAO YUAN KAO (3WD42GF27D)"
KEYCHAIN_PROFILE="notarytool"

# Step 1: Build release (reuses build_release.sh with signing)
echo "==> Step 1/4: Building signed release..."
CODESIGN_IDENTITY="$CODESIGN_IDENTITY" bash "$SCRIPT_DIR/build_release.sh"

# Step 2: Create zip for notarization
echo ""
echo "==> Step 2/4: Creating zip for notarization..."
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
echo "    Created $ZIP_PATH ($(du -h "$ZIP_PATH" | cut -f1))"

# Step 3: Submit for notarization and wait
echo ""
echo "==> Step 3/4: Submitting to Apple notary service (this may take a few minutes)..."
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait

# Step 4: Staple the ticket
echo ""
echo "==> Step 4/4: Stapling notarization ticket..."
xcrun stapler staple "$APP_BUNDLE"

# Re-create zip with stapled app
rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

echo ""
echo "==> Release complete!"
echo "    App:  $APP_BUNDLE"
echo "    Zip:  $ZIP_PATH"
echo "    Signed with: $CODESIGN_IDENTITY"
echo "    Notarized and stapled."
echo ""
echo "    To install: cp -r $APP_BUNDLE /Applications/"
