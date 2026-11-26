#!/bin/bash
# ==============================================================================
# test_sf-release.sh - sf-release.sh のテスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-release.sh ===${CLR_RST}"

# デフォルト（dry-run）実行 → sf deploy に --dry-run が渡される
test_dry_run_default() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" 2>&1 >/dev/null

    assert_file_contains "$MOCK_CALL_LOG" "project deploy" "デプロイコマンドが呼び出された"
    grep "project deploy" "$MOCK_CALL_LOG" | grep -q "\-\-dry-run" \
        && pass "--dry-run が渡された" || fail "--dry-run が渡された"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# --release フラグ → --dry-run なしで実行
test_release_mode() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    echo "Y" | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --release --no-open ) 2>&1 >/dev/null

    grep "project deploy" "$MOCK_CALL_LOG" | grep -qv "\-\-dry-run" \
        && pass "--release → --dry-run なし" || fail "--release → --dry-run なし"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# --force フラグ → --ignore-conflicts が渡される
test_force_flag() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --force --no-open 2>&1 >/dev/null

    grep "project deploy" "$MOCK_CALL_LOG" | grep -q "\-\-ignore-conflicts" \
        && pass "--force → --ignore-conflicts が渡された" || fail "--force → --ignore-conflicts が渡された"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# --target オプション → 指定した組織エイリアスが使われる
test_target_option() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"

    cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --target myorg --no-open 2>&1 >/dev/null

    grep "project deploy" "$MOCK_CALL_LOG" | grep -q "myorg" \
        && pass "--target → 指定エイリアスが使われた" || fail "--target → 指定エイリアスが使われた"
    teardown "$td" "$mb"
}

# デプロイ対象が空（コメント行のみ）→ 早期終了
test_empty_deploy_target() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    mkdir -p "$td/sf-tools/release/feature/test"
    echo "feature/test" > "$td/sf-tools/release/branch_name.txt"
    printf '# コメントのみ\n' > "$td/sf-tools/release/feature/test/deploy-target.txt"
    printf '# コメントのみ\n' > "$td/sf-tools/release/feature/test/remove-target.txt"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --no-open 2>&1)

    assert_output_contains "$out" "デプロイ対象がありません" "対象なし → 警告メッセージが表示された"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# 不明なオプション → エラー終了
test_unknown_option() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --unknown-option 2>&1)
    local ec=$?

    assert_exit_fail $ec "不明オプション → エラー終了"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# force-* 以外で実行 → エラー
test_outside_force_dir() {
    local rd mb
    rd=$(setup_regular_dir); mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"

    local out; out=$(cd "$rd" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" 2>&1)
    local ec=$?

    assert_exit_fail $ec "force-* 外 → エラー終了"
    teardown "$rd" "$mb"
}

# 保護組織（main/staging/develop）へのローカル実行 → エラー
test_protected_org_local_blocked() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    unset GITHUB_ACTIONS

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --target main 2>&1)
    local ec=$?

    assert_exit_fail $ec "保護組織(main) + ローカル → エラー終了"
    assert_output_contains "$out" "共有環境（予約名）のため、ローカルから実行できません" "保護組織(main) + ローカル → 適切なエラーメッセージ"
    echo "$out" | grep -q "PR 経由で GitHub Actions を使用してください" \
        && fail "保護組織(main) + ローカル → die に復旧の案内を含めない" \
        || pass "保護組織(main) + ローカル → die に復旧の案内を含めない"
    teardown "$td" "$mb"
}

# GitHub Actions 上からの保護組織実行 → 通過
test_protected_org_github_actions_allowed() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    export GITHUB_ACTIONS="true"

    cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --target main --no-open 2>&1 >/dev/null
    local ec=$?

    assert_exit_ok $ec "保護組織(main) + GITHUB_ACTIONS=true → 通過"
    unset GITHUB_ACTIONS
    teardown "$td" "$mb"
}

