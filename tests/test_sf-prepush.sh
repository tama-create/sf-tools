#!/bin/bash
# ==============================================================================
# test_sf-prepush.sh - sf-prepush.sh のテスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-prepush.sh ===${CLR_RST}"

# ------------------------------------------------------------------------------
# ヘルパー: sf-prepush.sh を force-* ディレクトリで実行
# ------------------------------------------------------------------------------
run_prepush() {
    local td="$1" mb="$2"
    cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-prepush.sh" 2>&1
}

# 標準入力に、git が pre-push フックに渡す行（「<ローカルの ref> <ローカルの sha> <リモートの ref> <リモートの sha>」）を渡して実行する
run_prepush_refs() {
    local td="$1" mb="$2" lines="$3"
    ( cd "$td" && printf '%b' "$lines" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-prepush.sh" 2>&1 )
}

# ------------------------------------------------------------------------------
# main ブランチへの直接プッシュを禁止
# ------------------------------------------------------------------------------
test_block_push_to_main() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    export MOCK_GIT_BRANCH="main"
    create_mock_git "$mb"

    local out; out=$(run_prepush "$td" "$mb")
    local ec=$?

    assert_exit_fail $ec "main への直接プッシュ → エラー終了"
    assert_output_contains "$out" "禁止" "main プッシュ禁止メッセージが出る"
    teardown "$td" "$mb"
    unset MOCK_GIT_BRANCH
}

# ------------------------------------------------------------------------------
# 自ブランチ・main ともに同期済み → 正常終了
# ------------------------------------------------------------------------------
test_all_synced() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    export MOCK_GIT_BRANCH="feature/test"
    export MOCK_GIT_LOG_BRANCH_OUTPUT=""
    export MOCK_GIT_LOG_MAIN_OUTPUT=""
    create_mock_git "$mb"

    local out; out=$(run_prepush "$td" "$mb")
    local ec=$?

    assert_exit_ok $ec "全同期済み → 正常終了"
    teardown "$td" "$mb"
    unset MOCK_GIT_BRANCH MOCK_GIT_LOG_BRANCH_OUTPUT MOCK_GIT_LOG_MAIN_OUTPUT
}

# ------------------------------------------------------------------------------
# 自ブランチのリモートがまだ存在しない → スキップして正常終了
# ------------------------------------------------------------------------------
test_own_branch_not_on_remote() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    export MOCK_GIT_BRANCH="feature/new"
    export MOCK_GIT_LS_REMOTE_EXIT=2   # ls-remote が失敗 → リモートにブランチなし
    export MOCK_GIT_LOG_MAIN_OUTPUT=""
    create_mock_git "$mb"

    local out; out=$(run_prepush "$td" "$mb")
    local ec=$?

    assert_exit_ok $ec "自ブランチがリモートにない → スキップして正常終了"
    grep -q "merge" "$mb/calls.log" \
        && fail "自ブランチのマージが呼ばれていない" \
        || pass "自ブランチのマージが呼ばれていない"
    teardown "$td" "$mb"
    unset MOCK_GIT_BRANCH MOCK_GIT_LS_REMOTE_EXIT MOCK_GIT_LOG_MAIN_OUTPUT
}

# ------------------------------------------------------------------------------
# 自ブランチに未取り込みコミットあり → マージ成功
# ------------------------------------------------------------------------------
test_own_branch_behind_merge_ok() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    export MOCK_GIT_BRANCH="feature/test"
    export MOCK_GIT_LOG_BRANCH_OUTPUT="abc1234 someone else's commit"
    export MOCK_GIT_LOG_MAIN_OUTPUT=""
    export MOCK_GIT_MERGE_EXIT=0
    create_mock_git "$mb"

    local out; out=$(run_prepush "$td" "$mb")
    local ec=$?

    assert_exit_fail $ec "自ブランチのマージ成功 → プッシュは中止（取り込みは、今回のプッシュに含まれないため）"
    assert_output_contains "$out" "このプッシュには、取り込みが含まれないため、中止しました" "取り込んだ → 中止の理由が表示される"
    grep -q "git-merge-arg: origin/feature/test" "$mb/calls.log" \
        && pass "origin/feature/test をマージした" \
        || fail "origin/feature/test をマージした"
    teardown "$td" "$mb"
    unset MOCK_GIT_BRANCH MOCK_GIT_LOG_BRANCH_OUTPUT MOCK_GIT_LOG_MAIN_OUTPUT MOCK_GIT_MERGE_EXIT
}

