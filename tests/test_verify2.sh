#!/bin/bash
# ==============================================================================
# tests/test_verify2.sh - phases/init/verify.sh のテスト（2/3）
# ==============================================================================
# test_verify.sh のテストが多く、時間がかかるため、3 つのファイルに分け、並列に動かす。
# 共通の部品は tests/verify-test-lib.sh。テストケースの一覧は、test_verify.sh の冒頭を参照。
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/verify-test-lib.sh"

test_review_fixes() {
    echo ""; echo -e "${CLR_HEAD}[TEST] レビューの指摘への対応（別の組織の取り違え・ユーザー未登録・古いステップ名・同名のファイル）${CLR_RST}"
    # 別の段階のログインのステップが、実行されていた（別の組織に入った）→ 失敗
    _env
    export MOCK_GH_OTHER_LOGIN=success
    _run "\n"
    assert_exit_fail "$RC" "別の段階のログインが、実行されていれば、失敗する"
    assert_file_contains "$OUT" "[NG] リリース（develop）: staging の組織へのログインは、実行されていない" "別の組織に入ったことが、NG として表示される"
    # 正常: ほかの段階のログインは skipped（確認が表示される）
    _env
    _run "\n"
    assert_exit_ok "$RC" "正常: 3 層が成功する"
    assert_file_contains "$OUT" "[OK] リリース（main）: develop の組織へのログインは、実行されていない" "ほかの段階のログインが skipped であることを確認する"
    # SF_USERNAME_* が空（未登録）→ 失敗（ユーザーの照合を、黙ってスキップしない）
    _env
    export MOCK_GH_VAR_SF_USERNAME_DEV=""
    _run "\n"
    assert_exit_fail "$RC" "接続ユーザーが空なら、失敗する"
    assert_file_contains "$OUT" "[NG] リリース（develop）: develop の接続ユーザー（SF_USERNAME_DEV）が、登録されている" "未登録が、NG として表示される"
    # 古いステップ名（本番組織・ステージング組織・開発組織）のワークフロー → 正しく確認できる
    _env
    export MOCK_GH_OLD_STEPS=1
    _run "\n"
    assert_exit_ok "$RC" "古いステップ名のワークフローでも、確認できる"
    assert_file_contains "$OUT" "[OK] リリース（staging）: staging の組織への JWT ログインが成功した" "古い名前（ステージング組織）を、読める"
    # 検証用と同名のクラスのファイルが、すでにある → 実行しない（何も作らない）
    _env
    export MOCK_GH_HELLO_ON=staging
    _run "\n"
    assert_exit_fail "$RC" "同名のファイルが、すでにあれば、実行しない"
    assert_file_contains "$OUT" "検証用と同じ名前のファイルが、すでにあります" "理由が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs" "同名のファイルがある: ブランチを作らない"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr create" "同名のファイルがある: PR を作らない"
    # --cleanup は、前回の残りの後始末のため、同名のファイルがあっても、実行できる
    _run "\n" --cleanup
    assert_exit_ok "$RC" "--cleanup は、同名のファイルがあっても、実行できる"
}

