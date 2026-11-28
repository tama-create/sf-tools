#!/bin/bash
# ==============================================================================
# test_sf-start.sh - sf-start.sh のテスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-start.sh ===${CLR_RST}"

# 接続済みの場合 → ログインスキップ、VS Code が起動される
test_connected_org() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    mkdir -p "$mh/sf-tools/bin" "$mh/sf-tools/phases/start"
    printf '#!/bin/bash\necho "launcher called" >> "%s"\n' "$MOCK_CALL_LOG" > "$mh/sf-tools/phases/start/launcher.sh"
    chmod +x "$mh/sf-tools/phases/start/launcher.sh"

    # 接続済みを示す設定ファイルを用意
    echo '{"target-org":"testorg"}' > "$td/.sf/config.json"
    # sf org display が接続済みの JSON を返すよう設定
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-start.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "接続済み → 終了コード 0"
    assert_file_contains "$MOCK_CALL_LOG" "code ." "VS Code が起動された"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb" "$mh"
}

# 未接続で、標準入力が閉じている（EOF）→ エイリアスの入力を、無限に繰り返さず、中断する
#   結合テスト X5-3 で見つかった: 以前は、EOF でも、空の入力を、無限に繰り返した
test_alias_prompt_eof_aborts() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    mkdir -p "$mh/sf-tools/bin" "$mh/sf-tools/phases/start"
    printf '#!/bin/bash\nexit 0\n' > "$mh/sf-tools/phases/start/launcher.sh"
    chmod +x "$mh/sf-tools/phases/start/launcher.sh"
    rm -f "$td/.sf/config.json"    # 初回起動（未接続）→ エイリアスの入力になる
    source "$SF_TOOLS_DIR/lib/platform.sh"   # run_with_timeout（時間の上限つき実行）

    local out; out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" run_with_timeout 20 bash "$SF_TOOLS_DIR/bin/sf-start.sh" < /dev/null 2>&1)
    local ec=$?

    assert_exit_fail $ec "EOF → 中断する（無限に繰り返さない。時間切れ 124 ではない）"
    [[ $ec -ne 124 ]] && pass "EOF → 時間切れにならない" || fail "EOF → 時間切れにならない" "終了コード 124（入力を繰り返し続けた）"
    [[ "$out" == *"入力が中断されました"* ]] && pass "EOF → 理由が表示される" || fail "EOF → 理由が表示される" "$(echo "$out" | tail -4)"
    teardown "$td" "$mb" "$mh"
}

# 接続済みの場合 → VS Code の設定ファイルが書き込まれる
test_config_files_written() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    mkdir -p "$mh/sf-tools/bin" "$mh/sf-tools/phases/start"
    printf '#!/bin/bash\nexit 0\n' > "$mh/sf-tools/phases/start/launcher.sh"
    chmod +x "$mh/sf-tools/phases/start/launcher.sh"

    echo '{"target-org":"testorg"}' > "$td/.sf/config.json"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-start.sh" 2>&1 >/dev/null

    assert_file_exists "$td/.sf/config.json" ".sf/config.json が書き込まれた"
    assert_file_exists "$td/.sfdx/sfdx-config.json" ".sfdx/sfdx-config.json が書き込まれた"
    assert_file_contains "$td/.sf/config.json" "testorg" "正しい org alias が設定された"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb" "$mh"
}

# FORCE_RELOGIN=1 → 接続済みでも強制ログインフローに入る
test_force_relogin() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    mkdir -p "$mh/sf-tools/bin" "$mh/sf-tools/phases/start"
    printf '#!/bin/bash\nexit 0\n' > "$mh/sf-tools/phases/start/launcher.sh"
    chmod +x "$mh/sf-tools/phases/start/launcher.sh"

    echo '{"target-org":"testorg"}' > "$td/.sf/config.json"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    # ORG_ALIAS 入力をシミュレートするため stdin に与える
    # 入力: エイリアス → ログイン先（Enter = Sandbox）
    local out; out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" FORCE_RELOGIN=1 \
        bash "$SF_TOOLS_DIR/bin/sf-start.sh" <<< $'testorg\n\n' 2>&1)
    local ec=$?

    assert_file_contains "$MOCK_CALL_LOG" "sf org login" "FORCE_RELOGIN=1 → ログインが呼び出された"
    assert_file_contains "$MOCK_CALL_LOG" "--instance-url https://test.salesforce.com" "Enter → Sandbox（test.salesforce.com）でログインする"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb" "$mh"
}

