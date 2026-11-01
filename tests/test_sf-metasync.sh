#!/bin/bash
# ==============================================================================
# test_sf-metasync.sh - sf-metasync.sh のテスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-metasync.sh ===${CLR_RST}"

# 変更あり → commit と push が実行される
test_changes_are_committed() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    # 1回目の diff-index（phase_git_update）: 0 = ローカル変更なし → 通過
    # 2回目の diff-index（phase_git_sync）:   1 = retrieve 後に変更あり → commit
    export MOCK_GIT_BRANCH="main"
    export MOCK_GIT_DIFF_EXIT=0
    export MOCK_GIT_DIFF_EXIT_2ND=1
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$( printf 'Y\nY\n' | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )
    local ec=$?

    assert_file_contains "$MOCK_CALL_LOG" "git commit" "変更あり → commit が実行された"
    assert_file_contains "$MOCK_CALL_LOG" "git push" "変更あり → push が実行された"
    assert_file_contains "$MOCK_CALL_LOG" "git push --no-verify origin main" "main への同期の push は、pre-push フックを通さない（--no-verify）"
    unset MOCK_GIT_BRANCH MOCK_GIT_DIFF_EXIT MOCK_GIT_DIFF_EXIT_2ND MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# 変更なし → commit されずに正常終了
