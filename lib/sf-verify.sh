#!/bin/bash
# ==============================================================================
# sf-verify.sh（lib）- リポジトリの検証（sf-verify.sh）と、e2e が共有する部品
# ==============================================================================
# Hello World の Apex（本文）・GitHub での PR の作成とマージ・ワークフローの実行の待ち・結果の読み取り。
# sf-verify.sh（管理者が、実際のリポジトリで実行する）と、tests/e2e（開発者の通し検証）が、同じ部品を使う。
# ここの関数は、リポジトリを、引数で受け取る。「どのリポジトリを操作してよいか」の安全ガードは、呼び出し側が行う。
#
# 【環境変数（任意）】
#   SFV_GH_TIMEOUT      gh 1 回の時間の上限（秒。既定 120。E2E_GH_TIMEOUT も使える）
#   SFV_POLL_SEC        確認の間隔（秒。既定 5。E2E_POLL_SEC も使える）
#   SFV_WF_TIMEOUT      ワークフローの完了を待つ上限（秒。既定 1200。E2E_WF_TIMEOUT も使える）
#   SFV_RUN_FIND_TRIES  ワークフローの起動を待つ回数（既定 24。E2E_RUN_FIND_TRIES も使える）
#   SFV_CONCLUSION_TRIES 結果の読み取りのやり直しの回数（既定 6。E2E_CONCLUSION_TRIES も使える）
# ==============================================================================

# Hello World の Apex のクラス名（誰も使わない、単純なもの。リリースして、すぐ削除する）
SFV_APEX_HELLO="SfToolsE2eHello"
SFV_APEX_HELLO_TEST="SfToolsE2eHelloTest"

# ------------------------------------------------------------------------------
# Hello World の本文
# ------------------------------------------------------------------------------
sfv_hello_cls() {
    printf '%s\n' "public with sharing class ${SFV_APEX_HELLO} {" \
        "    public static String hello() {" \
        "        return 'Hello, World!';" \
        "    }" \
        "}"
}
sfv_hello_test_cls() {
    printf '%s\n' "@isTest" \
        "private class ${SFV_APEX_HELLO_TEST} {" \
        "    @isTest" \
        "    static void helloReturnsGreeting() {" \
        "        System.assertEquals('Hello, World!', ${SFV_APEX_HELLO}.hello());" \
        "    }" \
        "}"
}
sfv_apex_meta() {
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
        '<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata">' \
        '    <apiVersion>64.0</apiVersion>' \
        '    <status>Active</status>' \
        '</ApexClass>'
}
# クラスのファイルの一覧（リポジトリの中のパス）
sfv_hello_paths() {
    printf '%s\n' \
        "force-app/main/default/classes/${SFV_APEX_HELLO}.cls" \
        "force-app/main/default/classes/${SFV_APEX_HELLO}.cls-meta.xml" \
        "force-app/main/default/classes/${SFV_APEX_HELLO_TEST}.cls" \
        "force-app/main/default/classes/${SFV_APEX_HELLO_TEST}.cls-meta.xml"
}
# パスに対応する本文
sfv_hello_content_for() {
    case "$1" in
        *"/${SFV_APEX_HELLO_TEST}.cls")      sfv_hello_test_cls ;;
        *"/${SFV_APEX_HELLO}.cls")           sfv_hello_cls ;;
        *".cls-meta.xml")                    sfv_apex_meta ;;
        *) return 1 ;;
    esac
}
# deploy-target.txt / remove-target.txt の本文
sfv_hello_deploy_target_text() {
    printf '%s\n' '[files]' \
        "force-app/main/default/classes/${SFV_APEX_HELLO}.cls" \
        "force-app/main/default/classes/${SFV_APEX_HELLO_TEST}.cls" \
        '' '[members]'
}
sfv_hello_remove_target_text() {
    printf '%s\n' '[files]' '' '[members]' \
        "ApexClass:${SFV_APEX_HELLO_TEST}" \
        "ApexClass:${SFV_APEX_HELLO}"
}
# 内容のない（雛形のままの）リリース対象
sfv_empty_target_text() { printf '%s\n' '[files]' '' '[members]'; }

# ------------------------------------------------------------------------------
# gh（時間の上限つき。標準入力は読ませない）
# ------------------------------------------------------------------------------
sfv_gh() {
    local t="${SFV_GH_TIMEOUT:-${E2E_GH_TIMEOUT:-120}}"
    if command -v timeout >/dev/null 2>&1; then  # 存在確認のため run 不使用
        timeout "$t" gh "$@" </dev/null
    else
        gh "$@" </dev/null
    fi
}
_sfv_poll()  { printf '%s' "${SFV_POLL_SEC:-${E2E_POLL_SEC:-5}}"; }
_sfv_tries() { printf '%s' "${SFV_CONCLUSION_TRIES:-${E2E_CONCLUSION_TRIES:-6}}"; }

