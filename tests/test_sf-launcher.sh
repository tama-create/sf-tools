#!/bin/bash
# ==============================================================================
# test_sf-launcher.sh - sf-launcher.sh のテスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-launcher.sh ===${CLR_RST}"

# ------------------------------------------------------------------------------
# force-* 以外のディレクトリ → exit 1
# ------------------------------------------------------------------------------
test_not_in_force_dir() {
    local td mb
    td=$(setup_regular_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    local ec=$?

    assert_exit_fail $ec "force-* 以外のディレクトリ → exit 1"
    assert_output_contains "$out" "force-" "force-* メッセージが表示された"
    teardown "$td" "$mb"
}

# ------------------------------------------------------------------------------
# 有効な番号を引数で直接指定 → sf-check.sh が呼ばれる
# （branch_name.txt なし → チェックスキップ → exit 0）
# ------------------------------------------------------------------------------
test_direct_number_arg() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"

    # 番号 1 = sf-check（branch_name.txt なし → スキップして exit 0）
    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 1 2>&1)
    local ec=$?

    assert_exit_ok $ec "有効な番号引数 (1) → exit 0"
    teardown "$td" "$mb"
}

# ------------------------------------------------------------------------------
# 範囲外の番号 → exit 1
# ------------------------------------------------------------------------------
test_out_of_range_number() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 99 2>&1)
    local ec=$?

    assert_exit_fail $ec "範囲外の番号 (99) → exit 1"
    assert_output_contains "$out" "範囲外" "範囲外メッセージが表示された"
    teardown "$td" "$mb"
}

# ------------------------------------------------------------------------------
# 回帰: 先頭が 0 の番号は 10 進数として扱う（以前は 08・09 が 8 進数として扱われ、[[ -eq ]] がエラーになった）
# ------------------------------------------------------------------------------
test_leading_zero_number() {
    local td mb out ec a
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"

    out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 01 2>&1); ec=$?
    assert_exit_ok $ec "01 → 1 として実行する（exit 0）"
    for a in 08 09 0000000099999999999; do
        out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" "$a" 2>&1); ec=$?
        assert_exit_fail $ec "${a} → 範囲外で exit 1"
        assert_output_contains "$out" "範囲外" "${a} → 範囲外メッセージが表示された"
        printf '%s\n' "$out" | grep -qiE "value too great|syntax error|invalid" \
            && fail "${a} → 算術のエラーが出ない" "$(printf '%s' "$out" | head -3)" \
            || pass "${a} → 算術のエラーが出ない"
    done
    teardown "$td" "$mb"
}

# ------------------------------------------------------------------------------
# 数字以外の引数 → exit 1
# ------------------------------------------------------------------------------
test_nonnumber_arg() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" abc 2>&1)
    local ec=$?

    assert_exit_fail $ec "数字以外の引数 (abc) → exit 1"
    teardown "$td" "$mb"
}

