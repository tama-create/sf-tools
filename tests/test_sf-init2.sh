#!/bin/bash
# ==============================================================================
# test_sf-init2.sh - sf-init.sh の単体テスト（モックベース。2/3）
# ==============================================================================
# sf-init.sh のテストは、時間がかかる（Windows の CI で約 10 分）ため、3 つのファイル（test_sf-init.sh・test_sf-init2.sh・
# test_sf-init3.sh）に分け、並列に動かす。共通の部品は tests/init-test-lib.sh。関数の分け方は、実測の所要時間で、均等になるようにした。
# どのテストが、どのファイルにあるかは、下の一覧（関数名）を参照。全部で 49 の関数（件数は、3 つの合計）。
#
# 【このファイルのテスト関数】
#   test_repo_create_failure
#   test_sf_login_failure
#   test_invalid_owner_folder
#   test_admin_branch_push_failure_is_not_fatal
#   test_initial_sync_failure_is_not_fatal
#   test_refuse_foreign_clone
#   test_restart_clears_mark
#   test_initial_sync_timeout_cancels
#   test_restart_interrupted_notice
#   test_only_option_runs_single_phase
#   test_add_tier_staging_happy
#   test_unknown_option_fails
#   test_e2e_input_sequence_layouts
#   test_sf_cli_check
#   test_completed_by_clone
#   test_sf_tools_autoupdate
#   test_org_connection
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/init-test-lib.sh"

# ==============================================================================
# テスト 3: リポジトリ作成に失敗する場合
# ==============================================================================
test_repo_create_failure() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] リポジトリ作成失敗（gh repo create が exit 1）${CLR_RST}"

    local mb mock_home init_base init_dir
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"

    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    _stub_subscripts "$mock_home"

    export MOCK_GH_REPO_CREATE_EXIT=1

    local exit_code
    # 警告確認 + confirm + ENV_TYPE選択 のみ入力（リポジトリ作成で失敗するため以降は不要）
    printf 'Y\nY\n1\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" ) > /dev/null 2>&1
    exit_code=$?

    assert_exit_fail "$exit_code"                                              "リポジトリ作成失敗で非ゼロ終了する"
    assert_file_contains "$MOCK_CALL_LOG" "gh repo create"                    "gh repo create が試みられる"

    unset MOCK_GH_REPO_CREATE_EXIT
    teardown "$mb" "$mock_home" "$init_base"
}

# ==============================================================================
# テスト 4: Salesforce ログインに失敗する場合
# ==============================================================================
test_sf_login_failure() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] Salesforce ログイン失敗（sf org login が exit 1）${CLR_RST}"

    local mb mock_home init_base init_dir
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"

    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    _stub_subscripts "$mock_home"

    # JWT 接続テスト失敗をシミュレート
    export MOCK_SF_LOGIN_EXIT=1

    # 警告確認 → Phase2 confirm → ENV_TYPE選択 → Phase5 ブランチ選択 → PAT → Slack → Phase10 アプリ種別選択(1=接続アプリ) → Connected App press_enter → prod Sandbox? → consumer_key/username まで入力
    # （sf org login jwt で失敗するため以降は不要）
    local exit_code
    printf 'Y\nY\n1\n1\nghp_faketoken\n\nxoxb-faketoken\nC01ABCDEFGH\n\n\n1\nfake_prod_key\nprod@example.com\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --legacy-connected-app ) > /dev/null 2>&1
    exit_code=$?

    assert_exit_fail "$exit_code"                                              "SF ログイン失敗で非ゼロ終了する"
    assert_file_contains "$MOCK_CALL_LOG" "sf org login"                      "sf org login jwt が試みられる"
    assert_file_contains "$init_dir/admin/.sf-init-testproject.progress" "SF_INIT_DONE_PHASE=9"  "Phase 10 が失敗 → 進捗は、成功した Phase 9 までが記録される"

    unset MOCK_SF_LOGIN_EXIT
    teardown "$mb" "$mock_home" "$init_base"
}

# ==============================================================================
# テスト 6: 無効なフォルダ構成（GitHub オーナー名バリデーション失敗）
# ==============================================================================
test_invalid_owner_folder() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 無効なフォルダ構成 → GitHub オーナー名エラー${CLR_RST}"

    local mb mock_home init_base init_dir
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)

    # GitHub ユーザー名に使用できない文字（スペース）を含むフォルダ名
    init_base=$(mktemp -d "${TMPDIR:-/tmp}/test-init-XXXX")
    mkdir -p "$init_base/invalid owner/testproject"
    init_dir="$init_base/invalid owner/testproject"

    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"

    local exit_code
    printf 'x\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" ) > /dev/null 2>&1
    exit_code=$?

    assert_exit_fail "$exit_code" "無効なオーナー名で失敗終了する"

    teardown "$mb" "$mock_home" "$init_base"
}

# ==============================================================================
# テスト 6e: admin ブランチを GitHub に push できなくても、セットアップは成功のまま（完了画面で知らせる）
# ==============================================================================
test_admin_branch_push_failure_is_not_fatal() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] admin ブランチの push に失敗 → セットアップは成功・完了画面で知らせる${CLR_RST}"

    local mb mock_home base work exit_code
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    base=$(mktemp -d "${TMPDIR:-/tmp}/test-init-XXXX")
    work="$base/my-work"; mkdir -p "$work"

    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    _stub_subscripts "$mock_home"

    export MOCK_GIT_C_PUSH_EXIT=1
    _make_input_3branches \
        | ( cd "$work" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --owner tamashimon --project testproject --legacy-connected-app ) \
          > /tmp/sf-init-test-pushfail.log 2>&1
    exit_code=$?
    unset MOCK_GIT_C_PUSH_EXIT

    assert_exit_ok   "$exit_code"                                                        "admin の push に失敗しても、セットアップは成功する"
    assert_file_contains "/tmp/sf-init-test-pushfail.log" "admin ブランチを GitHub に push できませんでした"  "警告を表示する"
    assert_file_contains "/tmp/sf-init-test-pushfail.log" "git push -u origin admin"     "完了画面で、手動で push する方法を知らせる"

    teardown "$mb" "$mock_home" "$base"
    rm -f /tmp/sf-init-test-pushfail.log
}

