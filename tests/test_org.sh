#!/bin/bash
# ==============================================================================
# test_org.sh - lib/org.sh（Salesforce 組織の接続情報の共通部品）のテスト
# ==============================================================================
#
# 【テストケース】
#   1. org_validate_url      : https かつ salesforce.com / force.com のみ許可
#   2. org_tier_of_suffix    : PROD / STG / DEV → main / staging / develop
#   3. org_choose_login_url  : 3 択（Enter=Sandbox・1・2・3 の URL 入力・q）/ 環境変数の指定 / 不正な URL の再入力
#   4. org_read_info / org_kind : 本番・Sandbox・Developer Edition・Trial・読み取り失敗（判定不能）
#   5. org_guard             : 本番は main のみ（staging・develop は拒否）/ 判定不能は確認
#   6. org_save              : 組織の情報を GitHub Variables に保存
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== lib/org.sh ===${CLR_RST}"

# 子プロセスで式を実行する。標準エラーを $OUT に、標準出力を $STD に、終了コードを $RC に入れる
#   引数: 実行する式。モックの sf / gh は、$MB に作る（呼び出し側で setup_mock_bin / create_all_mocks 済み）
_o() {
    OUT=$(mktemp "${TMPDIR:-/tmp}/test-sforg-err-XXXX")
    STD=$(mktemp "${TMPDIR:-/tmp}/test-sforg-std-XXXX")
    (
        export SF_INIT_MODE=1 PATH="$MB:$PATH"
        readonly SCRIPT_NAME=test
        readonly LOG_FILE=/dev/null
        readonly LOG_MODE=NEW
        source "${SF_TOOLS_DIR}/lib/common.sh"
        source "${SF_TOOLS_DIR}/lib/org.sh"
        eval "$1"
    ) > "$STD" 2> "$OUT"
    RC=$?
}
_oc() { rm -f "$OUT" "$STD"; }

MB=$(setup_mock_bin)
export MOCK_CALL_LOG="$MB/calls.log"
create_all_mocks "$MB"

test_validate_url() {
    echo ""; echo -e "${CLR_HEAD}[TEST] org_validate_url${CLR_RST}"
    local u
    for u in "https://login.salesforce.com" "https://test.salesforce.com" "https://mycompany.my.salesforce.com" \
             "https://mycompany--dev.sandbox.my.salesforce.com" "https://mycompany.my.site.force.com/path"; do
        _o "org_validate_url '$u'"
        assert_exit_ok "$RC" "許可: $u"; _oc
    done
    for u in "http://login.salesforce.com" "https://evil.example.com" "https://login.salesforce.com.evil.com" \
             "login.salesforce.com" "https://salesforce.com.evil.com/" "" "ftp://x.salesforce.com"; do
        _o "org_validate_url '$u'"
        assert_exit_fail "$RC" "拒否: ${u:-（空）}"; _oc
    done
}

test_tier() {
    echo ""; echo -e "${CLR_HEAD}[TEST] org_tier_of_suffix${CLR_RST}"
    _o 'echo "$(org_tier_of_suffix PROD) $(org_tier_of_suffix STG) $(org_tier_of_suffix DEV) [$(org_tier_of_suffix X)]"'
    assert_equals "$(cat "$STD")" "main staging develop []" "PROD→main / STG→staging / DEV→develop / 不明→空"; _oc
}

