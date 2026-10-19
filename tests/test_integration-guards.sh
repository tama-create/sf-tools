#!/bin/bash
# ==============================================================================
# test_integration-guards.sh - 結合テスト L1: 誤操作の防止（安全ガード）
# ==============================================================================
# 実際の git と fake で、管理者向け・本番に関わるコマンドの安全ガードを、状況ごとに確かめる。
# ハーネスと fake は tests/integration/lib.sh。計画: doc/integration-test-plan.md の 6.6
#
# 【シナリオ】
#   X6-1b  状況ごとの拒否の表: 別のオーナー・組織の admin・force-* の外・予約名の組織（prod）に接続中
#   X6-4   remove-target.txt の、危険な入力（リポジトリの外・親ディレクトリ・空・重複・存在しない・部分的に不正）
#   X6-5   sf-sync-wf: 手で変えたワークフローを、確認なしに上書きしない／--remove の安全ガード（B4 のローカル部分）
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
source "$(dirname "${BASH_SOURCE[0]}")/integration/lib.sh"
echo -e "${CLR_HEAD}=== 結合テスト L1: 誤操作の防止 ===${CLR_RST}"

trap 'it_teardown' EXIT

_head() { _it_git -C "$1" rev-parse HEAD; }
_nmut() { it_mutating_calls | wc -l | tr -d ' '; }

test_setup() {
    it_setup || { fail "サンドボックスの作成"; return 1; }
    it_seed_repo 1 || { fail "リポジトリの生成"; return 1; }
    it_make_clone devA JOB-A || { fail "クローンの作成" "$(it_out)"; return 1; }
    CL="$IT_CL"
    pass "準備: クローン（JOB-A）を作った"
}

# ------------------------------------------------------------------------------
# X6-1b: 状況ごとの拒否
# ------------------------------------------------------------------------------
test_X6_1b() {
    echo -e "\n${CLR_HEAD}--- X6-1b: 状況ごとの拒否（別のオーナー・admin・force-* の外・prod に接続中）---${CLR_RST}"
    IT_TIMEOUT=180
    local spec _sp mut

    # 別のオーナー（組織の admin でもない）: sf-update-secret は、確認の後で、拒否する（Actions 上でも同じ）
    echo "someone-else" > "$IT_STATE/gh.login"; rm -f "$IT_STATE/gh.org_role"
    it_calls_clear
    it_run "$CL" -i 'Y\n' bash "$IT_HOME/sf-tools/bin/sf-update-secret.sh"
    assert_exit_fail "$IT_RC" "X6-1b: 別のオーナーでは、sf-update-secret が拒否される"
    it_out_has "リポジトリオーナー" && pass "X6-1b: 拒否の理由（オーナーとの不一致）が出る" || fail "X6-1b: 拒否の理由（オーナーとの不一致）が出る"
    assert_equals "$(_nmut)" "0" "X6-1b: 別のオーナーでは、外部へ何も書き込まない"
    it_calls_clear
    it_run "$CL" -i '' env GITHUB_ACTIONS=true bash "$IT_HOME/sf-tools/bin/sf-update-secret.sh"
    assert_exit_fail "$IT_RC" "X6-1b: Actions 上（確認なし）でも、別のオーナーは拒否される"
    assert_equals "$(_nmut)" "0" "X6-1b: Actions 上でも、別のオーナーは、外部へ何も書き込まない"

    # 組織の有効な admin なら、オーナーの確認を通る（その先の確認で n → 中断）
    echo "admin active" > "$IT_STATE/gh.org_role"
    it_calls_clear
    it_run "$CL" -i 'n\n' bash "$IT_HOME/sf-tools/bin/sf-update-secret.sh"
    assert_exit_fail "$IT_RC" "X6-1b: 組織の admin でも、確認の n で中断する"
    it_out_has "リポジトリオーナー" && fail "X6-1b: 組織の admin は、オーナーの確認を通る" || pass "X6-1b: 組織の admin は、オーナーの確認を通る"
    rm -f "$IT_STATE/gh.org_role"; echo "$IT_OWNER" > "$IT_STATE/gh.login"

    # force-* の外では、管理者向け・開発向けのコマンドは、何もせず拒否される
    mkdir -p "$IT_WORK/plain"
    for spec in "sf-update-secret.sh" "sf-sync-wf.sh" "sf-metasync.sh" "sf-release.sh" "sf-push.sh"; do
        it_calls_clear
        it_run "$IT_WORK/plain" -i 'Y\n' bash "$IT_HOME/sf-tools/bin/$spec"
        assert_exit_fail "$IT_RC" "X6-1b: force-* の外では、${spec} が拒否される"
        it_out_has "force-*" && pass "X6-1b: ${spec}: force-* の外のメッセージが出る" || fail "X6-1b: ${spec}: force-* の外のメッセージが出る"
        assert_equals "$(it_calls | grep -vc 'sf --version')" "0" "X6-1b: force-* の外の ${spec} は、gh・sf を呼ばない"
    done

    # 予約名の組織（prod）に接続中: ローカルからのデプロイ・リリース・dry-run が拒否される
    echo "prod" > "$IT_STATE/sf.alias"
    for spec in "sf-deploy.sh" "sf-release.sh --release" "sf-dryrun.sh -n"; do
        read -ra _sp <<< "$spec"
        it_calls_clear
        it_run "$CL" -i 'Y\n' bash "$IT_HOME/sf-tools/bin/${_sp[0]}" "${_sp[@]:1}"
        assert_exit_fail "$IT_RC" "X6-1b: prod に接続中は、${spec} が拒否される"
        it_out_has "GitHub Actions を使用" && pass "X6-1b: ${spec}: PR 経由の案内が出る" || fail "X6-1b: ${spec}: PR 経由の案内が出る"
        assert_equals "$(it_calls sf | grep -c 'project deploy start')" "0" "X6-1b: prod に接続中の ${spec} は、デプロイを呼ばない"
    done
    echo "itorg" > "$IT_STATE/sf.alias"
    IT_TIMEOUT=300
}

