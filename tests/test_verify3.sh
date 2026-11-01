#!/bin/bash
# ==============================================================================
# tests/test_verify3.sh - phases/init/verify.sh のテスト（3/3）
# ==============================================================================
# test_verify.sh のテストが多く、時間がかかるため、3 つのファイルに分け、並列に動かす。
# 共通の部品は tests/verify-test-lib.sh。テストケースの一覧は、test_verify.sh の冒頭を参照。
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/verify-test-lib.sh"

test_branch_cleanup() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 後始末: 今回作った作業用ブランチを削除する${CLR_RST}"
    local del='api -X DELETE repos/tamashimon/force-testproject/git/refs/heads/verify-hello'

    # 正常: リリース用・削除用の 2 本のブランチを、削除する（PR の履歴は、PR の番号で残る）
    _env
    _run "Y\n"
    assert_exit_ok "$RC" "正常: 正常終了する"
    assert_equals "$(grep -c "${del}-[0-9]" "$MOCK_CALL_LOG")" "1" "正常: リリース用ブランチ（verify-hello-HHMMSS）を削除する"
    assert_equals "$(grep -c "${del}-delete-[0-9]" "$MOCK_CALL_LOG")" "1" "正常: 削除用ブランチ（verify-hello-delete-HHMMSS）を削除する"
    assert_file_contains "$OUT" "作業用ブランチを削除しました" "正常: 削除した旨が表示される"
    assert_file_contains "$OUT" "PR の履歴は、PR の番号で残っています" "正常: PR の履歴が残る旨が表示される"
    # 削除は、すべての PR の処理が終わったあと（最後の PR の作成より後）
    local last_pr first_del
    last_pr=$(grep -n 'gh pr create' "$MOCK_CALL_LOG" | tail -1 | cut -d: -f1)
    first_del=$(grep -n "${del}" "$MOCK_CALL_LOG" | head -1 | cut -d: -f1)
    assert_equals "$([[ -n "$last_pr" && -n "$first_del" && "$first_del" -gt "$last_pr" ]] && echo yes || echo no)" "yes" "正常: 削除は、すべての PR の後"

    # 開いている PR があるブランチは、削除しない（警告のみ。検証の成否には、含めない）
    _env
    export MOCK_GH_OPEN_PR_COUNT=1
    _run "Y\n"
    assert_exit_ok "$RC" "開いている PR あり: 検証は、成功のまま"
    assert_file_not_contains "$MOCK_CALL_LOG" "${del}" "開いている PR あり: ブランチを削除しない"
    assert_file_contains "$OUT" "開いている PR がある" "開いている PR あり: 理由が表示される"

    # 削除に失敗しても、検証は、成功のまま（警告のみ。手動の削除方法を案内する）
    _env
    export MOCK_GH_BRANCH_DELETE_EXIT=1
    _run "Y\n"
    assert_exit_ok "$RC" "削除に失敗: 検証は、成功のまま"
    assert_file_contains "$OUT" "削除できませんでした" "削除に失敗: 警告が表示される"
    assert_file_contains "$OUT" "gh api -X DELETE repos/tamashimon/force-testproject/git/refs/heads/verify-hello-" "削除に失敗: 手動の削除方法が案内される"

    # 途中で止めたときは、調査のために、ブランチを残す
    _env
    export MOCK_GH_MERGE_EXIT=1
    _run "Y\n"
    assert_exit_fail "$RC" "途中で止まった: 非ゼロで終了する"
    assert_file_not_contains "$MOCK_CALL_LOG" "${del}" "途中で止まった: ブランチを削除しない（調査のために残す）"

    # --cleanup: 削除用ブランチだけ（リリース用は、作っていない）
    _env
    _run "Y\n" --cleanup
    assert_exit_ok "$RC" "--cleanup: 正常終了する"
    assert_equals "$(grep -c "${del}-delete-[0-9]" "$MOCK_CALL_LOG")" "1" "--cleanup: 削除用ブランチを削除する"
    assert_equals "$(grep -c "${del}-[0-9]" "$MOCK_CALL_LOG")" "0" "--cleanup: リリース用ブランチは、対象にしない（作っていない）"

    # 部品: 名前の形式の確認は、verify.sh 側（想定外の名前は、削除しない）
    _env
    unset MOCK_GH_OPEN_PR_COUNT MOCK_GH_BRANCH_DELETE_EXIT
}

