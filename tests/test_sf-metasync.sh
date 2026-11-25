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

# 表（metadata-dirs.txt）にない種類の警告は、1 行にまとまる（重複は除く）。しかも、警告として出る（[INFO] [WARNING] の二重にしない）
# （以前は、種類ごとに 1 行ずつ、40 行以上出て、「[INFO] [WARNING] …」と二重になっていた）。ログファイルは色なしなので、そこで確かめる
test_unmapped_types_warning_is_one_line() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    printf 'NoSuchTypeA\nNoSuchTypeB\nNoSuchTypeA\n' >> "$td/sf-tools/config/metadata.txt"   # 表にない種類（NoSuchTypeA は重複）

    export MOCK_GIT_BRANCH="main"
    export MOCK_GIT_DIFF_EXIT=0
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    echo "Y" | ( cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) > /dev/null 2>&1

    local log_file="$td/sf-tools/logs/sf-metasync.log"
    assert_file_contains "$log_file" "[WARNING] 表（--dirs-table）にない種類が 2 個あります" "表にない種類 → 重複を除いて、個数を 1 行に出す"
    assert_file_contains "$log_file" "NoSuchTypeA、NoSuchTypeB" "表にない種類 → 名前は省略せずに、1 行に並べる"
    local n; n=$(grep -c '表（--dirs-table）にない種類' "$log_file")
    assert_equals "$n" "1" "表にない種類の警告は、1 行だけ（種類ごとに出さない）"
    assert_file_not_contains "$log_file" "[INFO] [WARNING]" "警告は、[INFO] [WARNING] の二重にならない"
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

# 伝播先は、有効な段階（get_tier_list）だけ（doc/tier-scaling-design.md 3.1・9 章）
#   引数: 1=branches.txt の中身（printf の書式）  2=伝播するはずのブランチ（空白区切り）  3=伝播しないはずのブランチ（空白区切り）  4=説明
_ms_tier_case() {
    local td mb mh b
    setup_std_env td mb mh
    create_all_mocks "$mb"
    printf "$1" > "$td/sf-tools/config/branches.txt"
    export MOCK_GIT_BRANCH="main"
    export MOCK_GIT_DIFF_EXIT=0
    export MOCK_GIT_DIFF_EXIT_2ND=1  # 変更あり → commit → 伝播
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'
    ( printf 'Y\nY\n' | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) ) > /dev/null 2>&1
    for b in $2; do
        assert_file_contains "$MOCK_CALL_LOG" "git push --no-verify origin ${b}" "${4}: ${b} へ伝播する"
    done
    for b in $3; do
        assert_file_not_contains "$MOCK_CALL_LOG" "git push --no-verify origin ${b}" "${4}: ${b} へは伝播しない"
    done
    unset MOCK_GIT_BRANCH MOCK_GIT_DIFF_EXIT MOCK_GIT_DIFF_EXIT_2ND MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}