# ==============================================================================
# テスト 6f: 最初のメタデータの同期に失敗しても、セットアップは成功のまま（完了画面で知らせる。クローンには取り込まない）
# ==============================================================================
test_initial_sync_failure_is_not_fatal() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 最初のメタデータの同期に失敗（起動できない / 同期の失敗）→ セットアップは成功・完了画面で知らせる${CLR_RST}"

    local mb mock_home base work exit_code k
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    _stub_subscripts "$mock_home"

    for k in "MOCK_GH_WORKFLOW_RUN_EXIT=1" "MOCK_GH_SYNC_CONCLUSION=failure"; do
        base=$(mktemp -d "${TMPDIR:-/tmp}/test-init-XXXX")
        work="$base/my-work"; mkdir -p "$work"
        rm -rf "$mb/deployed_src" "$mb/jwt.cnt" "$mock_home/.sf-jwt" "$mb/.repo_view_called" "$mb/.wfd_count"
        : > "$MOCK_CALL_LOG"
        _make_input_3branches \
            | ( export "$k"; cd "$work" && HOME="$mock_home" PATH="$mb:$PATH" \
                  bash "$mock_home/sf-tools/bin/sf-init.sh" --owner tamashimon --project testproject --legacy-connected-app ) \
              > /tmp/sf-init-test-syncfail.log 2>&1
        exit_code=$?
        assert_exit_ok   "$exit_code"                                                         "同期に失敗しても（${k}）、セットアップは成功する"
        assert_file_contains "/tmp/sf-init-test-syncfail.log" "同期は、できませんでした"           "（${k}）完了画面で、同期できなかったことを知らせる"
        assert_file_contains "/tmp/sf-init-test-syncfail.log" "gh workflow run wf-metasync.yml -R tamashimon/force-testproject"  "（${k}）すぐ同期する方法を案内する"
        assert_file_not_contains "$MOCK_CALL_LOG" "pull --ff-only origin main"                "（${k}）同期できていないため、クローンに取り込まない"
        assert_file_not_contains "/tmp/sf-init-test-syncfail.log" "同期済みです"               "（${k}）「同期済み」とは、表示しない"
        rm -rf "$base"
    done
    assert_file_contains "/tmp/sf-init-test-syncfail.log" "同期が、失敗しました"                "同期の失敗: 失敗の理由（ログの URL つき）を表示する"

    teardown "$mb" "$mock_home"
    rm -f /tmp/sf-init-test-syncfail.log
}

# ==============================================================================
# テスト 6h: 別のリポジトリ（別のオーナー・同じ XXXX）のクローンがあるときは、中断する
# ==============================================================================
test_refuse_foreign_clone() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] admin/force-XXXX が別のリポジトリのクローン → 中断（書き込み・push・状態ファイルの削除をしない）${CLR_RST}"
    local mb mock_home base work exit_code out
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    create_all_mocks "$mb"; create_mock_gh_for_init "$mb"; _stub_subscripts "$mock_home"
    base=$(mktemp -d "${TMPDIR:-/tmp}/test-init-XXXX"); work="$base/my-work"
    mkdir -p "$work/admin/force-testproject/.git"
    printf 'REPO_FULL_NAME="other/force-testproject"\n' > "$work/admin/.sf-init-testproject.env"   # ほかのリポジトリの、途中の状態
    printf 'SF_INIT_DONE_PHASE=5\n' > "$work/admin/.sf-init-testproject.progress"
    export MOCK_GIT_C_REMOTE_URL="https://user:SECRETTOKEN@github.com/other/force-testproject.git"   # Token つきの URL
    : > "$MOCK_CALL_LOG"
    out=$(printf 'Y\n' | ( cd "$work" && HOME="$mock_home" PATH="$mb:$PATH" \
        bash "$mock_home/sf-tools/bin/sf-init.sh" --owner tamashimon --project testproject ) 2>&1)
    exit_code=$?
    unset MOCK_GIT_C_REMOTE_URL
    assert_exit_fail "$exit_code"                                                        "別のリポジトリのクローン → 異常終了する"
    assert_output_not_contains "$out" "SECRETTOKEN"                                      "別のリポジトリのクローン → origin の URL の Token を、画面に出さない"
    assert_output_contains "$out" "tamashimon/force-testproject のクローンではありません"   "別のリポジトリのクローン → 理由（どのリポジトリか）を表示する"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo create"                           "別のリポジトリのクローン → リポジトリを作らない"
    assert_file_not_contains "$MOCK_CALL_LOG" "push"                                     "別のリポジトリのクローン → push しない"
    assert_file_exists "$work/admin/.sf-init-testproject.env"                            "別のリポジトリのクローン → ほかのリポジトリの状態ファイルを、消さない"
    assert_file_exists "$work/admin/.sf-init-testproject.progress"                       "別のリポジトリのクローン → 進捗ファイルも、消さない"
    teardown "$mb" "$mock_home" "$base"
}

# ==============================================================================
# テスト 6k: 「最初から、やり直す」を選ぶと、完了の印を外す（やり直しの途中で止まっても、完了済みと誤判定しない）
# ==============================================================================
test_restart_clears_mark() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 完了済みで [3] 最初から → 完了の印を 0（やり直し中）にする（その後 Phase 1・2 で止まっても、完了済みにならない）${CLR_RST}"
    local mb mock_home base work exit_code out
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    create_all_mocks "$mb"; create_mock_gh_for_init "$mb"; _stub_subscripts "$mock_home"
    base=$(mktemp -d "${TMPDIR:-/tmp}/test-init-XXXX"); work="$base/my-work"
    mkdir -p "$work/admin/force-testproject/.git"
    export MOCK_GIT_C_REMOTE_URL="https://github.com/tamashimon/force-testproject.git"
    export MOCK_GIT_C_CONFIG_VALUE=1     # 完了の印がある
    export MOCK_GH_AUTH_STATUS_EXIT=1    # Phase 1（環境チェック）で、失敗して止まる
    : > "$MOCK_CALL_LOG"
    out=$(printf 'Y\n3\n' | ( cd "$work" && HOME="$mock_home" PATH="$mb:$PATH" \
        bash "$mock_home/sf-tools/bin/sf-init.sh" ) 2>&1)
    exit_code=$?
    unset MOCK_GIT_C_REMOTE_URL MOCK_GIT_C_CONFIG_VALUE MOCK_GH_AUTH_STATUS_EXIT
    assert_exit_fail "$exit_code"                                                        "[3]・Phase 1 の失敗で止まる → 異常終了する"
    assert_output_contains "$out" "セットアップが、すでに完了しています"                      "[3]: 完了済みの案内が、最初に出る"
    assert_file_contains "$MOCK_CALL_LOG" "config sf-tools.setup-complete 0"             "[3] 最初から: 完了の印を 0（やり直し中）にする（消さない）"
    teardown "$mb" "$mock_home" "$base"
}

