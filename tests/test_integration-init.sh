#!/bin/bash
# ==============================================================================
# test_integration-init.sh - 結合テスト L1: sf-init の通し・中断と再開・生成物の後続コマンドでの利用
# ==============================================================================
# 実際の git と、状態を持つ fake の gh・sf（tests/integration/lib.sh）で、sf-init を最後まで動かす。
# 計画: doc/integration-test-plan.md の A13・B1・X2-1・X7-1・X8-1
#
# 【シナリオ】
#   I1  sf-init の通し（1 層）。完了後の状態（リポジトリ・ブランチ・Secret・Variable・Ruleset・完了の印）の基準を取る
#   A13 sf-init が生成したリポジトリを、後続のコマンド（sf-job → sf-install → sf-hook → sf-dryrun → sf-push）が使える
#   X8-1 完了済みのプロジェクトで、sf-init を再実行しても、何も変わらない（メニューで q）
#   X2-1 中断と再開: 停止点（Phase 3 の clone・Phase 8 の push・Phase 10 の Secret 登録・Phase 7 の SIGTERM・Phase 10 の SIGKILL）で止める
#        → 「続きから」で完了 → 完了後の状態が、I1 の基準と同じ（重複したコミット・ブランチ・Secret・Ruleset がない）
#   X7-1 PAT・Slack の Token が、画面・ログ・一時ファイル・状態ファイルに残らない（成功時・中断時）
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
source "$(dirname "${BASH_SOURCE[0]}")/integration/lib.sh"
echo -e "${CLR_HEAD}=== 結合テスト L1: sf-init の通し・中断と再開 ===${CLR_RST}"

trap 'it_teardown' EXIT
source "$(dirname "${BASH_SOURCE[0]}")/integration/init-lib.sh"


# ------------------------------------------------------------------------------
# I1: 通し
# ------------------------------------------------------------------------------
test_I1() {
    echo -e "\n${CLR_HEAD}--- I1・X7-1: sf-init の通し（1 層）---${CLR_RST}"
    _fresh || { fail "I1: サンドボックスの作成"; return 1; }
    IT_TIMEOUT=900
    _init "$FULL_INPUT"
    [[ $IT_RC -eq 0 ]] || { it_out | tail -20; }
    assert_exit_ok "$IT_RC" "I1: sf-init が最後まで成功する"
    BASE_STATE=$(_state)
    echo "  基準: ${BASE_STATE}"
    it_remote_snap | grep -q 'refs/heads/main ' && pass "I1: origin に main ができる" || fail "I1: origin に main ができる"
    it_remote_snap | grep -q 'refs/heads/admin ' && pass "I1: origin に admin ブランチができる" || fail "I1: origin に admin ブランチができる"
    assert_equals "$(_it_git -C "$(_admin)" config sf-tools.setup-complete)" "1" "I1: 完了の印（setup-complete）が付く"
    assert_file_not_exists "$IT_WORK/proj/admin/.sf-init-${IT_PROJECT}.env" "I1: 完了後、状態ファイル（.env）が消える"
    assert_file_not_exists "$IT_WORK/proj/admin/.sf-init-${IT_PROJECT}.progress" "I1: 完了後、進捗ファイルが消える"
    local s
    for s in PAT_TOKEN SLACK_BOT_TOKEN SF_PRIVATE_KEY SF_CONSUMER_KEY_PROD; do
        [[ -f "$IT_STATE/secrets/$s" ]] && pass "I1: Secret ${s} が登録される" || fail "I1: Secret ${s} が登録される"
    done
    for s in SLACK_CHANNEL_ID SF_USERNAME_PROD SF_INSTANCE_URL_PROD; do
        [[ -f "$IT_STATE/variables/$s" ]] && pass "I1: Variable ${s} が登録される" || fail "I1: Variable ${s} が登録される"
    done
    assert_equals "$(cat "$IT_STATE/secrets/PAT_TOKEN" 2>/dev/null | tr -d '\n')" "$PAT_MARK" "I1: PAT_TOKEN に、入力した値が入る"
    [[ "$(it_remote_count main)" == "1" ]] && pass "I1: main の初回コミットは 1 つ" || fail "I1: main の初回コミットは 1 つ" "$(it_remote_count main) 個"
    _no_leak "$PAT_MARK" "I1: 通しの出力・ログ・一時ファイル"
    _no_leak "$SLACK_MARK" "I1: 通しの出力・ログ・一時ファイル（Slack）"
    local bt; bt=$(grep -v '^#' "$(_admin)/sf-tools/config/branches.txt" | grep -v '^[[:space:]]*$' | tr '\n' ',')
    assert_equals "$bt" "main," "I1: branches.txt は、1 層（main のみ）"
}

