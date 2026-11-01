#!/bin/bash
# ==============================================================================
# test_sf-init3.sh - sf-init.sh の単体テスト（モックベース。3/3）
# ==============================================================================
# sf-init.sh のテストは、時間がかかる（Windows の CI で約 10 分）ため、3 つのファイル（test_sf-init.sh・test_sf-init2.sh・
# test_sf-init3.sh）に分け、並列に動かす。共通の部品は tests/init-test-lib.sh。関数の分け方は、実測の所要時間で、均等になるようにした。
# どのテストが、どのファイルにあるかは、下の一覧（関数名）を参照。全部で 53 の関数（件数は、3 つの合計）。
#
# 【このファイルのテスト関数】
#   test_happy_path_3branches
#   test_flex_layout_with_args
#   test_phase3_existing_clone
#   test_admin_branch_created_from_main
#   test_completed_before_mark_existed
#   test_finish_skips_foreign_repo_dir
#   test_repo_visibility_private
#   test_only_phase2_creates_env_file
#   test_add_tier_staging_already_exists
#   test_env_type_selection
#   test_phase11_removed
#   test_phase10_eca_auto
#   test_verify_step
#   test_wf_propagate_skip_missing_branch
#   test_sf_tools_branch_mismatch
#   test_restart_after_phase2_update
#   test_step_header_first_step
#   test_postprocess_conditions
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/init-test-lib.sh"

# ==============================================================================
# テスト 1: ハッピーパス（3ブランチ構成）
# ==============================================================================
test_happy_path_3branches() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] ハッピーパス（3ブランチ構成）${CLR_RST}"

    local mb mock_home init_base init_dir
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"

    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"   # repo view カウンター付きモックで上書き
    _stub_subscripts "$mock_home"

    local exit_code
    _make_input_3branches \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --legacy-connected-app ) \
          > /tmp/sf-init-test-happy.log 2>&1
    exit_code=$?

    assert_exit_ok   "$exit_code"                                                    "正常終了する"
    assert_file_contains "$MOCK_CALL_LOG" "gh auth status"                           "gh auth status が呼ばれる"
    assert_file_contains "$MOCK_CALL_LOG" "gh repo create"                           "gh repo create が呼ばれる"
    assert_file_contains "$MOCK_CALL_LOG" "git clone"                                "git clone が呼ばれる"
    assert_file_exists   "$init_dir/admin/force-testproject/.github/workflows/wf-validate.yml"  "WF ファイル(wf-validate.yml)がコピーされる"
    assert_file_exists   "$init_dir/admin/force-testproject/.github/workflows/wf-release.yml"   "WF ファイル(wf-release.yml)がコピーされる"
    assert_file_contains "$MOCK_CALL_LOG" "sf org login"                             "sf org login jwt が呼ばれる"
    assert_file_contains "$MOCK_CALL_LOG" "gh secret set SF_PRIVATE_KEY"             "SF_PRIVATE_KEY が登録される"
    assert_file_contains "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"       "SF_CONSUMER_KEY_PROD が登録される"
    assert_file_contains "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_STG"        "SF_CONSUMER_KEY_STG が登録される"
    assert_file_contains "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_DEV"        "SF_CONSUMER_KEY_DEV が登録される"
    assert_file_contains "$MOCK_CALL_LOG" "gh secret set PAT_TOKEN"                  "PAT_TOKEN が登録される"
    assert_file_contains "$MOCK_CALL_LOG" "gh secret set SLACK_BOT_TOKEN"            "SLACK_BOT_TOKEN が登録される"
    assert_file_contains "$MOCK_CALL_LOG" "gh variable set SLACK_CHANNEL_ID"          "SLACK_CHANNEL_ID が登録される"
    assert_file_not_contains "$MOCK_CALL_LOG" "SF_TOOLS_TOKEN"                       "SF_TOOLS_TOKEN は登録しない（sf-tools は公開リポジトリのため不要）"
    assert_file_not_contains "$MOCK_CALL_LOG" "ghp_faketoken"                        "PAT_TOKEN の値がコマンド（git push 等）のログに含まれない"
    assert_file_not_contains "$MOCK_CALL_LOG" "--body fake_prod_key"                 "コンシューマー鍵を --body（コマンドの引数）で渡さない（標準入力で渡す）"
    # 接続アプリ版の JWT 接続テストも、一時的なホームフォルダの中で実行される（ユーザーの sf の認証を変えない）
    local jwt_home_ca
    jwt_home_ca=$(grep "^sf-jwt-env HOME=" "$MOCK_CALL_LOG" | head -1 | sed -E 's/^sf-jwt-env HOME=([^ ]*) .*/\1/')
    [[ -n "$jwt_home_ca" && "$jwt_home_ca" == *"sf-tools-home."* && "$jwt_home_ca" != "$mock_home" && ! -e "$jwt_home_ca" ]] \
        && pass "接続アプリ版: JWT 接続テストは、一時的なホームの中で実行され、実行後に削除される" || fail "接続アプリ版: JWT 接続テストの隔離" "HOME=${jwt_home_ca}"
    assert_file_contains "$MOCK_CALL_LOG" "git -c credential.helper= push"           "Phase 8: 認証ヘルパーを無効化して push する"
    assert_file_not_exists "$init_dir/admin/.sf-init-testproject.env"                              "全 Phase 完了後、状態ファイル（.env: Token の値を含みうる）は消える"
    assert_file_not_exists "$init_dir/admin/.sf-init-testproject.progress"                         "全 Phase 完了後、進捗ファイルも消える"
    # ウィザード形式の画面（doc/wizard-ux-design.md）: 開始画面・ステップの見出し・完了画面
    assert_file_contains "/tmp/sf-init-test-happy.log" "新しい Salesforce プロジェクトを作ります"   "開始画面: タイトルが出る"
    assert_file_contains "/tmp/sf-init-test-happy.log" "【先に、用意してください】"                "開始画面: 事前に用意するものが出る"
    assert_file_contains "/tmp/sf-init-test-happy.log" "【これから行うこと】"                      "開始画面: 全体のステップが出る"
    assert_file_contains "/tmp/sf-init-test-happy.log" "ステップ 1 / 9: 準備の確認"               "ステップの見出し（現在地）: 1 / 8"
    assert_file_contains "/tmp/sf-init-test-happy.log" "ステップ 5 / 9: GitHub の Token"          "ステップの見出し（現在地）: 5 / 8"
    assert_file_contains "/tmp/sf-init-test-happy.log" "ステップ 8 / 9: Salesforce の接続"         "ステップの見出し（現在地）: 8 / 8"
    assert_file_contains "/tmp/sf-init-test-happy.log" "（完了: 準備の確認・プロジェクトの確認"      "ステップの見出し: 完了済みのステップが出る"
    assert_file_not_contains "/tmp/sf-init-test-happy.log" "Phase 6"                              "Phase の番号を、画面に出さない"
    assert_file_contains "/tmp/sf-init-test-happy.log" "【次にやること】"                          "完了画面: 次にやることが出る"
    assert_file_contains "/tmp/sf-init-test-happy.log" "sf-job.sh"                                 "完了画面: 次のコマンドが出る"
    assert_file_contains "$MOCK_CALL_LOG" "git add"                                  "git add が呼ばれる"

    teardown "$mb" "$mock_home" "$init_base"
    rm -f /tmp/sf-init-test-happy.log
}