# ==============================================================================
# テスト 6m: 同期が時間切れ → 実行を取り消す（あとの wf-metasync と、同時に動かさない）
# ==============================================================================
test_initial_sync_timeout_cancels() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 同期が、上限の時間内に終わらない → 取り消して、セットアップは成功のまま${CLR_RST}"
    local mb mock_home base work exit_code
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    create_all_mocks "$mb"; create_mock_gh_for_init "$mb"; _stub_subscripts "$mock_home"
    base=$(mktemp -d "${TMPDIR:-/tmp}/test-init-XXXX"); work="$base/my-work"; mkdir -p "$work"
    export MOCK_GH_SYNC_STATUS=in_progress SF_INIT_SYNC_TIMEOUT=2
    _make_input_3branches \
        | ( cd "$work" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --owner tamashimon --project testproject --legacy-connected-app ) \
          > /tmp/sf-init-test-synctimeout.log 2>&1
    exit_code=$?
    unset MOCK_GH_SYNC_STATUS SF_INIT_SYNC_TIMEOUT
    assert_exit_ok "$exit_code"                                                          "同期が時間切れでも、セットアップは成功する"
    assert_file_contains "$MOCK_CALL_LOG" "gh run cancel 101"                            "時間切れ → 同期の実行を取り消す"
    assert_file_contains "/tmp/sf-init-test-synctimeout.log" "取り消しました"             "時間切れ → 取り消した旨を表示する"
    assert_file_contains "/tmp/sf-init-test-synctimeout.log" "同期は、できませんでした"    "時間切れ → 完了画面で、同期できなかったことを知らせる"
    assert_file_not_contains "$MOCK_CALL_LOG" "pull --ff-only origin main"               "時間切れ → クローンに取り込まない"
    teardown "$mb" "$mock_home" "$base"
    rm -f /tmp/sf-init-test-synctimeout.log
}

# ==============================================================================
# テスト 6p: 前回の「最初から、やり直す」が途中で止まっている（印が 0）→ その旨を表示して、最初から、やり直す
# ==============================================================================
test_restart_interrupted_notice() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 印が 0（やり直し中に中断）→ 「途中で止まっています。最初から、やり直します」と表示する${CLR_RST}"
    local mb mock_home base work exit_code out
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    create_all_mocks "$mb"; create_mock_gh_for_init "$mb"; _stub_subscripts "$mock_home"
    base=$(mktemp -d "${TMPDIR:-/tmp}/test-init-XXXX"); work="$base/my-work"
    mkdir -p "$work/admin/force-testproject/.git"                        # 状態ファイルは、ない
    export MOCK_GIT_C_REMOTE_URL="https://github.com/tamashimon/force-testproject.git"
    export MOCK_GIT_C_CONFIG_VALUE=0                                      # やり直し中の印
    export MOCK_GH_AUTH_STATUS_EXIT=1                                     # Phase 1 で、止まる（最初から、始まったことの確認）
    : > "$MOCK_CALL_LOG"
    out=$(printf 'Y\n' | ( cd "$work" && HOME="$mock_home" PATH="$mb:$PATH" \
        bash "$mock_home/sf-tools/bin/sf-init.sh" ) 2>&1)
    exit_code=$?
    unset MOCK_GIT_C_REMOTE_URL MOCK_GIT_C_CONFIG_VALUE MOCK_GH_AUTH_STATUS_EXIT
    assert_output_contains "$out" "前回の「最初から、やり直す」が、途中で止まっています"      "印が 0 → 途中で止まっていた旨を表示する"
    assert_output_not_contains "$out" "セットアップが、すでに完了しています"                   "印が 0 → 完了済みの案内は、出さない（未完了）"
    teardown "$mb" "$mock_home" "$base"
}

# ==============================================================================
# テスト 8: --only 1 → Phase 1 のみ実行（gh repo create は呼ばれない）
# ==============================================================================
test_only_option_runs_single_phase() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] --only 1 → Phase 1 のみ実行${CLR_RST}"

    local mb mock_home init_base init_dir
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"

    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"

    local exit_code
    printf 'Y\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --only 1 ) > /dev/null 2>&1
    exit_code=$?

    assert_exit_ok            "$exit_code"                    "--only 1 で正常終了する"
    assert_file_contains      "$MOCK_CALL_LOG" "gh auth status" "Phase 1: gh auth status が呼ばれる"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh repo create" "--only 1: gh repo create は呼ばれない"

    teardown "$mb" "$mock_home" "$init_base"
}

# ==============================================================================
# テスト 11: --add-tier staging → 正常終了・Secrets/Variables が登録される
# ==============================================================================
test_add_tier_staging_happy() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] --add-tier staging → 正常終了${CLR_RST}"

    local mb mock_home force_dir
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)

    # force-* ディレクトリを模擬（check_force_dir が force- プレフィックスを要求するため）
    local base_dir
    base_dir=$(mktemp -d "${TMPDIR:-/tmp}/test-add-tier-XXXX")
    force_dir="$base_dir/force-testproject"
    mkdir -p "$force_dir/sf-tools/config"
    printf 'main\n' > "$force_dir/sf-tools/config/branches.txt"
    # ~/.sf-jwt/<repo_name>/server.key を模擬
    mkdir -p "$mock_home/.sf-jwt/force-testproject"
    {
        echo "-----BEGIN RSA PRIVATE KEY-----"
        echo "FAKE"
        echo "-----END RSA PRIVATE KEY-----"
    } > "$mock_home/.sf-jwt/force-testproject/server.key"
    printf -- "-----BEGIN CERTIFICATE-----\nFAKE\n-----END CERTIFICATE-----\n" > "$mock_home/.sf-jwt/force-testproject/server.crt"
    export MOCK_SF_ORG_JSON='{"result":{"username":"stg@example.com","alias":"x"}}'
    export SF_INIT_JWT_INTERVAL=0

    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"

    # git remote を返す git モックを追加
    cat > "$mb/git" << 'GITEOF'
#!/bin/bash
echo "git $*" >> "${MOCK_CALL_LOG:-/dev/null}"
case "$1 $2" in
    "remote get-url") echo "https://github.com/tamashimon/force-testproject.git" ;;
    "symbolic-ref --short") echo "admin" ;;  # 管理者用のクローンは、admin ブランチにいる（実行後に、ここへ戻る）
    "ls-remote --exit-code") exit 1 ;;  # ブランチ未存在
    *) exit 0 ;;
