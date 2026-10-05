#!/bin/bash
# ==============================================================================
# run.sh - sf-init の通し検証（e2e）。実際の GitHub / Salesforce で Phase 1〜10 を自動実行する
# ==============================================================================
# テスト用のリポジトリ（force-e2e-日時）と外部クライアントアプリを実際に作り、検証して、削除する。
# 通常のテスト（bash tests/run_tests.sh）には含まれない。実環境を使うため、開発者が手動で実行する。
#
# 【処理の流れ】
#   1. 前掃除      : 前回の失敗で残ったテスト用リソースを削除する（名前の形式とオーナーが一致するものだけ）
#   2. 実行        : sf-init を Phase 1〜10 まで自動で実行する（検証環境 = SF_TOOLS_BRANCH=development、main のみの構成）
#                    ・質問への答えは標準入力に流す
#                    ・sf org login web は、認証 URL でのログインに差し替える（tests/e2e/shims/sf）
#                    ・ブラウザは開かない（tests/e2e/shims の start / xdg-open / open）
#   3. 確認        : Secret / Variable / ブランチ / ワークフローの存在、トークンがログに出ていないこと、
#                    GitHub Actions の実行: wf-metasync（手動起動。並行して動かす）と、Hello World の Apex を PR 経由で
#                    リリース（wf-validate → マージ → wf-release）し、続けて削除する（sf-tools の本来の機能の通し）
#   4. 後掃除      : 前掃除と同じものを削除し（途中で止まって残った Hello World の Apex も含む）、sf のエイリアスを実行前の状態に戻す
#
# 【前提】
#   ・~/.sf-tools-e2e/fixture.env（鍵一式。bootstrap.sh で作成。E2E_FIXTURE 環境変数で場所を変更できる）
#   ・gh のログインユーザーが、fixture.env の E2E_GH_USER であること（テスト用の組織の管理者）
#   ・gh に delete_repo の権限があること: gh auth refresh -h github.com -s delete_repo
#   ・~/sf-tools が development ブランチで、origin/development と一致していること
#     （GitHub Actions は sf-tools の origin/development を使うため）
#
# 【オプション】
#   --keep        : 後掃除をしない（失敗の調査用。残ったものは cleanup.sh で削除できる）
#   --no-actions  : GitHub Actions の実行確認（wf-metasync・Hello World のリリースと削除）を省略する（約 8〜12 分短くなる）
#   -h, --help    : このヘルプを表示する
# ==============================================================================

readonly SCRIPT_NAME="e2e-run"
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true
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

KEEP=0
SKIP_ACTIONS=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)       KEEP=1 ;;
        --no-actions) SKIP_ACTIONS=1 ;;
        *) die "不明なオプションです: $1" ;;
    esac
    shift
done

e2e_load_fixture
e2e_guard_env
check_sf_cli  # sf が終了コードを正しく返すか確認（npm 版が前提。異常なら中断）

# ------------------------------------------------------------------------------
# 管理者向けの警告（実際のリポジトリ・組織を作成・削除する）
# ------------------------------------------------------------------------------
log "HEADER" "sf-init の通し検証（e2e）を開始します (${SCRIPT_NAME}.sh)"
echo -e "${CLR_ERR}╔══════════════════════════════════════════════════════╗${CLR_RESET}" >&2
echo -e "${CLR_ERR}║  !!  実際の GitHub / Salesforce を操作します         ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║                                                      ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║  ・テスト用のリポジトリ・外部クライアントアプリ・    ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║    Hello World の Apex を作成し、終了時に削除します  ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║  ・前回の残り（名前が一致する e2e 用のもの）も       ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║    最初に削除します                                  ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║  ・sf の認証が、テスト用組織の認証 URL で置き換わり  ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}╚══════════════════════════════════════════════════════╝${CLR_RESET}" >&2
log "INFO" "  オーナー: ${E2E_OWNER}  /  gh ユーザー: ${E2E_GH_USER}"
ask_yn "続行しますか？" || die "中断しました。"

