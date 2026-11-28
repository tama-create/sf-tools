#!/bin/bash
# ==============================================================================
# test_sf-refresh.sh - sf-refresh.sh のテスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-refresh.sh ===${CLR_RST}"

# 正常実行 → git pull、マージドライバー登録、npm install が行われる
test_normal_run() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    local out; out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "正常実行 → 終了コード 0"
    assert_file_contains "$MOCK_CALL_LOG" "git -C" "sf-tools の git pull が呼び出された"
    teardown "$td" "$mb" "$mh"
}

# スタンプファイルが新しい（24h以内）→ sf-update-cli.sh がバックグラウンド起動されない
test_upgrade_skipped_within_24h() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    # 1時間前のタイムスタンプでスタンプファイルを作成
    touch -t "$(date -d '1 hour ago' +'%Y%m%d%H%M' 2>/dev/null || date -v -1H +'%Y%m%d%H%M' 2>/dev/null || date +'%Y%m%d%H%M')" "$mh/.sf-tools-last-update" 2>/dev/null \
        || touch "$mh/.sf-tools-last-update"

    local out; out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1)

    assert_output_contains "$out" "スキップ" "24h 以内のためスキップメッセージが表示された"
    teardown "$td" "$mb" "$mh"
}

# スタンプファイルなし（初回）→ sf-update-cli.sh がバックグラウンド起動される
test_upgrade_triggered_on_first_run() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    # スタンプファイルなし（初回実行を再現）
    rm -f "$mh/.sf-tools-last-update"

    cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1 >/dev/null
    sleep 1  # バックグラウンド起動を少し待つ

    assert_file_exists "$mh/.sf-tools-last-update" "スタンプファイルが作成された"
    teardown "$td" "$mb" "$mh"
}

# package.json が存在しない → npm install がスキップされる
test_npm_install_skipped_no_package_json() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    rm -f "$mh/.sf-tools-last-update"  # アップグレードも動かすが npm install のみ確認

    local out; out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1)

    assert_output_contains "$out" "package.json が見つかりません" "package.json なし → npm install スキップメッセージ"
    teardown "$td" "$mb" "$mh"
}

# force-* 以外で実行 → エラー
test_outside_force_dir() {
    local rd mb mh
    rd=$(setup_regular_dir); mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"; mh=$(setup_mock_home)
    create_all_mocks "$mb"

    local out; out=$(cd "$rd" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1)
    local ec=$?

    assert_exit_fail $ec "force-* 外 → エラー終了"
    teardown "$rd" "$mb" "$mh"
}

# SF_INIT_RUNNING=1 の場合 → git pull をスキップ
test_skip_pull_when_sf_init_running() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    local out; out=$(cd "$td" && SF_INIT_RUNNING=1 HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1)

    assert_output_contains "$out" "git pull をスキップ" "SF_INIT_RUNNING=1 → git pull スキップメッセージが表示された"

    grep "git -C" "$MOCK_CALL_LOG" 2>/dev/null | grep -q "pull" \
        && fail "SF_INIT_RUNNING=1 → git pull が呼び出されていない" \
        || pass "SF_INIT_RUNNING=1 → git pull が呼び出されていない"

    teardown "$td" "$mb" "$mh"
}

# sf-hook.sh が呼び出され pre-push フックが生成される
test_hook_installed() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1 >/dev/null

    assert_file_exists "$td/.git/hooks/pre-push" "sf-hook.sh が呼び出され pre-push フックが生成された"
    teardown "$td" "$mb" "$mh"
}

# branch_name.txt とリリースディレクトリが作成される
test_release_dir_created() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    export MOCK_GIT_BRANCH="feature/test"

    cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1 >/dev/null

    assert_file_exists "$td/sf-tools/release/branch_name.txt" "branch_name.txt が作成された"
    assert_dir_exists "$td/sf-tools/release/feature/test" "リリースディレクトリが作成された"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb" "$mh"
}

