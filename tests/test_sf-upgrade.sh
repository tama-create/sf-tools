#!/bin/bash
# ==============================================================================
# test_sf-upgrade.sh - sf-upgrade.sh のテスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-upgrade.sh ===${CLR_RST}"

# 正常実行 → npm / sf / git が呼び出される
test_normal_run() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    # npm は古い版（10.0.0）→ 最新の版（11.0.0）がある状態にする（npm の更新が呼び出される）
    local out; out=$(cd "$td" && PATH="$mb:$PATH" MOCK_NPM_VERSION=10.0.0 MOCK_NPM_LATEST=11.0.0 bash "$SF_TOOLS_DIR/bin/sf-upgrade.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "正常実行 → 終了コード 0"
    assert_output_contains "$out" "すべてのアップデートが完了しました" "失敗がなければ、完了のメッセージを表示する"
    assert_output_not_contains "$out" "更新できなかったものがあります" "失敗がなければ、失敗の一覧は出さない"
    assert_file_contains "$MOCK_CALL_LOG" "npm install" "npm が呼び出された"
    assert_file_contains "$MOCK_CALL_LOG" "sf update" "sf update が呼び出された"
    # Windows の Git Bash だけで実行される（sf-upgrade.sh の is_gitbash と同じ判定。Linux・WSL・macOS では、実行されない）
    if [[ "$OSTYPE" == "msys"* || "$OSTYPE" == "mingw"* || "$OSTYPE" == "cygwin"* ]]; then
        assert_file_contains "$MOCK_CALL_LOG" "git update-git-for-windows" "git update が呼び出された"
    else
        skip "git update が呼び出された（Windows の Git Bash 専用コマンドのためスキップ）"
    fi
    teardown "$td" "$mb"
}

# npm が存在しない → WARNING で続行、正常終了
test_no_npm() {
    local td mb mh
    setup_std_env td mb mh
    # npm モックを作成しない（PATH に npm が存在しない状態）
    # システムの npm がヒットしないよう PATH をモックビンと基本コマンドのみに制限する
    create_mock_git "$mb"
    create_mock_sf "$mb"
    create_mock_code "$mb"

    local out; out=$(cd "$td" && PATH="$mb:/usr/bin:/bin" bash "$SF_TOOLS_DIR/bin/sf-upgrade.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "npm なし → 正常終了（続行）"
    assert_output_contains "$out" "WARNING" "WARNING ログが出力された"
    assert_output_contains "$out" "更新できなかったものがあります: npm" "npm がないとき、失敗の一覧に npm が出る（成功とは言わない）"
    assert_output_not_contains "$out" "すべてのアップデートが完了しました" "npm がないとき、完了のメッセージは出さない"
    teardown "$td" "$mb"
}

# sf が存在しない → WARNING で続行、正常終了
test_no_sf() {
    local td mb mh
    setup_std_env td mb mh
    # sf モックを作成しない（PATH に sf が存在しない状態）
    # システムの sf がヒットしないよう PATH をモックビンと基本コマンドのみに制限する
    create_mock_git "$mb"
    create_mock_npm "$mb"
    create_mock_code "$mb"

    # npm は最新の状態にする（版を出さないモックだと、npm も失敗に数えられ、一覧が「npm、Salesforce CLI」になる）
    local out; out=$(cd "$td" && PATH="$mb:/usr/bin:/bin" MOCK_NPM_VERSION=11.0.0 MOCK_NPM_LATEST=11.0.0 bash "$SF_TOOLS_DIR/bin/sf-upgrade.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "sf なし → 正常終了（続行）"
    assert_output_contains "$out" "WARNING" "WARNING ログが出力された"
    assert_output_contains "$out" "更新できなかったものがあります: Salesforce CLI" "sf がないとき、失敗の一覧に Salesforce CLI が出る"
    assert_output_not_contains "$out" "すべてのアップデートが完了しました" "sf がないとき、完了のメッセージは出さない"
    teardown "$td" "$mb"
}

# git update-git-for-windows は npm・sf の後に実行される（順序確認）
test_git_update_is_last() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    cd "$td" && PATH="$mb:$PATH" MOCK_NPM_VERSION=10.0.0 MOCK_NPM_LATEST=11.0.0 bash "$SF_TOOLS_DIR/bin/sf-upgrade.sh" 2>&1 >/dev/null

    local npm_line sf_line git_line
    npm_line=$(grep -n "npm install" "$MOCK_CALL_LOG" | head -1 | cut -d: -f1)
    sf_line=$(grep -n "sf update" "$MOCK_CALL_LOG" | head -1 | cut -d: -f1)
    git_line=$(grep -n "git update-git-for-windows" "$MOCK_CALL_LOG" | head -1 | cut -d: -f1)

    if [[ "$OSTYPE" != "msys"* && "$OSTYPE" != "mingw"* && "$OSTYPE" != "cygwin"* ]]; then
        skip "git update は npm・sf の後に実行された（Windows の Git Bash 専用コマンドのためスキップ）"
    elif [[ -n "$npm_line" && -n "$sf_line" && -n "$git_line" ]] \
        && [[ $npm_line -lt $git_line && $sf_line -lt $git_line ]]; then
        pass "git update は npm・sf の後に実行された"
    else
        fail "git update は npm・sf の後に実行された" "npm:$npm_line sf:$sf_line git:$git_line"
    fi
    teardown "$td" "$mb"
}

# Git Bash（$OSTYPE が msys / mingw / cygwin）では、Git のアップデートが実行される
# （$OSTYPE は bash が起動時に設定するため、環境変数では差し替えられない。bash -c の中で設定して、スクリプトを読み込む）
test_git_update_on_gitbash() {
    local td mb mh t
    for t in msys cygwin; do
        setup_std_env td mb mh
        create_all_mocks "$mb"
        (cd "$td" && PATH="$mb:$PATH" bash -c "OSTYPE=${t}; source '$SF_TOOLS_DIR/bin/sf-upgrade.sh'") > /dev/null 2>&1
        assert_file_contains "$MOCK_CALL_LOG" "git update-git-for-windows" "OSTYPE=${t}（Git Bash）でも、Git のアップデートが実行される"
        teardown "$td" "$mb"
    done
}

# sf が npm 版（npm ls -g @salesforce/cli が成功）→ npm で更新し、sf update は使わない
test_npm_sf_updated_by_npm() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    (cd "$td" && PATH="$mb:$PATH" MOCK_NPM_LS_EXIT=0 bash "$SF_TOOLS_DIR/bin/sf-upgrade.sh") > /dev/null 2>&1
    assert_file_contains     "$MOCK_CALL_LOG" "npm install -g @salesforce/cli@latest" "npm 版 → npm install -g @salesforce/cli@latest で更新する"
    assert_file_not_contains "$MOCK_CALL_LOG" "sf update" "npm 版 → sf update は使わない"
    teardown "$td" "$mb"
}

