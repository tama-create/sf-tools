#!/bin/bash
# ==============================================================================
# test_sf-start.sh - sf-start.sh のテスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-start.sh ===${CLR_RST}"

# 接続済みの場合 → ログインスキップ、VS Code が起動される
test_connected_org() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    mkdir -p "$mh/sf-tools/bin"
    printf '#!/bin/bash\necho "sf-launcher called" >> "%s"\n' "$MOCK_CALL_LOG" > "$mh/sf-tools/bin/sf-launcher.sh"
    chmod +x "$mh/sf-tools/bin/sf-launcher.sh"

    # 接続済みを示す設定ファイルを用意
    echo '{"target-org":"testorg"}' > "$td/.sf/config.json"
    # sf org display が接続済みの JSON を返すよう設定
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-start.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "接続済み → 終了コード 0"
    assert_file_contains "$MOCK_CALL_LOG" "code ." "VS Code が起動された"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb" "$mh"
}

# 接続済みの場合 → VS Code の設定ファイルが書き込まれる
test_config_files_written() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    mkdir -p "$mh/sf-tools/bin"
    printf '#!/bin/bash\nexit 0\n' > "$mh/sf-tools/bin/sf-launcher.sh"
    chmod +x "$mh/sf-tools/bin/sf-launcher.sh"

    echo '{"target-org":"testorg"}' > "$td/.sf/config.json"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-start.sh" 2>&1 >/dev/null

    assert_file_exists "$td/.sf/config.json" ".sf/config.json が書き込まれた"
    assert_file_exists "$td/.sfdx/sfdx-config.json" ".sfdx/sfdx-config.json が書き込まれた"
    assert_file_contains "$td/.sf/config.json" "testorg" "正しい org alias が設定された"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb" "$mh"
}

# FORCE_RELOGIN=1 → 接続済みでも強制ログインフローに入る
test_force_relogin() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    mkdir -p "$mh/sf-tools/bin"
    printf '#!/bin/bash\nexit 0\n' > "$mh/sf-tools/bin/sf-launcher.sh"
    chmod +x "$mh/sf-tools/bin/sf-launcher.sh"

    echo '{"target-org":"testorg"}' > "$td/.sf/config.json"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    # ORG_ALIAS 入力をシミュレートするため stdin に与える
    # 入力: エイリアス → ログイン先（Enter = Sandbox）
    local out; out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" FORCE_RELOGIN=1 \
        bash "$SF_TOOLS_DIR/bin/sf-start.sh" <<< $'testorg\n\n' 2>&1)
    local ec=$?

    assert_file_contains "$MOCK_CALL_LOG" "sf org login" "FORCE_RELOGIN=1 → ログインが呼び出された"
    assert_file_contains "$MOCK_CALL_LOG" "--instance-url https://test.salesforce.com" "Enter → Sandbox（test.salesforce.com）でログインする"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb" "$mh"
}

# ログイン先は、エイリアスの名前では決めない（alias が prod でも、選択した URL でログインする）
test_login_url_not_by_alias() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    mkdir -p "$mh/sf-tools/bin"
    printf '#!/bin/bash\nexit 0\n' > "$mh/sf-tools/bin/sf-launcher.sh"
    chmod +x "$mh/sf-tools/bin/sf-launcher.sh"
    echo '{"target-org":"x"}' > "$td/.sf/config.json"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"x","id":"00D000000000001AAA"}}'

    # alias = prod で、Enter（Sandbox）→ test.salesforce.com（従来は、prod なら、login.salesforce.com だった）
    : > "$MOCK_CALL_LOG"
    (cd "$td" && HOME="$mh" PATH="$mb:$PATH" FORCE_RELOGIN=1 bash "$SF_TOOLS_DIR/bin/sf-start.sh" <<< $'prod\n\n') > /dev/null 2>&1
    assert_file_contains "$MOCK_CALL_LOG" "--alias prod --instance-url https://test.salesforce.com" "alias が prod でも、選んだ URL（Sandbox）でログインする"
    # alias = sbx で、1（login.salesforce.com）→ login.salesforce.com（Developer Edition や別名の本番）
    : > "$MOCK_CALL_LOG"
    (cd "$td" && HOME="$mh" PATH="$mb:$PATH" FORCE_RELOGIN=1 bash "$SF_TOOLS_DIR/bin/sf-start.sh" <<< $'devorg\n1\n') > /dev/null 2>&1
    assert_file_contains "$MOCK_CALL_LOG" "--alias devorg --instance-url https://login.salesforce.com" "別名でも、1 を選べば、login.salesforce.com でログインする"
    # 環境変数での指定（質問しない）
    : > "$MOCK_CALL_LOG"
    (cd "$td" && HOME="$mh" PATH="$mb:$PATH" FORCE_RELOGIN=1 SF_INIT_LOGIN_URL_START=login bash "$SF_TOOLS_DIR/bin/sf-start.sh" <<< $'a1\n') > /dev/null 2>&1
    assert_file_contains "$MOCK_CALL_LOG" "--alias a1 --instance-url https://login.salesforce.com" "SF_INIT_LOGIN_URL_START=login → 質問せずに指定できる"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb" "$mh"
}

# sf-start.sh → sf-launcher.sh が呼ばれる
test_launcher_called() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    mkdir -p "$mh/sf-tools/bin"
    printf '#!/bin/bash\necho "sf-launcher called" >> "%s"\n' "$MOCK_CALL_LOG" > "$mh/sf-tools/bin/sf-launcher.sh"
    chmod +x "$mh/sf-tools/bin/sf-launcher.sh"

    echo '{"target-org":"testorg"}' > "$td/.sf/config.json"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-start.sh" 2>&1 >/dev/null

    assert_file_contains "$MOCK_CALL_LOG" "sf-launcher called" "sf-launcher.sh が呼び出された"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb" "$mh"
}

# force-* 以外で実行 → エラー
test_outside_force_dir() {
    local rd mb mh
    rd=$(setup_regular_dir); mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"; mh=$(setup_mock_home)
    create_all_mocks "$mb"
    mkdir -p "$mh/sf-tools/bin"
    printf '#!/bin/bash\nexit 0\n' > "$mh/sf-tools/bin/sf-launcher.sh"
    chmod +x "$mh/sf-tools/bin/sf-launcher.sh"

    local out; out=$(cd "$rd" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-start.sh" 2>&1)
    local ec=$?

    assert_exit_fail $ec "force-* 外 → エラー終了"
    teardown "$rd" "$mb" "$mh"
}

test_connected_org
test_config_files_written
test_force_relogin
test_login_url_not_by_alias
# sf の終了コードが 0 以外（インストーラー版の不具合）→ 案内を表示して中断する
test_sf_cli_abort() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    mkdir -p "$mh/sf-tools/bin"
    printf '#!/bin/bash\nexit 0\n' > "$mh/sf-tools/bin/sf-launcher.sh"
    chmod +x "$mh/sf-tools/bin/sf-launcher.sh"
    echo '{"target-org":"testorg"}' > "$td/.sf/config.json"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" MOCK_SF_VERSION_EXIT=1 bash "$SF_TOOLS_DIR/bin/sf-start.sh" 2>&1)
    local ec=$?

    assert_exit_fail $ec "sf の終了コード 1 → 中断する（終了コード 0 以外）"
    assert_output_contains "$out" "終了コードが 0 ではありません" "案内が表示された"
    assert_file_not_contains "$MOCK_CALL_LOG" "code ." "VS Code の起動まで、進まない"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb" "$mh"
}

test_launcher_called
test_sf_cli_abort
test_outside_force_dir

print_summary