test_components() {
    echo ""; echo -e "${CLR_HEAD}[TEST] --components: パターン別のサンプルを、develop だけにリリースして削除する${CLR_RST}"
    local del='api -X DELETE repos/tamashimon/force-testproject/git/refs/heads/verify-comp'

    # --plan: develop だけ。staging・main は、対象にしない。PR は作らない
    _env
    _run "" --components --plan
    assert_exit_ok "$RC" "--plan: 正常終了する"
    assert_file_contains     "$OUT" "サンプル（" "--plan: サンプルの実行内容が表示される"
    assert_file_contains     "$OUT" "develop → TAMA_DEVELOP" "--plan: develop の組織が表示される"
    assert_file_not_contains "$OUT" "staging → TAMA_STAGING" "--plan: staging は、対象にしない"
    assert_file_not_contains "$OUT" "main → TAMA_PROD" "--plan: main（本番）は、対象にしない"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr create" "--plan: PR を作らない"
    assert_file_contains     "$OUT" "メール テンプレート・表示ラベル）を" "--plan: 既存の labels がなければ、表示ラベルを含むと表示する"
    # --with-objects の --plan: リリースと削除の通しには Flow を含めない（VERIFY_SAMPLE_FLOW=0）ため、Flow を含むと表示しない
    _env
    _run "" --components --with-objects --plan
    assert_file_contains     "$OUT" "オブジェクト・項目）を" "--with-objects --plan: オブジェクト・項目を含むと表示する"
    assert_file_not_contains "$OUT" "Aura・Flow・" "--with-objects --plan: Flow を含むと表示しない（回帰: 以前は含むと表示した）"

    # 通し（既定）: オブジェクト系を含めない。リリース 1 本 + 削除 1 本。すべて develop 向け。develop の先頭から削除用のブランチを作る
    _env
    _run "\n" --components
    [[ "$RC" -eq 0 ]] || { echo "  --- 診断: verify.sh の出力（末尾 40 行）---"; tail -n 40 "$OUT" | sed 's/^/  | /'; }
    assert_exit_ok "$RC" "通し: 正常終了する"
    assert_equals "$(_count 'gh pr create')" "2" "通し: PR は 2 本（リリース 1・削除 1）"
    assert_equals "$(_count 'gh pr create.*--base develop')" "2" "通し: すべて develop 向け"
    assert_equals "$(_count 'gh pr merge')" "2" "通し: 2 本ともマージする"
    assert_file_contains "$MOCK_CALL_LOG" "git/ref/heads/develop" "通し: 削除用のブランチは、develop の先頭から作る"
    assert_file_contains "$MOCK_CALL_LOG" 'email/unfiled$public/SfToolsE2eHello.email' "通し: 名前に \$ を含むメール テンプレートのパス"
    assert_file_contains "$MOCK_CALL_LOG" "aura/SfToolsE2eHelloAura/SfToolsE2eHelloAura.cmp" "通し: Aura は、LWC と別名"
    # オブジェクト系（トリガー・Layout・オブジェクト・項目）は、既定では、触れない（削除したオブジェクトの名前が、15 日間、予約されるため）
    assert_equals "$(grep -c -- "-X PUT repos/.*\(objects/\|layouts/\|triggers/\)" "$MOCK_CALL_LOG")" "0" "通し: オブジェクト・Layout・トリガーのファイルは、追加しない"
    assert_equals "$(grep -c -- "-X PUT repos/.*flows/" "$MOCK_CALL_LOG")" "0" "通し: Flow のファイルは、追加しない（API で削除できない場合があるため）"
    assert_equals "$(grep -c "${del}-[0-9]\|${del}-delete-[0-9]" "$MOCK_CALL_LOG")" "2" "通し: 作業用ブランチ 2 本を、最後に削除する"
    assert_file_not_contains "$MOCK_CALL_LOG" "verify-comp-delete2" "通し: 段階 2 のブランチは、作らない"
    assert_file_contains "$OUT" "サンプル（パターン別のコンポーネント）の、リリースと削除が" "通し: 結果が、サンプル用の文面で表示される"
    # 通常の削除には、@ignore-missing を入れない（存在しない削除対象は、エラーにする。綴りの誤りを、見落とさないため）
    local _rt0 _b640
    _rt0=$(grep -- "-X PUT repos/.*remove-target.txt" "$MOCK_CALL_LOG" | tail -1)
    _b640="${_rt0#*content=}"; _b640="${_b640%% *}"
    assert_equals "$(printf '%s' "$_b640" | base64 -d 2>/dev/null | grep -c '@ignore-missing')" "0" "通し: 通常の削除には、@ignore-missing を入れない"
    assert_file_contains "$OUT" "オブジェクト系" "通し: オブジェクト系を含めていない旨が表示される"

    # --with-objects: リリース 1 本 + 削除 2 本（段階 1 → 段階 2）。オブジェクト・項目・Layout・トリガーも入る
    _env
    _run "\n" --components --with-objects
    [[ "$RC" -eq 0 ]] || { echo "  --- 診断: verify.sh の出力（末尾 40 行）---"; tail -n 40 "$OUT" | sed 's/^/  | /'; }
    assert_exit_ok "$RC" "--with-objects: 正常終了する"
    assert_equals "$(_count 'gh pr create')" "3" "--with-objects: PR は 3 本（リリース 1・削除 2）"
    assert_equals "$(_count 'gh pr create.*--base develop')" "3" "--with-objects: すべて develop 向け"
    assert_equals "$(_count 'gh pr merge')" "3" "--with-objects: 3 本ともマージする"
    assert_file_contains "$MOCK_CALL_LOG" "contents/force-app/main/default/objects/SfToolsE2eHello__c/fields/Note__c.field-meta.xml" "--with-objects: 項目のファイルを追加する"
    assert_file_contains "$MOCK_CALL_LOG" "SfToolsE2eHello__c-SfToolsE2eHello%20Layout.layout-meta.xml" "--with-objects: 名前に空白を含む Layout のパスは、URL エンコードして送る"
    assert_equals "$(grep -c "api -X DELETE repos/tamashimon/force-testproject/contents/.*objects/SfToolsE2eHello__c" "$MOCK_CALL_LOG")" "2" "--with-objects: 段階 2 で、オブジェクト・項目のファイルを削除する"
    assert_equals "$(grep -c "${del}-[0-9]\|${del}-delete-[0-9]\|${del}-delete2-[0-9]" "$MOCK_CALL_LOG")" "3" "--with-objects: 作業用ブランチ 3 本を、最後に削除する"
    # 段階 2 は、段階 1 のあと（段階 2 のブランチの作成は、段階 1 の PR のマージより後）
    local m1 b2
    m1=$(grep -n 'gh pr merge' "$MOCK_CALL_LOG" | sed -n 2p | cut -d: -f1)
    b2=$(grep -n 'refs.*verify-comp-delete2' "$MOCK_CALL_LOG" | head -1 | cut -d: -f1)
    assert_equals "$([[ -n "$m1" && -n "$b2" && "$b2" -gt "$m1" ]] && echo yes || echo no)" "yes" "--with-objects: 段階 2 のブランチは、段階 1 のマージの後に作る"

    # --with-objects だけの指定: 拒否する
    _env
    _run "" --with-objects
    assert_exit_fail "$RC" "--with-objects だけ: 拒否する"
    assert_file_contains "$OUT" "--components と一緒に" "--with-objects だけ: 理由が表示される"

    # --validate-only: PR は 1 本・マージしない・閉じる。リリース・削除は、行わない
    _env
    _run "\n" --components --validate-only
    assert_exit_ok "$RC" "--validate-only: 正常終了する"
    assert_equals "$(_count 'gh pr create')" "1" "--validate-only: PR は 1 本"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh pr merge" "--validate-only: マージしない"
    assert_equals "$(_count 'gh pr close')" "1" "--validate-only: PR を閉じる"
    assert_file_not_contains "$OUT" "wf-release が実行され" "--validate-only: リリースの実行を、待たない"
    assert_equals "$(grep -c "${del}" "$MOCK_CALL_LOG")" "1" "--validate-only: 作業用ブランチ（リリース用のみ）を削除する"
    assert_file_contains "$OUT" "反映はしていません" "--validate-only: 反映していない旨が表示される"
    assert_file_contains "$MOCK_CALL_LOG" "SfToolsE2eHello__c-SfToolsE2eHello%20Layout.layout-meta.xml" "--validate-only: オブジェクト系（Layout）も、検証の対象にする（何も作らないため）"
    assert_file_contains "$MOCK_CALL_LOG" "objects/SfToolsE2eHello__c/SfToolsE2eHello__c.object-meta.xml" "--validate-only: オブジェクトも、検証の対象にする"
    assert_file_contains "$MOCK_CALL_LOG" "flows/SfToolsE2eHello.flow-meta.xml" "--validate-only: Flow も、検証の対象にする（何も作らないため）"

    # --validate-only が失敗: マージしない・PR は閉じない（調査のため）・ブランチを残す
    _env
    export MOCK_GH_CONCL=failure
    _run "\n" --components --validate-only
    assert_exit_fail "$RC" "--validate-only 失敗: 非ゼロで終了する"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh pr merge" "--validate-only 失敗: マージしない"
    assert_file_not_contains "$MOCK_CALL_LOG" "${del}" "--validate-only 失敗: ブランチを残す（調査のため）"

    # --cleanup: 削除のみ（既定: PR 1 本 / --with-objects: PR 2 本（段階 1・段階 2））
    _env
    _run "\n" --components --cleanup
    assert_exit_ok "$RC" "--cleanup: 正常終了する"
    assert_equals "$(_count 'gh pr create')" "1" "--cleanup: PR は 1 本（削除の段階 1）"
    assert_file_not_contains "$OUT" "リリース用のブランチ" "--cleanup: リリース用のブランチは、作らない"
    # --cleanup の remove-target.txt には、「# @ignore-missing」を入れる（どこまで消えているか分からないため。冪等にする）
    local _rt _b64
    _rt=$(grep -- "-X PUT repos/.*remove-target.txt" "$MOCK_CALL_LOG" | head -1)
    _b64="${_rt#*content=}"; _b64="${_b64%% *}"
    assert_equals "$(printf '%s' "$_b64" | base64 -d 2>/dev/null | grep -c '^# @ignore-missing')" "1" "--cleanup: remove-target.txt に、@ignore-missing を入れる"
    assert_file_contains "$MOCK_CALL_LOG" "-X DELETE repos/tamashimon/force-testproject/contents/force-app/main/default/flows/SfToolsE2eHello.flow-meta.xml" "--cleanup: リポジトリの Flow のファイルを削除する（組織の Flow は、画面で手動で削除する）"
    _env
    _run "\n" --components --with-objects --cleanup
    assert_exit_ok "$RC" "--cleanup --with-objects: 正常終了する"
    assert_equals "$(_count 'gh pr create')" "2" "--cleanup --with-objects: PR は 2 本（削除の段階 1・段階 2）"

    # 失敗したときの後始末の案内: --components（と --with-objects）を含むコマンドを案内する
    _env
    export MOCK_GH_RELEASE_FAIL=1
    _run "\n" --components --with-objects
    assert_exit_fail "$RC" "リリースの失敗: 非ゼロで終了する"
    assert_file_contains "$OUT" "sf-init.sh --verify --components --with-objects --cleanup" "リリースの失敗: 後始末の案内に、--components --with-objects が入る"
    _env
    export MOCK_GH_RELEASE_FAIL=1
    _run "\n" --components
    assert_file_contains "$OUT" "sf-init.sh --verify --components --cleanup" "リリースの失敗（既定）: 後始末の案内に、--components が入る"
    assert_file_not_contains "$OUT" "--components --with-objects --cleanup" "リリースの失敗（既定）: --with-objects は、案内しない"

    # develop がない構成: 拒否する（本番・staging に、サンプルを入れない）
    _env
    export MOCK_GH_BRANCHES=$'main\nstaging'
    _run "\n" --components
    assert_exit_fail "$RC" "2 層（develop なし）: 拒否する"
    assert_file_contains "$OUT" "develop の組織がある構成" "2 層: 理由が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr create" "2 層: 何も作らない"
    _env
    export MOCK_GH_BRANCHES=$'main'
    _run "\n" --components
    assert_exit_fail "$RC" "1 層（main のみ）: 拒否する"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr create" "1 層: 何も作らない"

    # --validate-only だけの指定・--cleanup との併用: 拒否する
    _env
    _run "" --validate-only
    assert_exit_fail "$RC" "--validate-only だけ: 拒否する"
    assert_file_contains "$OUT" "--components と一緒に" "--validate-only だけ: 理由が表示される"
    _run "" --components --validate-only --cleanup
    assert_exit_fail "$RC" "--validate-only と --cleanup の併用: 拒否する"

    # 既存の labels がある: CustomLabels は、サンプルに含めない（上書きして削除してしまうのを避ける）
    _env
    export MOCK_GH_LABELS_EXIST=1   # 利用者のファイル（ほかのラベルも含む）
    _run "\n" --components
    assert_exit_ok "$RC" "既存の labels あり: 正常終了する"
    assert_file_contains "$OUT" "CustomLabels は、サンプルに含めません" "既存の labels あり: 理由が表示される"
    # 回帰: 表示ラベルを含めないときは、実行内容の表示にも「表示ラベル」を出さない（以前は、常に含むと表示した）
    assert_file_not_contains "$OUT" "・表示ラベル" "既存の labels あり: 実行内容に、表示ラベルを含むと表示しない"
    assert_equals "$(grep -c -- "-X [A-Z]* repos/.*labels/CustomLabels" "$MOCK_CALL_LOG")" "0" "既存の labels あり: そのファイルを、追加・削除しない（確認の読み取りのみ）"
    _env

    # 前回の検証の残り（サンプルのラベルだけのファイル）: サンプルのものとして扱う。--cleanup で、ファイルを削除する
    _env
    export MOCK_GH_LABELS_EXIST=ours
    _run "\n" --components --cleanup
    assert_exit_ok "$RC" "サンプルの labels の残り（--cleanup）: 正常終了する"
    assert_file_contains "$OUT" "サンプルの一部として扱います" "サンプルの labels の残り: サンプルのものとして扱う旨が表示される"
    assert_file_not_contains "$OUT" "CustomLabels は、サンプルに含めません" "サンプルの labels の残り: 含めない警告は、出さない"
    assert_file_contains "$MOCK_CALL_LOG" "-X DELETE repos/tamashimon/force-testproject/contents/force-app/main/default/labels/CustomLabels.labels-meta.xml" "サンプルの labels の残り: --cleanup が、そのファイルを削除する"
    # 通しの実行: 同名のファイルが、すでにある → 実行しない（--cleanup を案内する）
    _env
    export MOCK_GH_LABELS_EXIST=ours
    _run "\n" --components
    assert_exit_fail "$RC" "サンプルの labels の残り（通し）: 実行しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr create" "サンプルの labels の残り（通し）: PR を作らない"
    _env

    # 検証用と同名のファイルが、develop に、すでにある: 実行しない
    _env
    export MOCK_GH_HELLO_ON=develop
    _run "\n" --components
    assert_exit_fail "$RC" "同名のファイルが、すでにある: 実行しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr create" "同名のファイルが、すでにある: PR を作らない"
    unset MOCK_GH_HELLO_ON
    _env

    # --help に、オプションが表示される
    bash "$SF_TOOLS_DIR/phases/init/verify.sh" --help > "$OUT" 2>&1
    assert_file_contains "$OUT" "--components" "--help: --components が表示される"
    assert_file_contains "$OUT" "--validate-only" "--help: --validate-only が表示される"

    # 入口: sf-init.sh --verify --components --plan（verify.sh に、オプションが渡る）
    local init="$SF_TOOLS_DIR/bin/sf-init.sh" opt
    create_mock_sf "$MB"
    ( cd "$FDIR" && HOME="$HM" PATH="$MB:$PATH" bash "$init" --verify --components --plan ) > "$OUT" 2>&1 < /dev/null
    assert_exit_ok $? "sf-init.sh --verify --components --plan: 正常終了する"
    assert_file_contains "$OUT" "サンプル（" "sf-init.sh --verify --components --plan: サンプルの実行内容が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr create" "sf-init.sh --verify --components --plan: PR を作らない"
    # --verify なしの --components / --validate-only は、拒否する（sf-init の通常の実行に、混ぜない）
    for opt in --components --validate-only --with-objects; do
        ( cd "$FDIR" && HOME="$HM" PATH="$MB:$PATH" bash "$init" "$opt" ) > "$OUT" 2>&1 < /dev/null
        assert_exit_fail $? "${opt} だけの指定は、拒否される"
        assert_file_contains "$OUT" "--verify と一緒に指定してください" "${opt} だけの指定: 理由が表示される"
    done
}

test_branch_cleanup
test_components

teardown "$MB" "$FORCE" "$HM"
print_summary
