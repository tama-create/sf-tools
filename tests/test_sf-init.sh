#!/bin/bash
# ==============================================================================
# test_sf-init.sh - sf-init.sh の単体テスト（モックベース。1/3）
# ==============================================================================
# sf-init.sh のテストは、時間がかかる（Windows の CI で約 10 分）ため、3 つのファイル（test_sf-init.sh・test_sf-init2.sh・
# test_sf-init3.sh）に分け、並列に動かす。共通の部品は tests/init-test-lib.sh。関数の分け方は、実測の所要時間で、均等になるようにした。
# どのテストが、どのファイルにあるかは、下の一覧（関数名）を参照。全部で 49 の関数（件数は、3 つの合計）。
#
# 【このファイルのテスト関数】
#   test_missing_tool_gh
#   test_unauthorized_user
#   test_flex_layout_prompt
#   test_admin_branch_failure_is_not_fatal
#   test_refuse_inside_admin_or_clone
#   test_finish_unfinished_setup
#   test_resume_state_case_insensitive
#   test_flex_invalid_project_arg
#   test_invalid_phase_args
#   test_resume_runs_from_specified_phase
#   test_add_tier_develop_without_staging
#   test_phase9_ruleset_id
#   test_phase7_channel_id
#   test_e2e_input_sequence
#   test_wf_no_script_injection
#   test_phase6_pat_token
#   test_resume_choice
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/init-test-lib.sh"

# ==============================================================================
# テスト 2: 必要なツールが不足している場合（gh コマンドなし）
# ==============================================================================
test_missing_tool_gh() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 必要なツール不足（gh コマンドなし）${CLR_RST}"

    local mb mock_home init_base init_dir
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"

    # gh モックを作成しない → PATH="$mb" 限定なら command -v gh が失敗する
    create_mock_git  "$mb"
    create_mock_sf   "$mb"
    create_mock_npm  "$mb"
    create_mock_code "$mb"
    create_mock_node "$mb"
    # create_mock_gh は意図的に省略

    local exit_code
    # PATH を $mb のみに限定して gh が見つからない状態を再現する
    printf 'x\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" ) > /dev/null 2>&1
    exit_code=$?

    assert_exit_fail "$exit_code" "gh なしで失敗終了する"

    teardown "$mb" "$mock_home" "$init_base"
}

# ==============================================================================
# テスト 5: 許可されていないユーザーは実行できない
# ==============================================================================
test_unauthorized_user() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 許可されていないユーザー → 実行拒否${CLR_RST}"

    local mb mock_home init_base init_dir
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"

    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    export MOCK_GH_API_USER="stranger123"

    local exit_code
    printf 'x\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" ) > /dev/null 2>&1
    exit_code=$?

    assert_exit_fail "$exit_code" "許可されていないユーザーは失敗終了する"

    unset MOCK_GH_API_USER
    teardown "$mb" "$mock_home" "$init_base"
}

# ==============================================================================
# テスト 6c: 任意の場所 + 対話（オーナーと XXXX を聞く。「force- は自動で付く」と案内する）
# ==============================================================================
test_flex_layout_prompt() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 任意の場所 + 対話（オーナーと XXXX を入力）${CLR_RST}"
    unset SF_INIT_OWNER SF_INIT_PROJECT     # 対話で決めるため、環境変数を外す（終わりに戻す）

    local mb mock_home base work
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    base=$(mktemp -d "${TMPDIR:-/tmp}/test-init-XXXX")
    work="$base/work"
    mkdir -p "$work"

    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    _stub_subscripts "$mock_home"

    local exit_code
    # 先頭の 3 行が、オーナーの入力・XXXX の入力・確認（Y）。以降は、通常の入力
    { printf 'tamashimon\ntestproject\nY\n'; _make_input_3branches; } \
        | ( cd "$work" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --legacy-connected-app ) \
          > /tmp/sf-init-test-flex2.log 2>&1
    exit_code=$?

    assert_exit_ok   "$exit_code"                                                          "任意の場所 + 対話で、最後まで通る"
    assert_file_contains "/tmp/sf-init-test-flex2.log" "XXXX の部分だけを入力してください"     "対話: 「force- は自動で付く。XXXX だけ入力」と案内する"
    assert_file_contains "/tmp/sf-init-test-flex2.log" "作るリポジトリ"                        "対話: 入力のあとに、作るリポジトリ名を表示して確認する"
    assert_file_contains "$MOCK_CALL_LOG" "gh repo create tamashimon/force-testproject"    "入力したオーナーと XXXX で、リポジトリを作る"
    assert_file_exists   "$work/admin/force-testproject/.github/workflows/wf-validate.yml"  "管理者用の作業フォルダは admin"

    export SF_INIT_OWNER="tamashimon" SF_INIT_PROJECT="testproject"   # 環境変数を戻す
    teardown "$mb" "$mock_home" "$base"
}

# ==============================================================================
# テスト 6d: 管理者用のクローンを admin ブランチにできなくても、セットアップは成功のまま（完了画面で知らせる）
# ==============================================================================
test_admin_branch_failure_is_not_fatal() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] admin ブランチへの切り替えに失敗 → セットアップは成功・完了画面で知らせる${CLR_RST}"

    local mb mock_home base work exit_code
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    base=$(mktemp -d "${TMPDIR:-/tmp}/test-init-XXXX")
    work="$base/my-work"; mkdir -p "$work"

    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    _stub_subscripts "$mock_home"

    export MOCK_GIT_CHECKOUT_FAIL_BRANCH=admin
    _make_input_3branches \
        | ( cd "$work" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --owner tamashimon --project testproject --legacy-connected-app ) \
          > /tmp/sf-init-test-adminfail.log 2>&1
    exit_code=$?
    unset MOCK_GIT_CHECKOUT_FAIL_BRANCH

    assert_exit_ok   "$exit_code"                                                       "admin ブランチにできなくても、セットアップは成功する"
    assert_file_contains "/tmp/sf-init-test-adminfail.log" "admin ブランチにできませんでした"  "警告を表示する"
    assert_file_contains "/tmp/sf-init-test-adminfail.log" "git switch -c admin"        "完了画面で、手動で作る方法を知らせる"

    teardown "$mb" "$mock_home" "$base"
    rm -f /tmp/sf-init-test-adminfail.log
}

# ==============================================================================
# テスト 6g: 実行場所の確認（admin・force-* の中では、実行できない）
# ==============================================================================
test_refuse_inside_admin_or_clone() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] admin・force-* の中で実行 → 中断（別のクローンに、書き込まない）${CLR_RST}"
    local mb mock_home base d exit_code out
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    create_all_mocks "$mb"; create_mock_gh_for_init "$mb"; _stub_subscripts "$mock_home"
    for d in admin force-testproject; do
        base=$(mktemp -d "${TMPDIR:-/tmp}/test-init-XXXX"); mkdir -p "$base/$d"
        : > "$MOCK_CALL_LOG"
        out=$(printf 'Y\n' | ( cd "$base/$d" && HOME="$mock_home" PATH="$mb:$PATH" \
            bash "$mock_home/sf-tools/bin/sf-init.sh" ) 2>&1)
        exit_code=$?
        assert_exit_fail "$exit_code"                                                    "${d} の中で実行 → 異常終了する"
        assert_output_contains "$out" "中では実行できません"                              "${d} の中で実行 → 理由を表示する"
        assert_file_not_contains "$MOCK_CALL_LOG" "gh repo create"                       "${d} の中で実行 → 何も作らない"
        assert_dir_not_exists "$base/$d/admin"                                           "${d} の中で実行 → admin/ を作らない"
        rm -rf "$base"
    done
    teardown "$mb" "$mock_home"
}