esac
GITEOF
    chmod +x "$mb/git"

    local exit_code
    # 入力: Y（管理者向けの確認。この改行が、次のログイン先の質問に、Enter = Sandbox として読まれる）。
    # 既定は外部クライアントアプリ（自動で作成する）ため、鍵・ユーザー名の入力はない
    printf 'Y\n' \
        | ( cd "$force_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --add-tier staging ) \
          > /tmp/sf-init-add-tier.log 2>&1
    exit_code=$?

    assert_exit_ok   "$exit_code"                                                   "正常終了する"
    assert_file_contains "$MOCK_CALL_LOG" "sf org login web --instance-url https://test.salesforce.com --alias sf-tools-STG" "Enter → Sandbox（test.salesforce.com）でログインする"
    assert_file_contains "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_STG"       "SF_CONSUMER_KEY_STG が登録される"
    assert_file_contains "$MOCK_CALL_LOG" "gh variable set SF_USERNAME_STG"         "SF_USERNAME_STG が登録される"
    assert_file_contains "$MOCK_CALL_LOG" "gh variable set SF_INSTANCE_URL_STG"     "SF_INSTANCE_URL_STG が登録される"
    assert_file_contains "$MOCK_CALL_LOG" "gh variable set SF_ORG_KIND_STG --body sandbox" "組織の種類（Sandbox）が保存される"
    assert_file_contains "$force_dir/sf-tools/config/branches.txt" "staging"        "branches.txt に staging が追記される"
    # main への直接 push は、しない（PR を作成する）
    grep -Eq 'git push .*origin main' "$MOCK_CALL_LOG"         && fail "main への直接 push をしない" "main への push が呼ばれた"         || pass "main への直接 push をしない"
    # 回帰: 新しいブランチは、リモートの最新の main（origin/main）から作る（以前は、手元の main から作り、古いと古い内容から派生した）
    assert_file_contains "$MOCK_CALL_LOG" "git fetch origin main"                   "origin/main を取得する"
    assert_file_contains "$MOCK_CALL_LOG" "git checkout -b staging origin/main"     "staging ブランチは、origin/main から作る"
    grep -Eq 'git checkout -b system-add-tier-staging-[0-9]+ origin/main' "$MOCK_CALL_LOG"         && pass "作業用のブランチは、origin/main から作る"         || fail "作業用のブランチは、origin/main から作る" "$(grep 'git checkout' "$MOCK_CALL_LOG" | head -5)"
    assert_file_contains "$MOCK_CALL_LOG" "gh pr create --base main"                "PR を作成する"
    assert_file_contains "$MOCK_CALL_LOG" "git checkout admin"                      "終わったら、実行前のブランチ（管理者用の admin）に戻る（main に居座らない）"
    assert_file_contains "$MOCK_CALL_LOG" "origin system-add-tier-staging-"         "作業用のブランチを push する"

    unset MOCK_SF_ORG_JSON SF_INIT_JWT_INTERVAL
    teardown "$mb" "$mock_home"
    rm -rf "$base_dir" /tmp/sf-init-add-tier.log
}

# ==============================================================================
# テスト 14: 不明なオプション → エラー終了
# ==============================================================================
test_unknown_option_fails() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 不明なオプション → エラー終了${CLR_RST}"

    local mb mock_home init_base init_dir
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"

    create_all_mocks "$mb"

    local exit_code
    ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
          bash "$mock_home/sf-tools/bin/sf-init.sh" --unknown ) > /dev/null 2>&1
    exit_code=$?

    assert_exit_fail "$exit_code" "不明なオプションで失敗終了する"

    teardown "$mb" "$mock_home" "$init_base"
}

# ==============================================================================
# テスト: e2e の入力の台本（2 層・3 層）で、sf-init が最後まで進む
#   e2e_make_input の層数ごとの台本（Phase 5 の番号・ログイン先の答えの数）が、質問の順番と合っているかを、モックで確認する
# ==============================================================================
test_e2e_input_sequence_layouts() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] e2e の入力の台本（2 層・3 層）で、sf-init が最後まで進む${CLR_RST}"

    local layout mb mock_home init_base init_dir exit_code input
    for layout in 2 3; do
        mb=$(setup_mock_bin)
        export MOCK_CALL_LOG="$mb/calls.log"
        mock_home=$(setup_mock_home)
        init_base=$(_setup_init_dir "tamashimon" "e2e-20260101-000000")
        init_dir="$init_base/home/tamashimon/e2e-20260101-000000"
        create_all_mocks "$mb"
        create_mock_gh_for_init "$mb"
        _stub_subscripts "$mock_home"
        export MOCK_SF_ORG_JSON='{"result":{"username":"admin@example.com","alias":"x"}}'
        export SF_INIT_JWT_INTERVAL=0

        input=$(E2E_PAT_TOKEN=ghp_fakepat E2E_SLACK_BOT_TOKEN=xoxb-fakeslack E2E_SLACK_CHANNEL_ID=C01ABCDEFGH \
                bash -c "source '$SF_TOOLS_DIR/tests/e2e/lib.sh'; e2e_make_input $layout")
        printf '%s\n' "$input" \
            | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
                  bash "$mock_home/sf-tools/bin/sf-init.sh" ) > "$mb/out.log" 2>&1
        exit_code=$?

        assert_exit_ok            "$exit_code"                                                   "${layout} 層の台本で、最後まで正常終了する"
        assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"            "${layout} 層: main の接続情報が登録される"
        assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_STG"             "${layout} 層: staging の接続情報が登録される"
        if [[ "$layout" -eq 3 ]]; then
            assert_file_contains  "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_DEV"             "3 層: develop の接続情報が登録される"
        else
            assert_file_not_contains "$MOCK_CALL_LOG" "SF_CONSUMER_KEY_DEV"                        "2 層: develop の接続情報は、登録しない"
        fi
        assert_file_not_contains  "$mb/out.log" "ghp_fakepat"                                     "${layout} 層: PAT_TOKEN の値が出力に出ない"

        unset MOCK_SF_ORG_JSON SF_INIT_JWT_INTERVAL MOCK_CALL_LOG
        teardown "$mb" "$mock_home" "$init_base"
    done
}

# ==============================================================================
# テスト 21: sf の終了コードの確認（check_sf_cli）
#   sf --version が終了コード 1 を返す環境（Windows の Git Bash で、公式インストーラー版を自動更新した場合）では、
#   案内を表示して、リポジトリの作成などに進まずに中断する。--resume / --only のときも確認する
# ==============================================================================
test_sf_cli_check() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] sf の終了コードが 0 以外なら、sf-init は案内して中断する${CLR_RST}"

    local mb mock_home init_base init_dir exit_code
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"
    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    _stub_subscripts "$mock_home"

    _run_init() {  # 引数: sf-init.sh のオプション。標準入力は、確認に進まないため、Y だけ
        : > "$MOCK_CALL_LOG"
        printf 'Y\n' | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" MOCK_SF_VERSION_EXIT=1 \
              bash "$mock_home/sf-tools/bin/sf-init.sh" "$@" ) > "$mb/out.log" 2>&1
        exit_code=$?
    }

    _run_init
    assert_exit_fail         "$exit_code"                                                 "終了コード 1 → 中断する"
    assert_file_contains     "$mb/out.log" "終了コードが 0 ではありません"                  "終了コード 1 → 案内が表示される"
    assert_file_contains     "$mb/out.log" "npm install -g @salesforce/cli"                "終了コード 1 → npm 版のインストール方法が案内される"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo create"                             "終了コード 1 → リポジトリを作成しない"
    assert_file_not_contains "$mb/out.log" "続行しますか"                                    "終了コード 1 → 管理者向けの確認まで進まない"

    _run_init --resume 10
    assert_exit_fail         "$exit_code"                                                 "終了コード 1 + --resume 10 → 中断する"
    assert_file_contains     "$mb/out.log" "終了コードが 0 ではありません"                  "終了コード 1 + --resume 10 → 案内が表示される"

    _run_init --only 10
    assert_exit_fail         "$exit_code"                                                 "終了コード 1 + --only 10 → 中断する"

    unset -f _run_init
    unset MOCK_CALL_LOG
    teardown "$mb" "$mock_home" "$init_base"
}