# 保護組織外（個人 Sandbox）へのローカル実行 → 通過
test_unprotected_org_local_allowed() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    unset GITHUB_ACTIONS

    cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --target mysandbox --no-open 2>&1 >/dev/null
    local ec=$?

    assert_exit_ok $ec "個人 Sandbox(mysandbox) + ローカル → 通過"
    teardown "$td" "$mb"
}

# staging もローカル実行禁止
test_protected_org_staging_blocked() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    unset GITHUB_ACTIONS

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --target staging 2>&1)
    local ec=$?

    assert_exit_fail $ec "保護組織(staging) + ローカル → エラー終了"
    teardown "$td" "$mb"
}

# 共有環境の予約名（prod / develop / main も）は、ローカルからは拒否する
#   以前は main / staging / develop だけで、本番の標準のエイリアス（prod）が抜けていた
test_reserved_aliases_blocked() {
    local a td mb mh out ec
    for a in prod develop main; do
        setup_std_env td mb mh
        create_all_mocks "$mb"
        setup_release_dir "$td"
        unset GITHUB_ACTIONS
        out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --release --target "$a" 2>&1)
        ec=$?
        assert_exit_fail $ec "共有環境(${a}) + ローカル → エラー終了"
        assert_output_contains "$out" "ローカルから実行できません" "共有環境(${a}) + ローカル → 拒否の旨が表示される"
        assert_file_not_contains "$MOCK_CALL_LOG" "project deploy" "共有環境(${a}) + ローカル → デプロイしない"
        teardown "$td" "$mb"
    done
}

# -t / --target の値が無い・次のオプションを値として取り込む指定は、受け付けない（デプロイしない）
test_target_without_value_rejected() {
    local td mb mh out ec args
    for args in "--release --target" "--release -t" "--release -t --no-open" "--release --target --force"; do
        setup_std_env td mb mh
        create_all_mocks "$mb"
        setup_release_dir "$td"
        unset GITHUB_ACTIONS
        # shellcheck disable=SC2086
        out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" $args 2>&1)
        ec=$?
        assert_exit_fail $ec "値のない -t / --target（${args}）→ エラー終了"
        assert_output_contains "$out" "の値（組織のエイリアス）がない、または - で始まっています" "値のない -t / --target（${args}）→ 理由が表示される"
        assert_file_not_contains "$MOCK_CALL_LOG" "project deploy" "値のない -t / --target（${args}）→ デプロイしない"
        teardown "$td" "$mb"
    done
}

# 予約名以外（個人用の組織）は、ローカルからリリースできる
test_personal_alias_allowed() {
    local td mb mh out ec
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    unset GITHUB_ACTIONS
    out=$(cd "$td" && PATH="$mb:$PATH" SF_DEPLOY_CONFIRMED=1 bash "$SF_TOOLS_DIR/bin/sf-release.sh" --release --target dev00 2>&1)
    ec=$?
    assert_exit_ok $ec "個人用の組織(dev00) + ローカル → 実行できる"
    assert_file_contains "$MOCK_CALL_LOG" "project deploy" "個人用の組織(dev00) + ローカル → デプロイされる"
    teardown "$td" "$mb"
}

