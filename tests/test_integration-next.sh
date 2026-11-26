#!/bin/bash
# ==============================================================================
# test_integration-next.sh - 結合テスト L1: sf-next（次の PR 先の判定）と、main が進んだときの取り込み
# ==============================================================================
# 実際の git（3 層: main + staging + develop）と、fake の gh（PR の一覧は state/prs・リリースの印は state/marks）で、sf-next が、
# 作業ブランチの先端のコミットが、どの段階まで出たか（一方通行の決まり。sf-promote-check.sh --plan）を、正しく判定することを確かめる。
# ハーネスと fake は tests/integration/lib.sh。計画: doc/integration-test-plan.md の A5。決まり: doc/one-way-promotion-design.md
#
# 【シナリオ】
#   A5-1  印なし・PR なし → 次の PR 先は develop（いちばん下の段階から）
#   A5-2  develop への PR が発行中 → 「PR発行中（#番号）」で、新しく PR を作らない
#   A5-3  先端のコミットに develop の印 → develop は「リリース済み（このコミット）」・次の PR 先は staging
#   A5-4  develop に出したあとで変更して push（先端のコミットが変わる）→ 次の PR 先は、develop に戻る（出し直し）。
#         前の develop へのリリースの部品は、今回も含むので、積み重ね（R2）は通る
#   A5-5  他の人が先にマージして、origin の main が進んだ → sf-push が取り込み、push できる。そのあとも、sf-next が成功する
#   A5-6  「PR を出しますか」に Y → 開く URL（https の compare）
#   A5-7  全段階に印 → 「全段階にリリース済みです！」／ 上の段階にだけ印（原則に反する）→ 判断できないとして止まる
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

_lines() { it_out | sed 's/\x1b\[[0-9;]*m//g' | grep -E "develop|staging|main" | head -6; }
_line_has() { it_out | sed 's/\x1b\[[0-9;]*m//g' | grep -E "$1" | grep -qF -- "$2"; }   # 引数: 段階の名前（正規表現） 探す文字列
_head() { _it_git -C "$CL" rev-parse HEAD; }

test_A5() {
    echo -e "\n${CLR_HEAD}--- A5: sf-next の判定（一方通行の決まり）---${CLR_RST}"
    local h1
    h1=$(_head)
    # A5-1: 印なし・PR なし
    it_pr_clear; it_mark_clear
    _next
    assert_exit_ok "$IT_RC" "A5-1: sf-next が成功する"
    _has "develop" && pass "A5-1: 段階（develop）が表示される" || fail "A5-1: 段階（develop）が表示される" "$(it_out | tail -8)"
    _line_has "develop" "▶ develop" && pass "A5-1: 次の PR 先は、いちばん下の develop" || fail "A5-1: 次の PR 先は、いちばん下の develop" "$(_lines)"

    # A5-2: develop への PR が発行中
    it_pr_add open JOB-A develop 12 "$h1"
    _next
    assert_exit_ok "$IT_RC" "A5-2: sf-next が成功する"
    _line_has "develop" "PR発行中（#12）" && pass "A5-2: develop は「PR発行中（#12）」" || fail "A5-2: develop は「PR発行中（#12）」" "$(_lines)"
    _has "発行済みです" && pass "A5-2: 発行済みの PR を案内し、新しく作らない" || fail "A5-2: 発行済みの PR を案内し、新しく作らない" "$(it_out | tail -4)"

    # A5-3: 先端のコミットに develop の印（develop へのリリースが成功した）
    it_pr_clear; it_pr_add merged JOB-A develop 12 "$h1"
    it_origin_merge JOB-A develop || { fail "A5-3: 準備（origin の develop へのマージ）"; return; }
    it_mark_add "$h1" develop
    _next
    assert_exit_ok "$IT_RC" "A5-3: sf-next が成功する"
    _line_has "develop" "リリース済み（このコミット）" && pass "A5-3: develop は「リリース済み（このコミット）」" || fail "A5-3: develop は「リリース済み（このコミット）」" "$(_lines)"
    _line_has "staging" "▶ staging" && pass "A5-3: 次の PR 先は staging" || fail "A5-3: 次の PR 先は staging" "$(_lines)"

    # A5-4: develop に出したあとで変更して push → 先端のコミットが変わり、develop から出し直し（R2 は、前の部品を含むので通る）
    it_add_class "$CL" ItNext3
    it_set_deploy_target "$CL" JOB-A "force-app/main/default/classes/ItNext.cls" "force-app/main/default/classes/ItNext3.cls"
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-push.sh"
    [[ $IT_RC -eq 0 ]] || { fail "A5-4: 準備（変更して sf-push）" "$(it_out | tail -5)"; return; }
    [[ "$(_head)" != "$h1" ]] && pass "A5-4: 変更の push で、先端のコミットが変わった" || fail "A5-4: 変更の push で、先端のコミットが変わった"
    _next
    assert_exit_ok "$IT_RC" "A5-4: sf-next が成功する"
    _line_has "develop" "▶ develop" && pass "A5-4: 次の PR 先は develop に戻る（develop に出したあとの変更は、develop から出し直す）" || fail "A5-4: 次の PR 先は develop に戻る" "$(_lines)"
    _has "R2（積み重ね）" && pass "A5-4: 前の develop へのリリースの部品を、確かめた（積み重ね）" || fail "A5-4: 前の develop へのリリースの部品を、確かめた（積み重ね）" "$(it_out | tail -6)"
    it_out_has "[R2]" && fail "A5-4: 前の部品を含むので、積み重ねの違反にならない" "$(it_out | grep -F '[R2]' | head -2)" || pass "A5-4: 前の部品を含むので、積み重ねの違反にならない"

    # A5-4b: 前の develop へのリリースの部品（ItNext）を外す → 積み重ねの違反で、PR を勧めない
    it_set_deploy_target "$CL" JOB-A "force-app/main/default/classes/ItNext3.cls"
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-push.sh"
    [[ $IT_RC -eq 0 ]] || { fail "A5-4b: 準備（部品を外して sf-push）" "$(it_out | tail -5)"; return; }
    _next
    [[ $IT_RC -ne 0 ]] && pass "A5-4b: 積み重ねの違反があると、sf-next は止まる" || fail "A5-4b: 積み重ねの違反があると、sf-next は止まる" "$(it_out | tail -6)"
    _has "ApexClass:ItNext" && pass "A5-4b: 抜けた部品（ApexClass:ItNext）を表示する" || fail "A5-4b: 抜けた部品（ApexClass:ItNext）を表示する" "$(it_out | tail -6)"
    it_calls | grep -q "^browser " && fail "A5-4b: 違反があるときは、PR の作成画面を開かない" || pass "A5-4b: 違反があるときは、PR の作成画面を開かない"
    # 元に戻す（あとのシナリオのため）
    it_set_deploy_target "$CL" JOB-A "force-app/main/default/classes/ItNext.cls" "force-app/main/default/classes/ItNext3.cls"
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-push.sh"
    [[ $IT_RC -eq 0 ]] || { fail "A5-4b: 後始末（部品を戻して sf-push）" "$(it_out | tail -5)"; return; }
}