# ==============================================================================
# テスト 6j: 前回、完了の直前で中断した（進捗は 10 のまま）→ 後片付けを済ませてから、完了済みの案内を出す
# ==============================================================================
test_finish_unfinished_setup() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 進捗 10 の状態ファイルが残っている → admin ブランチ・完了の印・状態ファイルの整理を済ませる${CLR_RST}"
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
ENVEOF
    printf 'SF_INIT_DONE_PHASE=10\nSF_INIT_DONE_AT="2026-10-17 01:00"\n' > "$work/admin/.sf-init-testproject.progress"
    export MOCK_GIT_C_REMOTE_URL="https://github.com/tamashimon/force-testproject.git"   # 同じリポジトリのクローン
    : > "$MOCK_CALL_LOG"
    out=$(printf 'Y\nq\n' | ( cd "$work" && HOME="$mock_home" PATH="$mb:$PATH" \
        bash "$mock_home/sf-tools/bin/sf-init.sh" ) 2>&1)
    exit_code=$?
    unset MOCK_GIT_C_REMOTE_URL
    assert_exit_ok "$exit_code"                                                          "後片付け・q: 正常終了する"
    assert_output_contains "$out" "最後の後片付け"                                         "後片付け: 済んでいない旨を表示する"
    assert_file_contains "$MOCK_CALL_LOG" "checkout admin"                               "後片付け: クローンを admin ブランチにする"
    assert_file_contains "$MOCK_CALL_LOG" "push --no-verify -u origin admin"             "後片付け: admin ブランチを GitHub にも push する"
    assert_file_contains "$MOCK_CALL_LOG" "config sf-tools.setup-complete 1"             "後片付け: 完了の印を付ける"
    assert_file_not_exists "$work/admin/.sf-init-testproject.env"                        "後片付け: 状態ファイル（.env）を削除する"
    assert_file_not_exists "$work/admin/.sf-init-testproject.progress"                   "後片付け: 進捗ファイルを削除する"
    assert_output_contains "$out" "セットアップが、すでに完了しています"                      "後片付けのあと: 完了済みの案内が出る"
    teardown "$mb" "$mock_home" "$base"
}

# ==============================================================================
# テスト 6o: 状態ファイルのリポジトリ名の比較は、大文字と小文字を区別しない（続きをやる）
# ==============================================================================
test_resume_state_case_insensitive() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] --owner の大文字と小文字だけが違っても、途中の状態の「続きをやる」の案内が出る${CLR_RST}"
    local mb mock_home base work exit_code out
    mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    create_all_mocks "$mb"; create_mock_gh_for_init "$mb"; _stub_subscripts "$mock_home"
    base=$(mktemp -d "${TMPDIR:-/tmp}/test-init-XXXX"); work="$base/my-work"; mkdir -p "$work/admin"
    printf 'GITHUB_OWNER="tamashimon"\nPROJECT_NAME="testproject"\nREPO_NAME="force-testproject"\nREPO_FULL_NAME="tamashimon/force-testproject"\nBRANCH_COUNT="1"\n' > "$work/admin/.sf-init-testproject.env"
    printf 'SF_INIT_DONE_PHASE=5\nSF_INIT_DONE_AT="2026-10-17 01:00"\n' > "$work/admin/.sf-init-testproject.progress"
    : > "$MOCK_CALL_LOG"
    out=$(printf 'Y\nq\n' | ( cd "$work" && HOME="$mock_home" PATH="$mb:$PATH" \
        bash "$mock_home/sf-tools/bin/sf-init.sh" --owner TAMASHIMON --project testproject ) 2>&1)
    exit_code=$?
    assert_output_contains "$out" "前回のセットアップは、「ブランチの構成」まで完了しています"   "オーナーの大文字と小文字が違っても、続きをやる案内が出る"
    assert_file_exists "$work/admin/.sf-init-testproject.progress"                       "[q] 中断: 状態ファイルを、消さない（最初からやり直しにならない）"
    teardown "$mb" "$mock_home" "$base"
}

# ==============================================================================
# テスト 6d: 不正な --project は、リポジトリを作る前に、エラーで止まる
# ==============================================================================
test_flex_invalid_project_arg() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 不正な --project → 何も作らずにエラー${CLR_RST}"

    local mb mock_home base work out
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    base=$(mktemp -d "${TMPDIR:-/tmp}/test-init-XXXX")
    work="$base/work"
    mkdir -p "$work"
    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"

    out=$( { printf 'x\n' | ( cd "$work" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --owner tamashimon --project "bad name" --legacy-connected-app ); } 2>&1 )
    assert_exit_fail "$?" "空白を含むプロジェクト名 → エラー終了"
    assert_output_contains "$out" "プロジェクト名" "エラーに、プロジェクト名（XXXX）の説明が出る"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo create" "リポジトリを作る前に、止まる"
    assert_dir_not_exists "$work/init-bad name" "作業フォルダも作らない"

    out=$( { printf 'x\n' | ( cd "$work" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --project ); } 2>&1 )
    assert_exit_fail "$?" "--project に値がない → エラー終了"

    teardown "$mb" "$mock_home" "$base"
}

# ==============================================================================
# テスト 6e: --only / --resume / --add-tier の値の検査（値なし・数字以外・範囲外は、エラーで終了する）
# ==============================================================================
# 回帰: 値なしで最後に指定すると、引数の解析が終わらなかった（shift 2 が失敗。Ctrl+C は無効）。
#       --resume 11 は、Phase を 1 つも実行せずに、完了と表示していた。時間の上限（10 秒）を付けて実行し、止まらなければ失敗にする
test_invalid_phase_args() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] --only / --resume / --add-tier の値の検査${CLR_RST}"
    source "$(dirname "${BASH_SOURCE[0]}")/../lib/platform.sh"   # run_with_timeout

    local mb mock_home base work out rc args
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    base=$(mktemp -d "${TMPDIR:-/tmp}/test-init-XXXX")
    work="$base/work"
    mkdir -p "$work"
    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"

    # 値なし（最後の引数）: 無限ループにならず、すぐにエラーで終了する
    for args in "--only" "--resume" "--add-tier"; do
        out=$( { printf 'x
' | ( cd "$work" && HOME="$mock_home" PATH="$mb:$PATH"                   run_with_timeout 10 bash "$mock_home/sf-tools/bin/sf-init.sh" $args ); } 2>&1 )
        rc=$?
        assert_exit_fail "$rc" "${args} に値がない → エラー終了"
        [[ "$rc" != "124" ]] && pass "${args} に値がない → 時間切れ（無限ループ）にならない" || fail "${args} に値がない → 時間切れ（無限ループ）にならない" "終了コード 124（10 秒で打ち切り）"
        assert_output_contains "$out" "には、" "${args} に値がない → 指定のしかたが表示される"
    done

    # 値が Phase 番号でない（数字以外・0・範囲外・先頭が 0・次のオプション）: 何も実行せずに、エラーで終了する
    for args in "--resume 11" "--resume 0" "--resume abc" "--resume 02" "--resume --verify" "--only 11" "--only 0" "--only x" "--only -1"; do
        out=$( { printf 'x
' | ( cd "$work" && HOME="$mock_home" PATH="$mb:$PATH"                   run_with_timeout 10 bash "$mock_home/sf-tools/bin/sf-init.sh" $args ); } 2>&1 )
        rc=$?
        assert_exit_fail "$rc" "${args} → エラー終了"
        [[ "$rc" != "124" ]] && pass "${args} → 時間切れにならない" || fail "${args} → 時間切れにならない" "終了コード 124（10 秒で打ち切り）"
        assert_output_contains "$out" "Phase 番号（1〜10 の整数）" "${args} → 正しい指定が表示される"
        assert_file_not_contains "$MOCK_CALL_LOG" "gh repo create" "${args} → 何も作らない"
    done

    # --add-tier に、次のオプションを値として渡さない
    out=$( { printf 'x
' | ( cd "$work" && HOME="$mock_home" PATH="$mb:$PATH"               run_with_timeout 10 bash "$mock_home/sf-tools/bin/sf-init.sh" --add-tier --status ); } 2>&1 )
    assert_exit_fail "$?" "--add-tier の次がオプション → エラー終了"
    assert_output_contains "$out" "追加する段階（staging または develop）" "--add-tier の次がオプション → 指定のしかたが表示される"

    teardown "$mb" "$mock_home" "$base"
}

# ==============================================================================
# テスト 10: --only 9 → Phase 9 のみ実行（git commit は呼ばれない）
# ==============================================================================
test_resume_runs_from_specified_phase() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] --only 9 → Phase 9 のみ実行${CLR_RST}"

    local mb mock_home init_base init_dir
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"

    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    _stub_subscripts "$mock_home"

    # .sf-init.env を事前設定（Phase 2〜8 で書き出されるはずの内容）
    # --only 時は sf-init.sh が init/ に cd してから .sf-init.env を参照するため事前作成
    mkdir -p "$init_dir/admin"
    cat > "$init_dir/admin/.sf-init-testproject.env" << 'ENVEOF'
GITHUB_OWNER="tamashimon"
PROJECT_NAME="testproject"
REPO_NAME="force-testproject"
REPO_FULL_NAME="tamashimon/force-testproject"
REPO_DIR="/tmp/fake-repo"
BRANCH_COUNT="3"
PAT_TOKEN_VALUE="ghp_faketoken"
ENVEOF

    local exit_code
    printf 'Y\nN\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --only 9 ) > /dev/null 2>&1
    exit_code=$?

    assert_exit_ok            "$exit_code"                         "--only 9 で正常終了する"
    assert_file_not_contains  "$MOCK_CALL_LOG" "git commit"        "--only 9: git commit は呼ばれない"
    assert_file_contains      "$MOCK_CALL_LOG" "gh repo edit"      "Phase 9: gh repo edit が呼ばれる"

    teardown "$mb" "$mock_home" "$init_base"
}

# ==============================================================================
# テスト 13: --add-tier develop → staging がない場合はエラー
# ==============================================================================
test_add_tier_develop_without_staging() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] --add-tier develop → staging なしはエラー${CLR_RST}"

    local mb mock_home force_dir base_dir
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)

    base_dir=$(mktemp -d "${TMPDIR:-/tmp}/test-add-tier-XXXX")
    force_dir="$base_dir/force-testproject"
    mkdir -p "$force_dir/sf-tools/config"
    # main のみ（staging なし）
    printf 'main\n' > "$force_dir/sf-tools/config/branches.txt"

    create_all_mocks "$mb"

    cat > "$mb/git" << 'GITEOF'
#!/bin/bash
case "$1 $2" in
    "remote get-url") echo "https://github.com/tamashimon/force-testproject.git" ;;
    *) exit 0 ;;
