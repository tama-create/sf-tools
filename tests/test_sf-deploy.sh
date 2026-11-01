#!/bin/bash
# ==============================================================================
# test_sf-deploy.sh - sf-deploy.sh のテスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-deploy.sh ===${CLR_RST}"

# 機能ブランチ → sf-release.sh が --release --force で呼び出される
test_feature_branch() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td" "feature/deploy-test"

    export MOCK_GIT_BRANCH="feature/deploy-test"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$( echo "Y" | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-deploy.sh" --no-open ) 2>&1 )
    local ec=$?

    assert_exit_ok $ec "機能ブランチ → 終了コード 0"
    # sf-release.sh が --release --force で呼ばれたことを確認（deploy コマンドが実行されログに残る）
    assert_file_contains "$MOCK_CALL_LOG" "project deploy" "sf-release.sh が呼び出された（deploy 実行）"
    grep "project deploy" "$MOCK_CALL_LOG" | grep -qv "\-\-dry-run" \
        && pass "--release が渡された（dry-run なし）" || fail "--release が渡された（dry-run なし）"
    grep "project deploy" "$MOCK_CALL_LOG" | grep -q "\-\-ignore-conflicts" \
        && pass "--force が渡された（ignore-conflicts）" || fail "--force が渡された（ignore-conflicts）"
    unset MOCK_GIT_BRANCH MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# main ブランチ → エラー終了
test_main_branch_blocked() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    export MOCK_GIT_BRANCH="main"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-deploy.sh" 2>&1)
    local ec=$?

    assert_exit_fail $ec "main ブランチ → エラー終了"
    ! grep -q "project deploy" "$MOCK_CALL_LOG" 2>/dev/null \
        && pass "main ブランチ → デプロイは実行されない" \
        || fail "main ブランチ → デプロイは実行されない"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb"
}

# staging ブランチ → エラー終了
test_staging_branch_blocked() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    export MOCK_GIT_BRANCH="staging"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-deploy.sh" 2>&1)
    local ec=$?

    assert_exit_fail $ec "staging ブランチ → エラー終了"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb"
}

# develop ブランチ → エラー終了
test_development_branch_blocked() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    export MOCK_GIT_BRANCH="develop"

    local out; out=$(cd "$td" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-deploy.sh" 2>&1)
    local ec=$?

    assert_exit_fail $ec "develop ブランチ → エラー終了"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb"
}