# 手元の sf-tools が origin/development と違うと、GitHub Actions の確認結果が手元の変更を反映しない
_head=$(git -C "$SF_TOOLS_ROOT" rev-parse HEAD 2>/dev/null)                 # VAR=$(cmd) のため run 不使用
_origin=$(git -C "$SF_TOOLS_ROOT" rev-parse origin/development 2>/dev/null)  # VAR=$(cmd) のため run 不使用
if [[ -n "$_head" && "$_head" != "$_origin" ]]; then
    log "WARNING" "手元の sf-tools が origin/development と一致していません。GitHub Actions は origin/development を使うため、Actions の確認結果は手元の未 push の変更を反映しません。"
fi

# ------------------------------------------------------------------------------
# 一時領域の準備（差し替え用のコマンド・認証 URL のファイル・エイリアスの保存先）
# ------------------------------------------------------------------------------
E2E_TMP=$(mktemp -d "${TMPDIR:-/tmp}/e2e-run.XXXXXX") || die "一時ディレクトリを作成できません。"  # VAR=$(cmd) のため run 不使用
_finish() {
    # 異常終了でも、sf のエイリアスを戻し、認証 URL のファイルを消す
    [[ -f "${E2E_TMP}/aliases.txt" ]] && e2e_alias_restore "${E2E_TMP}/aliases.txt"
    rm -rf "$E2E_TMP"
}
trap _finish EXIT
e2e_alias_snapshot "${E2E_TMP}/aliases.txt"

