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

# 大文字と小文字だけが違う → 同じユーザーとして通過（GitHub は区別しない。以前は区別して die していた）
test_check_gh_owner_case_insensitive() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] check_gh_owner: 大文字と小文字だけが違う → 正常終了${CLR_RST}"

    local mb script
    mb=$(_make_mock_gh_bin "TestOwner" "" "fail")   # 組織 API は失敗させる（一致の判定だけで通過することを確かめる）
    script=$(_make_check_gh_owner_script)

    PATH="$mb:$PATH" bash "$script" "testowner" > /dev/null 2>&1
    assert_exit_ok $? "gh のユーザー TestOwner・オーナー testowner → 終了コード 0"
    PATH="$mb:$PATH" bash "$script" "TESTOWNER" > /dev/null 2>&1
    assert_exit_ok $? "gh のユーザー TestOwner・オーナー TESTOWNER → 終了コード 0"
    PATH="$mb:$PATH" bash "$script" "testowner2" > /dev/null 2>&1
    assert_exit_fail $? "大文字と小文字以外も違う（testowner2）→ die"

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
    echo -e "${CLR_HEAD}[TEST] read_secret: 入力を受け取り、* で表示する（値は画面に出ない）${CLR_RST}"
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

    # 入力した文字は、1 文字ごとに * で表示される（貼り付けられたかどうかが、見て分かる）
    out=$(printf 'ghp_abcdefghij\n' | bash "$script" 2>&1)
    [[ "$out" == *"PROMPT: **************"* ]] && pass "入力した文字数（14 文字）だけ * が表示される" || fail "入力した文字数だけ * が表示される" "$out"
    [[ "$out" == *"14 文字を受け取りました"* ]] && pass "受け取った文字数が表示される" || fail "受け取った文字数が表示される" "$out"
    [[ "$out" == *"先頭: ghp_…"* ]] && pass "先頭の「英字_」だけが表示される" || fail "先頭の「英字_」だけが表示される" "$out"
    [[ "$(echo "$out" | grep -v '^GOT=')" != *"abcdefghij"* ]] && pass "値の残りの部分は、画面に出ない" || fail "値の残りの部分は、画面に出ない" "$out"

    # BackSpace（DEL）で 1 文字消せる
    out=$(printf 'ghp_abX\x7fc\n' | bash "$script" 2>&1)
    [[ "$out" == *"GOT=[ghp_abc]"* ]] && pass "BackSpace で 1 文字消せる" || fail "BackSpace で 1 文字消せる" "$out"

    # 改行なしで終わった入力（EOF）は、確定として扱う
    out=$(printf 'ghp_noeol' | bash "$script" 2>&1)
    [[ "$out" == *"GOT=[ghp_noeol]"* ]] && pass "改行なしの入力（EOF）は、確定として扱う" || fail "改行なしの入力（EOF）は、確定として扱う" "$out"

    # 制御文字（ESC）は無視される
    out=$(printf 'ghp_a\x1bb\n' | bash "$script" 2>&1)
    [[ "$out" == *"GOT=[ghp_ab]"* ]] && pass "制御文字（ESC）は無視される" || fail "制御文字（ESC）は無視される" "$out"

    # 先頭が「英字_」ではない値は、先頭の表示を出さない（文字数だけ）
    out=$(printf 'abcdef\n' | bash "$script" 2>&1)
    [[ "$out" == *"6 文字を受け取りました"* && "$out" != *"先頭:"* ]] && pass "「英字_」で始まらない値は、文字数だけを表示する" || fail "「英字_」で始まらない値は、文字数だけを表示する" "$out"

    # 矢印キーなどの制御シーケンス（ESC [ A・ESC O B・ESC [ 1 ; 5 C）は、まとめて読み捨てる（[A などを値に入れない）
    out=$(printf 'ghp_a\x1b[Ab\x1bOBc\x1b[1;5Cd\n' | bash "$script" 2>&1)
    [[ "$out" == *"GOT=[ghp_abcd]"* ]] && pass "矢印キーの制御シーケンスは、値に入らない" || fail "矢印キーの制御シーケンスは、値に入らない" "$out"

    # CRLF の貼り付け: CR で確定し、続く LF は次の入力に残さない（次の読み取りが、空 Enter にならない）
    local script2
    script2=$(mktemp /tmp/test-read-secret2-XXXX.sh)
    cat > "$script2" << SEOF
#!/bin/bash
readonly SCRIPT_NAME=test
readonly LOG_FILE=/dev/null
readonly LOG_MODE=NEW
export SF_INIT_MODE=1
source '${SF_TOOLS_DIR}/lib/common.sh'
V=""; W=""
read_secret V "P1: "
IFS= read -r W
echo "GOT=[\$V] NEXT=[\$W]"
SEOF
    out=$(printf 'ghp_crlf\r\nnext\n' | bash "$script2" 2>&1)
    [[ "$out" == *"GOT=[ghp_crlf] NEXT=[next]"* ]] && pass "CRLF: 続く LF を読み捨て、次の入力に残さない" || fail "CRLF: 続く LF を読み捨て、次の入力に残さない" "$out"
    rm -f "$script2"

    rm -f "$script"
}

# ------------------------------------------------------------------------------
# read_key: VALID の省略時は、空 Enter 以外のすべての文字（空白・タブを含む）を受け付ける / press_enter は標準出力に出さない
# ------------------------------------------------------------------------------
test_read_key_and_press_enter() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] read_key（空白・タブを受け付ける）/ press_enter（標準出力に出さない）${CLR_RST}"
    local out
    _rk() {   # 引数: 実行する式。標準入力は、呼び出し側のもの。標準出力だけを返す
        bash -c "
            readonly SCRIPT_NAME=test; readonly LOG_FILE=/dev/null; readonly LOG_MODE=NEW; export SF_INIT_MODE=1
            source '${SF_TOOLS_DIR}/lib/common.sh'
            $1" 2>/dev/null
    }
    out=$(printf ' x' | _rk 'read_key K "P: "; echo "K=[$K]"')
    assert_equals "$out" "K=[ ]" "read_key（VALID なし）: 空白を、その文字のまま受け付ける（以前は空になり、無視された）"
    out=$(printf '\tx' | _rk 'read_key K "P: "; echo "K=[$K]"')
    assert_equals "$out" "K=[$(printf '\t')]" "read_key（VALID なし）: タブを、その文字のまま受け付ける"
    out=$(printf '\n y' | _rk 'read_key K "P: " "[xy]"; echo "K=[$K]"')
    assert_equals "$out" "K=[y]" "read_key（VALID あり）: 空 Enter・VALID に合わない空白は、無視する"
    out=$(printf '\n' | _rk 'v=$(press_enter "M"); echo "STDOUT=[$v]"')
    assert_equals "$out" "STDOUT=[]" "press_enter: 標準出力に、何も出さない（命令置換の結果に混ざらない）"
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

    # 失敗したコマンドの error.log の見出しの行も、伏せ字にする（以前は、見出しの行だけ、伏せ字にしていなかった）
    local td
    td=$(mktemp -d "${TMPDIR:-/tmp}/test-mask-err-XXXX")
    ( export SF_INIT_MODE=1; readonly SCRIPT_NAME=test LOG_FILE="$td/test.log" LOG_MODE=NEW
      source "$SF_TOOLS_DIR/lib/common.sh"
      run false "https://ghp_ERRSECRET@github.com/o/r.git" xoxb-8-8-YyYy ) > /dev/null 2>&1
    assert_file_exists       "$td/error.log"                 "run の失敗 → error.log に記録される"
    assert_file_not_contains "$td/error.log" "ghp_ERRSECRET" "error.log の見出しの行に、GitHub の Token が残らない"
    assert_file_not_contains "$td/error.log" "xoxb-8-8-YyYy" "error.log の見出しの行に、Slack の Token が残らない"
    assert_file_contains     "$td/error.log" "***masked***"  "error.log の見出しの行に、伏せ字が記録される"
    rm -rf "$td"
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

test_is_reserved_org_alias() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] is_reserved_org_alias: prod / staging / develop / main は共有環境（予約名）、それ以外は個人用${CLR_RST}"
    local a out
    for a in prod staging develop main; do
        out=$(_osd_run linux-gnu "is_reserved_org_alias '$a' && echo YES || echo NO")
        [[ "$out" == "YES" ]] && pass "${a} → 予約名（共有環境）" || fail "${a} → 予約名（共有環境）" "$out"
    done
    for a in dev00 my-sandbox DevHub production Prod prod2 "" "prod staging"; do
        out=$(_osd_run linux-gnu "is_reserved_org_alias '$a' && echo YES || echo NO")
        [[ "$out" == "NO" ]] && pass "「${a}」→ 予約名ではない（完全一致のみ。大文字小文字・部分一致は対象外）" || fail "「${a}」→ 予約名ではない" "$out"
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

