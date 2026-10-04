#!/bin/bash
# ==============================================================================
# test_sf-upgrade.sh - sf-upgrade.sh のテスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-upgrade.sh ===${CLR_RST}"

# 正常実行 → npm / sf / git が呼び出される
test_normal_run() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-upgrade.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "正常実行 → 終了コード 0"
    assert_file_contains "$MOCK_CALL_LOG" "npm install" "npm が呼び出された"
    assert_file_contains "$MOCK_CALL_LOG" "sf update" "sf update が呼び出された"
    if [[ "$(uname -s)" != "Linux" ]]; then
        assert_file_contains "$MOCK_CALL_LOG" "git update-git-for-windows" "git update が呼び出された"
    else
        skip "git update が呼び出された（WSL: Windows 専用コマンドのためスキップ）"
    fi
    teardown "$td" "$mb"
}

# npm が存在しない → WARNING で続行、正常終了
test_no_npm() {
    local td mb mh
    setup_std_env td mb mh
    # npm モックを作成しない（PATH に npm が存在しない状態）
    # システムの npm がヒットしないよう PATH をモックビンと基本コマンドのみに制限する
    create_mock_git "$mb"
    create_mock_sf "$mb"
    create_mock_code "$mb"

    local out; out=$(cd "$td" && PATH="$mb:/usr/bin:/bin" bash "$SF_TOOLS_DIR/bin/sf-upgrade.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "npm なし → 正常終了（続行）"
    assert_output_contains "$out" "WARNING" "WARNING ログが出力された"
    teardown "$td" "$mb"
}

# sf が存在しない → WARNING で続行、正常終了
test_no_sf() {
    local td mb mh
    setup_std_env td mb mh
    # sf モックを作成しない（PATH に sf が存在しない状態）
    # システムの sf がヒットしないよう PATH をモックビンと基本コマンドのみに制限する
    create_mock_git "$mb"
    create_mock_npm "$mb"
    create_mock_code "$mb"

    local out; out=$(cd "$td" && PATH="$mb:/usr/bin:/bin" bash "$SF_TOOLS_DIR/bin/sf-upgrade.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "sf なし → 正常終了（続行）"
    assert_output_contains "$out" "WARNING" "WARNING ログが出力された"
    teardown "$td" "$mb"
}

# git update-git-for-windows は npm・sf の後に実行される（順序確認）
test_git_update_is_last() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-upgrade.sh" 2>&1 >/dev/null

    local npm_line sf_line git_line
    npm_line=$(grep -n "npm install" "$MOCK_CALL_LOG" | head -1 | cut -d: -f1)
    sf_line=$(grep -n "sf update" "$MOCK_CALL_LOG" | head -1 | cut -d: -f1)
    git_line=$(grep -n "git update-git-for-windows" "$MOCK_CALL_LOG" | head -1 | cut -d: -f1)

    if [[ "$(uname -s)" == "Linux" ]]; then
        skip "git update は npm・sf の後に実行された（WSL: Windows 専用コマンドのためスキップ）"
    elif [[ -n "$npm_line" && -n "$sf_line" && -n "$git_line" ]] \
        && [[ $npm_line -lt $git_line && $sf_line -lt $git_line ]]; then
        pass "git update は npm・sf の後に実行された"
    else
        fail "git update は npm・sf の後に実行された" "npm:$npm_line sf:$sf_line git:$git_line"
    fi
    teardown "$td" "$mb"
}

# Git Bash（$OSTYPE が msys / mingw / cygwin）では、Git のアップデートが実行される
# （$OSTYPE は bash が起動時に設定するため、環境変数では差し替えられない。bash -c の中で設定して、スクリプトを読み込む）
test_git_update_on_gitbash() {
    local td mb mh t
    for t in msys cygwin; do
        setup_std_env td mb mh
        create_all_mocks "$mb"
        (cd "$td" && PATH="$mb:$PATH" bash -c "OSTYPE=${t}; source '$SF_TOOLS_DIR/bin/sf-upgrade.sh'") > /dev/null 2>&1
        assert_file_contains "$MOCK_CALL_LOG" "git update-git-for-windows" "OSTYPE=${t}（Git Bash）でも、Git のアップデートが実行される"
        teardown "$td" "$mb"
    done
}

# sf が npm 版（npm ls -g @salesforce/cli が成功）→ npm で更新し、sf update は使わない
test_npm_sf_updated_by_npm() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    (cd "$td" && PATH="$mb:$PATH" MOCK_NPM_LS_EXIT=0 bash "$SF_TOOLS_DIR/bin/sf-upgrade.sh") > /dev/null 2>&1
    assert_file_contains     "$MOCK_CALL_LOG" "npm install -g @salesforce/cli@latest" "npm 版 → npm install -g @salesforce/cli@latest で更新する"
    assert_file_not_contains "$MOCK_CALL_LOG" "sf update" "npm 版 → sf update は使わない"
    teardown "$td" "$mb"
}

# sf が npm 版ではない（公式インストーラー・pkg など）→ sf update で更新する
test_non_npm_sf_updated_by_sf_update() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    (cd "$td" && PATH="$mb:$PATH" MOCK_NPM_LS_EXIT=1 bash "$SF_TOOLS_DIR/bin/sf-upgrade.sh") > /dev/null 2>&1
    assert_file_contains     "$MOCK_CALL_LOG" "sf update" "npm 版ではない → sf update で更新する"
    assert_file_not_contains "$MOCK_CALL_LOG" "npm install -g @salesforce/cli" "npm 版ではない → npm で sf を更新しない"
    teardown "$td" "$mb"
}

test_normal_run
test_no_npm
test_no_sf
test_git_update_is_last
test_git_update_on_gitbash
test_npm_sf_updated_by_npm
test_non_npm_sf_updated_by_sf_update

print_summary