test_choose() {
    echo ""; echo -e "${CLR_HEAD}[TEST] org_choose_login_url${CLR_RST}"
    _o 'org_choose_login_url U "メイン組織" main PROD; echo "URL=$U"' <<< ""
    assert_file_contains "$STD" "URL=https://test.salesforce.com" "Enter → Sandbox（test.salesforce.com）"
    assert_file_contains "$OUT" "[2] https://test.salesforce.com" "選択肢は、ログイン先の URL で出る（種類ではなく）"; _oc
    _o 'org_choose_login_url U "メイン組織" main PROD; echo "URL=$U"' <<< "1"
    assert_file_contains "$STD" "URL=https://login.salesforce.com" "1 → login.salesforce.com"
    assert_file_contains "$OUT" "本番・Developer Edition・Trial など" "main の [1]: 本番を含む説明"; _oc
    _o 'org_choose_login_url U "検証組織" staging STG; echo "URL=$U"' <<< "1"
    assert_file_contains "$OUT" "本番は、main のみ" "staging の [1]: 「本番は main のみ」と添える（F8）"; _oc
    _o 'org_choose_login_url U "メイン組織" main PROD; echo "URL=$U"' <<< $'3\nhttps://mycompany.my.salesforce.com/'
    assert_file_contains "$STD" "URL=https://mycompany.my.salesforce.com" "3 → 組織の URL（末尾の / は除く）"; _oc
    _o 'org_choose_login_url U "メイン組織" main PROD; echo "URL=$U"' <<< $'3\nhttps://evil.example.com\nhttps://ok.my.salesforce.com'
    assert_file_contains "$STD" "URL=https://ok.my.salesforce.com" "不正な URL → 再入力"
    assert_file_contains "$OUT" "ログイン先の形式ではありません" "不正な URL: 理由が表示される"; _oc
    _o 'org_choose_login_url U "メイン組織" main PROD; echo "URL=$U"' <<< $'x\n2'
    assert_file_contains "$STD" "URL=https://test.salesforce.com" "不正な番号 → 再入力"; _oc
    _o 'org_choose_login_url U "メイン組織" main PROD; echo "URL=$U"' <<< "q"
    assert_exit_fail "$RC" "q → 中断"; _oc
    _o 'org_choose_login_url U "メイン組織" main PROD; echo "URL=$U"' < /dev/null
    assert_exit_fail "$RC" "EOF → 中断"; _oc
    # 環境変数による指定（質問しない）
    SF_INIT_LOGIN_URL_PROD=login _o 'org_choose_login_url U "メイン組織" main PROD; echo "URL=$U"' < /dev/null
    assert_file_contains "$STD" "URL=https://login.salesforce.com" "SF_INIT_LOGIN_URL_PROD=login → 質問せず login.salesforce.com"; _oc
    SF_INIT_LOGIN_URL_STG=https://x.sandbox.my.salesforce.com _o 'org_choose_login_url U "検証" staging STG; echo "URL=$U"' < /dev/null
    assert_file_contains "$STD" "URL=https://x.sandbox.my.salesforce.com" "環境変数に URL を指定 → そのまま使う"; _oc
    SF_INIT_LOGIN_URL_STG=https://evil.example.com _o 'org_choose_login_url U "検証" staging STG' < /dev/null
    assert_exit_fail "$RC" "環境変数の URL が不正 → 中断"; _oc
}

test_kind() {
    echo ""; echo -e "${CLR_HEAD}[TEST] org_read_info / org_kind${CLR_RST}"
    local j
    j='{"status":0,"result":{"records":[{"Id":"00D1","Name":"Acme Prod","IsSandbox":false,"OrganizationType":"Enterprise Edition","TrialExpirationDate":null}]}}'
    MOCK_SF_ORG_INFO="$j" _o 'org_read_info x; echo "$ORG_ID|$ORG_NAME|$(org_kind)"'
    assert_equals "$(cat "$STD")" "00D1|Acme Prod|production" "本番: IsSandbox=false・Enterprise Edition → production"; _oc
    j='{"status":0,"result":{"records":[{"Id":"00D2","Name":"Acme Dev","IsSandbox":true,"OrganizationType":"Enterprise Edition","TrialExpirationDate":null}]}}'
    MOCK_SF_ORG_INFO="$j" _o 'org_read_info x; echo "$(org_kind)"'
    assert_equals "$(cat "$STD")" "sandbox" "IsSandbox=true → sandbox"; _oc
    j='{"status":0,"result":{"records":[{"Id":"00D3","Name":"My DE","IsSandbox":false,"OrganizationType":"Developer Edition","TrialExpirationDate":null}]}}'
    MOCK_SF_ORG_INFO="$j" _o 'org_read_info x; echo "$(org_kind)"'
    assert_equals "$(cat "$STD")" "developer" "Developer Edition → developer（本番ではない）"; _oc
    j='{"status":0,"result":{"records":[{"Id":"00D4","Name":"Partner DE","IsSandbox":false,"OrganizationType":"Partner Developer Edition","TrialExpirationDate":null}]}}'
    MOCK_SF_ORG_INFO="$j" _o 'org_read_info x; echo "$(org_kind)"'
    assert_equals "$(cat "$STD")" "developer" "Partner Developer Edition → developer"; _oc
    j='{"status":0,"result":{"records":[{"Id":"00D5","Name":"Trial","IsSandbox":false,"OrganizationType":"Enterprise Edition","TrialExpirationDate":"2026-12-01T00:00:00.000+0000"}]}}'
    MOCK_SF_ORG_INFO="$j" _o 'org_read_info x; echo "$(org_kind)"'
    assert_equals "$(cat "$STD")" "trial" "TrialExpirationDate あり → trial（本番ではない）"; _oc
    MOCK_SF_ORG_QUERY_EXIT=1 _o 'org_read_info x; echo "rc=$?|$(org_kind)"'
    assert_equals "$(cat "$STD")" "rc=1|unknown" "読み取り失敗 → 判定不能（推測しない）"; _oc
    j='{"status":0,"result":{"records":[{"Id":"00D6","Name":"X","IsSandbox":false,"TrialExpirationDate":null}]}}'
    MOCK_SF_ORG_INFO="$j" _o 'org_read_info x; echo "$(org_kind)"'
    assert_equals "$(cat "$STD")" "unknown" "OrganizationType が無い → 判定不能（本番と推測しない）"; _oc
    MOCK_SF_ORG_INFO='{"status":0,"result":{"records":[]}}' _o 'org_read_info x; echo "rc=$?|$(org_kind)"'
    assert_equals "$(cat "$STD")" "rc=1|unknown" "レコードなし → 判定不能"; _oc
}