# ------------------------------------------------------------------------------
# A13: 生成されたリポジトリを、後続のコマンドが使える
# ------------------------------------------------------------------------------
test_A13() {
    echo -e "\n${CLR_HEAD}--- A13: sf-init の生成物を、後続のコマンドが使う ---${CLR_RST}"
    local dev="$IT_WORK/dev" cl="$IT_WORK/dev/JOB-1/$IT_REPO" i
    mkdir -p "$dev"
    IT_TIMEOUT=300
    it_run "$dev" -i 'JOB-1\nY\nitorg\n1\n' bash "$IT_HOME/sf-tools/bin/sf-job.sh" --owner "$IT_OWNER" --project "$IT_PROJECT"
    assert_exit_ok "$IT_RC" "A13: sf-init が作ったリポジトリから、sf-job が成功する"
    assert_dir_exists "$cl/.git" "A13: クローンができる"
    for i in $(seq 1 300); do grep -q "npm install の確認が完了しました" "$cl/sf-tools/logs/sf-install.log" 2>/dev/null && break; sleep 1; done
    assert_file_exists "$cl/.git/hooks/pre-push" "A13: sf-install がフックを入れる"
    assert_file_exists "$cl/sf-tools/release/JOB-1/deploy-target.txt" "A13: release/JOB-1/ ができる"
    it_add_class "$cl" ItA13
    it_set_deploy_target "$cl" JOB-1 "force-app/main/default/classes/ItA13.cls"
    it_run "$cl" bash "$IT_HOME/sf-tools/bin/sf-dryrun.sh" -n
    assert_exit_ok "$IT_RC" "A13: sf-dryrun が成功する"
    it_run "$cl" bash "$IT_HOME/sf-tools/bin/sf-push.sh"
    assert_exit_ok "$IT_RC" "A13: sf-push が成功する（フックを通る）"
    assert_equals "$(_it_git --git-dir="$IT_ORIGIN" rev-parse refs/heads/JOB-1)" "$(_it_git -C "$cl" rev-parse HEAD)" "A13: origin の JOB-1 が、手元の HEAD になる"
}

