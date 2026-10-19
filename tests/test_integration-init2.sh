#!/bin/bash
# ==============================================================================
# test_integration-init2.sh - 結合テスト L1: sf-init の状態の食い違い・入力の不正・外部サービスの失敗・同時実行
# ==============================================================================
# 実際の git と、状態を持つ fake の gh・sf（tests/integration/lib.sh）で、sf-init の異常な状態・失敗を確かめる。
# 共通の部品は tests/integration/init-lib.sh。計画: doc/integration-test-plan.md の X1・X3・X4
#
# 【シナリオ】
#   X3-5  状態ファイルの REPO_FULL_NAME が、実際と違う → 別のリポジトリを操作しない
#   X3-6  進捗が、実体より先行（Phase 8 の完了と記録されているが、origin に main がない）→ 続けず、拒否する
#   X3-7  進捗が 10（完了の直前）だが、origin に main がない → 完了にしない
#   X1-2  PAT の権限不足（workflow スコープなし）・無効な PAT → 登録しない
#   X1-3  別のユーザーでログイン・リポジトリ名の衝突 → 何も作らない／既存を壊さない
#   X4-1  同じプロジェクトを、2 つ同時に sf-init → 状態が壊れない（二重に作らない）
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
source "$(dirname "${BASH_SOURCE[0]}")/integration/lib.sh"
echo -e "${CLR_HEAD}=== 結合テスト L1: sf-init の状態の食い違い・失敗・同時実行 ===${CLR_RST}"

trap 'it_teardown' EXIT
source "$(dirname "${BASH_SOURCE[0]}")/integration/init-lib.sh"

_envf() { echo "$IT_WORK/proj/admin/.sf-init-${IT_PROJECT}.env"; }
_progf() { echo "$IT_WORK/proj/admin/.sf-init-${IT_PROJECT}.progress"; }
_nmut_other() { it_calls gh | grep -c "$1"; }

test_X3_5() {
    echo -e "\n${CLR_HEAD}--- X3-5: 状態ファイルの REPO_FULL_NAME が、実際と違う ---${CLR_RST}"
    mk_interrupted
    sed -i.bak "s|^REPO_FULL_NAME=.*|REPO_FULL_NAME=\"${IT_OWNER}/force-zzzz\"|" "$(_envf)" && rm -f "$(_envf).bak"
    it_calls_clear
    _init 'Y\n'    # 続きの質問は出ない（状態が、このプロジェクトのものではない）→ 新規として、確認まで進んで、入力が尽きる
    assert_exit_fail "$IT_RC" "X3-5: 入力が尽きて、中断する（続きの質問は出ない）"
    it_out_has "前回のセットアップは" && fail "X3-5: 別のリポジトリの状態では、「続きをやる」を出さない" || pass "X3-5: 別のリポジトリの状態では、「続きをやる」を出さない"
    assert_equals "$(_nmut_other zzzz)" "0" "X3-5: 状態ファイルの別のリポジトリ名（force-zzzz）を、gh で操作しない"
    assert_equals "$(it_mutating_calls | wc -l | tr -d ' ')" "0" "X3-5: 外部へ書き込まない"
}

test_X3_6() {
    echo -e "\n${CLR_HEAD}--- X3-6: 進捗が、実体より先行（Phase 8 まで完了と記録・origin に main がない）---${CLR_RST}"
    mk_interrupted
    sed -i.bak "s|^SF_INIT_DONE_PHASE=.*|SF_INIT_DONE_PHASE=9|" "$(_progf)" && rm -f "$(_progf).bak"
    it_calls_clear
    _init 'Y\n1\nY\n1\n'
    assert_exit_fail "$IT_RC" "X3-6: 実体と食い違う進捗では、続きを選んでも、拒否される"
    it_out_has "main ブランチを確認できません" && pass "X3-6: 理由（main を確認できない）が表示される" || fail "X3-6: 理由（main を確認できない）が表示される" "$(it_out | tail -6)"
    assert_equals "$(it_remote_snap | wc -l | tr -d ' ')" "0" "X3-6: origin に、何も作らない（admin ブランチも、作らない）"
    [[ -f "$IT_STATE/secrets/SF_PRIVATE_KEY" ]] && fail "X3-6: Phase 10 の Secret を、登録しない" || pass "X3-6: Phase 10 の Secret を、登録しない"
    assert_file_exists "$(_progf)" "X3-6: 保存した状態は、消さない"
}

