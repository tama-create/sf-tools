#!/bin/bash
# ==============================================================================
# 01_check_env.sh - Phase 1: 環境チェック
# ==============================================================================
# 実行場所（管理者用の作業フォルダ admin）・必要なコマンド・GitHub CLI の認証を確認する。
#
# 【使い方】
#   sf-init.sh が、管理者用の作業フォルダ（admin）をカレントにして、bash で呼び出す。
#
# 【処理の流れ】
#   1. カレントのフォルダ名が admin でなければ die
#   2. git / gh / node / npm / sf / code の有無を確認し、それぞれ --version の 1 行目を表示する。1 つでもなければ die
#   3. gh auth status が失敗したら、gh auth login を実行する（ログインに失敗したら die）
#
# 【前提条件】
#   - 環境変数 SF_TOOLS_DIR（sf-tools のルート。sf-init.sh が export する）。未設定のときは、このスクリプトの
#     2 つ上のフォルダ（sf-tools のルート）を使う（以前は 1 つ上の phases/ を指し、lib/common.sh を読み込めなかった）
#
# 【補足】
#   - SF_INIT_ENV_FILE（未設定時は ${PWD}/.sf-init.env）があれば source する（この Phase では、その値を使わない）
#   - 状態ファイルに何も書かない。sf-init.sh は、続きから再開するときも、この Phase を毎回実行する
#   - 終了コード: 0 = OK / 1 = die
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

# 変数の復元（前フェーズで書き出した .sf-init-XXXX.env を読み込む）
SF_INIT_ENV_FILE="${SF_INIT_ENV_FILE:-${PWD}/.sf-init.env}"
[[ -f "$SF_INIT_ENV_FILE" ]] && source "$SF_INIT_ENV_FILE"

# ------------------------------------------------------------------------------
# メイン処理
# ------------------------------------------------------------------------------
log "HEADER" "環境チェック"

# 管理者用の作業フォルダ（admin）からのみ実行を許可
local_dir=$(basename "$PWD")
if [[ "$local_dir" != "admin" ]]; then
    die "このスクリプトは、管理者用の作業フォルダ（admin）から実行してください。
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