test_propagate_tiers_only() {
    _ms_tier_case 'main\nstaging\ndevelop\n' "staging develop" ""                "3 段階"
    _ms_tier_case 'main\nstaging\n'          "staging"         "develop"         "develop の行がない（ブランチはリモートにある）"
    _ms_tier_case 'main\ndevelop\n'          ""                "staging develop" "staging がない（develop は無効）"
    _ms_tier_case 'main\nuat\nstaging\n'     "staging"         "uat develop"     "段階の名前でない行（uat）"
    _ms_tier_case '# なし\n'                  ""                "staging develop" "段階の行がない"
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
' | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" GITHUB_ACTIONS=true GITHUB_REPOSITORY=tamashimon-org/force-test GH_TOKEN=dummy bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )
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
test_unmapped_types_warning_is_one_line
test_unpushed_commit_pushed
test_non_main_branch_switches
test_staging_fail_dev_merges_main
test_propagate_tiers_only
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

# 回帰: 接続先の組織の情報を取得できない（sf org display が失敗）→ 何も変更せずに中断する
#   以前は、run の出力（エラーの文言）が空でないため、確認を素通りし、main への切替・取得まで進んでいた
test_target_org_display_fails_aborts_early() {
    local td mb mh out ec
    setup_std_env td mb mh
    create_all_mocks "$mb"
    export MOCK_GIT_BRANCH="feature/test"
    export MOCK_GIT_DIFF_EXIT=1
    export MOCK_SF_ORG_DISPLAY_EXIT=1

    out=$( printf 'Y\nY\n' | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )
    ec=$?
    assert_exit_fail "$ec" "sf org display が失敗 → 中断（終了コード 0 以外）"
    assert_output_contains "$out" "接続先の組織情報を取得できませんでした" "sf org display が失敗 → 理由が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "git stash" "sf org display が失敗 → stash しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git checkout" "sf org display が失敗 → ブランチを切り替えない"
    assert_file_not_contains "$MOCK_CALL_LOG" "sf project retrieve" "sf org display が失敗 → 組織から取得しない"
    unset MOCK_GIT_BRANCH MOCK_GIT_DIFF_EXIT MOCK_SF_ORG_DISPLAY_EXIT
    teardown "$td" "$mb" "$mh"
}

# 接続先は、エイリアスの名前ではなく、組織 ID で決める（手元で実行するとき）。GitHub の SF_ORG_ID_PROD（1 番目 = main の組織の ID）と
# 同じ ID の組織が、どんな名前でログインされていても、そのユーザー名が取得の接続先になる（prod エイリアスは、なくてよい）
test_target_org_resolved_by_org_id() {
    local td mb mh; _ms_env td mb mh
    export MOCK_GH_ORG_ID_PROD="00D5g00000FDr1YEAT" MOCK_SF_ORG_LIST_ID="00D5g00000FDr1YEAT" MOCK_SF_ORG_LIST_USER="main-org-user@example.com"
    _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "接続先（組織 ID）: 一致する組織がある → 正常終了"
    assert_file_contains "$MOCK_CALL_LOG" "gh variable get SF_ORG_ID_PROD" "接続先（組織 ID）: GitHub の SF_ORG_ID_PROD を読む"
    assert_file_contains "$MOCK_CALL_LOG" "sf project retrieve start --target-org main-org-user@example.com" "接続先（組織 ID）: 一致した組織のユーザー名で取得する"
    assert_file_not_contains "$MOCK_CALL_LOG" "--target-org prod" "接続先（組織 ID）: prod エイリアスは使わない"
    assert_output_contains "$_MS_OUT" "接続先組織: main-org-user@example.com" "接続先（組織 ID）: 接続先を表示する"
    _ms_unset; teardown "$td" "$mb" "$mh"
}

# 組織 ID は、15 文字と 18 文字の表記の違いを吸収する（上位 15 文字で比べる）
test_target_org_org_id_15_vs_18_chars() {
    local td mb mh; _ms_env td mb mh
    export MOCK_GH_ORG_ID_PROD="00D5g00000FDr1YEAT" MOCK_SF_ORG_LIST_ID="00D5g00000FDr1Y" MOCK_SF_ORG_LIST_USER="main-org-user@example.com"
    _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "接続先（組織 ID）: 18 文字と 15 文字の表記の違いは、一致とみなす → 正常終了"
    assert_file_contains "$MOCK_CALL_LOG" "sf project retrieve start --target-org main-org-user@example.com" "接続先（組織 ID）: 表記が違っても、同じ組織として取得する"
    _ms_unset; teardown "$td" "$mb" "$mh"
}

# 回帰（取り違えの防止）: main の組織の ID と同じ ID の組織が、この PC の sf にログインされていない → 何も変更せずに中断する
#   （prod という名前の別の組織があっても、推測して進まない）
test_target_org_not_logged_in_aborts() {
    local td mb mh out ec
    setup_std_env td mb mh
    create_all_mocks "$mb"
    export MOCK_GIT_BRANCH="feature/test" MOCK_GIT_DIFF_EXIT=1
    export MOCK_GH_ORG_ID_PROD="00D5g00000FDr1YEAT" MOCK_SF_ORG_LIST_ID="00D999999999999AAA"   # 一覧にある組織は、別の組織

    out=$( printf 'Y\nY\n' | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )
    ec=$?
    assert_exit_fail "$ec" "接続先（組織 ID）: 一致する組織がない → 中断（終了コード 0 以外）"
    assert_output_contains "$out" "ログインされていません" "接続先（組織 ID）: 一致する組織がない → 理由が表示される"
    assert_output_contains "$out" "00D5g00000FDr1YEAT" "接続先（組織 ID）: 探した組織 ID が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "git stash" "接続先（組織 ID）: 一致する組織がない → stash しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git checkout" "接続先（組織 ID）: 一致する組織がない → ブランチを切り替えない"
    assert_file_not_contains "$MOCK_CALL_LOG" "sf project retrieve" "接続先（組織 ID）: 一致する組織がない → 別の組織から取得しない"
    unset MOCK_GIT_BRANCH MOCK_GIT_DIFF_EXIT MOCK_GH_ORG_ID_PROD MOCK_SF_ORG_LIST_ID   # _ms_unset は、この塊より後に定義されるため使えない
    teardown "$td" "$mb" "$mh"
}

# 回帰: GitHub の SF_ORG_ID_PROD を読み取れない → 何も変更せずに中断する（prod エイリアスには、フォールバックしない）
test_target_org_id_variable_unreadable_aborts() {
    local td mb mh out ec
    setup_std_env td mb mh
    create_all_mocks "$mb"
    export MOCK_GIT_BRANCH="feature/test" MOCK_GIT_DIFF_EXIT=1 MOCK_GH_ORG_ID_PROD_EXIT=1

    out=$( printf 'Y\nY\n' | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )
    ec=$?
    assert_exit_fail "$ec" "接続先（組織 ID）: SF_ORG_ID_PROD を読めない → 中断（終了コード 0 以外）"
    assert_output_contains "$out" "SF_ORG_ID_PROD を読み取れませんでした" "接続先（組織 ID）: SF_ORG_ID_PROD を読めない → 理由が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "git checkout" "接続先（組織 ID）: SF_ORG_ID_PROD を読めない → ブランチを切り替えない"
    assert_file_not_contains "$MOCK_CALL_LOG" "sf project retrieve" "接続先（組織 ID）: SF_ORG_ID_PROD を読めない → 取得しない（prod にフォールバックしない）"
    unset MOCK_GIT_BRANCH MOCK_GIT_DIFF_EXIT MOCK_GH_ORG_ID_PROD_EXIT   # _ms_unset は、この塊より後に定義されるため使えない
    teardown "$td" "$mb" "$mh"
}

# GitHub Actions 上では、ワークフローが JWT で作る prod エイリアスを使い、gh（GitHub の Variable）は見ない
test_target_org_actions_uses_prod_alias() {
    local td mb mh; _ms_env td mb mh
    export MOCK_GH_ORG_ID_PROD_EXIT=1   # 手元の方式なら、ここで中断する。Actions 上では、読みにいかないので、影響しない
    _MS_OUT=$( ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" GITHUB_ACTIONS=true GITHUB_REPOSITORY=tamashimon-org/force-test GH_TOKEN=dummy bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )
    _MS_RC=$?
    assert_exit_ok "$_MS_RC" "接続先（Actions）: 正常終了"
    assert_file_contains "$MOCK_CALL_LOG" "sf project retrieve start --target-org prod" "接続先（Actions）: prod エイリアスで取得する"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh variable get SF_ORG_ID_PROD" "接続先（Actions）: GitHub の Variable は読まない"
    _ms_unset; teardown "$td" "$mb" "$mh"
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
test_target_org_display_fails_aborts_early
test_target_org_not_logged_in_aborts
test_target_org_id_variable_unreadable_aborts
test_org_display_output_not_logged
test_detached_head_aborts
test_metadata_crlf

# ------------------------------------------------------------------------------
# 鏡像方式（取得 → 計画 → 反映）のテスト。設計: doc/sf-metasync-redesign.md 9.1
# ------------------------------------------------------------------------------
# 共通: 標準の環境を作る（main・組織の登録済み）。取得先の一時プロジェクトへ書くファイルは MOCK_SF_RETRIEVE_FILES で指定する
_ms_env() {   # 引数: 変数名（td）・変数名（mb）・変数名（mh）
    setup_std_env "$1" "$2" "$3"
    create_all_mocks "${!2}"
    export MOCK_GIT_BRANCH="main" MOCK_GIT_DIFF_EXIT=0
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'
}
_ms_unset() { unset MOCK_GIT_BRANCH MOCK_GIT_DIFF_EXIT MOCK_GIT_DIFF_EXIT_2ND MOCK_SF_ORG_JSON MOCK_SF_RETRIEVE_FILES MOCK_SF_RETRIEVE_EXIT \
    MOCK_SF_RETRIEVE_ERR MOCK_SF_RETRIEVE_FAIL_ONCE MOCK_SF_RETRIEVE_JSON MOCK_GIT_COMMIT_EXIT SF_METASYNC_RETRY_WAIT \
    MOCK_SF_ORG_LIST_ID MOCK_SF_ORG_LIST_USER MOCK_SF_ORG_LIST_JSON MOCK_SF_ORG_LIST_EXIT MOCK_GH_ORG_ID_PROD MOCK_GH_ORG_ID_PROD_EXIT; }
# 実行する。引数: 標準入力 追加の環境変数と引数…（先頭の入力以外は bash に渡す）。結果: $_MS_OUT・$_MS_RC
_ms_run() {
    local input="$1"; shift
    _MS_OUT=$( printf '%b' "$input" | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" "$@" ) 2>&1 )
    _MS_RC=$?
}

# 通常の同期: SGD を呼ばない・取得は一時プロジェクトで行う・取得結果が作業ツリーに入る・パッケージのフォルダだけをステージする
test_mirror_basic() {
    local td mb mh; _ms_env td mb mh
    export MOCK_GIT_DIFF_EXIT_2ND=1
    export MOCK_SF_RETRIEVE_FILES='force-app/main/default/classes/New.cls|public class New {}'
    _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "鏡像: 追加あり → 正常終了"
    assert_file_not_contains "$MOCK_CALL_LOG" "sgd" "鏡像: sf sgd（sfdx-git-delta）を呼ばない"
    assert_file_contains "$MOCK_CALL_LOG" "sf project retrieve start --target-org metasync-test@example.com --ignore-conflicts --json --metadata ApexClass" "鏡像: 取得は --json で、metadata.txt の種類を指定する（接続先は、組織 ID で決めた組織のユーザー名）"
    [[ -f "$td/force-app/main/default/classes/New.cls" ]] && pass "鏡像: 取得結果の追加が、作業ツリーに入る" || fail "鏡像: 取得結果の追加が、作業ツリーに入る"
    assert_file_contains "$MOCK_CALL_LOG" "git add -A -- force-app" "鏡像: パッケージのフォルダだけをステージする"
    assert_file_contains "$MOCK_CALL_LOG" "git commit" "鏡像: commit する"
    assert_output_contains "$_MS_OUT" "追加 1 件 / 変更 0 件 / 削除 0 件 / 削除の保留 0 件" "鏡像: 計画の要約が表示される"
    _ms_unset; teardown "$td" "$mb"
}

# 削除: 組織にないファイルは、作業ツリーから消える（取得結果にあるフォルダのファイルは残る）
test_mirror_deletes() {
    local td mb mh; _ms_env td mb mh
    export MOCK_GIT_DIFF_EXIT_2ND=1
    mkdir -p "$td/force-app/main/default/classes"
    echo old > "$td/force-app/main/default/classes/Gone.cls"; echo keep > "$td/force-app/main/default/classes/Keep.cls"
    export MOCK_SF_RETRIEVE_FILES='force-app/main/default/classes/Keep.cls|keep'
    _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "鏡像の削除: 正常終了"
    [[ ! -e "$td/force-app/main/default/classes/Gone.cls" ]] && pass "鏡像の削除: 組織にないファイルが消える" || fail "鏡像の削除: 組織にないファイルが消える"
    [[ -f "$td/force-app/main/default/classes/Keep.cls" ]] && pass "鏡像の削除: 組織にあるファイルは残る" || fail "鏡像の削除: 組織にあるファイルは残る"
    _ms_unset; teardown "$td" "$mb"
}

# 取得の失敗: 作業ツリーは変わらず、commit・push しない。一時的なエラーは 1 回だけやり直す
test_retrieve_failure_and_retry() {
    local td mb mh; _ms_env td mb mh
    export SF_METASYNC_RETRY_WAIT=0
    export MOCK_SF_RETRIEVE_EXIT=1 MOCK_SF_RETRIEVE_ERR='Error (MetadataTransferError): request failed'
    _ms_run 'Y\n'
    assert_exit_fail "$_MS_RC" "取得の失敗（一時的なエラーが続く）→ 中断"
    assert_equals "$(grep -c 'project retrieve start' "$MOCK_CALL_LOG")" "2" "一時的なエラー → 1 回だけやり直す（取得は 2 回）"
    assert_file_not_contains "$MOCK_CALL_LOG" "git commit" "取得の失敗 → commit しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git add" "取得の失敗 → ステージしない（作業ツリーは変わらない）"
    _ms_unset; teardown "$td" "$mb"

    _ms_env td mb mh
    export SF_METASYNC_RETRY_WAIT=0 MOCK_SF_RETRIEVE_EXIT=1 MOCK_SF_RETRIEVE_FAIL_ONCE=1 MOCK_SF_RETRIEVE_ERR='MetadataTransferError'
    _ms_run 'Y\n'
    assert_exit_ok "$_MS_RC" "一時的なエラー → やり直しで成功すれば、正常終了"
    assert_equals "$(grep -c 'project retrieve start' "$MOCK_CALL_LOG")" "2" "やり直しで成功（取得は 2 回）"
    _ms_unset; teardown "$td" "$mb"

    # 実機で、取得が ERROR_HTTP_404 で失敗したあと、成功した（2026-11-01）。一時的なエラーとして、やり直す
    _ms_env td mb mh
    export SF_METASYNC_RETRY_WAIT=0 MOCK_SF_RETRIEVE_EXIT=1 MOCK_SF_RETRIEVE_FAIL_ONCE=1 MOCK_SF_RETRIEVE_ERR='ERROR_HTTP_404'
    _ms_run 'Y\n'
    assert_exit_ok "$_MS_RC" "ERROR_HTTP_404 → やり直しで成功すれば、正常終了"
    assert_equals "$(grep -c 'project retrieve start' "$MOCK_CALL_LOG")" "2" "ERROR_HTTP_404 → やり直す（取得は 2 回）"
    _ms_unset; teardown "$td" "$mb"

    _ms_env td mb mh
    export SF_METASYNC_RETRY_WAIT=0 MOCK_SF_RETRIEVE_EXIT=1 MOCK_SF_RETRIEVE_ERR='some permanent error'
    _ms_run 'Y\n'
    assert_exit_fail "$_MS_RC" "一時的でないエラー → 中断"
    assert_equals "$(grep -c 'project retrieve start' "$MOCK_CALL_LOG")" "1" "一時的でないエラー → やり直さない（取得は 1 回）"
    _ms_unset; teardown "$td" "$mb"
}

# --dry-run: 取得して計画を表示するだけ（作業ツリー・commit・push・伝播をしない）。-y は --dry-run のときだけ
test_dry_run_options() {
    local td mb mh; _ms_env td mb mh
    export MOCK_GIT_DIFF_EXIT_2ND=1
    export MOCK_SF_RETRIEVE_FILES='force-app/main/default/classes/New.cls|public class New {}'
    _ms_run '' --dry-run --yes
    assert_exit_ok "$_MS_RC" "--dry-run -y: 確認なしで正常終了"
    assert_output_contains "$_MS_OUT" "追加 1 件" "--dry-run: 計画が表示される"
    [[ ! -e "$td/force-app/main/default/classes/New.cls" ]] && pass "--dry-run: 作業ツリーに書かない" || fail "--dry-run: 作業ツリーに書かない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git commit" "--dry-run: commit しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git push" "--dry-run: push しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git add" "--dry-run: ステージしない"
    _ms_run 'n\n' --dry-run
    assert_exit_fail "$_MS_RC" "--dry-run（-y なし）: 続行の確認で N → 中断"
    _ms_run 'Y\n' --yes
    assert_exit_fail "$_MS_RC" "-y を --dry-run なしで指定 → 中断"
    assert_output_contains "$_MS_OUT" "一緒にだけ指定できます" "-y だけの指定: 理由が表示される"
    _ms_unset; teardown "$td" "$mb"
}

# --allow-mass-delete は GitHub Actions 上では指定できない
test_allow_mass_delete_on_actions() {
    local td mb mh; _ms_env td mb mh
    _MS_OUT=$( ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" GITHUB_ACTIONS=true GITHUB_REPOSITORY=tamashimon-org/force-test GH_TOKEN=dummy bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" --allow-mass-delete ) 2>&1 )
    assert_exit_fail $? "--allow-mass-delete を GitHub Actions 上で指定 → 中断"
    assert_output_contains "$_MS_OUT" "GitHub Actions 上では指定できません" "--allow-mass-delete: 理由が表示される"
    _ms_unset; teardown "$td" "$mb"
}

# packageDirectories が 2 つ → 取得の前に中断（S8）
test_two_package_directories() {
    local td mb mh; _ms_env td mb mh
    echo '{"packageDirectories":[{"path":"force-app"},{"path":"other"}]}' > "$td/sfdx-project.json"
    _ms_run 'Y\n'
    assert_exit_fail "$_MS_RC" "packageDirectories が 2 つ → 中断"
    assert_file_not_contains "$MOCK_CALL_LOG" "project retrieve" "packageDirectories が 2 つ → 取得の前に中断する"
    _ms_unset; teardown "$td" "$mb"
}

# 削除の保留（S3: 消えたフォルダ）→ 追加・変更は反映し、削除はせず、終了コード 3
test_hold_exit_code_3() {
    local td mb mh; _ms_env td mb mh
    export MOCK_GIT_DIFF_EXIT_2ND=1
    mkdir -p "$td/force-app/main/default/classes"; echo old > "$td/force-app/main/default/classes/Gone.cls"
    export MOCK_SF_RETRIEVE_FILES='force-app/main/default/lwc/c/c.js|js'
    _MS_OUT=$( ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" GITHUB_ACTIONS=true GITHUB_REPOSITORY=tamashimon-org/force-test GH_TOKEN=dummy bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )
    _MS_RC=$?
    assert_equals "$_MS_RC" "3" "削除の保留あり → 終了コード 3"
    [[ -f "$td/force-app/main/default/classes/Gone.cls" ]] && pass "削除の保留: ファイルは残る" || fail "削除の保留: ファイルは残る"
    assert_file_contains "$MOCK_CALL_LOG" "git commit" "削除の保留: 追加・変更の分は commit する"
    assert_file_contains "$MOCK_CALL_LOG" "git push --no-verify origin main" "削除の保留: 追加・変更の分は push する"
    assert_output_contains "$_MS_OUT" "削除を保留したものがあります" "削除の保留: 案内が表示される"
    # --allow-mass-delete（手元）: S3 の保留が解ける
    : > "$MOCK_CALL_LOG"; rm -f "${MOCK_CALL_LOG%/*}/diffidx.cnt"   # diff-index の呼び出し回数（2 回目に「変更あり」）を数え直す
    _ms_run 'Y\nY\n' --allow-mass-delete
    assert_exit_ok "$_MS_RC" "--allow-mass-delete: 終了コード 0"
    [[ ! -e "$td/force-app/main/default/classes/Gone.cls" ]] && pass "--allow-mass-delete: 削除される" || fail "--allow-mass-delete: 削除される"
    _ms_unset; teardown "$td" "$mb"
}

# コミットの前に中断（commit の失敗）→ 反映した分を HEAD に戻す
test_restore_after_apply_on_failure() {
    local td mb mh; _ms_env td mb mh
    export MOCK_GIT_DIFF_EXIT_2ND=1 MOCK_GIT_COMMIT_EXIT=1
    export MOCK_SF_RETRIEVE_FILES='force-app/main/default/classes/New.cls|x'
    _ms_run 'Y\nY\n'
    assert_exit_fail "$_MS_RC" "commit の失敗 → 中断"
    assert_file_contains "$MOCK_CALL_LOG" "git reset -q HEAD -- force-app" "反映のあと、コミットの前に中断 → ステージ済みの新規ファイルを、インデックスから外す"
    assert_file_contains "$MOCK_CALL_LOG" "git checkout HEAD -- force-app" "反映のあと、コミットの前に中断 → パッケージのフォルダを HEAD に戻す"
    assert_file_contains "$MOCK_CALL_LOG" "git clean -fdq -- force-app" "反映のあと、コミットの前に中断 → 新しく書いたファイルを消す"
    assert_file_not_contains "$MOCK_CALL_LOG" "git push" "commit の失敗 → push しない"
    _ms_unset; teardown "$td" "$mb"
}

# 反映の確認で N → 反映しない（作業ツリーに書かない・commit しない）
test_apply_confirm_no_aborts() {
    local td mb mh; _ms_env td mb mh
    export MOCK_SF_RETRIEVE_FILES='force-app/main/default/classes/New.cls|x'
    _ms_run 'Y\nN\n'
    assert_exit_fail "$_MS_RC" "反映の確認で N → 中断"
    assert_output_contains "$_MS_OUT" "中断しました" "反映の確認で N → 中断の旨が表示される"
    [[ ! -e "$td/force-app/main/default/classes/New.cls" ]] && pass "反映の確認で N → 作業ツリーに書かない" || fail "反映の確認で N → 作業ツリーに書かない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git commit" "反映の確認で N → commit しない"
    _ms_unset; teardown "$td" "$mb"
}

# ------------------------------------------------------------------------------
# 変更の検知（SF_METASYNC_DETECT。設計: doc/sf-metasync-redesign.md 15 章）のテスト
# ------------------------------------------------------------------------------
# 検知の準備: 状態ファイル（前回の全件取得の記録）と、sf のモック（lib/metasync.js が SF_METASYNC_SF で使う）を用意する。
#   引数: 履歴の件数（MOCK_SF_AUDIT_COUNT）。状態は、「一覧が空・A の種類あり」の組を、検知自身に作らせる（1 回目は不明）
_det_env() {
    mkdir -p "$td/sf-tools/config" "$td/sf-tools/metasync"
    export SF_METASYNC_SF="bash $mb/sf" MOCK_SF_LIST_DIR="$td/lists" MOCK_SF_AUDIT_COUNT="${1:-0}"
    mkdir -p "$td/lists"
}
_det_unset() { unset SF_METASYNC_SF MOCK_SF_LIST_DIR MOCK_SF_AUDIT_COUNT MOCK_SF_AUDIT_EXIT SF_METASYNC_DETECT; }
# 現在の種類の一覧（setup_std_env が作る sf-tools/config/metadata.txt）で、検知が書く状態を、あらかじめ作る
_det_state() {
    local types="$td/sf-tools/config/metadata.txt"
    SF_METASYNC_SF="bash $mb/sf" MOCK_SF_LIST_DIR="$td/lists" "$SF_METASYNC_NODE" "$SF_TOOLS_DIR/lib/metasync.js" detect --org prod \
        --types-file "$types" --table "$SF_TOOLS_DIR/config/metasync-detect.txt" --state "$td/none.json" \
        --out-state "$td/sf-tools/metasync/state.json" --now 2026-11-01T00:00:00Z > /dev/null 2>&1
}

# off（既定）: 検知を行わない（履歴・一覧を問い合わせない）。従来どおり、取得する
test_detect_off_default() {
    local td mb mh; _ms_env td mb mh; _det_env 0
    _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "検知 off: 正常終了"
    assert_file_contains "$MOCK_CALL_LOG" "sf project retrieve start" "検知 off: 取得する"
    assert_file_not_contains "$MOCK_CALL_LOG" "SetupAuditTrail" "検知 off: 履歴は問い合わせない"
    assert_file_not_contains "$MOCK_CALL_LOG" "org list metadata" "検知 off: 一覧は問い合わせない"
    [[ ! -f "$td/sf-tools/metasync/state.json" ]] && pass "検知 off: 状態ファイルを作らない" || fail "検知 off: 状態ファイルを作らない"
    _ms_unset; _det_unset; teardown "$td" "$mb"
}

# 不正なモード → 中断
test_detect_bad_mode() {
    local td mb mh; _ms_env td mb mh
    SF_METASYNC_DETECT=maybe _ms_run 'Y\nY\n'
    assert_exit_fail "$_MS_RC" "検知のモードが不正 → 中断"
    assert_output_contains "$_MS_OUT" "off / shadow / on" "検知のモードが不正 → 使える値が出る"
    _ms_unset; _det_unset; teardown "$td" "$mb"
}

# on・状態なし → 不明 → 全件取得し、状態ファイルを作ってコミットする（ファイルの変更がなくても、状態だけのコミット。伝播しない）
test_detect_on_first_run_writes_state() {
    local td mb mh; _ms_env td mb mh; _det_env 0
    export MOCK_GIT_DIFF_EXIT_2ND=1
    SF_METASYNC_DETECT=on _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "検知 on・状態なし: 正常終了"
    assert_file_contains "$MOCK_CALL_LOG" "sf project retrieve start" "検知 on・状態なし（不明）: 全件取得する"
    [[ -f "$td/sf-tools/metasync/state.json" ]] && pass "検知 on・状態なし: 状態ファイルを書く" || fail "検知 on・状態なし: 状態ファイルを書く"
    assert_file_contains "$MOCK_CALL_LOG" "git add -A -- force-app sf-tools/metasync/state.json" "状態ファイルも、ステージする"
    assert_file_contains "$MOCK_CALL_LOG" "検知の状態の更新のみ" "メタデータの変更がなければ、コミットの本文に「状態の更新のみ」と書く"
    assert_output_contains "$_MS_OUT" "下流ブランチへの伝播は行いません" "状態ファイルの更新だけのコミットは、下流へ伝播しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git merge" "状態ファイルの更新だけのコミットは、merge しない"
    _ms_unset; _det_unset; teardown "$td" "$mb"
}

# on・変更なし → 取得を省いて終了（コミット・push しない）。状態ファイルは変わらない
test_detect_on_unchanged_skips_retrieve() {
    local td mb mh; _ms_env td mb mh; _det_env 0
    _det_state
    cp "$td/sf-tools/metasync/state.json" "$td/state.before"
    SF_METASYNC_DETECT=on _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "検知 on・変更なし: 正常終了"
    assert_output_contains "$_MS_OUT" "全件取得を省きました" "検知 on・変更なし: 取得を省いたと表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "sf project retrieve" "検知 on・変更なし: 取得しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git commit" "検知 on・変更なし: commit しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git push" "検知 on・変更なし: push しない"
    cmp -s "$td/sf-tools/metasync/state.json" "$td/state.before" && pass "検知 on・変更なし: 状態ファイルは変わらない" || fail "検知 on・変更なし: 状態ファイルは変わらない"
    _ms_unset; _det_unset; teardown "$td" "$mb"
}

# on・変更なしでも、--full なら取得する（毎日の全件取得）。変更もなければ、状態は更新しない
test_detect_on_full_option() {
    local td mb mh; _ms_env td mb mh; _det_env 0
    _det_state
    cp "$td/sf-tools/metasync/state.json" "$td/state.before"
    SF_METASYNC_DETECT=on _ms_run 'Y\nY\n' --full
    assert_exit_ok "$_MS_RC" "検知 on・--full: 正常終了"
    assert_file_contains "$MOCK_CALL_LOG" "sf project retrieve start" "検知 on・変更なし・--full: 取得する"
    assert_output_contains "$_MS_OUT" "full が指定されているため" "--full: 取得する理由が出る"
    cmp -s "$td/sf-tools/metasync/state.json" "$td/state.before" && pass "--full・検知は変更なし: 状態は更新しない（毎日、状態だけのコミットを作らない）" || fail "--full・検知は変更なし: 状態は更新しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git commit" "--full・変更なし: commit しない"
    _ms_unset; _det_unset; teardown "$td" "$mb"
}

# on・履歴に記録がある → 変更あり → 取得し、状態を更新してコミットする。--dry-run は、検知が変更なしでも取得し、書かない
test_detect_on_changed_and_dry_run() {
    local td mb mh; _ms_env td mb mh; _det_env 0
    _det_state
    export MOCK_SF_AUDIT_COUNT=2 MOCK_GIT_DIFF_EXIT_2ND=1
    export MOCK_SF_RETRIEVE_FILES='force-app/main/default/classes/New.cls|x'
    SF_METASYNC_DETECT=on _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "検知 on・履歴あり: 正常終了"
    assert_output_contains "$_MS_OUT" "履歴に 2 件" "検知 on・履歴あり: 変更ありの理由が出る"
    assert_file_contains "$MOCK_CALL_LOG" "sf project retrieve start" "検知 on・履歴あり: 取得する"
    assert_file_contains "$MOCK_CALL_LOG" "検知の状態も更新" "メタデータの変更があるときは、本文に「検知の状態も更新」と書く"
    assert_file_contains "$MOCK_CALL_LOG" "git merge" "メタデータの変更があるときは、下流へ伝播する"
    _ms_unset; _det_unset; teardown "$td" "$mb"
    # --dry-run
    local td mb mh; _ms_env td mb mh; _det_env 0
    _det_state
    SF_METASYNC_DETECT=on _ms_run '' --dry-run -y
    assert_exit_ok "$_MS_RC" "検知 on・--dry-run: 正常終了"
    assert_file_contains "$MOCK_CALL_LOG" "sf project retrieve start" "検知 on・--dry-run: 検知が変更なしでも、取得して計画を作る"
    assert_output_contains "$_MS_OUT" "dry-run のため、検知の結果にかかわらず" "--dry-run: 取得する理由が出る"
    assert_file_not_contains "$MOCK_CALL_LOG" "git commit" "--dry-run: commit しない"
    _ms_unset; _det_unset; teardown "$td" "$mb"
}

# 履歴の問い合わせの失敗 → 不明 → 全件取得（検知の失敗が、取りこぼしにならない）
test_detect_failure_falls_back_to_full() {
    local td mb mh; _ms_env td mb mh; _det_env 0
    _det_state
    export MOCK_SF_AUDIT_EXIT=1
    SF_METASYNC_DETECT=on _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "検知の失敗: 正常終了"
    assert_output_contains "$_MS_OUT" "履歴の問い合わせに失敗" "検知の失敗: 理由が出る"
    assert_file_contains "$MOCK_CALL_LOG" "sf project retrieve start" "検知の失敗: 全件取得に倒れる"
    _ms_unset; _det_unset; teardown "$td" "$mb"
}

# shadow: 検知が変更なしでも取得する。実際に変更があれば、食い違いの WARNING を出す
test_detect_shadow_reports_mismatch() {
    local td mb mh; _ms_env td mb mh; _det_env 0
    _det_state
    export MOCK_GIT_DIFF_EXIT_2ND=1
    export MOCK_SF_RETRIEVE_FILES='force-app/main/default/classes/New.cls|x'
    SF_METASYNC_DETECT=shadow _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "検知 shadow: 正常終了"
    assert_file_contains "$MOCK_CALL_LOG" "sf project retrieve start" "検知 shadow: 検知が変更なしでも、取得する"
    assert_output_contains "$_MS_OUT" "検知は「変更なし」でしたが、実際は 1 件の変更がありました" "検知 shadow: 食い違いの WARNING が出る"
    assert_output_contains "$_MS_OUT" "A force-app/main/default/classes/New.cls" "検知 shadow: 食い違いの一覧が出る"
    _ms_unset; _det_unset; teardown "$td" "$mb"
}

# 状態ファイルを書いたが、コミットの前に中断（commit の失敗）→ 状態ファイルも戻す
test_detect_state_restored_on_failure() {
    local td mb mh; _ms_env td mb mh; _det_env 0
    export MOCK_GIT_DIFF_EXIT_2ND=1 MOCK_GIT_COMMIT_EXIT=1
    SF_METASYNC_DETECT=on _ms_run 'Y\nY\n'
    assert_exit_fail "$_MS_RC" "commit の失敗 → 中断"
    assert_file_contains "$MOCK_CALL_LOG" "git reset -q HEAD -- sf-tools/metasync/state.json" "中断 → 状態ファイルを、インデックスから外す"
    assert_file_contains "$MOCK_CALL_LOG" "git checkout HEAD -- sf-tools/metasync/state.json" "中断 → 状態ファイルを HEAD に戻す"
    # （HEAD にない状態ファイルが消えること = checkout が失敗したときの rm は、モックの git では確かめられない。結合テストで確かめる）
    _ms_unset; _det_unset; teardown "$td" "$mb"
}

# ------------------------------------------------------------------------------
# 一覧の指紋（SF_METASYNC_FINGERPRINT。設計: doc/sf-metasync-redesign.md 16 章の P1）のテスト
#   Metadata API は、モックのサーバー（tests/mock-soap-server.js）。sf の org display は、そのサーバーの URL とトークンを返す
# ------------------------------------------------------------------------------
# モックのサーバーを起動し、sf のモックが、そのサーバーを指すようにする。結果: FPI_DIR（サーバーのデータ・記録）・FPI_PID
_fpi_start() {
    FPI_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-msfpi-XXXX")
    echo '{"validToken":"TESTTOKEN","lists":{}}' > "$FPI_DIR/data.json"; : > "$FPI_DIR/requests.log"
    node "$SF_TOOLS_DIR/tests/mock-soap-server.js" "$FPI_DIR/data.json" "$FPI_DIR/port.txt" "$FPI_DIR/requests.log" &   # & はバックグラウンド起動（run 不使用の例外）
    FPI_PID=$!
    local i; for i in $(seq 1 100); do [[ -s "$FPI_DIR/port.txt" ]] && break; sleep 0.1; done
    [[ -s "$FPI_DIR/port.txt" ]] || fail "モックの SOAP サーバーが起動しなかった（10 秒待った）"
    trap '_fpi_stop' EXIT   # テストが途中で止まっても、モックのサーバーを残さない
    export MOCK_SF_ORG_JSON="{\"status\":0,\"result\":{\"alias\":\"testorg\",\"id\":\"00D000000000001AAA\",\"accessToken\":\"TESTTOKEN\",\"instanceUrl\":\"http://127.0.0.1:$(cat "$FPI_DIR/port.txt")\"}}"
    export SF_METASYNC_SF="bash $mb/sf"
}
_fpi_stop() {
    [[ -n "${FPI_PID:-}" ]] && { kill "$FPI_PID" 2>/dev/null; wait "$FPI_PID" 2>/dev/null; }
    FPI_PID=""; [[ -n "${FPI_DIR:-}" ]] && rm -rf "$FPI_DIR"
    unset SF_METASYNC_SF SF_METASYNC_FINGERPRINT SF_METASYNC_DETECT MOCK_SF_LIST_DIR MOCK_SF_AUDIT_COUNT
}
# サーバーのデータを書き換える。引数: キー・JSON の値
_fpi_set() {
    node -e 'const fs=require("fs");const f=process.argv[1],k=process.argv[2],v=process.argv[3];const d=JSON.parse(fs.readFileSync(f,"utf8"));d.lists=d.lists||{};d.lists[k]=JSON.parse(v);fs.writeFileSync(f,JSON.stringify(d));' "$FPI_DIR/data.json" "$1" "$2"
}
# 今のサーバーのデータで、指紋の状態（前回の同期の記録）を、あらかじめ作る
#   取得の範囲は、スクリプトと同じもの（metadata.txt。追加の取得は off）を渡す（範囲が違うと、不明になるため）
_fpi_state() {
    mkdir -p "$td/sf-tools/metasync"
    node "$SF_TOOLS_DIR/lib/metasync.js" fingerprint --org prod --fp-config "$SF_TOOLS_DIR/config/metasync-fingerprint.txt" \
        --types-file "$td/sf-tools/config/metadata.txt" \
        --state "$td/none.json" --out-state "$td/sf-tools/metasync/fingerprint.json" --repo "$td" > /dev/null 2>&1
}

# off（既定）: 指紋を作らない（Metadata API を呼ばない）。従来どおり、取得する
test_fp_off_default() {
    local td mb mh; _ms_env td mb mh; _fpi_start
    _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "指紋 off: 正常終了"
    assert_file_contains "$MOCK_CALL_LOG" "sf project retrieve start" "指紋 off: 取得する"
    assert_output_not_contains "$_MS_OUT" "一覧の指紋" "指紋 off: 指紋の出力がない"
    assert_equals "$(wc -l < "$FPI_DIR/requests.log" | tr -d ' ')" "0" "指紋 off: Metadata API を呼ばない"
    [[ ! -f "$td/sf-tools/metasync/fingerprint.json" ]] && pass "指紋 off: 状態ファイルを作らない" || fail "指紋 off: 状態ファイルを作らない"
    _fpi_stop; _ms_unset; teardown "$td" "$mb"
}

# 不正なモード → 中断
test_fp_bad_mode() {
    local td mb mh; _ms_env td mb mh
    SF_METASYNC_FINGERPRINT=maybe _ms_run 'Y\nY\n'
    assert_exit_fail "$_MS_RC" "指紋のモードが不正 → 中断"
    assert_output_contains "$_MS_OUT" "off / shadow / on" "指紋のモードが不正 → 使える値が出る"
    _ms_unset; teardown "$td" "$mb"
}

# shadow・状態なし → 不明 → 取得して、指紋の状態を書いてコミットする（ファイルの変更がなくても、状態だけのコミット。伝播しない）
test_fp_shadow_first_run() {
    local td mb mh; _ms_env td mb mh; _fpi_start
    export MOCK_GIT_DIFF_EXIT_2ND=1
    SF_METASYNC_FINGERPRINT=shadow _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "指紋 shadow・状態なし: 正常終了"
    assert_output_contains "$_MS_OUT" "一覧の指紋を作ります" "指紋 shadow: 指紋を作ると表示される"
    assert_output_contains "$_MS_OUT" "前回の指紋がありません" "指紋 shadow・状態なし: 不明の理由が出る"
    assert_file_contains "$MOCK_CALL_LOG" "sf project retrieve start" "指紋 shadow: 取得は、常に行う（省かない）"
    [[ -f "$td/sf-tools/metasync/fingerprint.json" ]] && pass "指紋 shadow・状態なし: 指紋の状態ファイルを書く" || fail "指紋 shadow・状態なし: 指紋の状態ファイルを書く"
    assert_file_contains "$MOCK_CALL_LOG" "git add -A -- force-app sf-tools/metasync/fingerprint.json" "指紋の状態ファイルも、ステージする（検知の状態ファイルは、別）"
    assert_file_contains "$MOCK_CALL_LOG" "指紋の状態の更新のみ" "メタデータの変更がなければ、コミットの本文に「指紋の状態の更新のみ」と書く"
    assert_output_contains "$_MS_OUT" "指紋の状態ファイルの更新だけのコミットのため、下流ブランチへの伝播は行いません" "状態ファイルの更新だけのコミットは、下流へ伝播しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git merge" "状態ファイルの更新だけのコミットは、merge しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "metasync/state.json" "検知（SF_METASYNC_DETECT）が off なら、検知の状態ファイルは触らない"
    _fpi_stop; _ms_unset; teardown "$td" "$mb"
}

# shadow・指紋は変更なし・実際は変更あり → 見逃しの WARNING。取得・反映は、そのまま行う
test_fp_shadow_miss() {
    local td mb mh; _ms_env td mb mh; _fpi_start
    _fpi_state
    cp "$td/sf-tools/metasync/fingerprint.json" "$td/fp.before"
    export MOCK_GIT_DIFF_EXIT_2ND=1
    export MOCK_SF_RETRIEVE_FILES='force-app/main/default/classes/New.cls|x'
    SF_METASYNC_FINGERPRINT=shadow _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "指紋 shadow・見逃し: 正常終了（同期は続ける）"
    assert_output_contains "$_MS_OUT" "変更なし（すべての種類で、指紋が前回と同じです）" "指紋は、変更なし"
    assert_output_contains "$_MS_OUT" "見逃し 1（1 件）" "影の比較: 見逃しの数が出る"
    assert_output_contains "$_MS_OUT" "指紋の見逃し: classes（指紋の種類: ApexClass）" "影の比較: 見逃しのフォルダと種類が出る"
    assert_output_contains "$_MS_OUT" "A force-app/main/default/classes/New.cls" "影の比較: 見逃しのファイルの例が出る"
    [[ -f "$td/force-app/main/default/classes/New.cls" ]] && pass "指紋 shadow: 取得結果は、そのまま反映する" || fail "指紋 shadow: 取得結果は、そのまま反映する"
    cmp -s "$td/sf-tools/metasync/fingerprint.json" "$td/fp.before" && pass "指紋が変更なしなら、状態ファイルは変わらない" || fail "指紋が変更なしなら、状態ファイルは変わらない"
    assert_file_not_contains "$MOCK_CALL_LOG" "fingerprint.json" "指紋が変更なしなら、状態ファイルをステージしない"
    assert_file_contains "$MOCK_CALL_LOG" "git merge" "メタデータの変更があるときは、下流へ伝播する"
    _fpi_stop; _ms_unset; teardown "$td" "$mb"
}

# 取得の範囲が変わった回（追加の取得を on にした）→ 指紋は不明（初回の取り込みを、見逃しに数えない）
test_fp_scope_change() {
    local td mb mh; _ms_env td mb mh; _fpi_start
    _fpi_state   # 追加の取得なし（off）の範囲で、前回の状態を作る
    export MOCK_GIT_DIFF_EXIT_2ND=1
    export MOCK_SF_RETRIEVE_FILES='force-app/main/default/classes/New.cls|x'
    SF_METASYNC_FINGERPRINT=shadow SF_METASYNC_EXTRA=on _ms_run 'Y\nY\n'
    assert_output_contains "$_MS_OUT" "取得の範囲）が、今回と合いません" "追加の取得を on にした回は、指紋の範囲が合わない"
    assert_output_contains "$_MS_OUT" "指紋が不明（全件取得に倒す回）のため、比べません" "範囲が変わった回は、影の比較をしない（取り込みを見逃しに数えない）"
    assert_output_not_contains "$_MS_OUT" "指紋の見逃し" "範囲が変わった回は、見逃しの WARNING を出さない"
    _fpi_stop; _ms_unset; teardown "$td" "$mb"
}

# shadow・指紋が変わり・実際にも変更あり → 検知できた。状態も更新する
test_fp_shadow_hit() {
    local td mb mh; _ms_env td mb mh; _fpi_start
    _fpi_state
    _fpi_set ApexClass '[{"fullName":"A9","lastModifiedDate":"2026-11-01T09:00:00.000Z"}]'
    export MOCK_GIT_DIFF_EXIT_2ND=1
    export MOCK_SF_RETRIEVE_FILES='force-app/main/default/classes/New.cls|x'
    SF_METASYNC_FINGERPRINT=shadow _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "指紋 shadow・検知できた: 正常終了"
    assert_output_contains "$_MS_OUT" "変更あり（指紋が前回と違う種類 1 個）" "指紋は、変更あり"
    assert_output_contains "$_MS_OUT" "検知できた 1（1 件）/ 見逃し 0（0 件）" "影の比較: 検知できた"
    assert_file_contains "$MOCK_CALL_LOG" "git add -A -- force-app sf-tools/metasync/fingerprint.json" "指紋が変わったら、状態ファイルもステージする"
    assert_file_contains "$MOCK_CALL_LOG" "指紋の状態も更新" "メタデータの変更があるときは、本文に「指紋の状態も更新」と書く"
    _fpi_stop; _ms_unset; teardown "$td" "$mb"
}

# 指紋の失敗（接続できない）は、同期を止めない（WARNING なしでも、取得・反映は続く。状態は書かない）
test_fp_failure_does_not_stop_sync() {
    local td mb mh; _ms_env td mb mh; _fpi_start
    # 使われていないポート（1）に向けて、接続の失敗を再現する（サーバーを止めて空いたポートを狙うと、並列のテストのモックが取ることがある）
    export MOCK_SF_ORG_JSON='{"status":0,"result":{"alias":"testorg","id":"00D000000000001AAA","accessToken":"TESTTOKEN","instanceUrl":"http://127.0.0.1:1"}}'
    export MOCK_GIT_DIFF_EXIT_2ND=1
    export MOCK_SF_RETRIEVE_FILES='force-app/main/default/classes/New.cls|x'
    SF_METASYNC_FINGERPRINT=shadow _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "指紋の失敗: 同期は正常終了する"
    assert_output_contains "$_MS_OUT" "一覧の取得に失敗した種類があります" "指紋の失敗の理由が出る"
    assert_output_contains "$_MS_OUT" "指紋が不明" "指紋が不明のときは、影の比較をしない"
    assert_file_contains "$MOCK_CALL_LOG" "sf project retrieve start" "指紋の失敗でも、取得する"
    [[ -f "$td/force-app/main/default/classes/New.cls" ]] && pass "指紋の失敗でも、取得結果を反映する" || fail "指紋の失敗でも、取得結果を反映する"
    [[ ! -f "$td/sf-tools/metasync/fingerprint.json" ]] && pass "指紋が取れなかったら、状態ファイルを書かない" || fail "指紋が取れなかったら、状態ファイルを書かない"
    _fpi_stop; _ms_unset; teardown "$td" "$mb"
}

# 指紋の状態ファイルを書いたが、コミットの前に中断（commit の失敗）→ 状態ファイルも戻す
test_fp_state_restored_on_failure() {
    local td mb mh; _ms_env td mb mh; _fpi_start
    export MOCK_GIT_DIFF_EXIT_2ND=1 MOCK_GIT_COMMIT_EXIT=1
    SF_METASYNC_FINGERPRINT=shadow _ms_run 'Y\nY\n'
    assert_exit_fail "$_MS_RC" "commit の失敗 → 中断"
    assert_file_contains "$MOCK_CALL_LOG" "git reset -q HEAD -- sf-tools/metasync/fingerprint.json" "中断 → 指紋の状態ファイルを、インデックスから外す"
    assert_file_contains "$MOCK_CALL_LOG" "git checkout HEAD -- sf-tools/metasync/fingerprint.json" "中断 → 指紋の状態ファイルを HEAD に戻す"
    _fpi_stop; _ms_unset; teardown "$td" "$mb"
}

# 検知（SF_METASYNC_DETECT=shadow）と指紋（shadow）を同時に使う: 2 つの状態ファイルを別々に書く
test_fp_with_detect() {
    local td mb mh; _ms_env td mb mh; _fpi_start
    mkdir -p "$td/lists"; export MOCK_SF_LIST_DIR="$td/lists" MOCK_SF_AUDIT_COUNT=0
    export MOCK_GIT_DIFF_EXIT_2ND=1
    SF_METASYNC_DETECT=shadow SF_METASYNC_FINGERPRINT=shadow _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "検知と指紋を同時に使う: 正常終了"
    assert_file_contains "$MOCK_CALL_LOG" "git add -A -- force-app sf-tools/metasync/state.json sf-tools/metasync/fingerprint.json" "2 つの状態ファイルを、どちらもステージする"
    assert_file_contains "$MOCK_CALL_LOG" "検知・指紋の状態の更新のみ" "本文に「検知・指紋の状態の更新のみ」と書く"
    [[ -f "$td/sf-tools/metasync/state.json" && -f "$td/sf-tools/metasync/fingerprint.json" ]] && pass "状態ファイルは、別々に 2 つできる" || fail "状態ファイルは、別々に 2 つできる"
    _fpi_stop; _ms_unset; teardown "$td" "$mb"
}

# 検知 on・指紋 shadow: 検知は「変更なし」、指紋は「変更あり」→ 食い違いの WARNING を出して、取得を省く（指紋の状態は書かない）
test_fp_detect_on_conflict_warning() {
    local td mb mh; _ms_env td mb mh; _det_env 0; _fpi_start
    _det_state; _fpi_state
    cp "$td/sf-tools/metasync/fingerprint.json" "$td/fp.before"
    _fpi_set ApexClass '[{"fullName":"A9","lastModifiedDate":"2026-11-01T09:00:00.000Z"}]'
    SF_METASYNC_DETECT=on SF_METASYNC_FINGERPRINT=shadow _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "検知 on・指紋 shadow・食い違い: 正常終了"
    assert_output_contains "$_MS_OUT" "指紋は『変更あり』ですが、検知は『変更なし』でした" "食い違いの WARNING が出る"
    assert_output_contains "$_MS_OUT" "全件取得を省きました" "検知が変更なしなら、取得を省く"
    assert_file_not_contains "$MOCK_CALL_LOG" "sf project retrieve" "取得しない"
    cmp -s "$td/sf-tools/metasync/fingerprint.json" "$td/fp.before" && pass "取得を省いたときは、指紋の状態ファイルを更新しない" || fail "取得を省いたときは、指紋の状態ファイルを更新しない"
    _fpi_stop; _ms_unset; _det_unset; teardown "$td" "$mb"
}

# 指紋 shadow・--dry-run: 取得して計画を作るだけ。commit・push しない（指紋の状態ファイルも、コミットしない）
test_fp_dry_run() {
    local td mb mh; _ms_env td mb mh; _fpi_start
    export MOCK_SF_RETRIEVE_FILES='force-app/main/default/classes/New.cls|x'
    SF_METASYNC_FINGERPRINT=shadow _ms_run '' --dry-run -y
    assert_exit_ok "$_MS_RC" "指紋 shadow・--dry-run: 正常終了"
    assert_output_contains "$_MS_OUT" "一覧の指紋を作ります" "--dry-run でも、指紋は作る（読み取りのみ）"
    assert_file_not_contains "$MOCK_CALL_LOG" "git commit" "--dry-run: commit しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "fingerprint.json" "--dry-run: 指紋の状態ファイルを、ステージしない"
    _fpi_stop; _ms_unset; teardown "$td" "$mb"
}

# 指紋は変わったが、ファイルの変更はなかった（空振り）→ 空振りを表示し、指紋の状態だけをコミットする
test_fp_changed_but_no_file_change() {
    local td mb mh; _ms_env td mb mh; _fpi_start
    _fpi_state
    _fpi_set ApexClass '[{"fullName":"A9","lastModifiedDate":"2026-11-01T09:00:00.000Z"}]'
    export MOCK_GIT_DIFF_EXIT_2ND=1
    SF_METASYNC_FINGERPRINT=shadow _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "指紋は変更あり・ファイルの変更なし: 正常終了"
    assert_output_contains "$_MS_OUT" "指紋の空振り" "空振り（指紋は変わったが、ファイルの変更はなかった種類）が出る"
    assert_file_contains "$MOCK_CALL_LOG" "指紋の状態の更新のみ" "指紋の状態だけのコミットになる"
    assert_file_not_contains "$MOCK_CALL_LOG" "git merge" "状態だけのコミットは、下流へ伝播しない"
    _fpi_stop; _ms_unset; teardown "$td" "$mb"
}

# ------------------------------------------------------------------------------
# 指紋 on（設計 16 章の P4）: 指紋が「変更なし」なら、取得を省く
# ------------------------------------------------------------------------------
# on・変更なし → 取得を省いて終了（コミット・push・伝播しない）。指紋の状態ファイルは変わらない
test_fp_on_unchanged_skips() {
    local td mb mh; _ms_env td mb mh; _fpi_start
    _fpi_state
    cp "$td/sf-tools/metasync/fingerprint.json" "$td/fp.before"
    SF_METASYNC_FINGERPRINT=on _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "指紋 on・変更なし: 正常終了"
    assert_output_contains "$_MS_OUT" "一覧の指紋の結果、Salesforce 組織側に変更はありませんでした（全件取得を省きました）" "指紋 on・変更なし: 取得を省いたと表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "sf project retrieve" "指紋 on・変更なし: 取得しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git commit" "指紋 on・変更なし: commit しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git push" "指紋 on・変更なし: push しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git merge" "指紋 on・変更なし: 伝播しない"
    cmp -s "$td/sf-tools/metasync/fingerprint.json" "$td/fp.before" && pass "指紋 on・変更なし: 状態ファイルは変わらない" || fail "指紋 on・変更なし: 状態ファイルは変わらない"
    _fpi_stop; _ms_unset; teardown "$td" "$mb"
}

# on・状態なし（不明）→ 全件取得して、指紋の状態を書く
test_fp_on_first_run_retrieves() {
    local td mb mh; _ms_env td mb mh; _fpi_start
    export MOCK_GIT_DIFF_EXIT_2ND=1
    SF_METASYNC_FINGERPRINT=on _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "指紋 on・状態なし: 正常終了"
    assert_file_contains "$MOCK_CALL_LOG" "sf project retrieve start" "指紋 on・状態なし（不明）: 全件取得する"
    [[ -f "$td/sf-tools/metasync/fingerprint.json" ]] && pass "指紋 on・状態なし: 状態ファイルを書く" || fail "指紋 on・状態なし: 状態ファイルを書く"
    assert_output_not_contains "$_MS_OUT" "全件取得を省きました" "指紋 on・状態なし: 取得を省かない"
    _fpi_stop; _ms_unset; teardown "$td" "$mb"
}

# on・変更あり → 全件取得して反映し、指紋の状態を更新する（取得した回は、影の比較も出す）
test_fp_on_changed_retrieves() {
    local td mb mh; _ms_env td mb mh; _fpi_start
    _fpi_state
    cp "$td/sf-tools/metasync/fingerprint.json" "$td/fp.before"
    _fpi_set ApexClass '[{"fullName":"A9","lastModifiedDate":"2026-11-01T09:00:00.000Z"}]'
    export MOCK_GIT_DIFF_EXIT_2ND=1
    export MOCK_SF_RETRIEVE_FILES='force-app/main/default/classes/New.cls|x'
    SF_METASYNC_FINGERPRINT=on _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "指紋 on・変更あり: 正常終了"
    assert_file_contains "$MOCK_CALL_LOG" "sf project retrieve start" "指紋 on・変更あり: 全件取得する"
    [[ -f "$td/force-app/main/default/classes/New.cls" ]] && pass "指紋 on・変更あり: 取得結果を反映する" || fail "指紋 on・変更あり: 取得結果を反映する"
    if cmp -s "$td/sf-tools/metasync/fingerprint.json" "$td/fp.before"; then fail "指紋 on・変更あり: 状態ファイルを更新する"; else pass "指紋 on・変更あり: 状態ファイルを更新する"; fi
    assert_output_contains "$_MS_OUT" "検知できた 1（1 件）" "指紋 on でも、取得した回は影の比較を出す"
    _fpi_stop; _ms_unset; teardown "$td" "$mb"
}

# on・指紋の失敗（接続できない）→ 不明として、全件取得する
test_fp_on_failure_retrieves() {
    local td mb mh; _ms_env td mb mh; _fpi_start
    _fpi_state
    # 使われていないポート（1）に向けて、接続の失敗を再現する
    export MOCK_SF_ORG_JSON='{"status":0,"result":{"alias":"testorg","id":"00D000000000001AAA","accessToken":"TESTTOKEN","instanceUrl":"http://127.0.0.1:1"}}'
    SF_METASYNC_FINGERPRINT=on _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "指紋 on・失敗: 正常終了"
    assert_file_contains "$MOCK_CALL_LOG" "sf project retrieve start" "指紋 on・失敗（不明）: 全件取得する"
    assert_output_not_contains "$_MS_OUT" "全件取得を省きました" "指紋 on・失敗: 取得を省かない"
    _fpi_stop; _ms_unset; teardown "$td" "$mb"
}

# on・変更なしでも、--full・--dry-run・未プッシュのコミットありのときは、取得する
test_fp_on_unchanged_but_forced() {
    local td mb mh; _ms_env td mb mh; _fpi_start
    _fpi_state
    SF_METASYNC_FINGERPRINT=on _ms_run 'Y\nY\n' --full
    assert_exit_ok "$_MS_RC" "指紋 on・変更なし・--full: 正常終了"
    assert_output_contains "$_MS_OUT" "が指定されているため、一覧の指紋の結果にかかわらず" "--full: 省かない理由が出る"   # 先頭の -- は grep のオプションに読まれるため外す
    assert_file_contains "$MOCK_CALL_LOG" "sf project retrieve start" "指紋 on・変更なし・--full: 取得する"
    : > "$MOCK_CALL_LOG"
    SF_METASYNC_FINGERPRINT=on _ms_run '' --dry-run -y
    assert_exit_ok "$_MS_RC" "指紋 on・変更なし・--dry-run: 正常終了"
    assert_file_contains "$MOCK_CALL_LOG" "sf project retrieve start" "指紋 on・変更なし・--dry-run: 取得する"
    assert_file_not_contains "$MOCK_CALL_LOG" "git commit" "指紋 on・--dry-run: commit しない"
    : > "$MOCK_CALL_LOG"
    export MOCK_GIT_REV_LIST_COUNT=2   # 未プッシュのコミットが 2 件
    SF_METASYNC_FINGERPRINT=on _ms_run 'Y\nY\n'
    assert_output_contains "$_MS_OUT" "未プッシュのコミットがあるため、一覧の指紋の結果にかかわらず" "未プッシュあり: 省かない理由が出る"
    assert_file_contains "$MOCK_CALL_LOG" "sf project retrieve start" "指紋 on・変更なし・未プッシュあり: 取得する"
    unset MOCK_GIT_REV_LIST_COUNT
    _fpi_stop; _ms_unset; teardown "$td" "$mb"
}

# 検知 on・指紋 on: 両方が変更なし → 省く ／ 検知は変更なし・指紋は変更あり → 全件取得する
#   （検知 on・指紋 shadow のときは、検知に従って省く。test_fp_detect_on_conflict_warning）
test_fp_on_with_detect_on() {
    local td mb mh; _ms_env td mb mh; _det_env 0; _fpi_start
    _det_state; _fpi_state
    SF_METASYNC_DETECT=on SF_METASYNC_FINGERPRINT=on _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "検知 on・指紋 on・両方変更なし: 正常終了"
    assert_output_contains "$_MS_OUT" "検知と一覧の指紋の結果、Salesforce 組織側に変更はありませんでした" "両方変更なし: 取得を省く"
    assert_file_not_contains "$MOCK_CALL_LOG" "sf project retrieve" "両方変更なし: 取得しない"
    : > "$MOCK_CALL_LOG"
    _fpi_set ApexClass '[{"fullName":"A9","lastModifiedDate":"2026-11-01T09:00:00.000Z"}]'
    SF_METASYNC_DETECT=on SF_METASYNC_FINGERPRINT=on _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "検知 変更なし・指紋 変更あり: 正常終了"
    assert_output_contains "$_MS_OUT" "検知と一覧の指紋の結果が分かれたため" "検知 変更なし・指紋 変更あり: 分かれたと表示される"
    assert_file_contains "$MOCK_CALL_LOG" "sf project retrieve start" "検知 変更なし・指紋 変更あり: 取得する"
    _fpi_stop; _ms_unset; _det_unset; teardown "$td" "$mb"
}

# 検知 on・指紋 on: 検知は変更あり（設定変更の履歴に記録）・指紋は変更なし → 全件取得する（履歴が、指紋の対象外の種類の変更を補う）
test_fp_on_with_detect_on_reverse() {
    local td mb mh; _ms_env td mb mh; _det_env 0; _fpi_start
    _det_state; _fpi_state
    export MOCK_SF_AUDIT_COUNT=1   # 設定変更の履歴に記録あり → 検知は「変更あり」
    SF_METASYNC_DETECT=on SF_METASYNC_FINGERPRINT=on _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "検知 変更あり・指紋 変更なし: 正常終了"
    assert_output_contains "$_MS_OUT" "検知と一覧の指紋の結果が分かれたため" "検知 変更あり・指紋 変更なし: 分かれたと表示される"
    assert_file_contains "$MOCK_CALL_LOG" "sf project retrieve start" "検知 変更あり・指紋 変更なし: 取得する"
    _fpi_stop; _ms_unset; _det_unset; teardown "$td" "$mb"
}

# 検知 shadow・指紋 on: 指紋で決める。検知が「変更あり」でも省き、食い違いの WARNING を出す
test_fp_on_with_detect_shadow() {
    local td mb mh; _ms_env td mb mh; _det_env 0; _fpi_start
    _det_state; _fpi_state
    export MOCK_SF_AUDIT_COUNT=1   # 設定変更の履歴に記録あり → 検知は「変更あり」
    SF_METASYNC_DETECT=shadow SF_METASYNC_FINGERPRINT=on _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "検知 shadow・指紋 on: 正常終了"
    assert_output_contains "$_MS_OUT" "検知は『変更あり』ですが、指紋は『変更なし』でした" "検知 shadow が変更あり: 食い違いの WARNING が出る"
    assert_output_contains "$_MS_OUT" "一覧の指紋の結果、Salesforce 組織側に変更はありませんでした" "検知 shadow は判定に使わず、指紋で省く"
    assert_file_not_contains "$MOCK_CALL_LOG" "sf project retrieve" "検知 shadow・指紋 on・変更なし: 取得しない"
    _fpi_stop; _ms_unset; _det_unset; teardown "$td" "$mb"
}

# ------------------------------------------------------------------------------
# 公開リポジトリの拒否・秘密情報の検査・Slack 通知（設計 16.7。P3）
# ------------------------------------------------------------------------------
_p3_unset() { unset SF_METASYNC_VIS_RETRY_WAIT SF_METASYNC_SECRET_SCAN SLACK_BOT_TOKEN SLACK_CHANNEL_ID MOCK_GH_VISIBILITY MOCK_GH_VISIBILITY_EXIT MOCK_CURL_RESPONSE MOCK_CURL_EXIT; }
_p3_slack() { export SLACK_BOT_TOKEN="xoxb-TESTTOKEN123456" SLACK_CHANNEL_ID="C0TESTCHAN"; }
# 取得結果に、秘密の疑い（AWS のアクセスキーの形）を含むファイルを 1 つ入れる
_p3_leak() { export MOCK_GIT_DIFF_EXIT_2ND=1 MOCK_SF_RETRIEVE_FILES='force-app/main/default/classes/Leak.cls|public class Leak { String t = "AKIAABCDEFGHIJKLMNOP"; }'; }

# private・internal は通る（公開範囲がログに出る）
test_p3_visibility_ok() {
    local td mb mh; _ms_env td mb mh
    export MOCK_GIT_DIFF_EXIT_2ND=1 MOCK_SF_RETRIEVE_FILES='force-app/main/default/classes/New.cls|public class New {}'
    _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "公開範囲 private: 正常終了"
    assert_output_contains "$_MS_OUT" "リポジトリの公開範囲: private" "公開範囲がログに出る"
    assert_file_contains "$MOCK_CALL_LOG" "gh api repos/" "公開範囲は gh api repos/<owner>/<repo> で確認する"
    _ms_unset; _p3_unset; teardown "$td" "$mb"
    local td mb mh; _ms_env td mb mh
    export MOCK_GH_VISIBILITY=internal MOCK_GIT_DIFF_EXIT_2ND=1 MOCK_SF_RETRIEVE_FILES='force-app/main/default/classes/New.cls|public class New {}'
    _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "公開範囲 internal: 正常終了"
    _ms_unset; _p3_unset; teardown "$td" "$mb"
}

# 公開、または確認できない → 取得せずに止める（終了コード 5）。Slack に通知する（dry-run を除く）
test_p3_visibility_public() {
    local td mb mh; _ms_env td mb mh; _p3_slack
    export MOCK_GH_VISIBILITY=public
    _ms_run 'Y\nY\n'
    assert_equals "$_MS_RC" "5" "公開リポジトリ → 終了コード 5"
    assert_output_contains "$_MS_OUT" "リポジトリが公開（public）です" "公開の理由が出る"
    assert_file_not_contains "$MOCK_CALL_LOG" "sf project retrieve" "公開リポジトリ: 取得しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git commit" "公開リポジトリ: コミットしない"
    assert_file_contains "$MOCK_CALL_LOG" "https://slack.com/api/chat.postMessage" "公開リポジトリ: Slack に通知する"
    assert_file_not_contains "$MOCK_CALL_LOG" "xoxb-TESTTOKEN123456" "Slack のトークンは、curl のコマンドラインの引数に出さない（標準入力で渡す）"
    assert_file_contains "$MOCK_CALL_LOG" " -K - " "curl の設定は、標準入力（-K -）から渡す"
    assert_file_contains "$MOCK_CALL_LOG" "取得は行っていません" "通知の本文に、理由が入る"
    assert_output_not_contains "$_MS_OUT" "xoxb-TESTTOKEN123456" "Slack のトークンは、ログに出さない"
    assert_output_contains "$_MS_OUT" "Slack に通知しました" "通知できた旨が出る"
    _ms_unset; _p3_unset; teardown "$td" "$mb"
    # 確認できない（gh の失敗・権限不足）→ 同じく止める
    local td mb mh; _ms_env td mb mh; _p3_slack
    export MOCK_GH_VISIBILITY_EXIT=1 SF_METASYNC_VIS_RETRY_WAIT=0
    _ms_run 'Y\nY\n'
    assert_equals "$_MS_RC" "5" "公開・非公開を確認できない → 終了コード 5"
    assert_equals "$(grep -c 'gh api repos/' "$MOCK_CALL_LOG")" "3" "確認できないときは、3 回まで試す（一時的な API の失敗で止めない）"
    assert_output_contains "$_MS_OUT" "確認できませんでした" "確認できない理由が出る"
    assert_file_not_contains "$MOCK_CALL_LOG" "sf project retrieve" "確認できない: 取得しない"
    _ms_unset; _p3_unset; teardown "$td" "$mb"
    # --dry-run: 止めるが、Slack には通知しない
    local td mb mh; _ms_env td mb mh; _p3_slack
    export MOCK_GH_VISIBILITY=public
    _ms_run '' --dry-run -y
    assert_equals "$_MS_RC" "5" "--dry-run でも、公開リポジトリは止める"
    assert_file_not_contains "$MOCK_CALL_LOG" "slack.com" "--dry-run: Slack に通知しない"
    _ms_unset; _p3_unset; teardown "$td" "$mb"
    # Slack の設定がない → WARNING にとどめて、止める
    local td mb mh; _ms_env td mb mh
    export MOCK_GH_VISIBILITY=public
    _ms_run 'Y\nY\n'
    assert_equals "$_MS_RC" "5" "Slack 未設定でも、公開リポジトリは止める"
    assert_output_contains "$_MS_OUT" "Slack に通知できません" "Slack 未設定の WARNING が出る"
    _ms_unset; _p3_unset; teardown "$td" "$mb"
}

# 検査 shadow（既定）: 疑いを WARNING で出すが、止めない（コミットする）
test_p3_scan_shadow() {
    local td mb mh; _ms_env td mb mh; _p3_slack; _p3_leak
    _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "検査 shadow（既定）: 疑いがあっても、正常終了"
    assert_output_contains "$_MS_OUT" "秘密の疑い: known-token force-app/main/default/classes/Leak.cls" "疑いの規則とパスが出る"
    assert_output_contains "$_MS_OUT" "shadow のため、止めません" "止めない旨が出る"
    assert_output_not_contains "$_MS_OUT" "AKIAABCDEFGHIJKLMNOP" "値（秘密）は、ログに出さない"
    assert_file_contains "$MOCK_CALL_LOG" "git commit" "shadow: コミットする"
    assert_file_not_contains "$MOCK_CALL_LOG" "slack.com" "shadow: Slack には通知しない"
    _ms_unset; _p3_unset; teardown "$td" "$mb"
}

# 検査 on: 疑いがあれば、何もコミットせずに止める（終了コード 4）。Slack に通知する
test_p3_scan_on() {
    local td mb mh; _ms_env td mb mh; _p3_slack; _p3_leak
    SF_METASYNC_SECRET_SCAN=on _ms_run 'Y\nY\n'
    assert_equals "$_MS_RC" "4" "検査 on: 疑いがある → 終了コード 4"
    assert_output_contains "$_MS_OUT" "何もコミット・push せずに止めます" "止める旨が出る"
    assert_output_not_contains "$_MS_OUT" "AKIAABCDEFGHIJKLMNOP" "値（秘密）は、ログに出さない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git commit" "検査 on: コミットしない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git push" "検査 on: push しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git add" "検査 on: ステージしない"
    [[ ! -f "$td/force-app/main/default/classes/Leak.cls" ]] && pass "検査 on: 作業ツリーに、疑わしいファイルを書かない" || fail "検査 on: 作業ツリーに、疑わしいファイルを書かない"
    assert_file_contains "$MOCK_CALL_LOG" "https://slack.com/api/chat.postMessage" "検査 on: Slack に通知する"
    assert_file_contains "$MOCK_CALL_LOG" "known-token  force-app/main/default/classes/Leak.cls" "通知の本文に、規則とパスが入る"
    assert_file_not_contains "$MOCK_CALL_LOG" "AKIAABCDEFGHIJKLMNOP" "通知にも、値（秘密）は入れない"
    assert_output_not_contains "$_MS_OUT" "xoxb-TESTTOKEN123456" "Slack のトークンは、ログに出さない"
    _ms_unset; _p3_unset; teardown "$td" "$mb"
    # Slack 未設定 / 通知の失敗 → WARNING にとどめて、止める
    local td mb mh; _ms_env td mb mh; _p3_leak
    SF_METASYNC_SECRET_SCAN=on _ms_run 'Y\nY\n'
    assert_equals "$_MS_RC" "4" "Slack 未設定でも、疑いがあれば止める"
    assert_output_contains "$_MS_OUT" "Slack に通知できません" "Slack 未設定の WARNING が出る"
    _ms_unset; _p3_unset; teardown "$td" "$mb"
    local td mb mh; _ms_env td mb mh; _p3_slack; _p3_leak
    export MOCK_CURL_RESPONSE='{"ok":false,"error":"invalid_auth"}'
    SF_METASYNC_SECRET_SCAN=on _ms_run 'Y\nY\n'
    assert_equals "$_MS_RC" "4" "Slack の通知が失敗しても、疑いがあれば止める"
    assert_output_contains "$_MS_OUT" "Slack への通知に失敗しました（invalid_auth）" "通知の失敗の理由が出る"
    _ms_unset; _p3_unset; teardown "$td" "$mb"
    # --dry-run: 止めるが、Slack には通知しない
    local td mb mh; _ms_env td mb mh; _p3_slack; _p3_leak
    SF_METASYNC_SECRET_SCAN=on _ms_run '' --dry-run -y
    assert_equals "$_MS_RC" "4" "検査 on・--dry-run: 疑いがあれば、終了コード 4"
    assert_file_not_contains "$MOCK_CALL_LOG" "slack.com" "--dry-run: Slack に通知しない"
    _ms_unset; _p3_unset; teardown "$td" "$mb"
}

# ------------------------------------------------------------------------------
# 追加の取得（SF_METASYNC_EXTRA。設計: doc/sf-metasync-redesign.md 16 章の P2）のテスト
#   名前を集める Metadata API は、モックのサーバー（_fpi_start）。--manifest つきの sf project retrieve は、モックの MOCK_SF_EXTRA_*
# ------------------------------------------------------------------------------
_ex_unset() { unset SF_METASYNC_EXTRA MOCK_SF_EXTRA_FILES MOCK_SF_EXTRA_EXIT MOCK_SF_EXTRA_ERR MOCK_SF_EXTRA_JSON; }
# 通常の取得に、カスタムオブジェクトのファイルを 1 つ入れる（objects を、同期の対象にする）。手元に、標準オブジェクトの項目のファイルを置く
_ex_prep() {
    export MOCK_GIT_DIFF_EXIT_2ND=1
    export MOCK_SF_RETRIEVE_FILES='force-app/main/default/objects/Foo__c/Foo__c.object-meta.xml|<CustomObject/>'
    mkdir -p "$td/force-app/main/default/objects/Account/fields"
    printf 'old\n' > "$td/force-app/main/default/objects/Account/fields/Old__c.field-meta.xml"
}

# off（既定）: 追加の取得をしない（名前を集めない・--manifest の取得をしない）
test_extra_off_default() {
    local td mb mh; _ms_env td mb mh; _fpi_start; _ex_prep
    _ms_run 'Y\nY\n'
    assert_file_not_contains "$MOCK_CALL_LOG" "--manifest" "追加の取得 off: --manifest の取得をしない"
    assert_output_not_contains "$_MS_OUT" "追加の取得: 完了" "追加の取得 off: 追加の取得を行わない"
    assert_equals "$(wc -l < "$FPI_DIR/requests.log" | tr -d ' ')" "0" "追加の取得 off: Metadata API を呼ばない"
    # on で入れた標準オブジェクトの部品は、off に戻した回に消さない（保留して、理由を出す）
    [[ -f "$td/force-app/main/default/objects/Account/fields/Old__c.field-meta.xml" ]] && pass "追加の取得 off: 標準オブジェクトの項目を、削除しない" || fail "追加の取得 off: 標準オブジェクトの項目を、削除しない"
    assert_output_contains "$_MS_OUT" "追加の取得は行わない設定" "追加の取得 off: 保留の理由が出る"
    _fpi_stop; _ms_unset; _ex_unset; teardown "$td" "$mb"
}

test_extra_bad_mode() {
    local td mb mh; _ms_env td mb mh
    SF_METASYNC_EXTRA=maybe _ms_run 'Y\nY\n'
    assert_exit_fail "$_MS_RC" "追加の取得のモードが不正 → 中断"
    assert_output_contains "$_MS_OUT" "off / on" "使える値が出る"
    _ms_unset; _ex_unset; teardown "$td" "$mb"
}

# on・成功: 名前を集め、--manifest で取り、取得結果（reports）を反映する。標準オブジェクトの部品も、組織になければ削除できる
test_extra_on_ok() {
    local td mb mh; _ms_env td mb mh; _fpi_start; _ex_prep
    _fpi_set ReportFolder '[{"fullName":"F1"}]'
    _fpi_set 'Report|F1' '[{"fullName":"F1/R1"},{"fullName":"F1/R2"}]'   # R2 は、一覧にあるが、取得の応答に入らない（取れなかったレポート）
    mkdir -p "$td/force-app/main/default/reports/F1"; printf 'r2\n' > "$td/force-app/main/default/reports/F1/R2.report-meta.xml"
    export MOCK_SF_EXTRA_FILES='force-app/main/default/reports/F1/R1.report-meta.xml|<Report/>'
    SF_METASYNC_EXTRA=on _ms_run 'Y\nY\n'
    [[ -f "$td/force-app/main/default/reports/F1/R2.report-meta.xml" ]] && pass "追加の取得 on: 指定したのに取れなかったレポートは、削除しない（ディスクで確かめて保留）" || fail "追加の取得 on: 指定したのに取れなかったレポートは、削除しない"
    assert_file_contains "$MOCK_CALL_LOG" "--manifest" "追加の取得 on: --manifest で取得する"
    assert_output_contains "$_MS_OUT" "追加の取得: 完了" "追加の取得 on: 完了と出る"
    assert_output_contains "$_MS_OUT" "追加の取得: 反映した" "追加の取得 on: 計画の要約に出る"
    [[ -f "$td/force-app/main/default/reports/F1/R1.report-meta.xml" ]] && pass "追加の取得 on: 取得したレポートが、作業ツリーに入る" || fail "追加の取得 on: 取得したレポートが、作業ツリーに入る"
    [[ ! -f "$td/force-app/main/default/objects/Account/fields/Old__c.field-meta.xml" ]] && pass "追加の取得 on・成功: 組織にない標準オブジェクトの項目は、削除する" || fail "追加の取得 on・成功: 組織にない標準オブジェクトの項目は、削除する"
    assert_file_contains "$FPI_DIR/requests.log" "ReportFolder|" "追加の取得 on: フォルダの一覧を取る"
    _fpi_stop; _ms_unset; _ex_unset; teardown "$td" "$mb"
}

# on・取得の失敗: 同期は続け、標準オブジェクトの部品の削除を保留する（取れなかったものを、削除と取り違えない）
test_extra_retrieve_fails() {
    local td mb mh; _ms_env td mb mh; _fpi_start; _ex_prep
    export MOCK_SF_EXTRA_EXIT=1 MOCK_SF_EXTRA_ERR="boom"
    SF_METASYNC_EXTRA=on SF_METASYNC_RETRY_WAIT=0 _ms_run 'Y\nY\n'
    assert_output_contains "$_MS_OUT" "追加の取得が失敗しました" "追加の取得の失敗が、WARNING で出る"
    assert_output_contains "$_MS_OUT" "追加の取得が失敗または不完全だったため" "削除を保留した旨が、計画の要約に出る"
    [[ -f "$td/force-app/main/default/objects/Account/fields/Old__c.field-meta.xml" ]] && pass "追加の取得が失敗: 標準オブジェクトの項目を、削除しない" || fail "追加の取得が失敗: 標準オブジェクトの項目を、削除しない"
    assert_file_contains "$MOCK_CALL_LOG" "git commit" "追加の取得が失敗でも: 通常の取得の内容は、コミットする（同期は止めない）"
    _fpi_stop; _ms_unset; _ex_unset; teardown "$td" "$mb"
}

# on・名前を集められない（Metadata API に接続できない）: 取得せず、同じく保留
test_extra_manifest_fails() {
    local td mb mh; _ms_env td mb mh; _fpi_start; _ex_prep
    export MOCK_SF_ORG_JSON='{"status":0,"result":{"alias":"testorg","id":"00D000000000001AAA","accessToken":"TESTTOKEN","instanceUrl":"http://127.0.0.1:1"}}'
    SF_METASYNC_EXTRA=on _ms_run 'Y\nY\n'
    assert_output_contains "$_MS_OUT" "名前を集められませんでした" "名前を集められない: WARNING が出る"
    assert_file_not_contains "$MOCK_CALL_LOG" "--manifest" "名前を集められない: --manifest の取得をしない"
    [[ -f "$td/force-app/main/default/objects/Account/fields/Old__c.field-meta.xml" ]] && pass "名前を集められない: 標準オブジェクトの項目を、削除しない" || fail "名前を集められない: 標準オブジェクトの項目を、削除しない"
    _fpi_stop; _ms_unset; _ex_unset; teardown "$td" "$mb"
}

# Actions 上で GH_TOKEN がない（wf-metasync.yml が古い）→ 理由が分かる文言で止める。gh は呼ばない
test_p3_visibility_no_token() {
    local td mb mh; _ms_env td mb mh
    _MS_OUT=$( ( cd "$td" && env -u GH_TOKEN -u GITHUB_TOKEN HOME="$mh" PATH="$mb:$PATH" GITHUB_ACTIONS=true GITHUB_REPOSITORY=tamashimon-org/force-test bash "$SF_TOOLS_DIR/bin/sf-metasync.sh" ) 2>&1 )
    _MS_RC=$?
    assert_equals "$_MS_RC" "5" "Actions で GH_TOKEN がない → 終了コード 5"
    assert_output_contains "$_MS_OUT" "GH_TOKEN が渡されていません" "wf-metasync.yml が古い可能性を案内する"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh api repos/" "GH_TOKEN がないときは、gh を呼ばない"
    _ms_unset; _p3_unset; teardown "$td" "$mb"
}

# Slack の本文の置き換えの書き方（Bash 5.2 以降は、置き換え側を引用しないと & が展開される）が、この Bash でも正しい
test_p3_slack_escape_syntax() {
    local t='a<b>c&d'
    t=${t//&/"&amp;"}; t=${t//</"&lt;"}; t=${t//>/"&gt;"}
    assert_equals "$t" 'a&lt;b&gt;c&amp;d' "Slack の特殊文字（& < >）の置き換えが、この Bash で正しい"
}

# 許可の一覧・検査の失敗・off・不正なモード
test_p3_scan_misc() {
    local td mb mh; _ms_env td mb mh; _p3_slack; _p3_leak
    printf '# 確認済みの誤検知\nknown-token force-app/main/default/classes/*\n' > "$td/sf-tools/config/metasync-secret-allow.txt"
    SF_METASYNC_SECRET_SCAN=on _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "許可の一覧に当たる疑いは、on でも止めない"
    assert_output_contains "$_MS_OUT" "許可済み 1 件" "許可済みの件数が出る"
    assert_file_contains "$MOCK_CALL_LOG" "git commit" "許可された内容は、コミットする"
    _ms_unset; _p3_unset; teardown "$td" "$mb"
    # 検査そのものが失敗（許可の一覧の書式の誤り）: on なら止める（検査していないものを、コミットしない）／ shadow は止めない
    local td mb mh; _ms_env td mb mh; _p3_slack; _p3_leak
    printf 'known-token\n' > "$td/sf-tools/config/metasync-secret-allow.txt"
    SF_METASYNC_SECRET_SCAN=on _ms_run 'Y\nY\n'
    assert_equals "$_MS_RC" "4" "検査 on・検査の失敗 → 終了コード 4 で止める"
    assert_output_contains "$_MS_OUT" "検査していない内容はコミットしない" "検査の失敗の理由が出る"
    assert_output_contains "$_MS_OUT" "の形式が正しくありません" "検査の失敗の原因が出る"
    assert_output_not_contains "$_MS_OUT" "\[ERROR\] \[ERROR\]" "ラベルが二重にならない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git commit" "検査の失敗: コミットしない"
    assert_file_contains "$MOCK_CALL_LOG" "https://slack.com/api/chat.postMessage" "検査の失敗: Slack に通知する（通知なしで止まり続けない）"
    assert_file_contains "$MOCK_CALL_LOG" "検査そのものが失敗しました" "検査の失敗: 通知の本文に、理由が入る"
    _ms_unset; _p3_unset; teardown "$td" "$mb"
    local td mb mh; _ms_env td mb mh; _p3_leak
    printf 'known-token\n' > "$td/sf-tools/config/metasync-secret-allow.txt"
    SF_METASYNC_SECRET_SCAN=shadow _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "検査 shadow・検査の失敗 → 止めない"
    assert_output_contains "$_MS_OUT" "秘密情報の検査に失敗しました" "検査の失敗が WARNING で出る"
    _ms_unset; _p3_unset; teardown "$td" "$mb"
    # off: 検査しない
    local td mb mh; _ms_env td mb mh; _p3_leak
    SF_METASYNC_SECRET_SCAN=off _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "検査 off: 正常終了"
    assert_output_not_contains "$_MS_OUT" "秘密の検査" "検査 off: 検査しない"
    _ms_unset; _p3_unset; teardown "$td" "$mb"
    # 疑いがなければ、on でも通る
    local td mb mh; _ms_env td mb mh
    export MOCK_GIT_DIFF_EXIT_2ND=1 MOCK_SF_RETRIEVE_FILES='force-app/main/default/classes/Safe.cls|public class Safe {}'
    SF_METASYNC_SECRET_SCAN=on _ms_run 'Y\nY\n'
    assert_exit_ok "$_MS_RC" "検査 on・疑いなし: 正常終了"
    assert_output_contains "$_MS_OUT" "疑い 0 件" "疑い 0 件と出る"
    _ms_unset; _p3_unset; teardown "$td" "$mb"
    # 不正なモード
    local td mb mh; _ms_env td mb mh
    SF_METASYNC_SECRET_SCAN=maybe _ms_run 'Y\nY\n'
    assert_exit_fail "$_MS_RC" "検査のモードが不正 → 中断"
    assert_output_contains "$_MS_OUT" "off / shadow / on" "使える値が出る"
    _ms_unset; _p3_unset; teardown "$td" "$mb"
}

test_mirror_basic
test_target_org_resolved_by_org_id
test_target_org_org_id_15_vs_18_chars
test_target_org_actions_uses_prod_alias
test_mirror_deletes
test_retrieve_failure_and_retry
test_dry_run_options
test_allow_mass_delete_on_actions
test_two_package_directories
test_hold_exit_code_3
test_restore_after_apply_on_failure
test_apply_confirm_no_aborts
test_detect_off_default
test_detect_bad_mode
test_detect_on_first_run_writes_state
test_detect_on_unchanged_skips_retrieve
test_detect_on_full_option
test_detect_on_changed_and_dry_run
test_detect_failure_falls_back_to_full
test_detect_shadow_reports_mismatch
test_detect_state_restored_on_failure
test_fp_off_default
test_fp_bad_mode
test_fp_shadow_first_run
test_fp_shadow_miss
test_fp_scope_change
test_fp_shadow_hit
test_fp_failure_does_not_stop_sync
test_fp_state_restored_on_failure
test_fp_with_detect
test_fp_detect_on_conflict_warning
test_fp_dry_run
test_fp_changed_but_no_file_change
test_fp_on_unchanged_skips
test_fp_on_first_run_retrieves
test_fp_on_changed_retrieves
test_fp_on_failure_retrieves
test_fp_on_unchanged_but_forced
test_fp_on_with_detect_on
test_fp_on_with_detect_on_reverse
test_fp_on_with_detect_shadow
test_p3_visibility_ok
test_p3_visibility_public
test_extra_off_default
test_extra_bad_mode
test_extra_on_ok
test_extra_retrieve_fails
test_extra_manifest_fails
test_p3_visibility_no_token
test_p3_slack_escape_syntax
test_p3_scan_shadow
test_p3_scan_on
test_p3_scan_misc

print_summary