test_X3_7() {
    echo -e "\n${CLR_HEAD}--- X3-7: 進捗が 10（完了の直前）だが、origin に main がない ---${CLR_RST}"
    mk_interrupted
    sed -i.bak "s|^SF_INIT_DONE_PHASE=.*|SF_INIT_DONE_PHASE=10|" "$(_progf)" && rm -f "$(_progf).bak"
    it_calls_clear
    _init 'Y\n'
    assert_exit_fail "$IT_RC" "X3-7: 進捗が 10 でも、origin に main がなければ、完了にせず、失敗で終わる"
    assert_equals "$(it_remote_snap | wc -l | tr -d ' ')" "0" "X3-7: origin に、何も作らない"
    assert_equals "$(_it_git -C "$(_admin)" config sf-tools.setup-complete 2>/dev/null)" "" "X3-7: 完了の印を、付けない"
    assert_file_exists "$(_progf)" "X3-7: 保存した状態は、消さない"
}

test_X3_7b() {
    echo -e "\n${CLR_HEAD}--- X3-7: 完了の印と進捗の矛盾 ---${CLR_RST}"
    # (1) 完了の印は 1 だが、進捗は途中（7）→ 「完了済み」とは、扱わず、「続きをやる」を出す
    mk_interrupted
    _it_git -C "$(_admin)" config sf-tools.setup-complete 1
    it_calls_clear
    _init 'Y\nq\n'
    it_out_has "前回のセットアップは" && pass "X3-7（印 1・進捗 7）: 「続きをやる」の質問が出る" || fail "X3-7（印 1・進捗 7）: 「続きをやる」の質問が出る" "$(it_out | tail -6)"
    it_out_has "すでに完了しています" && fail "X3-7（印 1・進捗 7）: 完了済みとは、扱わない" || pass "X3-7（印 1・進捗 7）: 完了済みとは、扱わない"
    assert_equals "$(it_mutating_calls | wc -l | tr -d ' ')" "0" "X3-7（印 1・進捗 7）: q で中断すると、外部へ書き込まない"

    # (2) 完了済み（印 1・状態ファイルなし）のプロジェクトの、印を 0 に戻す → 完了済みとは、扱わない（途中で止まった「やり直し」の扱い）
    _fresh || return 1; IT_TIMEOUT=900
    _init "$FULL_INPUT"
    assert_exit_ok "$IT_RC" "X3-7（印 0）: 準備: sf-init が、最後まで成功する"
    IT_TIMEOUT=300
    _it_git -C "$(_admin)" config sf-tools.setup-complete 0
    it_calls_clear
    _init 'Y\nq\n'
    it_out_has "すでに完了しています" && fail "X3-7（印 0）: 印が 0 のプロジェクトは、完了済みとは、扱わない" || pass "X3-7（印 0）: 印が 0 のプロジェクトは、完了済みとは、扱わない"
    it_out_has "途中で止まっています" && pass "X3-7（印 0）: 「やり直しが、途中で止まっています」と、知らせる" || fail "X3-7（印 0）: 「やり直しが、途中で止まっています」と、知らせる" "$(it_out | sed 's/\x1b\[[0-9;]*m//g' | tail -6)"
}

