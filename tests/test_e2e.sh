#!/bin/bash
# ==============================================================================
# test_e2e.sh - tests/e2e/（実環境での sf-init 通し検証）の安全ガードと部品のテスト
# ==============================================================================
# 実際の GitHub / Salesforce には接続しない（gh / sf はモック）。
# e2e 本体（run.sh）は実環境を使うため、通常のテストには含めない。ここでは、
# 「消してはいけないものを消さない」ことを中心に確認する。
#
# 【テストケース】
#   1. 名前の判定（削除対象かどうか）
#   2. ガード（GitHub Actions 上・gh ユーザー不一致では動かない）
#   3. 削除関数は、ガードを通らない・対象外の名前なら動かない
#   4. 鍵一式の読み込み（未設定・権限）
#   5. cleanup.sh の既定（一覧のみ。何も削除しない）
#   6. cleanup.sh --yes（対象だけを削除し、他は残す）
#   7. cleanup.sh の確認（N・delete 以外の入力で中止）
#   8. sf の差し替え（login web だけを置き換え、他はそのまま渡す）
#   9. sf のエイリアスの保存・復元
#  10. sf-init に流す入力の台本
#  11. run.sh のガード（GitHub Actions 上・鍵一式なしでは動かない）
#  15. 一覧の取得に失敗したとき（再試行・「対象なし」と取り違えない）
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== tests/e2e（安全ガードと部品）===${CLR_RST}"

E2E_DIR="$SF_TOOLS_DIR/tests/e2e"

# ------------------------------------------------------------------------------
# ヘルパー: モックの gh / sf
# ------------------------------------------------------------------------------
_mk_mocks() {
    local mb="$1"
    cat > "$mb/gh" << 'EOF'
#!/bin/bash
echo "gh $*" >> "${MOCK_CALL_LOG:-/dev/null}"
case "$1 $2" in
    "api user")    echo "${MOCK_GH_API_USER:-tamashimon}" ;;
    "repo list")
        # 一覧の取得失敗の再現（MOCK_GH_LIST_FAIL_FIRST=N: 最初の N 回は失敗。all なら、ずっと失敗）
        if [[ -n "${MOCK_GH_LIST_FAIL_FIRST:-}" ]]; then
            _d="${MOCK_CALL_LOG%/*}"
            _n=$(( $(cat "$_d/ghlist.cnt" 2>/dev/null || echo 0) + 1 )); echo "$_n" > "$_d/ghlist.cnt"
            if [[ "$MOCK_GH_LIST_FAIL_FIRST" == "all" || $_n -le $MOCK_GH_LIST_FAIL_FIRST ]]; then
                echo "error connecting to api.github.com" >&2; exit 1
            fi
        fi
        for n in ${MOCK_GH_REPOS:-}; do echo "$n"; done ;;
    "repo delete") exit 0 ;;
    *)             exit 0 ;;
esac
EOF
    cat > "$mb/sf" << 'EOF'
#!/bin/bash
echo "sf $*" >> "${MOCK_CALL_LOG:-/dev/null}"
_dir="${MOCK_CALL_LOG%/*}"
case "$1 $2" in
    "alias list")
        echo '{'; echo '  "status": 0,'; echo '  "result": ['
        _first=1
        for kv in ${MOCK_SF_ALIASES:-}; do
            [[ $_first -eq 0 ]] && echo '    },'
            _first=0
            echo '    {'; echo "      \"alias\": \"${kv%%=*}\","; echo "      \"value\": \"${kv#*=}\""
        done
        [[ $_first -eq 0 ]] && echo '    }'
        echo '  ],'; echo '  "warnings": []'; echo '}' ;;
    "org display")
        # 管理用ログインの失敗の再現（MOCK_SF_ADMIN_FAIL_FIRST=N: sfdx-url のログインが N 回失敗する間は、未接続）
        if [[ -n "${MOCK_SF_ADMIN_FAIL_FIRST:-}" && "$*" == *"--target-org sf-tools-e2e-admin"* && ! -f "$_dir/admin_ok" ]]; then
            echo "Error: No authorization information found" >&2; exit 1
        fi
        # --verbose: 認証 URL を返す。新しい sf のように隠す（既定）か、MOCK_SF_DISPLAY_URL の値を返す
        if [[ "$*" == *"--verbose"* ]]; then
            echo "{\"status\":0,\"result\":{\"username\":\"admin@example.com\",\"sfdxAuthUrl\":\"${MOCK_SF_DISPLAY_URL:-[REDACTED] Use 'sf org auth show-sfdx-auth-url' to view}\"}}"
            exit 0
        fi
        echo '{"status":0,"result":{"username":"admin@example.com"}}' ;;
    "org auth")
        # sf org auth show-sfdx-auth-url（MOCK_SF_SHOW_URL=none で、使えない古い sf を再現）
        [[ "${MOCK_SF_SHOW_URL:-}" == "none" ]] && { echo "Error: command not found" >&2; exit 1; }
        echo "{\"status\":0,\"result\":{\"sfdxAuthUrl\":\"${MOCK_SF_SHOW_URL:-force://PlatformCLI::fakeshowtoken@example.my.salesforce.com}\"},\"warnings\":[\"exposes an SFDX Auth URL\"]}" ;;
    "org login")
        # sfdx-url のログインを、最初の N 回だけ失敗させる（MOCK_SF_ADMIN_FAIL_FIRST=N。一時的な失敗・再試行の再現）
        if [[ "$3" == "sfdx-url" && -n "${MOCK_SF_ADMIN_FAIL_FIRST:-}" ]]; then
            _n=$(( $(cat "$_dir/login.cnt" 2>/dev/null || echo 0) + 1 )); echo "$_n" > "$_dir/login.cnt"
            if [[ $_n -le ${MOCK_SF_ADMIN_FAIL_FIRST} ]]; then
                echo "Error (RefreshTokenAuthError): Error authenticating with the refresh token due to:" >&2
                echo "force://PlatformCLI::secretrefreshtoken123@example.my.salesforce.com" >&2
                exit 1
            fi
            : > "$_dir/admin_ok"
        fi
        exit 0 ;;
    "org list")
        # 一覧の取得失敗の再現（MOCK_SF_LIST_FAIL_FIRST=N: 最初の N 回は失敗。all なら、ずっと失敗）
        if [[ -n "${MOCK_SF_LIST_FAIL_FIRST:-}" ]]; then
            _n=$(( $(cat "$_dir/sflist.cnt" 2>/dev/null || echo 0) + 1 )); echo "$_n" > "$_dir/sflist.cnt"
            if [[ "$MOCK_SF_LIST_FAIL_FIRST" == "all" || $_n -le $MOCK_SF_LIST_FAIL_FIRST ]]; then
                echo '{"status":1,"name":"Error","message":"connection reset"}'; exit 1
            fi
        fi
        echo '{'; echo '  "status": 0,'; echo '  "result": ['
        for n in ${MOCK_SF_ECAS:-}; do
            grep -qx "$n" "$_dir/deleted.txt" 2>/dev/null && continue
            echo "    { \"fullName\": \"$n\", \"type\": \"ExternalClientApplication\" },"
        done
        echo '  ]'; echo '}' ;;
    "project deploy")
        if [[ -f destructiveChanges.xml ]]; then
            cat destructiveChanges.xml >> "${MOCK_CALL_LOG}"
            # 削除用のデプロイの失敗の再現（MOCK_SF_DEPLOY_EXIT=1: 失敗。アプリは消えない）
            [[ "${MOCK_SF_DEPLOY_EXIT:-0}" -ne 0 ]] && exit "$MOCK_SF_DEPLOY_EXIT"
            grep -oE '<members>[^<]*</members><name>ExternalClientApplication</name>' destructiveChanges.xml \
                | sed -E 's:<members>([^<]*)</members>.*:\1:' >> "$_dir/deleted.txt"
        fi
        exit 0 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$mb/gh" "$mb/sf"
}

