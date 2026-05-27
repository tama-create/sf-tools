#!/bin/bash
# ==============================================================================
# test_sf-init.sh - sf-init.sh の単体テスト（モックベース）
# ==============================================================================
#
# 【テストケース】
#   1.  ハッピーパス（3ブランチ構成）- フルフロー正常終了
#   2.  必要なツール不足（gh なし）  - 環境チェックで失敗
#   3.  リポジトリ作成失敗           - gh repo create が exit 1 を返す
#   4.  Salesforce ログイン失敗      - sf org login が exit 1 を返す
#   5.  許可されていないユーザー     - check_authorized_user で失敗
#   6.  無効なフォルダ構成           - GitHub オーナー名バリデーション失敗
#   7.  リポジトリ visibility (Private) - 常に --private で作成
#   8.  --only 1 → Phase 1 のみ実行
#   9.  --only 2 → .sf-init.env が生成される
#   10. --only 9 → Phase 9 のみ実行
#   11. --add-tier staging → 正常終了・Secrets/Variables 登録
#   12. --add-tier staging → 既存ならエラー
#   13. --add-tier develop → staging なしはエラー
#   14. 不明なオプション → エラー終了
# ==============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

# ==============================================================================
# ヘルパー：{github-owner}/{company}/ 構造を作成
# （init/ は sf-init.sh が自動作成するため、ここでは作らない）
# 戻り値: ベースディレクトリのパス（teardown に渡す）
# ==============================================================================
_setup_init_dir() {
    local github_owner="${1:-tamashimon}"
    local company="${2:-testproject}"
    local base
    base=$(mktemp -d "${TMPDIR:-/tmp}/test-init-XXXX")
    mkdir -p "$base/home/$github_owner/$company"
    echo "$base"
}

# ==============================================================================
# ヘルパー：sf-init.sh 用 gh モック（repo view カウンター付き）
#
# 通常フロー:
#   - 1回目の "repo view" → exit 1（リポジトリ未存在 → create をトリガー）
#   - 2回目以降の "repo view" → exit 0（作成後の確認チェック）
#
# MOCK_GH_REPO_CREATE_EXIT が非ゼロの場合:
#   - "repo view" は常に exit 1（作成失敗を再現）
# ==============================================================================
create_mock_gh_for_init() {
    local bin_dir="$1"
    cat > "$bin_dir/gh" << 'GHEOF'
#!/bin/bash
echo "gh $*" >> "${MOCK_CALL_LOG:-/dev/null}"
case "$1 $2" in
    "auth status") exit "${MOCK_GH_AUTH_STATUS_EXIT:-0}" ;;
    "auth login")  exit "${MOCK_GH_AUTH_LOGIN_EXIT:-0}" ;;
    "repo view")
        # create が失敗設定の場合は常に「未存在」を返す
        if [[ -n "${MOCK_GH_REPO_CREATE_EXIT:-}" && "${MOCK_GH_REPO_CREATE_EXIT}" != "0" ]]; then
            exit 1
        fi
        # センチネル方式: 初回呼出しのみ exit 1（repo 未存在）、2回目以降 exit 0
        _sentinel="${MOCK_CALL_LOG%/*}/.repo_view_called"
        if [[ ! -f "$_sentinel" ]]; then
            touch "$_sentinel"
            exit 1
        fi
        exit 0 ;;
    "repo create") exit "${MOCK_GH_REPO_CREATE_EXIT:-0}" ;;
    "secret set")  exit "${MOCK_GH_SECRET_SET_EXIT:-0}" ;;
    "api user")    echo "${MOCK_GH_API_USER:-${github_owner}}" ;;
    *) exit 0 ;;
esac
GHEOF
    chmod +x "$bin_dir/gh"
}

# ==============================================================================
# ヘルパー：モックホームにサブスクリプトのスタブを設置
# ==============================================================================
_stub_subscripts() {
    local mock_home="$1"

    # sf-install.sh スタブ（何もしない）
    mkdir -p "$mock_home/sf-tools/bin"
    printf '#!/bin/bash\nexit 0\n' > "$mock_home/sf-tools/bin/sf-install.sh"
    chmod +x "$mock_home/sf-tools/bin/sf-install.sh"

    # sf-hook.sh スタブ（何もしない）
    printf '#!/bin/bash\nexit 0\n' > "$mock_home/sf-tools/bin/sf-hook.sh"
    chmod +x "$mock_home/sf-tools/bin/sf-hook.sh"

}

