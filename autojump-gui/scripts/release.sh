#!/usr/bin/env bash
# Build, sign, notarize, and package autojump-gui as a distributable DMG.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/release.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "error: $ENV_FILE missing — copy release.env.example and fill in" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$ENV_FILE"

: "${TEAM_ID:?TEAM_ID required in release.env}"
: "${API_KEY_ID:?API_KEY_ID required in release.env}"
: "${API_KEY_ISSUER:?API_KEY_ISSUER required in release.env}"
: "${API_KEY_PATH:?API_KEY_PATH required in release.env}"
API_KEY_PATH="${API_KEY_PATH/#\$HOME/$HOME}"
API_KEY_PATH="${API_KEY_PATH/#\~/$HOME}"
[[ -f "$API_KEY_PATH" ]] || { echo "error: API key not found at $API_KEY_PATH" >&2; exit 1; }

SCHEME="autojump-gui"
APP_NAME="Autojump"
PROJECT="$PROJECT_DIR/autojump-gui.xcodeproj"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/$APP_NAME.app"
NOTARY_ZIP="$BUILD_DIR/$APP_NAME-app.zip"

VERSION="$(xcodebuild -showBuildSettings -project "$PROJECT" -scheme "$SCHEME" -configuration Release 2>/dev/null \
    | awk -F'= ' '/^[[:space:]]*MARKETING_VERSION/ {print $2; exit}')"
VERSION="${VERSION:-1.0}"
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Archiving Release build"
xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    archive

echo "==> Exporting Developer ID-signed .app"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$SCRIPT_DIR/ExportOptions.plist"

echo "==> Submitting .app to Apple notary service"
ditto -c -k --keepParent "$APP_PATH" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" \
    --key "$API_KEY_PATH" \
    --key-id "$API_KEY_ID" \
    --issuer "$API_KEY_ISSUER" \
    --wait

echo "==> Stapling notarization ticket to .app"
xcrun stapler staple "$APP_PATH"

echo "==> Building DMG"
# hdiutil-based packaging: no AppleScript, no Finder dependency. The DMG ships the .app
# alongside an /Applications symlink so users can drag-install. We deliberately skipped
# create-dmg here because its Finder-styling AppleScript hangs indefinitely on modern
# macOS without explicit Automation→Finder permission for the parent process.
rm -f "$DMG_PATH"
DMG_STAGE="$BUILD_DIR/dmg-stage"
rm -rf "$DMG_STAGE"
mkdir -p "$DMG_STAGE"
cp -R "$APP_PATH" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
hdiutil create \
    -volname "$APP_NAME $VERSION" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -format UDZO \
    "$DMG_PATH"
rm -rf "$DMG_STAGE"

echo "==> Notarizing DMG"
xcrun notarytool submit "$DMG_PATH" \
    --key "$API_KEY_PATH" \
    --key-id "$API_KEY_ID" \
    --issuer "$API_KEY_ISSUER" \
    --wait

echo "==> Stapling notarization ticket to DMG"
xcrun stapler staple "$DMG_PATH"

echo ""
echo "Done."
echo "DMG: $DMG_PATH"
echo "Verify with:  spctl -a -t open --context context:primary-signature -vv \"$DMG_PATH\""