# ==============================================================================
# テスト 6b: フォルダ構成に頼らない（任意の場所 + 引数 --owner / --project）→ 管理者用の作業フォルダは admin
# ==============================================================================
test_flex_layout_with_args() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 任意の場所 + --owner / --project → admin で、最後まで通る${CLR_RST}"

    local mb mock_home base work
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    base=$(mktemp -d "${TMPDIR:-/tmp}/test-init-XXXX")
    work="$base/my-work"          # …/home/{owner}/{company}/ ではない、任意の場所
    mkdir -p "$work"

    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    _stub_subscripts "$mock_home"

    local exit_code
    _make_input_3branches \
        | ( cd "$work" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --owner tamashimon --project force-testproject --legacy-connected-app ) \
          > /tmp/sf-init-test-flex.log 2>&1
    exit_code=$?

    assert_exit_ok   "$exit_code"                                                          "任意の場所で、引数を指定すると、最後まで通る"
    assert_file_contains "$MOCK_CALL_LOG" "gh repo create tamashimon/force-testproject"    "引数のオーナーと XXXX（force- は除く）で、リポジトリを作る"
    assert_file_exists   "$work/admin/force-testproject/.github/workflows/wf-validate.yml"  "管理者用の作業フォルダは admin（admin/force-testproject）"
    assert_dir_not_exists "$work/init"                                                     "admin フォルダ（旧構成の名前）は作らない"
    assert_file_not_exists "$work/admin/.sf-init-testproject.env"                          "完了後、状態ファイル（.sf-init-XXXX.env）は消える（完了後は読む場所がない）"
    assert_file_not_exists "$work/admin/.sf-init-testproject.progress"                     "完了後、進捗ファイル（.sf-init-XXXX.progress）も消える"
    assert_file_contains "/tmp/sf-init-test-flex.log" "force- は自動で付くため"             "force- まで指定したとき、除いたことを表示する"
    assert_file_contains "/tmp/sf-init-test-flex.log" "cd \"$work\""                        "完了画面: 次のコマンドに、実際の作業フォルダを表示する（~/home/… ではない）"
    assert_file_contains "$MOCK_CALL_LOG" "gh workflow run wf-metasync.yml"                "最後に、最初のメタデータの同期（wf-metasync）を起動する"
    assert_file_contains "$MOCK_CALL_LOG" "pull --ff-only origin main"                     "同期のあと、管理者用のクローンに、main を取り込む（git pull --ff-only）"
    assert_file_contains "/tmp/sf-init-test-flex.log" "メタデータは、同期済みです"           "完了画面: メタデータが同期済みであることを知らせる"
    assert_file_contains "$MOCK_CALL_LOG" "checkout admin"                                 "最後に、管理者用のクローンを、admin ブランチにする（モックの git は、admin が既にあると答える）"
    assert_file_contains "$MOCK_CALL_LOG" "push --no-verify -u origin admin"               "admin ブランチを、GitHub にも push する（強制 push ではない）"
    assert_file_contains "/tmp/sf-init-test-flex.log" "ブランチは admin です"               "完了画面: admin ブランチにいることを知らせる"
    assert_file_contains "/tmp/sf-init-test-flex.log" "GitHub の両方にあります"            "完了画面: ローカルと GitHub の両方にあることを知らせる"
    assert_file_contains "/tmp/sf-init-test-flex.log" "main から古くなります"               "完了画面: admin は main から古くなる旨を知らせる"
    assert_file_not_contains "/tmp/sf-init-test-flex.log" "~/home/"                         "完了画面に、~/home/ という決まりを出さない"

    teardown "$mb" "$mock_home" "$base"
}

# ==============================================================================
# テスト 6i: Phase 3: すでにあるクローンが、別のリポジトリなら中断する・同じなら main に切り替える
# ==============================================================================
test_phase3_existing_clone() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] Phase 3: すでにあるクローン（別のリポジトリ → 中断 / 同じ → main に切り替え・最新にする）${CLR_RST}"
    local mb mock_home base work exit_code out
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    create_all_mocks "$mb"; create_mock_gh_for_init "$mb"; _stub_subscripts "$mock_home"
    base=$(mktemp -d "${TMPDIR:-/tmp}/test-init-XXXX"); work="$base/my-work"
    mkdir -p "$work/admin/force-testproject/.git"
    cat > "$work/admin/.sf-init-testproject.env" <<ENVEOF
GITHUB_OWNER="tamashimon"
PROJECT_NAME="testproject"
REPO_NAME="force-testproject"
REPO_FULL_NAME="tamashimon/force-testproject"
REPO_DIR="$work/admin/force-testproject"
ENV_TYPE="production"
SF_TOOLS_BRANCH="main"
ENVEOF
    # 別のリポジトリ（Phase 3 の確認。--only 3 は、sf-init.sh の確認を通らずに、Phase 3 だけを実行する）
    export MOCK_GIT_C_REMOTE_URL="https://github.com/other/force-testproject.git"
    : > "$MOCK_CALL_LOG"
    out=$(printf 'Y\n' | ( cd "$work" && HOME="$mock_home" PATH="$mb:$PATH" \
        bash "$mock_home/sf-tools/bin/sf-init.sh" --only 3 --owner tamashimon --project testproject ) 2>&1)
    exit_code=$?
    assert_exit_fail "$exit_code"                                                        "Phase 3・別のリポジトリのクローン → 異常終了する"
    assert_file_not_contains "$MOCK_CALL_LOG" "checkout main"                            "Phase 3・別のリポジトリのクローン → 切り替えもしない"
    # 同じリポジトリ（admin ブランチにいる想定: モックの symbolic-ref は main 以外を返す）
    export MOCK_GIT_C_REMOTE_URL="https://github.com/Tamashimon/Force-TestProject.git"   # 大文字と小文字は、区別しない
    # 完了の印は 0（やり直し中）にする。印が未設定で admin ブランチがあると、完了済みとみなされ、--only は拒否される
    #   （完了済みのプロジェクトでは、--resume / --only は使えない）。ここは、セットアップの途中の Phase 3 を試すテスト
    export MOCK_GIT_C_CONFIG_VALUE=0
    : > "$MOCK_CALL_LOG"
    out=$(printf 'Y\n' | ( cd "$work" && HOME="$mock_home" PATH="$mb:$PATH" \
        bash "$mock_home/sf-tools/bin/sf-init.sh" --only 3 --owner tamashimon --project testproject ) 2>&1)
    exit_code=$?
    unset MOCK_GIT_C_REMOTE_URL MOCK_GIT_C_CONFIG_VALUE
    assert_exit_ok "$exit_code"                                                          "Phase 3・同じリポジトリのクローン（大文字と小文字の違いは許す）→ 正常終了する"
    assert_file_contains "$MOCK_CALL_LOG" "checkout main"                                "Phase 3・admin ブランチのままだと、あとの Phase のコミットが main に入らないため、main に切り替える"
    assert_file_contains "$MOCK_CALL_LOG" "pull --ff-only origin main"                   "Phase 3・main を最新にする（git pull --ff-only）"
    teardown "$mb" "$mock_home" "$base"
}

# ==============================================================================
# テスト 6l: admin ブランチは、新しく作る場合、main から作る
# ==============================================================================
test_admin_branch_created_from_main() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] admin ブランチがまだないとき → main から作る（checkout -b admin main）${CLR_RST}"
    local mb mock_home base work exit_code
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    create_all_mocks "$mb"; create_mock_gh_for_init "$mb"; _stub_subscripts "$mock_home"
    base=$(mktemp -d "${TMPDIR:-/tmp}/test-init-XXXX"); work="$base/my-work"; mkdir -p "$work"
    export MOCK_GIT_REV_VERIFY_EXIT=1     # admin ブランチは、まだない
    _make_input_3branches \
        | ( cd "$work" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --owner tamashimon --project testproject --legacy-connected-app ) \
          > /tmp/sf-init-test-newadmin.log 2>&1
    exit_code=$?
    unset MOCK_GIT_REV_VERIFY_EXIT
    assert_exit_ok "$exit_code"                                                          "admin ブランチがまだない → 正常終了する"
    assert_file_contains "$MOCK_CALL_LOG" "checkout -b admin main"                       "admin ブランチは、main から作る"
    assert_file_contains "$MOCK_CALL_LOG" "config sf-tools.setup-complete 1"             "完了時に、クローンに完了の印を付ける"
    teardown "$mb" "$mock_home" "$base"
    rm -f /tmp/sf-init-test-newadmin.log
}

