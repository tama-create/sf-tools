#!/bin/bash
# ==============================================================================
# test_sf-launcher.sh - sf-launcher.sh のテスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-launcher.sh ===${CLR_RST}"

# ------------------------------------------------------------------------------
# force-* 以外のディレクトリ → exit 1
# ------------------------------------------------------------------------------
test_not_in_force_dir() {
    local td mb
    td=$(setup_regular_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    local ec=$?

    assert_exit_fail $ec "force-* 以外のディレクトリ → exit 1"
    assert_output_contains "$out" "force-" "force-* メッセージが表示された"
    teardown "$td" "$mb"
}

# ------------------------------------------------------------------------------
# 有効な番号を引数で直接指定 → sf-check.sh が呼ばれる
# （branch_name.txt なし → チェックスキップ → exit 0）
# ------------------------------------------------------------------------------
test_direct_number_arg() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"

    # 番号 1 = sf-check（branch_name.txt なし → スキップして exit 0）
    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 1 2>&1)
    local ec=$?

    assert_exit_ok $ec "有効な番号引数 (1) → exit 0"
    teardown "$td" "$mb"
}

# ------------------------------------------------------------------------------
# 範囲外の番号 → exit 1
# ------------------------------------------------------------------------------
test_out_of_range_number() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 99 2>&1)
    local ec=$?

    assert_exit_fail $ec "範囲外の番号 (99) → exit 1"
    assert_output_contains "$out" "範囲外" "範囲外メッセージが表示された"
    teardown "$td" "$mb"
}

# ------------------------------------------------------------------------------
# 回帰: 先頭が 0 の番号は 10 進数として扱う（以前は 08・09 が 8 進数として扱われ、[[ -eq ]] がエラーになった）
# ------------------------------------------------------------------------------
test_leading_zero_number() {
    local td mb out ec a
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"

    out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 01 2>&1); ec=$?
    assert_exit_ok $ec "01 → 1 として実行する（exit 0）"
    for a in 08 09 0000000099999999999; do
        out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" "$a" 2>&1); ec=$?
        assert_exit_fail $ec "${a} → 範囲外で exit 1"
        assert_output_contains "$out" "範囲外" "${a} → 範囲外メッセージが表示された"
        printf '%s\n' "$out" | grep -qiE "value too great|syntax error|invalid" \
            && fail "${a} → 算術のエラーが出ない" "$(printf '%s' "$out" | head -3)" \
            || pass "${a} → 算術のエラーが出ない"
    done
    teardown "$td" "$mb"
}

# ------------------------------------------------------------------------------
# 数字以外の引数 → exit 1
# ------------------------------------------------------------------------------
test_nonnumber_arg() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" abc 2>&1)
    local ec=$?

    assert_exit_fail $ec "数字以外の引数 (abc) → exit 1"
    teardown "$td" "$mb"
}

# ------------------------------------------------------------------------------
# インタラクティブモードで q → exit 0
# ------------------------------------------------------------------------------
test_quit_interactive() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"

    # printf "q" で stdin に 1 文字送る → read -rsn1 が受け取って exit 0
    local out; out=$(cd "$td" && printf "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "q で終了 → exit 0"
    teardown "$td" "$mb"
}

# ------------------------------------------------------------------------------
# 実行
# ------------------------------------------------------------------------------
test_not_in_force_dir
test_direct_number_arg
test_out_of_range_number
test_leading_zero_number
test_nonnumber_arg
test_quit_interactive

print_summary
