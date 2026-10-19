#!/bin/bash
# ==============================================================================
# test_integration-next.sh - 結合テスト L1: sf-next（次の PR 先の判定）と、main が進んだときの取り込み
# ==============================================================================
# 実際の git（3 層: main + staging + develop）と、fake の gh（PR の一覧は state/prs）で、sf-next が、
# 作業ブランチの、各環境ブランチへのマージの状況（なし・PR 発行中・マージ済み・同期のみ・順序外）を、正しく判定することを確かめる。
# ハーネスと fake は tests/integration/lib.sh。計画: doc/integration-test-plan.md の A5
#
# 【シナリオ】
#   A5-1  PR なし → 次の PR 先は develop（いちばん下の環境から）
#   A5-2  develop への PR が発行中 → 「PR発行中」・次の PR 先は staging
#   A5-3  develop へマージ済み → 「マージ済み」・次の PR 先は staging
#   A5-4  順序外: develop をとばして、main へ PR がマージ済み → 「順序外」の警告
#   A5-5  他の人が先にマージして、origin の develop が進んだ → sf-push が取り込み、判定は変わらない（取り込んだ結果で、push できる）
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
source "$(dirname "${BASH_SOURCE[0]}")/integration/lib.sh"
echo -e "${CLR_HEAD}=== 結合テスト L1: sf-next ===${CLR_RST}"

trap 'it_teardown' EXIT

_next() { it_run "$CL" -i "${1:-n\n}" bash "$IT_HOME/sf-tools/bin/sf-next.sh"; [[ $IT_RC -eq 0 ]] || { echo "--- sf-next 失敗の出力:"; it_out | tail -8; }; }   # 既定は、PR を出すかの確認に n
_has() { it_out_has "$1"; }

test_setup() {
    it_setup || { fail "サンドボックスの作成"; return 1; }
    it_seed_repo 3 || { fail "リポジトリの生成（3 層）"; return 1; }
    it_make_clone devA JOB-A || { fail "クローンの作成" "$(it_out)"; return 1; }
    CL="$IT_CL"
    IT_TIMEOUT=300
    # JOB-A に、コミットを 1 つ作って push（main と違う内容にする）
    it_add_class "$CL" ItNext
    it_set_deploy_target "$CL" JOB-A "force-app/main/default/classes/ItNext.cls"
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-push.sh"
    [[ $IT_RC -eq 0 ]] || { fail "準備: sf-push" "$(it_out | tail -5)"; return 1; }
    pass "準備: 3 層のリポジトリと、コミットのある JOB-A を作った"
}

