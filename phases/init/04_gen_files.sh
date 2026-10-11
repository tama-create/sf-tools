#!/bin/bash
# ==============================================================================
# 04_gen_files.sh - Phase 4: ファイル生成
# ==============================================================================
# sf-install.sh を実行してワークフロー・設定ファイル・フックを生成する。
# SF_INIT_RUNNING=1 を export して sf-install.sh に初期化モードを通知する。
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

[[ -z "$REPO_DIR" ]] && die "REPO_DIR が未設定です。Phase 2 が完了しているか確認してください。"

# ------------------------------------------------------------------------------
# メイン処理
# ------------------------------------------------------------------------------
log "HEADER" "ファイル生成"

log "INFO" "sf-tools の初期設定ファイルを生成中..."

# sf-install.sh に初期化モードを通知する（フック・ブランチ設定のスキップ制御に使用）
export SF_INIT_RUNNING=1

cd "$REPO_DIR" || die "ディレクトリに移動できません: $REPO_DIR"

run bash "${SF_TOOLS_DIR}/bin/sf-install.sh" \
    || die "sf-install.sh の実行に失敗しました。"

log "SUCCESS" "完了: 設定ファイルの生成 OK。"
exit $RET_OK