# sf が npm 版ではない（公式インストーラー・pkg など）→ sf update で更新する
test_non_npm_sf_updated_by_sf_update() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    (cd "$td" && PATH="$mb:$PATH" MOCK_NPM_LS_EXIT=1 bash "$SF_TOOLS_DIR/bin/sf-upgrade.sh") > /dev/null 2>&1
    assert_file_contains     "$MOCK_CALL_LOG" "sf update" "npm 版ではない → sf update で更新する"
    assert_file_not_contains "$MOCK_CALL_LOG" "npm install -g @salesforce/cli" "npm 版ではない → npm で sf を更新しない"
    teardown "$td" "$mb"
}

# npm が最新（現在の版 = 最新の版）→ npm は更新しない
test_npm_up_to_date() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" MOCK_NPM_VERSION=11.0.0 MOCK_NPM_LATEST=11.0.0 bash "$SF_TOOLS_DIR/bin/sf-upgrade.sh" 2>&1)
    assert_output_contains "$out" "npm は最新です" "npm が最新 → 「最新です」と表示する"
    assert_file_not_contains "$MOCK_CALL_LOG" "npm install -g npm@latest" "npm が最新 → 更新しない"
    teardown "$td" "$mb"
}

# npm に新しい版があり、今の Node で入る → 更新する
test_npm_updated_when_compatible() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" MOCK_NPM_VERSION=10.0.0 MOCK_NPM_LATEST=11.0.0 bash "$SF_TOOLS_DIR/bin/sf-upgrade.sh" 2>&1)
    assert_file_not_contains "$MOCK_CALL_LOG" "--dry-run" "新しい版がある → --dry-run の試し打ちはしない（npm 12 では、これだけが壊れる）"
    if grep -F "npm install -g npm@latest" "$MOCK_CALL_LOG" | grep -vqF -- "--dry-run"; then
        pass "新しい版がある → npm install -g npm@latest で更新する"
    else
        fail "新しい版がある → npm install -g npm@latest で更新する" "更新の呼び出しがない"
    fi
    assert_output_contains "$out" "npm を更新しました" "更新できた → SUCCESS を表示する"
    assert_output_not_contains "$out" "更新できなかったものがあります" "更新できた → 失敗の一覧は出ない"
    teardown "$td" "$mb"
}

