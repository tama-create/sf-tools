#!/bin/bash
# ==============================================================================
# scenario.sh - e2e のシナリオ方式（実環境の L2。シナリオを 1 つずつ、短く動かす）
# ==============================================================================
# run.sh（sf-init の通し検証）が前回残したテスト用リポジトリを使い、名前で選んだシナリオだけを実行する。
# 通常のテスト（bash tests/run_tests.sh）には含まれない。実環境を使うため、開発者（Claude）が手元で実行する。
# 設計: doc/integration-test-plan.md の 11
#
# 【使い方】
#   bash tests/e2e/scenario.sh --list              # シナリオの一覧（実環境に接続しない）
#   bash tests/e2e/scenario.sh log-secrets         # 名前で選んで実行する（複数指定可。名前なしは、何も実行しない）
#
# 【処理の流れ】
#   1. 前提の確認  : 鍵一式・gh のログインユーザー（既存のガード）。前回残したテスト用リポジトリ（最新の 1 つ。
#                    名前の形式とオーナーが一致するものだけ）が、GitHub にあること。なければ、run.sh で作るよう案内して終わる
#                    （シナリオ側では、リポジトリを、黙って作らない）
#   2. 状態の記録  : 実行の前に、main の SHA・ブランチの一覧・PR の数を記録する
#   3. 実行        : シナリオごとに、確認して、結果（成功 / 失敗 / 実行できない）と所要時間を表示する
#   4. 状態の確認  : 実行のあとに、2 と比べる。差があれば、報告して、後続のシナリオを実行しない
#   5. 結果        : 1 シナリオ = 1 行。失敗があれば、終了コード 1。「実行できない」は、成功に数えない
#
# 【シナリオ】（--list でも表示する）
#   log-secrets    : 直近の Actions の実行ログと PR のコメントに、PAT・Slack の Token・認証 URL・秘密鍵が出ていない（読み取りのみ）
#   manual-delete  : テスト用リポジトリの Secret（SLACK_BOT_TOKEN）と Variable（SLACK_CHANNEL_ID）を、手で削除 → sf-init.sh --status が
#                    不足を見つけ、直し方を示す → 元に戻す → 診断が、元に戻る（書き込みあり。終了時に、必ず元に戻す）
#
# 【安全】
#   ・既存の安全ガード（テスト用リポジトリの名前の形式・オーナーの一致）を、必ず通す。削除の経路は、持たない
#   ・書き込みを行うシナリオは、冒頭の警告に、書き込む内容を明記する（_scn_writes）。書き込んだものは、終了時（中断・異常終了を含む）に、
#     必ず元に戻す（_scn_restore）。元の値を読めない Secret は、鍵一式の値で戻せるものだけを、対象にする
#   ・秘密の値は、表示しない（見つかった「種類」だけを表示する）
#
# 【オプション】
#   --list        : シナリオの一覧を表示して終わる
#   -y, --yes     : 開始の確認を省略する
#   -h, --help    : このヘルプを表示する
# ==============================================================================

readonly SCRIPT_NAME="e2e-scenario"
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true  # run 不使用: ログフォルダの準備（log が使える前の処理）
readonly LOG_FILE="$HOME/sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"

export SF_INIT_MODE=1   # プロジェクト外から実行するため、force-* チェックをバイパスする
E2E_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_TOOLS_ROOT="$(cd "${E2E_SCRIPT_DIR}/../.." && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}"
    exit 0
fi

source "${SF_TOOLS_ROOT}/lib/common.sh"
source "${E2E_SCRIPT_DIR}/lib.sh"