# main ブランチでは release ディレクトリを作成しない
test_release_dir_skipped_on_main() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    export MOCK_GIT_BRANCH="main"

    cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1 >/dev/null

    assert_dir_exists     "$td/sf-tools/release"           "sf-tools/release/ ベースディレクトリが作成された"
    assert_file_not_exists "$td/sf-tools/release/.gitkeep" ".gitkeep は作らない（2026-11-27 に、作るのをやめた）"
    assert_dir_not_exists "$td/sf-tools/release/main"     "main の release サブディレクトリが作成されない"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb" "$mh"
}

# sf-update-cli.sh が呼び出された（初回実行時）
test_upgrade_called_on_first_run() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    rm -f "$mh/.sf-tools-last-update"

    cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1 >/dev/null
    sleep 2

    grep -q "sf update" "$MOCK_CALL_LOG" \
        && pass "sf-update-cli.sh が呼び出された" \
        || fail "sf-update-cli.sh が呼び出された"
    teardown "$td" "$mb" "$mh"
}

# sf-update-cli.sh が呼び出されない（24h以内）
test_upgrade_not_called_within_24h() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    touch -t "$(date -d '1 hour ago' +'%Y%m%d%H%M' 2>/dev/null || date -v -1H +'%Y%m%d%H%M' 2>/dev/null || date +'%Y%m%d%H%M')" "$mh/.sf-tools-last-update" 2>/dev/null \
        || touch "$mh/.sf-tools-last-update"

    cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1 >/dev/null
    sleep 1

    grep -q "sf update" "$MOCK_CALL_LOG" \
        && fail "sf-update-cli.sh が呼び出されていない（24h以内）" \
        || pass "sf-update-cli.sh が呼び出されていない（24h以内）"
    teardown "$td" "$mb" "$mh"
}

# 前回の sf-update-cli.sh が途中で切れていた（ロックが残り、その PID が動いていない）→ 24 時間以内でも、もう一度動かす
test_upgrade_rerun_when_interrupted() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 途中で切れた更新を「済み」にしない${CLR_RST}"
    local td mb mh out
    setup_std_env td mb mh
    create_all_mocks "$mb"
    touch "$mh/.sf-tools-last-update"   # 24 時間以内
    # 動いていない PID のロック（sleep を起動して終わらせ、その PID を使う）
    local dead; sleep 0 & dead=$!; wait "$dead" 2>/dev/null
    printf 'PID=%s\n' "$dead" > "$mh/.sf-tools-upgrade.lock"
    out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1 >/dev/null)
    sleep 1
    assert_output_contains "$out" "途中で切れていました" "ロックが残り、PID が動いていない → 途中で切れたと表示する"
    assert_file_contains "$td/sf-tools/logs/sf-refresh.log" "開発ツールのアップデートをバックグラウンドで開始します" "24 時間以内でも、もう一度動かす"

    # ロックの PID が動いている（ほかの sf-update-cli.sh が更新中）→ 途中で切れたとは見ない（24 時間以内なら、飛ばす）
    sleep 30 & local alive=$!
    printf 'PID=%s\n' "$alive" > "$mh/.sf-tools-upgrade.lock"
    touch "$mh/.sf-tools-last-update"
    out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1 >/dev/null)
    kill "$alive" 2>/dev/null; wait "$alive" 2>/dev/null
    assert_output_not_contains "$out" "途中で切れていました" "ロックの PID が動いている → 途中で切れたと見ない"
    assert_file_contains "$td/sf-tools/logs/sf-refresh.log" "アップデート済みのためスキップします" "ロックの PID が動いている → 24 時間以内なら飛ばす"

    # PID が生きていても、ロックが 2 時間以上前 → 途中で切れたとみる（PID の使い回し）
    printf 'PID=%s\n' "$$" > "$mh/.sf-tools-upgrade.lock"
    touch -t "$(date -d '3 hours ago' +'%Y%m%d%H%M' 2>/dev/null || date -v -3H +'%Y%m%d%H%M')" "$mh/.sf-tools-upgrade.lock"
    touch "$mh/.sf-tools-last-update"
    out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1 >/dev/null)
    sleep 1
    assert_output_contains "$out" "途中で切れていました" "ロックが 2 時間以上前 → PID が生きていても、途中で切れたとみる"
    teardown "$td" "$mb" "$mh"
}

