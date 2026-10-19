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
#   16. Phase 11 は廃止（sf-tools は公開リポジトリのため、SF_TOOLS_TOKEN は不要）: --only 11 はエラー、ひな形に Token がない
#   17. Phase 9: 既存 Ruleset の ID 検証（403 のエラー本文を ID として扱わない / 数字の ID は削除）
#   18. Phase 7: SLACK_CHANNEL_ID の形式チェック（C… / G… のみ受け付け。D… / U… は拒否して再入力）
#   19. Phase 10: 外部クライアントアプリの自動作成（正常 / JWT リトライ / deploy 失敗 / JWT 不成功で中断・スキップ）
#   24. Phase 6: PAT_TOKEN（発行済みの確認 Y/N・Token の検証〔スコープ・管理者〕・無効な Token の貼り直し・Token を画面とログに出さない）
# ==============================================================================

source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

# sf-init.sh は、オーナーと XXXX を、引数（--owner / --project。環境変数 SF_INIT_OWNER / SF_INIT_PROJECT）か、
# 対話で決める（フォルダ構成には頼らない）。既定のテストは、環境変数で渡す（引数・対話のテストは、個別に指定する）
export SF_INIT_OWNER="tamashimon" SF_INIT_PROJECT="testproject"
# 最初のメタデータの同期（wf-metasync の起動と、完了の待ち）の確認の間隔。モックの gh は、すぐに答えるため、0 にする
export VERIFY_POLL_SEC=0

