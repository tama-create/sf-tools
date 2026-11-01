#!/bin/bash
# ==============================================================================
# test_integration-git.sh - 結合テスト L1: 実際の git のフック・マージ・競合
# ==============================================================================
# 実際の git と、ローカルの bare の origin で、フック（pre-commit・pre-push）・取り込み・競合・並行を確かめる。
# ハーネスと fake は tests/integration/lib.sh。計画: doc/integration-test-plan.md
#
# 【シナリオ】
#   A15  pre-commit フック: 実際の git commit が、不備のある変更を止め、直すと通す
#   A2   pre-push フック: 不備のある変更・main への直接 push を止め、直すと通す
#   A5   main が先に進んでいるとき、push の前に自動で取り込む
#   A6   マージコンフリクト: sf-push が中止し、作業フォルダが元のまま。解消すると通る（X4-2 と同じ）
#   A7   2 つのジョブ（ブランチ）を並行して進める。互いに影響しない
#   A9   sf-unhook → push（フックなし）→ sf-hook（再設置）の往復
#   X4-1a 2 つのクローンから、同じブランチへ、同時に push → 片方だけ成功。取り込んで再 push できる
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
source "$(dirname "${BASH_SOURCE[0]}")/integration/lib.sh"
echo -e "${CLR_HEAD}=== 結合テスト L1: git のフック・取り込み・競合 ===${CLR_RST}"

trap 'it_teardown' EXIT

BAD_PATH="force-app/main/default/classes/NoSuchClass.cls"   # 存在しないファイル（sf-check が、エラーにする）

# コミットを作る。引数: クローン メッセージ [git commit の追加の引数]。結果: IT_RC
_commit() { local cl="$1" msg="$2"; shift 2; it_run "$cl" bash -c "git add -A && git commit -q -m \"\$0\" \"\$@\"" "$msg" "$@"; }
_head() { _it_git -C "$1" rev-parse HEAD; }
_count() { _it_git -C "$1" rev-list --count HEAD; }
_remote_ref() { _it_git --git-dir="$IT_ORIGIN" rev-parse "refs/heads/$1" 2>/dev/null; }

test_setup() {
    it_setup || { fail "サンドボックスの作成"; return 1; }
    it_seed_repo 1 || { fail "リポジトリの生成"; return 1; }
    it_make_clone devA JOB-A || { fail "クローン devA の作成" "$(it_out)"; return 1; }
    pass "準備: クローン devA（JOB-A）を作り、フックを設置した"
}

# ------------------------------------------------------------------------------
# A15 / A2: フック
# ------------------------------------------------------------------------------
test_hooks() {
    echo -e "\n${CLR_HEAD}--- A15・A2: pre-commit・pre-push フック ---${CLR_RST}"
    local cl="$IT_CL" c0 r0
    assert_file_exists "$cl/.git/hooks/pre-commit" "A15: pre-commit フックが入っている"
    assert_file_exists "$cl/.git/hooks/pre-push" "A2: pre-push フックが入っている"

    # A15: 存在しないファイルを deploy-target に書いた変更 → git commit が止まる
    it_add_class "$cl" ItOk
    it_set_deploy_target "$cl" JOB-A "$BAD_PATH"
    c0=$(_count "$cl")
    _commit "$cl" "不備のある変更"
    assert_exit_fail "$IT_RC" "A15: 不備のある変更は、git commit が止まる"
    assert_equals "$(_count "$cl")" "$c0" "A15: 止まったとき、コミットは増えない"
    it_out_has "sf-precommit" && pass "A15: pre-commit フック（sf-precommit）が動いた" || fail "A15: pre-commit フック（sf-precommit）が動いた" "$(it_out | tail -5)"

    # 直すと通る
    it_set_deploy_target "$cl" JOB-A "force-app/main/default/classes/ItOk.cls"
    _commit "$cl" "直した変更"
    assert_exit_ok "$IT_RC" "A15: 直すと、git commit が通る"
    assert_equals "$(_count "$cl")" "$((c0 + 1))" "A15: コミットが 1 つ増える"

    # A2: pre-commit を飛ばしたコミット（--no-verify）でも、push のフックが止める
    it_add_class "$cl" ItBad
    it_set_deploy_target "$cl" JOB-A "force-app/main/default/classes/ItOk.cls" "$BAD_PATH"
    _commit "$cl" "フックを飛ばした不備" --no-verify
    assert_exit_ok "$IT_RC" "A2: --no-verify なら、不備のあるコミットが、手元にはできる"
    r0=$(_remote_ref JOB-A)
    it_run "$cl" git push
    assert_exit_fail "$IT_RC" "A2: pre-push フックが、不備のある push を止める"
    assert_equals "$(_remote_ref JOB-A)" "$r0" "A2: 止めたとき、origin は変わらない"
    it_out_has "プッシュを中断しました" && pass "A2: 中断のメッセージが出る" || fail "A2: 中断のメッセージが出る" "$(it_out | tail -5)"

    # 直して、もう 1 つコミットすると push が通る
    it_set_deploy_target "$cl" JOB-A "force-app/main/default/classes/ItOk.cls" "force-app/main/default/classes/ItBad.cls"
    _commit "$cl" "直した"
    it_run "$cl" git push
    assert_exit_ok "$IT_RC" "A2: 直すと、push が通る"
    assert_equals "$(_remote_ref JOB-A)" "$(_head "$cl")" "A2: origin が、手元の HEAD になる"

    # main への直接 push は、フックが止める（X6-3 の、ローカルのフック部分）
    r0=$(_remote_ref main)
    it_run "$cl" bash -c "git checkout -q -b scratch origin/main && echo x > x.txt && git add x.txt && git commit -q -m 'main へ' --no-verify && git branch -q -f main scratch && git checkout -q main && git push origin main"
    assert_exit_fail "$IT_RC" "A2: main への直接 push は、フックが止める"
    assert_equals "$(_remote_ref main)" "$r0" "A2: main は、変わらない"
    it_out_has "直接プッシュは禁止" && pass "A2: 直接プッシュ禁止のメッセージが出る" || fail "A2: 直接プッシュ禁止のメッセージが出る" "$(it_out | tail -5)"
    it_run "$cl" bash -c "git checkout -q JOB-A && git branch -q -D main scratch"
}

