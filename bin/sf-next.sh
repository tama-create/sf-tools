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
#   上記以外の引数（2 つ目以降の -h / --help を含む）は、「不明なオプションです」と表示して中断する。
#
# 【処理の流れ】
#   1. 現在のブランチを取得する。取得できない（detached HEAD など）とき・保護ブランチ（branches.txt のブランチ。
#      ファイルがない・空のときは main）の上にいるときは、エラーで終了する
#   2. branches.txt の順序を逆にしたものを、マージの順とする（例: main / staging / develop → develop → staging → main）
#   3. git fetch origin <全ブランチ>（1 回のコマンド）で、リモートの最新を取得する
#      （失敗しても、警告を出して続行し、手元の origin/* で判定する）
#   4. gh pr list で、マージ済み・オープンの PR を、それぞれ最新 50 件だけ取得する
#      （マージ済みは、PR の最後のコミット（headRefOid）も取る。取得に失敗したときは、警告を出さず、PR なしとして扱う）
#   5. マージの順に、各ブランチの状態を、次の順で判定する
#        a. 現在のブランチ → 対象ブランチの PR が、マージ済みにあり、HEAD がマージ済みの内容に含まれる → merged
#           （含まれる = HEAD が、マージ済みの PR の最後のコミットと同じか、その祖先か、origin/<対象ブランチ> の祖先。
#            PR の最後のコミットでも比べるので、Squash・Rebase でマージした場合も、正しく判定できる。
#            PR の最後のコミットが取れない（gh が headRefOid を返さない）ときは、判定できないため、merged とする）
#           マージ済みの PR はあるが、HEAD が含まれない（マージのあとに、同じブランチへ新しいコミットを足した）ときは、
#           同じ向きのオープンの PR があれば → pr_open、なければ → merged_stale（次の PR 先にする。下の d と同じ扱い）
#        b. git merge-base --is-ancestor HEAD origin/<対象ブランチ> が真             → synced
#           （HEAD のコミットが、すでに origin/<対象ブランチ> に含まれている。直接の PR はないが、別のブランチ経由で
#            伝播済みなど。この PR のデプロイ WF は未実行）
#        c. 現在のブランチ → 対象ブランチの PR が、オープンにある                    → pr_open
#        d. どれでもない                                                              → none
#      最初の none / merged_stale のブランチを「次の PR 先」とする
#   6. merged のブランチより前（マージの順）に、synced / pr_open / none / merged_stale のブランチが 1 つでもあれば、
#      その merged を out_of_order（順序外）にする
#   7. 結果を表示する（下の【補足】の表示）
#   8. 次の PR 先があれば、「<次の PR 先> にPRを出しますか？」と確認する。次の PR 先がマージの順の 2 つ目以降
#      （例: staging・main）のときは、前に「<1 つ前のブランチ> の組織で、動作を確かめ終えましたか？」を付ける
#      （マージ済みの表示だけを見て、確かめずに上の段階へ上げるのを防ぐため。確認の回数は増やさない）
#        Y: ブラウザで <origin の URL>/compare/<次の PR 先>...<現在のブランチ>?expand=1 を開き、URL も表示する
#           （origin の URL は、http(s):// の URL に含まれる認証情報（//<ユーザー>:<Token>@ の部分）を除き、
#           git@github.com: / ssh://git@github.com/ を https://github.com/ に直し、末尾の .git を除いたもの。
#           origin の URL を取得できないときは、エラーで終了する）
#        N: 何もせず終了する / q: 中断する（終了コード 1）
#      次の PR 先がないときは、pr_open が残っていれば「マージ完了を待ってください」、
#      なければ「全ブランチへのマージが完了しています！」と表示して終了する
#
# 【前提条件】
#   - 現在のディレクトリの名前が force- で始まること（lib/common.sh が確認する）
#   - PR の状態の判定には gh（認証済み）が必要。使えないときも止まらず、PR なしとして判定する
#
# 【補足】
#   - AI 操作（環境変数 SF_TOOLS_AI=1。doc/ai-operation-design.md）: PR を出すかの質問の名前は next.pr。
#     SF_TOOLS_ANSWERS="next.pr=n" で、状況の表示だけ（ブラウザを開かない）。"next.pr=y" で、PR の作成画面を開く
#     （人の了承を得たときだけ）。答えがなければ、ブラウザを開く前に「[確認待ち] next.pr: …」を出して、終了コード 20 で終わる
#   - 表示は、標準エラーに出す。見出し「<現在のブランチ> のマージ状況」の下に、マージの順で 1 行ずつ（状態ごと）:
#       ✓ <ブランチ>   マージ済み                 : merged
#       ▶ <ブランチ>   マージ済み・その後の変更（N コミット）が未反映 → 次のPR先 : merged_stale のうち、次の PR 先
#       ✗ <ブランチ>   マージ済み・その後の変更（N コミット）が未反映             : merged_stale のうち、2 つ目以降
#                      （N を数えられない（PR の最後のコミットが手元にない）ときは「その後の変更が未反映」）
#       ✓ <ブランチ>   マージ済み（ブランチ同期） : synced
#       ⚠ <ブランチ>   マージ済み（順序外）       : out_of_order
#       → <ブランチ>   PR発行中                   : pr_open
#       ▶ <ブランチ>   次のPR先                   : none のうち、最初のもの
#       ✗ <ブランチ>                              : none のうち、2 つ目以降（文言なし）
#   - 表示例（develop マージ済み / staging PR発行中 / main 未着手）:
#       ✓ develop   マージ済み
#       → staging   PR発行中
#       ▶ main      次のPR先
#   - 終了コード: 0 = 正常終了（N で終了した場合を含む） / 1 = エラー・q で中断 / 20 = 確認待ち（AI 操作）
#   - ログ: ./sf-tools/logs/sf-next.log（実行のたびに作り直す）
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 共通ライブラリの必須設定
# ------------------------------------------------------------------------------
SCRIPT_NAME="${0##*/}"; readonly SCRIPT_NAME="${SCRIPT_NAME%.sh}"
readonly LOG_FILE="./sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"