# 名前を付け替えた本番組織（予約名ではない）も、ローカルからは拒否する。種類を確認できない組織も拒否する
test_renamed_production_org_denied() {
    local td mb mh out ec
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    unset GITHUB_ACTIONS
    out=$(cd "$td" && PATH="$mb:$PATH" MOCK_SF_ORG_INFO='{"status":0,"result":{"records":[{"attributes":{"type":"Organization"},"Id":"00D000000000009AAA","Name":"Real Prod","IsSandbox":false,"OrganizationType":"Enterprise Edition","TrialExpirationDate":null}]}}' SF_DEPLOY_CONFIRMED=1 bash "$SF_TOOLS_DIR/bin/sf-release.sh" --release --target myprod 2>&1)
    ec=$?
    assert_exit_fail $ec "名前を付け替えた本番組織(myprod) + ローカル → エラー終了"
    assert_output_contains "$out" "本番組織のため、ローカルから実行できません" "本番組織 → 拒否の旨が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "project deploy" "本番組織 → デプロイしない"
    out=$(cd "$td" && PATH="$mb:$PATH" MOCK_SF_ORG_QUERY_EXIT=1 SF_DEPLOY_CONFIRMED=1 bash "$SF_TOOLS_DIR/bin/sf-release.sh" --release --target mystg 2>&1)
    ec=$?
    assert_exit_fail $ec "組織の種類を確認できない + ローカル → エラー終了"
    assert_output_contains "$out" "組織の種類を確認できないため、ローカルから実行できません" "確認できない → 拒否の旨が表示される"
    # GitHub Actions 上では、組織の種類は調べない（共有環境へのリリースは、Actions の役目）
    out=$(cd "$td" && GITHUB_ACTIONS=true PATH="$mb:$PATH" MOCK_SF_ORG_INFO='{"status":0,"result":{"records":[{"attributes":{"type":"Organization"},"Id":"00D000000000009AAA","Name":"Real Prod","IsSandbox":false,"OrganizationType":"Enterprise Edition","TrialExpirationDate":null}]}}' bash "$SF_TOOLS_DIR/bin/sf-release.sh" --release --target myprod 2>&1)
    ec=$?
    assert_exit_ok $ec "GitHub Actions 上 → 組織の種類にかかわらず、実行できる"
    teardown "$td" "$mb"
}

# @isTest のクラスを含む → --test-level RunSpecifiedTests と、クラスごとの --tests が渡される（--run-tests は存在しないフラグ）
test_run_specified_tests() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    local cls="$td/force-app/main/default/classes"
    printf '@isTest\nprivate class FooTest {}\n' > "$cls/FooTest.cls"
    printf '@isTest\nprivate class BarTest {}\n' > "$cls/BarTest.cls"
    printf '[files]\nforce-app/main/default/classes/TestClass.cls\nforce-app/main/default/classes/FooTest.cls\nforce-app/main/default/classes/BarTest.cls\n' \
        > "$td/sf-tools/release/feature/test/deploy-target.txt"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --no-open 2>&1 >/dev/null

    local line; line=$(grep "project deploy" "$MOCK_CALL_LOG" | head -1)
    [[ "$line" == *"--test-level RunSpecifiedTests"* ]] && pass "テストクラスあり → --test-level RunSpecifiedTests" || fail "テストクラスあり → --test-level RunSpecifiedTests" "$line"
    [[ "$line" == *"--tests FooTest"* ]] && pass "FooTest が --tests で渡された" || fail "FooTest が --tests で渡された" "$line"
    [[ "$line" == *"--tests BarTest"* ]] && pass "BarTest が --tests で渡された（クラスごとに繰り返す）" || fail "BarTest が --tests で渡された" "$line"
    [[ "$line" != *"--run-tests"* ]] && pass "存在しないフラグ --run-tests は渡さない" || fail "存在しないフラグ --run-tests は渡さない" "$line"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

test_dry_run_default
test_release_mode
test_run_specified_tests
test_force_flag
test_target_option
test_empty_deploy_target
test_unknown_option
test_outside_force_dir
test_protected_org_local_blocked
test_protected_org_github_actions_allowed
# sf の終了コードが 0 以外（インストーラー版の不具合）→ 案内を表示して中断する
test_sf_cli_abort() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$(cd "$td" && PATH="$mb:$PATH" MOCK_SF_VERSION_EXIT=1 bash "$SF_TOOLS_DIR/bin/sf-release.sh" 2>&1)

    assert_output_contains "$out" "終了コードが 0 ではありません" "sf の終了コード 1 → 案内が表示された"
    assert_file_not_contains "$MOCK_CALL_LOG" "project deploy" "sf の終了コード 1 → デプロイの処理まで、進まない"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# [files] と [members] の混在 → package.xml に、両方が入る（sf project generate manifest は、--source-dir と --metadata を
