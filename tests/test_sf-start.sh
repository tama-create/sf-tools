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
    local out; out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" FORCE_RELOGIN=1 \
        bash "$SF_TOOLS_DIR/bin/sf-start.sh" <<< "testorg" 2>&1)
    local ec=$?

    assert_file_contains "$MOCK_CALL_LOG" "sf org login" "FORCE_RELOGIN=1 → ログインが呼び出された"
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
# sf の終了コードが 0 以外（インストーラー版の不具合）→ 警告を表示するが、続行する
test_sf_cli_warning_only() {
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

    assert_exit_ok $ec "sf の終了コード 1 → 警告のみで、終了コード 0（続行する）"
    assert_output_contains "$out" "終了コードが 0 ではありません" "警告が表示された"
    assert_file_contains "$MOCK_CALL_LOG" "code ." "VS Code の起動まで、続行された"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb" "$mh"
}

test_launcher_called
test_sf_cli_warning_only
test_outside_force_dir

print_summary