# ==============================================================================
# テスト 6n: 印を導入する前の版で完了したプロジェクト（印も状態ファイルもない・admin ブランチはある）→ 完了済みとして扱う
# ==============================================================================
test_completed_before_mark_existed() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 印がない（以前の版で完了）・admin ブランチがある → 完了済みの案内（新規セットアップとして、上書きしない）${CLR_RST}"
    local mb mock_home base work exit_code out
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    create_all_mocks "$mb"; create_mock_gh_for_init "$mb"; _stub_subscripts "$mock_home"
    base=$(mktemp -d "${TMPDIR:-/tmp}/test-init-XXXX"); work="$base/my-work"
    mkdir -p "$work/admin/force-testproject/.git"                      # 状態ファイルは、ない
    export MOCK_GIT_C_REMOTE_URL="https://github.com/tamashimon/force-testproject.git"
    # MOCK_GIT_C_CONFIG_VALUE は、未設定（印がない）。モックの git は、admin ブランチが「ある」と答える（rev-parse --verify）
    : > "$MOCK_CALL_LOG"
    out=$(printf 'Y\nq\n' | ( cd "$work" && HOME="$mock_home" PATH="$mb:$PATH" \
        bash "$mock_home/sf-tools/bin/sf-init.sh" ) 2>&1)
    exit_code=$?
    assert_exit_ok "$exit_code"                                                          "印がなく admin ブランチがある・q: 正常終了する"
    assert_output_contains "$out" "セットアップが、すでに完了しています"                      "印がなく admin ブランチがある: 完了済みの案内が出る"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo create"                           "印がなく admin ブランチがある: 新規セットアップとして、動かない"
    assert_file_contains "$MOCK_CALL_LOG" "config sf-tools.setup-complete 1"             "印がなく admin ブランチがある: 印を付ける（移行）"
    # --resume N も、拒否される
    : > "$MOCK_CALL_LOG"
    out=$(printf 'Y\n' | ( cd "$work" && HOME="$mock_home" PATH="$mb:$PATH" \
        bash "$mock_home/sf-tools/bin/sf-init.sh" --resume 5 ) 2>&1)
    exit_code=$?
    unset MOCK_GIT_C_REMOTE_URL
    assert_exit_fail "$exit_code"                                                        "印がなく admin ブランチがある・--resume 5: 拒否される"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh secret set"                            "印がなく admin ブランチがある・--resume 5: 何も登録しない"
    teardown "$mb" "$mock_home" "$base"
}

# ==============================================================================
# テスト 6q: 後片付けは、状態ファイルの REPO_DIR が指すクローンが、別のリポジトリなら、何もしない
# ==============================================================================
test_finish_skips_foreign_repo_dir() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 状態ファイルの REPO_DIR が別のリポジトリのクローン → 後片付けで、push しない${CLR_RST}"
    local mb mock_home base work other exit_code out
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    create_all_mocks "$mb"; create_mock_gh_for_init "$mb"; _stub_subscripts "$mock_home"
    base=$(mktemp -d "${TMPDIR:-/tmp}/test-init-XXXX"); work="$base/my-work"; other="$base/elsewhere/force-testproject"
    mkdir -p "$work/admin" "$other/.git"
    cat > "$work/admin/.sf-init-testproject.env" <<ENVEOF
GITHUB_OWNER="tamashimon"
PROJECT_NAME="testproject"
REPO_NAME="force-testproject"
REPO_FULL_NAME="tamashimon/force-testproject"
REPO_DIR="$other"
ENVEOF
    printf 'SF_INIT_DONE_PHASE=10\nSF_INIT_DONE_AT="2026-10-17 01:00"\n' > "$work/admin/.sf-init-testproject.progress"
    export MOCK_GIT_C_REMOTE_URL="https://github.com/someone-else/force-testproject.git"   # REPO_DIR のクローンは、別のリポジトリ
    : > "$MOCK_CALL_LOG"
    out=$(printf 'Y\nq\n' | ( cd "$work" && HOME="$mock_home" PATH="$mb:$PATH" \
        bash "$mock_home/sf-tools/bin/sf-init.sh" ) 2>&1)
    exit_code=$?
    unset MOCK_GIT_C_REMOTE_URL
    assert_file_not_contains "$MOCK_CALL_LOG" "push"                                     "別のリポジトリのクローン → 後片付けで、push しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "setup-complete 1"                         "別のリポジトリのクローン → 完了の印を付けない"
    assert_file_exists "$work/admin/.sf-init-testproject.env"                            "別のリポジトリのクローン → 状態ファイルも、消さない"
    teardown "$mb" "$mock_home" "$base"
}

# ==============================================================================
# テスト 7: リポジトリ visibility - 常に --private で作成
# ==============================================================================
test_repo_visibility_private() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 任意オーナー → --private で作成${CLR_RST}"

    local mb mock_home init_base init_dir
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"

    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    _stub_subscripts "$mock_home"

    _make_input_3branches \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" ) > /dev/null 2>&1

    assert_file_contains "$MOCK_CALL_LOG" "gh repo create"  "gh repo create が呼ばれる"
    assert_file_contains "$MOCK_CALL_LOG" "--private"       "常に --private で作成される"

    teardown "$mb" "$mock_home" "$init_base"
}

# ==============================================================================
# テスト 9: --only 2 → .sf-init.env が生成される
# ==============================================================================
test_only_phase2_creates_env_file() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] --only 2 → .sf-init.env が生成される${CLR_RST}"

    local mb mock_home init_base init_dir
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"

    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"

    local exit_code
    printf 'Y\nY\n1\nN\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --only 2 ) > /dev/null 2>&1
    exit_code=$?

    assert_exit_ok       "$exit_code"                                                "--only 2 で正常終了する"
    assert_file_exists   "$init_dir/admin/.sf-init-testproject.env"                                    ".sf-init.env が生成される"
    assert_file_contains "$init_dir/admin/.sf-init-testproject.env" "REPO_FULL_NAME"                  ".sf-init.env に REPO_FULL_NAME が含まれる"
    assert_file_contains "$init_dir/admin/.sf-init-testproject.env" "tamashimon/force-testproject"    "正しい REPO_FULL_NAME が書き出される"

    teardown "$mb" "$mock_home" "$init_base"
}

# ==============================================================================
# テスト 12: --add-tier staging → すでに存在する場合はエラー
# ==============================================================================
test_add_tier_staging_already_exists() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] --add-tier staging → 既存ならエラー${CLR_RST}"

    local mb mock_home force_dir base_dir
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)

    base_dir=$(mktemp -d "${TMPDIR:-/tmp}/test-add-tier-XXXX")
    force_dir="$base_dir/force-testproject"
    mkdir -p "$force_dir/sf-tools/config"
    # staging がすでに存在する状態
    printf 'main\nstaging\n' > "$force_dir/sf-tools/config/branches.txt"

    create_all_mocks "$mb"

    # git show origin/main:sf-tools/config/branches.txt は、MOCK_GIT_MAIN_BRANCHES（printf %b）を返す（origin/main の版）
    cat > "$mb/git" << 'GITEOF'
#!/bin/bash
echo "git $*" >> "${MOCK_CALL_LOG:-/dev/null}"
case "$1 $2" in
    "remote get-url") echo "https://github.com/tamashimon/force-testproject.git" ;;
    "show origin/main:sf-tools/config/branches.txt") printf '%b' "${MOCK_GIT_MAIN_BRANCHES:-main\n}" ;;
    *) exit 0 ;;
esac
GITEOF
    chmod +x "$mb/git"

    local exit_code out="$mb/out.log"
    ( cd "$force_dir" && HOME="$mock_home" PATH="$mb:$PATH" MOCK_GIT_MAIN_BRANCHES='main\nstaging\n' \
          bash "$mock_home/sf-tools/bin/sf-init.sh" --add-tier staging ) > "$out" 2>&1 < /dev/null
    exit_code=$?

    assert_exit_fail "$exit_code" "既存 tier は失敗終了する"
    assert_file_contains "$out" "すでに branches.txt（origin/main）に登録されています" "既存 tier → 理由が表示される"

    # 回帰: 作業ツリー（admin）の branches.txt には staging がなく、origin/main にはある → 重複として止める
    #   （以前は、作業ツリーで確認し、origin/main の版に追記していたため、すり抜けて staging が 2 行になった）
    printf 'main\n' > "$force_dir/sf-tools/config/branches.txt"
    : > "$MOCK_CALL_LOG"
    ( cd "$force_dir" && HOME="$mock_home" PATH="$mb:$PATH" MOCK_GIT_MAIN_BRANCHES='main\nstaging\n' \
          bash "$mock_home/sf-tools/bin/sf-init.sh" --add-tier staging ) > "$out" 2>&1 < /dev/null
    exit_code=$?
    assert_exit_fail "$exit_code" "作業ツリーになく origin/main にある → 失敗終了する"
    assert_file_contains "$out" "すでに branches.txt（origin/main）に登録されています" "作業ツリーになく origin/main にある → 重複として止める"
    assert_file_not_contains "$MOCK_CALL_LOG" "git push" "作業ツリーになく origin/main にある → 何も push しない"

    # 逆: 作業ツリーにはあり、origin/main にない → 止めない（確認は、追記する版で行う。ここでは、確認の質問まで進むことだけを見る）
    printf 'main\nstaging\n' > "$force_dir/sf-tools/config/branches.txt"
    ( cd "$force_dir" && HOME="$mock_home" PATH="$mb:$PATH" MOCK_GIT_MAIN_BRANCHES='main\n' \
          bash "$mock_home/sf-tools/bin/sf-init.sh" --add-tier staging ) > "$out" 2>&1 < /dev/null
    assert_file_not_contains "$out" "すでに branches.txt" "作業ツリーにあり origin/main にない → 重複としない"

    # origin/main の branches.txt を読めない → 中断する
    cat > "$mb/git" << 'GITEOF'
