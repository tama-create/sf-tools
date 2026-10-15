#!/bin/bash
# ==============================================================================
# test_sf-check.sh - sf-check.sh のテスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-check.sh ===${CLR_RST}"

# ------------------------------------------------------------------------------
# [files] セクション: 存在するパスのみ → 正常終了
# ------------------------------------------------------------------------------
test_files_valid_path() {
    local td
    td=$(setup_force_dir)
    mkdir -p "$td/force-app/main/default/classes"
    touch "$td/force-app/main/default/classes/MyClass.cls"

    local deploy="$td/deploy.txt"
    printf '[files]\nforce-app/main/default/classes/MyClass.cls\n' > "$deploy"
    local remove="$td/remove.txt"
    printf '[files]\n' > "$remove"

    local out; out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$deploy" "$remove" 2>&1)
    local ret=$?

    assert_exit_ok "$ret" "[files] 存在するパス → 正常終了"
    teardown "$td"
}

# ------------------------------------------------------------------------------
# [files] セクション: 存在しないパス → エラー終了・行番号付きメッセージ
# ------------------------------------------------------------------------------
test_files_missing_path() {
    local td
    td=$(setup_force_dir)

    local deploy="$td/deploy.txt"
    printf '[files]\nforce-app/main/default/classes/Missing.cls\n' > "$deploy"
    local remove="$td/remove.txt"
    printf '[files]\n' > "$remove"

    local out; out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$deploy" "$remove" 2>&1)
    local ret=$?

    assert_exit_fail "$ret" "[files] 存在しないパス → エラー終了"
    assert_output_contains "$out" ":2" "[files] 存在しないパス → 行番号が表示された"
    assert_output_contains "$out" "Missing.cls" "[files] 存在しないパス → ファイル名が表示された"
    teardown "$td"
}

# ------------------------------------------------------------------------------
# [members] セクション: 正しい書式（種別:名前） → 正常終了
# ------------------------------------------------------------------------------
test_members_valid_format() {
    local td
    td=$(setup_force_dir)

    local deploy="$td/deploy.txt"
    printf '[members]\nCustomLabel:MyLabel\nProfile:Admin\n' > "$deploy"
    local remove="$td/remove.txt"
    printf '[files]\n' > "$remove"

    local out; out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$deploy" "$remove" 2>&1)
    local ret=$?

    assert_exit_ok "$ret" "[members] 正しい書式 → 正常終了"
    teardown "$td"
}

# ------------------------------------------------------------------------------
# [members] セクション: コロンなし → エラー終了・行番号付きメッセージ
# ------------------------------------------------------------------------------
test_members_invalid_format() {
    local td
    td=$(setup_force_dir)

    local deploy="$td/deploy.txt"
    printf '[members]\nCustomLabelMyLabel\n' > "$deploy"
    local remove="$td/remove.txt"
    printf '[files]\n' > "$remove"

    local out; out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$deploy" "$remove" 2>&1)
    local ret=$?

    assert_exit_fail "$ret" "[members] コロンなし → エラー終了"
    assert_output_contains "$out" ":2" "[members] コロンなし → 行番号が表示された"
    assert_output_contains "$out" "書式エラー（種別名:メンバー名）" "[members] コロンなし → 書式エラーメッセージが表示された"
    teardown "$td"
}

# ------------------------------------------------------------------------------
# [files]/[members] マーカーのみ・コメントのみ → 正常終了（エラーなし）
# ------------------------------------------------------------------------------
test_markers_only_no_error() {
    local td
    td=$(setup_force_dir)

    local deploy="$td/deploy.txt"
    printf '[files]\n# コメント\n\n[members]\n# コメント\n' > "$deploy"
    local remove="$td/remove.txt"
    printf '[files]\n' > "$remove"

    local out; out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$deploy" "$remove" 2>&1)
    local ret=$?

    assert_exit_ok "$ret" "[files]/[members] マーカーのみ → エラーなし"
    teardown "$td"
}