esac
GITEOF
    chmod +x "$mb/git"

    local exit_code
    ( cd "$force_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
          bash "$mock_home/sf-tools/bin/sf-init.sh" --add-tier develop ) > /dev/null 2>&1
    exit_code=$?

    assert_exit_fail "$exit_code" "staging なしで develop 追加は失敗終了する"

    teardown "$mb" "$mock_home"
    rm -rf "$base_dir"
}

# ==============================================================================
# テスト 17: Phase 9 の既存 Ruleset の削除（--only 9）
#   - エラー本文が返る（無料プランの 403）: 削除を試みない・「確認できなかった」と表示（誤った ID で DELETE しない）
#   - 数字の ID が返る                    : その ID で DELETE が呼ばれ、「削除しました」と表示
# ==============================================================================
test_phase9_ruleset_id() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] Phase 9: 既存 Ruleset の ID 検証（エラー本文を ID として扱わない）${CLR_RST}"

    local mb mock_home init_base init_dir exit_code out
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    _stub_subscripts "$mock_home"
    out="$mb/out.log"

    _p9_run() {
        init_base=$(_setup_init_dir "tamashimon" "testproject")
        init_dir="$init_base/home/tamashimon/testproject"
        mkdir -p "$init_dir/admin"
        printf 'GITHUB_OWNER="tamashimon"\nPROJECT_NAME="testproject"\nREPO_NAME="force-testproject"\nREPO_FULL_NAME="tamashimon/force-testproject"\n' \
            > "$init_dir/admin/.sf-init-testproject.env"
        : > "$MOCK_CALL_LOG"
        printf 'Y\n' \
            | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
                  bash "$mock_home/sf-tools/bin/sf-init.sh" --only 9 ) > "$out" 2>&1
        exit_code=$?
    }

    # エラー本文（403）
    MOCK_GH_RULESETS=error _p9_run
    assert_exit_ok            "$exit_code"                         "403 でも Phase 9 は正常終了する"
    assert_file_not_contains  "$MOCK_CALL_LOG" "--method DELETE"   "403 → エラー本文を ID として DELETE しない"
    assert_file_contains      "$out" "確認できなかった"             "403 → 「確認できなかった」と表示される"
    assert_file_not_contains  "$out" "を削除しました"               "403 → 「削除しました」と誤表示しない"
    rm -rf "$init_base"

    # 数字の ID
    MOCK_GH_RULESETS=id _p9_run
    assert_exit_ok            "$exit_code"                                     "既存 Ruleset あり → 正常終了"
    assert_file_contains      "$MOCK_CALL_LOG" "rulesets/12345"                "既存 Ruleset あり → その ID で DELETE される"
    assert_file_contains      "$out" "を削除しました"                           "既存 Ruleset あり → 「削除しました」と表示される"

    unset -f _p9_run
    teardown "$mb" "$mock_home" "$init_base"
}

# ==============================================================================
# テスト 18: Phase 7 の SLACK_CHANNEL_ID の形式チェック（--only 7）
#   入力列: 警告確認 Y →（\n は press_enter が消費）→ Bot Token → チャンネル ID ...
#   - C… の ID               : 警告なしで登録
#   - D… / U… の ID          : 警告のうえ拒否され、入力し直した C… / G… が登録される（D… / U… は登録されない）
#   - 案内文                 : 共有チャンネルの用意と DM 不可が表示される
# ==============================================================================
test_phase7_channel_id() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] Phase 7: SLACK_CHANNEL_ID の形式チェック${CLR_RST}"

    local mb mock_home init_base init_dir exit_code out
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    _stub_subscripts "$mock_home"
    out="$mb/out.log"

    _p7_run() {
        init_base=$(_setup_init_dir "tamashimon" "testproject")
        init_dir="$init_base/home/tamashimon/testproject"
        mkdir -p "$init_dir/admin"
        printf 'REPO_FULL_NAME="tamashimon/force-testproject"\nPROJECT_NAME="testproject"\n' > "$init_dir/admin/.sf-init-testproject.env"
        rm -f "$mb"/var_SLACK_CHANNEL_ID.txt
        : > "$MOCK_CALL_LOG"
        printf '%b' "$1" \
            | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
                  bash "$mock_home/sf-tools/bin/sf-init.sh" --only 7 ) > "$out" 2>&1
        exit_code=$?
    }

    # C… の ID
    _p7_run 'Y\nxoxb-fake\nC01ABCDEFGH\n\n'
    assert_exit_ok           "$exit_code"                                  "C… → 正常終了"
    assert_file_contains     "$mb/var_SLACK_CHANNEL_ID.txt" "C01ABCDEFGH"  "C… → そのまま登録される"
    assert_file_not_contains "$out" "チャンネル ID の形式ではありません"    "C… → 警告が出ない"
    rm -rf "$init_base"

    # D… の ID → 拒否されて入力し直し → C… の ID
    _p7_run 'Y\nxoxb-fake\nD0C6AQHLYLT\nC01ABCDEFGH\n\n'
    assert_exit_ok           "$exit_code"                                  "D… → 再入力 C… → 正常終了"
    assert_file_contains     "$out" "チャンネル ID の形式ではありません"    "D… → 警告が出る"
    assert_file_contains     "$mb/var_SLACK_CHANNEL_ID.txt" "C01ABCDEFGH"  "D… → 拒否され、入力し直した C… が登録される"
    assert_file_not_contains "$mb/var_SLACK_CHANNEL_ID.txt" "D0C6AQHLYLT"  "D… は登録されない"
    rm -rf "$init_base"

    # U… の ID → 拒否されて入力し直し → G… の ID（非公開チャンネル）
    _p7_run 'Y\nxoxb-fake\nU01ABCDEFGH\nG01ABCDEFGH\n\n'
    assert_exit_ok           "$exit_code"                                  "U… → 再入力 G… → 正常終了"
    assert_file_contains     "$mb/var_SLACK_CHANNEL_ID.txt" "G01ABCDEFGH"  "U… → 拒否され、入力し直した G… が登録される"
    assert_file_not_contains "$mb/var_SLACK_CHANNEL_ID.txt" "U01ABCDEFGH"  "U… は登録されない"
    rm -rf "$init_base"

    # 案内文（共有チャンネルの案内が表示される）
    _p7_run 'Y\nxoxb-fake\nC01ABCDEFGH\n\n'
    assert_file_contains     "$out" "共有チャンネル"                        "共有チャンネルを用意する案内が表示される"
    assert_file_contains     "$out" "DM"                                    "DM は使えない旨が表示される"

    unset -f _p7_run
    teardown "$mb" "$mock_home" "$init_base"
}

