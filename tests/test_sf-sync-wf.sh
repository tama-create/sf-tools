#!/bin/bash
# ==============================================================================
# test_sf-sync-wf.sh - sf-sync-wf.sh のテスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-sync-wf.sh ===${CLR_RST}"

# テスト環境を作る。force-* のフォルダ（td）・モックの bin（mb）・sf-tools 一式を置いた HOME（mh）
#   雛形（mh の sf-tools/templates/.github/workflows/）に、2 つのワークフローを置き、
#   プロジェクト（td の .github/workflows/）には、雛形と同じものをコピーしておく
#   使い方: _wf_env td mb mh
_wf_env() {
    local -n _t=$1 _m=$2 _h=$3
    setup_std_env _t _m _h
    create_all_mocks "$_m"
    local src="$_h/sf-tools/templates/.github/workflows"
    rm -rf "$src"; mkdir -p "$src" "$_t/.github/workflows"
    printf 'name: A\njobs:\n  a:\n    steps:\n      - run: echo new-a\n' > "$src/wf-a.yml"
    printf 'name: B\njobs:\n  b:\n    steps:\n      - run: echo new-b\n' > "$src/wf-b.yml"
    cp "$src/wf-a.yml" "$src/wf-b.yml" "$_t/.github/workflows/"
    export MOCK_GIT_BRANCH="system-20261006"
}

# sf-sync-wf.sh を実行する。使い方: _wf_run td mb mh 標準入力 [引数...]
_wf_run() {
    local td="$1" mb="$2" mh="$3" input="$4"; shift 4
    printf '%b' "$input" | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$mh/sf-tools/bin/sf-sync-wf.sh" "$@" ) 2>&1
}

# --help → 説明が表示される
test_help() {
    local out ec
    out=$(bash "$SF_TOOLS_DIR/bin/sf-sync-wf.sh" --help 2>&1); ec=$?
    assert_exit_ok "$ec" "--help → 終了コード 0"
    assert_output_contains "$out" "sf-sync-wf.sh" "--help → スクリプト名が表示される"
    assert_output_contains "$out" "system-日付" "--help → 更新の手順（作業用ブランチの名前）が表示される"
}

# force-* 以外 / 環境ブランチ / 不明なオプション → 拒否される
test_guards() {
    local td mb mh out ec
    _wf_env td mb mh

    local rd; rd=$(setup_regular_dir)
    out=$( cd "$rd" && HOME="$mh" PATH="$mb:$PATH" bash "$mh/sf-tools/bin/sf-sync-wf.sh" 2>&1 < /dev/null ); ec=$?
    assert_exit_fail "$ec" "force-* 以外 → エラー終了"
    teardown "$rd"

    local b
    for b in main staging develop; do
        echo "changed" >> "$td/.github/workflows/wf-a.yml"
        out=$(MOCK_GIT_BRANCH="$b" _wf_run "$td" "$mb" "$mh" "Y"); ec=$?
        assert_exit_fail "$ec" "環境ブランチ（${b}）→ エラー終了"
        assert_output_contains "$out" "環境ブランチ" "環境ブランチ（${b}）→ 拒否の理由が表示される"
        grep -q "changed" "$td/.github/workflows/wf-a.yml" && pass "環境ブランチ（${b}）→ ファイルは変更されない" || fail "環境ブランチ（${b}）→ ファイルは変更されない"
        cp "$mh/sf-tools/templates/.github/workflows/wf-a.yml" "$td/.github/workflows/wf-a.yml"
    done

    out=$(_wf_run "$td" "$mb" "$mh" "" --unknown); ec=$?
    assert_exit_fail "$ec" "不明なオプション → エラー終了"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb" "$mh"
}

# 差分なし → 「最新です」で終了（確認を出さない）。CRLF だけの違いは、差分とみなさない
test_up_to_date() {
    local td mb mh out ec
    _wf_env td mb mh
    out=$(_wf_run "$td" "$mb" "$mh" "Y"); ec=$?
    assert_exit_ok "$ec" "差分なし → 終了コード 0"
    assert_output_contains "$out" "最新です" "差分なし → 「最新です」と表示される"
    assert_output_contains "$out" "管理者以外は、実行しないでください" "差分なしでも、冒頭に、管理者向けの警告ボックスが表示される"
    out=$(_wf_run "$td" "$mb" "$mh" "N"); ec=$?
    assert_exit_fail "$ec" "冒頭の確認で N → 中断（差分なしでも、確認を出す）"
    out=$(_wf_run "$td" "$mb" "$mh" "" --check); ec=$?
    assert_exit_ok "$ec" "--check → 確認なしで、終了コード 0（何も変更しないため）"
    echo "$out" | grep -q "管理者以外は、実行しないでください" && fail "--check → 警告ボックスを表示しない" || pass "--check → 警告ボックスを表示しない"

    sed -i 's/$/\r/' "$td/.github/workflows/wf-a.yml"   # CRLF にする（Windows の改行）
    out=$(_wf_run "$td" "$mb" "$mh" "Y"); ec=$?
    assert_exit_ok "$ec" "CRLF だけの違い → 終了コード 0"
    assert_output_contains "$out" "最新です" "CRLF だけの違い → 差分とみなさない"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb" "$mh"
}