# ==============================================================================
# ヘルパー：作業フォルダ（{base}/home/{github-owner}/{company}/。フォルダ名に意味はない）を作成
# （admin/ は sf-init.sh が自動作成するため、ここでは作らない）
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
    "api repos/"*"/branches/main")
        # 続きから: origin の main の確認。MOCK_GH_BRANCH_MAIN_EXIT=1 → main がない（状態ファイルと、実際の GitHub の食い違い）
        exit "${MOCK_GH_BRANCH_MAIN_EXIT:-0}" ;;
    "api user")
        # Phase 6 の Token 検証（GH_TOKEN 付きの呼び出し）:
        #   MOCK_GH_BAD_TOKEN=<値>     → その Token のとき、認証に失敗（exit 1）
        #   MOCK_GH_TOKEN_USER=<名前>  → Token のユーザー（既定 tamashimon）
        #   MOCK_GH_TOKEN_SCOPES=<値>  → X-OAuth-Scopes（既定 "repo, workflow"。空なら、ヘッダーを出さない＝Fine-grained 相当）
        if [[ -n "${GH_TOKEN:-}" ]]; then
            if [[ -n "${MOCK_GH_BAD_TOKEN:-}" && "$GH_TOKEN" == "$MOCK_GH_BAD_TOKEN" ]]; then exit 1; fi
            case " $* " in
                *" --include "*)
                    echo "HTTP/2.0 200 OK"
                    [[ -n "${MOCK_GH_TOKEN_SCOPES-repo, workflow}" ]] && echo "X-Oauth-Scopes: ${MOCK_GH_TOKEN_SCOPES-repo, workflow}"
                    echo ""; echo '{"login":"x"}'; exit 0 ;;
            esac
            echo "${MOCK_GH_TOKEN_USER:-tamashimon}"; exit 0
        fi
        echo "${MOCK_GH_API_USER:-${github_owner}}" ;;
    "variable get")
        # --status / --reconnect の確認用: 環境変数 MOCK_GH_VAR_<名前> の値を返す（未設定なら、exit 1）
        _vn="MOCK_GH_VAR_$3"
        [[ -n "${!_vn:-}" ]] && { echo "${!_vn}"; exit 0; }
        exit 1 ;;
    "secret list")
        # MOCK_GH_SECRET_LIST_EXIT=1: 一覧の取得に失敗する（権限不足・通信エラーの再現）
        [[ "${MOCK_GH_SECRET_LIST_EXIT:-0}" != "0" ]] && exit "$MOCK_GH_SECRET_LIST_EXIT"
        # --status の診断用: MOCK_GH_SECRETS（改行区切りの名前）。実際の gh と同じく、名前の後ろに TAB と日時が付く
        while IFS= read -r _n; do [[ -n "$_n" ]] && printf '%s\t2026-10-11T08:00:00Z\n' "$_n"; done <<< "${MOCK_GH_SECRETS:-}"
        exit 0 ;;
    "variable list")
        while IFS= read -r _n; do [[ -n "$_n" ]] && printf '%s\tx\t2026-10-11T08:00:00Z\n' "$_n"; done <<< "${MOCK_GH_VARIABLES:-}"
        exit 0 ;;
    "workflow run")
        # 最初のメタデータの同期（wf-metasync の手動起動）。MOCK_GH_WORKFLOW_RUN_EXIT=1 → 起動に失敗する
        exit "${MOCK_GH_WORKFLOW_RUN_EXIT:-0}" ;;
    "run list")
        case " $* " in
            *" --event workflow_dispatch "*)
                # 手動起動した実行の ID: 1 回目（起動の前の基準）は 100、以降は 101（基準より新しい実行が、できたことにする）
                _c="${MOCK_CALL_LOG%/*}/.wfd_count"; _n=$(cat "$_c" 2>/dev/null || echo 0); echo $(( _n + 1 )) > "$_c"
                if [[ "$_n" -eq 0 ]]; then echo 100; else echo 101; fi
                exit 0 ;;
        esac
        printf '%s\n' "${MOCK_GH_RUN_OUT:-none}"; exit 0 ;;
    "run view")
        # 同期の実行の状態と結果。MOCK_GH_SYNC_CONCLUSION=failure → 同期が失敗する
        case " $* " in
            *" --json status "*)     echo "${MOCK_GH_SYNC_STATUS:-completed}" ;;   # MOCK_GH_SYNC_STATUS=in_progress → 終わらない（時間切れ）
            *" --json conclusion "*) echo "${MOCK_GH_SYNC_CONCLUSION:-success}" ;;
        esac
        exit 0 ;;
    "variable set")
        # --body で値が渡される場合は何もしない（標準入力を読むと、テストの入力列を消費してしまう）
        case " $* " in *" --body "*) exit 0 ;; esac
        # 標準入力で渡された値を、変数名ごとのファイルに保存する（テストで値を検証するため）
        cat > "${MOCK_CALL_LOG%/*}/var_$3.txt"; exit 0 ;;
    "api repos/"*)
        # Phase 6 の Token 検証（リポジトリの管理者か）: MOCK_GH_PERM_ADMIN=false → 管理者ではない
        case " $* " in
            *" .permissions.admin "*|*" '.permissions.admin' "*)
                if [[ -n "${MOCK_GH_BAD_TOKEN:-}" && "${GH_TOKEN:-}" == "$MOCK_GH_BAD_TOKEN" ]]; then exit 1; fi
                echo "${MOCK_GH_PERM_ADMIN:-true}"; exit 0 ;;
        esac
        # --status の診断用: ブランチの一覧（MOCK_GH_BRANCHES）・ワークフローの一覧（MOCK_GH_WORKFLOWS）
        case "$2" in
            */branches) printf '%s\n' "${MOCK_GH_BRANCHES:-}"; exit 0 ;;
            */contents/.github/workflows) printf '%s\n' "${MOCK_GH_WORKFLOWS:-}"; exit 0 ;;
        esac
        # Ruleset 一覧: MOCK_GH_RULESETS=error → エラー本文を標準出力に出して exit 1（無料プランの 403 を再現）、
        #               MOCK_GH_RULESETS=id    → 既存の Ruleset の ID（12345）を返す
        if [[ "$2" == */rulesets ]]; then
            case "${MOCK_GH_RULESETS:-none}" in
                error) echo '{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature.","status":"403"}'; exit 1 ;;
                id)    echo "12345"; exit 0 ;;
                *)     exit 0 ;;
            esac
        fi
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
#   ★ Phase 5 のブランチ選択の \n は、read_secret が空行として無視（ブラウザは、質問なしですぐ開く）
#   5. ghp_faketoken      (PAT トークン - read_secret。Token の検証は、モックの gh が通す)
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
# 入力順（後処理）: なし（admin フォルダの削除の質問は、廃止した。admin フォルダは、管理者用として残す。Phase 10 が最後）
# ==============================================================================
_make_input_3branches() {
    printf 'Y\nY\n1\n1\nghp_faketoken\n\nxoxb-faketoken\nC01ABCDEFGH\n\n\n1\nfake_prod_key\nprod@example.com\n\nY\nfake_stg_key\nstg@example.com\n\nY\nfake_dev_key\ndev@example.com\n'
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
    : > "$MOCK_CALL_LOG"
    out=$(printf 'Y\n' | ( cd "$work" && HOME="$mock_home" PATH="$mb:$PATH" \
        bash "$mock_home/sf-tools/bin/sf-init.sh" --only 3 --owner tamashimon --project testproject ) 2>&1)
    exit_code=$?
    unset MOCK_GIT_C_REMOTE_URL
    assert_exit_ok "$exit_code"                                                          "Phase 3・同じリポジトリのクローン（大文字と小文字の違いは許す）→ 正常終了する"
    assert_file_contains "$MOCK_CALL_LOG" "checkout main"                                "Phase 3・admin ブランチのままだと、あとの Phase のコミットが main に入らないため、main に切り替える"
    assert_file_contains "$MOCK_CALL_LOG" "pull --ff-only origin main"                   "Phase 3・main を最新にする（git pull --ff-only）"
    teardown "$mb" "$mock_home" "$base"
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
    assert_file_exists   "$init_dir/admin/.sf-init-testproject.env"                                    ".sf-init.env が生成される"
    assert_file_contains "$init_dir/admin/.sf-init-testproject.env" "REPO_FULL_NAME"                  ".sf-init.env に REPO_FULL_NAME が含まれる"
    assert_file_contains "$init_dir/admin/.sf-init-testproject.env" "tamashimon/force-testproject"    "正しい REPO_FULL_NAME が書き出される"

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
    assert_file_not_contains "$MOCK_CALL_LOG" "origin main"                         "main への直接 push をしない"
    assert_file_contains "$MOCK_CALL_LOG" "gh pr create --base main"                "PR を作成する"
    assert_file_contains "$MOCK_CALL_LOG" "git checkout admin"                      "終わったら、実行前のブランチ（管理者用の admin）に戻る（main に居座らない）"
    assert_file_contains "$MOCK_CALL_LOG" "origin system-add-tier-staging-"         "作業用のブランチを push する"

    unset MOCK_SF_ORG_JSON SF_INIT_JWT_INTERVAL
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
# ワークフローのひな形 wf-propagate.yml: staging / develop がない構成では、失敗にせずスキップする
#   背景: main のみの構成で、main へのマージのたびに git checkout staging が失敗し、赤い ✗ になっていた（e2e で発覚）
#   ワークフローの run: の本文を取り出して、本物の git で実行する（ブランチがない / ある）
# ==============================================================================
_wfp_step_script() {  # 引数: ステップの id（merge_staging など）。run: | の本文を標準出力へ
    awk -v id="$1" '
        $0 ~ "id: " id {f=1}
        f && /run: \|/ {r=1; next}
        r { if ($0 ~ /^          /) { sub(/^          /, ""); print } else if ($0 ~ /^[[:space:]]*$/) { print "" } else { exit } }
    ' "$SF_TOOLS_DIR/templates/.github/workflows/wf-propagate.yml"
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
    rm -rf "$init_base"

    # JWT が成功しない → 確認で N → 中断
    MOCK_SF_JWT_FAIL_FIRST=99 SF_INIT_JWT_RETRIES=2 _p10_run 'Y\nN\n'
    assert_exit_fail          "$exit_code"                                                              "JWT 不成功 + スキップしない → 中断"
    assert_file_not_contains  "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"                       "JWT 不成功 + スキップしない → 登録しない"
    rm -rf "$init_base"

    # JWT が成功しない → 確認で Y → スキップして登録
    MOCK_SF_JWT_FAIL_FIRST=99 SF_INIT_JWT_RETRIES=2 _p10_run 'Y\nY\n'
    assert_exit_ok            "$exit_code"                                                              "JWT 不成功 + スキップする → 終了コード 0"
    assert_file_contains      "$MOCK_CALL_LOG" "gh secret set SF_CONSUMER_KEY_PROD"                       "JWT 不成功 + スキップする → 登録される"

    unset -f _p10_run
    unset MOCK_SF_ORG_JSON SF_INIT_JWT_INTERVAL SF_INIT_LOGIN_URL_PROD
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
    assert_file_contains      "$out" "完了済みのプロジェクトでは、--resume は使えません"          "クローンで完了済みと判定・--resume 5: 理由が表示される"
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
    assert_file_contains      "$out" "sf-init.sh --only 6"                                      "--status: 直し方が表示される"
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

# ==============================================================================
# テスト実行
# ==============================================================================
echo ""
echo -e "${CLR_HEAD}========================================"
echo "  sf-init.sh テスト"
echo -e "========================================${CLR_RST}"

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

test_happy_path_3branches
test_missing_tool_gh
test_repo_create_failure
test_sf_login_failure
test_unauthorized_user
test_invalid_owner_folder
test_flex_layout_with_args
test_flex_layout_prompt
test_admin_branch_failure_is_not_fatal
test_admin_branch_push_failure_is_not_fatal
test_initial_sync_failure_is_not_fatal
test_refuse_inside_admin_or_clone
test_refuse_foreign_clone
test_phase3_existing_clone
test_finish_unfinished_setup
test_restart_clears_mark
test_admin_branch_created_from_main
test_initial_sync_timeout_cancels
test_completed_before_mark_existed
test_resume_state_case_insensitive
test_restart_interrupted_notice
test_finish_skips_foreign_repo_dir
test_flex_invalid_project_arg
test_repo_visibility_private
test_only_option_runs_single_phase
test_only_phase2_creates_env_file
test_resume_runs_from_specified_phase
test_add_tier_staging_happy
test_add_tier_staging_already_exists
test_add_tier_develop_without_staging
test_unknown_option_fails
test_env_type_selection
test_phase11_removed
test_phase9_ruleset_id
test_phase7_channel_id
test_phase10_eca_auto
test_e2e_input_sequence
test_e2e_input_sequence_layouts
test_verify_step
test_sf_cli_check
test_wf_propagate_skip_missing_branch
test_wf_no_script_injection
test_phase6_pat_token
test_resume_choice
test_completed_by_clone
test_sf_tools_autoupdate
test_sf_tools_branch_mismatch
test_org_connection

print_summary
