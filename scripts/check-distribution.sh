#!/usr/bin/env bash
# 憲法第18条-4/8 配布物ゲート (機械強制版)
#
# 背景: 2026-04-23 E-H credentials 曝露 (人力チェック飛ばし) →
#       2026-07-11 v02a-f32 個人通知コード混入 (同じく人力チェック飛ばし)。
#       規律で二度破られたため、release-ios.sh から自動実行して
#       1件でもヒットしたら exit 1 でリリースを止める。
#
# 使い方: ./scripts/check-distribution.sh <Payload/EhViewer.app へのパス>

set -euo pipefail

APP="${1:?usage: check-distribution.sh <path-to-.app>}"
BIN="$APP/$(basename "$APP" .app)"
[[ -f "$BIN" ]] || { echo "ERROR: binary not found: $BIN"; exit 1; }

FAIL=0
hit() { echo "✘ [18条ゲート] $1"; FAIL=1; }

# 1. Tailscale CGNAT 帯 (100.64.0.0/10) の IP — 私設サーバー直結の証拠
if strings "$BIN" | grep -nE '\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]+\.[0-9]+\b' | head -5 | grep .; then
    hit "バイナリに Tailscale 私設 IP が残存"
fi

# 2. 個人識別子・私設ホスト名
#    bundle ID (com.kanayayuutou.*) は全アプリで公開情報のため除外。
#    /Users/kanayayuutou 等のビルドパス漏れ・メール・私設ホストは検知対象。
if strings "$BIN" | grep -niE 'kanayayuutou|kan8223|nas\.local|cortex-poller' \
        | grep -vE 'com\.kanayayuutou\.' | head -5 | grep .; then
    hit "バイナリに個人識別子/私設ホスト名が残存"
fi

# 3. credentials 実値 (シンボル名でなく値。passHash=32hex 等)
if strings "$BIN" | grep -nE "(passHash|igneous|memberID)[\"']? *[:=] *[\"']?[a-f0-9]{16,}" | head -5 | grep .; then
    hit "バイナリに credentials 実値らしき文字列"
fi
if strings "$BIN" | grep -n "BEGIN.*PRIVATE KEY" | head -3 | grep .; then
    hit "バイナリに秘密鍵"
fi

# 4. Info.plist の ATS 例外 (私設サーバー向け平文 HTTP 許可の混入検知)
if /usr/libexec/PlistBuddy -c "Print :NSAppTransportSecurity" "$APP/Info.plist" >/dev/null 2>&1; then
    hit "Info.plist に NSAppTransportSecurity 例外 (意図したものなら本スクリプトを更新すること)"
fi

# 5. 署名済み entitlements の aps-environment (APNs は personal-notify 専用)
if codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "aps-environment"; then
    hit "entitlements に aps-environment (APNs) が残存"
fi

if [[ "$FAIL" -eq 1 ]]; then
    echo ""
    echo "========================================"
    echo " 第18条ゲート FAILED — 配布中止"
    echo "========================================"
    exit 1
fi
echo "✔ [18条ゲート] OK: 配布物に私設 IP / 個人情報 / credentials / APNs なし"