# ==============================================================================
# テスト 20: e2e の入力の台本（tests/e2e/lib.sh の e2e_make_input）で、sf-init が最後まで進む
#   実環境の通し検証（tests/e2e/run.sh）が流す標準入力が、sf-init の質問の順番と合っているかを、
#   モックで確認する（質問の順番を変えたとき、台本の直し忘れをここで検知する）
#   構成: 検証環境（SF_TOOLS_BRANCH=development）・main のみ・外部クライアントアプリ・DM ではない共有チャンネル
# ==============================================================================
test_e2e_input_sequence() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] e2e の入力の台本で、sf-init が Phase 1〜10 を最後まで進む${CLR_RST}"

    local mb mock_home init_base init_dir exit_code input
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
            bash -c "source '$SF_TOOLS_DIR/tests/e2e/lib.sh'; e2e_make_input")
    printf '%s\n' "$input" \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" ) > "$mb/out.log" 2>&1
    exit_code=$?

    assert_exit_ok            "$exit_code"                                                          "台本で最後まで正常終了する"
    assert_file_contains      "$mb/out.log" "開発版（sf-tools: development）"                      "sf-tools の版は、開発版になる"
    assert_file_contains      "$MOCK_CALL_LOG" "gh variable set SF_TOOLS_BRANCH --body development"   "SF_TOOLS_BRANCH=development が登録される"
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set PAT_TOKEN"                              "PAT_TOKEN が登録される"
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SLACK_BOT_TOKEN"                        "SLACK_BOT_TOKEN が登録される"
    assert_file_contains      "$mb/var_SLACK_CHANNEL_ID.txt" "C01ABCDEFGH"                            "SLACK_CHANNEL_ID に、台本のチャンネル ID が登録される"
    assert_file_contains      "$MOCK_CALL_LOG" "sf org login web --instance-url https://login.salesforce.com --alias sf-tools-PROD" "メイン組織のログインが呼ばれる"
    assert_file_contains      "$MOCK_CALL_LOG" "project deploy start --source-dir force-app"          "外部クライアントアプリが作成される"
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"                   "SF_CONSUMER_KEY_PROD が登録される"
    assert_file_not_contains  "$MOCK_CALL_LOG" "SF_CONSUMER_KEY_STG"                                  "main のみの構成なので、ステージング組織は設定しない"
    assert_file_not_contains  "$MOCK_CALL_LOG" "SF_TOOLS_TOKEN"                                       "SF_TOOLS_TOKEN は登録しない（sf-tools は公開リポジトリのため不要）"
    assert_dir_exists         "$init_dir/admin"                                                        "admin フォルダが残る（削除の質問は、廃止した）"
    assert_file_not_contains  "$mb/out.log" "削除してよいですか"                                       "admin フォルダの削除の質問は、出さない"
    assert_file_not_contains  "$mb/out.log" "ghp_fakepat"                                            "PAT_TOKEN の値が出力に出ない"

    unset MOCK_SF_ORG_JSON SF_INIT_JWT_INTERVAL MOCK_CALL_LOG SF_INIT_LOGIN_URL_PROD
    teardown "$mb" "$mock_home" "$init_base"
}

# ==============================================================================
# ワークフローのひな形: 利用者が決められる値（PR のタイトル・ブランチ名）を、シェルや JavaScript に直接埋め込まない
#   背景: Codex のレビュー（2026-10-06）。PR のタイトルやブランチ名に `"`・バッククォート・$( ) があると、
#         通知のステップが壊れる、または、任意のコマンドが実行される（スクリプトの注入）。env: で環境変数に渡す
# ==============================================================================
test_wf_no_script_injection() {
    echo ""; echo -e "${CLR_HEAD}[TEST] ワークフロー: PR のタイトル・ブランチ名を、スクリプトに直接埋め込まない（注入の防止）${CLR_RST}"
    local d="$SF_TOOLS_DIR/templates/.github/workflows" f name bad
    for f in "$d"/wf-*.yml; do
        name=$(basename "$f")
        # env: の代入行（NAME: ${{ ... }}）と、if: / ref: の行は、除く。残った行が、スクリプトへの直接の埋め込み
        bad=$(grep -nE '\$\{\{ *github\.(event\.pull_request\.(title|head\.ref|base\.ref|html_url)|ref_name|head_ref)|steps\.sequence_check\.outputs\.(feature|prev)' "$f" \
              | grep -vE '^[0-9]+:[[:space:]]+(if:|ref:)|^[0-9]+:[[:space:]]+[A-Z_]+: \$\{\{' || true)
        if [[ -z "$bad" ]]; then pass "${name}: 利用者が決められる値を、スクリプトに直接埋め込んでいない"
        else fail "${name}: 利用者が決められる値を、スクリプトに直接埋め込んでいない" "$(echo "$bad" | head -2)"; fi
    done

    # Slack に送る JSON のエスケープ（json_escape）: 3 つのワークフローで、同じ関数。悪意のある・壊れやすい値で確認する
    local je t out
    for name in wf-release wf-propagate wf-sequence; do
        je=$(grep -h 'json_escape()' "$d/${name}.yml" | sed 's/^ *//')
        [[ -n "$je" ]] && pass "${name}: json_escape を使っている" || { fail "${name}: json_escape を使っている"; continue; }
        t='x"; touch /tmp/pwned_wf_test; echo "a\b <b>&</b>'
        out=$(bash -c "$je"'; json_escape "$1"' _ "$t")
        [[ ! -e /tmp/pwned_wf_test ]] && pass "${name}: タイトルに含まれるコマンドは、実行されない" || { fail "${name}: タイトルに含まれるコマンドは、実行されない"; rm -f /tmp/pwned_wf_test; }
        [[ "$out" == 'x\"; touch /tmp/pwned_wf_test; echo \"a\\b &lt;b&gt;&amp;&lt;/b&gt;' ]] \
            && pass "${name}: \" と \ を JSON 用にエスケープし、& < > を Slack 用に置き換える" \
            || fail "${name}: \" と \ を JSON 用にエスケープし、& < > を Slack 用に置き換える" "$out"
    done

    # JWT の秘密鍵は、ログインに失敗しても、必ず消す（trap）。本人だけが読める権限（umask 077）で作る
    for name in wf-release wf-validate wf-metasync; do
        assert_file_contains "$d/${name}.yml" "trap 'rm -f /tmp/server.key' EXIT" "${name}: 秘密鍵は、失敗しても、必ず消す（trap）"
        assert_file_contains "$d/${name}.yml" "umask 077" "${name}: 秘密鍵は、本人だけが読める権限で作る"
    done
}