# ------------------------------------------------------------------------------
# 1. シナリオの一覧
# ------------------------------------------------------------------------------
SCENARIO_NAMES="log-secrets manual-delete"   # 実行の順番どおり
_scn_desc() {
    case "$1" in
        log-secrets)   echo "Actions のログ・PR のコメントに、秘密情報が出ていない（読み取りのみ）" ;;
        manual-delete) echo "Secret・Variable を手で削除 → --status が見つけ、直し方を示す → 元に戻す（書き込みあり）" ;;
        *) echo "" ;;
    esac
}
# 書き込みを行うシナリオが、書き込む内容（なければ空）。開始の警告に表示する
_scn_writes() {
    case "$1" in
        manual-delete) echo "Secret（SLACK_BOT_TOKEN）と Variable（SLACK_CHANNEL_ID）を、一時的に削除し、すぐに元に戻します" ;;
        *) echo "" ;;
    esac
}
_scn_known() { local n; for n in $SCENARIO_NAMES; do [[ "$n" == "$1" ]] && return 0; done; return 1; }
_scn_list() {
    local n
    for n in $SCENARIO_NAMES; do printf '  %-14s %s\n' "$n" "$(_scn_desc "$n")"; done
}

SELECTED=()
ASSUME_YES=0
LIST_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)    LIST_ONLY=1 ;;
        -y|--yes)  ASSUME_YES=1 ;;
        -*)        die "不明なオプションです: $1" ;;
        *)         _scn_known "$1" || die "不明なシナリオです: $1（--list で一覧を表示できます）"
                   SELECTED+=("$1") ;;
    esac
    shift
done

if [[ $LIST_ONLY -eq 1 ]]; then
    echo "シナリオ（run.sh が前回残したテスト用リポジトリに対して、実行します）:"
    _scn_list
    exit $RET_OK