test_X1_2() {
    echo -e "\n${CLR_HEAD}--- X1-2: PAT の権限不足・無効な PAT ---${CLR_RST}"
    _fresh || return 1; IT_TIMEOUT=900
    echo "repo" > "$IT_STATE/gh.scopes"          # workflow スコープがない
    local bad="${PAT_MARK}\n${PAT_MARK}\n${PAT_MARK}\n"
    _init "Y\nY\n1\n3\n${bad}"
    assert_exit_fail "$IT_RC" "X1-2: workflow スコープのない PAT は、3 回とも拒否され、失敗で終わる"
    [[ -f "$IT_STATE/secrets/PAT_TOKEN" ]] && fail "X1-2: 権限不足の PAT は、Secret に登録されない" || pass "X1-2: 権限不足の PAT は、Secret に登録されない"
    assert_equals "$(_progress)" "5" "X1-2: 進捗は、PAT の前（Phase 5）まで"
    rm -f "$IT_STATE/gh.scopes"
    # 無効な PAT（GitHub が、認証を拒否する）
    _fresh || return 1
    it_fault gh "api user --include*" 1 99 1 "gh: Bad credentials (HTTP 401)"
    _init "Y\nY\n1\n3\n${bad}"
    assert_exit_fail "$IT_RC" "X1-2: 無効な PAT は、拒否され、失敗で終わる"
    [[ -f "$IT_STATE/secrets/PAT_TOKEN" ]] && fail "X1-2: 無効な PAT は、Secret に登録されない" || pass "X1-2: 無効な PAT は、Secret に登録されない"
    it_fault_clear
    _no_leak "$PAT_MARK" "X1-2: 失敗の出力・ログ・一時ファイル"
}

test_X1_3() {
    echo -e "\n${CLR_HEAD}--- X1-3: 別のユーザー・リポジトリ名の衝突 ---${CLR_RST}"
    _fresh || return 1; IT_TIMEOUT=300
    # 別のユーザーでログイン（そのオーナーの組織の admin でもない）
    echo "someone-else" > "$IT_STATE/gh.login"
    it_calls_clear
    _init "$FULL_INPUT"
    assert_exit_fail "$IT_RC" "X1-3: 別のユーザーでは、sf-init が拒否される"
    it_out_has "リポジトリオーナー" && pass "X1-3: 拒否の理由（オーナーとの不一致）が出る" || fail "X1-3: 拒否の理由（オーナーとの不一致）が出る"
    assert_equals "$(it_mutating_calls | wc -l | tr -d ' ')" "0" "X1-3: 別のユーザーでは、外部へ何も書き込まない"
    assert_equals "$(it_calls gh | grep -c 'repo create')" "0" "X1-3: 別のユーザーでは、リポジトリを作らない"
    echo "$IT_OWNER" > "$IT_STATE/gh.login"

    # 同名のリポジトリが、すでにある（別の用途で使われている: コミットがある）
    _fresh || return 1; IT_TIMEOUT=300
    it_seed_repo 1 || { fail "X1-3: 準備"; return; }
    local before; before=$(it_remote_snap)
    it_calls_clear
    _init "$FULL_INPUT"
    assert_equals "$(it_calls gh | grep -c 'repo create')" "0" "X1-3: 同名のリポジトリがあるとき、新しく作ろうとしない"
    assert_equals "$(it_remote_snap | grep -c 'refs/heads/main ')" "1" "X1-3: 既存のリポジトリの main が、残っている"
    echo "  既存のリポジトリがあるときの結果: rc=${IT_RC}（main のコミット数: $(it_remote_count main)）"
}