# ------------------------------------------------------------------------------
# 自ブランチのマージ失敗 → merge --abort が呼ばれてエラー終了
# ------------------------------------------------------------------------------
test_own_branch_merge_conflict() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    export MOCK_GIT_BRANCH="feature/test"
    export MOCK_GIT_LOG_BRANCH_OUTPUT="abc1234 conflicting commit"
    export MOCK_GIT_LOG_MAIN_OUTPUT=""
    export MOCK_GIT_MERGE_EXIT=1
    create_mock_git "$mb"

    local out; out=$(run_prepush "$td" "$mb")
    local ec=$?

    assert_exit_fail $ec "自ブランチのマージ失敗 → エラー終了"
    grep -q "git merge --abort" "$mb/calls.log" \
        && pass "merge --abort が呼ばれた" \
        || fail "merge --abort が呼ばれた"
    teardown "$td" "$mb"
    unset MOCK_GIT_BRANCH MOCK_GIT_LOG_BRANCH_OUTPUT MOCK_GIT_LOG_MAIN_OUTPUT MOCK_GIT_MERGE_EXIT
}

# ------------------------------------------------------------------------------
# main に未取り込みコミットあり → マージ成功
# ------------------------------------------------------------------------------
test_main_behind_merge_ok() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    export MOCK_GIT_BRANCH="feature/test"
    export MOCK_GIT_LOG_BRANCH_OUTPUT=""
    export MOCK_GIT_LOG_MAIN_OUTPUT="def5678 main update"
    export MOCK_GIT_MERGE_EXIT=0
    create_mock_git "$mb"

    local out; out=$(run_prepush "$td" "$mb")
    local ec=$?

    assert_exit_fail $ec "main のマージ成功 → プッシュは中止（取り込みは、今回のプッシュに含まれないため）"
    assert_output_contains "$out" "このプッシュには、取り込みが含まれないため、中止しました" "取り込んだ → 中止の理由が表示される"
    grep -q "git-merge-arg: origin/main" "$mb/calls.log" \
        && pass "origin/main をマージした" \
        || fail "origin/main をマージした"
    teardown "$td" "$mb"
    unset MOCK_GIT_BRANCH MOCK_GIT_LOG_BRANCH_OUTPUT MOCK_GIT_LOG_MAIN_OUTPUT MOCK_GIT_MERGE_EXIT
}

# ------------------------------------------------------------------------------
# main のマージ失敗 → merge --abort が呼ばれてエラー終了
# ------------------------------------------------------------------------------
test_main_merge_conflict() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    export MOCK_GIT_BRANCH="feature/test"
    export MOCK_GIT_LOG_BRANCH_OUTPUT=""
    export MOCK_GIT_LOG_MAIN_OUTPUT="def5678 main conflicting commit"
    export MOCK_GIT_MERGE_EXIT=1
    create_mock_git "$mb"

    local out; out=$(run_prepush "$td" "$mb")
    local ec=$?

    assert_exit_fail $ec "main のマージ失敗 → エラー終了"
    grep -q "git merge --abort" "$mb/calls.log" \
        && pass "merge --abort が呼ばれた" \
        || fail "merge --abort が呼ばれた"
    teardown "$td" "$mb"
    unset MOCK_GIT_BRANCH MOCK_GIT_LOG_BRANCH_OUTPUT MOCK_GIT_LOG_MAIN_OUTPUT MOCK_GIT_MERGE_EXIT
}

# ------------------------------------------------------------------------------
# 自ブランチ・main 両方に更新あり → 順番通りにマージ
# ------------------------------------------------------------------------------
test_both_behind_merge_order() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    export MOCK_GIT_BRANCH="feature/test"
    export MOCK_GIT_LOG_BRANCH_OUTPUT="abc1234 branch update"
    export MOCK_GIT_LOG_MAIN_OUTPUT="def5678 main update"
    export MOCK_GIT_MERGE_EXIT=0
    create_mock_git "$mb"

    local out; out=$(run_prepush "$td" "$mb")
    local ec=$?

    assert_exit_fail $ec "両方マージ成功 → プッシュは中止（取り込みは、今回のプッシュに含まれないため）"
    # 自ブランチ → main の順でマージされていることを確認
    local branch_line main_line
    branch_line=$(grep -n "git-merge-arg: origin/feature/test" "$mb/calls.log" | cut -d: -f1)
    main_line=$(grep -n "git-merge-arg: origin/main" "$mb/calls.log" | cut -d: -f1)
    [[ -n "$branch_line" && -n "$main_line" && "$branch_line" -lt "$main_line" ]] \
        && pass "自ブランチ → main の順でマージされた" \
        || fail "自ブランチ → main の順でマージされた"
    teardown "$td" "$mb"
    unset MOCK_GIT_BRANCH MOCK_GIT_LOG_BRANCH_OUTPUT MOCK_GIT_LOG_MAIN_OUTPUT MOCK_GIT_MERGE_EXIT
}

