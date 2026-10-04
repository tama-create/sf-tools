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
#   15. 環境種別の選択（本番 / 検証で続行 / 検証を取り消して選び直し / 検証で中断）
#   16. Phase 11（SF_TOOLS_TOKEN）: 登録 / 読み取り失敗で再入力 / 読み取り失敗でスキップ / q で中断
#   17. Phase 9: 既存 Ruleset の ID 検証（403 のエラー本文を ID として扱わない / 数字の ID は削除）
#   18. Phase 7: SLACK_CHANNEL_ID の形式チェック（C… / G… のみ受け付け。D… / U… は拒否して再入力）
#   19. Phase 10: 外部クライアントアプリの自動作成（正常 / JWT リトライ / deploy 失敗 / JWT 不成功で中断・スキップ）
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
    "variable set")
        # --body で値が渡される場合は何もしない（標準入力を読むと、テストの入力列を消費してしまう）
        case " $* " in *" --body "*) exit 0 ;; esac
        # 標準入力で渡された値を、変数名ごとのファイルに保存する（テストで値を検証するため）
        cat > "${MOCK_CALL_LOG%/*}/var_$3.txt"; exit 0 ;;
    "api repos/"*)
        # Ruleset 一覧: MOCK_GH_RULESETS=error → エラー本文を標準出力に出して exit 1（無料プランの 403 を再現）、
        #               MOCK_GH_RULESETS=id    → 既存の Ruleset の ID（12345）を返す
        if [[ "$2" == */rulesets ]]; then
            case "${MOCK_GH_RULESETS:-none}" in
                error) echo '{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature.","status":"403"}'; exit 1 ;;
                id)    echo "12345"; exit 0 ;;
                *)     exit 0 ;;
            esac
        fi
        # Phase 11 の読み取り確認: Token（環境変数 GH_TOKEN）が "badtoken" で始まる場合、または
        # MOCK_GH_API_REPO_EXIT が非ゼロの場合は失敗させる
        [[ "${GH_TOKEN:-}" == badtoken* ]] && exit 1
        exit "${MOCK_GH_API_REPO_EXIT:-0}" ;;
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
# 入力順（Phase 11: SF_TOOLS_TOKEN）:
#  22. \n                 (press_enter - Token 作成案内)
#  23. ghp_faketoolstoken (SF_TOOLS_TOKEN - read_secret。画面に表示されない)
#  24. N                  (init フォルダ削除をスキップ)
# ==============================================================================
_make_input_3branches() {
    printf 'Y\nY\n1\n1\nghp_faketoken\n\nxoxb-faketoken\nC01ABCDEFGH\n\n1\nN\nfake_prod_key\nprod@example.com\nY\nfake_stg_key\nstg@example.com\nY\nfake_dev_key\ndev@example.com\n\nghp_faketoolstoken\nN\n'
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
    assert_file_contains "$MOCK_CALL_LOG" "gh secret set SF_TOOLS_TOKEN"             "SF_TOOLS_TOKEN が登録される"
    assert_file_not_contains "$MOCK_CALL_LOG" "ghp_faketoolstoken"                   "SF_TOOLS_TOKEN の値がコマンドのログに含まれない"
    assert_file_not_contains "$MOCK_CALL_LOG" "ghp_faketoken"                        "PAT_TOKEN の値がコマンド（git push 等）のログに含まれない"
    assert_file_not_contains "$MOCK_CALL_LOG" "--body fake_prod_key"                 "コンシューマー鍵を --body（コマンドの引数）で渡さない（標準入力で渡す）"
    assert_file_contains "$MOCK_CALL_LOG" "git -c credential.helper= push"           "Phase 8: 認証ヘルパーを無効化して push する"
    assert_file_not_contains "$init_dir/init/.sf-init.env" "PAT_TOKEN_VALUE"         "push 後に .sf-init.env から PAT が削除される"
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
    env_file="$init_dir/init/.sf-init.env"
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
    env_file="$init_dir/init/.sf-init.env"
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
    env_file="$init_dir/init/.sf-init.env"
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
    env_file="$init_dir/init/.sf-init.env"
    printf 'Y\nY\n2\nq\n' \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" --only 2 ) > /dev/null 2>&1
    exit_code=$?
    assert_exit_fail        "$exit_code"   "2 → q → 中断（異常終了）"
    assert_file_not_exists  "$env_file"    "2 → q → .sf-init.env は生成されない"

    teardown "$mb" "$mock_home" "$init_base"
}

