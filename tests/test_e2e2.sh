#!/bin/bash
# ==============================================================================
# test_e2e2.sh - tests/e2e/（実環境での sf-init 通し検証）の安全ガードと部品のテスト（2/2）
# ==============================================================================
# test_e2e.sh のテストが多く、時間がかかる（Windows の CI で約 8 分）ため、2 つのファイルに分け、並列に動かす。
# 共通の部品は tests/e2e-test-lib.sh。実際の GitHub / Salesforce には接続しない（gh / sf はモック）。
#
# 【このファイルのテスト関数】（番号は test_e2e.sh の冒頭の一覧と同じ）
#  25. シナリオ manual-delete（Secret・Variable の削除 → 検出 → 元に戻す。終了時に必ず戻す）
#  26. シナリオ validate-fail（壊れた Apex の PR → wf-validate が失敗 → 直すと成功。マージしない・必ず後始末する）
#  27. シナリオ dist-main（配布版 = SF_TOOLS_BRANCH 未設定で、sf-tools の main が使われる。rr の直後だけ）
#  28. シナリオ metasync-diff（組織側だけの Apex が、wf-metasync で main に反映される。組織と main を、必ず戻す）
#  29. 中断→再開（run.sh --interrupt）と、git の shim（main への push を 1 回だけ失敗させる）
#  30. シナリオ propagate-fail（main → staging の伝播のコンフリクト。失敗し、通知され、staging は変わらない）
#  31. シナリオ restart-org（sf-restart で接続先を staging の組織に切り替え → dry-run → 元に戻す）
#  33. シナリオ sync-wf（改変したワークフローを sf-sync-wf が見つけて直す・--remove は雛形にあるファイルを拒否）
#  34. シナリオ update-secret（sf-update-secret で秘密鍵を同じ鍵で上書き・更新日時が進む・誤ったパスは拒否される）
#  35. シナリオ cross-os（別の OS が作ったリポジトリの確認）
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/e2e-test-lib.sh"
echo -e "${CLR_HEAD}=== tests/e2e（安全ガードと部品 2/2）===${CLR_RST}"