# npm 12 の不具合（npm/cli#9800）の再現: --dry-run だけが EALLOWREMOTE で失敗し、本番の更新は成功する。
# --dry-run を使っていたころは、この組み合わせで、毎回「npm のアップデートに失敗しました」と出ていた（Mac・Node 26・npm 12 で発覚）
test_npm12_dryrun_broken() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" MOCK_NPM_VERSION=12.2.0 MOCK_NPM_LATEST=12.2.1 \
        MOCK_NPM_DRYRUN_EXIT=1 MOCK_NPM_DRYRUN_OUT="npm error code EALLOWREMOTE" \
        bash "$SF_TOOLS_DIR/bin/sf-upgrade.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "npm 12 の --dry-run の不具合 → 正常終了"
    assert_output_contains "$out" "npm を更新しました" "npm 12 の --dry-run の不具合 → 本番の更新は成功する"
    assert_output_not_contains "$out" "npm のアップデートに失敗しました" "npm 12 の --dry-run の不具合 → 失敗と表示しない"
    assert_output_not_contains "$out" "更新できなかったものがあります" "npm 12 の --dry-run の不具合 → 失敗の一覧は出ない"
    teardown "$td" "$mb"
}

# npm の最新版が、今の Node では入らない → 更新せず、Node の更新を案内する（失敗には数えない）
test_npm_node_incompatible() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    # 本番の npm install -g npm@latest が、npm の出力（実機で確認した形）で止まる。npm は何も変えない
    local out; out=$(cd "$td" && PATH="$mb:$PATH" MOCK_NPM_VERSION=10.0.0 MOCK_NPM_LATEST=12.0.0 \
        MOCK_NPM_SELF_EXIT=1 MOCK_NPM_SELF_OUT=$'npm error code EBADENGINE\nnpm error notsup Not compatible with your version of node/npm: npm@12.0.0' \
        bash "$SF_TOOLS_DIR/bin/sf-upgrade.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "Node が対応していない → 正常終了"
    assert_output_contains "$out" "では入れられません" "Node が対応していない → 入れられない旨を案内する"
    assert_output_contains "$out" "Node を更新してください" "Node が対応していない → Node の更新を案内する"
    assert_output_not_contains "$out" "npm のアップデートに失敗しました" "Node が対応していない → 失敗と表示しない"
    assert_output_not_contains "$out" "更新できなかったものがあります" "Node が対応していないのは、失敗に数えない"
    teardown "$td" "$mb"
}

# 対応外以外の理由で、npm の更新が失敗 → WARNING に理由（npm の出力の末尾 5 行）と、失敗の一覧に npm
test_npm_update_other_error() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" MOCK_NPM_VERSION=10.0.0 MOCK_NPM_LATEST=11.0.0 \
        MOCK_NPM_SELF_EXIT=1 MOCK_NPM_SELF_OUT=$'npm error line1-old\nnpm error line2\nnpm error line3\nnpm error line4\nnpm error line5\nnpm error code ENETUNREACH' \
        bash "$SF_TOOLS_DIR/bin/sf-upgrade.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "更新の失敗 → 正常終了（続行）"
    assert_output_contains "$out" "npm のアップデートに失敗しました" "更新が失敗 → WARNING を表示する"
    assert_output_contains "$out" "ENETUNREACH" "更新が失敗 → 理由（npm の出力）を表示する"
    assert_output_not_contains "$out" "line1-old" "更新が失敗 → 理由は、末尾の 5 行だけ（それより前は出さない）"
    assert_output_contains "$out" "更新できなかったものがあります: npm" "更新が失敗 → 失敗の一覧に npm が出る"
    teardown "$td" "$mb"
}

