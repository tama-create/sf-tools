#!/bin/bash
# ==============================================================================
# test_common.sh - lib/common.sh の共通関数テスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== common.sh ===${CLR_RST}"

# check_authorized_user / check_admin_user は廃止済み。
# 権限チェックは警告ボックス + ask_yn に置き換えられたため、テストなし。

# ------------------------------------------------------------------------------
# check_gh_owner のテスト
# ------------------------------------------------------------------------------
# 引数1: gh api user が返すユーザー名 / 引数2: 組織メンバーシップ API が返す "role state"（空なら空返却）
# 引数3: "fail" を渡すと組織メンバーシップ API が exit 1 で失敗する
_make_mock_gh_bin() {
    local mb user org_status org_cmd
    mb=$(setup_mock_bin)
    user="${1:-testowner}"
    org_status="${2:-}"
    if [[ "${3:-}" == "fail" ]]; then
        org_cmd="exit 1"
    else
        org_cmd="echo \"${org_status}\""
    fi
    cat > "$mb/gh" << EOF
#!/bin/bash
echo "gh \$*" >> "\${MOCK_CALL_LOG:-/dev/null}"
case "\$1 \$2" in
    "api user") echo "${user}" ;;
    "api user/memberships/orgs/"*) ${org_cmd} ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$mb/gh"
    echo "$mb"
}

# check_gh_owner を呼び出す小さなラッパースクリプトを生成する
_make_check_gh_owner_script() {
    local script
    script=$(mktemp /tmp/test-check-gh-owner-XXXX.sh)
    cat > "$script" << EOF
#!/bin/bash
readonly SCRIPT_NAME=test
readonly LOG_FILE=/dev/null
readonly LOG_MODE=NEW
export SF_INIT_MODE=1
source '${SF_TOOLS_DIR}/lib/common.sh'
check_gh_owner "\$1"
EOF
    chmod +x "$script"
    echo "$script"
}

# 一致 → 正常終了
test_check_gh_owner_match() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] check_gh_owner: ユーザーが一致 → 正常終了${CLR_RST}"

    local mb script
    mb=$(_make_mock_gh_bin "testowner")
    script=$(_make_check_gh_owner_script)

    PATH="$mb:$PATH" bash "$script" "testowner" > /dev/null 2>&1
    assert_exit_ok $? "ユーザー一致 → 終了コード 0"

    rm -f "$script"; teardown "$mb"
}

# 不一致 → die
test_check_gh_owner_mismatch() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] check_gh_owner: ユーザーが不一致 → die${CLR_RST}"

    local mb script
    mb=$(_make_mock_gh_bin "other-user")
    script=$(_make_check_gh_owner_script)

    PATH="$mb:$PATH" bash "$script" "testowner" > /dev/null 2>&1
    assert_exit_fail $? "ユーザー不一致 → die"

    rm -f "$script"; teardown "$mb"
}

# gh が空を返す → スキップして正常終了
test_check_gh_owner_skip_on_empty() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] check_gh_owner: gh が空を返す → スキップ${CLR_RST}"

    local mb script
    mb=$(setup_mock_bin)
    cat > "$mb/gh" << 'GHEOF'
#!/bin/bash
exit 0
GHEOF
    chmod +x "$mb/gh"
    script=$(_make_check_gh_owner_script)

    PATH="$mb:$PATH" bash "$script" "testowner" > /dev/null 2>&1
    assert_exit_ok $? "gh 空返却 → スキップして終了コード 0"

    rm -f "$script"; teardown "$mb"
}

# 不一致だが、オーナーが組織で認証ユーザーがその有効な管理者 → 通過
test_check_gh_owner_org_admin() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] check_gh_owner: 組織の有効な管理者 → 正常終了${CLR_RST}"

    local mb script
    mb=$(_make_mock_gh_bin "other-user" "admin active")
    script=$(_make_check_gh_owner_script)

    PATH="$mb:$PATH" bash "$script" "testorg" > /dev/null 2>&1
    assert_exit_ok $? "組織 admin(active) → 終了コード 0"

    rm -f "$script"; teardown "$mb"
}

# 不一致で、組織の一般メンバー → die
test_check_gh_owner_org_member() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] check_gh_owner: 組織の一般メンバー → die${CLR_RST}"

    local mb script
    mb=$(_make_mock_gh_bin "other-user" "member active")
    script=$(_make_check_gh_owner_script)

    PATH="$mb:$PATH" bash "$script" "testorg" > /dev/null 2>&1
    assert_exit_fail $? "組織 member → die"

    rm -f "$script"; teardown "$mb"
}

# 不一致で、組織の管理者だが招待が未承諾（pending）→ die
test_check_gh_owner_org_admin_pending() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] check_gh_owner: 組織 admin だが pending → die${CLR_RST}"

    local mb script
    mb=$(_make_mock_gh_bin "other-user" "admin pending")
    script=$(_make_check_gh_owner_script)

    PATH="$mb:$PATH" bash "$script" "testorg" > /dev/null 2>&1
    assert_exit_fail $? "組織 admin(pending) → die"

    rm -f "$script"; teardown "$mb"
}

