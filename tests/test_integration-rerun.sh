#!/bin/bash
# ==============================================================================
# test_integration-rerun.sh - 結合テスト L1: 再実行（冪等）と、手元のファイルの改変
# ==============================================================================
# 実際の git と fake で、状態を持つコマンドを続けて 2 回実行しても結果が同じになること（X8-1）と、
# 手元のフック・設定ファイルが改変・欠落しても、コマンドが安全に止まるか復元すること（X3-10）を確かめる。
# ハーネスと fake は tests/integration/lib.sh。計画: doc/integration-test-plan.md
#
# 【シナリオ】
#   R1  X8-1  sf-push を、変更なしで 2 回目に実行 → 何もせず成功する（コミットも push も増えない）
#   R2  X8-1  sf-dryrun を 2 回続けて実行 → どちらも成功し、組織へ書き込まない
#   R3  X8-1  sf-update-secret（コンシューマーキー）を、同じ入力で 2 回 → 同じ値のまま（重複しない）
#   R4  X3-10 フックの改変・削除 → sf-hook が、正規の内容に戻す
#   R5  X3-10 ブランチの上にいない（detached HEAD）・保護ブランチ（main）の上で sf-push → コミットせずに止まる（コミットだけが残らない）
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
source "$(dirname "${BASH_SOURCE[0]}")/integration/lib.sh"
echo -e "${CLR_HEAD}=== 結合テスト L1: 再実行・手元のファイルの改変 ===${CLR_RST}"

trap 'it_teardown' EXIT

_head() { _it_git -C "$1" rev-parse HEAD; }
_hooks_sum() { ( cd "$1/.git/hooks" 2>/dev/null && for f in pre-commit pre-push; do [[ -f "$f" ]] && cksum < "$f" || echo none; done | tr '\n' ' '; ); }

test_setup() {
    it_setup || { fail "サンドボックスの作成"; return 1; }
    it_seed_repo 1 || { fail "リポジトリの生成"; return 1; }
    it_make_clone devA JOB-A || { fail "クローンの作成" "$(it_out)"; return 1; }
    CL="$IT_CL"
    IT_TIMEOUT=300
    pass "準備: クローン（JOB-A）を作った"
}

test_R1() {
    echo -e "\n${CLR_HEAD}--- R1: sf-push の再実行（変更なし）---${CLR_RST}"
    local h1 r1
    it_add_class "$CL" ItRerun
    it_set_deploy_target "$CL" JOB-A "force-app/main/default/classes/ItRerun.cls"
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-push.sh"
    assert_exit_ok "$IT_RC" "R1: 1 回目の sf-push が成功する"
    h1=$(_head "$CL"); r1=$(it_remote_snap)
    it_calls_clear
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-push.sh"
    assert_exit_ok "$IT_RC" "R1: 変更がなくても、2 回目の sf-push は成功する"
    assert_equals "$(_head "$CL")" "$h1" "R1: 2 回目は、コミットを作らない"
    assert_equals "$(it_remote_snap)" "$r1" "R1: 2 回目は、origin を変えない"
    assert_equals "$(it_mutating_calls | wc -l | tr -d ' ')" "0" "R1: 2 回目は、GitHub・組織へ書き込まない"
}

test_R2() {
    echo -e "\n${CLR_HEAD}--- R2: sf-dryrun を 2 回続けて実行 ---${CLR_RST}"
    local i
    it_calls_clear
    for i in 1 2; do
        it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-dryrun.sh" -n
        assert_exit_ok "$IT_RC" "R2: ${i} 回目の sf-dryrun が成功する"
    done
    assert_equals "$(it_mutating_calls | wc -l | tr -d ' ')" "0" "R2: dry-run は、2 回とも、組織へ書き込まない"
}

