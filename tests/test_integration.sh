#!/bin/bash
# ==============================================================================
# test_integration.sh - 結合テスト L1（ローカル結合）のシナリオ
# ==============================================================================
# 実際の git と、ローカルの bare リポジトリ（origin の代わり）で、複数のコマンドを連動させて動かす。
# gh・sf・npm・curl・code は、状態を持つ fake（tests/integration/lib.sh）。計画: doc/integration-test-plan.md
# サンドボックスは 1 つを使い回す（作成に時間がかかるため）。シナリオは、上から順に、前のシナリオの状態を引き継ぐ。
#
# 【シナリオ】
#   A13a  新しい開発者の最初の 1 時間（sf-job → sf-start → sf-install → sf-hook → sf-dryrun → sf-push）
#         ※ sf-init の生成物ではなく、テンプレートから作った最小のリポジトリ。sf-init との通しは L2（C1）
#   X2-3  sf-push: コミットは成功・プッシュは失敗 → 再実行で、コミットが二重にならず、未プッシュのコミットが届く
#   X6-2  確認の入力（n / q / EOF / 空 Enter）で、破壊的な操作（gh・sf の書き込み）が、起きないこと
#   X6-1  管理者向けコマンドの、GitHub Actions 上での挙動（コマンドごとの表。実装の仕様どおり）
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
source "$(dirname "${BASH_SOURCE[0]}")/integration/lib.sh"
echo -e "${CLR_HEAD}=== 結合テスト L1（ローカル結合）===${CLR_RST}"

trap 'it_teardown' EXIT

CL=""   # 作業中のクローン（A13a が作る）

# バックグラウンドの sf-install の完了を待つ。引数: クローン 待つ秒数（既定 120）
_it_wait_install() {
    local cl="$1" max="${2:-300}" i=0
    while (( i < max )); do
        grep -q "npm install の確認が完了しました" "$cl/sf-tools/logs/sf-install.log" 2>/dev/null && return 0
        sleep 1; i=$((i + 1))
    done
    return 1
}