# ------------------------------------------------------------------------------
# X3-10: 生成されたリポジトリの 1 か所を壊したとき、後続のコマンドが、安全に止まる（A13 のクローンを使う）
# ------------------------------------------------------------------------------
test_X3_10() {
    echo -e "\n${CLR_HEAD}--- X3-10: 生成物の改変点ごとの拒否の表 ---${CLR_RST}"
    local cl="$IT_WORK/dev/JOB-1/$IT_REPO" h0 r0 url
    [[ -d "$cl/.git" ]] || { fail "X3-10: A13 のクローンがない"; return; }
    IT_TIMEOUT=300
    h0=$(_it_git -C "$cl" rev-parse HEAD); r0=$(it_remote_snap)

    # (a) origin の URL が、別のリポジトリになっている → push は失敗し、origin も手元のコミットも変わらない
    url=$(_it_git -C "$cl" config remote.origin.url)
    _it_git -C "$cl" config remote.origin.url "https://github.com/${IT_OWNER}/force-other.git"
    echo "x3-10" > "$cl/x310.txt"
    it_run "$cl" bash "$IT_HOME/sf-tools/bin/sf-push.sh"
    assert_exit_fail "$IT_RC" "X3-10（origin が別のリポジトリ）: sf-push は失敗で終わる"
    assert_equals "$(it_remote_snap)" "$r0" "X3-10（origin が別のリポジトリ）: origin は変わらない"
    assert_equals "$(_it_git -C "$cl" rev-parse HEAD)" "$h0" "X3-10（origin が別のリポジトリ）: 手元に、コミットを作らない"
    _it_git -C "$cl" config remote.origin.url "$url"
    rm -f "$cl/x310.txt"

    # (b) branches.txt が、なくなっている → sf-install は、プロジェクトの破損として、止まる（黙って作り直さない）。git で戻せば、動く
    rm -f "$cl/sf-tools/config/branches.txt"
    it_run "$cl" bash "$IT_HOME/sf-tools/bin/sf-install.sh"
    assert_exit_fail "$IT_RC" "X3-10（branches.txt がない）: sf-install は、止まる"
    it_out_has "設定ファイルが見つかりません" && pass "X3-10（branches.txt がない）: 理由（設定ファイルが見つかりません）が出る" || fail "X3-10（branches.txt がない）: 理由が出る"
    assert_file_not_exists "$cl/sf-tools/config/branches.txt" "X3-10（branches.txt がない）: 黙って作り直さない"
    _it_git -C "$cl" checkout -- sf-tools/config/branches.txt

    # (c) release/<ブランチ>/ と branch_name.txt が、なくなっている → sf-install が復元する。復元前の sf-dryrun は、デプロイしない
    rm -rf "$cl/sf-tools/release/JOB-1" "$cl/sf-tools/release/branch_name.txt"
    it_calls_clear
    it_run "$cl" bash "$IT_HOME/sf-tools/bin/sf-dryrun.sh" -n
    assert_equals "$(it_calls sf | grep -c 'deploy start')" "0" "X3-10（release/ がない）: 対象がないため、デプロイ（検証）を呼ばない"
    assert_equals "$(it_mutating_calls | wc -l | tr -d ' ')" "0" "X3-10（release/ がない）: 外部へ書き込まない"
    it_run "$cl" bash "$IT_HOME/sf-tools/bin/sf-install.sh"
    assert_file_exists "$cl/sf-tools/release/JOB-1/deploy-target.txt" "X3-10（release/ がない）: sf-install が、release/JOB-1/ を復元する"
    assert_equals "$(cat "$cl/sf-tools/release/branch_name.txt" 2>/dev/null)" "JOB-1" "X3-10（release/ がない）: branch_name.txt も復元される"

    # (d) Salesforce に、接続していない（ログインが切れた）→ sf-dryrun は、デプロイせず、失敗で終わる
    it_add_class "$cl" ItX310
    it_set_deploy_target "$cl" JOB-1 "force-app/main/default/classes/ItX310.cls"
    : > "$IT_STATE/sf.alias"
    it_calls_clear
    it_run "$cl" bash "$IT_HOME/sf-tools/bin/sf-dryrun.sh" -n
    assert_exit_fail "$IT_RC" "X3-10（組織に接続していない）: sf-dryrun は、失敗で終わる"
    assert_equals "$(it_calls sf | grep -c 'deploy start')" "0" "X3-10（組織に接続していない）: デプロイ（検証）を呼ばない"
    echo "itorg" > "$IT_STATE/sf.alias"
}

# ------------------------------------------------------------------------------
# X8-1: 完了済みのプロジェクトで再実行
# ------------------------------------------------------------------------------
test_X8_1() {
    echo -e "\n${CLR_HEAD}--- X8-1: 完了済みのプロジェクトで sf-init を再実行 ---${CLR_RST}"
    local s0; s0=$(_state)
    IT_TIMEOUT=240
    _init 'Y\nq\n'
    it_out_has "完了" && pass "X8-1: 完了済みであることが表示される" || fail "X8-1: 完了済みであることが表示される" "$(it_out | tail -8)"
    assert_equals "$(_state)" "$s0" "X8-1: メニューで q → 何も変わらない"
    _init 'Y\n\n'
    assert_equals "$(_state)" "$s0" "X8-1: 空の入力（メニューに答えない）→ 何も変わらない"
}

# ------------------------------------------------------------------------------
# X2-1: 中断と再開
# ------------------------------------------------------------------------------
# 停止点ごとの共通の確認。引数: 停止点の名前
_resumed_equals_base() {
    assert_equals "$(_state)" "$BASE_STATE" "X2-1（$1）: 再開して完了した状態が、通しの基準と同じ（重複がない）"
    assert_equals "$(_it_git -C "$(_admin)" rev-list --count main)" "1" "X2-1（$1）: 管理者用クローンの main のコミットは 1 つ（重複がない）"
}