# 同時に渡すと、共通部分だけ（重なりがなければ空）になる。別々に生成して、統合する）
test_mixed_files_and_members() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'
    local rd="$td/sf-tools/release/feature/test"
    mkdir -p "$td/force-app/main/default/flows"
    touch "$td/force-app/main/default/flows/MyFlow.flow-meta.xml"
    printf '[files]\nforce-app/main/default/classes/TestClass.cls\nforce-app/main/default/flows/MyFlow.flow-meta.xml\n\n[members]\nCustomObject:My__c\nLayout:My__c-My Layout\n' \
        > "$rd/deploy-target.txt"
    printf '[files]\n\n[members]\nApexClass:OldClass\nFlow:OldFlow\n' > "$rd/remove-target.txt"
    # 削除の対象は、組織にある（ないと、組織にない削除の対象として外れる。test_prune_missing_destructive）
    export MOCK_SF_LIST_DIR="$td/list"; mkdir -p "$MOCK_SF_LIST_DIR"
    printf '[{"fullName":"OldClass"}]' > "$MOCK_SF_LIST_DIR/ApexClass.json"
    printf '[{"fullName":"OldFlow"}]' > "$MOCK_SF_LIST_DIR/Flow.json"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --no-open 2>&1)
    local ec=$?
    unset MOCK_SF_LIST_DIR

    assert_exit_ok $ec "混在: 正常終了する"
    assert_file_contains "$rd/package.xml" "<name>ApexClass</name>"  "混在: package.xml に、[files] の ApexClass が入る"
    assert_file_contains "$rd/package.xml" "<members>TestClass</members>" "混在: [files] のメンバー名が入る"
    assert_file_contains "$rd/package.xml" "<name>Flow</name>"       "混在: [files] の Flow が入る"
    assert_file_contains "$rd/package.xml" "<name>CustomObject</name>" "混在: package.xml に、[members] の CustomObject が入る"
    assert_file_contains "$rd/package.xml" "<members>My__c-My Layout</members>" "混在: 名前に空白を含むメンバーが入る"
    assert_file_contains "$rd/destructiveChanges.xml" "<members>OldClass</members>" "混在: destructiveChanges.xml に、削除対象が入る"
    assert_file_contains "$rd/destructiveChanges.xml" "<name>Flow</name>" "混在: destructiveChanges.xml に、種類が入る"
    # 統合前の一時ファイルは、残さない
    assert_file_not_exists "$rd/package.files.xml"   "混在: 統合前の一時ファイル（files）を残さない"
    assert_file_not_exists "$rd/package.members.xml" "混在: 統合前の一時ファイル（members）を残さない"
    # sf project generate manifest は、--source-dir と --metadata を、別々の呼び出しで渡す（同時には、渡さない）
    local both
    both=$(grep "project generate manifest" "$MOCK_CALL_LOG" | grep -c -- "--source-dir.*--metadata\|--metadata.*--source-dir")
    assert_equals "$both" "0" "混在: --source-dir と --metadata を、同時に渡さない"
    assert_file_contains "$MOCK_CALL_LOG" "--manifest" "混在: デプロイに、マニフェストを渡す"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# 反映と削除の両方に同じものがある → 中断する（削除のあとの反映で作り直し、項目のデータだけが消えるため。
# 2026-11-26 に force-test-win で、オブジェクトの本体を deploy-target.txt に書き、削除する項目が反映にも入った）
test_overlap_deploy_and_remove_aborts() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'
    local rd="$td/sf-tools/release/feature/test"
    printf '[files]\n\n[members]\nCustomField:Equipment__c.LegacyNote__c\nCustomField:Equipment__c.Status__c\n' > "$rd/deploy-target.txt"
    printf '[files]\n\n[members]\nCustomField:Equipment__c.LegacyNote__c\nApexClass:OldClass\n' > "$rd/remove-target.txt"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --no-open 2>&1)
    assert_exit_fail $? "重なり: 非ゼロで終了する"
    assert_output_contains "$out" "反映（package.xml）と削除（destructiveChanges.xml）の両方に、同じものがあります" "重なり: 理由が表示される"
    assert_output_contains "$out" "CustomField:Equipment__c.LegacyNote__c" "重なり: 重なったものの種類と名前が表示される"
    assert_output_not_contains "$out" "ERROR.*CustomField:Equipment__c.Status__c" "重なり: 重なっていないものは、重なりとして表示しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "project deploy" "重なり: デプロイまで、進まない（dry-run も行わない）"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# [members] のみ・[files] のみ → 従来どおり、package.xml が生成される