# npm の版を確認できない → WARNING と、失敗の一覧に npm
test_npm_version_unknown() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-upgrade.sh" 2>&1)   # モックの既定: 版を出力しない
    assert_output_contains "$out" "npm の版を確認できませんでした" "版を確認できない → WARNING を表示する"
    assert_output_contains "$out" "更新できなかったものがあります: npm" "版を確認できない → 失敗の一覧に npm が出る"
    teardown "$td" "$mb"
}

# sf の更新（npm 版）が失敗 → WARNING と、失敗の一覧に Salesforce CLI。完了とは言わず、終了コードは 0
test_sf_update_failure_summary() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" MOCK_NPM_LS_EXIT=0 MOCK_NPM_EXIT=1 MOCK_NPM_VERSION=11.0.0 MOCK_NPM_LATEST=11.0.0 \
        bash "$SF_TOOLS_DIR/bin/sf-upgrade.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "sf の更新が失敗 → 終了コード 0（呼び出し元を止めない）"
    assert_output_contains "$out" "Salesforce CLI のアップデートに失敗しました" "sf の更新が失敗 → WARNING を表示する"
    assert_output_contains "$out" "更新できなかったものがあります: Salesforce CLI" "sf の更新が失敗 → 失敗の一覧に Salesforce CLI が出る"
    assert_output_not_contains "$out" "すべてのアップデートが完了しました" "sf の更新が失敗 → 完了のメッセージは出さない"
    teardown "$td" "$mb"
}

# 失敗が複数 → 名前が全部並ぶ
test_failure_summary_lists_all() {
    local td mb mh
    setup_std_env td mb mh
    create_mock_git "$mb"
    create_mock_code "$mb"
    # npm も sf もない（PATH に存在しない）

    local out; out=$(cd "$td" && PATH="$mb:/usr/bin:/bin" bash "$SF_TOOLS_DIR/bin/sf-upgrade.sh" 2>&1)
    assert_output_contains "$out" "更新できなかったものがあります: npm、Salesforce CLI" "失敗が複数 → 名前が全部並ぶ"
    teardown "$td" "$mb"
}

# sf の更新が失敗し、npm の置き場所に書き込めない → その旨の WARNING を表示する
test_prefix_unwritable_hint() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    local ro="$td/ro-prefix"
    mkdir -p "$ro" && chmod 555 "$ro"
    if ( : > "$ro/.t" ) 2>/dev/null; then
        # root・Windows など、フォルダの権限で書き込みを止められない環境
        rm -f "$ro/.t"
        skip "置き場所に書き込めない旨の案内（この環境では、書き込めないフォルダを作れないためスキップ）"
    else
        local out; out=$(cd "$td" && PATH="$mb:$PATH" MOCK_NPM_LS_EXIT=0 MOCK_NPM_EXIT=1 MOCK_NPM_VERSION=11.0.0 MOCK_NPM_LATEST=11.0.0 \
            MOCK_NPM_PREFIX="$ro" bash "$SF_TOOLS_DIR/bin/sf-upgrade.sh" 2>&1)
        assert_output_contains "$out" "に書き込めません" "置き場所に書き込めない → その旨の WARNING を表示する"
    fi
    chmod 755 "$ro"
    teardown "$td" "$mb"
}

# sf の更新が失敗しても、置き場所に書き込めるなら、書き込めない旨の案内は出さない
test_prefix_writable_no_hint() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    local rw="$td/rw-prefix"; mkdir -p "$rw"
    local out; out=$(cd "$td" && PATH="$mb:$PATH" MOCK_NPM_LS_EXIT=0 MOCK_NPM_EXIT=1 MOCK_NPM_VERSION=11.0.0 MOCK_NPM_LATEST=11.0.0 \
        MOCK_NPM_PREFIX="$rw" bash "$SF_TOOLS_DIR/bin/sf-upgrade.sh" 2>&1)
    assert_output_not_contains "$out" "に書き込めません" "置き場所に書き込める → 書き込めない旨の案内は出さない"
    teardown "$td" "$mb"
}

test_normal_run
test_no_npm
test_no_sf
test_git_update_is_last
test_git_update_on_gitbash
test_npm_sf_updated_by_npm
test_non_npm_sf_updated_by_sf_update
test_npm_up_to_date
test_npm_updated_when_compatible
test_npm12_dryrun_broken
test_npm_node_incompatible
test_npm_update_other_error
test_npm_version_unknown
test_sf_update_failure_summary
test_failure_summary_lists_all
test_prefix_unwritable_hint
test_prefix_writable_no_hint

print_summary
