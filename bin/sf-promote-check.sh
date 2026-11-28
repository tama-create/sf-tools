#!/bin/bash
# ==============================================================================
# sf-promote-check.sh - 一方通行のリリース（develop → staging → main）の確認
# ==============================================================================
# 開発物を、開発環境 → develop → staging → main の順に、同じコミットのまま上げる大原則（doc/one-way-promotion-design.md）を、
# 確かめる。破っていれば、終了コード 1（ワークフローが、マージ・組織へのリリースを止める）。判定の本体は、ここ 1 か所
# （wf-sequence・wf-validate・wf-release・sf-pr が呼ぶ）。読み取りのみ（組織・GitHub を変えない）。
#
# 【使い方】
#   sf-promote-check.sh --pr <PR 番号> [--only sequence|stack] [--json]   # ワークフロー用（PR の情報は GitHub から読む）
#   sf-promote-check.sh --plan [--json]                                    # sf-pr 用（手元のブランチの、次の出し先）
#
# 【オプション】
#   --pr <番号>      : その PR（ブランチ B の先端のコミット H を、段階 T へ出す）を確かめる。H・B・T・フォークかは、
#                      gh pr view で GitHub から読む（引数では受け取らない。違う H や T を渡して通せないように）
#   --only <分担>    : ワークフローの間の分担だけ（規則を選ぶ機能ではない）。sequence = R0・R1・R3（sf のない wf-sequence）、
#                      stack = R0・R2（wf-validate）。ほかの値・2 回の指定・空は、終了コード 2。付けなければ R0〜R3（wf-release）
#   --plan           : 手元のブランチについて、次に出してよい段階（next_tier）を計算する（PR は作らない）
#   --json           : 結果を、標準出力に JSON で 1 行で出す（画面の表示は、標準エラー）
#   -v, --verbose    : コマンドの応答（出力）をコンソールにも表示する
#   -h, --help       : このヘルプを表示して終了する
#
# 【規則】（正本は doc/one-way-promotion-design.md 3.2。段階の並びは origin/main の sf-tools/config/branches.txt を
#   get_tier_list --strict で読む。P = T の 1 つ前の段階、TOP = main）
#   R0 前提   : origin/main と branches.txt が読める・段階の構成が正しい・フォークからの PR でない・作業ツリーの HEAD が H・
#               origin のリポジトリが GitHub の応答と同じ。満たさなければ、終了コード 2（判断できないときは止める）
#   R1 順序   : P があるなら、H に P のリリースの印がある
#   R2 積み重ね: B から T へ前に出したリリース（マージ済みで、head が B・base が T・同じリポジトリの PR。その先端のコミットに
#               T の印があり、TOP の印がないもの）の部品（種類:メンバー）が、すべて、今回の反映か削除に入っている。
#               部品は、そのときのコミットの作業ツリー（git worktree）で、lib/manifest.sh の manifest_build で作る
#               （両方とも宣言した対象。組織には問い合わせない）。作れない・空なら、終了コード 2
#   R3 環境ブランチ: B が branches.txt のブランチなら、破り
#   リリースの印: wf-release が、組織へのリリースに成功したとき、H に付ける commit status（context
#   sf-tools/released-<段階>）。信じるのは、同じ context の一番新しい状態が success で、付けたのが github-actions[bot]、
#   target_url の実行が、このリポジトリの .github/workflows/wf-release.yml の pull_request の成功した実行で、
#   その実行の head_sha が H のときだけ（人や、ほかのワークフローが付けた印は無視する）
#
# 【処理の流れ】
#   1. 引数を確かめる。gh と git があること・Git リポジトリの中であることを確かめる（なければ 2）
#   2. origin の URL から owner/repo を決める。git fetch origin main で、origin/main の branches.txt を一時ファイルに出し、
#      get_tier_list --strict で段階を読む（読めなければ 2）
#   3. --pr: gh pr view で H・B・T・フォークか・リポジトリを読み、R0 を確かめる。--plan: 現在のブランチを B、HEAD を H とし、
#      git fetch origin B で、HEAD が origin/B と同じかを確かめる（違えば 2。push していない変更がある）
#   4. B の deploy-target.txt・remove-target.txt に、どちらも実質的な行がなければ、スキップ（終了コード 0。どの規則も見ない）
#   5. 規則を確かめる（--pr: --only の分担。--plan: 段階を下から順に見て、H にその段階の印がない最初の段階を next_tier にし、
#      その段階で R1・R2 を確かめる。上の段階に印があるのに下の段階にないときは 2。全部にあれば next_tier = none）
#   6. 結果を表示する（--json なら JSON も）
#
# 【前提条件】
#   - force-* のプロジェクトのルートで実行すること。ログは ./sf-tools/logs/sf-promote-check.log（毎回上書き）
#   - gh が使えること（ワークフローでは GH_TOKEN。権限: pull-requests: read・statuses: read・actions: read・contents: read）
#   - R2 を確かめるとき（--only stack・--only なし・--plan）は、Salesforce CLI（sf。npm 版）が要る
#
# 【補足】
#   - 終了コード: 0 = すべて満たす（またはスキップ）／ 1 = 破った（理由を ERROR で表示する）／ 2 = 判断できない（R0）
#   - --json の形: {"mode":"pr|plan","ok":true|false,"skipped":true|false,"branch":"B","head":"H","target":"T",
#     "next_tier":"develop|staging|main|none","pr_open":"<番号>","tiers":["develop","staging","main"]（下の段階から。構成にあるものだけ）,
#     "violations":[{"rule":"R1","detail":"..."}],"error":"..."}
#   - 管理者向けのコマンドではない（読み取りのみ）。手元でも動かせる（sf-pr.sh が --plan で呼ぶ）
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 共通ライブラリ（第 1 引数の -h / --help も、ここで処理する: lib/common.sh の 0 章）
source "${SCRIPT_DIR}/../lib/common.sh" \
    || { echo "[FATAL ERROR] Library not found: ${SCRIPT_DIR}/../lib/common.sh" >&2; exit 1; }  # run 不使用: run の定義前
