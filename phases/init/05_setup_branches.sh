#!/bin/bash
# ==============================================================================
# 05_setup_branches.sh - Phase 5: ブランチ構成
# ==============================================================================
# ブランチ構成パターンを対話式で選択し、branches.txt を更新する。
# リモートブランチの作成は Phase 8 (08_initial_commit.sh) で実施する。
#
# 【選択肢】
#   [1] main / staging / develop  : 標準構成。3段階リリース
#   [2] main / staging            : 2段階リリース
#   [3] main                      : 小規模・単独開発向け
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
echo "      標準構成。開発→検証→本番の3段階リリース" >&2
echo "" >&2
echo -e "  ${CLR_INFO}[2]${CLR_RESET} main / staging" >&2
echo "      開発組織を使わない場合。検証→本番の2段階" >&2
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

# branches.txt を更新（既存のコメントヘッダーを保持し、ブランチ行だけ差し替える）
run mkdir -p "sf-tools/config"

TMP_BRANCH_FILE="${BRANCH_LIST_FILE}.tmp"
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
} > "$TMP_BRANCH_FILE"
run mv "$TMP_BRANCH_FILE" "$BRANCH_LIST_FILE"
TMP_BRANCH_FILE=""  # mv 成功後はクリア（trap での削除対象から外す）

log "SUCCESS" "branches.txt を更新しました: ${BRANCHES[*]}"

# BRANCH_COUNT を .sf-init.env に追記
BRANCH_COUNT="${#BRANCHES[@]}"
printf 'BRANCH_COUNT="%s"\n' "$BRANCH_COUNT" >> "$SF_INIT_ENV_FILE"

log "SUCCESS" "完了: ブランチ構成 OK（${BRANCH_COUNT} 階層）。"
exit $RET_OK