# ------------------------------------------------------------------------------
# X6-4: remove-target.txt の危険な入力
# ------------------------------------------------------------------------------
test_X6_4() {
    echo -e "\n${CLR_HEAD}--- X6-4: remove-target.txt の危険な入力 ---${CLR_RST}"
    IT_TIMEOUT=240
    local outside="$IT_ROOT/outside.cls" name kind entries
    echo "public class Outside {}" > "$outside"
    it_add_class "$CL" Keep
    mkdir -p "$CL/force-app/main/default/classes/sub"
    it_set_deploy_target "$CL" JOB-A

    # 書式: 名前|期待(ng=拒否・ok=通る)|行をカンマ区切りで（空なら行なし）
    while IFS='|' read -r name kind entries; do
        [[ -n "$name" ]] || continue
        entries=${entries//OUTSIDE/$outside}
        { echo "[files]"; IFS=, read -ra _ents <<< "$entries"; for l in "${_ents[@]}"; do [[ -n "$l" ]] && echo "$l"; done; } > "$CL/sf-tools/release/JOB-A/remove-target.txt"
        it_calls_clear
        it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-dryrun.sh" -n
        if [[ "$kind" == "ng" ]]; then
            assert_exit_fail "$IT_RC" "X6-4: ${name} → 拒否される"
            assert_equals "$(it_calls sf | grep -c 'deploy start')" "0" "X6-4: ${name} → デプロイ（検証）まで進まない"
        else
            assert_exit_ok "$IT_RC" "X6-4: ${name} → 通る"
        fi
        assert_equals "$(_nmut)" "0" "X6-4: ${name} → 外部へ書き込まない"
    done << 'ROWS'
リポジトリの外（絶対パス）|ng|OUTSIDE
リポジトリの外（..）|ng|../../outside.cls
親ディレクトリ（ディレクトリを指す）|ng|force-app/main/default/classes
カレント（.）|ng|.
ワイルドカード|ng|force-app/main/default/classes/*.cls
存在しないファイル|ng|force-app/main/default/classes/Nope.cls
一部だけ不正（存在する+存在しない）|ng|force-app/main/default/classes/Keep.cls,force-app/main/default/classes/Nope.cls
空（何も書かれていない）|ok|
重複（同じファイルを 2 回）|ok|force-app/main/default/classes/Keep.cls,force-app/main/default/classes/Keep.cls
ROWS
    IT_TIMEOUT=300
}

# ------------------------------------------------------------------------------
# X6-5: sf-sync-wf
# ------------------------------------------------------------------------------
test_X6_5() {
    echo -e "\n${CLR_HEAD}--- X6-5: sf-sync-wf（手で変えたワークフローの扱い）---${CLR_RST}"
    local wf="$CL/.github/workflows/wf-validate.yml" tpl="$IT_HOME/sf-tools/templates/.github/workflows/wf-validate.yml" h0
    if [[ ! -f "$wf" ]]; then fail "X6-5: クローンに wf-validate.yml がない"; return; fi
    h0=$(_head "$CL")

    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-sync-wf.sh" --check
    assert_exit_ok "$IT_RC" "X6-5: 雛形と同じなら、--check は 0（差分なし）"

    # 利用者が手で変えた
    echo "# 手で変えた行（利用者の変更）" >> "$wf"
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-sync-wf.sh" --check
    assert_exit_fail "$IT_RC" "X6-5: 手で変えると、--check は 1（差分あり）"
    assert_equals "$(grep -c '手で変えた行' "$wf")" "1" "X6-5: --check は、ファイルを書き換えない"

    # 1 回目の確認（警告）で N / q / EOF → 何も変えない
    local inp label
    for label in n q eof; do
        case "$label" in n) inp='n\n' ;; q) inp='q\n' ;; *) inp='' ;; esac
        it_run "$CL" -i "$inp" bash "$IT_HOME/sf-tools/bin/sf-sync-wf.sh"
        assert_exit_fail "$IT_RC" "X6-5: 最初の確認に ${label} → 中断する"
        assert_equals "$(grep -c '手で変えた行' "$wf")" "1" "X6-5: 最初の確認に ${label} → 手で変えた内容が残る"
    done
    # 差分を見た後の 2 回目の確認で N → 何も変えない
    it_run "$CL" -i 'Y\nn\n' bash "$IT_HOME/sf-tools/bin/sf-sync-wf.sh"
    assert_exit_fail "$IT_RC" "X6-5: 差分を見た後の確認に n → 中断する"
    assert_equals "$(grep -c '手で変えた行' "$wf")" "1" "X6-5: 差分を見た後の確認に n → 手で変えた内容が残る"

    # 2 回とも Y → 雛形で上書き。コミットは作らない
    it_run "$CL" -i 'Y\nY\n' bash "$IT_HOME/sf-tools/bin/sf-sync-wf.sh"
    assert_exit_ok "$IT_RC" "X6-5: 2 回の確認に Y → 更新される"
    assert_equals "$(cmp -s "$wf" "$tpl" && echo same || echo diff)" "same" "X6-5: 雛形と同じ内容になる"
    assert_equals "$(_head "$CL")" "$h0" "X6-5: コミット・プッシュは、行わない"
    it_run "$CL" bash "$IT_HOME/sf-tools/bin/sf-sync-wf.sh" --check
    assert_exit_ok "$IT_RC" "X6-5: 更新後の --check は 0"

    # 再実行（冪等）: 最新です
    it_run "$CL" -i 'Y\n' bash "$IT_HOME/sf-tools/bin/sf-sync-wf.sh"
    assert_exit_ok "$IT_RC" "X6-5: 差分がなければ、再実行は成功する（冪等）"

    # --remove: 雛形にあるファイルは削除できない。雛形にないファイルは、二重の確認のうえ削除できる
    it_run "$CL" -i 'Y\nY\nY\n' bash "$IT_HOME/sf-tools/bin/sf-sync-wf.sh" --remove wf-validate.yml
    assert_exit_fail "$IT_RC" "X6-5: 雛形にあるワークフローは、--remove で削除できない"
    assert_file_exists "$wf" "X6-5: 雛形にあるワークフローが、残っている"
    echo "name: 廃止されたワークフロー" > "$CL/.github/workflows/old-removed.yml"
    it_run "$CL" -i 'Y\nn\n' bash "$IT_HOME/sf-tools/bin/sf-sync-wf.sh" --remove old-removed.yml
    assert_file_exists "$CL/.github/workflows/old-removed.yml" "X6-5: --remove の確認に n → 削除されない"
    it_run "$CL" -i 'Y\nY\nY\n' bash "$IT_HOME/sf-tools/bin/sf-sync-wf.sh" --remove old-removed.yml
    assert_exit_ok "$IT_RC" "X6-5: 雛形にないワークフローは、確認のうえ、--remove で削除できる"
    assert_file_not_exists "$CL/.github/workflows/old-removed.yml" "X6-5: 削除される"
    assert_equals "$(_head "$CL")" "$h0" "X6-5: --remove も、コミットは作らない"
}

_it_timed() { local t0=$SECONDS rc; "$@"; rc=$?; echo "  （所要時間: $1 = $((SECONDS - t0)) 秒）"; return $rc; }

test_setup || { print_summary; exit 1; }
for _sc in ${IT_SCENARIOS:-X6_1b X6_4 X6_5}; do
    _it_timed "test_${_sc}" || break
done

print_summary
