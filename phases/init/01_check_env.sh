#!/bin/bash
# ==============================================================================
# 01_check_env.sh - Phase 1: 環境チェック
# ==============================================================================
# 必要なツールの存在確認と GitHub CLI 認証状態を検証する。
# init フォルダからの実行であることも確認する。
# ==============================================================================

# SF_TOOLS_DIR は sf-init.sh（司令塔）から export される
PHASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_TOOLS_DIR="${SF_TOOLS_DIR:-$(dirname "$PHASE_DIR")}"

readonly SCRIPT_NAME="sf-init"
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true
readonly LOG_FILE="$HOME/sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="APPEND"  # 司令塔が NEW で初期化済みのため追記
export SF_INIT_MODE=1

source "${SF_TOOLS_DIR}/lib/common.sh"
source "${SF_TOOLS_DIR}/phases/init/init-common.sh"

# 変数の復元（前フェーズで書き出した .sf-init.env を読み込む）
SF_INIT_ENV_FILE="${SF_INIT_ENV_FILE:-${PWD}/.sf-init.env}"
[[ -f "$SF_INIT_ENV_FILE" ]] && source "$SF_INIT_ENV_FILE"

# ------------------------------------------------------------------------------
# メイン処理
# ------------------------------------------------------------------------------
log "HEADER" "環境チェック"

# 管理者用の作業フォルダ（従来の構成: init / 新しい形: init-XXXX）からのみ実行を許可
local_dir=$(basename "$PWD")
if [[ "$local_dir" != "init" && "$local_dir" != init-* ]]; then
    die "このスクリプトは、管理者用の作業フォルダ（init-XXXX。従来の構成では init）から実行してください。
実行方法（通常は、sf-init.sh が、このフォルダを作って移動します）:
  ~/sf-tools/bin/sf-init.sh [--owner OWNER] [--project XXXX]"
fi

log "INFO" "必要なツールを確認中..."

missing=0
for cmd in git gh node npm sf code; do
    if command -v "$cmd" &>/dev/null; then
        ver=$("$cmd" --version 2>&1 | head -1)
        log "INFO" "  ✅ $cmd: $ver"
    else
        log "ERROR" "  ❌ $cmd が見つかりません"
        missing=1
    fi
done

[[ $missing -eq 1 ]] && die "必要なツールが不足しています。インストール後に再実行してください。"

log "INFO" "GitHub CLI の認証状態を確認中..."
if ! run gh auth status; then
    log "WARNING" "GitHub CLI が未認証です。ログインします..."
    run gh auth login || die "GitHub 認証に失敗しました。"
fi

log "SUCCESS" "完了: 環境チェック OK。"
exit $RET_OK
