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
            # MOCK_GIT_REMOTE_URL が未設定なら既定の URL。空を設定すると、origin がない（何も出さない）
            echo "${MOCK_GIT_REMOTE_URL-https://github.com/test-owner/force-tama.git}"
        fi
        exit 0 ;;
    fetch)          exit 0 ;;
    rev-parse)
        # rev-parse HEAD → いまの HEAD のコミット（既定: headoid0。gh モックの、マージ済みの PR の既定の最後のコミットと同じ）
        echo "${MOCK_GIT_HEAD_OID:-headoid0}"; exit 0 ;;
    rev-list)
        # rev-list --count <oid>..HEAD → MOCK_GIT_NEW_COMMITS（未設定なら、手元にないコミットとして失敗）
        [[ -n "${MOCK_GIT_NEW_COMMITS:-}" ]] || exit 128
        echo "$MOCK_GIT_NEW_COMMITS"; exit 0 ;;
    merge-base)
        # merge-base --is-ancestor HEAD origin/<target>  → MOCK_GIT_MERGED_TARGETS に target があれば真
        # merge-base --is-ancestor HEAD <コミット>       → MOCK_GIT_ANCESTOR_OIDS に、そのコミットがあれば真
        if [[ "$2" == "--is-ancestor" ]]; then
            if [[ "$4" == origin/* ]]; then
                target="${4#origin/}"
                for mb in ${MOCK_GIT_MERGED_TARGETS:-}; do
                    [[ "$mb" == "$target" ]] && exit 0
                done
            else
                for mb in ${MOCK_GIT_ANCESTOR_OIDS:-}; do
                    [[ "$mb" == "$4" ]] && exit 0
                done
            fi
            exit 1
        fi
        exit 0 ;;
    *)              exit 0 ;;
esac
EOF
    chmod +x "$bin_dir/git"

    # gh モック（--json headRefName,baseRefName[,headRefOid] → 環境変数で制御）
    # MOCK_GH_MERGED_PRS / MOCK_GH_OPEN_PRS: スペース区切りの "head->base" ペア。"head->base@oid" で PR の最後のコミットを指定できる
    #   （省略時は headoid0 = git モックの既定の HEAD。つまり「マージのあと、新しいコミットはない」）
    cat > "$bin_dir/gh" << 'EOF'
#!/bin/bash
echo "gh $*" >> "${MOCK_CALL_LOG:-/dev/null}"
# --jq 付きのときは、gh が適用した後の出力（「ヘッド<TAB>ベース[<TAB>コミット]」の行。@tsv）を返す。なければ JSON
_build_out() {
    local result="[" sep="" pr head base oid
    for pr in $1; do
        oid="headoid0"
        [[ "$pr" == *@* ]] && { oid="${pr##*@}"; pr="${pr%@*}"; }
        head="${pr%%->*}"; base="${pr##*->}"
        if [[ "$_args" == *"--jq"* && "$_args" == *"headRefOid"* && -z "${MOCK_GH_NO_OID:-}" ]]; then
            printf '%s	%s	%s
' "$head" "$base" "$oid"
        elif [[ "$_args" == *"--jq"* ]]; then
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
# --- PR 作成画面の URL: origin の URL の形（https / scp 形式 / ssh://）によらず、https の URL になる ---
#   結合テスト A5 で見つかった: ssh://git@github.com/... の origin だと、ssh:// のままの、開けない URL になった
test_pr_url_from_remote_forms() {
    local td mb mh u
    for u in "https://github.com/test-owner/force-tama.git" "git@github.com:test-owner/force-tama.git" "ssh://git@github.com/test-owner/force-tama.git"; do
        setup_std_env td mb mh
        create_mock_git_with_remote "$mb"
        create_mock_browser "$mb"
        export MOCK_GIT_REMOTE_URL="$u"
        export MOCK_GIT_BRANCH="feature/my-feature"
        export MOCK_GH_MERGED_PRS="feature/my-feature->develop"
        export MOCK_GH_OPEN_PRS=""
        local out; out=$(cd "$td" && echo "y" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
        assert_output_contains "$out" "https://github.com/test-owner/force-tama/compare/staging...feature/my-feature" "origin が ${u} → https の PR 作成画面の URL になる"
        unset MOCK_GIT_REMOTE_URL MOCK_GIT_BRANCH MOCK_GH_MERGED_PRS MOCK_GH_OPEN_PRS
        teardown "$td" "$mb"
    done
}

# --- 回帰: origin の URL に認証情報（https://user:TOKEN@）があっても、画面・ブラウザに出さない ---
#   （以前は、そのまま PR 作成画面の URL にして、画面に表示し、ブラウザで開いていた）
test_pr_url_strips_credentials() {
    local td mb mh u
    for u in "https://x-access-token:ghp_SECRETTOKEN123@github.com/test-owner/force-tama.git" "http://user@github.com/test-owner/force-tama.git"; do
        setup_std_env td mb mh
        create_mock_git_with_remote "$mb"
        create_mock_browser "$mb"
        export MOCK_GIT_REMOTE_URL="$u"
        export MOCK_GIT_BRANCH="feature/my-feature"
        export MOCK_GH_MERGED_PRS="feature/my-feature->develop"
        export MOCK_GH_OPEN_PRS=""
        local out; out=$(cd "$td" && echo "y" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
        assert_output_contains "$out" "//github.com/test-owner/force-tama/compare/staging...feature/my-feature" "認証情報つきの origin（${u%%@*}@...）→ 認証情報を除いた URL を表示する"
        echo "$out" | grep -q "SECRETTOKEN\|user@" \
            && fail "認証情報つきの origin → 画面に認証情報を出さない" "$out" \
            || pass "認証情報つきの origin → 画面に認証情報を出さない"
        grep -v "remote get-url" "$MOCK_CALL_LOG" | grep -q "SECRETTOKEN\|user@" \
            && fail "認証情報つきの origin → ブラウザに認証情報を渡さない" \
            || pass "認証情報つきの origin → ブラウザに認証情報を渡さない"
        unset MOCK_GIT_REMOTE_URL MOCK_GIT_BRANCH MOCK_GH_MERGED_PRS MOCK_GH_OPEN_PRS
        teardown "$td" "$mb"
    done
}

# --- origin の URL を取得できない → エラー終了（/compare/... だけの、開けない URL を開かない）---
test_pr_url_no_origin() {
    local td mb mh
    setup_std_env td mb mh
    create_mock_git_with_remote "$mb"
    create_mock_browser "$mb"
    export MOCK_GIT_REMOTE_URL=""
    export MOCK_GIT_BRANCH="feature/my-feature"
    export MOCK_GH_MERGED_PRS="feature/my-feature->develop"
    export MOCK_GH_OPEN_PRS=""
    local out; out=$(cd "$td" && echo "y" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
    assert_exit_fail $? "origin の URL がない → エラー終了"
    assert_output_contains "$out" "origin の URL を取得できません" "origin の URL がない → 理由が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "compare/" "origin の URL がない → ブラウザを開かない"
    unset MOCK_GIT_REMOTE_URL MOCK_GIT_BRANCH MOCK_GH_MERGED_PRS MOCK_GH_OPEN_PRS
    teardown "$td" "$mb"
}

# --- 回帰: git fetch の「> Command:」の行を、標準エラーごと捨てない（以前は 2>/dev/null で、-v の出力も消えていた）---
test_fetch_command_line_shown() {
    local td mb mh
    setup_std_env td mb mh
    create_mock_git_with_remote "$mb"
    export MOCK_GIT_BRANCH="feature/my-feature"
    export MOCK_GH_MERGED_PRS="" MOCK_GH_OPEN_PRS=""
    local out; out=$(cd "$td" && echo "n" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
    assert_output_contains "$out" "> Command: .*git fetch origin develop staging main" "git fetch の「> Command:」の行が表示される"
    unset MOCK_GIT_BRANCH MOCK_GH_MERGED_PRS MOCK_GH_OPEN_PRS
    teardown "$td" "$mb"
}

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
test_pr_url_from_remote_forms
test_pr_url_strips_credentials
test_pr_url_no_origin
test_fetch_command_line_shown
test_out_of_order_merge
test_staging_synced
test_protected_branch_blocked
test_single_branch_none_merged
test_single_branch_merged

# --- マージのあとに同じブランチへコミットを足した: develop は「その後の変更が未反映」→ 次の PR 先は develop（staging ではない）---
test_merged_stale_next_is_develop() {
    local td mb mh
    setup_std_env td mb mh
    create_mock_git_with_remote "$mb"

    export MOCK_GIT_BRANCH="feature/my-feature"
    export MOCK_GH_MERGED_PRS="feature/my-feature->develop@oldoid1"   # PR の最後のコミット ≠ いまの HEAD（headoid0）
    export MOCK_GH_OPEN_PRS=""
    export MOCK_GIT_NEW_COMMITS="3"

    local out; out=$(cd "$td" && echo "n" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "マージのあとの変更あり → 終了コード 0"
    assert_output_contains "$out" "▶.*develop.*その後の変更（3 コミット）が未反映 → 次のPR先" "develop が ▶（その後の変更 3 コミットが未反映・次のPR先）"
    assert_output_contains "$out" "✗.*staging" "staging は ✗（次のPR先ではない）"
    assert_output_contains "$out" "develop にPRを出しますか" "develop への PR を確認する"
    assert_output_not_contains "$out" "staging にPRを出しますか" "staging への PR を案内しない（develop で確かめていない変更を上げない）"
    assert_output_not_contains "$out" "動作を確かめ終えましたか" "develop（最初の段階）への PR では、動作の確認を聞かない"

    unset MOCK_GIT_BRANCH MOCK_GH_MERGED_PRS MOCK_GH_OPEN_PRS MOCK_GIT_NEW_COMMITS
    teardown "$td" "$mb"
}

# --- マージのあとの変更の数を数えられない（PR の最後のコミットが手元にない）: 数なしで「未反映」と出す ---
test_merged_stale_count_unknown() {
    local td mb mh
    setup_std_env td mb mh
    create_mock_git_with_remote "$mb"

    export MOCK_GIT_BRANCH="feature/my-feature"
    export MOCK_GH_MERGED_PRS="feature/my-feature->develop@oldoid1"
    export MOCK_GH_OPEN_PRS=""
    unset MOCK_GIT_NEW_COMMITS

    local out; out=$(cd "$td" && echo "n" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
    assert_output_contains "$out" "▶.*develop.*マージ済み・その後の変更が未反映 → 次のPR先" "数えられないときは、数なしで「未反映」"

    unset MOCK_GIT_BRANCH MOCK_GH_MERGED_PRS MOCK_GH_OPEN_PRS
    teardown "$td" "$mb"
}

# --- Squash・Rebase でマージ: HEAD が origin/develop の祖先でなくても、PR の最後のコミットと同じ・その祖先なら、マージ済み ---
test_merged_squash_is_merged() {
    local td mb mh out
    setup_std_env td mb mh
    create_mock_git_with_remote "$mb"

    export MOCK_GIT_BRANCH="feature/my-feature"
    export MOCK_GH_OPEN_PRS=""
    export MOCK_GIT_MERGED_TARGETS=""          # HEAD は origin/develop の祖先ではない（Squash）

    # HEAD = PR の最後のコミット
    export MOCK_GH_MERGED_PRS="feature/my-feature->develop@headoid0"
    out=$(cd "$td" && echo "n" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
    assert_output_contains "$out" "✓.*develop.*マージ済み" "HEAD が PR の最後のコミットと同じ → develop は ✓"
    assert_output_contains "$out" "▶.*staging" "→ 次は staging"

    # HEAD が PR の最後のコミットの祖先（手元が少し古い）
    export MOCK_GIT_HEAD_OID="oldhead"
    export MOCK_GH_MERGED_PRS="feature/my-feature->develop@newoid9"
    export MOCK_GIT_ANCESTOR_OIDS="newoid9"
    out=$(cd "$td" && echo "n" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
    assert_output_contains "$out" "✓.*develop.*マージ済み" "HEAD が PR の最後のコミットの祖先 → develop は ✓"
    assert_output_not_contains "$out" "未反映" "未反映とは出さない"

    unset MOCK_GIT_BRANCH MOCK_GH_MERGED_PRS MOCK_GH_OPEN_PRS MOCK_GIT_MERGED_TARGETS MOCK_GIT_HEAD_OID MOCK_GIT_ANCESTOR_OIDS
    teardown "$td" "$mb"
}

# --- マージのあとの変更で、もう一度 develop へ PR を発行済み → develop は PR発行中（未反映の ▶ にしない）---
test_merged_stale_with_open_pr() {
    local td mb mh
    setup_std_env td mb mh
    create_mock_git_with_remote "$mb"

    export MOCK_GIT_BRANCH="feature/my-feature"
    export MOCK_GH_MERGED_PRS="feature/my-feature->develop@oldoid1"
    export MOCK_GH_OPEN_PRS="feature/my-feature->develop"

    local out; out=$(cd "$td" && echo "n" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
    assert_output_contains "$out" "→.*develop.*PR発行中" "develop は PR発行中"
    assert_output_not_contains "$out" "未反映" "PR を発行済みなら、未反映とは出さない"

    unset MOCK_GIT_BRANCH MOCK_GH_MERGED_PRS MOCK_GH_OPEN_PRS
    teardown "$td" "$mb"
}

# --- develop・staging ともにマージ済みのあとで、コミットを足した → develop が ▶、staging は ✗（未反映。順序外にしない）---
test_merged_stale_both() {
    local td mb mh
    setup_std_env td mb mh
    create_mock_git_with_remote "$mb"

    export MOCK_GIT_BRANCH="feature/my-feature"
    export MOCK_GH_MERGED_PRS="feature/my-feature->develop@oldoid1 feature/my-feature->staging@oldoid1"
    export MOCK_GH_OPEN_PRS=""
    export MOCK_GIT_NEW_COMMITS="2"

    local out; out=$(cd "$td" && echo "n" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
    assert_output_contains "$out" "▶.*develop.*その後の変更（2 コミット）が未反映 → 次のPR先" "develop が ▶（次のPR先）"
    assert_output_contains "$out" "✗.*staging.*その後の変更（2 コミット）が未反映" "staging は ✗（未反映）"
    assert_output_not_contains "$out" "順序外" "順序外にはしない"

    unset MOCK_GIT_BRANCH MOCK_GH_MERGED_PRS MOCK_GH_OPEN_PRS MOCK_GIT_NEW_COMMITS
    teardown "$td" "$mb"
}

# --- 2 つ目以降の段階（staging・main）への PR では、1 つ前のブランチの組織で確かめたかを、同じ確認の中で聞く ---
test_confirm_asks_previous_org_checked() {
    local td mb mh out
    setup_std_env td mb mh
    create_mock_git_with_remote "$mb"

    export MOCK_GIT_BRANCH="feature/my-feature"
    export MOCK_GH_OPEN_PRS=""

    export MOCK_GH_MERGED_PRS="feature/my-feature->develop"
    out=$(cd "$td" && echo "n" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
    assert_output_contains "$out" "develop の組織で、動作を確かめ終えましたか？ staging にPRを出しますか？" "staging へは、develop の組織での確認を聞く"

    export MOCK_GH_MERGED_PRS="feature/my-feature->develop feature/my-feature->staging"
    out=$(cd "$td" && echo "n" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
    assert_output_contains "$out" "staging の組織で、動作を確かめ終えましたか？ main にPRを出しますか？" "main へは、staging の組織での確認を聞く"

    unset MOCK_GIT_BRANCH MOCK_GH_MERGED_PRS MOCK_GH_OPEN_PRS
    teardown "$td" "$mb"
}

# --- gh が PR の最後のコミットを返さない（MOCK_GH_NO_OID）: 判定できないため、以前どおりマージ済みとする ---
test_merged_without_oid_is_merged() {
    local td mb mh
    setup_std_env td mb mh
    create_mock_git_with_remote "$mb"

    export MOCK_GIT_BRANCH="feature/my-feature"
    export MOCK_GH_MERGED_PRS="feature/my-feature->develop@oldoid1"
    export MOCK_GH_OPEN_PRS=""
    export MOCK_GH_NO_OID=1

    local out; out=$(cd "$td" && echo "n" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1)
    assert_output_contains "$out" "✓.*develop.*マージ済み" "最後のコミットが取れないときは、develop は ✓"
    assert_output_not_contains "$out" "未反映" "未反映とは出さない"

    unset MOCK_GIT_BRANCH MOCK_GH_MERGED_PRS MOCK_GH_OPEN_PRS MOCK_GH_NO_OID
    teardown "$td" "$mb"
}

test_merged_stale_next_is_develop
test_merged_stale_count_unknown
test_merged_without_oid_is_merged
test_merged_squash_is_merged
test_merged_stale_with_open_pr
test_merged_stale_both
test_confirm_asks_previous_org_checked

print_summary
