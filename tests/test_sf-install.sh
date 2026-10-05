#!/bin/bash
# ==============================================================================
# test_sf-install.sh - sf-install.sh のテスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-install.sh ===${CLR_RST}"

# 正常実行 → git pull、マージドライバー登録、npm install が行われる
test_normal_run() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    local out; out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-install.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "正常実行 → 終了コード 0"
    assert_file_contains "$MOCK_CALL_LOG" "git -C" "sf-tools の git pull が呼び出された"
    teardown "$td" "$mb" "$mh"
}

# スタンプファイルが新しい（24h以内）→ sf-upgrade.sh がバックグラウンド起動されない
test_upgrade_skipped_within_24h() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    # 1時間前のタイムスタンプでスタンプファイルを作成
    touch -t "$(date -d '1 hour ago' +'%Y%m%d%H%M' 2>/dev/null || date -v -1H +'%Y%m%d%H%M' 2>/dev/null || date +'%Y%m%d%H%M')" "$mh/.sf-tools-last-update" 2>/dev/null \
        || touch "$mh/.sf-tools-last-update"

    local out; out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-install.sh" 2>&1)

    assert_output_contains "$out" "スキップ" "24h 以内のためスキップメッセージが表示された"
    teardown "$td" "$mb" "$mh"
}

# スタンプファイルなし（初回）→ sf-upgrade.sh がバックグラウンド起動される
test_upgrade_triggered_on_first_run() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    # スタンプファイルなし（初回実行を再現）
    rm -f "$mh/.sf-tools-last-update"

    cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-install.sh" 2>&1 >/dev/null
    sleep 1  # バックグラウンド起動を少し待つ

    assert_file_exists "$mh/.sf-tools-last-update" "スタンプファイルが作成された"
    teardown "$td" "$mb" "$mh"
}

# package.json が存在しない → npm install がスキップされる
test_npm_install_skipped_no_package_json() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    rm -f "$mh/.sf-tools-last-update"  # アップグレードも動かすが npm install のみ確認

    local out; out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-install.sh" 2>&1)

    assert_output_contains "$out" "package.json が見つかりません" "package.json なし → npm install スキップメッセージ"
    teardown "$td" "$mb" "$mh"
}

# force-* 以外で実行 → エラー
test_outside_force_dir() {
    local rd mb mh
    rd=$(setup_regular_dir); mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"; mh=$(setup_mock_home)
    create_all_mocks "$mb"

    local out; out=$(cd "$rd" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-install.sh" 2>&1)
    local ec=$?

    assert_exit_fail $ec "force-* 外 → エラー終了"
    teardown "$rd" "$mb" "$mh"
}

# SF_INIT_RUNNING=1 の場合 → git pull をスキップ
test_skip_pull_when_sf_init_running() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    local out; out=$(cd "$td" && SF_INIT_RUNNING=1 HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-install.sh" 2>&1)

    assert_output_contains "$out" "git pull をスキップ" "SF_INIT_RUNNING=1 → git pull スキップメッセージが表示された"

    grep "git -C" "$MOCK_CALL_LOG" 2>/dev/null | grep -q "pull" \
        && fail "SF_INIT_RUNNING=1 → git pull が呼び出されていない" \
        || pass "SF_INIT_RUNNING=1 → git pull が呼び出されていない"

    teardown "$td" "$mb" "$mh"
}

# sf-hook.sh が呼び出され pre-push フックが生成される
test_hook_installed() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-install.sh" 2>&1 >/dev/null

    assert_file_exists "$td/.git/hooks/pre-push" "sf-hook.sh が呼び出され pre-push フックが生成された"
    teardown "$td" "$mb" "$mh"
}

# branch_name.txt とリリースディレクトリが作成される
test_release_dir_created() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    export MOCK_GIT_BRANCH="feature/test"

    cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-install.sh" 2>&1 >/dev/null

    assert_file_exists "$td/sf-tools/release/branch_name.txt" "branch_name.txt が作成された"
    assert_dir_exists "$td/sf-tools/release/feature/test" "リリースディレクトリが作成された"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb" "$mh"
}

# main ブランチでは release ディレクトリを作成しない
test_release_dir_skipped_on_main() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    export MOCK_GIT_BRANCH="main"

    cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-install.sh" 2>&1 >/dev/null

    assert_dir_exists     "$td/sf-tools/release"           "sf-tools/release/ ベースディレクトリが作成された"
    assert_file_exists    "$td/sf-tools/release/.gitkeep" ".gitkeep が作成された"
    assert_dir_not_exists "$td/sf-tools/release/main"     "main の release サブディレクトリが作成されない"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb" "$mh"
}

# sf-upgrade.sh が呼び出された（初回実行時）
test_upgrade_called_on_first_run() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    rm -f "$mh/.sf-tools-last-update"

    cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-install.sh" 2>&1 >/dev/null
    sleep 2

    grep -q "sf update" "$MOCK_CALL_LOG" \
        && pass "sf-upgrade.sh が呼び出された" \
        || fail "sf-upgrade.sh が呼び出された"
    teardown "$td" "$mb" "$mh"
}