# ------------------------------------------------------------------------------
# A13a: 新しい開発者の最初の 1 時間
# ------------------------------------------------------------------------------
test_A13a() {
    echo -e "\n${CLR_HEAD}--- A13a: 新しい開発者の最初の 1 時間 ---${CLR_RST}"
    it_setup || { fail "A13a: サンドボックスの作成"; return 1; }
    it_seed_repo 1 || { fail "A13a: リポジトリの生成"; return 1; }
    local proj="$IT_WORK/proj" snap before_count
    CL="$IT_WORK/proj/JOB-1/$IT_REPO"

    # 1. sf-job（ジョブ名・確認・エイリアス・ログイン先の入力）→ sf-start まで一気に
    mkdir -p "$proj"
    it_run "$proj" -i 'JOB-1\nY\nitorg\n1\n' bash "$IT_HOME/sf-tools/bin/sf-job.sh" --owner "$IT_OWNER" --project "$IT_PROJECT"
    assert_exit_ok "$IT_RC" "A13a: sf-job が成功する（clone → sf-start まで）"
    assert_dir_exists "$CL/.git" "A13a: クローンができる"
    it_remote_snap | grep -q 'refs/heads/JOB-1 ' && pass "A13a: origin に、ジョブブランチ JOB-1 ができる" || fail "A13a: origin に、ジョブブランチ JOB-1 ができる"
    assert_equals "$(_it_git -C "$CL" rev-parse --abbrev-ref HEAD)" "JOB-1" "A13a: クローンは JOB-1 を、チェックアウトしている"
    assert_file_contains "$CL/.sf/config.json" '"itorg"' "A13a: sf-start が .sf/config.json に、エイリアスを書く"
    assert_equals "$(cat "$IT_STATE/sf.alias")" "itorg" "A13a: sf のログイン状態（エイリアス）が残る"

    # 2. sf-start がバックグラウンドで起動した sf-install の完了を待つ
    if _it_wait_install "$CL"; then pass "A13a: バックグラウンドの sf-install が、完了する"; else fail "A13a: バックグラウンドの sf-install が、完了する" "待ちきれなかった"; return 1; fi
    assert_file_exists "$CL/.git/hooks/pre-push" "A13a: pre-push フックが入る（sf-install → sf-hook）"
    assert_file_exists "$CL/sf-tools/release/JOB-1/deploy-target.txt" "A13a: release/JOB-1/ が準備される"
    assert_equals "$(cat "$CL/sf-tools/release/branch_name.txt")" "JOB-1" "A13a: branch_name.txt がジョブ名になる"

    # 3. sf-install の再実行は、冪等（コミットが増えない・フックが増えない）
    snap=$(it_snap "$CL")
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-install.sh"
    assert_exit_ok "$IT_RC" "A13a: sf-install の再実行が成功する"
    assert_equals "$(it_snap_get "$(it_snap "$CL")" head)" "$(it_snap_get "$snap" head)" "A13a: 再実行で HEAD は動かない"
    assert_equals "$(it_snap_get "$(it_snap "$CL")" hooks)" "$(it_snap_get "$snap" hooks)" "A13a: 再実行でフックは増えない"

    # 4. 開発: クラスを足し、deploy-target.txt に書いて、dry-run
    mkdir -p "$CL/force-app/main/default/classes"
    printf 'public class ItSample { }\n' > "$CL/force-app/main/default/classes/ItSample.cls"
    printf '<?xml version="1.0"?>\n<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata"><apiVersion>60.0</apiVersion><status>Active</status></ApexClass>\n' \
        > "$CL/force-app/main/default/classes/ItSample.cls-meta.xml"
    printf '[files]\nforce-app/main/default/classes/ItSample.cls\n' > "$CL/sf-tools/release/JOB-1/deploy-target.txt"
    snap=$(it_snap "$CL"); it_calls_clear
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-dryrun.sh" -n
    assert_exit_ok "$IT_RC" "A13a: sf-dryrun が成功する"
    it_calls sf | grep -q 'project deploy start .*--dry-run' && pass "A13a: sf-dryrun は、検証（--dry-run）で、デプロイを呼ぶ" || fail "A13a: sf-dryrun は、検証（--dry-run）で、デプロイを呼ぶ"
    assert_equals "$(it_mutating_calls | wc -l | tr -d ' ')" "0" "A13a: sf-dryrun は、組織へ書き込まない"
    assert_equals "$(it_snap_get "$(it_snap "$CL")" head)" "$(it_snap_get "$snap" head)" "A13a: sf-dryrun は、コミットしない"

    # 5. sf-push（コミットメッセージは code の fake が書く）→ commit フック → push フック → origin に届く
    before_count=$(it_snap_get "$(it_snap "$CL")" count)
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-push.sh"
    assert_exit_ok "$IT_RC" "A13a: sf-push が成功する"
    assert_equals "$(it_snap_get "$(it_snap "$CL")" count)" "$((before_count + 1))" "A13a: コミットが 1 つ増える"
    assert_equals "$(_it_git -C "$CL" log -1 --format=%s)" "$IT_COMMIT_MSG_DEFAULT" "A13a: コミットメッセージは、入力どおり"
    it_out_has "コミット前チェックを開始します" && pass "A13a: commit のフック（pre-commit）が動く" || fail "A13a: commit のフック（pre-commit）が動く"
    it_out_has "main 同期チェックを開始します" && pass "A13a: push のフック（pre-push）が動く" || fail "A13a: push のフック（pre-push）が動く"
    assert_equals "$(_it_git --git-dir="$IT_ORIGIN" rev-parse refs/heads/JOB-1)" "$(_it_git -C "$CL" rev-parse HEAD)" "A13a: origin の JOB-1 が、手元の HEAD に一致する"

    # 6. 変更なしでもう一度 sf-push → 何も起きない
    snap=$(it_snap "$CL")
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-push.sh"
    assert_equals "$(it_snap_get "$(it_snap "$CL")" head)" "$(it_snap_get "$snap" head)" "A13a: 変更なしの sf-push で HEAD は動かない"
    assert_equals "$(_it_git --git-dir="$IT_ORIGIN" rev-parse refs/heads/JOB-1)" "$(_it_git -C "$CL" rev-parse HEAD)" "A13a: 変更なしの sf-push で origin もずれない"
}

