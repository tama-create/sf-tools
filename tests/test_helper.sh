#!/bin/bash
# ==============================================================================
# test_helper.sh - sf-tools テスト共通ユーティリティ
# ==============================================================================

SF_TOOLS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TESTS_PASSED=0
TESTS_FAILED=0

CLR_PASS='\033[32m'
CLR_FAIL='\033[31m'
CLR_HEAD='\033[36m'
CLR_RST='\033[0m'

# check_sf_cli の「24 時間は確認を省略」の記録先。テストでは、無効にする（本物のホームに記録を作らず、
# 省略のテスト以外で、確認が省略されないようにするため。省略のテストは、独自の記録先を指定する）
export SF_TOOLS_SF_CHECK_STAMP=/dev/null

# check_java_cli も同様（記録を作らない。省略のテストは、独自の記録先を指定する）。
# JAVA_HOME は、本物のものを使わない（check_java_cli は JAVA_HOME を優先するため、モックの java が無視される）。
# 本物の環境の変数で、結果が変わらないようにする（GITHUB_ACTIONS の Linux には、JAVA_HOME が設定されている）
export SF_TOOLS_JAVA_CHECK_STAMP=/dev/null
unset JAVA_HOME SF_TOOLS_SKIP_JAVA_CHECK SF_TOOLS_JAVA_MIN_MAJOR

# check_vscode_extension（sf-init の Phase 1）も、本物の環境の設定で、結果が変わらないようにする
# （本物の VS Code の代わりに、create_mock_code の code が、拡張の一覧を返す）
unset SF_TOOLS_SKIP_VSCODE_CHECK

# TMPDIR の末尾の / を除く。macOS の TMPDIR は /var/folders/.../T/ のように / で終わり、"${TMPDIR:-/tmp}/x" が T//x になる。
# bash の cd は // を 1 つにして PWD を作るため、テストの期待値（T//x）と、スクリプトが出すパス（T/x）が食い違う
while [[ "${TMPDIR:-}" == */ && "$TMPDIR" != "/" ]]; do TMPDIR="${TMPDIR%/}"; done
export TMPDIR

