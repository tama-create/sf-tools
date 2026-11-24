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
# デバッグログ（sf-log.sh）の状態の 1 行（logs/apex/.status。doc/sf-log-design.md 5.4）
# ------------------------------------------------------------------------------
test_apexlog_status_line() {
    echo ""; echo -e "${CLR_HEAD}[TEST] デバッグログの状態の 1 行${CLR_RST}"
    local td mb out
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"
    out=$(cd "$td" && echo "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    assert_output_not_contains "$out" "デバッグログ" ".status がない → 何も表示しない"
    mkdir -p "$td/logs/apex"
    printf 'STATE=collecting\nORG=dev\nEXPIRES=2026-11-23T06:30:00Z\nEXPIRES_AT=15:30\nCOUNT_TODAY=3\nWARNING=\n' > "$td/logs/apex/.status"
    out=$(cd "$td" && echo "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    [[ "$out" == *"デバッグログ: 取得中（dev・期限 15:30・今日 3 本）"* ]] && pass "取得中 → 組織・期限・今日の本数を表示する" || fail "取得中 → 組織・期限・今日の本数を表示する" "$out"
    [[ "$out" == *$'\033[1m\033[0;32m  デバッグログ: 取得中'* ]] && pass "取得中 → 太字の緑で表示する（目立たせる）" || fail "取得中 → 太字の緑で表示する（目立たせる）" "$out"
    printf 'STATE=skipped\nREASON=このプロジェクトでは、自動で取らない設定のため\n' > "$td/logs/apex/.status"
    out=$(cd "$td" && echo "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    [[ "$out" == *"デバッグログ: 取っていません（このプロジェクトでは、自動で取らない設定のため）"* ]] && pass "取らない → 理由を表示する" || fail "取らない → 理由を表示する" "$out"
    [[ "$out" == *$'\033[0;33m  デバッグログ: 取っていません'* ]] && pass "取らない → 黄色で表示する" || fail "取らない → 黄色で表示する" "$out"
    printf 'STATE=error\nREASON=接続できないため\n' > "$td/logs/apex/.status"
    out=$(cd "$td" && echo "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    [[ "$out" == *$'\033[1m\033[0;31m  デバッグログ: 取れていません（接続できないため）'* ]] && pass "取れていません → 太字の赤で表示する" || fail "取れていません → 太字の赤で表示する" "$out"
    printf 'STATE=collecting\nORG=dev\nWARNING=取得に失敗しました（120 秒後にやり直します）\n' > "$td/logs/apex/.status"
    out=$(cd "$td" && echo "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    [[ "$out" == *"⚠ デバッグログ: 取得に失敗しました"* ]] && pass "WARNING → もう 1 行表示する" || fail "WARNING → もう 1 行表示する" "$out"
    printf 'STATE=$(touch injected)\n' > "$td/logs/apex/.status"
    out=$(cd "$td" && echo "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    assert_file_not_exists "$td/injected" ".status を source しない（中身を実行しない）"
    assert_output_not_contains "$out" "デバッグログ" "知らない STATE → 何も表示しない"
    teardown "$td" "$mb"
}
test_apexlog_status_line

# ------------------------------------------------------------------------------
# 準備中（starting）のあいだは、状態が変わったら、メニューを描き直す（コマンドは動かさない。read -t 5 秒ずつ）
# ------------------------------------------------------------------------------
test_apexlog_status_refresh() {
    echo ""; echo -e "${CLR_HEAD}[TEST] デバッグログ: 準備中のあいだの描き直し${CLR_RST}"
    local td mb out t0 n
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"
    mkdir -p "$td/logs/apex"
    printf 'STATE=starting\nORG=dev\n' > "$td/logs/apex/.status"
    # 2 秒後に取得中へ変わる。入力の q は 8 秒後（その間に、5 秒の待ち切れが 1 回ある）
    ( sleep 2; printf 'STATE=collecting\nORG=dev\nEXPIRES_AT=15:30\nCOUNT_TODAY=0\n' > "$td/logs/apex/.status" ) &
    out=$(cd "$td" && { sleep 8; printf 'q'; } | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    wait
    [[ "$out" == *"デバッグログ: 準備中（dev）"* ]] && pass "最初は、準備中を表示する" || fail "最初は、準備中を表示する" "$out"
    [[ "$out" == *"デバッグログ: 取得中（dev・期限 15:30・今日 0 本）"* ]] && pass "取得中に変わったら、メニューを描き直す" || fail "取得中に変わったら、メニューを描き直す" "$out"
    n=$(printf '%s\n' "$out" | grep -c ">> Launcher <<")
    assert_equals "$n" "2" "描き直しは 1 回だけ（取得中になったら、待ち切れで描き直さない）"
    [[ ! -s "$mb/calls.log" ]] && pass "描き直しでは、コマンドを動かさない" || fail "描き直しでは、コマンドを動かさない" "$(cat "$mb/calls.log")"
    # 準備中のままの EOF → すぐ終わる（待ち切れと取り違えない）
    printf 'STATE=starting\nORG=dev\n' > "$td/logs/apex/.status"
    t0=$SECONDS
    out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" < /dev/null 2>&1); local ec=$?
    assert_exit_ok $ec "準備中の EOF → 正常終了"
    (( SECONDS - t0 < 4 )) && pass "準備中の EOF → 待たずに終わる" || fail "準備中の EOF → 待たずに終わる" "$((SECONDS - t0)) 秒"
    teardown "$td" "$mb"
}
test_apexlog_status_refresh

print_summary