test_environment() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 環境の確認（リリースの前。NG があれば、リリースへ進まない）${CLR_RST}"
    # 正常: wf-metasync を実行して、成功する
    _env
    _run "\n" --plan
    assert_file_contains "$OUT" "最初の確認 : 環境全体（SF_TOOLS_BRANCH・ログに Token が残っていないこと・wf-metasync の実行）" "--plan: 最初の確認の内容が表示される"
    assert_file_contains "$OUT" "wf-metasync は、Salesforce（main の組織）の変更を、main に同期します" "--plan: wf-metasync の影響が表示される"
    _env
    _run "\n"
    assert_exit_ok "$RC" "環境の確認とリリースが、成功する"
    assert_file_contains "$OUT" "環境（wf-metasync）: 成功した" "wf-metasync の成功が確認される"
    assert_file_contains "$OUT" "環境（wf-metasync）: sf-tools の取得が成功した" "wf-metasync の中の sf-tools の取得が確認される"
    assert_file_contains "$MOCK_CALL_LOG" "workflow run wf-metasync.yml" "wf-metasync が手動で起動される"
    # wf-metasync は、リリースの前に実行される（先に、PR を作らない）
    local first_dispatch first_pr
    first_dispatch=$(grep -n "workflow run wf-metasync" "$MOCK_CALL_LOG" | head -1 | cut -d: -f1)
    first_pr=$(grep -n "gh pr create" "$MOCK_CALL_LOG" | head -1 | cut -d: -f1)
    [[ -n "$first_dispatch" && -n "$first_pr" && "$first_dispatch" -lt "$first_pr" ]] \
        && pass "wf-metasync は、リリースの PR より前に実行される" || fail "wf-metasync は、リリースの PR より前に実行される" "dispatch=$first_dispatch pr=$first_pr"

    # SF_TOOLS_BRANCH が、不正 → リリースへ進まない
    _env
    export MOCK_GH_VAR_SF_TOOLS_BRANCH=feature-x
    _run "\n"
    assert_exit_fail "$RC" "SF_TOOLS_BRANCH が不正なら、中断する"
    assert_file_contains "$OUT" "これ以上は、進みません" "先に進まないことが表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh pr create" "環境の NG: PR を作らない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs" "環境の NG: ブランチを作らない"
    assert_file_not_contains "$MOCK_CALL_LOG" "workflow run" "環境の NG（SF_TOOLS_BRANCH）: wf-metasync も、起動しない（組織に、何も変更しない）"

    # ログに、Token が残っている → リリースへ進まない
    _env
    mkdir -p "$HM/sf-tools/logs"
    printf 'token=ghp_%s\n' "abcdefghijklmnopqrstuvwxyz0123456789" > "$HM/sf-tools/logs/old.log"
    _run "\n"
    assert_exit_fail "$RC" "ログに Token が残っていれば、中断する"
    assert_file_contains "$OUT" "Token（または認証 URL）らしい文字列が、ログに残っています" "どのログかが表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh pr create" "ログに Token: PR を作らない"
    assert_file_not_contains "$MOCK_CALL_LOG" "workflow run" "ログに Token: wf-metasync も、起動しない（組織に、何も変更しない）"
    rm -f "$HM/sf-tools/logs/old.log"

    # wf-metasync が、失敗 → リリースへ進まない
    _env
    export MOCK_GH_METASYNC_FAIL=1
    _run "\n"
    assert_exit_fail "$RC" "wf-metasync が失敗すれば、中断する"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh pr create" "wf-metasync の失敗: PR を作らない"

    # --no-metasync: wf-metasync を実行しない
    _env
    _run "\n" --no-metasync
    assert_exit_ok "$RC" "--no-metasync: 成功する"
    assert_file_not_contains "$MOCK_CALL_LOG" "workflow run" "--no-metasync: wf-metasync を起動しない"

    # --cleanup: 環境の確認は、行わない（後始末のため）
    _env
    export MOCK_GH_VAR_SF_TOOLS_BRANCH=feature-x
    _run "\n" --cleanup
    assert_exit_ok "$RC" "--cleanup: 環境の確認の NG に、影響されない"
    assert_file_not_contains "$MOCK_CALL_LOG" "workflow run" "--cleanup: wf-metasync を起動しない"

    # sf-init から呼ばれたとき（SF_VERIFY_CONFIRMED=1）: 確認を、二重には聞かない（標準入力が空でも、進む）
    _env
    export SF_VERIFY_CONFIRMED=1
    _run ""
    assert_exit_ok "$RC" "SF_VERIFY_CONFIRMED=1: 確認なしで進む"
    assert_file_not_contains "$OUT" "Enter で、" "SF_VERIFY_CONFIRMED=1: 確認の質問を出さない"
}

test_review_fixes
test_environment

teardown "$MB" "$FORCE" "$HM"
print_summary