# ==============================================================================
# テスト 25b: 完了済みのプロジェクトの判定は、状態ファイルではなく、クローンで行う（完了時に、状態ファイルは消えるため）
# ==============================================================================
test_completed_by_clone() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 状態ファイルがなくても、admin のクローンが同じリポジトリなら、完了済みとして扱う${CLR_RST}"

    local mb mock_home init_base init_dir exit_code out
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    _stub_subscripts "$mock_home"
    out="$mb/out.log"

    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"
    mkdir -p "$init_dir/admin/force-testproject"     # 状態ファイル（.sf-init-*）は、ない。クローンだけがある
    export MOCK_GIT_C_REMOTE_URL="https://github.com/tamashimon/force-testproject.git"
    export MOCK_GIT_C_CONFIG_VALUE=1                 # 完了の印（クローンの git config sf-tools.setup-complete=1）がある

    # 引数なし → 完了済みの案内（[q] 終了: 何も実行しない）
    : > "$MOCK_CALL_LOG"
    printf 'Y\nq\n' | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
        bash "$mock_home/sf-tools/bin/sf-init.sh" ) > "$out" 2>&1
    exit_code=$?
    assert_exit_ok            "$exit_code"                                                  "クローンで完了済みと判定・q: 正常終了する"
    assert_file_contains      "$out" "セットアップが、すでに完了しています"                       "クローンで完了済みと判定: 完了済みの案内が出る"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh repo create"                              "クローンで完了済みと判定・q: 何も実行しない"
    assert_file_not_exists    "$init_dir/admin/.sf-init-testproject.env"                     "クローンで完了済みと判定・q: 状態ファイルを作らない"

    # --resume N → 拒否（状態ファイルがなくても、完了済みなら拒否する）
    : > "$MOCK_CALL_LOG"
    printf 'Y\n' | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
        bash "$mock_home/sf-tools/bin/sf-init.sh" --resume 5 ) > "$out" 2>&1
    exit_code=$?
    assert_exit_fail          "$exit_code"                                                  "クローンで完了済みと判定・--resume 5: 拒否される"
    assert_file_contains      "$out" "完了済みのプロジェクトでは、--resume / --only は使えません"          "クローンで完了済みと判定・--resume 5: 理由が表示される"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh secret set"                              "クローンで完了済みと判定・--resume 5: 何も登録しない"

    # [1] 接続を見る: クローンのフォルダで status.sh が実行される
    printf '#!/bin/bash\necho "STATUS-STUB cwd=$PWD"\nexit 0\n' > "$mock_home/sf-tools/phases/init/status.sh"
    chmod +x "$mock_home/sf-tools/phases/init/status.sh"
    printf 'Y\n1\n' | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
        bash "$mock_home/sf-tools/bin/sf-init.sh" ) > "$out" 2>&1
    exit_code=$?
    assert_exit_ok            "$exit_code"                                                  "クローンで完了済みと判定・1: 正常終了する"
    assert_file_contains      "$out" "STATUS-STUB cwd="                                       "クローンで完了済みと判定・1: 接続の確認（status.sh）が実行される"
    assert_file_contains      "$out" "admin/force-testproject"                                 "クローンで完了済みと判定・1: クローンのフォルダで実行される"

    unset MOCK_GIT_C_REMOTE_URL MOCK_GIT_C_CONFIG_VALUE
    teardown "$mb" "$mock_home" "$init_base"
}

# ==============================================================================
# テスト 26: sf-tools が古いとき、確認のうえ更新し、更新した sf-tools で自動的に実行しなおす（P14）
# ==============================================================================
test_sf_tools_autoupdate() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] sf-tools が古い → 更新して、自動で、はじめから実行しなおす${CLR_RST}"

    local mb mock_home init_base init_dir exit_code out base before after
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"
    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    rm -f "$mb/git"   # このテストは、本物の git で、sf-tools の更新を確認する
    out="$mb/out.log"

    # sf-tools（mock_home/sf-tools）を、本物の Git リポジトリにし、origin を 1 コミット先に進める
    base=$(mktemp -d "${TMPDIR:-/tmp}/test-autoupd-XXXX")
    export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
    (
        cd "$mock_home/sf-tools" || exit 1
        # core.precomposeunicode: macOS の tar は、日本語のファイル名を NFD に変えて展開する。HOME を差し替えて実行すると、
        #   ~/.gitconfig の設定が効かず、同じファイルが「未追跡」に見える（未コミットの変更ありと判定される）ため、リポジトリに設定する
        git init -q -b main && git config core.precomposeunicode true && printf 'logs/\n' >> .git/info/exclude
        git add -A && git commit -qm base
        git init -q --bare -b main "$base/origin.git"
        git remote add origin "$base/origin.git" && git push -q origin main
        git clone -q "$base/origin.git" "$base/w" && cd "$base/w" \
            && echo new > NEW_FILE && git add NEW_FILE && git commit -qm advance && git push -q origin main
    ) > /dev/null 2>&1
    before=$(git -C "$mock_home/sf-tools" rev-list --count HEAD)

    # 入力: Y（sf-tools を更新しますか？）→ Y（実行しなおしたあとの、管理者向けの確認）。以降は、Phase 2 の確認で入力が尽きて中断する
    printf 'Y\nY\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" ) > "$out" 2>&1
    exit_code=$?
    after=$(git -C "$mock_home/sf-tools" rev-list --count HEAD)

    assert_file_contains      "$out" "sf-tools（main）は origin より 1 コミット遅れています"  "遅れが、表示される"
    assert_file_contains      "$out" "sf-tools を更新しました"                                "更新した旨が表示される"
    assert_equals "$after" "$((before + 1))"                                                  "git pull で、1 コミット進んだ"
    assert_file_exists        "$mock_home/sf-tools/NEW_FILE"                                  "origin の新しい内容が、取り込まれた"
    assert_file_contains      "$out" "更新した sf-tools で、もう一度、はじめから実行します"      "自動で、実行しなおす旨が表示される"
    assert_file_contains      "$out" "更新した sf-tools で、はじめから実行しています"            "実行しなおした旨が表示される"
    assert_file_contains      "$out" "ステップ 1 / 9: 準備の確認"                             "実行しなおしたあと、ステップの見出しから続く"
    assert_file_contains      "$out" "【先に、用意してください】"                              "実行しなおしたあと、開始画面（用意するもの）が出る"
    assert_equals "$(grep -c 'このコマンドは管理者専用です' "$out")" "2"                    "管理者向けの警告は、更新の前と、実行しなおしたあとの、2 回出る（確認を飛ばさない）"

    unset MOCK_CALL_LOG
    teardown "$mb" "$mock_home" "$init_base" "$base"
}

