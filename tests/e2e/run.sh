#!/bin/bash
# ==============================================================================
# run.sh - sf-init の通し検証（e2e）。実際の GitHub / Salesforce で Phase 1〜10 を自動実行する
# ==============================================================================
# テスト用のリポジトリ（force-e2e-日時）と外部クライアントアプリを実際に作り、検証する（既定では、終了後も残し、次回の最初に削除する）。
# 通常のテスト（bash tests/run_tests.sh）には含まれない。実環境を使うため、開発者が手動で実行する。
#
# 【処理の流れ】
#   1. 前掃除      : 前回の失敗で残ったテスト用リソースを削除する（名前の形式とオーナーが一致するものだけ）
#   2. 実行        : sf-init を Phase 1〜10 まで自動で実行する（検証環境 = SF_TOOLS_BRANCH=development、main のみの構成）
#                    ・質問への答えは標準入力に流す
#                    ・sf org login web は、認証 URL でのログインに差し替える（tests/e2e/shims/sf）
#                    ・ブラウザは開かない（tests/e2e/shims の start / xdg-open / open）
#   3. 確認        : Secret / Variable / ブランチ / ワークフローの存在、トークンがログに出ていないこと、
#                    GitHub Actions の実行: wf-metasync（手動起動。完了を待つ。Hello World と同時に動かすと、組織へのデプロイと取得が重なって失敗する）、続けて Hello World の Apex を PR 経由で
#                    リリース（wf-validate → マージ → wf-release）し、続けて削除する（sf-tools の本来の機能の通し）。
#                    リリース・削除の作業は、通常の運用と同じく、sf-tools のコマンドで行う: sf-job.sh（ブランチ作成・clone・sf-start.sh）
#                    → ファイルを書く → sf-dryrun.sh（ローカルの検証）→ sf-push.sh（commit・push・pre-push フック）。PR の作成・マージは gh。
#                    リリース後は、sf-next.sh（マージ済みの表示）と、sf-deploy.sh（共有環境への強制リリースの拒否）も確認する
#   4. 終了        : sf のエイリアスを実行前の状態に戻す。テスト用のリポジトリ・外部クライアントアプリなどは、既定では削除せずに残す
#                    （終了後に、GitHub の画面で、Actions の実行・PR・ファイルを見返せるようにするため。次回の前掃除で、自動で削除される）。
#                    --cleanup を付けると、終了時に削除する（途中で止まって残った Hello World の Apex も含む）
#
# 【前提】
#   ・~/.sf-tools-e2e/fixture.env（鍵一式。bootstrap.sh で作成。E2E_FIXTURE 環境変数で場所を変更できる）
#   ・gh のログインユーザーが、fixture.env の E2E_GH_USER であること（テスト用の組織の管理者）
#   ・gh に delete_repo の権限があること: gh auth refresh -h github.com -s delete_repo
#   ・~/sf-tools が development ブランチで、origin/development と一致していること
#     （GitHub Actions は sf-tools の origin/development を使うため）
#
# 【オプション】
#   --cleanup     : 終了時に、テスト用のものを削除する（既定は削除しない。次回の前掃除、または cleanup.sh で削除される）
#   --keep        : 何もしない（以前の名残り。既定が「削除しない」になったため）
#   --resume      : 前回残したテスト用リポジトリ（最新の 1 つ）を使い、Hello World の部分（sf-job → sf-dryrun → sf-push → PR → リリース → 削除、
#                   sf-next・sf-deploy の確認）だけを再実行する。前掃除・sf-init・wf-metasync は、行わない（約 15 分。直しの確認を、早く繰り返すため）。
#                   ジョブ名は、毎回、時刻付きの別の名前になる。前回の残りの Hello World の Apex が、組織にあれば、最初に削除する
#   --no-actions  : GitHub Actions の実行確認（wf-metasync・Hello World のリリースと削除）を省略する（約 8〜12 分短くなる）
#   -h, --help    : このヘルプを表示する
# ==============================================================================

