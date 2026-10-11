#!/bin/bash
# ==============================================================================
# sf-verify.sh - 実際のリポジトリと組織で、リリース・削除が動くことを検証する（管理者向け）
# ==============================================================================
# sf-init で作った、実際のリポジトリ（force-*）が、実際の Salesforce 組織に対して、正しく動くことを確認する。
# 誰も使わない、単純な Apex（Hello World: SfToolsE2eHello / SfToolsE2eHelloTest）を、各段階にリリースして、削除する。
# 何をするかを、先に表示し、Enter を 1 回押して確認してから、実行する（sf-init と同じ Git Bash で、続けて実行する想定。入力は、最小）。
# force-* ディレクトリの中で、リポジトリのオーナー（組織の管理者）の gh アカウントで、実行する。
#
# 【処理の流れ】
#   1. 診断          : セットアップの状態（sf-init.sh --status の診断）。不足があれば、ここで中断する
#   2. 実行内容の表示 : リポジトリ・段階ごとの組織の名前と種類・実行する内容・目安の時間。本番は、赤く表示する
#   3. 確認          : 警告と、Enter の確認（Enter / Y で進む。N / q は、何も変更せずに中断）。本番（または種類を判定できない）
#                      組織があるときは、質問の文面で、本番を含むことを明示する
#   3b. 環境の確認   : 環境全体を、最初に確認する（e2e の確認と同じ観点）。NG があれば、そこで止める（組織に、何も変更しない。
#                      wf-metasync は、手前の 2 つの確認が OK のときだけ、実行する）
#                        ・SF_TOOLS_BRANCH が、main または development である
#                        ・ローカルのログ（~/sf-tools/logs）に、Token・認証 URL が残っていない
#                        ・wf-metasync（Salesforce → Git の同期）を、手動で 1 回実行し、成功する
#                          （JWT ログイン・sf-tools の取得を含む。main の組織の変更が、main にコミットされることがある）
#   4. リリース      : 同じブランチから、develop → staging → main の順（ない段階は、とばす）に、段階ごとの PR を出して、
#                      wf-validate（検証）→ マージ → wf-release（リリース）。段階ごとに、次を確認する:
#                        ・その段階の組織への JWT ログインが成功した
#                        ・ほかの段階のログインのステップは、実行されていない（別の組織に、ログインしていない）
#                        ・接続ユーザー（SF_USERNAME_*）が登録されていて、ログに、そのユーザーが出ている
#                        ・ログに、Hello World のクラス名が出ている
#                      main へのマージのあとは、wf-propagate も確認する
#   5. 削除          : 削除用のブランチ（remove-target.txt と、リポジトリのクラスのファイルの削除）から、同じ順に、各段階へ PR →
#                      マージ → wf-release。組織のクラスと、リポジトリのファイルの両方が、消える
#   6. 結果の表示    : 段階ごとの成功・失敗
#
# 【注意】
#   ・リポジトリに、PR・コミット（追加と削除）が、残る。Slack に、通知が届く。リリースの間、組織が、短時間、占有される
#   ・作業の少ない時間帯に、実行すること
#   ・失敗したとき: リリースのあとで止まった場合、組織に Hello World が残ることがある。
#     残った組織と、削除のみをやり直す方法（--cleanup）を、表示する
#   ・ブランチ保護で、PR のマージが拒否されると、その段階で止まり、PR が残る
#   ・検証用と同じ名前のクラス（SfToolsE2eHello / SfToolsE2eHelloTest）のファイルが、すでにリポジトリにあると、
#     上書きして削除してしまうため、実行しない（--cleanup を除く）。組織だけにある同名のクラスは、検出できない
#
# 【オプション】
#   --plan      : 診断と、実行内容の表示だけを行う（何も変更しない。確認も出さない）
#   --no-metasync : 環境の確認のうち、wf-metasync の実行を、省略する（組織からの同期を、いま行いたくないとき）
#   --cleanup   : 削除のみを行う（リリースの途中で止まって、組織に Hello World が残ったときの後始末）。
#                 対象は、固定名のクラス（SfToolsE2eHello / SfToolsE2eHelloTest）だけ。ほかのクラスには、触れない
#   -h, --help  : このヘルプを表示する
# ==============================================================================