test_members_only_and_files_only() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'
    local rd="$td/sf-tools/release/feature/test"

    printf '[files]\n\n[members]\nCustomObject:Only__c\n' > "$rd/deploy-target.txt"
    (cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --no-open >/dev/null 2>&1)
    assert_file_contains "$rd/package.xml" "<members>Only__c</members>" "[members] のみ: package.xml が生成される"

    printf '[files]\nforce-app/main/default/classes/TestClass.cls\n' > "$rd/deploy-target.txt"
    (cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --no-open >/dev/null 2>&1)
    assert_file_contains "$rd/package.xml" "<members>TestClass</members>" "[files] のみ: package.xml が生成される"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# マニフェストが空（メンバーが 1 つもない）→ エラーで中断する（NothingToDeploy の成功扱いにしない）
test_empty_manifest_aborts() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'
    # 空のマニフェストを返す sf（生成は成功するが、<types> がない）
    cat > "$mb/sf" << 'EOF'
#!/bin/bash
echo "sf $*" >> "${MOCK_CALL_LOG:-/dev/null}"
case "$1 $2" in
    "--version "*) echo "@salesforce/cli/2.0.0"; exit 0 ;;
    "project generate")
        OUT_DIR=""; OUT_NAME="package.xml"; PREV=""
        for arg in "$@"; do
            [[ "$PREV" == "--output-dir" ]] && OUT_DIR="$arg"
            [[ "$PREV" == "--name" ]] && OUT_NAME="$arg"
            PREV="$arg"
        done
        mkdir -p "$OUT_DIR"
        printf '<?xml version="1.0" encoding="UTF-8"?>\n<Package xmlns="http://soap.sforce.com/2006/04/metadata">\n    <version>64.0</version>\n</Package>\n' > "$OUT_DIR/$OUT_NAME"
        exit 0 ;;
    "org display") echo '{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'; exit 0 ;;
    "data query") echo '{"status":0,"result":{"records":[{"Id":"00D000000000001AAA","Name":"Mock Sandbox","IsSandbox":true,"OrganizationType":"Enterprise Edition","TrialExpirationDate":null}]}}'; exit 0 ;;  # 組織の種類の確認（Sandbox）
esac
exit 0
EOF
    chmod +x "$mb/sf"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --no-open 2>&1)
    local ec=$?

    assert_exit_fail $ec "空のマニフェスト: 非ゼロで終了する"
    assert_output_contains "$out" "メンバーが 1 つも含まれていません" "空のマニフェスト: 理由が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "project deploy" "空のマニフェスト: デプロイまで、進まない"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# 回帰: マニフェストの統合（merge_package_xml）の失敗で、中断する（以前は戻り値を見ていなかった）
#   出力先の package.xml をフォルダにして、統合の書き込みを失敗させる
test_merge_failure_aborts() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'
    local rd="$td/sf-tools/release/feature/test"
    mkdir -p "$rd/package.xml/blocker"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --no-open 2>&1)
    assert_exit_fail $? "統合の失敗 → 非ゼロで終了する"
    assert_output_contains "$out" "マニフェストの統合（merge_package_xml）に失敗しました" "統合の失敗 → 理由が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "project deploy" "統合の失敗 → デプロイまで、進まない"
    assert_file_not_exists "$rd/package.files.xml" "統合の失敗 → 統合前の一時ファイルを残さない"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# 回帰: sf-check.sh のエラーで中断するとき、die は事実だけ（「上記のエラーを修正」と書かない）。sf-check.sh の理由は表示される