#!/bin/bash
case "$1 $2" in
    "remote get-url") echo "https://github.com/tamashimon/force-testproject.git" ;;
    "show origin/main:sf-tools/config/branches.txt") echo "fatal: path does not exist" >&2; exit 128 ;;
    *) exit 0 ;;
esac
GITEOF
    ( cd "$force_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
          bash "$mock_home/sf-tools/bin/sf-init.sh" --add-tier staging ) > "$out" 2>&1 < /dev/null
    exit_code=$?
    assert_exit_fail "$exit_code" "origin/main の branches.txt を読めない → 失敗終了する"
    assert_file_contains "$out" "を読めません" "origin/main の branches.txt を読めない → 理由が表示される"

    teardown "$mb" "$mock_home"
    rm -rf "$base_dir"
}

# ==============================================================================
# テスト 15: 環境種別の選択（--only 2 で Phase 2 のみ実行）
#   入力列: 警告確認 Y → Phase2 確認 Y → 環境種別以降（\n は buffer 残留として無視される）
#   - 1            → 本番環境（確認なし）
#   - 2 → Y        → 検証環境
#   - 2 → N → 1    → 検証を取り消して選び直し、本番環境
#   - 2 → q        → 中断（.sf-init.env は生成されない）
# ==============================================================================
test_env_type_selection() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 環境種別の選択（本番 / 検証・確認 / 選び直し / 中断）${CLR_RST}"

    local mb mock_home init_base init_dir env_file exit_code
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"

    # 1: 本番環境
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"
    env_file="$init_dir/admin/.sf-init-testproject.env"
    printf 'Y\nY\n1\nN\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --only 2 ) > /dev/null 2>&1
    exit_code=$?
    assert_exit_ok       "$exit_code"                              "1 → 正常終了"
    assert_file_contains "$env_file" 'ENV_TYPE="production"'       "1 → ENV_TYPE=production"
    assert_file_contains "$env_file" 'SF_TOOLS_BRANCH="main"'      "1 → SF_TOOLS_BRANCH=main"
    rm -rf "$init_base"

    # 2 → Y: 検証環境
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"
    env_file="$init_dir/admin/.sf-init-testproject.env"
    printf 'Y\nY\n2\nY\nN\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --only 2 ) > /dev/null 2>&1
    exit_code=$?
    assert_exit_ok       "$exit_code"                                    "2 → Y → 正常終了"
    assert_file_contains "$env_file" 'ENV_TYPE="staging"'                "2 → Y → ENV_TYPE=staging"
    assert_file_contains "$env_file" 'SF_TOOLS_BRANCH="development"'     "2 → Y → SF_TOOLS_BRANCH=development"
    rm -rf "$init_base"

    # 2 → N → 1: 検証を取り消して選び直し、本番環境
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"
    env_file="$init_dir/admin/.sf-init-testproject.env"
    printf 'Y\nY\n2\nN\n1\nN\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --only 2 ) > /dev/null 2>&1
    exit_code=$?
    assert_exit_ok       "$exit_code"                              "2 → N → 1 → 正常終了"
    assert_file_contains "$env_file" 'ENV_TYPE="production"'       "2 → N → 1 → ENV_TYPE=production（選び直せる）"
    rm -rf "$init_base"

    # 2 → q: 中断
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"
    env_file="$init_dir/admin/.sf-init-testproject.env"
    printf 'Y\nY\n2\nq\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --only 2 ) > /dev/null 2>&1
    exit_code=$?
    assert_exit_fail        "$exit_code"   "2 → q → 中断（異常終了）"
    assert_file_not_exists  "$env_file"    "2 → q → .sf-init.env は生成されない"

    teardown "$mb" "$mock_home" "$init_base"
}

# ==============================================================================
# テスト 16: Phase 11 は廃止（sf-tools は公開リポジトリのため、SF_TOOLS_TOKEN は不要）
#   - --only 11 はエラー（Phase 11 のスクリプトが無い）
#   - ワークフローのひな形は、Token なしで sf-tools を clone する（SF_TOOLS_TOKEN / x-access-token を使わない）
#   - sf-init のコード・ドキュメントが、SF_TOOLS_TOKEN を要求しない
# ==============================================================================
test_phase11_removed() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] Phase 11 は廃止: SF_TOOLS_TOKEN は不要（sf-tools は公開リポジトリ）${CLR_RST}"

    local mb mock_home init_base init_dir exit_code out
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    _stub_subscripts "$mock_home"
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"
    mkdir -p "$init_dir/admin"
    printf 'REPO_FULL_NAME="tamashimon/force-testproject"\nPROJECT_NAME="testproject"\n' > "$init_dir/admin/.sf-init-testproject.env"
    : > "$MOCK_CALL_LOG"

    out=$( printf 'Y\n' | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --only 11 ) 2>&1 )
    exit_code=$?
    assert_exit_fail         "$exit_code"                                              "--only 11 → エラー終了（Phase 11 は無い）"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh secret set SF_TOOLS_TOKEN"           "--only 11 → SF_TOOLS_TOKEN は登録されない"
    [[ ! -e "$SF_TOOLS_DIR/phases/init/11_sf_tools_token.sh" ]] \
        && pass "Phase 11 のスクリプト（11_sf_tools_token.sh）が存在しない" || fail "Phase 11 のスクリプトが存在しない" "残っている"

    # ワークフローのひな形: Token なしで clone する
    local wf
    for wf in wf-metasync wf-release wf-validate; do
        assert_file_contains     "$SF_TOOLS_DIR/templates/.github/workflows/${wf}.yml" "git clone -b \${{ vars.SF_TOOLS_BRANCH || 'main' }} https://github.com/tama-create/sf-tools.git" "${wf}: Token なしで sf-tools を clone する"
        assert_file_not_contains "$SF_TOOLS_DIR/templates/.github/workflows/${wf}.yml" "SF_TOOLS_TOKEN"   "${wf}: SF_TOOLS_TOKEN を使わない"
        assert_file_not_contains "$SF_TOOLS_DIR/templates/.github/workflows/${wf}.yml" "x-access-token"   "${wf}: Token 付きの URL を使わない"
    done

    teardown "$mb" "$mock_home" "$init_base"
}