# ------------------------------------------------------------------------------
# PR の作成・マージ
# ------------------------------------------------------------------------------
# PR を作成し、番号を標準出力に返す。失敗したら、戻り値 1。引数: リポジトリ head ブランチ タイトル [本文] [base（既定 main）]
sfv_pr_create() {
    local repo="$1" head="$2" title="$3" body="${4:-sf-tools の検証（自動作成）。}" base="${5:-main}" out
    out=$(sfv_gh pr create -R "$repo" --base "$base" --head "$head" --title "$title" --body "$body" 2>/dev/null) || return 1  # VAR=$(cmd) のため run 不使用
    printf '%s\n' "$out" | grep -oE '[0-9]+$' | tail -1
}
# PR をマージする（マージコミット。ブランチは削除しない）。引数: リポジトリ PR 番号
sfv_pr_merge() { sfv_gh pr merge "$2" -R "$1" --merge >/dev/null 2>&1; }  # 戻り値で判定するため run 不使用
# PR を、マージせずに閉じる。引数: リポジトリ PR 番号
sfv_pr_close() { sfv_gh pr close "$2" -R "$1" >/dev/null 2>&1; }          # 戻り値で判定するため run 不使用

# ------------------------------------------------------------------------------
# ワークフローの実行
# ------------------------------------------------------------------------------
# PR のイベントで起動した、ワークフローの最新の実行の ID を、標準出力に返す（なければ 0）。
#   同じブランチから、段階ごとに PR を出すとき、新しい PR の実行を、前の PR の実行と取り違えないための基準にする。
#   引数: リポジトリ ワークフロー名 ブランチ名（PR の head ブランチ）
sfv_latest_run_id() {
    local id
    id=$(sfv_gh run list -R "$1" --workflow "$2" --branch "$3" --event pull_request --limit 1 --json databaseId --jq '.[0].databaseId // 0' 2>/dev/null)  # VAR=$(cmd) のため run 不使用
    [[ "$id" =~ ^[0-9]+$ ]] || id=0
    printf '%s' "$id"
}
# PR のイベントで起動したワークフローの実行が、完了するまで待ち、実行 ID を標準出力に返す。
#   引数: リポジトリ ワークフロー名 ブランチ名 [この ID より新しい実行だけを対象にする（既定 0）]
#   上限（SFV_WF_TIMEOUT 秒）以内に完了しなければ、戻り値 1
sfv_wait_pr_run() {
    local repo="$1" wf="$2" br="$3" after="${4:-0}" i id status waited=0
    local timeout="${SFV_WF_TIMEOUT:-${E2E_WF_TIMEOUT:-1200}}" poll
    poll=$(_sfv_poll)
    for (( i = 1; i <= ${SFV_RUN_FIND_TRIES:-${E2E_RUN_FIND_TRIES:-24}}; i++ )); do   # 起動までの待ち
        id=$(sfv_gh run list -R "$repo" --workflow "$wf" --branch "$br" --event pull_request --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)  # VAR=$(cmd) のため run 不使用
        if [[ "$id" =~ ^[0-9]+$ ]] && (( id > after )); then break; fi   # 基準より新しい実行だけを、対象にする
        id=""
        sleep "$poll"  # run 不使用: 待機
    done
    [[ -n "$id" ]] || return 1
    while (( waited < timeout )); do
        status=$(sfv_gh run view "$id" -R "$repo" --json status --jq .status 2>/dev/null)  # VAR=$(cmd) のため run 不使用
        [[ "$status" == "completed" ]] && { printf '%s' "$id"; return 0; }
        sleep "$poll"; waited=$((waited + (poll > 0 ? poll : 1)))  # run 不使用: 待機（間隔が 0 でも、上限に達する）
    done
    return 1
}
# 実行の結果（success / failure ...）を、標準出力に返す。空のときだけ、やり直す（完了直後の反映の遅れ・gh の一時的な失敗への対策）
#   引数: リポジトリ 実行 ID
sfv_run_conclusion() {
    local out="" i n
    n=$(_sfv_tries)
    for (( i = 1; i <= n; i++ )); do
        out=$(sfv_gh run view "$2" -R "$1" --json conclusion --jq .conclusion 2>/dev/null)  # VAR=$(cmd) のため run 不使用
        [[ -n "$out" ]] && break
        (( i < n )) && sleep "$(_sfv_poll)"  # run 不使用: 待機
    done
    printf '%s' "$out"
}
# 実行の中のステップの結果を、標準出力に返す。空のときだけ、やり直す。引数: リポジトリ 実行 ID ステップ名
sfv_step_conclusion() {
    local out="" i n
    n=$(_sfv_tries)
    for (( i = 1; i <= n; i++ )); do
        out=$(sfv_gh run view "$2" -R "$1" --json jobs \
            --jq ".jobs[].steps[] | select(.name==\"$3\") | .conclusion" 2>/dev/null | head -1)  # VAR=$(cmd) のため run 不使用
        [[ -n "$out" ]] && break
        (( i < n )) && sleep "$(_sfv_poll)"  # run 不使用: 待機
    done
    printf '%s' "$out"
}
# 失敗した実行を、1 回だけ再実行して、完了を待つ（試行番号が増え、完了するまで）。引数: リポジトリ 実行 ID
sfv_rerun_and_wait() {
    local repo="$1" id="$2" a0 a st waited=0 poll timeout="${SFV_WF_TIMEOUT:-${E2E_WF_TIMEOUT:-1200}}"
    poll=$(_sfv_poll)
    a0=$(sfv_gh run view "$id" -R "$repo" --json attempt --jq .attempt 2>/dev/null)  # VAR=$(cmd) のため run 不使用
    [[ "$a0" =~ ^[0-9]+$ ]] || return 1
    sfv_gh run rerun "$id" -R "$repo" --failed >/dev/null 2>&1 || return 1  # 戻り値で判定するため run 不使用
    while (( waited < timeout )); do
        a=$(sfv_gh run view "$id" -R "$repo" --json attempt --jq .attempt 2>/dev/null)    # VAR=$(cmd) のため run 不使用
        st=$(sfv_gh run view "$id" -R "$repo" --json status --jq .status 2>/dev/null)     # VAR=$(cmd) のため run 不使用
        [[ "$a" =~ ^[0-9]+$ ]] && (( a > a0 )) && [[ "$st" == "completed" ]] && return 0
        sleep "$poll"; waited=$((waited + (poll > 0 ? poll : 1)))  # run 不使用: 待機（間隔が 0 でも、上限に達する）
    done
    return 1
}
# 実行のログに、文字列（固定）が含まれるか。引数: リポジトリ 実行 ID 文字列
sfv_run_log_has() { sfv_gh run view "$2" -R "$1" --log 2>/dev/null | grep -qF -- "$3"; }