# ------------------------------------------------------------------------------
# 2. 共通ライブラリの読み込み
# ------------------------------------------------------------------------------
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR/" == /* && "$SCRIPT_DIR/" != *//* && "$SCRIPT_DIR/" != */./* && "$SCRIPT_DIR/" != */../* ]] || SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="${SCRIPT_DIR}/../lib/common.sh"

if [[ ! -f "$COMMON_LIB" ]]; then
    echo "[FATAL ERROR] Library not found: $COMMON_LIB" >&2
    exit 1
fi
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}"  # run 不使用: common.sh の読み込み前（run が未定義）
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

# 保護ブランチ（branches.txt のブランチ。例: main/staging/develop）からは実行不可
if is_protected_branch "$CURRENT_BRANCH"; then
    die "${CURRENT_BRANCH} は保護ブランチ（sf-tools/config/branches.txt）のため、実行できません。"
fi

# get_branch_list は常に成功する（ファイルがない・空のときは、WARNING を出して main だけを返す）ため、失敗の判定はしない
BRANCH_LIST=$(get_branch_list)

# branches.txt の順序（例: main → staging → develop）のまま MERGE_ORDER に読み込み、逆順にした REVERSED をマージ順にする
# マージ順（REVERSED）: develop → staging → main
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
#   （標準エラーは捨てない。run の「> Command:」の行と、-v のときのコマンドの応答は、標準エラーに出るため）
run git fetch origin "${REVERSED[@]}" \
    || log "WARNING" "リモートブランチの取得に失敗しました（ローカルキャッシュで判定します）。"

# gh pr list はブランチごとに呼ぶと遅いため、マージ済み・オープン を各1回で取得
# --head フィルタが merged/open で正常動作しないバージョンがあるため、それぞれ最新 50 件を取得して絞る
# 出力は「ヘッド<TAB>ベース」の行（gh の --jq で作る。JSON を、シェルでは、読まない）。
# マージ済みは、3 列目に PR の最後のコミット（headRefOid）を付ける（マージのあとに足したコミットを見つけるため。5 の merged_stale）。
# 取得に失敗したときは、空（= PR なし）として扱う
_merged_prs=$(gh pr list --state merged --limit 50 \
    --json headRefName,baseRefName,headRefOid --jq '.[] | [.headRefName, .baseRefName, .headRefOid] | @tsv' 2>/dev/null || echo "")  # VAR=$(cmd) のため run 不使用