# ==============================================================================
# テスト 19: Phase 10 — 外部クライアントアプリ（ECA）の自動作成（--only 10）
#   入力列: 警告確認 Y → アプリ種別 2 → メイン組織は Sandbox? N（ブランチ構成 1 階層 = メイン組織のみ）
#   - 正常                  : ブラウザログイン → deploy → 鍵を retrieve → JWT → 登録。メタデータの内容も検証
#   - 終了コード 1          : login web / org display の終了コードが 1 なら中断（成否は終了コードで判定。sf は npm 版が前提）
#   - ログイン失敗          : 待ち時間切れなどで login web が失敗したら中断。deploy・登録は行われない
#   - JWT が最初の 2 回失敗 : リトライして 3 回目で成功
#   - deploy が失敗         : 中断。retrieve・登録は行われない
#   - JWT が成功しない      : 確認で N → 中断 / Y → 接続テストをスキップして登録
#   いずれも sf org logout は使わない（同じユーザー名の全エイリアスの認証が消えるため）
# ==============================================================================
test_phase10_eca_auto() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] Phase 10: 外部クライアントアプリの自動作成${CLR_RST}"

    local mb mock_home init_base init_dir exit_code out jwt_calls
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    _stub_subscripts "$mock_home"
    out="$mb/out.log"
    export MOCK_SF_ORG_JSON='{"result":{"username":"admin@example.com","alias":"x"}}'
    export SF_INIT_JWT_INTERVAL=0
    # ログイン先は、環境変数で指定する（login = login.salesforce.com）。直前の質問（read_key）の改行が、
    # 次の質問に、空 Enter（= 既定の Sandbox）として読まれるのを、避けるため。ログイン先の質問そのものは、tests/test_org.sh で確認する
    export SF_INIT_LOGIN_URL_PROD=login

    _p10_run() {
        init_base=$(_setup_init_dir "tamashimon" "testproject")
        init_dir="$init_base/home/tamashimon/testproject"
        mkdir -p "$init_dir/admin"
        printf 'REPO_FULL_NAME="tamashimon/force-testproject"\nREPO_NAME="force-testproject"\nPROJECT_NAME="testproject"\nBRANCH_COUNT="1"\n' \
            > "$init_dir/admin/.sf-init-testproject.env"
        # 前のケースで生成された証明書が残ると「既存の証明書を再利用しますか？」の確認が出て入力列がずれるため消す
        rm -rf "$mb/deployed_src" "$mb/jwt.cnt" "$mock_home/.sf-jwt"
        : > "$MOCK_CALL_LOG"
        printf '%b' "$1" \
            | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
                  bash "$mock_home/sf-tools/bin/sf-init.sh" --only 10 ) > "$out" 2>&1
        exit_code=$?
    }
    # 一時エイリアス（sf-tools-PROD）を、指定の呼び出し（$1 の最初の行）より後で外したか。引数: 呼び出しの文字列 テスト名
    _p10_unset_after() {
        local first last
        first=$(grep -nF -- "$1" "$MOCK_CALL_LOG" | head -1 | cut -d: -f1)
        last=$(grep -nF -- "sf alias unset sf-tools-PROD" "$MOCK_CALL_LOG" | tail -1 | cut -d: -f1)
        [[ -n "$first" && -n "$last" && "$last" -gt "$first" ]] \
            && pass "$2" || fail "$2" "「$1」の行: ${first:-なし} / 最後の alias unset の行: ${last:-なし}"
    }

    # 正常
    _p10_run 'Y\n'
    assert_exit_ok            "$exit_code"                                                              "正常 → 終了コード 0"
    assert_file_contains      "$MOCK_CALL_LOG" "sf org login web --instance-url https://login.salesforce.com --alias sf-tools-PROD" "ブラウザでログインする（一時エイリアス）"
    assert_file_contains      "$MOCK_CALL_LOG" "sf alias unset sf-tools-PROD"                             "ログイン前に前回の一時エイリアスを外す"
    assert_file_contains      "$MOCK_CALL_LOG" "sf project deploy start --source-dir force-app"          "メタデータを deploy する"
    assert_file_contains      "$MOCK_CALL_LOG" "ExtlClntAppGlobalOauthSettings:SF_TOOLS_force_testproject_glbloauth" "コンシューマー鍵を retrieve で取得する"
    assert_file_contains      "$MOCK_CALL_LOG" "sf org login jwt"                                         "JWT 接続テストを行う"
    assert_file_contains      "$MOCK_CALL_LOG" "sf alias unset sf-tools-PROD"                             "一時エイリアスを sf alias unset で消す"
    assert_file_not_contains  "$MOCK_CALL_LOG" "org logout"                                               "sf org logout は使わない"
    # JWT 接続テストは、一時的なホームフォルダの中で実行される（ユーザーの sf のエイリアス・認証を変えない）
    local jwt_home
    jwt_home=$(grep "^sf-jwt-env HOME=" "$MOCK_CALL_LOG" | head -1 | sed -E 's/^sf-jwt-env HOME=([^ ]*) .*/\1/')
    [[ -n "$jwt_home" && "$jwt_home" == *"sf-tools-home."* && "$jwt_home" != "$mock_home" ]] \
        && pass "JWT 接続テストは、一時的なホーム（sf-tools-home.*）の中で実行される" || fail "JWT 接続テストは、一時的なホームの中で実行される" "HOME=${jwt_home}"
    [[ -n "$jwt_home" && ! -e "$jwt_home" ]] \
        && pass "JWT 接続テストの一時的なホームは、実行後に削除されている" || fail "JWT 接続テストの一時的なホームは、実行後に削除されている" "${jwt_home}"
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"                       "SF_CONSUMER_KEY_PROD が登録される"
    assert_file_not_contains  "$MOCK_CALL_LOG" "--body 3MVGMOCKCONSUMERKEY"                               "コンシューマー鍵を --body（引数）で渡さない"
    assert_file_contains      "$MOCK_CALL_LOG" "gh variable set SF_USERNAME_PROD --body admin@example.com" "SF_USERNAME_PROD にログインしたユーザー名が登録される"
    local d="$mb/deployed_src/main/default"
    assert_file_exists        "$d/externalClientApps/SF_TOOLS_force_testproject.eca-meta.xml"            "ECA 本体のメタデータが生成される"
    assert_file_contains      "$d/extlClntAppOauthPolicies/SF_TOOLS_force_testproject_oauthPlcy.ecaOauthPlcy-meta.xml" "<commaSeparatedProfile>System Administrator</commaSeparatedProfile>" "接続ユーザーのプロファイル名が入る"
    assert_file_contains      "$d/extlClntAppOauthPolicies/SF_TOOLS_force_testproject_oauthPlcy.ecaOauthPlcy-meta.xml" "AdminApprovedPreAuthorized" "管理者が承認したユーザーは事前承認済み"
    assert_file_contains      "$d/extlClntAppGlobalOauthSets/SF_TOOLS_force_testproject_glbloauth.ecaGlblOauth-meta.xml" "<certificate>" "証明書が入る"
    assert_file_not_contains  "$d/extlClntAppGlobalOauthSets/SF_TOOLS_force_testproject_glbloauth.ecaGlblOauth-meta.xml" "-----BEGIN" "証明書の BEGIN/END 行は含まない（本文のみ）"
    assert_file_not_contains  "$d/extlClntAppGlobalOauthSets/SF_TOOLS_force_testproject_glbloauth.ecaGlblOauth-meta.xml" "consumerKey" "consumerKey は書かない（出力項目）"
    rm -rf "$init_base"

    # sf の終了コードが 1 → 失敗として中断（成否は終了コードで判定する。sf は npm 版が前提）
    #   出力に成功の文言（Successfully authorized）があっても、終了コードが 1 なら、成功とはみなさない
    MOCK_SF_LOGIN_WEB_EXIT=1 _p10_run 'Y\n'
    assert_exit_fail          "$exit_code"                                                              "login web の終了コード 1 → 中断（出力に成功の文言があっても、成功とみなさない）"
    assert_file_contains      "$out" "へのログインに失敗しました"                                          "login web の終了コード 1 → 失敗の旨が表示される"
    assert_file_not_contains  "$MOCK_CALL_LOG" "project deploy start"                                     "login web の終了コード 1 → deploy しない"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"                       "login web の終了コード 1 → 登録しない"
    rm -rf "$init_base"

    MOCK_SF_ORG_DISPLAY_EXIT=1 _p10_run 'Y\n'
    assert_exit_fail          "$exit_code"                                                              "org display の終了コード 1 → 中断"
    assert_file_contains      "$out" "接続情報を取得できませんでした"                                      "org display の終了コード 1 → 失敗の旨が表示される"
    assert_file_not_contains  "$MOCK_CALL_LOG" "project deploy start"                                     "org display の終了コード 1 → deploy しない"
    # 回帰: ログインのあとの die でも、一時エイリアスを外してから終了する（以前は、org_guard の違反のときだけ外していた）
    _p10_unset_after "sf org display" "org display の終了コード 1 → 一時エイリアスを外してから中断する"
    rm -rf "$init_base"

    # ログイン失敗（待ち時間切れなどで接続できていない）→ 中断
    MOCK_SF_LOGIN_WEB_FAIL=1 _p10_run 'Y\n'
    assert_exit_fail          "$exit_code"                                                              "ログイン失敗 → 中断"
    assert_file_contains      "$out" "へのログインに失敗しました"                                          "ログイン失敗 → 失敗の旨が表示される"
    assert_file_not_contains  "$MOCK_CALL_LOG" "project deploy start"                                     "ログイン失敗 → deploy しない"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"                       "ログイン失敗 → 登録しない"
    rm -rf "$init_base"

    # JWT が最初の 2 回失敗 → リトライして成功
    MOCK_SF_JWT_FAIL_FIRST=2 _p10_run 'Y\n'
    jwt_calls=$(grep -c "^sf org login jwt" "$MOCK_CALL_LOG")
    assert_exit_ok            "$exit_code"                                                              "JWT リトライ → 終了コード 0"
    [[ "$jwt_calls" -eq 3 ]] && pass "JWT 接続テストを 3 回試行（2 回失敗 + 1 回成功）" || fail "JWT 接続テストを 3 回試行" "試行回数: ${jwt_calls}"
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"                       "リトライ成功後に登録される"
    rm -rf "$init_base"

    # deploy 失敗 → 中断
    MOCK_SF_DEPLOY_EXIT=1 _p10_run 'Y\n'
    assert_exit_fail          "$exit_code"                                                              "deploy 失敗 → 中断"
    assert_file_not_contains  "$MOCK_CALL_LOG" "project retrieve"                                         "deploy 失敗 → retrieve しない"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"                       "deploy 失敗 → 登録しない"
    _p10_unset_after "sf project deploy start" "deploy 失敗 → 一時エイリアスを外してから中断する（回帰）"
    rm -rf "$init_base"

    # JWT が成功しない → 確認で N → 中断
    MOCK_SF_JWT_FAIL_FIRST=99 SF_INIT_JWT_RETRIES=2 _p10_run 'Y\nN\n'
    assert_exit_fail          "$exit_code"                                                              "JWT 不成功 + スキップしない → 中断"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"                       "JWT 不成功 + スキップしない → 登録しない"
    # 回帰: N で中断しても、一時エイリアスは残らない（retrieve のあとで外す。以前は、テストのあとに外していたため、N で残った）
    _p10_unset_after "sf project retrieve" "JWT 不成功 + スキップしない → 一時エイリアスは外れている"
    # 回帰: 最後の試行のあとは、待たない（試行 2 回 → 待つのは 1 回だけ。以前は、最後の失敗のあとにも待っていた）
    assert_equals "$(grep -c "秒後に、もう一度、確認します" "$out")" "1"                                      "JWT 不成功（2 回）→ 待つのは試行の間の 1 回だけ"
    rm -rf "$init_base"

    # JWT が成功しない → 確認で Y → スキップして登録
    MOCK_SF_JWT_FAIL_FIRST=99 SF_INIT_JWT_RETRIES=2 _p10_run 'Y\nY\n'
    assert_exit_ok            "$exit_code"                                                              "JWT 不成功 + スキップする → 終了コード 0"
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"                       "JWT 不成功 + スキップする → 登録される"

    unset -f _p10_run _p10_unset_after
    unset MOCK_SF_ORG_JSON SF_INIT_JWT_INTERVAL SF_INIT_LOGIN_URL_PROD
    teardown "$mb" "$mock_home" "$init_base"
}

