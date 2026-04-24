#!/usr/bin/env bash
# Secret / credential scanner for pre-commit hook and CI.
# Exits 1 if any prohibited pattern is found in tracked/staged Swift/plist/yaml/sh/json files.
#
# 使い方:
#   ./scripts/check-secrets.sh          # 全 tracked file をスキャン (CI用)
#   ./scripts/check-secrets.sh --staged # git staged 分のみスキャン (pre-commit hook用)
#
# 履歴: 2026-04-23 に Mac Catalyst 用 DEBUG cookie 注入ブロックが削除忘れでリリースされ、
# ユーザーの E-Hentai credentials が GitHub public repo に約4日間曝露した事件を受け、
# 再発防止策として導入。
set -euo pipefail

cd "$(dirname "$0")/.."

MODE="${1:-all}"

# スキャン対象ファイル選択
# 自分自身 (scripts/check-secrets.sh) はパターン定義を含むので必ず除外。
# scripts/git-hooks/pre-commit はスキャナ本体を呼ぶだけなので除外してもしなくても可。
SELF_EXCLUDE='^(scripts/check-secrets\.sh|scripts/git-hooks/pre-commit)$'
if [[ "$MODE" == "--staged" ]]; then
    FILES=$(git diff --cached --name-only --diff-filter=ACMR | grep -E '\.(swift|plist|yaml|yml|sh|json|entitlements|xcconfig|pbxproj)$' | grep -vE "$SELF_EXCLUDE" || true)
else
    FILES=$(git ls-files | grep -E '\.(swift|plist|yaml|yml|sh|json|entitlements|xcconfig|pbxproj)$' | grep -vE "$SELF_EXCLUDE" || true)
fi

if [[ -z "$FILES" ]]; then
    echo "[check-secrets] no target files to scan"
    exit 0
fi

FAIL=0
matched() {
    echo "❌ SECRET DETECTED: $1"
    echo "  $2"
    FAIL=1
}

# === Pattern 1: 過去に流出した既知の credentials (再流入防止) ===
# 2026-04-23 事件で revoke 済みだが history に残る。新規コミットに再登場したら即 block
KNOWN_LEAKED=(
    '1532300'
    '28d002497da9623ccb2f6ffd144f633b'
    '1n2bd6yv2ulot91qa'
)
for pat in "${KNOWN_LEAKED[@]}"; do
    HITS=$(grep -nE "$pat" $FILES 2>/dev/null || true)
    if [[ -n "$HITS" ]]; then
        matched "known-leaked credential pattern: $pat" "$HITS"
    fi
done

# === Pattern 2: Credential 風のハードコード ===
# E-Hentai cookie fields + 一般的な secret 名
# 注: `saveCredentials(` そのものは CookieManager.saveCredentials を呼ぶ正規経路もあるので
# 「リテラル引数」を含むケースのみ検出する (複数行にまたがるので rough match)
REGEX_CREDENTIAL=(
    'memberID[[:space:]]*[:=][[:space:]]*["\x27][0-9]{3,}["\x27]'
    'passHash[[:space:]]*[:=][[:space:]]*["\x27][a-fA-F0-9]{16,}["\x27]'
    'igneous[[:space:]]*[:=][[:space:]]*["\x27][a-z0-9]{8,}["\x27]'
    'ipb_member_id[[:space:]]*=[[:space:]]*[0-9]{3,}'
    'ipb_pass_hash[[:space:]]*=[[:space:]]*[a-fA-F0-9]{16,}'
    'password[[:space:]]*[:=][[:space:]]*["\x27][^"\x27[:space:]]{4,}["\x27]'
    'token[[:space:]]*[:=][[:space:]]*["\x27][A-Za-z0-9_\-]{20,}["\x27]'
    'api[_-]?key[[:space:]]*[:=][[:space:]]*["\x27][A-Za-z0-9_\-]{16,}["\x27]'
    'Bearer[[:space:]]+[A-Za-z0-9_\-]{16,}'
    'BEGIN[[:space:]]+(RSA[[:space:]]+)?PRIVATE[[:space:]]+KEY'
    'sk-[A-Za-z0-9]{32,}'
    'xoxb-[A-Za-z0-9\-]{20,}'
    'ghp_[A-Za-z0-9]{20,}'
    'AKIA[A-Z0-9]{16}'
)
for pat in "${REGEX_CREDENTIAL[@]}"; do
    HITS=$(grep -nEI "$pat" $FILES 2>/dev/null || true)
    if [[ -n "$HITS" ]]; then
        matched "credential-like hardcoded value: $pat" "$HITS"
    fi
done

# === Pattern 3: DEBUG cookie 注入コメント (2026-04-23 事件の再発防止) ===
REGEX_DEBUG_INJECT=(
    'injecting.*cookies.*to.*[Kk]eychain'
    'iPad.*sim.*から.*吸い出.*cookie'
    'DEBUG.*cookie.*hardcode'
    '注入完了後.*削除する'
    'cookie.*hardcode.*回避'
)
for pat in "${REGEX_DEBUG_INJECT[@]}"; do
    HITS=$(grep -nE "$pat" $FILES 2>/dev/null || true)
    if [[ -n "$HITS" ]]; then
        matched "debug-injection comment (should be removed before release): $pat" "$HITS"
    fi
done

if [[ $FAIL -ne 0 ]]; then
    echo ""
    echo "=========================================="
    echo " ERROR: Potential credential leak detected in staged files."
    echo "=========================================="
    echo " Action required before commit:"
    echo "   1. 該当行を削除 or Keychain / 環境変数 / Secrets.plist (gitignore) に移動"
    echo "   2. git diff --cached で該当箇所を再確認"
    echo "   3. False positive の場合のみ scripts/check-secrets.sh の regex を調整"
    echo "=========================================="
    exit 1
fi

echo "[check-secrets] OK: no secrets detected in $(echo "$FILES" | wc -l | xargs) files"
exit 0