# deploy-target.txt と remove-target.txt が作成される
test_deploy_remove_target_created() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    export MOCK_GIT_BRANCH="feature/test"

    cd "$td" && SF_INIT_RUNNING=1 HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1 >/dev/null

    assert_file_exists "$td/sf-tools/release/feature/test/deploy-target.txt" "deploy-target.txt が作成された"
    assert_file_exists "$td/sf-tools/release/feature/test/remove-target.txt" "remove-target.txt が作成された"
    if cmp -s "$td/sf-tools/release/feature/test/deploy-target.txt" "$SF_TOOLS_DIR/config/install/release/deploy-target.txt"; then
        pass "deploy-target.txt の中身は config/install/release/ の雛形と同じ"
    else
        fail "deploy-target.txt の中身は config/install/release/ の雛形と同じ" "中身が違う"
    fi
    # README.md（このブランチの作業の資料の入口）も、雛形からコピーする
    if cmp -s "$td/sf-tools/release/feature/test/README.md" "$SF_TOOLS_DIR/config/install/release/README.md"; then
        pass "README.md が、config/install/release/ の雛形と同じ中身で作成された"
    else
        fail "README.md が、config/install/release/ の雛形と同じ中身で作成された" "ない、または中身が違う"
    fi
    assert_file_not_exists "$td/sf-tools/release/.gitkeep" "sf-tools/release/.gitkeep は作らない"
    # すでにある README.md・ターゲットファイルは、上書きしない（書いた内容を消さない）
    printf '自分で書いた内容\n' > "$td/sf-tools/release/feature/test/README.md"
    printf '[files]\nforce-app/main/default/classes/A.cls\n' > "$td/sf-tools/release/feature/test/deploy-target.txt"
    cd "$td" && SF_INIT_RUNNING=1 HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1 >/dev/null
    assert_equals "$(cat "$td/sf-tools/release/feature/test/README.md")" "自分で書いた内容" "すでにある README.md は、上書きしない"
    assert_file_contains "$td/sf-tools/release/feature/test/deploy-target.txt" "classes/A.cls" "すでにある deploy-target.txt は、上書きしない"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb" "$mh"
}