# WSL: URL を PowerShell の単引用符で囲んで渡す。URL の中の ' は '' にする（以前は、そのまま埋め込み、文字列が壊れた）
#   WSL の判定（/proc/version の grep）は、関数で差し替えて、WSL として動かす
test_open_browser_wsl_quote() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] open_browser: WSL では、URL の ' を '' にして、PowerShell に渡す${CLR_RST}"
    local mb n
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    for n in start powershell.exe open xdg-open; do
        printf '#!/bin/bash\necho "%s $*" >> "$MOCK_CALL_LOG"\n' "$n" > "$mb/$n"
        chmod +x "$mb/$n"
    done
    : > "$MOCK_CALL_LOG"
    PATH="$mb:$PATH" _osd_run linux-gnu "grep() { return 0; }; open_browser \"https://example.com/a'b?x=it's\"" > /dev/null
    assert_file_contains "$MOCK_CALL_LOG" "powershell.exe -c Start-Process 'https://example.com/a''b?x=it''s'" "WSL: ' を '' にして、単引用符で囲んで渡す"
    : > "$MOCK_CALL_LOG"
    PATH="$mb:$PATH" _osd_run linux-gnu "grep() { return 0; }; open_browser 'https://example.com/x'" > /dev/null
    assert_file_contains "$MOCK_CALL_LOG" "powershell.exe -c Start-Process 'https://example.com/x'" "WSL: ' のない URL は、そのまま渡す"
    unset MOCK_CALL_LOG
    teardown "$mb"
}