# ==============================================================================
# ヘルパー：3ブランチ構成用の stdin 入力シーケンス
#
# 入力順（sf-init.sh 冒頭の管理者警告）:
#   1. Y                  (ask_yn "続行しますか？" - read_key 1文字読み。\n は buffer 残留)
#   ★ \n は read_key [YyNnQq] が無効として読み飛ばし
# 入力順（Phase 2: プロジェクト情報確認）:
#   2. Y                  (ask_yn "よろしいですか？" - read_key 1文字読み。\n は buffer 残留)
#   ★ \n は read_key [12qQ] が無効として読み飛ばし
#   3. 1                  (ENV_TYPE 選択 "本番環境" - read_key [12qQ]。\n は buffer 残留)
# 入力順（Phase 5: ブランチ構成）:
#   ★ \n は read_key [1-3Qq] が無効として読み飛ばし
#   4. 1                  (main/staging/develop 選択 - read_key [1-3Qq]。\n は buffer 残留)
#   ★ 1\n の \n は次の press_enter が消費
# 入力順（Phase 6: PAT）:
#   5. \n                 (press_enter - PAT 取得案内。Phase 5 ブランチ選択残留 \n を消費)
#   6. ghp_faketoken      (PAT トークン - read_or_quit)
# 入力順（Phase 7: Slack）:
#   7. \n                 (press_enter - Bot Token 取得案内)
#   8. xoxb-faketoken     (Slack Bot Token - read_or_quit)
#   9. C01ABCDEFGH        (Slack チャンネル ID - read_or_quit)
#  10. \n                 (press_enter - Bot 招待完了確認)
# 入力順（Phase 10: JWT 認証）:
#  11. 1                  (アプリ種別選択 - read_key [12Qq]。接続アプリケーションを選択。\n は buffer 残留)
#  ★ \n は read_key [12Qq] が無効として読み飛ばし
#  12. \n                 (press_enter - Connected App 設定案内)
#  13. N                  (prod Sandbox? - ask_yn read_key。\n は buffer 残留)
#  ★ \n は read_or_quit が空行として無視
#  14. fake_prod_key      (prod コンシューマーキー - read_or_quit)
#  15. prod@example.com   (prod ユーザー名 - read_or_quit)
#  16. Y                  (staging Sandbox? - ask_yn read_key。\n は buffer 残留)
#  ★ \n は read_or_quit が空行として無視
#  17. fake_stg_key       (staging コンシューマーキー - read_or_quit)
#  18. stg@example.com    (staging ユーザー名 - read_or_quit)
#  19. Y                  (develop Sandbox? - ask_yn read_key)
#  20. fake_dev_key       (develop コンシューマーキー - read_or_quit)
#  21. dev@example.com    (develop ユーザー名 - read_or_quit)
#  22. N                  (init フォルダ削除をスキップ)
# ==============================================================================
_make_input_3branches() {
    printf 'Y\nY\n1\n1\nghp_faketoken\n\nxoxb-faketoken\nC01ABCDEFGH\n\n1\nN\nfake_prod_key\nprod@example.com\nY\nfake_stg_key\nstg@example.com\nY\nfake_dev_key\ndev@example.com\nN\n'
}

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
              bash "$mock_home/sf-tools/bin/sf-init.sh" ) \
          > /tmp/sf-init-test-happy.log 2>&1
    exit_code=$?

    assert_exit_ok   "$exit_code"                                                    "正常終了する"
    assert_file_contains "$MOCK_CALL_LOG" "gh auth status"                           "gh auth status が呼ばれる"
    assert_file_contains "$MOCK_CALL_LOG" "gh repo create"                           "gh repo create が呼ばれる"
    assert_file_contains "$MOCK_CALL_LOG" "git clone"                                "git clone が呼ばれる"
    assert_file_exists   "$init_dir/init/force-testproject/.github/workflows/wf-validate.yml"  "WF ファイル(wf-validate.yml)がコピーされる"
    assert_file_exists   "$init_dir/init/force-testproject/.github/workflows/wf-release.yml"   "WF ファイル(wf-release.yml)がコピーされる"
    assert_file_contains "$MOCK_CALL_LOG" "sf org login"                             "sf org login jwt が呼ばれる"
    assert_file_contains "$MOCK_CALL_LOG" "gh secret set SF_PRIVATE_KEY"             "SF_PRIVATE_KEY が登録される"
    assert_file_contains "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"       "SF_CONSUMER_KEY_PROD が登録される"
    assert_file_contains "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_STG"        "SF_CONSUMER_KEY_STG が登録される"
    assert_file_contains "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_DEV"        "SF_CONSUMER_KEY_DEV が登録される"
    assert_file_contains "$MOCK_CALL_LOG" "gh secret set PAT_TOKEN"                  "PAT_TOKEN が登録される"
    assert_file_contains "$MOCK_CALL_LOG" "gh secret set SLACK_BOT_TOKEN"            "SLACK_BOT_TOKEN が登録される"
    assert_file_contains "$MOCK_CALL_LOG" "gh variable set SLACK_CHANNEL_ID"          "SLACK_CHANNEL_ID が登録される"
    assert_file_contains "$MOCK_CALL_LOG" "git add"                                  "git add が呼ばれる"

    teardown "$mb" "$mock_home" "$init_base"
    rm -f /tmp/sf-init-test-happy.log
}

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
    printf 'Y\nY\n1\n1\nghp_faketoken\n\nxoxb-faketoken\nC01ABCDEFGH\n\n1\nN\nfake_prod_key\nprod@example.com\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" ) > /dev/null 2>&1
    exit_code=$?

    assert_exit_fail "$exit_code"                                              "SF ログイン失敗で非ゼロ終了する"
    assert_file_contains "$MOCK_CALL_LOG" "sf org login"                      "sf org login jwt が試みられる"

    unset MOCK_SF_LOGIN_EXIT
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
    assert_file_exists   "$init_dir/init/.sf-init.env"                                    ".sf-init.env が生成される"
    assert_file_contains "$init_dir/init/.sf-init.env" "REPO_FULL_NAME"                  ".sf-init.env に REPO_FULL_NAME が含まれる"
    assert_file_contains "$init_dir/init/.sf-init.env" "tamashimon/force-testproject"    "正しい REPO_FULL_NAME が書き出される"

    teardown "$mb" "$mock_home" "$init_base"
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
    mkdir -p "$init_dir/init"
    cat > "$init_dir/init/.sf-init.env" << 'ENVEOF'
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

    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"

    # git remote を返す git モックを追加
    cat > "$mb/git" << 'GITEOF'