# ------------------------------------------------------------------------------
# アサーション関数
# ------------------------------------------------------------------------------
pass() { echo -e "  ${CLR_PASS}[PASS]${CLR_RST} $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo -e "  ${CLR_FAIL}[FAIL]${CLR_RST} $1${2:+  → $2}"; TESTS_FAILED=$((TESTS_FAILED + 1)); }
skip() { echo -e "  \033[33m[SKIP]\033[0m $1"; }

assert_exit_ok()         { [[ $1 -eq 0 ]]  && pass "$2" || fail "$2" "終了コード: $1（期待: 0）"; }
assert_exit_fail()       { [[ $1 -ne 0 ]]  && pass "$2" || fail "$2" "終了コード 0（期待: 非ゼロ）"; }
assert_file_exists()     { [[ -f "$1" ]]   && pass "$2" || fail "$2" "ファイルが存在しない: $1"; }
assert_file_not_exists() { [[ ! -f "$1" ]] && pass "$2" || fail "$2" "ファイルが存在する: $1"; }
assert_dir_exists()      { [[ -d "$1" ]]   && pass "$2" || fail "$2" "ディレクトリが存在しない: $1"; }
assert_dir_not_exists()  { [[ ! -d "$1" ]] && pass "$2" || fail "$2" "ディレクトリが存在する: $1"; }
assert_file_contains()       { grep -qF -- "$2" "$1" 2>/dev/null && pass "$3" || fail "$3" "'$2' が '$1' に含まれていない"; }
assert_file_not_contains()   { ! grep -qF -- "$2" "$1" 2>/dev/null && pass "$3" || fail "$3" "'$2' が '$1' に含まれている"; }
assert_executable()          { [[ -x "$1" ]]   && pass "$2" || fail "$2" "実行権限がない: $1"; }
assert_equals()              { [[ "$1" == "$2" ]] && pass "$3" || fail "$3" "期待: '$2'  実際: '$1'"; }
assert_output_contains()     { echo "$1" | grep -q "$2" && pass "$3" || fail "$3" "'$2' が出力に含まれていない"; }
assert_output_not_contains() { echo "$1" | grep -q "$2" && fail "$3" "'$2' が出力に含まれている" || pass "$3"; }

# ------------------------------------------------------------------------------
# テスト環境セットアップ
# ------------------------------------------------------------------------------

# force-* テスト用ディレクトリを作成（.git/hooks 付き）
setup_force_dir() {
    local dir
    dir=$(mktemp -d "${TMPDIR:-/tmp}/force-test-XXXX")
    mkdir -p "$dir/logs" "$dir/.git/hooks" "$dir/.sf" "$dir/.sfdx" \
             "$dir/sf-tools/config" "$dir/sf-tools/release" "$dir/sf-tools/logs"
    echo "ApexClass" > "$dir/sf-tools/config/metadata.txt"
    echo '{"packageDirectories":[{"path":"force-app","default":true}],"sourceApiVersion":"66.0"}' > "$dir/sfdx-project.json"
    printf 'main\nstaging\ndevelop\n' > "$dir/sf-tools/config/branches.txt"
    echo "$dir"
}

# force-* でない通常ディレクトリを作成
setup_regular_dir() {
    local dir
    dir=$(mktemp -d "${TMPDIR:-/tmp}/regular-test-XXXX")
    mkdir -p "$dir/logs"
    echo "$dir"
}

# モックバイナリディレクトリを作成して返す
setup_mock_bin() {
    local dir
    dir=$(mktemp -d "${TMPDIR:-/tmp}/mock-bin-XXXX")
    echo "$dir"
}

# td / mb / mh を一括セット（指定した名前の変数に代入する）。MOCK_CALL_LOG も自動エクスポート。
#   nameref（local -n）は Bash 4.3 以降のため使わない（macOS 標準の Bash 3.2 で動かす）。printf -v で代入する
# 使い方: local td mb mh; setup_std_env td mb mh
setup_std_env() {
    local _sse_td _sse_mb _sse_mh
    _sse_td=$(setup_force_dir)
    _sse_mb=$(setup_mock_bin)
    _sse_mh=$(setup_mock_home)
    printf -v "$1" '%s' "$_sse_td"
    printf -v "$2" '%s' "$_sse_mb"
    printf -v "$3" '%s' "$_sse_mh"
    export MOCK_CALL_LOG="$_sse_mb/calls.log"
}

# HOME 用の仮ディレクトリを作成し、sf-tools 一式をコピー
setup_mock_home() {
    local dir
    dir=$(mktemp -d "${TMPDIR:-/tmp}/mock-home-XXXX")
    mkdir -p "$dir/sf-tools"
    # .git / logs は不要なので除外してコピー（tar で高速化）
    (cd "$SF_TOOLS_DIR" && tar cf - \
        --exclude='.git' \
        --exclude='logs' \
        . ) | tar xf - -C "$dir/sf-tools/"
    mkdir -p "$dir/sf-tools/logs" "$dir/sf-tools/config"
    echo "$dir"
}

# ask_yn を含むスクリプトのテスト用ヘルパー
# stdin に "n" を流すことで対話プロンプトのブロックを防ぐ
# 使い方: run_script_with_no "スクリプトパス" [追加引数...]
run_script_with_no() {
    echo "n" | bash "$@" 2>&1
}

# テスト環境を一括クリーンアップ（可変長引数）
teardown() {
    local arg
    for arg in "$@"; do
        [[ -n "$arg" ]] && rm -rf "$arg" 2>/dev/null
    done
}

# リリースディレクトリとターゲットリストを生成
setup_release_dir() {
    local td="$1" branch="${2:-feature/test}"
    mkdir -p "$td/sf-tools/release/$branch"
    echo "$branch" > "$td/sf-tools/release/branch_name.txt"
    # sf-check.sh のファイル存在チェックを通すため、参照ファイルを実際に作成する
    mkdir -p "$td/force-app/main/default/classes"
    touch "$td/force-app/main/default/classes/TestClass.cls"
    printf '[files]\nforce-app/main/default/classes/TestClass.cls\n' \
        > "$td/sf-tools/release/$branch/deploy-target.txt"
    printf '[files]\n' > "$td/sf-tools/release/$branch/remove-target.txt"
}

# ------------------------------------------------------------------------------
# 標準モックスクリプト生成
# ------------------------------------------------------------------------------

# git モック（MOCK_GIT_* 環境変数で挙動を制御）
create_mock_git() {
    local bin_dir="$1"
    cat > "$bin_dir/git" << 'EOF'
#!/bin/bash
echo "git $*" >> "${MOCK_CALL_LOG:-/dev/null}"
# 先頭の -c key=value（例: -c credential.helper=）は読み飛ばして、サブコマンドで分岐する
while [[ "${1:-}" == "-c" ]]; do shift 2; done
case "$1" in
    -C)
        case "$3" in
            pull) exit "${MOCK_GIT_PULL_EXIT:-0}" ;;
            symbolic-ref) echo "${MOCK_GIT_BRANCH:-feature/test}"; exit 0 ;;
            remote) echo "${MOCK_GIT_C_REMOTE_URL:-}"; exit 0 ;;   # git -C DIR remote get-url origin（完了済みのプロジェクトの判定）
            config) echo "${MOCK_GIT_C_CONFIG_VALUE:-}"; exit 0 ;;  # git -C DIR config --get sf-tools.setup-complete（完了の印。値を返す）
            push) exit "${MOCK_GIT_C_PUSH_EXIT:-0}" ;;   # git -C DIR push ...（admin ブランチを GitHub に作る処理）
            checkout)
                # git -C DIR checkout BRANCH（管理者用のクローンを admin ブランチにする処理）
                [[ -n "${MOCK_GIT_CHECKOUT_FAIL_BRANCH:-}" && "$4" == "${MOCK_GIT_CHECKOUT_FAIL_BRANCH}" ]] && exit 1
                exit 0 ;;
            rev-parse)
                # 既定では「Git リポジトリではない」を返す（sf-init の sf-tools 最新化確認をスキップさせ、
                # 対話入力を消費しないようにする）。最新化確認自体のテストは test_init-common.sh で実際の Git を使う
                [[ "$4" == "--is-inside-work-tree" ]] && exit "${MOCK_GIT_IS_REPO_EXIT:-1}"
                # admin ブランチが、すでにあるか（rev-parse --verify）。既定は「ある」。MOCK_GIT_REV_VERIFY_EXIT=1 → ない（新しく作る）
                [[ "$4" == "--verify" ]] && exit "${MOCK_GIT_REV_VERIFY_EXIT:-0}"
                exit 0 ;;
            *) exit 0 ;;
        esac ;;
    symbolic-ref)   echo "${MOCK_GIT_BRANCH:-feature/test}"; exit 0 ;;
    pull)           exit "${MOCK_GIT_PULL_EXIT:-0}" ;;
    log)
        if [[ "$*" == *"..origin/main"* ]]; then
            echo "${MOCK_GIT_LOG_MAIN_OUTPUT:-}"
        else
            echo "${MOCK_GIT_LOG_BRANCH_OUTPUT:-}"
        fi
        exit 0 ;;
    fetch)          exit 0 ;;
    push)           exit "${MOCK_GIT_PUSH_EXIT:-0}" ;;
    stash)          exit 0 ;;
    rebase)         exit "${MOCK_GIT_REBASE_EXIT:-0}" ;;
    merge)
        echo "git-merge-arg: $2" >> "${MOCK_CALL_LOG:-/dev/null}"
        exit "${MOCK_GIT_MERGE_EXIT:-0}" ;;
    checkout)
        if [[ -n "${MOCK_GIT_CHECKOUT_FAIL_BRANCH:-}" && "$2" == "${MOCK_GIT_CHECKOUT_FAIL_BRANCH}" ]]; then
            exit 1
        fi
        exit "${MOCK_GIT_CHECKOUT_EXIT:-0}" ;;
    status)         exit 0 ;;
    ls-files)       [[ -n "${MOCK_GIT_UNTRACKED:-}" ]] && printf '%s