# ==============================================================================
# テスト: ステップ 9「動作の確認」（verify.sh を呼ぶ最後のステップ）
#   verify.sh は、スタブ（呼ばれたことと、環境変数・実行したフォルダを記録）に置き換える
# ==============================================================================
test_verify_step() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] ステップ 9: 動作の確認（Enter = 確認する / s = あとで / EOF = あとで / 失敗）${CLR_RST}"

    local mb mock_home init_base init_dir exit_code input case_name answer stub_rc
    for case_name in enter skip eof fail; do
        mb=$(setup_mock_bin)
        export MOCK_CALL_LOG="$mb/calls.log"
        mock_home=$(setup_mock_home)
        init_base=$(_setup_init_dir "tamashimon" "testproject")
        init_dir="$init_base/home/tamashimon/testproject"
        create_all_mocks "$mb"
        create_mock_gh_for_init "$mb"
        _stub_subscripts "$mock_home"
        # verify.sh のスタブ（呼ばれたこと・SF_VERIFY_CONFIRMED・実行したフォルダを記録して、指定の終了コードで終わる）
        stub_rc=0; [[ "$case_name" == "fail" ]] && stub_rc=1
        printf '#!/bin/bash\necho "VERIFY-CALLED confirmed=${SF_VERIFY_CONFIRMED:-} cwd=$(basename "$PWD")" >> "%s/verify.log"\nexit %s\n' "$mb" "$stub_rc" \
            > "$mock_home/sf-tools/phases/init/verify.sh"
        chmod +x "$mock_home/sf-tools/phases/init/verify.sh"
        export MOCK_SF_ORG_JSON='{"result":{"username":"admin@example.com","alias":"x"}}'
        export SF_INIT_JWT_INTERVAL=0 SF_INIT_VERIFY_ASK=1

        input=$(E2E_PAT_TOKEN=ghp_fakepat E2E_SLACK_BOT_TOKEN=xoxb-fakeslack E2E_SLACK_CHANNEL_ID=C01ABCDEFGH \
                bash -c "source '$SF_TOOLS_DIR/tests/e2e/lib.sh'; e2e_make_input")
        case "$case_name" in
            enter|fail) answer=$'\n' ;;
            skip)       answer=$'s\n' ;;
            eof)        answer="" ;;
        esac
        printf '%s\n%s' "$input" "$answer" \
            | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
                  bash "$mock_home/sf-tools/bin/sf-init.sh" ) > "$mb/out.log" 2>&1
        exit_code=$?

        assert_exit_ok "$exit_code" "${case_name}: sf-init は、正常終了する（確認の結果は、セットアップの成否に、影響しない）"
        assert_file_contains "$mb/out.log" "ステップ 9 / 9: 動作の確認" "${case_name}: ステップ 9 の見出しが、表示される"
        case "$case_name" in
            enter)
                assert_file_contains "$mb/verify.log" "VERIFY-CALLED" "enter: verify.sh が呼ばれる"
                assert_file_contains "$mb/verify.log" "confirmed=1" "enter: 確認は、二重に聞かない（SF_VERIFY_CONFIRMED=1）"
                assert_file_contains "$mb/verify.log" "cwd=force-testproject" "enter: 管理者用のフォルダ（force-*）で実行される"
                assert_file_contains "$mb/out.log" "動作の確認: 成功しました" "enter: 完了画面に、成功が表示される"
                ;;
            skip)
                assert_file_not_exists "$mb/verify.log" "skip: verify.sh は、呼ばれない"
                assert_file_contains "$mb/out.log" "動作の確認は、あとで行えます" "skip: あとで実行するコマンドが、表示される"
                ;;
            eof)
                assert_file_not_exists "$mb/verify.log" "eof: 標準入力が閉じていれば、あとで、とする（呼ばれない）"
                assert_file_contains "$mb/out.log" "動作の確認は、あとで行えます" "eof: あとで実行するコマンドが、表示される"
                ;;
            fail)
                assert_file_contains "$mb/verify.log" "VERIFY-CALLED" "fail: verify.sh が呼ばれる"
                assert_file_contains "$mb/out.log" "失敗した項目があります" "fail: 完了画面に、失敗と案内が、表示される"
                assert_file_contains "$mb/out.log" "sf-init.sh --verify --cleanup" "fail: 削除のみのやり直しが、案内される"
                ;;
        esac
        unset MOCK_SF_ORG_JSON SF_INIT_JWT_INTERVAL SF_INIT_VERIFY_ASK MOCK_CALL_LOG
        teardown "$mb" "$mock_home" "$init_base"
    done

    # 端末でも、SF_INIT_VERIFY_ASK でもない（テスト・e2e・パイプ）: 聞かない（確認の質問が、入力を奪わない）
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"
    create_all_mocks "$mb"; create_mock_gh_for_init "$mb"; _stub_subscripts "$mock_home"
    printf '#!/bin/bash\necho CALLED >> "%s/verify.log"\n' "$mb" > "$mock_home/sf-tools/phases/init/verify.sh"
    chmod +x "$mock_home/sf-tools/phases/init/verify.sh"
    export MOCK_SF_ORG_JSON='{"result":{"username":"admin@example.com","alias":"x"}}' SF_INIT_JWT_INTERVAL=0
    input=$(E2E_PAT_TOKEN=ghp_fakepat E2E_SLACK_BOT_TOKEN=xoxb-fakeslack E2E_SLACK_CHANNEL_ID=C01ABCDEFGH \
            bash -c "source '$SF_TOOLS_DIR/tests/e2e/lib.sh'; e2e_make_input")
    printf '%s\n\n' "$input" \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" ) > "$mb/out.log" 2>&1
    exit_code=$?
    assert_exit_ok "$exit_code" "非対話: 正常終了する"
    assert_file_not_contains "$mb/out.log" "動作を確認しますか" "非対話（端末ではない）: 質問を出さない"
    assert_file_not_exists "$mb/verify.log" "非対話: verify.sh を呼ばない"
    assert_file_contains "$mb/out.log" "動作の確認は、あとで行えます" "非対話: あとで実行するコマンドを、案内する"
    unset MOCK_SF_ORG_JSON SF_INIT_JWT_INTERVAL MOCK_CALL_LOG
    teardown "$mb" "$mock_home" "$init_base"
}

