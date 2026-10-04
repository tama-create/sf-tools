#!/bin/bash
# ==============================================================================
# sf-upgrade.sh - 開発ツール一括アップデートスクリプト
# ==============================================================================
# sf-install.sh から自動呼び出しされるほか、手動でも実行できます。
#
# 【処理の流れ】
#   1. npm を最新バージョンにアップデート
#   2. Salesforce CLI (sf) をアップデート
#        npm 版（npm ls -g @salesforce/cli が成功）: npm install -g @salesforce/cli@latest
#        それ以外（公式インストーラー・pkg など）  : sf update
#   3. Git をアップデート（Windows のみ。最後に実行 ※アップデート時は GUI インストーラーが起動）
#
# 【オプション】
#   -v, --verbose       : コマンドの応答（出力）をコンソールにも表示します
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 共通ライブラリの必須設定
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME=$(basename "$0" .sh)
readonly LOG_FILE="./sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"


# ------------------------------------------------------------------------------
# 2. 共通ライブラリの読み込み
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="${SCRIPT_DIR}/../lib/common.sh"

if [[ ! -f "$COMMON_LIB" ]]; then
    echo "[FATAL ERROR] Library not found: $COMMON_LIB" >&2
    exit 1
fi

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}"
    exit 0
fi
source "$COMMON_LIB"

# ==============================================================================
# メイン処理
# ==============================================================================
log "HEADER" "開発ツールのアップデートを開始します (${SCRIPT_NAME}.sh)"

# ------------------------------------------------------------------------------
# npm のアップデート
# ------------------------------------------------------------------------------
log "INFO" "npm をアップデートします..."
if command -v npm >/dev/null 2>&1; then
    run npm install -g npm@latest \
        || log "WARNING" "npm のアップデートに失敗しました（続行します）"
else
    log "WARNING" "npm が見つかりません。Node.js のインストールを確認してください。"
fi

# ------------------------------------------------------------------------------
# Salesforce CLI のアップデート
# ------------------------------------------------------------------------------
log "INFO" "Salesforce CLI をアップデートします..."
if command -v sf >/dev/null 2>&1; then
    sf_via_npm=0
    if command -v npm >/dev/null 2>&1; then  # 存在確認のため run 不使用
        if npm ls -g @salesforce/cli --depth=0 >/dev/null 2>&1; then sf_via_npm=1; fi  # 判定のみのため run 不使用
    fi
    if [[ $sf_via_npm -eq 1 ]]; then
        # npm 版（sf-tools が前提とする入れ方）: npm で更新する（sf update は npm 版では使えない）
        run npm install -g @salesforce/cli@latest \
            || log "WARNING" "Salesforce CLI のアップデートに失敗しました（続行します）"
    else
        # npm 版以外（公式インストーラー・pkg など）: sf update で更新する
        run sf update \
            || log "WARNING" "Salesforce CLI のアップデートに失敗しました（続行します）"
    fi
else
    log "WARNING" "sf コマンドが見つかりません。Salesforce CLI のインストールを確認してください。"
fi

# ------------------------------------------------------------------------------
# Git のアップデート（最後に実行 ※アップデート時は GUI インストーラーが起動する）
# ------------------------------------------------------------------------------
log "INFO" "Git をアップデートします..."
if is_gitbash; then
    run git update-git-for-windows --yes \
        || log "WARNING" "Git のアップデートに失敗しました（続行します）"
else
    log "INFO" "Git のアップデートはパッケージマネージャーで行ってください（スキップ）"
fi

log "SUCCESS" "すべてのアップデートが完了しました"
