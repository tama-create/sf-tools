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
assert_output_not_contains() { echo "$1" | grep -qv "$2" && pass "$3" || fail "$3" "'$2' が出力に含まれている"; }

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
    printf 'main\nstaging\ndevelop\n' > "$dir/sf-tools/config/branches.txt"
    # 管理者ユーザー設定（check_admin_user が参照するプロジェクトローカルファイル）
    printf '# admin-users.txt\ntamashimon\n' > "$dir/sf-tools/config/admin-users.txt"
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

# td / mb / mh を一括セット（nameref 使用）。MOCK_CALL_LOG も自動エクスポート。
# 使い方: local td mb mh; setup_std_env td mb mh
setup_std_env() {
    local -n _td=$1 _mb=$2 _mh=$3
    _td=$(setup_force_dir)
    _mb=$(setup_mock_bin)
    _mh=$(setup_mock_home)
    export MOCK_CALL_LOG="$_mb/calls.log"
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
            rev-parse)
                # 既定では「Git リポジトリではない」を返す（sf-init の sf-tools 最新化確認をスキップさせ、
                # 対話入力を消費しないようにする）。最新化確認自体のテストは test_init-common.sh で実際の Git を使う
                [[ "$4" == "--is-inside-work-tree" ]] && exit "${MOCK_GIT_IS_REPO_EXIT:-1}"
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
    clone)
        _dest=""
        for _a in "$@"; do _dest="$_a"; done
        mkdir -p "$_dest/.git" "$_dest/sf-tools/config" \
                 "$_dest/sf-tools/release" "$_dest/sf-tools/logs" "$_dest/logs"
        exit "${MOCK_GIT_CLONE_EXIT:-0}" ;;
    add)            exit 0 ;;
    commit)         exit 0 ;;
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
    ls-remote)      exit "${MOCK_GIT_LS_REMOTE_EXIT:-0}" ;;
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
        # sf-start.sh の grep/cut パース（各キーが1行前提）に対応するため
        # コンパクト JSON を , と { で改行展開して出力する
        echo "${MOCK_SF_ORG_JSON:-{\"result\":{\"alias\":\"testorg\",\"id\":\"00D000000000001AAA\"}}}" \
            | sed 's/[,{]/&\n/g'
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
    "data query")
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
        exit 0 ;;
    "project generate")
        OUT_DIR=""; OUT_NAME="package.xml"; PREV=""
        for arg in "$@"; do
            [[ "$PREV" == "--output-dir" ]] && OUT_DIR="$arg"
            [[ "$PREV" == "--name" ]] && OUT_NAME="$arg"
            PREV="$arg"
        done
        [[ -n "$OUT_DIR" ]] && mkdir -p "$OUT_DIR" && \
            printf '<?xml version="1.0" encoding="UTF-8"?>\n<Package xmlns="http://soap.sforce.com/2006/04/metadata"><version>60.0</version></Package>\n' \
            > "$OUT_DIR/$OUT_NAME"
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
exit "${MOCK_NPM_EXIT:-0}"
EOF
    chmod +x "$bin_dir/npm"
}

# code（VS Code）モック
create_mock_code() {
    local bin_dir="$1"
    cat > "$bin_dir/code" << 'EOF'
#!/bin/bash
echo "code $*" >> "${MOCK_CALL_LOG:-/dev/null}"
exit 0
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
    "variable get") echo "${MOCK_GH_VARIABLE_GET_VALUE:-fake@example.com}" ; exit "${MOCK_GH_VARIABLE_GET_EXIT:-0}" ;;
    "api user")    echo "${MOCK_GH_API_USER:-tamashimon-org}" ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$bin_dir/gh"
}

# node モック
create_mock_node() {
    local bin_dir="$1"
    cat > "$bin_dir/node" << 'EOF'
#!/bin/bash
echo "node $*" >> "${MOCK_CALL_LOG:-/dev/null}"
echo "v20.0.0"
exit 0
EOF
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

# 全モックを一括生成
create_all_mocks() {
    local bin_dir="$1"
    create_mock_git "$bin_dir"
    create_mock_sf "$bin_dir"
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
