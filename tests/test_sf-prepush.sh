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

    assert_exit_ok $ec "自ブランチのマージ成功 → 正常終了"
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

    assert_exit_ok $ec "main のマージ成功 → 正常終了"
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

    assert_exit_ok $ec "両方マージ成功 → 正常終了"
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
    assert_output_contains "$out" "構文エラー" "構文エラーメッセージが表示された"
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
# 実行
# ------------------------------------------------------------------------------
test_fetch_targets_safe
test_block_push_to_main
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
