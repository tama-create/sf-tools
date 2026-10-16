#!/bin/bash
# ==============================================================================
# 02_project_info.sh - Phase 2: プロジェクト情報の確認
# ==============================================================================
# GITHUB_OWNER とプロジェクト名（XXXX）を確認する。値は、sf-init.sh が決めたもの（引数・従来のフォルダ構成・対話）。
# 環境種別（本番/検証）を選択し、.sf-init.env に変数を書き出して後続フェーズと共有する。
#
# 【値の決まり方】
#   カレント: 管理者用の作業フォルダ（従来の構成: …/home/{owner}/{company}/init/ / 新しい形: {作業フォルダ}/init-XXXX/）
#             （sf-init.sh が自動作成・移動）
#   PROJECT_NAME  = XXXX（環境変数 SF_INIT_PROJECT。sf-init.sh が、引数・従来の構成・対話から決める）
#   GITHUB_OWNER  = オーナー（環境変数 SF_INIT_OWNER）
#                   ※ この 2 つがないとき（Phase だけを直接実行したとき）は、従来の構成から取る:
#                     PROJECT_NAME = init の 1 つ上のフォルダ名、GITHUB_OWNER = 2 つ上のフォルダ名
#   REPO_NAME     = force-{PROJECT_NAME}
#   REPO_FULL_NAME= {GITHUB_OWNER}/force-{PROJECT_NAME}
#   REPO_DIR      = {PWD}/force-{PROJECT_NAME}
#
# 【環境種別】
#   配布版 (production)    : SF_TOOLS_BRANCH=main       → GitHub Actions は sf-tools main を使用（通常はこちら）
#   開発版 (staging)       : SF_TOOLS_BRANCH=development → GitHub Actions は sf-tools development を使用
#                           sf-tools の開発者専用（未リリースのコードが使われる）。
#                           誤選択を防ぐため、選択時に WARNING と Y/N/q 確認を行う（N なら選択に戻る）
#
# 【sf-tools の最新化確認】
#   環境種別の選択直後に ensure_sf_tools_branch（init-common.sh）を呼び、~/sf-tools が
#   選択した環境のブランチ（本番=main / 検証=development）かどうか、origin より遅れていないかを確認する。
#   ・遅れていれば確認のうえ git pull --ff-only を実行し、終了コード 75 で終了する（sf-init.sh が、自動で、実行しなおす）する
#   ・ブランチ違いは確認（Y/N/q）。ローカルに未コミット・未 push の変更があれば更新せず警告のみ
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
log "HEADER" "プロジェクト情報の確認"

log "INFO" "プロジェクト情報を確認中..."

# sf-init.sh が決めた値（SF_INIT_OWNER / SF_INIT_PROJECT。引数・従来のフォルダ構成・対話のいずれか）を使う。
#   Phase だけを直接実行したとき（値がないとき）は、従来のフォルダ構成から取る: init の 1つ上 = {company}、2つ上 = {github-owner}
if [[ -n "${SF_INIT_OWNER:-}" && -n "${SF_INIT_PROJECT:-}" ]]; then
    PROJECT_NAME="$SF_INIT_PROJECT"
    GITHUB_OWNER="$SF_INIT_OWNER"
else
    PROJECT_NAME=$(basename "$(dirname "$PWD")")
    GITHUB_OWNER=$(basename "$(dirname "$(dirname "$PWD")")")
fi
REPO_NAME="force-${PROJECT_NAME}"
REPO_FULL_NAME="${GITHUB_OWNER}/${REPO_NAME}"
REPO_DIR="${PWD}/${REPO_NAME}"

# GitHub オーナー名バリデーション（英数字・ハイフンのみ・先頭末尾はハイフン不可）
if [[ -z "$GITHUB_OWNER" ]] || \
   [[ ! "$GITHUB_OWNER" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,37}[a-zA-Z0-9])?$ ]]; then
    die "GitHub オーナー名が無効です: \"${GITHUB_OWNER}\"
  オーナー名は、英数字とハイフンのみ使えます（先頭・末尾は英数字）。
  --owner で指定するか、対話で、入力してください。"
fi