test_guard() {
    echo ""; echo -e "${CLR_HEAD}[TEST] org_guard: 本番は main のみ（F8）${CLR_RST}"
    local prod='{"status":0,"result":{"records":[{"Id":"00D1","Name":"Acme Prod","IsSandbox":false,"OrganizationType":"Enterprise Edition","TrialExpirationDate":null}]}}'
    local sbx='{"status":0,"result":{"records":[{"Id":"00D2","Name":"Acme Dev","IsSandbox":true,"OrganizationType":"Enterprise Edition","TrialExpirationDate":null}]}}'
    local de='{"status":0,"result":{"records":[{"Id":"00D3","Name":"My DE","IsSandbox":false,"OrganizationType":"Developer Edition","TrialExpirationDate":null}]}}'
    MOCK_SF_ORG_INFO="$prod" _o 'org_read_info x; org_guard main "メイン組織"'
    assert_exit_ok "$RC" "本番 → main: 接続できる"; _oc
    MOCK_SF_ORG_INFO="$prod" _o 'org_read_info x; org_guard staging "検証組織"; echo "rc=$?"'
    assert_file_contains "$STD" "rc=2" "本番 → staging: 拒否（戻り値 2）"
    assert_file_contains "$OUT" "本番組織は、main にしか、つなげません" "本番 → staging: 理由が表示される"; _oc
    MOCK_SF_ORG_INFO="$prod" _o 'org_read_info x; org_guard develop "開発組織"; echo "rc=$?"'
    assert_file_contains "$STD" "rc=2" "本番 → develop: 拒否"; _oc
    MOCK_SF_ORG_INFO="$sbx" _o 'org_read_info x; org_guard main "メイン組織"; echo "rc=$?"'
    assert_file_contains "$STD" "rc=0" "Sandbox → main: 接続できる（main に Sandbox も可）"; _oc
    MOCK_SF_ORG_INFO="$de" _o 'org_read_info x; org_guard main "メイン組織"; echo "rc=$?"'
    assert_file_contains "$STD" "rc=0" "Developer Edition → main: 接続できる"; _oc
    MOCK_SF_ORG_INFO="$de" _o 'org_read_info x; org_guard staging "検証組織"; echo "rc=$?"'
    assert_file_contains "$STD" "rc=0" "Developer Edition → staging: 接続できる"; _oc
    MOCK_SF_ORG_INFO="$sbx" _o 'org_read_info x; org_guard develop "開発組織"; echo "rc=$?"'
    assert_file_contains "$STD" "rc=0" "Sandbox → develop: 接続できる"; _oc
    # 判定不能は、main 以外には、つなげない（確認では、通さない。本番かどうか、確かめられないため）
    MOCK_SF_ORG_QUERY_EXIT=1 _o 'org_read_info x; org_guard staging "検証組織"; echo "rc=$?"' < /dev/null
    assert_file_contains "$STD" "rc=2" "判定不能 → staging: 拒否（質問せずに、戻り値 2）"
    assert_file_contains "$OUT" "組織の種類を判定できませんでした" "判定不能 → staging: 理由が表示される"; _oc
    MOCK_SF_ORG_QUERY_EXIT=1 _o 'org_read_info x; org_guard develop "開発組織"; echo "rc=$?"' <<< "Y"
    assert_file_contains "$STD" "rc=2" "判定不能 → develop: Y を入力しても、拒否する（確認で通さない）"; _oc
    MOCK_SF_ORG_QUERY_EXIT=1 _o 'org_read_info x; org_guard main "メイン組織"; echo "rc=$?"' < /dev/null
    assert_file_contains "$STD" "rc=0" "判定不能 → main: 確認なしで続行（main はどの種類でも可）"; _oc
}

