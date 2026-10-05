#!/bin/bash
# ==============================================================================
# test_sf-job.sh - sf-job.sh の単体テスト（モックベース）
# ==============================================================================
#
# 【テストケース】
#   1. ハッピーパス                         - フルフロー正常終了
#   2. フォルダからオーナー名自動取得        - REPO_FULL_NAME が正しく構成される
#   3. init フォルダから実行               - 環境チェックで失敗
#   4. force-* フォルダから実行            - 環境チェックで失敗
#   5. リポジトリが存在しない              - プロジェクト情報確認で失敗
#   6. ジョブ名ローカル重複                - WARNING → 再入力 → 正常終了
#   7. ジョブ名 GitHub ブランチ重複        - WARNING → 再入力 → 正常終了
#   8. 無効なジョブ名                      - WARNING → 再入力 → 正常終了
#   9. ブランチ作成失敗                    - 非ゼロ終了
#  10. クローン失敗                        - 非ゼロ終了
#  11. q で中断                            - 非ゼロ終了
# ==============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

# ==============================================================================
# ヘルパー：sf-job.sh 用の gh モックを作成
# ==============================================================================
create_mock_gh_for_job() {
    local bin_dir="$1"
    cat > "$bin_dir/gh" << 'EOF'
#!/bin/bash
echo "gh $*" >> "${MOCK_CALL_LOG:-/dev/null}"

# gh repo view OWNER/REPO --json name
if [[ "$1" == "repo" && "$2" == "view" ]]; then
    [[ "${MOCK_GH_REPO_VIEW_EXIT:-0}" != "0" ]] && { echo "not found" >&2; exit 1; }
    echo "{\"name\":\"${3##*/}\"}"
    exit 0
fi

# gh api repos/... 系
if [[ "$1" == "api" ]]; then
    # main ブランチは常に存在する
    [[ "$2" == */branches/main ]] && exit 0
    # ジョブブランチ存在チェック（デフォルト 1 = 存在しない）
    [[ "$2" == */branches/* ]] && exit "${MOCK_GH_BRANCH_EXISTS_EXIT:-1}"
    # ブランチ作成（デフォルト 0 = 成功）
    [[ "$2" == */git/refs ]]   && exit "${MOCK_GH_CREATE_BRANCH_EXIT:-0}"
fi

case "$1 $2" in
    "auth status") exit "${MOCK_GH_AUTH_STATUS_EXIT:-0}" ;;
    "auth login")  exit "${MOCK_GH_AUTH_LOGIN_EXIT:-0}" ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$bin_dir/gh"
}

# ==============================================================================
# ヘルパー：sf-start.sh / sf-launcher.sh をスタブ化
# ==============================================================================
_stub_job_subscripts() {
    local mock_home="$1"
    mkdir -p "$mock_home/sf-tools/bin"
    printf '#!/bin/bash\nexit 0\n' > "$mock_home/sf-tools/bin/sf-start.sh"
    chmod +x "$mock_home/sf-tools/bin/sf-start.sh"
    printf '#!/bin/bash\nexit 0\n' > "$mock_home/sf-tools/bin/sf-launcher.sh"
    chmod +x "$mock_home/sf-tools/bin/sf-launcher.sh"
}

# ==============================================================================
# ヘルパー：{github-owner}/{company}/ ディレクトリを作成して company パスを返す
# teardown には $(dirname "$(dirname "$(dirname "$cdir")") を渡すこと（home/ 階層を含む3段）
# ==============================================================================
setup_company_dir() {
    local github_owner="${1:-tamashimon-org}"
    local company="${2:-yamada}"
    local base
    base=$(mktemp -d "${TMPDIR:-/tmp}/test-cmp-XXXX")
    mkdir -p "$base/home/$github_owner/$company"
    echo "$base/home/$github_owner/$company"
}