test_check_error_message() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'
    printf '[files]\nforce-app/main/default/classes/NoSuchClass.cls\n' > "$td/sf-tools/release/feature/test/deploy-target.txt"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --no-open 2>&1)
    assert_exit_fail $? "sf-check.sh のエラー → 非ゼロで終了する"
    assert_output_contains "$out" "ターゲットファイルの検証（sf-check.sh）でエラーがありました" "sf-check.sh のエラー → 事実だけのメッセージ"
    assert_output_contains "$out" "パスが存在しません" "sf-check.sh のエラー → 理由（どの行が、なぜ）が表示される"
    echo "$out" | grep -q "上記のエラーを修正" \
        && fail "sf-check.sh のエラー → die に復旧の案内を含めない" \
        || pass "sf-check.sh のエラー → die に復旧の案内を含めない"
    assert_file_not_contains "$MOCK_CALL_LOG" "project deploy" "sf-check.sh のエラー → デプロイまで、進まない"
    # 端末では、run を通すと、-v がなければ、sf-check.sh の出力が画面に出ない（テストの標準出力は端末でないため、上では区別できない）。
    #   run を通して呼んでいないことを、コードで確かめる
    grep -q 'run bash "${SCRIPT_DIR}/sf-check.sh"' "$SF_TOOLS_DIR/bin/sf-release.sh" \
        && fail "sf-check.sh を run を通さずに呼ぶ（出力を画面に出す）" \
        || pass "sf-check.sh を run を通さずに呼ぶ（出力を画面に出す）"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# remove-target.txt の「# @ignore-missing」→ --ignore-warnings を付ける（存在しない削除対象を、エラーにしない。後始末用）
test_ignore_missing_directive() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'
    local rd="$td/sf-tools/release/feature/test"

    # 指示なし: --ignore-warnings を付けない（存在しない削除対象は、これまでどおり、エラー）
    printf '[files]\n\n[members]\nApexClass:Gone\n' > "$rd/remove-target.txt"
    (cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --no-open >/dev/null 2>&1)
    assert_file_not_contains "$MOCK_CALL_LOG" "--ignore-warnings" "指示なし: --ignore-warnings を付けない"

    # 指示あり: --ignore-warnings を付ける
    : > "$MOCK_CALL_LOG"
    printf '# @ignore-missing\n[files]\n\n[members]\nApexClass:Gone\n' > "$rd/remove-target.txt"
    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --no-open 2>&1)
    assert_file_contains "$MOCK_CALL_LOG" "--ignore-warnings" "指示あり: --ignore-warnings を付ける"
    assert_output_contains "$out" "@ignore-missing があるため" "指示あり: 理由が表示される"
    assert_file_contains "$rd/destructiveChanges.xml" "<members>Gone</members>" "指示あり: 削除対象は、通常どおり、マニフェストに入る（指示行は、コメント扱い）"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

test_unprotected_org_local_allowed
test_protected_org_staging_blocked
test_reserved_aliases_blocked
test_target_without_value_rejected
test_personal_alias_allowed
test_renamed_production_org_denied
test_sf_cli_abort
test_mixed_files_and_members
test_overlap_deploy_and_remove_aborts
test_members_only_and_files_only
test_empty_manifest_aborts
test_merge_failure_aborts
test_check_error_message
test_ignore_missing_directive