# ==============================================================================
# テスト 24: Phase 6: PAT_TOKEN（ブラウザをすぐ開く・Token の検証・貼り直し）
# ==============================================================================
test_phase6_pat_token() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] Phase 6: PAT_TOKEN（ブラウザをすぐ開く・Token の検証・貼り直し）${CLR_RST}"

    local mb mock_home init_base init_dir exit_code
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    init_base=$(_setup_init_dir "tamashimon" "testproject")
    init_dir="$init_base/home/tamashimon/testproject"
    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    _stub_subscripts "$mock_home"
    mkdir -p "$init_dir/admin"

    # 引数: 標準入力（printf の書式）。先頭の Y は、管理者向けの確認。環境変数（MOCK_GH_*）は、呼ぶ前に export する
    #   REPO_DIR は入れない
    _p6_run() {
        : > "$MOCK_CALL_LOG"
        cat > "$init_dir/admin/.sf-init-testproject.env" << 'ENVEOF'
GITHUB_OWNER="tamashimon"
PROJECT_NAME="testproject"
REPO_NAME="force-testproject"
REPO_FULL_NAME="tamashimon/force-testproject"
ENVEOF
        printf "$1" | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --only 6 ) > "$mb/out.log" 2>&1
        exit_code=$?
    }
    local envf="$init_dir/admin/.sf-init-testproject.env"

    # --- 正常: 質問なしで、ブラウザを開く → 検証 OK → 登録 ---
    _p6_run 'Y\nghp_good\n'
    assert_exit_ok            "$exit_code"                                                  "正常終了する"
    assert_file_not_contains  "$mb/out.log" "発行済み"                                       "「発行済みか」は、聞かない"
    assert_file_contains      "$mb/out.log" "【作るアカウント】 tamashimon"                   "Token を作るアカウント（オーナー）が表示される"
    assert_file_contains      "$mb/out.log" "文字の数だけ * が並びます"                         "貼り付けると * が並ぶことを、先に伝える"
    assert_file_contains      "$mb/out.log" "Generate token"                                "手順（やること）が表示される"
    assert_file_contains      "$MOCK_CALL_LOG" "tokens/new?description=sf-metasync-testproject&scopes=repo,workflow" "Token の作成ページ（Note・Scopes 入力済み）を、ブラウザで開く"
    assert_file_contains      "$mb/out.log" "Token を確認できました（tamashimon さんの Token"   "検証の結果が、人の言葉で表示される"
    assert_file_contains      "$MOCK_CALL_LOG" "gh api repos/tamashimon/force-testproject"   "リポジトリの管理者かを問い合わせる"
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set PAT_TOKEN"                     "PAT_TOKEN が登録される"
    assert_file_contains      "$envf" 'PAT_TOKEN_VALUE="ghp_good"'                          "Phase 8 用に .sf-init.env へ書き出される"
    assert_file_not_contains  "$mb/out.log" "ghp_good"                                      "Token の値が画面（出力）に出ない"
    assert_file_not_contains  "$MOCK_CALL_LOG" "ghp_good"                                   "Token の値がコマンドのログに出ない"

    # --- 検証 NG: workflow の権限がない（3 回とも）→ 中断・登録しない ---
    export MOCK_GH_TOKEN_SCOPES="repo"
    _p6_run 'Y\nghp_a\nghp_b\nghp_c\n'
    assert_exit_fail          "$exit_code"                                                  "workflow の権限なし（3 回）: 中断する"
    assert_file_contains      "$mb/out.log" "「workflow」の権限がありません"                   "workflow の権限なし: 理由が表示される"
    assert_file_contains      "$mb/out.log" "作り直してください"                               "workflow の権限なし: 直し方が表示される"
    assert_file_contains      "$mb/out.log" "あと 2 回"                                       "貼り直せる残りの回数が表示される"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh secret set PAT_TOKEN"                     "workflow の権限なし: 登録しない"

    # --- 検証 NG: Fine-grained 相当（スコープのヘッダーなし）→ 中断 ---
    export MOCK_GH_TOKEN_SCOPES=""
    _p6_run 'Y\nghp_a\nghp_b\nghp_c\n'
    assert_exit_fail          "$exit_code"                                                  "種類が違う Token: 中断する"
    assert_file_contains      "$mb/out.log" "種類が違います"                                   "種類が違う: 理由が表示される"
    unset MOCK_GH_TOKEN_SCOPES

    # --- 検証 NG: リポジトリの管理者ではない → 中断・登録しない ---
    export MOCK_GH_PERM_ADMIN=false MOCK_GH_TOKEN_USER=someone-else
    _p6_run 'Y\nghp_a\nghp_b\nghp_c\n'
    assert_exit_fail          "$exit_code"                                                  "管理者ではない Token: 中断する"
    assert_file_contains      "$mb/out.log" "someone-else さんのものですが"                    "管理者ではない: Token のユーザーが表示される"
    assert_file_contains      "$mb/out.log" "の管理者ではありません"                            "管理者ではない: 理由が表示される"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh secret set PAT_TOKEN"                     "管理者ではない: 登録しない"
    unset MOCK_GH_PERM_ADMIN MOCK_GH_TOKEN_USER

    # --- 検証 NG: 無効な Token → 貼り直せる（2 回目で成功）---
    export MOCK_GH_BAD_TOKEN=ghp_bad
    _p6_run 'Y\nghp_bad\nghp_good\n'
    assert_exit_ok            "$exit_code"                                                  "無効な Token → 貼り直して成功する"
    assert_file_contains      "$mb/out.log" "Token を確認できませんでした"                      "無効な Token: 理由が表示される"
    assert_file_contains      "$envf" 'PAT_TOKEN_VALUE="ghp_good"'                          "貼り直した Token が書き出される"
    assert_file_not_contains  "$envf" "ghp_bad"                                             "無効な Token は書き出されない"
    unset MOCK_GH_BAD_TOKEN

    # --- q で中断 ---
    _p6_run 'Y\nq\n'
    assert_exit_fail          "$exit_code"                                                  "貼り付けの入力で q → 中断する"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh secret set PAT_TOKEN"                     "q: 登録しない"

    unset -f _p6_run
    unset MOCK_CALL_LOG
    teardown "$mb" "$mock_home" "$init_base"
}

# ==============================================================================
# テスト 25: 途中で止まったときの「続きをやる / 最初からやり直す」
# ==============================================================================
test_resume_choice() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 前回の続き（続きをやる / 最初からやり直す / 中断 / 質問が出ない条件）${CLR_RST}"

    local mb mock_home init_base init_dir exit_code out envf progf
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    _stub_subscripts "$mock_home"
    out="$mb/out.log"
    export MOCK_SF_ORG_JSON='{"result":{"username":"admin@example.com","alias":"x"}}'
    export SF_INIT_JWT_INTERVAL=0