# 回帰: ログインに失敗したら、先へ進まない（以前は、警告だけで「接続完了」と表示し、設定ファイルも書いていた）
test_login_failure_aborts() {
    local td mb mh out ec
    setup_std_env td mb mh
    create_all_mocks "$mb"
    mkdir -p "$mh/sf-tools/bin" "$mh/sf-tools/phases/start"
    printf '#!/bin/bash
echo LAUNCHER-RAN >> "%s/launcher.log"
exit 0
' "$mb" > "$mh/sf-tools/phases/start/launcher.sh"
    chmod +x "$mh/sf-tools/phases/start/launcher.sh"
    rm -f "$td/.sf/config.json" "$td/.sfdx/sfdx-config.json"

    out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" MOCK_SF_LOGIN_WEB_FAIL=1         bash "$SF_TOOLS_DIR/bin/sf-start.sh" <<< $'failorg

' 2>&1)
    ec=$?

    assert_exit_fail "$ec" "ログインに失敗 → エラー終了"
    assert_output_contains "$out" "Salesforce へのログインに失敗しました" "ログインに失敗 → 理由が表示される"
    echo "$out" | grep -q "接続完了"         && fail "ログインに失敗 → 「接続完了」と表示しない" "表示された"         || pass "ログインに失敗 → 「接続完了」と表示しない"
    assert_file_not_exists "$td/.sf/config.json" "ログインに失敗 → 設定ファイル（.sf/config.json）を書かない"
    assert_file_not_exists "$mb/launcher.log" "ログインに失敗 → ランチャーを起動しない"
    teardown "$td" "$mb" "$mh"
}

# ログイン先は、エイリアスの名前では決めない（alias が prod でも、選択した URL でログインする）
test_login_url_not_by_alias() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    mkdir -p "$mh/sf-tools/bin" "$mh/sf-tools/phases/start"
    printf '#!/bin/bash\nexit 0\n' > "$mh/sf-tools/phases/start/launcher.sh"
    chmod +x "$mh/sf-tools/phases/start/launcher.sh"
    echo '{"target-org":"x"}' > "$td/.sf/config.json"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"x","id":"00D000000000001AAA"}}'

    # alias = prod で、Enter（Sandbox）→ test.salesforce.com（従来は、prod なら、login.salesforce.com だった）
    : > "$MOCK_CALL_LOG"
    (cd "$td" && HOME="$mh" PATH="$mb:$PATH" FORCE_RELOGIN=1 bash "$SF_TOOLS_DIR/bin/sf-start.sh" <<< $'prod\n\n') > /dev/null 2>&1
    assert_file_contains "$MOCK_CALL_LOG" "--alias prod --instance-url https://test.salesforce.com" "alias が prod でも、選んだ URL（Sandbox）でログインする"
    # alias = sbx で、1（login.salesforce.com）→ login.salesforce.com（Developer Edition や別名の本番）
    : > "$MOCK_CALL_LOG"
    (cd "$td" && HOME="$mh" PATH="$mb:$PATH" FORCE_RELOGIN=1 bash "$SF_TOOLS_DIR/bin/sf-start.sh" <<< $'devorg\n1\n') > /dev/null 2>&1
    assert_file_contains "$MOCK_CALL_LOG" "--alias devorg --instance-url https://login.salesforce.com" "別名でも、1 を選べば、login.salesforce.com でログインする"
    # 環境変数での指定（質問しない）
    : > "$MOCK_CALL_LOG"
    (cd "$td" && HOME="$mh" PATH="$mb:$PATH" FORCE_RELOGIN=1 SF_INIT_LOGIN_URL_START=login bash "$SF_TOOLS_DIR/bin/sf-start.sh" <<< $'a1\n') > /dev/null 2>&1
    assert_file_contains "$MOCK_CALL_LOG" "--alias a1 --instance-url https://login.salesforce.com" "SF_INIT_LOGIN_URL_START=login → 質問せずに指定できる"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb" "$mh"
}