test_X2_1_clone() {
    echo -e "\n${CLR_HEAD}--- X2-1: Phase 3（リポジトリ作成の後・clone の途中で失敗）---${CLR_RST}"
    _fresh || return 1; IT_TIMEOUT=900
    it_ssh_fail on
    _init "$FULL_INPUT"
    assert_exit_fail "$IT_RC" "X2-1（clone）: clone が失敗すると、sf-init は失敗で終わる"
    grep -qxF "${IT_OWNER}/${IT_REPO}" "$IT_STATE/repos" && pass "X2-1（clone）: リポジトリは、すでに作られている（作成後の失敗）" || fail "X2-1（clone）: リポジトリは、すでに作られている"
    it_ssh_fail off
    _init "${RESUME_HEAD}3\n${PAT_MARK}\n\n${SLACK_MARK}\n${CHAN}\n\n1\n"
    [[ $IT_RC -eq 0 ]] || it_out | tail -15
    assert_exit_ok "$IT_RC" "X2-1（clone）: 「続きから」で、最後まで成功する"
    _resumed_equals_base "clone"
    _no_leak "$PAT_MARK" "X2-1（clone）: 中断→再開の出力・ログ・一時ファイル"
}

test_X2_1_push() {
    echo -e "\n${CLR_HEAD}--- X2-1: Phase 8（初回コミットの後・push の失敗）---${CLR_RST}"
    _fresh || return 1; IT_TIMEOUT=900
    git init -q --bare -b main "$IT_ORIGIN"; it_origin_reject on   # 空の bare を先に作り、push を拒否させる
    _init "$FULL_INPUT"
    assert_exit_fail "$IT_RC" "X2-1（push）: push が拒否されると、sf-init は失敗で終わる"
    # X8-2: 失敗の画面が案内する復旧の手順（もう一度 sf-init.sh を実行し、「続きをやる」を選ぶ）が、出る。実際に通ることは、下の再開で確認する
    it_out_has "「続きをやる」を選ぶと" && pass "X8-2: 失敗の画面に、復旧の手順（「続きをやる」を選ぶ）が、案内される" || fail "X8-2: 失敗の画面に、復旧の手順が、案内される" "$(it_out | sed 's/\x1b\[[0-9;]*m//g' | tail -5)"
    assert_equals "$(_progress)" "7" "X2-1（push）: 進捗は、Phase 7 まで（Phase 8 は、記録されない）"
    assert_equals "$(it_remote_snap | wc -l | tr -d ' ')" "0" "X2-1（push）: origin には、何も届いていない"
    _no_leak "$PAT_MARK" "X2-1（push）: 中断時の出力・ログ・一時ファイル"
    _pat_in_state && pass "X2-1（push）: Phase 8 の完了前は、PAT は、状態ファイルにだけ置かれている（再開に使う）" || fail "X2-1（push）: Phase 8 の完了前は、PAT は、状態ファイルにだけ置かれている"
    _state_mode_600 && pass "X2-1（push）: PAT のある状態ファイルの権限は 600" || fail "X2-1（push）: PAT のある状態ファイルの権限は 600"
    it_origin_reject off
    _init "${RESUME_HEAD}1\n"
    [[ $IT_RC -eq 0 ]] || it_out | tail -15
    assert_exit_ok "$IT_RC" "X2-1（push）: 「続きから」で、最後まで成功する"
    _resumed_equals_base "push"
    _no_leak "$PAT_MARK" "X2-1（push）: 再開後の出力・ログ・一時ファイル"
}

test_X2_1_secret() {
    echo -e "\n${CLR_HEAD}--- X2-1: Phase 10（コンシューマーキーの Secret 登録の失敗）---${CLR_RST}"
    _fresh || return 1; IT_TIMEOUT=900
    it_fault gh "secret set SF_CONSUMER_KEY_PROD*" 1 1 1 "HTTP 403: Resource not accessible by personal access token"
    _init "$FULL_INPUT"
    assert_exit_fail "$IT_RC" "X2-1（secret）: Secret の登録が失敗すると、sf-init は失敗で終わる"
    [[ -f "$IT_STATE/secrets/SF_CONSUMER_KEY_PROD" ]] && fail "X2-1（secret）: 失敗した Secret は、入らない" || pass "X2-1（secret）: 失敗した Secret は、入らない"
    it_fault_clear
    _init "${RESUME_HEAD}Y\n1\n"   # 続きから → 既存の証明書を再利用（Y）→ ログイン先 1
    [[ $IT_RC -eq 0 ]] || it_out | tail -15
    assert_exit_ok "$IT_RC" "X2-1（secret）: 「続きから」で、最後まで成功する"
    _resumed_equals_base "secret"
}