test_wf_propagate_skip_missing_branch() {
    echo ""; echo -e "${CLR_HEAD}[TEST] wf-propagate: staging / develop がなければスキップ、あれば伝播する${CLR_RST}"
    local base; base=$(mktemp -d "${TMPDIR:-/tmp}/test-wfp-XXXX")
    local g="git -c user.name=t -c user.email=t@example.com"
    # origin（main だけ）と、その clone（Actions のチェックアウト相当）
    git init -q --bare "$base/origin.git" 2>/dev/null
    git clone -q "$base/origin.git" "$base/seed" 2>/dev/null
    ( cd "$base/seed" && git checkout -q -b main 2>/dev/null; echo a > a.txt; git add a.txt; $g commit -q -m init; git push -q origin main 2>/dev/null )
    git clone -q "$base/origin.git" "$base/work" 2>/dev/null
    local sc out rc

    # --- ブランチがない: 失敗にせず、スキップする ---
    sc="$base/step.sh"
    local b
    for b in staging develop; do
        _wfp_step_script "merge_${b}" > "$sc"
        [[ -s "$sc" ]] && pass "${b}: ステップの本文を取り出せた" || fail "${b}: ステップの本文を取り出せた"
        : > "$base/out.txt"
        out=$( cd "$base/work" && GITHUB_OUTPUT="$base/out.txt" bash -e "$sc" 2>&1 ); rc=$?
        assert_exit_ok "$rc"                                             "${b} がない → 失敗にならない（終了コード 0）"
        assert_file_contains "$base/out.txt" "result=skipped"            "${b} がない → result=skipped を出力する"
        assert_output_contains "$out" "${b} ブランチがないため"          "${b} がない → スキップの旨を表示する"
        if echo "$out" | grep -q "pathspec"; then fail "${b} がない → git checkout のエラーは出ない"; else pass "${b} がない → git checkout のエラーは出ない"; fi
    done

    # --- ブランチがある: main の変更を伝播する ---
    ( cd "$base/seed" && git checkout -q -b staging 2>/dev/null; git push -q origin staging 2>/dev/null; git checkout -q main; echo b > b.txt; git add b.txt; $g commit -q -m "main の変更"; git push -q origin main 2>/dev/null )
    ( cd "$base/work" && git fetch -q origin 2>/dev/null )
    _wfp_step_script merge_staging > "$sc"
    : > "$base/out.txt"
    out=$( cd "$base/work" && GITHUB_OUTPUT="$base/out.txt" bash -e -c "git config user.name t; git config user.email t@example.com; source '$sc'" 2>&1 ); rc=$?
    assert_exit_ok "$rc"                                                 "staging がある → 伝播できる（終了コード 0）"
    assert_file_contains "$base/out.txt" "result=success"                "staging がある → result=success を出力する"
    [[ "$(git -C "$base/origin.git" show staging:b.txt 2>/dev/null)" == "b" ]] \
        && pass "staging がある → main の変更が origin の staging に入った" || fail "staging がある → main の変更が origin の staging に入った"
    assert_file_contains "$SF_TOOLS_DIR/templates/.github/workflows/wf-propagate.yml" 'steps.merge_staging.outputs.result == '"'conflict'" "コンフリクトの判定（conflict）は、そのまま残っている"
    teardown "$base"
}

# ==============================================================================
# テスト 27: 起動時に確認済みのブランチと、選んだ環境が違う → Phase 2 で、ブランチ違いだけを確認する（二重に更新を確認しない）
# ==============================================================================
test_sf_tools_branch_mismatch() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 現在のブランチ（main）と、選んだ環境（検証 = development）が違う → 確認 → N で中断${CLR_RST}"

    local mb mock_home init_base init_dir exit_code out base
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"
    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    rm -f "$mb/git"   # 本物の git で、ブランチを判定する
    out="$mb/out.log"

    base=$(mktemp -d "${TMPDIR:-/tmp}/test-mismatch-XXXX")
    export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
    (
        cd "$mock_home/sf-tools" || exit 1
        # core.precomposeunicode: macOS の tar は、日本語のファイル名を NFD に変えて展開する。HOME を差し替えて実行すると、
        #   ~/.gitconfig の設定が効かず、同じファイルが「未追跡」に見える（未コミットの変更ありと判定される）ため、リポジトリに設定する
        git init -q -b main && git config core.precomposeunicode true && printf 'logs/\n' >> .git/info/exclude
        git add -A && git commit -qm base
        git init -q --bare -b main "$base/origin.git"
        git remote add origin "$base/origin.git" && git push -q origin main
    ) > /dev/null 2>&1

    # 入力: Y=開始の確認 / Y=プロジェクトの確認 / 2=検証環境 / Y=検証環境で続行 / N=ブランチ違いのまま続行しない
    printf 'Y\nY\n2\nY\nN\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" ) > "$out" 2>&1
    exit_code=$?

    assert_exit_fail          "$exit_code"                                                    "ブランチ違い + N → 中断する"
    assert_file_contains      "$out" "sf-tools（main）は最新です"                              "起動時に、現在のブランチの最新化が確認される"
    assert_file_contains      "$out" "ローカルの sf-tools は main ブランチですが、選択した環境は development です" "ブランチ違いが表示される"
    assert_equals "$(grep -c 'は最新です' "$out")" "1"                                        "最新化の確認は、1 回だけ（Phase 2 で、二重に確認しない）"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh repo create"                              "中断したので、リポジトリを作らない"

    unset MOCK_CALL_LOG
    teardown "$mb" "$mock_home" "$init_base" "$base"
}

# ==============================================================================
# テスト 28: Phase 2 が sf-tools を更新した（終了コード 75）→ 作業フォルダに戻り、ロックを解放してから、実行しなおす
# ==============================================================================
# 回帰: 以前は、admin/ に移動したまま、ロックも残したまま exec していたため、実行しなおした側が、実行場所の確認
#       （admin の中では実行できない）か、ロック（同じ PID を「実行中」と判定）で、必ず終了していた
test_restart_after_phase2_update() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] Phase 2 の終了コード 75 → 作業フォルダから、ロックなしで、実行しなおす${CLR_RST}"

    local mb mock_home init_base init_dir exit_code out p2
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"
    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    out="$mb/out.log"
    p2="$mock_home/sf-tools/phases/init/02_project_info.sh"

    # Phase 2 の差し替え: 1 回目は 75（sf-tools を更新した）、2 回目以降は 0
    cat > "$p2" << 'P2EOF'
