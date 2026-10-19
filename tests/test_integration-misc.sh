#!/bin/bash
# ==============================================================================
# test_integration-misc.sh - 結合テスト L1: 開発の日常の分岐・設定の不正・再実行
# ==============================================================================
# 実際の git と fake で、日常の分岐（デプロイの失敗と修正・強制デプロイ）、設定ファイルの不正、
# 古い ~/sf-tools、ツール更新の間隔、コマンドの再実行（冪等）を確かめる。
# ハーネスと fake は tests/integration/lib.sh。計画: doc/integration-test-plan.md
#
# 【シナリオ】
#   A1   壊れた Apex → sf-dryrun が失敗 → 直す → 通る
#   A12  sf-deploy: 強制デプロイの確認（n は何も呼ばない・Y は --ignore-conflicts で呼ぶ）
#   X3-2 branches.txt が壊れている（空・重複・不正な名前）→ push のフックが、安全に動く
#   X3-3 deploy-target.txt の書式の不正・CRLF → sf-dryrun が、止める／通す
#   X3-4 ~/sf-tools が古い → sf-sync-wf が、更新を求める（--check は、更新せず中断）
#   A10  sf-install: node_modules の最新判定（package-lock）と、ツール更新の 24 時間の間隔
#   X8-1 再実行の表: sf-hook・sf-unhook を、続けて 2 回実行しても、同じ結果になる
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
source "$(dirname "${BASH_SOURCE[0]}")/integration/lib.sh"
echo -e "${CLR_HEAD}=== 結合テスト L1: 日常の分岐・設定の不正・再実行 ===${CLR_RST}"

trap 'it_teardown' EXIT

_head() { _it_git -C "$1" rev-parse HEAD; }
_hooks_sum() { ( cd "$1/.git/hooks" 2>/dev/null && for f in pre-commit pre-push; do [[ -f "$f" ]] && cksum < "$f" || echo none; done | tr '\n' ' '; ); }

test_setup() {
    it_setup || { fail "サンドボックスの作成"; return 1; }
    it_seed_repo 1 || { fail "リポジトリの生成"; return 1; }
    it_make_clone devA JOB-A || { fail "クローンの作成" "$(it_out)"; return 1; }
    CL="$IT_CL"
    pass "準備: クローン（JOB-A）を作った"
}

test_A1() {
    echo -e "\n${CLR_HEAD}--- A1: 壊れた Apex → dryrun 失敗 → 直す → 通る ---${CLR_RST}"
    it_add_class "$CL" ItBroken "public class ItBroken { Integer x = ; }"
    it_set_deploy_target "$CL" JOB-A "force-app/main/default/classes/ItBroken.cls"
    it_deploy_fail on "Deploy Failed: force-app/main/default/classes/ItBroken.cls (1:40): Unexpected token ';'"
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-dryrun.sh" -n
    assert_exit_fail "$IT_RC" "A1: 壊れた Apex は、sf-dryrun が失敗する"
    it_out_has "Unexpected token" && pass "A1: 失敗の理由（コンパイルエラー）が、表示される" || fail "A1: 失敗の理由（コンパイルエラー）が、表示される"
    assert_equals "$(it_mutating_calls | wc -l | tr -d ' ')" "0" "A1: dry-run は、組織へ書き込まない"
    # 直す
    it_deploy_fail off
    it_add_class "$CL" ItBroken "public class ItBroken { Integer x = 1; }"
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-dryrun.sh" -n
    assert_exit_ok "$IT_RC" "A1: 直すと、sf-dryrun が通る"
}

test_A12() {
    echo -e "\n${CLR_HEAD}--- A12: sf-deploy（強制デプロイ）の確認 ---${CLR_RST}"
    it_calls_clear
    it_run "$CL" -i 'n\n' bash "$IT_HOME/sf-tools/bin/sf-deploy.sh"
    assert_exit_fail "$IT_RC" "A12: 確認に n → 中断する"
    assert_equals "$(it_calls sf | grep -c 'project deploy start')" "0" "A12: n のとき、デプロイを呼ばない"
    it_calls_clear
    it_run "$CL" -i 'Y\n' bash "$IT_HOME/sf-tools/bin/sf-deploy.sh"
    assert_exit_ok "$IT_RC" "A12: 確認に Y → 強制デプロイが成功する"
    it_calls sf | grep 'project deploy start' | grep -q -- '--ignore-conflicts' && pass "A12: 強制デプロイは、--ignore-conflicts で呼ばれる" || fail "A12: 強制デプロイは、--ignore-conflicts で呼ばれる" "$(it_calls sf | grep deploy)"
}