# sf-start.sh → メニュー（phases/start/launcher.sh）が呼ばれる
# AI 向けの案内（CLAUDE.md・AGENTS.md の、手順書を指す行）がなければ、WARNING で知らせる（書き換えない）
test_ai_guide_check() {
    local td mb mh out
    setup_std_env td mb mh
    create_all_mocks "$mb"
    mkdir -p "$mh/sf-tools/bin" "$mh/sf-tools/phases/start"
    printf '#!/bin/bash\nexit 0\n' > "$mh/sf-tools/phases/start/launcher.sh"; chmod +x "$mh/sf-tools/phases/start/launcher.sh"
    rm -f "$mh/sf-tools/bin/sf-log.sh"
    echo '{"target-org":"testorg"}' > "$td/.sf/config.json"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'
    # どちらもない → 両方の名前で知らせる
    out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-start.sh" 2>&1 < /dev/null)
    assert_output_contains "$out" "AI 向けの案内（CLAUDE.md・AGENTS.md の" "案内がなければ、両方のファイルの名前で知らせる"
    assert_file_not_exists "$td/CLAUDE.md" "ファイルを作らない（書き換えない）"
    # 雛形と同じ → 知らせない
    cp "$SF_TOOLS_DIR/templates/CLAUDE.md" "$SF_TOOLS_DIR/templates/AGENTS.md" "$td/"
    out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-start.sh" 2>&1 < /dev/null)
    assert_output_not_contains "$out" "AI 向けの案内" "雛形の行があれば、知らせない"
    # プロジェクト独自の決まりを書き足しても、行が残っていれば知らせない。行を消したら知らせる
    printf '# このプロジェクトの決まり\n- 命名は XXX\n' >> "$td/CLAUDE.md"
    grep -v 'ai-dev-loop' "$td/AGENTS.md" > "$td/AGENTS.md.t" && mv "$td/AGENTS.md.t" "$td/AGENTS.md"
    out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-start.sh" 2>&1 < /dev/null)
    assert_output_contains "$out" "AI 向けの案内（AGENTS.md の" "行を消したファイルだけを知らせる（書き足しは問題にしない）"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb" "$mh"
}

test_launcher_called() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    mkdir -p "$mh/sf-tools/bin" "$mh/sf-tools/phases/start"
    printf '#!/bin/bash\necho "launcher called ARGS=$#" >> "%s"\n' "$MOCK_CALL_LOG" > "$mh/sf-tools/phases/start/launcher.sh"
    chmod +x "$mh/sf-tools/phases/start/launcher.sh"

    echo '{"target-org":"testorg"}' > "$td/.sf/config.json"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-start.sh" 2>&1 >/dev/null

    assert_file_contains "$MOCK_CALL_LOG" "launcher called ARGS=0" "メニュー（phases/start/launcher.sh）を、引数なしで開く"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb" "$mh"
}

# force-* 以外で実行 → エラー
test_outside_force_dir() {
    local rd mb mh
    rd=$(setup_regular_dir); mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"; mh=$(setup_mock_home)
    create_all_mocks "$mb"
    mkdir -p "$mh/sf-tools/bin" "$mh/sf-tools/phases/start"
    printf '#!/bin/bash\nexit 0\n' > "$mh/sf-tools/phases/start/launcher.sh"
    chmod +x "$mh/sf-tools/phases/start/launcher.sh"

    local out; out=$(cd "$rd" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-start.sh" 2>&1)
    local ec=$?

    assert_exit_fail $ec "force-* 外 → エラー終了"
    teardown "$rd" "$mb" "$mh"
}

test_connected_org
test_alias_prompt_eof_aborts
test_config_files_written
test_force_relogin
test_login_failure_aborts
test_login_url_not_by_alias
# sf の終了コードが 0 以外（インストーラー版の不具合）→ 案内を表示して中断する
test_sf_cli_abort() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    mkdir -p "$mh/sf-tools/bin" "$mh/sf-tools/phases/start"
    printf '#!/bin/bash\nexit 0\n' > "$mh/sf-tools/phases/start/launcher.sh"
    chmod +x "$mh/sf-tools/phases/start/launcher.sh"
    echo '{"target-org":"testorg"}' > "$td/.sf/config.json"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" MOCK_SF_VERSION_EXIT=1 bash "$SF_TOOLS_DIR/bin/sf-start.sh" 2>&1)
    local ec=$?

    assert_exit_fail $ec "sf の終了コード 1 → 中断する（終了コード 0 以外）"
    assert_output_contains "$out" "終了コードが 0 ではありません" "案内が表示された"
    assert_file_not_contains "$MOCK_CALL_LOG" "code ." "VS Code の起動まで、進まない"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb" "$mh"
}