# ------------------------------------------------------------------------------
# X2-3: sf-push のプッシュ失敗 → 再実行
# ------------------------------------------------------------------------------
test_X2_3() {
    echo -e "\n${CLR_HEAD}--- X2-3: sf-push のプッシュ失敗 → 再実行 ---${CLR_RST}"
    local before_count remote_before
    printf 'public class ItSample2 { }\n' > "$CL/force-app/main/default/classes/ItSample2.cls"
    printf '<?xml version="1.0"?>\n<ApexClass xmlns="http://soap.sforce.com/2006/04/metadata"><apiVersion>60.0</apiVersion><status>Active</status></ApexClass>\n' \
        > "$CL/force-app/main/default/classes/ItSample2.cls-meta.xml"
    printf '[files]\nforce-app/main/default/classes/ItSample.cls\nforce-app/main/default/classes/ItSample2.cls\n' > "$CL/sf-tools/release/JOB-1/deploy-target.txt"
    before_count=$(it_snap_get "$(it_snap "$CL")" count)
    remote_before=$(_it_git --git-dir="$IT_ORIGIN" rev-parse refs/heads/JOB-1)

    it_origin_reject on
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-push.sh"
    assert_exit_fail "$IT_RC" "X2-3: プッシュが拒否されると、sf-push は失敗で終わる"
    assert_equals "$(it_snap_get "$(it_snap "$CL")" count)" "$((before_count + 1))" "X2-3: コミットは、手元に残る（1 つ）"
    assert_equals "$(_it_git --git-dir="$IT_ORIGIN" rev-parse refs/heads/JOB-1)" "$remote_before" "X2-3: origin は、変わらない"

    it_origin_reject off
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-push.sh"
    assert_equals "$(it_snap_get "$(it_snap "$CL")" count)" "$((before_count + 1))" "X2-3: 再実行で、コミットが、二重にならない"
    # 変更がなくても、未プッシュのコミットがあれば、コミットせず、プッシュだけ行う
    assert_exit_ok "$IT_RC" "X2-3: 再実行は成功する"
    it_out_has "未プッシュのコミットが 1 件" && pass "X2-3: 未プッシュのコミットがあると表示される" || fail "X2-3: 未プッシュのコミットがあると表示される"
    assert_equals "$(_it_git --git-dir="$IT_ORIGIN" rev-parse refs/heads/JOB-1)" "$(_it_git -C "$CL" rev-parse HEAD)" "X2-3: 再実行で、手元のコミットが、origin に届く"
    assert_equals "$(_it_git -C "$CL" rev-list --count origin/JOB-1..HEAD)" "0" "X2-3: 手元は、origin と揃う"
}

# ------------------------------------------------------------------------------
# X6-2: 確認の入力で、破壊的な操作が起きない
# ------------------------------------------------------------------------------
test_X6_2() {
    echo -e "\n${CLR_HEAD}--- X6-2: 確認の入力（n / q / EOF / 空 Enter）---${CLR_RST}"
    local spec inp label snap remote_before
    IT_TIMEOUT=180
    # 入力の種類: n / q / EOF（入力なし）/ 空 Enter。IT_X62_QUICK=1 のときは n と EOF だけ（Windows は、プロセスの起動が遅く、時間の予算のため）
    local inputs="n q eof enter"
    [[ "${IT_X62_QUICK:-}" == "1" ]] && inputs="n eof"
    for spec in "sf-metasync.sh" "sf-update-secret.sh" "sf-sync-wf.sh" "sf-release.sh --release" "sf-typecheck.sh" "sf-deploy.sh"; do
        for label in $inputs; do
            case "$label" in n) inp='n\n' ;; q) inp='q\n' ;; eof) inp='' ;; *) inp='\n' ;; esac
            snap=$(it_snap "$CL"); remote_before=$(it_remote_snap); it_calls_clear
            read -ra _sp <<< "$spec"   # コマンドと引数に分ける
            it_run "$CL" -i "$inp" bash "$IT_HOME/sf-tools/bin/${_sp[0]}" "${_sp[@]:1}"
            assert_exit_fail "$IT_RC" "X6-2: ${spec} に ${label} → 失敗（中断）で終わる"
            assert_equals "$(it_mutating_calls | wc -l | tr -d ' ')" "0" "X6-2: ${spec} に ${label} → 外部への書き込みがない"
            assert_equals "$(it_remote_snap)" "$remote_before" "X6-2: ${spec} に ${label} → origin は変わらない"
            assert_equals "$(it_snap_get "$(it_snap "$CL")" head)" "$(it_snap_get "$snap" head)" "X6-2: ${spec} に ${label} → 手元の HEAD は動かない"
        done
    done
    IT_TIMEOUT=300
}

