#!/usr/bin/env bash
# iOS Release IPA Build Pipeline
#
# 生成物: build/ios-release/EhViewer-<version>.ipa
# 用途: AltStore / Sideloadly / TrollStore で再署名・インストールするユーザーへの配布
#       (AltStore / Sideloadly はユーザーの Personal Team で再署名するので
#        この IPA の signature は剥がされる)
#
# 使い方: ./scripts/release-ios.sh [version]
#   例: ./scripts/release-ios.sh v02a-f6

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

VERSION="${1:-$(date +%Y%m%d-%H%M)}"
BUILD_DIR="$ROOT/build/ios-release"
ARCHIVE_PATH="$BUILD_DIR/EhViewer.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
IPA_FINAL="$BUILD_DIR/EhViewer-$VERSION.ipa"
EXPORT_OPTIONS="$ROOT/scripts/ExportOptions-iOS.plist"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# アップデート確認機能の自己バージョン (AppVersion.releaseTag) を今回のタグへ同期。
# v* 形式のタグ指定時のみ。手動更新の腐り (例: 設定が古いまま) を防ぐ保険。
VERSION_FILE="$ROOT/EhViewer/Services/UpdateChecker.swift"
if [[ "$VERSION" == v* && -f "$VERSION_FILE" ]]; then
    echo "==> Sync AppVersion.releaseTag = $VERSION"
    /usr/bin/sed -i '' -E "s/(static let releaseTag = \")[^\"]*(\")/\1${VERSION}\2/" "$VERSION_FILE"
    grep -n "static let releaseTag" "$VERSION_FILE" || true
fi

echo "==> [1/3] Archive (iOS Release)"
xcodebuild archive \
    -project EhViewer.xcodeproj \
    -scheme EhViewer \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Automatic

echo "==> [2/3] Export (Development IPA)"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS"

[[ -f "$EXPORT_DIR/EhViewer.ipa" ]] || { echo "ERROR: IPA not found"; exit 1; }

echo "==> [2.5/3] 憲法第18条 配布物ゲート (私設IP/個人情報/credentials/APNs スキャン)"
GATE_TMP="$BUILD_DIR/gate-check"
rm -rf "$GATE_TMP"
mkdir -p "$GATE_TMP"
unzip -oq "$EXPORT_DIR/EhViewer.ipa" -d "$GATE_TMP"
"$ROOT/scripts/check-distribution.sh" "$GATE_TMP/Payload/EhViewer.app"

echo "==> [3/3] Rename IPA with version tag"
cp "$EXPORT_DIR/EhViewer.ipa" "$IPA_FINAL"

SIZE=$(du -h "$IPA_FINAL" | cut -f1)

echo ""
echo "========================================"
echo " Done: $IPA_FINAL ($SIZE)"
echo "========================================"
echo ""
echo "GitHub Releases の既存タグに追加 upload:"
echo "  gh release upload $VERSION \"$IPA_FINAL\" --clobber"
echo ""
echo "新規リリースとして作成する場合:"
echo "  gh release create $VERSION \"$IPA_FINAL\" --title \"$VERSION\" --notes \"iOS IPA\""
echo ""
