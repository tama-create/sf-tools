#!/bin/bash
# ==============================================================================
# 02_project_info.sh - Phase 2: プロジェクト情報の確認
# ==============================================================================
# sf-init.sh が決めたオーナーとプロジェクト名（XXXX）から、リポジトリ名・クローン先を決めて確認し、
# sf-tools の版（配布版 = main / 開発版 = development）を選ばせる。結果を状態ファイル（SF_INIT_ENV_FILE）に書き出す。
#
# 【使い方】
#   sf-init.sh が、管理者用の作業フォルダ（admin）をカレントにして、bash で呼び出す。
#
# 【処理の流れ】
#   1. PROJECT_NAME = SF_INIT_PROJECT（空なら die）、GITHUB_OWNER = SF_INIT_OWNER
#      （空、または「英数字とハイフンのみ・先頭と末尾は英数字・1〜39 文字」でなければ die）
#   2. 次の値を決める
#        REPO_NAME      = force-{PROJECT_NAME}
#        REPO_FULL_NAME = {GITHUB_OWNER}/force-{PROJECT_NAME}
#        REPO_DIR       = {PWD}/force-{PROJECT_NAME}
#   3. リポジトリ（REPO_FULL_NAME）とクローン先（REPO_DIR）を表示し、ask_yn で確認する（N / q は die）
#   4. sf-tools の版を選ぶ（1 / 2 / q。q は die）
#        1 = 配布版: ENV_TYPE=production・SF_TOOLS_BRANCH=main
#        2 = 開発版: WARNING を表示して ask_yn。Y なら ENV_TYPE=staging・SF_TOOLS_BRANCH=development、
#            N なら選択に戻る、q は die
#   5. ~/sf-tools（SF_TOOLS_DIR）のブランチと最新化を確認する
#        - SF_INIT_TOOLS_CHECKED_BRANCH が空でない（sf-init.sh が起動時に最新化を確認済み）: そのブランチが
#          SF_TOOLS_BRANCH と違うときだけ、WARNING と ask_yn（N / q は die）。最新化の確認は、ここでは行わない
#        - 空: ensure_sf_tools_branch（init-common.sh）を呼ぶ。sf-tools を更新した（戻り値 2）ときは、
#          状態ファイルを書かずに、終了コード 75 で終了する（sf-init.sh が、更新した sf-tools で、はじめから実行しなおす）
#   6. 状態ファイルを上書きで作り、次の 7 つを書き出す（chmod 600。Windows では効果なし）
#        GITHUB_OWNER / PROJECT_NAME / REPO_NAME / REPO_FULL_NAME / REPO_DIR / ENV_TYPE / SF_TOOLS_BRANCH
#
# 【前提条件】
#   - 環境変数 SF_TOOLS_DIR（sf-tools のルート）・SF_INIT_OWNER・SF_INIT_PROJECT（sf-init.sh が export する）
#
# 【補足】
#   - 状態ファイルは SF_INIT_ENV_FILE（sf-init.sh からは admin/.sf-init-XXXX.env。未設定時は ${PWD}/.sf-init.env）
#   - 版は、GitHub Actions が使う sf-tools のブランチを決める（Salesforce の本番・Sandbox とは関係ない）。
#     開発版は sf-tools の開発者専用（未リリースのコードが使われる）
#   - 終了コード: 0 = OK / 75 = sf-tools を更新した / 1 = die
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

# 変数の復元（前フェーズで書き出した .sf-init-XXXX.env を読み込む）
SF_INIT_ENV_FILE="${SF_INIT_ENV_FILE:-${PWD}/.sf-init.env}"
[[ -f "$SF_INIT_ENV_FILE" ]] && source "$SF_INIT_ENV_FILE"

# ------------------------------------------------------------------------------
# メイン処理
# ------------------------------------------------------------------------------
log "HEADER" "プロジェクト情報の確認"

log "INFO" "プロジェクト情報を確認中..."

# sf-init.sh が決めた値（SF_INIT_OWNER / SF_INIT_PROJECT。引数・対話のいずれか）を使う
PROJECT_NAME="${SF_INIT_PROJECT:-}"
GITHUB_OWNER="${SF_INIT_OWNER:-}"
[[ -n "$PROJECT_NAME" ]] || die "プロジェクト名（SF_INIT_PROJECT）が設定されていません。sf-init.sh から実行してください。"
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