# ------------------------------------------------------------------------------
# 回帰: 現在のブランチが作業用でも、プッシュ先が保護ブランチなら、拒否する
#   （以前は、現在のブランチしか見ず、git push origin feature:main などが、フックを通り抜けた）
# ------------------------------------------------------------------------------
test_block_push_target_protected() {
    local td mb out ec ref
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    export MOCK_GIT_BRANCH="feature/test"
    export MOCK_GIT_LOG_BRANCH_OUTPUT=""
    export MOCK_GIT_LOG_MAIN_OUTPUT=""
    create_mock_git "$mb"

    for ref in main staging develop; do
        out=$(run_prepush_refs "$td" "$mb" "refs/heads/feature/test 1111111 refs/heads/${ref} 2222222
"); ec=$?
        assert_exit_fail $ec "feature/test から ${ref} へのプッシュ → エラー終了"
        assert_output_contains "$out" "${ref} ブランチへの直接プッシュは禁止されています" "プッシュ先 ${ref} → 禁止メッセージが出る"
    done
    # 保護ブランチの削除（ローカルの ref が (delete)）も、拒否する
    out=$(run_prepush_refs "$td" "$mb" "(delete) 0000000 refs/heads/main 2222222
"); ec=$?
    assert_exit_fail $ec "保護ブランチの削除（:main）→ エラー終了"
    # 複数の ref のうち、1 つでも保護ブランチなら、拒否する
    out=$(run_prepush_refs "$td" "$mb" "refs/heads/a 1 refs/heads/a 2
refs/heads/b 3 refs/heads/main 4
"); ec=$?
    assert_exit_fail $ec "複数の ref のうち 1 つが main → エラー終了"
    # 作業用ブランチへのプッシュ・タグは、止めない
    out=$(run_prepush_refs "$td" "$mb" "refs/heads/feature/test 1111111 refs/heads/feature/test 2222222
"); ec=$?
    assert_exit_ok $ec "作業用ブランチへのプッシュ → 正常終了"
    out=$(run_prepush_refs "$td" "$mb" "refs/tags/v1 1111111 refs/tags/v1 0000000
"); ec=$?
    assert_exit_ok $ec "タグのプッシュ → 正常終了（ブランチではない）"
    # 標準入力が空（手動実行など）でも、これまでどおり動く
    out=$(run_prepush_refs "$td" "$mb" ""); ec=$?
    assert_exit_ok $ec "標準入力が空 → 正常終了"
    teardown "$td" "$mb"
    unset MOCK_GIT_BRANCH MOCK_GIT_LOG_BRANCH_OUTPUT MOCK_GIT_LOG_MAIN_OUTPUT
}

# ------------------------------------------------------------------------------
# staging / develop への直接プッシュを禁止
# ------------------------------------------------------------------------------
test_block_push_to_staging() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    export MOCK_GIT_BRANCH="staging"
    create_mock_git "$mb"

    local out; out=$(run_prepush "$td" "$mb")
    local ec=$?

    assert_exit_fail $ec "staging への直接プッシュ → エラー終了"
    teardown "$td" "$mb"
    unset MOCK_GIT_BRANCH
}

test_block_push_to_develop() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    export MOCK_GIT_BRANCH="develop"
    create_mock_git "$mb"

    local out; out=$(run_prepush "$td" "$mb")
    local ec=$?

    assert_exit_fail $ec "develop への直接プッシュ → エラー終了"
    teardown "$td" "$mb"
    unset MOCK_GIT_BRANCH
}

# ------------------------------------------------------------------------------
# 構文エラーあり → プッシュを中断
# ------------------------------------------------------------------------------
test_syntax_error_blocks_push() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    export MOCK_GIT_BRANCH="feature/test"
    create_mock_git "$mb"

    # 存在しないパスを記述した deploy-target.txt を作成
    mkdir -p "$td/sf-tools/release/feature/test"
    echo "feature/test" > "$td/sf-tools/release/branch_name.txt"
    printf '[files]\nforce-app/main/default/classes/NotExist.cls\n' \
        > "$td/sf-tools/release/feature/test/deploy-target.txt"
    printf '[files]\n' > "$td/sf-tools/release/feature/test/remove-target.txt"

    local out; out=$(run_prepush "$td" "$mb")
    local ec=$?

    assert_exit_fail $ec "構文エラーあり → プッシュを中断"
    assert_output_contains "$out" "ターゲットファイルの検証でエラーがありました" "検証エラーのメッセージが表示された"
    teardown "$td" "$mb"
    unset MOCK_GIT_BRANCH
}

# ------------------------------------------------------------------------------
# branch_name.txt がない → スキップして正常終了
# ------------------------------------------------------------------------------
test_syntax_skip_when_no_branch_name() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    export MOCK_GIT_BRANCH="feature/test"
    export MOCK_GIT_LOG_BRANCH_OUTPUT=""
    export MOCK_GIT_LOG_MAIN_OUTPUT=""
    create_mock_git "$mb"

    # branch_name.txt を作成しない（setup_force_dir のデフォルト状態）
    local out; out=$(run_prepush "$td" "$mb")
    local ec=$?

    assert_exit_ok $ec "branch_name.txt なし → スキップして正常終了"
    teardown "$td" "$mb"
    unset MOCK_GIT_BRANCH MOCK_GIT_LOG_BRANCH_OUTPUT MOCK_GIT_LOG_MAIN_OUTPUT
}

# ------------------------------------------------------------------------------
# git fetch に渡すブランチ名は、1 つずつ引用して渡し、使えない名前は渡さない
#   branches.txt はリポジトリで共有されるため、空白・ワイルドカード・"-" で始まる値が
#   git fetch のオプションや別の引数として解釈されないようにする
# ------------------------------------------------------------------------------
test_fetch_targets_safe() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    export MOCK_GIT_BRANCH="feature/test"
    export MOCK_GIT_LOG_BRANCH_OUTPUT=""
    export MOCK_GIT_LOG_MAIN_OUTPUT=""
    create_mock_git "$mb"
    # 正常な名前（前後に空白あり）と、使えない名前（オプション形式・空白入り・ワイルドカード）を混ぜる
    printf 'main\n  staging  \n--upload-pack=evil\nbad name\nfeat*\ndevelop\n' > "$td/sf-tools/config/branches.txt"

    local out; out=$(run_prepush "$td" "$mb")
    local ec=$?

    assert_exit_ok $ec "使えないブランチ名が混ざっていても → 正常終了"
    assert_file_contains "$mb/calls.log" "git fetch -q origin -- feature/test main staging develop" \
        "正常な名前だけを、1 つずつ、-- の後ろで git fetch に渡す（前後の空白は除去）"
    assert_file_not_contains "$mb/calls.log" "--upload-pack" "オプション形式の名前は、git fetch に渡さない"
    assert_file_not_contains "$mb/calls.log" "bad" "空白入りの名前は、分割して渡さない"
    assert_file_not_contains "$mb/calls.log" "feat*" "ワイルドカードの名前は、渡さない"
    assert_output_contains "$out" "使えないブランチ名があります" "使えない名前は、警告を表示してスキップする"
    teardown "$td" "$mb"
    unset MOCK_GIT_BRANCH MOCK_GIT_LOG_BRANCH_OUTPUT MOCK_GIT_LOG_MAIN_OUTPUT
}