# ==============================================================================
# テスト 1: ハッピーパス
# ==============================================================================
test_happy_path() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] ハッピーパス${CLR_RST}"

    local mb mock_home cdir
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home); cdir=$(setup_company_dir)

    create_mock_git "$mb"
    create_mock_gh_for_job "$mb"
    _stub_job_subscripts "$mock_home"

    local ec
    printf 'JOB-test\nY\n' \
        | (export HOME="$mock_home" PATH="$mb:$PATH"; cd "$cdir" && bash "$mock_home/sf-tools/bin/sf-job.sh") \
          > /dev/null 2>&1
    ec=$?

    assert_exit_ok  $ec                                     "正常終了する"
    assert_file_contains "$MOCK_CALL_LOG" "gh auth status"  "gh auth status が呼ばれる"
    assert_file_contains "$MOCK_CALL_LOG" "gh repo view"    "リポジトリ確認が呼ばれる"
    assert_file_contains "$MOCK_CALL_LOG" "git/refs"        "ブランチ作成 API が呼ばれる"
    assert_file_contains "$MOCK_CALL_LOG" "git clone"       "git clone が呼ばれる"
    assert_file_contains "$MOCK_CALL_LOG" "git clone -c core.longpaths=true" "git clone に core.longpaths=true が付く（Windows のパス長の上限対策）"

    teardown "$mb" "$mock_home" "$(dirname "$(dirname "$(dirname "$cdir")")")"
}

# ==============================================================================
# テスト 2: フォルダ名から GitHub オーナー名が自動取得される
# ==============================================================================
test_owner_auto_derive() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] フォルダ名から GitHub オーナー名を自動取得${CLR_RST}"

    local mb mock_home cdir
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    # 異なるオーナー名でフォルダを作成
    cdir=$(setup_company_dir "my-org-name" "yamada")

    create_mock_git "$mb"
    create_mock_gh_for_job "$mb"
    _stub_job_subscripts "$mock_home"

    local ec
    printf 'JOB-test\nY\n' \
        | (export HOME="$mock_home" PATH="$mb:$PATH"; cd "$cdir" && bash "$mock_home/sf-tools/bin/sf-job.sh") \
          > /dev/null 2>&1
    ec=$?

    assert_exit_ok  $ec                                                  "正常終了する"
    # REPO_FULL_NAME = my-org-name/force-yamada が使われていること
    assert_file_contains "$MOCK_CALL_LOG" "my-org-name/force-yamada"     "フォルダ名からオーナーが正しく導出される"

    teardown "$mb" "$mock_home" "$(dirname "$(dirname "$(dirname "$cdir")")")"
}

# ==============================================================================
# テスト 3: init フォルダから実行 → エラー
# ==============================================================================
test_from_init_dir() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] init フォルダから実行 → エラー${CLR_RST}"

    local mb mock_home base init_dir
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    base=$(mktemp -d "${TMPDIR:-/tmp}/test-init-XXXX")
    init_dir="$base/init"
    mkdir -p "$init_dir"

    create_mock_gh_for_job "$mb"
    _stub_job_subscripts "$mock_home"

    local ec
    printf 'q\n' \
        | (export HOME="$mock_home" PATH="$mb:$PATH"; cd "$init_dir" && bash "$mock_home/sf-tools/bin/sf-job.sh") \
          > /dev/null 2>&1
    ec=$?

    assert_exit_fail $ec "init フォルダ → エラー終了"

    teardown "$mb" "$mock_home" "$base"
}

# ==============================================================================
# テスト 4: force-* フォルダから実行 → エラー
# ==============================================================================
test_from_force_dir() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] force-* フォルダから実行 → エラー${CLR_RST}"

    local mb mock_home base force_dir
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    base=$(mktemp -d "${TMPDIR:-/tmp}/test-frc-XXXX")
    force_dir="$base/force-yamada"
    mkdir -p "$force_dir"

    create_mock_gh_for_job "$mb"
    _stub_job_subscripts "$mock_home"

    local ec
    printf 'q\n' \
        | (export HOME="$mock_home" PATH="$mb:$PATH"; cd "$force_dir" && bash "$mock_home/sf-tools/bin/sf-job.sh") \
          > /dev/null 2>&1
    ec=$?

    assert_exit_fail $ec "force-* フォルダ → エラー終了"

    teardown "$mb" "$mock_home" "$base"
}