# ------------------------------------------------------------------------------
# A5 / A6: main が進んだとき・競合
# ------------------------------------------------------------------------------
test_main_ahead_and_conflict() {
    echo -e "\n${CLR_HEAD}--- A5・A6: main が進んだとき・競合 ---${CLR_RST}"
    local cl="$IT_CL" r0
    # A5: 別の開発者が main に、無関係なファイルを足した（A がまだ取り込んでいない）
    it_origin_commit main "docs/other.md" "他の人の変更" "他の人: main に追加" || { fail "A5: main の変更の準備"; return; }
    it_add_class "$cl" ItNext
    it_set_deploy_target "$cl" JOB-A "force-app/main/default/classes/ItOk.cls" "force-app/main/default/classes/ItBad.cls" "force-app/main/default/classes/ItNext.cls"
    it_run "$cl" bash "$IT_HOME/sf-tools/bin/sf-push.sh"
    assert_exit_ok "$IT_RC" "A5: main が進んでいても、sf-push が成功する"
    assert_file_exists "$cl/docs/other.md" "A5: main の変更が、取り込まれる"
    assert_equals "$(_remote_ref JOB-A)" "$(_head "$cl")" "A5: 取り込んだ結果が、origin に届く"

    # A6: main 側と手元で、同じファイルを、別々に変更（手元は、コミット済み）→ sf-push の取り込みで競合
    it_add_class "$cl" Shared "public class Shared { Integer local; }"
    it_set_deploy_target "$cl" JOB-A "force-app/main/default/classes/ItOk.cls" "force-app/main/default/classes/ItBad.cls" "force-app/main/default/classes/ItNext.cls" "force-app/main/default/classes/Shared.cls"
    _commit "$cl" "Shared を追加（手元）" --no-verify
    it_origin_commit main "force-app/main/default/classes/Shared.cls" "public class Shared { Integer fromMain; }" "他の人: main に Shared を追加" || { fail "A6: 競合の準備"; return; }
    r0=$(_remote_ref JOB-A)
    local h0; h0=$(_head "$cl")
    it_run "$cl" bash "$IT_HOME/sf-tools/bin/sf-push.sh"
    assert_exit_fail "$IT_RC" "A6: 競合すると、sf-push は失敗で終わる"
    assert_equals "$(_head "$cl")" "$h0" "A6: 競合のとき、手元の HEAD は元のまま（マージを中止している）"
    assert_equals "$(_remote_ref JOB-A)" "$r0" "A6: 競合のとき、origin は変わらない"
    assert_equals "$(_it_git -C "$cl" ls-files -u | wc -l | tr -d ' ')" "0" "A6: 競合の途中の状態（未解決）が、残らない"
    it_out_has "origin/main とのマージに失敗しました" && pass "A6: マージの失敗のメッセージが出る" || fail "A6: マージの失敗のメッセージが出る" "$(it_out | tail -5)"
    # 理由（git merge の出力。競合したファイル名を含む。git の表示言語によらず、ファイル名は出る）も、-v なしで出る
    it_out_has "Shared.cls" && pass "A6: 失敗の理由（競合したファイル）が出る" || fail "A6: 失敗の理由（競合したファイル）が出る" "$(it_out | tail -5)"
    # 解消（手で取り込み、競合は、手元の側を採用）→ sf-push が通る
    it_run "$cl" bash -c "git fetch -q origin && git merge -q -X ours --no-edit origin/main"
    assert_exit_ok "$IT_RC" "A6: 手で競合を解消できる"
    it_run "$cl" bash "$IT_HOME/sf-tools/bin/sf-push.sh"
    assert_exit_ok "$IT_RC" "A6: 解消後は、sf-push が通る"
    assert_equals "$(_remote_ref JOB-A)" "$(_head "$cl")" "A6: 解消した結果が、origin に届く"
}

