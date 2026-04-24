#!/usr/bin/env bash
# このリポジトリで git hook を有効化するセットアップスクリプト。
# clone 直後に 1 回だけ実行すれば、以降の commit で自動で secret scan が走る。
#
# 実行内容:
#   - scripts/git-hooks/ を hook path に設定 (リポジトリ内 hook なのでチーム間で共有される)
#   - hook ファイル + scripts/check-secrets.sh を実行可能にする
set -euo pipefail

cd "$(dirname "$0")/.."

git config core.hooksPath scripts/git-hooks
chmod +x scripts/git-hooks/pre-commit
chmod +x scripts/check-secrets.sh

echo "✓ git hooks installed: scripts/git-hooks/"
echo "  pre-commit will now scan for leaked credentials before every commit."
echo "  手動実行: ./scripts/check-secrets.sh"
