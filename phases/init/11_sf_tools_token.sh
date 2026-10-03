#!/bin/bash
# ==============================================================================
# 11_sf_tools_token.sh - Phase 11: SF_TOOLS_TOKEN の設定
# ==============================================================================
# GitHub Actions（wf-metasync / wf-validate / wf-release）は、実行のたびに Private の
# sf-tools リポジトリを clone する。その読み取り専用 Token（Fine-grained PAT）を
# SF_TOOLS_TOKEN として GitHub Secrets に登録する。
#
#   11-1. Fine-grained PAT の作成画面を事前入力した URL で開く（開けない場合に備え URL も表示する）
#   11-2. Token を入力（画面に表示しない）
#   11-3. Token で sf-tools を読めるか確認する（環境変数で渡し、コマンドの文字列に Token を含めない）
#   11-4. SF_TOOLS_TOKEN を Secret として登録する（標準入力で渡す）
#
# 【備考】
#   ・Token は sf-tools の所有者のアカウントで作成する（force-* の管理アカウントとは別の場合がある）
#   ・読み取りの確認に失敗した場合は、再入力かスキップを選べる。スキップすると登録されず、
#     Actions が「自動化ツール（sf-tools）を取得」で失敗する（doc/setup-guide.md 3.2 で手動登録できる）
#   ・Token は変数に保持するだけで、.sf-init.env などのファイルには書き出さない
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

# ------------------------------------------------------------------------------
# メイン処理
# ------------------------------------------------------------------------------
log "HEADER" "Phase 11: SF_TOOLS_TOKEN の設定"

SF_TOOLS_OWNER="${SF_TOOLS_REPO_FULL_NAME%%/*}"
SF_TOOLS_REPO_NAME="${SF_TOOLS_REPO_FULL_NAME#*/}"

# Fine-grained PAT の作成画面（name / description / target_name / expires_in / contents は URL で事前入力できる）
TOKEN_URL="https://github.com/settings/personal-access-tokens/new?name=sf-tools-clone&description=Clone+the+private+sf-tools+repository+from+GitHub+Actions&target_name=${SF_TOOLS_OWNER}&expires_in=none&contents=read"

echo ""
echo "  GitHub Actions が Private の sf-tools（${SF_TOOLS_REPO_FULL_NAME}）を取得するために必要です。"
echo ""
echo "  ブラウザで Fine-grained personal access token の作成画面を開きます。"
echo "  ※ ${SF_TOOLS_OWNER} アカウント（sf-tools の所有者）でログインして操作してください。"
echo "  【手順】"
echo "    1. Repository access: 「Only select repositories」→ ${SF_TOOLS_REPO_NAME} だけを選択"
echo "    2. Permissions: Contents が Read-only になっていることを確認（事前入力済み）"
echo "    3. 「Generate token」をクリックして Token をコピー"
echo ""
echo "  ブラウザが開かない場合は、次の URL を開いてください:"
echo "    ${TOKEN_URL}"
echo ""
open_browser "$TOKEN_URL"
press_enter "Token をコピーしたら Enter を押してください..."

while true; do
    TOOLS_TOKEN_VALUE=""
    read_secret TOOLS_TOKEN_VALUE "  Token を貼り付けてください（画面には表示されません・q で中断）："

    # Token で sf-tools を読めるか確認する（Token は環境変数で渡し、コマンドの文字列やログに含めない）
    if GH_TOKEN="$TOOLS_TOKEN_VALUE" gh api "repos/${SF_TOOLS_REPO_FULL_NAME}" --jq '.full_name' >/dev/null 2>&1; then  # if cmd のため run 不使用
        log "SUCCESS" "Token で ${SF_TOOLS_REPO_FULL_NAME} を読み取れることを確認しました。"
        break
    fi
    log "WARNING" "Token で ${SF_TOOLS_REPO_FULL_NAME} を読み取れませんでした（Token の所有者・対象リポジトリ・権限を確認してください）。"
    if ask_yn "▶ 入力し直しますか？（N の場合は登録をスキップします）"; then
        continue
    fi
    TOOLS_TOKEN_VALUE=""
    log "WARNING" "SF_TOOLS_TOKEN の登録をスキップしました。登録しないと GitHub Actions が sf-tools を取得できず失敗します（手動登録: doc/setup-guide.md 3.2）。"
    log "SUCCESS" "Phase 11 完了（SF_TOOLS_TOKEN は未登録）。"
    exit $RET_OK
done

printf '%s' "$TOOLS_TOKEN_VALUE" | run gh secret set SF_TOOLS_TOKEN -R "$REPO_FULL_NAME" \
    || die "SF_TOOLS_TOKEN の登録に失敗しました。"
TOOLS_TOKEN_VALUE=""

log "SUCCESS" "Phase 11 完了: SF_TOOLS_TOKEN の設定 OK。"
exit $RET_OK
