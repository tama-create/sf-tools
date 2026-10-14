#!/bin/bash
# ==============================================================================
# test_sf-next.sh - sf-next.sh のテスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-next.sh ===${CLR_RST}"

# git モックに merge-base --is-ancestor / remote get-url を追加
create_mock_git_with_remote() {
    local bin_dir="$1"
    cat > "$bin_dir/git" << 'EOF'
#!/bin/bash
echo "git $*" >> "${MOCK_CALL_LOG:-/dev/null}"
case "$1" in
    symbolic-ref)   echo "${MOCK_GIT_BRANCH:-feature/test}"; exit 0 ;;
    remote)
        if [[ "$2" == "get-url" ]]; then
            echo "https://github.com/test-owner/force-tama.git"
        fi
        exit 0 ;;
    fetch)          exit 0 ;;
    merge-base)
        # merge-base --is-ancestor HEAD origin/<target>
        if [[ "$2" == "--is-ancestor" ]]; then
            target="${4#origin/}"
            for mb in ${MOCK_GIT_MERGED_TARGETS:-}; do
                [[ "$mb" == "$target" ]] && exit 0
            done
            exit 1
        fi
        exit 0 ;;
    *)              exit 0 ;;
esac
EOF
    chmod +x "$bin_dir/git"

    # gh モック（--json headRefName,baseRefName → 環境変数で制御）
    # MOCK_GH_MERGED_PRS / MOCK_GH_OPEN_PRS: スペース区切りの "head->base" ペア
    cat > "$bin_dir/gh" << 'EOF'
#!/bin/bash
echo "gh $*" >> "${MOCK_CALL_LOG:-/dev/null}"
# --jq 付きのときは、gh が適用した後の出力（「ヘッド<TAB>ベース」の行。@tsv）を返す。なければ JSON
_build_out() {
    local result="[" sep="" pr head base
    for pr in $1; do
        head="${pr%%->*}"; base="${pr##*->}"
        if [[ "$_args" == *"--jq"* ]]; then
            printf '%s	%s
' "$head" "$base"
        else
            result="${result}${sep}{\"headRefName\":\"${head}\",\"baseRefName\":\"${base}\"}"
            sep=","
        fi
    done
    [[ "$_args" == *"--jq"* ]] || echo "${result}]"
}
_args="$*"
if echo "$_args" | grep -q -- "--state merged" && echo "$_args" | grep -q -- "--json"; then
    _build_out "${MOCK_GH_MERGED_PRS:-}"
elif echo "$_args" | grep -q -- "--state open" && echo "$_args" | grep -q -- "--json"; then
    _build_out "${MOCK_GH_OPEN_PRS:-}"
else
    exit 0
fi
EOF
    chmod +x "$bin_dir/gh"
}