#!/bin/bash
echo "git $*" >> "${MOCK_CALL_LOG:-/dev/null}"
case "$1 $2" in
    "remote get-url") echo "https://github.com/tamashimon/force-testproject.git" ;;
    "ls-remote --exit-code") exit 1 ;;  # ブランチ未存在
    *) exit 0 ;;
esac
GITEOF
    chmod +x "$mb/git"

    local exit_code
    # staging Sandbox? → コンシューマーキー → ユーザー名 の順
    printf 'Y\nfake_stg_key\nstg@example.com\n' \
        | ( cd "$force_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --add-tier staging ) \
          > /tmp/sf-init-add-tier.log 2>&1
    exit_code=$?

    assert_exit_ok   "$exit_code"                                                   "正常終了する"
    assert_file_contains "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_STG"       "SF_CONSUMER_KEY_STG が登録される"
    assert_file_contains "$MOCK_CALL_LOG" "gh variable set SF_USERNAME_STG"         "SF_USERNAME_STG が登録される"
    assert_file_contains "$MOCK_CALL_LOG" "gh variable set SF_INSTANCE_URL_STG"     "SF_INSTANCE_URL_STG が登録される"
    assert_file_contains "$force_dir/sf-tools/config/branches.txt" "staging"        "branches.txt に staging が追記される"

    teardown "$mb" "$mock_home"
    rm -rf "$base_dir" /tmp/sf-init-add-tier.log
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
          bash "$mock_home/sf-tools/bin/sf-init.sh" --add-tier staging ) > /dev/null 2>&1
    exit_code=$?

    assert_exit_fail "$exit_code" "既存 tier は失敗終了する"

    teardown "$mb" "$mock_home"
    rm -rf "$base_dir"
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
# テスト実行
# ==============================================================================
echo ""
echo -e "${CLR_HEAD}========================================"
echo "  sf-init.sh テスト"
echo -e "========================================${CLR_RST}"

test_happy_path_3branches
test_missing_tool_gh
test_repo_create_failure
test_sf_login_failure
test_unauthorized_user
test_invalid_owner_folder
test_repo_visibility_private
test_only_option_runs_single_phase
test_only_phase2_creates_env_file
test_resume_runs_from_specified_phase
test_add_tier_staging_happy
test_add_tier_staging_already_exists
test_add_tier_develop_without_staging
test_unknown_option_fails

print_summary
