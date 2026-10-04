#!/bin/bash
# ==============================================================================
# 06_pat_token.sh - Phase 6: PAT_TOKEN の設定
# ==============================================================================
# GitHub Personal Access Token を生成して GitHub Secrets に登録する。
# ワークフローがブランチ保護をバイパスして push するために必要。
#
# 【備考】
#   生成した PAT_TOKEN_VALUE は .sf-init.env に書き出し、Phase 8 で使用する。
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
log "HEADER" "Phase 6: PAT_TOKEN の設定"
echo ""
echo "  ワークフローがブランチ保護をバイパスして push するために必要です。"
echo ""
echo "  ブラウザで Personal access tokens (classic) のページを開きます。"
echo "  【手順】"
echo "    1. 「Generate new token」→「Generate new token (classic)」をクリック"
echo "    2. 以下の設定でトークンを作成してください:"
echo ""
echo "       Note       : sf-metasync-${PROJECT_NAME}"
echo "       Expiration : No expiration"
echo "       Scopes     : ✅ repo（全選択）  ✅ workflow"
echo ""
echo "    3. 「Generate token」をクリックしてトークンをコピー"
echo ""
open_browser "https://github.com/settings/tokens"
press_enter "トークンをコピーしたら Enter を押してください..."

PAT_TOKEN_VALUE=""
read_or_quit PAT_TOKEN_VALUE "  生成されたトークンを貼り付けてください（q で中断）："
echo ""

echo "$PAT_TOKEN_VALUE" | run gh secret set PAT_TOKEN -R "$REPO_FULL_NAME" \
    || die "PAT_TOKEN の登録に失敗しました。"

# PAT_TOKEN_VALUE を .sf-init.env に書き出す（Phase 8 の push で使用）
printf 'PAT_TOKEN_VALUE="%s"\n' "$PAT_TOKEN_VALUE" >> "$SF_INIT_ENV_FILE"

log "SUCCESS" "Phase 6 完了: PAT_TOKEN の設定 OK。"
exit $RET_OK