# 差分あり: N / q → 変更しない。Y → 雛形の内容で上書き（新規ファイルも追加）
test_sync() {
    local td mb mh out ec
    _wf_env td mb mh
    local tmpl="$mh/sf-tools/templates/.github/workflows"
    echo "# project customized" >> "$td/.github/workflows/wf-a.yml"
    rm -f "$td/.github/workflows/wf-b.yml"   # このプロジェクトにない（新規）

    # 冒頭の確認で N / q → 差分を表示する前に中断する（何も変更しない）
    out=$(_wf_run "$td" "$mb" "$mh" "N"); ec=$?
    assert_exit_fail "$ec" "冒頭の確認で N → 中断（エラー終了）"
    assert_output_contains "$out" "管理者以外は、実行しないでください" "冒頭の確認 → 警告ボックスが表示される"
    echo "$out" | grep -q "差分あり: wf-a.yml" && fail "冒頭の確認で N → 差分は、表示されない" || pass "冒頭の確認で N → 差分は、表示されない"
    out=$(_wf_run "$td" "$mb" "$mh" "q"); ec=$?
    assert_exit_fail "$ec" "冒頭の確認で q → 中断（エラー終了）"
    grep -q "project customized" "$td/.github/workflows/wf-a.yml" && pass "冒頭の確認で N / q → ファイルは変更されない" || fail "冒頭の確認で N / q → ファイルは変更されない"

    out=$(_wf_run "$td" "$mb" "$mh" "YN"); ec=$?
    assert_exit_fail "$ec" "差分あり + 2 回目 N → 中断（エラー終了）"
    assert_output_contains "$out" "差分あり: wf-a.yml" "差分あり → 差分のあるファイルが表示される"
    assert_output_contains "$out" "new-a" "差分あり → diff の内容（雛形側）が表示される"
    assert_output_contains "$out" "新規（雛形にあり、このプロジェクトにない）: wf-b.yml" "差分あり → 新規のファイルが表示される"
    grep -q "project customized" "$td/.github/workflows/wf-a.yml" && pass "N → ファイルは変更されない" || fail "N → ファイルは変更されない"
    assert_file_not_exists "$td/.github/workflows/wf-b.yml" "N → 新規のファイルは、追加されない"

    out=$(_wf_run "$td" "$mb" "$mh" "Yq"); ec=$?
    assert_exit_fail "$ec" "差分あり + 2 回目 q → 中断（エラー終了）"
    grep -q "project customized" "$td/.github/workflows/wf-a.yml" && pass "q → ファイルは変更されない" || fail "q → ファイルは変更されない"

    out=$(_wf_run "$td" "$mb" "$mh" "YY"); ec=$?
    assert_exit_ok "$ec" "差分あり + Y → 終了コード 0"
    cmp -s "$tmpl/wf-a.yml" "$td/.github/workflows/wf-a.yml" && pass "Y → 差分のあるファイルが、雛形の内容になる" || fail "Y → 差分のあるファイルが、雛形の内容になる"
    cmp -s "$tmpl/wf-b.yml" "$td/.github/workflows/wf-b.yml" && pass "Y → 新規のファイルが追加される" || fail "Y → 新規のファイルが追加される"
    assert_output_contains "$out" "git diff .github/workflows/" "Y → 確認とコミットの案内が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "git commit" "Y → 自動でコミットしない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git push" "Y → 自動でプッシュしない"

    out=$(_wf_run "$td" "$mb" "$mh" "Y"); ec=$?
    assert_output_contains "$out" "最新です" "更新後 → 「最新です」になる"

    # 雛形にないファイルは、変更しない（情報として、表示するだけ）
    echo "name: Extra" > "$td/.github/workflows/wf-old.yml"
    echo "# again" >> "$td/.github/workflows/wf-a.yml"
    out=$(_wf_run "$td" "$mb" "$mh" "YY"); ec=$?
    assert_output_contains "$out" "雛形にないワークフロー" "雛形にないファイルが、情報として表示される"
    assert_file_exists "$td/.github/workflows/wf-old.yml" "雛形にないファイルは、削除されない"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb" "$mh"
}

# .github/workflows/ がないプロジェクト → 雛形のすべてを追加する
test_no_workflows_dir() {
    local td mb mh out ec
    _wf_env td mb mh
    rm -rf "$td/.github"
    out=$(_wf_run "$td" "$mb" "$mh" "YY"); ec=$?
    assert_exit_ok "$ec" ".github/workflows/ がない + Y → 終了コード 0"
    assert_file_exists "$td/.github/workflows/wf-a.yml" ".github/workflows/ がない → wf-a.yml が追加される"
    assert_file_exists "$td/.github/workflows/wf-b.yml" ".github/workflows/ がない → wf-b.yml が追加される"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb" "$mh"
}