# 不一致で、組織メンバーシップ API が失敗 → die（安全側に倒す）
test_check_gh_owner_org_api_failure() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] check_gh_owner: 組織 API 失敗 → die${CLR_RST}"

    local mb script
    mb=$(_make_mock_gh_bin "other-user" "" "fail")
    script=$(_make_check_gh_owner_script)

    PATH="$mb:$PATH" bash "$script" "testorg" > /dev/null 2>&1
    assert_exit_fail $? "組織 API 失敗 → die"

    rm -f "$script"; teardown "$mb"
}


# ------------------------------------------------------------------------------
# read_secret のテスト
# ------------------------------------------------------------------------------
_make_read_secret_script() {
    local script
    script=$(mktemp /tmp/test-read-secret-XXXX.sh)
    cat > "$script" << SEOF
#!/bin/bash
readonly SCRIPT_NAME=test
readonly LOG_FILE=/dev/null
readonly LOG_MODE=NEW
export SF_INIT_MODE=1
source '${SF_TOOLS_DIR}/lib/common.sh'
V=""
read_secret V "PROMPT: "
echo "GOT=[\$V]"
SEOF
    chmod +x "$script"
    echo "$script"
}

test_read_secret() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] read_secret: 入力を受け取り、画面に値を出さない${CLR_RST}"
    local script out
    script=$(_make_read_secret_script)

    out=$(printf 'ghp_secretvalue\n' | bash "$script" 2>&1)
    [[ "$out" == *"GOT=[ghp_secretvalue]"* ]] && pass "入力した値が変数に入る" || fail "入力した値が変数に入る" "$out"
    # 変数の確認用 GOT 行を除いた表示（プロンプト等）に値が含まれないこと
    [[ "$(echo "$out" | grep -v '^GOT=')" != *"ghp_secretvalue"* ]] && pass "値が画面（プロンプト出力）に表示されない" || fail "値が画面に表示されない" "$out"

    out=$(printf '\n\nghp_second\n' | bash "$script" 2>&1)
    [[ "$out" == *"GOT=[ghp_second]"* ]] && pass "空 Enter は無視して再入力になる" || fail "空 Enter は無視して再入力になる" "$out"

    out=$(printf 'ghp_crlf\r\n' | bash "$script" 2>&1)
    [[ "$out" == *"GOT=[ghp_crlf]"* ]] && pass "末尾の CR が除去される" || fail "末尾の CR が除去される" "$out"

    printf 'q\n' | bash "$script" > /dev/null 2>&1
    assert_exit_fail $? "q → 中断（die）"

    printf '' | bash "$script" > /dev/null 2>&1
    assert_exit_fail $? "EOF → 中断（die）"

    rm -f "$script"
}


# ------------------------------------------------------------------------------
# _mask_secrets / run のコマンドログの伏せ字（Token が CMD ログに残らないこと）
# ------------------------------------------------------------------------------
test_mask_secrets() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] _mask_secrets / run: Token らしい文字列をコマンドログで伏せ字にする${CLR_RST}"

    local script logf out
    script=$(mktemp /tmp/test-mask-XXXX.sh)
    logf=$(mktemp /tmp/test-mask-log-XXXX)
    cat > "$script" << SEOF
#!/bin/bash
readonly SCRIPT_NAME=test
readonly LOG_FILE='${logf}'
readonly LOG_MODE=NEW
export SF_INIT_MODE=1
source '${SF_TOOLS_DIR}/lib/common.sh'
echo "MASK=\$(_mask_secrets 'a ghp_ABC123def b gho_XYZ789 c github_pat_11AAA_bbbCCC d xoxb-111-222-AbCdEf e plain')"
run true "https://ghp_SECRETVALUE@github.com/o/r.git" xoxb-9-9-ZzZz > /dev/null 2>&1
SEOF
    out=$(bash "$script" 2>&1)

    [[ "$out" == *"MASK=a ghp_***masked*** b gho_***masked*** c github_pat_***masked*** d xoxb-***masked*** e plain"* ]] \
        && pass "ghp_ / gho_ / github_pat_ / xoxb- が伏せ字になり、通常の文字列は変わらない" \
        || fail "Token らしい文字列が伏せ字になる" "$out"

    assert_file_not_contains "$logf" "ghp_SECRETVALUE"  "run のコマンドログに GitHub の Token が残らない"
    assert_file_not_contains "$logf" "xoxb-9-9-ZzZz"    "run のコマンドログに Slack の Token が残らない"
    assert_file_contains     "$logf" "***masked***"     "run のコマンドログに伏せ字が記録される"

    rm -f "$script" "$logf"
}

test_check_gh_owner_match
test_check_gh_owner_mismatch
test_check_gh_owner_skip_on_empty
test_check_gh_owner_org_admin
test_check_gh_owner_org_member
test_check_gh_owner_org_admin_pending
test_check_gh_owner_org_api_failure
test_read_secret
test_mask_secrets

print_summary