# ==============================================================================
# テスト 28: 段階と組織の種類の独立（本番は main のみ・--status・--reconnect・--legacy-connected-app）
# ==============================================================================
test_org_connection() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 段階と組織の種類の独立: 本番は main のみ / --status / --reconnect / --legacy-connected-app${CLR_RST}"

    local mb mock_home out exit_code base force_dir init_base init_dir
    local PROD_JSON SBX_JSON DE_JSON
    PROD_JSON='{"status":0,"result":{"records":[{"Id":"00D0000000PROD01","Name":"Acme Production","IsSandbox":false,"OrganizationType":"Enterprise Edition","TrialExpirationDate":null}]}}'
    SBX_JSON='{"status":0,"result":{"records":[{"Id":"00D0000000SBX001","Name":"Acme Sandbox","IsSandbox":true,"OrganizationType":"Enterprise Edition","TrialExpirationDate":null}]}}'
    DE_JSON='{"status":0,"result":{"records":[{"Id":"00D0000000DE0001","Name":"My Developer Org","IsSandbox":false,"OrganizationType":"Developer Edition","TrialExpirationDate":null}]}}'

    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    out="$mb/out.log"
    export MOCK_SF_ORG_JSON='{"result":{"username":"admin@example.com","alias":"x"}}'
    export SF_INIT_JWT_INTERVAL=0

    # --- A. Phase 10: 本番は main のみ。staging に本番をつなぐと、アプリを作る前に、中断する ---
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"
    mkdir -p "$init_dir/admin"
    printf 'REPO_FULL_NAME="tamashimon/force-testproject"\nREPO_NAME="force-testproject"\nPROJECT_NAME="testproject"\nBRANCH_COUNT="2"\n' \
        > "$init_dir/admin/.sf-init-testproject.env"
    : > "$MOCK_CALL_LOG"
    printf 'Y\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" MOCK_SF_ORG_INFO="$PROD_JSON" \
              SF_INIT_LOGIN_URL_PROD=login SF_INIT_LOGIN_URL_STG=login \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --only 10 ) > "$out" 2>&1
    exit_code=$?
    assert_exit_fail          "$exit_code"                                                    "本番 → main は通り、本番 → staging で中断する"
    assert_file_contains      "$out" "Salesforce の本番組織は、main にしか、つなげません"        "staging に本番: 理由が表示される"
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"              "main（本番）は、登録される"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_STG"               "staging（本番）は、登録されない"
    assert_equals "$(grep -c 'sf project deploy start' "$MOCK_CALL_LOG")" "1"                    "外部クライアントアプリは、main の 1 回だけ作る（staging の本番には、作らない）"
    assert_file_contains      "$MOCK_CALL_LOG" "gh variable set SF_ORG_KIND_PROD --body production" "main に本番: 種類（production）が保存される"
    rm -rf "$init_base"

    # --- A2. main にも staging にも、Developer Edition / Sandbox を、つなげる（種類は、段階と関係ない）---
    rm -rf "$mock_home/.sf-jwt" "$mb/deployed_src" "$mb/jwt.cnt"   # 前のケースで生成された証明書が残ると、「再利用しますか？」の質問が出るため
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"
    mkdir -p "$init_dir/admin"
    printf 'REPO_FULL_NAME="tamashimon/force-testproject"\nREPO_NAME="force-testproject"\nPROJECT_NAME="testproject"\nBRANCH_COUNT="2"\n' \
        > "$init_dir/admin/.sf-init-testproject.env"
    : > "$MOCK_CALL_LOG"
    printf 'Y\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" MOCK_SF_ORG_INFO="$DE_JSON" \
              SF_INIT_LOGIN_URL_PROD=login SF_INIT_LOGIN_URL_STG=login \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --only 10 ) > "$out" 2>&1
    exit_code=$?
    assert_exit_ok            "$exit_code"                                                    "Developer Edition を main・staging に、つなげられる"
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_STG"             "staging（Developer Edition）も、登録される"
    assert_file_contains      "$MOCK_CALL_LOG" "gh variable set SF_ORG_KIND_STG --body developer" "種類（developer）が保存される"
    assert_file_contains      "$MOCK_CALL_LOG" "gh variable set SF_ORG_ID_STG --body 00D0000000DE0001" "組織 ID が保存される"
    rm -rf "$init_base"

    # --- 以降: force-* ディレクトリでの --status / --reconnect ---
    # JWT の鍵・証明書（~/.sf-jwt/force-testproject/）。--reconnect が使う
    mkdir -p "$mock_home/.sf-jwt/force-testproject"
    printf -- "-----BEGIN RSA PRIVATE KEY-----\nFAKE\n-----END RSA PRIVATE KEY-----\n" > "$mock_home/.sf-jwt/force-testproject/server.key"
    printf -- "-----BEGIN CERTIFICATE-----\nFAKE\n-----END CERTIFICATE-----\n" > "$mock_home/.sf-jwt/force-testproject/server.crt"
    base=$(mktemp -d "${TMPDIR:-/tmp}/test-org-XXXX")
    force_dir="$base/force-testproject"
    mkdir -p "$force_dir/sf-tools/config"
    printf 'main\nstaging\n' > "$force_dir/sf-tools/config/branches.txt"
    cat > "$mb/git" << 'GITEOF'
#!/bin/bash
echo "git $*" >> "${MOCK_CALL_LOG:-/dev/null}"
case "$1 $2" in
    "remote get-url") echo "https://github.com/tamashimon/force-testproject.git" ;;
    *) exit 0 ;;