readonly SCRIPT_NAME="sf-verify"
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true  # run 不使用: ログフォルダの準備（log が使える前の処理）
readonly LOG_FILE="$HOME/sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}"
    exit 0
fi

source "${SCRIPT_DIR}/../lib/common.sh"
source "${SCRIPT_DIR}/../lib/wizard.sh"
source "${SCRIPT_DIR}/../lib/sf-org.sh"
source "${SCRIPT_DIR}/../lib/sf-diag.sh"
source "${SCRIPT_DIR}/../lib/sf-verify.sh"

PLAN_ONLY=0
CLEANUP_ONLY=0
NO_METASYNC=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --plan)    PLAN_ONLY=1 ;;
        --cleanup) CLEANUP_ONLY=1 ;;
        --no-metasync) NO_METASYNC=1 ;;
        *) die "不明なオプションです: $1" ;;
    esac
    shift
done

# ------------------------------------------------------------------------------
# 0. 前提の確認
# ------------------------------------------------------------------------------
[[ "${GITHUB_ACTIONS:-}" == "true" ]] && die "GitHub Actions 上では、実行できません。"
check_force_dir || die "force-* ディレクトリ内で実行してください。"

remote_url=$(git remote get-url origin 2>/dev/null) || die "git remote を取得できません。"  # VAR=$(cmd) のため run 不使用
REPO=$(echo "$remote_url" | sed 's|.*github\.com[:/]\(.*\)\.git|\1|; s|.*github\.com[:/]\(.*\)|\1|')  # VAR=$(cmd) のため run 不使用
[[ "$REPO" == */* ]] || die "リポジトリ名を取得できません。"
OWNER="${REPO%%/*}"

log "HEADER" "リポジトリの検証（${REPO}）"
check_gh_owner "$OWNER"

# 段階: リモートのブランチから判定する（develop → staging → main の順に、リリースする）
branches=$(sfv_gh api "repos/${REPO}/branches" --paginate --jq '.[].name' 2>/dev/null | tr -d '\r') \
    || die "ブランチの一覧を取得できません。"  # VAR=$(cmd) のため run 不使用
grep -qx "main" <<< "$branches" || die "ブランチ main が見つかりません。"
TIERS=()
grep -qx "develop" <<< "$branches" && grep -qx "staging" <<< "$branches" && TIERS+=("develop")
grep -qx "staging" <<< "$branches" && TIERS+=("staging")
TIERS+=("main")

_suffix_of() { case "$1" in main) echo "PROD" ;; staging) echo "STG" ;; develop) echo "DEV" ;; esac; }
_var() { sfv_gh variable get "$1" -R "$REPO" 2>/dev/null | tr -d '\r' || true; }  # 取得専用のため run 不使用

# ------------------------------------------------------------------------------
# 1. 診断（不足があれば、ここで中断する）
# ------------------------------------------------------------------------------
sf_diag_run "$REPO" "${TIERS[@]}"
[[ "$DIAG_NG" -eq 0 ]] || die "セットアップに不足があるため、検証を始められません（上の「直し方」を実行してください）。"

# 同名のクラスのファイルが、すでにリポジトリにないこと。あれば、検証のクラスが、それを上書きして、削除してしまう。
#   --cleanup は、前回の検証の残りの後始末のため、対象外（残りがあるのが、前提）。組織だけにある同名のクラスは、ここでは検出できない
if [[ $CLEANUP_ONLY -eq 0 ]]; then
    for t in "${TIERS[@]}"; do
        while IFS= read -r p; do
            if sfv_file_sha "$REPO" "$t" "$p" > /dev/null; then  # 条件チェック
                log "ERROR" "  ${t} ブランチに、検証用と同じ名前のファイルが、すでにあります: ${p}"
                log "WARNING" "  このまま実行すると、そのクラスを、上書きして、削除します。前回の検証の残りであれば、sf-verify.sh --cleanup を実行してください。"
                die "検証用と同名のクラスのファイルが、すでにあります（${t}: ${p}）。"
            fi
        done < <(sfv_hello_paths)
    done
fi

# ------------------------------------------------------------------------------
# 2. 実行内容の表示
# ------------------------------------------------------------------------------
NEED_PROD_CONFIRM=0
echo "" >&2
echo -e "  ${CLR_WARNING}【これから行うこと】${CLR_RESET}" >&2
echo "    リポジトリ : ${REPO}" >&2
echo "    段階（リリースの順）:" >&2
for t in "${TIERS[@]}"; do
    sfx=$(_suffix_of "$t")
    kind=$(_var "SF_ORG_KIND_${sfx}")
    oname=$(_var "SF_ORG_NAME_${sfx}")
    user=$(_var "SF_USERNAME_${sfx}")
    label=$(sf_org_kind_label "${kind:-unknown}")
    case "$kind" in
        developer|sandbox|trial) mark="" ;;
        *) mark="  ← 本番（または、種類を判定できない）組織"; NEED_PROD_CONFIRM=1 ;;
    esac
    if [[ -n "$mark" ]]; then
        echo -e "      ${CLR_ERR}${t} → ${oname:-（名前なし）} / ${label} / ${user:-（ユーザー未設定）}${mark}${CLR_RESET}" >&2
    else
        echo "      ${t} → ${oname:-（名前なし）} / ${label} / ${user:-（ユーザー未設定）}" >&2
    fi
done
n_tiers=${#TIERS[@]}
if [[ $CLEANUP_ONLY -eq 1 ]]; then
    echo "    内容       : 削除のみ（Hello World のクラスを、各段階の組織から消す。${n_tiers} 本の PR）" >&2
else
    echo "    内容       : Hello World（${SFV_APEX_HELLO} / ${SFV_APEX_HELLO_TEST}）を、各段階にリリースして、削除する" >&2
    echo "                 PR を $((n_tiers * 2)) 本（リリース ${n_tiers}・削除 ${n_tiers}）作成してマージする。組織のクラスと、リポジトリのファイルは、最後に消える" >&2
fi
if [[ $CLEANUP_ONLY -eq 0 ]]; then
    _env_items="SF_TOOLS_BRANCH・ログに Token が残っていないこと"
    [[ $NO_METASYNC -eq 1 ]] || _env_items+="・wf-metasync の実行"
    echo "    最初の確認 : 環境全体（${_env_items}）。NG があれば、リリースへ進みません" >&2
    if [[ $NO_METASYNC -eq 0 ]]; then
        echo "                 ※ wf-metasync は、Salesforce（main の組織）の変更を、main に同期します。変更があれば、main にコミットされます" >&2
    fi
fi
_est=$((n_tiers * (CLEANUP_ONLY == 1 ? 1 : 2) * 8))
[[ $CLEANUP_ONLY -eq 0 && $NO_METASYNC -eq 0 ]] && _est=$((_est + 5))
echo "    目安の時間 : 約 ${_est} 分" >&2
echo "    残るもの   : リポジトリに、PR・コミットの履歴。Slack に、通知（段階ごとに数通）" >&2

if [[ $PLAN_ONLY -eq 1 ]]; then
    log "INFO" "--plan のため、ここで終了します（何も変更していません）。"
    exit $RET_OK
fi

# ------------------------------------------------------------------------------
# 3. 確認（管理者向けの警告・Enter の確認。本番を含むときは、文面で明示する）
#    sf-init.sh から呼ばれたとき（SF_VERIFY_CONFIRMED=1）は、sf-init が、確認済みのため、二重には聞かない
# ------------------------------------------------------------------------------
if [[ "${SF_VERIFY_CONFIRMED:-}" != "1" ]]; then
    echo "" >&2
    echo -e "${CLR_ERR}╔══════════════════════════════════════════════════════╗${CLR_RESET}" >&2
    echo -e "${CLR_ERR}║  !!  実際のリポジトリと組織に、リリースします        ║${CLR_RESET}" >&2
    echo -e "${CLR_ERR}║      Hello World を、リリースして、削除します        ║${CLR_RESET}" >&2
    echo -e "${CLR_ERR}║      管理者以外は、実行しないでください              ║${CLR_RESET}" >&2
    echo -e "${CLR_ERR}╚══════════════════════════════════════════════════════╝${CLR_RESET}" >&2
    echo "" >&2
    # 確認は、Enter を 1 回押すだけ（q で中断）。入力を、最小にするため。本番を含むときは、文面で、明示する
    if [[ $NEED_PROD_CONFIRM -eq 1 ]]; then
        echo -e "  ${CLR_ERR}本番（または、種類を判定できない）組織に、Hello World を、リリースして、削除します。${CLR_RESET}" >&2
        wizard_confirm "本番の組織を含みます。Enter で、${REPO} の検証を始めます（q で中断）"
    else
        wizard_confirm "Enter で、${REPO} の検証を始めます（q で中断）"
    fi
fi

# ------------------------------------------------------------------------------
# 4・5. リリースと削除
# ------------------------------------------------------------------------------
OK_COUNT=0
NG_COUNT=0
FLAKY=0
declare -A LEFT=()   # 組織に、Hello World が残っている可能性のある段階（リリースの PR をマージしてから、削除が成功するまで）
STOPPED=0

# 1 件の確認: 説明 コマンド...
_vchk() {
    local desc="$1"; shift
    if "$@"; then
        log "SUCCESS" "  [OK] ${desc}"
        OK_COUNT=$((OK_COUNT + 1))
        return 0
    fi
    log "ERROR" "  [NG] ${desc}"
    NG_COUNT=$((NG_COUNT + 1))
    return 1
}

_slack_ok() { sfv_gh run view "$1" -R "$REPO" --log 2>/dev/null | grep -F "Slack response" | grep -q '"ok":true'; }

# 実行が成功したか。失敗したら、ログを表示し、1 回だけ再実行する（一時的な失敗への対策）。引数: 実行 ID ラベル
_run_ok() {
    local id="$1" label="$2" out line
    [[ "$(sfv_run_conclusion "$REPO" "$id")" == "success" ]] && return 0
    log "WARNING" "${label}: 失敗しました。失敗したステップのログ（末尾 30 行）:"
    out=$(sfv_gh run view "$id" -R "$REPO" --log-failed 2>/dev/null | sed -E 's/\x1b\[[0-9;]*m//g' | tail -n 30) || true  # VAR=$(cmd) のため run 不使用
    while IFS= read -r line; do printf '    %s\n' "$(_mask_secrets "$line")" >&2; done <<< "$out"
    log "WARNING" "${label}: 一時的な失敗の可能性があるため、1 回だけ再実行します。"
    sfv_rerun_and_wait "$REPO" "$id" || return 1
    if [[ "$(sfv_run_conclusion "$REPO" "$id")" == "success" ]]; then
        FLAKY=$((FLAKY + 1))
        log "WARNING" "${label}: 再実行で成功しました（一時的な失敗だった可能性があります）。"
        return 0
    fi
    return 1
}

# ワークフローの、ログインのステップ名（段階ごと）。文言を中立化する前に作られたリポジトリのワークフローは、古い名前
_login_step_names() {
    case "$1" in
        main)    printf '%s\n' "main の組織にログイン（JWT）" "本番組織にログイン（JWT）" ;;
        staging) printf '%s\n' "staging の組織にログイン（JWT）" "ステージング組織にログイン（JWT）" ;;
        develop) printf '%s\n' "develop の組織にログイン（JWT）" "開発組織にログイン（JWT）" ;;
    esac
}
# 段階のログインのステップの結果（success / skipped など）。見つからなければ、空。引数: 実行 ID 段階
#   名前の候補を、順に探す（見つからないものを、何度も待たないよう、1 回ずつ。全部なければ、反映の遅れに備えて、1 回だけ待って探す）
_login_conclusion() {
    local id="$1" t="$2" name c
    while IFS= read -r name; do
        c=$(SFV_CONCLUSION_TRIES=1 sfv_step_conclusion "$REPO" "$id" "$name")  # VAR=$(cmd) のため run 不使用
        if [[ -n "$c" ]]; then printf '%s' "$c"; return 0; fi
    done < <(_login_step_names "$t")
    name=$(_login_step_names "$t" | head -1)  # VAR=$(cmd) のため run 不使用
    sfv_step_conclusion "$REPO" "$id" "$name"
}

# 段階ごとの確認: その段階の組織に、入ったか（別の組織に、入っていないか）。引数: 段階 実行 ID 種類（リリース / 削除）
#   1. その段階の組織への JWT ログインが成功した
#   2. ほかの段階のログインのステップは、実行されていない（skipped）。別の組織に、ログインしていない
#   3. 接続ユーザー（SF_USERNAME_*）が登録されていて、ログに、そのユーザーが出ている
#   4. ログに、Hello World のクラス名が出ている
_evidence() {
    local t="$1" id="$2" kind="$3" user u c
    user=$(_var "SF_USERNAME_$(_suffix_of "$t")")
    _vchk "${kind}（${t}）: ${t} の組織への JWT ログインが成功した" test "$(_login_conclusion "$id" "$t")" == "success"
    for u in develop staging main; do
        [[ "$u" == "$t" ]] && continue
        c=$(_login_conclusion "$id" "$u")  # VAR=$(cmd) のため run 不使用
        if [[ -n "$c" ]]; then
            _vchk "${kind}（${t}）: ${u} の組織へのログインは、実行されていない（別の組織に入っていない）" test "$c" == "skipped"
        else
            log "WARNING" "  [注意] ${kind}（${t}）: ${u} のログインのステップを、見つけられませんでした（古いワークフローの可能性）。"
        fi
    done
    _vchk "${kind}（${t}）: ${t} の接続ユーザー（SF_USERNAME_$(_suffix_of "$t")）が、登録されている" test -n "$user"
    if [[ -n "$user" ]]; then
        _vchk "${kind}（${t}）: ログインしたユーザーが、${t} の接続ユーザー（${user}）と一致する" sfv_run_log_has "$REPO" "$id" "$user"
    fi
    _vchk "${kind}（${t}）: ログに、${SFV_APEX_HELLO} が出ている" sfv_run_log_has "$REPO" "$id" "$SFV_APEX_HELLO"
    if ! _slack_ok "$id"; then
        log "WARNING" "  [注意] ${kind}（${t}）: Slack への通知の成功（ok:true）を、確認できませんでした（検証の成否には、含めません）。"
    fi
}

# 失敗したときの案内
_guidance() {
    echo "" >&2
    log "ERROR" "検証を、途中で止めました。"
    if (( ${#LEFT[@]} > 0 )); then
        log "WARNING" "  Hello World が、次の段階の組織に、残っている可能性があります: ${!LEFT[*]}"
        log "WARNING" "  削除のみを、やり直すには、次を実行してください: sf-verify.sh --cleanup"
    fi
    log "WARNING" "  PR が残っているときは、GitHub の画面で、確認してください（https://github.com/${REPO}/pulls）。"
}

# PR → wf-validate → マージ → wf-release →（main のときだけ）wf-propagate。
#   成功したら、リリース（または削除）の実行 ID を FLOW_RUN に入れる。
#   引数: ラベル ブランチ タイトル 先の段階 種類（release / delete。release のとき、マージした時点で、その段階を LEFT に入れる）
FLOW_RUN=""
_pr_flow() {
    local label="$1" br="$2" title="$3" base="$4" mode="$5" prn runid b_val b_rel b_pro pid
    b_val=$(sfv_latest_run_id "$REPO" wf-validate.yml "$br")    # VAR=$(cmd) のため run 不使用
    b_rel=$(sfv_latest_run_id "$REPO" wf-release.yml "$br")     # VAR=$(cmd) のため run 不使用
    b_pro=$(sfv_latest_run_id "$REPO" wf-propagate.yml "$br")   # VAR=$(cmd) のため run 不使用
    prn=$(sfv_pr_create "$REPO" "$br" "$title" "sf-verify.sh による検証（Hello World）。" "$base") || prn=""  # VAR=$(cmd) のため run 不使用
    _vchk "${label}: PR を作成した（${base} 向け）" test -n "$prn" || return 1
    runid=$(sfv_wait_pr_run "$REPO" wf-validate.yml "$br" "$b_val") || runid=""   # VAR=$(cmd) のため run 不使用
    _vchk "${label}: wf-validate（検証）が実行され、完了した" test -n "$runid" || return 1
    _vchk "${label}: wf-validate が成功した" _run_ok "$runid" "${label}: wf-validate" || return 1
    _vchk "${label}: PR をマージした" sfv_pr_merge "$REPO" "$prn" || return 1
    [[ "$mode" == "release" ]] && LEFT["$base"]=1   # マージした時点から、組織に、クラスが入った可能性がある
    runid=$(sfv_wait_pr_run "$REPO" wf-release.yml "$br" "$b_rel") || runid=""    # VAR=$(cmd) のため run 不使用
    _vchk "${label}: wf-release が実行され、完了した" test -n "$runid" || return 1
    FLOW_RUN="$runid"
    _vchk "${label}: wf-release が成功した" _run_ok "$runid" "${label}: wf-release" || return 1
    if [[ "$base" == "main" ]]; then
        pid=$(sfv_wait_pr_run "$REPO" wf-propagate.yml "$br" "$b_pro") || pid=""   # VAR=$(cmd) のため run 不使用
        if _vchk "${label}: wf-propagate が実行され、完了した" test -n "$pid"; then
            _vchk "${label}: wf-propagate が成功した" _run_ok "$pid" "${label}: wf-propagate" || true  # 失敗しても、続きの確認は進める
        fi
    fi
    return 0
}

# リリース用のブランチを作る（main の先頭から。クラスのファイルと、リリース対象）。引数: ブランチ
_make_release_branch() {
    local br="$1" sha p
    sha=$(sfv_branch_sha "$REPO" main)  # VAR=$(cmd) のため run 不使用
    [[ -n "$sha" ]] || return 1
    sfv_branch_create "$REPO" "$br" "$sha" || return 1
    while IFS= read -r p; do
        sfv_hello_content_for "$p" | sfv_file_put "$REPO" "$br" "$p" "verify: Hello World を追加" || return 1
    done < <(sfv_hello_paths)
    sfv_hello_deploy_target_text | sfv_file_put "$REPO" "$br" "sf-tools/release/${br}/deploy-target.txt" "verify: リリース対象" || return 1
    sfv_empty_target_text        | sfv_file_put "$REPO" "$br" "sf-tools/release/${br}/remove-target.txt" "verify: 削除対象（なし）" || return 1
}
# 削除用のブランチを作る（main の先頭から。クラスのファイルの削除と、削除対象）。引数: ブランチ
_make_delete_branch() {
    local br="$1" sha p
    sha=$(sfv_branch_sha "$REPO" main)  # VAR=$(cmd) のため run 不使用
    [[ -n "$sha" ]] || return 1
    sfv_branch_create "$REPO" "$br" "$sha" || return 1
    while IFS= read -r p; do
        sfv_file_delete "$REPO" "$br" "$p" "verify: Hello World を削除" || return 1
    done < <(sfv_hello_paths)
    sfv_empty_target_text         | sfv_file_put "$REPO" "$br" "sf-tools/release/${br}/deploy-target.txt" "verify: リリース対象（なし）" || return 1
    sfv_hello_remove_target_text  | sfv_file_put "$REPO" "$br" "sf-tools/release/${br}/remove-target.txt" "verify: 削除対象" || return 1
}

# 環境全体の確認（リリースの前に行う。NG があれば、リリースへ進まない: 組織に、何も変更していない状態で止まる）
# ローカルのログに、Token・認証 URL が、残っていないこと（sf-init・sf-verify などのログ）
_logs_clean() {
    local f found=0
    for f in "$HOME"/sf-tools/logs/*.log; do
        [[ -f "$f" ]] || continue
        if grep -qE 'ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[bp]-[0-9A-Za-z-]{20,}|force://[^[:space:]]*:[^[:space:]]*:[^@[:space:]]{20,}@' "$f" 2>/dev/null; then
            log "ERROR" "    Token（または認証 URL）らしい文字列が、ログに残っています: ${f}"
            found=1
        fi
    done
    [[ $found -eq 0 ]]
}
_tools_branch_ok() {
    local v
    v=$(_var SF_TOOLS_BRANCH)  # VAR=$(cmd) のため run 不使用
    log "INFO" "    SF_TOOLS_BRANCH = ${v:-（未設定）}"
    [[ "$v" == "main" || "$v" == "development" ]]
}
# wf-metasync を、手動で 1 回実行して、成功を確認する（JWT ログイン・sf-tools の取得を含む）
_metasync_check() {
    local id
    id=$(sfv_dispatch_workflow "$REPO" wf-metasync.yml main) || id=""  # VAR=$(cmd) のため run 不使用
    _vchk "環境（wf-metasync）: 起動した" test -n "$id" || return 1
    _vchk "環境（wf-metasync）: 完了した" sfv_wait_run "$REPO" "$id" || return 1
    _vchk "環境（wf-metasync）: 成功した（Salesforce → Git の同期）" _run_ok "$id" "wf-metasync" || return 1
    _vchk "環境（wf-metasync）: Salesforce 組織への JWT ログインが成功した" \
        test "$(sfv_step_conclusion "$REPO" "$id" "Salesforce 組織にログイン")" == "success"
    _vchk "環境（wf-metasync）: sf-tools の取得が成功した（公開リポジトリを、Token なしで clone）" \
        test "$(sfv_step_conclusion "$REPO" "$id" "自動化ツール（sf-tools）を取得")" == "success"
}

STAMP=$(date +%H%M%S)  # VAR=$(cmd) のため run 不使用
JOB_RELEASE="verify-hello-${STAMP}"
JOB_DELETE="verify-hello-delete-${STAMP}"

if [[ $CLEANUP_ONLY -eq 0 ]]; then
    log "HEADER" "環境の確認"
    # 環境の確認で、NG があれば、そこで止める。組織・リポジトリに、何も変更しない状態で終わる
    #   （wf-metasync は、組織の変更を main にコミットすることがあるため、手前の確認が、すべて OK のときだけ実行する）
    _env_stop_if_ng() {
        [[ $NG_COUNT -eq 0 ]] && return 0
        echo "" >&2
        log "ERROR" "環境の確認で、NG があります。これ以上は、進みません（リリースも、wf-metasync も、行っていません）。"
        log "WARNING" "  上の [NG] を直してから、もう一度、実行してください。"
        exit $RET_NG
    }
    _vchk "環境: SF_TOOLS_BRANCH が、main または development である" _tools_branch_ok || true
    _vchk "環境: ローカルのログに、Token・認証 URL が残っていない" _logs_clean || true
    _env_stop_if_ng
    if [[ $NO_METASYNC -eq 0 ]]; then
        _metasync_check || true
    else
        log "INFO" "  wf-metasync の実行は、省略しました（--no-metasync）。"
    fi
    _env_stop_if_ng
    log "HEADER" "リリース（${TIERS[*]}）"
    if _vchk "リリース用のブランチ ${JOB_RELEASE} を作成した（クラスのファイルとリリース対象）" _make_release_branch "$JOB_RELEASE"; then
        for t in "${TIERS[@]}"; do
            if _pr_flow "リリース（${t}）" "$JOB_RELEASE" "verify: Hello World をリリース" "$t" release; then
                _evidence "$t" "$FLOW_RUN" "リリース" || true  # 確認の失敗は、記録して、続きを進める（削除まで行って、組織を、元に戻すため）
            else
                STOPPED=1
                break
            fi
        done
    else
        STOPPED=1
    fi
    if [[ $STOPPED -eq 1 ]]; then
        _guidance
        exit $RET_NG
    fi
fi

log "HEADER" "削除（${TIERS[*]}）"
# --cleanup のときは、どの段階に残っているか分からないため、すべての段階を、対象にする
[[ $CLEANUP_ONLY -eq 1 ]] && for t in "${TIERS[@]}"; do LEFT["$t"]=1; done
if _vchk "削除用のブランチ ${JOB_DELETE} を作成した（クラスのファイルの削除と削除対象）" _make_delete_branch "$JOB_DELETE"; then
    for t in "${TIERS[@]}"; do
        if _pr_flow "削除（${t}）" "$JOB_DELETE" "verify: Hello World を削除" "$t" delete; then
            _evidence "$t" "$FLOW_RUN" "削除" || true
            unset 'LEFT[$t]'   # この段階のクラスは、消えた
        else
            STOPPED=1
            break
        fi
    done
else
    STOPPED=1
fi
if [[ $STOPPED -eq 1 ]]; then
    _guidance
    exit $RET_NG
fi

# ------------------------------------------------------------------------------
# 6. 結果
# ------------------------------------------------------------------------------
echo "" >&2
log "HEADER" "結果"
log "INFO" "  確認: ${OK_COUNT} 件成功 / ${NG_COUNT} 件失敗"
(( FLAKY > 0 )) && log "WARNING" "  再実行で成功したワークフローが ${FLAKY} 件あります（一時的な失敗の可能性）。"
if [[ $NG_COUNT -eq 0 ]]; then
    log "SUCCESS" "検証: すべて成功しました。${REPO} は、段階ごとの組織に対して、リリースと削除が動いています。"
    exit $RET_OK
fi
log "ERROR" "検証: 失敗した確認があります（上の [NG] を確認してください）。"
exit $RET_NG
