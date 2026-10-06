#!/bin/bash
# ==============================================================================
# sf-next.sh - 次のPR先ブランチを確認するスクリプト
# ==============================================================================
# 現在のブランチがブランチ階層のどこまでマージ済みかを確認し、
# 次にPRを出すべきブランチを表示します。
#
# 【使い方】
#   bash ~/sf-tools/bin/sf-next.sh
#
# 【状態遷移】
#   ✗ なし  →  ▶ 次のPR先  →  → PR発行中  →  ✓ マージ済み
#                                               ✓ マージ済み（ブランチ同期）  ← 間接伝播
#                                               ⚠ 順序外マージ済み（前のブランチ未完）
#
# 【表示例（develop マージ済み / staging PR発行中 / main 未着手）】
#   ✓ develop   マージ済み
#   → staging   PR発行中
#   ▶ main      次のPR先
#
# 【判定方法】
#   1. gh pr list --state merged で現在ブランチ→対象ブランチへの直接 PR を確認
#   2. git merge-base --is-ancestor で間接伝播（上位ブランチ経由）を確認 → synced
#      ※ synced は PR/デプロイ WF が未実行のため、後続の merged は ⚠ 扱い
#   3. gh pr list --state open で PR 発行中を確認
#   4. 前のブランチが直接マージ/PR未完/同期のみ なのに後のブランチが直接マージ済みなら ⚠
#
# 【前提条件】
#   - force-* ディレクトリ内で実行すること
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 共通ライブラリの必須設定
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME=$(basename "$0" .sh)
readonly LOG_FILE="./sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"

# ------------------------------------------------------------------------------
# 2. 共通ライブラリの読み込み
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="${SCRIPT_DIR}/../lib/common.sh"

if [[ ! -f "$COMMON_LIB" ]]; then
    echo "[FATAL ERROR] Library not found: $COMMON_LIB" >&2
    exit 1
fi
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}"
    exit 0
fi
source "$COMMON_LIB"

# ------------------------------------------------------------------------------
# 3. ブランチ階層の取得
# ------------------------------------------------------------------------------
log "HEADER" "次のPR先を確認します (${SCRIPT_NAME}.sh)"

CURRENT_BRANCH=$(run git symbolic-ref --short HEAD) \
    || die "現在のブランチを取得できません。"

# 保護ブランチ（main/staging/develop）からは実行不可
if is_protected_branch "$CURRENT_BRANCH"; then
    die "${CURRENT_BRANCH} は保護ブランチです。feature ブランチから実行してください。"
fi

BRANCH_LIST=$(get_branch_list) || die "ブランチ構成を取得できません。"

# branches.txt の順序（main → staging → develop）を逆順にしてマージ順にする
# マージ順: develop → staging → main
MERGE_ORDER=()
while IFS= read -r b; do
    MERGE_ORDER+=("$b")
done <<< "$BRANCH_LIST"

