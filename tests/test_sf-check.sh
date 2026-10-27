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
# ------------------------------------------------------------------------------
# [files] セクション: リポジトリの外を指すパス（絶対パス・.. を含むパス）→ 存在するファイルでも、エラー終了
#   （結合テスト X6-4 で見つかった: 外のファイルを、リリース・削除の対象にできてしまう）
# ------------------------------------------------------------------------------
test_files_outside_repo_path() {
    local td outside
    td=$(setup_force_dir)
    mkdir -p "$td/force-app/main/default/classes"
    outside=$(mktemp "${TMPDIR:-/tmp}/outside-XXXXXX")   # リポジトリの外にある、存在するファイル
    touch "$td/force-app/main/default/classes/Inside.cls"
    printf '[files]\n' > "$td/deploy.txt"

    local name path out ret
    for name in "絶対パス" ".. を含む（先頭）" ".. を含む（途中）"; do
        case "$name" in
            "絶対パス")           path="$outside" ;;
            ".. を含む（先頭）")  path="../$(basename "$outside")" ;;
            *)                    path="force-app/../../$(basename "$outside")" ;;
        esac
        printf '[files]\n%s\n' "$path" > "$td/remove.txt"
        out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$td/deploy.txt" "$td/remove.txt" 2>&1); ret=$?
        assert_exit_fail "$ret" "[files] リポジトリの外（${name}）→ エラー終了"
        assert_output_contains "$out" "リポジトリの外を指すパス" "[files] リポジトリの外（${name}）→ 専用のメッセージ"
    done

    # リポジトリの中の、普通のパスは、これまでどおり通る（名前に .. を含むだけのものも）
    mkdir -p "$td/force-app/main/default/classes/a..b"
    touch "$td/force-app/main/default/classes/a..b/Ok.cls"
    printf '[files]\nforce-app/main/default/classes/Inside.cls\nforce-app/main/default/classes/a..b/Ok.cls\n' > "$td/remove.txt"
    out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$td/deploy.txt" "$td/remove.txt" 2>&1); ret=$?
    assert_exit_ok "$ret" "[files] リポジトリの中のパス（名前に .. を含むだけのものを含む）→ 正常終了"
    rm -f "$outside"
    teardown "$td"
}

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
# 回帰: 命名規則（〜Test / 〜_Test）に合わない名前のテストクラスが deploy-target.txt に含まれている → WARNING なし
#   （以前は、内容検索の結果が ./ で始まり、deploy-target.txt の書き方と一致せず、含まれていても警告していた）
test_no_warning_when_test_included_nonstandard_name() {
    local td
    td=$(setup_force_dir)
    mkdir -p "$td/force-app/main/default/classes"
    printf 'public class MyClass {}
' > "$td/force-app/main/default/classes/MyClass.cls"
    printf '@isTest
public class MyClassSpec { static void t(){ MyClass x; } }
' > "$td/force-app/main/default/classes/MyClassSpec.cls"
    local deploy="$td/deploy.txt" remove="$td/remove.txt"
    printf '[files]
force-app/main/default/classes/MyClass.cls
force-app/main/default/classes/MyClassSpec.cls
' > "$deploy"
    printf '[files]
' > "$remove"

    local out; out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$deploy" "$remove" 2>&1)
    assert_exit_ok "$?" "名前が規則外のテストクラスが含まれている → exit 0"
    echo "$out" | grep -qi "テストクラス不足の可能性"         && fail "名前が規則外のテストクラスが含まれている → warning なし"         || pass "名前が規則外のテストクラスが含まれている → warning なし"

    # 含まれていないときは、警告する（表示するパスに ./ が付かない）
    printf '[files]
force-app/main/default/classes/MyClass.cls
' > "$deploy"
    out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$deploy" "$remove" 2>&1)
    echo "$out" | grep -qi "テストクラス不足の可能性"         && pass "名前が規則外のテストクラスが含まれていない → warning"         || fail "名前が規則外のテストクラスが含まれていない → warning"
    assert_output_contains "$out" "→ force-app/main/default/classes/MyClassSpec.cls" "警告に出るテストクラスのパスに ./ が付かない"
    teardown "$td"
}