# ==============================================================================
# テスト 5: リポジトリが存在しない → エラー
# ==============================================================================
test_repo_not_found() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] リポジトリが存在しない → エラー${CLR_RST}"

    local mb mock_home cdir
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home); cdir=$(setup_company_dir)

    create_mock_gh_for_job "$mb"
    _stub_job_subscripts "$mock_home"
    export MOCK_GH_REPO_VIEW_EXIT=1

    local ec
    printf 'q\n' \
        | (export HOME="$mock_home" PATH="$mb:$PATH" MOCK_GH_REPO_VIEW_EXIT="$MOCK_GH_REPO_VIEW_EXIT"; \
           cd "$cdir" && bash "$mock_home/sf-tools/bin/sf-job.sh") \
          > /dev/null 2>&1
    ec=$?

    assert_exit_fail $ec "リポジトリ未発見 → エラー終了"

    unset MOCK_GH_REPO_VIEW_EXIT
    teardown "$mb" "$mock_home" "$(dirname "$(dirname "$(dirname "$cdir")")")"
}

# ==============================================================================
# テスト 6: ジョブ名ローカル重複 → WARNING & 再入力
# ==============================================================================
test_local_job_dir_duplicate() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] ジョブ名ローカル重複 → WARNING & 再入力${CLR_RST}"

    local mb mock_home cdir
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home); cdir=$(setup_company_dir)

    create_mock_git "$mb"
    create_mock_gh_for_job "$mb"
    _stub_job_subscripts "$mock_home"

    mkdir -p "$cdir/JOB-existing"

    local ec out
    out=$(printf 'JOB-existing\nJOB-newname\nY\n' \
        | (export HOME="$mock_home" PATH="$mb:$PATH"; cd "$cdir" && bash "$mock_home/sf-tools/bin/sf-job.sh") 2>&1)
    ec=$?

    assert_exit_ok $ec "重複後に新しい名前で正常終了"
    assert_output_contains "$out" "すでに存在します" "ローカル重複 WARNING が表示される"
    assert_file_contains "$MOCK_CALL_LOG" "git clone" "git clone が呼ばれる"

    teardown "$mb" "$mock_home" "$(dirname "$(dirname "$(dirname "$cdir")")")"
}

# ==============================================================================
# テスト 7: ジョブ名 GitHub ブランチ重複 → WARNING & 再入力
# ==============================================================================
test_github_branch_duplicate() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] ジョブ名 GitHub ブランチ重複 → WARNING & 再入力${CLR_RST}"

    local mb mock_home cdir
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home); cdir=$(setup_company_dir)

    # JOB-existing → ブランチあり(exit 0)、JOB-newname → ブランチなし(exit 1)
    cat > "$mb/gh" << 'EOF'
#!/bin/bash
echo "gh $*" >> "${MOCK_CALL_LOG:-/dev/null}"
if [[ "$1" == "repo" && "$2" == "view" ]]; then echo '{"name":"force-yamada"}'; exit 0; fi
if [[ "$1" == "api" && "$2" == */branches/main ]]; then exit 0; fi
if [[ "$1" == "api" && "$2" == */branches/* ]]; then
    [[ "$2" == *"existing"* ]] && exit 0 || exit 1
fi
if [[ "$1" == "api" && "$2" == */git/refs ]]; then exit 0; fi
case "$1 $2" in "auth status") exit 0 ;; *) exit 0 ;; esac
EOF
    chmod +x "$mb/gh"

    create_mock_git "$mb"
    _stub_job_subscripts "$mock_home"

    local ec out
    out=$(printf 'JOB-existing\nJOB-newname\nY\n' \
        | (export HOME="$mock_home" PATH="$mb:$PATH"; cd "$cdir" && bash "$mock_home/sf-tools/bin/sf-job.sh") 2>&1)
    ec=$?

    assert_exit_ok $ec "ブランチ重複後に新しい名前で正常終了"
    assert_output_contains "$out" "すでに同名のブランチ" "GitHub ブランチ重複 WARNING が表示される"

    teardown "$mb" "$mock_home" "$(dirname "$(dirname "$(dirname "$cdir")")")"
}

