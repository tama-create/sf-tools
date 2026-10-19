#!/bin/bash
# ==============================================================================
# test_sf-push.sh - sf-push.sh のテスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-push.sh ===${CLR_RST}"

# git / code モック生成ヘルパー
_create_mocks_push() {
    local mb="$1" td="$2" mode="$3"  # mode: no_changes / unpushed / cancel / success / conflict
    cat > "$mb/git" << EOF
#!/bin/bash
echo "git \$*" >> "\${MOCK_CALL_LOG:-/dev/null}"
# -C <dir> を読み飛ばして実際のサブコマンドで dispatch
args=("\$@")
idx=0
while [[ "\${args[\$idx]}" == "-C" ]]; do
    idx=\$(( idx + 2 ))
done
cmd="\${args[\$idx]}"
case "\$cmd" in
    rev-parse)
        next="\${args[\$(( idx + 1 ))]}"
        if [[ "\$next" == "--show-toplevel" ]]; then echo "$td"; exit 0; fi
        if [[ "\$next" == "--show-prefix" ]];   then echo "";    exit 0; fi
        exit 0 ;;
    symbolic-ref) echo "feature/test"; exit 0 ;;
    fetch)  exit 0 ;;
    merge)
        [[ "$mode" == "conflict" ]] && exit 1 || exit 0 ;;
    add)    exit 0 ;;
    diff)
        [[ "$mode" == "no_changes" || "$mode" == "unpushed" ]] && exit 0 || exit 1 ;;
    rev-list) [[ "$mode" == "unpushed" ]] && echo 2; exit 0 ;;
    commit) exit 0 ;;
    push)   exit 0 ;;
    *)      exit 0 ;;
esac
EOF
    chmod +x "$mb/git"

    # code モック: cancel なら何も書かない、success ならメッセージを書く
    cat > "$mb/code" << EOF
#!/bin/bash
echo "code \$*" >> "\${MOCK_CALL_LOG:-/dev/null}"
FILE="\${@: -1}"
if [[ "$mode" == "success" ]]; then
    echo "feat: テストコミット" > "\$FILE"
fi
exit 0
EOF
    chmod +x "$mb/code"
}

# --- 変更なし → エラー終了 ---
test_push_no_changes() {
    local td mb mh
    setup_std_env td mb mh
    _create_mocks_push "$mb" "$td" "no_changes"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-push.sh" 2>&1)
    local ec=$?
    assert_exit_ok $ec "変更なし → 終了コード 0（WARNING で正常終了）"
    assert_file_not_contains "$mb/calls.log" "push" "変更なし・未プッシュなし → git push は呼ばれない"
    assert_file_not_contains "$mb/calls.log" "commit" "変更なし → git commit は呼ばれない"
    teardown "$td" "$mb"
}

# --- 変更なし＋未プッシュのコミットあり → コミットせず、プッシュだけ行う（コミット後にプッシュが失敗した後の再実行）---
test_push_unpushed_only() {
    local td mb mh
    setup_std_env td mb mh
    _create_mocks_push "$mb" "$td" "unpushed"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-push.sh" 2>&1)
    local ec=$?
    assert_exit_ok $ec "変更なし＋未プッシュあり → 終了コード 0"
    assert_file_contains "$mb/calls.log" "push" "未プッシュのコミットがあれば git push が呼ばれる"
    assert_file_not_contains "$mb/calls.log" "commit" "未プッシュのみのとき git commit は呼ばれない"
    assert_file_not_contains "$mb/calls.log" "code" "未プッシュのみのとき コミットメッセージの入力は開かない"
    assert_output_contains "$out" "未プッシュのコミットが 2 件" "未プッシュの件数が表示される"
    teardown "$td" "$mb"
}

# --- VSCode でメッセージ未入力 → 正常終了（キャンセル）---
test_push_cancel() {
    local td mb mh
    setup_std_env td mb mh
    _create_mocks_push "$mb" "$td" "cancel"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-push.sh" 2>&1)
    local ec=$?
    assert_exit_ok $ec "未入力キャンセル → 終了コード 0"
    teardown "$td" "$mb"
}

# --- 正常系: VSCode でメッセージ入力 → commit & push ---
test_push_success() {
    local td mb mh
    setup_std_env td mb mh
    _create_mocks_push "$mb" "$td" "success"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-push.sh" 2>&1)
    local ec=$?
    assert_exit_ok $ec "正常系 → 終了コード 0"
    assert_file_contains "$mb/calls.log" "add"    "git add が呼ばれた"
    assert_file_contains "$mb/calls.log" "commit" "git commit が呼ばれた"
    assert_file_contains "$mb/calls.log" "push"   "git push が呼ばれた"
    teardown "$td" "$mb"
}

# --- sf-check.sh がエラー → コミット中止 ---
test_push_check_fail() {
    local td mb mh
    setup_std_env td mb mh
    _create_mocks_push "$mb" "$td" "success"

    # sf-check.sh が失敗するよう、存在しないパスを deploy-target.txt に書く
    mkdir -p "$td/sf-tools/release/feature/test"
    echo "feature/test" > "$td/sf-tools/release/branch_name.txt"
    printf '[files]\nnonexistent/path/that/does/not/exist.cls\n' \
        > "$td/sf-tools/release/feature/test/deploy-target.txt"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-push.sh" 2>&1)
    local ec=$?
    assert_exit_fail $ec "sf-check エラー → コミット中止（終了コード 非0）"
    teardown "$td" "$mb"
}

# --- マージコンフリクト → エラー中止 ---
test_push_merge_conflict() {
    local td mb mh
    setup_std_env td mb mh
    _create_mocks_push "$mb" "$td" "conflict"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-push.sh" 2>&1)
    local ec=$?
    assert_exit_fail $ec "マージコンフリクト → エラー中止（終了コード 非0）"
    echo "$out" > "$mb/push_out.log"
    assert_file_contains "$mb/push_out.log" "コンフリクト" "コンフリクトメッセージが出力される"
    teardown "$td" "$mb"
}

test_push_no_changes
test_push_unpushed_only
test_push_cancel
test_push_check_fail
test_push_merge_conflict
test_push_success

echo ""