# --- 3ブランチ構成: develop マージ済み → 次は staging ---
test_next_is_staging() {
    local td mb mh
    setup_std_env td mb mh
    create_mock_git_with_remote "$mb"

    export MOCK_GIT_BRANCH="feature/my-feature"
    export MOCK_GH_MERGED_PRS="feature/my-feature->develop"
    export MOCK_GH_OPEN_PRS=""

    local out; out=$(cd "$td" && echo "n" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "develop 済み → 終了コード 0"
    assert_output_contains "$out" "✓.*develop" "develop が ✓ (マージ済み)"
    assert_output_contains "$out" "▶.*staging" "staging が ▶ (次のPR先)"
    assert_output_contains "$out" "✗.*main" "main が ✗ (未着手)"

    unset MOCK_GIT_BRANCH MOCK_GH_MERGED_PRS MOCK_GH_OPEN_PRS
    teardown "$td" "$mb"
}

# --- 3ブランチ構成: develop+staging マージ済み → 次は main ---
test_next_is_main() {
    local td mb mh
    setup_std_env td mb mh
    create_mock_git_with_remote "$mb"

    export MOCK_GIT_BRANCH="feature/my-feature"
    export MOCK_GH_MERGED_PRS="feature/my-feature->develop feature/my-feature->staging"
    export MOCK_GH_OPEN_PRS=""

    local out; out=$(cd "$td" && echo "n" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "develop+staging 済み → 終了コード 0"
    assert_output_contains "$out" "✓.*develop" "develop が ✓ (マージ済み)"
    assert_output_contains "$out" "✓.*staging" "staging が ✓ (マージ済み)"
    assert_output_contains "$out" "▶.*main" "main が ▶ (次のPR先)"

    unset MOCK_GIT_BRANCH MOCK_GH_MERGED_PRS MOCK_GH_OPEN_PRS
    teardown "$td" "$mb"
}

# --- 3ブランチ構成: 全ブランチマージ済み → 完了メッセージ ---
test_all_merged() {
    local td mb mh
    setup_std_env td mb mh
    create_mock_git_with_remote "$mb"

    export MOCK_GIT_BRANCH="feature/my-feature"
    export MOCK_GH_MERGED_PRS="feature/my-feature->develop feature/my-feature->staging feature/my-feature->main"
    export MOCK_GH_OPEN_PRS=""

    local out; out=$(cd "$td" && echo "n" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "全ブランチマージ済み → 終了コード 0"
    assert_output_contains "$out" "全ブランチへのマージが完了" "完了メッセージが表示される"

    unset MOCK_GIT_BRANCH MOCK_GH_MERGED_PRS MOCK_GH_OPEN_PRS
    teardown "$td" "$mb"
}

# --- 3ブランチ構成: 未マージ → 次は develop ---
test_none_merged() {
    local td mb mh
    setup_std_env td mb mh
    create_mock_git_with_remote "$mb"

    export MOCK_GIT_BRANCH="feature/my-feature"
    export MOCK_GH_MERGED_PRS=""
    export MOCK_GH_OPEN_PRS=""

    local out; out=$(cd "$td" && echo "n" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "未マージ → 終了コード 0"
    assert_output_contains "$out" "▶.*develop" "develop が ▶ (次のPR先)"
    assert_output_contains "$out" "✗.*staging" "staging が ✗ (未着手)"
    assert_output_contains "$out" "✗.*main" "main が ✗ (未着手)"

    unset MOCK_GIT_BRANCH MOCK_GH_MERGED_PRS MOCK_GH_OPEN_PRS
    teardown "$td" "$mb"
}

# --- 2ブランチ構成（main + staging）: 未マージ → 次は staging ---
test_two_branches_none_merged() {
    local td mb mh
    setup_std_env td mb mh
    # branches.txt を2ブランチに上書き
    printf 'main\nstaging\n' > "$td/sf-tools/config/branches.txt"
    create_mock_git_with_remote "$mb"

    export MOCK_GIT_BRANCH="feature/my-feature"
    export MOCK_GH_MERGED_PRS=""
    export MOCK_GH_OPEN_PRS=""

    local out; out=$(cd "$td" && echo "n" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "2ブランチ未マージ → 終了コード 0"
    assert_output_contains "$out" "▶.*staging" "staging が ▶ (次のPR先)"
    assert_output_contains "$out" "✗.*main" "main が ✗ (未着手)"

    unset MOCK_GIT_BRANCH MOCK_GH_MERGED_PRS MOCK_GH_OPEN_PRS
    teardown "$td" "$mb"
}

# --- 保護ブランチから実行 → エラー ---
test_protected_branch_blocked() {
    local td mb mh
    setup_std_env td mb mh
    create_mock_git_with_remote "$mb"

    export MOCK_GIT_BRANCH="main"

    local out; out=$(cd "$td" && echo "n" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
    local ec=$?

    assert_exit_fail $ec "保護ブランチ → エラー終了"
    assert_output_contains "$out" "保護ブランチ" "エラーメッセージが表示される"

    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb"
}

# --- 1ブランチ構成（main のみ）: 未マージ → main が次のPR先 ---
test_single_branch_none_merged() {
    local td mb mh
    setup_std_env td mb mh
    # branches.txt を1ブランチに上書き
    printf 'main\n' > "$td/sf-tools/config/branches.txt"
    create_mock_git_with_remote "$mb"

    export MOCK_GIT_BRANCH="feature/my-feature"
    export MOCK_GH_MERGED_PRS=""
    export MOCK_GH_OPEN_PRS=""

    local out; out=$(cd "$td" && echo "n" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "1ブランチ未マージ → 終了コード 0"
    assert_output_contains "$out" "▶.*main" "main が ▶ (次のPR先)"

    unset MOCK_GIT_BRANCH MOCK_GH_MERGED_PRS MOCK_GH_OPEN_PRS
    teardown "$td" "$mb"
}

# --- 1ブランチ構成（main のみ）: マージ済み → 完了 ---
test_single_branch_merged() {
    local td mb mh
    setup_std_env td mb mh
    printf 'main\n' > "$td/sf-tools/config/branches.txt"
    create_mock_git_with_remote "$mb"

    export MOCK_GIT_BRANCH="feature/my-feature"
    export MOCK_GH_MERGED_PRS="feature/my-feature->main"
    export MOCK_GH_OPEN_PRS=""

    local out; out=$(cd "$td" && echo "n" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "1ブランチマージ済み → 終了コード 0"
    assert_output_contains "$out" "✓.*main" "main が ✓ (マージ済み)"
    assert_output_contains "$out" "全ブランチへのマージが完了" "完了メッセージが表示される"

    unset MOCK_GIT_BRANCH MOCK_GH_MERGED_PRS MOCK_GH_OPEN_PRS
    teardown "$td" "$mb"
}

# --- PR発行中: develop ✓ / staging → PR発行中 / main ▶ 次のPR先 ---
test_pr_open_shown() {
    local td mb mh
    setup_std_env td mb mh
    create_mock_git_with_remote "$mb"

    export MOCK_GIT_BRANCH="feature/my-feature"
    export MOCK_GH_MERGED_PRS="feature/my-feature->develop"
    export MOCK_GH_OPEN_PRS="feature/my-feature->staging"

    local out; out=$(cd "$td" && echo "n" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "PR発行中あり → 終了コード 0"
    assert_output_contains "$out" "✓.*develop" "develop が ✓ (マージ済み)"
    assert_output_contains "$out" "→.*staging" "staging が → (PR発行中)"
    assert_output_contains "$out" "▶.*main" "main が ▶ (次のPR先)"

    unset MOCK_GIT_BRANCH MOCK_GH_MERGED_PRS MOCK_GH_OPEN_PRS
    teardown "$td" "$mb"
}

# --- 順序外マージ: develop ✓ / staging ▶ / main ⚠（main が先にマージ済み）---
test_out_of_order_merge() {
    local td mb mh
    setup_std_env td mb mh
    create_mock_git_with_remote "$mb"

    export MOCK_GIT_BRANCH="feature/my-feature"
    # staging を飛ばして main もマージ済み（順序外）
    export MOCK_GH_MERGED_PRS="feature/my-feature->develop feature/my-feature->main"
    export MOCK_GH_OPEN_PRS=""

    local out; out=$(cd "$td" && echo "n" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "順序外マージ → 終了コード 0"
    assert_output_contains "$out" "✓.*develop" "develop が ✓ (マージ済み)"
    assert_output_contains "$out" "▶.*staging" "staging が ▶ (次のPR先)"
    assert_output_contains "$out" "⚠.*main" "main が ⚠ (順序外マージ済み)"

    unset MOCK_GIT_BRANCH MOCK_GH_MERGED_PRS MOCK_GH_OPEN_PRS
    teardown "$td" "$mb"
}

# --- ブランチ同期: develop ✓ / staging ✓(同期) / main ⚠（PR なしで伝播、staging デプロイ未実行）---
test_staging_synced() {
    local td mb mh
    setup_std_env td mb mh
    create_mock_git_with_remote "$mb"

    export MOCK_GIT_BRANCH="feature/my-feature"
    # develop と main に直接 PR あり、staging は gh PR なし（git merge-base で伝播のみ）
    export MOCK_GH_MERGED_PRS="feature/my-feature->develop feature/my-feature->main"
    export MOCK_GH_OPEN_PRS=""
    # git merge-base では develop/staging/main すべてが到達可能（staging は伝播）
    export MOCK_GIT_MERGED_TARGETS="develop staging main"

    local out; out=$(cd "$td" && echo "n" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "ブランチ同期あり → 終了コード 0"
    assert_output_contains "$out" "✓.*develop" "develop が ✓ (マージ済み)"
    assert_output_contains "$out" "✓.*staging.*ブランチ同期" "staging が ✓ (ブランチ同期)"
    assert_output_contains "$out" "⚠.*main" "main が ⚠ (順序外マージ済み)"

    unset MOCK_GIT_BRANCH MOCK_GH_MERGED_PRS MOCK_GH_OPEN_PRS MOCK_GIT_MERGED_TARGETS
    teardown "$td" "$mb"
}

test_next_is_staging
test_next_is_main
# --- PR 作成画面を開く: open_browser で、OS に合ったコマンド（Git Bash: start / WSL: powershell / macOS: open / Linux: xdg-open）を使う ---
test_pr_open_browser() {
    local td mb mh
    setup_std_env td mb mh
    create_mock_git_with_remote "$mb"
    create_mock_browser "$mb"

    export MOCK_GIT_BRANCH="feature/my-feature"
    export MOCK_GH_MERGED_PRS="feature/my-feature->develop"
    export MOCK_GH_OPEN_PRS=""

    local out; out=$(cd "$td" && echo "y" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "PR を出す → 終了コード 0"
    assert_file_contains "$MOCK_CALL_LOG" "compare/staging...feature/my-feature" "ブラウザで、PR 作成画面（次の PR 先 staging）を開く"
    assert_output_contains "$out" "compare/staging...feature/my-feature" "開けなかった場合に備えて、URL も表示する"

    unset MOCK_GIT_BRANCH MOCK_GH_MERGED_PRS MOCK_GH_OPEN_PRS
    teardown "$td" "$mb"
}

test_all_merged
test_none_merged
test_two_branches_none_merged
test_pr_open_shown
test_pr_open_browser
test_out_of_order_merge
test_staging_synced
test_protected_branch_blocked
test_single_branch_none_merged
test_single_branch_merged

print_summary
