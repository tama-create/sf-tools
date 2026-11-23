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

# ------------------------------------------------------------------------------
# Apex ログ（sf-log.sh）の状態の 1 行（logs/apex/.status。doc/sf-log-design.md 5.4）
# ------------------------------------------------------------------------------
test_apexlog_status_line() {
    echo ""; echo -e "${CLR_HEAD}[TEST] Apex ログの状態の 1 行${CLR_RST}"
    local td mb out
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"
    out=$(cd "$td" && echo "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    assert_output_not_contains "$out" "Apex ログ" ".status がない → 何も表示しない"
    mkdir -p "$td/logs/apex"
    printf 'STATE=collecting\nORG=dev\nEXPIRES=2026-11-23T06:30:00Z\nEXPIRES_AT=15:30\nCOUNT_TODAY=3\nWARNING=\n' > "$td/logs/apex/.status"
    out=$(cd "$td" && echo "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    [[ "$out" == *"Apex ログ: 取得中（dev・期限 15:30・今日 3 本）"* ]] && pass "取得中 → 組織・期限・今日の本数を表示する" || fail "取得中 → 組織・期限・今日の本数を表示する" "$out"
    printf 'STATE=skipped\nREASON=このプロジェクトでは、自動で取らない設定のため\n' > "$td/logs/apex/.status"
    out=$(cd "$td" && echo "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    [[ "$out" == *"Apex ログ: 取っていません（このプロジェクトでは、自動で取らない設定のため）"* ]] && pass "取らない → 理由を表示する" || fail "取らない → 理由を表示する" "$out"
    printf 'STATE=collecting\nORG=dev\nWARNING=取得に失敗しました（120 秒後にやり直します）\n' > "$td/logs/apex/.status"
    out=$(cd "$td" && echo "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    [[ "$out" == *"⚠ Apex ログ: 取得に失敗しました"* ]] && pass "WARNING → もう 1 行表示する" || fail "WARNING → もう 1 行表示する" "$out"
    printf 'STATE=$(touch injected)\n' > "$td/logs/apex/.status"
    out=$(cd "$td" && echo "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    assert_file_not_exists "$td/injected" ".status を source しない（中身を実行しない）"
    assert_output_not_contains "$out" "Apex ログ" "知らない STATE → 何も表示しない"
    teardown "$td" "$mb"
}
test_apexlog_status_line

print_summary
