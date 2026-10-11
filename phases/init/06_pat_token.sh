#!/bin/bash
# ==============================================================================
# 06_pat_token.sh - Phase 6: PAT_TOKEN の設定
# ==============================================================================
# GitHub Personal Access Token（Classic）を GitHub Secrets に登録する。
# ワークフローがブランチ保護をバイパスして push するために必要。
#
# 【処理の流れ】
#   1. この Token を作るべきアカウント（リポジトリのオーナー・組織の管理者）を表示する
#   2. 手順（やることは 3 つ）を表示し、ブラウザで Token の作成ページを、すぐに開く
#        Note（sf-metasync-<プロジェクト名>）・Scopes（repo, workflow）・Expiration（No expiration）は、URL で入力済み。
#        「発行済みの Token があるか」は、聞かない（Token の値は、作成直後の 1 回しか表示されず、利用者は覚えていないため）。
#        保存してある Token があれば、それを貼り付けてもよい
#   3. Token を貼り付ける（画面には表示されない。表示されない旨を、先に伝える。空 Enter は無視）
#   4. Token を GitHub に問い合わせて検証する（最大 3 回まで貼り直し。失敗の理由と、直し方を、表示する）
#        - Token が有効であること
#        - スコープに repo・workflow があること（Classic の PAT。Fine-grained は、スコープを確認できないため不可）
#        - force-* のリポジトリの管理者（オーナー・組織の管理者）の Token であること
#   5. GitHub Secrets（PAT_TOKEN）に登録する
#
# 【備考】
#   生成した PAT_TOKEN_VALUE は .sf-init.env に書き出し、Phase 8 で使用する（push 後に削除される）。
#   Token は、コマンドの引数に含めない（環境変数 GH_TOKEN で gh に渡す。ログ・プロセス一覧に残さないため）。
#   PAT_TOKEN は、force-*（プロジェクト側）のリポジトリのための Token であり、sf-tools（公開リポジトリ）とは関係ない。
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

REPO_OWNER="${REPO_FULL_NAME%%/*}"
# classic の PAT の作成ページは、description / scopes / default_expires_at を、URL のパラメータで指定できる
PAT_NEW_URL="https://github.com/settings/tokens/new?description=sf-metasync-${PROJECT_NAME}&scopes=repo,workflow&default_expires_at=none"

# ------------------------------------------------------------------------------
# Token の検証
#   引数: Token
#   戻り値: 0=使える Token / 1=使えない Token（理由と、直し方を、WARNING で表示する）
#   Token は、環境変数 GH_TOKEN で gh に渡す（コマンドの引数に出さない）。
#   gh の直接実行は、値の取得（VAR=$(cmd)）のため。run を使うと、応答が画面に流れるため、使わない
# ------------------------------------------------------------------------------
verify_pat_token() {
    local tok="$1" login scopes admin
    login=$(GH_TOKEN="$tok" gh api user --jq '.login' 2>/dev/null) || login=""  # VAR=$(cmd) のため run 不使用
    login="${login%$'\r'}"
    if [[ -z "$login" ]]; then
        log "WARNING" "Token を確認できませんでした。コピーした Token が、途中で切れていないか、確認してください（有効期限切れ・通信の失敗の可能性もあります）。"
        return 1
    fi

    # スコープ（Classic の PAT だけが、X-OAuth-Scopes ヘッダーを返す）
    scopes=$(GH_TOKEN="$tok" gh api user --include 2>/dev/null \
        | tr -d '\r' | grep -i '^x-oauth-scopes:' | head -n 1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d ' ') || scopes=""  # VAR=$(cmd) のため run 不使用
    if [[ -z "$scopes" ]]; then
        log "WARNING" "この Token は、種類が違います（Classic の Token が必要です）。作成ページから、作り直してください: ${PAT_NEW_URL}"
        return 1
    fi
    case ",${scopes}," in *,repo,*) ;; *)
        log "WARNING" "この Token には、「repo」の権限がありません。作成ページで、repo にチェックが入っていることを確認して、作り直してください: ${PAT_NEW_URL}"
        return 1 ;;
    esac
    case ",${scopes}," in *,workflow,*) ;; *)
        log "WARNING" "この Token には、「workflow」の権限がありません。作成ページで、workflow にチェックが入っていることを確認して、作り直してください: ${PAT_NEW_URL}"
        return 1 ;;
    esac

    # リポジトリの管理者か（個人のリポジトリならオーナー、組織のリポジトリなら組織の管理者）
    admin=$(GH_TOKEN="$tok" gh api "repos/${REPO_FULL_NAME}" --jq '.permissions.admin' 2>/dev/null) || admin=""  # VAR=$(cmd) のため run 不使用
    admin="${admin%$'\r'}"
    if [[ "$admin" != "true" ]]; then
        log "WARNING" "この Token は ${login} さんのものですが、${REPO_FULL_NAME} の管理者ではありません。${REPO_OWNER}（組織の場合は、その組織の管理者）のアカウントで、作り直してください: ${PAT_NEW_URL}"
        return 1
    fi

    log "SUCCESS" "Token を確認できました（${login} さんの Token / 権限: ${scopes}）。"
    return 0
}