# 決まり: templates/ には、force-* にそのまま置くものだけを入れる（sf-project の Phase 3 が、除外なしで丸ごとコピーするため）。
#   sf-refresh.sh が名前や場所を変えて使うコピー元は、config/install/ に置く。
#   以前は templates/sf-tools/release/__BRANCH__/ と templates/gitmessage に置いていて、force-* に不要な写しが残っていた
test_templates_only_force_files() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] templates/ には force-* にそのまま置くものだけ・コピー元は config/install/${CLR_RST}"
    local f
    for f in config/install/release/deploy-target.txt config/install/release/remove-target.txt config/install/release/README.md config/install/gitmessage; do
        assert_file_exists "$SF_TOOLS_DIR/$f" "コピー元がある: $f"
    done
    # templates/ に、コピー元の写し・仮の名前（__BRANCH__ など、__ で始まるフォルダ）を置かない
    if [[ -e "$SF_TOOLS_DIR/templates/gitmessage" ]]; then
        fail "templates/ に gitmessage を置かない" "templates/gitmessage がある"
    else
        pass "templates/ に gitmessage を置かない"
    fi
    local stray
    stray=$(cd "$SF_TOOLS_DIR/templates" && find . -type d -name '__*' | head -3)  # VAR=$(cmd) のため run 不使用
    if [[ -n "$stray" ]]; then
        fail "templates/ に __ で始まる仮の名前のフォルダを置かない" "$stray"
    else
        pass "templates/ に __ で始まる仮の名前のフォルダを置かない"
    fi
    # templates/ の .gitkeep は、force-app/main/default/.gitkeep の 1 個だけ（新しいプロジェクトは force-app が空で、
    #   sfdx-project.json のフォルダがないと sf CLI が MissingPackageDirectoryError で止まるため、1 個は要る。種類ごとのフォルダの .gitkeep は配らない）
    local keeps
    keeps=$(cd "$SF_TOOLS_DIR/templates" && find . -name .gitkeep | sort | tr '\n' ' ')  # VAR=$(cmd) のため run 不使用
    assert_equals "$keeps" "./force-app/main/default/.gitkeep " "templates/ の .gitkeep は force-app/main/default/.gitkeep の 1 個だけ"
    # sf-refresh.sh が templates/ から読むのは、同じ名前・同じ場所に置く sf-tools/config/ だけ
    local refs
    refs=$(grep -v '^[[:space:]]*#' "$SF_TOOLS_DIR/bin/sf-refresh.sh" | grep -o 'sf-tools/templates/[^"]*' | grep -v '^sf-tools/templates/sf-tools/config/' | head -3)  # VAR=$(cmd) のため run 不使用
    if [[ -n "$refs" ]]; then
        fail "sf-refresh.sh は templates/ をコピー元にしない（sf-tools/config/ を除く）" "$refs"
    else
        pass "sf-refresh.sh は templates/ をコピー元にしない（sf-tools/config/ を除く）"
    fi
}

# .gitmessage が作成され git config に設定される
test_gitmessage_created() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    cd "$td" && SF_INIT_RUNNING=1 HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1 >/dev/null

    assert_file_exists "$td/.gitmessage" ".gitmessage が作成された"
    if cmp -s "$td/.gitmessage" "$SF_TOOLS_DIR/config/install/gitmessage"; then
        pass ".gitmessage の中身は config/install/gitmessage と同じ"
    else
        fail ".gitmessage の中身は config/install/gitmessage と同じ" "中身が違う"
    fi
    assert_file_contains "$MOCK_CALL_LOG" "config commit.template" "git config commit.template が呼び出された"
    teardown "$td" "$mb" "$mh"
}

# release 初期化に失敗 → WARNING が出力される（SUCCESS にならない）
test_release_dir_init_fail() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    export MOCK_GIT_BRANCH="feature/test"
    rm -f "$mh/sf-tools/config/install/release/deploy-target.txt"

    local out; out=$(cd "$td" && SF_INIT_RUNNING=1 HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1)

    assert_output_contains "$out" "リリース管理ディレクトリの準備に失敗" "release 初期化失敗 → WARNING が出力された"
    assert_output_not_contains "$out" "リリース管理ディレクトリの準備が完了" "release 初期化失敗 → SUCCESS ログが出ていない"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb" "$mh"
}

# sf の終了コードが 0 以外（インストーラー版の不具合）→ 警告を表示するが、中断せず、sf-tools の最新化は続行する
test_sf_cli_warning_only() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    local out; out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" MOCK_SF_VERSION_EXIT=1 bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "sf の終了コード 1 → 警告のみで、終了コード 0（中断しない）"
    assert_output_contains "$out" "終了コードが 0 ではありません" "sf の終了コード 1 → 警告が表示された"
    assert_output_contains "$out" "npm install -g @salesforce/cli" "sf の終了コード 1 → npm 版の案内が表示された"
    assert_file_contains "$MOCK_CALL_LOG" "git -C" "sf の終了コード 1 → sf-tools の git pull は、続行される"
    teardown "$td" "$mb" "$mh"
}