# sf-upgrade.sh が呼び出されない（24h以内）
test_upgrade_not_called_within_24h() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    touch -t "$(date -d '1 hour ago' +'%Y%m%d%H%M' 2>/dev/null || date -v -1H +'%Y%m%d%H%M' 2>/dev/null || date +'%Y%m%d%H%M')" "$mh/.sf-tools-last-update" 2>/dev/null \
        || touch "$mh/.sf-tools-last-update"

    cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-install.sh" 2>&1 >/dev/null
    sleep 1

    grep -q "sf update" "$MOCK_CALL_LOG" \
        && fail "sf-upgrade.sh が呼び出されていない（24h以内）" \
        || pass "sf-upgrade.sh が呼び出されていない（24h以内）"
    teardown "$td" "$mb" "$mh"
}

# deploy-target.txt と remove-target.txt が作成される
test_deploy_remove_target_created() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    export MOCK_GIT_BRANCH="feature/test"

    cd "$td" && SF_INIT_RUNNING=1 HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-install.sh" 2>&1 >/dev/null

    assert_file_exists "$td/sf-tools/release/feature/test/deploy-target.txt" "deploy-target.txt が作成された"
    assert_file_exists "$td/sf-tools/release/feature/test/remove-target.txt" "remove-target.txt が作成された"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb" "$mh"
}

# .gitmessage が作成され git config に設定される
test_gitmessage_created() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    cd "$td" && SF_INIT_RUNNING=1 HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-install.sh" 2>&1 >/dev/null

    assert_file_exists "$td/.gitmessage" ".gitmessage が作成された"
    assert_file_contains "$MOCK_CALL_LOG" "config commit.template" "git config commit.template が呼び出された"
    teardown "$td" "$mb" "$mh"
}

# release 初期化に失敗 → WARNING が出力される（SUCCESS にならない）
test_release_dir_init_fail() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    export MOCK_GIT_BRANCH="feature/test"
    rm -f "$mh/sf-tools/templates/sf-tools/release/__BRANCH__/deploy-target.txt"

    local out; out=$(cd "$td" && SF_INIT_RUNNING=1 HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-install.sh" 2>&1)

    assert_output_contains "$out" "リリース管理ディレクトリの準備に失敗" "release 初期化失敗 → WARNING が出力された"
    assert_output_not_contains "$out" "リリース管理ディレクトリの準備が完了" "release 初期化失敗 → SUCCESS ログが出ていない"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb" "$mh"
}

# sf の終了コードが 0 以外（インストーラー版の不具合）→ 警告を表示するが、中断せず、sf-tools の最新化は続行する
test_sf_cli_warning_only() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    local out; out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" MOCK_SF_VERSION_EXIT=1 bash "$SF_TOOLS_DIR/bin/sf-install.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "sf の終了コード 1 → 警告のみで、終了コード 0（中断しない）"
    assert_output_contains "$out" "終了コードが 0 ではありません" "sf の終了コード 1 → 警告が表示された"
    assert_output_contains "$out" "npm install -g @salesforce/cli" "sf の終了コード 1 → npm 版の案内が表示された"
    assert_file_contains "$MOCK_CALL_LOG" "git -C" "sf の終了コード 1 → sf-tools の git pull は、続行される"
    teardown "$td" "$mb" "$mh"
}


# sf-init.sh から呼ばれた場合（SF_INIT_RUNNING=1）は、package.json があっても npm install をスキップする
#   （init フォルダは、設定とプッシュだけに使い、最後に削除する一時フォルダのため。約 90 秒の短縮）
test_npm_install_skipped_when_sf_init_running() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    echo '{"name":"x","version":"1.0.0"}' > "$td/package.json"

    local out; out=$(cd "$td" && SF_INIT_RUNNING=1 HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-install.sh" 2>&1)

    assert_output_contains "$out" "npm install をスキップします（初期セットアップ用の一時フォルダのため）" "sf-init 中 → npm install のスキップメッセージが表示された"
    # 背景で動く sf-upgrade.sh の npm install -g（別のコマンド）と区別するため、引数なしの行だけを見る
    if grep -qx "npm install" "$MOCK_CALL_LOG"; then fail "sf-init 中 → npm install が呼び出されていない" "引数なしの npm install が呼ばれた"; else pass "sf-init 中 → npm install が呼び出されていない"; fi
    teardown "$td" "$mb" "$mh"
}

# 通常の起動（sf-start.sh からなど）では、package.json があれば npm install する
test_npm_install_runs_normally() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    echo '{"name":"x","version":"1.0.0"}' > "$td/package.json"
    rm -f "$td/node_modules/.package-lock.json"

    local out; out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-install.sh" 2>&1)

    assert_file_contains "$MOCK_CALL_LOG" "npm install" "通常起動 → npm install が呼び出される"
    teardown "$td" "$mb" "$mh"
}
test_normal_run
test_npm_install_skipped_when_sf_init_running
test_npm_install_runs_normally
test_sf_cli_warning_only
test_gitmessage_created
test_upgrade_skipped_within_24h
test_upgrade_triggered_on_first_run
test_upgrade_called_on_first_run
test_upgrade_not_called_within_24h
test_npm_install_skipped_no_package_json
test_outside_force_dir
test_skip_pull_when_sf_init_running
test_hook_installed
test_release_dir_created
test_deploy_remove_target_created
test_release_dir_init_fail

print_summary
