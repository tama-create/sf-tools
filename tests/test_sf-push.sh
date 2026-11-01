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
    symbolic-ref) echo "\${MOCK_BRANCH:-feature/test}"; [[ "\${MOCK_DETACHED:-}" == "1" ]] && exit 1; exit 0 ;;
    fetch)  exit 0 ;;
    merge)
        # merge --abort は成功させる。コンフリクトのときは、git と同じ形の理由を出して失敗する
        [[ "\${args[\$(( idx + 1 ))]}" == "--abort" ]] && exit 0
        if [[ "$mode" == "conflict" ]]; then
            echo "CONFLICT (content): Merge conflict in force-app/main/default/classes/A.cls"
            echo "Automatic merge failed; fix conflicts and then commit the result."
            exit 1
        fi
        exit 0 ;;
    add)    exit 0 ;;
    diff)
        [[ "$mode" == "no_changes" || "$mode" == "unpushed" ]] && exit 0 || exit 1 ;;
    rev-list) [[ "$mode" == "unpushed" ]] && echo 2; exit 0 ;;
    commit)
        # -F で渡されたメッセージのファイルを、テストで中身を確かめるため、写しておく
        for (( i = idx; i < \${#args[@]}; i++ )); do
            [[ "\${args[\$i]}" == "-F" ]] && cp "\${args[\$(( i + 1 ))]}" "$mb/commit_msg.txt"
        done
        exit 0 ;;
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
elif [[ "$mode" == "multiline" ]]; then
    # 先頭の空行・コメント・件名・空行・本文（途中に空白だけの行）・末尾の空行（CRLF）
    printf '\n   \n# コメント\n件名\r\n\r\n本文1\n  \n# 途中のコメント\n本文2\n\n  \n' > "\$FILE"
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
    # 回帰: 理由（git merge の出力）を、-v がなくても表示する。die は事実だけ（以前は理由にかかわらず「コンフリクト」と決めつけ、
    #   「手動で解決してください」と案内していた）
    # 画面（端末）では、run は、-v がなければ、出力を標準出力にも出さない。標準出力を捨て、標準エラーだけで、理由が見えるか確かめる
    #   （標準出力が端末でないときは、run が出力を標準出力に返すため、標準出力も含めると、以前のコードでも見えてしまう）
    local err; err=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-push.sh" 2>&1 >/dev/null)
    assert_output_contains "$err" "CONFLICT (content): Merge conflict in force-app/main/default/classes/A.cls" \
        "マージの失敗 → git merge の出力（理由）が、-v なしでも標準エラーに表示される"
    assert_file_contains "$mb/push_out.log" "origin/main とのマージに失敗しました。" "マージの失敗 → 事実だけのメッセージ"
    assert_file_not_contains "$mb/push_out.log" "手動で解決" "マージの失敗 → die に復旧の案内を含めない"
    assert_file_contains "$mb/calls.log" "merge --abort" "マージの失敗 → git merge --abort が呼ばれる"
    assert_file_not_contains "$mb/calls.log" "commit" "マージの失敗 → git commit は呼ばれない"
    teardown "$td" "$mb"
}

# --- 回帰: コミットメッセージの、途中の空行（件名と本文の間など）を残す。コメント行と前後の空行・CR は除く ---
#   （以前は空行をすべて除き、件名と本文の間の空行も消えていた）
test_push_commit_message_keeps_inner_blank_lines() {
    local td mb mh
    setup_std_env td mb mh
    _create_mocks_push "$mb" "$td" "multiline"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-push.sh" 2>&1)
    assert_exit_ok $? "複数行のメッセージ → 終了コード 0"
    local expected actual
    expected=$(printf '件名\n\n本文1\n\n本文2')
    actual=$(cat "$mb/commit_msg.txt" 2>/dev/null)
    assert_equals "$actual" "$expected" "コメント行・前後の空行・CR を除き、途中の空行は残す"
    teardown "$td" "$mb"
}

# --- 回帰: sf-check.sh のエラーの理由（どの行か）は、-v がなくても、画面に出る ---
test_push_check_fail_shows_reason() {
    local td mb mh
    setup_std_env td mb mh
    _create_mocks_push "$mb" "$td" "success"
    mkdir -p "$td/sf-tools/release/feature/test"
    echo "feature/test" > "$td/sf-tools/release/branch_name.txt"
    printf '[files]\nnonexistent/ReasonCheck.cls\n' > "$td/sf-tools/release/feature/test/deploy-target.txt"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-push.sh" 2>&1)
    assert_exit_fail $? "sf-check エラー → 終了コード 非0"
    assert_output_contains "$out" "パスが存在しません" "sf-check エラー → 理由が、-v なしでも表示される"
    assert_output_contains "$out" "nonexistent/ReasonCheck.cls" "sf-check エラー → エラーの行が、-v なしでも表示される"
    assert_file_not_contains "$mb/calls.log" "commit" "sf-check エラー → git commit は呼ばれない"
    # 端末では、run を通すと、-v がなければ、sf-check.sh の出力が画面に出ない（テストの標準出力は端末でないため、上では区別できない）。
    #   run を通して呼んでいないことを、コードで確かめる
    grep -q 'run bash "${SCRIPT_DIR}/sf-check.sh"' "$SF_TOOLS_DIR/bin/sf-push.sh" \
        && fail "sf-check.sh を run を通さずに呼ぶ（出力を画面に出す）" \
        || pass "sf-check.sh を run を通さずに呼ぶ（出力を画面に出す）"
    teardown "$td" "$mb"
}

# --- detached HEAD（ブランチの上にいない）→ コミットせずに、エラー終了 ---
test_push_detached_head() {
    local td mb mh
    setup_std_env td mb mh
    _create_mocks_push "$mb" "$td" "success"

    local out; out=$(cd "$td" && MOCK_DETACHED=1 PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-push.sh" 2>&1)
    local ec=$?
    assert_exit_fail $ec "detached HEAD → エラー終了"
    assert_output_contains "$out" "detached HEAD" "detached HEAD であることが表示される"
    assert_file_not_contains "$mb/calls.log" "commit" "detached HEAD → git commit は呼ばれない"
    assert_file_not_contains "$mb/calls.log" "push" "detached HEAD → git push は呼ばれない"
    assert_file_not_contains "$mb/calls.log" "add" "detached HEAD → git add も呼ばれない"
    teardown "$td" "$mb"
}

# --- 保護ブランチ（main）の上 → コミットせずに、エラー終了 ---
test_push_protected_branch() {
    local td mb mh
    setup_std_env td mb mh
    _create_mocks_push "$mb" "$td" "success"

    local out; out=$(cd "$td" && MOCK_BRANCH=main PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-push.sh" 2>&1)
    local ec=$?
    assert_exit_fail $ec "main の上 → エラー終了"
    assert_output_contains "$out" "保護ブランチ" "保護ブランチであることが表示される"
    assert_file_not_contains "$mb/calls.log" "commit" "main の上 → git commit は呼ばれない"
    assert_file_not_contains "$mb/calls.log" "push" "main の上 → git push は呼ばれない"
    # branches.txt に定義された環境ブランチ（staging）も、同じ
    mkdir -p "$td/sf-tools/config"; printf 'main\nstaging\n' > "$td/sf-tools/config/branches.txt"
    : > "$mb/calls.log"
    out=$(cd "$td" && MOCK_BRANCH=staging PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-push.sh" 2>&1)
    assert_exit_fail $? "staging の上（branches.txt の環境ブランチ）→ エラー終了"
    assert_file_not_contains "$mb/calls.log" "commit" "staging の上 → git commit は呼ばれない"
    # 作業ブランチは、これまでどおり動く
    : > "$mb/calls.log"
    out=$(cd "$td" && MOCK_BRANCH=JOB-1 PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-push.sh" 2>&1)
    assert_exit_ok $? "作業ブランチ（JOB-1）は、これまでどおり動く"
    assert_file_contains "$mb/calls.log" "commit" "作業ブランチでは git commit が呼ばれる"
    teardown "$td" "$mb"
}

test_push_no_changes
test_push_unpushed_only
test_push_detached_head
test_push_protected_branch
test_push_cancel
test_push_check_fail
test_push_merge_conflict
test_push_commit_message_keeps_inner_blank_lines
test_push_check_fail_shows_reason
test_push_success

echo ""
