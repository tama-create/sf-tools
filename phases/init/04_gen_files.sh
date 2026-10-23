#!/bin/bash
# ==============================================================================
# 04_gen_files.sh - Phase 4: ファイル生成
# ==============================================================================
# クローン（REPO_DIR）で sf-install.sh を初期化モード（SF_INIT_RUNNING=1）で実行し、sf-tools の設定ファイル・
# Git フック・リリース管理フォルダ・コミットメッセージのテンプレートを用意する。
#
# 【使い方】
#   sf-init.sh が、管理者用の作業フォルダ（admin）をカレントにして、bash で呼び出す。
#
# 【処理の流れ】
#   1. 状態ファイルの REPO_DIR が空なら die
#   2. SF_INIT_RUNNING=1 を export し、REPO_DIR に移動して、bash sf-install.sh を実行する（失敗は die）
#
# 【前提条件】
#   - Phase 3 で作ったクローン（REPO_DIR）
#   - 環境変数 SF_TOOLS_DIR（sf-tools のルート。sf-init.sh が export する）
#
# 【補足】
#   - SF_INIT_RUNNING=1 のとき、sf-install.sh は、通常の起動と次の点が違う
#       - ~/sf-tools の git pull をしない
#       - sf-tools/config/ の metadata.txt・branches.txt を、ないときだけテンプレートからコピーする（通常は、ないと die）
#       - .gitmessage を置き、commit.template に設定する
#       - npm install をしない
#   - pre-commit / pre-push フックのインストール（sf-hook.sh）と、sf-tools/release/ の準備は、通常どおり行う
#   - ワークフロー（.github/workflows/）は、この Phase ではなく、Phase 3 がテンプレートからコピーする
# ==============================================================================

# SF_TOOLS_DIR は sf-init.sh（司令塔）から export される
PHASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_TOOLS_DIR="${SF_TOOLS_DIR:-$(dirname "$(dirname "$PHASE_DIR")")}"

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

# sf-install.sh に初期化モードを通知する（git pull・npm install の省略、設定ファイルの生成、.gitmessage の設置に使用）
export SF_INIT_RUNNING=1

cd "$REPO_DIR" || die "ディレクトリに移動できません: $REPO_DIR"

run bash "${SF_TOOLS_DIR}/bin/sf-install.sh" \
    || die "sf-install.sh の実行に失敗しました。"

log "SUCCESS" "完了: 設定ファイルの生成 OK。"
exit $RET_OK