# ------------------------------------------------------------------------------
# インタラクティブモードで q → exit 0
# ------------------------------------------------------------------------------
test_quit_interactive() {
    local td mb
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"

    # printf "q" で stdin に 1 文字送る → read -rsn1 が受け取って exit 0
    local out; out=$(cd "$td" && printf "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    local ec=$?

    assert_exit_ok $ec "q で終了 → exit 0"
    teardown "$td" "$mb"
}

# ------------------------------------------------------------------------------
# メニューの並び: 日々の作業の順（Check → Dryrun → Deploy → Push → Next）。Start・Restart は線の下（2026-11-26 に並べ替え）。
# VS Code の中では Start・Restart と線を出さない
# ------------------------------------------------------------------------------
test_menu_order() {
    local td mb out plain
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"

    out=$(cd "$td" && printf "q" | TERM_PROGRAM= PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    plain=$(printf '%s\n' "$out" | sed $'s/\033\\[[0-9;]*m//g')
    local order
    order=$(printf '%s\n' "$plain" | grep -oE '\[[0-9]\] [A-Za-z]+' | tr '\n' ' ')
    assert_equals "$order" "[1] Check [2] Dryrun [3] Deploy [4] Push [5] Next [6] Start [7] Restart " "番号は、作業の順（Check・Dryrun・Deploy・Push・Next）、その下に Start・Restart"
    # Next と Start の間に、短い線がある
    printf '%s\n' "$plain" | grep -A1 '\[5\] Next' | tail -1 | grep -q '^  ──────────$' \
        && pass "Next と Start の間に線を引く" || fail "Next と Start の間に線を引く" "$plain"
    # 番号の直接指定も、新しい並び（2 = Dryrun）で動く
    out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2 2>&1)
    [[ "$out" == *"▶ sf-dryrun"* ]] && pass "番号 2 → sf-dryrun を動かす" || fail "番号 2 → sf-dryrun を動かす" "$(printf '%s' "$out" | head -5)"

    # VS Code の中: Start・Restart と、線を出さない
    out=$(cd "$td" && printf "q" | TERM_PROGRAM=vscode PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    plain=$(printf '%s\n' "$out" | sed $'s/\033\\[[0-9;]*m//g')
    order=$(printf '%s\n' "$plain" | grep -oE '\[[0-9]\] [A-Za-z]+' | tr '\n' ' ')
    assert_equals "$order" "[1] Check [2] Dryrun [3] Deploy [4] Push [5] Next " "VS Code の中: 1〜5 だけ"
    printf '%s\n' "$plain" | grep -q '^  ──────────$' \
        && fail "VS Code の中: 線を引かない" "$plain" || pass "VS Code の中: 線を引かない"
    teardown "$td" "$mb"
}

# ------------------------------------------------------------------------------
# 実行
# ------------------------------------------------------------------------------
test_not_in_force_dir
test_direct_number_arg
test_out_of_range_number
test_leading_zero_number
test_nonnumber_arg
test_quit_interactive
test_menu_order

# ------------------------------------------------------------------------------
# デバッグログ（sf-log.sh）の状態の 1 行（logs/apex/.status。doc/sf-log-design.md 5.4）
# ------------------------------------------------------------------------------
test_apexlog_status_line() {
    echo ""; echo -e "${CLR_HEAD}[TEST] デバッグログの状態の 1 行${CLR_RST}"
    local td mb out
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"
    out=$(cd "$td" && echo "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    assert_output_not_contains "$out" "ログ ●" ".status がない → 何も表示しない"
    mkdir -p "$td/logs/apex"
    printf 'STATE=collecting\nORG=dev\nEXPIRES=2026-11-23T06:30:00Z\nEXPIRES_AT=15:30\nCOUNT_TODAY=3\nWARNING=\n' > "$td/logs/apex/.status"
    out=$(cd "$td" && echo "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    [[ "$out" == *"● 取得中（期限 15:30・今日 3 本）"* ]] && pass "取得中 → 組織・期限・今日の本数を表示する" || fail "取得中 → 組織・期限・今日の本数を表示する" "$out"
    [[ "$out" == *$'\033[1m\033[0;32m● 取得中'* ]] && pass "取得中 → 太字の緑で表示する（目立たせる）" || fail "取得中 → 太字の緑で表示する（目立たせる）" "$out"
    printf 'STATE=skipped\nREASON=このプロジェクトでは、自動で取らない設定のため\n' > "$td/logs/apex/.status"
    out=$(cd "$td" && echo "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    [[ "$out" == *"● 取っていません（このプロジェクトでは、自動で取らない設定のため）"* ]] && pass "取らない → 理由を表示する" || fail "取らない → 理由を表示する" "$out"
    [[ "$out" == *$'\033[0;33m● 取っていません'* ]] && pass "取らない → 黄色で表示する" || fail "取らない → 黄色で表示する" "$out"
    printf 'STATE=error\nREASON=接続できないため\n' > "$td/logs/apex/.status"
    out=$(cd "$td" && echo "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    [[ "$out" == *$'\033[1m\033[0;31m● 取れていません（接続できないため）'* ]] && pass "取れていません → 太字の赤で表示する" || fail "取れていません → 太字の赤で表示する" "$out"
    printf 'STATE=collecting\nORG=dev\nWARNING=取得に失敗しました（120 秒後にやり直します）\n' > "$td/logs/apex/.status"
    out=$(cd "$td" && echo "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    [[ "$out" == *"⚠ デバッグログ: 取得に失敗しました"* ]] && pass "WARNING → もう 1 行表示する" || fail "WARNING → もう 1 行表示する" "$out"
    printf 'STATE=$(touch injected)\n' > "$td/logs/apex/.status"
    out=$(cd "$td" && echo "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    assert_file_not_exists "$td/injected" ".status を source しない（中身を実行しない）"
    assert_output_not_contains "$out" "ログ ●" "知らない STATE → 何も表示しない"
    teardown "$td" "$mb"
}
test_apexlog_status_line

# ------------------------------------------------------------------------------
# 準備中（starting）のあいだは、状態が変わったら、メニューを描き直す（コマンドは動かさない。read -t 5 秒ずつ）
# ------------------------------------------------------------------------------
test_apexlog_status_refresh() {
    echo ""; echo -e "${CLR_HEAD}[TEST] デバッグログ: 準備中のあいだの描き直し${CLR_RST}"
    local td mb out t0 n
    td=$(setup_force_dir); mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"
    mkdir -p "$td/logs/apex"
    printf 'STATE=starting\nORG=dev\n' > "$td/logs/apex/.status"
    # 2 秒後に取得中へ変わる。入力の q は 8 秒後（その間に、5 秒の待ち切れが 1 回ある）
    ( sleep 2; printf 'STATE=collecting\nORG=dev\nEXPIRES_AT=15:30\nCOUNT_TODAY=0\n' > "$td/logs/apex/.status" ) &
    out=$(cd "$td" && { sleep 8; printf 'q'; } | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    wait
    [[ "$out" == *"● 準備中"* ]] && pass "最初は、準備中を表示する" || fail "最初は、準備中を表示する" "$out"
    [[ "$out" == *"● 取得中（期限 15:30・今日 0 本）"* ]] && pass "取得中に変わったら、メニューを描き直す" || fail "取得中に変わったら、メニューを描き直す" "$out"
    n=$(printf '%s\n' "$out" | grep -c ">> Launcher <<")
    assert_equals "$n" "2" "描き直しは 1 回だけ（取得中になったら、待ち切れで描き直さない）"
    # 状況の表示（処理の流れ 6）が読む git（読み取りのみ）は除いて、ほかのコマンドを動かしていないことを確かめる
    local others
    others=$(grep -vE '^git (symbolic-ref -q --short HEAD|status --porcelain|rev-parse -q --verify (@\{u\}|HEAD)|rev-list --count @\{u\}\.\.HEAD)$' "$mb/calls.log" 2>/dev/null)
    [[ -z "$others" ]] && pass "描き直しでは、コマンドを動かさない（状況の表示の、読み取りの git だけ）" || fail "描き直しでは、コマンドを動かさない（状況の表示の、読み取りの git だけ）" "$others"
    # 準備中のままの EOF → すぐ終わる（待ち切れと取り違えない）
    printf 'STATE=starting\nORG=dev\n' > "$td/logs/apex/.status"
    t0=$SECONDS
    out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" < /dev/null 2>&1); local ec=$?
    assert_exit_ok $ec "準備中の EOF → 正常終了"
    (( SECONDS - t0 < 4 )) && pass "準備中の EOF → 待たずに終わる" || fail "準備中の EOF → 待たずに終わる" "$((SECONDS - t0)) 秒"
    teardown "$td" "$mb"
}
test_apexlog_status_refresh

# ------------------------------------------------------------------------------
# 今の状況の表示と、次の目安（処理の流れ 6）・結果の 1 行（処理の流れ 7）
#   本物の git の一時リポジトリ（origin は bare）で確かめる（偽の git では、変更の数・追跡先の差を作れないため）
# ------------------------------------------------------------------------------
_st_repo() { # 作業フォルダ（force-*）を作り、origin（bare）へ push して、追跡先を付ける。パスを出す
    local td bare
    td=$(setup_force_dir); bare="${td}.origin.git"
    git init -q --bare "$bare"
    (
        cd "$td" || exit 1
        git init -q -b feature/x
        git config user.email t@example.com; git config user.name t; git config core.autocrlf false
        # 本物の force-* と同じく、.sf/・logs は Git の対象外にし、ほかは最初にコミットしておく（変更 0 件から始める）
        printf '.sf/\nlogs\n' > .gitignore
        printf 'a\n' > a.txt; git add -A; git commit -q -m init
        git remote add origin "$bare"; git push -q -u origin feature/x 2>/dev/null
    )
    printf '{"target-org": "my-dev"}\n' > "$td/.sf/config.json"
    echo "$td"
}
_st_menu() { # 作業フォルダ → メニューの出力（色を除く）
    (cd "$1" && printf 'q' | TERM_PROGRAM= bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1) | sed $'s/\033\\[[0-9;]*m//g'
}

_st_aligned() { # 出力（色なし） 段階（例: "4 Push"） 説明 → 印（^）が、その段階の真下にあるか
    local flow mark c1 c2
    flow=$(printf '%s\n' "$1" | grep -F '1 Check  >  2 Dryrun' | head -1)
    mark=$(printf '%s\n' "$1" | grep -E '^ *\^ ' | head -1)
    c1=${flow%%"$2"*}; c2=${mark%%^*}
    [[ -n "$flow" && -n "$mark" && ${#c1} -eq ${#c2} ]] && pass "$3" || fail "$3" "流れ: [$flow] 印: [$mark]"
}
test_status_display() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 今の状況の表示と、次の目安${CLR_RST}"
    local td out head
    td=$(_st_repo); head=$(git -C "$td" rev-parse HEAD)

    out=$(_st_menu "$td")
    assert_output_contains "$out" "feature/x ｜ my-dev" "1 行目に、ブランチと組織（.sf/config.json の target-org）を出す"
    assert_output_contains "$out" "1 Check  >  2 Dryrun  >  3 Deploy  >  4 Push  >  5 Next" "作業の流れを出す（番号はメニューの並び）"
    assert_output_contains "$out" "\^ ここ（次の出し先を確かめる）" "変更なし・push 済み・next-status.txt がない → Next で確かめる"
    _st_aligned "$out" "5 Next" "印（^）は、流れの 5 Next の真下に出る"

    printf 'HEAD=%s\nNEXT=staging\nPR=\nSKIPPED=false\n' "$head" > "$td/sf-tools/logs/next-status.txt"
    out=$(_st_menu "$td")
    assert_output_contains "$out" "\^ ここ（staging へ PR を出す）" "next-status.txt の HEAD が今と同じ → 次の PR 先を出す"

    printf 'HEAD=%s\nNEXT=staging\nPR=12\nSKIPPED=false\n' "$head" > "$td/sf-tools/logs/next-status.txt"
    out=$(_st_menu "$td")
    assert_output_contains "$out" "\^ ここ（PR #12 の検証が緑になったら、マージ）" "発行中の PR → 番号と、検証を待つことを出す"

    printf 'HEAD=%s\nNEXT=none\nPR=\nSKIPPED=false\n' "$head" > "$td/sf-tools/logs/next-status.txt"
    out=$(_st_menu "$td")
    assert_output_contains "$out" "✓ 全段階にリリース済みです" "NEXT=none → 全段階にリリース済み（印は出さない）"
    assert_output_not_contains "$out" "\^ ここ" "NEXT=none → 印（^）は出さない"

    printf 'HEAD=%s\nNEXT=develop\nPR=\nSKIPPED=true\n' "$head" > "$td/sf-tools/logs/next-status.txt"
    out=$(_st_menu "$td")
    assert_output_contains "$out" "ターゲットファイル（sf-tools/release/feature/x/）に、出すものを書きます" "SKIPPED=true → ターゲットファイルに書く"

    printf 'HEAD=0000000000000000000000000000000000000000\nNEXT=main\nPR=\nSKIPPED=false\n' > "$td/sf-tools/logs/next-status.txt"
    out=$(_st_menu "$td")
    assert_output_contains "$out" "\^ ここ（次の出し先を確かめる）" "HEAD が今と違う（古い結果）→ 使わない"

    printf 'HEAD=%s\nNEXT=$(touch injected)\nPR=1;x\n' "$head" > "$td/sf-tools/logs/next-status.txt"
    out=$(_st_menu "$td")
    assert_file_not_exists "$td/injected" "next-status.txt を source しない（中身を実行しない）"
    assert_output_contains "$out" "\^ ここ（次の出し先を確かめる）" "形の違う NEXT= → 使わない"

    printf 'b\n' > "$td/b.txt"
    out=$(_st_menu "$td")
    assert_output_contains "$out" "\^ ここから（未コミットの変更 1 件）" "未コミットの変更を数え、Check から始める"
    _st_aligned "$out" "1 Check" "印（^）は、流れの 1 Check の真下に出る"

    git -C "$td" add b.txt; git -C "$td" commit -q -m b
    out=$(_st_menu "$td")
    assert_output_contains "$out" "\^ ここ（push していないコミット 1 件）" "push していないコミットを数え、Push を示す"
    _st_aligned "$out" "4 Push" "印（^）は、流れの 4 Push の真下に出る"

    # デバッグログの REASON・WARNING に、制御文字（ESC・改行）・文字の向きを変える文字を入れても、画面を崩さない（clean_text）
    mkdir -p "$td/logs/apex"
    printf 'STATE=error' > "$td/logs/apex/.status"
    printf '\nREASON=x\033[2Jy\xe2\x80\xaez\nWARNING=w\033[31mv\\033u\n' >> "$td/logs/apex/.status"
    out=$( (cd "$td" && printf 'q' | TERM_PROGRAM= bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1) )
    [[ "$out" != *$'\033[2J'* && "$out" != *$'\xe2\x80\xae'* && "$out" != *$'\033[31mv'* ]] && pass "デバッグログの理由・WARNING の制御文字・向きを変える文字を除く" || fail "デバッグログの理由・WARNING の制御文字・向きを変える文字を除く" "$out"
    [[ "$out" == *"● 取れていません（x[2Jyz）"* && "$out" == *'⚠ デバッグログ: w[31mv\033u'* ]] && pass "デバッグログの理由・WARNING は、文字として残す（\\033 の並びは制御にしない）" || fail "デバッグログの理由・WARNING は、文字として残す（\\033 の並びは制御にしない）" "$out"
    rm -f "$td/logs/apex/.status"

    # 追跡先がない（push したことがないブランチ）→ Push の下に「追跡先なし」
    git -C "$td" checkout -q -b feature/nopush
    out=$(_st_menu "$td")
    assert_output_contains "$out" "\\^ ここ（まだ push していません。追跡先なし）" "追跡先がない → Push の下に、追跡先なし"
    _st_aligned "$out" "4 Push" "追跡先なし: 印（^）は、流れの 4 Push の真下に出る"
    git -C "$td" checkout -q feature/x

    git -C "$td" checkout -q -b develop
    out=$(_st_menu "$td")
    assert_output_contains "$out" "⚠ 環境ブランチの上です" "環境ブランチ（branches.txt）→ その旨を出す"
    assert_output_not_contains "$out" "\^ ここ" "環境ブランチ → 流れの印を出さない"

    # 組織名: 制御文字（ESC・改行）・文字の向きを変える文字を除き、60 文字を超えたら切る
    local long; long=$(printf 'o%.0s' $(seq 1 80))
    printf '{"target-org": "ab\\u001b[31mcd\\nef\\u202egh%s"}\n' "$long" > "$td/.sf/config.json"
    out=$( (cd "$td" && printf 'q' | TERM_PROGRAM= bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1) | grep ' ｜ ')
    [[ "$out" != *$'\033[31m'* && "$out" != *$'\xe2\x80\xae'* ]] && pass "組織名の制御文字・向きを変える文字を除く" || fail "組織名の制御文字・向きを変える文字を除く" "$out"
    [[ "$out" == *"ab[31mcdefgh"*"…"* ]] && pass "組織名は 60 文字で切って … を付ける" || fail "組織名は 60 文字で切って … を付ける" "$out"
    printf '{"target-org": "x\\\\033[31my"}\n' > "$td/.sf/config.json"
    out=$( (cd "$td" && printf 'q' | TERM_PROGRAM= bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1) | grep ' ｜ ')
    [[ "$out" != *$'\033[31m'* && "$out" == *'x\033[31my'* ]] && pass "組織名の \\033 の文字の並びは、制御として解釈せず、そのまま出す" || fail "組織名の \\033 の文字の並びは、制御として解釈せず、そのまま出す" "$out"
    printf 'HEAD=%s\nNEXT=staging\nPR=1234567890\n' "$(git -C "$td" rev-parse HEAD)" > "$td/sf-tools/logs/next-status.txt"
    out=$(_st_menu "$td")
    assert_output_not_contains "$out" "PR #1234567890" "長すぎる PR=（10 桁以上）は使わない"
    printf 'HEAD=%s\nNEXT=%s\n' "$(git -C "$td" rev-parse HEAD)" "$long" > "$td/sf-tools/logs/next-status.txt"
    out=$(_st_menu "$td")
    assert_output_not_contains "$out" "ここ（ooo" "長すぎる NEXT=（41 文字以上）は使わない"

    rm -f "$td/.sf/config.json"
    out=$(_st_menu "$td")
    assert_output_not_contains "$out" "｜ ab" ".sf/config.json がない → 組織を出さない"
    teardown "$td" "${td}.origin.git"
}
test_status_display

test_result_line() {
    echo ""; echo -e "${CLR_HEAD}[TEST] コマンドの結果の 1 行${CLR_RST}"
    local td out
    td=$(_st_repo)
    out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 1 2>&1 | sed $'s/\033\\[[0-9;]*m//g')
    assert_output_contains "$out" "✓ Check: 終わりました（成功）" "成功 → ✓ の 1 行"
    git -C "$td" checkout -q -b develop
    out=$(cd "$td" && bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 5 2>&1 | sed $'s/\033\\[[0-9;]*m//g'); local ec=$?
    assert_output_contains "$out" "✗ Next: 失敗、または中断しました（終了コード 1）" "失敗（環境ブランチの上の sf-next）→ ✗ の 1 行と終了コード"
    teardown "$td" "${td}.origin.git"
}
test_result_line

print_summary