# 組織にない削除の対象を外す（同じブランチで、削除を含む変更を何度も出すと、2 回目からは、消す対象が組織にない）
#   組織にあるものの一覧は、偽の sf の MOCK_SF_LIST_DIR/<種類>.json（なければ空の一覧）。MOCK_SF_LIST_FAIL で一覧を失敗させる
_prune_env() {   # 引数: td 変数名 mb 変数名（setup_std_env の結果）。一覧のフォルダを作り、MOCK_SF_LIST_DIR に入れる
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'
    export MOCK_SF_LIST_DIR="$1/list"
    mkdir -p "$MOCK_SF_LIST_DIR"
}
test_prune_missing_destructive() {
    local td mb mh rd out ec
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    _prune_env "$td"
    rd="$td/sf-tools/release/feature/test"

    # 一部ない: 組織にあるもの（大文字・小文字の違いは、同じとみなす）は残し、ないものだけ外す
    printf '[files]\n\n[members]\nApexClass:Gone\nApexClass:Keep\nApexClass:MixedCase\n' > "$rd/remove-target.txt"
    printf '[{"fullName":"Keep"},{"fullName":"MIXEDCASE"},{"fullName":"Other"}]' > "$MOCK_SF_LIST_DIR/ApexClass.json"
    out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --no-open 2>&1); ec=$?
    assert_exit_ok $ec "一部ない: 成功する"
    assert_file_contains "$MOCK_CALL_LOG" "org list metadata --metadata-type ApexClass" "一部ない: 種類ごとに、組織の一覧を問い合わせる"
    assert_file_contains "$rd/destructiveChanges.xml" "<members>Keep</members>" "一部ない: 組織にあるものは、残す"
    assert_file_contains "$rd/destructiveChanges.xml" "<members>MixedCase</members>" "一部ない: 大文字・小文字だけ違うものは、ある、とみなして残す"
    assert_file_not_contains "$rd/destructiveChanges.xml" "<members>Gone</members>" "一部ない: 組織にないものは、外す"
    assert_output_contains "$out" "組織（testorg）にないため、削除の対象から外しました" "一部ない: 外したことを WARNING で表示する"
    assert_output_contains "$out" "ApexClass:Gone" "一部ない: 外したものの種類と名前を表示する"
    [[ "$(echo "$out" | grep -c "ApexClass:Gone")" -ge 2 ]] \
        && pass "一部ない: 外したものを、デプロイのあとにもう一度表示する" || fail "一部ない: 外したものを、デプロイのあとにもう一度表示する"
    grep "project deploy" "$MOCK_CALL_LOG" | grep -q -- "--pre-destructive-changes" \
        && pass "一部ない: 残った削除は、--pre-destructive-changes で渡す" || fail "一部ない: 残った削除は、--pre-destructive-changes で渡す"

    # 全部ない・反映はある: 削除の指定を付けずに、反映（検証）だけ行う
    : > "$MOCK_CALL_LOG"
    printf '[files]\n\n[members]\nApexClass:Gone\nCustomField:Equipment__c.Old__c\n' > "$rd/remove-target.txt"
    out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --no-open 2>&1); ec=$?
    assert_exit_ok $ec "全部ない: 成功する"
    assert_file_contains "$MOCK_CALL_LOG" "project deploy" "全部ない: 反映（検証）は行う"
    assert_file_not_contains "$MOCK_CALL_LOG" "--pre-destructive-changes" "全部ない: 削除の指定（--pre-destructive-changes）を付けない"
    assert_file_not_exists "$rd/destructiveChanges.xml" "全部ない: destructiveChanges.xml を残さない"
    assert_output_contains "$out" "削除の対象が、すべて組織にないため" "全部ない: 削除しない理由を表示する"

    # 全部ない・反映もない: 何もせずに成功する（develop に削除を出したあと、同じブランチから、もう一度出したとき）
    : > "$MOCK_CALL_LOG"
    printf '[files]\n' > "$rd/deploy-target.txt"
    out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --no-open 2>&1); ec=$?
    assert_exit_ok $ec "削除だけで全部ない: 成功する（終了コード 0）"
    assert_file_not_contains "$MOCK_CALL_LOG" "project deploy" "削除だけで全部ない: デプロイしない"
    assert_output_contains "$out" "反映・削除するものがありません" "削除だけで全部ない: 理由を表示する"
    unset MOCK_SF_ORG_JSON MOCK_SF_LIST_DIR
    teardown "$td" "$mb"
}

