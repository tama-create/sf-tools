#!/bin/bash
# ==============================================================================
# test_sf-job.sh - sf-job.sh の単体テスト（モックベース）
# ==============================================================================
#
# 【テストケース】
#   1. ハッピーパス                         - フルフロー正常終了
#   4. force-* フォルダから実行            - 環境チェックで失敗
#   5. リポジトリが存在しない              - プロジェクト情報確認で失敗
#   6. ジョブ名ローカル重複                - WARNING → 再入力 → 正常終了
#   7. ジョブ名 GitHub ブランチ重複        - WARNING → 再入力 → 正常終了
#   8. 無効なジョブ名                      - WARNING → 再入力 → 正常終了
#   9. ブランチ作成失敗                    - 非ゼロ終了
#  10. クローン失敗                        - 非ゼロ終了
#  11. q で中断                            - 非ゼロ終了
#  12. --name                              - 入力を聞かない・合わない名前は再入力せずに中断（doc/ai-operation-design.md 11.3）
#  13. AI 操作（SF_TOOLS_AI=1）            - job.existing・job.create・sf-start を動かさない・gh auth login を動かさない
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
    "api user")    [[ -n "${MOCK_GH_API_USER:-}" ]] && echo "$MOCK_GH_API_USER"; exit 0 ;;   # 未設定なら、ユーザー名を返さない
    *) exit 0 ;;
esac
EOF
    chmod +x "$bin_dir/gh"
}

# ==============================================================================
# ヘルパー：sf-start.sh / メニュー（phases/start/launcher.sh）をスタブ化
# ==============================================================================
_stub_job_subscripts() {
    local mock_home="$1"
    mkdir -p "$mock_home/sf-tools/bin" "$mock_home/sf-tools/phases/start"
    printf '#!/bin/bash\nexit 0\n' > "$mock_home/sf-tools/bin/sf-start.sh"
    chmod +x "$mock_home/sf-tools/bin/sf-start.sh"
    printf '#!/bin/bash\nexit 0\n' > "$mock_home/sf-tools/phases/start/launcher.sh"
    chmod +x "$mock_home/sf-tools/phases/start/launcher.sh"
}

# ==============================================================================
# ヘルパー：作業フォルダを作成してパスを返す（フォルダ名に意味はない。オーナーと XXXX は、引数で渡す）
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
        | (export HOME="$mock_home" PATH="$mb:$PATH"; cd "$cdir" && bash "$mock_home/sf-tools/bin/sf-job.sh" --owner tamashimon-org --project yamada) \
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
# 回帰: オーナーでも組織の管理者でもない開発者も、実行できる（sf-job は開発者向けのコマンド）
#   （以前は、オーナー権限の確認で中断し、開発者は、実行できなかった）
# ==============================================================================
test_developer_not_owner_can_run() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] オーナーでも管理者でもない開発者が、実行できる${CLR_RST}"

    local mb mock_home cdir
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home); cdir=$(setup_company_dir)

    create_mock_git "$mb"
    create_mock_gh_for_job "$mb"
    _stub_job_subscripts "$mock_home"

    local ec out
    out=$(printf 'JOB-dev
Y
'         | (export HOME="$mock_home" PATH="$mb:$PATH" MOCK_GH_API_USER="some-developer"; cd "$cdir" && bash "$mock_home/sf-tools/bin/sf-job.sh" --owner tamashimon-org --project yamada) 2>&1)
    ec=$?

    assert_exit_ok  $ec                                          "gh のユーザーがオーナーと違っても、正常終了する"
    assert_file_contains "$MOCK_CALL_LOG" "git clone"            "git clone が呼ばれる"
    assert_file_not_contains "$MOCK_CALL_LOG" "memberships/orgs" "組織の管理者かどうかは、問い合わせない"
    echo "$out" | grep -q "管理者（admin）でもありません"         && fail "オーナー権限の拒否が、出ない" "拒否のメッセージが出た"         || pass "オーナー権限の拒否が、出ない"

    teardown "$mb" "$mock_home" "$(dirname "$(dirname "$(dirname "$cdir")")")"
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
           cd "$cdir" && bash "$mock_home/sf-tools/bin/sf-job.sh" --owner tamashimon-org --project yamada) \
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

    mkdir -p "$cdir/JOB-existing/force-yamada"   # 同じジョブ名のフォルダに、同じプロジェクトのクローンがある

    local ec out
    out=$(printf 'JOB-existing\nJOB-newname\nY\n' \
        | (export HOME="$mock_home" PATH="$mb:$PATH"; cd "$cdir" && bash "$mock_home/sf-tools/bin/sf-job.sh" --owner tamashimon-org --project yamada) 2>&1)
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
    out=$(printf 'JOB-existing\nN\nJOB-newname\nY\n' \
        | (export HOME="$mock_home" PATH="$mb:$PATH"; cd "$cdir" && bash "$mock_home/sf-tools/bin/sf-job.sh" --owner tamashimon-org --project yamada) 2>&1)
    ec=$?

    assert_exit_ok $ec "ブランチ重複後に新しい名前で正常終了"
    assert_output_contains "$out" "すでに同名のブランチ" "GitHub ブランチ重複 WARNING が表示される"

    teardown "$mb" "$mock_home" "$(dirname "$(dirname "$(dirname "$cdir")")")"
}