# ------------------------------------------------------------------------------
# branches.txt に、origin にまだないブランチ名があっても、push は止まらない（その名前だけ取得しない）
#   結合テスト X3-2 で見つかった: 以前は、git fetch が「見つからない」で失敗し、すべての push が止まった
# ------------------------------------------------------------------------------
test_missing_remote_branch_skipped() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    export MOCK_GIT_BRANCH="feature/test"
    export MOCK_GIT_LOG_BRANCH_OUTPUT=""
    export MOCK_GIT_LOG_MAIN_OUTPUT=""
    export MOCK_GIT_LS_REMOTE_MISSING="staging"
    create_mock_git "$mb"
    printf 'main\nstaging\ndevelop\n' > "$td/sf-tools/config/branches.txt"

    local out; out=$(run_prepush "$td" "$mb")
    local ec=$?

    assert_exit_ok $ec "origin にないブランチ名が書かれていても → 正常終了（push を止めない）"
    assert_file_contains "$mb/calls.log" "git fetch -q origin -- feature/test main develop" \
        "origin にあるブランチだけを git fetch に渡す（staging は渡さない）"
    assert_output_contains "$out" "origin に、まだありません（取得しません）: staging" "取得しなかったブランチを、警告で知らせる"
    teardown "$td" "$mb"
    unset MOCK_GIT_BRANCH MOCK_GIT_LOG_BRANCH_OUTPUT MOCK_GIT_LOG_MAIN_OUTPUT MOCK_GIT_LS_REMOTE_MISSING
}