test_X4_1() {
    echo -e "\n${CLR_HEAD}--- X4-1: 同じプロジェクトを、2 つ同時に sf-init ---${CLR_RST}"
    _fresh || return 1; IT_TIMEOUT=900
    it_fault gh "secret set SLACK_BOT_TOKEN*" 1 1 0 "" 20     # 1 つ目を、Phase 7 で、20 秒止める（その間に、2 つ目を起動する）
    local pid i
    mkdir -p "$IT_WORK/proj"
    printf '%b' "$FULL_INPUT" > "$IT_ROOT/a.in"
    (
        cd "$IT_WORK/proj" || exit 99
        export HOME="$IT_HOME" PATH="$IT_BIN:$PATH" IT_STATE IT_ORIGIN SF_LAUNCHER_ACTIVE=1 SF_TOOLS_SF_CHECK_STAMP=/dev/null
        export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_SSH_COMMAND="$IT_BIN/ssh" TMPDIR="$IT_ROOT/tmp"
        unset GITHUB_ACTIONS CI GH_TOKEN GITHUB_TOKEN; mkdir -p "$TMPDIR"
        exec bash "$IT_HOME/sf-tools/bin/sf-init.sh" --owner "$IT_OWNER" --project "$IT_PROJECT" < "$IT_ROOT/a.in" > "$IT_ROOT/a.out" 2>&1
    ) &
    pid=$!
    for i in $(seq 1 400); do grep -qF "secret set SLACK_BOT_TOKEN" "$IT_STATE/calls.log" 2>/dev/null && break; kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    # 2 つ目: 同じ入力で、同じ場所・同じプロジェクト
    it_calls_clear
    _init "$FULL_INPUT"
    local rc_b=$IT_RC b_out="$IT_OUT"
    wait "$pid"; local rc_a=$?
    echo "  1 つ目: rc=${rc_a} / 2 つ目: rc=${rc_b}"
    assert_equals "$(grep -c 'gh repo create' "$IT_STATE/calls.log")" "0" "X4-1: 2 つ目は、リポジトリを、もう一度作らない"
    assert_equals "$(it_remote_snap | awk '{print $1}' | grep -c 'refs/heads/main$')" "1" "X4-1: origin の main は 1 つ"
    # 排他（ロック）: 後から起動した 2 つ目は、拒否される。先に起動した 1 つ目は、そのまま、最後まで成功する
    assert_equals "$rc_a" "0" "X4-1: 先に起動した 1 つ目は、最後まで成功する"
    [[ "$rc_b" != "0" ]] && pass "X4-1: 同時に起動した 2 つ目は、拒否される（失敗で終わる）" || fail "X4-1: 同時に起動した 2 つ目は、拒否される" "rc=0"
    grep -qF "すでに実行中です" "$b_out" && pass "X4-1: 拒否の理由（すでに実行中）が、表示される" || fail "X4-1: 拒否の理由（すでに実行中）が、表示される" "$(tail -5 "$b_out")"
    assert_equals "$(grep -c 'repo create' "$IT_STATE/calls.log")" "0" "X4-1: 2 つ目は、gh に、何も書き込まない（リポジトリを作らない）"
    assert_equals "$(ls "$IT_STATE/rulesets" 2>/dev/null | wc -l | tr -d ' ')" "2" "X4-1: Ruleset は、1 回分（2 つ）だけ"
    assert_equals "$(_it_git -C "$(_admin)" config sf-tools.setup-complete)" "1" "X4-1: 最終の状態は、完了している（完了の印）"
    assert_equals "$(it_remote_count main)" "1" "X4-1: main の初回コミットは 1 つ（二重にならない）"
    assert_equals "$(it_remote_snap | awk '{print $1}' | sed 's|refs/heads/||' | sort | tr '\n' ',')" "admin,main," "X4-1: ブランチは、admin と main だけ（二重・余分がない）"
    [[ -d "$IT_WORK/proj/admin/.sf-init-${IT_PROJECT}.lock" ]] && fail "X4-1: 完了後、ロックが残らない" || pass "X4-1: 完了後、ロックが残らない"
}

# 古いロック（実行していたプロセスが、もういない）は、引き継ぐ
test_X4_1_stale() {
    echo -e "\n${CLR_HEAD}--- X4-1: 古いロックの引き継ぎ ---${CLR_RST}"
    _fresh || return 1; IT_TIMEOUT=900
    mkdir -p "$IT_WORK/proj/admin/.sf-init-${IT_PROJECT}.lock"
    echo "999999" > "$IT_WORK/proj/admin/.sf-init-${IT_PROJECT}.lock/pid"      # 存在しない PID
    _init "$FULL_INPUT"
    assert_exit_ok "$IT_RC" "X4-1（古いロック）: 実行中のプロセスがいない古いロックは、引き継いで、最後まで成功する"
    it_out_has "古いロックを引き継ぎます" && pass "X4-1（古いロック）: 引き継いだことが、表示される" || fail "X4-1（古いロック）: 引き継いだことが、表示される"
    [[ -d "$IT_WORK/proj/admin/.sf-init-${IT_PROJECT}.lock" ]] && fail "X4-1（古いロック）: 完了後、ロックが残らない" || pass "X4-1（古いロック）: 完了後、ロックが残らない"
}

_it_timed() { local t0=$SECONDS rc; "$@"; rc=$?; echo "  （所要時間: $1 = $((SECONDS - t0)) 秒）"; return $rc; }

for _sc in ${IT_SCENARIOS:-X3_5 X3_6 X3_7 X3_7b X1_2 X1_3 X4_1 X4_1_stale}; do
    _it_timed "test_${_sc}" || break
done

print_summary