# force-* 以外で実行 → エラー
test_outside_force_dir() {
    local rd mb
    rd=$(setup_regular_dir); mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    create_all_mocks "$mb"

    local out; out=$(cd "$rd" && PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-deploy.sh" 2>&1)
    local ec=$?

    assert_exit_fail $ec "force-* 外 → エラー終了"
    teardown "$rd" "$mb"
}

# 一般ユーザー（非管理者）でも Sandbox へデプロイできる
test_non_admin_can_deploy() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 一般ユーザー → Sandbox デプロイ可${CLR_RST}"

    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td" "feature/deploy-test"

    export MOCK_GIT_BRANCH="feature/deploy-test"
    export MOCK_GH_API_USER="stranger123"  # 一般のユーザー（管理者でなくても、実行できる）

    local out; out=$( echo "Y" | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-deploy.sh" --no-open ) 2>&1 )
    local ec=$?

    assert_exit_ok $ec "一般ユーザーでも正常終了する"
    assert_file_contains "$MOCK_CALL_LOG" "project deploy" "一般ユーザーでもデプロイが実行される"
    unset MOCK_GIT_BRANCH MOCK_GH_API_USER
    teardown "$td" "$mb"
}

# 確認で N → 中断する（強制デプロイを実行しない）
#   以前は ask_yn の戻り値を見ておらず、N と答えても強制デプロイが実行されていた
test_confirm_no_aborts() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td" "feature/deploy-test"

    export MOCK_GIT_BRANCH="feature/deploy-test"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"testorg","id":"00D000000000001AAA"}}'

    local out; out=$( echo "N" | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-deploy.sh" --no-open ) 2>&1 )
    local ec=$?

    assert_exit_fail $ec "確認で N → 中断（終了コード 0 以外）"
    assert_output_contains "$out" "中断しました" "確認で N → 中断の旨が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "project deploy" "確認で N → 強制デプロイは実行されない"
    unset MOCK_GIT_BRANCH MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# 共有環境（予約名 prod / staging / develop / main）は、確認の前に拒否する（-t / --target でも、接続中の組織でも）
test_reserved_alias_blocked() {
    local a td mb mh out ec
    for a in prod staging develop main; do
        setup_std_env td mb mh
        create_all_mocks "$mb"
        setup_release_dir "$td" "feature/deploy-test"
        export MOCK_GIT_BRANCH="feature/deploy-test"
        out=$( echo "Y" | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-deploy.sh" --no-open -t "$a" ) 2>&1 )
        ec=$?
        assert_exit_fail $ec "共有環境(${a}) を -t で指定 → 拒否（終了コード 0 以外）"
        assert_output_contains "$out" "共有環境（予約名）のため、ローカルから強制リリースできません" "共有環境(${a}) → 拒否の旨が表示される"
        # 確認（続行しますか）が出ていないこと（assert_output_not_contains は複数行で常に成功するため、grep で確認する）
        echo "$out" | grep -q "続行しますか" \
            && fail "共有環境(${a}) → 確認の前に拒否する（確認を出さない）" "確認が表示された" \
            || pass "共有環境(${a}) → 確認の前に拒否する（確認を出さない）"
        assert_file_not_contains "$MOCK_CALL_LOG" "project deploy" "共有環境(${a}) → 強制デプロイは実行されない"
        unset MOCK_GIT_BRANCH
        teardown "$td" "$mb"
    done

    # --target 指定なし: 接続中の組織（sf org display）のエイリアスが prod → 拒否
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td" "feature/deploy-test"
    export MOCK_GIT_BRANCH="feature/deploy-test"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"prod","id":"00D000000000001AAA"}}'
    out=$( echo "Y" | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-deploy.sh" --no-open ) 2>&1 )
    ec=$?
    assert_exit_fail $ec "接続中の組織が prod → 拒否"
    assert_file_not_contains "$MOCK_CALL_LOG" "project deploy" "接続中の組織が prod → 強制デプロイは実行されない"
    unset MOCK_GIT_BRANCH MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# 回帰: ブランチを取得できない（detached HEAD など）→ 確認の前に中断する
#   （以前は失敗を見ず、git のエラーの文言をブランチ名として扱い、保護ブランチの確認を素通りして、強制リリースまで進んでいた）
test_branch_unavailable_blocked() {
    local td mb mh out ec
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td" "feature/deploy-test"
    # symbolic-ref だけ失敗する git（detached HEAD の再現）。それ以外は、標準のモックに任せる
    mv "$mb/git" "$mb/git-base"
    cat > "$mb/git" << EOF
#!/bin/bash
if [[ "\$1" == "symbolic-ref" ]]; then
    echo "git \$*" >> "\${MOCK_CALL_LOG:-/dev/null}"
    echo "fatal: ref HEAD is not a symbolic ref" >&2
    exit 128
fi
exec "$mb/git-base" "\$@"
EOF
    chmod +x "$mb/git"
    export MOCK_SF_ORG_JSON='{"result":{"alias":"dev00","id":"00D000000000001AAA"}}'
    out=$( echo "Y" | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-deploy.sh" --no-open -t dev00 ) 2>&1 )
    ec=$?
    assert_exit_fail $ec "ブランチを取得できない → 中断（終了コード 0 以外）"
    assert_output_contains "$out" "現在のブランチを取得できません" "ブランチを取得できない → 理由が表示される"
    echo "$out" | grep -q "続行しますか" \
        && fail "ブランチを取得できない → 確認の前に中断する" "確認が表示された" \
        || pass "ブランチを取得できない → 確認の前に中断する"
    assert_file_not_contains "$MOCK_CALL_LOG" "project deploy" "ブランチを取得できない → 強制デプロイは実行されない"
    unset MOCK_SF_ORG_JSON
    teardown "$td" "$mb"
}

# 保護ブランチの上 → ブランチ名を 1 回だけ表示する（以前は「main ブランチでは実行できません。現在のブランチ: main」と 2 回）
test_protected_branch_message() {
    local td mb mh out
    setup_std_env td mb mh
    create_all_mocks "$mb"
    export MOCK_GIT_BRANCH="staging"
    out=$( echo "Y" | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-deploy.sh" ) 2>&1 )
    assert_exit_fail $? "保護ブランチ(staging) → 中断"
    assert_output_contains "$out" "staging は保護ブランチ（sf-tools/config/branches.txt）のため、実行できません。" "保護ブランチ → 事実だけのメッセージ"
    echo "$out" | grep -q "現在のブランチ: staging" \
        && fail "保護ブランチ → ブランチ名を重ねて表示しない" \
        || pass "保護ブランチ → ブランチ名を重ねて表示しない"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb"
}

# -t / --target の指定の形式が不正 → 確認の前に拒否する
#   --target=ALIAS 形式（sf-release.sh は未対応。接続中の組織を検査して素通りしないようにする）、値なし、次のオプションを値にする指定
test_target_invalid_forms_rejected() {
    local td mb mh out ec args
    # 不明なオプション・2 番目以降の -h も、確認の前に拒否する（以前は、確認のあとで sf-release.sh が拒否していた）
    for args in "--target=prod" "--target=dev00" "-t" "--target --no-open" "-t --no-open" "--bogus" "-n -h" "-t dev00 --bogus"; do
        setup_std_env td mb mh
        create_all_mocks "$mb"
        setup_release_dir "$td" "feature/deploy-test"
        export MOCK_GIT_BRANCH="feature/deploy-test"
        export MOCK_SF_ORG_JSON='{"result":{"alias":"dev00","id":"00D000000000001AAA"}}'
        # shellcheck disable=SC2086
        out=$( echo "Y" | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-deploy.sh" $args ) 2>&1 )
        ec=$?
        assert_exit_fail $ec "不正な指定（${args}）→ 拒否（終了コード 0 以外）"
        echo "$out" | grep -q "続行しますか" \
            && fail "不正な指定（${args}）→ 確認の前に拒否する（確認を出さない）" "確認が表示された" \
            || pass "不正な指定（${args}）→ 確認の前に拒否する（確認を出さない）"
        assert_file_not_contains "$MOCK_CALL_LOG" "project deploy" "不正な指定（${args}）→ 強制デプロイは実行されない"
        unset MOCK_GIT_BRANCH MOCK_SF_ORG_JSON
        teardown "$td" "$mb"
    done
}

# 名前を付け替えた本番組織（予約名ではない）も、確認の前に拒否する。種類を確認できない組織も拒否する
test_renamed_production_org_denied() {
    local td mb mh out ec
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td" "feature/deploy-test"
    export MOCK_GIT_BRANCH="feature/deploy-test"
    out=$( echo "Y" | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" MOCK_SF_ORG_INFO='{"status":0,"result":{"records":[{"attributes":{"type":"Organization"},"Id":"00D000000000009AAA","Name":"Real Prod","IsSandbox":false,"OrganizationType":"Enterprise Edition","TrialExpirationDate":null}]}}' bash "$SF_TOOLS_DIR/bin/sf-deploy.sh" --no-open -t myprod ) 2>&1 )
    ec=$?
    assert_exit_fail $ec "名前を付け替えた本番組織(myprod) を -t で指定 → 拒否"
    assert_output_contains "$out" "本番組織のため、ローカルから強制リリースできません" "本番組織 → 拒否の旨が表示される"
    echo "$out" | grep -q "続行しますか" && fail "本番組織 → 確認の前に拒否する（確認を出さない）" "確認が表示された" || pass "本番組織 → 確認の前に拒否する（確認を出さない）"
    assert_file_not_contains "$MOCK_CALL_LOG" "project deploy" "本番組織 → 強制デプロイは実行されない"
    out=$( echo "Y" | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" MOCK_SF_ORG_QUERY_EXIT=1 bash "$SF_TOOLS_DIR/bin/sf-deploy.sh" --no-open -t mystg ) 2>&1 )
    ec=$?
    assert_exit_fail $ec "組織の種類を確認できない → 拒否"
    assert_output_contains "$out" "組織の種類を確認できないため、ローカルから強制リリースできません" "確認できない → 拒否の旨が表示される"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb"
}

# 個人用の組織（予約名以外）を -t で指定 → 実行できる
test_personal_alias_allowed() {
    local td mb mh out ec
    setup_std_env td mb mh
    create_all_mocks "$mb"
    setup_release_dir "$td" "feature/deploy-test"
    export MOCK_GIT_BRANCH="feature/deploy-test"
    out=$( echo "Y" | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$SF_TOOLS_DIR/bin/sf-deploy.sh" --no-open -t dev00 ) 2>&1 )
    ec=$?
    assert_exit_ok $ec "個人用の組織(dev00) を -t で指定 → 実行できる"
    assert_file_contains "$MOCK_CALL_LOG" "project deploy" "個人用の組織(dev00) → 強制デプロイが実行される"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb"
}

test_feature_branch
test_reserved_alias_blocked
test_target_invalid_forms_rejected
test_branch_unavailable_blocked
test_protected_branch_message
test_personal_alias_allowed
test_renamed_production_org_denied
test_confirm_no_aborts
test_main_branch_blocked
test_staging_branch_blocked
test_development_branch_blocked
test_outside_force_dir
test_non_admin_can_deploy

print_summary
