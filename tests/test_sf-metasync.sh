#!/bin/bash
# ==============================================================================
# test_sf-metasync.sh - sf-metasync.sh のテスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-metasync.sh ===${CLR_RST}"

# 変更あり → commit と push が実行される
test_changes_are_committed() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    # 1回目の diff-index（phase_git_update）: 0 = ローカル変更なし → 通過
    # 2回目の diff-index（phase_git_sync）:   1 = retrieve 後に変更あり → commit
    export MOCK_GIT_BRANCH="main"
    export MOCK_GIT_DIFF_EXIT=0
    export MOCK_GIT_DIFF_EXIT_2ND=1
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$( printf 'Y\nY\n' | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )
    local ec=$?

    assert_file_contains "$MOCK_CALL_LOG" "git commit" "変更あり → commit が実行された"
    assert_file_contains "$MOCK_CALL_LOG" "git push" "変更あり → push が実行された"
    unset MOCK_GIT_BRANCH MOCK_GIT_DIFF_EXIT MOCK_GIT_DIFF_EXIT_2ND MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# 変更なし → commit されずに正常終了
test_no_changes() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    export MOCK_GIT_BRANCH="main"
    export MOCK_GIT_DIFF_EXIT=0
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$( echo "Y" | ( cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )
    local ec=$?

    assert_exit_ok $ec "変更なし → 正常終了"
    ! grep -q "git commit" "$MOCK_CALL_LOG" 2>/dev/null \
        && pass "変更なし → commit は実行されない" \
        || fail "変更なし → commit は実行されない"
    unset MOCK_GIT_BRANCH MOCK_GIT_DIFF_EXIT MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# main 以外のブランチ → main へ自動切替して正常終了
test_non_main_branch_switches() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    export MOCK_GIT_BRANCH="feature/test"
    export MOCK_GIT_DIFF_EXIT=0
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$( echo "Y" | ( cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )
    local ec=$?

    assert_exit_ok $ec "main 以外のブランチ → 正常終了（main へ自動切替）"
    assert_file_contains "$MOCK_CALL_LOG" "git checkout main" "main 以外 → main へ checkout した"
    ! grep -q "git-merge-arg:" "$MOCK_CALL_LOG" 2>/dev/null \
        && pass "変更なし → merge が実行されない" \
        || fail "変更なし → merge が実行されない"
    unset MOCK_GIT_BRANCH MOCK_GIT_DIFF_EXIT MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# staging チェックアウト失敗 → develop は main からマージする（prev_branch バグ修正確認）
test_staging_fail_dev_merges_main() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    export MOCK_GIT_BRANCH="main"
    export MOCK_GIT_CHECKOUT_FAIL_BRANCH="staging"  # staging チェックアウトのみ失敗させる
    export MOCK_GIT_DIFF_EXIT=0
    export MOCK_GIT_DIFF_EXIT_2ND=1  # phase_git_sync で変更あり → commit → propagate 実行
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    printf 'Y\nY\n' | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 >/dev/null

    # develop のマージ元が "main" であることを確認（staging ではない）
    assert_file_contains "$MOCK_CALL_LOG" "git-merge-arg: main" "staging 失敗後、develop は main からマージした"
    ! grep -q "git-merge-arg: staging" "$MOCK_CALL_LOG" 2>/dev/null \
        && pass "staging からのマージは実行されない" \
        || fail "staging からのマージは実行されない"
    unset MOCK_GIT_BRANCH MOCK_GIT_CHECKOUT_FAIL_BRANCH MOCK_GIT_DIFF_EXIT MOCK_GIT_DIFF_EXIT_2ND MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# force-* 以外で実行 → エラー
test_outside_force_dir() {
    local rd mb
    rd=$(setup_regular_dir); mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"

    local out; out=$(cd "$rd" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" 2>&1)
    local ec=$?

    assert_exit_fail $ec "force-* 外 → エラー終了"
    teardown "$rd" "$mb"
}

# feature ブランチ + ローカル変更あり → stash して処理し、終了後に stash pop
test_stash_pop_on_exit() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    export MOCK_GIT_BRANCH="feature/test"
    # 1回目の diff-index (phase_switch_to_main): 1 = 変更あり → stash
    # 2回目以降の diff-index (phase_git_update): 0 = main に変更なし
    export MOCK_GIT_DIFF_EXIT=1
    export MOCK_GIT_DIFF_EXIT_2ND=0
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    echo "Y" | ( cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 >/dev/null

    assert_file_contains "$MOCK_CALL_LOG" "git stash" "ローカル変更あり → stash が実行された"
    assert_file_contains "$MOCK_CALL_LOG" "git stash pop" "終了時に stash pop が実行された"
    unset MOCK_GIT_BRANCH MOCK_GIT_DIFF_EXIT MOCK_GIT_DIFF_EXIT_2ND MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

test_changes_are_committed
test_no_changes
test_non_main_branch_switches
test_staging_fail_dev_merges_main
# sf の終了コードが 0 以外（インストーラー版の不具合）→ 案内を表示して中断する
test_sf_cli_abort() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    export MOCK_GIT_BRANCH="main"
    export MOCK_GIT_DIFF_EXIT=0
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$( echo "Y" | ( cd "$td" && PATH="$mb:$PATH" MOCK_SF_VERSION_EXIT=1 bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )

    assert_output_contains "$out" "終了コードが 0 ではありません" "sf の終了コード 1 → 案内が表示された"
    assert_file_not_contains "$MOCK_CALL_LOG" "sf org display" "sf の終了コード 1 → 組織の確認まで、進まない"
    unset MOCK_GIT_BRANCH MOCK_GIT_DIFF_EXIT MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# コミット&プッシュの確認で N → 中断する（commit / push しない）
#   以前は ask_yn の戻り値を見ておらず、N と答えても main に commit / push されていた
test_commit_confirm_no_aborts() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    export MOCK_GIT_BRANCH="main"
    export MOCK_GIT_DIFF_EXIT=0
    export MOCK_GIT_DIFF_EXIT_2ND=1
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$( printf 'Y\nN\n' | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )
    local ec=$?

    assert_exit_fail $ec "コミットの確認で N → 中断（終了コード 0 以外）"
    assert_output_contains "$out" "中断しました" "コミットの確認で N → 中断の旨が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "git commit" "コミットの確認で N → commit しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git push" "コミットの確認で N → push しない"
    unset MOCK_GIT_BRANCH MOCK_GIT_DIFF_EXIT MOCK_GIT_DIFF_EXIT_2ND MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

test_outside_force_dir
test_stash_pop_on_exit
test_sf_cli_abort
test_commit_confirm_no_aborts

print_summary