# 回帰: Step B（内容検索）が、空白を含むパスのテストクラスも見つける
#   （以前は xargs が空白でパスを分割し、テストクラスを見つけられず、含まれていなくても警告しなかった）
test_missing_test_class_found_in_path_with_space() {
    local td
    td=$(setup_force_dir)
    mkdir -p "$td/force-app/main/default/classes" "$td/force-app/main/default/my tests"
    printf 'public class MyClass {}\n' > "$td/force-app/main/default/classes/MyClass.cls"
    printf '@isTest\npublic class MyClassSpec { static void t(){ MyClass x; } }\n' \
        > "$td/force-app/main/default/my tests/MyClassSpec.cls"
    local deploy="$td/deploy.txt" remove="$td/remove.txt"
    printf '[files]\nforce-app/main/default/classes/MyClass.cls\n' > "$deploy"
    printf '[files]\n' > "$remove"

    local out; out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$deploy" "$remove" 2>&1)
    assert_exit_ok "$?" "空白を含むパスのテストクラス → exit 0（warning のみ）"
    assert_output_contains "$out" "→ force-app/main/default/my tests/MyClassSpec.cls" \
        "空白を含むパスのテストクラスが見つかり、含まれていないと警告される"
    teardown "$td"
}

# 回帰: deploy-target.txt に ./ 付きで書いたテストクラスも、含まれていると判定する（警告しない）
#   （以前は、見つかったパスだけ ./ を除いて比べ、./ 付きの行と一致せず、含まれていても警告していた）
test_no_warning_when_test_included_with_dot_slash() {
    local td
    td=$(setup_force_dir)
    mkdir -p "$td/force-app/main/default/classes"
    printf 'public class MyClass {}\n' > "$td/force-app/main/default/classes/MyClass.cls"
    printf '@isTest\npublic class MyClassTest {}\n' > "$td/force-app/main/default/classes/MyClassTest.cls"
    local deploy="$td/deploy.txt" remove="$td/remove.txt"
    printf '[files]\n./force-app/main/default/classes/MyClass.cls\n./force-app/main/default/classes/MyClassTest.cls\n' > "$deploy"
    printf '[files]\n' > "$remove"

    local out; out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$deploy" "$remove" 2>&1)
    assert_exit_ok "$?" "./ 付きで書いたテストクラス → exit 0"
    echo "$out" | grep -q "テストクラス不足の可能性" \
        && fail "./ 付きで書いたテストクラス → warning なし" "$out" \
        || pass "./ 付きで書いたテストクラス → warning なし"

    # クラスだけ ./ 付き・テストクラスは ./ なし、でも同じ
    printf '[files]\n./force-app/main/default/classes/MyClass.cls\nforce-app/main/default/classes/MyClassTest.cls\n' > "$deploy"
    out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$deploy" "$remove" 2>&1)
    echo "$out" | grep -q "テストクラス不足の可能性" \
        && fail "クラスだけ ./ 付き → warning なし" "$out" \
        || pass "クラスだけ ./ 付き → warning なし"
    teardown "$td"
}

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