source "${SCRIPT_DIR}/../lib/manifest.sh"   # manifest_parse_list・manifest_build（R2 の部品）

readonly RET_CANNOT_JUDGE=2
readonly MARK_PREFIX="sf-tools/released-"
readonly RELEASE_WORKFLOW_PATH=".github/workflows/wf-release.yml"

# ------------------------------------------------------------------------------
# 3. 引数
# ------------------------------------------------------------------------------
MODE=""; PR_NUMBER=""; ONLY=""; ONLY_SET=0; JSON_OUT=0
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --help|-h) awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}"; exit 0 ;;
        --pr)
            [[ -z "$MODE" ]] || { log "ERROR" "--pr と --plan は、どちらか 1 つです。"; exit $RET_CANNOT_JUDGE; }
            [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || { log "ERROR" "--pr には、PR の番号（1 以上の整数）を指定してください。"; exit $RET_CANNOT_JUDGE; }
            MODE="pr"; PR_NUMBER="$2"; shift ;;
        --plan)
            [[ -z "$MODE" ]] || { log "ERROR" "--pr と --plan は、どちらか 1 つです。"; exit $RET_CANNOT_JUDGE; }
            MODE="plan" ;;
        --only)
            [[ "$ONLY_SET" -eq 0 ]] || { log "ERROR" "--only は 1 回だけ指定できます。"; exit $RET_CANNOT_JUDGE; }
            case "${2:-}" in
                sequence|stack) ONLY="$2"; ONLY_SET=1; shift ;;
                *) log "ERROR" "--only の値は sequence か stack です: ${2:-（空）}"; exit $RET_CANNOT_JUDGE ;;
            esac ;;
        --json) JSON_OUT=1 ;;
        --verbose|-v) : ;;  # SILENT_EXEC は common.sh が設定済み
        *) log "ERROR" "不明なオプションです: $1"; exit $RET_CANNOT_JUDGE ;;
    esac
    shift