# ------------------------------------------------------------------------------
# A7: 2 つのジョブ
# ------------------------------------------------------------------------------
test_parallel_jobs() {
    echo -e "\n${CLR_HEAD}--- A7: 2 つのジョブを並行して進める ---${CLR_RST}"
    it_make_clone devB JOB-B || { fail "A7: devB の作成" "$(it_out)"; return; }
    local clb="$IT_CL" cla="$IT_WORK/devA/$IT_REPO" ra rb
    ra=$(_remote_ref JOB-A)
    it_add_class "$clb" ItJobB
    it_set_deploy_target "$clb" JOB-B "force-app/main/default/classes/ItJobB.cls"
    it_run "$clb" bash "$IT_HOME/sf-tools/bin/sf-push.sh"
    assert_exit_ok "$IT_RC" "A7: JOB-B の sf-push が成功する"
    assert_equals "$(_remote_ref JOB-A)" "$ra" "A7: JOB-B の push は、JOB-A に影響しない"
    assert_equals "$(cat "$cla/sf-tools/release/branch_name.txt")" "JOB-A" "A7: JOB-A のクローンの branch_name は JOB-A のまま"
    assert_equals "$(cat "$clb/sf-tools/release/branch_name.txt")" "JOB-B" "A7: JOB-B のクローンの branch_name は JOB-B"
    [[ -f "$clb/force-app/main/default/classes/ItOk.cls" ]] && fail "A7: JOB-B に JOB-A のクラスが混ざらない" || pass "A7: JOB-B に JOB-A のクラスが混ざらない"
    rb=$(_remote_ref JOB-B)
    it_run "$clb" bash "$IT_HOME/sf-tools/bin/sf-dryrun.sh" -n
    assert_exit_ok "$IT_RC" "A7: JOB-B の sf-dryrun が成功する"
    it_calls sf | grep -q "release/JOB-B/package.xml" && pass "A7: sf-dryrun は、JOB-B の release を使う" || fail "A7: sf-dryrun は、JOB-B の release を使う"
    assert_equals "$(_remote_ref JOB-B)" "$rb" "A7: sf-dryrun は origin を変えない"
}

# ------------------------------------------------------------------------------
# A9: sf-unhook ⇄ sf-hook
# ------------------------------------------------------------------------------
test_unhook_hook() {
    echo -e "\n${CLR_HEAD}--- A9: sf-unhook → push → sf-hook ---${CLR_RST}"
    local cl="$IT_WORK/devB/$IT_REPO" r0
    it_run "$cl" bash "$IT_HOME/sf-tools/bin/sf-unhook.sh"
    assert_exit_ok "$IT_RC" "A9: sf-unhook が成功する"
    [[ -f "$cl/.git/hooks/pre-push" ]] && fail "A9: pre-push フックが外れる" || pass "A9: pre-push フックが外れる"
    assert_file_exists "$cl/.git/hooks/pre-commit" "A9: 【意図した仕様（確認済み）】sf-unhook は pre-push だけを外す（pre-commit は残る。プッシュの検証だけを止めるのが狙い）"
    it_add_class "$cl" ItNoHook
    it_set_deploy_target "$cl" JOB-B "force-app/main/default/classes/ItJobB.cls" "$BAD_PATH"
    _commit "$cl" "push フックなしで、不備のある変更" --no-verify   # pre-commit は残るため、--no-verify で通す
    assert_exit_ok "$IT_RC" "A9: 不備のあるコミットを、手元に作る（--no-verify）"
    it_run "$cl" git push
    assert_exit_ok "$IT_RC" "A9: フックなしなら、不備のある push も通る（フックが外れている証拠）"
    it_run "$cl" bash "$IT_HOME/sf-tools/bin/sf-hook.sh"
    assert_exit_ok "$IT_RC" "A9: sf-hook が成功する"
    assert_file_exists "$cl/.git/hooks/pre-push" "A9: pre-push フックが戻る"
    it_set_deploy_target "$cl" JOB-B "force-app/main/default/classes/ItJobB.cls" "$BAD_PATH"
    echo "x" >> "$cl/force-app/main/default/classes/ItNoHook.cls"
    _commit "$cl" "再設置後の不備のある変更"
    assert_exit_fail "$IT_RC" "A9: フックを戻すと、また止まる"
    it_run "$cl" git reset -q --hard HEAD
}