log "INFO" "  GitHub オーナー: ${GITHUB_OWNER}"
log "INFO" "  リポジトリ名: ${REPO_NAME}（force- + ${PROJECT_NAME}）"

# 確認表示
echo ""
echo "  --------------------------------------------------"
echo "  リポジトリ : ${REPO_FULL_NAME}"
echo "  クローン先 : ${REPO_DIR}"
echo "  --------------------------------------------------"
echo ""
ask_yn "▶ よろしいですか？" || die "セットアップを中断しました。"

# 環境種別の選択
echo ""
log "INFO" "sf-tools の版を選択してください（Salesforce の本番・Sandbox とは、関係ありません）："
log "INFO" "  1. 配布版（main）        - 通常は、こちらを選択してください。"
log "INFO" "                             GitHub Actions は、リリース済みの sf-tools（main ブランチ）を使用"
log "INFO" "  2. 開発版（development） - sf-tools の開発者専用です（リリース前の動作確認用）。"
log "INFO" "                             GitHub Actions は、未リリースの sf-tools（development ブランチ）を使用"
echo ""
while true; do
    read_key ENV_TYPE_KEY "▶ sf-tools の版を選択してください [1/2/q]：" "[12qQ]"
    [[ "$ENV_TYPE_KEY" =~ ^[qQ]$ ]] && die "セットアップを中断しました。"
    if [[ "$ENV_TYPE_KEY" == "1" ]]; then
        ENV_TYPE="production"
        SF_TOOLS_BRANCH="main"
        log "INFO" "  → 配布版（sf-tools: main）"
        break
    fi
    # 検証環境は未リリースのコードを使うため、誤選択を防ぐ確認を挟む（N なら選択に戻る）
    log "WARNING" "開発版は、sf-tools の開発者専用です。リリース前の未検証コード（sf-tools development）が使われます。"
    if ask_yn "▶ 開発版（development）で続行しますか？"; then
        ENV_TYPE="staging"
        SF_TOOLS_BRANCH="development"
        log "INFO" "  → 開発版（sf-tools: development）"
        break
    fi
    echo ""
done

# 選択した環境に合わせて ~/sf-tools の最新化を確認する。更新した場合（戻り値 2）は、終了コード 75 で終了する
#   （司令塔の sf-init.sh が、更新した sf-tools で、自動的に、最初から実行しなおす）
#   起動時（sf-init.sh）に、現在のブランチの最新化を、確認済みなら（SF_INIT_TOOLS_CHECKED_BRANCH）、
#   二重に確認せず、選んだ環境とのブランチ違いだけを確認する
if [[ -n "${SF_INIT_TOOLS_CHECKED_BRANCH:-}" ]]; then
    if [[ "$SF_INIT_TOOLS_CHECKED_BRANCH" != "$SF_TOOLS_BRANCH" ]]; then
        log "WARNING" "ローカルの sf-tools は ${SF_INIT_TOOLS_CHECKED_BRANCH} ブランチですが、選択した環境は ${SF_TOOLS_BRANCH} です。"
        ask_yn "▶ このまま続行しますか？" || die "セットアップを中断しました。"
    fi
else
    ensure_sf_tools_branch "$SF_TOOLS_BRANCH"
    [[ $? -eq 2 ]] && exit 75
fi

# .sf-init.env に変数を書き出す（後続フェーズで source して使用）
{
    printf 'GITHUB_OWNER="%s"\n'    "$GITHUB_OWNER"
    printf 'PROJECT_NAME="%s"\n'   "$PROJECT_NAME"
    printf 'REPO_NAME="%s"\n'      "$REPO_NAME"
    printf 'REPO_FULL_NAME="%s"\n' "$REPO_FULL_NAME"
    printf 'REPO_DIR="%s"\n'       "$REPO_DIR"
    printf 'ENV_TYPE="%s"\n'        "$ENV_TYPE"
    printf 'SF_TOOLS_BRANCH="%s"\n' "$SF_TOOLS_BRANCH"
} > "$SF_INIT_ENV_FILE"
chmod 600 "$SF_INIT_ENV_FILE" 2>/dev/null || true  # run 不使用: ファイル権限保護（Windows は効果なし・意図的エラー無視）

log "SUCCESS" "完了: プロジェクト情報の確認 OK。"
exit $RET_OK