# 確かめられないものは外さない（外しすぎると、消すはずのものが黙って残るため）
test_prune_keeps_unverifiable() {
    local td mb mh rd out ec
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    _prune_env "$td"
    rd="$td/sf-tools/release/feature/test"

    # 一覧が取れない種類は、外さない（WARNING）
    printf '[files]\n\n[members]\nApexClass:Gone\n' > "$rd/remove-target.txt"
    out=$(cd "$td" && MOCK_SF_LIST_FAIL=ApexClass PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --no-open 2>&1)
    assert_file_contains "$rd/destructiveChanges.xml" "<members>Gone</members>" "一覧が取れない: 外さない"
    assert_output_contains "$out" "ApexClass: 組織にあるかを確かめられませんでした" "一覧が取れない: WARNING を表示する"
    grep "project deploy" "$MOCK_CALL_LOG" | grep -q -- "--pre-destructive-changes" \
        && pass "一覧が取れない: 削除は、そのまま渡す（Salesforce が判断する）" || fail "一覧が取れない: 削除は、そのまま渡す（Salesforce が判断する）"

    # フォルダの中の種類・* ・書き方が違いうる名前は、確かめずに残す
    : > "$MOCK_CALL_LOG"
    printf '[files]\n\n[members]\nReport:MyFolder/OldReport\nApexClass:*\nLayout:Account-Account %%28Old%%29 Layout\n' > "$rd/remove-target.txt"
    out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --no-open 2>&1)
    assert_file_contains "$rd/destructiveChanges.xml" "<members>MyFolder/OldReport</members>" "フォルダの中の種類（Report）: 外さない"
    assert_file_not_contains "$MOCK_CALL_LOG" "--metadata-type Report" "フォルダの中の種類（Report）: 一覧を問い合わせない"
    assert_file_contains "$rd/destructiveChanges.xml" "<members>*</members>" "ワイルドカード（*）: 外さない"
    assert_file_contains "$rd/destructiveChanges.xml" "Account-Account %28Old%29 Layout" "英数字と _ . - 以外を含む名前: 外さない"
    assert_output_not_contains "$out" "削除の対象から外しました" "確かめられないものだけのとき: 外したものはない"

    # # @ignore-missing があれば、確かめない（従来どおり、--ignore-warnings で Salesforce に任せる）
    : > "$MOCK_CALL_LOG"
    printf '# @ignore-missing\n[files]\n\n[members]\nApexClass:Gone\n' > "$rd/remove-target.txt"
    (cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --no-open >/dev/null 2>&1)
    assert_file_not_contains "$MOCK_CALL_LOG" "org list metadata" "@ignore-missing: 組織の一覧を問い合わせない"
    assert_file_contains "$rd/destructiveChanges.xml" "<members>Gone</members>" "@ignore-missing: 外さない"
    unset MOCK_SF_ORG_JSON MOCK_SF_LIST_DIR
    teardown "$td" "$mb"
}

# GitHub Actions 上では、外したものを、実行の要約（GITHUB_STEP_SUMMARY）にも書く（1 回だけ）
test_prune_step_summary() {
    local td mb mh rd sum
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td"
    _prune_env "$td"
    rd="$td/sf-tools/release/feature/test"
    sum="$td/summary.md"
    printf '[files]\n\n[members]\nApexClass:Gone\n' > "$rd/remove-target.txt"
    (cd "$td" && GITHUB_ACTIONS=true GITHUB_STEP_SUMMARY="$sum" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" -t testorg --no-open >/dev/null 2>&1)
    assert_file_contains "$sum" "削除の対象から外したもの" "要約: 見出しを書く"
    assert_file_contains "$sum" "ApexClass:Gone" "要約: 外したものを書く"
    [[ "$(grep -c "ApexClass:Gone" "$sum" 2>/dev/null)" -eq 1 ]] \
        && pass "要約: 1 回だけ書く（最後の再表示では、書かない）" || fail "要約: 1 回だけ書く（最後の再表示では、書かない）"
    unset MOCK_SF_ORG_JSON MOCK_SF_LIST_DIR
    teardown "$td" "$mb"
}

test_prune_missing_destructive
test_prune_keeps_unverifiable
test_prune_step_summary

print_summary