# ==============================================================================
# テスト 16: Phase 11（SF_TOOLS_TOKEN）— --only 11 で単体実行
#   入力列: 警告確認 Y →（\n は press_enter が消費）→ Token ...
#   - 正常                : Token で読み取れる → SF_TOOLS_TOKEN が登録される
#   - 失敗 → Y → 再入力   : 1回目の Token で読めず、入力し直して成功 → 登録される
#   - 失敗 → N            : 登録をスキップして正常終了（SF_TOOLS_TOKEN は登録されない）
#   - q                   : 中断（登録されない）
#   いずれも Token の値が MOCK_CALL_LOG（コマンドのログ）に含まれないこと
# ==============================================================================
test_phase11_sf_tools_token() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] Phase 11: SF_TOOLS_TOKEN（登録 / 再入力 / スキップ / 中断）${CLR_RST}"

    local mb mock_home init_base init_dir exit_code
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"
    mock_home=$(setup_mock_home)
    create_all_mocks "$mb"
    create_mock_gh_for_init "$mb"
    _stub_subscripts "$mock_home"

    # ケースごとに init フォルダと .sf-init.env（REPO_DIR なし = 最後の削除確認が出ない）を用意して実行する
    _p11_run() {
        init_base=$(_setup_init_dir "tamashimon" "testproject")
        init_dir="$init_base/home/tamashimon/testproject"
        mkdir -p "$init_dir/init"
        printf 'REPO_FULL_NAME="tamashimon/force-testproject"\nPROJECT_NAME="testproject"\n' > "$init_dir/init/.sf-init.env"
        : > "$MOCK_CALL_LOG"
        printf '%b' "$1" \
            | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
                  bash "$mock_home/sf-tools/bin/sf-init.sh" --only 11 ) > /dev/null 2>&1
        exit_code=$?
    }

    # 正常
    _p11_run 'Y\nghp_goodtoken\n'
    assert_exit_ok       "$exit_code"                                                 "正常 → 終了コード 0"
    assert_file_contains "$MOCK_CALL_LOG" "gh secret set SF_TOOLS_TOKEN"              "正常 → SF_TOOLS_TOKEN が登録される"
    assert_file_not_contains "$MOCK_CALL_LOG" "ghp_goodtoken"                         "正常 → Token の値がコマンドのログに含まれない"
    rm -rf "$init_base"

    # 失敗 → Y → 再入力
    _p11_run 'Y\nbadtoken_first\nY\nghp_secondtoken\n'
    assert_exit_ok       "$exit_code"                                                 "失敗 → 再入力 → 終了コード 0"
    assert_file_contains "$MOCK_CALL_LOG" "gh secret set SF_TOOLS_TOKEN"              "失敗 → 再入力 → SF_TOOLS_TOKEN が登録される"
    assert_file_not_contains "$MOCK_CALL_LOG" "badtoken_first"                        "失敗した Token の値もログに含まれない"
    rm -rf "$init_base"

    # 失敗 → N: スキップ
    _p11_run 'Y\nbadtoken_only\nN\n'
    assert_exit_ok       "$exit_code"                                                 "失敗 → N → 正常終了（スキップ）"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh secret set SF_TOOLS_TOKEN"          "失敗 → N → SF_TOOLS_TOKEN は登録されない"
    rm -rf "$init_base"

    # q: 中断
    _p11_run 'Y\nq\n'
    assert_exit_fail     "$exit_code"                                                 "q → 中断（異常終了）"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh secret set SF_TOOLS_TOKEN"          "q → SF_TOOLS_TOKEN は登録されない"

    unset -f _p11_run
    teardown "$mb" "$mock_home" "$init_base"
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
        mkdir -p "$init_dir/init"
        printf 'GITHUB_OWNER="tamashimon"\nPROJECT_NAME="testproject"\nREPO_NAME="force-testproject"\nREPO_FULL_NAME="tamashimon/force-testproject"\n' \
            > "$init_dir/init/.sf-init.env"
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
        mkdir -p "$init_dir/init"
        printf 'REPO_FULL_NAME="tamashimon/force-testproject"\nPROJECT_NAME="testproject"\n' > "$init_dir/init/.sf-init.env"
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
# テスト 19: Phase 10 — 外部クライアントアプリ（ECA）の自動作成（--only 10）
#   入力列: 警告確認 Y → アプリ種別 2 → メイン組織は Sandbox? N（ブランチ構成 1 階層 = メイン組織のみ）
#   - 正常                  : ブラウザログイン → deploy → 鍵を retrieve → JWT → 登録。メタデータの内容も検証
#   - ログイン成功 + 終了コード 1 : login / display とも終了コード 1 でも、出力の username が取れれば成功とみなして続行
#                                   （Windows の sf で実際に発生。終了コードは見ない）
#   - ログイン失敗          : 接続情報が取れなければ中断。deploy・登録は行われない
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

    _p10_run() {
        init_base=$(_setup_init_dir "tamashimon" "testproject")
        init_dir="$init_base/home/tamashimon/testproject"
        mkdir -p "$init_dir/init"
        printf 'REPO_FULL_NAME="tamashimon/force-testproject"\nREPO_NAME="force-testproject"\nPROJECT_NAME="testproject"\nBRANCH_COUNT="1"\n' \
            > "$init_dir/init/.sf-init.env"
        # 前のケースで生成された証明書が残ると「既存の証明書を再利用しますか？」の確認が出て入力列がずれるため消す
        rm -rf "$mb/deployed_src" "$mb/jwt.cnt" "$mock_home/.sf-jwt"
        : > "$MOCK_CALL_LOG"
        printf '%b' "$1" \
            | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
                  bash "$mock_home/sf-tools/bin/sf-init.sh" --only 10 ) > "$out" 2>&1
        exit_code=$?
    }

    # 正常
    _p10_run 'Y\n2\nN\n'
    assert_exit_ok            "$exit_code"                                                              "正常 → 終了コード 0"
    assert_file_contains      "$MOCK_CALL_LOG" "sf org login web --instance-url https://login.salesforce.com --alias sf-tools-PROD" "ブラウザでログインする（一時エイリアス）"
    assert_file_contains      "$MOCK_CALL_LOG" "sf alias unset sf-tools-PROD"                             "ログイン前に前回の一時エイリアスを外す"
    assert_file_contains      "$MOCK_CALL_LOG" "sf project deploy start --source-dir force-app"          "メタデータを deploy する"
    assert_file_contains      "$MOCK_CALL_LOG" "ExtlClntAppGlobalOauthSettings:SF_TOOLS_force_testproject_glbloauth" "コンシューマー鍵を retrieve で取得する"
    assert_file_contains      "$MOCK_CALL_LOG" "sf org login jwt"                                         "JWT 接続テストを行う"
    assert_file_contains      "$MOCK_CALL_LOG" "sf alias unset sf-tools-PROD"                             "一時エイリアスを sf alias unset で消す"
    assert_file_not_contains  "$MOCK_CALL_LOG" "org logout"                                               "sf org logout は使わない"
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

    # ログインは成功するが sf の終了コードが 1（Windows で実際に発生。org display も終了コード 1）→ 出力で判定して続行
    MOCK_SF_LOGIN_WEB_EXIT=1 MOCK_SF_ORG_DISPLAY_EXIT=1 _p10_run 'Y\n2\nN\n'
    assert_exit_ok            "$exit_code"                                                              "ログイン成功 + 終了コード 1（login / display とも）→ 続行して終了コード 0"
    assert_file_contains      "$MOCK_CALL_LOG" "project deploy start"                                     "ログイン成功 + 終了コード 1 → deploy まで進む"
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"                       "ログイン成功 + 終了コード 1 → 登録される"
    rm -rf "$init_base"

    # ログイン失敗（待ち時間切れなどで接続できていない）→ 中断
    MOCK_SF_LOGIN_WEB_FAIL=1 _p10_run 'Y\n2\nN\n'
    assert_exit_fail          "$exit_code"                                                              "ログイン失敗 → 中断"
    assert_file_contains      "$out" "へのログインに失敗しました"                                          "ログイン失敗 → 失敗の旨が表示される"
    assert_file_not_contains  "$MOCK_CALL_LOG" "project deploy start"                                     "ログイン失敗 → deploy しない"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"                       "ログイン失敗 → 登録しない"
    rm -rf "$init_base"

    # JWT が最初の 2 回失敗 → リトライして成功
    MOCK_SF_JWT_FAIL_FIRST=2 _p10_run 'Y\n2\nN\n'
    jwt_calls=$(grep -c "^sf org login jwt" "$MOCK_CALL_LOG")
    assert_exit_ok            "$exit_code"                                                              "JWT リトライ → 終了コード 0"
    [[ "$jwt_calls" -eq 3 ]] && pass "JWT 接続テストを 3 回試行（2 回失敗 + 1 回成功）" || fail "JWT 接続テストを 3 回試行" "試行回数: ${jwt_calls}"
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"                       "リトライ成功後に登録される"
    rm -rf "$init_base"

    # deploy 失敗 → 中断
    MOCK_SF_DEPLOY_EXIT=1 _p10_run 'Y\n2\nN\n'
    assert_exit_fail          "$exit_code"                                                              "deploy 失敗 → 中断"
    assert_file_not_contains  "$MOCK_CALL_LOG" "project retrieve"                                         "deploy 失敗 → retrieve しない"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"                       "deploy 失敗 → 登録しない"
    rm -rf "$init_base"

    # JWT が成功しない → 確認で N → 中断
    MOCK_SF_JWT_FAIL_FIRST=99 SF_INIT_JWT_RETRIES=2 _p10_run 'Y\n2\nN\nN\n'
    assert_exit_fail          "$exit_code"                                                              "JWT 不成功 + スキップしない → 中断"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"                       "JWT 不成功 + スキップしない → 登録しない"
    rm -rf "$init_base"

    # JWT が成功しない → 確認で Y → スキップして登録
    MOCK_SF_JWT_FAIL_FIRST=99 SF_INIT_JWT_RETRIES=2 _p10_run 'Y\n2\nN\nY\n'
    assert_exit_ok            "$exit_code"                                                              "JWT 不成功 + スキップする → 終了コード 0"
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"                       "JWT 不成功 + スキップする → 登録される"

    unset -f _p10_run
    unset MOCK_SF_ORG_JSON SF_INIT_JWT_INTERVAL
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
    echo -e "${CLR_HEAD}[TEST] e2e の入力の台本で、sf-init が Phase 1〜11 を最後まで進む${CLR_RST}"

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
            E2E_SF_TOOLS_TOKEN=github_pat_faketools \
            bash -c "source '$SF_TOOLS_DIR/tests/e2e/lib.sh'; e2e_make_input")
    printf '%s\n' "$input" \
        | ( cd "$init_dir" && HOME="$mock_home" PATH="$mb:$PATH" \
              bash "$mock_home/sf-tools/bin/sf-init.sh" ) > "$mb/out.log" 2>&1
    exit_code=$?

    assert_exit_ok            "$exit_code"                                                          "台本で最後まで正常終了する"
    assert_file_contains      "$mb/out.log" "検証環境（sf-tools: development）"                      "環境種別は検証環境になる"
    assert_file_contains      "$MOCK_CALL_LOG" "gh variable set SF_TOOLS_BRANCH --body development"   "SF_TOOLS_BRANCH=development が登録される"
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set PAT_TOKEN"                              "PAT_TOKEN が登録される"
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SLACK_BOT_TOKEN"                        "SLACK_BOT_TOKEN が登録される"
    assert_file_contains      "$mb/var_SLACK_CHANNEL_ID.txt" "C01ABCDEFGH"                            "SLACK_CHANNEL_ID に、台本のチャンネル ID が登録される"
    assert_file_contains      "$MOCK_CALL_LOG" "sf org login web --instance-url https://login.salesforce.com --alias sf-tools-PROD" "メイン組織のログインが呼ばれる"
    assert_file_contains      "$MOCK_CALL_LOG" "project deploy start --source-dir force-app"          "外部クライアントアプリが作成される"
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"                   "SF_CONSUMER_KEY_PROD が登録される"
    assert_file_not_contains  "$MOCK_CALL_LOG" "SF_CONSUMER_KEY_STG"                                  "main のみの構成なので、ステージング組織は設定しない"
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SF_TOOLS_TOKEN"                         "SF_TOOLS_TOKEN が登録される"
    assert_dir_exists         "$init_dir/init"                                                        "最後の質問に N と答えて、init フォルダが残る（台本の最後までずれていない）"
    assert_file_not_contains  "$mb/out.log" "ghp_fakepat"                                            "PAT_TOKEN の値が出力に出ない"
    assert_file_not_contains  "$mb/out.log" "github_pat_faketools"                                   "SF_TOOLS_TOKEN の値が出力に出ない"

    unset MOCK_SF_ORG_JSON SF_INIT_JWT_INTERVAL MOCK_CALL_LOG
    teardown "$mb" "$mock_home" "$init_base"
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
test_env_type_selection
test_phase11_sf_tools_token
test_phase9_ruleset_id
test_phase7_channel_id
test_phase10_eca_auto
test_e2e_input_sequence
test_sf_cli_check

print_summary
