#!/bin/bash
# ==============================================================================
# test_sf-release.sh - sf-release.sh のテスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-release.sh ===${CLR_RST}"

# デフォルト（dry-run）実行 → sf deploy に --dry-run が渡される
test_dry_run_default() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" 2>&1 >/dev/null

    assert_file_contains "$MOCK_CALL_LOG" "project deploy" "デプロイコマンドが呼び出された"
    grep "project deploy" "$MOCK_CALL_LOG" | grep -q "\-\-dry-run" \
        && pass "--dry-run が渡された" || fail "--dry-run が渡された"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# --release フラグ → --dry-run なしで実行
test_release_mode() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    echo "Y" | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --release --no-open ) 2>&1 >/dev/null

    grep "project deploy" "$MOCK_CALL_LOG" | grep -qv "\-\-dry-run" \
        && pass "--release → --dry-run なし" || fail "--release → --dry-run なし"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# --force フラグ → --ignore-conflicts が渡される
test_force_flag() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --force --no-open 2>&1 >/dev/null

    grep "project deploy" "$MOCK_CALL_LOG" | grep -q "\-\-ignore-conflicts" \
        && pass "--force → --ignore-conflicts が渡された" || fail "--force → --ignore-conflicts が渡された"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# --target オプション → 指定した組織エイリアスが使われる
test_target_option() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"

    cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --target myorg --no-open 2>&1 >/dev/null

    grep "project deploy" "$MOCK_CALL_LOG" | grep -q "myorg" \
        && pass "--target → 指定エイリアスが使われた" || fail "--target → 指定エイリアスが使われた"
    teardown "$td" "$mb"
}

# デプロイ対象が空（コメント行のみ）→ 早期終了
test_empty_deploy_target() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    mkdir -p "$td/sf-tools/release/feature/test"
    echo "feature/test" > "$td/sf-tools/release/branch_name.txt"
    printf '# コメントのみ\n' > "$td/sf-tools/release/feature/test/deploy-target.txt"
    printf '# コメントのみ\n' > "$td/sf-tools/release/feature/test/remove-target.txt"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --no-open 2>&1)

    assert_output_contains "$out" "デプロイ対象がありません" "対象なし → 警告メッセージが表示された"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# 不明なオプション → エラー終了
test_unknown_option() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --unknown-option 2>&1)
    local ec=$?

    assert_exit_fail $ec "不明オプション → エラー終了"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# force-* 以外で実行 → エラー
test_outside_force_dir() {
    local rd mb
    rd=$(setup_regular_dir); mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"

    local out; out=$(cd "$rd" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" 2>&1)
    local ec=$?

    assert_exit_fail $ec "force-* 外 → エラー終了"
    teardown "$rd" "$mb"
}

# 保護組織（main/staging/develop）へのローカル実行 → エラー
test_protected_org_local_blocked() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    unset GITHUB_ACTIONS

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --target main 2>&1)
    local ec=$?

    assert_exit_fail $ec "保護組織(main) + ローカル → エラー終了"
    assert_output_contains "$out" "PR 経由で GitHub Actions" "保護組織(main) + ローカル → 適切なエラーメッセージ"
    teardown "$td" "$mb"
}

# GitHub Actions 上からの保護組織実行 → 通過
test_protected_org_github_actions_allowed() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    export GITHUB_ACTIONS="true"

    cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --target main --no-open 2>&1 >/dev/null
    local ec=$?

    assert_exit_ok $ec "保護組織(main) + GITHUB_ACTIONS=true → 通過"
    unset GITHUB_ACTIONS
    teardown "$td" "$mb"
}

# 保護組織外（個人 Sandbox）へのローカル実行 → 通過
test_unprotected_org_local_allowed() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    unset GITHUB_ACTIONS

    cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --target mysandbox --no-open 2>&1 >/dev/null
    local ec=$?

    assert_exit_ok $ec "個人 Sandbox(mysandbox) + ローカル → 通過"
    teardown "$td" "$mb"
}

# staging もローカル実行禁止
test_protected_org_staging_blocked() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    unset GITHUB_ACTIONS

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --target staging 2>&1)
    local ec=$?

    assert_exit_fail $ec "保護組織(staging) + ローカル → エラー終了"
    teardown "$td" "$mb"
}

test_dry_run_default
test_release_mode
test_force_flag
test_target_option
test_empty_deploy_target
test_unknown_option
test_outside_force_dir
test_protected_org_local_blocked
test_protected_org_github_actions_allowed
# sf の終了コードが 0 以外（インストーラー版の不具合）→ 警告を表示するが、続行する
test_sf_cli_warning_only() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$(cd "$td" && PATH="$mb:$PATH" MOCK_SF_VERSION_EXIT=1 bash "$SF_TOOLS_DIR/bin/sf-release.sh" 2>&1)

    assert_output_contains "$out" "終了コードが 0 ではありません" "sf の終了コード 1 → 警告が表示された"
    assert_file_contains "$MOCK_CALL_LOG" "project deploy" "sf の終了コード 1 → デプロイの処理まで、続行された"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

test_unprotected_org_local_allowed
test_protected_org_staging_blocked
test_sf_cli_warning_only

print_summary
