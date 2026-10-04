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

# ------------------------------------------------------------------------------
# is_gitbash / open_browser のテスト（Git Bash でも $OSTYPE が cygwin になる環境がある）
# ------------------------------------------------------------------------------
_osd_run() {  # 引数: OSTYPE の値, 実行するコード（common.sh を読み込んだあとに、OSTYPE を設定して実行する）
    bash -c "
        readonly SCRIPT_NAME=test; readonly LOG_FILE=/dev/null; readonly LOG_MODE=NEW; export SF_INIT_MODE=1
        source '${SF_TOOLS_DIR}/lib/common.sh'
        OSTYPE='$1'
        $2" 2>&1
}

test_is_gitbash() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] is_gitbash: \$OSTYPE が msys / mingw / cygwin なら Git Bash と判定する${CLR_RST}"
    local t out
    for t in msys msys2 mingw64 cygwin; do
        out=$(_osd_run "$t" 'is_gitbash && echo YES || echo NO')
        [[ "$out" == "YES" ]] && pass "OSTYPE=${t} → Git Bash と判定する" || fail "OSTYPE=${t} → Git Bash と判定する" "$out"
    done
    for t in linux-gnu darwin22 freebsd13; do
        out=$(_osd_run "$t" 'is_gitbash && echo YES || echo NO')
        [[ "$out" == "NO" ]] && pass "OSTYPE=${t} → Git Bash と判定しない" || fail "OSTYPE=${t} → Git Bash と判定しない" "$out"
    done
}

test_open_browser_gitbash() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] open_browser: Git Bash（msys / mingw / cygwin）では start を呼ぶ${CLR_RST}"
    local mb t n
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    for n in start powershell.exe open xdg-open; do
        printf '#!/bin/bash\necho "%s $*" >> "$MOCK_CALL_LOG"\n' "$n" > "$mb/$n"
        chmod +x "$mb/$n"
    done
    for t in msys mingw64 cygwin; do
        : > "$MOCK_CALL_LOG"
        PATH="$mb:$PATH" _osd_run "$t" "open_browser 'https://example.com/x'" > /dev/null
        assert_file_contains     "$MOCK_CALL_LOG" "https://example.com/x" "OSTYPE=${t} → start でブラウザを開く"
        assert_file_contains     "$MOCK_CALL_LOG" "start"                 "OSTYPE=${t} → start が呼ばれる"
        assert_file_not_contains "$MOCK_CALL_LOG" "powershell.exe"        "OSTYPE=${t} → WSL 用の powershell.exe は呼ばれない"
    done
    unset MOCK_CALL_LOG
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# check_sf_cli のテスト（sf が成功しても終了コード 1 を返す環境の検知）
# ------------------------------------------------------------------------------
# 引数: 1=PATH, 2=check_sf_cli の引数, 環境変数 MOCK_SF_VERSION_EXIT を引き継ぐ
_csc_run() {
    PATH="$1" bash -c "
        readonly SCRIPT_NAME=test; readonly LOG_FILE=/dev/null; readonly LOG_MODE=NEW; export SF_INIT_MODE=1
        source '${SF_TOOLS_DIR}/lib/common.sh'
        check_sf_cli $2
        echo RET=\$?" 2>&1
}