# ------------------------------------------------------------------------------
# ファイルが存在しない → スキップして正常終了
# ------------------------------------------------------------------------------
test_file_not_exists() {
    local td
    td=$(setup_force_dir)

    local out; out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$td/no-deploy.txt" "$td/no-remove.txt" 2>&1)
    local ret=$?

    assert_exit_ok "$ret" "ファイルが存在しない → スキップして正常終了"
    teardown "$td"
}

# ------------------------------------------------------------------------------
# 引数省略: branch_name.txt から自動解決 → 正常終了
# ------------------------------------------------------------------------------
test_auto_resolve_branch() {
    local td
    td=$(setup_force_dir)
    setup_release_dir "$td"
    # setup_release_dir が作る deploy-target.txt は存在しないパスを参照するため
    # 空ファイルに差し替え
    printf '[files]\n' > "$td/sf-tools/release/feature/test/deploy-target.txt"

    local out; out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" 2>&1)
    local ret=$?

    assert_exit_ok "$ret" "引数省略 → branch_name.txt から自動解決して正常終了"
    teardown "$td"
}

# ------------------------------------------------------------------------------
# テストクラス不足: 通常 Apex のみで対応テストクラスがローカルに存在する → WARNING
# ------------------------------------------------------------------------------
test_missing_test_class_warning() {
    local td
    td=$(setup_force_dir)
    mkdir -p "$td/force-app/main/default/classes"
    printf 'public class MyClass {}\n' \
        > "$td/force-app/main/default/classes/MyClass.cls"
    printf '@isTest\npublic class MyClassTest {}\n' \
        > "$td/force-app/main/default/classes/MyClassTest.cls"

    local deploy="$td/deploy.txt"
    printf '[files]\nforce-app/main/default/classes/MyClass.cls\n' > "$deploy"
    local remove="$td/remove.txt"
    printf '[files]\n' > "$remove"

    local out; out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$deploy" "$remove" 2>&1)
    local ret=$?

    assert_exit_ok  "$ret" "テストクラス不足 → exit 0（warning のみ）"
    echo "$out" | grep -qi "warning" \
        && pass "テストクラス不足 → warning が表示された" \
        || fail "テストクラス不足 → warning が表示された"
    assert_output_contains "$out" "MyClassTest" "テストクラス不足 → テストクラス名が表示された"
    teardown "$td"
}

# ------------------------------------------------------------------------------
# テストクラス不足: テストクラスが deploy-target.txt に含まれている → WARNING なし
# ------------------------------------------------------------------------------
test_no_warning_when_test_included() {
    local td
    td=$(setup_force_dir)
    mkdir -p "$td/force-app/main/default/classes"
    printf 'public class MyClass {}\n' \
        > "$td/force-app/main/default/classes/MyClass.cls"
    printf '@isTest\npublic class MyClassTest {}\n' \
        > "$td/force-app/main/default/classes/MyClassTest.cls"

    local deploy="$td/deploy.txt"
    printf '[files]\nforce-app/main/default/classes/MyClass.cls\nforce-app/main/default/classes/MyClassTest.cls\n' > "$deploy"
    local remove="$td/remove.txt"
    printf '[files]\n' > "$remove"

    local out; out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$deploy" "$remove" 2>&1)
    local ret=$?

    assert_exit_ok "$ret" "テストクラス含まれている → exit 0"
    echo "$out" | grep -qi "テストクラス不足の可能性" \
        && fail "テストクラス含まれている → warning なし" \
        || pass "テストクラス含まれている → warning なし"
    teardown "$td"
}

# ------------------------------------------------------------------------------
# テストクラス不足: @isTest クラス自身のみ → WARNING なし
# ------------------------------------------------------------------------------
test_no_warning_for_test_class_itself() {
    local td
    td=$(setup_force_dir)
    mkdir -p "$td/force-app/main/default/classes"
    printf '@isTest\npublic class MyClassTest {}\n' \
        > "$td/force-app/main/default/classes/MyClassTest.cls"

    local deploy="$td/deploy.txt"
    printf '[files]\nforce-app/main/default/classes/MyClassTest.cls\n' > "$deploy"
    local remove="$td/remove.txt"
    printf '[files]\n' > "$remove"

    local out; out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$deploy" "$remove" 2>&1)
    local ret=$?

    assert_exit_ok "$ret" "@isTest クラス自身 → exit 0"
    echo "$out" | grep -qi "テストクラス不足の可能性" \
        && fail "@isTest クラス自身 → warning なし" \
        || pass "@isTest クラス自身 → warning なし"
    teardown "$td"
}

