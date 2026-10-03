#!/bin/bash
# ==============================================================================
# 07_slack.sh - Phase 7: Slack 連携の設定
# ==============================================================================
# Slack App を作成して Bot Token と チャンネル ID を GitHub に登録する。
#
#   7-1. Slack App 作成・Bot Token 取得・SLACK_BOT_TOKEN 登録（Secret）
#   7-2. SLACK_CHANNEL_ID 登録（Variable）
#   7-3. Bot をチャンネルに招待
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

[[ -z "$REPO_FULL_NAME" ]] && die "REPO_FULL_NAME が未設定です。Phase 2 が完了しているか確認してください。"
[[ -z "$PROJECT_NAME" ]]   && die "PROJECT_NAME が未設定です。Phase 2 が完了しているか確認してください。"

# ------------------------------------------------------------------------------
# メイン処理
# ------------------------------------------------------------------------------
log "HEADER" "Phase 7: Slack 連携の設定"

# 8-1. Bot Token 取得
echo ""
echo "  ブラウザで Slack API ページを開きます。"
echo "  以下の手順で Bot Token を取得してください:"
echo ""
echo "    1. 「Create New App」→「From scratch」をクリック"
echo "    2. 以下を設定して「Create App」をクリック:"
echo "       App Name  : sf-notify-${PROJECT_NAME}"
echo "       Workspace : 通知先のワークスペースを選択"
echo "    3. 左メニュー「OAuth & Permissions」をクリック"
echo "    4. 「ボットトークンのスコープ」→「OAuth スコープを追加する」をクリック"
echo "       chat:write と入力して追加"
echo "    5. 左メニュー「Install App」→「Install to <ワークスペース名>」をクリック"
echo "    6. 「許可する」をクリック"
echo "       → 「Installed App Settings」ページが表示される"
echo "    7. ページ内「Bot User OAuth Token」（xoxb-...）をコピー"
echo ""
open_browser "https://api.slack.com/apps"
press_enter "Bot Token を取得したら Enter を押してください..."

slack_token=""
read_or_quit slack_token "  Bot User OAuth Token を貼り付けてください（q で中断）："
echo ""

echo "$slack_token" | run gh secret set SLACK_BOT_TOKEN -R "$REPO_FULL_NAME" \
    || die "SLACK_BOT_TOKEN の登録に失敗しました。"
log "SUCCESS" "SLACK_BOT_TOKEN を登録しました。"

# 8-2. チャンネル ID 登録
echo ""
echo "  通知先 Slack チャンネルの ID を入力します。"
echo "  確認方法: チャンネルを開く → チャンネル名をクリック → 最下部に「チャンネル ID」"
echo "            C から始まる文字列（例: C01ABCDEFGH）"
echo ""

channel_id=""
read_or_quit channel_id "  チャンネル ID（q で中断）："

echo "$channel_id" | run gh variable set SLACK_CHANNEL_ID -R "$REPO_FULL_NAME" \
    || die "SLACK_CHANNEL_ID の登録に失敗しました。"
log "SUCCESS" "SLACK_CHANNEL_ID を登録しました。"

# 8-3. Bot 招待案内
echo ""
log "WARNING" "【重要】Slack チャンネルへの Bot 招待が必要です"
echo "  通知先チャンネルで以下のコマンドを実行してください:"
echo ""
echo "    /invite @sf-notify-${PROJECT_NAME}"
echo ""
echo "  Bot がチャンネルに参加していないと通知が届きません。"
echo ""
press_enter "Bot の招待が完了したら Enter を押してください..."

log "SUCCESS" "Phase 7 完了: Slack 連携の設定 OK。"
exit $RET_OK