# ==============================================================================
# テスト 8: 無効なジョブ名 → WARNING & 再入力
# ==============================================================================
test_invalid_job_name() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 無効なジョブ名 → WARNING & 再入力${CLR_RST}"

    local mb mock_home cdir
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home); cdir=$(setup_company_dir)

    create_mock_git "$mb"
    create_mock_gh_for_job "$mb"
    _stub_job_subscripts "$mock_home"

    local ec out
    out=$(printf 'JOB INVALID\nJOB-valid\nY\n' \
        | (export HOME="$mock_home" PATH="$mb:$PATH"; cd "$cdir" && bash "$mock_home/sf-tools/bin/sf-job.sh") 2>&1)
    ec=$?

    assert_exit_ok $ec "無効な名前の後に有効な名前で正常終了"
    assert_output_contains "$out" "無効なジョブ名" "無効なジョブ名 WARNING が表示される"

    teardown "$mb" "$mock_home" "$(dirname "$(dirname "$(dirname "$cdir")")")"
}

# ==============================================================================
# テスト 9: ブランチ作成失敗 → エラー
# ==============================================================================
test_branch_create_failure() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] ブランチ作成失敗 → エラー${CLR_RST}"

    local mb mock_home cdir
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home); cdir=$(setup_company_dir)

    create_mock_git "$mb"
    create_mock_gh_for_job "$mb"
    _stub_job_subscripts "$mock_home"
    export MOCK_GH_CREATE_BRANCH_EXIT=1

    local ec
    printf 'JOB-test\nY\n' \
        | (export HOME="$mock_home" PATH="$mb:$PATH" MOCK_GH_CREATE_BRANCH_EXIT="$MOCK_GH_CREATE_BRANCH_EXIT"; \
           cd "$cdir" && bash "$mock_home/sf-tools/bin/sf-job.sh") \
          > /dev/null 2>&1
    ec=$?

    assert_exit_fail $ec "ブランチ作成失敗 → エラー終了"

    unset MOCK_GH_CREATE_BRANCH_EXIT
    teardown "$mb" "$mock_home" "$(dirname "$(dirname "$(dirname "$cdir")")")"
}

# ==============================================================================
# テスト 10: クローン失敗 → エラー
# ==============================================================================
test_clone_failure() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] クローン失敗 → エラー${CLR_RST}"

    local mb mock_home cdir
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home); cdir=$(setup_company_dir)

    create_mock_git "$mb"
    create_mock_gh_for_job "$mb"
    _stub_job_subscripts "$mock_home"
    export MOCK_GIT_CLONE_EXIT=1

    local ec
    printf 'JOB-test\nY\n' \
        | (export HOME="$mock_home" PATH="$mb:$PATH" MOCK_GIT_CLONE_EXIT="$MOCK_GIT_CLONE_EXIT"; \
           cd "$cdir" && bash "$mock_home/sf-tools/bin/sf-job.sh") \
          > /dev/null 2>&1
    ec=$?

    assert_exit_fail $ec "クローン失敗 → エラー終了"

    unset MOCK_GIT_CLONE_EXIT
    teardown "$mb" "$mock_home" "$(dirname "$(dirname "$(dirname "$cdir")")")"
}

# ==============================================================================
# テスト 11: q で中断 → エラー終了
# ==============================================================================
test_quit_with_q() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] q で中断 → エラー終了${CLR_RST}"

    local mb mock_home cdir
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home); cdir=$(setup_company_dir)

    create_mock_gh_for_job "$mb"
    _stub_job_subscripts "$mock_home"

    local ec
    printf 'q\n' \
        | (export HOME="$mock_home" PATH="$mb:$PATH"; cd "$cdir" && bash "$mock_home/sf-tools/bin/sf-job.sh") \
          > /dev/null 2>&1
    ec=$?

    assert_exit_fail $ec "q 入力 → 中断終了"

    teardown "$mb" "$mock_home" "$(dirname "$(dirname "$(dirname "$cdir")")")"
}

# ==============================================================================
# テスト実行
# ==============================================================================
echo ""
echo -e "${CLR_HEAD}========================================"
echo "  sf-job.sh テスト"
echo -e "========================================${CLR_RST}"

test_happy_path
test_owner_auto_derive
test_from_init_dir
test_from_force_dir
test_repo_not_found
test_local_job_dir_duplicate
test_github_branch_duplicate
test_invalid_job_name
test_branch_create_failure
test_clone_failure
test_quit_with_q

print_summary