test_A5_7() {
    echo -e "\n${CLR_HEAD}--- A5-7: 全段階に印 → 完了 / 上の段階にだけ印 → 止まる ---${CLR_RST}"
    local h
    h=$(_head)
    it_pr_clear; it_mark_clear
    it_mark_add "$h" develop; it_mark_add "$h" staging; it_mark_add "$h" main
    _next
    assert_exit_ok "$IT_RC" "A5-7: 全段階に印があれば、sf-next が成功する"
    _has "全段階にリリース済みです" && pass "A5-7: 「全段階にリリース済みです！」と表示する" || fail "A5-7: 「全段階にリリース済みです！」と表示する" "$(it_out | tail -4)"
    [[ "$(it_out | sed 's/\x1b\[[0-9;]*m//g' | grep -c "リリース済み（このコミット）")" -eq 3 ]] && pass "A5-7: 3 つの段階が、リリース済み" || fail "A5-7: 3 つの段階が、リリース済み" "$(_lines)"
    # 上の段階（main）にだけ印（人が付けたのではなく、原則に反する状態）→ 判断できない
    it_mark_clear; it_mark_add "$h" main
    _next
    [[ $IT_RC -ne 0 ]] && pass "A5-7: 上の段階にだけ印があると、sf-next は止まる" || fail "A5-7: 上の段階にだけ印があると、sf-next は止まる" "$(it_out | tail -4)"
    _has "原則に反する状態" && pass "A5-7: 原則に反する状態と表示する" || fail "A5-7: 原則に反する状態と表示する" "$(it_out | tail -4)"
    # 人（github-actions[bot] でない）が付けた印は、無視する
    it_mark_clear; it_mark_add "$h" develop success someone
    _next
    assert_exit_ok "$IT_RC" "A5-7: 人が付けた印があっても、sf-next は成功する"
    _line_has "develop" "▶ develop" && pass "A5-7: 人が付けた印は無視し、次の PR 先は develop" || fail "A5-7: 人が付けた印は無視し、次の PR 先は develop" "$(_lines)"
    it_mark_clear
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
    it_pr_clear; it_mark_clear; it_calls_clear
    _next 'Y
'
    assert_exit_ok "$IT_RC" "A5-6: Y で、成功する"
    it_calls | grep -q "^browser .*https://github.com/${IT_OWNER}/${IT_REPO}/compare/" && pass "A5-6: 開く URL は、https の PR 作成画面（origin が ssh:// でも）" || fail "A5-6: 開く URL は、https の PR 作成画面" "$(it_calls | grep browser | head -2)"
    assert_equals "$(it_mutating_calls | wc -l | tr -d ' ')" "0" "A5-6: PR の作成は、ブラウザで行う（gh で、書き込まない）"
}

_it_timed() { local t0=$SECONDS rc; "$@"; rc=$?; echo "  （所要時間: $1 = $((SECONDS - t0)) 秒）"; return $rc; }

test_setup || { print_summary; exit 1; }
for _sc in ${IT_SCENARIOS:-A5 A5_5 A5_6 A5_7}; do
    _it_timed "test_${_sc}" || break
done

print_summary
