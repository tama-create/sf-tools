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
    "repo list")   for n in ${MOCK_GH_REPOS:-}; do echo "$n"; done ;;
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
    "org display") echo '{"status":0,"result":{"username":"admin@example.com"}}' ;;
    "org login")   exit 0 ;;
    "org list")
        echo '{'; echo '  "status": 0,'; echo '  "result": ['
        for n in ${MOCK_SF_ECAS:-}; do
            grep -qx "$n" "$_dir/deleted.txt" 2>/dev/null && continue
            echo "    { \"fullName\": \"$n\", \"type\": \"ExternalClientApplication\" },"
        done
        echo '  ]'; echo '}' ;;
    "project deploy")
        if [[ -f destructiveChanges.xml ]]; then
            cat destructiveChanges.xml >> "${MOCK_CALL_LOG}"
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
        echo "E2E_SF_TOOLS_TOKEN=github_pat_faketools"
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
    expected=$'Y\nY\n2\nY\n3\nghp_fakepat\n\nxoxb-fakeslack\nC01ABCDEFGH\n\n2\nN\ngithub_pat_faketools\nN'
    assert_equals "$out" "$expected" "台本が、質問の順番どおりである（Y→Y→2→Y→3→PAT→空→Slack→ID→空→2→N→Token→N）"
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

print_summary
