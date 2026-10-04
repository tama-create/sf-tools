#!/bin/bash
# ==============================================================================
# test_sf-update-secret.sh - sf-update-secret.sh のテスト（JWT 認証方式）
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-update-secret.sh ===${CLR_RST}"

# モック生成ヘルパー
_create_mocks_update_secret() {
    local mb="$1" td="$2"

    # git モック（remote get-url origin → force-test リポジトリを返す）
    cat > "$mb/git" << EOF
#!/bin/bash
echo "git \$*" >> "\${MOCK_CALL_LOG:-/dev/null}"
case "\$1" in
    remote) echo "https://github.com/tamashimon-org/force-test.git" ;;
    *)      exit 0 ;;
esac
EOF
    chmod +x "$mb/git"

    create_mock_sf  "$mb"
    create_mock_gh  "$mb"
    create_mock_openssl "$mb"
}

# ダミー server.key を JWT_DIR に作成し、branches.txt を PROD のみにする
# （_update_all は $HOME/.sf-jwt/<REPO_NAME>/server.key と ./sf-tools/config/branches.txt を参照）
_prepare_update_all_env() {
    local home_dir="$1" force_dir="$2"
    mkdir -p "$home_dir/.sf-jwt/force-test"
    echo "DUMMY KEY" > "$home_dir/.sf-jwt/force-test/server.key"
    # PROD のみ処理させるため branches.txt を1行にする
    echo "main" > "$force_dir/sf-tools/config/branches.txt"
}

# --- 正常系: 全更新（PROD のみ・branches.txt なし）---
test_update_all_success() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 全更新（PROD のみ）→ 正常終了${CLR_RST}"

    local td mb mh
    setup_std_env td mb mh
    _create_mocks_update_secret "$mb" "$td"
    _prepare_update_all_env "$td" "$td"

    # 入力: Y=管理者警告確認 4=全更新 Y=SF_PRIVATE_KEY更新 consumer_key username（PROD のみ）
    printf 'Y4Yfake_consumer_key\nfake@example.com\n' \
        | ( cd "$td" && HOME="$td" PATH="$mb:$PATH" \
              bash "$SF_TOOLS_DIR/bin/sf-update-secret.sh" ) > /tmp/update-secret-test.log 2>&1
    local ec=$?

    assert_exit_ok $ec "全更新 → 終了コード 0"
    assert_file_contains "$mb/calls.log" "gh secret set SF_CONSUMER_KEY_PROD"   "SF_CONSUMER_KEY_PROD が更新される"
    assert_file_contains "$mb/calls.log" "gh variable set SF_USERNAME_PROD"     "SF_USERNAME_PROD が更新される"
    assert_file_contains "$mb/calls.log" "gh variable set SF_INSTANCE_URL_PROD" "SF_INSTANCE_URL_PROD が更新される"

    # JWT 接続テストは、一時的なホームフォルダの中で実行される（ユーザーの sf のエイリアス・認証を変えない）
    local jwt_home
    jwt_home=$(grep "^sf-jwt-env HOME=" "$mb/calls.log" | head -1 | sed -E 's/^sf-jwt-env HOME=([^ ]*) .*/\1/')
    [[ -n "$jwt_home" && "$jwt_home" == *"sf-tools-home."* && "$jwt_home" != "$td" ]] \
        && pass "JWT 接続テストは、一時的なホーム（sf-tools-home.*）の中で実行される" || fail "JWT 接続テストは、一時的なホームの中で実行される" "HOME=${jwt_home}"
    [[ -n "$jwt_home" && ! -e "$jwt_home" ]] \
        && pass "JWT 接続テストの一時的なホームは、実行後に削除されている" || fail "JWT 接続テストの一時的なホームは、実行後に削除されている" "${jwt_home}"

    teardown "$td" "$mb"
    rm -f /tmp/update-secret-test.log
}

# --- sf の終了コードが 0 以外（インストーラー版の不具合）→ 警告のみで、処理は続行される ---
test_update_sf_cli_warning_only() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] sf の終了コード 1 → 警告を表示するが、続行する${CLR_RST}"

    local td mb mh
    setup_std_env td mb mh
    _create_mocks_update_secret "$mb" "$td"
    _prepare_update_all_env "$td" "$td"

    printf 'Y4Yfake_consumer_key\nfake@example.com\n' \
        | ( cd "$td" && HOME="$td" PATH="$mb:$PATH" MOCK_SF_VERSION_EXIT=1 \
              bash "$SF_TOOLS_DIR/bin/sf-update-secret.sh" ) > /tmp/update-secret-test2.log 2>&1
    local ec=$?

    assert_exit_ok $ec "sf の終了コード 1 → 警告のみで、終了コード 0（続行する）"
    assert_file_contains "/tmp/update-secret-test2.log" "終了コードが 0 ではありません" "警告が表示された"
    assert_file_contains "$mb/calls.log" "gh secret set SF_CONSUMER_KEY_PROD" "更新の処理まで、続行された"

    teardown "$td" "$mb"
    rm -f /tmp/update-secret-test2.log
}

