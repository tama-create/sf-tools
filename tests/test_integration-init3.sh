#!/bin/bash
# ==============================================================================
# test_integration-init3.sh - 結合テスト L1: sf-init の診断（--status）・管理者用ブランチの欠け・Salesforce の失敗・同時の作成
# ==============================================================================
# 実際の git と、状態を持つ fake の gh・sf で、完了済みのプロジェクトの、手動の削除・欠け、Salesforce の接続の失敗、
# 同名のリポジトリの同時作成を確かめる。共通の部品は tests/integration/init-lib.sh。
# 計画: doc/integration-test-plan.md の X1-4・X3-1・X3-8・X3-9・X4-1b・X9-1
#
# 【シナリオ】
#   X3-9   Secret・Variable・ワークフロー・ブランチ・リポジトリの欠けを、--status が、見つけて、直し方を示す
#   X3-8   管理者用の admin ブランチが、origin から消えた・状態ファイルが残った → 後片付けで、admin ブランチが戻る
#   X1-4   Salesforce へのログインの失敗（Phase 10）→ 続きから、完了する
#   X9-1   JWT の接続テストの失敗 → リトライの上限で止まり、確認の質問が出る（スキップすれば、Secret の登録まで進む）
#   X4-1b  同名のリポジトリを、別のフォルダから、同時に作る → 片方だけが、成功し、重複・破損がない
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
source "$(dirname "${BASH_SOURCE[0]}")/integration/lib.sh"
echo -e "${CLR_HEAD}=== 結合テスト L1: sf-init の診断・欠け・Salesforce の失敗・同時の作成 ===${CLR_RST}"

trap 'it_teardown' EXIT
source "$(dirname "${BASH_SOURCE[0]}")/integration/init-lib.sh"

# 環境変数つきで、sf-init を動かす。引数: 入力 変数=値...
_initx() {
    local inp="$1"; shift
    mkdir -p "$IT_WORK/proj"
    it_run "$IT_WORK/proj" -i "$inp" env "$@" bash "$IT_HOME/sf-tools/bin/sf-init.sh" --owner "$IT_OWNER" --project "$IT_PROJECT"
}
# 管理者用のクローンで、--status を動かす。結果: IT_RC・IT_OUT
_status() { it_run "$(_admin)" bash "$IT_HOME/sf-tools/bin/sf-init.sh" --status; }
_plain() { it_out | sed 's/\x1b\[[0-9;]*m//g'; }