# --check → 差分があるかだけを調べる（変更しない・確認を出さない）
test_check() {
    local td mb mh out ec
    _wf_env td mb mh
    out=$(_wf_run "$td" "$mb" "$mh" "" --check); ec=$?
    assert_exit_ok "$ec" "--check + 差分なし → 終了コード 0"
    assert_output_contains "$out" "最新です" "--check + 差分なし → 「最新です」"

    echo "# customized" >> "$td/.github/workflows/wf-a.yml"
    out=$(_wf_run "$td" "$mb" "$mh" "" --check); ec=$?
    assert_exit_fail "$ec" "--check + 差分あり → 終了コード 1"
    assert_output_contains "$out" "差分あり: wf-a.yml" "--check + 差分あり → 差分が表示される"
    grep -q "customized" "$td/.github/workflows/wf-a.yml" && pass "--check → ファイルは変更されない" || fail "--check → ファイルは変更されない"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb" "$mh"
}

# --remove → 雛形から廃止されたファイルだけを、二重の確認のうえ、削除する
test_remove() {
    local td mb mh out ec
    _wf_env td mb mh
    echo "name: Old" > "$td/.github/workflows/wf-old.yml"

    out=$(_wf_run "$td" "$mb" "$mh" "YN" --remove wf-old.yml); ec=$?
    assert_exit_fail "$ec" "--remove + 1 回目 Y・2 回目 N → 中断"
    assert_file_exists "$td/.github/workflows/wf-old.yml" "--remove + 2 回目 N → 削除されない"

    out=$(_wf_run "$td" "$mb" "$mh" "N" --remove wf-old.yml); ec=$?
    assert_exit_fail "$ec" "--remove + 1 回目 N → 中断"
    assert_file_exists "$td/.github/workflows/wf-old.yml" "--remove + 1 回目 N → 削除されない"

    out=$(_wf_run "$td" "$mb" "$mh" "YY" --remove wf-old.yml); ec=$?
    assert_exit_ok "$ec" "--remove + Y・Y → 終了コード 0"
    assert_file_not_exists "$td/.github/workflows/wf-old.yml" "--remove + Y・Y → 削除される"

    # 雛形にあるファイル・存在しないファイル・パスを含む名前・ファイル名の指定なし → 拒否される
    out=$(_wf_run "$td" "$mb" "$mh" "YY" --remove wf-a.yml); ec=$?
    assert_exit_fail "$ec" "--remove + 雛形にあるファイル → エラー終了"
    assert_output_contains "$out" "雛形にある" "--remove + 雛形にあるファイル → 理由が表示される"
    assert_file_exists "$td/.github/workflows/wf-a.yml" "--remove + 雛形にあるファイル → 削除されない"
    out=$(_wf_run "$td" "$mb" "$mh" "YY" --remove wf-none.yml); ec=$?
    assert_exit_fail "$ec" "--remove + 存在しないファイル → エラー終了"
    echo "name: Outside" > "$td/outside.yml"
    out=$(_wf_run "$td" "$mb" "$mh" "YY" --remove ../../outside.yml); ec=$?
    assert_exit_fail "$ec" "--remove + パスを含む名前 → エラー終了"
    assert_file_exists "$td/outside.yml" "--remove + パスを含む名前 → フォルダの外のファイルは、削除されない"
    out=$(_wf_run "$td" "$mb" "$mh" "" --remove); ec=$?
    assert_exit_fail "$ec" "--remove + ファイル名の指定なし → エラー終了"

    echo "name: Old" > "$td/.github/workflows/wf-old.yml"
    out=$(MOCK_GIT_BRANCH="main" _wf_run "$td" "$mb" "$mh" "YY" --remove wf-old.yml); ec=$?
    assert_exit_fail "$ec" "--remove + 環境ブランチ → エラー終了"
    assert_file_exists "$td/.github/workflows/wf-old.yml" "--remove + 環境ブランチ → 削除されない"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb" "$mh"
}

# 実際の雛形（templates/.github/workflows/）と、sf-init が作るもの（雛形のコピー）が、同じであること
test_real_templates_are_synced() {
    local td mb mh out ec
    setup_std_env td mb mh
    create_all_mocks "$mb"
    mkdir -p "$td/.github"
    cp -r "$SF_TOOLS_DIR/templates/.github/workflows" "$td/.github/workflows"
    export MOCK_GIT_BRANCH="system-20261006"
    out=$(_wf_run "$td" "$mb" "$mh" "" --check); ec=$?
    assert_exit_ok "$ec" "実際の雛形のコピー → --check で差分なし"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb" "$mh"
}

test_help
test_guards
test_up_to_date
test_sync
test_no_workflows_dir
test_check
test_remove
test_real_templates_are_synced

print_summary