test_check_sf_cli() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] check_sf_cli: sf の終了コードが 0 以外なら案内して中断する${CLR_RST}"
    local mb out rc
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    create_mock_sf "$mb"

    # 正常（終了コード 0）→ 何も表示せず戻り値 0
    out=$(_csc_run "$mb:/usr/bin:/bin" "")
    [[ "$out" == "RET=0" ]] && pass "正常 → 何も表示せず、戻り値 0" || fail "正常 → 何も表示せず、戻り値 0" "$out"

    # 終了コード 1 → 案内を表示して die（以降の処理に進まない）
    out=$(MOCK_SF_VERSION_EXIT=1 _csc_run "$mb:/usr/bin:/bin" "")
    [[ "$out" == *"終了コードが 0 ではありません（sf --version: 終了コード 1）"* ]] \
        && pass "終了コード 1 → 終了コードの値を表示する" || fail "終了コード 1 → 終了コードの値を表示する" "$out"
    [[ "$out" == *"npm install -g @salesforce/cli"* ]] \
        && pass "終了コード 1 → npm 版のインストール方法を案内する" || fail "終了コード 1 → npm 版のインストール方法を案内する" "$out"
    [[ "$out" == *"sf の場所: $mb/sf"* ]] \
        && pass "終了コード 1 → sf の場所を表示する" || fail "終了コード 1 → sf の場所を表示する" "$out"
    [[ "$out" != *"RET="* ]] \
        && pass "終了コード 1 → die して、以降の処理に進まない" || fail "終了コード 1 → die して、以降の処理に進まない" "$out"
    MOCK_SF_VERSION_EXIT=1 _csc_run "$mb:/usr/bin:/bin" "" > /dev/null; rc=$?
    assert_exit_fail "$rc" "終了コード 1 → スクリプトは異常終了する"

    # --warn-only → 案内は表示するが、die せず、戻り値 1
    out=$(MOCK_SF_VERSION_EXIT=1 _csc_run "$mb:/usr/bin:/bin" "--warn-only")
    [[ "$out" == *"終了コードが 0 ではありません"* && "$out" == *"RET=1"* ]] \
        && pass "--warn-only → 案内を表示し、die せずに戻り値 1" || fail "--warn-only → 案内を表示し、die せずに戻り値 1" "$out"

    # sf が未インストール → 何もしない（各スクリプトの環境チェックが扱う）
    out=$(_csc_run "/usr/bin:/bin" "")
    [[ "$out" == "RET=0" ]] && pass "sf 未インストール → 何もせず、戻り値 0" || fail "sf 未インストール → 何もせず、戻り値 0" "$out"

    unset MOCK_CALL_LOG
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# check_sf_cli --cache: 24 時間の省略 / 失敗は記録しない / GitHub Actions では何もしない
# ------------------------------------------------------------------------------
_sf_version_calls() { grep -c "^sf --version" "$MOCK_CALL_LOG" 2>/dev/null || true; }