export SF_INIT_LOGIN_URL_PROD=login   # ログイン先を、質問せずに指定する

    # 引数: 前回の完了 Phase / リポジトリ / sf-init.sh の引数 / 標準入力（printf %b） / 追加の .sf-init.env の行（省略可）
    #   前回の状態（.sf-init.env）を作ってから、sf-init.sh を実行する
    _rc_run() {
        local done_phase="$1" repo="$2" args="$3" input="$4"
        init_base=$(_setup_init_dir "tamashimon" "testproject")
        init_dir="$init_base/home/tamashimon/testproject"
        envf="$init_dir/admin/.sf-init-testproject.env"; progf="$init_dir/admin/.sf-init-testproject.progress"
        mkdir -p "$init_dir/admin"
        {
            printf 'GITHUB_OWNER="tamashimon"\nPROJECT_NAME="testproject"\nREPO_NAME="force-testproject"\n'
            printf 'REPO_FULL_NAME="%s"\nBRANCH_COUNT="1"\n' "$repo"   # REPO_DIR は、5 番目の引数で渡す（既定は入れない）
            [[ -n "${5:-}" ]] && printf '%s\n' "${5//@INIT@/$init_dir/admin}"   # 追加の行（@INIT@ は、管理者用フォルダ（admin）のパスに置き換える）
        } > "$envf"
        [[ "${5:-}" == *REPO_DIR* ]] && mkdir -p "$init_dir/admin/force-testproject"
        printf 'SF_INIT_DONE_PHASE=%s\nSF_INIT_DONE_AT="2026-10-11 14:32"\n' "$done_phase" > "$progf"
        [[ -n "${6:-}" ]] && printf '%b\n' "$6" >> "$progf"   # 進捗ファイルに追加する行（段階ごとの完了の記録など）
        rm -rf "$mb/deployed_src" "$mb/jwt.cnt" "$mock_home/.sf-jwt" "$mb/.repo_view_called"
        if [[ -n "${7:-}" ]]; then   # 7 番目の引数: 既存の JWT 証明書を、先に作っておく（再利用 / 再生成の質問が出る）
            mkdir -p "$mock_home/.sf-jwt/force-testproject"
            printf 'OLD-KEY
' > "$mock_home/.sf-jwt/force-testproject/server.key"
            printf 'OLD-CRT
' > "$mock_home/.sf-jwt/force-testproject/server.crt"
        fi
        : > "$MOCK_CALL_LOG"
        # shellcheck disable=SC2086
        printf '%b' "$input" \
            | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
                  bash "$mock_home/sf-tools/bin/sf-init.sh" $args ) > "$out" 2>&1
        exit_code=$?
    }

    # [1] 続きをやる: Phase 1 を実行したうえで、Phase 10 だけを実行する（Y=警告 / 1=続き / 2=外部クライアントアプリ / N=Sandbox?）
    _rc_run 9 "tamashimon/force-testproject" "" 'Y\n1\n'   # ログイン先は、環境変数（SF_INIT_LOGIN_URL_PROD=login）で指定する
    assert_exit_ok            "$exit_code"                                                  "[1] 続き: 正常終了する"
    assert_file_contains      "$out" "前回のセットアップは、「リポジトリの設定」まで完了しています"   "続き: 前回の進捗が表示される"
    assert_file_contains      "$out" "2026-10-11 14:32"                                     "続き: 前回の時刻が表示される"
    assert_file_contains      "$out" "「Salesforce の接続」から、続きをやる"                                 "続き: 選択肢に次の Phase が表示される"
    assert_file_contains      "$MOCK_CALL_LOG" "gh auth status"                              "続き: Phase 1（環境チェック）は実行される"
    assert_file_not_contains  "$out" "ステップ 2 / 9: プロジェクトの確認"                          "続き: Phase 2〜9 は実行しない"
    assert_file_contains      "$out" "ステップ 8 / 9: Salesforce の接続"                                           "続き: Phase 10 から実行される"
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"          "続き: Phase 10 の処理が実行される"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh repo create"                              "続き: リポジトリを作り直さない"
    assert_file_not_exists    "$progf"                                                        "続き: 完了後、進捗ファイルは消える"
    assert_file_not_exists    "$envf"                                                         "続き: 完了後、状態ファイル（.env）も消える"
    rm -rf "$init_base"

    # [1] 続き（Phase 8 まで完了と記録）なのに、origin に main がない → 続けない（main のないまま、完了と表示しない）
    export MOCK_GH_BRANCH_MAIN_EXIT=1
    _rc_run 9 "tamashimon/force-testproject" "" 'Y