# ==============================================================================
# テスト 7b: 同名のブランチが GitHub にある → 続ける（Y）なら、ブランチを作らず、clone する / 環境ブランチの名前は使えない
#   結合テスト X2-2 で見つかった: 以前は、ブランチ作成のあとに clone が失敗すると、同じジョブ名では、続けられなかった
# ==============================================================================
test_github_branch_resume() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 同名のブランチが GitHub にある → 続ける（Y）/ 環境ブランチの名前は拒否${CLR_RST}"

    local mb mock_home cdir ec out
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home); cdir=$(setup_company_dir)
    cat > "$mb/gh" << 'GHEOF'
#!/bin/bash
echo "gh $*" >> "${MOCK_CALL_LOG:-/dev/null}"
if [[ "$1" == "repo" && "$2" == "view" ]]; then echo '{"name":"force-yamada"}'; exit 0; fi
if [[ "$1" == "api" && "$2" == */branches/main ]]; then exit 0; fi
if [[ "$1" == "api" && "$2" == */branches/* ]]; then
    [[ "$2" == *"existing"* ]] && { echo "Tama / 2026-10-19T00:00:00Z"; exit 0; } || exit 1
fi
exit 0
GHEOF
    chmod +x "$mb/gh"
    create_mock_git "$mb"
    _stub_job_subscripts "$mock_home"

    # Y: 既存のブランチを使う（作成の API は、呼ばない）。最後のコミットの作者が、表示される
    out=$(printf 'JOB-existing\nY\nY\n' \
        | (export HOME="$mock_home" PATH="$mb:$PATH"; cd "$cdir" && bash "$mock_home/sf-tools/bin/sf-job.sh" --owner tamashimon-org --project yamada) 2>&1)
    ec=$?
    assert_exit_ok $ec "同名のブランチがあり、続ける（Y）→ 正常終了"
    assert_output_contains "$out" "最後のコミット: Tama" "最後のコミットの作者・日時が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs" "続ける（Y）→ ブランチの作成の API を呼ばない"
    assert_file_contains "$MOCK_CALL_LOG" "git clone" "続ける（Y）→ clone する"
    assert_file_contains "$MOCK_CALL_LOG" "--branch JOB-existing" "続ける（Y）→ 既存のブランチを clone する"

    # 環境ブランチ・管理者用のブランチの名前は、使えない（同名のブランチが、すでにあり、続けてしまわないため）
    : > "$MOCK_CALL_LOG"
    out=$(printf 'main\nadmin\nstaging\nq\n' \
        | (export HOME="$mock_home" PATH="$mb:$PATH"; cd "$cdir" && bash "$mock_home/sf-tools/bin/sf-job.sh" --owner tamashimon-org --project yamada) 2>&1)
    assert_output_contains "$out" "環境ブランチ・管理者用のブランチの名前のため、使えません: main" "main は、ジョブ名に使えない"
    assert_output_contains "$out" "使えません: admin" "admin は、ジョブ名に使えない"
    assert_output_contains "$out" "使えません: staging" "staging は、ジョブ名に使えない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs" "環境ブランチの名前では、ブランチを作らない"

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
        | (export HOME="$mock_home" PATH="$mb:$PATH"; cd "$cdir" && bash "$mock_home/sf-tools/bin/sf-job.sh" --owner tamashimon-org --project yamada) 2>&1)
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
           cd "$cdir" && bash "$mock_home/sf-tools/bin/sf-job.sh" --owner tamashimon-org --project yamada) \
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
           cd "$cdir" && bash "$mock_home/sf-tools/bin/sf-job.sh" --owner tamashimon-org --project yamada) \
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
        | (export HOME="$mock_home" PATH="$mb:$PATH"; cd "$cdir" && bash "$mock_home/sf-tools/bin/sf-job.sh" --owner tamashimon-org --project yamada) \
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

# ==============================================================================
# フォルダ構成に頼らない（任意の作業フォルダ）のテスト
#   リポジトリ名は force-XXXX。オーナーと XXXX は、引数・クローンの git remote・対話で決める
# ==============================================================================
_setup_flex_dir() {
    local base; base=$(mktemp -d "${TMPDIR:-/tmp}/test-flex-XXXX")
    mkdir -p "$base/work"
    echo "$base/work"
}

test_flex_args() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 任意の作業フォルダ + --owner / --project → 入力なしで決まる${CLR_RST}"

    local mb mock_home wdir
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home); wdir=$(_setup_flex_dir)
    create_mock_git "$mb"; create_mock_gh_for_job "$mb"; _stub_job_subscripts "$mock_home"

    local ec
    printf 'JOB-test\nY\n' \
        | (export HOME="$mock_home" PATH="$mb:$PATH"; cd "$wdir" && bash "$mock_home/sf-tools/bin/sf-job.sh" --owner my-org --project force-acme) \
          > /dev/null 2>&1
    ec=$?

    assert_exit_ok $ec                                                      "任意の作業フォルダで、引数を指定すると、正常終了する"
    assert_file_contains "$MOCK_CALL_LOG" "my-org/force-acme"               "引数のオーナーと XXXX（force- は除く）で、リポジトリを扱う"
    assert_file_contains "$MOCK_CALL_LOG" "git clone"                       "git clone が呼ばれる"
    assert_file_contains "$MOCK_CALL_LOG" "$wdir/JOB-test/force-acme"       "クローン先は、{作業フォルダ}/{ジョブ名}/force-XXXX"

    teardown "$mb" "$mock_home" "$(dirname "$wdir")"
}

test_flex_prompt() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 任意の作業フォルダ・クローンなし → 対話（オーナーと XXXX を入力）${CLR_RST}"

    local mb mock_home wdir
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home); wdir=$(_setup_flex_dir)
    create_mock_git "$mb"; create_mock_gh_for_job "$mb"; _stub_job_subscripts "$mock_home"

    local ec out
    # gh が、オーナーの候補を返さない（モック）→ オーナーを入力。続いて XXXX と確認（Y）、ジョブ名と確認（Y）
    out=$(printf 'my-org\nacme\nY\nJOB-test\nY\n' \
        | (export HOME="$mock_home" PATH="$mb:$PATH"; cd "$wdir" && bash "$mock_home/sf-tools/bin/sf-job.sh") 2>&1)
    ec=$?

    assert_exit_ok $ec                                                      "対話で、オーナーと XXXX を入力すると、正常終了する"
    [[ "$out" == *"force-* のクローンが見つかりません"* ]] && pass "クローンがないとき、その旨を表示する" || fail "クローンがないとき、その旨を表示する" "出力に案内がない"
    assert_output_contains "$out" "XXXX の部分だけを入力してください"          "「force- は自動で付く。XXXX だけ入力」と案内する"
    assert_file_contains "$MOCK_CALL_LOG" "my-org/force-acme"               "入力したオーナーと XXXX で、リポジトリを扱う"

    teardown "$mb" "$mock_home" "$(dirname "$wdir")"
}

test_flex_from_init_xxxx_dir() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 管理者用の作業フォルダ（admin）から実行 → エラー${CLR_RST}"

    local mb mock_home base d ec out
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    base=$(mktemp -d "${TMPDIR:-/tmp}/test-init-XXXX"); d="$base/admin"; mkdir -p "$d"
    create_mock_gh_for_job "$mb"; _stub_job_subscripts "$mock_home"

    out=$(printf 'q\n' | (export HOME="$mock_home" PATH="$mb:$PATH"; cd "$d" && bash "$mock_home/sf-tools/bin/sf-job.sh" --owner my-org --project acme) 2>&1)
    ec=$?
    assert_exit_fail $ec "admin フォルダ → エラー終了"
    assert_output_contains "$out" "管理者用の作業フォルダ" "管理者用の作業フォルダからは、実行できないと表示する"

    teardown "$mb" "$mock_home" "$base"
}

test_flex_job_name_per_project() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 同じジョブ名でも、別のプロジェクトなら重複にしない（同じプロジェクトは重複）${CLR_RST}"

    local mb mock_home wdir ec out
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home); wdir=$(_setup_flex_dir)
    create_mock_git "$mb"; create_mock_gh_for_job "$mb"; _stub_job_subscripts "$mock_home"
    mkdir -p "$wdir/JOB-001/force-beta"          # 別のプロジェクト（beta）の、同名のジョブ

    out=$(printf 'JOB-001\nY\n' \
        | (export HOME="$mock_home" PATH="$mb:$PATH"; cd "$wdir" && bash "$mock_home/sf-tools/bin/sf-job.sh" --owner my-org --project acme) 2>&1)
    ec=$?
    assert_exit_ok $ec "別のプロジェクトの同名のジョブがあっても、重複にならず、正常終了する"
    assert_output_not_contains "$out" "すでに存在します" "重複の警告は、出ない"

    mkdir -p "$wdir/JOB-002/force-acme"          # 同じプロジェクト（acme）の、同名のジョブ
    out=$(printf 'JOB-002\nJOB-003\nY\n' \
        | (export HOME="$mock_home" PATH="$mb:$PATH"; cd "$wdir" && bash "$mock_home/sf-tools/bin/sf-job.sh" --owner my-org --project acme) 2>&1)
    assert_output_contains "$out" "すでに存在します" "同じプロジェクトの同名のジョブ → 重複の警告が出て、聞きなおす"

    teardown "$mb" "$mock_home" "$(dirname "$wdir")"
}

test_unknown_option() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 不明なオプション・値のない --project → エラー${CLR_RST}"

    local mb mock_home wdir ec
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home); wdir=$(_setup_flex_dir)
    create_mock_gh_for_job "$mb"; _stub_job_subscripts "$mock_home"

    (export HOME="$mock_home" PATH="$mb:$PATH"; cd "$wdir" && bash "$mock_home/sf-tools/bin/sf-job.sh" --nope) > /dev/null 2>&1
    assert_exit_fail $? "不明なオプション → エラー終了"
    (export HOME="$mock_home" PATH="$mb:$PATH"; cd "$wdir" && bash "$mock_home/sf-tools/bin/sf-job.sh" --project) > /dev/null 2>&1
    assert_exit_fail $? "--project に値がない → エラー終了"

    teardown "$mb" "$mock_home" "$(dirname "$wdir")"
}

# ==============================================================================
# 回帰: gh が未認証のとき、gh auth login を run を使わずに実行する（gh の対話画面を表示するため）
#   （以前は run で実行していたため、出力が一時ファイルに書き出され、gh の質問・ブラウザの案内が、正しく表示されなかった）
# ==============================================================================
test_gh_auth_login_direct() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] gh が未認証 → gh auth login を直接実行する（run を使わない）${CLR_RST}"

    local mb mock_home cdir ec out
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home); cdir=$(setup_company_dir)
    create_mock_git "$mb"
    create_mock_gh_for_job "$mb"
    _stub_job_subscripts "$mock_home"

    out=$(printf 'JOB-test\nY\n' \
        | (export HOME="$mock_home" PATH="$mb:$PATH" MOCK_GH_AUTH_STATUS_EXIT=1; cd "$cdir" && bash "$mock_home/sf-tools/bin/sf-job.sh" --owner tamashimon-org --project yamada) 2>&1)
    ec=$?
    assert_exit_ok  $ec                                                  "未認証 → ログインに成功 → 正常終了する"
    assert_file_contains "$MOCK_CALL_LOG" "gh auth login"                "gh auth login が呼ばれる"
    # assert_output_not_contains は grep -qv（1 行でも一致しなければ合格）のため使わず、固定文字列で全体を確かめる
    printf '%s\n' "$out" | grep -qF "Command: [sf-job.sh] gh auth login" \
        && fail "gh auth login は run を通さない（コマンドの記録が出ない）" "run の記録（Command: … gh auth login）が出た" \
        || pass "gh auth login は run を通さない（コマンドの記録が出ない）"

    out=$(printf 'JOB-test\nY\n' \
        | (export HOME="$mock_home" PATH="$mb:$PATH" MOCK_GH_AUTH_STATUS_EXIT=1 MOCK_GH_AUTH_LOGIN_EXIT=1; cd "$cdir" && bash "$mock_home/sf-tools/bin/sf-job.sh" --owner tamashimon-org --project yamada) 2>&1)
    ec=$?
    assert_exit_fail $ec                                                 "ログインに失敗 → 中断する"
    assert_output_contains "$out" "GitHub 認証に失敗しました"             "ログインに失敗 → 理由を表示する"

    teardown "$mb" "$mock_home" "$(dirname "$(dirname "$(dirname "$cdir")")")"
}

# ==============================================================================
# 12/13 の共通: sf-start.sh を、呼ばれたことを記録するスタブにする。sf-job.sh を動かし、出力を JB_OUT・終了コードを JB_RC に
# ==============================================================================
_stub_start_logged() {
    local mock_home="$1"
    _stub_job_subscripts "$mock_home"
    printf '#!/bin/bash\necho "sf-start called" >> "${MOCK_CALL_LOG:-/dev/null}"\nexit 0\n' > "$mock_home/sf-tools/bin/sf-start.sh"
    chmod +x "$mock_home/sf-tools/bin/sf-start.sh"
}
_job() { # 標準入力 作業フォルダ [環境変数...] -- [引数...]
    local input="$1" dir="$2"; shift 2
    local envs=()
    while [[ $# -gt 0 && "$1" != "--" ]]; do envs+=("$1"); shift; done
    [[ "${1:-}" == "--" ]] && shift
    JB_OUT=$(printf '%s' "$input" \
        | (export HOME="$JB_HOME" PATH="$JB_MB:$PATH"; cd "$dir" && env "${envs[@]}" bash "$JB_HOME/sf-tools/bin/sf-job.sh" "$@") 2>&1)
    JB_RC=$?
}

test_name_option() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] --name: 入力を聞かない・合わない名前は、入力し直さずに中断${CLR_RST}"

    local cdir
    JB_MB=$(setup_mock_bin); export MOCK_CALL_LOG="$JB_MB/calls.log"
    JB_HOME=$(setup_mock_home); cdir=$(setup_company_dir)
    create_mock_git "$JB_MB"; create_mock_gh_for_job "$JB_MB"; _stub_start_logged "$JB_HOME"

    _job $'Y\n' "$cdir" X=1 -- --owner tamashimon-org --project yamada --name JOB-named
    assert_exit_ok $JB_RC                                                   "--name: 正常終了する"
    assert_output_not_contains "$JB_OUT" "ジョブ名："                   "--name: ジョブ名を聞かない"
    assert_file_contains "$MOCK_CALL_LOG" "JOB-named/force-yamada"          "--name: その名前でクローンする"
    assert_file_contains "$MOCK_CALL_LOG" "sf-start called"                 "--name（人の操作）: sf-start を動かす"

    local bad
    for bad in "bad name" "-JOB" "develop" "admin"; do
        : > "$MOCK_CALL_LOG"
        _job $'Y\n' "$cdir" X=1 -- --owner tamashimon-org --project yamada --name "$bad"
        assert_exit_fail $JB_RC                                             "--name「${bad}」: 中断する"
        assert_output_contains "$JB_OUT" "このジョブ名は使えません"          "--name「${bad}」: 理由を表示する"
        assert_file_not_contains "$MOCK_CALL_LOG" "git/refs"                "--name「${bad}」: ブランチを作らない"
    done

    : > "$MOCK_CALL_LOG"
    mkdir -p "$cdir/JOB-dup/force-yamada"
    _job $'Y\n' "$cdir" X=1 -- --owner tamashimon-org --project yamada --name JOB-dup
    assert_exit_fail $JB_RC                                                 "--name でフォルダが重複: 中断する"
    assert_output_contains "$JB_OUT" "同名のフォルダがすでに存在します"      "--name でフォルダが重複: 理由を表示する"
    assert_output_not_contains "$JB_OUT" "別のジョブ名を入力してください" "--name でフォルダが重複: 入力し直しを促さない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs"                    "--name でフォルダが重複: ブランチを作らない"

    : > "$MOCK_CALL_LOG"
    _job $'N\n' "$cdir" MOCK_GH_BRANCH_EXISTS_EXIT=0 -- --owner tamashimon-org --project yamada --name JOB-other
    assert_exit_fail $JB_RC                                                 "--name で同名のブランチ・N: 中断する"
    assert_output_not_contains "$JB_OUT" "ジョブ名："                   "--name で同名のブランチ・N: 別の名前を聞かない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git clone"                   "--name で同名のブランチ・N: クローンしない"

    teardown "$JB_MB" "$JB_HOME" "$(dirname "$(dirname "$(dirname "$cdir")")")"
}

test_ai_mode_job() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] AI 操作（SF_TOOLS_AI=1）${CLR_RST}"

    local cdir wdir
    JB_MB=$(setup_mock_bin); export MOCK_CALL_LOG="$JB_MB/calls.log"
    JB_HOME=$(setup_mock_home); cdir=$(setup_company_dir); wdir=$(_setup_flex_dir)
    create_mock_git "$JB_MB"; create_mock_gh_for_job "$JB_MB"; _stub_start_logged "$JB_HOME"
    local A=(--owner tamashimon-org --project yamada --name JOB-ai)

    _job $'Y\n' "$cdir" SF_TOOLS_AI=1 -- "${A[@]}"
    assert_equals "$JB_RC" "20"                                             "AI・答えなし → 20（標準入力の Y は読まない）"
    assert_output_contains "$JB_OUT" "\[確認待ち\] job.create: ▶ よろしいですか？" "AI・答えなし → job.create の確認待ち"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs"                    "AI・答えなし → ブランチを作らない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git clone"                   "AI・答えなし → クローンしない"

    : > "$MOCK_CALL_LOG"
    _job "" "$cdir" SF_TOOLS_AI=1 SF_TOOLS_ANSWERS="job.create=y" -- "${A[@]}"
    assert_exit_ok $JB_RC                                                   "AI・job.create=y → 正常終了する"
    assert_file_contains "$MOCK_CALL_LOG" "git/refs"                        "AI・job.create=y → ブランチを作る"
    assert_file_contains "$MOCK_CALL_LOG" "JOB-ai/force-yamada"             "AI・job.create=y → クローンする"
    assert_file_not_contains "$MOCK_CALL_LOG" "sf-start called"             "AI・job.create=y → sf-start を動かさない"
    assert_output_contains "$JB_OUT" "sf-start.sh は、人がそのフォルダで実行します" "AI・job.create=y → sf-start は人が動かすと表示する"

    : > "$MOCK_CALL_LOG"
    _job "" "$cdir" SF_TOOLS_AI=1 SF_TOOLS_ANSWERS="job.create=n" -- --owner tamashimon-org --project yamada --name JOB-ai2
    assert_exit_fail $JB_RC                                                 "AI・job.create=n → 中断する"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs"                    "AI・job.create=n → ブランチを作らない"

    : > "$MOCK_CALL_LOG"
    _job "" "$cdir" SF_TOOLS_AI=1 SF_TOOLS_ANSWERS="job.create=y" MOCK_GH_AUTH_STATUS_EXIT=1 -- --owner tamashimon-org --project yamada --name JOB-ai3
    assert_exit_fail $JB_RC                                                 "AI・gh が未認証 → 中断する"
    assert_equals "$JB_RC" "1"                                              "AI・gh が未認証 → 終了コード 1"
    assert_output_contains "$JB_OUT" "GitHub CLI が未認証です"              "AI・gh が未認証 → 理由を表示する"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh auth login"               "AI・gh が未認証 → gh auth login を動かさない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs"                    "AI・gh が未認証 → ブランチを作らない"

    : > "$MOCK_CALL_LOG"
    _job "" "$cdir" SF_TOOLS_AI=1 SF_TOOLS_ANSWERS="job.create=y" -- --owner tamashimon-org --project yamada
    assert_equals "$JB_RC" "20"                                             "AI・--name なし → 20（ジョブ名の入力で止まる）"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs"                    "AI・--name なし → ブランチを作らない"

    : > "$MOCK_CALL_LOG"
    _job "" "$wdir" SF_TOOLS_AI=1 SF_TOOLS_ANSWERS="job.create=y" -- --name JOB-ai4
    assert_equals "$JB_RC" "20"                                             "AI・--owner・--project なし（対話になる）→ 20"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs"                    "AI・--owner・--project なし → ブランチを作らない"

    : > "$MOCK_CALL_LOG"
    _job "" "$cdir" SF_TOOLS_AI=1 SF_TOOLS_ANSWERS="job.create=y" MOCK_GH_BRANCH_EXISTS_EXIT=0 -- --owner tamashimon-org --project yamada --name JOB-ai5
    assert_equals "$JB_RC" "20"                                             "AI・同名のブランチ・答えなし → 20"
    assert_output_contains "$JB_OUT" "\[確認待ち\] job.existing: このブランチを使って、続けますか？" "AI・同名のブランチ → job.existing の確認待ち"
    assert_file_not_contains "$MOCK_CALL_LOG" "git clone"                   "AI・同名のブランチ・答えなし → クローンしない"

    : > "$MOCK_CALL_LOG"
    _job "" "$cdir" SF_TOOLS_AI=1 SF_TOOLS_ANSWERS="job.existing=n job.create=y" MOCK_GH_BRANCH_EXISTS_EXIT=0 -- --owner tamashimon-org --project yamada --name JOB-ai6
    assert_exit_fail $JB_RC                                                 "AI・同名のブランチ・job.existing=n → 中断する"
    assert_file_not_contains "$MOCK_CALL_LOG" "git clone"                   "AI・同名のブランチ・job.existing=n → クローンしない"

    : > "$MOCK_CALL_LOG"
    _job "" "$cdir" SF_TOOLS_AI=1 SF_TOOLS_ANSWERS="job.existing=y job.create=y" MOCK_GH_BRANCH_EXISTS_EXIT=0 -- --owner tamashimon-org --project yamada --name JOB-ai7
    assert_exit_ok $JB_RC                                                   "AI・同名のブランチ・job.existing=y → 正常終了する"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs"                    "AI・同名のブランチ・job.existing=y → ブランチを作らない（既存を使う）"
    assert_file_contains "$MOCK_CALL_LOG" "JOB-ai7/force-yamada"            "AI・同名のブランチ・job.existing=y → クローンする"

    teardown "$JB_MB" "$JB_HOME" "$(dirname "$(dirname "$(dirname "$cdir")")")" "$(dirname "$wdir")"
}

test_happy_path
test_gh_auth_login_direct
test_developer_not_owner_can_run
test_from_force_dir
test_repo_not_found
test_local_job_dir_duplicate
test_github_branch_duplicate
test_github_branch_resume
test_invalid_job_name
test_branch_create_failure
test_clone_failure
test_quit_with_q
test_flex_args
test_flex_prompt
test_flex_from_init_xxxx_dir
test_flex_job_name_per_project
test_unknown_option
test_name_option
test_ai_mode_job

print_summary