' "$MOCK_GIT_UNTRACKED"; exit 0 ;;   # 追跡していないファイル（MOCK_GIT_UNTRACKED=<パス>）
    clone)
        _dest=""
        for _a in "$@"; do _dest="$_a"; done
        mkdir -p "$_dest/.git" "$_dest/sf-tools/config" \
                 "$_dest/sf-tools/release" "$_dest/sf-tools/logs" "$_dest/logs"
        exit "${MOCK_GIT_CLONE_EXIT:-0}" ;;
    add)            exit 0 ;;
    commit)         exit "${MOCK_GIT_COMMIT_EXIT:-0}" ;;
    diff-index)
        if [[ -n "${MOCK_GIT_DIFF_EXIT_2ND:-}" ]]; then
            _cnt_file="${MOCK_CALL_LOG%/*}/diffidx.cnt"
            _cnt=$(cat "$_cnt_file" 2>/dev/null || echo 0)
            _cnt=$((_cnt + 1))
            echo "$_cnt" > "$_cnt_file"
            [[ $_cnt -ge 2 ]] && exit "${MOCK_GIT_DIFF_EXIT_2ND}"
        fi
        exit "${MOCK_GIT_DIFF_EXIT:-0}" ;;
    config)         exit 0 ;;
    remote)         echo "https://github.com/mock-owner/mock-repo.git"; exit 0 ;;
    ls-remote)
        # MOCK_GIT_LS_REMOTE_MISSING=<ブランチ名（空白区切り）>: そのブランチだけ、リモートにない（exit 2）
        for _m in ${MOCK_GIT_LS_REMOTE_MISSING:-}; do [[ " $* " == *" $_m "* ]] && exit 2; done
        exit "${MOCK_GIT_LS_REMOTE_EXIT:-0}" ;;
    rev-list)       echo "${MOCK_GIT_REV_LIST_COUNT:-0}"; exit 0 ;;   # 未プッシュのコミットの件数（git rev-list --count origin/X..HEAD）
    update-git-for-windows) exit 0 ;;
    *)              exit 0 ;;
esac
EOF
    chmod +x "$bin_dir/git"
}