1
'
    assert_exit_fail          "$exit_code"                                                  "main なし: 続きを選んでも、失敗で終わる"
    assert_file_contains      "$out" "main ブランチを確認できません"                                "main なし: 理由が表示される"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"          "main なし: Phase 10 の処理は、実行されない"
    assert_file_contains      "$progf" "SF_INIT_DONE_PHASE=9"                                 "main なし: 保存した状態は、消さない"
    rm -rf "$init_base"
    unset MOCK_GH_BRANCH_MAIN_EXIT

    # [q] 中断: 何も実行しない
    _rc_run 5 "tamashimon/force-testproject" "" 'Y\nq\n'
    assert_exit_fail          "$exit_code"                                                  "[q] 中断: 非ゼロで終了する"
    assert_file_contains      "$out" "前回のセットアップは、「ブランチの構成」まで完了しています"          "q: 質問が表示される"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh auth status"                              "q: Phase 1 も実行しない"
    assert_file_contains      "$progf" "SF_INIT_DONE_PHASE=5"                                 "q: 保存した状態は、消さない"
    rm -rf "$init_base"

    # [2] 最初からやり直す: 保存した状態を消して、Phase 1 から（Y=警告 / 2=最初から / 以降は、通常の全 Phase の入力）
    _rc_run 5 "tamashimon/force-testproject" "--legacy-connected-app" "Y\n2\n$(_make_input_3branches | sed '1d')"
    assert_exit_ok            "$exit_code"                                                  "[2] 最初から: 正常終了する"
    assert_file_contains      "$out" "ステップ 2 / 9: プロジェクトの確認"                          "最初から: Phase 2 から実行される"
    assert_file_contains      "$MOCK_CALL_LOG" "gh repo create"                              "最初から: Phase 3 が実行される"
    assert_file_not_exists    "$progf"                                                        "最初から: 完了後、進捗ファイルは消える"
    rm -rf "$init_base"

    # 質問が出ない: リポジトリが、この作業フォルダのものではない
    _rc_run 5 "other/force-other" "" 'Y\n'
    assert_file_not_contains  "$out" "前回のセットアップは"                                   "別のリポジトリの状態 → 質問しない（最初から）"
    [[ ! -e "$envf" ]] && pass "別のリポジトリの状態 → 残骸として消す" || fail "別のリポジトリの状態 → 残骸として消す"
    rm -rf "$init_base"

    # 完了済み（Phase 10）: 「続きをやる」ではなく、完了済みの案内を出す。[q] 終了: 何も実行しない・状態を消さない
    _rc_run 10 "tamashimon/force-testproject" "" 'Y\nq\n'
    assert_exit_ok            "$exit_code"                                                  "完了済み・q: 正常終了する"
    assert_file_contains      "$out" "セットアップが、すでに完了しています"                       "完了済み: 完了済みであることが表示される"
    assert_file_not_contains  "$out" "から、続きをやる"                                        "完了済み: 「続きをやる」は出さない"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh repo create"                              "完了済み・q: 何も実行しない"
    assert_file_contains      "$progf" "SF_INIT_DONE_PHASE=10"                                "完了済み・q: 保存した状態は、消さない"
    rm -rf "$init_base"

    # 完了済み・[1] 接続を見る: 管理者用のフォルダで status.sh が実行される（何も変更しない）
    printf '#!/bin/bash\necho "STATUS-STUB cwd=$PWD"\nexit 0\n' > "$mock_home/sf-tools/phases/init/status.sh"
    _rc_run 10 "tamashimon/force-testproject" "" 'Y\n1\n' 'REPO_DIR="@INIT@/force-testproject"'
    assert_exit_ok            "$exit_code"                                                  "完了済み・1: 正常終了する"
    assert_file_contains      "$out" "STATUS-STUB cwd="                                       "完了済み・1: 接続の確認（status.sh）が実行される"
    assert_file_contains      "$out" "admin/force-testproject"                                 "完了済み・1: 管理者用のフォルダで実行される"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh repo create"                              "完了済み・1: 何も変更しない"
    rm -rf "$init_base"

    # 完了済み・[2] 動作を確認する: 管理者用のフォルダで verify.sh を実行し、その終了コードで終わる（何も作り直さない）
    printf '#!/bin/bash\necho "VERIFY-FROM-MENU cwd=$(basename "$PWD")"\nexit 0\n' > "$mock_home/sf-tools/phases/init/verify.sh"
    chmod +x "$mock_home/sf-tools/phases/init/verify.sh"
    _rc_run 10 "tamashimon/force-testproject" "" 'Y\n2\n' 'REPO_DIR="@INIT@/force-testproject"'
    assert_exit_ok            "$exit_code"                                                  "完了済み・2: 正常終了する"
    assert_file_contains      "$out" "VERIFY-FROM-MENU cwd=force-testproject"                  "完了済み・2: 管理者用のフォルダで、verify.sh が実行される"
    assert_file_contains      "$out" "動作を、確認する"                                        "完了済み: 選択肢に、動作の確認が、表示される"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh repo create"                              "完了済み・2: 何も作り直さない"
    rm -rf "$init_base"
    printf '#!/bin/bash\nexit 1\n' > "$mock_home/sf-tools/phases/init/verify.sh"
    _rc_run 10 "tamashimon/force-testproject" "" 'Y\n2\n' 'REPO_DIR="@INIT@/force-testproject"'
    assert_exit_fail          "$exit_code"                                                  "完了済み・2: verify.sh が失敗すれば、非ゼロで終了する"
    rm -rf "$init_base"

    # 完了済みのプロジェクトで、--resume N を明示 → 拒否する（接続処理を、確認なしで、やり直さない）
    _rc_run 10 "tamashimon/force-testproject" "--resume 10" 'Y\n'
    assert_exit_fail          "$exit_code"                                                  "完了済み・--resume 10: 拒否される"
    assert_file_contains      "$out" "完了済みのプロジェクトでは、--resume は使えません"          "完了済み・--resume 10: 理由が表示される"
    assert_file_contains      "$out" "sf-init.sh --reconnect"                                   "完了済み・--resume 10: --reconnect が案内される"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh secret set"                              "完了済み・--resume 10: 何も登録しない"
    rm -rf "$init_base"
    # 境界: 完了済み・--resume 2 も拒否される（N > 1 は、すべて）
    _rc_run 10 "tamashimon/force-testproject" "--resume 2" 'Y\n'
    assert_exit_fail          "$exit_code"                                                  "完了済み・--resume 2: 拒否される"
    assert_file_contains      "$out" "完了済みのプロジェクトでは、--resume は使えません"          "完了済み・--resume 2: 理由が表示される"
    rm -rf "$init_base"
    # 境界: 別のリポジトリの状態は、拒否しない（残骸として、扱う）
    _rc_run 10 "other/force-other" "--resume 2" 'Y\n'
    assert_file_not_contains  "$out" "完了済みのプロジェクトでは、--resume は使えません"          "別のリポジトリの状態・--resume: 拒否しない"
    rm -rf "$init_base"
    # 境界: 完了済み・--only 10 は、拒否しない（デバッグ用）
    _rc_run 10 "tamashimon/force-testproject" "--only 10" 'Y\n'
    assert_file_not_contains  "$out" "完了済みのプロジェクトでは、--resume は使えません"          "完了済み・--only 10: 拒否しない"
    rm -rf "$init_base"
    # 未完了なら、--resume N は、これまでどおり使える
    _rc_run 9 "tamashimon/force-testproject" "--resume 10" 'Y\n'
    assert_exit_ok            "$exit_code"                                                  "未完了・--resume 10: 実行できる"
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"          "未完了・--resume 10: Phase 10 が実行される"
    rm -rf "$init_base"

    # --only: 進捗を更新しない旨が、表示される。段階ごとの記録も、しない
    _rc_run 9 "tamashimon/force-testproject" "--only 10" 'Y\n'
    assert_file_contains      "$out" "--only は、指定した Phase だけを実行します。進捗は、更新しません"  "--only: 進捗を更新しない旨が、表示される"
    assert_file_not_contains  "$progf" "SF_INIT_DONE_TIER_"                                  "--only: 段階ごとの完了を、記録しない"
    rm -rf "$init_base"

    # Phase 10 の段階ごとの再開: 前回、main が完了していて、Secret も、あるなら、main をスキップして、staging だけ行う
    export SF_INIT_LOGIN_URL_STG=login
    export MOCK_GH_SECRETS=$'SF_CONSUMER_KEY_PROD'
    _rc_run 9 "tamashimon/force-testproject" "" 'Y\n1\n' 'BRANCH_COUNT="2"' 'SF_INIT_DONE_TIER_PROD=1'
    assert_exit_ok            "$exit_code"                                                  "段階ごとの再開: 正常終了する"
    assert_file_contains      "$out" "メイン組織（PROD）は、前回、設定が完了しているため、スキップします"  "段階ごとの再開: 完了した段階を、スキップする"
    assert_file_not_contains  "$MOCK_CALL_LOG" "alias sf-tools-PROD"                         "段階ごとの再開: main の組織には、ログインし直さない"
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_STG"           "段階ごとの再開: 残りの段階（staging）は、実行される"
    assert_file_not_contains  "$progf" "SF_INIT_DONE_TIER_"                                  "段階ごとの再開: 完了後、段階ごとの記録は、消える（Phase 10 の完了に、置き換わる）"
    rm -rf "$init_base"
    # 既存の証明書を「再利用する」なら、完了済みの段階は、スキップのまま（秘密鍵が変わらないため）
    _rc_run 9 "tamashimon/force-testproject" "" 'Y
1
Y
' 'BRANCH_COUNT="2"' 'SF_INIT_DONE_TIER_PROD=1' 1
    assert_file_contains      "$out" "メイン組織（PROD）は、前回、設定が完了しているため、スキップします"  "証明書を再利用: 完了済みの段階は、スキップする"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"          "証明書を再利用: 完了済みの段階は、登録しなおさない"
    rm -rf "$init_base"
    # 回帰: 既存の証明書を「再生成する（N）」なら、完了済みの段階も、設定しなおす（以前は、スキップされ、
    #   その段階の組織に古い証明書が残り、新しい秘密鍵（SF_PRIVATE_KEY）と合わなくなっていた）
    _rc_run 9 "tamashimon/force-testproject" "" 'Y