test_X3_2() {
    echo -e "\n${CLR_HEAD}--- X3-2: branches.txt が壊れている ---${CLR_RST}"
    local bt="$CL/sf-tools/config/branches.txt" label content
    [[ -f "$bt" ]] || { fail "X3-2: branches.txt がない"; return; }
    local orig; orig=$(cat "$bt")
    while IFS='|' read -r label content; do
        [[ -n "$label" ]] || continue
        printf '%b' "$content" > "$bt"
        echo "x $label" > "$CL/sf-tools/ittmp.txt"
        it_run "$CL" bash -c "git add -A && git commit -q -m 'x' --no-verify && git push -q origin JOB-A"
        assert_exit_ok "$IT_RC" "X3-2: branches.txt（${label}）でも、push のフックが、安全に動いて push できる"
        [[ -e "$CL/--upload-pack=touch evil" || -e "$IT_ROOT/evil" ]] && fail "X3-2: 不正な名前は、実行されない" || pass "X3-2（${label}）: 不正な名前は、コマンドとして実行されない"
    done << 'ROWS'
空|
重複|main\nmain\nmain\n
不正な名前（オプションの形）|main\n--upload-pack=touch evil\n
不正な名前（空白・記号）|main\nbad name;ls\n$(touch evil)\n
ROWS
    # origin にないブランチ名が書かれていても、push は止まらない（その名前だけ取得せず、警告する。以前は、すべての push が止まった）
    printf 'main\nno-such-branch\n' > "$bt"
    echo "y" > "$CL/sf-tools/ittmp.txt"
    it_run "$CL" bash -c "git add -A && git commit -q -m 'y' --no-verify && git push origin JOB-A"
    assert_exit_ok "$IT_RC" "X3-2: origin にないブランチ名が書かれていても、push は、止まらない"
    it_out_has "origin に、まだありません（取得しません）: no-such-branch" && pass "X3-2: 取得しなかったブランチを、警告で知らせる" || fail "X3-2: 取得しなかったブランチを、警告で知らせる" "$(it_out | tail -6)"
    printf '%s\n' "$orig" > "$bt"
    it_run "$CL" bash -c "git add -A && git commit -q -m 'z' --no-verify && git push -q origin JOB-A"
    assert_exit_ok "$IT_RC" "X3-2: branches.txt を戻すと、push が通る"
}

test_X3_3() {
    echo -e "\n${CLR_HEAD}--- X3-3: deploy-target.txt の書式の不正・CRLF ---${CLR_RST}"
    local dt="$CL/sf-tools/release/JOB-A/deploy-target.txt" label content
    it_add_class "$CL" ItFmt
    while IFS='|' read -r label content kind; do
        [[ -n "$label" ]] || continue
        printf '%b' "$content" > "$dt"
        it_calls_clear
        it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-dryrun.sh" -n
        if [[ "$kind" == "ng" ]]; then
            assert_exit_fail "$IT_RC" "X3-3: ${label} → 止まる"
            assert_equals "$(it_calls sf | grep -c 'deploy start')" "0" "X3-3: ${label} → デプロイ（検証）まで進まない"
        else
            assert_exit_ok "$IT_RC" "X3-3: ${label} → 通る"
        fi
    done << 'ROWS'
members にコロンがない|[members]\nApexClass\n|ng
members の名前が空|[members]\nApexClass:\n|ng
members の種別が空|[members]\n:Name\n|ng
存在しないファイル|[files]\nforce-app/main/default/classes/Nope.cls\n|ng
CRLF の改行（Windows で編集）|[files]\r\nforce-app/main/default/classes/ItFmt.cls\r\n|ok
前後に空白・コメント・空行|# コメント\n\n[files]\n  force-app/main/default/classes/ItFmt.cls  \n|ok
ROWS
}