_open_prs=$(gh pr list --state open --limit 50 \
    --json headRefName,baseRefName --jq '.[] | [.headRefName, .baseRefName] | @tsv' 2>/dev/null || echo "")  # VAR=$(cmd) のため run 不使用

# ------------------------------------------------------------------------------
# 5. 各ブランチへのマージ状況を確認
# ------------------------------------------------------------------------------
NEXT_TARGET=""
STATUSES=()

# _pr_exists PRS HEAD BASE
# PRS（「ヘッド<TAB>ベース[<TAB>コミット]」の行）に、HEAD → BASE の PR があるか確認する。
# 1・2 列目を、固定文字列として比較する（ブランチ名の . や [ を、正規表現として解釈しない）。
_pr_exists() {
    local prs="$1" head="$2" base="$3"
    printf '%s\n' "$prs" | awk -F'\t' -v h="$head" -v b="$base" '$1 == h && $2 == b { f = 1; exit } END { exit !f }'  # 条件チェックのため run 不使用（関数の戻り値にする）
}

# _pr_oids PRS HEAD BASE
# HEAD → BASE の PR の、最後のコミット（3 列目）を、1 行に 1 つ出す（新しい PR から順。gh pr list の並び）。
_pr_oids() {
    printf '%s\n' "$1" | awk -F'\t' -v h="$2" -v b="$3" '$1 == h && $2 == b && $3 != "" { print $3 }'  # 出力用のため run 不使用
}

# _head_in_merged TARGET
# いまの HEAD が、TARGET へマージ済みの内容に含まれるか（含まれれば 0）。
#   HEAD が、マージ済みの PR の最後のコミットと同じか、その祖先 / origin/<TARGET> の祖先なら、含まれる。
#   PR の最後のコミットでも比べるのは、Squash・Rebase でマージすると、HEAD が origin/<TARGET> の祖先にならないため
#   PR の最後のコミットが 1 つも取れない（gh が headRefOid を返さない）ときは、判定できないため、含まれるとする（以前の動き）
_head_in_merged() {
    local target="$1" oid oids
    git merge-base --is-ancestor HEAD "origin/$target" 2>/dev/null && return 0  # 条件チェックのため run 不使用
    oids=$(_pr_oids "$_merged_prs" "$CURRENT_BRANCH" "$target")  # VAR=$(cmd) のため run 不使用
    [[ -z "$oids" ]] && return 0
    while IFS= read -r oid; do
        [[ -z "$oid" ]] && continue
        [[ "$oid" == "$HEAD_OID" ]] && return 0
        git merge-base --is-ancestor HEAD "$oid" 2>/dev/null && return 0  # 条件チェックのため run 不使用
    done <<< "$oids"
    return 1
}

# _new_commits_since_merge TARGET
# TARGET へマージ済みの最新の PR の最後のコミットから、HEAD までのコミットの数を出す。数えられないときは、何も出さない
_new_commits_since_merge() {
    local oid n
    oid=$(_pr_oids "$_merged_prs" "$CURRENT_BRANCH" "$1" | head -1)  # VAR=$(cmd) のため run 不使用
    [[ -z "$oid" ]] && return 0
    n=$(git rev-list --count "${oid}..HEAD" 2>/dev/null) || return 0  # VAR=$(cmd) のため run 不使用（手元にないコミットなら数えない）
    n=$(printf '%s' "$n" | tr -d ' ')
    [[ "$n" =~ ^[0-9]+$ ]] && printf '%s' "$n"
}

HEAD_OID=$(git rev-parse HEAD 2>/dev/null || echo "")  # VAR=$(cmd) のため run 不使用
STALE_COUNTS=()   # merged_stale のときの、マージのあとのコミットの数（REVERSED と同じ並び。数えられないときは空）