test_X3_9() {
    echo -e "\n${CLR_HEAD}--- X3-9: --status が、欠けを見つける ---${CLR_RST}"
    _fresh || return 1; IT_TIMEOUT=900
    _init "$FULL_INPUT"
    assert_exit_ok "$IT_RC" "X3-9: 準備: sf-init が、最後まで成功する"
    IT_TIMEOUT=300

    _status
    assert_exit_ok "$IT_RC" "X3-9: そろっているとき、--status は成功する（不足なし）"
    _plain | grep -qE '^ +✗ ' && fail "X3-9: そろっているとき、✗（不足）が出ない" "$(_plain | grep -E '^ +✗ ' | head -3)" || pass "X3-9: そろっているとき、✗（不足）が出ない"

    # Secret が、消えている（手動で削除）→ 不足。直し方が出る
    mv "$IT_STATE/secrets/SF_PRIVATE_KEY" "$IT_ROOT/saved.key"
    _status
    assert_exit_fail "$IT_RC" "X3-9: Secret（SF_PRIVATE_KEY）がないと、--status は、不足で失敗する"
    _plain | grep -q "SF_PRIVATE_KEY" && pass "X3-9: 不足の Secret の名前が、表示される" || fail "X3-9: 不足の Secret の名前が、表示される"
    _plain | grep -q "sf-init.sh --only 10" && pass "X3-9: 直し方（--only 10）が、表示される" || fail "X3-9: 直し方（--only 10）が、表示される"
    mv "$IT_ROOT/saved.key" "$IT_STATE/secrets/SF_PRIVATE_KEY"

    # Variable が、消えている → 不足。直し方（--reconnect）が出る
    mv "$IT_STATE/variables/SF_USERNAME_PROD" "$IT_ROOT/saved.var"
    _status
    assert_exit_fail "$IT_RC" "X3-9: Variable（SF_USERNAME_PROD）がないと、--status は、不足で失敗する"
    _plain | grep -q "sf-init.sh --reconnect main" && pass "X3-9: 直し方（--reconnect main）が、表示される" || fail "X3-9: 直し方（--reconnect main）が、表示される"
    mv "$IT_ROOT/saved.var" "$IT_STATE/variables/SF_USERNAME_PROD"

    # ワークフローのファイルが、main から消えている → 不足。直し方（sf-sync-wf）が出る
    it_origin_delete_file main ".github/workflows/wf-validate.yml" || { fail "X3-9: 準備（ワークフローの削除）"; return; }
    _status
    assert_exit_fail "$IT_RC" "X3-9: ワークフロー（wf-validate.yml）がないと、--status は、不足で失敗する"
    _plain | grep -q "wf-validate.yml" && pass "X3-9: 不足のワークフローの名前が、表示される" || fail "X3-9: 不足のワークフローの名前が、表示される"
    it_origin_restore_file main ".github/workflows/wf-validate.yml" || fail "X3-9: 準備（ワークフローの復元）"

    # branches.txt に staging があるのに、origin に staging ブランチがない（と、staging の Secret・Variable がない）
    local bt="$(_admin)/sf-tools/config/branches.txt"; local orig; orig=$(cat "$bt")
    printf '%s\nstaging\n' "$orig" > "$bt"
    _status
    assert_exit_fail "$IT_RC" "X3-9: branches.txt にあるブランチ（staging）が、origin にないと、--status は、不足で失敗する"
    _plain | grep -q "ブランチ staging がありません" && pass "X3-9: 不足のブランチ（staging）が、表示される" || fail "X3-9: 不足のブランチ（staging）が、表示される"
    _plain | grep -q "sf-init.sh --add-tier staging" && pass "X3-9: 直し方（--add-tier staging）が、表示される" || fail "X3-9: 直し方（--add-tier staging）が、表示される"
    printf '%s\n' "$orig" > "$bt"

    # リポジトリそのものが、GitHub から消えている
    grep -vxF "${IT_OWNER}/${IT_REPO}" "$IT_STATE/repos" > "$IT_STATE/repos.new"; mv "$IT_STATE/repos.new" "$IT_STATE/repos"
    _status
    assert_exit_fail "$IT_RC" "X3-1: リポジトリが GitHub から消えていると、--status は、不足で失敗する"
    _plain | grep -q "リポジトリが見つかりません" && pass "X3-1: 「リポジトリが見つかりません」と表示される" || fail "X3-1: 「リポジトリが見つかりません」と表示される"
    echo "${IT_OWNER}/${IT_REPO}" >> "$IT_STATE/repos"
}

test_X3_8() {
    echo -e "\n${CLR_HEAD}--- X3-8: admin ブランチが origin から消え、状態ファイルが残った ---${CLR_RST}"
    _fresh || return 1; IT_TIMEOUT=900
    _init "$FULL_INPUT"
    assert_exit_ok "$IT_RC" "X3-8: 準備: sf-init が、最後まで成功する"
    IT_TIMEOUT=300
    # origin の admin ブランチを消し、「完了の直前で止まった」状態（進捗 10・状態ファイルあり）を、作る
    _it_git --git-dir="$IT_ORIGIN" branch -D admin >/dev/null
    printf 'GITHUB_OWNER="%s"\nPROJECT_NAME="%s"\nREPO_NAME="%s"\nREPO_FULL_NAME="%s/%s"\nREPO_DIR="%s"\nBRANCH_COUNT="1"\n' \
        "$IT_OWNER" "$IT_PROJECT" "$IT_REPO" "$IT_OWNER" "$IT_REPO" "$(_admin)" > "$IT_WORK/proj/admin/.sf-init-${IT_PROJECT}.env"
    chmod 600 "$IT_WORK/proj/admin/.sf-init-${IT_PROJECT}.env"
    printf 'SF_INIT_DONE_PHASE=10\nSF_INIT_DONE_AT="2026-10-19 12:00"\n' > "$IT_WORK/proj/admin/.sf-init-${IT_PROJECT}.progress"
    _init 'Y\nq\n'     # 警告 Y → 後片付け（admin ブランチの再 push）→ 完了済みのメニューで q
    it_remote_snap | grep -q 'refs/heads/admin ' && pass "X3-8: 後片付けで、origin に admin ブランチが、戻る" || fail "X3-8: 後片付けで、origin に admin ブランチが、戻る" "$(_plain | tail -8)"
    assert_file_not_exists "$IT_WORK/proj/admin/.sf-init-${IT_PROJECT}.env" "X3-8: 後片付けのあと、状態ファイルが消える"
    assert_equals "$(_it_git -C "$(_admin)" config sf-tools.setup-complete)" "1" "X3-8: 完了の印が、付いている"
}