SHIM_DIR="${E2E_TMP}/shims"
mkdir -p "$SHIM_DIR"
cp "${E2E_SCRIPT_DIR}/shims/sf" "${SHIM_DIR}/sf"
for _n in start xdg-open open; do cp "${E2E_SCRIPT_DIR}/shims/browser" "${SHIM_DIR}/${_n}"; done
chmod +x "${SHIM_DIR}"/* 2>/dev/null || true  # run 不使用: 実行権限の付与（Windows は効果なし・意図的エラー無視）
export E2E_SHIM_DIR="$SHIM_DIR"
export E2E_SFDX_URL_FILE="${E2E_TMP}/sfdx-url.txt"
printf '%s' "$E2E_SFDX_AUTH_URL" > "$E2E_SFDX_URL_FILE"
chmod 600 "$E2E_SFDX_URL_FILE" 2>/dev/null || true  # run 不使用: ファイル権限保護（Windows は効果なし・意図的エラー無視）

# ------------------------------------------------------------------------------
# 1. 前掃除
# ------------------------------------------------------------------------------
e2e_cleanup_all delete || die "前回のテスト用リソースを削除できませんでした。"

# ------------------------------------------------------------------------------
# 2. 実行（sf-init を Phase 1〜10 まで）
# ------------------------------------------------------------------------------
PROJECT=$(e2e_new_project_name)
REPO_NAME="force-${PROJECT}"
REPO_FULL="${E2E_OWNER}/${REPO_NAME}"
WORK="${E2E_HOME_ROOT}/${E2E_OWNER}/${PROJECT}"
run mkdir -p "$WORK" || die "作業フォルダを作成できません: ${WORK}"

log "HEADER" "sf-init を実行します（${REPO_FULL}）"
INIT_OUT="${E2E_TMP}/sf-init.out"
e2e_make_input \
    | ( cd "$WORK" && PATH="${SHIM_DIR}:${PATH}" bash "${SF_TOOLS_ROOT}/bin/sf-init.sh" 2>&1 ) \
    | tee "$INIT_OUT"
INIT_RC=${PIPESTATUS[1]}

# ------------------------------------------------------------------------------
# 3. 確認
# ------------------------------------------------------------------------------
CHECK_PASS=0
CHECK_FAIL=0
# chk 説明 コマンド...  : コマンドが成功すれば PASS、失敗すれば FAIL（失敗しても止まらない）
#   戻り値: PASS なら 0、FAIL なら 1（続きの手順を進められるかの判断に使える。失敗しても、run.sh 自体は止まらない）
chk() {
    local desc="$1"; shift
    if "$@"; then
        log "SUCCESS" "  [PASS] ${desc}"
        CHECK_PASS=$((CHECK_PASS + 1))
        return 0
    fi
    log "ERROR" "  [FAIL] ${desc}"
    CHECK_FAIL=$((CHECK_FAIL + 1))
    return 1
}

_has_secret()   { gh secret list -R "$REPO_FULL" 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }
_has_variable() { gh variable list -R "$REPO_FULL" 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }
_var_equals()   { [[ "$(gh variable get "$1" -R "$REPO_FULL" 2>/dev/null)" == "$2" ]]; }
_has_branch()   { gh api "repos/${REPO_FULL}/branches" --jq '.[].name' 2>/dev/null | grep -qx "$1"; }
_has_workflow() { gh api "repos/${REPO_FULL}/contents/.github/workflows" --jq '.[].name' 2>/dev/null | grep -qx "$1"; }
# ファイルに値が含まれていないこと（トークンの漏れの確認）
_not_in_file()  { [[ ! -f "$2" ]] || ! grep -qF -- "$1" "$2"; }

# Actions: ワークフローを手動で起動し、実行 ID を標準出力に返す（完了は待たない）
_dispatch_workflow() {
    local wf="$1" i id
    for ((i = 1; i <= 12; i++)); do   # 登録直後はワークフローが認識されるまで少しかかる
        gh workflow run "$wf" -R "$REPO_FULL" --ref main >/dev/null 2>&1 && break
        sleep 5  # run 不使用: 待機
    done
    for ((i = 1; i <= 12; i++)); do
        id=$(gh run list -R "$REPO_FULL" --workflow "$wf" --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)  # VAR=$(cmd) のため run 不使用
        [[ -n "$id" ]] && break
        sleep 5  # run 不使用: 待機
    done
    [[ -n "$id" ]] || return 1
    printf '%s' "$id"
}

# Actions: 実行 ID の実行が、完了するまで待つ（E2E_WF_TIMEOUT 秒（既定 1200）以内。E2E_POLL_SEC 秒（既定 5）おきに確認）
_wait_run() {
    local id="$1" timeout="${E2E_WF_TIMEOUT:-1200}" poll="${E2E_POLL_SEC:-5}" waited=0 status
    while (( waited < timeout )); do
        status=$(gh run view "$id" -R "$REPO_FULL" --json status --jq .status 2>/dev/null)  # VAR=$(cmd) のため run 不使用
        [[ "$status" == "completed" ]] && return 0
        sleep "$poll"; waited=$((waited + poll))  # run 不使用: 待機
    done
    return 1
}
_run_conclusion() { gh run view "$1" -R "$REPO_FULL" --json conclusion --jq .conclusion 2>/dev/null; }
_step_conclusion() {
    gh run view "$1" -R "$REPO_FULL" --json jobs \
        --jq ".jobs[].steps[] | select(.name==\"$2\") | .conclusion" 2>/dev/null | head -1
}

# ------------------------------------------------------------------------------
# Hello World の Apex を、PR 経由でリリースし、続けて削除する（sf-tools の本来の機能の通しの確認）
#   wf-validate（検証）→ PR のマージ → wf-release（リリース / 削除）。テスト用の組織（本番相当）に対して行う。
#   失敗した手順があれば、そこで止める（残ったクラスは、後掃除で削除される）
# ------------------------------------------------------------------------------
_admin_login_ok() { ( e2e_sf_admin_login ); }
_put_deploy_target() { e2e_hello_deploy_target_text | e2e_gh_file_put "$REPO_FULL" "$1" "sf-tools/release/$1/deploy-target.txt" -; }
_put_remove_target() { e2e_hello_remove_target_text | e2e_gh_file_put "$REPO_FULL" "$1" "sf-tools/release/$1/remove-target.txt" -; }
# 使わない側のファイルは、空の雛形で置く（sf-release.sh は、両方のファイルが無いと止まるため）
_put_empty_remove_target() { e2e_empty_target_text | e2e_gh_file_put "$REPO_FULL" "$1" "sf-tools/release/$1/remove-target.txt" -; }
_put_empty_deploy_target() { e2e_empty_target_text | e2e_gh_file_put "$REPO_FULL" "$1" "sf-tools/release/$1/deploy-target.txt" -; }

# リリース用のファイル（クラス 2 つ・メタデータ 2 つ・deploy-target.txt）を、ブランチに追加する
_hello_add_deploy_files() {
    local br="$1" f
    for f in "${E2E_APEX_HELLO}.cls" "${E2E_APEX_HELLO}.cls-meta.xml" "${E2E_APEX_HELLO_TEST}.cls" "${E2E_APEX_HELLO_TEST}.cls-meta.xml"; do
        chk "リリース: ${f} を追加した" e2e_gh_file_put "$REPO_FULL" "$br" "force-app/main/default/classes/${f}" "${E2E_SCRIPT_DIR}/fixtures/${f}" || return 1
    done
    chk "リリース: deploy-target.txt を追加した" _put_deploy_target "$br" || return 1
    chk "リリース: remove-target.txt（空の雛形）を追加した" _put_empty_remove_target "$br"
}
# 削除用のファイル（remove-target.txt）を、ブランチに追加する
_hello_add_remove_files() {
    chk "削除: remove-target.txt を追加した" _put_remove_target "$1" || return 1
    chk "削除: deploy-target.txt（空の雛形）を追加した" _put_empty_deploy_target "$1"
}

# 1 回分: ブランチ作成 → ファイル追加 → PR → wf-validate → マージ → wf-release。成功したら、実行 ID を HELLO_RELEASE_RUN に入れる
#   引数: ラベル ブランチ名 PR のタイトル ファイルを追加する関数名
_hello_cycle() {
    local label="$1" br="$2" title="$3" addfn="$4" prn runid
    chk "${label}: ブランチ ${br} を作成した" e2e_gh_branch_create "$REPO_FULL" "$br" || return 1
    "$addfn" "$br" || return 1
    prn=$(e2e_gh_pr_create "$REPO_FULL" "$br" "$title") || prn=""   # VAR=$(cmd) のため run 不使用
    chk "${label}: PR を作成した" test -n "$prn" || return 1
    runid=$(e2e_wait_pr_run "$REPO_FULL" wf-validate.yml "$br") || runid=""   # VAR=$(cmd) のため run 不使用
    chk "${label}: wf-validate（検証）が実行され、完了した" test -n "$runid" || return 1
    chk "${label}: wf-validate が成功した" test "$(_run_conclusion "$runid")" == "success" || return 1
    chk "${label}: PR をマージした" e2e_gh_pr_merge "$REPO_FULL" "$prn" || return 1
    runid=$(e2e_wait_pr_run "$REPO_FULL" wf-release.yml "$br") || runid=""   # VAR=$(cmd) のため run 不使用
    chk "${label}: wf-release が実行され、完了した" test -n "$runid" || return 1
    chk "${label}: wf-release が成功した" test "$(_run_conclusion "$runid")" == "success" || return 1
    HELLO_RELEASE_RUN="$runid"
    return 0
}

_hello_flow() {
    HELLO_RELEASE_RUN=""
    chk "Hello World: Salesforce への管理用ログイン（問い合わせ用）ができた" _admin_login_ok || return 0
    chk "Hello World: リリース前は、Salesforce にクラスがない" test "$(e2e_apex_count "$E2E_APEX_HELLO")" == "0" || return 0

    _hello_cycle "リリース" "e2e-hello" "e2e: Hello World をリリース" _hello_add_deploy_files || return 0
    # wf-release の途中のステップ（JWT ログイン・sf-tools の取得・Slack 通知）
    chk "wf-release: 本番組織へのログイン（JWT）が成功した" \
        test "$(_step_conclusion "$HELLO_RELEASE_RUN" "本番組織にログイン（JWT）")" == "success"
    chk "wf-release: sf-tools の取得が成功した（公開リポジトリを、Token なしで clone）" \
        test "$(_step_conclusion "$HELLO_RELEASE_RUN" "自動化ツール（sf-tools）を取得")" == "success"
    chk "wf-release: Slack への通知が成功した（ok:true）" \
        bash -c 'gh run view "$1" -R "$2" --log 2>/dev/null | grep -F "Slack response" | grep -q "\"ok\":true"' _ "$HELLO_RELEASE_RUN" "$REPO_FULL"
    chk "リリース後: Salesforce に ${E2E_APEX_HELLO} ができた" test "$(e2e_apex_count "$E2E_APEX_HELLO")" == "1"
    chk "リリース後: Salesforce に ${E2E_APEX_HELLO_TEST} ができた" test "$(e2e_apex_count "$E2E_APEX_HELLO_TEST")" == "1"

    _hello_cycle "削除" "e2e-hello-delete" "e2e: Hello World を削除" _hello_add_remove_files || return 0
    chk "削除後: Salesforce から ${E2E_APEX_HELLO} が消えた" test "$(e2e_apex_count "$E2E_APEX_HELLO")" == "0"
    chk "削除後: Salesforce から ${E2E_APEX_HELLO_TEST} が消えた" test "$(e2e_apex_count "$E2E_APEX_HELLO_TEST")" == "0"
}

log "HEADER" "確認"
chk "sf-init が正常終了した（終了コード ${INIT_RC}）" test "$INIT_RC" -eq 0

if [[ "$INIT_RC" -eq 0 ]]; then
    for _s in PAT_TOKEN SF_PRIVATE_KEY SF_CONSUMER_KEY_PROD SLACK_BOT_TOKEN; do
        chk "Secret ${_s} が登録されている" _has_secret "$_s"
    done
    for _v in SF_USERNAME_PROD SF_INSTANCE_URL_PROD SF_TOOLS_BRANCH SLACK_CHANNEL_ID; do
        chk "Variable ${_v} が登録されている" _has_variable "$_v"
    done
    chk "SF_TOOLS_BRANCH が development" _var_equals SF_TOOLS_BRANCH development
    chk "SLACK_CHANNEL_ID が入力した共有チャンネルの ID" _var_equals SLACK_CHANNEL_ID "$E2E_SLACK_CHANNEL_ID"
    chk "ブランチ main がある" _has_branch main
    for _w in wf-metasync.yml wf-propagate.yml wf-release.yml wf-sequence.yml wf-validate.yml; do
        chk "ワークフロー ${_w} がある" _has_workflow "$_w"
    done

    # トークンが、sf-init の出力・ログに出ていないこと
    for _f in "$INIT_OUT" "$HOME/sf-tools/logs/sf-init.log" "$HOME/sf-tools/logs/error.log"; do
        chk "PAT_TOKEN の値が $(basename "$_f") に出ていない"      _not_in_file "$E2E_PAT_TOKEN"       "$_f"
        chk "SLACK_BOT_TOKEN の値が $(basename "$_f") に出ていない" _not_in_file "$E2E_SLACK_BOT_TOKEN" "$_f"
        chk "認証 URL が $(basename "$_f") に出ていない"            _not_in_file "$E2E_SFDX_AUTH_URL"   "$_f"
    done

    if [[ $SKIP_ACTIONS -eq 0 ]]; then
        log "INFO" "GitHub Actions を実行します（各待ち: 最大 ${E2E_WF_TIMEOUT:-1200} 秒）..."
        # wf-metasync を起動する（待たない。次の Hello World の流れと並行して動く）
        _meta_id=$(_dispatch_workflow wf-metasync.yml) || _meta_id=""   # VAR=$(cmd) のため run 不使用
        # Hello World を、PR 経由でリリースし（wf-validate → マージ → wf-release）、続けて削除する
        _hello_flow
        # wf-metasync の完了を待つ
        chk "wf-metasync が起動した" test -n "$_meta_id"
        if [[ -n "$_meta_id" ]]; then
            chk "wf-metasync が完了した" _wait_run "$_meta_id"
            chk "wf-metasync が成功した（JWT ログイン・sf-tools の取得を含む）" \
                test "$(_run_conclusion "$_meta_id")" == "success"
        fi
    else
        log "INFO" "GitHub Actions の実行確認を省略しました（--no-actions）。"
    fi
fi

# ------------------------------------------------------------------------------
# 4. 後掃除
# ------------------------------------------------------------------------------
CLEAN_RC=0
if [[ $KEEP -eq 1 ]]; then
    log "WARNING" "後掃除を省略しました（--keep）。残ったものは tests/e2e/cleanup.sh で削除できます。"
else
    e2e_cleanup_all delete || CLEAN_RC=1
fi

# ------------------------------------------------------------------------------
# 結果
# ------------------------------------------------------------------------------
echo ""
log "HEADER" "結果"
log "INFO" "  確認: ${CHECK_PASS} 件成功 / ${CHECK_FAIL} 件失敗"
if [[ $CLEAN_RC -ne 0 ]]; then
    log "ERROR" "  後掃除に失敗したものがあります。tests/e2e/cleanup.sh で確認してください。"
fi
if [[ $CHECK_FAIL -eq 0 && $CLEAN_RC -eq 0 ]]; then
    log "SUCCESS" "e2e: すべて成功しました。"
    exit $RET_OK
fi
log "ERROR" "e2e: 失敗がありました。"
exit $RET_NG
