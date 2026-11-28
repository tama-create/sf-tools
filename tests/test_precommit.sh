#!/bin/bash
# ==============================================================================
# test_precommit.sh - phases/hook/precommit.sh のテスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== phases/hook/precommit.sh ===${CLR_RST}"

# ------------------------------------------------------------------------------
# ヘルパー: phases/hook/precommit.sh を force-* ディレクトリで実行
# ------------------------------------------------------------------------------
run_precommit() {
    local td="$1" mb="$2"
    cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/phases/hook/precommit.sh" 2>&1
}

# ------------------------------------------------------------------------------
# sf-check がスキップ（branch_name.txt なし）→ exit 0
# ------------------------------------------------------------------------------
test_check_skip() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"

    local out; out=$(run_precommit "$td" "$mb")
    local ec=$?

    assert_exit_ok $ec "sf-check スキップ（branch_name.txt なし）→ exit 0"
    teardown "$td" "$mb"
}

# ------------------------------------------------------------------------------
# sf-check がエラー（不正なターゲットファイル）→ コミット中止 (exit 1)
# ------------------------------------------------------------------------------
test_check_fail() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"

    # 存在しないパスを記述した deploy-target.txt を作成
    mkdir -p "$td/sf-tools/release/feature/test"
    echo "feature/test" > "$td/sf-tools/release/branch_name.txt"
    printf '[files]\nforce-app/main/default/classes/NotExist.cls\n' \
        > "$td/sf-tools/release/feature/test/deploy-target.txt"
    printf '[files]\n' > "$td/sf-tools/release/feature/test/remove-target.txt"

    local out; out=$(run_precommit "$td" "$mb")
    local ec=$?

    assert_exit_fail $ec "sf-check エラー → コミット中止 (exit 1)"
    assert_output_contains "$out" "中止" "コミット中止メッセージが表示された"
    teardown "$td" "$mb"
}

# ------------------------------------------------------------------------------
# 実行
# ------------------------------------------------------------------------------
test_check_skip
test_check_fail

print_summary