# --- JWT 接続テスト失敗 → エラー中止 ---
test_update_jwt_login_fail() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] JWT 接続テスト失敗 → エラー中止${CLR_RST}"

    local td mb mh
    setup_std_env td mb mh
    _create_mocks_update_secret "$mb" "$td"
    _prepare_update_all_env "$td" "$td"

    export MOCK_SF_LOGIN_EXIT=1

    printf 'Y4Yfake_consumer_key\nfake@example.com\n' \
        | ( cd "$td" && HOME="$td" PATH="$mb:$PATH" \
              bash "$SF_TOOLS_DIR/bin/sf-update-secret.sh" ) > /dev/null 2>&1
    local ec=$?

    assert_exit_fail $ec "JWT 失敗 → エラー中止"

    unset MOCK_SF_LOGIN_EXIT
    teardown "$td" "$mb"
}

# --- gh secret set 失敗 → エラー中止 ---
test_update_gh_fail() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] gh secret set 失敗 → エラー中止${CLR_RST}"

    local td mb mh
    setup_std_env td mb mh
    _create_mocks_update_secret "$mb" "$td"
    _prepare_update_all_env "$td" "$td"

    export MOCK_GH_SECRET_SET_EXIT=1

    printf 'Y4Yfake_consumer_key\nfake@example.com\n' \
        | ( cd "$td" && HOME="$td" PATH="$mb:$PATH" \
              bash "$SF_TOOLS_DIR/bin/sf-update-secret.sh" ) > /dev/null 2>&1
    local ec=$?

    assert_exit_fail $ec "gh 失敗 → エラー中止"

    unset MOCK_GH_SECRET_SET_EXIT
    teardown "$td" "$mb"
}

# --- force-* 以外のディレクトリ → エラー中止 ---
test_update_not_force_dir() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] force-* 以外 → エラー中止${CLR_RST}"

    local td mb
    td=$(setup_regular_dir); mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    _create_mocks_update_secret "$mb" "$td"

    printf '4\n' \
        | ( cd "$td" && HOME="$td" PATH="$mb:$PATH" \
              bash "$SF_TOOLS_DIR/bin/sf-update-secret.sh" ) > /dev/null 2>&1
    local ec=$?

    assert_exit_fail $ec "force-* 以外 → エラー中止"

    teardown "$td" "$mb"
}

# --- 秘密鍵のみ更新（メニュー 1）---
test_update_private_key() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 秘密鍵のみ更新（メニュー 1）${CLR_RST}"

    local td mb mh
    setup_std_env td mb mh
    _create_mocks_update_secret "$mb" "$td"

    # ダミー秘密鍵ファイルを /tmp に作成
    local dummy_key="/tmp/test-server-$$.key"
    echo "DUMMY KEY" > "$dummy_key"

    # 入力: Y=管理者警告確認 1=秘密鍵更新 key_file_path Y=確認
    printf "Y1${dummy_key}\nY" \
        | ( cd "$td" && HOME="$td" PATH="$mb:$PATH" \
              bash "$SF_TOOLS_DIR/bin/sf-update-secret.sh" ) > /dev/null 2>&1
    local ec=$?

    assert_exit_ok $ec "秘密鍵更新 → 終了コード 0"
    assert_file_contains "$mb/calls.log" "gh secret set SF_PRIVATE_KEY" "SF_PRIVATE_KEY が更新される"

    rm -f "$dummy_key"
    teardown "$td" "$mb"
}

# --- 警告 N で中断 ---
test_update_warning_cancel() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 警告で N → 中断${CLR_RST}"

    local td mb mh
    setup_std_env td mb mh
    _create_mocks_update_secret "$mb" "$td"
    _prepare_update_all_env "$td" "$td"

    unset GITHUB_ACTIONS

    # N=警告で中断
    printf 'N\n' \
        | ( cd "$td" && HOME="$td" PATH="$mb:$PATH" \
              bash "$SF_TOOLS_DIR/bin/sf-update-secret.sh" ) > /dev/null 2>&1
    local ec=$?

    assert_exit_fail $ec "警告で N → 中断"
    ! grep -q "gh secret set" "$mb/calls.log" 2>/dev/null \
        && pass "N → Secrets は更新されない" \
        || fail "N → Secrets は更新されない"

    teardown "$td" "$mb"
}

test_update_all_success
test_update_sf_cli_warning_only
test_update_jwt_login_fail
test_update_gh_fail
test_update_not_force_dir
test_update_private_key
test_update_warning_cancel

echo ""