# 鍵一式のファイルを作る（引数: 出力先 [E2E_GH_USER]）
_mk_fixture() {
    local f="$1" ghu="${2:-tamashimon}"
    {
        echo "E2E_OWNER=tamashimon-org"
        echo "E2E_GH_USER=${ghu}"
        echo "E2E_HOME_ROOT=${3:-/tmp/none/home}"
        echo "E2E_PAT_TOKEN=ghp_fakepat"
        echo "E2E_SLACK_BOT_TOKEN=xoxb-fakeslack"
        echo "E2E_SLACK_CHANNEL_ID=C01ABCDEFGH"
        echo "E2E_SFDX_AUTH_URL=force://PlatformCLI::fakeurl@example.my.salesforce.com"
    } > "$f"
    chmod 600 "$f"
}

# e2e/lib.sh の関数を、モックの PATH で実行する。引数: 実行するシェルコード
# 事前に MB（モックのフォルダ）、FX（鍵一式）、HM（HOME）をセットしておくこと
_e2e_call() {
    (
        cd "$HM" || exit 1
        export HOME="$HM" PATH="$MB:$PATH" SF_INIT_MODE=1 E2E_FIXTURE="$FX"
        bash -c "
            readonly SCRIPT_NAME=test; readonly LOG_FILE=/dev/null; readonly LOG_MODE=NEW
            source '$SF_TOOLS_DIR/lib/common.sh'
            source '$E2E_DIR/lib.sh'
            $1
        "
    ) > "$MB/out.log" 2>&1
}