test_X3_4() {
    echo -e "\n${CLR_HEAD}--- X3-4: ~/sf-tools が古い ---${CLR_RST}"
    local h0; h0=$(_head "$CL")
    it_sftools_advance || { fail "X3-4: 準備（sf-tools の新しい版）"; return; }
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-sync-wf.sh" --check
    assert_exit_fail "$IT_RC" "X3-4: ~/sf-tools が古いとき、--check は、更新せずに中断する"
    # 通常の実行: 更新の確認 n → 中断（sf-tools は、古いまま）
    local before; before=$(_it_git -C "$IT_HOME/sf-tools" rev-parse HEAD)
    it_run "$CL" -i 'n\n' bash "$IT_HOME/sf-tools/bin/sf-sync-wf.sh"
    assert_exit_fail "$IT_RC" "X3-4: 更新を断ると、sf-sync-wf は中断する"
    assert_equals "$(_it_git -C "$IT_HOME/sf-tools" rev-parse HEAD)" "$before" "X3-4: 更新を断ると、~/sf-tools は、変わらない"
    # 更新を許可: 更新して、続行する
    it_run "$CL" -i 'Y\nn\nn\n' bash "$IT_HOME/sf-tools/bin/sf-sync-wf.sh"   # 更新に Y → 更新した版で再実行 → 警告の確認に n
    [[ "$(_it_git -C "$IT_HOME/sf-tools" rev-parse HEAD)" != "$before" ]] && pass "X3-4: 更新を許可すると、~/sf-tools が新しい版になる" || fail "X3-4: 更新を許可すると、~/sf-tools が新しい版になる" "$(it_out | tail -6)"
    assert_equals "$(_head "$CL")" "$h0" "X3-4: クローンのコミットは、変わらない"
}

test_A10() {
    echo -e "\n${CLR_HEAD}--- A10: sf-install の node_modules の判定・ツール更新の間隔 ---${CLR_RST}"
    local lock="$CL/package-lock.json" nm="$CL/node_modules/.package-lock.json" i
    echo "{}" > "$lock"; mkdir -p "$CL/node_modules"; echo "{}" > "$nm"
    touch -t 202601010000 "$lock"        # lock が古い・node_modules が新しい → 最新
    it_calls_clear
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-install.sh"
    assert_exit_ok "$IT_RC" "A10: sf-install が成功する（node_modules は最新）"
    assert_equals "$(it_calls npm | grep -c '^npm install$')" "0" "A10: node_modules が最新なら、npm install を呼ばない"
    touch "$lock"; touch -t 202601010000 "$nm"   # lock が新しい → 更新が必要
    it_calls_clear
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-install.sh"
    assert_equals "$(it_calls npm | grep -c '^npm install$')" "1" "A10: package-lock が新しければ、npm install を呼ぶ"
    # ツール更新: スタンプが新しい（24 時間以内）→ 起動しない
    it_calls_clear
    assert_equals "$(it_calls npm | grep -c 'install -g')" "0" "A10: スタンプが新しければ、ツール更新（npm install -g）を呼ばない"
    # スタンプを古くする → 起動する。Windows で本物の Git 更新が動かないよう、先に止める
    it_block_git_update
    touch -t 202601010000 "$IT_HOME/.sf-tools-last-update"
    it_calls_clear
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-install.sh"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        it_calls npm | grep -q 'install -g @salesforce/cli' && break
        sleep 1
    done
    it_calls npm | grep -q 'install -g @salesforce/cli' && pass "A10: スタンプが古ければ、ツール更新（sf-upgrade）が動く" || fail "A10: スタンプが古ければ、ツール更新（sf-upgrade）が動く"
    [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]] && { it_calls git | grep -q 'update-git-for-windows' && pass "A10: Git の更新は、代理が受け止め、本物は動かない" || true; }
    sleep 2   # バックグラウンドの sf-upgrade の終了を待つ
}

test_X8_1() {
    echo -e "\n${CLR_HEAD}--- X8-1: 再実行の表（sf-hook・sf-unhook を 2 回）---${CLR_RST}"
    local s1 s2 h0; h0=$(_head "$CL")
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-hook.sh"; s1=$(_hooks_sum "$CL")
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-hook.sh"; s2=$(_hooks_sum "$CL")
    assert_exit_ok "$IT_RC" "X8-1: sf-hook の 2 回目も、成功する"
    assert_equals "$s2" "$s1" "X8-1: sf-hook を 2 回実行しても、フックの内容は同じ"
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-unhook.sh"
    assert_exit_ok "$IT_RC" "X8-1: sf-unhook が成功する"
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-unhook.sh"
    assert_exit_ok "$IT_RC" "X8-1: sf-unhook の 2 回目（すでに外れている）も、失敗しない"
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-hook.sh"
    assert_equals "$(_hooks_sum "$CL")" "$s1" "X8-1: unhook → hook で、元のフックに戻る"
    assert_equals "$(_head "$CL")" "$h0" "X8-1: どれも、コミットを作らない"
}

_it_timed() { local t0=$SECONDS rc; "$@"; rc=$?; echo "  （所要時間: $1 = $((SECONDS - t0)) 秒）"; return $rc; }

test_setup || { print_summary; exit 1; }
for _sc in ${IT_SCENARIOS:-A1 A12 X3_2 X3_3 X3_4 A10 X8_1}; do
    _it_timed "test_${_sc}" || break
done

print_summary
