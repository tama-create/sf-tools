#!/bin/bash
# ==============================================================================
# test_sf-dryrun.sh - sf-dryrun.sh のテスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-dryrun.sh ===${CLR_RST}"

# 機能ブランチ → sf-release.sh が --dry-run で呼び出される
test_feature_branch_dry_run() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td" "feature/dryrun-test"

    export MOCK_GIT_BRANCH="feature/dryrun-test"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-dryrun.sh" --no-open 2>&1)
    local ec=$?

    assert_exit_ok $ec "機能ブランチ → 終了コード 0"
    assert_file_contains "$MOCK_CALL_LOG" "project deploy" "sf-release.sh が呼び出された"
    grep "project deploy" "$MOCK_CALL_LOG" | grep -q "\-\-dry-run" \
        && pass "--dry-run が渡された" || fail "--dry-run が渡された"
    unset MOCK_GIT_BRANCH MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# --release オプション転送 → dry-run なしで実行される
test_release_option_forwarded() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td" "feature/dryrun-test"

    export MOCK_GIT_BRANCH="feature/dryrun-test"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    echo "Y" | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-dryrun.sh" --release --no-open ) 2>&1 >/dev/null

    grep "project deploy" "$MOCK_CALL_LOG" | grep -qv "\-\-dry-run" \
        && pass "--release 転送 → dry-run なし" || fail "--release 転送 → dry-run なし"
    unset MOCK_GIT_BRANCH MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# 保護組織（branches.txt 記載）へのローカル実行 → エラー
test_protected_org_blocked() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    unset GITHUB_ACTIONS

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-dryrun.sh" --target main 2>&1)
    local ec=$?

    assert_exit_fail $ec "保護組織(main) + ローカル → エラー終了"
    assert_output_contains "$out" "共有環境（予約名）のため、ローカルから実行できません" "保護組織(main) + ローカル → 適切なエラーメッセージ"
    teardown "$td" "$mb"
}

# force-* 以外で実行 → エラー
test_outside_force_dir() {
    local rd mb
    rd=$(setup_regular_dir); mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"

    local out; out=$(cd "$rd" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-dryrun.sh" 2>&1)
    local ec=$?

    assert_exit_fail $ec "force-* 外 → エラー終了"
    teardown "$rd" "$mb"
}

test_feature_branch_dry_run
test_release_option_forwarded
test_protected_org_blocked
test_outside_force_dir

print_summary