test_check_sf_cli_cache() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] check_sf_cli --cache: 成功は 24 時間省略 / 失敗は毎回確認 / Actions では何もしない${CLR_RST}"
    local mb stamp out
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    create_mock_sf "$mb"
    stamp="$mb/sf-check-stamp"
    local P="$mb:/usr/bin:/bin"

    # 1 回目: 成功 → 記録を作り、sf --version を実行する
    : > "$MOCK_CALL_LOG"
    out=$(SF_TOOLS_SF_CHECK_STAMP="$stamp" _csc_run "$P" "--warn-only --cache")
    [[ "$out" == "RET=0" && "$(_sf_version_calls)" == "1" ]] \
        && pass "1 回目: sf --version を実行して成功する" || fail "1 回目: sf --version を実行して成功する" "$out / 呼び出し $(_sf_version_calls)"
    [[ "$(cat "$stamp" 2>/dev/null)" == "$mb/sf" ]] \
        && pass "成功を、sf の場所つきで記録する" || fail "成功を、sf の場所つきで記録する" "$(cat "$stamp" 2>/dev/null)"

    # 2 回目: 記録があるので、sf --version を実行せずに省略する
    out=$(SF_TOOLS_SF_CHECK_STAMP="$stamp" _csc_run "$P" "--warn-only --cache")
    [[ "$out" == "RET=0" && "$(_sf_version_calls)" == "1" ]] \
        && pass "2 回目: 24 時間以内なので、sf --version を実行せずに省略する" || fail "2 回目: sf --version を実行せずに省略する" "呼び出し $(_sf_version_calls)"

    # 記録が古い（2 日前）→ 省略しない
    touch -d "2 days ago" "$stamp"
    SF_TOOLS_SF_CHECK_STAMP="$stamp" _csc_run "$P" "--warn-only --cache" > /dev/null
    [[ "$(_sf_version_calls)" == "2" ]] \
        && pass "記録が 24 時間より古い → 省略せず、確認する" || fail "記録が 24 時間より古い → 省略せず、確認する" "呼び出し $(_sf_version_calls)"

    # 記録の sf の場所が違う → 省略しない
    printf '%s' "/another/path/sf" > "$stamp"
    SF_TOOLS_SF_CHECK_STAMP="$stamp" _csc_run "$P" "--warn-only --cache" > /dev/null
    [[ "$(_sf_version_calls)" == "3" ]] \
        && pass "記録の sf の場所が違う → 省略せず、確認する" || fail "記録の sf の場所が違う → 省略せず、確認する" "呼び出し $(_sf_version_calls)"

    # --cache なし → 記録があっても、毎回確認する
    SF_TOOLS_SF_CHECK_STAMP="$stamp" _csc_run "$P" "--warn-only" > /dev/null
    [[ "$(_sf_version_calls)" == "4" ]] \
        && pass "--cache なし → 毎回確認する" || fail "--cache なし → 毎回確認する" "呼び出し $(_sf_version_calls)"

    # 失敗（終了コード 1）→ 記録を作らず、毎回警告する
    rm -f "$stamp"; : > "$MOCK_CALL_LOG"
    out=$(MOCK_SF_VERSION_EXIT=1 SF_TOOLS_SF_CHECK_STAMP="$stamp" _csc_run "$P" "--warn-only --cache")
    [[ "$out" == *"終了コードが 0 ではありません"* && "$out" == *"RET=1"* && ! -f "$stamp" ]] \
        && pass "失敗 → 警告し、記録は作らない" || fail "失敗 → 警告し、記録は作らない" "$out"
    MOCK_SF_VERSION_EXIT=1 SF_TOOLS_SF_CHECK_STAMP="$stamp" _csc_run "$P" "--warn-only --cache" > /dev/null
    [[ "$(_sf_version_calls)" == "2" ]] \
        && pass "失敗は、毎回確認する（省略されない）" || fail "失敗は、毎回確認する" "呼び出し $(_sf_version_calls)"

    # GitHub Actions 上 → 何もしない（sf --version も実行しない）
    : > "$MOCK_CALL_LOG"
    out=$(GITHUB_ACTIONS=true MOCK_SF_VERSION_EXIT=1 SF_TOOLS_SF_CHECK_STAMP="$stamp" _csc_run "$P" "--cache")
    [[ "$out" == "RET=0" && "$(_sf_version_calls)" == "0" ]] \
        && pass "GitHub Actions 上 → 何もせず、sf --version も実行しない" || fail "GitHub Actions 上 → 何もしない" "$out / 呼び出し $(_sf_version_calls)"

    unset MOCK_CALL_LOG
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# run_isolated_home: 一時的なホームフォルダの中で実行する（sf の認証・エイリアスの隔離）
# ------------------------------------------------------------------------------
test_run_isolated_home() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] run_isolated_home: 一時的なホームの中で実行し、出力と終了コードを返し、後で削除する${CLR_RST}"
    local out rc home_line tmp_home
    out=$(bash -c "
        readonly SCRIPT_NAME=test; readonly LOG_FILE=/dev/null; readonly LOG_MODE=NEW; export SF_INIT_MODE=1
        source '${SF_TOOLS_DIR}/lib/common.sh'
        o=\$(run_isolated_home bash -c 'echo \"H=\$HOME U=\$USERPROFILE\"; echo ERRLINE >&2; exit 3'); rc=\$?
        echo \"RC=\$rc\"; echo \"\$o\"
        echo \"REALHOME=\$HOME\"" 2>&1)
    rc=$(printf '%s\n' "$out" | sed -n 's/^RC=//p')
    home_line=$(printf '%s\n' "$out" | grep '^H=')
    tmp_home=$(printf '%s' "$home_line" | sed -E 's/^H=([^ ]*) U=.*/\1/')

    [[ "$rc" == "3" ]] && pass "コマンドの終了コードを返す" || fail "コマンドの終了コードを返す" "$out"
    [[ "$out" == *"ERRLINE"* ]] && pass "標準エラーも、出力として返す" || fail "標準エラーも、出力として返す" "$out"
    [[ "$tmp_home" == *"sf-tools-home."* ]] && pass "HOME が、一時フォルダ（sf-tools-home.*）になる" || fail "HOME が一時フォルダになる" "$home_line"
    [[ "$home_line" == *"U=$tmp_home"* ]] && pass "USERPROFILE も、同じ一時フォルダになる（Windows は USERPROFILE を見る）" || fail "USERPROFILE も同じ一時フォルダになる" "$home_line"
    [[ ! -e "$tmp_home" ]] && pass "実行後に、一時フォルダは削除されている" || fail "実行後に、一時フォルダは削除されている" "$tmp_home"
    [[ "$out" == *"REALHOME=$HOME"* ]] && pass "呼び出し元の HOME は変わらない" || fail "呼び出し元の HOME は変わらない" "$out"
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
test_is_gitbash
test_open_browser_gitbash
test_check_sf_cli
test_check_sf_cli_cache
test_run_isolated_home

print_summary