done
[[ -n "$MODE" ]] || { log "ERROR" "--pr <番号> か --plan を指定してください。"; exit $RET_CANNOT_JUDGE; }
[[ "$MODE" == "pr" || "$ONLY_SET" -eq 0 ]] || { log "ERROR" "--only は --pr と一緒に使います。"; exit $RET_CANNOT_JUDGE; }

# 確かめる規則（--only の分担）
CHECK_R1=1; CHECK_R2=1; CHECK_R3=1
case "$ONLY" in
    sequence) CHECK_R2=0 ;;
    stack)    CHECK_R1=0; CHECK_R3=0 ;;
esac

# ------------------------------------------------------------------------------
# 4. 結果の記録と出力
# ------------------------------------------------------------------------------
V_RULES=(); V_DETAILS=()
R_BRANCH=""; R_HEAD=""; R_TARGET=""; R_NEXT=""; R_PR_OPEN=""; R_SKIPPED=0; R_ERROR=""
_json_str() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\t'/ }"; s="${s//$'\n'/ }"; printf '"%s"' "$s"; }
_violation() { V_RULES+=("$1"); V_DETAILS+=("$2"); log "ERROR" "[$1] $2"; }
_emit_json() {
    local ok="$1" i v="" t="" x
    [[ "$JSON_OUT" -eq 1 ]] || return 0
    for ((i = 0; i < ${#V_RULES[@]}; i++)); do
        v="${v}${v:+,}{\"rule\":$(_json_str "${V_RULES[$i]}"),\"detail\":$(_json_str "${V_DETAILS[$i]}")}"
    done
    for x in ${TIERS_UP[@]+"${TIERS_UP[@]}"}; do t="${t}${t:+,}$(_json_str "$x")"; done
    printf '{"mode":%s,"ok":%s,"skipped":%s,"branch":%s,"head":%s,"target":%s,"next_tier":%s,"pr_open":%s,"tiers":[%s],"violations":[%s],"error":%s}\n' \
        "$(_json_str "$MODE")" "$ok" "$([[ $R_SKIPPED -eq 1 ]] && echo true || echo false)" \
        "$(_json_str "$R_BRANCH")" "$(_json_str "$R_HEAD")" "$(_json_str "$R_TARGET")" \
        "$(_json_str "$R_NEXT")" "$(_json_str "$R_PR_OPEN")" "$t" "$v" "$(_json_str "$R_ERROR")"
}
# 判断できない（R0）: 理由を表示し、JSON を出して、終了コード 2
_cannot_judge() { R_ERROR="$1"; log "ERROR" "[R0] 判断できません: $1"; _emit_json false; exit $RET_CANNOT_JUDGE; }

# 一時フォルダ（branches.txt の写し・前のリリースの作業ツリー・マニフェスト）。終わったら必ず消す
WORK_TMP=$(mktemp -d "${TMPDIR:-/tmp}/sf-promote-check-XXXXXX") || { log "ERROR" "一時フォルダを作れません。"; exit $RET_CANNOT_JUDGE; }
WORKTREES=()
_cleanup() {
    local w
    for w in ${WORKTREES[@]+"${WORKTREES[@]}"}; do
        git worktree remove --force "$w" >/dev/null 2>&1 || true  # 意図的なエラー無視（後始末）
    done
    rm -rf "$WORK_TMP"  # run 不使用: 一時フォルダの後始末
}
trap _cleanup EXIT

# ------------------------------------------------------------------------------
# 5. 前提（R0 の一部）: コマンド・リポジトリ・段階
# ------------------------------------------------------------------------------
log "HEADER" "一方通行のリリースを確かめます (${SCRIPT_NAME}.sh)"
command -v git >/dev/null 2>&1 || _cannot_judge "git がありません。"  # 存在確認のため run 不使用
command -v gh  >/dev/null 2>&1 || _cannot_judge "gh がありません。"   # 存在確認のため run 不使用
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || _cannot_judge "Git リポジトリの中ではありません。"  # 条件チェック

_or_rc=0; origin_repo REPO || _or_rc=$?   # origin から「owner/repo」（lib/project.sh。1 = origin なし / 2 = GitHub 以外）
case $_or_rc in
    0) ;;
    1) _cannot_judge "origin の URL を取得できません。" ;;
    *) _cannot_judge "origin が GitHub のリポジトリではありません。" ;;
