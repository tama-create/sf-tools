#!/bin/bash
# ==============================================================================
# bootstrap.sh - e2e テストの鍵一式（~/.sf-tools-e2e/fixture.env）を作る（最初の 1 回だけ）
# ==============================================================================
# e2e テストが使う Token などを、対話で入力して、リポジトリの外のファイルに保存する。
# Token の作成そのものは自動化できないため、ここで 1 回だけ、手動で用意したものを入力する。
#
# 【事前に用意するもの】
#   1. Classic PAT（repo・workflow）            → sf-init の Phase 6 と同じもの
#   2. Slack の Bot Token と、通知先の共有チャンネルの ID（Bot をそのチャンネルに招待済み）
#   3. Fine-grained PAT（sf-tools の Contents: Read-only）→ sf-init の Phase 11 と同じもの
#   4. テスト用の Salesforce 組織（本番または Developer Edition。Sandbox ではない）の管理者ユーザー
#
# 【処理の流れ】
#   1. 保存先の確認（既にあれば、上書きの確認）
#   2. オーナー・gh ユーザー・作業フォルダの root・各 Token・チャンネル ID の入力
#   3. sf の終了コードの確認（npm 版が前提。終了コードが 0 でなければ中断する）
#   4. ブラウザで Salesforce にログイン（1 回だけ）→ 認証 URL を取得して保存
#   5. 保存したファイルの読み込みとガードの確認
#
# 【オプション】
#   -h, --help : このヘルプを表示する
#
# 【保存先】 ~/.sf-tools-e2e/fixture.env（権限は本人のみ。E2E_FIXTURE 環境変数で変更できる）
# ==============================================================================

readonly SCRIPT_NAME="e2e-bootstrap"
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true
readonly LOG_FILE="$HOME/sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"

export SF_INIT_MODE=1   # プロジェクト外から実行するため、force-* チェックをバイパスする
E2E_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_TOOLS_ROOT="$(cd "${E2E_SCRIPT_DIR}/../.." && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}"
    exit 0
fi

source "${SF_TOOLS_ROOT}/lib/common.sh"
source "${E2E_SCRIPT_DIR}/lib.sh"

log "HEADER" "e2e テストの鍵一式を作成します (${SCRIPT_NAME}.sh)"

# ------------------------------------------------------------------------------
# 1. 保存先の確認
# ------------------------------------------------------------------------------
FIXTURE=$(e2e_fixture_path)
if [[ -f "$FIXTURE" ]]; then
    log "WARNING" "既に存在します: ${FIXTURE}"
    ask_yn "上書きしますか？" || die "中断しました。"
fi

# ------------------------------------------------------------------------------
# 2. 入力
# ------------------------------------------------------------------------------
echo ""
read_or_quit B_OWNER "  テスト用リポジトリのオーナー（組織名。例: tamashimon-org）（q で中断）："

B_GH_USER=$(gh api user --jq .login 2>/dev/null)  # VAR=$(cmd) のため run 不使用
if [[ -n "$B_GH_USER" ]] && ask_yn "gh のログインユーザー「${B_GH_USER}」で e2e を実行しますか？"; then
    :
else
    read_or_quit B_GH_USER "  e2e を実行する gh ユーザー名（q で中断）："
fi

read_or_quit B_HOME_ROOT "  作業フォルダの root（この下に {オーナー}/{プロジェクト} を作ります。例: /c/home）（q で中断）："
[[ "$B_HOME_ROOT" == */home ]] || die "作業フォルダの root は、/home で終わる必要があります: ${B_HOME_ROOT}"

echo ""
read_secret B_PAT        "  Classic PAT（repo・workflow）（画面には表示されません・q で中断）："
read_secret B_SLACK      "  Slack の Bot Token（画面には表示されません・q で中断）："
while true; do
    read_or_quit B_CHANNEL "  通知先の共有チャンネルの ID（C または G で始まる。q で中断）："
    [[ "$B_CHANNEL" =~ ^[CG][A-Z0-9]{8,}$ ]] && break
    log "WARNING" "「${B_CHANNEL}」はチャンネル ID の形式ではありません。入力し直してください。"
done
read_secret B_TOOLS      "  SF_TOOLS_TOKEN 用の Fine-grained PAT（画面には表示されません・q で中断）："

# ------------------------------------------------------------------------------
# 3. sf の終了コードの確認
# ------------------------------------------------------------------------------
check_sf_cli

# ------------------------------------------------------------------------------
# 4. ブラウザでログイン → 認証 URL を取得
# ------------------------------------------------------------------------------
BOOT_ALIAS="sf-tools-e2e-bootstrap"
echo ""
log "INFO" "ブラウザが開きます。テスト用の Salesforce 組織に、管理者でログインしてください（2 分以内）。"
run sf alias unset "$BOOT_ALIAS" || true  # 未設定でも続行（意図的エラー無視）
run sf org login web --instance-url https://login.salesforce.com --alias "$BOOT_ALIAS" \
    || die "Salesforce へのログインに失敗しました。"
# 新しい sf は、sf org display --verbose で認証 URL を隠すため、sf org auth show-sfdx-auth-url を使う
# （古い sf では、sf org display --verbose にフォールバックする）。形式を確認し、合わなければ保存しない
B_SFDX_URL=$(e2e_get_sfdx_auth_url "$BOOT_ALIAS")  # VAR=$(cmd) のため run 不使用（値を画面・ログに出さない）
run sf alias unset "$BOOT_ALIAS" || true  # 後始末（意図的エラー無視）
[[ -n "$B_SFDX_URL" ]] || die "認証 URL を取得できませんでした（ログインに失敗したか、Sandbox の組織です）。"
log "SUCCESS" "認証 URL を取得しました。"

# ------------------------------------------------------------------------------
# 保存（権限は本人のみ）
# ------------------------------------------------------------------------------
mkdir -p "$(dirname "$FIXTURE")"
chmod 700 "$(dirname "$FIXTURE")" 2>/dev/null || true  # run 不使用: 権限保護（Windows は効果なし・意図的エラー無視）
(
    umask 077
    {
        echo "# e2e テストの鍵一式（bootstrap.sh が作成）。リポジトリに入れないこと。"
        printf 'E2E_OWNER=%q\n'            "$B_OWNER"
        printf 'E2E_GH_USER=%q\n'          "$B_GH_USER"
        printf 'E2E_HOME_ROOT=%q\n'        "$B_HOME_ROOT"
        printf 'E2E_PAT_TOKEN=%q\n'        "$B_PAT"
        printf 'E2E_SLACK_BOT_TOKEN=%q\n'  "$B_SLACK"
        printf 'E2E_SLACK_CHANNEL_ID=%q\n' "$B_CHANNEL"
        printf 'E2E_SF_TOOLS_TOKEN=%q\n'   "$B_TOOLS"
        printf 'E2E_SFDX_AUTH_URL=%q\n'    "$B_SFDX_URL"
    } > "$FIXTURE"
)
chmod 600 "$FIXTURE" 2>/dev/null || true  # run 不使用: 権限保護（Windows は効果なし・意図的エラー無視）
log "SUCCESS" "保存しました: ${FIXTURE}"

# ------------------------------------------------------------------------------
# 5. 保存したファイルの確認
# ------------------------------------------------------------------------------
e2e_load_fixture
e2e_guard_env
log "SUCCESS" "鍵一式の読み込みとガードの確認が完了しました。tests/e2e/run.sh を実行できます。"
exit $RET_OK