# 逆順に並べ替え
REVERSED=()
for ((i=${#MERGE_ORDER[@]}-1; i>=0; i--)); do
    REVERSED+=("${MERGE_ORDER[$i]}")
done

# ------------------------------------------------------------------------------
# 4. リモートの最新状態を取得 & PR 一覧を事前取得
# ------------------------------------------------------------------------------
# git merge-base（synced 判定）のためリモートの最新状態を取得する
log "INFO" "リモートの最新状態を取得中..."
run git fetch origin "${REVERSED[@]}" 2>/dev/null \
    || log "WARNING" "リモートブランチの取得に失敗しました（ローカルキャッシュで判定します）。"

# gh pr list はブランチごとに呼ぶと遅いため、マージ済み・オープン を各1回で取得
# --head フィルタが merged/open で正常動作しないバージョンがあるため全件取得して絞る
_merged_prs=$(gh pr list --state merged \
    --json headRefName,baseRefName --limit 50 2>/dev/null || echo "[]")
_open_prs=$(gh pr list --state open \
    --json headRefName,baseRefName --limit 50 2>/dev/null || echo "[]")

# ------------------------------------------------------------------------------
# 5. 各ブランチへのマージ状況を確認
# ------------------------------------------------------------------------------
NEXT_TARGET=""
STATUSES=()

# _pr_exists PRSJON HEAD BASE
# JSON 配列内に headRefName=HEAD かつ baseRefName=BASE のオブジェクトが存在するか確認。
# gh pr list の --json 出力はフィールド順が保証されないため、
# awk で } を区切りとして各オブジェクトを分割し両フィールドを個別に検索する。
_pr_exists() {
    local prs="$1" head="$2" base="$3"
    echo "$prs" | awk \
        -v hf="\"headRefName\":\"${head}\"" \
        -v bf="\"baseRefName\":\"${base}\"" \
        'BEGIN{RS="}"} index($0,hf) && index($0,bf) {found=1} END{exit !found}'
}

for target in "${REVERSED[@]}"; do
    if _pr_exists "$_merged_prs" "$CURRENT_BRANCH" "$target"; then
        # 現在ブランチ → 対象ブランチへの直接 PR がマージ済み
        STATUSES+=("merged")
    elif git merge-base --is-ancestor HEAD "origin/$target" 2>/dev/null; then
        # 直接 PR はないが上位ブランチ経由で間接的にコミットが伝播済み（デプロイ WF は未実行）
        STATUSES+=("synced")
    elif _pr_exists "$_open_prs" "$CURRENT_BRANCH" "$target"; then
        # PR が発行済み（マージ前）
        STATUSES+=("pr_open")
    else
        STATUSES+=("none")
        [[ -z "$NEXT_TARGET" ]] && NEXT_TARGET="$target"
    fi
done

# ------------------------------------------------------------------------------
# 5b. 順序外マージの検出（merged でも前に synced/pr_open/none があれば out_of_order に昇格）
# ------------------------------------------------------------------------------
# synced = デプロイ WF が未実行のためデプロイ観点では「未完」扱い
for idx in "${!STATUSES[@]}"; do
    [[ "${STATUSES[$idx]}" != "merged" ]] && continue
    for ((j=0; j<idx; j++)); do
        if [[ "${STATUSES[$j]}" == "none" || "${STATUSES[$j]}" == "pr_open" || "${STATUSES[$j]}" == "synced" ]]; then
            STATUSES[$idx]="out_of_order"
            break
        fi
    done
done

# ------------------------------------------------------------------------------
# 6. ブランチ名の最大幅を計算（表示の桁揃え用）
# ------------------------------------------------------------------------------
MAX_LEN=0
for target in "${REVERSED[@]}"; do
    (( ${#target} > MAX_LEN )) && MAX_LEN=${#target}
done

# スペースを生成するヘルパー
pad() {
    local len="$1" s=""
    for ((n=0; n<len; n++)); do s+=" "; done
    echo "$s"
}

# ------------------------------------------------------------------------------
# 7. 結果表示
# ------------------------------------------------------------------------------
echo "" >&2
echo -e "  ${CLR_INFO}${CURRENT_BRANCH} のマージ状況${CLR_RESET}" >&2
echo -e "  ${CLR_INFO}────────────────────────────${CLR_RESET}" >&2

for idx in "${!REVERSED[@]}"; do
    target="${REVERSED[$idx]}"
    status="${STATUSES[$idx]}"
    name_pad=$(pad $(( MAX_LEN - ${#target} )))

    case "$status" in
        merged)
            echo -e "    ${CLR_SUCCESS}✓ ${target}${name_pad}   マージ済み${CLR_RESET}" >&2
            ;;
        synced)
            echo -e "    ${CLR_INFO}✓ ${target}${name_pad}   マージ済み（ブランチ同期）${CLR_RESET}" >&2
            ;;
        out_of_order)
            echo -e "    ${CLR_WARNING}⚠ ${target}${name_pad}   マージ済み（順序外）${CLR_RESET}" >&2
            ;;
        pr_open)
            echo -e "    ${CLR_INFO}→ ${target}${name_pad}   PR発行中${CLR_RESET}" >&2
            ;;
        none)
            if [[ "$target" == "$NEXT_TARGET" ]]; then
                echo -e "    ${CLR_WARNING}▶ ${target}${name_pad}   次のPR先${CLR_RESET}" >&2
            else
                echo -e "    ${CLR_ERR}✗ ${target}${CLR_RESET}" >&2
            fi
            ;;
    esac
done

echo "" >&2

# ------------------------------------------------------------------------------
# 8. PR 作成の確認
# ------------------------------------------------------------------------------
if [[ -z "$NEXT_TARGET" ]]; then
    # pr_open が残っている場合はマージ待ち
    for s in "${STATUSES[@]}"; do
        if [[ "$s" == "pr_open" ]]; then
            log "INFO" "全 PR が発行済みです。マージ完了を待ってください。"
            exit $RET_OK
        fi
    done
    log "SUCCESS" "全ブランチへのマージが完了しています！"
    exit $RET_OK
fi

if ask_yn "${NEXT_TARGET} にPRを出しますか？"; then
    # リモートリポジトリ情報を取得
    REPO_URL=$(git remote get-url origin 2>/dev/null \
        | sed 's|git@github\.com:|https://github.com/|; s|\.git$||')
    PR_URL="${REPO_URL}/compare/${NEXT_TARGET}...${CURRENT_BRANCH}?expand=1"
    log "INFO" "ブラウザでPR作成画面を開きます..."
    run start "$PR_URL" 2>/dev/null \
        || run open "$PR_URL" 2>/dev/null \
        || run xdg-open "$PR_URL" 2>/dev/null \
        || { log "WARNING" "ブラウザを開けません。以下のURLを手動で開いてください:"; echo "  $PR_URL" >&2; }
else
    log "INFO" "PR 作成をスキップしました。"
fi