# sf（Salesforce CLI）モック
create_mock_sf() {
    local bin_dir="$1"
    cat > "$bin_dir/sf" << 'EOF'
#!/bin/bash
echo "sf $*" >> "${MOCK_CALL_LOG:-/dev/null}"
case "$1 $2" in
    "--version "*|"version "*)
        # check_sf_cli の確認用（MOCK_SF_VERSION_EXIT=1 で、成功しても終了コード 1 を返す環境を再現）
        echo "@salesforce/cli/2.152.14 win32-x64 node-v24.14.0"
        exit "${MOCK_SF_VERSION_EXIT:-0}" ;;
    "org display")
        # sf-init の一時エイリアス（sf-tools-*）は、ブラウザログインに失敗した場合は未接続として扱う
        # （MOCK_SF_LOGIN_WEB_FAIL=1。ログイン失敗の再現）
        if [[ "${MOCK_SF_LOGIN_WEB_FAIL:-}" == "1" && "$*" == *"--target-org sf-tools-"* ]]; then
            echo "Error: No authorization information found" >&2
            exit 1
        fi
        # sf org display --json の出力（JSON）。MOCK_SF_ORG_JSON=<JSON> で差し替える
        # 注意: ${VAR:-{...}} は、既定値の中の } で展開が終わり、末尾が付け足されるため、別の変数に入れる
        _org_display_default='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'
        echo "${MOCK_SF_ORG_JSON:-$_org_display_default}"
        exit "${MOCK_SF_ORG_DISPLAY_EXIT:-0}" ;;
    "org login")
        # sf org login jwt が、どのホームフォルダで実行されたかを記録する（JWT 接続テストの隔離の確認用）
        [[ "$3" == "jwt" ]] && echo "sf-jwt-env HOME=${HOME} USERPROFILE=${USERPROFILE:-}" >> "${MOCK_CALL_LOG:-/dev/null}"
        # sf org login jwt を最初の N 回だけ失敗させる（MOCK_SF_JWT_FAIL_FIRST=N。反映待ちのリトライの再現）
        if [[ "$3" == "jwt" && -n "${MOCK_SF_JWT_FAIL_FIRST:-}" ]]; then
            _jc="${MOCK_CALL_LOG%/*}/jwt.cnt"
            _n=$(( $(cat "$_jc" 2>/dev/null || echo 0) + 1 ))
            echo "$_n" > "$_jc"
            if [[ $_n -le ${MOCK_SF_JWT_FAIL_FIRST} ]]; then
                echo "Error authenticating with JWT: client identifier invalid" >&2
                exit 1
            fi
        fi
        # sf org login web の再現（MOCK_SF_LOGIN_WEB_FAIL=1: ログイン失敗 / MOCK_SF_LOGIN_WEB_EXIT=1: 成功するが終了コード 1）
        if [[ "$3" == "web" ]]; then
            if [[ "${MOCK_SF_LOGIN_WEB_FAIL:-}" == "1" ]]; then
                echo "Error (AuthTimeoutError): The authentication session timed out. Please try again." >&2
                exit 1
            fi
            echo "Successfully authorized fake@example.com with org ID 00D000000000001AAA"
            exit "${MOCK_SF_LOGIN_WEB_EXIT:-0}"
        fi
        [[ "${MOCK_SF_LOGIN_EXIT:-0}" -eq 0 ]] && echo "Successfully authorized fake@example.com with org ID 00D000000000001AAA"
        exit "${MOCK_SF_LOGIN_EXIT:-0}" ;;
    "org list")
        # sf-metasync の変更の検知（lib/metasync.js detect）の一覧: sf org list metadata --metadata-type 種類 [--folder フォルダ]。
        #   応答は、ディレクトリ MOCK_SF_LIST_DIR の <種類>.json（フォルダ付きは <種類>__<フォルダ>.json。$ や / は _ に置換）の
        #   「result」の中身（配列）。ファイルがなければ、空の一覧。MOCK_SF_LIST_FAIL=<種類> で、その種類の一覧が失敗する
        if [[ "$3" == "metadata" ]]; then
            _lt=""; _lf=""; _prev=""
            for _a in "$@"; do
                [[ "$_prev" == "--metadata-type" ]] && _lt="$_a"
                [[ "$_prev" == "--folder" ]] && _lf="$_a"
                _prev="$_a"
            done
            [[ -n "${MOCK_SF_LIST_FAIL:-}" && "$_lt" == "$MOCK_SF_LIST_FAIL" ]] && { echo '{"status":1,"message":"list failed"}'; exit 1; }
            _key="$_lt"; [[ -n "$_lf" ]] && _key="${_lt}__${_lf//[\$\/]/_}"
            if [[ -f "${MOCK_SF_LIST_DIR:-/nonexistent}/${_key}.json" ]]; then
                echo "{\"status\":0,\"result\":$(cat "${MOCK_SF_LIST_DIR}/${_key}.json")}"
            else
                echo '{"status":0,"result":[]}'
            fi
            exit 0
        fi
        # sf org list --json（ログイン済みの組織の一覧。org_find_username_by_id が使う）: 既定は 1 件
        #   （組織 ID = MOCK_SF_ORG_LIST_ID、ユーザー名 = MOCK_SF_ORG_LIST_USER）。MOCK_SF_ORG_LIST_JSON で全体を差し替え、
        #   MOCK_SF_ORG_LIST_EXIT=1 で失敗を再現する。既定の ID は、gh モックの SF_ORG_ID_PROD（MOCK_GH_ORG_ID_PROD の既定）と同じ
        if [[ "$*" == *"--json"* ]]; then
            _ol_default="{\"status\":0,\"result\":{\"nonScratchOrgs\":[{\"orgId\":\"${MOCK_SF_ORG_LIST_ID:-00D000000000001AAA}\",\"username\":\"${MOCK_SF_ORG_LIST_USER:-metasync-test@example.com}\"}]}}"
            echo "${MOCK_SF_ORG_LIST_JSON:-$_ol_default}"
            exit "${MOCK_SF_ORG_LIST_EXIT:-0}"
        fi
        exit 0 ;;
    "data query")
        # 設定変更の履歴の件数（sf-metasync の変更の検知）: SELECT COUNT() FROM SetupAuditTrail。
        #   MOCK_SF_AUDIT_COUNT=<件数>（既定 0）／ MOCK_SF_AUDIT_EXIT=1 で、問い合わせの失敗を再現する
        if [[ "$*" == *"SetupAuditTrail"* ]]; then
            [[ "${MOCK_SF_AUDIT_EXIT:-0}" -ne 0 ]] && { echo '{"status":1,"message":"query failed"}'; exit 1; }
            echo "{\"status\":0,\"result\":{\"totalSize\":${MOCK_SF_AUDIT_COUNT:-0},\"done\":true,\"records\":[]}}"
            exit 0
        fi
        # 組織の種類の取得（org_read_info: SELECT ... FROM Organization）。
        #   MOCK_SF_ORG_INFO=<JSON> で応答を差し替える。既定は Sandbox（Enterprise Edition）
        #   MOCK_SF_ORG_QUERY_EXIT=1 で、取得の失敗を再現する
        if [[ "$*" == *"FROM Organization"* ]]; then
            [[ "${MOCK_SF_ORG_QUERY_EXIT:-0}" -ne 0 ]] && { echo "Error: query failed" >&2; exit "${MOCK_SF_ORG_QUERY_EXIT}"; }
            # 注意: ${VAR:-{...}} は、既定値の中の } で展開が終わり、末尾が付け足されるため、別の変数に入れる
            _org_default='{"status":0,"result":{"records":[{"attributes":{"type":"Organization"},"Id":"00D000000000001AAA","Name":"Mock Sandbox","IsSandbox":true,"OrganizationType":"Enterprise Edition","TrialExpirationDate":null}]}}'
            echo "${MOCK_SF_ORG_INFO:-$_org_default}"
            exit 0
        fi
        # 接続ユーザーのプロファイル名の取得（sf-init の外部クライアントアプリ作成）
        echo "{\"status\":0,\"result\":{\"records\":[{\"Profile\":{\"Name\":\"${MOCK_SF_PROFILE_NAME:-System Administrator}\"}}]}}"
        exit 0 ;;
    "org logout")   exit 0 ;;
    "org open")     exit 0 ;;
    "alias unset")  exit 0 ;;
    "config set")   exit 0 ;;
    "update"|"update --no-prompt") exit 0 ;;
    "sgd source")
        OUT_DIR=""
        PREV=""
        for arg in "$@"; do
            [[ "$PREV" == "--output-dir" ]] && OUT_DIR="$arg"
            PREV="$arg"
        done
        [[ -n "$OUT_DIR" ]] && mkdir -p "$OUT_DIR/package" && echo '<Package/>' > "$OUT_DIR/package/package.xml"
        exit "${MOCK_SF_SGD_EXIT:-0}" ;;
    "project retrieve")
        # 外部クライアントアプリのコンシューマー鍵の取得を再現: ExtlClntAppGlobalOauthSettings:<名前> を指定された場合、
        # カレントの force-app 配下に consumerKey を含むファイルを作る
        _meta=""; _prev=""
        for _a in "$@"; do
            [[ "$_prev" == "--metadata" || "$_prev" == "-m" ]] && _meta="$_a"
            _prev="$_a"
        done
        if [[ "$_meta" == ExtlClntAppGlobalOauthSettings:* ]]; then
            _nm="${_meta#ExtlClntAppGlobalOauthSettings:}"
            _d="force-app/main/default/extlClntAppGlobalOauthSets"
            mkdir -p "$_d"
            printf '<ExtlClntAppGlobalOauthSettings>\n    <consumerKey>%s</consumerKey>\n</ExtlClntAppGlobalOauthSettings>\n' \
                "${MOCK_SF_CONSUMER_KEY:-3MVGMOCKCONSUMERKEY}" > "$_d/${_nm}.ecaGlblOauth-meta.xml"
        fi
        # sf-metasync の取得を再現: MOCK_SF_RETRIEVE_FILES=<パス|内容>（複数は改行区切り）を、カレント（取得先の一時プロジェクト）に書く。
        #   MOCK_SF_RETRIEVE_EXIT=<コード>: その終了コードで失敗する（MOCK_SF_RETRIEVE_ERR=<文言> を標準エラーに出す）
        #   MOCK_SF_RETRIEVE_JSON=<JSON>: 標準出力に出す応答
        if [[ -n "${MOCK_SF_RETRIEVE_EXIT:-}" ]]; then
            _rcnt="${MOCK_CALL_LOG%/*}/retrieve.cnt"; _rn=$(( $(cat "$_rcnt" 2>/dev/null || echo 0) + 1 )); echo "$_rn" > "$_rcnt"
            # MOCK_SF_RETRIEVE_FAIL_ONCE=1: 1 回目だけ失敗する（やり直しの確認）
            if [[ -z "${MOCK_SF_RETRIEVE_FAIL_ONCE:-}" || "$_rn" -eq 1 ]]; then
                echo "${MOCK_SF_RETRIEVE_ERR:-}" >&2; exit "$MOCK_SF_RETRIEVE_EXIT"
            fi
        fi
        if [[ -n "${MOCK_SF_RETRIEVE_FILES:-}" ]]; then
            while IFS="|" read -r _fp _fc; do [[ -n "$_fp" ]] || continue; mkdir -p "${_fp%/*}"; printf '%s\n' "$_fc" > "$_fp"; done <<< "$MOCK_SF_RETRIEVE_FILES"
        fi
        [[ -n "${MOCK_SF_RETRIEVE_JSON:-}" ]] && echo "$MOCK_SF_RETRIEVE_JSON"
        exit 0 ;;
    "project generate")
        # sf project generate manifest の再現:
        #   --source-dir <パス>  → パスから、種類とメンバー名を推定して、<types> に入れる
        #   --metadata <種別:名前> → そのまま <types> に入れる
        #   両方を同時に渡すと、共通部分だけ（実際の sf と同じ。モックでは、常に空）になる
        OUT_DIR=""; OUT_NAME="package.xml"; PREV=""; _src=(); _meta=()
        for arg in "$@"; do
            [[ "$PREV" == "--output-dir" ]] && OUT_DIR="$arg"
            [[ "$PREV" == "--name" ]] && OUT_NAME="$arg"
            [[ "$PREV" == "--source-dir" ]] && _src+=("$arg")
            [[ "$PREV" == "--metadata" ]] && _meta+=("$arg")
            PREV="$arg"
        done
        if [[ -n "$OUT_DIR" ]]; then
            mkdir -p "$OUT_DIR"
            {
                printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<Package xmlns="http://soap.sforce.com/2006/04/metadata">'
                if [[ ${#_src[@]} -gt 0 && ${#_meta[@]} -gt 0 ]]; then
                    :   # 共通部分だけ → 空
                else
                    for _p in "${_src[@]}"; do
                        _b="${_p##*/}"; _b="${_b%%.*}"
                        case "$_p" in
                            */classes/*)  _t="ApexClass" ;;
                            */triggers/*) _t="ApexTrigger" ;;
                            */lwc/*)      _t="LightningComponentBundle"; _b="${_p#*/lwc/}"; _b="${_b%%/*}" ;;
                            */aura/*)     _t="AuraDefinitionBundle"; _b="${_p#*/aura/}"; _b="${_b%%/*}" ;;
                            */flows/*)    _t="Flow" ;;
                            *)            _t="CustomObject" ;;
                        esac
                        printf '    <types>\n        <members>%s</members>\n        <name>%s</name>\n    </types>\n' "$_b" "$_t"
                    done
                    for _m in "${_meta[@]}"; do
                        printf '    <types>\n        <members>%s</members>\n        <name>%s</name>\n    </types>\n' "${_m#*:}" "${_m%%:*}"
                    done
                fi
                printf '%s\n' '    <version>60.0</version>' '</Package>'
            } > "$OUT_DIR/$OUT_NAME"
        fi
        exit 0 ;;
    "project deploy")
        # カレントに force-app があれば、deploy された内容をテストで検証できるよう控えを残す
        [[ -d force-app ]] && cp -r force-app "${MOCK_CALL_LOG%/*}/deployed_src" 2>/dev/null
        echo '{"status":0,"result":{"success":true}}'
        exit "${MOCK_SF_DEPLOY_EXIT:-0}" ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$bin_dir/sf"
}

# npm モック
create_mock_npm() {
    local bin_dir="$1"
    cat > "$bin_dir/npm" << 'EOF'
#!/bin/bash
echo "npm $*" >> "${MOCK_CALL_LOG:-/dev/null}"
# npm ls -g @salesforce/cli（sf が npm 版かの判定）: 既定は 1（npm 版ではない）。MOCK_NPM_LS_EXIT=0 で npm 版を再現
[[ "$1" == "ls" ]] && exit "${MOCK_NPM_LS_EXIT:-1}"
# npm --version（今の版）・npm view npm version（最新の版）: 既定は何も出力しない。MOCK_NPM_VERSION / MOCK_NPM_LATEST で版を再現
[[ "$1" == "--version" ]] && { [[ -n "${MOCK_NPM_VERSION:-}" ]] && echo "$MOCK_NPM_VERSION"; exit 0; }
[[ "$1" == "view" ]] && { [[ -n "${MOCK_NPM_LATEST:-}" ]] && echo "$MOCK_NPM_LATEST"; exit 0; }
# npm config get prefix（npm の置き場所）: MOCK_NPM_PREFIX で再現（既定は何も出力しない）
[[ "$1 $2 $3" == "config get prefix" ]] && { [[ -n "${MOCK_NPM_PREFIX:-}" ]] && echo "$MOCK_NPM_PREFIX"; exit 0; }
# npm install -g npm@latest --dry-run: 出力と終了コードを再現（既定は成功）。npm 12 は、これだけが EALLOWREMOTE で壊れる（npm/cli#9800）。
#   sf-upgrade.sh は --dry-run を使わない（使っていたら、このモックの失敗に巻き込まれて、テストが落ちる）
[[ "$*" == *"--dry-run"* ]] && { [[ -n "${MOCK_NPM_DRYRUN_OUT:-}" ]] && echo "$MOCK_NPM_DRYRUN_OUT"; exit "${MOCK_NPM_DRYRUN_EXIT:-0}"; }
# npm install -g npm@latest（npm 自身の更新）: 出力と終了コードを再現（MOCK_NPM_SELF_OUT / MOCK_NPM_SELF_EXIT。既定は MOCK_NPM_EXIT）
[[ "$*" == *"npm@latest"* ]] && { [[ -n "${MOCK_NPM_SELF_OUT:-}" ]] && echo "$MOCK_NPM_SELF_OUT"; exit "${MOCK_NPM_SELF_EXIT:-${MOCK_NPM_EXIT:-0}}"; }
exit "${MOCK_NPM_EXIT:-0}"
EOF
    chmod +x "$bin_dir/npm"
}

# code（VS Code）モック
# code --list-extensions（check_vscode_extension）には、MOCK_CODE_EXTENSIONS（改行区切り）を返す。
# 既定は、Salesforce 拡張が入っている状態（salesforce.salesforcedx-vscode）。空文字（MOCK_CODE_EXTENSIONS=）なら、何も入っていない状態
create_mock_code() {
    local bin_dir="$1"
    cat > "$bin_dir/code" << 'EOF'
#!/bin/bash
echo "code $*" >> "${MOCK_CALL_LOG:-/dev/null}"
if [[ "${1:-}" == "--list-extensions" ]]; then
    printf '%s\n' "${MOCK_CODE_EXTENSIONS-salesforce.salesforcedx-vscode}"
fi
exit "${MOCK_CODE_EXIT:-0}"
EOF
    chmod +x "$bin_dir/code"
}

# gh（GitHub CLI）モック（MOCK_GH_* 環境変数で挙動を制御）
create_mock_gh() {
    local bin_dir="$1"
    cat > "$bin_dir/gh" << 'EOF'
#!/bin/bash
echo "gh $*" >> "${MOCK_CALL_LOG:-/dev/null}"
case "$1 $2" in
    "auth status") exit "${MOCK_GH_AUTH_STATUS_EXIT:-0}" ;;
    "auth login")  exit "${MOCK_GH_AUTH_LOGIN_EXIT:-0}" ;;
    "repo create") exit "${MOCK_GH_REPO_CREATE_EXIT:-0}" ;;
    "secret set")   exit "${MOCK_GH_SECRET_SET_EXIT:-0}" ;;
    "variable set") exit "${MOCK_GH_VARIABLE_SET_EXIT:-0}" ;;
    "variable get")
        # SF_ORG_ID_PROD（main の組織の ID）は、専用の値（MOCK_GH_ORG_ID_PROD。既定は、sf モックの組織一覧の既定の ID と同じ）。
        #   MOCK_GH_ORG_ID_PROD_EXIT=1 で、読み取れない（gh の失敗・Variable がない）状態を再現する（出力なし）
        if [[ "$3" == "SF_ORG_ID_PROD" ]]; then
            [[ "${MOCK_GH_ORG_ID_PROD_EXIT:-0}" -ne 0 ]] && { echo "HTTP 404: Not Found" >&2; exit 1; }
            echo "${MOCK_GH_ORG_ID_PROD:-00D000000000001AAA}"; exit 0
        fi
        echo "${MOCK_GH_VARIABLE_GET_VALUE:-fake@example.com}" ; exit "${MOCK_GH_VARIABLE_GET_EXIT:-0}" ;;
    "api user")    echo "${MOCK_GH_API_USER:-tamashimon-org}" ;;
    # オーナー候補・既存プロジェクトの一覧（jq で絞ったあとの出力を、そのまま返す）: 改行区切り
    "api user/memberships/orgs") [[ -n "${MOCK_GH_ORGS_ADMIN:-}" ]] && printf '%s\n' "$MOCK_GH_ORGS_ADMIN"; exit 0 ;;
    "api user/orgs")             [[ -n "${MOCK_GH_ORGS_MEMBER:-}" ]] && printf '%s\n' "$MOCK_GH_ORGS_MEMBER"; exit 0 ;;
    "repo list")                 [[ -n "${MOCK_GH_REPO_LIST:-}" ]] && printf '%s\n' "$MOCK_GH_REPO_LIST"; exit 0 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$bin_dir/gh"
}

# sedi - ファイルを、その場で置換する（GNU / BSD の sed 共通。テストの中で、-i を直接使わない）
#   使い方: sedi SCRIPT FILE
sedi() {
    sed -i.bak "$1" "$2" && rm -f "$2.bak"
}

# touch_ago - ファイルの更新日時を、N 分前にする（GNU / BSD 共通。テストの中で、touch -d "2 hours ago" を直接使わない）
#   使い方: touch_ago 分 FILE...     例: touch_ago 120 "$file"
#   date の「N 分前」の書き方は、GNU（-d）と BSD（-v）で違うため、両方を試す
touch_ago() {
    local min="$1" ts; shift
    ts=$(date -d "${min} minutes ago" +'%Y%m%d%H%M.%S' 2>/dev/null || date -v "-${min}M" +'%Y%m%d%H%M.%S')
    touch -t "$ts" "$@"
}

# node モック
#   node -e '...'（lib/common.sh の json_get が JSON を読むために使う）は、本物の node に渡す
#   （JSON の読み取りを、モックで偽装しない。呼び出しの記録にも、残さない）。それ以外は、バージョンを返すだけ
#   本物の node の場所は、モックを PATH に置く前（このファイルの読み込み時）に控える。
#   WSL（run_tests.sh は Git Bash から WSL に移って実行する）には node がなく、Windows 側の node.exe だけがある場合がある
REAL_NODE_PATH="${REAL_NODE_PATH:-$(command -v node 2>/dev/null || command -v node.exe 2>/dev/null || true)}"
export SF_METASYNC_NODE="${SF_METASYNC_NODE:-$REAL_NODE_PATH}"   # sf-metasync.sh が起動する node（モックの node は -e 以外を処理しないため、本物を渡す）  # 存在確認・値の取得のため run 不使用
create_mock_node() {
    local bin_dir="$1"
    {
        echo '#!/bin/bash'
        echo "REAL_NODE='${REAL_NODE_PATH}'"
        cat << 'EOF'
if [[ "$1" == "-e" && -n "$REAL_NODE" && -x "$REAL_NODE" ]]; then
    exec "$REAL_NODE" "$@"
fi
echo "node $*" >> "${MOCK_CALL_LOG:-/dev/null}"
echo "v20.0.0"
exit 0
EOF
    } > "$bin_dir/node"
    chmod +x "$bin_dir/node"
}

# ブラウザ起動コマンドモック
# WSL では powershell.exe が実在するため、mock bin を PATH 先頭に置くことで無効化する
create_mock_browser() {
    local bin_dir="$1"
    local _cmd
    for _cmd in powershell.exe xdg-open open wslview start; do
        cat > "$bin_dir/$_cmd" << 'EOF'
#!/bin/bash
echo "$0 $*" >> "${MOCK_CALL_LOG:-/dev/null}"
exit 0
EOF
        chmod +x "$bin_dir/$_cmd"
    done
}

# openssl モック（JWT 証明書生成用）
create_mock_openssl() {
    local bin_dir="$1"
    cat > "$bin_dir/openssl" << 'EOF'
#!/bin/bash
echo "openssl $*" >> "${MOCK_CALL_LOG:-/dev/null}"
# x509 -subject（証明書の発行先の確認。generate_jwt_cert が、生成後に空でないことを確認する）: 発行先を返す
#   MOCK_OPENSSL_SUBJECT が設定されていれば、その値（空文字なら、発行先が空の証明書の再現）
if [[ "$1" == "x509" ]]; then
    case " $* " in
        *" -subject "*) echo "subject=${MOCK_OPENSSL_SUBJECT-/CN=sf-jwt-mock}"; exit "${MOCK_OPENSSL_EXIT:-0}" ;;
    esac
fi
# -out <file> を探してダミーファイルを生成する
# rsa -traditional でも同様に -out ファイルを生成（PKCS#1 変換ステップのモック）
_prev=""
for _arg in "$@"; do
    if [[ "$_prev" == "-out" ]]; then
        mkdir -p "$(dirname "$_arg")" 2>/dev/null || true
        { echo "-----BEGIN RSA PRIVATE KEY-----"; echo "FAKE KEY"; echo "-----END RSA PRIVATE KEY-----"; } > "$_arg"
    fi
    _prev="$_arg"
done
exit "${MOCK_OPENSSL_EXIT:-0}"
EOF
    chmod +x "$bin_dir/openssl"
}

# java モック（check_java_cli の確認用。java -version は、標準エラーに出力する）
#   MOCK_JAVA_VERSION=11.0.17 のように、バージョンを差し替える（既定 17.0.21。Apex 拡張の要件を満たす）
#   MOCK_JAVA_RAW='...'       を指定すると、その文字列（\n は改行）を、そのまま出力する（想定外の形式の再現用）
create_mock_java() {
    local bin_dir="$1"
    cat > "$bin_dir/java" << 'EOF'
#!/bin/bash
echo "java $*" >> "${MOCK_CALL_LOG:-/dev/null}"
if [[ -n "${MOCK_JAVA_RAW:-}" ]]; then
    printf '%b\n' "$MOCK_JAVA_RAW" >&2
    exit 0
fi
_v="${MOCK_JAVA_VERSION:-17.0.21}"
echo "openjdk version \"${_v}\" 2026-10-22 LTS" >&2
echo "OpenJDK Runtime Environment (build ${_v}+1-LTS)" >&2
echo "OpenJDK 64-Bit Server VM (build ${_v}+1-LTS, mixed mode, sharing)" >&2
exit 0
EOF
    chmod +x "$bin_dir/java"
}

# 全モックを一括生成
create_all_mocks() {
    local bin_dir="$1"
    create_mock_git "$bin_dir"
    create_mock_sf "$bin_dir"
    create_mock_java "$bin_dir"   # check_java_cli が、本物の java ではなく、これを使う（17 以上）
    create_mock_npm "$bin_dir"
    create_mock_code "$bin_dir"
    create_mock_gh "$bin_dir"
    create_mock_node "$bin_dir"
    create_mock_browser "$bin_dir"  # ブラウザ起動コマンドを無効化
    create_mock_openssl "$bin_dir"  # JWT 証明書生成コマンドを無効化
}

# ------------------------------------------------------------------------------
# テスト結果サマリー
# ------------------------------------------------------------------------------
print_summary() {
    local total=$((TESTS_PASSED + TESTS_FAILED))
    echo ""
    echo "========================================"
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${CLR_PASS}結果: ${TESTS_PASSED}/${total} 件すべて成功${CLR_RST}"
        return 0
    else
        echo -e "${CLR_FAIL}結果: ${TESTS_PASSED}/${total} 件成功 / ${TESTS_FAILED} 件失敗${CLR_RST}"
        return 1
    fi
}