# デバッグログ（sf-log.sh）とのつなぎ: begin に印を渡し、登録したときだけ、終了時に同じ印で leave する（doc/sf-log-design.md 5 章）
#   sf-log.sh は、呼ばれた引数を記録するだけの偽物にする（終了コードは SFLOG_RC）
test_sf_log_begin_and_leave() {
    echo ""; echo -e "${CLR_HEAD}[TEST] デバッグログ（sf-log.sh begin / leave）${CLR_RST}"
    local td mb mh out owner
    setup_std_env td mb mh
    create_all_mocks "$mb"
    mkdir -p "$mh/sf-tools/bin" "$mh/sf-tools/phases/start"
    printf '#!/bin/bash\nexit 0\n' > "$mh/sf-tools/phases/start/launcher.sh"
    printf '#!/bin/bash\necho "sflog $*" >> "%s"\n[ "$1" = leave ] && echo "LEAVE-RESULT-FROM-SFLOG"\nexit "${SFLOG_RC:-0}"\n' "$MOCK_CALL_LOG" > "$mh/sf-tools/bin/sf-log.sh"
    echo '{"target-org":"testorg"}' > "$td/.sf/config.json"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    # 0（始めた）→ begin に印を渡し、終了時に同じ印で leave
    : > "$MOCK_CALL_LOG"
    out=$(cd "$td" && unset SF_LOG_OWNER && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-start.sh" 2>&1)
    assert_output_contains "$out" "LEAVE-RESULT-FROM-SFLOG" "終了時の leave の結果を表示する（残った・消せなかったことに気づけるように）"
    owner=$(grep "^sflog begin" "$MOCK_CALL_LOG" | sed 's/.*--owner //')
    [[ "$owner" =~ ^[0-9]+:[0-9]+:(gitbash|wsl|macos|linux|unknown)[0-9]+$ ]] && pass "begin に、自分の印（PID:時刻:環境の名前と乱数）を渡す" || fail "begin に、自分の印（PID:時刻:環境の名前と乱数）を渡す" "$(cat "$MOCK_CALL_LOG")"
    local rt; rt=$(bash -c "readonly SCRIPT_NAME=t LOG_FILE=/dev/null LOG_MODE=NEW; export SF_INIT_MODE=1; source '$SF_TOOLS_DIR/lib/common.sh'; detect_runtime" 2>/dev/null)
    [[ "${owner##*:}" == "${rt}"* ]] && pass "印の 3 つ目の頭は、動いている環境の名前（${rt}。doc/sf-log-design.md 5.6）" || fail "印の 3 つ目の頭は、動いている環境の名前" "${owner} / ${rt}"
    assert_file_contains "$MOCK_CALL_LOG" "sflog begin -o testorg --owner" "begin に、接続先のエイリアスを渡す"
    assert_file_contains "$MOCK_CALL_LOG" "sflog leave --owner ${owner}" "終了時に、同じ印で leave する"
    # begin の前に、ランチャーの起動はしない（begin → launcher の順）。leave はランチャーのあと
    # 10（取らない）→ leave しない
    : > "$MOCK_CALL_LOG"
    (cd "$td" && unset SF_LOG_OWNER && SFLOG_RC=10 HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-start.sh" >/dev/null 2>&1)
    assert_file_contains "$MOCK_CALL_LOG" "sflog begin" "取らない（10）でも、begin は呼ぶ"
    assert_file_not_contains "$MOCK_CALL_LOG" "sflog leave" "取らない（10）→ leave しない（登録していないため）"
    # 失敗（1）→ 警告を出して進む・leave しない
    : > "$MOCK_CALL_LOG"
    out=$(cd "$td" && unset SF_LOG_OWNER && SFLOG_RC=1 HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-start.sh" 2>&1)
    assert_exit_ok $? "begin の失敗でも、sf-start は 0 で終わる"
    assert_output_contains "$out" "デバッグログの準備を始められませんでした" "begin の失敗 → 警告を表示する"
    assert_file_not_contains "$MOCK_CALL_LOG" "sflog leave" "begin の失敗 → leave しない"
    # 入れ子（外側の印が生きている）→ 印を引き継ぎ、leave しない
    : > "$MOCK_CALL_LOG"
    (cd "$td" && SF_LOG_OWNER="$$:1:outer" HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-start.sh" >/dev/null 2>&1)
    assert_file_contains "$MOCK_CALL_LOG" "sflog begin -o testorg --owner $$:1:outer" "入れ子 → 外側の印を引き継ぐ"
    assert_file_not_contains "$MOCK_CALL_LOG" "sflog leave" "入れ子 → leave しない（後始末は外側）"
    # 外側の印が死んでいる → 自分の印を作る
    : > "$MOCK_CALL_LOG"
    local dead; bash -c 'exit 0' & dead=$!; wait "$dead"
    (cd "$td" && SF_LOG_OWNER="${dead}:1:old" HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-start.sh" >/dev/null 2>&1)
    assert_file_not_contains "$MOCK_CALL_LOG" "--owner ${dead}:1:old" "外側の印が死んでいる → 引き継がない"
    assert_file_contains "$MOCK_CALL_LOG" "sflog leave" "外側の印が死んでいる → 自分で登録し、終了時に leave する"
    # sf-log.sh がない → 呼ばない
    rm -f "$mh/sf-tools/bin/sf-log.sh"; : > "$MOCK_CALL_LOG"
    (cd "$td" && unset SF_LOG_OWNER && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-start.sh" >/dev/null 2>&1)
    assert_file_not_contains "$MOCK_CALL_LOG" "sflog" "sf-log.sh がない → 何もしない"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb" "$mh"
}

test_launcher_called
test_ai_guide_check
test_sf_cli_abort
test_outside_force_dir
test_sf_log_begin_and_leave

print_summary