# ------------------------------------------------------------------------------
# 1. 名前の判定
# ------------------------------------------------------------------------------
test_e2e_names() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 名前の判定（削除対象かどうか）${CLR_RST}"
    local mb; mb=$(setup_mock_bin); MB="$mb"; FX="$mb/fx.env"; HM="$mb"
    _e2e_call '
        e2e_is_target_repo force-e2e-20261004-103000 || echo BAD1
        e2e_is_target_repo force-test-win            && echo BAD2
        e2e_is_target_repo force-e2e-abc             && echo BAD3
        e2e_is_target_repo force-e2e-20261004-1030   && echo BAD4
        e2e_is_target_repo xforce-e2e-20261004-103000 && echo BAD5
        e2e_is_target_repo "force-e2e-20261004-103000;rm" && echo BAD6
        e2e_is_target_eca SF_TOOLS_force_e2e_20261004_103000 || echo BAD7
        e2e_is_target_eca SF_TOOLS                    && echo BAD8
        e2e_is_target_eca SF_TOOLS_force_test_win     && echo BAD9
        e2e_is_target_eca SF_TOOLS_force_e2e_abc      && echo BAD10
        e2e_is_target_project e2e-20261004-103000 || echo BAD11
        e2e_is_target_project test-win               && echo BAD12
        e2e_is_target_jwt_dir force-e2e-20261004-103000 || echo BAD13
        e2e_is_target_jwt_dir force-test-win          && echo BAD14
        [[ "$(e2e_new_project_name)" =~ ^e2e-[0-9]{8}-[0-9]{6}$ ]] || echo BAD15
        e2e_is_target_tmp e2e-run.AbCdEf        || echo BAD21
        e2e_is_target_tmp e2e-sfdx-url.AbCdEf   || echo BAD22
        e2e_is_target_tmp e2e-eca-del.123456    || echo BAD23
        e2e_is_target_tmp e2e-run.AbC           && echo BAD24
        e2e_is_target_tmp e2e-run.AbCdEf1       && echo BAD25
        e2e_is_target_tmp other.AbCdEf          && echo BAD26
        e2e_is_target_tmp "e2e-run.AbCdEf;rm"   && echo BAD27
        OSTYPE=cygwin;    e2e_is_windows || echo BAD16
        OSTYPE=msys;      e2e_is_windows || echo BAD17
        OSTYPE=mingw64;   e2e_is_windows || echo BAD18
        OSTYPE=linux-gnu; e2e_is_windows && echo BAD19
        OSTYPE=darwin22;  e2e_is_windows && echo BAD20
        echo DONE'
    assert_file_contains     "$mb/out.log" "DONE"  "判定の関数が最後まで実行された"
    assert_file_not_contains "$mb/out.log" "BAD"   "対象は一致し、対象外（他のリポジトリ・アプリ・不正な名前）は一致しない"
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# 2. ガード
# ------------------------------------------------------------------------------
test_e2e_guard() {
    echo ""; echo -e "${CLR_HEAD}[TEST] ガード（GitHub Actions 上・gh ユーザー不一致では動かない）${CLR_RST}"
    local mb; mb=$(setup_mock_bin); MB="$mb"; FX="$mb/fx.env"; HM="$mb"
    export MOCK_CALL_LOG="$mb/calls.log"; _mk_mocks "$mb"; _mk_fixture "$FX"

    _e2e_call 'e2e_load_fixture; e2e_guard_env; echo "GUARD=${E2E_GUARD_OK}"'
    assert_file_contains "$mb/out.log" "GUARD=1" "正常: ガードを通る（E2E_GUARD_OK=1）"

    GITHUB_ACTIONS=true _e2e_call 'e2e_load_fixture; e2e_guard_env; echo "GUARD=${E2E_GUARD_OK}"'
    assert_file_not_contains "$mb/out.log" "GUARD=1" "GitHub Actions 上では、ガードを通らない"
    assert_file_contains     "$mb/out.log" "GitHub Actions 上では" "その旨が表示される"

    MOCK_GH_API_USER=someone-else _e2e_call 'e2e_load_fixture; e2e_guard_env; echo "GUARD=${E2E_GUARD_OK}"'
    assert_file_not_contains "$mb/out.log" "GUARD=1" "gh のユーザーが E2E_GH_USER と違うと、ガードを通らない"
    assert_file_contains     "$mb/out.log" "一致しません" "その旨が表示される"

    unset MOCK_CALL_LOG
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# 3. 削除関数のガード
# ------------------------------------------------------------------------------
test_e2e_delete_guards() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 削除関数は、ガードを通らない・対象外の名前なら動かない${CLR_RST}"
    local mb; mb=$(setup_mock_bin); MB="$mb"; FX="$mb/fx.env"; HM="$mb"
    export MOCK_CALL_LOG="$mb/calls.log"; _mk_mocks "$mb"; _mk_fixture "$FX"
    : > "$MOCK_CALL_LOG"

    _e2e_call 'e2e_load_fixture; e2e_delete_repo force-e2e-20261004-103000'
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete" "ガードを通っていないと、リポジトリを削除しない"

    _e2e_call 'e2e_load_fixture; e2e_guard_env; e2e_delete_repo force-test-win'
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete" "対象外の名前（force-test-win）は削除しない"

    _e2e_call 'e2e_load_fixture; e2e_guard_env; e2e_delete_repo "force-e2e-20261004-103000 force-test-win"'
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete" "空白を含む名前（複数指定）は削除しない"

    _e2e_call 'e2e_load_fixture; e2e_guard_env; e2e_delete_eca SF_TOOLS'
    assert_file_not_contains "$MOCK_CALL_LOG" "project deploy" "対象外のアプリ（SF_TOOLS）は削除しない"

    _e2e_call 'e2e_load_fixture; e2e_guard_env; e2e_delete_local /tmp/some/test-win; echo DONE'
    assert_file_not_contains "$MB/out.log" "DONE" "対象外のフォルダ名は削除しない（異常終了する）"

    _e2e_call 'e2e_load_fixture; e2e_guard_env; e2e_delete_repo force-e2e-20261004-103000'
    assert_file_contains "$MOCK_CALL_LOG" "gh repo delete tamashimon-org/force-e2e-20261004-103000 --yes" "対象の名前は削除する（オーナーは鍵一式の E2E_OWNER）"

    unset MOCK_CALL_LOG
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# 4. 鍵一式の読み込み
# ------------------------------------------------------------------------------
test_e2e_fixture() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 鍵一式の読み込み${CLR_RST}"
    local mb; mb=$(setup_mock_bin); MB="$mb"; FX="$mb/fx.env"; HM="$mb"
    export MOCK_CALL_LOG="$mb/calls.log"; _mk_mocks "$mb"

    FX="$mb/none.env" _e2e_call 'e2e_load_fixture; echo LOADED'
    assert_file_not_contains "$mb/out.log" "LOADED" "ファイルが無いと、読み込みに失敗する"

    _mk_fixture "$FX"; sed -i '/E2E_PAT_TOKEN/d' "$FX"
    _e2e_call 'e2e_load_fixture; echo LOADED'
    assert_file_not_contains "$mb/out.log" "LOADED" "必須の項目が未設定だと、読み込みに失敗する"
    assert_file_contains     "$mb/out.log" "E2E_PAT_TOKEN が未設定" "未設定の項目名が表示される"

    if [[ "$OSTYPE" != "msys"* && "$OSTYPE" != "mingw"* && "$OSTYPE" != "cygwin"* ]]; then
        _mk_fixture "$FX"; chmod 644 "$FX"
        _e2e_call 'e2e_load_fixture; echo LOADED'
        assert_file_not_contains "$mb/out.log" "LOADED" "権限が 600 でないと、読み込みに失敗する"
        _mk_fixture "$FX"
        _e2e_call 'e2e_load_fixture; echo LOADED'
        assert_file_contains     "$mb/out.log" "LOADED" "権限が 600 なら、読み込める"
    fi

    unset MOCK_CALL_LOG
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# cleanup.sh 用: 対象と対象外が混在する環境を作る
#   戻り値（変数）: CB=ベースdir
# ------------------------------------------------------------------------------
_mk_cleanup_env() {
    CB=$(mktemp -d "${TMPDIR:-/tmp}/test-e2e-cl-XXXX")
    MB="$CB/bin"; mkdir -p "$MB"; HM="$CB/home-dir"; mkdir -p "$HM"
    FX="$CB/fx.env"
    _mk_mocks "$MB"
    _mk_fixture "$FX" tamashimon "$CB/root/home"
    export MOCK_CALL_LOG="$MB/calls.log"; : > "$MOCK_CALL_LOG"
    export MOCK_GH_REPOS="force-e2e-20260101-000000 force-test-win force-e2e-abc force-e2e-20260102-010101"
    export MOCK_SF_ECAS="SF_TOOLS SF_TOOLS_force_test_win SF_TOOLS_force_e2e_20260101_000000"
    mkdir -p "$CB/root/home/tamashimon-org/e2e-20260101-000000" "$CB/root/home/tamashimon-org/test-win" \
             "$HM/.sf-jwt/force-e2e-20260101-000000" "$HM/.sf-jwt/force-test-win"
}

_run_cleanup() {  # 引数: オプション。標準入力はそのまま使う
    (
        cd "$HM" || exit 1
        export HOME="$HM" PATH="$MB:$PATH" E2E_FIXTURE="$FX"
        bash "$E2E_DIR/cleanup.sh" "$@"
    ) > "$MB/out.log" 2>&1
}

# ------------------------------------------------------------------------------
# 5. cleanup.sh の既定（一覧のみ）
# ------------------------------------------------------------------------------
test_e2e_cleanup_list() {
    echo ""; echo -e "${CLR_HEAD}[TEST] cleanup.sh の既定は、一覧のみ（何も削除しない）${CLR_RST}"
    _mk_cleanup_env
    _run_cleanup; local rc=$?
    assert_exit_ok "$rc" "一覧のみ → 終了コード 0"
    assert_file_contains     "$MB/out.log" "GitHub: tamashimon-org/force-e2e-20260101-000000" "対象のリポジトリが一覧に出る"
    assert_file_contains     "$MB/out.log" "GitHub: tamashimon-org/force-e2e-20260102-010101" "対象のリポジトリ（2 件目）が一覧に出る"
    assert_file_not_contains "$MB/out.log" "force-test-win"  "対象外のリポジトリは一覧に出ない"
    assert_file_not_contains "$MB/out.log" "force-e2e-abc"   "形式が違うリポジトリは一覧に出ない"
    assert_file_contains     "$MB/out.log" "Salesforce: SF_TOOLS_force_e2e_20260101_000000" "対象のアプリが一覧に出る"
    assert_file_not_contains "$MB/out.log" "Salesforce: SF_TOOLS_force_test_win" "対象外のアプリは一覧に出ない"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete"      "リポジトリを削除しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "post-destructive"    "アプリを削除しない"
    assert_dir_exists "$CB/root/home/tamashimon-org/e2e-20260101-000000" "ローカルの作業フォルダが残っている"
    assert_dir_exists "$HM/.sf-jwt/force-e2e-20260101-000000"            "ローカルの証明書フォルダが残っている"
    unset MOCK_CALL_LOG MOCK_GH_REPOS MOCK_SF_ECAS
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 6. cleanup.sh --yes（対象だけを削除する）
# ------------------------------------------------------------------------------
test_e2e_cleanup_delete() {
    echo ""; echo -e "${CLR_HEAD}[TEST] cleanup.sh --yes は、対象だけを削除し、他は残す${CLR_RST}"
    _mk_cleanup_env
    _run_cleanup --yes --no-confirm; local rc=$?
    assert_exit_ok "$rc" "削除 → 終了コード 0"
    assert_file_contains     "$MOCK_CALL_LOG" "gh repo delete tamashimon-org/force-e2e-20260101-000000 --yes" "対象のリポジトリを削除する"
    assert_file_contains     "$MOCK_CALL_LOG" "gh repo delete tamashimon-org/force-e2e-20260102-010101 --yes" "対象のリポジトリ（2 件目）を削除する"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete tamashimon-org/force-test-win" "対象外のリポジトリ（force-test-win）は削除しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "force-e2e-abc"                              "形式が違うリポジトリは削除しない"
    assert_file_contains     "$MOCK_CALL_LOG" "post-destructive-changes destructiveChanges.xml" "アプリを削除用のデプロイで消す"
    assert_file_contains     "$MOCK_CALL_LOG" "<members>SF_TOOLS_force_e2e_20260101_000000</members><name>ExternalClientApplication</name>" "対象のアプリ本体を指定する"
    assert_file_contains     "$MOCK_CALL_LOG" "<members>SF_TOOLS_force_e2e_20260101_000000_glbloauth</members><name>ExtlClntAppGlobalOauthSettings</name>" "構成要素（グローバル OAuth 設定）も指定する"
    assert_file_contains     "$MOCK_CALL_LOG" "<name>ExtlClntAppOauthConfigurablePolicies</name>" "構成要素（OAuth ポリシー）も指定する"
    assert_file_contains     "$MOCK_CALL_LOG" "<name>ExtlClntAppConfigurablePolicies</name>"      "構成要素（ポリシー）も指定する"
    assert_file_not_contains "$MOCK_CALL_LOG" "<members>SF_TOOLS</members>"                 "元からあるアプリ（SF_TOOLS）は削除しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "SF_TOOLS_force_test_win"                    "対象外のアプリ（SF_TOOLS_force_test_win）は削除しない"
    assert_dir_not_exists "$CB/root/home/tamashimon-org/e2e-20260101-000000" "対象のローカル作業フォルダを削除する"
    assert_dir_not_exists "$HM/.sf-jwt/force-e2e-20260101-000000"            "対象の証明書フォルダを削除する"
    assert_dir_exists     "$CB/root/home/tamashimon-org/test-win"            "対象外の作業フォルダ（test-win）は残る"
    assert_dir_exists     "$HM/.sf-jwt/force-test-win"                       "対象外の証明書フォルダ（force-test-win）は残る"
    assert_file_contains  "$MOCK_CALL_LOG" "sf alias unset sf-tools-e2e-admin" "終了時に、管理用の一時エイリアスを外す"
    unset MOCK_CALL_LOG MOCK_GH_REPOS MOCK_SF_ECAS
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 7. cleanup.sh の確認
# ------------------------------------------------------------------------------
test_e2e_cleanup_confirm() {
    echo ""; echo -e "${CLR_HEAD}[TEST] cleanup.sh --yes の確認（N・delete 以外の入力で中止）${CLR_RST}"
    _mk_cleanup_env
    printf 'N' | _run_cleanup --yes; local rc=$?
    assert_exit_fail "$rc" "確認で N → 中止"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete" "確認で N → 削除しない"

    printf 'Ynodelete\n' | _run_cleanup --yes; rc=$?
    assert_exit_fail "$rc" "delete 以外の入力 → 中止"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete" "delete 以外の入力 → 削除しない"

    printf 'Ydelete\n' | _run_cleanup --yes; rc=$?
    assert_exit_ok "$rc" "delete と入力 → 削除を実行"
    assert_file_contains "$MOCK_CALL_LOG" "gh repo delete tamashimon-org/force-e2e-20260101-000000 --yes" "delete と入力 → リポジトリを削除する"
    unset MOCK_CALL_LOG MOCK_GH_REPOS MOCK_SF_ECAS
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 8. sf の差し替え
# ------------------------------------------------------------------------------
test_e2e_sf_shim() {
    echo ""; echo -e "${CLR_HEAD}[TEST] sf の差し替え（login web だけを置き換え、他はそのまま渡す）${CLR_RST}"
    local b mb sd; b=$(mktemp -d "${TMPDIR:-/tmp}/test-e2e-shim-XXXX")
    mb="$b/real"; sd="$b/shim"; mkdir -p "$mb" "$sd"
    export MOCK_CALL_LOG="$b/calls.log"; : > "$MOCK_CALL_LOG"
    _mk_mocks "$mb"
    cp "$E2E_DIR/shims/sf" "$sd/sf"; chmod +x "$sd/sf"
    printf 'force://PlatformCLI::fakeurl@example.my.salesforce.com' > "$b/url.txt"

    ( export E2E_SHIM_DIR="$sd" E2E_SFDX_URL_FILE="$b/url.txt" PATH="$sd:$mb:$PATH"
      sf org login web --instance-url https://login.salesforce.com --alias sf-tools-PROD ) > /dev/null 2>&1
    assert_file_contains     "$MOCK_CALL_LOG" "sf org login sfdx-url --sfdx-url-file $b/url.txt --alias sf-tools-PROD" "login web は、認証 URL でのログインに置き換わる（エイリアスを引き継ぐ）"
    assert_file_not_contains "$MOCK_CALL_LOG" "org login web" "本物の login web（ブラウザ）は呼ばれない"

    : > "$MOCK_CALL_LOG"
    ( export E2E_SHIM_DIR="$sd" E2E_SFDX_URL_FILE="$b/url.txt" PATH="$sd:$mb:$PATH"
      sf project deploy start --source-dir force-app --target-org sf-tools-PROD ) > /dev/null 2>&1
    assert_file_contains "$MOCK_CALL_LOG" "sf project deploy start --source-dir force-app --target-org sf-tools-PROD" "login web 以外は、本物の sf にそのまま渡る"

    : > "$MOCK_CALL_LOG"
    ( export E2E_SHIM_DIR="$sd" E2E_SFDX_URL_FILE="$b/none.txt" PATH="$sd:$mb:$PATH"
      sf org login web --alias x ) > /dev/null 2>&1
    assert_exit_fail $? "認証 URL のファイルが無いと、失敗する"
    assert_file_not_contains "$MOCK_CALL_LOG" "org login" "認証 URL のファイルが無いと、ログインを呼ばない"

    unset MOCK_CALL_LOG
    teardown "$b"
}

# ------------------------------------------------------------------------------
# 9. sf のエイリアスの保存・復元
# ------------------------------------------------------------------------------
test_e2e_alias_restore() {
    echo ""; echo -e "${CLR_HEAD}[TEST] sf のエイリアスの保存・復元${CLR_RST}"
    local mb; mb=$(setup_mock_bin); MB="$mb"; FX="$mb/fx.env"; HM="$mb"
    export MOCK_CALL_LOG="$mb/calls.log"; _mk_mocks "$mb"

    MOCK_SF_ALIASES="DevHub=hub@example.com develop=dev@example.com" _e2e_call 'e2e_alias_snapshot "'"$mb"'/snap.txt"'
    assert_file_contains "$mb/snap.txt" "DevHub=hub@example.com" "エイリアスを保存できる（1 件目）"
    assert_file_contains "$mb/snap.txt" "develop=dev@example.com" "エイリアスを保存できる（2 件目）"

    # テスト中に、prod が増え、develop の指す先が変わった状態
    : > "$MOCK_CALL_LOG"
    MOCK_SF_ALIASES="DevHub=hub@example.com develop=CHANGED@example.com prod=p@example.com" \
        _e2e_call 'e2e_alias_restore "'"$mb"'/snap.txt"'
    assert_file_contains     "$MOCK_CALL_LOG" "sf alias unset prod"                    "増えたエイリアス（prod）は外す"
    assert_file_contains     "$MOCK_CALL_LOG" "sf alias set develop=dev@example.com"   "指す先が変わったエイリアス（develop）は元に戻す"
    assert_file_not_contains "$MOCK_CALL_LOG" "sf alias set DevHub"                    "変わっていないエイリアスは触らない"
    assert_file_not_contains "$MOCK_CALL_LOG" "sf alias unset develop"                 "元からあったエイリアスは外さない"

    # テスト中に、develop が消えた状態
    : > "$MOCK_CALL_LOG"
    MOCK_SF_ALIASES="DevHub=hub@example.com" _e2e_call 'e2e_alias_restore "'"$mb"'/snap.txt"'
    assert_file_contains "$MOCK_CALL_LOG" "sf alias set develop=dev@example.com" "消えたエイリアスは付け直す"

    unset MOCK_CALL_LOG
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# 10. sf-init に流す入力の台本
# ------------------------------------------------------------------------------
test_e2e_input() {
    echo ""; echo -e "${CLR_HEAD}[TEST] sf-init に流す入力の台本${CLR_RST}"
    local mb out; mb=$(setup_mock_bin); MB="$mb"; FX="$mb/fx.env"; HM="$mb"
    export MOCK_CALL_LOG="$mb/calls.log"; _mk_mocks "$mb"; _mk_fixture "$FX"
    _e2e_call 'e2e_load_fixture; e2e_make_input'
    out=$(cat "$mb/out.log")
    local expected
    expected=$'Y\nY\n2\nY\n3\nghp_fakepat\n\nxoxb-fakeslack\nC01ABCDEFGH\n\n2\nN\nN'
    assert_equals "$out" "$expected" "台本が、質問の順番どおりである（Y→Y→2→Y→3→PAT→空→Slack→ID→空→2→N→N）"
    unset MOCK_CALL_LOG
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# 11. run.sh のガード
# ------------------------------------------------------------------------------
test_e2e_run_guard() {
    echo ""; echo -e "${CLR_HEAD}[TEST] run.sh のガード（GitHub Actions 上・鍵一式なしでは動かない）${CLR_RST}"
    _mk_cleanup_env
    local rc

    ( cd "$HM" && export HOME="$HM" PATH="$MB:$PATH" E2E_FIXTURE="$FX" GITHUB_ACTIONS=true
      printf 'Y' | bash "$E2E_DIR/run.sh" ) > "$MB/out.log" 2>&1; rc=$?
    assert_exit_fail "$rc" "GitHub Actions 上では、run.sh は中止する"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete" "GitHub Actions 上では、何も削除しない"

    ( cd "$HM" && export HOME="$HM" PATH="$MB:$PATH" E2E_FIXTURE="$CB/none.env"
      printf 'Y' | bash "$E2E_DIR/run.sh" ) > "$MB/out.log" 2>&1; rc=$?
    assert_exit_fail "$rc" "鍵一式が無いと、run.sh は中止する"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete" "鍵一式が無いと、何も削除しない"

    ( cd "$HM" && export HOME="$HM" PATH="$MB:$PATH" E2E_FIXTURE="$FX"
      printf 'N' | bash "$E2E_DIR/run.sh" ) > "$MB/out.log" 2>&1; rc=$?
    assert_exit_fail "$rc" "確認で N → run.sh は中止する"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete" "確認で N → 何も削除しない"

    local f
    for f in run.sh cleanup.sh bootstrap.sh; do
        bash "$E2E_DIR/$f" --help 2>&1 | grep -q "オプション\|処理の流れ" \
            && pass "${f} --help が表示できる" || fail "${f} --help が表示できる"
    done
    unset MOCK_CALL_LOG MOCK_GH_REPOS MOCK_SF_ECAS
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 12. 認証 URL の検証と取得
# ------------------------------------------------------------------------------
test_e2e_sfdx_url() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 認証 URL の検証と取得（新しい sf は --verbose で隠すため）${CLR_RST}"
    local mb out; mb=$(setup_mock_bin); MB="$mb"; FX="$mb/fx.env"; HM="$mb"
    export MOCK_CALL_LOG="$mb/calls.log"; _mk_mocks "$mb"; _mk_fixture "$FX"

    # 形式の判定
    _e2e_call '
        e2e_valid_sfdx_url "force://PlatformCLI::abc123.def@host.my.salesforce.com"            || echo BAD1
        e2e_valid_sfdx_url "force://clientid:clientsecret:abc123@host.my.salesforce.com"       || echo BAD2
        e2e_valid_sfdx_url "[REDACTED] Use '"'"'sf org auth show-sfdx-auth-url'"'"' to view"      && echo BAD3
        e2e_valid_sfdx_url ""                                                                  && echo BAD4
        e2e_valid_sfdx_url "force://x@y"                                                       && echo BAD5
        e2e_valid_sfdx_url "https://PlatformCLI::abc@host"                                     && echo BAD6
        e2e_valid_sfdx_url "force://PlatformCLI::abc@host extra"                               && echo BAD7
        echo DONE'
    assert_file_contains     "$mb/out.log" "DONE" "形式の判定が最後まで実行された"
    assert_file_not_contains "$mb/out.log" "BAD"  "認証 URL の形式は通り、隠された文章・不正な形式は通らない"

    # 鍵一式の読み込みで、形式の違う認証 URL を拒否する
    _mk_fixture "$FX"; sed -i "s|^E2E_SFDX_AUTH_URL=.*|E2E_SFDX_AUTH_URL='[REDACTED] Use sf org auth show-sfdx-auth-url to view'|" "$FX"
    _e2e_call 'e2e_load_fixture; echo LOADED'
    assert_file_not_contains "$mb/out.log" "LOADED" "鍵一式の認証 URL が隠された文章だと、読み込みに失敗する"
    assert_file_contains     "$mb/out.log" "認証 URL の形式ではありません" "その旨が表示される"
    _mk_fixture "$FX"

    # 取得: 新しい sf（show-sfdx-auth-url が使える）
    _e2e_call 'u=$(e2e_get_sfdx_auth_url prod); echo "URL=[$u]"'
    assert_file_contains "$mb/out.log" "URL=[force://PlatformCLI::fakeshowtoken@example.my.salesforce.com]" "新しい sf: show-sfdx-auth-url から取得できる"

    # 取得: 古い sf（show が使えず、display --verbose に認証 URL がある）
    MOCK_SF_SHOW_URL=none MOCK_SF_DISPLAY_URL="force://PlatformCLI::olddisplaytoken@example.my.salesforce.com" \
        _e2e_call 'u=$(e2e_get_sfdx_auth_url prod); echo "URL=[$u]"'
    assert_file_contains "$mb/out.log" "URL=[force://PlatformCLI::olddisplaytoken@example.my.salesforce.com]" "古い sf: display --verbose から取得できる"

    # 取得: show が不正な値を返す → display にフォールバック
    MOCK_SF_SHOW_URL="[REDACTED]" MOCK_SF_DISPLAY_URL="force://PlatformCLI::fallbacktoken@example.my.salesforce.com" \
        _e2e_call 'u=$(e2e_get_sfdx_auth_url prod); echo "URL=[$u]"'
    assert_file_contains "$mb/out.log" "URL=[force://PlatformCLI::fallbacktoken@example.my.salesforce.com]" "show が不正な値 → display にフォールバックする"

    # 取得: どちらでも取れない（show が使えず、display は隠される）→ 失敗（隠された文章を返さない）
    MOCK_SF_SHOW_URL=none _e2e_call 'u=$(e2e_get_sfdx_auth_url prod); rc=$?; echo "RC=$rc URL=[$u]"'
    assert_file_contains     "$mb/out.log" "RC=1 URL=[]" "どちらでも取れない → 空で、戻り値 1"
    assert_file_not_contains "$mb/out.log" "REDACTED"   "隠された文章を、認証 URL として返さない"

    unset MOCK_CALL_LOG
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# 13. 管理用ログインの失敗時の表示と再試行
# ------------------------------------------------------------------------------
test_e2e_admin_login_retry() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 管理用ログイン: 失敗時に原因を表示し、1 回だけやり直す${CLR_RST}"
    local mb n; mb=$(setup_mock_bin); MB="$mb"; FX="$mb/fx.env"; HM="$mb"
    export MOCK_CALL_LOG="$mb/calls.log"; _mk_mocks "$mb"; _mk_fixture "$FX"
    export E2E_ADMIN_RETRY_WAIT=0
    local script='e2e_load_fixture; e2e_guard_env; e2e_sf_admin_login; echo LOGGED_IN'
    _attempts() { grep -c "^sf org login sfdx-url" "$MOCK_CALL_LOG"; }
    _reset() { rm -f "$mb/login.cnt" "$mb/admin_ok"; : > "$MOCK_CALL_LOG"; }

    _reset; _e2e_call "$script"
    assert_file_contains "$mb/out.log" "LOGGED_IN" "正常: 1 回でログインできる"
    [[ "$(_attempts)" -eq 1 ]] && pass "正常: 試行は 1 回" || fail "正常: 試行は 1 回" "試行: $(_attempts)"

    _reset; MOCK_SF_ADMIN_FAIL_FIRST=1 _e2e_call "$script"
    assert_file_contains "$mb/out.log" "LOGGED_IN" "1 回目が失敗しても、やり直してログインできる"
    [[ "$(_attempts)" -eq 2 ]] && pass "1 回目が失敗 → 試行は 2 回" || fail "1 回目が失敗 → 試行は 2 回" "試行: $(_attempts)"
    assert_file_contains "$mb/out.log" "管理用ログインに失敗しました（1/2）" "1 回目の失敗が、表示される"

    _reset; MOCK_SF_ADMIN_FAIL_FIRST=2 _e2e_call "$script"
    assert_file_not_contains "$mb/out.log" "LOGGED_IN" "2 回とも失敗 → 中断する"
    [[ "$(_attempts)" -eq 2 ]] && pass "2 回とも失敗 → 試行は 2 回で、止まる" || fail "2 回とも失敗 → 試行は 2 回で、止まる" "試行: $(_attempts)"
    assert_file_contains     "$mb/out.log" "RefreshTokenAuthError" "失敗時に、sf の出力（原因）が表示される"
    assert_file_contains     "$mb/out.log" "***masked***"          "認証 URL のリフレッシュトークンは、伏せ字で表示される"
    assert_file_not_contains "$mb/out.log" "secretrefreshtoken123" "リフレッシュトークンの値は、画面に出ない"
    assert_file_contains     "$mb/out.log" "管理用ログインに失敗しました。" "最後に、失敗の旨で中断する"

    unset -f _attempts _reset
    unset MOCK_CALL_LOG E2E_ADMIN_RETRY_WAIT
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# 14. 強制終了で残った一時ファイル・フォルダの掃除
# ------------------------------------------------------------------------------
test_e2e_tmp_cleanup() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 強制終了で残った一時ファイル・フォルダの掃除（認証 URL を含むことがある）${CLR_RST}"
    _mk_cleanup_env
    local t="$CB/tmpdir"; mkdir -p "$t"
    # 掃除の対象（古い）
    mkdir -p "$t/e2e-run.AbCdEf" "$t/e2e-eca-del.123456"
    echo secret > "$t/e2e-run.AbCdEf/sfdx-url.txt"
    echo secret > "$t/e2e-sfdx-url.QwErTy"
    # 対象外: 新しいもの（別の実行の途中かもしれない）、実行中の run.sh のもの、名前が違うもの
    mkdir -p "$t/e2e-run.NewOne" "$t/e2e-run.Curren" "$t/e2e-run.toolong1" "$t/other.AbCdEf" "$t/e2e-run.AbC"
    touch -d "2 hours ago" "$t/e2e-run.AbCdEf" "$t/e2e-run.AbCdEf/sfdx-url.txt" "$t/e2e-eca-del.123456" "$t/e2e-sfdx-url.QwErTy" \
        "$t/e2e-run.Curren" "$t/e2e-run.toolong1" "$t/other.AbCdEf" "$t/e2e-run.AbC"

    # 一覧（実行中の run.sh の一時フォルダは、E2E_TMP で除外される）
    TMPDIR="$t" E2E_TMP="$t/e2e-run.Curren" _e2e_call 'e2e_load_fixture; e2e_guard_env; e2e_list_target_local'
    assert_file_contains     "$MB/out.log" "$t/e2e-run.AbCdEf"       "古い e2e-run.* が、掃除の対象になる"
    assert_file_contains     "$MB/out.log" "$t/e2e-eca-del.123456"   "古い e2e-eca-del.* が、掃除の対象になる"
    assert_file_contains     "$MB/out.log" "$t/e2e-sfdx-url.QwErTy"  "古い e2e-sfdx-url.*（ファイル）が、掃除の対象になる"
    assert_file_not_contains "$MB/out.log" "e2e-run.NewOne"          "新しいもの（30 分以内）は、対象外"
    assert_file_not_contains "$MB/out.log" "e2e-run.Curren"          "実行中の run.sh の一時フォルダ（E2E_TMP）は、対象外"
    assert_file_not_contains "$MB/out.log" "toolong1"                "名前の形式が違うもの（文字数が違う）は、対象外"
    assert_file_not_contains "$MB/out.log" "other.AbCdEf"            "ほかの名前は、対象外"

    # cleanup.sh（既定は一覧のみ。何も消さない）
    TMPDIR="$t" _run_cleanup
    assert_dir_exists "$t/e2e-run.AbCdEf" "一覧のみの間は、一時フォルダを消さない"

    # cleanup.sh --yes --no-confirm（対象だけを消す）
    TMPDIR="$t" _run_cleanup --yes --no-confirm; local rc=$?
    assert_exit_ok "$rc" "削除 → 終了コード 0"
    assert_dir_not_exists "$t/e2e-run.AbCdEf"     "古い e2e-run.* を削除する"
    assert_dir_not_exists "$t/e2e-eca-del.123456" "古い e2e-eca-del.* を削除する"
    assert_file_not_exists "$t/e2e-sfdx-url.QwErTy" "古い e2e-sfdx-url.* を削除する"
    assert_dir_exists "$t/e2e-run.NewOne"   "新しいものは残る"
    assert_dir_exists "$t/e2e-run.toolong1" "名前の形式が違うものは残る"
    assert_dir_exists "$t/other.AbCdEf"     "ほかの名前は残る"

    # 削除関数は、対象外の名前なら動かない
    _e2e_call 'e2e_load_fixture; e2e_guard_env; e2e_delete_local "'"$t"'/other.AbCdEf"; echo DONE'
    assert_file_not_contains "$MB/out.log" "DONE" "対象外の名前は、削除しない（異常終了する）"
    assert_dir_exists "$t/other.AbCdEf" "対象外のフォルダが残っている"

    unset MOCK_CALL_LOG MOCK_GH_REPOS MOCK_SF_ECAS
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 15. 一覧の取得に失敗したとき（「対象なし」と取り違えない）
#   背景: 一覧の取得に失敗したのを「対象なし」とみなし、アプリが削除されないまま e2e が「成功」した実例がある
# ------------------------------------------------------------------------------
test_e2e_list_failure() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 一覧の取得に失敗したとき: 再試行し、それでも失敗なら「対象なし」とみなさない${CLR_RST}"
    _mk_cleanup_env
    export E2E_LIST_RETRY_WAIT=0
    local fn='e2e_load_fixture; e2e_guard_env; out=$(e2e_list_target_ecas); rc=$?; echo "RC=$rc OUT=[$out]"'
    _reset() { rm -f "$MB/sflist.cnt" "$MB/ghlist.cnt"; : > "$MOCK_CALL_LOG"; }

    # --- Salesforce 側（関数）---
    _reset; _e2e_call "$fn"
    assert_file_contains "$MB/out.log" "RC=0 OUT=[SF_TOOLS_force_e2e_20260101_000000]" "正常: 一覧が取れる"

    _reset; MOCK_SF_LIST_FAIL_FIRST=2 _e2e_call "$fn"
    assert_file_contains "$MB/out.log" "RC=0 OUT=[SF_TOOLS_force_e2e_20260101_000000]" "2 回失敗しても、3 回目で取れる（再試行）"
    [[ "$(grep -c '^sf org list' "$MOCK_CALL_LOG")" -eq 3 ]] && pass "再試行は 3 回までで、取れたら止まる" || fail "再試行は 3 回までで、取れたら止まる" "回数: $(grep -c '^sf org list' "$MOCK_CALL_LOG")"

    _reset; MOCK_SF_LIST_FAIL_FIRST=all _e2e_call "$fn"
    assert_file_contains "$MB/out.log" "RC=1 OUT=[]" "ずっと失敗 → 戻り値 1（何も出力しない）"
    [[ "$(grep -c '^sf org list' "$MOCK_CALL_LOG")" -eq 3 ]] && pass "ずっと失敗 → 3 回で諦める" || fail "ずっと失敗 → 3 回で諦める" "回数: $(grep -c '^sf org list' "$MOCK_CALL_LOG")"


    # --- Salesforce 側（cleanup.sh）---
    _reset; MOCK_SF_LIST_FAIL_FIRST=all _run_cleanup --yes --no-confirm; local rc=$?
    assert_exit_fail "$rc" "アプリの一覧を取れない → 失敗で終わる（成功と報告しない）"
    assert_file_contains     "$MB/out.log" "外部クライアントアプリの一覧を取得できませんでした" "取得失敗の旨が表示される"
    assert_file_not_contains "$MB/out.log" "対象の外部クライアントアプリはありません" "「対象なし」とは表示しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "post-destructive" "取得できないときは、アプリの削除をしない"
    assert_file_contains     "$MOCK_CALL_LOG" "gh repo delete tamashimon-org/force-e2e-20260101-000000 --yes" "GitHub 側の削除は、続けて行う（途中で止まらない）"
    assert_dir_not_exists "$CB/root/home/tamashimon-org/e2e-20260101-000000" "ローカルの掃除も、続けて行う（途中で止まらない）"

    # --- アプリの削除（deploy）が失敗したとき（終了コードで判定する）---
    teardown "$CB"
    _mk_cleanup_env
    _reset; MOCK_SF_DEPLOY_EXIT=1 _run_cleanup --yes --no-confirm; rc=$?
    assert_exit_fail         "$rc" "削除用の deploy が失敗 → 失敗で終わる"
    assert_file_contains     "$MB/out.log" "の削除（deploy）に失敗しました" "削除の失敗が表示される"

    _reset; MOCK_SF_LIST_FAIL_FIRST=all _run_cleanup; rc=$?
    assert_exit_fail "$rc" "一覧のみの表示でも、取れなければ失敗で終わる"

    # --- GitHub 側 ---
    teardown "$CB"
    _mk_cleanup_env
    _reset; MOCK_GH_LIST_FAIL_FIRST=1 _e2e_call 'e2e_load_fixture; e2e_guard_env; out=$(e2e_list_target_repos); echo "RC=$? OUT=[$out]"'
    assert_file_contains "$MB/out.log" "RC=0 OUT=[force-e2e-20260101-000000" "リポジトリ一覧: 1 回失敗しても、取れる（再試行）"

    _reset; MOCK_GH_LIST_FAIL_FIRST=all _run_cleanup --yes --no-confirm; rc=$?
    assert_exit_fail "$rc" "リポジトリの一覧を取れない → 失敗で終わる"
    assert_file_contains     "$MB/out.log" "リポジトリの一覧を取得できませんでした" "リポジトリの取得失敗の旨が表示される"
    assert_file_not_contains "$MB/out.log" "対象のリポジトリはありません" "「対象なし」とは表示しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete" "取得できないときは、リポジトリを削除しない"
    assert_file_contains     "$MOCK_CALL_LOG" "post-destructive-changes" "Salesforce 側の削除は、続けて行う（途中で止まらない）"

    unset -f _reset
    unset MOCK_CALL_LOG MOCK_GH_REPOS MOCK_SF_ECAS E2E_LIST_RETRY_WAIT
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 16. ローカルの削除の補強（名前が一致しても、中身が想定外・シンボリックリンクなら消さない）
#   背景: Codex のレビューで、JWT 用フォルダを、名前だけで rm -rf していることを指摘された
# ------------------------------------------------------------------------------
test_e2e_local_guard() {
    echo ""; echo -e "${CLR_HEAD}[TEST] ローカルの削除: 中身が想定外のフォルダ・シンボリックリンクは、消さない${CLR_RST}"
    _mk_cleanup_env
    local j="$HM/.sf-jwt/force-e2e-20260101-000000"
    printf 'k' > "$j/server.key"; printf 'c' > "$j/server.crt"

    # 想定どおりの中身（server.key / server.crt だけ）→ 削除される
    _run_cleanup --yes --no-confirm; local rc=$?
    assert_exit_ok "$rc" "中身が server.key / server.crt だけ → 削除できる（終了コード 0）"
    assert_dir_not_exists "$j" "中身が server.key / server.crt だけのフォルダは、削除される"
    teardown "$CB"

    # 想定外のファイルが入っている → 削除しない（失敗として返す）
    _mk_cleanup_env
    j="$HM/.sf-jwt/force-e2e-20260101-000000"
    printf 'k' > "$j/server.key"; printf 'important' > "$j/notes.txt"
    _run_cleanup --yes --no-confirm; rc=$?
    assert_exit_fail "$rc" "想定外のファイルあり → 失敗で終わる"
    assert_dir_exists "$j" "想定外のファイルが入っているフォルダは、削除しない"
    assert_file_exists "$j/notes.txt" "想定外のファイルが残っている"
    assert_file_contains "$MB/out.log" "想定外のファイル（notes.txt）があるため、削除しません" "削除しない理由が表示される"
    assert_dir_not_exists "$CB/root/home/tamashimon-org/e2e-20260101-000000" "ほかの掃除（作業フォルダ）は、続けて行う"
    teardown "$CB"

    # シンボリックリンクは、一覧に出さない
    _mk_cleanup_env
    local t="$CB/tmpdir" real="$CB/real-target"; mkdir -p "$t" "$real"
    ln -s "$real" "$t/e2e-run.LnKdIr" 2>/dev/null
    ln -s "$real" "$HM/.sf-jwt/force-e2e-20260202-020202" 2>/dev/null
    touch -h -d "2 hours ago" "$t/e2e-run.LnKdIr" 2>/dev/null
    if [[ -L "$t/e2e-run.LnKdIr" ]]; then
        TMPDIR="$t" _e2e_call 'e2e_load_fixture; e2e_guard_env; e2e_list_target_local'
        assert_file_not_contains "$MB/out.log" "e2e-run.LnKdIr" "一時フォルダのシンボリックリンクは、対象外"
        assert_file_not_contains "$MB/out.log" "force-e2e-20260202-020202" "証明書フォルダのシンボリックリンクは、対象外"
    else
        pass "（シンボリックリンクを作れない環境のため省略）"
    fi
    unset MOCK_CALL_LOG MOCK_GH_REPOS MOCK_SF_ECAS
    teardown "$CB"
}

test_e2e_names
test_e2e_guard
test_e2e_delete_guards
test_e2e_fixture
test_e2e_cleanup_list
test_e2e_cleanup_delete
test_e2e_cleanup_confirm
test_e2e_sf_shim
test_e2e_alias_restore
test_e2e_input
test_e2e_run_guard
test_e2e_sfdx_url
test_e2e_admin_login_retry
test_e2e_tmp_cleanup
test_e2e_list_failure
test_e2e_local_guard

print_summary
