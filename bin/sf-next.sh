#!/bin/bash
# ==============================================================================
# sf-next.sh - 次のPR先ブランチを確認するスクリプト
# ==============================================================================
# 現在のブランチが、ブランチ階層（sf-tools/config/branches.txt）のどこまでマージ済みかを確認し、
# 次に PR を出すべきブランチを表示する。確認（Y/N/q）のうえ、PR の作成画面をブラウザで開く（PR そのものは作らない）。
#
# 【使い方】
#   bash ~/sf-tools/bin/sf-next.sh [オプション]
#
# 【オプション】
#   -v, --verbose  : コマンドの応答（出力）をコンソールにも表示する
#   -h, --help     : このヘルプを表示して終了する（1 つ目の引数のときだけ）
#   上記以外の引数は、「不明なオプションです」と表示して中断する。
#
# 【処理の流れ】
#   1. 現在のブランチを取得する。detached HEAD のとき・保護ブランチ（branches.txt のブランチ。
#      ファイルがない・空のときは main）の上にいるときは、エラーで終了する
#   2. branches.txt の順序を逆にしたものを、マージの順とする（例: main / staging / develop → develop → staging → main）
#   3. git fetch origin <各ブランチ> で、リモートの最新を取得する（失敗しても、警告を出して続行し、手元の origin/* で判定する）
#   4. gh pr list で、マージ済み・オープンの PR を、それぞれ最新 50 件だけ取得する
#      （取得に失敗したときは、警告を出さず、PR なしとして扱う）
#   5. マージの順に、各ブランチの状態を、次の順で判定する
#        a. 現在のブランチ → 対象ブランチの PR が、マージ済みにある                  → merged
#        b. git merge-base --is-ancestor HEAD origin/<対象ブランチ> が真             → synced
#           （直接の PR はないが、上位ブランチ経由で伝播済み。PR・デプロイ WF は未実行）
#        c. 現在のブランチ → 対象ブランチの PR が、オープンにある                    → pr_open
#        d. どれでもない                                                              → none
#      最初の none のブランチを「次の PR 先」とする
#   6. merged のブランチより前（マージの順）に、synced / pr_open / none のブランチが 1 つでもあれば、
#      その merged を out_of_order（順序外）にする
#   7. 結果を表示する（下の【補足】の表示）
#   8. 次の PR 先があれば、「<次の PR 先> にPRを出しますか？」と確認する
#        Y: ブラウザで <origin の URL>/compare/<次の PR 先>...<現在のブランチ>?expand=1 を開き、URL も表示する
#           （origin の URL は、git@github.com: / ssh://git@github.com/ を https://github.com/ に直し、末尾の .git を除いたもの）
#        N: 何もせず終了する / q: 中断する（終了コード 1）
#      次の PR 先がないときは、pr_open が残っていれば「マージ完了を待ってください」、
#      なければ「全ブランチへのマージが完了しています」と表示して終了する
#
# 【前提条件】
#   - 現在のディレクトリの名前が force- で始まること（lib/common.sh が確認する）
#   - PR の状態の判定には gh（認証済み）が必要。使えないときも止まらず、PR なしとして判定する
#
# 【補足】
#   - 表示（状態ごと）:
#       ✓ <ブランチ>   マージ済み                 : merged
#       ✓ <ブランチ>   マージ済み（ブランチ同期） : synced
#       ⚠ <ブランチ>   マージ済み（順序外）       : out_of_order
#       → <ブランチ>   PR発行中                   : pr_open
#       ▶ <ブランチ>   次のPR先                   : none のうち、最初のもの
#       ✗ <ブランチ>                              : none のうち、2 つ目以降（文言なし）
#   - 表示例（develop マージ済み / staging PR発行中 / main 未着手）:
#       ✓ develop   マージ済み
#       → staging   PR発行中
#       ▶ main      次のPR先
#   - 終了コード: 0 = 正常終了（N で終了した場合を含む） / 1 = エラー・q で中断
#   - ログ: ./sf-tools/logs/sf-next.log（実行のたびに作り直す）
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
reject_unknown_args "$@"   # -v / --verbose 以外の引数は、不明なオプションとして中断する

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
# 出力は「ヘッド<TAB>ベース」の行（gh の --jq で作る。JSON を、シェルでは、読まない）。
# 取得に失敗したときは、空（= PR なし）として扱う
_merged_prs=$(gh pr list --state merged --limit 50 \
    --json headRefName,baseRefName --jq '.[] | [.headRefName, .baseRefName] | @tsv' 2>/dev/null || echo "")
_open_prs=$(gh pr list --state open --limit 50 \
    --json headRefName,baseRefName --jq '.[] | [.headRefName, .baseRefName] | @tsv' 2>/dev/null || echo "")

# ------------------------------------------------------------------------------
# 5. 各ブランチへのマージ状況を確認
# ------------------------------------------------------------------------------
NEXT_TARGET=""
STATUSES=()

# _pr_exists PRS HEAD BASE
# PRS（「ヘッド<TAB>ベース」の行）に、HEAD → BASE の PR があるか確認する。
# 固定文字列として、行全体で比較する（ブランチ名の . や [ を、正規表現として解釈しない）。
_pr_exists() {
    local prs="$1" head="$2" base="$3"
    printf '%s\n' "$prs" | grep -qxF -- "${head}"$'\t'"${base}"
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
        | sed 's|git@github\.com:|https://github.com/|; s|ssh://git@github\.com/|https://github.com/|; s|\.git$||')
    PR_URL="${REPO_URL}/compare/${NEXT_TARGET}...${CURRENT_BRANCH}?expand=1"
    log "INFO" "ブラウザでPR作成画面を開きます..."
    # open_browser（lib/platform.sh）が、OS に合ったコマンドで開く（Git Bash: start / WSL: powershell / macOS: open / Linux: xdg-open）
    open_browser "$PR_URL"
    echo "  $PR_URL" >&2   # 開けなかった場合に備えて、URL も表示する
else
    log "INFO" "PR 作成をスキップしました。"
fi
