#!/bin/bash
# ==============================================================================
# test_sf-launcher.sh - sf-launcher.sh のテスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
export SF_LAUNCHER_BG_STATUS=0   # 2 行目の裏の判定（sf-next.sh --status）を止める。確かめるテストだけで 1 にする
export SF_LAUNCHER_FROM_START=1  # sf-start.sh から開いた扱いにする（メニューを sf-start.sh に切り替えない）。確かめるテストだけで外す
unset SF_LAUNCHER_ACTIVE
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
    assert_equals "$order" "[1] Check [2] Dryrun [3] Deploy [4] Push [5] PullRequest [6] Start [7] Restart " "番号は、作業の順（Check・Dryrun・Deploy・Push・PullRequest）、その下に Start・Restart"
    # Next と Start の間に、短い線がある
    printf '%s\n' "$plain" | grep -A1 '\[5\] PullRequest' | tail -1 | grep -q '^  ──────────$' \
        && pass "PullRequest と Start の間に線を引く" || fail "PullRequest と Start の間に線を引く" "$plain"
    # 番号の直接指定も、新しい並び（2 = Dryrun）で動く
    out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2 2>&1)
    [[ "$out" == *"▶ sf-dryrun"* ]] && pass "番号 2 → sf-dryrun を動かす" || fail "番号 2 → sf-dryrun を動かす" "$(printf '%s' "$out" | head -5)"

    # VS Code の中: Start・Restart と、線を出さない
    out=$(cd "$td" && printf "q" | TERM_PROGRAM=vscode PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    plain=$(printf '%s\n' "$out" | sed $'s/\033\\[[0-9;]*m//g')
    order=$(printf '%s\n' "$plain" | grep -oE '\[[0-9]\] [A-Za-z]+' | tr '\n' ' ')
    assert_equals "$order" "[1] Check [2] Dryrun [3] Deploy [4] Push [5] PullRequest " "VS Code の中: 1〜5 だけ"
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
    assert_output_not_contains "$out" "Log:" ".status がない → 何も表示しない"
    mkdir -p "$td/logs/apex"
    printf 'STATE=collecting\nORG=dev\nEXPIRES=2026-11-23T06:30:00Z\nEXPIRES_AT=15:30\nCOUNT_TODAY=3\nWARNING=\n' > "$td/logs/apex/.status"
    out=$(cd "$td" && echo "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    [[ "$out" == *"取得中 (15:30/3本)"* ]] && pass "取得中 → 期限・今日の本数を表示する（Log: 取得中 (期限/本数)）" || fail "取得中 → 期限・今日の本数を表示する（Log: 取得中 (期限/本数)）" "$out"
    [[ "$out" == *$'\033[1m\033[0;32m取得中'* ]] && pass "取得中 → 太字の緑で表示する（目立たせる）" || fail "取得中 → 太字の緑で表示する（目立たせる）" "$out"
    printf 'STATE=skipped\nREASON=このプロジェクトでは、自動で取らない設定のため\n' > "$td/logs/apex/.status"
    out=$(cd "$td" && echo "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    [[ "$out" == *"取っていません（このプロジェクトでは、自動で取らない設定のため）"* ]] && pass "取らない → 理由を表示する" || fail "取らない → 理由を表示する" "$out"
    [[ "$out" == *$'\033[0;33m取っていません'* ]] && pass "取らない → 黄色で表示する" || fail "取らない → 黄色で表示する" "$out"
    printf 'STATE=error\nREASON=接続できないため\n' > "$td/logs/apex/.status"
    out=$(cd "$td" && echo "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    [[ "$out" == *$'\033[1m\033[0;31m取れていません（接続できないため）'* ]] && pass "取れていません → 太字の赤で表示する" || fail "取れていません → 太字の赤で表示する" "$out"
    printf 'STATE=stopped\nREASON=すべての sf-start が終了したため\n' > "$td/logs/apex/.status"
    out=$(cd "$td" && echo "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    [[ "$out" == *"止まっています（すべての sf-start が終了したため）。sf-start で取り始めます"* ]] && pass "止まっている → 理由と、sf-start で取り始めることを添える" || fail "止まっている → 理由と、sf-start で取り始めることを添える" "$out"
    [[ "$out" == *$'\033[0;33m止まっています'* ]] && pass "止まっている → 黄色で表示する" || fail "止まっている → 黄色で表示する" "$out"
    printf 'STATE=collecting\nORG=dev\nWARNING=取得に失敗しました（120 秒後にやり直します）\n' > "$td/logs/apex/.status"
    out=$(cd "$td" && echo "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    [[ "$out" == *"⚠ Log: 取得に失敗しました"* ]] && pass "WARNING → もう 1 行表示する" || fail "WARNING → もう 1 行表示する" "$out"
    printf 'STATE=$(touch injected)\n' > "$td/logs/apex/.status"
    out=$(cd "$td" && echo "q" | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1)
    assert_file_not_exists "$td/injected" ".status を source しない（中身を実行しない）"
    assert_output_not_contains "$out" "Log:" "知らない STATE → 何も表示しない"
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
    # メニューの描画が終わるのを見てから進める（決め打ちの秒数で待つと、描画の遅い Windows の CI で、描き直しの前に q が届く）:
    #   1 回目の描画 → 取得中に変える → 2 回目の描画（待ち切れでの描き直し）→ さらに 6 秒待ち（取得中なら、描き直さない）→ q
    local outf="$td/launcher.out"
    _wait_menus() { # ファイル 回数 → その回数だけメニューが描かれるまで待つ（最大 90 秒）
        local i=0
        while [[ $(grep -c ">> LAUNCHER <<" "$1" 2>/dev/null || true) -lt $2 && $i -lt 90 ]]; do sleep 1; i=$((i + 1)); done
    }
    (
        cd "$td" && {
            _wait_menus "$outf" 1
            printf 'STATE=collecting\nORG=dev\nEXPIRES_AT=15:30\nCOUNT_TODAY=0\n' > "$td/logs/apex/.status"
            _wait_menus "$outf" 2
            sleep 6; printf 'q'
        } | PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" > "$outf" 2>&1
    )
    out=$(cat "$outf")
    [[ "$out" == *"Log: "*"準備中"* ]] && pass "最初は、準備中を表示する" || fail "最初は、準備中を表示する" "$out"
    [[ "$out" == *"取得中 (15:30/0本)"* ]] && pass "取得中に変わったら、メニューを描き直す" || fail "取得中に変わったら、メニューを描き直す" "$out"
    n=$(printf '%s\n' "$out" | grep -c ">> LAUNCHER <<")
    assert_equals "$n" "2" "描き直しは 1 回だけ（取得中になったら、待ち切れで描き直さない）"
    # 状況の表示（処理の流れ 6）が読む git（読み取りのみ）は除いて、ほかのコマンドを動かしていないことを確かめる
    local others
    others=$(grep -vE '^git status --porcelain=v2 --branch$' "$mb/calls.log" 2>/dev/null)
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

test_status_display() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 見出しの 2 行（状況と、段階の並び）${CLR_RST}"
    local td out head
    td=$(_st_repo); head=$(git -C "$td" rev-parse HEAD)

    out=$(_st_menu "$td")
    assert_output_contains "$out" ">> LAUNCHER <<   feature/x @ my-dev ／ 変更 0 件" "1 行目に、ブランチ @ 組織（.sf/config.json の target-org）と変更の数を出す"
    assert_output_contains "$out" "                   Branch: （5 PullRequest で確かめる）" "next-status.txt がない → 2 行目は「5 PullRequest で確かめる」（1 行目のブランチ名の位置にそろえる）"

    printf 'HEAD=%s\nNEXT=staging\nPR=\nSKIPPED=false\nTIERS=develop staging main\n' "$head" > "$td/sf-tools/logs/next-status.txt"
    out=$(_st_menu "$td")
    assert_output_contains "$out" "Branch: ✓ develop ⇒ ▸ staging (次のPR) ⇒ × main" "next-status.txt の HEAD が今と同じ → 段階の並び（出し終わり ✓・次 ▸・まだ ×）"

    printf 'HEAD=%s\nNEXT=staging\nPR=12\nSKIPPED=false\nTIERS=develop staging main\n' "$head" > "$td/sf-tools/logs/next-status.txt"
    out=$(_st_menu "$td")
    assert_output_contains "$out" "▸ staging (PR #12 発行中)" "発行中の PR → 番号を出す"

    printf 'HEAD=%s\nNEXT=none\nPR=\nSKIPPED=false\nTIERS=develop staging main\n' "$head" > "$td/sf-tools/logs/next-status.txt"
    out=$(_st_menu "$td")
    assert_output_contains "$out" "Branch: ✓ develop ⇒ ✓ staging ⇒ ✓ main  (全段階にリリース済み)" "NEXT=none → すべて ✓・全段階にリリース済み"
    assert_output_not_contains "$out" "▸" "NEXT=none → ▸ は出さない"

    printf 'HEAD=%s\nNEXT=develop\nPR=\nSKIPPED=true\nTIERS=develop staging main\n' "$head" > "$td/sf-tools/logs/next-status.txt"
    out=$(_st_menu "$td")
    assert_output_contains "$out" "Branch: 出すものなし（ターゲットファイル sf-tools/release/feature/x/ が空）" "SKIPPED=true → 出すものなし"

    printf 'HEAD=0000000000000000000000000000000000000000\nNEXT=main\nPR=\nSKIPPED=false\nTIERS=develop staging main\n'> "$td/sf-tools/logs/next-status.txt"
    out=$(_st_menu "$td")
    assert_output_contains "$out" "Branch: （5 PullRequest で確かめる）" "HEAD が今と違う（古い結果）→ 使わない"

    printf 'HEAD=%s\nNEXT=$(touch injected)\nPR=1;x\n' "$head" > "$td/sf-tools/logs/next-status.txt"
    out=$(_st_menu "$td")
    assert_file_not_exists "$td/injected" "next-status.txt を source しない（中身を実行しない）"
    assert_output_contains "$out" "Branch: （5 PullRequest で確かめる）" "形の違う NEXT= → 使わない"
    printf 'HEAD=%s\nNEXT=staging\nTIERS=develop $(x) main\n' "$head" > "$td/sf-tools/logs/next-status.txt"
    out=$(_st_menu "$td")
    assert_output_contains "$out" "Branch: （5 PullRequest で確かめる）" "形の違う TIERS= → 使わない"
    printf 'HEAD=%s\nNEXT=qa\nTIERS=develop staging main\n' "$head" > "$td/sf-tools/logs/next-status.txt"
    out=$(_st_menu "$td")
    assert_output_contains "$out" "Branch: （5 PullRequest で確かめる）" "NEXT= が段階の一覧にない → 使わない"

    printf 'b\n' > "$td/b.txt"
    out=$(_st_menu "$td")
    assert_output_contains "$out" "／ 変更 1 件" "未コミットの変更を数える"

    git -C "$td" add b.txt; git -C "$td" commit -q -m b
    out=$(_st_menu "$td")
    assert_output_contains "$out" "／ 変更 0 件" "コミットすると、変更の数は 0 件"

    # デバッグログの REASON・WARNING に、制御文字（ESC・改行）・文字の向きを変える文字を入れても、画面を崩さない（clean_text）
    mkdir -p "$td/logs/apex"
    printf 'STATE=error' > "$td/logs/apex/.status"
    printf '\nREASON=x\033[2Jy\xe2\x80\xaez\nWARNING=w\033[31mv\\033u\n' >> "$td/logs/apex/.status"
    out=$( (cd "$td" && printf 'q' | TERM_PROGRAM= bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1) )
    [[ "$out" != *$'\033[2J'* && "$out" != *$'\xe2\x80\xae'* && "$out" != *$'\033[31mv'* ]] && pass "デバッグログの理由・WARNING の制御文字・向きを変える文字を除く" || fail "デバッグログの理由・WARNING の制御文字・向きを変える文字を除く" "$out"
    [[ "$out" == *"取れていません（x[2Jyz）"* && "$out" == *'⚠ Log: w[31mv\033u'* ]] && pass "デバッグログの理由・WARNING は、文字として残す（\\033 の並びは制御にしない）" || fail "デバッグログの理由・WARNING は、文字として残す（\\033 の並びは制御にしない）" "$out"
    rm -f "$td/logs/apex/.status"

    # 追跡先がない（push したことがないブランチ）→ Push の下に「追跡先なし」
    git -C "$td" checkout -q -b feature/nopush
    out=$(_st_menu "$td")
    assert_output_contains "$out" "   feature/nopush @ my-dev ／" "push したことがないブランチ → ブランチ名を出す"
    git -C "$td" checkout -q feature/x

    # git status --porcelain=v2 の境界: behind だけ（ahead 0）→ Push ではなく Next / 名前の変更は 1 件 / 付け離れた HEAD
    git -C "$td" checkout -q feature/x
    git -C "$td" commit -q --allow-empty -m e1; git -C "$td" push -q origin feature/x 2>/dev/null
    git -C "$td" reset -q --hard HEAD~1   # origin が 1 つ先（behind 1・ahead 0）
    rm -f "$td/sf-tools/logs/next-status.txt"
    out=$(_st_menu "$td")
    assert_output_contains "$out" "／ 変更 0 件" "behind だけ（ahead 0）→ 変更は 0 件"
    git -C "$td" mv a.txt renamed.txt
    out=$(_st_menu "$td")
    assert_output_contains "$out" "／ 変更 1 件" "名前の変更（porcelain v2 の rename の行）は 1 件"
    git -C "$td" reset -q --hard HEAD
    git -C "$td" checkout -q --detach HEAD
    out=$(_st_menu "$td")
    assert_output_contains "$out" "（ブランチの上にいません）" "付け離れた HEAD（(detached)）→ ブランチの上にいない"
    git -C "$td" checkout -q feature/x
    # 追跡先のブランチが消えた（branch.upstream はあるが branch.ab がない）→ 追跡先なし
    git -C "$td" push -q origin --delete feature/x 2>/dev/null; git -C "$td" fetch -q --prune origin 2>/dev/null
    out=$(_st_menu "$td")
    assert_output_contains "$out" "   feature/x @ my-dev ／" "追跡先のブランチが消えても、表示は崩れない"
    git -C "$td" push -q -u origin feature/x 2>/dev/null

    git -C "$td" checkout -q -b develop
    out=$(_st_menu "$td")
    assert_output_contains "$out" "⚠ 環境ブランチの上です" "環境ブランチ（branches.txt）→ その旨を出す"
    assert_output_not_contains "$out" "Branch:" "環境ブランチ → Branch: の行を出さない"
    git -C "$td" checkout -q feature/x   # 以下は、作業用のブランチの上で確かめる（環境ブランチの上では Branch: の行を出さないため）

    # 組織名: 制御文字（ESC・改行）・文字の向きを変える文字を除き、60 文字を超えたら切る
    local long; long=$(printf 'o%.0s' $(seq 1 80))
    printf '{"target-org": "ab\\u001b[31mcd\\nef\\u202egh%s"}\n' "$long" > "$td/.sf/config.json"
    out=$( (cd "$td" && printf 'q' | TERM_PROGRAM= bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1) | grep ' @ ')
    [[ "$out" != *$'\033[31m'* && "$out" != *$'\xe2\x80\xae'* ]] && pass "組織名の制御文字・向きを変える文字を除く" || fail "組織名の制御文字・向きを変える文字を除く" "$out"
    [[ "$out" == *"ab[31mcdefgh"*"…"* ]] && pass "組織名は 60 文字で切って … を付ける" || fail "組織名は 60 文字で切って … を付ける" "$out"
    printf '{"target-org": "x\\\\033[31my"}\n' > "$td/.sf/config.json"
    out=$( (cd "$td" && printf 'q' | TERM_PROGRAM= bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1) | grep ' @ ')
    [[ "$out" != *$'\033[31m'* && "$out" == *'x\033[31my'* ]] && pass "組織名の \\033 の文字の並びは、制御として解釈せず、そのまま出す" || fail "組織名の \\033 の文字の並びは、制御として解釈せず、そのまま出す" "$out"
    printf 'HEAD=%s\nNEXT=staging\nPR=1234567890\n' "$(git -C "$td" rev-parse HEAD)" > "$td/sf-tools/logs/next-status.txt"
    out=$(_st_menu "$td")
    assert_output_not_contains "$out" "PR #1234567890" "長すぎる PR=（10 桁以上）は使わない"
    printf 'HEAD=%s\nNEXT=%s\n' "$(git -C "$td" rev-parse HEAD)" "$long" > "$td/sf-tools/logs/next-status.txt"
    out=$(_st_menu "$td")
    assert_output_not_contains "$out" "▸ ooo" "長すぎる NEXT=（41 文字以上）は使わない"
    local h; h=$(git -C "$td" rev-parse HEAD)
    printf 'HEAD=%s\nNEXT=main\nPR=\nSKIPPED=false\nTIERS=main\n' "$h" > "$td/sf-tools/logs/next-status.txt"
    out=$(_st_menu "$td")
    assert_output_contains "$out" "Branch: ▸ main (次のPR)" "段階が main だけ → ▸ main（⇒ は出さない）"
    assert_output_not_contains "$out" "⇒" "段階が 1 つ → ⇒ は出さない"
    printf 'HEAD=%s\nNEXT=staging\nPR=\nSKIPPED=false\nTIERS=develop staging staging main\n' "$h" > "$td/sf-tools/logs/next-status.txt"
    out=$(_st_menu "$td")
    assert_output_contains "$out" "Branch: （5 PullRequest で確かめる）" "TIERS= に同じ段階が 2 回 → 使わない"
    printf 'HEAD=%s\nNEXT=staging\nPR=\nSKIPPED=yes\nTIERS=develop staging main\n' "$h" > "$td/sf-tools/logs/next-status.txt"
    out=$(_st_menu "$td")
    assert_output_contains "$out" "Branch: （5 PullRequest で確かめる）" "SKIPPED= が true / false 以外 → 使わない"
    printf 'HEAD=%s\nNEXT=staging\nPR=-3\nSKIPPED=false\nTIERS=develop staging main\n' "$h" > "$td/sf-tools/logs/next-status.txt"
    out=$(_st_menu "$td")
    assert_output_contains "$out" "▸ staging (次のPR)" "PR= が数字でない（-3）→ PR の番号だけ使わない"
    assert_output_not_contains "$out" "PR #" "PR= が数字でない → 番号を出さない"

    rm -f "$td/.sf/config.json"
    out=$(_st_menu "$td")
    assert_output_not_contains "$out" "@ " ".sf/config.json がない → 組織を出さない"
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
    assert_output_contains "$out" "✗ PullRequest: 失敗、または中断しました（終了コード 1）" "失敗（環境ブランチの上の sf-next）→ ✗ の 1 行と終了コード"
    teardown "$td" "${td}.origin.git"
}
test_result_line

test_fzf_label_to_command() {
    echo ""; echo -e "${CLR_HEAD}[TEST] fzf: 選んだ表示名から、コマンドを引き直す（PullRequest → sf-next）${CLR_RST}"
    local td mb out
    td=$(_st_repo); mb=$(mktemp -d)
    git -C "$td" checkout -q -b develop   # 環境ブランチの上の sf-next は失敗する → 結果の 1 行で、何が動いたかが分かる
    # 1 回目は PullRequest の行を選び、2 回目は Esc（空）で終える fzf のモック
    cat > "$mb/fzf" <<'MOCK'
#!/bin/bash
n=0; [[ -f "$0.count" ]] && n=$(cat "$0.count"); echo $((n + 1)) > "$0.count"
if [[ $n -eq 0 ]]; then grep '^PullRequest ' | head -1; else cat > /dev/null; fi
MOCK
    chmod +x "$mb/fzf"
    out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" --fzf < /dev/null 2>&1 | sed $'s/\033\\[[0-9;]*m//g')
    assert_output_contains "$out" "✗ PullRequest: 失敗、または中断しました" "fzf で PullRequest を選ぶ → sf-next.sh が動く"
    teardown "$td" "${td}.origin.git" "$mb"
}
test_fzf_label_to_command

test_reload_when_updated() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 起動のあとに自分のファイルが書き換わったら、新しい版で読み込み直す${CLR_RST}"
    local td bd out
    td=$(_st_repo); bd=$(mktemp -d)
    cp "$SF_TOOLS_DIR/bin/sf-launcher.sh" "$bd/sf-launcher.sh"
    mkdir -p "$td/sf-tools/logs"   # 本物の force-* では、sf-start.sh のログで、すでにある
    # 起動して 2 秒後に書き換え（git pull の代わり。秒の単位の環境でも新しく見えるよう間を空ける）、待ち切れ（5 秒）のあとに q
    out=$( (cd "$td" && { sleep 2; echo '# 書き換え' >> "$bd/sf-launcher.sh"; sleep 8; printf 'q'; } | TERM_PROGRAM= bash "$bd/sf-launcher.sh" 2>&1) | sed $'s/\033\\[[0-9;]*m//g')
    assert_output_contains "$out" "↻ sf-tools が更新されたため、ランチャーを読み込み直します" "書き換わった → 読み込み直すことを出す"
    [[ $(printf '%s\n' "$out" | grep -c '>> LAUNCHER <<') -ge 2 ]] && pass "読み込み直したあと、メニューを描き直す" || fail "読み込み直したあと、メニューを描き直す" "$out"
    assert_output_contains "$out" "終了しました" "読み込み直したあとも、入力（q）を受け付ける"
    ls "$td"/sf-tools/logs/.launcher-* >/dev/null 2>&1 && fail "終了のあと、印のファイルを消す" || pass "終了のあと、印のファイルを消す"
    out=$( (cd "$td" && { sleep 6; printf 'q'; } | TERM_PROGRAM= bash "$bd/sf-launcher.sh" 2>&1) | sed $'s/\033\\[[0-9;]*m//g')
    assert_output_not_contains "$out" "読み込み直します" "書き換わっていない → 待ち切れても、読み込み直さない"
    # 入力がないまま、6 秒後に閉じる（Bash 3.2 では、待ち切れと同じ戻り値の EOF）→ 1 回だけ待ち切れ扱いのあと、終わる
    local t0 ec; t0=$SECONDS
    (cd "$td" && sleep 6 | TERM_PROGRAM= bash "$bd/sf-launcher.sh" >/dev/null 2>&1); ec=$?
    assert_exit_ok $ec "入力が 6 秒後に閉じる → 正常終了"
    (( SECONDS - t0 < 20 )) && pass "入力が 6 秒後に閉じる → 待ち続けずに終わる" || fail "入力が 6 秒後に閉じる → 待ち続けずに終わる" "$((SECONDS - t0)) 秒"
    teardown "$td" "${td}.origin.git" "$bd"
}
test_reload_when_updated

test_bg_status() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 2 行目の結果がないとき、裏で sf-next.sh --status を動かし、終わったら描き直す${CLR_RST}"
    local td mk out n
    td=$(_st_repo); mk=$(mktemp -d)
    mkdir -p "$td/sf-tools/logs"
    # 判定の本体（sf-promote-check.sh）のモック: 呼ばれた回数を数え、少し待ってから、develop が次の結果を返す
    cat > "$mk/pc.sh" <<'MOCK'
#!/bin/bash
echo x >> "${0%/*}/count"
sleep 2
printf '{"mode":"plan","ok":true,"skipped":false,"branch":"feature/x","head":"h","target":"develop","next_tier":"develop","pr_open":"","tiers":["develop","staging","main"],"violations":[],"error":""}\n'
MOCK
    out=$( (cd "$td" && { sleep 25; printf 'q'; } | SF_LAUNCHER_BG_STATUS=1 SF_PROMOTE_CHECK_CMD="$mk/pc.sh" TERM_PROGRAM= bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1) | sed $'s/\033\\[[0-9;]*m//g')
    assert_output_contains "$out" "Branch: （確かめています…）" "結果がない → 裏で判定し、そのあいだは「確かめています」"
    assert_output_contains "$out" "Branch: ▸ develop (次のPR) ⇒ × staging ⇒ × main" "裏の判定が終わる → 描き直して、段階の並びを出す"
    assert_file_contains "$td/sf-tools/logs/next-status.txt" "TIERS=develop staging main" "裏の判定が、next-status.txt を書く"
    [[ -f "$td/sf-tools/logs/sf-next-status.log" ]] && pass "裏の判定は、別のログ（sf-next-status.log）に書く" || fail "裏の判定は、別のログ（sf-next-status.log）に書く"
    n=$(wc -l < "$mk/count" | tr -d ' ')
    assert_equals "$n" "1" "同じ先端のコミットでは、判定は 1 回だけ"

    # 判定できない（終了コード 2）→ 「5 PullRequest で確かめる」に戻し、同じコミットでは、繰り返さない
    rm -f "$td/sf-tools/logs/next-status.txt" "$mk/count"
    cat > "$mk/pc.sh" <<'MOCK'
#!/bin/bash
echo x >> "${0%/*}/count"
printf '{"mode":"plan","ok":false,"next_tier":"","tiers":[],"violations":[],"error":"origin を読めません"}\n'
exit 2
MOCK
    out=$( (cd "$td" && { sleep 20; printf 'q'; } | SF_LAUNCHER_BG_STATUS=1 SF_PROMOTE_CHECK_CMD="$mk/pc.sh" TERM_PROGRAM= bash "$SF_TOOLS_DIR/bin/sf-launcher.sh" 2>&1) | sed $'s/\033\\[[0-9;]*m//g')
    assert_output_contains "$out" "Branch: （5 PullRequest で確かめる）" "裏の判定が失敗 → 「5 PullRequest で確かめる」"
    n=$(wc -l < "$mk/count" | tr -d ' ')
    assert_equals "$n" "1" "失敗しても、同じ先端のコミットでは、繰り返さない"

    # 読み込み直し（exec）のときは、判定したコミットを引き継ぐ（同じコミットで、もう一度判定しない）
    rm -f "$td/sf-tools/logs/next-status.txt" "$mk/count"
    cat > "$mk/pc.sh" <<'MOCK'
#!/bin/bash
echo x >> "${0%/*}/count"
sleep 6
exit 2
MOCK
    local bd; bd=$(mktemp -d)   # 書き換えてよい sf-tools の写し（bin/ と lib/。sf-next.sh が ../lib を読むため）
    mkdir -p "$bd/bin"
    cp "$SF_TOOLS_DIR/bin/sf-launcher.sh" "$SF_TOOLS_DIR/bin/sf-next.sh" "$bd/bin/"
    cp -r "$SF_TOOLS_DIR/lib" "$bd/lib"
    out=$( (cd "$td" && { sleep 3; echo '# 書き換え' >> "$bd/bin/sf-launcher.sh"; sleep 14; printf 'q'; } | SF_LAUNCHER_BG_STATUS=1 SF_PROMOTE_CHECK_CMD="$mk/pc.sh" TERM_PROGRAM= bash "$bd/bin/sf-launcher.sh" 2>&1) | sed $'s/\033\\[[0-9;]*m//g')
    assert_output_contains "$out" "読み込み直します" "判定中に書き換わる → 読み込み直す"
    n=$(wc -l < "$mk/count" | tr -d ' ')
    assert_equals "$n" "1" "読み込み直しても、同じ先端のコミットでは、判定は 1 回だけ（引き継ぐ）"
    teardown "$td" "${td}.origin.git" "$mk" "$bd"
}
test_bg_status

test_handoff_to_sf_start() {
    echo ""; echo -e "${CLR_HEAD}[TEST] メニューを sf-start.sh を通さずに開く → sf-start.sh に切り替える（入口をそろえる）${CLR_RST}"
    local td bd out
    td=$(setup_force_dir); bd=$(mktemp -d)
    mkdir -p "$bd/bin" "$td/sf-tools/logs"
    cp "$SF_TOOLS_DIR/bin/sf-launcher.sh" "$bd/bin/"
    # sf-start.sh のモック: 呼ばれたこと・受け取った SF_LAUNCHER_ACTIVE・引数の数を書く
    cat > "$bd/bin/sf-start.sh" <<'MOCK'
#!/bin/bash
echo "start ACTIVE=${SF_LAUNCHER_ACTIVE:-} ARGS=$#" >> "${0%/*}/start.calls"
MOCK
    out=$( (cd "$td" && echo "q" | env -u SF_LAUNCHER_FROM_START -u SF_LAUNCHER_ACTIVE bash "$bd/bin/sf-launcher.sh" 2>&1) | sed $'s/\033\\[[0-9;]*m//g')
    assert_file_contains "$bd/bin/start.calls" "start ACTIVE= ARGS=0" "印なしのメニュー → sf-start.sh を引数なしで動かす（SF_LAUNCHER_ACTIVE は外す）"
    assert_output_contains "$out" "sf-start で開きます" "切り替えるとき → 「sf-start で開きます」と出す"
    assert_output_not_contains "$out" "番号を入力" "切り替えるとき → 自分ではメニューを出さない"

    # sf-start.sh からの起動（SF_LAUNCHER_FROM_START=1）→ 切り替えず、メニューを出す
    rm -f "$bd/bin/start.calls"
    out=$( (cd "$td" && echo "q" | env -u SF_LAUNCHER_ACTIVE SF_LAUNCHER_FROM_START=1 bash "$bd/bin/sf-launcher.sh" 2>&1) | sed $'s/\033\\[[0-9;]*m//g')
    [[ ! -f "$bd/bin/start.calls" ]] && pass "sf-start.sh からの起動 → 切り替えない" || fail "sf-start.sh からの起動 → 切り替えない" "$(cat "$bd/bin/start.calls")"
    assert_output_contains "$out" "番号を入力" "sf-start.sh からの起動 → メニューを出す"

    # ランチャーの中から開かれた（起動したときに SF_LAUNCHER_ACTIVE=1）→ 切り替えない（行ったり来たりしない）
    rm -f "$bd/bin/start.calls"
    (cd "$td" && echo "q" | env -u SF_LAUNCHER_FROM_START SF_LAUNCHER_ACTIVE=1 bash "$bd/bin/sf-launcher.sh" > /dev/null 2>&1)
    [[ ! -f "$bd/bin/start.calls" ]] && pass "起動したときに SF_LAUNCHER_ACTIVE=1 → 切り替えない" || fail "起動したときに SF_LAUNCHER_ACTIVE=1 → 切り替えない" "$(cat "$bd/bin/start.calls")"

    # 印を付けない古い版の sf-start.sh から（SF_LOG_OWNER の PID が生きている）→ 切り替えない
    rm -f "$bd/bin/start.calls"
    (cd "$td" && echo "q" | env -u SF_LAUNCHER_FROM_START -u SF_LAUNCHER_ACTIVE SF_LOG_OWNER="$$:1:gitbash1" bash "$bd/bin/sf-launcher.sh" > /dev/null 2>&1)
    [[ ! -f "$bd/bin/start.calls" ]] && pass "SF_LOG_OWNER の PID が生きている → 切り替えない（古い版の sf-start.sh から）" || fail "SF_LOG_OWNER の PID が生きている → 切り替えない（古い版の sf-start.sh から）" "$(cat "$bd/bin/start.calls")"
    # 持ち主の PID が死んでいる（sf-start.sh が終わったあとの残り）→ 切り替える
    rm -f "$bd/bin/start.calls"
    local dead; bash -c 'exit 0' & dead=$!; wait "$dead"
    (cd "$td" && echo "q" | env -u SF_LAUNCHER_FROM_START -u SF_LAUNCHER_ACTIVE SF_LOG_OWNER="${dead}:1:gitbash1" bash "$bd/bin/sf-launcher.sh" > /dev/null 2>&1)
    assert_file_contains "$bd/bin/start.calls" "start ACTIVE=" "SF_LOG_OWNER の PID が死んでいる → 切り替える"

    # 番号の指定 → 切り替えない
    rm -f "$bd/bin/start.calls"; : > "$bd/bin/sf-check.sh"
    (cd "$td" && env -u SF_LAUNCHER_FROM_START -u SF_LAUNCHER_ACTIVE bash "$bd/bin/sf-launcher.sh" 1 > /dev/null 2>&1)
    [[ ! -f "$bd/bin/start.calls" ]] && pass "番号の指定 → 切り替えない" || fail "番号の指定 → 切り替えない" "$(cat "$bd/bin/start.calls")"

    # 読み込み直し（exec）→ 新しい版も、切り替えない（SF_LAUNCHER_FROM_START が環境に残る）
    rm -f "$bd/bin/start.calls"
    out=$( (cd "$td" && { sleep 3; echo '# 書き換え' >> "$bd/bin/sf-launcher.sh"; sleep 8; printf 'q'; } | env -u SF_LAUNCHER_ACTIVE SF_LAUNCHER_FROM_START=1 bash "$bd/bin/sf-launcher.sh" 2>&1) | sed $'s/\033\\[[0-9;]*m//g')
    assert_output_contains "$out" "読み込み直します" "（前提）書き換え → 読み込み直す"
    [[ ! -f "$bd/bin/start.calls" ]] && pass "読み込み直し → 切り替えない" || fail "読み込み直し → 切り替えない" "$(cat "$bd/bin/start.calls")"

    # sf-start.sh がない → そのままメニューを出す
    rm -f "$bd/bin/start.calls" "$bd/bin/sf-start.sh"
    out=$( (cd "$td" && echo "q" | env -u SF_LAUNCHER_FROM_START -u SF_LAUNCHER_ACTIVE bash "$bd/bin/sf-launcher.sh" 2>&1) | sed $'s/\033\\[[0-9;]*m//g')
    assert_output_contains "$out" "番号を入力" "sf-start.sh がない → そのままメニューを出す"
    teardown "$td" "$bd"
}
test_handoff_to_sf_start

print_summary