for target in "${REVERSED[@]}"; do
    STALE_COUNTS+=("")
    if _pr_exists "$_merged_prs" "$CURRENT_BRANCH" "$target"; then
        if _head_in_merged "$target"; then
            # 現在ブランチ → 対象ブランチへの直接 PR がマージ済みで、いまの HEAD もその内容に含まれる
            STATUSES+=("merged")
        elif _pr_exists "$_open_prs" "$CURRENT_BRANCH" "$target"; then
            # マージのあとに足したコミットで、もう一度 PR を発行済み（マージ前）
            STATUSES+=("pr_open")
        else
            # マージのあとに、同じブランチへ新しいコミットを足した（まだ対象ブランチに入っていない）→ 次の PR 先
            STATUSES+=("merged_stale")
            STALE_COUNTS[${#STATUSES[@]}-1]="$(_new_commits_since_merge "$target")"
            [[ -z "$NEXT_TARGET" ]] && NEXT_TARGET="$target"
        fi
    elif git merge-base --is-ancestor HEAD "origin/$target" 2>/dev/null; then  # 条件チェックのため run 不使用
        # HEAD のコミットが、すでに origin/<対象> に含まれている（直接 PR はないが、別のブランチ経由で伝播済みなど。デプロイ WF は未実行）
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
# 5b. 順序外マージの検出（merged でも前に synced/pr_open/none/merged_stale があれば out_of_order に昇格）
# ------------------------------------------------------------------------------
# synced = デプロイ WF が未実行のためデプロイ観点では「未完」扱い。merged_stale = 新しいコミットが未反映のため「未完」扱い
for idx in "${!STATUSES[@]}"; do
    [[ "${STATUSES[$idx]}" != "merged" ]] && continue
    for ((j=0; j<idx; j++)); do
        if [[ "${STATUSES[$j]}" == "none" || "${STATUSES[$j]}" == "pr_open" || "${STATUSES[$j]}" == "synced" || "${STATUSES[$j]}" == "merged_stale" ]]; then
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
        merged_stale)
            # マージのあとに足したコミットが、まだ対象ブランチに入っていない（次の PR 先）
            if [[ -n "${STALE_COUNTS[$idx]}" ]]; then
                stale_msg="マージ済み・その後の変更（${STALE_COUNTS[$idx]} コミット）が未反映"
            else
                stale_msg="マージ済み・その後の変更が未反映"
            fi
            if [[ "$target" == "$NEXT_TARGET" ]]; then
                echo -e "    ${CLR_WARNING}▶ ${target}${name_pad}   ${stale_msg} → 次のPR先${CLR_RESET}" >&2
            else
                echo -e "    ${CLR_ERR}✗ ${target}${name_pad}   ${stale_msg}${CLR_RESET}" >&2
            fi
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

# 次の PR 先がマージの順の 2 つ目以降（例: staging・main）なら、1 つ前のブランチの組織で確かめたかを、同じ確認の中で聞く
#   （「マージ済み」の表示だけを見て、確かめずに上の段階へ上げるのを防ぐため。確認の回数は増やさない）
CONFIRM_MSG="${NEXT_TARGET} にPRを出しますか？"
for idx in "${!REVERSED[@]}"; do
    if [[ "${REVERSED[$idx]}" == "$NEXT_TARGET" && $idx -gt 0 ]]; then
        CONFIRM_MSG="${REVERSED[$((idx-1))]} の組織で、動作を確かめ終えましたか？ ${CONFIRM_MSG}"
        break
    fi
done

if ask_yn "$CONFIRM_MSG" next.pr; then   # next.pr: AI 操作の質問の名前（doc/ai-operation-design.md）
    # リモートリポジトリ情報を取得
    #   http(s):// の URL に含まれる認証情報（//<ユーザー>:<Token>@）は除く（Token を、画面・ログ・ブラウザの履歴に出さないため）。
    #   lib/project.sh の git_origin_redacted は *** に置き換える（表示用）ため、ブラウザで開く URL には使えない
    REPO_URL=$(git remote get-url origin 2>/dev/null \
        | sed 's#^\(https\{0,1\}://\)[^@/]*@#\1#; s|git@github\.com:|https://github.com/|; s|ssh://git@github\.com/|https://github.com/|; s|\.git$||')  # VAR=$(cmd) のため run 不使用
    [[ -n "$REPO_URL" ]] || die "origin の URL を取得できません。"
    PR_URL="${REPO_URL}/compare/${NEXT_TARGET}...${CURRENT_BRANCH}?expand=1"
    log "INFO" "ブラウザでPR作成画面を開きます..."
    # open_browser（lib/platform.sh）が、OS に合ったコマンドで開く（Git Bash: start / WSL: powershell / macOS: open / Linux: xdg-open）
    open_browser "$PR_URL"
    echo "  $PR_URL" >&2   # 開けなかった場合に備えて、URL も表示する
else
    log "INFO" "PR 作成をスキップしました。"
fi