test_no_changes() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    export MOCK_GIT_BRANCH="main"
    export MOCK_GIT_DIFF_EXIT=0
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$( echo "Y" | ( cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )
    local ec=$?

    assert_exit_ok $ec "変更なし → 正常終了"
    ! grep -q "git commit" "$MOCK_CALL_LOG" 2>/dev/null \
        && pass "変更なし → commit は実行されない" \
        || fail "変更なし → commit は実行されない"
    unset MOCK_GIT_BRANCH MOCK_GIT_DIFF_EXIT MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# main 以外のブランチ → main へ自動切替して正常終了
test_non_main_branch_switches() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    export MOCK_GIT_BRANCH="feature/test"
    export MOCK_GIT_DIFF_EXIT=0
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$( echo "Y" | ( cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )
    local ec=$?

    assert_exit_ok $ec "main 以外のブランチ → 正常終了（main へ自動切替）"
    assert_file_contains "$MOCK_CALL_LOG" "git checkout main" "main 以外 → main へ checkout した"
    ! grep -q "git-merge-arg:" "$MOCK_CALL_LOG" 2>/dev/null \
        && pass "変更なし → merge が実行されない" \
        || fail "変更なし → merge が実行されない"
    unset MOCK_GIT_BRANCH MOCK_GIT_DIFF_EXIT MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# staging チェックアウト失敗 → develop は main からマージする（prev_branch バグ修正確認）
test_staging_fail_dev_merges_main() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    export MOCK_GIT_BRANCH="main"
    export MOCK_GIT_CHECKOUT_FAIL_BRANCH="staging"  # staging チェックアウトのみ失敗させる
    export MOCK_GIT_DIFF_EXIT=0
    export MOCK_GIT_DIFF_EXIT_2ND=1  # phase_git_sync で変更あり → commit → propagate 実行
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$( printf 'Y
Y
' | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )

    # 回帰: 完了のメッセージは、実際に伝播できたブランチと、スキップしたブランチを表示する（以前は、固定の文言だった）
    assert_output_contains "$out" "伝播したブランチ: develop）" "完了メッセージ: 伝播できたブランチ（develop）が表示される"
    assert_output_contains "$out" "伝播できなかったブランチ（スキップ）: staging" "完了メッセージ: スキップしたブランチ（staging）が表示される"

    # develop のマージ元が "main" であることを確認（staging ではない）
    assert_file_contains "$MOCK_CALL_LOG" "git-merge-arg: main" "staging 失敗後、develop は main からマージした"
    # 回帰: 伝播の push も、pre-push フックを通さない（伝播先は保護ブランチのため、フックが必ず拒否する。以前は付けていなかった）
    assert_file_contains "$MOCK_CALL_LOG" "git push --no-verify origin develop" "伝播の push は、pre-push フックを通さない（--no-verify）"
    ! grep -q "git-merge-arg: staging" "$MOCK_CALL_LOG" 2>/dev/null \
        && pass "staging からのマージは実行されない" \
        || fail "staging からのマージは実行されない"
    unset MOCK_GIT_BRANCH MOCK_GIT_CHECKOUT_FAIL_BRANCH MOCK_GIT_DIFF_EXIT MOCK_GIT_DIFF_EXIT_2ND MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# force-* 以外で実行 → エラー
test_outside_force_dir() {
    local rd mb
    rd=$(setup_regular_dir); mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"

    local out; out=$(cd "$rd" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" 2>&1)
    local ec=$?

    assert_exit_fail $ec "force-* 外 → エラー終了"
    teardown "$rd" "$mb"
}

# feature ブランチ + ローカル変更あり → stash して処理し、終了後に stash pop
# 回帰: 手元で実行したとき、追跡していないファイルがあれば中止する（以前は、git add -A で、同期のコミットに含めていた）
test_untracked_files_abort_locally() {
    local td mb mh out ec
    setup_std_env td mb mh
    create_all_mocks "$mb"
    export MOCK_GIT_BRANCH="main"
    export MOCK_GIT_DIFF_EXIT=0
    export MOCK_GIT_DIFF_EXIT_2ND=1
    export MOCK_GIT_UNTRACKED="memo.txt"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    out=$( printf 'Y
Y
' | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )
    ec=$?
    assert_exit_fail "$ec" "追跡していないファイルがある → 中止（終了コード 0 以外）"
    assert_output_contains "$out" "追跡していないファイルがあります" "追跡していないファイル → 理由が表示される"
    assert_output_contains "$out" "memo.txt" "追跡していないファイル → ファイル名が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "git commit" "追跡していないファイル → コミットしない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git push" "追跡していないファイル → プッシュしない"

    # GitHub Actions 上では、確認しない（クリーンなチェックアウトで、定期の同期を止めないため）
    : > "$MOCK_CALL_LOG"
    out=$( printf 'Y
Y
' | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" GITHUB_ACTIONS=true bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )
    echo "$out" | grep -q "追跡していないファイルがあります"         && fail "GitHub Actions 上では、追跡していないファイルを、確認しない" "中止した"         || pass "GitHub Actions 上では、追跡していないファイルを、確認しない"
    unset MOCK_GIT_BRANCH MOCK_GIT_DIFF_EXIT MOCK_GIT_DIFF_EXIT_2ND MOCK_GIT_UNTRACKED MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

test_stash_pop_on_exit() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    export MOCK_GIT_BRANCH="feature/test"
    # 1回目の diff-index (phase_switch_to_main): 1 = 変更あり → stash
    # 2回目以降の diff-index (phase_git_update): 0 = main に変更なし
    export MOCK_GIT_DIFF_EXIT=1
    export MOCK_GIT_DIFF_EXIT_2ND=0
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    echo "Y" | ( cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 >/dev/null

    assert_file_contains "$MOCK_CALL_LOG" "git stash" "ローカル変更あり → stash が実行された"
    assert_file_contains "$MOCK_CALL_LOG" "git stash pop" "終了時に stash pop が実行された"
    unset MOCK_GIT_BRANCH MOCK_GIT_DIFF_EXIT MOCK_GIT_DIFF_EXIT_2ND MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# 変更なしでも、未プッシュのコミットがあれば、push だけ行う（前回の同期のコミットの push が、失敗していた）
#   結合テスト X8-4 で見つかった: 以前は、再実行しても「変更なし」で終わり、未プッシュのコミットが取り残された
test_unpushed_commit_pushed() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    export MOCK_GIT_BRANCH="main"
    export MOCK_GIT_DIFF_EXIT=0          # 組織側に変更なし（ステージに変更なし）
    export MOCK_GIT_REV_LIST_COUNT=2     # 未プッシュのコミットが 2 件
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$( printf 'Y\nY\n' | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )
    local ec=$?

    assert_exit_ok $ec "変更なし＋未プッシュあり → 正常終了"
    assert_file_contains "$MOCK_CALL_LOG" "git push --no-verify origin main" "未プッシュのコミットがあれば、push だけ行う"
    assert_file_not_contains "$MOCK_CALL_LOG" "git commit" "未プッシュのみのとき、新しいコミットは作らない"
    assert_output_contains "$out" "未プッシュのコミットが 2 件" "未プッシュの件数が表示される"

    # 確認で N → push しない
    : > "$MOCK_CALL_LOG"
    out=$( printf 'Y\nn\n' | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )
    ec=$?
    assert_exit_fail $ec "未プッシュのコミットの push の確認に n → 中断する"
    assert_file_not_contains "$MOCK_CALL_LOG" "git push" "確認に n → push しない"
    unset MOCK_GIT_BRANCH MOCK_GIT_DIFF_EXIT MOCK_GIT_REV_LIST_COUNT MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

test_changes_are_committed
test_no_changes
test_unpushed_commit_pushed
test_non_main_branch_switches
test_staging_fail_dev_merges_main
# sf の終了コードが 0 以外（インストーラー版の不具合）→ 案内を表示して中断する
test_sf_cli_abort() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    export MOCK_GIT_BRANCH="main"
    export MOCK_GIT_DIFF_EXIT=0
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$( echo "Y" | ( cd "$td" && PATH="$mb:$PATH" MOCK_SF_VERSION_EXIT=1 bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )

    assert_output_contains "$out" "終了コードが 0 ではありません" "sf の終了コード 1 → 案内が表示された"
    assert_file_not_contains "$MOCK_CALL_LOG" "sf org display" "sf の終了コード 1 → 組織の確認まで、進まない"
    unset MOCK_GIT_BRANCH MOCK_GIT_DIFF_EXIT MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# コミット&プッシュの確認で N → 中断する（commit / push しない）
#   以前は ask_yn の戻り値を見ておらず、N と答えても main に commit / push されていた
test_commit_confirm_no_aborts() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    export MOCK_GIT_BRANCH="main"
    export MOCK_GIT_DIFF_EXIT=0
    export MOCK_GIT_DIFF_EXIT_2ND=1
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$( printf 'Y\nN\n' | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )
    local ec=$?

    assert_exit_fail $ec "コミットの確認で N → 中断（終了コード 0 以外）"
    assert_output_contains "$out" "中断しました" "コミットの確認で N → 中断の旨が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "git commit" "コミットの確認で N → commit しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git push" "コミットの確認で N → push しない"
    unset MOCK_GIT_BRANCH MOCK_GIT_DIFF_EXIT MOCK_GIT_DIFF_EXIT_2ND MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# create_mock_git のあとに、引数（"$*"）が、指定のパターンに一致する呼び出しだけを失敗させるラッパーを被せる
#   引数: モックの bin・パターン（case の書式。空白は使えない）・終了コード
_fail_git_matching() {
    local mb="$1" pattern="$2" code="$3"
    mv "$mb/git" "$mb/git-base"
    cat > "$mb/git" << EOF
#!/bin/bash
case "\$*" in
    $pattern) echo "git \$*" >> "\${MOCK_CALL_LOG:-/dev/null}"; exit $code ;;
esac
exec "\$(dirname "\$0")/git-base" "\$@"
EOF
    chmod +x "$mb/git"
}

# 回帰: prod の組織情報を取得できない（sf org display が失敗）→ 何も変更せずに中断する
#   以前は、run の出力（エラーの文言）が空でないため、確認を素通りし、main への切替・取得まで進んでいた
test_prod_not_registered_aborts_early() {
    local td mb mh out ec
    setup_std_env td mb mh
    create_all_mocks "$mb"
    export MOCK_GIT_BRANCH="feature/test"
    export MOCK_GIT_DIFF_EXIT=1
    export MOCK_SF_ORG_DISPLAY_EXIT=1

    out=$( printf 'Y\nY\n' | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )
    ec=$?
    assert_exit_fail "$ec" "sf org display が失敗 → 中断（終了コード 0 以外）"
    assert_output_contains "$out" "prod エイリアスの組織情報を取得できませんでした" "sf org display が失敗 → 理由が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "git stash" "sf org display が失敗 → stash しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git checkout" "sf org display が失敗 → ブランチを切り替えない"
    assert_file_not_contains "$MOCK_CALL_LOG" "sf project retrieve" "sf org display が失敗 → 組織から取得しない"
    unset MOCK_GIT_BRANCH MOCK_GIT_DIFF_EXIT MOCK_SF_ORG_DISPLAY_EXIT
    teardown "$td" "$mb" "$mh"
}

# 回帰: sf org display --json の出力（アクセストークンを含む）を、ログに残さない（以前は、run がログに記録していた）
test_org_display_output_not_logged() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    export MOCK_GIT_BRANCH="main"
    export MOCK_GIT_DIFF_EXIT=0
    export MOCK_SF_ORG_JSON='{"result":{"alias":"prod","accessToken":"SECRET_TOKEN_FOR_TEST"}}'

    printf 'Y\n' | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) > /dev/null 2>&1
    assert_file_not_contains "$td/sf-tools/logs/sf-metasync.log" "SECRET_TOKEN_FOR_TEST" "sf org display の出力（アクセストークン）を、ログに残さない"
    unset MOCK_GIT_BRANCH MOCK_GIT_DIFF_EXIT MOCK_SF_ORG_JSON
    teardown "$td" "$mb" "$mh"
}

# 回帰: detached HEAD → stash・切替の前に中断する
#   以前は、元のブランチにエラーの文言（と「main」）が入り、終了時に戻れないまま、main の上で git stash pop していた
test_detached_head_aborts() {
    local td mb mh out ec
    setup_std_env td mb mh
    create_all_mocks "$mb"
    _fail_git_matching "$mb" "symbolic-ref*" 1
    export MOCK_GIT_DIFF_EXIT=1   # 未コミットの変更あり（以前は、stash していた）
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    out=$( printf 'Y\nY\n' | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )
    ec=$?
    assert_exit_fail "$ec" "detached HEAD → 中断（終了コード 0 以外）"
    assert_output_contains "$out" "detached HEAD" "detached HEAD → 理由が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "git stash" "detached HEAD → stash しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git checkout" "detached HEAD → ブランチを切り替えない"
    unset MOCK_GIT_DIFF_EXIT MOCK_SF_ORG_JSON
    teardown "$td" "$mb" "$mh"
}

# 回帰: metadata.txt が CRLF でも、種類の名前に CR を付けずに取得する（以前は、CR が付いたまま --metadata に渡していた）
test_metadata_crlf() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    export MOCK_GIT_BRANCH="main"
    export MOCK_GIT_DIFF_EXIT=0
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'
    printf '# comment\r\nApexClass\r\n\r\nCustomObject\r\n' > "$td/sf-tools/config/metadata.txt"

    printf 'Y\n' | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) > /dev/null 2>&1
    grep -q -- "--metadata ApexClass --metadata CustomObject$" "$MOCK_CALL_LOG" \
        && pass "CRLF の metadata.txt → CR を除いた種類の名前で取得する" \
        || fail "CRLF の metadata.txt → CR を除いた種類の名前で取得する" "$(grep -- '--metadata' "$MOCK_CALL_LOG" | od -c | head -5)"
    unset MOCK_GIT_BRANCH MOCK_GIT_DIFF_EXIT MOCK_SF_ORG_JSON
    teardown "$td" "$mb" "$mh"
}

test_outside_force_dir
test_untracked_files_abort_locally
test_stash_pop_on_exit
test_sf_cli_abort
test_commit_confirm_no_aborts
test_prod_not_registered_aborts_early
test_org_display_output_not_logged
test_detached_head_aborts
test_metadata_crlf

print_summary