#!/bin/bash
echo "phase2-stub" >> "$MOCK_CALL_LOG"
_s="${MOCK_CALL_LOG%/*}/.phase2_called"
if [[ ! -f "$_s" ]]; then : > "$_s"; exit 75; fi
exit 0
P2EOF
    # 入力: Y = 続行しますか？（1 回目）/ Y = 続行しますか？（実行しなおした後）
    printf 'Y\nY\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --only 2 ) > "$out" 2>&1
    exit_code=$?

    assert_exit_ok            "$exit_code"                                                  "75 → 実行しなおして、正常終了する"
    assert_file_contains      "$out" "もう一度、はじめから実行します"                         "実行しなおすことを表示する"
    assert_file_not_contains  "$out" "中では実行できません"                                   "実行しなおした側が、admin の中と判定されない"
    assert_file_not_contains  "$out" "すでに実行中です"                                       "実行しなおした側が、残ったロックで止まらない"
    assert_equals "$(grep -c 'phase2-stub' "$MOCK_CALL_LOG")" "2"                           "Phase 2 が、実行しなおした後にも、実行される"
    assert_dir_not_exists     "$init_dir/admin/.sf-init-testproject.lock"                   "終了後に、ロックが残らない"
    assert_dir_not_exists     "$init_dir/admin/admin"                                       "admin の中に、admin を作らない"

    # 実行しなおしても、まだ 75 → 2 回目は、実行しなおさずに終了する（無限に繰り返さない）
    printf '#!/bin/bash\necho "phase2-stub" >> "$MOCK_CALL_LOG"\nexit 75\n' > "$p2"
    : > "$MOCK_CALL_LOG"
    printf 'Y\nY\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --only 2 ) > "$out" 2>&1
    exit_code=$?
    assert_exit_fail          "$exit_code"                                                  "75 が続く → 異常終了する"
    assert_file_contains      "$out" "sf-tools を更新しても、最新になりませんでした"          "75 が続く → 理由を表示する"
    assert_equals "$(grep -c 'phase2-stub' "$MOCK_CALL_LOG")" "2"                           "75 が続く → 実行しなおしは 1 回だけ"
    assert_dir_not_exists     "$init_dir/admin/.sf-init-testproject.lock"                   "75 が続く → ロックが残らない"

    unset MOCK_CALL_LOG
    teardown "$mb" "$mock_home" "$init_base"
}

# ==============================================================================
# テスト 29: 最初のステップ（ステップ 1）の見出しに、「完了」の一覧を出さない（macOS の seq 1 0 は、1 0 と逆順に出る）
# ==============================================================================
# 回帰: _show_step_header が seq 1 0 を呼び、macOS（BSD）では「（完了: 準備の確認・）」と表示していた。
#       BSD と同じ動き（開始 > 終了なら、逆順に出す）の seq を、PATH の先頭に置いて確かめる
test_step_header_first_step() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] ステップ 1 の見出しに、完了の一覧を出さない（BSD の seq でも）${CLR_RST}"
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/platform.sh"   # run_with_timeout

    local mb mock_home init_base init_dir out
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"
    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    _stub_subscripts "$mock_home"
    out="$mb/out.log"
    cat > "$mb/seq" << 'SEQEOF'
#!/bin/bash
# BSD の seq の動き: 引数 1 つは 1〜N。開始 > 終了なら、逆順に出す
if [[ $# -eq 1 ]]; then a=1; b=$1; else a=$1; b=$2; fi
if (( a <= b )); then i=$a; while (( i <= b )); do echo "$i"; i=$((i + 1)); done
else i=$a; while (( i >= b )); do echo "$i"; i=$((i - 1)); done; fi
SEQEOF
    chmod +x "$mb/seq"

    # 入力: Enter = 開始画面の確認。以降は入力なし（Phase 2 の確認で、EOF で終了する）
    printf '\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              run_with_timeout 60 bash "$mock_home/sf-tools/bin/sf-init.sh" ) > "$out" 2>&1

    assert_file_contains      "$out" "ステップ 1 / 9"                                        "ステップ 1 の見出しが出る"
    assert_file_not_contains  "$out" "完了: 準備の確認・）"                                   "ステップ 1 に、完了の一覧（準備の確認・）を出さない"

    unset MOCK_CALL_LOG
    teardown "$mb" "$mock_home" "$init_base"
}

# ==============================================================================
# テスト 30: 後処理の条件（完了の印を付けられない → 状態ファイルを残す / 同期・admin ブランチを行わなかった理由）
# ==============================================================================
# 回帰: 以前は、完了の印を付けられなくても、状態ファイルを消していた（_finish_unfinished_setup は残す。扱いが違った）。
#       --only 10 でも、同期の行に「途中までの実行のため」と出ていた（最後まで実行している）
test_postprocess_conditions() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 後処理: 印を付けられない → 状態ファイルを残す / 同期しなかった理由を正しく出す${CLR_RST}"

    local mb mock_home init_base init_dir exit_code out
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    out="$mb/out.log"
    # Phase 10 の差し替え（接続の処理は、このテストの対象外）
    printf '#!/bin/bash\necho "phase10-stub" >> "$MOCK_CALL_LOG"\nexit 0\n' > "$mock_home/sf-tools/phases/init/10_sf_auth.sh"

    # --- A. --resume 10・状態ファイルに REPO_DIR がない → 印を付けられない → 状態ファイルを残す ---
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"
    mkdir -p "$init_dir/admin"
    printf 'REPO_FULL_NAME="tamashimon/force-testproject"\nREPO_NAME="force-testproject"\nPROJECT_NAME="testproject"\nBRANCH_COUNT="1"\n' \
        > "$init_dir/admin/.sf-init-testproject.env"
    printf 'Y\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --resume 10 ) > "$out" 2>&1
    exit_code=$?
    assert_exit_ok            "$exit_code"                                                  "REPO_DIR なし: 正常終了する"
    assert_file_contains      "$MOCK_CALL_LOG" "phase10-stub"                               "REPO_DIR なし: Phase 10 を実行する"
    assert_file_contains      "$out" "状態ファイルは、残します"                               "印を付けられない → 状態ファイルを残すと表示する"
    assert_file_exists        "$init_dir/admin/.sf-init-testproject.env"                    "印を付けられない → .env を残す"
    assert_file_exists        "$init_dir/admin/.sf-init-testproject.progress"               "印を付けられない → 進捗ファイルを残す"
    assert_file_contains      "$out" "REPO_DIR・REPO_FULL_NAME）がないため、メタデータの同期" "同期しなかった理由: 状態ファイルに REPO_DIR などがない"
    assert_file_contains      "$out" "クローンの場所（REPO_DIR）がないため"                   "admin ブランチにしなかった理由: REPO_DIR がない"
    assert_file_not_contains  "$out" "途中までの実行のため"                                   "最後まで実行したので、「途中まで」とは出さない"
    rm -rf "$init_base"

    # --- B. --only 10 → 同期の行は「--only の実行のため」（「途中までの実行のため」ではない）---
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"
    mkdir -p "$init_dir/admin"
    printf 'REPO_FULL_NAME="tamashimon/force-testproject"\nREPO_NAME="force-testproject"\nPROJECT_NAME="testproject"\nBRANCH_COUNT="1"\nREPO_DIR="%s"\n' \
        "$init_dir/admin/force-testproject" > "$init_dir/admin/.sf-init-testproject.env"
    printf 'Y\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --only 10 ) > "$out" 2>&1
    exit_code=$?
    assert_exit_ok            "$exit_code"                                                  "--only 10: 正常終了する"
    assert_file_contains      "$out" "--only の実行のため、メタデータの同期"                  "--only 10: 同期しなかった理由は --only"
    assert_file_not_contains  "$out" "途中までの実行のため、メタデータの同期"                 "--only 10: 「途中までの実行」とは出さない"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh workflow run"                            "--only 10: 同期（wf-metasync）は起動しない"
    rm -rf "$init_base"

    unset MOCK_CALL_LOG
    teardown "$mb" "$mock_home"
}

echo ""
echo -e "${CLR_HEAD}========================================"
echo "  sf-init.sh テスト（3/3）"
echo -e "========================================${CLR_RST}"

test_happy_path_3branches
test_flex_layout_with_args
test_phase3_existing_clone
test_admin_branch_created_from_main
test_completed_before_mark_existed
test_finish_skips_foreign_repo_dir
test_repo_visibility_private
test_only_phase2_creates_env_file
test_add_tier_staging_already_exists
test_env_type_selection
test_phase11_removed
test_phase10_eca_auto
test_verify_step
test_wf_propagate_skip_missing_branch
test_sf_tools_branch_mismatch
test_restart_after_phase2_update
test_step_header_first_step
test_postprocess_conditions

print_summary
