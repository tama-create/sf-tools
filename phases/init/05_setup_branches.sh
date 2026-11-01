#!/bin/bash
# ==============================================================================
# 05_setup_branches.sh - Phase 5: ブランチ構成
# ==============================================================================
# ブランチ構成を対話で選び、クローンの sf-tools/config/branches.txt を書き直す。
# リモートのブランチは、この Phase では作らない（Phase 8 の 08_initial_commit.sh が作る）。
#
# 【使い方】
#   sf-init.sh が、管理者用の作業フォルダ（admin）をカレントにして、bash で呼び出す。
#
# 【処理の流れ】
#   1. 状態ファイルの REPO_DIR が空なら die。REPO_DIR に移動する
#   2. ブランチ構成を選ぶ（1 / 2 / 3 / q。q は die）
#        [1] main / staging / develop  : 標準構成。3 段階のリリース
#        [2] main / staging            : 2 段階のリリース（開発組織を使わない場合）
#        [3] main                      : 小規模・単独開発向け
#   3. branches.txt を書き直す: 既存のファイルの # で始まる行（コメント。先頭の空白は可）だけを残し、空行 1 行のあとに、
#      選んだブランチを 1 行ずつ書く（一時ファイルに書いてから mv。以前のブランチの行・空行は消える。
#      sf-tools/config の mkdir・一時ファイルの書き込み・mv の失敗は die。die したときは、一時ファイルを消す（trap）。
#      branches.txt は、書き直す前のまま）
#   4. BRANCH_COUNT（選んだブランチの数: 1〜3）を状態ファイルに追記する（追記の失敗は die）
#
# 【前提条件】
#   - Phase 3 で作ったクローン（REPO_DIR）
#   - 環境変数 SF_TOOLS_DIR（sf-tools のルート。sf-init.sh が export する）
#
# 【補足】
#   - 終了コード: 0 = OK / 1 = die
# ==============================================================================

# SF_TOOLS_DIR は sf-init.sh（司令塔）から export される
PHASE_DIR="${BASH_SOURCE[0]%/*}"
[[ "$PHASE_DIR/" == /* && "$PHASE_DIR/" != *//* && "$PHASE_DIR/" != */./* && "$PHASE_DIR/" != */../* ]] || PHASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_TOOLS_DIR="${SF_TOOLS_DIR:-$(dirname "$(dirname "$PHASE_DIR")")}"

readonly SCRIPT_NAME="sf-init"
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true  # run 不使用: common.sh の読み込み前（run が未定義）
readonly LOG_FILE="$HOME/sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="APPEND"  # 司令塔が NEW で初期化済みのため追記
export SF_INIT_MODE=1

source "${SF_TOOLS_DIR}/lib/common.sh"
source "${SF_TOOLS_DIR}/phases/init/init-common.sh"

# 変数の復元（前フェーズで書き出した .sf-init.env を読み込む）
SF_INIT_ENV_FILE="${SF_INIT_ENV_FILE:-${PWD}/.sf-init.env}"
[[ -f "$SF_INIT_ENV_FILE" ]] && source "$SF_INIT_ENV_FILE"

[[ -z "$REPO_DIR" ]] && die "REPO_DIR が未設定です。Phase 2 が完了しているか確認してください。"

# 一時ファイルのクリーンアップ（die / 異常終了時に .tmp が残留しないよう保護）
TMP_BRANCH_FILE=""
trap '[[ -n "$TMP_BRANCH_FILE" ]] && rm -f "$TMP_BRANCH_FILE"' EXIT

# ------------------------------------------------------------------------------
# メイン処理
# ------------------------------------------------------------------------------
log "HEADER" "ブランチ構成"

cd "$REPO_DIR" || die "ディレクトリに移動できません: $REPO_DIR"

# ブランチ構成の選択
echo "" >&2
echo -e "  ${CLR_INFO}ブランチ構成を選択してください:${CLR_RESET}" >&2
echo -e "  ${CLR_INFO}──────────────────────────────────────────────────────${CLR_RESET}" >&2
echo -e "  ${CLR_INFO}[1]${CLR_RESET} main / staging / develop" >&2
echo "      標準構成。develop → staging → main の3段階" >&2
echo "" >&2
echo -e "  ${CLR_INFO}[2]${CLR_RESET} main / staging" >&2
echo "      develop を使わない場合。staging → main の2段階" >&2
echo "" >&2
echo -e "  ${CLR_INFO}[3]${CLR_RESET} main" >&2
echo "      小規模プロジェクト・単独開発向け" >&2
echo -e "  ${CLR_INFO}[q]${CLR_RESET} 中断" >&2
echo -e "  ${CLR_INFO}──────────────────────────────────────────────────────${CLR_RESET}" >&2
echo "" >&2

read_key choice "  番号を入力 [1-3/q]: " "[1-3Qq]"
# shellcheck disable=SC2154  # choice は、read_key（lib/input.sh）が、名前で受け取って代入する
case "$choice" in
    1) BRANCHES=("main" "staging" "develop") ;;
    2) BRANCHES=("main" "staging") ;;
    3) BRANCHES=("main") ;;
    [Qq]) die "中断しました。" ;;
esac

# branches.txt を更新（既存の # の行（コメント）だけを保持し、ほかの行は、選んだブランチの行に置き換える）
run mkdir -p "sf-tools/config" || die "sf-tools/config を作成できません: ${REPO_DIR}/sf-tools/config"

TMP_BRANCH_FILE="${BRANCH_LIST_FILE}.tmp"
# run 不使用: 一時ファイルへの書き出し（リダイレクト。失敗は die）
{
    if [[ -f "$BRANCH_LIST_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            [[ "$line" =~ ^[[:space:]]*# ]] && echo "$line"
        done < "$BRANCH_LIST_FILE"
    fi
    echo ""
    for b in "${BRANCHES[@]}"; do
        echo "$b"
    done
} > "$TMP_BRANCH_FILE" || die "branches.txt の一時ファイルに書き込めません: ${TMP_BRANCH_FILE}"
run mv "$TMP_BRANCH_FILE" "$BRANCH_LIST_FILE" || die "branches.txt の更新に失敗しました: ${BRANCH_LIST_FILE}"
TMP_BRANCH_FILE=""  # mv 成功後はクリア（trap での削除対象から外す）

log "SUCCESS" "branches.txt を更新しました: ${BRANCHES[*]}"

# BRANCH_COUNT を .sf-init.env に追記（再実行のたびに追記する。source すると、最後の行の値になる）
BRANCH_COUNT="${#BRANCHES[@]}"
# run 不使用: 状態ファイルへの追記（リダイレクト。失敗は die）
printf 'BRANCH_COUNT="%s"\n' "$BRANCH_COUNT" >> "$SF_INIT_ENV_FILE" \
    || die "状態ファイルに書き込めません: ${SF_INIT_ENV_FILE}"

log "SUCCESS" "完了: ブランチ構成 OK（${BRANCH_COUNT} 階層）。"
exit $RET_OK