esac
REPO_LC=$(printf "%s" "$REPO" | tr "[:upper:]" "[:lower:]")  # VAR=$(cmd) のため run 不使用（GitHub の名前は、大文字・小文字を区別しない）
_lc() { printf "%s" "$1" | tr "[:upper:]" "[:lower:]"; }

git fetch --quiet origin main >/dev/null 2>&1 || _cannot_judge "origin の main を取得できません。"  # 条件チェック（失敗は 2）
git show origin/main:"$BRANCH_LIST_FILE" > "$WORK_TMP/branches.txt" 2>/dev/null \
    || _cannot_judge "origin/main の ${BRANCH_LIST_FILE} を読めません。"  # 条件チェック
TIERS_TXT=$(get_tier_list --strict "$WORK_TMP/branches.txt") || _cannot_judge "段階の構成を判断できません（origin/main の ${BRANCH_LIST_FILE}）。"  # VAR=$(cmd) のため run 不使用
# 下の段階から順（develop → staging → main）の配列にする
TIERS_UP=()
while IFS= read -r _t; do
    [[ -n "$_t" ]] && TIERS_UP=("$_t" ${TIERS_UP[@]+"${TIERS_UP[@]}"})
done <<< "$TIERS_TXT"
TOP_TIER="main"

# 環境ブランチ（branches.txt の全行。保護の判定と同じ）
ENV_BRANCHES=$(grep -v '^[[:space:]]*#' "$WORK_TMP/branches.txt" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | awk 'NF')  # VAR=$(cmd) のため run 不使用
_is_env_branch() { printf '%s\n' "$ENV_BRANCHES" | grep -qxF "$1"; }  # 条件チェック