test_save() {
    echo ""; echo -e "${CLR_HEAD}[TEST] org_save${CLR_RST}"
    : > "$MOCK_CALL_LOG"
    MOCK_SF_ORG_INFO='{"status":0,"result":{"records":[{"Id":"00D9","Name":"Org Nine","IsSandbox":true,"OrganizationType":"Enterprise Edition","TrialExpirationDate":null}]}}' \
        _o 'REPO_FULL_NAME=o/force-x; org_read_info x; org_save STG'
    assert_file_contains "$MOCK_CALL_LOG" "gh variable set SF_ORG_ID_STG --body 00D9 -R o/force-x"      "組織 ID を保存する"
    assert_file_contains "$MOCK_CALL_LOG" "gh variable set SF_ORG_KIND_STG --body sandbox -R o/force-x" "種類を保存する"
    assert_file_contains "$MOCK_CALL_LOG" "SF_ORG_NAME_STG"                                           "組織名を保存する"
    assert_file_contains "$MOCK_CALL_LOG" "SF_ORG_CHECKED_STG"                                        "確認日時を保存する"; _oc
    : > "$MOCK_CALL_LOG"
    MOCK_SF_ORG_QUERY_EXIT=1 _o 'REPO_FULL_NAME=o/force-x; org_read_info x; org_save STG'
    assert_file_not_contains "$MOCK_CALL_LOG" "SF_ORG_ID_STG" "読み取れていない → 保存しない（推測した値を、保存しない）"; _oc
}

# JWT 接続テストと、組織情報の読み取り（従来の接続アプリ用。同じ一時的なホームの中）
test_jwt_test() {
    echo ""; echo -e "${CLR_HEAD}[TEST] org_jwt_test / org_parse_info${CLR_RST}"
    local de='{"status":0,"result":{"records":[{"Id":"00D3","Name":"My DE","IsSandbox":false,"OrganizationType":"Developer Edition","TrialExpirationDate":null}]}}'
    : > "$MOCK_CALL_LOG"
    MOCK_SF_ORG_INFO="$de" _o 'org_jwt_test al KEY /tmp/k.key u@x.com https://login.salesforce.com; echo "rc=$?|$ORG_ID|$(org_kind)"'
    assert_file_contains "$STD" "rc=0|00D3|developer" "JWT 接続テスト成功 → 組織の情報も読み取れる"
    assert_file_contains "$MOCK_CALL_LOG" "sf org login jwt" "JWT ログインを実行する"
    assert_file_contains "$MOCK_CALL_LOG" "FROM Organization" "同じ一時的なホームの中で、組織の種類を問い合わせる"; _oc
    MOCK_SF_LOGIN_EXIT=1 _o 'org_jwt_test al KEY /tmp/k.key u@x.com https://login.salesforce.com; echo "rc=$?|[$ORG_ID]|$(org_kind)"'
    assert_file_contains "$STD" "rc=1|[]|unknown" "JWT 接続テスト失敗 → 組織の情報は、空（判定不能。推測しない）"; _oc
    _o 'org_parse_info "{\"status\":1,\"result\":{}}"; echo "rc=$?"'
    assert_file_contains "$STD" "rc=1" "status が 0 ではない JSON → 読み取れない"; _oc
}

test_validate_url
test_tier
test_jwt_test
test_choose
test_kind
test_guard
test_save

teardown "$MB"
print_summary