# ------------------------------------------------------------------------------
# X6-1: 管理者向けコマンドの、GitHub Actions 上（GITHUB_ACTIONS=true）での挙動
# ------------------------------------------------------------------------------
# 実装の仕様どおりの表（コマンドごとに違う）。確認（続行しますか）を、省くか・省かないか、拒否するか
#   sf-typecheck  : 確認の後に「GitHub Actions 上では、実行できません」で拒否する（-y で確認を省いても、拒否される）
#   sf-sync-wf    : 確認を省かない（ワークフローを書き換えるコマンドのため）
#   sf-deploy     : --force の確認は、省かない（予約名の組織の拒否だけが、Actions 上では、外れる）
#   sf-metasync / sf-update-secret / sf-release --release : 確認を省いて、先へ進む（Actions で動かす前提のコマンド）
test_X6_1() {
    echo -e "\n${CLR_HEAD}--- X6-1: GitHub Actions 上の挙動（コマンドごとの表）---${CLR_RST}"
    local row spec want_prompt want_text _sp
    IT_TIMEOUT=180
    # 書式: コマンドと引数 | 確認を出す(1)/出さない(0) | 出力に含まれる文字（なければ空）
    while IFS='|' read -r spec want_prompt want_text; do
        [[ -n "$spec" ]] || continue
        it_calls_clear
        read -ra _sp <<< "$spec"
        it_run "$CL" -i '' env GITHUB_ACTIONS=true bash "$IT_HOME/sf-tools/bin/${_sp[0]}" "${_sp[@]:1}"
        if [[ "$want_prompt" == "1" ]]; then
            it_out_has "続行しますか" && pass "X6-1: ${spec} は、Actions 上でも、確認を出す" || fail "X6-1: ${spec} は、Actions 上でも、確認を出す"
        else
            it_out_has "続行しますか" && fail "X6-1: ${spec} は、Actions 上では、確認を出さない" || pass "X6-1: ${spec} は、Actions 上では、確認を出さない"
        fi
        [[ -z "$want_text" ]] || { it_out_has "$want_text" && pass "X6-1: ${spec} の出力に「${want_text}」" || fail "X6-1: ${spec} の出力に「${want_text}」"; }
    done << 'ROWS'
sf-typecheck.sh -y --org itorg|0|GitHub Actions 上では、実行できません
sf-sync-wf.sh|1|
sf-deploy.sh|1|
sf-metasync.sh|0|
sf-update-secret.sh|0|
sf-release.sh --release|0|デプロイ/検証が完了しました
ROWS
    # Actions 上で拒否されるコマンドは、外部へ何も書かない
    it_calls_clear
    it_run "$CL" -i '' env GITHUB_ACTIONS=true bash "$IT_HOME/sf-tools/bin/sf-typecheck.sh" -y --org itorg
    assert_exit_fail "$IT_RC" "X6-1: sf-typecheck は、Actions 上では、失敗で終わる"
    assert_equals "$(it_mutating_calls | wc -l | tr -d ' ')" "0" "X6-1: sf-typecheck は、Actions 上では、外部へ書き込まない"
    IT_TIMEOUT=300
}

# 各シナリオの所要時間（秒）を出す（CI の時間の予算の確認用）
_it_timed() { local t0=$SECONDS rc; "$@"; rc=$?; echo "  （所要時間: $1 = $((SECONDS - t0)) 秒）"; return $rc; }
# 実行するシナリオ: IT_SCENARIOS（空白区切り。既定は全部）。A13a は、他のシナリオの土台（クローン）を作るため、必ず先頭で動かす
_it_scenarios="${IT_SCENARIOS:-A13a X2_3 X6_2 X6_1}"
for _it_sc in $_it_scenarios; do
    _it_timed "test_${_it_sc}" || break
done

print_summary