# 段階の 1 つ前（なければ空）
_prev_tier() {
    local t="$1" i
    for ((i = 0; i < ${#TIERS_UP[@]}; i++)); do
        if [[ "${TIERS_UP[$i]}" == "$t" ]]; then
            [[ $i -gt 0 ]] && echo "${TIERS_UP[$((i-1))]}"
            return 0
        fi
    done
    return 1
}

# ------------------------------------------------------------------------------
# 6. リリースの印（commit status）を確かめる
#    引数: コミット 段階。戻り値: 0 = 印がある（信じる条件をすべて満たす）/ 1 = ない / 2 = 判断できない
# ------------------------------------------------------------------------------
_has_mark() {
    local sha="$1" tier="$2" line created state creator url run_id info
    # 一番新しい状態だけを見る。全ページを取り（--paginate。1 ページは 100 件まで）、その context の状態を
    #   「作成日時<TAB>状態<TAB>付けた者<TAB>URL」で 1 行ずつ出し、作成日時（ISO 8601）の並べ替えで、一番新しいものを選ぶ
    #   （API の返す順番には頼らない）。1 行もなければ、印なし
    line=$(gh api --paginate "repos/${REPO}/commits/${sha}/statuses?per_page=100" \
        --jq ".[] | select(.context == \"${MARK_PREFIX}${tier}\") | \"\(.created_at)\t\(.state)\t\(.creator.login)\t\(.target_url)\"" 2>/dev/null </dev/null) \
        || return 2  # VAR=$(cmd) のため run 不使用（失敗は判断できない）
    line=$(printf '%s\n' "$line" | grep -v '^[[:space:]]*$' | LC_ALL=C sort | tail -1)  # VAR=$(cmd) のため run 不使用
    [[ -z "$line" ]] && return 1
    IFS=$'\t' read -r created state creator url <<< "$line"
    [[ "$state" == "success" ]] || return 1
    [[ "$creator" == "github-actions[bot]" ]] || { log "WARNING" "${sha:0:7} の ${MARK_PREFIX}${tier} は、github-actions[bot] 以外（${creator}）が付けたため、無視します。"; return 1; }
    [[ "$url" =~ /actions/runs/([0-9]+) ]] || return 2   # 実行の ID が取り出せない（壊れている）→ 判断できない
    run_id="${BASH_REMATCH[1]}"
    if [[ "$(_lc "$url")" != *"github.com/${REPO_LC}/actions/runs/${run_id}"* ]]; then
        log "WARNING" "${sha:0:7} の ${MARK_PREFIX}${tier} は、ほかのリポジトリの実行を指しているため、無視します（${url}）。"
        return 1
    fi
    info=$(gh api "repos/${REPO}/actions/runs/${run_id}" \
        --jq '"\(.repository.full_name)\t\(.path)\t\(.event)\t\(.conclusion)\t\(.head_sha)"' 2>/dev/null </dev/null) || return 2  # VAR=$(cmd) のため run 不使用
    info="$(_lc "${info%%$'\t'*}")"$'\t'"${info#*$'\t'}"   # リポジトリの名前だけ、小文字にして比べる
    if [[ "$info" != "${REPO_LC}"$'\t'"${RELEASE_WORKFLOW_PATH}"$'\t'"pull_request"$'\t'"success"$'\t'"${sha}" ]]; then
        log "WARNING" "${sha:0:7} の ${MARK_PREFIX}${tier} は、このリポジトリの wf-release の成功した実行（このコミット）のものでないため、無視します（${info//$'\t'/ / }）。"
        return 1
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 7. 部品（R2）
# ------------------------------------------------------------------------------
# 対象が空か（deploy-target.txt・remove-target.txt の両方に、実質的な行がない）。sf を使わない
_targets_empty() {
    local reldir="$1" n=0
    manifest_parse_list "${reldir}/deploy-target.txt" || return 2
    n=$((n + ${#MANIFEST_ARGS[@]}))
    manifest_parse_list "${reldir}/remove-target.txt" || return 2
    n=$((n + ${#MANIFEST_ARGS[@]}))
    [[ $n -eq 0 ]]
}
# マニフェストの「種類:メンバー」（* を含む。重複なし）
#   行の分け方に頼らない（1 行に詰まった <types><members>A</members><name>T</name></types> も、複数行の形も読む）。
#   ファイルを 1 つの文字列にまとめ、<types>〜</types> ごとに、<name> と、すべての <members> を取り出す（BSD の awk でも動く書き方）
_pairs_all() {
    local f
    for f in "$@"; do
        [[ -f "$f" ]] || continue
        awk '
            { buf = buf $0 " " }
            END {
                s = buf
                while ((i = index(s, "<types>")) > 0) {
                    s = substr(s, i + 7)
                    j = index(s, "</types>"); if (j == 0) break
                    blk = substr(s, 1, j - 1); s = substr(s, j + 8)
                    name = ""
                    if (match(blk, /<name>[^<]*<\/name>/)) name = substr(blk, RSTART + 6, RLENGTH - 13)
                    gsub(/^[ \t\r]+|[ \t\r]+$/, "", name)
                    n = 0; b = blk
                    while (match(b, /<members>[^<]*<\/members>/)) {
                        mm = substr(b, RSTART + 9, RLENGTH - 19); gsub(/^[ \t\r]+|[ \t\r]+$/, "", mm)
                        m[n++] = mm; b = substr(b, RSTART + RLENGTH)
                    }
                    for (k = 0; k < n; k++) if (name != "" && m[k] != "") printf "%s:%s\n", name, m[k]
                }
            }
        ' "$f"
    done | LC_ALL=C sort -u
}
# 作業ツリー DIR で、ブランチ B のリリースのフォルダから、宣言した部品を出す。戻り値: 0 / 1 = 作れない・空
_declared_pairs() {
    local dir="$1" branch="$2" out="$3" rc=0
    mkdir -p "$out" "$dir/sf-tools/logs" || return 1  # run 不使用: 一時フォルダ（ログは相対パスのため、作業ツリーにも置き場を作る）
    # 標準入力は閉じる（呼び出し側の while の入力を、sf に読ませないため）
    ( cd "$dir" && manifest_build "sf-tools/release/${branch}" "$out" ) </dev/null || rc=$?
    [[ $rc -eq 0 ]] || return 1
    _pairs_all "${out}/package.xml" "${out}/destructiveChanges.xml" > "${out}/pairs.txt"
    [[ -s "${out}/pairs.txt" ]] || return 1
    return 0
}
# R2: ブランチ B・先端 H・段階 T。破れば _violation。判断できなければ 2
_check_r2() {
    local branch="$1" head="$2" tier="$3" prs line num oid cross mk wt cur_out missing p type
    log "INFO" "R2（積み重ね）: ${branch} から ${tier} へ前に出したリリースの部品が、今回に含まれるかを確かめます..."
    prs=$(gh pr list --repo "$REPO" --state merged --head "$branch" --base "$tier" --limit 1000 \
        --json number,headRefOid,isCrossRepository --jq '.[] | "\(.number)\t\(.headRefOid)\t\(.isCrossRepository)"' 2>/dev/null) \
        || _cannot_judge "${branch} → ${tier} のマージ済みの PR を取得できません。"  # VAR=$(cmd) のため run 不使用
    # 上限（1000 件）まで返ったときは、取りこぼしがありうるため、判断できない（前のリリースを見落として通さない）
    [[ "$(printf '%s\n' "$prs" | grep -c .)" -lt 1000 ]] \
        || _cannot_judge "${branch} → ${tier} のマージ済みの PR が 1000 件以上あり、すべてを確かめられません。"
    cur_out="$WORK_TMP/current"
    _declared_pairs "$(pwd)" "$branch" "$cur_out" || _cannot_judge "今回（${head:0:7}）のマニフェストを作れません（または空）。"
    while IFS=$'\t' read -r num oid cross; do
        [[ -z "$num" ]] && continue
        [[ "$cross" == "false" ]] || continue          # フォークからの PR は対象にしない
        [[ "$oid" == "$head" ]] && continue            # 同じコミット（今回と同じ一覧）
        mk=0; _has_mark "$oid" "$tier" || mk=$?
        [[ $mk -eq 2 ]] && _cannot_judge "${oid:0:7} の ${tier} の印を確かめられません。"
        [[ $mk -eq 0 ]] || continue                    # T に出ていない（リリースに失敗した PR など）
        if [[ "$tier" != "$TOP_TIER" ]]; then
            mk=0; _has_mark "$oid" "$TOP_TIER" || mk=$?
            [[ $mk -eq 2 ]] && _cannot_judge "${oid:0:7} の ${TOP_TIER} の印を確かめられません。"
            [[ $mk -eq 0 ]] && continue                # 1 周が終わった（main まで届いた）
        fi
        git cat-file -e "${oid}^{commit}" 2>/dev/null || git fetch --quiet origin "$oid" >/dev/null 2>&1 \
            || _cannot_judge "前のリリース（PR #${num}・${oid:0:7}）のコミットを取得できません。"  # 条件チェック
        wt="$WORK_TMP/wt-${num}"
        git worktree add --quiet --detach "$wt" "$oid" >/dev/null 2>&1 || _cannot_judge "前のリリース（PR #${num}）の作業ツリーを作れません。"  # 条件チェック
        WORKTREES+=("$wt")
        _declared_pairs "$wt" "$branch" "$WORK_TMP/prev-${num}" || _cannot_judge "前のリリース（PR #${num}・${oid:0:7}）のマニフェストを作れません（または空）。"
        missing=""
        while IFS= read -r p; do
            [[ -z "$p" ]] && continue
            grep -qxF "$p" "$cur_out/pairs.txt" && continue    # 同じ部品がある
            type="${p%%:*}"
            grep -qxF "${type}:*" "$cur_out/pairs.txt" && continue  # 今回に同じ種類の * がある
            missing="${missing}${missing:+, }${p}"
        done < "$WORK_TMP/prev-${num}/pairs.txt"
        if [[ -n "$missing" ]]; then
            _violation "R2" "前に ${tier} へ出したリリース（PR #${num}・${oid:0:7}）の部品が、今回の deploy-target.txt・remove-target.txt にありません: ${missing}"
        fi
    done <<< "$prs"
    return 0
}

# ------------------------------------------------------------------------------
# 8. メイン
# ------------------------------------------------------------------------------
HEAD_NOW=$(git rev-parse HEAD 2>/dev/null) || _cannot_judge "HEAD を読めません。"  # VAR=$(cmd) のため run 不使用

if [[ "$MODE" == "pr" ]]; then
    PR_INFO=$(gh pr view "$PR_NUMBER" --repo "$REPO" \
        --json headRefOid,headRefName,baseRefName,isCrossRepository,url \
        --jq '"\(.headRefOid)\t\(.headRefName)\t\(.baseRefName)\t\(.isCrossRepository)\t\(.url)"' 2>/dev/null) \
        || _cannot_judge "PR #${PR_NUMBER} を取得できません（${REPO}）。"  # VAR=$(cmd) のため run 不使用
    IFS=$'\t' read -r R_HEAD R_BRANCH R_TARGET PR_CROSS PR_URL <<< "$PR_INFO"
    [[ "$(_lc "$PR_URL")" == *"github.com/${REPO_LC}/pull/${PR_NUMBER}" ]] || _cannot_judge "PR のリポジトリが、origin（${REPO}）と違います: ${PR_URL}"
    [[ "$PR_CROSS" == "false" ]] || _cannot_judge "フォークからの PR です（force-* では受け付けません）。"
    [[ "$HEAD_NOW" == "$R_HEAD" ]] || _cannot_judge "作業ツリーの HEAD（${HEAD_NOW:0:7}）が、PR の先端のコミット（${R_HEAD:0:7}）と違います。"
    printf '%s\n' "${TIERS_UP[@]}" | grep -qxF "$R_TARGET" \
        || { log "INFO" "${R_TARGET} は段階ではありません（origin/main の ${BRANCH_LIST_FILE}）。確かめるものはありません。"; R_SKIPPED=1; _emit_json true; exit 0; }
    log "INFO" "PR #${PR_NUMBER}: ${R_BRANCH}（${R_HEAD:0:7}）→ ${R_TARGET}"

    if [[ "$CHECK_R3" -eq 1 ]] && _is_env_branch "$R_BRANCH"; then
        _violation "R3" "環境ブランチ ${R_BRANCH} から、直接 ${R_TARGET} へは出せません（開発のブランチから出してください）。"
    fi
    if ! _is_env_branch "$R_BRANCH"; then
        _te=0; _targets_empty "sf-tools/release/${R_BRANCH}" || _te=$?
        if [[ $_te -eq 0 ]]; then
            log "INFO" "対象が空です（deploy-target.txt・remove-target.txt）。リリースしないため、確かめません。"
            R_SKIPPED=1; _emit_json true; exit 0
        fi
        [[ $_te -eq 2 ]] && _cannot_judge "sf-tools/release/${R_BRANCH}/ の deploy-target.txt・remove-target.txt がありません。"
        if [[ "$CHECK_R1" -eq 1 ]]; then
            PREV=$(_prev_tier "$R_TARGET")  # VAR=$(cmd) のため run 不使用
            if [[ -n "$PREV" ]]; then
                _mk=0; _has_mark "$R_HEAD" "$PREV" || _mk=$?
                [[ $_mk -eq 2 ]] && _cannot_judge "${R_HEAD:0:7} の ${PREV} の印を確かめられません。"
                if [[ $_mk -ne 0 ]]; then
                    _violation "R1" "${R_HEAD:0:7} は、まだ ${PREV} に出ていません（${PREV} へのリリースが成功した、同じコミットだけを ${R_TARGET} へ出せます）。${PREV} に出したあとに変更したなら、${PREV} から出し直してください。"
                fi
            fi
        fi
        [[ "$CHECK_R2" -eq 1 ]] && _check_r2 "$R_BRANCH" "$R_HEAD" "$R_TARGET"
    fi
else
    # --plan: 手元のブランチ
    R_BRANCH=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || _cannot_judge "ブランチの上にいません（detached HEAD）。"  # VAR=$(cmd) のため run 不使用
    R_HEAD="$HEAD_NOW"
    if _is_env_branch "$R_BRANCH"; then
        _violation "R3" "環境ブランチ ${R_BRANCH} の上にいます（開発のブランチで実行してください）。"
        _emit_json false; exit 1
    fi
    git fetch --quiet origin "$R_BRANCH" >/dev/null 2>&1 || _cannot_judge "origin の ${R_BRANCH} を取得できません（push していない可能性があります）。"  # 条件チェック
    _remote=$(git rev-parse "origin/${R_BRANCH}" 2>/dev/null) || _cannot_judge "origin/${R_BRANCH} を読めません。"  # VAR=$(cmd) のため run 不使用
    [[ "$_remote" == "$R_HEAD" ]] || _cannot_judge "手元（${R_HEAD:0:7}）と origin/${R_BRANCH}（${_remote:0:7}）が違います（push していない変更があるか、取り込んでいない変更があります）。"
    _te=0; _targets_empty "sf-tools/release/${R_BRANCH}" || _te=$?
    [[ $_te -eq 2 ]] && _cannot_judge "sf-tools/release/${R_BRANCH}/ の deploy-target.txt・remove-target.txt がありません。"
    [[ $_te -eq 0 ]] && R_SKIPPED=1
    # 下の段階から順に、印のない最初の段階
    R_NEXT=""; _seen_missing=""
    for _t in "${TIERS_UP[@]}"; do
        _mk=0; _has_mark "$R_HEAD" "$_t" || _mk=$?
        [[ $_mk -eq 2 ]] && _cannot_judge "${R_HEAD:0:7} の ${_t} の印を確かめられません。"
        if [[ $_mk -eq 0 ]]; then
            [[ -n "$_seen_missing" ]] && _cannot_judge "${R_HEAD:0:7} は ${_t} に出ているのに、下の段階 ${_seen_missing} に出ていません（原則に反する状態）。"
        else
            [[ -z "$_seen_missing" ]] && { _seen_missing="$_t"; R_NEXT="$_t"; }
        fi
    done
    [[ -n "$R_NEXT" ]] || R_NEXT="none"
    R_TARGET="$R_NEXT"
    if [[ "$R_NEXT" != "none" ]]; then
        R_PR_OPEN=$(gh pr list --repo "$REPO" --state open --head "$R_BRANCH" --base "$R_NEXT" --json number --jq '.[0].number // empty' 2>/dev/null) \
            || _cannot_judge "PR の一覧を取得できません。"  # VAR=$(cmd) のため run 不使用
        [[ "$R_SKIPPED" -eq 1 ]] || _check_r2 "$R_BRANCH" "$R_HEAD" "$R_NEXT"
    fi
    log "INFO" "次に出してよい段階: ${R_NEXT}${R_PR_OPEN:+（開いている PR: #${R_PR_OPEN}）}"
fi

if [[ ${#V_RULES[@]} -gt 0 ]]; then
    log "ERROR" "一方通行のリリースの決まりを破っています（${#V_RULES[@]} 件。doc/one-way-promotion-design.md）。"
    _emit_json false
    exit 1
fi
log "SUCCESS" "一方通行のリリースの決まりを満たしています。"
_emit_json true
exit 0
