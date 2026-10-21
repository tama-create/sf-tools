#!/bin/bash
# ==============================================================================
# init-test-lib.sh - sf-init.sh の単体テスト（test_sf-init.sh・test_sf-init2.sh・test_sf-init3.sh）の共通の部品
# ==============================================================================
# 3 つのテストファイルが source する。時間のかかる 1 ファイル（Windows の CI で約 10 分）を、3 つに分けて、並列に動かすために、
# 共通の準備（環境変数・作業フォルダ・gh のモック・サブスクリプトの差し替え・入力の台本）を、ここに置く。
# テストの本体は、各ファイルにある（どのファイルにあるかは、各ファイルの冒頭の一覧を参照）。
#
# 以下は、分割する前の test_sf-init.sh の冒頭にあった、テストケースの一覧（3 つのファイルの合計）。
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
# 最初のメタデータの同期（wf-metasync の起動と、完了の待ち）の確認の間隔。モックの gh は、すぐに答えるため
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