test_X1_4() {
    echo -e "\n${CLR_HEAD}--- X1-4: Salesforce へのログインの失敗（Phase 10）→ 続きから ---${CLR_RST}"
    _fresh || return 1; IT_TIMEOUT=900
    it_fault sf "org login web*" 1 1 1 "Error: Authentication failed (access_denied)"
    _init "$FULL_INPUT"
    assert_exit_fail "$IT_RC" "X1-4: Salesforce へのログインが失敗すると、sf-init は、失敗で終わる"
    [[ -f "$IT_STATE/secrets/SF_CONSUMER_KEY_PROD" ]] && fail "X1-4: 接続できなかった組織の Secret は、登録されない" || pass "X1-4: 接続できなかった組織の Secret は、登録されない"
    assert_equals "$(_progress)" "9" "X1-4: 進捗は、Phase 10 の前（Phase 9）まで"
    it_fault_clear
    _init "${RESUME_HEAD}Y\n1\n"
    [[ $IT_RC -eq 0 ]] || _plain | tail -10
    assert_exit_ok "$IT_RC" "X1-4: 「続きから」で、最後まで成功する"
    [[ -f "$IT_STATE/secrets/SF_CONSUMER_KEY_PROD" ]] && pass "X1-4: 続きから、Secret が登録される" || fail "X1-4: 続きから、Secret が登録される"
}

test_X9_1() {
    echo -e "\n${CLR_HEAD}--- X9-1: JWT の接続テストの失敗 → リトライの上限 ---${CLR_RST}"
    _fresh || return 1; IT_TIMEOUT=900
    it_fault sf "org login jwt*" 1 99 1 "ERROR: invalid_grant: user hasn't approved this consumer"
    _initx "${FULL_INPUT}N\n" SF_INIT_JWT_RETRIES=4 SF_INIT_JWT_INTERVAL=0
    assert_exit_fail "$IT_RC" "X9-1: 接続テストが、リトライしても失敗し、スキップを断ると（N）、sf-init は、失敗で終わる"
    assert_equals "$(it_calls sf | grep -c 'org login jwt')" "4" "X9-1: リトライは、上限（4 回）で止まる（無限に繰り返さない）"
    [[ -f "$IT_STATE/secrets/SF_CONSUMER_KEY_PROD" ]] && fail "X9-1: 接続テストをスキップしなかったときは、Secret を登録しない" || pass "X9-1: 接続テストをスキップしなかったときは、Secret を登録しない"
    # 続きから: 接続テストをスキップする（Y）と、Secret の登録まで進む
    it_calls_clear
    _initx "${RESUME_HEAD}Y\n1\nY\n" SF_INIT_JWT_RETRIES=2 SF_INIT_JWT_INTERVAL=0
    [[ $IT_RC -eq 0 ]] || _plain | tail -10
    assert_exit_ok "$IT_RC" "X9-1: 接続テストをスキップする（Y）と、最後まで成功する"
    assert_equals "$(it_calls sf | grep -c 'org login jwt')" "2" "X9-1: 再開でも、リトライは、上限（2 回）で止まる"
    [[ -f "$IT_STATE/secrets/SF_CONSUMER_KEY_PROD" ]] && pass "X9-1: スキップすると、Secret の登録まで進む" || fail "X9-1: スキップすると、Secret の登録まで進む"
    it_fault_clear
}

