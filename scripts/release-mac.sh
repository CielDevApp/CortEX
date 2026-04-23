#!/usr/bin/env bash
# Mac Catalyst Release Build + Notarize Pipeline
#
# 前提 (初回のみ):
#   1. Xcode → Settings → Accounts → Manage Certificates → "+" → Developer ID Application
#   2. https://appleid.apple.com で App-Specific Password を生成
#   3. Keychain に保存: xcrun notarytool store-credentials AC_PASSWORD \
#        --apple-id "<your-apple-id>" --team-id "<your-team-id>"
#      (プロンプトで app-specific password を入力)
#
# 他開発者向け: ExportOptions-DeveloperID.plist / ExportOptions-iOS.plist 内の
# teamID (6Z9S7D5BMC) を自分の Team ID に書き換える。
#
# 使い方: ./scripts/release-mac.sh [version]
#   例: ./scripts/release-mac.sh v02a-f6

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VERSION="${1:-$(date +%Y%m%d-%H%M)}"
BUILD_DIR="$ROOT/build/mac-release"
ARCHIVE_PATH="$BUILD_DIR/EhViewer.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP_PATH="$EXPORT_DIR/EhViewer.app"
ZIP_PATH="$BUILD_DIR/EhViewer-macOS-$VERSION.zip"
EXPORT_OPTIONS="$ROOT/scripts/ExportOptions-DeveloperID.plist"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> [1/5] Archive (Mac Catalyst Release)"
xcodebuild archive \
    -project EhViewer.xcodeproj \
    -scheme EhViewer \
    -configuration Release \
    -destination 'generic/platform=macOS,variant=Mac Catalyst' \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Automatic \
    | xcbeautify 2>/dev/null || xcodebuild archive \
        -project EhViewer.xcodeproj \
        -scheme EhViewer \
        -configuration Release \
        -destination 'generic/platform=macOS,variant=Mac Catalyst' \
        -archivePath "$ARCHIVE_PATH" \
        CODE_SIGN_STYLE=Automatic

echo "==> [2/5] Export (Developer ID)"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS"

[[ -d "$APP_PATH" ]] || { echo "ERROR: $APP_PATH not found"; exit 1; }

echo "==> [3/5] Zip for notarization"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> [4/5] Submit to Apple Notary Service (wait for result)"
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile AC_PASSWORD \
    --wait

echo "==> [5/5] Staple notarization ticket"
xcrun stapler staple "$APP_PATH"

# Re-zip the stapled app (stapled ticket must be inside the distributed zip)
rm "$ZIP_PATH"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo ""
echo "========================================"
echo " Done: $ZIP_PATH"
echo "========================================"
echo ""
echo "GitHub Releases に upload:"
echo "  gh release create $VERSION \"$ZIP_PATH\" --title \"$VERSION\" --notes \"Mac Catalyst build\""
echo ""
