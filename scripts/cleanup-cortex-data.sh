#!/usr/bin/env bash
# Cort:EX の全ローカルデータを削除するクリーンアップユーティリティ。
# 新 Mac / 別ユーザーへ配布 or 譲渡する前に実行すると、
# Keychain / ダウンロード / キャッシュ / お気に入り / 設定が全て消える。
#
# 2026-04-23 credentials 流出事件を受けた措置。v02a-f6 以前のバイナリを install した
# 端末には compromised credentials が Keychain に残る可能性があるため、譲渡前に必ず実行する。
#
# 使い方:
#   ./scripts/cleanup-cortex-data.sh         # 確認あり
#   ./scripts/cleanup-cortex-data.sh --force # 確認なし（スクリプト組み込み用）
#
# Note: App 内の「全データリセット」ボタンでも同等の処理が実行可能。
#       こちらは App を開けない状況 (アカウント変更前 / uninstall 後) 向け。

set -euo pipefail

BUNDLE_ID="com.kanayayuutou.CortEX"
SERVICE="com.kanayayuutou.EhViewer"

FORCE="${1:-}"
if [[ "$FORCE" != "--force" ]]; then
    echo "以下を全て削除します:"
    echo "  - Keychain (service=$SERVICE) の全エントリ"
    echo "  - ~/Library/Containers/$BUNDLE_ID/ (Mac Catalyst 版 sandbox 内全データ)"
    echo "  - ~/Library/Application Scripts/$BUNDLE_ID/"
    echo "  - ~/Library/Group Containers/*.$BUNDLE_ID/"
    echo "  - ~/Library/HTTPStorages/$BUNDLE_ID*"
    echo "  - ~/Library/Preferences/$BUNDLE_ID.plist"
    echo "  - ~/Library/Caches/$BUNDLE_ID/"
    echo ""
    read -p "続行しますか？ (yes/no) " ans
    [[ "$ans" == "yes" ]] || { echo "キャンセル"; exit 1; }
fi

echo "==> Keychain 削除"
# security コマンドで kSecClassGenericPassword の service 一致を全削除
# (複数エントリに対応するためループで消える分だけ消す)
while security delete-generic-password -s "$SERVICE" 2>/dev/null; do
    echo "  removed one keychain entry"
done
echo "  keychain cleanup done"

echo "==> アプリデータ削除"
# Mac Catalyst は sandbox 内にデータを保存
for path in \
    "$HOME/Library/Containers/$BUNDLE_ID" \
    "$HOME/Library/Application Scripts/$BUNDLE_ID" \
    "$HOME/Library/HTTPStorages/$BUNDLE_ID" \
    "$HOME/Library/HTTPStorages/$BUNDLE_ID.binarycookies" \
    "$HOME/Library/Preferences/$BUNDLE_ID.plist" \
    "$HOME/Library/Caches/$BUNDLE_ID" \
    ; do
    if [[ -e "$path" ]]; then
        rm -rf "$path"
        echo "  removed: $path"
    fi
done

# Group Container (app group 使ってる場合)
for path in "$HOME/Library/Group Containers/"*."$BUNDLE_ID"; do
    if [[ -d "$path" ]]; then
        rm -rf "$path"
        echo "  removed: $path"
    fi
done

echo ""
echo "==========================================="
echo " Cort:EX の全ローカルデータ削除完了"
echo "==========================================="
echo " 次回 App 起動時は未ログイン・DL 0 件の"
echo " 完全なクリーンインストール状態になります。"
echo "==========================================="