# ------------------------------------------------------------------------------
# X4-1a: 同じブランチへ、同時に push
# ------------------------------------------------------------------------------
test_concurrent_push() {
    echo -e "\n${CLR_HEAD}--- X4-1a: 同じブランチへ、同時に push ---${CLR_RST}"
    local a="$IT_WORK/devA/$IT_REPO" b="$IT_WORK/devC/$IT_REPO" ok_a ok_b
    it_run "$IT_WORK" bash -c "mkdir -p devC && git clone -q https://github.com/${IT_OWNER}/${IT_REPO}.git devC/$IT_REPO && cd devC/$IT_REPO && git checkout -q JOB-A"
    assert_exit_ok "$IT_RC" "X4-1a: 2 つ目のクローン（JOB-A）を作る"
    # 両方、同じ親から、別のコミットを作る（フックは使わない）
    echo "from a" > "$a/a.txt"; echo "from c" > "$b/c.txt"
    it_run "$a" bash -c "git add -A && git commit -q -m 'A の変更' --no-verify"
    it_run "$b" bash -c "git add -A && git commit -q -m 'C の変更' --no-verify"
    # 同時に push する（バックグラウンドで 2 つ起動して、両方を待つ）
    (
        export HOME="$IT_HOME" PATH="$IT_BIN:$PATH" IT_STATE IT_ORIGIN GIT_SSH_COMMAND="$IT_BIN/ssh" GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1
        ( cd "$a" && git push origin JOB-A > "$IT_ROOT/push_a.txt" 2>&1; echo $? > "$IT_ROOT/rc_a.txt" ) &
        ( cd "$b" && git push origin JOB-A > "$IT_ROOT/push_c.txt" 2>&1; echo $? > "$IT_ROOT/rc_c.txt" ) &
        wait
    )
    ok_a=$(cat "$IT_ROOT/rc_a.txt"); ok_b=$(cat "$IT_ROOT/rc_c.txt")
    if [[ "$ok_a" == "0" && "$ok_b" != "0" ]] || [[ "$ok_a" != "0" && "$ok_b" == "0" ]]; then
        pass "X4-1a: 同時の push は、片方だけが成功する"
    else
        fail "X4-1a: 同時の push は、片方だけが成功する" "A=${ok_a} C=${ok_b}"
    fi
    # 負けた側は、取り込んで、再 push できる
    local loser="$a"; [[ "$ok_a" == "0" ]] && loser="$b"
    it_run "$loser" bash -c "git pull -q --no-rebase --no-edit origin JOB-A && git push -q origin JOB-A"
    assert_exit_ok "$IT_RC" "X4-1a: 負けた側は、取り込んで、再 push できる"
    assert_equals "$(_remote_ref JOB-A)" "$(_head "$loser")" "X4-1a: origin に、両方の変更が入る"
    assert_equals "$(_it_git --git-dir="$IT_ORIGIN" ls-tree -r --name-only JOB-A | grep -cE '^(a|c)\.txt$')" "2" "X4-1a: a.txt と c.txt の両方が、残っている"
}

_it_timed() { local t0=$SECONDS rc; "$@"; rc=$?; echo "  （所要時間: $1 = $((SECONDS - t0)) 秒）"; return $rc; }

test_setup || { print_summary; exit 1; }
for _sc in ${IT_SCENARIOS:-hooks main_ahead_and_conflict parallel_jobs unhook_hook concurrent_push}; do
    _it_timed "test_${_sc}" || break
done

print_summary