# Java が 17 未満（Apex 拡張の要件を満たさない）→ 警告を表示するが、中断せず、sf-tools の最新化は続行する
test_java_old_warning_only() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    local out; out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" MOCK_JAVA_VERSION=11.0.17 bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "Java 11 → 警告のみで、終了コード 0（中断しない）"
    assert_output_contains "$out" "Java 11.0.17 が使われます" "Java 11 → 警告にバージョンが表示された"
    assert_output_contains "$out" "Java 17 以上が必要です" "Java 11 → 17 以上が必要なことが表示された"
    assert_output_contains "$out" "salesforcedx-vscode-apex.java.home" "Java 11 → VS Code の設定の案内が表示された"
    assert_file_contains "$MOCK_CALL_LOG" "git -C" "Java 11 → sf-tools の git pull は、続行される"
    teardown "$td" "$mb" "$mh"
}

# Java が見つからない → 警告を表示するが、中断しない（JAVA_HOME は、テストの読み込み時に外してある。PATH の java が無い状態を作る）
test_java_missing_warning_only() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    rm -f "$mb/java"    # モックの java を消す。ただし、実機に java があれば、そちらが使われるため、PATH に java の無いときだけ検査する

    if PATH="$mb:/usr/bin:/bin" command -v java >/dev/null 2>&1; then  # 条件チェックのため run 不使用
        skip "この環境の /usr/bin か /bin に java があるため、「java が無い」状態を作れない（check_java_cli のテストで検査済み）"
    else
        local out; out=$(cd "$td" && HOME="$mh" PATH="$mb:/usr/bin:/bin" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1)
        local ec=$?
        assert_exit_ok $ec "Java なし → 警告のみで、終了コード 0（中断しない）"
        assert_output_contains "$out" "Java が見つかりません" "Java なし → 警告が表示された"
    fi
    teardown "$td" "$mb" "$mh"
}

# Java が 17 以上 → Java の警告は出ない。SF_TOOLS_SKIP_JAVA_CHECK=1 なら、古くても出ない
test_java_ok_no_warning() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    local out; out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1)
    assert_output_not_contains "$out" "Apex 拡張" "Java 17 → Java の警告は出ない"

    out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" MOCK_JAVA_VERSION=11.0.17 SF_TOOLS_SKIP_JAVA_CHECK=1 bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1)
    assert_output_not_contains "$out" "Apex 拡張" "SF_TOOLS_SKIP_JAVA_CHECK=1 → Java 11 でも警告は出ない"
    teardown "$td" "$mb" "$mh"
}


# sf-project.sh から呼ばれた場合（SF_INIT_RUNNING=1）は、package.json があっても npm install をスキップする
#   （sf-project が、このクローンで行うのは、ファイルの準備とプッシュだけで、node_modules を使わないため。約 90 秒の短縮）
test_npm_install_skipped_when_sf_init_running() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    echo '{"name":"x","version":"1.0.0"}' > "$td/package.json"

    local out; out=$(cd "$td" && SF_INIT_RUNNING=1 HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1)

    assert_output_contains "$out" "npm install をスキップします（sf-project は、ファイルの準備とプッシュだけを行うため）" "sf-project 中 → npm install のスキップメッセージが表示された"
    # 背景で動く sf-update-cli.sh の npm install -g（別のコマンド）と区別するため、引数なしの行だけを見る
    if grep -qx "npm install" "$MOCK_CALL_LOG"; then fail "sf-project 中 → npm install が呼び出されていない" "引数なしの npm install が呼ばれた"; else pass "sf-project 中 → npm install が呼び出されていない"; fi
    teardown "$td" "$mb" "$mh"
}

# 通常の起動（sf-start.sh からなど）では、package.json があれば npm install する
test_npm_install_runs_normally() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    echo '{"name":"x","version":"1.0.0"}' > "$td/package.json"
    rm -f "$td/node_modules/.package-lock.json"

    local out; out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1)

    assert_file_contains "$MOCK_CALL_LOG" "npm install" "通常起動 → npm install が呼び出される"
    teardown "$td" "$mb" "$mh"
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