# is_protected_branch: ブランチ名を、固定の文字列として、行全体で比べる（. を正規表現として扱わない・- で始まる名前も扱える）
test_is_protected_branch() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] is_protected_branch: ブランチ名は、固定の文字列として比べる${CLR_RST}"
    local td out b
    td=$(mktemp -d "${TMPDIR:-/tmp}/test-ipb-XXXX")
    mkdir -p "$td/sf-tools/config"
    printf '%s\n' "# 保護するブランチ" "main" "release.1" "staging" > "$td/sf-tools/config/branches.txt"
    for b in main release.1 staging "ma.n" "release-1" "releasex1" "-x" "--help" "Main" ""; do
        out=$( cd "$td" && bash -c "
            readonly SCRIPT_NAME=test; readonly LOG_FILE=/dev/null; readonly LOG_MODE=NEW; export SF_INIT_MODE=1
            source '${SF_TOOLS_DIR}/lib/common.sh'
            is_protected_branch \"\$1\" && echo YES || echo NO" _ "$b" 2>&1 )
        case "$b" in
            main|release.1|staging) assert_equals "$out" "YES" "「${b}」→ 保護対象" ;;
            *)                      assert_equals "$out" "NO"  "「${b}」→ 保護対象ではない（エラーも出さない）" ;;
        esac
    done
    rm -rf "$td"
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
    touch_ago 2880 "$stamp"
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
# print_admin_warning: 管理者向けの警告ボックス（幅のそろえ・標準の見出し）
# ------------------------------------------------------------------------------
test_print_admin_warning() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] print_admin_warning: 管理者向けの警告ボックスを、幅をそろえて表示する${CLR_RST}"
    local out inner bad
    out=$(bash -c "
        readonly SCRIPT_NAME=test; readonly LOG_FILE=/dev/null; readonly LOG_MODE=NEW; export SF_INIT_MODE=1
        source '${SF_TOOLS_DIR}/lib/common.sh'
        print_admin_warning --standard 'GitHub Secrets を更新します。' 'English line 1' 'ＡＢＣ全角と半角 mixed'
        print_admin_warning '!!  見出しだけ' '    続き'
        print_admin_warning --standard" 2>&1 | sed $'s/\033\\[[0-9;]*m//g')

    assert_output_contains "$out" "このコマンドは管理者専用です" "標準の見出し（このコマンドは管理者専用です）が出る"
    assert_output_contains "$out" "管理者以外は絶対に実行しないでください" "標準の見出し（管理者以外は絶対に…）が出る"
    assert_output_contains "$out" "GitHub Secrets を更新します。" "指定した行が出る"
    assert_output_contains "$out" "見出しだけ" "--standard なしでも、指定した行が出る"
    # 内側の幅（全角 2・半角 1）が、すべての行で 54 にそろっている
    bad=$(bash -c "
        readonly SCRIPT_NAME=test; readonly LOG_FILE=/dev/null; readonly LOG_MODE=NEW; export SF_INIT_MODE=1
        source '${SF_TOOLS_DIR}/lib/common.sh'
        while IFS= read -r l; do
            case \"\$l\" in ║*║)
                inner=\"\${l#║}\"; inner=\"\${inner%║}\"
                [[ \$(_display_width \"\$inner\") -eq 54 ]] || echo \"BAD: \$l\" ;;
            esac
        done <<< \"\$1\"" _ "$out")
    assert_equals "$bad" "" "すべての行で、内側の表示の幅が 54 にそろっている（右の枠が、ずれない）"
    local box_count; box_count=$(printf '%s\n' "$out" | grep -c '^╔')
    assert_equals "$box_count" "3" "呼び出しごとに、ボックスが 1 つ出る"
    # 標準エラーに出る（標準出力を汚さない）
    local so
    so=$(bash -c "
        readonly SCRIPT_NAME=test; readonly LOG_FILE=/dev/null; readonly LOG_MODE=NEW; export SF_INIT_MODE=1
        source '${SF_TOOLS_DIR}/lib/common.sh'
        print_admin_warning --standard 'x'" 2>/dev/null)
    assert_equals "$so" "" "標準出力には、何も出さない（標準エラーのみ）"
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

    # SF_USE_GENERIC_UNIX_KEYCHAIN: Windows（Git Bash）以外では true（mac のキーチェーンの警告を避ける）。Git Bash では設定しない
    #   呼び出し元の環境には、残さない（サブシェルの中だけ）。関数も、呼び出せる（従来の HOME=… "$@" と同じ）
    local kc
    kc=$(bash -c "
        readonly SCRIPT_NAME=test; readonly LOG_FILE=/dev/null; readonly LOG_MODE=NEW; export SF_INIT_MODE=1
        source '${SF_TOOLS_DIR}/lib/common.sh'
        OSTYPE=darwin25
        echo \"MAC=\$(run_isolated_home bash -c 'echo \${SF_USE_GENERIC_UNIX_KEYCHAIN:-unset}')\"
        OSTYPE=linux-gnu
        echo \"LINUX=\$(run_isolated_home bash -c 'echo \${SF_USE_GENERIC_UNIX_KEYCHAIN:-unset}')\"
        OSTYPE=msys
        echo \"GITBASH=\$(run_isolated_home bash -c 'echo \${SF_USE_GENERIC_UNIX_KEYCHAIN:-unset}')\"
        echo \"CALLER=\${SF_USE_GENERIC_UNIX_KEYCHAIN:-unset}\"
        f() { echo \"FUNC H=\$HOME K=\${SF_USE_GENERIC_UNIX_KEYCHAIN:-unset}\"; }
        OSTYPE=darwin25
        run_isolated_home f" 2>&1)
    assert_output_contains "$kc" "MAC=true" "macOS: SF_USE_GENERIC_UNIX_KEYCHAIN=true（キーチェーンを使わない）"
    assert_output_contains "$kc" "LINUX=true" "Linux: SF_USE_GENERIC_UNIX_KEYCHAIN=true"
    assert_output_contains "$kc" "GITBASH=unset" "Git Bash: 設定しない（従来のまま）"
    assert_output_contains "$kc" "CALLER=unset" "呼び出し元の環境には、残らない"
    assert_output_contains "$kc" "FUNC H=" "シェル関数も、一時ホームの中で実行できる"
    assert_output_contains "$kc" "K=true" "シェル関数にも、環境変数が渡る"
}

# ------------------------------------------------------------------------------
# ensure_sf_tools_latest のテスト（実際の Git で確認する）
# ------------------------------------------------------------------------------
# origin(bare) と、更新用の作業用 clone(w)、検証対象の clone(sf-tools) を作る。戻り値（標準出力）: ベースディレクトリ
_esl_repos() {
    local b
    b=$(mktemp -d "${TMPDIR:-/tmp}/test-esl-XXXX")
    git init -q --bare --initial-branch=main "$b/origin.git"   # HOME が違う環境でも、既定のブランチ名に依存しない
    git clone -q "$b/origin.git" "$b/w" 2>/dev/null
    (
        cd "$b/w" || exit 1
        git -c user.name=t -c user.email=t@example.com checkout -q -b main && echo 1 > f && git add f \
            && git -c user.name=t -c user.email=t@example.com commit -qm c1 && git push -q origin main
    ) > /dev/null 2>&1
    git clone -q "$b/origin.git" "$b/sf-tools" 2>/dev/null
    echo "$b"
}
# origin の main に、新しいコミットを 1 つ追加する（検証対象を、1 コミット遅れさせる）
_esl_advance() {
    ( cd "$1/w" || exit 1
      echo "$RANDOM" >> f && git -c user.name=t -c user.email=t@example.com commit -qam new && git push -q origin main ) > /dev/null 2>&1
}
# 実行する。引数: ベースdir 標準入力 [ensure_sf_tools_latest の引数...]。出力は ベースdir/out.log。終了コードを返す
_esl_run() {
    local b="$1" input="$2"; shift 2
    printf '%b' "$input" | (
        export SF_INIT_MODE=1
        readonly SCRIPT_NAME=test; readonly LOG_FILE=/dev/null; readonly LOG_MODE=NEW
        source "$SF_TOOLS_DIR/lib/common.sh"
        ensure_sf_tools_latest "$@"
        echo "RC=$?"
    ) > "$b/out.log" 2>&1
}

test_ensure_sf_tools_latest() {
    echo ""; echo -e "${CLR_HEAD}[TEST] ensure_sf_tools_latest: sf-tools が最新であることの確認（必須）${CLR_RST}"
    local b before after

    # 最新 → 通過（RC=0）。--no-update でも同じ
    b=$(_esl_repos)
    _esl_run "$b" "" "$b/sf-tools"
    assert_exit_ok $? "最新 → 終了コード 0"
    assert_file_contains "$b/out.log" "RC=0" "最新 → 戻り値 0"
    assert_file_contains "$b/out.log" "最新です" "最新 → 「最新です」と表示される"
    _esl_run "$b" "" --no-update "$b/sf-tools"
    assert_file_contains "$b/out.log" "RC=0" "最新 + --no-update → 戻り値 0"
    teardown "$b"

    # 遅れ + Y → git pull --ff-only で更新し、戻り値 2（呼び出し元が、再実行する）
    b=$(_esl_repos); _esl_advance "$b"
    before=$(git -C "$b/sf-tools" rev-list --count HEAD)
    _esl_run "$b" 'Y\n' "$b/sf-tools"
    assert_exit_ok $? "遅れ + Y → 終了コード 0"
    assert_file_contains "$b/out.log" "RC=2" "遅れ + Y → 更新した（戻り値 2）"
    after=$(git -C "$b/sf-tools" rev-list --count HEAD)
    [[ "$after" -eq $((before + 1)) ]] && pass "遅れ + Y → 1 コミット進んだ" || fail "遅れ + Y → 1 コミット進んだ" "前=${before} 後=${after}"
    teardown "$b"

    # 遅れ + N → 更新せず、中断（最新でないと、続行しない）
    b=$(_esl_repos); _esl_advance "$b"
    before=$(git -C "$b/sf-tools" rev-list --count HEAD)
    _esl_run "$b" 'N\n' "$b/sf-tools"
    assert_exit_fail $? "遅れ + N → 中断（異常終了）"
    assert_file_contains "$b/out.log" "最新ではないため、続行できません" "遅れ + N → 理由が表示される"
    after=$(git -C "$b/sf-tools" rev-list --count HEAD)
    [[ "$after" -eq "$before" ]] && pass "遅れ + N → 更新されない" || fail "遅れ + N → 更新されない"
    teardown "$b"

    # 遅れ + --no-update → 質問せず、更新せず、中断
    b=$(_esl_repos); _esl_advance "$b"
    before=$(git -C "$b/sf-tools" rev-list --count HEAD)
    _esl_run "$b" "" --no-update "$b/sf-tools"
    assert_exit_fail $? "遅れ + --no-update → 中断（異常終了）"
    assert_file_contains "$b/out.log" "最新ではありません" "遅れ + --no-update → 理由が表示される"
    after=$(git -C "$b/sf-tools" rev-list --count HEAD)
    [[ "$after" -eq "$before" ]] && pass "遅れ + --no-update → 更新されない" || fail "遅れ + --no-update → 更新されない"
    teardown "$b"

    # 遅れ + 未コミットの変更 → 自動では更新できず、中断（開発者の作業を守る）
    b=$(_esl_repos); _esl_advance "$b"
    echo "local change" >> "$b/sf-tools/f"
    before=$(git -C "$b/sf-tools" rev-list --count HEAD)
    _esl_run "$b" 'Y\n' "$b/sf-tools"
    assert_exit_fail $? "遅れ + 未コミットの変更 → 中断（異常終了）"
    assert_file_contains "$b/out.log" "未コミットの変更" "遅れ + 未コミットの変更 → 理由が表示される"
    after=$(git -C "$b/sf-tools" rev-list --count HEAD)
    [[ "$after" -eq "$before" ]] && pass "遅れ + 未コミットの変更 → 更新されない" || fail "遅れ + 未コミットの変更 → 更新されない"
    teardown "$b"

    # origin に接続できない → 最新か確認できないため、中断（続行しない）
    b=$(_esl_repos)
    rm -rf "$b/origin.git"
    _esl_run "$b" "" "$b/sf-tools"
    assert_exit_fail $? "origin に接続できない → 中断（異常終了）"
    assert_file_contains "$b/out.log" "最新かどうかを確認できません" "origin に接続できない → 理由が表示される"
    teardown "$b"

    # origin に同じブランチがない（手元だけの作業ブランチ）→ 確認できないため、WARNING を出して続行（戻り値 0）
    #   以前は、git fetch origin <ブランチ> の失敗を「接続できない」として、中断していた
    b=$(_esl_repos)
    git -C "$b/sf-tools" checkout -q -b local-only-work
    _esl_run "$b" "" "$b/sf-tools"
    assert_exit_ok $? "origin に同じブランチがない → 終了コード 0（中断しない）"
    assert_file_contains "$b/out.log" "RC=0" "origin に同じブランチがない → 戻り値 0"
    assert_file_contains "$b/out.log" "origin に local-only-work ブランチが存在しない" "origin に同じブランチがない → 警告が表示される"
    assert_file_not_contains "$b/out.log" "接続できない" "origin に同じブランチがない → 「接続できない」とは言わない"
    teardown "$b"

    # Git リポジトリでない → 確認できないため、WARNING を出して続行
    b=$(mktemp -d "${TMPDIR:-/tmp}/test-esl-XXXX"); mkdir -p "$b/sf-tools"
    _esl_run "$b" "" "$b/sf-tools"
    assert_exit_ok $? "Git リポジトリでない → 終了コード 0（確認できないため、続行）"
    assert_file_contains "$b/out.log" "RC=0" "Git リポジトリでない → 戻り値 0"
    assert_file_contains "$b/out.log" "確認できません" "Git リポジトリでない → 警告が表示される"
    teardown "$b"
}

# ------------------------------------------------------------------------------
# json_get のテスト（本物の node で JSON を読む。モックの node は、-e だけ本物に渡す: test_helper.sh）
# ------------------------------------------------------------------------------
# 実行する。引数: JSON パス...。標準出力: json_get の出力。戻り値: json_get の終了コード
_jg() {
    (
        export SF_INIT_MODE=1 PATH="$JG_MB:$PATH"
        readonly SCRIPT_NAME=test; readonly LOG_FILE=/dev/null; readonly LOG_MODE=NEW
        source "$SF_TOOLS_DIR/lib/common.sh"
        json_get "$@"
    ) 2> /dev/null
}

test_json_get() {
    echo ""; echo -e "${CLR_HEAD}[TEST] json_get${CLR_RST}"
    JG_MB=$(setup_mock_bin)
    create_mock_node "$JG_MB"
    local q='"' out rc

    # 基本: sf data query の形（result.records.0.…）・先頭のドット・存在しないパス・null・真偽値
    local j='{"status":0,"result":{"records":[{"Id":"00D1","Name":"Acme","IsSandbox":false,"TrialExpirationDate":null}],"alias":"prod"}}'
    out=$(_jg "$j" status result.records.0.Id result.records.0.Name result.records.0.IsSandbox result.records.0.TrialExpirationDate .result.alias result.none)
    assert_equals "$out" $'0\n00D1\nAcme\nfalse\n\nprod' "基本: 値を、パスごとに 1 行で返す（null は空行。先頭のドットは許容。末尾の空行は、コマンド置換で落ちる）"
    _jg "$j" result.alias > /dev/null; rc=$?
    assert_equals "$rc" "0" "基本: 読み取れたときは 0"

    # ルートが配列
    out=$(_jg '[{"a":"x"},{"a":"y"}]' 1.a)
    assert_equals "$out" "y" "ルートが配列: 添字で取れる"

    # 値が日本語・引用符・波かっこ・改行を含む
    out=$(_jg '{"result":{"v":"会社 \"A\" {x}\n次の行"}}' result.v)
    assert_equals "$out" "会社 ${q}A${q} {x} 次の行" "日本語・引用符・波かっこを含む値。値の中の改行は、空白 1 つになる（1 パス = 1 行）"

    # 「*」: 配列の全要素に展開する（要素ごとに 1 行。キーがない要素は空行で、行の数がそろう）
    out=$(_jg '{"result":[{"alias":"prod","value":"a@x.com"},{"alias":"stg"},{"alias":"dev","value":"c=d@x.com"}]}' 'result.*.alias' 'result.*.value')
    assert_equals "$out" $'prod\nstg\ndev\na@x.com\n\nc=d@x.com' "「*」: 配列の要素ごとに 1 行（キーのない要素は空行）"
    out=$(_jg '{"result":[]}' 'result.*.alias')
    assert_equals "$out" "" "「*」: 空の配列は、何も出さない"
    out=$(_jg '{"a":{"x":{"n":1},"y":{"n":2}}}' 'a.*.n')
    assert_equals "$out" $'1\n2' "「*」: オブジェクトの値にも展開できる"

    # オブジェクトは JSON 文字列で返る
    out=$(_jg '{"result":{"o":{"k":1}}}' result.o)
    assert_equals "$out" '{"k":1}' "オブジェクトは、JSON 文字列で返る"

    # records が空・結果なし
    out=$(_jg '{"status":0,"result":{"records":[]}}' result.records.0.Id)
    assert_equals "$out" "" "records が空: 空行（値なし）"

    # sf の警告が、JSON の前後に付いている（run は標準エラーも標準出力に混ぜる）
    out=$(_jg $'»   Warning: update available\n{"result":{"alias":"prod"}}\n' result.alias)
    assert_equals "$out" "prod" "警告が JSON の前後に付いていても、読める"

    # 読み取れない: 不正な JSON・空・JSON ではない文字列 → 終了コード 1
    _jg 'not json' result.alias > /dev/null; rc=$?
    assert_equals "$rc" "1" "JSON ではない文字列: 終了コード 1"
    _jg '' result.alias > /dev/null; rc=$?
    assert_equals "$rc" "1" "空: 終了コード 1"
    _jg '{"a":' a > /dev/null; rc=$?
    assert_equals "$rc" "1" "途中で切れた JSON: 終了コード 1"

    # 終了コードを確認してから、代入する使い方（コマンド置換の失敗を、検出できる）
    local vals
    vals=$(_jg 'not json' a) && rc=0 || rc=1
    assert_equals "$rc" "1" "コマンド置換: 失敗が、|| で検出できる"
    # set -e でも、呼び出し側が || で受ければ、中断しない
    out=$( set -e; ( export SF_INIT_MODE=1 PATH="$JG_MB:$PATH"; readonly SCRIPT_NAME=test LOG_FILE=/dev/null LOG_MODE=NEW
                     source "$SF_TOOLS_DIR/lib/common.sh"
                     v=$(json_get 'not json' a 2>/dev/null) || v="fallback"; echo "$v" ) )
    assert_equals "$out" "fallback" "set -e でも、|| で受ければ、中断しない"

    # node がない環境: 明確なメッセージで、終了コード 1
    local nonode; nonode=$(mktemp -d "${TMPDIR:-/tmp}/test-nonode-XXXX")
    out=$( ( export SF_INIT_MODE=1 PATH="$nonode:/usr/bin:/bin"; readonly SCRIPT_NAME=test LOG_FILE=/dev/null LOG_MODE=NEW
             source "$SF_TOOLS_DIR/lib/common.sh"
             if command -v node > /dev/null 2>&1; then echo "SKIP-node-in-usr-bin"; exit 0; fi
             json_get '{"a":1}' a; echo "rc=$?" ) 2>&1 )
    if echo "$out" | grep -q "SKIP-node-in-usr-bin"; then
        pass "node がない環境（このテスト環境の /usr/bin に node があるためスキップ）"
    else
        assert_output_contains "$out" "node が見つかりません" "node がない: メッセージが表示される"
        assert_output_contains "$out" "rc=1" "node がない: 終了コード 1"
    fi
    rm -rf "$nonode"
    teardown "$JG_MB"
}

# ------------------------------------------------------------------------------
# merge_package_xml のテスト（package.xml を、種類ごとに、重複なく統合する）
# ------------------------------------------------------------------------------
test_merge_package_xml() {
    echo ""; echo -e "${CLR_HEAD}[TEST] merge_package_xml: マニフェストの統合${CLR_RST}"
    local td out
    td=$(mktemp -d "${TMPDIR:-/tmp}/test-mpx-XXXX")
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<Package xmlns="http://soap.sforce.com/2006/04/metadata">' \
        '    <types>' '        <members>B</members>' '        <members>A</members>' '        <name>ApexClass</name>' '    </types>' \
        '    <version>64.0</version>' '</Package>' > "$td/a.xml"
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<Package xmlns="http://soap.sforce.com/2006/04/metadata">' \
        '    <types>' '        <members>A</members>' '        <members>C</members>' '        <name>ApexClass</name>' '    </types>' \
        '    <types>' '        <members>My__c-My Layout</members>' '        <name>Layout</name>' '    </types>' \
        '    <version>60.0</version>' '</Package>' > "$td/b.xml"
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<Package xmlns="http://soap.sforce.com/2006/04/metadata">' \
        '    <version>64.0</version>' '</Package>' > "$td/empty.xml"
    _mp() { ( export SF_INIT_MODE=1; readonly SCRIPT_NAME=test LOG_FILE=/dev/null LOG_MODE=NEW
              source "$SF_TOOLS_DIR/lib/common.sh"; eval "$1" ) 2>&1; }

    _mp "merge_package_xml '$td/out.xml' '$td/a.xml' '$td/b.xml'"
    out=$(cat "$td/out.xml")
    assert_output_contains "$out" "<members>A</members>"  "統合: 両方のメンバーが入る"
    assert_output_contains "$out" "<members>C</members>"  "統合: 片方だけのメンバーも入る"
    assert_output_contains "$out" "<members>My__c-My Layout</members>" "統合: 名前に空白を含むメンバー"
    assert_equals "$(grep -c '<members>A</members>' "$td/out.xml")" "1" "統合: 重複するメンバーは、1 つにする"
    assert_equals "$(grep -c '<name>ApexClass</name>' "$td/out.xml")" "1" "統合: 同じ種類は、1 つの <types> にまとめる"
    assert_equals "$(grep -c '<types>' "$td/out.xml")" "2" "統合: 種類は 2 つ（ApexClass・Layout）"
    assert_output_contains "$out" "<version>64.0</version>" "統合: version は、最初のものを使う"
    assert_equals "$(head -n 1 "$td/out.xml")" '<?xml version="1.0" encoding="UTF-8"?>' "統合: XML 宣言から始まる"
    assert_equals "$(tail -n 1 "$td/out.xml")" '</Package>' "統合: </Package> で終わる"
    # 種類は、名前の順に並ぶ（ApexClass の後に Layout）
    assert_equals "$(grep '<name>' "$td/out.xml" | tr -d ' \n')" "<name>ApexClass</name><name>Layout</name>" "統合: 種類は、名前の順"

    _mp "merge_package_xml '$td/o2.xml' '$td/empty.xml' '$td/empty.xml'"
    assert_equals "$(grep -c '<members>' "$td/o2.xml")" "0" "統合: 入力が空なら、メンバーのない、空のマニフェストを出力する"
    assert_equals "$(grep -c '<version>64.0</version>' "$td/o2.xml")" "1" "統合: 空でも、version を出力する"

    # 日本語の名前（レイアウトなど）: 別の名前を、同じものとして消さない（LC_ALL=C の sort -u。macOS の sort -u は、ロケールにより、
    #   別の日本語を同一視することがある）
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<Package xmlns="http://soap.sforce.com/2006/04/metadata">' \
        '    <types>' '        <members>Account-取引先 レイアウト</members>' '        <members>Account-商談 レイアウト</members>' \
        '        <name>Layout</name>' '    </types>' '    <version>64.0</version>' '</Package>' > "$td/ja.xml"
    _mp "merge_package_xml '$td/o-ja.xml' '$td/ja.xml' '$td/ja.xml'"
    assert_equals "$(grep -c '<members>' "$td/o-ja.xml")" "2" "統合: 別の日本語の名前は、両方とも残る（重複だけを除く）"

    # 入力が読めない → 戻り値 1。古い出力（前回の結果）は、削除する（以前は、戻り値 0 で、古い出力が残った）
    cp "$td/out.xml" "$td/o3.xml"
    _mp "merge_package_xml '$td/o3.xml' '$td/a.xml' '$td/none.xml'; echo RC=\$?" > "$td/mp.log"
    assert_file_contains "$td/mp.log" "RC=1" "入力がない → 戻り値 1"
    assert_file_contains "$td/mp.log" "読めません" "入力がない → ERROR を表示する"
    assert_file_not_exists "$td/o3.xml" "入力がない → 古い出力を削除する（古い内容を、統合の結果として使わせない）"
    _mp "merge_package_xml '$td/o4.xml'; echo RC=\$?" > "$td/mp.log"
    assert_file_contains "$td/mp.log" "RC=1" "入力の指定がない → 戻り値 1（標準入力を読みに行かない）"
    _mp "merge_package_xml '$td/no-such-dir/o5.xml' '$td/a.xml'; echo RC=\$?" > "$td/mp.log"
    assert_file_contains "$td/mp.log" "RC=1" "出力に書けない → 戻り値 1"
    _mp "merge_package_xml '$td/o6.xml' '$td/a.xml'; echo RC=\$?" > "$td/mp.log"
    assert_file_contains "$td/mp.log" "RC=0" "成功 → 戻り値 0"
    rm -rf "$td"
}

# ------------------------------------------------------------------------------
# run / log の高速化（プロセスを起動しない書き方）の回帰テスト
#   _now_ts（date を使わない時刻）・_mask_secrets_var（Token らしい文字列を含むときだけ sed）・_has_term_codes・
#   _prefix_lines（sed "/./s/^/接頭辞/" と同じ結果）。run が、色・絵文字を含まない出力も、含む出力も、NUL を含む出力も、
#   従来と同じにログへ記録し、NothingToDeploy を検知すること
# ------------------------------------------------------------------------------
test_run_fast_paths() {
    echo ""; echo -e "${CLR_HEAD}[TEST] run / log の高速化（_now_ts・_mask_secrets_var・_has_term_codes・_prefix_lines）${CLR_RST}"
    local td out exp
    td=$(mktemp -d "${TMPDIR:-/tmp}/test-runfast-XXXX")
    mkdir -p "$td/logs"
    _pf() {   # 引数: 実行する式（common.sh を読み込んだ子プロセスで評価する。ログは $td/logs）
        ( export SF_INIT_MODE=1; readonly SCRIPT_NAME=pf LOG_FILE="$td/logs/pf.log" LOG_MODE=NEW
          source "$SF_TOOLS_DIR/lib/common.sh"
          eval "$1" ) 2>/dev/null
    }

    # _now_ts: 書式（YYYY-MM-DD HH:MM:SS）。date と、同じ秒（前後 2 秒以内）の時刻
    out=$(_pf '_now_ts t; echo "$t"')
    [[ "$out" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2}$ ]] && pass "_now_ts: YYYY-MM-DD HH:MM:SS の書式" || fail "_now_ts: YYYY-MM-DD HH:MM:SS の書式" "$out"
    [[ "${out%% *}" == "$(date +%Y-%m-%d)" || "${out%% *}" == "$(date -d yesterday +%Y-%m-%d 2>/dev/null)" ]] && pass "_now_ts: 日付が、date と同じ" || fail "_now_ts: 日付が、date と同じ" "$out"

    # _mask_secrets_var: _mask_secrets と同じ結果（Token を含む・含まない）
    out=$(_pf 'a="x ghp_ABC123 y xoxb-1-2-Ab z github_pat_11AA_bb p"; _mask_secrets_var m "$a"; [[ "$m" == "$(_mask_secrets "$a")" ]] && echo SAME; b="plain text 日本語 ghp xox- github"; _mask_secrets_var n "$b"; [[ "$n" == "$b" && "$n" == "$(_mask_secrets "$b")" ]] && echo SAME2')
    assert_equals "$(echo "$out" | tr '\n' ',')" "SAME,SAME2," "_mask_secrets_var: Token を含むと含まないの、どちらも _mask_secrets と同じ結果"

    # _has_term_codes: ESC・絵文字・— → は「ありうる」。ASCII と日本語（0xe3〜0xe9 始まり）は「ない」
    out=$(_pf 'for s in "plain ascii" "日本語のテスト" $'"'"'a\033[31mb'"'"' "ok ✅" "a — b" "ok 🚀"; do _has_term_codes "$s" && echo Y || echo N; done')
    assert_equals "$(echo "$out" | tr '\n' ',')" "N,N,Y,Y,Y,Y," "_has_term_codes: ASCII・日本語は N、ESC・絵文字・— は Y"

    # _prefix_lines: sed "/./s/^/P /" と同じ（空行は、そのまま）。最後の改行がなくても、改行を付ける
    printf 'a\n\nb\n\n日本語\n' > "$td/in.txt"
    exp=$(sed "/./s/^/P /" "$td/in.txt")
    out=$(_pf "_prefix_lines 'P ' < '$td/in.txt'")
    assert_equals "$out" "$exp" "_prefix_lines: sed と同じ結果（空行はそのまま）"
    printf 'x\ny' > "$td/in2.txt"
    out=$(_pf "_prefix_lines 'P ' < '$td/in2.txt'; echo END")
    assert_equals "$(echo "$out" | tr '\n' ',')" "P x,P y,END," "_prefix_lines: 最後の行に改行がなくても、改行を付ける（次のログが、同じ行に続かない）"

    # run: 色・絵文字なしの出力（組み込みで記録）／色つき（sed で除く）／絵文字／NUL を含む出力（grep で NothingToDeploy を検知）
    : > "$td/logs/pf.log"
    _pf 'run echo hello; run printf "a\n\nb\n"; run printf "\033[31mred\033[0m ok ✅ done\n"; run bash -c "printf \"a\\0NothingToDeploy\\n\""; echo "RC=$?" > '"$td"'/rc.txt'
    assert_file_contains "$td/logs/pf.log" "[OUT] hello" "run: 色・絵文字なしの出力が、[OUT] で記録される"
    assert_file_contains "$td/logs/pf.log" "[OUT] red ok  done" "run: 色の指定と絵文字を除いて記録される（従来どおり）"
    assert_file_contains "$td/rc.txt" "RC=2" "run: NUL を含む出力でも、NothingToDeploy を検知する（RET_NO_CHANGE = 2）"
    # 空行を挟んだ出力（a・空行・b）の、空でない行だけに [OUT] が付く（a と b の 2 行）。NUL を含む出力の先頭の a（1 行）を足して 3 行
    out=$(grep -c '\[OUT\] [ab]$' "$td/logs/pf.log")
    assert_equals "$out" "3" "run: 空行を挟んだ出力の、空でない行だけに、[OUT] が付く"
    rm -rf "$td"
}

# sed_inplace / _strip_ansi / _strip_term_codes のテスト（GNU / BSD の sed の、どちらでも動くこと）
#   BSD の sed（macOS）は、`sed -i SCRIPT FILE` と、\x1b などの 16 進の表記を、解釈しない。
# ------------------------------------------------------------------------------
test_portable_sed() {
    echo ""; echo -e "${CLR_HEAD}[TEST] sed_inplace / _strip_ansi / _strip_term_codes${CLR_RST}"
    local td out rc esc
    td=$(mktemp -d "${TMPDIR:-/tmp}/test-psed-XXXX")
    esc=$'\033'
    _ps() {   # 引数: 実行する式（common.sh を読み込んだ子プロセスで評価する）
        ( export SF_INIT_MODE=1; readonly SCRIPT_NAME=test LOG_FILE=/dev/null LOG_MODE=NEW
          source "$SF_TOOLS_DIR/lib/common.sh"
          eval "$1" ) 2>&1
    }

    # sed_inplace: 削除・置換・戻り値・バックアップを残さない・存在しないファイル
    printf 'A=1\nPAT_TOKEN_VALUE="x"\nB=2\n' > "$td/env"
    _ps "sed_inplace '/^PAT_TOKEN_VALUE=/d' '$td/env'" > /dev/null; rc=$?
    assert_equals "$rc" "0" "sed_inplace: 行を削除できる（戻り値 0）"
    assert_equals "$(tr '\n' ',' < "$td/env")" "A=1,B=2," "sed_inplace: 該当の行だけが、消える"
    assert_equals "$([[ -e "$td/env.bak" ]] && echo yes || echo no)" "no" "sed_inplace: バックアップを残さない"
    printf 'name=__REPO_NAME__\n' > "$td/j"
    _ps "sed_inplace 's/__REPO_NAME__/force-x/g' '$td/j'" > /dev/null
    assert_equals "$(cat "$td/j")" "name=force-x" "sed_inplace: 置換できる"
    _ps "sed_inplace 's/a/b/' '$td/none'" > /dev/null; rc=$?
    assert_equals "$([[ $rc -ne 0 ]] && echo ng || echo ok)" "ng" "sed_inplace: ファイルがなければ、非ゼロ"
    assert_equals "$([[ -e "$td/none.bak" ]] && echo yes || echo no)" "no" "sed_inplace: 失敗しても、バックアップを残さない"

    # _strip_ansi: 色の指定・カーソル操作を除く。日本語・記号は、そのまま
    out=$(printf '%s[34m%s[1mValidated%s[22m %s[?25lWaiting%s[?25h 日本語 ▶\n' "$esc" "$esc" "$esc" "$esc" "$esc" | _ps '_strip_ansi')
    assert_equals "$out" "Validated Waiting 日本語 ▶" "_strip_ansi: ANSI を除き、日本語・記号は残す"

    # _strip_term_codes: ANSI に加えて、絵文字（3 バイト・4 バイト・U+FE0F）を除く。日本語は残す
    out=$(printf '%s[32mOK%s[0m ✅ 完了 🔥 ⚠️ done\n' "$esc" "$esc" | _ps '_strip_term_codes')
    assert_equals "$out" "OK  完了   done" "_strip_term_codes: ANSI と絵文字を除き、日本語は残す"

    # base64_oneline: 76 文字を超える入力でも、1 行（改行なし）になり、元に戻せる。-w 0 を使わない（BSD の base64 にはない）
    local long; long=$(printf 'abcdefghij%.0s' 1 2 3 4 5 6 7 8 9 10 11 12)   # 120 文字
    out=$(printf '%s' "$long" | _ps 'base64_oneline')
    assert_equals "$(printf '%s' "$out" | wc -l | tr -d ' ')" "0" "base64_oneline: 出力に改行を含まない（1 行）"
    assert_equals "$(printf '%s' "$out" | base64 -d 2>/dev/null)" "$long" "base64_oneline: base64 -d で、元の内容に戻る"
    assert_equals "$(grep -c -e '| base64 -w' "$SF_TOOLS_DIR"/bin/*.sh "$SF_TOOLS_DIR"/lib/*.sh "$SF_TOOLS_DIR"/phases/init/*.sh | awk -F: '{s+=$NF} END{print s+0}')" "0" "base64 -w は、使わない（macOS の base64 にはない）"

    rm -rf "$td"
}

# ------------------------------------------------------------------------------
# Bash 3.2（macOS 標準の /bin/bash）で動くこと: set_var / run_with_timeout と、Bash 4 以降の機能を使っていないことの確認
# ------------------------------------------------------------------------------
test_bash32_compat() {
    echo ""; echo -e "${CLR_HEAD}[TEST] Bash 3.2 対応: set_var / run_with_timeout / Bash 4 以降の機能を使わない${CLR_RST}"
    local td out rc start elapsed c
    td=$(mktemp -d "${TMPDIR:-/tmp}/test-b32-XXXX")
    _b32() {   # 引数: 実行する式（common.sh を読み込んだ子プロセスで評価する）
        ( export SF_INIT_MODE=1; readonly SCRIPT_NAME=test LOG_FILE=/dev/null LOG_MODE=NEW
          source "$SF_TOOLS_DIR/lib/common.sh"
          eval "$1" ) 2>&1
    }

    # set_var: 指定した名前の変数に代入する。値は、評価しない（$ や ` を、そのまま入れる）
    out=$(_b32 'f() { set_var "$1" "値 A"; }; f X; echo "X=$X"')
    assert_equals "$out" "X=値 A" "set_var: 呼び出し元の変数に代入できる"
    out=$(_b32 'set_var X '\''$(echo NG) `echo NG` "q" %s'\''; echo "X=$X"')
    assert_equals "$out" 'X=$(echo NG) `echo NG` "q" %s' "set_var: 値は評価しない（\$( ) や \` を、そのまま入れる）"
    out=$(_b32 'set_var "X; echo INJECTED" v; echo "rc=$?"'); rc=$?
    assert_equals "$([[ $rc -ne 0 ]] && echo ng || echo ok)" "ng" "set_var: 変数名が正しくなければ、die する"
    assert_output_contains "$out" "変数名が正しくありません" "set_var: 理由が表示される"
    assert_equals "$([[ "$out" == *$'\n'INJECTED* || "$out" == INJECTED* ]] && echo yes || echo no)" "no" "set_var: 変数名に混ぜたコマンドは、実行されない"

    # run_with_timeout: 終了コードと標準入力を、そのまま渡す。時間切れは 124
    _b32 'run_with_timeout 5 bash -c "exit 3"' > /dev/null; rc=$?
    assert_equals "$rc" "3" "run_with_timeout: コマンドの終了コードを返す"
    out=$(printf 'in-data\n' | _b32 'run_with_timeout 5 cat')
    assert_equals "$out" "in-data" "run_with_timeout: 標準入力を、そのまま渡す"
    start=$SECONDS
    _b32 'run_with_timeout 1 sleep 20' > /dev/null; rc=$?
    elapsed=$(( SECONDS - start ))
    assert_equals "$rc" "124" "run_with_timeout: 時間切れは 124"
    [[ $elapsed -lt 10 ]] && pass "run_with_timeout: 上限の秒数で打ち切る（待ち続けない）" \
        || fail "run_with_timeout: 上限の秒数で打ち切る（待ち続けない）" "所要: ${elapsed} 秒"

    # timeout コマンドがない環境（macOS の標準）でも、同じように動く。PATH を、必要なコマンドだけにして確認する
    mkdir -p "$td/bin"
    for c in sleep cat; do
        printf '#!/bin/bash\nexec "%s" "$@"\n' "$(command -v "$c")" > "$td/bin/$c"; chmod +x "$td/bin/$c"
    done
    _b32 "PATH='$td/bin'; command -v timeout >/dev/null && exit 99; run_with_timeout 5 /bin/bash -c 'exit 3'" > /dev/null; rc=$?
    assert_equals "$rc" "3" "timeout なし: コマンドの終了コードを返す"
    out=$(printf 'in-data\n' | _b32 "PATH='$td/bin'; run_with_timeout 5 cat")
    assert_equals "$out" "in-data" "timeout なし: 標準入力を、そのまま渡す"
    start=$SECONDS
    _b32 "PATH='$td/bin'; run_with_timeout 1 sleep 20" > /dev/null; rc=$?
    elapsed=$(( SECONDS - start ))
    assert_equals "$rc" "124" "timeout なし: 時間切れは 124"
    [[ $elapsed -lt 10 ]] && pass "timeout なし: 上限の秒数で打ち切る（待ち続けない）" \
        || fail "timeout なし: 上限の秒数で打ち切る（待ち続けない）" "所要: ${elapsed} 秒"

    # TERM を無視するコマンドも、上限で打ち切る（TERM のあと、約 2 秒待って KILL する。2026-10-14 のレビューで発見:
    #   以前は、wait が戻らず、待ち続けた）。PATH は、timeout がない状態のまま
    start=$SECONDS
    _b32 "PATH='$td/bin'; run_with_timeout 1 /bin/bash -c 'trap \"\" TERM; while :; do :; done'" > /dev/null 2>&1; rc=$?
    elapsed=$(( SECONDS - start ))
    assert_equals "$rc" "124" "timeout なし: TERM を無視するコマンドも、時間切れは 124"
    [[ $elapsed -lt 12 ]] && pass "timeout なし: TERM を無視するコマンドも、上限＋数秒で打ち切る（KILL）" \
        || fail "timeout なし: TERM を無視するコマンドも、上限＋数秒で打ち切る（KILL）" "所要: ${elapsed} 秒"

    # Bash 4 以降の機能を、使っていないこと（コメントの行は除く。このファイル自身は、下の検索の文字列を含むため除く）
    #   nameref / 連想配列 / mapfile / 大文字・小文字の変換 / |& / &>> / $( ) の中の case（3.2 は「)」を取り違える）
    _b32_grep() {   # 引数: 説明 / 正規表現
        local hits
        hits=$( cd "$SF_TOOLS_DIR" && grep -rnIE -- "$2" bin lib phases hooks templates tests 2>/dev/null \
                  | grep -v '^tests/test_common\.sh:' | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' | head -5 )
        [[ -z "$hits" ]] && pass "使っていない: $1" || fail "使っていない: $1" "$hits"
    }
    _b32_grep "nameref（local -n / declare -n）"  '(local|declare|typeset)[[:space:]]+-[a-zA-Z]*n[a-zA-Z]*[[:space:]]'
    _b32_grep "連想配列（declare -A / local -A）"  '(local|declare|typeset)[[:space:]]+-[a-zA-Z]*A[a-zA-Z]*[[:space:]]'
    _b32_grep "mapfile / readarray"                '(^|[;&|({[:space:]])(mapfile|readarray)[[:space:]]+-'
    _b32_grep "大文字・小文字の変換（\${x^} / \${x,,}）" '\$\{[A-Za-z_0-9]+(\[[^]]*\])?(\^\^?|,,?)\}'
    _b32_grep "wait -n（Bash 4.3 以降）"           '(^|[;&|({[:space:]])wait[[:space:]]+-[a-zA-Z]*n'
    _b32_grep "|& と &>>"                          '(\|&[[:space:]]|&>>)'
    _b32_grep "\$( ) の中の case"                  '\$\([[:space:]]*case[[:space:]]'

    # bin のスクリプトは、実行権限つき（100755）で git に記録されていること。
    #   macOS・Linux では、実行権限がないと、PATH を通しても、`sf-start.sh` と名前だけで呼べない（Windows の Git Bash は、権限を見ない）。
    #   git の記録（インデックス）で見る: ファイルシステムの権限は、環境（core.fileMode=false など）で変わるため
    if git -C "$SF_TOOLS_DIR" rev-parse --git-dir > /dev/null 2>&1; then
        local noexec
        noexec=$(git -C "$SF_TOOLS_DIR" ls-files -s 'bin/*.sh' | awk '$1 != "100755" {print $4}' | head -5 | tr '\n' ' ')
        [[ -z "$noexec" ]] && pass "bin/*.sh は、実行権限つきで git に記録されている" \
            || fail "bin/*.sh は、実行権限つきで git に記録されている" "実行権限なし: ${noexec}（git update-index --chmod=+x で直す）"
    else
        skip "bin/*.sh の実行権限（git のリポジトリではないためスキップ）"
    fi

    # 共通ライブラリが、3.2 を拒否しないこと（バージョンの下限が、3.2 であること）
    grep -q 'BASH_VERSINFO\[0\] == 3 && BASH_VERSINFO\[1\] < 2' "$SF_TOOLS_DIR/lib/common.sh" \
        && pass "common.sh: Bash の下限は 3.2" || fail "common.sh: Bash の下限は 3.2" "バージョンの確認が、3.2 を下限にしていない"

    rm -rf "$td"
}

# ------------------------------------------------------------------------------
# テストの保護: 実際の Git for Windows の更新・npm のグローバル更新・sf update を、テストが実行しない
#   （run_tests.sh が、保護用の代理コマンドを PATH の先頭に置く。2026-10-14: Windows の Actions で、モックが消えたあとの
#    バックグラウンドの sf-upgrade.sh が、本物の git update-git-for-windows を実行し、Git Bash 自体が壊れた）
# ------------------------------------------------------------------------------
test_runner_guard() {
    echo ""; echo -e "${CLR_HEAD}[TEST] テストの保護: 実際の Git / npm / sf の更新を実行しない${CLR_RST}"
    if [[ -z "${SF_TEST_GUARD_BIN:-}" || ! -d "${SF_TEST_GUARD_BIN:-}" ]]; then
        skip "run_tests.sh 経由ではない（SF_TEST_GUARD_BIN がない）ためスキップ"; return
    fi
    local out rc
    [[ "$PATH" == "${SF_TEST_GUARD_BIN}:"* ]] && pass "保護用のフォルダが、PATH の先頭にある" \
        || fail "保護用のフォルダが、PATH の先頭にある" "PATH=${PATH%%:*}..."
    if command -v git > /dev/null 2>&1; then
        out=$(git update-git-for-windows --yes 2>&1); rc=$?
        assert_equals "$rc" "0" "git update-git-for-windows: 実行せず、0 で終わる"
        assert_output_contains "$out" "sftest-guard" "git update-git-for-windows: 保護の表示が出る（本物は動かない）"
        out=$(git --version 2>&1)
        assert_output_contains "$out" "git version" "git の通常のコマンドは、本物に渡る"
    fi
    if command -v npm > /dev/null 2>&1; then
        out=$(npm install -g @salesforce/cli@latest 2>&1); rc=$?
        assert_equals "$rc" "0" "npm install -g: 実行せず、0 で終わる"
        assert_output_contains "$out" "sftest-guard" "npm install -g: 保護の表示が出る（本物は動かない）"
    fi
    if command -v sf > /dev/null 2>&1; then
        out=$(sf update 2>&1); rc=$?
        assert_equals "$rc" "0" "sf update: 実行せず、0 で終わる"
        assert_output_contains "$out" "sftest-guard" "sf update: 保護の表示が出る（本物は動かない）"
    fi
}

test_runner_guard
test_check_gh_owner_match
test_check_gh_owner_mismatch
test_check_gh_owner_skip_on_empty
test_check_gh_owner_org_admin
test_check_gh_owner_org_member
test_check_gh_owner_org_admin_pending
test_check_gh_owner_org_api_failure
test_check_gh_owner_case_insensitive
# ------------------------------------------------------------------------------
# ensure_admin_branch のテスト（実際の Git で確認する）
# ------------------------------------------------------------------------------
# origin(bare) と、main に 1 コミットある clone(c) を作る。戻り値（標準出力）: ベースディレクトリ
_eab_repo() {
    local b
    b=$(mktemp -d "${TMPDIR:-/tmp}/test-eab-XXXX")
    git init -q --bare --initial-branch=main "$b/origin.git"
    git clone -q "$b/origin.git" "$b/c" 2>/dev/null
    (
        cd "$b/c" || exit 1
        git -c user.name=t -c user.email=t@example.com checkout -q -b main && echo 1 > f && git add f \
            && git -c user.name=t -c user.email=t@example.com commit -qm c1 && git push -q origin main
    ) > /dev/null 2>&1
    echo "$b"
}
# 実行する。引数: クローンのディレクトリ 出力先。出力に RC=戻り値 を残す
_eab_run() {
    (
        export SF_INIT_MODE=1
        readonly SCRIPT_NAME=test; readonly LOG_FILE=/dev/null; readonly LOG_MODE=NEW
        source "$SF_TOOLS_DIR/lib/common.sh"
        ensure_admin_branch "$1"
        echo "RC=$?"
    ) > "$2" 2>&1
}

test_ensure_admin_branch() {
    echo ""; echo -e "${CLR_HEAD}[TEST] ensure_admin_branch: 管理者用のクローンを、admin ブランチ（ローカル）にする${CLR_RST}"
    local b cur remote_heads count

    # main にいる → main から admin を作って、切り替わる。GitHub（origin）には、作らない
    b=$(_eab_repo)
    _eab_run "$b/c" "$b/out.log"
    cur=$(git -C "$b/c" symbolic-ref --short HEAD)
    assert_file_contains "$b/out.log" "RC=0" "main → 戻り値 0"
    [[ "$cur" == "admin" ]] && pass "main → admin ブランチに切り替わる" || fail "main → admin ブランチに切り替わる" "現在: ${cur}"
    [[ "$(git -C "$b/c" rev-parse admin)" == "$(git -C "$b/c" rev-parse main)" ]] \
        && pass "admin は、main と同じ位置から作られる" || fail "admin は、main と同じ位置から作られる"
    remote_heads=$(git -C "$b/c" ls-remote --heads origin)
    [[ "$remote_heads" != *"refs/heads/admin"* ]] && pass "ensure_admin_branch 単体では、origin に push しない（push は push_admin_branch）" || fail "ensure_admin_branch 単体では、origin に push しない（push は push_admin_branch）" "$remote_heads"

    # すでに admin にいる → 何も変えない（冪等）
    _eab_run "$b/c" "$b/out2.log"
    cur=$(git -C "$b/c" symbolic-ref --short HEAD)
    assert_file_contains "$b/out2.log" "RC=0" "すでに admin → 戻り値 0"
    [[ "$cur" == "admin" ]] && pass "すでに admin → そのまま" || fail "すでに admin → そのまま" "現在: ${cur}"
    teardown "$b"

    # admin ブランチがすでにあり、main にいる → 作り直さずに、切り替える（admin の作業を消さない）
    b=$(_eab_repo)
    git -C "$b/c" checkout -q -b admin
    echo 2 > "$b/c/g"; git -C "$b/c" add g
    git -C "$b/c" -c user.name=t -c user.email=t@example.com commit -qm admin-work
    git -C "$b/c" checkout -q main
    _eab_run "$b/c" "$b/out.log"
    cur=$(git -C "$b/c" symbolic-ref --short HEAD)
    count=$(git -C "$b/c" rev-list --count admin)
    assert_file_contains "$b/out.log" "RC=0" "admin が既にある → 戻り値 0"
    [[ "$cur" == "admin" ]] && pass "admin が既にある → admin に切り替わる" || fail "admin が既にある → admin に切り替わる" "現在: ${cur}"
    [[ "$count" -eq 2 ]] && pass "admin が既にある → 作り直さない（admin のコミットが残る）" || fail "admin が既にある → 作り直さない（admin のコミットが残る）" "コミット数: ${count}"
    teardown "$b"

    # Git のクローンではない・引数なし → 失敗（戻り値 1）
    b=$(mktemp -d "${TMPDIR:-/tmp}/test-eab-XXXX")
    _eab_run "$b" "$b/out.log"
    assert_file_contains "$b/out.log" "RC=1" "Git のクローンではない → 戻り値 1"
    _eab_run "" "$b/out.log"
    assert_file_contains "$b/out.log" "RC=1" "ディレクトリの指定がない → 戻り値 1"
    teardown "$b"
}

test_push_admin_branch() {
    echo ""; echo -e "${CLR_HEAD}[TEST] push_admin_branch: admin ブランチを GitHub にも作る（強制 push はしない）${CLR_RST}"
    local b up remote_sha other

    # admin にいる → origin にも admin ができ、追跡（upstream）が設定される
    b=$(_eab_repo)
    _eab_run "$b/c" "$b/out.log"
    (
        export SF_INIT_MODE=1
        readonly SCRIPT_NAME=test; readonly LOG_FILE=/dev/null; readonly LOG_MODE=NEW
        source "$SF_TOOLS_DIR/lib/common.sh"
        push_admin_branch "$b/c"
        echo "RC=$?"
    ) > "$b/push.log" 2>&1
    assert_file_contains "$b/push.log" "RC=0" "admin → push できる（戻り値 0）"
    [[ "$(git -C "$b/c" ls-remote --heads origin)" == *"refs/heads/admin"* ]] \
        && pass "origin にも、admin ブランチができる" || fail "origin にも、admin ブランチができる"
    up=$(git -C "$b/c" rev-parse --abbrev-ref admin@{upstream} 2>/dev/null)
    [[ "$up" == "origin/admin" ]] && pass "追跡ブランチが origin/admin になる（-u）" || fail "追跡ブランチが origin/admin になる（-u）" "upstream: ${up}"

    # 2 回目 → すでに最新でも、失敗しない
    (
        export SF_INIT_MODE=1
        readonly SCRIPT_NAME=test; readonly LOG_FILE=/dev/null; readonly LOG_MODE=NEW
        source "$SF_TOOLS_DIR/lib/common.sh"
        push_admin_branch "$b/c"
        echo "RC=$?"
    ) > "$b/push2.log" 2>&1
    assert_file_contains "$b/push2.log" "RC=0" "すでに最新 → 戻り値 0"
    teardown "$b"

    # GitHub 側の admin が食い違っている → 失敗（戻り値 1）にして、GitHub 側を上書きしない
    b=$(_eab_repo)
    git clone -q "$b/origin.git" "$b/other" 2>/dev/null
    (
        cd "$b/other" || exit 1
        git checkout -q -b admin && echo x > other.txt && git add other.txt \
            && git -c user.name=t -c user.email=t@example.com commit -qm other && git push -q origin admin
    ) > /dev/null 2>&1
    remote_sha=$(git -C "$b/c" ls-remote --heads origin admin | cut -f1)
    _eab_run "$b/c" "$b/out.log"
    echo y > "$b/c/local.txt"; git -C "$b/c" add local.txt
    git -C "$b/c" -c user.name=t -c user.email=t@example.com commit -qm local-work
    (
        export SF_INIT_MODE=1
        readonly SCRIPT_NAME=test; readonly LOG_FILE=/dev/null; readonly LOG_MODE=NEW
        source "$SF_TOOLS_DIR/lib/common.sh"
        push_admin_branch "$b/c"
        echo "RC=$?"
    ) > "$b/push3.log" 2>&1
    assert_file_contains "$b/push3.log" "RC=1" "GitHub 側の admin と食い違う → 戻り値 1"
    [[ "$(git -C "$b/c" ls-remote --heads origin admin | cut -f1)" == "$remote_sha" ]] \
        && pass "食い違うとき、GitHub 側の admin を上書きしない" || fail "食い違うとき、GitHub 側の admin を上書きしない"
    teardown "$b"

    # ディレクトリの指定がない → 失敗
    b=$(mktemp -d "${TMPDIR:-/tmp}/test-eab-XXXX")
    (
        export SF_INIT_MODE=1
        readonly SCRIPT_NAME=test; readonly LOG_FILE=/dev/null; readonly LOG_MODE=NEW
        source "$SF_TOOLS_DIR/lib/common.sh"
        push_admin_branch ""
        echo "RC=$?"
    ) > "$b/out.log" 2>&1
    assert_file_contains "$b/out.log" "RC=1" "ディレクトリの指定がない → 戻り値 1"
    teardown "$b"
}

# --- get_target_org: sf org display の一時的な失敗は、待って、やり直す。特定できなければ、原因を残す ---
test_get_target_org() {
    echo ""; echo -e "${CLR_HEAD}[TEST] get_target_org（一時的な失敗のやり直し・原因の記録）${CLR_RST}"
    local b rc; b=$(mktemp -d "${TMPDIR:-/tmp}/test-gto-XXXX")
    create_mock_node "$b"
    # sf org display: 1 回目から N 回までは、失敗の JSON（MOCK_DISPLAY_FAILS=N）。以後は、エイリアス itorg。呼び出し回数を数える
    cat > "$b/sf" << 'EOF'
#!/bin/bash
d="${MOCK_DIR:?}"
n=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$d/count"
if [[ $n -le ${MOCK_DISPLAY_FAILS:-0} ]]; then
    echo '{"status":1,"name":"RefreshTokenAuthError","message":"Error authenticating with the refresh token"}'; exit 1
fi
echo '{"status":0,"result":{"alias":"itorg","id":"00D000000000001AAA"}}'
EOF
    chmod +x "$b/sf"
    _gto() {   # 引数: MOCK_DISPLAY_FAILS [追加の環境変数...]。結果は $b/out.log
        rm -f "$b/count"
        (
            export MOCK_DIR="$b" PATH="$b:$PATH" MOCK_DISPLAY_FAILS="$1" SF_TOOLS_ORG_DISPLAY_WAIT=0 SF_INIT_MODE=1
            unset SF_TARGET_ORG
            readonly SCRIPT_NAME=test; readonly LOG_FILE=/dev/null; readonly LOG_MODE=NEW
            source "$SF_TOOLS_DIR/lib/common.sh"
            out=$(get_target_org); echo "RC=$? OUT=${out}"
        ) > "$b/out.log" 2>&1
    }

    _gto 0
    assert_file_contains "$b/out.log" "RC=0 OUT=itorg" "get_target_org: 1 回目で取れれば、そのエイリアスを返す"
    assert_equals "$(cat "$b/count")" "1" "get_target_org: 1 回目で取れたら、やり直さない"
    _gto 2
    assert_file_contains "$b/out.log" "RC=0 OUT=itorg" "get_target_org: 一時的に 2 回失敗しても、3 回目で取れる"
    assert_equals "$(cat "$b/count")" "3" "get_target_org: 試行は 3 回"
    _gto 9
    assert_file_contains "$b/out.log" "RC=1" "get_target_org: 3 回とも失敗したら、戻り値 1"
    assert_equals "$(cat "$b/count")" "3" "get_target_org: 失敗し続けても、試行は 3 回で止まる"
    assert_file_contains "$b/out.log" "3 回試行" "get_target_org: 試行の回数が、警告に出る"
    assert_file_contains "$b/out.log" "Error authenticating with the refresh token" "get_target_org: sf の応答の要点（message）が、警告に出る"
    # 明示指定・環境変数は、sf を呼ばない
    rm -f "$b/count"
    ( export MOCK_DIR="$b" PATH="$b:$PATH" SF_INIT_MODE=1; unset SF_TARGET_ORG
      readonly SCRIPT_NAME=test; readonly LOG_FILE=/dev/null; readonly LOG_MODE=NEW
      source "$SF_TOOLS_DIR/lib/common.sh"
      out=$(get_target_org explicit); echo "RC=$? OUT=${out}" ) > "$b/out.log" 2>&1
    assert_file_contains "$b/out.log" "RC=0 OUT=explicit" "get_target_org: 引数で指定すれば、そのまま返す"
    assert_file_not_exists "$b/count" "get_target_org: 引数で指定すれば、sf を呼ばない"
    teardown "$b"
}

test_read_secret
test_read_key_and_press_enter
test_get_target_org
test_mask_secrets
test_run_fast_paths
test_is_gitbash
test_is_reserved_org_alias
test_open_browser_gitbash
test_open_browser_wsl_quote
test_is_protected_branch
test_check_sf_cli
test_check_sf_cli_cache
test_print_admin_warning
test_run_isolated_home
test_ensure_sf_tools_latest
test_ensure_admin_branch
test_push_admin_branch
test_json_get
test_portable_sed
test_merge_package_xml
test_bash32_compat

print_summary