1
N
' 'BRANCH_COUNT="2"' 'SF_INIT_DONE_TIER_PROD=1' 1
    assert_exit_ok            "$exit_code"                                                  "証明書を再生成: 正常終了する"
    assert_file_contains      "$out" "証明書を作り直したため、前回、設定が完了した段階も、設定しなおします"  "証明書を再生成: 設定しなおす旨が表示される"
    assert_file_not_contains  "$out" "メイン組織（PROD）は、前回、設定が完了しているため、スキップします"  "証明書を再生成: 完了済みの段階を、スキップしない"
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"          "証明書を再生成: 完了済みの段階も、登録しなおす"
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_STG"           "証明書を再生成: 残りの段階も、登録する"
    rm -rf "$init_base"
    # 記録があっても、Secret が、もうなければ、やり直す（記録だけを、信じない）
    export MOCK_GH_SECRETS=""
    _rc_run 9 "tamashimon/force-testproject" "" 'Y\n1\n' 'BRANCH_COUNT="2"' 'SF_INIT_DONE_TIER_PROD=1'
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"          "記録があっても、Secret がなければ、その段階を、やり直す"
    rm -rf "$init_base"
    # Secret の一覧を取得できないときは、スキップせずに、実行する（理由を表示する）
    export MOCK_GH_SECRET_LIST_EXIT=1
    _rc_run 9 "tamashimon/force-testproject" "" 'Y\n1\n' 'BRANCH_COUNT="2"' 'SF_INIT_DONE_TIER_PROD=1'
    assert_file_contains      "$out" "Secret の一覧を確認できないため、PROD の段階は、スキップせずに、実行します"  "一覧を取得できない: 理由が表示される"
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"          "一覧を取得できない: その段階を、実行する（誤ってスキップしない）"
    unset MOCK_GH_SECRET_LIST_EXIT
    rm -rf "$init_base"
    # 記録がなければ、すべての段階を、実行する
    export MOCK_GH_SECRETS=$'SF_CONSUMER_KEY_PROD'
    _rc_run 9 "tamashimon/force-testproject" "" 'Y\n1\n' 'BRANCH_COUNT="2"'
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"          "記録がなければ、Secret があっても、実行する（前回の続きではない）"
    rm -rf "$init_base"
    unset MOCK_GH_SECRETS SF_INIT_LOGIN_URL_STG

    # 動作の確認の質問: --resume N では、聞かない（通しの実行と、中断後の「続きをやる」だけ）
    printf '#!/bin/bash\necho VERIFY-CALLED >> "%s/verify.log"\n' "$mb" > "$mock_home/sf-tools/phases/init/verify.sh"
    chmod +x "$mock_home/sf-tools/phases/init/verify.sh"
    export SF_INIT_VERIFY_ASK=1
    rm -f "$mb/verify.log"
    _rc_run 9 "tamashimon/force-testproject" "--resume 10" 'Y\n\n'
    assert_file_not_contains  "$out" "ステップ 9 / 9: 動作の確認"                              "--resume 10: 動作の確認を、聞かない"
    assert_file_not_exists    "$mb/verify.log"                                                "--resume 10: verify.sh を呼ばない"
    rm -rf "$init_base"
    # 中断後の「続きをやる」では、聞く（Enter = 確認する）
    _rc_run 9 "tamashimon/force-testproject" "" 'Y\n1\n\n'
    assert_file_contains      "$out" "ステップ 9 / 9: 動作の確認"                              "続きをやる: 動作の確認を、聞く"
    # 診断: 失敗したときだけ、そのときの画面出力と標準入力の読まれ方を、ログに出す（Windows の Git Bash で、パイプの
    #   Enter が、確認の質問に届かなかった原因を、Actions のログから特定するため。通常は、何も出ない）
    if ! grep -q "VERIFY-CALLED" "$mb/verify.log" 2>/dev/null; then
        echo "    [診断] exit_code=${exit_code} / bash=${BASH_VERSION} / OSTYPE=${OSTYPE}"
        echo "    [診断] verify.log: $(head -c 300 "$mb/verify.log" 2>&1 | tr '\n' '|')"
        echo "    [診断] out.log の「動作の確認」付近（末尾 30 行。行頭の ' | ' は、診断の目印）:"
        tail -30 "$out" 2>&1 | sed 's/^/      | /' | cat -v | cut -c1-200
    fi
    assert_file_contains      "$mb/verify.log" "VERIFY-CALLED"                                 "続きをやる: Enter で、verify.sh を呼ぶ"
    rm -rf "$init_base"
    unset SF_INIT_VERIFY_ASK

    # 完了時の後始末: 状態ファイルを消す（残っていた Token の値の行も、一緒に消える）。admin フォルダ自体は、残す
    _rc_run 9 "tamashimon/force-testproject" "" 'Y\n1\n' 'PAT_TOKEN_VALUE="ghp_leftover"'
    assert_exit_ok            "$exit_code"                                                  "完了時の掃除: 正常終了する"
    assert_file_not_exists    "$envf"                                                         "完了時の掃除: 状態ファイル（Token の値の行を含む）が、消える"
    assert_file_not_exists    "$progf"                                                        "完了時の掃除: 進捗ファイルも、消える"
    assert_file_not_contains  "$out" "ghp_leftover"                                           "完了時の掃除: Token の値が、画面に出ない"
    assert_file_contains      "$out" "管理者用フォルダ"                                         "完了画面: 管理者用のフォルダを案内する"
    assert_file_not_contains  "$out" "削除してよいですか"                                      "admin フォルダの削除の質問は、出さない"
    rm -rf "$init_base"

    # 質問が出ない: --resume N を明示
    _rc_run 5 "tamashimon/force-testproject" "--resume 6" 'Y\n'
    assert_file_not_contains  "$out" "前回のセットアップは"                                   "--resume N → 質問しない（指定を優先）"
    assert_file_contains      "$out" "実行フェーズ: Phase 6"                                  "--resume 6 → Phase 6 から実行される"
    rm -rf "$init_base"

    # --only N: 進捗を記録しない
    _rc_run 5 "tamashimon/force-testproject" "--only 1" 'Y\n'
    assert_file_contains      "$progf" "SF_INIT_DONE_PHASE=5"                                 "--only → 進捗を書き換えない"
    rm -rf "$init_base"

    # 境界値: Phase 2 まで完了（次は、リポジトリの作成）
    _rc_run 2 "tamashimon/force-testproject" "" 'Y\nq\n'
    assert_file_contains      "$out" "前回のセットアップは、「プロジェクトの確認」まで完了しています"  "Phase 2 完了: 質問が出る"
    assert_file_contains      "$out" "「リポジトリの作成」から、続きをやる"                       "Phase 2 完了: 次は、リポジトリの作成"
    rm -rf "$init_base"

    # 境界値: Phase 8 まで完了（次は、リポジトリの設定）
    _rc_run 8 "tamashimon/force-testproject" "" 'Y\nq\n'
    assert_file_contains      "$out" "前回のセットアップは、「初回のコミット」まで完了しています"    "Phase 8 完了: 質問が出る"
    assert_file_contains      "$out" "「リポジトリの設定」から、続きをやる"                       "Phase 8 完了: 次は、リポジトリの設定"
    rm -rf "$init_base"

    # 境界値: 進捗ファイルが壊れている（数字ではない）・範囲外 → 質問しない（最初から）
    _rc_run abc "tamashimon/force-testproject" "" 'Y\n'
    assert_file_not_contains  "$out" "前回のセットアップは"                                   "壊れた進捗（abc）→ 質問しない"
    rm -rf "$init_base"
    _rc_run 1 "tamashimon/force-testproject" "" 'Y\n'
    assert_file_not_contains  "$out" "前回のセットアップは"                                   "Phase 1 のみ完了 → 質問しない（状態を持たないため）"
    rm -rf "$init_base"

    # 進捗ファイルがなく、.sf-init.env だけがある → 質問しない
    _rc_run 5 "tamashimon/force-testproject" "" 'Y\n'
    rm -f "$progf"
    printf 'Y\n' | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" bash "$mock_home/sf-tools/bin/sf-init.sh" ) > "$out" 2>&1
    assert_file_not_contains  "$out" "前回のセットアップは"                                   "進捗ファイルなし → 質問しない"
    rm -rf "$init_base"

    unset -f _rc_run
    unset MOCK_SF_ORG_JSON SF_INIT_JWT_INTERVAL MOCK_CALL_LOG SF_INIT_LOGIN_URL_PROD
    teardown "$mb" "$mock_home" "$init_base"
}

echo ""
echo -e "${CLR_HEAD}========================================"
echo "  sf-init.sh テスト（1/3）"
echo -e "========================================${CLR_RST}"

test_missing_tool_gh
test_unauthorized_user
test_flex_layout_prompt
test_admin_branch_failure_is_not_fatal
test_refuse_inside_admin_or_clone
test_finish_unfinished_setup
test_resume_state_case_insensitive
test_flex_invalid_project_arg
test_invalid_phase_args
test_resume_runs_from_specified_phase
test_add_tier_develop_without_staging
test_phase9_ruleset_id
test_phase7_channel_id
test_e2e_input_sequence
test_wf_no_script_injection
test_phase6_pat_token
test_resume_choice

print_summary