# create_mock_git のあとに、引数（"$*"）が、指定のパターンに一致する呼び出しだけを失敗させるラッパーを被せる
#   引数: モックの bin・パターン（case の書式。空白は使えない）・終了コード・標準エラーに出す文言（省略可）
_fail_git_matching() {
    local mb="$1" pattern="$2" code="$3" msg="${4:-}"
    mv "$mb/git" "$mb/git-base"
    cat > "$mb/git" << EOF
#!/bin/bash
case "\$*" in
    $pattern) echo "git \$*" >> "\${MOCK_CALL_LOG:-/dev/null}"; [[ -n "$msg" ]] && echo "$msg" >&2; exit $code ;;
esac
exec "\$(dirname "\$0")/git-base" "\$@"
EOF
    chmod +x "$mb/git"
}

# ------------------------------------------------------------------------------
# 回帰: detached HEAD → プッシュを中止する（以前は、run が返すエラーの文言を現在のブランチとして扱い、続けていた）
# ------------------------------------------------------------------------------
test_detached_head_aborts() {
    local td mb out ec
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    create_mock_git "$mb"
    _fail_git_matching "$mb" "symbolic-ref*" 128 "fatal: ref HEAD is not a symbolic ref"

    out=$(run_prepush "$td" "$mb"); ec=$?
    assert_exit_fail "$ec" "detached HEAD → エラー終了（プッシュ中止）"
    assert_output_contains "$out" "detached HEAD" "detached HEAD → 理由が表示される"
    assert_file_not_contains "$mb/calls.log" "git fetch" "detached HEAD → fetch・取り込みに進まない"
    teardown "$td" "$mb"
}

# ------------------------------------------------------------------------------
# 回帰: 未取り込みのコミットの確認（git log）が失敗 → merge を試みずに中止する
#   （以前は、run が返すエラーの文言を、未取り込みのコミットと見なして、merge を試みていた）
# ------------------------------------------------------------------------------
test_git_log_failure_aborts() {
    local td mb out ec
    # 自ブランチ（origin/feature/test）の確認が失敗
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    export MOCK_GIT_BRANCH="feature/test"
    create_mock_git "$mb"
    _fail_git_matching "$mb" "log*origin/feature/test*" 128 "fatal: ambiguous argument 'feature/test..origin/feature/test': unknown revision"
    out=$(run_prepush "$td" "$mb"); ec=$?
    assert_exit_fail "$ec" "origin/feature/test の git log が失敗 → エラー終了"
    assert_output_contains "$out" "origin/feature/test との差分を確認できませんでした" "origin/feature/test の git log が失敗 → 理由が表示される"
    assert_file_not_contains "$mb/calls.log" "git-merge-arg" "origin/feature/test の git log が失敗 → merge しない"
    teardown "$td" "$mb"

    # origin/main の確認が失敗（手元に origin/main がない）
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    export MOCK_GIT_LOG_BRANCH_OUTPUT=""
    create_mock_git "$mb"
    _fail_git_matching "$mb" "log*origin/main*" 128 "fatal: ambiguous argument 'feature/test..origin/main': unknown revision"
    out=$(run_prepush "$td" "$mb"); ec=$?
    assert_exit_fail "$ec" "origin/main の git log が失敗 → エラー終了"
    assert_output_contains "$out" "origin/main との差分を確認できませんでした" "origin/main の git log が失敗 → 理由が表示される"
    assert_file_not_contains "$mb/calls.log" "git-merge-arg" "origin/main の git log が失敗 → merge しない"
    teardown "$td" "$mb"
    unset MOCK_GIT_BRANCH MOCK_GIT_LOG_BRANCH_OUTPUT
}

# ------------------------------------------------------------------------------
# 実行
# ------------------------------------------------------------------------------
test_detached_head_aborts
test_git_log_failure_aborts
test_missing_remote_branch_skipped
test_fetch_targets_safe
test_block_push_to_main
test_block_push_target_protected
test_block_push_to_staging
test_block_push_to_develop
test_syntax_error_blocks_push
test_syntax_skip_when_no_branch_name
test_all_synced
test_own_branch_not_on_remote
test_own_branch_behind_merge_ok
test_own_branch_merge_conflict
test_main_behind_merge_ok
test_main_merge_conflict
test_both_behind_merge_order

print_summary