test_e2e_scenario_manual_delete() {
    echo ""; echo -e "${CLR_HEAD}[TEST] scenario.sh manual-delete（削除 → 検出 → 元に戻す。終了時に必ず戻す）${CLR_RST}"
    _mk_cleanup_env
    _mk_status_stub
    local rc admin="$CB/root/home/tamashimon-org/e2e-20260101-000000/admin/force-e2e-20260101-000000"
    mkdir -p "$admin/.git"
    _reset_state() { printf 'PAT_TOKEN\nSLACK_BOT_TOKEN\n' > "$MB/secrets.txt"; printf 'SLACK_CHANNEL_ID=C01ABCDEFGH\nSF_USERNAME_PROD=a@example.com\n' > "$MB/vars.txt"; rm -f "$MB/secretset.failed" "$MB/status.cwd"; : > "$MOCK_CALL_LOG"; }
    export E2E_SF_INIT="$MB/status-stub.sh" E2E_STATUS_TRIES=2

    # --- 成功: 削除 → 検出（直し方つき）→ 元に戻る ---
    _reset_state
    _run_scenario -y manual-delete; rc=$?
    assert_exit_ok "$rc" "manual-delete: 成功する"
    assert_file_contains "$MB/out.log" "成功（15 件）" "manual-delete: 15 件の確認が成功する"
    assert_file_contains "$MB/out.log" "gh secret set SLACK_BOT_TOKEN" "manual-delete: 直し方が、確認されている"
    assert_equals "$(sort "$MB/secrets.txt" | tr '\n' ',')" "PAT_TOKEN,SLACK_BOT_TOKEN," "manual-delete: Secret が、元の一覧に戻る"
    assert_equals "$(cat "$MB/secretval.SLACK_BOT_TOKEN" 2>/dev/null)" "xoxb-fakeslack" "manual-delete: 戻した Secret の値が、鍵一式の Token と同じ（空で戻さない）"
    assert_equals "$(grep '^SLACK_CHANNEL_ID=' "$MB/vars.txt")" "SLACK_CHANNEL_ID=C01ABCDEFGH" "manual-delete: Variable が、元の値で戻る"
    assert_equals "$(sort "$MB/vars.txt" | tr '\n' ',')" "SF_USERNAME_PROD=a@example.com,SLACK_CHANNEL_ID=C01ABCDEFGH," "manual-delete: 触っていない Variable は、そのまま"
    assert_equals "$(grep -c 'secret delete SLACK_BOT_TOKEN' "$MOCK_CALL_LOG")" "1" "manual-delete: 削除するのは、SLACK_BOT_TOKEN だけ（1 回）"
    assert_equals "$(grep -c 'secret delete' "$MOCK_CALL_LOG")" "1" "manual-delete: ほかの Secret は、削除しない"
    assert_equals "$(grep -c 'variable delete SLACK_CHANNEL_ID' "$MOCK_CALL_LOG")" "1" "manual-delete: 削除する Variable は、SLACK_CHANNEL_ID だけ（1 回）"
    assert_equals "$(grep -c 'variable delete' "$MOCK_CALL_LOG")" "1" "manual-delete: ほかの Variable は、削除しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "repo delete" "manual-delete: リポジトリは、削除しない"
    grep -qx "$admin" "$MB/status.cwd" && pass "manual-delete: --status は、管理者用のクローンで実行される" || fail "manual-delete: --status は、管理者用のクローンで実行される" "$(cat "$MB/status.cwd")"

    # --- 診断が不足を見つけられない → 失敗（それでも、元に戻す）---
    _reset_state
    MOCK_STATUS_BLIND=1 _run_scenario -y manual-delete; rc=$?
    assert_exit_fail "$rc" "manual-delete: 診断が、不足を見つけなければ、失敗する"
    assert_equals "$(sort "$MB/secrets.txt" | tr '\n' ',')" "PAT_TOKEN,SLACK_BOT_TOKEN," "manual-delete: 失敗しても、Secret は、元に戻る"
    assert_equals "$(grep '^SLACK_CHANNEL_ID=' "$MB/vars.txt")" "SLACK_CHANNEL_ID=C01ABCDEFGH" "manual-delete: 失敗しても、Variable は、元に戻る"

    # --- 元に戻す処理の 1 回目が失敗 → 終了時に、再試行して、戻る ---
    _reset_state
    MOCK_GH_SECRET_SET_FAIL_FIRST=1 _run_scenario -y manual-delete; rc=$?
    assert_exit_fail "$rc" "manual-delete: 元に戻す処理が失敗すると、失敗として報告する"
    assert_file_contains "$MB/out.log" "元に戻せませんでした" "manual-delete: 戻せなかったことと、手での戻し方が表示される"
    assert_equals "$(sort "$MB/secrets.txt" | tr '\n' ',')" "PAT_TOKEN,SLACK_BOT_TOKEN," "manual-delete: 終了時の再試行で、Secret が、戻る"

    # --- 前提が満たされないとき: 実行できない（何も削除しない）---
    _reset_state
    rm -rf "$admin"
    _run_scenario -y manual-delete; rc=$?
    assert_exit_fail "$rc" "manual-delete: 管理者用のクローンがなければ、実行できない"
    assert_file_contains "$MB/out.log" "実行できない" "manual-delete: 「実行できない」と報告する"
    assert_file_not_contains "$MOCK_CALL_LOG" "secret delete" "manual-delete: 実行できないときは、何も削除しない"
    mkdir -p "$admin/.git"
    _reset_state; printf 'PAT_TOKEN\n' > "$MB/secrets.txt"
    _run_scenario -y manual-delete; rc=$?
    assert_exit_fail "$rc" "manual-delete: もともと不足があれば、実行できない"
    assert_file_not_contains "$MOCK_CALL_LOG" "secret delete" "manual-delete: もともと不足があるときは、何も削除しない"

    # --- 開始の警告: 書き込む内容が表示され、N で中止すると、何も削除しない ---
    _reset_state
    _run_scenario manual-delete < <(printf 'N\n'); rc=$?
    assert_exit_fail "$rc" "manual-delete: 開始の確認で N → 中止する"
    assert_file_contains "$MB/out.log" "書き込み（manual-delete）" "manual-delete: 警告に、書き込む内容が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "secret delete" "manual-delete: N のとき、何も削除しない"
    unset E2E_SF_INIT E2E_STATUS_TRIES
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 26. シナリオ validate-fail（壊れた Apex の PR → wf-validate が失敗 → 直すと成功。ブランチ・PR は後で戻す）
# ------------------------------------------------------------------------------
test_e2e_scenario_validate_fail() {
    echo ""; echo -e "${CLR_HEAD}[TEST] scenario.sh validate-fail（失敗 → 直す → 成功。マージしない・必ず後始末する）${CLR_RST}"
    _mk_cleanup_env
    local rc
    local ok_comments=$'## ❌ Salesforce 検証結果: 検証失敗\nSfToolsE2eHello.cls (1:40): Unexpected token\n---\n## ✅ Salesforce 検証結果: 検証成功'
    export E2E_RUN_FIND_TRIES=2 E2E_CONCLUSION_TRIES=1

    # --- 成功: 失敗 → 直す → 成功。マージせず、PR を閉じ、ブランチを削除する ---
    : > "$MOCK_CALL_LOG"; rm -f "$MB/prrun.cnt" "$MB/concl.cnt"
    MOCK_GH_RUN_SEQ=1 MOCK_GH_CONCL_LIST="failure success" MOCK_GH_PR_COMMENTS="$ok_comments" _run_scenario -y validate-fail; rc=$?
    [[ $rc -eq 0 ]] || sed 's/\x1b\[[0-9;]*m//g' "$MB/out.log" | tail -20
    assert_exit_ok "$rc" "validate-fail: 成功する"
    assert_file_contains "$MB/out.log" "成功（" "validate-fail: 結果が成功と表示される"
    assert_equals "$(grep -c 'api -X POST repos/.*/git/refs ' "$MOCK_CALL_LOG")" "1" "validate-fail: テスト用ブランチを 1 つ作る"
    assert_file_contains "$MOCK_CALL_LOG" "ref=refs/heads/e2e-vf-" "validate-fail: ブランチ名は、e2e-vf-時刻の形式"
    assert_equals "$(grep -c 'api -X PUT .*contents/' "$MOCK_CALL_LOG")" "7" "validate-fail: ファイルは 7 回（リリース対象 2・クラス 4・直し 1）書く"
    assert_file_not_contains "$MOCK_CALL_LOG" "branch=main" "validate-fail: main には、書き込まない"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr merge" "validate-fail: PR を、マージしない"
    assert_file_contains "$MOCK_CALL_LOG" "pr close 7" "validate-fail: PR を閉じる"
    assert_file_contains "$MOCK_CALL_LOG" "api -X DELETE repos/tamashimon-org/force-e2e-20260101-000000/git/refs/heads/e2e-vf-" "validate-fail: テスト用ブランチを削除する"
    assert_file_not_contains "$MOCK_CALL_LOG" "repo delete" "validate-fail: リポジトリは、削除しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "workflow run" "validate-fail: ワークフローを、手で起動しない"

    # --- 壊れた Apex なのに、検証が成功した → 失敗（それでも、後始末はする）---
    : > "$MOCK_CALL_LOG"; rm -f "$MB/prrun.cnt" "$MB/concl.cnt"
    MOCK_GH_RUN_SEQ=1 MOCK_GH_CONCL_LIST="success success" MOCK_GH_PR_COMMENTS="$ok_comments" _run_scenario -y validate-fail; rc=$?
    assert_exit_fail "$rc" "validate-fail: 壊れた Apex で検証が成功したら、失敗する"
    assert_file_contains "$MOCK_CALL_LOG" "pr close 7" "validate-fail: 失敗しても、PR を閉じる"
    assert_file_contains "$MOCK_CALL_LOG" "git/refs/heads/e2e-vf-" "validate-fail: 失敗しても、ブランチを削除する"

    # --- 失敗のコメントが付かない → 失敗 ---
    : > "$MOCK_CALL_LOG"; rm -f "$MB/prrun.cnt" "$MB/concl.cnt"
    MOCK_GH_RUN_SEQ=1 MOCK_GH_CONCL_LIST="failure success" MOCK_GH_PR_COMMENTS="## ✅ Salesforce 検証結果: 検証成功" E2E_COMMENT_TRIES=1 \
        _run_scenario -y validate-fail; rc=$?
    assert_exit_fail "$rc" "validate-fail: 「検証失敗」のコメントが付かなければ、失敗する"

    # --- 直しても、再検証が失敗 → 失敗 ---
    : > "$MOCK_CALL_LOG"; rm -f "$MB/prrun.cnt" "$MB/concl.cnt"
    MOCK_GH_RUN_SEQ=1 MOCK_GH_CONCL_LIST="failure failure" MOCK_GH_PR_COMMENTS="$ok_comments" _run_scenario -y validate-fail; rc=$?
    assert_exit_fail "$rc" "validate-fail: 直したあとも失敗するなら、失敗する"

    # --- ワークフローが動かない → 失敗（途中で止まっても、PR を閉じ、ブランチを削除する）---
    : > "$MOCK_CALL_LOG"; rm -f "$MB/prrun.cnt" "$MB/concl.cnt"
    MOCK_GH_RUN_NONE=1 _run_scenario -y validate-fail; rc=$?
    assert_exit_fail "$rc" "validate-fail: wf-validate が動かなければ、失敗する"
    assert_file_contains "$MOCK_CALL_LOG" "pr close 7" "validate-fail: 途中で止まっても、PR を閉じる"
    assert_file_contains "$MOCK_CALL_LOG" "git/refs/heads/e2e-vf-" "validate-fail: 途中で止まっても、ブランチを削除する"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr merge" "validate-fail: 途中で止まっても、マージしない"

    # --- 開始の警告: 書き込む内容が表示され、N で中止すると、何も作らない ---
    : > "$MOCK_CALL_LOG"
    _run_scenario validate-fail < <(printf 'N\n'); rc=$?
    assert_exit_fail "$rc" "validate-fail: 開始の確認で N → 中止する"
    assert_file_contains "$MB/out.log" "書き込み（validate-fail）" "validate-fail: 警告に、書き込む内容が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs" "validate-fail: N のとき、ブランチを作らない"
    unset E2E_RUN_FIND_TRIES E2E_CONCLUSION_TRIES
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 27. シナリオ dist-main（配布版 = SF_TOOLS_BRANCH 未設定で、sf-tools の main が使われる。rr の直後だけ）
# ------------------------------------------------------------------------------
test_e2e_scenario_dist_main() {
    echo ""; echo -e "${CLR_HEAD}[TEST] scenario.sh dist-main（Variable を一時的に削除 → main が使われる → 必ず戻す）${CLR_RST}"
    _mk_cleanup_env
    local rc g="$CB/sftools-git" o="$CB/sftools-origin.git" log_main log_dev
    local gc=(git -c user.name=t -c user.email=t@example.com)
    log_main="Run git clone -b main https://github.com/tama-create/sf-tools.git /home/runner/sf-tools"
    log_dev="Run git clone -b development https://github.com/tama-create/sf-tools.git /home/runner/sf-tools"
    # sf-tools の origin の代わり（main と development が同じ内容）
    git init -q --bare "$o"; git init -q "$g"
    mkdir -p "$g/bin" "$g/doc"; echo a > "$g/bin/x.sh"
    ( cd "$g" && "${gc[@]}" add -A && "${gc[@]}" commit -q -m first && git branch -M main && git remote add origin "$o" \
        && git push -q origin main && git push -q origin main:development ) > "$MB/gitsetup.log" 2>&1
    export E2E_SF_TOOLS_GIT_DIR="$g" E2E_RUN_FIND_TRIES=2 E2E_CONCLUSION_TRIES=1
    _reset_dm() {
        printf 'PAT_TOKEN\nSLACK_BOT_TOKEN\n' > "$MB/secrets.txt"
        printf 'SLACK_CHANNEL_ID=C01ABCDEFGH\nSF_TOOLS_BRANCH=development\n' > "$MB/vars.txt"
        : > "$MOCK_CALL_LOG"; rm -f "$MB/prrun.cnt" "$MB/concl.cnt"
    }

    # --- 成功: 削除 → main が使われる → 戻る ---
    _reset_dm
    MOCK_GH_RUN_SEQ=1 MOCK_GH_CONCL_LIST="success" MOCK_GH_RUN_LOG="$log_main" _run_scenario -y dist-main; rc=$?
    [[ $rc -eq 0 ]] || sed 's/\x1b\[[0-9;]*m//g' "$MB/out.log" | tail -20
    assert_exit_ok "$rc" "dist-main: 成功する"
    assert_file_contains "$MB/out.log" "成功（" "dist-main: 結果が成功と表示される"
    assert_equals "$(grep -c 'variable delete SF_TOOLS_BRANCH' "$MOCK_CALL_LOG")" "1" "dist-main: 削除する Variable は、SF_TOOLS_BRANCH だけ（1 回）"
    assert_equals "$(grep -c 'variable delete' "$MOCK_CALL_LOG")" "1" "dist-main: ほかの Variable は、削除しない"
    assert_equals "$(grep '^SF_TOOLS_BRANCH=' "$MB/vars.txt")" "SF_TOOLS_BRANCH=development" "dist-main: Variable が、元の値で戻る"
    assert_file_contains "$MOCK_CALL_LOG" "pr close 7" "dist-main: PR を閉じる"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr merge" "dist-main: PR を、マージしない"
    assert_file_contains "$MOCK_CALL_LOG" "git/refs/heads/e2e-dm-" "dist-main: テスト用ブランチ（e2e-dm-）を削除する"
    assert_file_not_contains "$MOCK_CALL_LOG" "branch=main" "dist-main: main には、書き込まない"

    # --- ログが development を取得していた → 失敗（それでも、Variable・PR・ブランチは戻す）---
    _reset_dm
    MOCK_GH_RUN_SEQ=1 MOCK_GH_CONCL_LIST="success" MOCK_GH_RUN_LOG="$log_dev" _run_scenario -y dist-main; rc=$?
    assert_exit_fail "$rc" "dist-main: main を取得していなければ、失敗する"
    assert_equals "$(grep '^SF_TOOLS_BRANCH=' "$MB/vars.txt")" "SF_TOOLS_BRANCH=development" "dist-main: 失敗しても、Variable は戻る"
    assert_file_contains "$MOCK_CALL_LOG" "pr close 7" "dist-main: 失敗しても、PR を閉じる"

    # --- 検証が失敗 → 失敗 ---
    _reset_dm
    MOCK_GH_RUN_SEQ=1 MOCK_GH_CONCL_LIST="failure" MOCK_GH_RUN_LOG="$log_main" _run_scenario -y dist-main; rc=$?
    assert_exit_fail "$rc" "dist-main: wf-validate が失敗したら、失敗する"

    # --- ワークフローが動かない → 失敗（途中で止まっても、すべて戻す）---
    _reset_dm
    MOCK_GH_RUN_NONE=1 _run_scenario -y dist-main; rc=$?
    assert_exit_fail "$rc" "dist-main: wf-validate が動かなければ、失敗する"
    assert_equals "$(grep '^SF_TOOLS_BRANCH=' "$MB/vars.txt")" "SF_TOOLS_BRANCH=development" "dist-main: 途中で止まっても、Variable は戻る"
    assert_file_contains "$MOCK_CALL_LOG" "pr close 7" "dist-main: 途中で止まっても、PR を閉じる"
    assert_file_contains "$MOCK_CALL_LOG" "git/refs/heads/e2e-dm-" "dist-main: 途中で止まっても、ブランチを削除する"

    # --- 前提: Variable がもともと未設定 → 実行できない（何も作らない）---
    _reset_dm; printf 'SLACK_CHANNEL_ID=C01ABCDEFGH\n' > "$MB/vars.txt"
    _run_scenario -y dist-main; rc=$?
    assert_exit_fail "$rc" "dist-main: Variable がもともと未設定なら、実行できない"
    assert_file_contains "$MB/out.log" "実行できない" "dist-main: 「実行できない」と報告する"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs" "dist-main: 実行できないときは、ブランチを作らない"

    # --- 前提: main と development の配布物に差がある → 実行できない（rr の前）---
    _reset_dm
    ( cd "$g" && git checkout -q development && echo b >> bin/x.sh && "${gc[@]}" commit -q -am dev-change && git push -q origin development ) > "$MB/gitsetup.log" 2>&1
    _run_scenario -y dist-main; rc=$?
    assert_exit_fail "$rc" "dist-main: main と development の配布物に差があれば、実行できない"
    assert_file_contains "$MB/out.log" "差があります" "dist-main: 差があることが、表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "variable delete" "dist-main: 差があるときは、Variable を削除しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs" "dist-main: 差があるときは、ブランチを作らない"
    # 配布物以外（doc）だけの差は、実行できる（rr の対象外のパス）
    ( cd "$g" && git checkout -q -f main && git push -q -f origin main:development && git checkout -q development 2>/dev/null; git reset -q --hard origin/development; echo d > doc/a.md && "${gc[@]}" add -A && "${gc[@]}" commit -q -m doc && git push -q origin development ) > "$MB/gitsetup.log" 2>&1
    _reset_dm
    MOCK_GH_RUN_SEQ=1 MOCK_GH_CONCL_LIST="success" MOCK_GH_RUN_LOG="$log_main" _run_scenario -y dist-main; rc=$?
    assert_exit_ok "$rc" "dist-main: doc だけの差なら、実行できる（配布物のパスではない）"

    # --- 前提: sf-tools の origin を取得できない → 実行できない ---
    _reset_dm
    E2E_SF_TOOLS_GIT_DIR="$CB/none" _run_scenario -y dist-main; rc=$?
    assert_exit_fail "$rc" "dist-main: sf-tools の origin を取得できなければ、実行できない"
    assert_file_not_contains "$MOCK_CALL_LOG" "variable delete" "dist-main: 取得できないときは、Variable を削除しない"

    # --- 開始の警告 ---
    _reset_dm
    _run_scenario dist-main < <(printf 'N\n'); rc=$?
    assert_exit_fail "$rc" "dist-main: 開始の確認で N → 中止する"
    assert_file_contains "$MB/out.log" "書き込み（dist-main）" "dist-main: 警告に、書き込む内容が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "variable delete" "dist-main: N のとき、何も削除しない"
    unset E2E_SF_TOOLS_GIT_DIR E2E_RUN_FIND_TRIES E2E_CONCLUSION_TRIES
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 28. シナリオ metasync-diff（組織側だけの Apex が、wf-metasync で main に反映される。組織と main を、必ず戻す）
# ------------------------------------------------------------------------------
test_e2e_scenario_metasync_diff() {
    echo ""; echo -e "${CLR_HEAD}[TEST] scenario.sh metasync-diff（組織に直接デプロイ → wf-metasync → main に反映 → 組織・main を戻す）${CLR_RST}"
    _mk_cleanup_env
    local rc cls="force-app/main/default/classes/SfToolsE2eHello.cls"
    export E2E_CONCLUSION_TRIES=1 VERIFY_DISPATCH_TRIES=2 E2E_LIST_RETRY=1
    _reset_ms() {
        rm -f "$MB/apex_created.txt" "$MB/deleted.txt" "$MB/disp.cnt" "$MB/concl.cnt" "$MB/mainfiles.txt"
        : > "$MB/mainfiles.txt"; : > "$MOCK_CALL_LOG"
        unset MOCK_SF_APEX
    }

    # --- 成功: 組織に作る → wf-metasync → main に反映 → 組織・main を戻す ---
    _reset_ms
    MOCK_GH_METASYNC_REFLECT=1 MOCK_GH_CONCL_LIST="success" _run_scenario -y metasync-diff; rc=$?
    [[ $rc -eq 0 ]] || sed 's/\x1b\[[0-9;]*m//g' "$MB/out.log" | tail -25
    assert_exit_ok "$rc" "metasync-diff: 成功する"
    assert_file_contains "$MB/out.log" "成功（" "metasync-diff: 結果が成功と表示される"
    assert_equals "$(grep -c -- '--metadata-dir' "$MOCK_CALL_LOG")" "1" "metasync-diff: 組織への直接のデプロイは、1 回"
    assert_equals "$(sort "$MB/deleted.txt" | tr '\n' ',')" "SfToolsE2eHello,SfToolsE2eHelloTest," "metasync-diff: 組織の Apex（許可された 2 つの名前）を削除する"
    assert_equals "$(grep -c 'workflow run wf-metasync.yml' "$MOCK_CALL_LOG")" "1" "metasync-diff: wf-metasync を 1 回起動する"
    assert_equals "$(grep -c 'workflow run' "$MOCK_CALL_LOG")" "1" "metasync-diff: ほかのワークフローは、起動しない"
    assert_equals "$(grep -c 'api -X DELETE repos/.*/contents/' "$MOCK_CALL_LOG")" "4" "metasync-diff: main から削除するファイルは、Hello World の 4 つだけ"
    assert_file_contains "$MOCK_CALL_LOG" "api -X DELETE repos/tamashimon-org/force-e2e-20260101-000000/contents/${cls}" "metasync-diff: main の ${cls##*/} を削除する"
    assert_equals "$(wc -c < "$MB/mainfiles.txt" | tr -d ' ')" "0" "metasync-diff: main に、Hello World のファイルが残らない"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr merge" "metasync-diff: PR は、扱わない"
    assert_file_not_contains "$MOCK_CALL_LOG" "repo delete" "metasync-diff: リポジトリは、削除しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "alias unset sf-tools-e2e-admin" "metasync-diff: （エイリアスは、保存した一覧へ戻す）"

    # --- main に反映されない → 失敗（それでも、組織は戻す）---
    _reset_ms
    MOCK_GH_CONCL_LIST="success" _run_scenario -y metasync-diff; rc=$?
    assert_exit_fail "$rc" "metasync-diff: main に反映されなければ、失敗する"
    assert_equals "$(sort "$MB/deleted.txt" | tr '\n' ',')" "SfToolsE2eHello,SfToolsE2eHelloTest," "metasync-diff: 失敗しても、組織の Apex は削除される"

    # --- wf-metasync が失敗 → 失敗（それでも、組織・main は戻す）---
    _reset_ms
    MOCK_GH_METASYNC_REFLECT=1 MOCK_GH_CONCL_LIST="failure" _run_scenario -y metasync-diff; rc=$?
    assert_exit_fail "$rc" "metasync-diff: wf-metasync が失敗したら、失敗する"
    assert_equals "$(sort "$MB/deleted.txt" | tr '\n' ',')" "SfToolsE2eHello,SfToolsE2eHelloTest," "metasync-diff: wf-metasync が失敗しても、組織の Apex は削除される"
    assert_equals "$(wc -c < "$MB/mainfiles.txt" | tr -d ' ')" "0" "metasync-diff: wf-metasync が失敗しても、main に残ったファイルは削除される"

    # --- 組織への直接のデプロイが失敗 → 失敗（削除も失敗するときは、手での戻し方を案内する）---
    _reset_ms
    MOCK_SF_DEPLOY_EXIT=1 _run_scenario -y metasync-diff; rc=$?
    assert_exit_fail "$rc" "metasync-diff: デプロイに失敗したら、失敗する"
    assert_file_contains "$MB/out.log" "cleanup.sh --yes" "metasync-diff: 組織を戻せなかったときは、cleanup.sh を案内する"

    # --- 前提: 組織にすでにある → 実行できない（何もデプロイしない）---
    _reset_ms
    MOCK_SF_APEX="SfToolsE2eHello" _run_scenario -y metasync-diff; rc=$?
    assert_exit_fail "$rc" "metasync-diff: 組織にすでに Apex があれば、実行できない"
    assert_file_contains "$MB/out.log" "実行できない" "metasync-diff: 「実行できない」と報告する"
    assert_file_not_contains "$MOCK_CALL_LOG" "--metadata-dir" "metasync-diff: 実行できないときは、デプロイしない"
    assert_file_not_contains "$MOCK_CALL_LOG" "api -X DELETE repos/.*/contents/" "metasync-diff: 実行できないときは、main のファイルを削除しない"

    # --- main に（run.sh のリリースの履歴として）すでにある → いったん外し、反映を確認し、実行前の状態へ戻す ---
    _reset_ms
    printf '%s\n' "$cls" "${cls}-meta.xml" > "$MB/mainfiles.txt"
    MOCK_GH_METASYNC_REFLECT=1 MOCK_GH_CONCL_LIST="success" _run_scenario -y metasync-diff; rc=$?
    [[ $rc -eq 0 ]] || sed 's/\x1b\[[0-9;]*m//g' "$MB/out.log" | tail -25
    assert_exit_ok "$rc" "metasync-diff: main にすでにファイルがあっても、成功する（いったん外す）"
    assert_equals "$(sort "$MB/mainfiles.txt" | tr '\n' ',')" "${cls},${cls}-meta.xml," "metasync-diff: 終了後、main は、実行前の状態（元からあった 2 つだけ）に戻る"
    assert_equals "$(grep -c 'api -X PUT .*contents/.*branch=main' "$MOCK_CALL_LOG")" "2" "metasync-diff: 元からあった 2 つのファイルを、元の本文で戻す"
    assert_file_contains "$MB/out.log" "いったん外した" "metasync-diff: いったん外したことが、表示される"


    # --- 開始の警告 ---
    _reset_ms
    _run_scenario metasync-diff < <(printf 'N\n'); rc=$?
    assert_exit_fail "$rc" "metasync-diff: 開始の確認で N → 中止する"
    assert_file_contains "$MB/out.log" "書き込み（metasync-diff）" "metasync-diff: 警告に、書き込む内容が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "--metadata-dir" "metasync-diff: N のとき、デプロイしない"
    unset E2E_CONCLUSION_TRIES VERIFY_DISPATCH_TRIES E2E_LIST_RETRY
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 29. 中断→再開（run.sh --interrupt）と、git の shim
# ------------------------------------------------------------------------------
test_e2e_interrupt() {
    echo ""; echo -e "${CLR_HEAD}[TEST] run.sh --interrupt（Phase 8 の push を 1 回だけ失敗させる git の shim）${CLR_RST}"
    _mk_cleanup_env
    local rc shim="$E2E_DIR/shims/git"
    # 本物の git の代わり: 呼ばれた引数を記録する
    cat > "$MB/realgit" << 'EOF'
#!/bin/bash
echo "REAL: $*" >> "${MOCK_CALL_LOG%/*}/realgit.log"
exit 0
EOF
    chmod +x "$MB/realgit"
    _git_shim() { E2E_REAL_GIT="$MB/realgit" E2E_GIT_FAIL_MARK="$MB/mark" bash "$shim" "$@" > "$MB/shim.out" 2>&1; }

    # --- main への push は、1 回目だけ失敗する ---
    rm -f "$MB/mark" "$MB/realgit.log"
    _git_shim -c credential.helper= push --no-verify origin main; rc=$?
    assert_equals "$rc" "128" "git の shim: main への push の 1 回目は、失敗する（終了コード 128）"
    assert_file_exists "$MB/mark" "git の shim: 失敗させた印のファイルができる"
    assert_file_contains "$MB/shim.out" "わざと失敗させました" "git の shim: 理由が表示される"
    assert_file_not_exists "$MB/realgit.log" "git の shim: 失敗させたとき、本物の git は呼ばない"
    _git_shim -c credential.helper= push --no-verify origin main; rc=$?
    assert_exit_ok "$rc" "git の shim: 2 回目の push は、通る"
    assert_file_contains "$MB/realgit.log" "REAL: -c credential.helper= push --no-verify origin main" "git の shim: 2 回目は、本物の git に、引数をそのまま渡す"

    # --- main 以外の push・push 以外は、失敗させない ---
    rm -f "$MB/mark" "$MB/realgit.log"
    _git_shim push origin admin; rc=$?
    assert_exit_ok "$rc" "git の shim: main 以外の push は、失敗させない"
    assert_file_not_exists "$MB/mark" "git の shim: main 以外の push では、印を作らない"
    _git_shim commit -m "main の変更"; rc=$?
    assert_exit_ok "$rc" "git の shim: push 以外（commit）は、失敗させない"
    _git_shim checkout main; rc=$?
    assert_exit_ok "$rc" "git の shim: push 以外（checkout main）は、失敗させない"
    assert_file_not_exists "$MB/mark" "git の shim: push 以外では、印を作らない"

    # --- 印の指定がなければ、何も失敗させない / 本物の git の指定がなければ、失敗する ---
    rm -f "$MB/mark" "$MB/realgit.log"
    ( E2E_REAL_GIT="$MB/realgit" bash "$shim" push origin main ) > "$MB/shim.out" 2>&1; rc=$?
    assert_exit_ok "$rc" "git の shim: 印の指定がなければ、main への push も失敗させない"
    ( unset E2E_REAL_GIT; E2E_GIT_FAIL_MARK="$MB/mark" bash "$shim" push origin main ) > "$MB/shim.out" 2>&1; rc=$?
    assert_exit_fail "$rc" "git の shim: 本物の git の指定がなければ、動かない"

    # --- run.sh のオプション ---
    : > "$MOCK_CALL_LOG"
    ( cd "$HM" && export HOME="$HM" PATH="$MB:$PATH" E2E_FIXTURE="$FX"
      printf 'Y' | bash "$E2E_DIR/run.sh" --interrupt --resume ) > "$MB/out.log" 2>&1; rc=$?
    assert_exit_fail "$rc" "run.sh: --interrupt と --resume の同時指定は、中止する"
    assert_file_contains "$MB/out.log" "新しくリポジトリを作るときだけ" "run.sh: --interrupt + --resume: 理由が表示される"
    assert_equals "$(grep -c 'gh repo delete\|gh repo create' "$MOCK_CALL_LOG")" "0" "run.sh: オプションの検証で中止したとき、何も削除・作成しない"
    bash "$E2E_DIR/run.sh" --help 2>&1 | grep -q -- "--interrupt" && pass "run.sh --help に、--interrupt の説明がある" || fail "run.sh --help に、--interrupt の説明がある"
    assert_file_contains "$E2E_DIR/run.sh" "_interrupt_first_run" "run.sh: 1 回目（わざと失敗）の関数がある"
    assert_file_contains "$E2E_DIR/run.sh" "shims/git" "run.sh: git の shim を使う"
    assert_file_contains "$E2E_DIR/run.sh" "「続きをやる」を選ぶと" "run.sh: 失敗の画面の復旧の案内を、確認する"
    unset MOCK_CALL_LOG MOCK_GH_REPOS MOCK_SF_ECAS
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 30. シナリオ propagate-fail（main → staging の伝播のコンフリクト。失敗し、通知され、staging は変わらない）
# ------------------------------------------------------------------------------
test_e2e_scenario_propagate_fail() {
    echo ""; echo -e "${CLR_HEAD}[TEST] scenario.sh propagate-fail（main・staging に衝突を作る → wf-propagate が失敗 → 削除して戻す）${CLR_RST}"
    _mk_cleanup_env
    local rc f="e2e-propagate-conflict.txt"
    local ok_log=$'##[error]コンフリクト: main → staging のマージでコンフリクトが発生しました\nSlack response: {"ok":true}'
    export E2E_CONCLUSION_TRIES=1 VERIFY_DISPATCH_TRIES=2
    _reset_pf() {
        rm -f "$MB/disp.cnt" "$MB/concl.cnt" "$MB/stg.cnt"
        : > "$MB/mainfiles.txt"; : > "$MB/stagingfiles.txt"; : > "$MOCK_CALL_LOG"
        unset MOCK_GH_NO_STAGING MOCK_GH_STAGING_MOVE
    }

    # --- 成功: 衝突を作る → wf-propagate が失敗・通知 → staging は変わらない → ファイルを削除 ---
    _reset_pf
    MOCK_GH_CONCL_LIST="failure" MOCK_GH_RUN_LOG="$ok_log" _run_scenario -y propagate-fail; rc=$?
    [[ $rc -eq 0 ]] || sed 's/\x1b\[[0-9;]*m//g' "$MB/out.log" | tail -25
    assert_exit_ok "$rc" "propagate-fail: 成功する"
    assert_file_contains "$MB/out.log" "成功（" "propagate-fail: 結果が成功と表示される"
    assert_equals "$(grep -c "api -X PUT .*contents/${f}.*branch=main" "$MOCK_CALL_LOG")" "1" "propagate-fail: main に、ファイルを 1 回コミットする"
    assert_equals "$(grep -c "api -X PUT .*contents/${f}.*branch=staging" "$MOCK_CALL_LOG")" "1" "propagate-fail: staging に、ファイルを 1 回コミットする"
    assert_equals "$(grep -c 'workflow run wf-propagate.yml' "$MOCK_CALL_LOG")" "1" "propagate-fail: wf-propagate を 1 回起動する"
    assert_equals "$(grep -c 'workflow run' "$MOCK_CALL_LOG")" "1" "propagate-fail: ほかのワークフローは、起動しない"
    assert_equals "$(grep -c 'api -X DELETE repos/.*/contents/' "$MOCK_CALL_LOG")" "2" "propagate-fail: 削除は、main・staging の 2 回だけ"
    assert_equals "$(wc -c < "$MB/mainfiles.txt" | tr -d ' ')" "0" "propagate-fail: main に、ファイルが残らない"
    assert_equals "$(wc -c < "$MB/stagingfiles.txt" | tr -d ' ')" "0" "propagate-fail: staging に、ファイルが残らない"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr merge" "propagate-fail: PR は、扱わない"

    # --- 伝播が成功してしまった（衝突を検出できない）→ 失敗（それでも、削除する）---
    # --- 続けて動かす: main にコミットしてよいシナリオのあとも、次のシナリオが、「main が変わった」と誤判定されない（基準を更新する）---
    _reset_pf; rm -f "$MB/mainsha.cnt"   # main の SHA の呼び出し回数を、0 に戻す（1 回目は、元の SHA・2 回目以降は、変わった SHA を返すため）
    MOCK_GH_MAIN_SHA_CHANGE=1 MOCK_GH_RUN_IDS="11" MOCK_GH_CONCL_LIST="failure" MOCK_GH_RUN_LOG="$ok_log" _run_scenario -y propagate-fail log-secrets; rc=$?
    [[ $rc -eq 0 ]] || sed 's/\x1b\[[0-9;]*m//g' "$MB/out.log" | tail -15
    assert_exit_ok "$rc" "propagate-fail → log-secrets: 続けて動かしても、成功する（main の基準を更新する）"
    assert_file_contains "$MB/out.log" "log-secrets: 成功" "propagate-fail → log-secrets: あとのシナリオも、実行される（状態が変わったと誤判定しない）"
    assert_file_not_contains "$MB/out.log" "状態（main の SHA" "propagate-fail → log-secrets: 状態の変化として、報告されない"

    _reset_pf
    MOCK_GH_CONCL_LIST="success" MOCK_GH_RUN_LOG="$ok_log" _run_scenario -y propagate-fail; rc=$?
    assert_exit_fail "$rc" "propagate-fail: wf-propagate が成功してしまったら、失敗する"
    assert_equals "$(wc -c < "$MB/mainfiles.txt" | tr -d ' ')" "0" "propagate-fail: 失敗しても、main のファイルは削除される"
    assert_equals "$(wc -c < "$MB/stagingfiles.txt" | tr -d ' ')" "0" "propagate-fail: 失敗しても、staging のファイルは削除される"

    # --- Slack への通知が出ていない → 失敗 ---
    _reset_pf
    MOCK_GH_CONCL_LIST="failure" MOCK_GH_RUN_LOG="コンフリクト" _run_scenario -y propagate-fail; rc=$?
    assert_exit_fail "$rc" "propagate-fail: Slack への通知（ok:true）がなければ、失敗する"

    # --- staging が、失敗したのに、動いた（壊した）→ 失敗 ---
    _reset_pf
    MOCK_GH_STAGING_MOVE=1 MOCK_GH_CONCL_LIST="failure" MOCK_GH_RUN_LOG="$ok_log" _run_scenario -y propagate-fail; rc=$?
    assert_exit_fail "$rc" "propagate-fail: 失敗した伝播で、staging の先頭が動いたら、失敗する"
    assert_file_contains "$MB/out.log" "ブランチを壊さない" "propagate-fail: 確認の項目が、表示される"

    # --- ワークフローが動かない → 失敗（途中で止まっても、削除する）---
    _reset_pf
    MOCK_GH_WORKFLOW_EXIT=1 _run_scenario -y propagate-fail; rc=$?
    assert_exit_fail "$rc" "propagate-fail: wf-propagate を起動できなければ、失敗する"
    assert_equals "$(wc -c < "$MB/mainfiles.txt" | tr -d ' ')" "0" "propagate-fail: 途中で止まっても、main のファイルは削除される"
    assert_equals "$(wc -c < "$MB/stagingfiles.txt" | tr -d ' ')" "0" "propagate-fail: 途中で止まっても、staging のファイルは削除される"

    # --- 前提: staging がない → 実行できない（何もコミットしない）---
    _reset_pf
    MOCK_GH_NO_STAGING=1 _run_scenario -y propagate-fail; rc=$?
    assert_exit_fail "$rc" "propagate-fail: staging がなければ、実行できない"
    assert_file_contains "$MB/out.log" "実行できない" "propagate-fail: 「実行できない」と報告する"
    assert_file_not_contains "$MOCK_CALL_LOG" "api -X PUT" "propagate-fail: 実行できないときは、何もコミットしない"
    assert_file_not_contains "$MOCK_CALL_LOG" "api -X DELETE" "propagate-fail: 実行できないときは、何も削除しない"

    # --- 前提: すでにファイルがある → 実行できない（触れない）---
    _reset_pf; echo "$f" > "$MB/mainfiles.txt"
    _run_scenario -y propagate-fail; rc=$?
    assert_exit_fail "$rc" "propagate-fail: main にすでにファイルがあれば、実行できない"
    assert_file_contains "$MB/mainfiles.txt" "$f" "propagate-fail: 実行できないときは、既存のファイルに触れない"

    # --- 開始の警告 ---
    _reset_pf
    _run_scenario propagate-fail < <(printf 'N\n'); rc=$?
    assert_exit_fail "$rc" "propagate-fail: 開始の確認で N → 中止する"
    assert_file_contains "$MB/out.log" "書き込み（propagate-fail）" "propagate-fail: 警告に、書き込む内容が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "api -X PUT" "propagate-fail: N のとき、何もコミットしない"
    unset E2E_CONCLUSION_TRIES VERIFY_DISPATCH_TRIES
    teardown "$CB"
}

test_e2e_scenario_restart_org() {
    echo ""; echo -e "${CLR_HEAD}[TEST] scenario.sh restart-org（接続先を staging の組織に切り替え → dry-run → 元に戻す）${CLR_RST}"
    _mk_cleanup_env
    _mk_restart_stubs
    local rc proj="e2e-20260101-000000" repo="force-e2e-20260101-000000"
    local clone="$CB/root/home/tamashimon-org/$proj/e2e-hello-123456/$repo"
    local fx_stg="$CB/fx-stg.env"
    cp "$FX" "$fx_stg"; echo 'E2E_SFDX_AUTH_URL_STG=force://PlatformCLI::stgurl@example.my.salesforce.com' >> "$fx_stg"
    export E2E_SF_RESTART="$MB/restart-stub.sh" E2E_SF_DRYRUN="$MB/dryrun-stub.sh" E2E_INSTALL_TIMEOUT=2 E2E_CMD_POLL_SEC=1 E2E_HEARTBEAT_SEC=100
    _reset_ro() {
        rm -rf "$clone"; mkdir -p "$clone/.sf"
        printf '{"target-org": "sf-tools-e2e-job"}\n' > "$clone/.sf/config.json"
        rm -f "$MB"/org_user.* "$MB/restart.log"
        printf 'SLACK_CHANNEL_ID=C01ABCDEFGH\nSF_USERNAME_STG=stg@example.com\n' > "$MB/vars.txt"; : > "$MB/secrets.txt"
        : > "$MOCK_CALL_LOG"
    }
    _run_scn_stg() { ( cd "$HM" && export HOME="$HM" PATH="$MB:$PATH" E2E_FIXTURE="$fx_stg" E2E_POLL_SEC=0; bash "$E2E_DIR/scenario.sh" "$@" ) > "$MB/out.log" 2>&1; }

    # --- 成功: 切り替え → 組織が変わる → dry-run → 元に戻る ---
    _reset_ro
    _run_scn_stg -y restart-org; rc=$?
    [[ $rc -eq 0 ]] || sed 's/\x1b\[[0-9;]*m//g' "$MB/out.log" | tail -25
    assert_exit_ok "$rc" "restart-org: 成功する"
    assert_file_contains "$MB/out.log" "成功（" "restart-org: 結果が成功と表示される"
    assert_equals "$(tr '\n' ',' < "$MB/restart.log")" "restart sf-tools-e2e-restart-STG,restart sf-tools-e2e-job," "restart-org: 切り替え（STG）→ 戻す（元のエイリアス）の順に、sf-restart を呼ぶ"
    assert_file_contains "$clone/.sf/config.json" "sf-tools-e2e-job" "restart-org: 終了後、クローンの接続先は、元のエイリアスに戻る"
    assert_file_contains "$MOCK_CALL_LOG" "org login sfdx-url" "restart-org: 元のエイリアスで、認証 URL でログインし直してから、ユーザーを読む"
    assert_file_not_contains "$MOCK_CALL_LOG" "project deploy" "restart-org: 組織へ、デプロイしない（dry-run は、台本）"
    assert_file_not_contains "$MOCK_CALL_LOG" "repo delete" "restart-org: リポジトリは、削除しない"

    # --- dry-run が失敗 → 失敗（それでも、元に戻す）---
    _reset_ro
    MOCK_DRYRUN_EXIT=1 _run_scn_stg -y restart-org; rc=$?
    assert_exit_fail "$rc" "restart-org: dry-run が失敗したら、失敗する"
    assert_equals "$(tr '\n' ',' < "$MB/restart.log")" "restart sf-tools-e2e-restart-STG,restart sf-tools-e2e-job," "restart-org: 失敗しても、元の組織へ戻す"
    assert_file_contains "$clone/.sf/config.json" "sf-tools-e2e-job" "restart-org: 失敗しても、クローンの接続先は、元に戻る"

    # --- 切り替え自体が失敗 → 失敗（元に戻す処理も、同じように失敗したら、手での戻し方を案内する）---
    _reset_ro
    MOCK_RESTART_FAIL=1 _run_scn_stg -y restart-org; rc=$?
    assert_exit_fail "$rc" "restart-org: sf-restart が失敗したら、失敗する"
    assert_file_contains "$MB/out.log" "sf-restart.sh を実行して" "restart-org: 戻せなかったときは、手での戻し方を案内する"

    # --- 前提: staging の組織が、鍵一式にない → 実行できない ---
    _reset_ro
    _run_scenario -y restart-org; rc=$?
    assert_exit_fail "$rc" "restart-org: 鍵一式に staging の組織がなければ、実行できない"
    assert_file_contains "$MB/out.log" "実行できない" "restart-org: 「実行できない」と報告する"
    assert_equals "$(wc -l < "$MB/restart.log" 2>/dev/null | tr -d ' ')" "" "restart-org: 実行できないときは、sf-restart を呼ばない"

    # --- 前提: 接続済みのジョブのクローンがない / SF_USERNAME_STG がない → 実行できない ---
    _reset_ro; rm -rf "$clone"
    _run_scn_stg -y restart-org; rc=$?
    assert_exit_fail "$rc" "restart-org: ジョブのクローンがなければ、実行できない"
    _reset_ro; printf 'SLACK_CHANNEL_ID=C01ABCDEFGH\n' > "$MB/vars.txt"
    _run_scn_stg -y restart-org; rc=$?
    assert_exit_fail "$rc" "restart-org: Variable SF_USERNAME_STG がなければ、実行できない"
    assert_file_not_contains "$MOCK_CALL_LOG" "org login" "restart-org: 実行できないときは、ログインしない"

    # --- 開始の警告 ---
    _reset_ro
    _run_scn_stg restart-org < <(printf 'N\n'); rc=$?
    assert_exit_fail "$rc" "restart-org: 開始の確認で N → 中止する"
    assert_file_contains "$MB/out.log" "書き込み（restart-org）" "restart-org: 警告に、書き込む内容が表示される"
    assert_equals "$(wc -l < "$MB/restart.log" 2>/dev/null | tr -d ' ')" "" "restart-org: N のとき、sf-restart を呼ばない"
    unset E2E_SF_RESTART E2E_SF_DRYRUN E2E_INSTALL_TIMEOUT E2E_CMD_POLL_SEC E2E_HEARTBEAT_SEC
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 33. シナリオ sync-wf（改変したワークフローを sf-sync-wf が見つけて直す。--remove は、雛形にあるファイルを拒否する）
# ------------------------------------------------------------------------------
test_e2e_scenario_sync_wf() {
    echo ""; echo -e "${CLR_HEAD}[TEST] scenario.sh sync-wf（B4。管理者用のクローンの中だけ）${CLR_RST}"
    _mk_cleanup_env
    # git の改行の自動変換（core.autocrlf）を、テストの中で、そろえる。シナリオは、HOME を一時フォルダに差し替えて動くため、Windows の標準の
    #   設定（true）で git を動かし、テストの確認（git status）は、CI の設定（false）で動くと、LF と CRLF の違いが、変更に見える（Windows の CI だけで失敗した）
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=false
    local rc proj="e2e-20260101-000000" repo="force-e2e-20260101-000000"
    local clone="$CB/root/home/tamashimon-org/$proj/admin/$repo" tpl="$MB/tpl"
    mkdir -p "$tpl"; printf 'name: wf-validate
on: pull_request
' > "$tpl/wf-validate.yml"
    # 代役の sf-sync-wf.sh（雛形は $tpl。--check: 差分があれば終了コード 1・雛形にないファイルは案内だけ / 引数なし: 雛形で上書き / --remove: 雛形にあれば拒否）
    cat > "$MB/syncwf-stub.sh" <<'SWEOF'
#!/bin/bash
tpl="${SYNCWF_TPL:?}"; dst=".github/workflows"
case "${1:-}" in
    --check)
        rc=0
        for f in "$tpl"/*; do n=$(basename "$f"); cmp -s "$f" "$dst/$n" || { echo "差分: $n"; rc=1; }; done
        for f in "$dst"/*; do n=$(basename "$f"); [[ -e "$tpl/$n" ]] || echo "雛形にないワークフロー（変更しません）: $n"; done
        exit $rc ;;
    --remove)
        [[ ! -e "$tpl/$2" ]] || { echo "$2 は、雛形にあるため、削除できません"; exit 1; }
        [[ -f "$dst/$2" ]] || { echo "削除対象が見つかりません"; exit 1; }
        rm -f "$dst/$2"; exit 0 ;;
    "")
        cp "$tpl"/* "$dst"/; exit 0 ;;
esac
exit 2
SWEOF
    chmod +x "$MB/syncwf-stub.sh"
    export E2E_SF_SYNC_WF="$MB/syncwf-stub.sh" SYNCWF_TPL="$tpl" E2E_CMD_POLL_SEC=1 E2E_HEARTBEAT_SEC=100
    _reset_sw() {   # 本物の git で、管理者用のクローン（admin ブランチ・雛形と同じ内容をコミット済み）を作る
        rm -rf "$clone"; mkdir -p "$clone/.github/workflows"
        cp "$tpl/wf-validate.yml" "$clone/.github/workflows/wf-validate.yml"
        ( cd "$clone" && git init -q -b admin . && git -c user.name=t -c user.email=t@example.com add -A && git -c user.name=t -c user.email=t@example.com commit -q -m init )
        : > "$MOCK_CALL_LOG"
    }

    # --- 成功: 改変 → 見つかる → 雛形に戻る → --remove の拒否と、不要なファイルの削除 → きれいに戻る ---
    _reset_sw
    _run_scenario -y sync-wf; rc=$?
    [[ $rc -eq 0 ]] || sed 's/\[[0-9;]*m//g' "$MB/out.log" | tail -25
    assert_exit_ok "$rc" "sync-wf: 成功する"
    assert_file_contains "$MB/out.log" "成功（" "sync-wf: 結果が成功と表示される"
    assert_equals "$(git -C "$clone" status --porcelain)" "" "sync-wf: 終了後、クローンの作業ツリーは、きれい（改変も、不要なファイルも、残らない）"
    assert_equals "$(git -C "$clone" rev-list --count HEAD)" "1" "sync-wf: コミットを増やさない"
    assert_file_not_contains "$MOCK_CALL_LOG" "repo delete" "sync-wf: リポジトリは、削除しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "secret set" "sync-wf: GitHub に、書き込まない（Secret）"

    # --- sf-sync-wf が、雛形に戻せない（上書きが効かない）→ 失敗する。それでも、終了時に、クローンを元に戻す ---
    _reset_sw
    # 上書き（引数なし）だけを、何もせずに成功させる代役（壊れた sf-sync-wf.sh）。ほかは、元の代役に渡す
    printf '#!/bin/bash
[[ -n "${1:-}" ]] || exit 0
exec "%s" "$@"
' "$MB/syncwf-stub.sh" > "$MB/syncwf-broken.sh"; chmod +x "$MB/syncwf-broken.sh"
    E2E_SF_SYNC_WF="$MB/syncwf-broken.sh" _run_scenario -y sync-wf; rc=$?
    assert_exit_fail "$rc" "sync-wf: 雛形に戻らなければ、失敗する"
    assert_equals "$(git -C "$clone" status --porcelain)" "" "sync-wf: 失敗しても、終了時に、クローンを元に戻す"

    # --- 前提: クローンがない / 環境ブランチの上 / 未コミットの変更 → 実行できない ---
    _reset_sw; rm -rf "$clone"
    _run_scenario -y sync-wf; rc=$?
    assert_exit_fail "$rc" "sync-wf: 管理者用のクローンがなければ、実行できない"
    assert_file_contains "$MB/out.log" "実行できない" "sync-wf: 「実行できない」と報告する"
    _reset_sw; ( cd "$clone" && git branch -q -m main )
    _run_scenario -y sync-wf; rc=$?
    assert_exit_fail "$rc" "sync-wf: 環境ブランチ（main）の上では、実行できない"
    _reset_sw; printf 'x
' >> "$clone/.github/workflows/wf-validate.yml"
    _run_scenario -y sync-wf; rc=$?
    assert_exit_fail "$rc" "sync-wf: 未コミットの変更があれば、実行できない（元に戻せなくなるため）"
    assert_equals "$(tail -n 1 "$clone/.github/workflows/wf-validate.yml")" "x" "sync-wf: 実行できないときは、あった変更に、触らない"

    # --- 開始の警告 ---
    _reset_sw
    _run_scenario sync-wf < <(printf 'N
'); rc=$?
    assert_exit_fail "$rc" "sync-wf: 開始の確認で N → 中止する"
    assert_file_contains "$MB/out.log" "書き込み（sync-wf）" "sync-wf: 警告に、書き込む内容が表示される"
    unset E2E_SF_SYNC_WF SYNCWF_TPL E2E_CMD_POLL_SEC E2E_HEARTBEAT_SEC GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 34. シナリオ update-secret（sf-update-secret で秘密鍵を同じ鍵で上書き。更新日時が進む・誤ったパスは拒否される）
# ------------------------------------------------------------------------------
test_e2e_scenario_update_secret() {
    echo ""; echo -e "${CLR_HEAD}[TEST] scenario.sh update-secret（B2。同じ秘密鍵で上書き）${CLR_RST}"
    _mk_cleanup_env
    local rc proj="e2e-20260101-000000" repo="force-e2e-20260101-000000"
    local clone="$CB/root/home/tamashimon-org/$proj/admin/$repo" key="$HM/.sf-jwt/$repo/server.key"
    # 代役の sf-update-secret.sh（入力: 続行 Y・メニュー 1・鍵のパス・更新 Y。鍵がなければ、拒否。あれば、gh secret set SF_PRIVATE_KEY）
    cat > "$MB/updsecret-stub.sh" <<'USEOF'
#!/bin/bash
read -r _a; read -r _b; read -r path
[[ -f "$path" ]] || { echo "ファイルが存在しません: $path"; exit 1; }
read -r _c
echo "更新します（秘密鍵の中身は表示しません）"
printf 'SECRET-VALUE' | gh secret set SF_PRIVATE_KEY -R tamashimon-org/force-e2e-20260101-000000
USEOF
    chmod +x "$MB/updsecret-stub.sh"
    export E2E_SF_UPDATE_SECRET="$MB/updsecret-stub.sh" E2E_SECRET_WAIT=0 E2E_CMD_POLL_SEC=1 E2E_HEARTBEAT_SEC=100
    _reset_us() {
        rm -rf "$clone" "$HM/.sf-jwt"; mkdir -p "$clone/.git" "$HM/.sf-jwt/$repo"
        printf -- '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n' > "$key"
        printf 'SF_PRIVATE_KEY\nSLACK_BOT_TOKEN\nPAT_TOKEN\n' > "$MB/secrets.txt"; rm -f "$MB/pk.ver"
        : > "$MOCK_CALL_LOG"
    }

    # --- 成功: 誤ったパスは拒否（更新されない）→ 同じ鍵で上書き（更新日時が進む・一覧は変わらない・鍵の中身は出ない）---
    _reset_us
    _run_scenario -y update-secret; rc=$?
    [[ $rc -eq 0 ]] || sed 's/\x1b\[[0-9;]*m//g' "$MB/out.log" | tail -25
    assert_exit_ok "$rc" "update-secret: 成功する"
    assert_file_contains "$MB/out.log" "成功（" "update-secret: 結果が成功と表示される"
    assert_equals "$(cat "$MB/pk.ver")" "1" "update-secret: SF_PRIVATE_KEY の更新は、1 回だけ（誤ったパスでは、更新しない）"
    assert_file_not_contains "$MB/out.log" "BEGIN PRIVATE KEY" "update-secret: 秘密鍵の中身を表示しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "repo delete" "update-secret: リポジトリは、削除しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "secret delete" "update-secret: Secret は、削除しない"

    # --- sf-update-secret が、実際には更新しない（更新日時が進まない）→ 失敗する ---
    _reset_us
    printf '#!/bin/bash\nread -r a; read -r b; read -r p; [[ -f "$p" ]] || exit 1\nexit 0\n' > "$MB/updsecret-noop.sh"; chmod +x "$MB/updsecret-noop.sh"
    E2E_SF_UPDATE_SECRET="$MB/updsecret-noop.sh" _run_scenario -y update-secret; rc=$?
    assert_exit_fail "$rc" "update-secret: 更新日時が進まなければ、失敗する"

    # --- 誤ったパスでも、更新してしまう（拒否しない）→ 失敗する ---
    _reset_us
    printf '#!/bin/bash\nread -r a; read -r b; read -r p; read -r c\nprintf x | gh secret set SF_PRIVATE_KEY -R tamashimon-org/force-e2e-20260101-000000\n' > "$MB/updsecret-bad.sh"; chmod +x "$MB/updsecret-bad.sh"
    E2E_SF_UPDATE_SECRET="$MB/updsecret-bad.sh" _run_scenario -y update-secret; rc=$?
    assert_exit_fail "$rc" "update-secret: 誤ったパスでも更新してしまうなら、失敗する"

    # --- 前提: 管理者用のクローンがない / 秘密鍵がない / Secret がない → 実行できない ---
    _reset_us; rm -rf "$clone"
    _run_scenario -y update-secret; rc=$?
    assert_exit_fail "$rc" "update-secret: 管理者用のクローンがなければ、実行できない"
    assert_file_contains "$MB/out.log" "実行できない" "update-secret: 「実行できない」と報告する"
    _reset_us; rm -f "$key"
    _run_scenario -y update-secret; rc=$?
    assert_exit_fail "$rc" "update-secret: 秘密鍵がなければ、実行できない"
    assert_file_not_contains "$MOCK_CALL_LOG" "secret set" "update-secret: 実行できないときは、Secret を更新しない"
    _reset_us
    MOCK_GH_NO_PK=1 _run_scenario -y update-secret; rc=$?
    assert_exit_fail "$rc" "update-secret: Secret SF_PRIVATE_KEY がなければ、実行できない"

    # --- 開始の警告 ---
    _reset_us
    _run_scenario update-secret < <(printf 'N\n'); rc=$?
    assert_exit_fail "$rc" "update-secret: 開始の確認で N → 中止する"
    assert_file_contains "$MB/out.log" "書き込み（update-secret）" "update-secret: 警告に、書き込む内容が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "secret set" "update-secret: N のとき、Secret を更新しない"
    unset E2E_SF_UPDATE_SECRET E2E_SECRET_WAIT E2E_CMD_POLL_SEC E2E_HEARTBEAT_SEC
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 35. シナリオ cross-os（別の OS が作ったリポジトリを clone して、改行・フック・ワークフローを確認する。読み取りのみ・--repo で指定）
# ------------------------------------------------------------------------------
test_e2e_scenario_cross_os() {
    echo ""; echo -e "${CLR_HEAD}[TEST] scenario.sh cross-os（C2。別の OS が作ったリポジトリを、clone して確認する）${CLR_RST}"
    _mk_cleanup_env
    # git の改行の自動変換を切る（CRLF のファイルを、そのまま記録する。Windows の標準の設定でも、同じ結果にする）
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=false
    local rc repo="force-e2e-20260101-000000" src="$MB/xos-src" hsrc="$MB/xos-hooks" tpl="$MB/xos-tpl"
    local base="$CB/root/home/tamashimon-org"
    mkdir -p "$hsrc" "$tpl" "$src"
    printf '#!/bin/bash\necho pre-commit\n' > "$hsrc/pre-commit"; printf '#!/bin/bash\necho pre-push\n' > "$hsrc/pre-push"
    printf 'name: wf-validate\non: pull_request\n' > "$tpl/wf-validate.yml"
    # 代役の sf-hook.sh（XOS_HOOK_MODE: ok = 同じ内容・実行できる / crlf = 行末が CRLF / diff = 内容が違う / none = 入れない / noexec = 実行権限なし）
    cat > "$MB/xos-hook.sh" <<'XHEOF'
#!/bin/bash
src="${XOS_HOOKS_SRC:?}"; mkdir -p .git/hooks
case "${XOS_HOOK_MODE:-ok}" in
    none) exit 0 ;;
    crlf) for h in pre-commit pre-push; do printf '#!/bin/bash\r\necho %s\r\n' "$h" > ".git/hooks/$h"; chmod +x ".git/hooks/$h"; done ;;
    diff) for h in pre-commit pre-push; do printf '#!/bin/bash\necho other\n' > ".git/hooks/$h"; chmod +x ".git/hooks/$h"; done ;;
    noexec) cp "$src/pre-commit" "$src/pre-push" .git/hooks/; chmod -x .git/hooks/pre-commit .git/hooks/pre-push ;;
    *) cp "$src/pre-commit" "$src/pre-push" .git/hooks/; chmod +x .git/hooks/pre-commit .git/hooks/pre-push ;;
esac
exit 0
XHEOF
    # 代役の sf-sync-wf.sh（--check: 雛形と同じなら 0、違えば 1）
    cat > "$MB/xos-sync.sh" <<'XSEOF'
#!/bin/bash
[[ "${1:-}" == "--check" ]] || exit 2
cmp -s "${SYNCWF_TPL:?}/wf-validate.yml" .github/workflows/wf-validate.yml || { echo "差分: wf-validate.yml"; exit 1; }
XSEOF
    chmod +x "$MB/xos-hook.sh" "$MB/xos-sync.sh"
    export E2E_SF_HOOK="$MB/xos-hook.sh" E2E_SF_SYNC_WF="$MB/xos-sync.sh" E2E_SF_HOOKS_DIR="$hsrc" XOS_HOOKS_SRC="$hsrc" SYNCWF_TPL="$tpl" \
           MOCK_GH_CLONE_SRC="$src" E2E_CMD_POLL_SEC=1 E2E_HEARTBEAT_SEC=100
    _reset_xos() {   # 本物の git で、clone 元のリポジトリ（main・LF のファイル）を作る。macOS のように、手元の作業フォルダは、ない
        rm -rf "$src"; mkdir -p "$src/.github/workflows" "$src/config"
        cp "$tpl/wf-validate.yml" "$src/.github/workflows/wf-validate.yml"
        printf 'main\nstaging\n' > "$src/config/branches.txt"
        ( cd "$src" && git init -q -b main . && git -c user.name=t -c user.email=t@example.com add -A && git -c user.name=t -c user.email=t@example.com commit -q -m init )
        rm -rf "$base"/e2e-20260101-000000 "$base"/e2e-xos.*
        : > "$MOCK_CALL_LOG"
    }
    _xos_left() { ls -d "$base"/e2e-xos.* 2>/dev/null | wc -l | tr -d ' '; }

    # --- 成功: --repo で指定（手元の作業フォルダがなくても動く）。一時フォルダは、残らない。GitHub には、書き込まない ---
    _reset_xos
    _run_scenario -y --repo "$repo" cross-os; rc=$?
    [[ $rc -eq 0 ]] || sed 's/\x1b\[[0-9;]*m//g' "$MB/out.log" | tail -25
    assert_exit_ok "$rc" "cross-os: 成功する（--repo で指定。手元の作業フォルダはない）"
    assert_file_contains "$MB/out.log" "成功（" "cross-os: 結果が成功と表示される"
    assert_file_contains "$MB/out.log" "CRLF（または、混在）がない" "cross-os: 改行（CRLF がない）を確認する"
    assert_file_contains "$MB/out.log" "同じ内容である" "cross-os: フックが、sf-tools のものと同じ内容かを確認する"
    assert_file_contains "$MB/out.log" "sf-sync-wf.sh --check が成功した" "cross-os: ワークフローが、雛形と同じかを確認する"
    assert_file_contains "$MOCK_CALL_LOG" "gh repo clone tamashimon-org/$repo" "cross-os: 指定されたリポジトリを clone する"
    assert_file_contains "$MOCK_CALL_LOG" "core.longpaths=true" "cross-os: Windows のパス長の上限対策（core.longpaths=true）を付けて clone する（通常の運用と同じ）"
    assert_equals "$(_xos_left)" "0" "cross-os: 終了後、clone した一時フォルダは、残らない"
    assert_file_not_contains "$MOCK_CALL_LOG" "repo delete" "cross-os: リポジトリは、削除しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "secret set" "cross-os: GitHub に、書き込まない（Secret）"
    assert_file_not_contains "$MOCK_CALL_LOG" "git push" "cross-os: push しない"

    # --- 記録されたテキストファイルに CRLF がある（Windows が作ったファイルの改行が、そのまま入った）→ 失敗する ---
    _reset_xos
    printf 'a: 1\r\nb: 2\r\n' > "$src/crlf.yml"; ( cd "$src" && git -c user.name=t -c user.email=t@example.com add -A && git -c user.name=t -c user.email=t@example.com commit -q -m crlf )
    _run_scenario -y --repo "$repo" cross-os; rc=$?
    assert_exit_fail "$rc" "cross-os: 記録されたファイルに CRLF があれば、失敗する"
    assert_file_contains "$MB/out.log" "crlf.yml" "cross-os: CRLF のファイル名を表示する"
    assert_equals "$(_xos_left)" "0" "cross-os: 失敗しても、一時フォルダは、残らない"

    # --- フック: CR が入っている / 内容が違う / 入らない / 実行できない → 失敗する ---
    _reset_xos
    XOS_HOOK_MODE=crlf _run_scenario -y --repo "$repo" cross-os; rc=$?
    assert_exit_fail "$rc" "cross-os: フックに CR があれば、失敗する"
    _reset_xos
    XOS_HOOK_MODE=diff _run_scenario -y --repo "$repo" cross-os; rc=$?
    assert_exit_fail "$rc" "cross-os: フックの内容が、sf-tools のものと違えば、失敗する"
    _reset_xos
    XOS_HOOK_MODE=none _run_scenario -y --repo "$repo" cross-os; rc=$?
    assert_exit_fail "$rc" "cross-os: フックが入らなければ、失敗する"
    if [[ "$OSTYPE" != msys* && "$OSTYPE" != cygwin* ]]; then   # Windows（Git Bash）は、実行権限を同じようには判定できないため、確認しない
        _reset_xos
        XOS_HOOK_MODE=noexec _run_scenario -y --repo "$repo" cross-os; rc=$?
        assert_exit_fail "$rc" "cross-os: フックが実行できなければ、失敗する"
    fi

    # --- ワークフローが、雛形と違う → 失敗する ---
    _reset_xos
    printf 'name: drift\n' > "$src/.github/workflows/wf-validate.yml"; ( cd "$src" && git -c user.name=t -c user.email=t@example.com add -A && git -c user.name=t -c user.email=t@example.com commit -q -m drift )
    _run_scenario -y --repo "$repo" cross-os; rc=$?
    assert_exit_fail "$rc" "cross-os: ワークフローが雛形と違えば、失敗する"

    # --- clone できない → 実行できない（失敗にはするが、何も残さない）---
    _reset_xos
    MOCK_GH_CLONE_SRC="" _run_scenario -y --repo "$repo" cross-os; rc=$?
    assert_exit_fail "$rc" "cross-os: clone できなければ、実行できない"
    assert_file_contains "$MB/out.log" "実行できない" "cross-os: 「実行できない」と報告する"
    assert_equals "$(_xos_left)" "0" "cross-os: clone できなくても、一時フォルダは、残らない"

    # --- --repo のガード: 名前の形式・値の欠落・指定なし（作業フォルダもない）---
    _reset_xos
    _run_scenario -y --repo force-test-win cross-os; rc=$?
    assert_exit_fail "$rc" "--repo: テスト用の名前の形式でなければ、拒否する"
    assert_file_contains "$MB/out.log" "テスト用のリポジトリ名" "--repo: 拒否の理由（名前の形式）を表示する"
    assert_file_not_contains "$MOCK_CALL_LOG" "repo clone" "--repo: 拒否したら、clone しない"
    _run_scenario -y cross-os --repo; rc=$?
    assert_exit_fail "$rc" "--repo: 値がなければ、拒否する"
    _run_scenario -y --repo cross-os; rc=$?
    assert_file_contains "$MB/out.log" "シナリオ名を指定してください" "--repo: 次の語は、値として扱う（シナリオ名がなくなるため、何も実行しない）"
    assert_file_not_contains "$MOCK_CALL_LOG" "repo clone" "--repo: 何も実行しないときは、clone しない"
    _run_scenario -y cross-os; rc=$?
    assert_exit_fail "$rc" "--repo なし: 手元の作業フォルダがなければ、実行できない（macOS の CI では、--repo を指定する）"
    MOCK_GH_REPO_VIEW_EXIT=1 _run_scenario -y --repo "$repo" cross-os; rc=$?
    assert_exit_fail "$rc" "--repo: GitHub にないリポジトリは、実行できない"
    assert_file_not_contains "$MOCK_CALL_LOG" "repo clone" "--repo: GitHub にないときは、clone しない"

    # --- 開始の警告（読み取りのみ）---
    _reset_xos
    _run_scenario --repo "$repo" cross-os < <(printf 'N\n'); rc=$?
    assert_exit_fail "$rc" "cross-os: 開始の確認で N → 中止する"
    assert_file_contains "$MB/out.log" "読み取りのみ" "cross-os: 警告に、読み取りのみと表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "repo clone" "cross-os: N のとき、clone しない"
    unset E2E_SF_HOOK E2E_SF_SYNC_WF E2E_SF_HOOKS_DIR XOS_HOOKS_SRC SYNCWF_TPL MOCK_GH_CLONE_SRC E2E_CMD_POLL_SEC E2E_HEARTBEAT_SEC GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
    teardown "$CB"
}

test_e2e_scenario_manual_delete
test_e2e_scenario_validate_fail
test_e2e_scenario_dist_main
test_e2e_scenario_metasync_diff
test_e2e_interrupt
test_e2e_scenario_propagate_fail
test_e2e_scenario_restart_org
test_e2e_scenario_sync_wf
test_e2e_scenario_update_secret
test_e2e_scenario_cross_os

print_summary