# 回帰: [files] に、フォルダ（LWC・Aura など、フォルダ単位のもの）を書ける。雛形も、そう案内している
#   （以前は、ファイルだけを認め、雛形の案内どおりに書くと、コミットが止まっていた）
test_files_directory_is_accepted() {
    local td; td=$(setup_force_dir)
    mkdir -p "$td/force-app/main/default/lwc/myComponent"
    echo x > "$td/force-app/main/default/lwc/myComponent/myComponent.js"
    printf '[files]
force-app/main/default/lwc/myComponent
' > "$td/deploy.txt"; printf '[files]
' > "$td/remove.txt"
    local out; out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$td/deploy.txt" "$td/remove.txt" 2>&1)
    assert_exit_ok "$?" "[files] にフォルダ（LWC）→ 正常終了"
    mkdir -p "$td/force-app/main/default/aura/myAura"; echo x > "$td/force-app/main/default/aura/myAura/myAura.cmp"
    printf '[files]
force-app/main/default/aura/myAura
force-app/main/default/lwc/myComponent/
' > "$td/deploy.txt"
    out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$td/deploy.txt" "$td/remove.txt" 2>&1)
    assert_exit_ok "$?" "[files] に Aura のフォルダ・末尾に / のあるフォルダ → 正常終了"
    # それ以外のフォルダ（classes・lwc 全体・.）は、対象が広がりすぎるため、エラー（remove-target.txt では、広範囲の削除になる）
    mkdir -p "$td/force-app/main/default/classes"
    local d
    mkdir -p "$td/force-app/main/default/objects/MyObject__c"
    printf '[files]
force-app/main/default/objects/MyObject__c
' > "$td/deploy.txt"
    out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$td/deploy.txt" "$td/remove.txt" 2>&1)
    assert_exit_ok "$?" "[files] にオブジェクトのフォルダ（objects/MyObject__c）→ 正常終了"
    printf '[files]
force-app/main/default/lwc/myComponent/
' > "$td/deploy.txt"
    for d in "force-app/main/default/classes" "force-app/main/default/lwc" "force-app/main/default/objects" "force-app/main/default/lwc/myComponent/.." "."; do
        printf '[files]
%s
' "$d" > "$td/remove.txt"
        out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$td/deploy.txt" "$td/remove.txt" 2>&1)
        assert_exit_fail "$?" "remove-target.txt に、広いフォルダ（${d}）→ エラー終了"
    done
    printf '[files]
' > "$td/remove.txt"
    printf '[files]
force-app/main/default/lwc/noSuchComponent
' > "$td/deploy.txt"
    out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$td/deploy.txt" "$td/remove.txt" 2>&1)
    assert_exit_fail "$?" "[files] に存在しないフォルダ → エラー終了"
    assert_output_contains "$out" "パスが存在しません" "存在しないフォルダ → 理由が表示される"
    printf '[files]
../outside-dir
' > "$td/deploy.txt"; mkdir -p "$td/../outside-dir" 2>/dev/null
    out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$td/deploy.txt" "$td/remove.txt" 2>&1)
    assert_exit_fail "$?" "[files] にリポジトリの外のフォルダ → エラー終了（フォルダでも、外は認めない）"
    rmdir "$td/../outside-dir" 2>/dev/null
    teardown "$td"
}

# 回帰: 不明なオプションは、パスとして扱わず、エラーで終了する。-v は受け付ける
test_unknown_option_rejected() {
    local td; td=$(setup_force_dir)
    printf '[files]
' > "$td/deploy.txt"; printf '[files]
' > "$td/remove.txt"
    local out; out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" --bogus "$td/deploy.txt" 2>&1)
    assert_exit_fail "$?" "不明なオプション → エラー終了"
    assert_output_contains "$out" "不明なオプションです: --bogus" "不明なオプション → 理由が表示される"
    out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" -v "$td/deploy.txt" "$td/remove.txt" 2>&1)
    assert_exit_ok "$?" "-v は受け付ける（残りの 2 つが、パスとして扱われる）"
    teardown "$td"
}

# 回帰: branch_name.txt がないときは、黙って成功せず、WARNING を出す（コミットは止めない: exit 0）
test_missing_branch_file_warns() {
    local td; td=$(setup_force_dir)
    rm -f "$td/sf-tools/release/branch_name.txt"
    local out; out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" 2>&1)
    assert_exit_ok "$?" "branch_name.txt なし → exit 0（コミットは止めない）"
    echo "$out" | sed 's/\[[0-9;]*m//g' | grep -q "WARNING.*スキップしました"         && pass "branch_name.txt なし → WARNING で、検証を飛ばしたことを知らせる"         || fail "branch_name.txt なし → WARNING で、検証を飛ばしたことを知らせる" "$out"
    teardown "$td"
}