fi
if [[ ${#SELECTED[@]} -eq 0 ]]; then
    echo "シナリオ名を指定してください（何も実行していません）。一覧:"
    _scn_list
    exit $RET_OK
fi

# ------------------------------------------------------------------------------
# 2. 前提の確認（既存のガード → テスト用リポジトリ）
# ------------------------------------------------------------------------------
e2e_load_fixture
e2e_guard_env

log "HEADER" "e2e のシナリオを開始します (${SCRIPT_NAME}.sh): ${SELECTED[*]}"
PROJECT=$(e2e_find_latest_project) \
    || die "シナリオを実行できるテスト用の作業フォルダがありません（${E2E_HOME_ROOT}/${E2E_OWNER}/e2e-日時）。先に、bash tests/e2e/run.sh --no-add-tier で、テスト用リポジトリを作ってください。"  # VAR=$(cmd) のため run 不使用
REPO_NAME="force-${PROJECT}"
REPO_FULL="${E2E_OWNER}/${REPO_NAME}"
_e2e_check_repo "$REPO_FULL"
_e2e_gh repo view "$REPO_FULL" >/dev/null 2>&1 \
    || die "テスト用のリポジトリが GitHub にありません: ${REPO_FULL}（先に、bash tests/e2e/run.sh --no-add-tier で作ってください）"  # 戻り値で判定するため run 不使用

if [[ $ASSUME_YES -eq 0 && "${GITHUB_ACTIONS:-}" != "true" ]]; then
    _warn=()
    for name in "${SELECTED[@]}"; do
        _w=$(_scn_writes "$name")  # VAR=$(cmd) のため run 不使用
        [[ -z "$_w" ]] || _warn+=("    書き込み（${name}）: ${_w}")
    done
    if [[ ${#_warn[@]} -gt 0 ]]; then
        print_admin_warning "!!  実際の GitHub に、書き込みます" "    対象: ${REPO_FULL}（テスト用。名前の形式・オーナーを確認済み）" "${_warn[@]}" "    終了時（中断を含む）に、必ず元に戻します"
    else
        print_admin_warning "!!  実際の GitHub を操作します（読み取りのみ）" "    対象: ${REPO_FULL}（テスト用。名前の形式・オーナーを確認済み）" "    シナリオ: ${SELECTED[*]}"
    fi
    ask_yn "続行しますか？" || die "中断しました。"
fi

# ------------------------------------------------------------------------------
# 元に戻す（書き込むシナリオが、削除したものを戻す。終了時に、必ず動く）
# ------------------------------------------------------------------------------
RESTORE_SECRET=""      # 削除中の Secret の名前（戻したら空にする。値は、鍵一式から戻す）
RESTORE_VAR_NAME=""    # 削除中の Variable の名前
RESTORE_VAR_VALUE=""   # その元の値
_scn_restore() {
    local rc=0
    if [[ -n "$RESTORE_SECRET" ]]; then
        # Secret の値は、読めない。鍵一式の値で戻せる SLACK_BOT_TOKEN だけを、削除の対象にしている
        if printf '%s' "$E2E_SLACK_BOT_TOKEN" | _e2e_gh secret set "$RESTORE_SECRET" -R "$REPO_FULL" >/dev/null 2>&1; then
            log "INFO" "  元に戻しました: Secret ${RESTORE_SECRET}"; RESTORE_SECRET=""
        else
            log "ERROR" "  Secret ${RESTORE_SECRET} を、元に戻せませんでした（${REPO_FULL}）。手で、gh secret set ${RESTORE_SECRET} -R ${REPO_FULL} を実行してください。"; rc=1
        fi
    fi
    if [[ -n "$RESTORE_VAR_NAME" ]]; then
        if _e2e_gh variable set "$RESTORE_VAR_NAME" -R "$REPO_FULL" --body "$RESTORE_VAR_VALUE" >/dev/null 2>&1; then
            log "INFO" "  元に戻しました: Variable ${RESTORE_VAR_NAME}"; RESTORE_VAR_NAME=""; RESTORE_VAR_VALUE=""
        else
            log "ERROR" "  Variable ${RESTORE_VAR_NAME} を、元に戻せませんでした（${REPO_FULL}）。元の値: ${RESTORE_VAR_VALUE}"; rc=1
        fi
    fi
    return $rc
}
trap _scn_restore EXIT

# ------------------------------------------------------------------------------
# 3. 状態の記録と比較（シナリオが、リポジトリの状態を変えていないこと）
# ------------------------------------------------------------------------------
# 出力: main の SHA・ブランチの一覧・PR の数（1 行ずつ）。取得に失敗したら、戻り値 1
_scn_state() {
    local sha br prs
    sha=$(_e2e_gh api "repos/${REPO_FULL}/git/ref/heads/main" --jq .object.sha 2>/dev/null) || return 1  # VAR=$(cmd) のため run 不使用
    br=$(_e2e_gh api "repos/${REPO_FULL}/branches" --paginate --jq '.[].name' 2>/dev/null) || return 1  # VAR=$(cmd) のため run 不使用
    br=$(printf '%s\n' "$br" | sort | tr '\n' ',')  # パイプのみのため run 不使用
    prs=$(_e2e_gh pr list -R "$REPO_FULL" --state all --limit 200 --json number --jq 'length' 2>/dev/null) || return 1  # VAR=$(cmd) のため run 不使用
    printf 'main=%s\nbranches=%s\nprs=%s\n' "$sha" "$br" "$prs"
}

# ------------------------------------------------------------------------------
# 4. シナリオ
# ------------------------------------------------------------------------------
# 各シナリオは、確認を _chk で数え、「実行できない」ときは SCN_SKIP に理由を入れる
SCN_PASS=0
SCN_FAIL=0
SCN_SKIP=""
_chk() {   # 引数: 説明 結果(0=成功) [失敗の詳細]
    if [[ "$2" -eq 0 ]]; then
        SCN_PASS=$((SCN_PASS + 1)); log "SUCCESS" "  [OK] $1"
    else
        SCN_FAIL=$((SCN_FAIL + 1)); log "ERROR" "  [NG] $1${3:+ → $3}"
    fi
}

# log-secrets: 直近の Actions の実行ログと、PR のコメント・本文に、秘密情報が出ていない
#   検査できなかったもの（実行が 0 件・ログが空）は、成功にしない（実行できないとして報告する）
scn_log_secrets() {
    local max="${E2E_LOG_RUNS:-10}" ids id n_runs=0 n_prs=0 kinds log pr_ids n
    ids=$(_e2e_gh run list -R "$REPO_FULL" --limit "$max" --json databaseId --jq '.[].databaseId' 2>/dev/null) \
        || { SCN_SKIP="Actions の実行の一覧を取得できません"; return; }  # VAR=$(cmd) のため run 不使用
    pr_ids=$(_e2e_gh pr list -R "$REPO_FULL" --state all --limit 30 --json number --jq '.[].number' 2>/dev/null) \
        || { SCN_SKIP="PR の一覧を取得できません"; return; }  # VAR=$(cmd) のため run 不使用
    for id in $ids; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        log=$(_e2e_gh run view "$id" -R "$REPO_FULL" --log 2>/dev/null) || continue  # VAR=$(cmd) のため run 不使用
        [[ -n "$log" ]] || continue
        n_runs=$((n_runs + 1))
        if kinds=$(printf '%s' "$log" | e2e_scan_secrets); then   # 条件チェック（出力は、見つかった種類の名前だけ）
            _chk "実行 ${id} のログに、秘密情報が出ていない" 0
        else
            _chk "実行 ${id} のログに、秘密情報が出ていない" 1 "見つかった種類: $(printf '%s' "$kinds" | tr '\n' ' ')"
        fi
    done
    for n in $pr_ids; do
        [[ "$n" =~ ^[0-9]+$ ]] || continue
        log=$(_e2e_gh pr view "$n" -R "$REPO_FULL" --json body,comments --jq '[.body, (.comments[].body)] | join("\n---\n")' 2>/dev/null) || continue  # VAR=$(cmd) のため run 不使用
        n_prs=$((n_prs + 1))
        if kinds=$(printf '%s' "$log" | e2e_scan_secrets); then   # 条件チェック
            _chk "PR #${n} の本文・コメントに、秘密情報が出ていない" 0
        else
            _chk "PR #${n} の本文・コメントに、秘密情報が出ていない" 1 "見つかった種類: $(printf '%s' "$kinds" | tr '\n' ' ')"
        fi
    done
    if [[ $n_runs -eq 0 ]]; then
        SCN_SKIP="検査できる Actions のログがありません（実行が 0 件、またはログを取得できません。run.sh を、--no-actions なしで実行すると、できます）"
        return
    fi
    log "INFO" "  検査した範囲: Actions の実行 ${n_runs} 件・PR ${n_prs} 件"
}

# manual-delete: Secret・Variable を手で削除 → sf-init.sh --status が、不足を見つけ、直し方を示す → 元に戻す → 診断が、元に戻る
#   --status は、管理者用のクローン（admin/force-XXXX）で実行する（E2E_SF_INIT: 実行する sf-init.sh を差し替える。テスト用）。もともと診断が通らないとき（不足がある）は、確認の意味がないため、実行できないとする
_scn_status() {   # 出力を SCN_STATUS_OUT に入れ、戻り値は --status の終了コード
    local admin="${E2E_HOME_ROOT}/${E2E_OWNER}/${PROJECT}/admin/${REPO_NAME}"
    SCN_STATUS_OUT=$( cd "$admin" && printf 'Y\n' | bash "${E2E_SF_INIT:-${SF_TOOLS_ROOT}/bin/sf-init.sh}" --status 2>&1 | _strip_ansi; exit "${PIPESTATUS[1]}" )  # VAR=$(cmd) のため run 不使用
}
_scn_names() {   # 引数: secret|variable。名前の一覧（並べ替えて、カンマ区切り）
    local out
    out=$(_e2e_gh "$1" list -R "$REPO_FULL" --json name --jq '.[].name' 2>/dev/null) || return 1  # VAR=$(cmd) のため run 不使用
    printf '%s\n' "$out" | sort | tr '\n' ','  # パイプのみのため run 不使用
}
scn_manual_delete() {
    local admin="${E2E_HOME_ROOT}/${E2E_OWNER}/${PROJECT}/admin/${REPO_NAME}"
    local secrets_before vars_before saved i rc
    [[ -d "${admin}/.git" ]] || { SCN_SKIP="管理者用のクローンがありません（${admin}）。run.sh で、リポジトリを作り直してください"; return; }
    _scn_status; rc=$?
    [[ $rc -eq 0 ]] || { SCN_SKIP="もともと、診断（--status）が、不足を報告しています（終了コード ${rc}）。確認の前提が、満たされていません"; return; }
    secrets_before=$(_scn_names secret) || { SCN_SKIP="Secret の一覧を取得できません"; return; }  # VAR=$(cmd) のため run 不使用
    vars_before=$(_scn_names variable) || { SCN_SKIP="Variable の一覧を取得できません"; return; }  # VAR=$(cmd) のため run 不使用
    [[ "$secrets_before" == *SLACK_BOT_TOKEN* && "$vars_before" == *SLACK_CHANNEL_ID* ]] \
        || { SCN_SKIP="削除する対象（Secret SLACK_BOT_TOKEN・Variable SLACK_CHANNEL_ID）が、リポジトリにありません"; return; }
    saved=$(_e2e_gh variable get SLACK_CHANNEL_ID -R "$REPO_FULL" 2>/dev/null | tr -d '\r')  # パイプのみのため run 不使用
    [[ -n "$saved" ]] || { SCN_SKIP="Variable SLACK_CHANNEL_ID の値を、読み取れません"; return; }

    # --- Secret を削除 → 検出 ---
    RESTORE_SECRET="SLACK_BOT_TOKEN"   # 削除の前に登録する（途中で止まっても、終了時に戻す）
    _e2e_gh secret delete SLACK_BOT_TOKEN -R "$REPO_FULL" >/dev/null 2>&1; _chk "Secret SLACK_BOT_TOKEN を削除した" $?
    rc=0
    for (( i = 1; i <= ${E2E_STATUS_TRIES:-5}; i++ )); do
        _scn_status; rc=$?
        [[ $rc -ne 0 ]] && break
        sleep "${E2E_POLL_SEC:-5}"  # run 不使用: 反映の待機
    done
    _chk "Secret を削除すると、--status が、不足として終了する（終了コード ${rc}）" "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"
    printf '%s' "$SCN_STATUS_OUT" | grep -q "✗.*SLACK_BOT_TOKEN"; _chk "不足の一覧に、SLACK_BOT_TOKEN が出る" $?
    printf '%s' "$SCN_STATUS_OUT" | grep -q "sf-init.sh --only 7"; _chk "直し方（sf-init.sh --only 7）が、表示される" $?
    printf '%s' "$SCN_STATUS_OUT" | e2e_scan_secrets >/dev/null; _chk "--status の出力に、秘密情報が出ていない" $?   # e2e_scan_secrets は、含まれていなければ 0
    _scn_restore; _chk "Secret SLACK_BOT_TOKEN を、元に戻した" $?
    _scn_status; rc=$?; _chk "戻すと、--status が、不足なしに戻る（終了コード ${rc}）" $rc

    # --- Variable を削除 → 検出 ---
    RESTORE_VAR_NAME="SLACK_CHANNEL_ID"; RESTORE_VAR_VALUE="$saved"
    _e2e_gh variable delete SLACK_CHANNEL_ID -R "$REPO_FULL" >/dev/null 2>&1; _chk "Variable SLACK_CHANNEL_ID を削除した" $?
    rc=0
    for (( i = 1; i <= ${E2E_STATUS_TRIES:-5}; i++ )); do
        _scn_status; rc=$?
        [[ $rc -ne 0 ]] && break
        sleep "${E2E_POLL_SEC:-5}"  # run 不使用: 反映の待機
    done
    _chk "Variable を削除すると、--status が、不足として終了する（終了コード ${rc}）" "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"
    printf '%s' "$SCN_STATUS_OUT" | grep -q "✗.*SLACK_CHANNEL_ID"; _chk "不足の一覧に、SLACK_CHANNEL_ID が出る" $?
    _scn_restore; _chk "Variable SLACK_CHANNEL_ID を、元に戻した" $?
    _scn_status; rc=$?; _chk "戻すと、--status が、不足なしに戻る（終了コード ${rc}）" $rc

    # --- 元の状態に戻ったこと（名前の一覧と、Variable の値）---
    _chk "Secret の名前の一覧が、実行前と同じ" "$([[ "$(_scn_names secret)" == "$secrets_before" ]] && echo 0 || echo 1)"
    _chk "Variable の名前の一覧が、実行前と同じ" "$([[ "$(_scn_names variable)" == "$vars_before" ]] && echo 0 || echo 1)"
    _chk "Variable SLACK_CHANNEL_ID の値が、実行前と同じ" "$([[ "$(_e2e_gh variable get SLACK_CHANNEL_ID -R "$REPO_FULL" 2>/dev/null | tr -d '\r')" == "$saved" ]] && echo 0 || echo 1)"
}

# ------------------------------------------------------------------------------
# 5. 実行
# ------------------------------------------------------------------------------
STATE_BEFORE=$(_scn_state) || die "実行前の状態（main の SHA・ブランチ・PR）を取得できないため、中断します。"  # VAR=$(cmd) のため run 不使用
FAILED_ANY=0
SUMMARY=()
for name in "${SELECTED[@]}"; do
    log "HEADER" "シナリオ: ${name}（$(_scn_desc "$name")）"
    SCN_PASS=0; SCN_FAIL=0; SCN_SKIP=""
    t0=$SECONDS
    "scn_${name//-/_}"
    secs=$(( SECONDS - t0 ))
    if [[ -n "$SCN_SKIP" ]]; then
        result="実行できない（${SCN_SKIP}）"; FAILED_ANY=1
    elif [[ $SCN_FAIL -gt 0 ]]; then
        result="失敗（${SCN_PASS} 件成功 / ${SCN_FAIL} 件失敗）"; FAILED_ANY=1
    elif [[ $SCN_PASS -eq 0 ]]; then
        result="失敗（確認が 0 件。何も検査していません）"; FAILED_ANY=1
    else
        result="成功（${SCN_PASS} 件）"
    fi
    SUMMARY+=("${name}: ${result} — ${secs} 秒")

    # 状態の確認: シナリオが、リポジトリの状態を変えていないこと。差があれば、後続を実行しない
    STATE_AFTER=$(_scn_state) || STATE_AFTER="取得できません"  # VAR=$(cmd) のため run 不使用
    if [[ "$STATE_AFTER" != "$STATE_BEFORE" ]]; then
        log "ERROR" "シナリオ ${name} の前後で、リポジトリの状態（main の SHA・ブランチ・PR の数）が変わりました。後続のシナリオは、実行しません。"
        log "ERROR" "  前: $(printf '%s' "$STATE_BEFORE" | tr '\n' ' ')"
        log "ERROR" "  後: $(printf '%s' "$STATE_AFTER" | tr '\n' ' ')"
        FAILED_ANY=1
        SUMMARY+=("（状態が変わったため、以降のシナリオは実行していません）")
        break
    fi
done

# ------------------------------------------------------------------------------
# 6. 結果
# ------------------------------------------------------------------------------
echo "" >&2
log "HEADER" "結果（${REPO_FULL}）"
for line in "${SUMMARY[@]}"; do log "INFO" "  ${line}"; done
if [[ $FAILED_ANY -eq 0 ]]; then
    log "SUCCESS" "e2e のシナリオ: すべて成功しました。"
    log "INFO" "検証の記録（成功したときだけ、doc/dev-reference.md 9.7 の表に追記する）:"
    e2e_record_line "e2e シナリオ ${SELECTED[*]} が成功"
    exit $RET_OK
fi
die "e2e のシナリオ: 失敗、または実行できないものがあります。"