readonly SCRIPT_NAME="e2e-run"
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

START_SEC=$SECONDS   # 経過時間の表示用
KEEP=1   # 既定は、終了時に削除しない（あとから見返せるように。次回の前掃除で削除される）
SKIP_ACTIONS=0
RESUME=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)       KEEP=1 ;;
        --cleanup)    KEEP=0 ;;
        --no-actions) SKIP_ACTIONS=1 ;;
        --resume)     RESUME=1 ;;
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
echo -e "${CLR_ERR}║    Hello World の Apex を作成します（Apex は削除）    ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║  ・終了後も、リポジトリなどは残します（見返す用）    ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║    前回の残りは、最初に削除します                    ║${CLR_RESET}" >&2
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
    [[ -f "${E2E_TMP}/aliases.txt.ok" ]] && e2e_alias_restore "${E2E_TMP}/aliases.txt"
    rm -rf "$E2E_TMP"  # run 不使用: 一時フォルダの後始末（trap 内。認証 URL のファイルを残さない）
}
trap _finish EXIT
e2e_alias_snapshot "${E2E_TMP}/aliases.txt" || die "sf のエイリアスの一覧を取得できません（実行前の状態を保存できないため、中断します）。"

SHIM_DIR="${E2E_TMP}/shims"
mkdir -p "$SHIM_DIR"  # run 不使用: 差し替え用コマンドの置き場（一時フォルダ内）
cp "${E2E_SCRIPT_DIR}/shims/sf" "${SHIM_DIR}/sf"  # run 不使用: 差し替え用コマンドの配置（一時フォルダ内）
cp "${E2E_SCRIPT_DIR}/shims/code" "${SHIM_DIR}/code"  # run 不使用: 差し替え用コマンドの配置（一時フォルダ内）
for _n in start xdg-open open; do cp "${E2E_SCRIPT_DIR}/shims/browser" "${SHIM_DIR}/${_n}"; done
chmod +x "${SHIM_DIR}"/* 2>/dev/null || true  # run 不使用: 実行権限の付与（Windows は効果なし・意図的エラー無視）
export E2E_SHIM_DIR="$SHIM_DIR"
export E2E_SFDX_URL_FILE="${E2E_TMP}/sfdx-url.txt"
printf '%s' "$E2E_SFDX_AUTH_URL" > "$E2E_SFDX_URL_FILE"
chmod 600 "$E2E_SFDX_URL_FILE" 2>/dev/null || true  # run 不使用: ファイル権限保護（Windows は効果なし・意図的エラー無視）

# ------------------------------------------------------------------------------
# 経過時間の表示（どこで時間がかかっているか分かるように）と、ジョブ名
# ------------------------------------------------------------------------------
_elapsed() { local s=$(( SECONDS - START_SEC )); log "INFO" "  経過時間: $(( s / 60 )) 分 $(( s % 60 )) 秒（$1）"; }
# ジョブ名（= ブランチ名）は、毎回、時刻付きの別の名前にする（--resume で、同じリポジトリを使っても、ぶつからないように）
RUN_ID=$(date +%H%M%S)  # VAR=$(cmd) のため run 不使用
JOB_RELEASE="e2e-hello-${RUN_ID}"
JOB_DELETE="e2e-hello-delete-${RUN_ID}"

# ------------------------------------------------------------------------------
# 1・2. 前掃除 → sf-init の実行（Phase 1〜10）。--resume のときは、前回残したリポジトリを使う
# ------------------------------------------------------------------------------
# 前回残したテスト用の作業フォルダ（名前が決まった形式のもののうち、最新の 1 つ）の名前を、標準出力に返す。なければ、戻り値 1
#   名前は、日時（e2e-YYYYMMDD-HHMMSS）なので、フォルダ名の並び順が、新しい順になる
_find_resume_project() {
    local d name best=""
    for d in "${E2E_HOME_ROOT}/${E2E_OWNER}"/e2e-*; do
        [[ -d "$d" ]] || continue
        name=$(basename "$d")  # VAR=$(cmd) のため run 不使用
        e2e_is_target_project "$name" && best="$name"
    done
    [[ -n "$best" ]] || return 1
    printf '%s' "$best"
}

_set_project() {   # 引数: プロジェクト名。PROJECT / REPO_NAME / REPO_FULL / WORK を決める
    PROJECT="$1"
    REPO_NAME="force-${PROJECT}"
    REPO_FULL="${E2E_OWNER}/${REPO_NAME}"
    WORK="${E2E_HOME_ROOT}/${E2E_OWNER}/${PROJECT}"
}

_fresh_start() {
    e2e_cleanup_all delete || die "前回のテスト用リソースを削除できませんでした。"
    _set_project "$(e2e_new_project_name)"
    run mkdir -p "$WORK" || die "作業フォルダを作成できません: ${WORK}"

    log "HEADER" "sf-init を実行します（${REPO_FULL}）"
    INIT_OUT="${E2E_TMP}/sf-init.out"
    e2e_make_input \
        | ( cd "$WORK" && PATH="${SHIM_DIR}:${PATH}" bash "${SF_TOOLS_ROOT}/bin/sf-init.sh" 2>&1 ) \
        | tee "$INIT_OUT"
    INIT_RC=${PIPESTATUS[1]}
    _elapsed "sf-init の終了"
}

_resume_start() {
    local p
    log "HEADER" "再開（--resume）: 前回残したテスト用リポジトリを使います"
    p=$(_find_resume_project) || die "再開できる、前回のテスト用の作業フォルダがありません（${E2E_HOME_ROOT}/${E2E_OWNER}/e2e-日時）。"  # VAR=$(cmd) のため run 不使用
    _set_project "$p"
    _e2e_check_repo "$REPO_FULL"
    _e2e_gh repo view "$REPO_FULL" >/dev/null 2>&1 || die "再開できるリポジトリがありません: ${REPO_FULL}"  # 戻り値で判定するため run 不使用
    log "INFO" "  リポジトリ: https://github.com/${REPO_FULL}"
    log "INFO" "  前掃除・sf-init・wf-metasync は、行いません。Hello World の部分だけを、再実行します。"
    INIT_OUT=""
    INIT_RC=0
}

if [[ $RESUME -eq 1 ]]; then
    _resume_start
else
    _fresh_start
fi

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

_has_secret()   { _e2e_gh secret list -R "$REPO_FULL" 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }
_has_variable() { _e2e_gh variable list -R "$REPO_FULL" 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }
_var_equals()   { [[ "$(_e2e_gh variable get "$1" -R "$REPO_FULL" 2>/dev/null)" == "$2" ]]; }
_has_branch()   { _e2e_gh api "repos/${REPO_FULL}/branches" --jq '.[].name' 2>/dev/null | grep -qx "$1"; }
_has_workflow() { _e2e_gh api "repos/${REPO_FULL}/contents/.github/workflows" --jq '.[].name' 2>/dev/null | grep -qx "$1"; }
# ファイルに値が含まれていないこと（トークンの漏れの確認）
_not_in_file()  { [[ ! -f "$2" ]] || ! grep -qF -- "$1" "$2"; }

# Actions: ワークフローを手動で起動し、起動した実行の ID を標準出力に返す（完了は待たない）
#   起動の前の、最新の実行 ID を覚え、それより新しい実行だけを、起動した実行とみなす（古い実行を、取り違えないため）。
#   起動の呼び出しが、すべて失敗したら、戻り値 1
_dispatch_workflow() {
    local wf="$1" i id before dispatched=0
    before=$(_e2e_gh run list -R "$REPO_FULL" --workflow "$wf" --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId // 0' 2>/dev/null)  # VAR=$(cmd) のため run 不使用
    [[ "$before" =~ ^[0-9]+$ ]] || before=0
    for ((i = 1; i <= 12; i++)); do   # 登録直後はワークフローが認識されるまで少しかかる
        if _e2e_gh workflow run "$wf" -R "$REPO_FULL" --ref main >/dev/null 2>&1; then dispatched=1; break; fi  # 条件チェック
        sleep 5  # run 不使用: 待機
    done
    [[ $dispatched -eq 1 ]] || return 1
    for ((i = 1; i <= 12; i++)); do
        id=$(_e2e_gh run list -R "$REPO_FULL" --workflow "$wf" --event workflow_dispatch --limit 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null)  # VAR=$(cmd) のため run 不使用
        [[ "$id" =~ ^[0-9]+$ ]] && (( id > before )) && { printf '%s' "$id"; return 0; }
        sleep 5  # run 不使用: 待機
    done
    return 1
}

# Actions: 実行 ID の実行が、完了するまで待つ（E2E_WF_TIMEOUT 秒（既定 1200）以内。E2E_POLL_SEC 秒（既定 5）おきに確認）
_wait_run() {
    local id="$1" timeout="${E2E_WF_TIMEOUT:-1200}" poll="${E2E_POLL_SEC:-5}" waited=0 status
    while (( waited < timeout )); do
        status=$(_e2e_gh run view "$id" -R "$REPO_FULL" --json status --jq .status 2>/dev/null)  # VAR=$(cmd) のため run 不使用
        [[ "$status" == "completed" ]] && return 0
        sleep "$poll"; waited=$((waited + poll))  # run 不使用: 待機
    done
    return 1
}
_run_conclusion() { e2e_run_conclusion "$REPO_FULL" "$1"; }   # 空のときは、やり直す（lib.sh）
_step_conclusion() { e2e_step_conclusion "$REPO_FULL" "$1" "$2"; }

# ------------------------------------------------------------------------------
# Hello World の Apex を、PR 経由でリリースし、続けて削除する（sf-tools の本来の機能の通しの確認）
#   wf-validate（検証）→ PR のマージ → wf-release（リリース / 削除）。テスト用の組織（本番相当）に対して行う。
#   失敗した手順があれば、そこで止める（残ったクラスは、後掃除で削除される）
# ------------------------------------------------------------------------------
_admin_login_ok() { ( e2e_sf_admin_login ); }
# wf-release の Slack 通知が成功したか（ログに、Slack の応答 ok:true がある）
_slack_ok() { _e2e_gh run view "$1" -R "$REPO_FULL" --log 2>/dev/null | grep -F "Slack response" | grep -q '"ok":true'; }

# Hello World の作業は、開発者の作業を、sf-tools のコマンドで再現する（通常の運用と同じ道）
#   sf-job.sh（ブランチ作成・clone・sf-start.sh）→ ファイルを書く → sf-dryrun.sh（ローカルの検証）→ sf-push.sh（commit・push・pre-push フック）
#   ファイルの書き込みだけが、開発者の手作業にあたる部分。そのあと、gh で PR を作る（通常の運用では GitHub の画面）
_hello_write_release() {   # 引数: クローンのフォルダ ブランチ名（リリース: クラスと deploy-target.txt。remove-target.txt は雛形のまま）
    local repo="$1" job="$2" f
    mkdir -p "${repo}/force-app/main/default/classes" || return 1  # run 不使用: テスト用の作業フォルダへの書き込み
    for f in "${E2E_APEX_HELLO}.cls" "${E2E_APEX_HELLO}.cls-meta.xml" "${E2E_APEX_HELLO_TEST}.cls" "${E2E_APEX_HELLO_TEST}.cls-meta.xml"; do
        cp "${E2E_SCRIPT_DIR}/fixtures/${f}" "${repo}/force-app/main/default/classes/${f}" || return 1  # run 不使用: 同上
    done
    e2e_hello_deploy_target_text > "${repo}/sf-tools/release/${job}/deploy-target.txt"
}
_hello_write_remove() {   # 引数: クローンのフォルダ ブランチ名（削除: remove-target.txt。deploy-target.txt は雛形のまま）
    e2e_hello_remove_target_text > "${1}/sf-tools/release/${2}/remove-target.txt"
}
# push した内容（手元の HEAD）が、GitHub のブランチの先頭と一致すること。どちらかが読めない（空）場合は、一致とみなさない
_pushed_to_remote() {   # 引数: クローンのフォルダ ブランチ名
    local l r
    l=$(git -C "$1" rev-parse HEAD 2>/dev/null)  # VAR=$(cmd) のため run 不使用
    r=$(git -C "$1" ls-remote origin "refs/heads/${2}" 2>/dev/null | awk '{print $1}')  # VAR=$(cmd) のため run 不使用
    [[ -n "$l" && "$l" == "$r" ]]
}
_hello_push() { E2E_COMMIT_MSG="$2" e2e_run_sf_cmd "sf-push-$1" "$3" "" "${SF_TOOLS_ROOT}/bin/sf-push.sh"; }   # 引数: ジョブ名 メッセージ クローンのフォルダ

# ジョブの開始から push まで。引数: ラベル ブランチ名（= ジョブ名） コミットメッセージ ファイルを書く関数名 テストクラスを検出するか（1 / 0）
_hello_local_job() {
    local label="$1" job="$2" msg="$3" writefn="$4" expect_tests="$5" repo="${WORK}/$2/${REPO_NAME}"
    chk "${label}: sf-job.sh で、ジョブ（ブランチ ${job}）を開始した（ブランチ作成・clone・sf-start.sh）" \
        e2e_run_sf_cmd "sf-job-${job}" "$WORK" "${job}\nY\n${E2E_JOB_ALIAS}\n" "${SF_TOOLS_ROOT}/bin/sf-job.sh" || return 1
    chk "${label}: sf-install.sh（sf-start.sh が背景で実行）が完了した" e2e_wait_sf_install "$repo" || return 1
    chk "${label}: Git フック（pre-push）が設置された" test -f "${repo}/.git/hooks/pre-push"
    chk "${label}: リリース管理フォルダ release/${job}/ が用意された（雛形）" \
        test -f "${repo}/sf-tools/release/${job}/deploy-target.txt" -a -f "${repo}/sf-tools/release/${job}/remove-target.txt" || return 1
    chk "${label}: ファイルを書いた" "$writefn" "$repo" "$job" || return 1
    chk "${label}: sf-dryrun.sh で、ローカルから検証できた" \
        e2e_run_sf_cmd "sf-dryrun-${job}" "$repo" "" "${SF_TOOLS_ROOT}/bin/sf-dryrun.sh" --no-open || return 1
    if [[ "$expect_tests" == "1" ]]; then
        chk "${label}: sf-dryrun.sh が、@isTest のクラスを検出した（--tests の指定）" \
            grep -q "テストクラス合計: 1件" "${E2E_TMP}/sf-dryrun-${job}.out" || return 1
    fi
    chk "${label}: sf-push.sh で、commit と push ができた" _hello_push "$job" "$msg" "$repo" || return 1
    chk "${label}: pre-push フック（sf-prepush.sh）が動いた" test -s "${repo}/sf-tools/logs/sf-prepush.log"
    chk "${label}: push した内容が、GitHub のブランチ ${job} に届いている" _pushed_to_remote "$repo" "$job"
}
# ワークフローの実行が成功したか。失敗したら、ログを表示し、1 回だけ再実行する（一時的な失敗への対策）。
#   再実行で成功したら、PASS（警告を表示し、FLAKY_RUNS に数える）。再実行でも失敗したら、FAIL
#   引数: 実行ID ラベル
FLAKY_RUNS=0
_run_ok() {
    local id="$1" label="$2"
    [[ "$(_run_conclusion "$id")" == "success" ]] && return 0
    e2e_show_run_failure "$REPO_FULL" "$id" "$label"
    log "WARNING" "${label}: 失敗しました。一時的な失敗（Salesforce・通信側）の可能性があるため、1 回だけ再実行します（gh run rerun --failed）。"
    e2e_rerun_and_wait "$REPO_FULL" "$id" || { log "ERROR" "${label}: 再実行できなかった、または、完了しませんでした。"; return 1; }
    if [[ "$(_run_conclusion "$id")" == "success" ]]; then
        FLAKY_RUNS=$((FLAKY_RUNS + 1))
        log "WARNING" "${label}: 再実行で成功しました。一時的な失敗だった可能性があります（最初の失敗のログは、上に表示しています）。"
        return 0
    fi
    log "ERROR" "${label}: 再実行でも失敗しました。"
    e2e_show_run_failure "$REPO_FULL" "$id" "${label}（再実行後）"
    return 1
}

# PR の作成 → wf-validate → マージ → wf-release → wf-propagate。成功したら、実行 ID を HELLO_RELEASE_RUN に入れる
#   引数: ラベル ブランチ名（push 済み） PR のタイトル
_hello_pr_flow() {
    local label="$1" br="$2" title="$3" prn runid
    prn=$(e2e_gh_pr_create "$REPO_FULL" "$br" "$title") || prn=""   # VAR=$(cmd) のため run 不使用
    chk "${label}: PR を作成した" test -n "$prn" || return 1
    runid=$(e2e_wait_pr_run "$REPO_FULL" wf-validate.yml "$br") || runid=""   # VAR=$(cmd) のため run 不使用
    chk "${label}: wf-validate（検証）が実行され、完了した" test -n "$runid" || return 1
    chk "${label}: wf-validate が成功した（失敗したら、1 回だけ再実行）" _run_ok "$runid" "${label}: wf-validate" || return 1
    chk "${label}: PR をマージした" e2e_gh_pr_merge "$REPO_FULL" "$prn" || return 1
    runid=$(e2e_wait_pr_run "$REPO_FULL" wf-release.yml "$br") || runid=""   # VAR=$(cmd) のため run 不使用
    chk "${label}: wf-release が実行され、完了した" test -n "$runid" || return 1
    chk "${label}: wf-release が成功した（失敗したら、1 回だけ再実行）" _run_ok "$runid" "${label}: wf-release" || return 1
    # wf-propagate（main へのマージ時。staging / develop がない構成では、スキップして成功になる）。失敗しても、続きの確認は進める
    local pid
    pid=$(e2e_wait_pr_run "$REPO_FULL" wf-propagate.yml "$br") || pid=""   # VAR=$(cmd) のため run 不使用
    if chk "${label}: wf-propagate が実行され、完了した" test -n "$pid"; then
        chk "${label}: wf-propagate が成功した（staging / develop がない構成では、スキップ。失敗したら、1 回だけ再実行）" _run_ok "$pid" "${label}: wf-propagate"
    fi
    HELLO_RELEASE_RUN="$runid"
    return 0
}

# 1 回分: ジョブ → PR → wf-validate → マージ → wf-release → wf-propagate。引数: ラベル ブランチ名 PR のタイトル ファイルを書く関数名 テストを検出するか
_hello_cycle() {
    local label="$1" br="$2" title="$3" writefn="$4" expect_tests="$5"
    _hello_local_job "$label" "$br" "$title" "$writefn" "$expect_tests" || return 1
    _hello_pr_flow "$label" "$br" "$title"
}

# sf-next.sh: リリースしたジョブのクローンで実行し、マージ済みのブランチが「マージ済み」と表示されること（質問には N で答える）
_hello_sf_next() { e2e_run_sf_cmd "sf-next" "$1" "N\n" "${SF_TOOLS_ROOT}/bin/sf-next.sh" && grep -q "マージ済み" "${E2E_TMP}/sf-next.out"; }
# sf-deploy.sh: 予約名の組織へのローカルからの強制リリースは、確認の前に拒否される（終了コード 0 以外、拒否の文言、デプロイしない）
#   予約名は main を使う（開発者の本物の組織に付いていることがある prod / staging / develop は、避ける。
#   万一、拒否が働かなくなっても、main という名前の組織は、まず無いので、本物の組織への強制リリースにならない）
_hello_deploy_refused() {
    e2e_run_sf_cmd_refused "sf-deploy-refused" "$1" "N\n" "${SF_TOOLS_ROOT}/bin/sf-deploy.sh" -t main --no-open \
        && [[ -s "${E2E_TMP}/sf-deploy-refused.out" ]] \
        && grep -q "共有環境のため" "${E2E_TMP}/sf-deploy-refused.out" \
        && ! grep -q "project deploy start" "${E2E_TMP}/sf-deploy-refused.out"
}

# --resume: 前回の残りの Hello World の Apex クラスが、組織にあれば、削除する（名前が完全に一致するものだけ。なければ、何もしない）
_resume_clean_apex() {
    local list
    local -a names=()
    list=$(e2e_list_target_apex) || return 1  # VAR=$(cmd) のため run 不使用
    [[ -z "$list" ]] && return 0
    mapfile -t names <<< "$list"
    log "WARNING" "  前回の残りの Apex クラスがあります。削除します: ${names[*]}"
    e2e_delete_apex "${names[@]}"
}

_hello_flow() {
    HELLO_RELEASE_RUN=""
    chk "Hello World: Salesforce への管理用ログイン（問い合わせ用）ができた" _admin_login_ok || return 0
    if [[ $RESUME -eq 1 ]]; then
        chk "Hello World: 前回の残りの Apex クラスを、確認した（あれば削除）" _resume_clean_apex || return 0
    fi
    chk "Hello World: リリース前は、Salesforce にクラスがない" test "$(e2e_apex_count "$E2E_APEX_HELLO")" == "0" || return 0

    _hello_cycle "リリース" "$JOB_RELEASE" "e2e: Hello World をリリース" _hello_write_release 1 || return 0
    _elapsed "リリース側（sf-job → PR → wf-release）の終了"
    # wf-release の途中のステップ（JWT ログイン・sf-tools の取得・Slack 通知）
    chk "wf-release: 本番組織へのログイン（JWT）が成功した" \
        test "$(_step_conclusion "$HELLO_RELEASE_RUN" "本番組織にログイン（JWT）")" == "success"
    chk "wf-release: sf-tools の取得が成功した（公開リポジトリを、Token なしで clone）" \
        test "$(_step_conclusion "$HELLO_RELEASE_RUN" "自動化ツール（sf-tools）を取得")" == "success"
    chk "wf-release: Slack への通知が成功した（ok:true）" \
        _slack_ok "$HELLO_RELEASE_RUN"
    chk "リリース後: Salesforce への管理用ログイン（問い合わせ用）をやり直した" _admin_login_ok || return 0
    chk "リリース後: Salesforce に ${E2E_APEX_HELLO} ができた" test "$(e2e_apex_count "$E2E_APEX_HELLO")" == "1"
    chk "リリース後: Salesforce に ${E2E_APEX_HELLO_TEST} ができた" test "$(e2e_apex_count "$E2E_APEX_HELLO_TEST")" == "1"

    # 通常の運用で使う、そのほかの sf-tools のコマンド（リリースしたジョブのクローンで実行する）
    local repo="${WORK}/${JOB_RELEASE}/${REPO_NAME}"
    chk "sf-next.sh: マージ済みのブランチを、マージ済みと表示する" _hello_sf_next "$repo"
    chk "sf-deploy.sh: 共有環境（予約名 main）へのローカルからの強制リリースを、拒否する" _hello_deploy_refused "$repo"

    _hello_cycle "削除" "$JOB_DELETE" "e2e: Hello World を削除" _hello_write_remove 0 || return 0
    # 2 回目の sf-job.sh（sf-start.sh）が、同じ組織の接続を、いったんログアウトして、ログインし直す。
    # 同じユーザーの認証は、エイリアスが違っても、共通の保存先を使うため、問い合わせ用の管理用ログインを、やり直してから確認する
    _elapsed "削除側（sf-job → PR → wf-release）の終了"
    chk "削除後: Salesforce への管理用ログイン（問い合わせ用）をやり直した" _admin_login_ok || return 0
    chk "削除後: Salesforce から ${E2E_APEX_HELLO} が消えた" test "$(e2e_apex_count "$E2E_APEX_HELLO")" == "0"
    chk "削除後: Salesforce から ${E2E_APEX_HELLO_TEST} が消えた" test "$(e2e_apex_count "$E2E_APEX_HELLO_TEST")" == "0"
}

log "HEADER" "確認"
[[ $RESUME -eq 1 ]] || chk "sf-init が正常終了した（終了コード ${INIT_RC}）" test "$INIT_RC" -eq 0   # --resume では、sf-init を実行しない

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
        # wf-metasync（--resume では、行わない: 前回の確認で済んでおり、Hello World の確認を、早く繰り返すため）
        if [[ $RESUME -eq 0 ]]; then
            # wf-metasync を起動して、完了を待つ。Hello World の流れと並行させない
            #   （組織からの取得と、組織へのデプロイが重なると、MetadataTransferError で失敗する）
            _meta_id=$(_dispatch_workflow wf-metasync.yml) || _meta_id=""   # VAR=$(cmd) のため run 不使用
            chk "wf-metasync が起動した" test -n "$_meta_id"
            if [[ -n "$_meta_id" ]]; then
                if chk "wf-metasync が完了した" _wait_run "$_meta_id"; then   # 完了していない実行を、成功かどうか判定しない
                    chk "wf-metasync が成功した（JWT ログイン・sf-tools の取得を含む。失敗したら、1 回だけ再実行）" _run_ok "$_meta_id" "wf-metasync"
                fi
            fi
            _elapsed "wf-metasync の確認の終了"
        fi
        # Hello World を、PR 経由でリリースし（wf-validate → マージ → wf-release）、続けて削除する
        _hello_flow
    else
        log "INFO" "GitHub Actions の実行確認を省略しました（--no-actions）。"
    fi
fi

# ------------------------------------------------------------------------------
# 4. 後掃除
# ------------------------------------------------------------------------------
CLEAN_RC=0
if [[ $KEEP -eq 1 ]]; then
    log "INFO" "テスト用のものは、削除せずに残しました（あとから見返せます。次回の e2e の最初に、自動で削除されます）。"
    log "INFO" "  リポジトリ: https://github.com/${REPO_FULL}"
    log "INFO" "  Actions   : https://github.com/${REPO_FULL}/actions"
    log "INFO" "  すぐに削除する場合: tests/e2e/cleanup.sh --yes"
else
    e2e_cleanup_all delete || CLEAN_RC=1
fi

# ------------------------------------------------------------------------------
# 結果
# ------------------------------------------------------------------------------
echo ""
log "HEADER" "結果"
log "INFO" "  確認: ${CHECK_PASS} 件成功 / ${CHECK_FAIL} 件失敗"
_elapsed "全体"
if [[ $FLAKY_RUNS -gt 0 ]]; then
    log "WARNING" "  再実行で成功したワークフローが ${FLAKY_RUNS} 件あります（一時的な失敗の可能性。上の、最初の失敗のログを確認してください）。"
fi
if [[ $CLEAN_RC -ne 0 ]]; then
    log "ERROR" "  後掃除に失敗したものがあります。tests/e2e/cleanup.sh で確認してください。"
fi
if [[ $CHECK_FAIL -eq 0 && $CLEAN_RC -eq 0 ]]; then
    log "SUCCESS" "e2e: すべて成功しました。"
    exit $RET_OK
fi
log "ERROR" "e2e: 失敗がありました。"
exit $RET_NG