test_R3() {
    echo -e "\n${CLR_HEAD}--- R3: sf-update-secret（コンシューマーキー）を同じ入力で 2 回 ---${CLR_RST}"
    local ck="ITRERUNKEY-0a1b2c" i
    mkdir -p "$IT_HOME/.sf-jwt/$IT_REPO" "$IT_STATE/variables"
    printf 'dummy-key' > "$IT_HOME/.sf-jwt/$IT_REPO/server.key"
    printf '%s' "it@example.invalid" > "$IT_STATE/variables/SF_USERNAME_PROD"
    for i in 1 2; do
        it_run "$CL" -i "Y\n2\n1\n${ck}\nY\n1\n" bash "$IT_HOME/sf-tools/bin/sf-update-secret.sh"
        assert_exit_ok "$IT_RC" "R3: ${i} 回目の更新が成功する"
        assert_equals "$(cat "$IT_STATE/secrets/SF_CONSUMER_KEY_PROD" 2>/dev/null)" "$ck" "R3: ${i} 回目の後も、Secret は入力した値のまま"
    done
    assert_equals "$(ls "$IT_STATE/secrets" | grep -c CONSUMER_KEY_PROD)" "1" "R3: Secret は重複しない"
}

test_R4() {
    echo -e "\n${CLR_HEAD}--- R4: フックの改変・削除 → sf-hook が戻す ---${CLR_RST}"
    local s0 h0; s0=$(_hooks_sum "$CL"); h0=$(_head "$CL")
    # 改変: pre-push を、何もしないフックに差し替える
    printf '#!/bin/sh\nexit 0\n' > "$CL/.git/hooks/pre-push"
    [[ "$(_hooks_sum "$CL")" != "$s0" ]] && pass "R4: （前提）pre-push を改変した" || fail "R4: （前提）pre-push を改変した"
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-hook.sh"
    assert_exit_ok "$IT_RC" "R4: 改変されていても、sf-hook が成功する"
    assert_equals "$(_hooks_sum "$CL")" "$s0" "R4: 改変された pre-push が、正規の内容に戻る"
    # 削除: 両方のフックを消す
    rm -f "$CL/.git/hooks/pre-push" "$CL/.git/hooks/pre-commit"
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-hook.sh"
    assert_exit_ok "$IT_RC" "R4: フックが無くても、sf-hook が成功する"
    assert_equals "$(_hooks_sum "$CL")" "$s0" "R4: 削除された pre-push・pre-commit が、戻る"
    assert_equals "$(_head "$CL")" "$h0" "R4: コミットは作らない"
}

test_R5() {
    echo -e "\n${CLR_HEAD}--- R5: detached HEAD・main の上での sf-push ---${CLR_RST}"
    local h0 r0
    it_add_class "$CL" ItR5

    # detached HEAD: コミットを作らず、止まる（作ると、どのブランチにも残らない）
    _it_git -C "$CL" checkout -q --detach
    h0=$(_head "$CL"); r0=$(it_remote_snap)
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-push.sh"
    assert_exit_fail "$IT_RC" "R5: detached HEAD では、sf-push が失敗で終わる"
    it_out_has "detached HEAD" && pass "R5: detached HEAD であることが、表示される" || fail "R5: detached HEAD であることが、表示される" "$(it_out | tail -4)"
    assert_equals "$(_head "$CL")" "$h0" "R5: detached HEAD で、コミットを作らない"
    assert_equals "$(it_remote_snap)" "$r0" "R5: detached HEAD で、origin を変えない"
    _it_git -C "$CL" checkout -q JOB-A

    # main の上: コミットを作らず、止まる（作ると、main に、プッシュできないコミットだけが残る）
    _it_git -C "$CL" checkout -q main
    h0=$(_head "$CL"); r0=$(it_remote_snap)
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-push.sh"
    assert_exit_fail "$IT_RC" "R5: main の上では、sf-push が失敗で終わる"
    it_out_has "保護ブランチ" && pass "R5: 保護ブランチであることが、表示される" || fail "R5: 保護ブランチであることが、表示される" "$(it_out | tail -4)"
    assert_equals "$(_head "$CL")" "$h0" "R5: main の上で、コミットを作らない（手元の main が、origin と食い違わない）"
    assert_equals "$(it_remote_snap)" "$r0" "R5: main の上で、origin を変えない"
    assert_file_exists "$CL/force-app/main/default/classes/ItR5.cls" "R5: 作業中のファイルは、そのまま残る（失われない）"
    _it_git -C "$CL" checkout -q JOB-A
}

_it_timed() { local t0=$SECONDS rc; "$@"; rc=$?; echo "  （所要時間: $1 = $((SECONDS - t0)) 秒）"; return $rc; }

test_setup || { print_summary; exit 1; }
for _sc in ${IT_SCENARIOS:-R1 R2 R3 R4 R5}; do
    _it_timed "test_${_sc}" || break
done

print_summary
