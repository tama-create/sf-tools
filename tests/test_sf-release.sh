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
    assert_output_contains "$out" "PR 経由で GitHub Actions" "保護組織(main) + ローカル → 適切なエラーメッセージ"
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
        assert_output_contains "$out" "組織のエイリアスを指定してください" "値のない -t / --target（${args}）→ 理由が表示される"
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

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-release.sh" --no-open 2>&1)
    local ec=$?

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
test_sf_cli_abort
test_mixed_files_and_members
test_members_only_and_files_only
test_empty_manifest_aborts
test_ignore_missing_directive

print_summary