# ------------------------------------------------------------------------------
# メイン処理
# ------------------------------------------------------------------------------
log "HEADER" "PAT_TOKEN の設定"
echo ""
echo "  GitHub の Token（アクセス用の合言葉）を作って、登録します。"
echo "  自動で動くワークフローが、このリポジトリを更新するために必要です。"
echo "  （sf-tools が公開リポジトリであることとは、関係ありません）"
echo ""
echo -e "  ${CLR_WARNING}【作るアカウント】 ${REPO_OWNER}${CLR_RESET}"
echo "      ・組織のリポジトリの場合は、その組織の管理者のアカウントです"
echo "      ・ブラウザが別のアカウントでログインしている場合は、先に、切り替えてください"
echo ""
echo "  いま、ブラウザで Token の作成ページを開きます。やることは 3 つです。"
echo "    1. ページの一番下の「Generate token」ボタンを押す"
echo "         （入力済みの内容は、そのままで構いません）"
echo "           Note: sf-metasync-${PROJECT_NAME} / Expiration: No expiration / Scopes: repo, workflow"
echo "    2. 表示された Token（ghp_ で始まる文字列）を、コピーする"
echo "         ※ Token は、この 1 回しか表示されません"
echo "    3. このターミナルに戻って、貼り付けて、Enter を押す"
echo "         ※ 貼り付けると、文字の数だけ * が並びます（Token の中身は、画面に出ません）。そのまま Enter を押してください"
echo "         ※ Git Bash は、右クリックで貼り付けます（Shift+Insert でも貼り付けられます）"
echo ""
echo "  ブラウザが開かない場合は、次の URL を開いてください:"
echo "    ${PAT_NEW_URL}"
echo ""
echo "  （以前に作って、保存してある Token があれば、それを貼り付けても構いません）"
echo ""
open_browser "$PAT_NEW_URL"

# Token の貼り付けと検証（使えない Token は、3 回まで貼り直せる）
PAT_TOKEN_VALUE=""
attempt=0
while true; do
    read_secret PAT_TOKEN_VALUE "  ▶ ここに Token を貼り付けて、Enter を押してください（* で表示されます・q で中断）："
    attempt=$((attempt + 1))
    log "INFO" "Token を受け取りました。GitHub に問い合わせて、確認しています..."
    if verify_pat_token "$PAT_TOKEN_VALUE"; then
        break
    fi
    [[ $attempt -ge 3 ]] && die "PAT_TOKEN の検証に ${attempt} 回失敗しました。"
    log "WARNING" "もう一度、貼り付けてください（あと $((3 - attempt)) 回）。Token を作り直した場合は、新しい Token を貼り付けてください。"
done
echo ""

echo "$PAT_TOKEN_VALUE" | run gh secret set PAT_TOKEN -R "$REPO_FULL_NAME" \
    || die "PAT_TOKEN の登録に失敗しました。"

# PAT_TOKEN_VALUE を .sf-init.env に書き出す（Phase 8 の push で使用）
printf 'PAT_TOKEN_VALUE="%s"\n' "$PAT_TOKEN_VALUE" >> "$SF_INIT_ENV_FILE"

log "SUCCESS" "完了: PAT_TOKEN の設定 OK。"
exit $RET_OK