# 回帰: Step B（内容検索）の「単語として含まれる」判定（grep -qw と同じ。プロセスを起動しない書き方に直したため）
#   クラス名が、ほかの単語の一部（Delta2・XDelta・Delta_）・大文字小文字違い（delta）のときは、テストクラスと見なさない。
#   Eps.run() のように、記号で区切られていれば、見なす。
#   @isTest の大文字小文字: デプロイするクラス自身が、テストクラスか（@IsTest など）の判定は、区別しない。
#   テストクラスの本文検索（Step B）は、区別する（@isTest だけを探す）。どちらも、以前（grep）と同じ
test_missing_test_word_boundary() {
    local td; td=$(setup_force_dir)
    local c="$td/force-app/main/default/classes"
    mkdir -p "$c"
    printf 'public class Delta {}\n' > "$c/Delta.cls"
    printf '@isTest\nclass SpecA { void t(){ Delta2 a; XDelta b; Delta_ c; delta d; } }\n' > "$c/SpecA.cls"
    printf 'public class Eps {}\n' > "$c/Eps.cls"
    printf '@isTest\nclass SpecB { void t(){ Eps.run(); } }\n' > "$c/SpecB.cls"
    printf '@IsTest\npublic class Zed {}\n' > "$c/Zed.cls"
    printf '@isTest\nclass SpecC { void t(){ Zed z; } }\n' > "$c/SpecC.cls"
    printf 'public class Eta {}\n' > "$c/Eta.cls"
    printf '@istest\nclass SpecD { void t(){ Eta e; } }\n' > "$c/SpecD.cls"
    printf '[files]\nforce-app/main/default/classes/Delta.cls\nforce-app/main/default/classes/Eps.cls\nforce-app/main/default/classes/Zed.cls\nforce-app/main/default/classes/Eta.cls\n' > "$td/deploy.txt"
    printf '[files]\n' > "$td/remove.txt"

    local out; out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$td/deploy.txt" "$td/remove.txt" 2>&1)
    assert_exit_ok "$?" "単語の境界の確認 → 警告だけで、exit 0"
    echo "$out" | grep -q "SpecA.cls" && fail "Delta2 / XDelta / Delta_ / delta は、Delta のテストと見なさない" || pass "Delta2 / XDelta / Delta_ / delta は、Delta のテストと見なさない"
    assert_output_contains "$out" "→ force-app/main/default/classes/SpecB.cls" "Eps.run() は、単語として含まれる → テストクラスと見なす（deploy-target にないため、警告）"
    echo "$out" | grep -q "SpecC.cls" && fail "自分が @IsTest のクラス（Zed）は、テストクラスの確認の対象外" || pass "自分が @IsTest のクラス（Zed）は、テストクラスの確認の対象外（大文字小文字を区別しない）"
    echo "$out" | grep -q "SpecD.cls" && fail "@istest（小文字）のテストクラスは、本文検索の対象外（区別する）" || pass "@istest（小文字）のテストクラスは、本文検索の対象外（区別する）"
    teardown "$td"
}

# 回帰: 可否の表を、最初に 1 回だけ読み込む形に直したため。同じ種類が重複していたら、最初の行を使う。
#   CRLF の行・列の少ない行（備考なし）も、同じに扱う
test_capability_table_duplicate_and_crlf() {
    local td; td=$(setup_force_dir)
    printf '# c\r\nFooNg\tng\tok\t備考A\r\nFooNg\tok\tok\t重複（無視）\r\nBarLim\tlimited\tok\r\n' > "$td/cap.txt"
    printf '[members]\nFooNg:A\nBarLim:B\n' > "$td/deploy.txt"; printf '[files]\n' > "$td/remove.txt"
    local out; out=$(cd "$td" && SF_CHECK_CAPABILITY_FILE="$td/cap.txt" bash "$SF_TOOLS_DIR/bin/sf-check.sh" "$td/deploy.txt" "$td/remove.txt" 2>&1)
    assert_exit_fail "$?" "重複した種類は、最初の行（ng）を使う → エラー終了"
    assert_output_contains "$out" "備考A" "最初の行の備考が出る（CR は除かれる）"
    echo "$out" | grep -q "重複（無視）" && fail "重複した 2 行目は、使わない" || pass "重複した 2 行目は、使わない"
    assert_output_contains "$out" "BarLim" "列の少ない行（備考なし）の種類も、引ける（limited → 警告）"
    teardown "$td"
}

test_files_valid_path
test_files_missing_path
test_missing_test_word_boundary
test_capability_table_duplicate_and_crlf
test_files_directory_is_accepted
test_unknown_option_rejected
test_missing_branch_file_warns
test_files_outside_repo_path
test_members_valid_format
test_members_invalid_format
test_markers_only_no_error
test_file_not_exists
test_auto_resolve_branch
test_missing_test_class_warning
test_no_warning_when_test_included
test_no_warning_when_test_included_nonstandard_name
test_missing_test_class_found_in_path_with_space
test_no_warning_when_test_included_with_dot_slash
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