# ------------------------------------------------------------------------------
# GitHub の API で、ブランチの作成・ファイルの追加・削除を行う（ローカルに clone しない。フックにも影響されない）
# ------------------------------------------------------------------------------
# ブランチの先頭のコミット SHA を、標準出力に返す。引数: リポジトリ ブランチ
sfv_branch_sha() { sfv_gh api "repos/${1}/git/ref/heads/${2}" --jq .object.sha 2>/dev/null; }
# ブランチを作る。引数: リポジトリ 新しいブランチ 元の SHA
sfv_branch_create() { sfv_gh api -X POST "repos/${1}/git/refs" -f "ref=refs/heads/${2}" -f "sha=${3}" >/dev/null 2>&1; }
# ファイルの SHA（ブランチ上）を、標準出力に返す。なければ、戻り値 1。引数: リポジトリ ブランチ パス
sfv_file_sha() {
    local s
    s=$(sfv_gh api "repos/${1}/contents/${3}?ref=${2}" --jq .sha 2>/dev/null) || return 1  # VAR=$(cmd) のため run 不使用
    [[ -n "$s" ]] || return 1
    printf '%s' "$s"
}
# ファイルを追加（または更新）する。本文は、標準入力。引数: リポジトリ ブランチ パス コミットメッセージ
sfv_file_put() {
    local repo="$1" br="$2" path="$3" msg="$4" b64 sha
    b64=$(base64 | tr -d '\n\r')  # 標準入力の本文を、base64 にする（パイプのみ）
    if sha=$(sfv_file_sha "$repo" "$br" "$path"); then  # 条件チェック
        sfv_gh api -X PUT "repos/${repo}/contents/${path}" -f "message=${msg}" -f "content=${b64}" -f "branch=${br}" -f "sha=${sha}" >/dev/null 2>&1
    else
        sfv_gh api -X PUT "repos/${repo}/contents/${path}" -f "message=${msg}" -f "content=${b64}" -f "branch=${br}" >/dev/null 2>&1
    fi
}
# ファイルを削除する（なければ、何もせず、成功）。引数: リポジトリ ブランチ パス コミットメッセージ
sfv_file_delete() {
    local repo="$1" br="$2" path="$3" msg="$4" sha
    sha=$(sfv_file_sha "$repo" "$br" "$path") || return 0  # ファイルがなければ、何もしない
    sfv_gh api -X DELETE "repos/${repo}/contents/${path}" -f "message=${msg}" -f "sha=${sha}" -f "branch=${br}" >/dev/null 2>&1
}