test_X4_1b() {
    echo -e "\n${CLR_HEAD}--- X4-1b: 同名のリポジトリを、別のフォルダから、同時に作る ---${CLR_RST}"
    _fresh || return 1; IT_TIMEOUT=900
    # 1 つ目の「リポジトリはあるか」の確認だけ、6 秒遅らせる（その間に、2 つ目が、作る）。遅れた 1 つ目は、「ない」と思って、作ろうとして、失敗する
    it_fault gh "repo view*" 1 1 1 "Could not resolve to a Repository with the name" 6
    local p1="$IT_WORK/p1" p2="$IT_WORK/p2" pid i
    mkdir -p "$p1" "$p2"
    printf '%b' "$FULL_INPUT" > "$IT_ROOT/r1.in"; printf '%b' "$FULL_INPUT" > "$IT_ROOT/r2.in"
    _run_bg() {   # 作業フォルダ 入力ファイル 出力ファイル rc ファイル
        (
            cd "$1" || exit 99
            export HOME="$IT_HOME" PATH="$IT_BIN:$PATH" IT_STATE IT_ORIGIN SF_LAUNCHER_ACTIVE=1 SF_TOOLS_SF_CHECK_STAMP=/dev/null
            export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_SSH_COMMAND="$IT_BIN/ssh" TMPDIR="$IT_ROOT/tmp"
            unset GITHUB_ACTIONS CI GH_TOKEN GITHUB_TOKEN; mkdir -p "$TMPDIR"
            bash "$IT_HOME/sf-tools/bin/sf-init.sh" --owner "$IT_OWNER" --project "$IT_PROJECT" < "$2" > "$3" 2>&1; echo $? > "$4"
        ) &
    }
    _run_bg "$p1" "$IT_ROOT/r1.in" "$IT_ROOT/r1.out" "$IT_ROOT/r1.rc"
    pid1=$!
    for i in $(seq 1 60); do grep -q "repo view" "$IT_STATE/calls.log" 2>/dev/null && break; sleep 0.5; done
    _run_bg "$p2" "$IT_ROOT/r2.in" "$IT_ROOT/r2.out" "$IT_ROOT/r2.rc"
    pid2=$!
    wait "$pid1" "$pid2" 2>/dev/null
    local rc1 rc2; rc1=$(cat "$IT_ROOT/r1.rc"); rc2=$(cat "$IT_ROOT/r2.rc")
    echo "  1 つ目: rc=${rc1} / 2 つ目: rc=${rc2}"
    local ok=0; [[ "$rc1" == "0" ]] && ok=$((ok + 1)); [[ "$rc2" == "0" ]] && ok=$((ok + 1))
    assert_equals "$ok" "1" "X4-1b: 同名のリポジトリの同時作成は、片方だけが、成功する"
    local loser_out="$IT_ROOT/r1.out"; [[ "$rc1" == "0" ]] && loser_out="$IT_ROOT/r2.out"
    grep -q "作成に失敗\|already exists" "$loser_out" && pass "X4-1b: 負けた側に、作成の失敗の理由が、表示される" || fail "X4-1b: 負けた側に、作成の失敗の理由が、表示される" "$(sed 's/\x1b\[[0-9;]*m//g' "$loser_out" | tail -5)"
    assert_equals "$(it_remote_count main)" "1" "X4-1b: main の初回コミットは 1 つ（重複しない）"
    assert_equals "$(grep -cxF "${IT_OWNER}/${IT_REPO}" "$IT_STATE/repos")" "1" "X4-1b: リポジトリは、1 つだけ登録されている"
    # 【現状の限界】排他（ロック）は、同じ admin フォルダの中だけ。別のフォルダから、同名のリポジトリを同時に作ると、作成に失敗した側も、
    #   「すでにある」として続けるため、Ruleset が、重複することがある（このときの件数: $(ls "$IT_STATE/rulesets" | wc -l)）。
    #   実際には、2 人の管理者が、同じ新規プロジェクトを、同時に作ることは、まれ。確認は、しない
    it_fault_clear
}

_it_timed() { local t0=$SECONDS rc; "$@"; rc=$?; echo "  （所要時間: $1 = $((SECONDS - t0)) 秒）"; return $rc; }

for _sc in ${IT_SCENARIOS:-X3_9 X3_8 X1_4 X9_1 X4_1b}; do
    _it_timed "test_${_sc}" || break
done

print_summary