esac
GITEOF
    chmod +x "$mb/git"

    # --- B. --status: 段階ごとの接続・同じ組織の重複・本番が main 以外にある場合の警告 ---
    : > "$MOCK_CALL_LOG"
    ( cd "$force_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
        MOCK_GH_VAR_SF_INSTANCE_URL_PROD=https://login.salesforce.com MOCK_GH_VAR_SF_USERNAME_PROD=admin@example.com \
        MOCK_GH_VAR_SF_ORG_KIND_PROD=developer MOCK_GH_VAR_SF_ORG_ID_PROD=00D0000000DE0001 \
        MOCK_GH_VAR_SF_ORG_NAME_PROD="My Developer Org" MOCK_GH_VAR_SF_ORG_CHECKED_PROD="2026-10-11 14:32" \
        MOCK_GH_VAR_SF_INSTANCE_URL_STG=https://login.salesforce.com MOCK_GH_VAR_SF_USERNAME_STG=admin@example.com \
        MOCK_GH_VAR_SF_ORG_KIND_STG=production MOCK_GH_VAR_SF_ORG_ID_STG=00D0000000DE0001 \
        bash "$mock_home/sf-tools/bin/sf-init.sh" --status ) > "$out" 2>&1
    exit_code=$?
    assert_exit_fail          "$exit_code"                                                    "--status: 本番が main 以外にあれば、非ゼロで終了する"
    assert_file_contains      "$out" "main"                                                    "--status: main が表示される"
    assert_file_contains      "$out" "種類: Developer Edition"                                  "--status: 組織の種類が表示される"
    assert_file_contains      "$out" "組織: My Developer Org（ID 00D0000000DE0001）"            "--status: 組織名・組織 ID が表示される"
    assert_file_contains      "$out" "最終確認: 2026-10-11 14:32"                               "--status: 最終確認日時が表示される"
    assert_file_contains      "$out" "同じ組織につながっています"                                 "--status: 同じ組織の重複が警告される"
    assert_file_contains      "$out" "本番組織は main のみです"                                  "--status: 本番が main 以外にあれば警告する"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh variable set"                              "--status: 何も変更しない（読み取りのみ）"

    # --- C. --reconnect main: 組織を付け替える（旧: Sandbox → 新: Developer Edition）---
    : > "$MOCK_CALL_LOG"
    printf 'Y\n' \
        | ( cd "$force_dir" && HOME="$mock_home" PATH="$mb:$PATH" MOCK_SF_ORG_INFO="$DE_JSON" \
              SF_INIT_LOGIN_URL_PROD=login \
              MOCK_GH_VAR_SF_INSTANCE_URL_PROD=https://test.salesforce.com MOCK_GH_VAR_SF_USERNAME_PROD=old@example.com \
              MOCK_GH_VAR_SF_ORG_KIND_PROD=sandbox MOCK_GH_VAR_SF_ORG_ID_PROD=00D0000000SBX001 MOCK_GH_VAR_SF_ORG_NAME_PROD="Acme Sandbox" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --reconnect main ) > "$out" 2>&1
    exit_code=$?
    assert_exit_ok            "$exit_code"                                                    "--reconnect main: 正常終了する"
    assert_file_contains      "$out" "ログイン先 : https://test.salesforce.com"                  "いまの接続（ログイン先）が表示される"
    assert_file_contains      "$out" "組織       : Acme Sandbox（ID 00D0000000SBX001）"         "いまの接続（組織）が表示される"
    assert_file_contains      "$MOCK_CALL_LOG" "gh variable set SF_INSTANCE_URL_PROD --body https://login.salesforce.com" "新しいログイン先が登録される"
    assert_file_contains      "$MOCK_CALL_LOG" "gh variable set SF_ORG_ID_PROD --body 00D0000000DE0001"                   "新しい組織 ID が保存される"
    assert_file_contains      "$out" "古い組織（Acme Sandbox / ID 00D0000000SBX001）には、外部クライアントアプリ"          "古い組織に残るものが、案内される"
    assert_file_contains      "$out" "自動では、削除しません"                                    "古いアプリは、自動では削除しない"

    # --- D. --reconnect staging に、本番をつなごうとする → 拒否（何も登録しない）---
    : > "$MOCK_CALL_LOG"
    printf 'Y\n' \
        | ( cd "$force_dir" && HOME="$mock_home" PATH="$mb:$PATH" MOCK_SF_ORG_INFO="$PROD_JSON" \
              SF_INIT_LOGIN_URL_STG=login \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --reconnect staging ) > "$out" 2>&1
    exit_code=$?
    assert_exit_fail          "$exit_code"                                                    "--reconnect staging に本番 → 拒否する"
    assert_file_contains      "$out" "本番組織は、main にしか、つなげません"                      "拒否の理由が表示される"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_STG"             "何も登録しない"
    assert_file_not_contains  "$MOCK_CALL_LOG" "sf project deploy start"                       "アプリを作らない"

    # --- D2. 判定できない組織（種類を読み取れない）→ staging には、つなげない（確認では、通さない）---
    : > "$MOCK_CALL_LOG"
    printf 'Y\n' \
        | ( cd "$force_dir" && HOME="$mock_home" PATH="$mb:$PATH" MOCK_SF_ORG_QUERY_EXIT=1 \
              SF_INIT_LOGIN_URL_STG=test \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --reconnect staging ) > "$out" 2>&1
    exit_code=$?
    assert_exit_fail          "$exit_code"                                                    "--reconnect staging + 種類を判定できない → 拒否する"
    assert_file_contains      "$out" "組織の種類を判定できませんでした"                          "判定不能: 理由が表示される"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_STG"             "判定不能: 何も登録しない"
    assert_file_not_contains  "$MOCK_CALL_LOG" "sf project deploy start"                       "判定不能: アプリを作らない"

    # --- D3. 従来の接続アプリ（--legacy-connected-app）でも、staging に本番は、つなげない（Secrets を登録する前に拒否）---
    : > "$MOCK_CALL_LOG"
    printf 'Y\nfake_key\nuser@example.com\n' \
        | ( cd "$force_dir" && HOME="$mock_home" PATH="$mb:$PATH" MOCK_SF_ORG_INFO="$PROD_JSON" \
              SF_INIT_LOGIN_URL_STG=login SF_INIT_LEGACY_CONNECTED_APP=1 \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --reconnect staging ) > "$out" 2>&1
    exit_code=$?
    assert_exit_fail          "$exit_code"                                                    "従来の接続アプリ + staging に本番 → 拒否する"
    assert_file_contains      "$MOCK_CALL_LOG" "sf org login jwt"                              "従来の接続アプリ: JWT 接続テストは、行う（組織の種類を読み取るため）"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_STG"             "従来の接続アプリ: Secrets を登録しない（ガードの後に、登録する）"
    assert_file_contains      "$out" "本番組織、または、種類を判定できない組織は、つなげません"    "従来の接続アプリ: 理由が表示される"

    # --- D4. --add-tier staging に本番 → 拒否。ブランチも PR も作らない（接続を先に行い、できなければ、何も変更しない）---
    local base2 force_dir2
    base2=$(mktemp -d "${TMPDIR:-/tmp}/test-org2-XXXX")
    force_dir2="$base2/force-testproject"
    mkdir -p "$force_dir2/sf-tools/config"
    printf 'main\n' > "$force_dir2/sf-tools/config/branches.txt"
    : > "$MOCK_CALL_LOG"
    printf 'Y\n' \
        | ( cd "$force_dir2" && HOME="$mock_home" PATH="$mb:$PATH" MOCK_SF_ORG_INFO="$PROD_JSON" \
              SF_INIT_LOGIN_URL_STG=login \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --add-tier staging ) > "$out" 2>&1
    exit_code=$?
    assert_exit_fail          "$exit_code"                                                    "--add-tier staging に本番 → 拒否する"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh pr create"                                  "--add-tier: PR を作らない"
    assert_file_not_contains  "$MOCK_CALL_LOG" "push --no-verify -u origin staging"            "--add-tier: staging ブランチを作らない"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_STG"             "--add-tier: Secrets を登録しない"
    assert_equals "$(cat "$force_dir2/sf-tools/config/branches.txt")" "main"                  "--add-tier: branches.txt を変更しない"
    rm -rf "$base2"

    # --- H. --status: 本番が main にだけあれば、正常終了する ---
    : > "$MOCK_CALL_LOG"
    local diag_secrets diag_vars diag_wf
    diag_secrets=$'PAT_TOKEN\nSLACK_BOT_TOKEN\nSF_PRIVATE_KEY\nSF_CONSUMER_KEY_PROD\nSF_CONSUMER_KEY_STG'
    diag_vars=$'SLACK_CHANNEL_ID\nSF_TOOLS_BRANCH\nSF_USERNAME_PROD\nSF_INSTANCE_URL_PROD\nSF_ORG_ID_PROD\nSF_USERNAME_STG\nSF_INSTANCE_URL_STG\nSF_ORG_ID_STG'
    diag_wf=$'wf-metasync.yml\nwf-propagate.yml\nwf-release.yml\nwf-sequence.yml\nwf-validate.yml'
    ( cd "$force_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
        MOCK_GH_SECRETS="$diag_secrets" MOCK_GH_VARIABLES="$diag_vars" MOCK_GH_BRANCHES=$'main\nstaging' MOCK_GH_WORKFLOWS="$diag_wf" \
        MOCK_GH_VAR_SF_INSTANCE_URL_PROD=https://login.salesforce.com MOCK_GH_VAR_SF_USERNAME_PROD=admin@example.com \
        MOCK_GH_VAR_SF_ORG_KIND_PROD=production MOCK_GH_VAR_SF_ORG_ID_PROD=00D0000000PROD01 MOCK_GH_VAR_SF_ORG_NAME_PROD="Acme Production" \
        MOCK_GH_VAR_SF_INSTANCE_URL_STG=https://test.salesforce.com MOCK_GH_VAR_SF_USERNAME_STG=admin@example.com.test \
        MOCK_GH_VAR_SF_ORG_KIND_STG=sandbox MOCK_GH_VAR_SF_ORG_ID_STG=00D0000000SBX001 \
        bash "$mock_home/sf-tools/bin/sf-init.sh" --status ) > "$out" 2>&1
    exit_code=$?
    assert_exit_ok            "$exit_code"                                                    "--status: main = 本番・staging = Sandbox → 正常終了する"
    assert_file_contains      "$out" "種類: 本番"                                               "--status: main の種類（本番）が表示される"
    assert_file_not_contains  "$out" "同じ組織につながっています"                               "--status: 別の組織なら、重複の警告は出ない"
    assert_file_contains      "$out" "セットアップに、不足はありません"                           "--status: 診断（セットアップの状態）で、不足なしと表示される"

    # --- H2. --status の診断: 不足があれば、直し方つきで表示し、非ゼロで終了する（何も変更しない）---
    : > "$MOCK_CALL_LOG"
    ( cd "$force_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
        MOCK_GH_SECRETS=$'SLACK_BOT_TOKEN\nSF_PRIVATE_KEY\nSF_CONSUMER_KEY_PROD' MOCK_GH_VARIABLES="$diag_vars" \
        MOCK_GH_BRANCHES="main" MOCK_GH_WORKFLOWS="$diag_wf" \
        MOCK_GH_VAR_SF_INSTANCE_URL_PROD=https://login.salesforce.com MOCK_GH_VAR_SF_USERNAME_PROD=admin@example.com \
        MOCK_GH_VAR_SF_ORG_KIND_PROD=developer MOCK_GH_VAR_SF_ORG_ID_PROD=00D0000000DE0001 \
        bash "$mock_home/sf-tools/bin/sf-init.sh" --status ) > "$out" 2>&1
    exit_code=$?
    assert_exit_fail          "$exit_code"                                                    "--status: 診断で不足があれば、非ゼロで終了する"
    assert_file_contains      "$out" "PAT_TOKEN がありません"                                    "--status: 不足している Secret が表示される"
    assert_file_contains      "$out" "gh secret set PAT_TOKEN"                                  "--status: 直し方が表示される"
    assert_file_contains      "$out" "SF_CONSUMER_KEY_STG がありません"                           "--status: 段階（staging）の不足が表示される"
    assert_file_contains      "$out" "sf-init.sh --add-tier staging"                            "--status: ブランチがないときの直し方が表示される"
    assert_file_not_contains  "$out" "--status が失敗しました"                                    "--status: 診断の結果を、エラー終了のメッセージにしない"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh secret set"                                  "--status: 何も変更しない（Secrets）"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh variable set"                                "--status: 何も変更しない（Variables）"

    # --- E. 段階の指定が正しくない / branches.txt にない ---
    printf 'Y\n' | ( cd "$force_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
        bash "$mock_home/sf-tools/bin/sf-init.sh" --reconnect develop ) > "$out" 2>&1
    assert_exit_fail          "$?"                                                            "--reconnect develop（branches.txt にない）→ 中断する"
    assert_file_contains      "$out" "develop は、branches.txt にありません"                       "理由が表示される"
    printf 'Y\n' | ( cd "$force_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
        bash "$mock_home/sf-tools/bin/sf-init.sh" --reconnect foo ) > "$out" 2>&1
    assert_exit_fail          "$?"                                                            "--reconnect foo → 中断する"

    # --- F. --legacy-connected-app と、保存済みの種別（外部クライアントアプリ）の食い違い ---
    rm -rf "$mock_home/.sf-jwt"   # 「既存の証明書を再利用しますか？」の質問を、出さないため
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"
    mkdir -p "$init_dir/admin"
    printf 'REPO_FULL_NAME="tamashimon/force-testproject"\nREPO_NAME="force-testproject"\nPROJECT_NAME="testproject"\nBRANCH_COUNT="1"\nAPP_TYPE=2\n' \
        > "$init_dir/admin/.sf-init-testproject.env"
    printf 'Y\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --only 10 --legacy-connected-app ) > "$out" 2>&1
    exit_code=$?
    assert_exit_fail          "$exit_code"                                                    "--legacy-connected-app + 保存済みの外部クライアントアプリ → 中断する"
    assert_file_contains      "$out" "外部クライアントアプリ（APP_TYPE=2）で、設定を始めています"      "食い違いの理由が表示される"
    rm -rf "$init_base"

    unset MOCK_CALL_LOG MOCK_SF_ORG_JSON SF_INIT_JWT_INTERVAL
    teardown "$mb" "$mock_home" "$base"
}

echo ""
echo -e "${CLR_HEAD}========================================"
echo "  sf-init.sh テスト（2/3）"
echo -e "========================================${CLR_RST}"

test_repo_create_failure
test_sf_login_failure
test_invalid_owner_folder
test_admin_branch_push_failure_is_not_fatal
test_initial_sync_failure_is_not_fatal
test_refuse_foreign_clone
test_restart_clears_mark
test_initial_sync_timeout_cancels
test_restart_interrupted_notice
test_only_option_runs_single_phase
test_add_tier_staging_happy
test_unknown_option_fails
test_e2e_input_sequence_layouts
test_sf_cli_check
test_completed_by_clone
test_sf_tools_autoupdate
test_org_connection

print_summary