# 回帰: detached HEAD → リリース管理ディレクトリを作らない（WARNING のみ）
#   以前は、run が返すエラーの文言（fatal: ref HEAD is not a symbolic ref）をブランチ名とし、その名前のフォルダと branch_name.txt を作っていた
test_release_dir_detached_head() {
    local td mb mh out ec
    setup_std_env td mb mh
    create_all_mocks "$mb"
    _fail_git_matching "$mb" "symbolic-ref*" 128 "fatal: ref HEAD is not a symbolic ref"

    out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1); ec=$?
    assert_exit_ok "$ec" "detached HEAD → 終了コード 0（WARNING のみ）"
    assert_output_contains "$out" "現在のブランチ名を取得できませんでした" "detached HEAD → WARNING が表示される"
    assert_file_not_exists "$td/sf-tools/release/branch_name.txt" "detached HEAD → branch_name.txt を作らない"
    if ls "$td/sf-tools/release" 2>/dev/null | grep -q "fatal"; then
        fail "detached HEAD → エラーの文言の名前のフォルダを作らない" "$(ls "$td/sf-tools/release")"
    else
        pass "detached HEAD → エラーの文言の名前のフォルダを作らない"
    fi
    teardown "$td" "$mb" "$mh"
}

# 回帰: gitmessage のテンプレートが無い → WARNING で、設置の完了（SUCCESS）を表示しない（以前は、両方を表示していた）
test_gitmessage_template_missing() {
    local td mb mh out
    setup_std_env td mb mh
    create_all_mocks "$mb"
    rm -f "$mh/sf-tools/config/install/gitmessage"

    out=$(cd "$td" && SF_INIT_RUNNING=1 HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1)
    assert_output_contains "$out" "gitmessage テンプレートが見つかりません" "テンプレートなし → 理由が表示される"
    assert_output_contains "$out" "コミットメッセージテンプレートの設置に失敗しました" "テンプレートなし → 失敗の WARNING が表示される"
    # assert_output_not_contains（grep -v）は、複数行の出力では、ほかの行で成功してしまうため、直接確かめる
    echo "$out" | grep -q "コミットメッセージテンプレートの設置が完了しました" \
        && fail "テンプレートなし → 完了と表示しない" "完了と表示した" \
        || pass "テンプレートなし → 完了と表示しない"
    teardown "$td" "$mb" "$mh"
}

# 回帰: git config commit.template が失敗 → 設置の完了を表示しない（以前は、戻り値を見ていなかった）
test_gitmessage_config_fail() {
    local td mb mh out
    setup_std_env td mb mh
    create_all_mocks "$mb"
    _fail_git_matching "$mb" "config*commit.template*" 1 "error: could not lock config file"

    out=$(cd "$td" && SF_INIT_RUNNING=1 HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-refresh.sh" 2>&1)
    assert_output_contains "$out" "コミットメッセージテンプレートの設置に失敗しました" "git config の失敗 → 失敗の WARNING が表示される"
    echo "$out" | grep -q "コミットメッセージテンプレートの設置が完了しました" \
        && fail "git config の失敗 → 完了と表示しない" "完了と表示した" \
        || pass "git config の失敗 → 完了と表示しない"
    teardown "$td" "$mb" "$mh"
}

test_normal_run
test_templates_only_force_files
test_release_dir_detached_head
test_gitmessage_template_missing
test_gitmessage_config_fail
test_npm_install_skipped_when_sf_init_running
test_npm_install_runs_normally
test_sf_cli_warning_only
test_java_old_warning_only
test_java_missing_warning_only
test_java_ok_no_warning
test_gitmessage_created
test_upgrade_skipped_within_24h
test_upgrade_triggered_on_first_run
test_upgrade_called_on_first_run
test_upgrade_not_called_within_24h
test_upgrade_rerun_when_interrupted
test_npm_install_skipped_no_package_json
test_outside_force_dir
test_skip_pull_when_sf_init_running
test_hook_installed
test_release_dir_created
test_deploy_remove_target_created
test_release_dir_init_fail

print_summary