test_A5() {
    echo -e "\n${CLR_HEAD}--- A5: sf-next の判定 ---${CLR_RST}"
    # A5-1: PR なし
    it_pr_clear
    _next
    assert_exit_ok "$IT_RC" "A5-1: sf-next が成功する"
    _has "develop" && pass "A5-1: 環境ブランチ（develop）が表示される" || fail "A5-1: 環境ブランチ（develop）が表示される" "$(it_out | tail -8)"
    it_out | sed 's/\x1b\[[0-9;]*m//g' | grep -E "develop|staging|main" | grep -q "▶ develop" && pass "A5-1: 次の PR 先は、いちばん下の develop" || fail "A5-1: 次の PR 先は、いちばん下の develop" "$(it_out | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'develop|staging|main' | head -4)"

    # A5-2: develop への PR が発行中
    it_pr_add open JOB-A develop
    _next
    it_out | sed 's/\x1b\[[0-9;]*m//g' | grep -E "develop" | grep -q "PR発行中" && pass "A5-2: develop は「PR発行中」" || fail "A5-2: develop は「PR発行中」" "$(it_out | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'develop|staging|main' | head -4)"
    it_out | sed 's/\x1b\[[0-9;]*m//g' | grep -E "staging" | grep -q "▶" && pass "A5-2: 次の PR 先は staging" || fail "A5-2: 次の PR 先は staging" "$(it_out | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'develop|staging|main' | head -4)"

    # A5-3: develop へマージ済み（origin の develop が、JOB-A を含む。PR は merged）
    it_pr_clear; it_pr_add merged JOB-A develop
    it_origin_merge JOB-A develop || { fail "A5-3: 準備（origin の develop へのマージ）"; return; }
    _next
    it_out | sed 's/\x1b\[[0-9;]*m//g' | grep -E "develop" | grep -q "マージ済み" && pass "A5-3: develop は「マージ済み」" || fail "A5-3: develop は「マージ済み」" "$(it_out | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'develop|staging|main' | head -4)"
    it_out | sed 's/\x1b\[[0-9;]*m//g' | grep -E "staging" | grep -q "▶" && pass "A5-3: 次の PR 先は staging" || fail "A5-3: 次の PR 先は staging" "$(it_out | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'develop|staging|main' | head -4)"

    # A5-4: 順序外（develop は PR 発行中のまま、main へ、先にマージ済み）
    it_pr_clear; it_pr_add open JOB-A develop; it_pr_add merged JOB-A main
    it_origin_merge JOB-A main || { fail "A5-4: 準備（origin の main へのマージ）"; return; }
    _next
    it_out | sed 's/\x1b\[[0-9;]*m//g' | grep -E "main" | grep -q "順序外" && pass "A5-4: main は「順序外マージ済み」の警告" || fail "A5-4: main は「順序外マージ済み」の警告" "$(it_out | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'develop|staging|main' | head -5)"
}

test_A5_5() {
    echo -e "\n${CLR_HEAD}--- A5-5: 他の人が先にマージ → 取り込んで、push できる ---${CLR_RST}"
    local r0
    # 別の開発者が、origin の main に、無関係なファイルを積む（自分の JOB-A は、まだ取り込んでいない）
    it_origin_commit main "docs/others.md" "他の人" "他の人: main に追加" || { fail "A5-5: 準備"; return; }
    it_add_class "$CL" ItNext2
    it_set_deploy_target "$CL" JOB-A "force-app/main/default/classes/ItNext.cls" "force-app/main/default/classes/ItNext2.cls"
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-push.sh"
    assert_exit_ok "$IT_RC" "A5-5: main が進んでいても、sf-push が、取り込んで、成功する"
    assert_file_exists "$CL/docs/others.md" "A5-5: 他の人の main の変更が、取り込まれる"
    assert_equals "$(_it_git --git-dir="$IT_ORIGIN" rev-parse refs/heads/JOB-A)" "$(_it_git -C "$CL" rev-parse HEAD)" "A5-5: 取り込んだ結果が、origin に届く"
    _next
    assert_exit_ok "$IT_RC" "A5-5: 取り込み後も、sf-next が成功する"
}

test_A5_6() {
    echo -e "
${CLR_HEAD}--- A5-6: 「PR を出しますか」に Y → 開く URL（https の compare）---${CLR_RST}"
    it_pr_clear; it_calls_clear
    _next 'Y
'
    assert_exit_ok "$IT_RC" "A5-6: Y で、成功する"
    it_calls | grep -q "^browser .*https://github.com/${IT_OWNER}/${IT_REPO}/compare/" && pass "A5-6: 開く URL は、https の PR 作成画面（origin が ssh:// でも）" || fail "A5-6: 開く URL は、https の PR 作成画面" "$(it_calls | grep browser | head -2)"
    assert_equals "$(it_mutating_calls | wc -l | tr -d ' ')" "0" "A5-6: PR の作成は、ブラウザで行う（gh で、書き込まない）"
}

_it_timed() { local t0=$SECONDS rc; "$@"; rc=$?; echo "  （所要時間: $1 = $((SECONDS - t0)) 秒）"; return $rc; }

test_setup || { print_summary; exit 1; }
for _sc in ${IT_SCENARIOS:-A5 A5_5 A5_6}; do
    _it_timed "test_${_sc}" || break
done

print_summary