test_X2_1_sigterm() {
    echo -e "\n${CLR_HEAD}--- X2-1: Phase 7（Slack の Secret 登録中）を SIGTERM で止める ---${CLR_RST}"
    _fresh || return 1; IT_TIMEOUT=900
    it_fault gh "secret set SLACK_BOT_TOKEN*" 1 1 0 "" 25    # 25 秒かかる呼び出し（その間に止める）
    _init_kill "$FULL_INPUT" "secret set SLACK_BOT_TOKEN" TERM
    [[ $IT_KILL_RC -ne 0 ]] && pass "X2-1（SIGTERM）: 止めると、sf-init は非ゼロで終わる" || fail "X2-1（SIGTERM）: 止めると、sf-init は非ゼロで終わる" "rc=$IT_KILL_RC"
    [[ -f "$IT_WORK/proj/admin/.sf-init-${IT_PROJECT}.progress" ]] && pass "X2-1（SIGTERM）: 進捗が残る" || fail "X2-1（SIGTERM）: 進捗が残る"
    _pat_in_state && pass "X2-1（SIGTERM）: Phase 8 の完了前は、PAT は、状態ファイルにだけ置かれている" || fail "X2-1（SIGTERM）: Phase 8 の完了前は、PAT は、状態ファイルにだけ置かれている"
    _state_mode_600 && pass "X2-1（SIGTERM）: PAT のある状態ファイルの権限は 600" || fail "X2-1（SIGTERM）: PAT のある状態ファイルの権限は 600"
    _no_leak "$PAT_MARK" "X2-1（SIGTERM）: 中断時の出力・ログ・一時ファイル"
    it_fault_clear
    _init "${RESUME_HEAD}${SLACK_MARK}\n${CHAN}\n\n1\n"
    [[ $IT_RC -eq 0 ]] || it_out | tail -15
    assert_exit_ok "$IT_RC" "X2-1（SIGTERM）: 「続きから」で、最後まで成功する"
    _resumed_equals_base "SIGTERM"
}

test_X2_1_sigkill() {
    echo -e "\n${CLR_HEAD}--- X2-1: Phase 10（ECA の deploy 中）を SIGKILL で止める ---${CLR_RST}"
    _fresh || return 1; IT_TIMEOUT=900
    it_fault sf "project deploy start --source-dir force-app*" 1 1 0 "" 25
    _init_kill "$FULL_INPUT" "project deploy start --source-dir force-app" KILL
    [[ $IT_KILL_RC -ne 0 ]] && pass "X2-1（SIGKILL）: 強制終了すると、非ゼロで終わる" || fail "X2-1（SIGKILL）: 強制終了すると、非ゼロで終わる" "rc=$IT_KILL_RC"
    _pat_in_state && fail "X2-1（SIGKILL）: Phase 8 の完了後は、PAT が、状態ファイルから消えている" || pass "X2-1（SIGKILL）: Phase 8 の完了後は、PAT が、状態ファイルから消えている"
    _no_leak "$PAT_MARK" "X2-1（SIGKILL）: 強制終了後の出力・ログ"
    it_fault_clear
    _init "${RESUME_HEAD}Y\n1\n"   # 続きから → 既存の証明書を再利用（Y）→ ログイン先 1
    [[ $IT_RC -eq 0 ]] || it_out | tail -15
    assert_exit_ok "$IT_RC" "X2-1（SIGKILL）: 強制終了のあと、「続きから」で、最後まで成功する"
    it_out_has "古いロックを引き継ぎます" && pass "X2-1（SIGKILL）: 強制終了で残ったロックは、古いロックとして、引き継がれる" || fail "X2-1（SIGKILL）: 強制終了で残ったロックは、古いロックとして、引き継がれる"
    _resumed_equals_base "SIGKILL"
}

_it_timed() { local t0=$SECONDS rc; "$@"; rc=$?; echo "  （所要時間: $1 = $((SECONDS - t0)) 秒）"; return $rc; }

BASE_STATE=""
for _sc in ${IT_SCENARIOS:-I1 A13 X3_10 X8_1 X2_1_clone X2_1_push X2_1_secret X2_1_sigterm X2_1_sigkill}; do
    if [[ "$_sc" == X2_1_* && -z "$BASE_STATE" ]]; then
        # I1 を飛ばして実行した場合は、基準を、先に取る
        _it_timed test_I1 || break
    fi
    _it_timed "test_${_sc}" || break
done

print_summary