# ------------------------------------------------------------------------------
# 種類の可否（config/metadata-capability.txt）: ng はエラー・limited は警告・ok / unknown / 表にない種類は何もしない
#   SF_CHECK_CAPABILITY_FILE で、テスト用の表に差し替える
# ------------------------------------------------------------------------------
_cap_table() {
    printf '# コメント\nFooNg\tng\tng\t使えない理由\nFooDelNg\tok\tng\t\nFooLimited\tlimited\tlimited\t条件つき\nFooUnknown\tunknown\tunknown\t\nFooOk\tok\tok\t\nFlow\tok\tlimited\t権限\n' > "$1"
}

test_capability_ng_release_error() {
    local td; td=$(setup_force_dir)
    _cap_table "$td/cap.txt"
    printf '[members]\nFooNg:A\n' > "$td/deploy.txt"; printf '[files]\n' > "$td/remove.txt"
    local out; out=$(cd "$td" && SF_CHECK_CAPABILITY_FILE="$td/cap.txt" bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$td/deploy.txt" "$td/remove.txt" 2>&1)
    local ret=$?
    assert_exit_fail "$ret" "可否 ng（release）→ エラー終了"
    assert_output_contains "$out" "FooNg" "可否 ng → 種類名が表示された"
    assert_output_contains "$out" "リリースできない" "可否 ng（deploy-target.txt）→ リリースできないと表示された"
    assert_output_contains "$out" "使えない理由" "可否 ng → 備考が表示された"
    teardown "$td"
}

test_capability_ng_delete_only_in_remove() {
    local td; td=$(setup_force_dir)
    _cap_table "$td/cap.txt"
    # delete だけ ng の種類: deploy-target.txt に書いても、止めない
    printf '[members]\nFooDelNg:A\n' > "$td/deploy.txt"; printf '[files]\n' > "$td/remove.txt"
    local out; out=$(cd "$td" && SF_CHECK_CAPABILITY_FILE="$td/cap.txt" bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$td/deploy.txt" "$td/remove.txt" 2>&1)
    assert_exit_ok "$?" "delete だけ ng の種類を deploy-target.txt に書く → 正常終了"
    # remove-target.txt に書くと、エラー
    printf '[files]\n' > "$td/deploy.txt"; printf '[members]\nFooDelNg:A\n' > "$td/remove.txt"
    out=$(cd "$td" && SF_CHECK_CAPABILITY_FILE="$td/cap.txt" bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$td/deploy.txt" "$td/remove.txt" 2>&1)
    assert_exit_fail "$?" "delete が ng の種類を remove-target.txt に書く → エラー終了"
    assert_output_contains "$out" "削除できない" "可否 ng（remove-target.txt）→ 削除できないと表示された"
    teardown "$td"
}

test_capability_limited_warning_only() {
    local td; td=$(setup_force_dir)
    _cap_table "$td/cap.txt"
    printf '[members]\nFooLimited:A\n' > "$td/deploy.txt"; printf '[files]\n' > "$td/remove.txt"
    local out; out=$(cd "$td" && SF_CHECK_CAPABILITY_FILE="$td/cap.txt" bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$td/deploy.txt" "$td/remove.txt" 2>&1)
    assert_exit_ok "$?" "可否 limited → 警告のみ（正常終了）"
    assert_output_contains "$out" "条件によって" "可否 limited → 警告が表示された"
    teardown "$td"
}

test_capability_unknown_and_unlisted_pass() {
    local td; td=$(setup_force_dir)
    _cap_table "$td/cap.txt"
    printf '[members]\nFooUnknown:A\nFooOk:B\nNotInTable:C\n' > "$td/deploy.txt"; printf '[members]\nFooUnknown:A\nNotInTable:C\n' > "$td/remove.txt"
    local out; out=$(cd "$td" && SF_CHECK_CAPABILITY_FILE="$td/cap.txt" bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$td/deploy.txt" "$td/remove.txt" 2>&1)
    assert_exit_ok "$?" "可否 unknown・ok・表にない種類 → 何も言わない（正常終了）"
    teardown "$td"
}

test_capability_override_env() {
    local td; td=$(setup_force_dir)
    _cap_table "$td/cap.txt"
    printf '[members]\nFooNg:A\n' > "$td/deploy.txt"; printf '[files]\n' > "$td/remove.txt"
    local out; out=$(cd "$td" && SF_CHECK_IGNORE_CAPABILITY=1 SF_CHECK_CAPABILITY_FILE="$td/cap.txt" bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$td/deploy.txt" "$td/remove.txt" 2>&1)
    assert_exit_ok "$?" "SF_CHECK_IGNORE_CAPABILITY=1 → ng でも、確認を省略して正常終了"
    teardown "$td"
}

test_capability_files_path_maps_to_type() {
    local td; td=$(setup_force_dir)
    _cap_table "$td/cap.txt"
    # Flow は、表では delete が limited → [files] のパスから Flow と分かり、remove-target.txt では警告になる
    mkdir -p "$td/force-app/main/default/flows"
    touch "$td/force-app/main/default/flows/MyFlow.flow-meta.xml"
    printf '[files]\n' > "$td/deploy.txt"; printf '[files]\nforce-app/main/default/flows/MyFlow.flow-meta.xml\n' > "$td/remove.txt"
    local out; out=$(cd "$td" && SF_CHECK_CAPABILITY_FILE="$td/cap.txt" bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$td/deploy.txt" "$td/remove.txt" 2>&1)
    assert_exit_ok "$?" "[files] の Flow（delete が limited）→ 正常終了"
    assert_output_contains "$out" "条件によって" "[files] のパスから種類を推定して、警告が表示された"
    teardown "$td"
}

test_capability_shipped_table_wellformed() {
    local f="$SF_TOOLS_DIR/config/metadata-capability.txt" bad
    assert_file_exists "$f" "同梱の可否の表がある"
    # 4 列（タブ区切り）・release/delete は ok|ng|limited|unknown のどれか・種類は重複しない
    bad=$(awk -F'\t' '$0 !~ /^#/ && $0 != "" && (NF != 4 || $2 !~ /^(ok|ng|limited|unknown)$/ || $3 !~ /^(ok|ng|limited|unknown)$/)' "$f")
    assert_equals "$bad" "" "同梱の可否の表: 全行が、4 列・正しい値"
    bad=$(awk -F'\t' '$0 !~ /^#/ && $0 != "" { c[$1]++ } END { for (k in c) if (c[k] > 1) print k }' "$f")
    assert_equals "$bad" "" "同梱の可否の表: 種類が重複していない"
    # ng の行には、備考（理由）が、ある
    bad=$(awk -F'\t' '$0 !~ /^#/ && ($2 == "ng" || $3 == "ng") && $4 == ""' "$f")
    assert_equals "$bad" "" "同梱の可否の表: ng の行には、備考がある"
}

test_capability_shipped_table_blocks_standard_value_set_delete() {
    local td; td=$(setup_force_dir)
    printf '[files]\n' > "$td/deploy.txt"; printf '[members]\nStandardValueSet:Industry\n' > "$td/remove.txt"
    local out; out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$td/deploy.txt" "$td/remove.txt" 2>&1)
    assert_exit_fail "$?" "同梱の表: StandardValueSet の削除 → エラー終了"
    teardown "$td"
}

test_files_valid_path
test_files_missing_path
test_members_valid_format
test_members_invalid_format
test_markers_only_no_error
test_file_not_exists
test_auto_resolve_branch
test_missing_test_class_warning
test_no_warning_when_test_included
test_no_warning_for_test_class_itself
test_capability_ng_release_error
test_capability_ng_delete_only_in_remove
test_capability_limited_warning_only
test_capability_unknown_and_unlisted_pass
test_capability_override_env
test_capability_files_path_maps_to_type
test_capability_shipped_table_wellformed
test_capability_shipped_table_blocks_standard_value_set_delete

print_summary
