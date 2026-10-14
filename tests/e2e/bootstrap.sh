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
#   3. テスト用の Salesforce 組織（本番または Developer Edition。Sandbox ではない）の管理者ユーザー
#      ・1 層（main のみ）の検証には、1 つ。
#      ・2 層（main + staging）には 2 つ、3 層（main + staging + develop）には 3 つ。**層の数だけ、別々の組織が要る**
#        （段階ごとに、その組織にだけリリースされることを確認するため。同じ組織を、複数の段階には使えない）。
#        2 つ目以降は、この最初の登録のあとで、--add-orgs で追加する
#   （SF_TOOLS_TOKEN は不要: sf-tools は公開リポジトリ）
#
# 【処理の流れ】
#   1. 保存先の確認（既にあれば、上書きの確認）
#   2. オーナー・gh ユーザー・作業フォルダの root・各 Token・チャンネル ID の入力
#   3. sf の終了コードの確認（npm 版が前提。終了コードが 0 でなければ中断する）
#   4. ブラウザで Salesforce にログイン（1 回だけ）→ 認証 URL を取得して保存
#   5. 保存したファイルの読み込みとガードの確認
#
# 【オプション】
#   --add-orgs : 既にある鍵一式に、staging・develop 用のテスト用組織（認証 URL）だけを追加する
#                （2 層・3 層の通し検証に必要。Token などは、入力し直さない。ブラウザでのログインが、組織の数だけ必要）
#   --refresh-orgs : 登録済みの組織（main・staging・develop）の認証 URL が、いまも有効かを確認し、**無効なものだけ**を、
#                ブラウザでのログインで取り直す（Token などの、ほかの値は、そのまま）。
#                リフレッシュトークンは、同じユーザーでログインを繰り返すと、古いものから無効になる
#                （e2e が RefreshTokenAuthError で失敗したときに使う）。有効なものには、何もしない
#   -h, --help : このヘルプを表示する
#
# 【保存先】 ~/.sf-tools-e2e/fixture.env（権限は本人のみ。E2E_FIXTURE 環境変数で変更できる）
# ==============================================================================

readonly SCRIPT_NAME="e2e-bootstrap"
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true  # run 不使用: ログフォルダの準備（log が使える前の処理）
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

ADD_ORGS=0
REFRESH_ORGS=0
for _a in "$@"; do
    case "$_a" in
        --add-orgs) ADD_ORGS=1 ;;
        --refresh-orgs) REFRESH_ORGS=1 ;;
        *) die "不明なオプションです: ${_a}" ;;
    esac
done
[[ $ADD_ORGS -eq 0 || $REFRESH_ORGS -eq 0 ]] || die "--add-orgs と --refresh-orgs は、同時に指定できません。"

# ブラウザでログインして、認証 URL を取得する。引数: 仮のエイリアス 表示名
#   成功: 認証 URL を B_URL に、組織 ID を B_ORG_ID に入れる。失敗: die
_bootstrap_login() {
    local alias="$1" label="$2"
    echo ""
    log "INFO" "ブラウザが開きます。${label}のテスト用 Salesforce 組織に、管理者でログインしてください（2 分以内）。"
    run sf alias unset "$alias" || true  # 未設定でも続行（意図的エラー無視）
    run sf org login web --instance-url https://login.salesforce.com --alias "$alias" \
        || die "Salesforce へのログインに失敗しました。"
    # 新しい sf は、sf org display --verbose で認証 URL を隠すため、sf org auth show-sfdx-auth-url を使う
    # （古い sf では、sf org display --verbose にフォールバックする）。形式を確認し、合わなければ保存しない
    B_URL=$(e2e_get_sfdx_auth_url "$alias")  # VAR=$(cmd) のため run 不使用（値を画面・ログに出さない）
    B_ORG_ID=$(e2e_org_id "$alias")          # VAR=$(cmd) のため run 不使用
    run sf alias unset "$alias" || true  # 後始末（意図的エラー無視）
    [[ -n "$B_URL" ]] || die "認証 URL を取得できませんでした（ログインに失敗したか、Sandbox の組織です）。"
    [[ -n "$B_ORG_ID" ]] || die "組織の ID を取得できませんでした。"
    log "SUCCESS" "認証 URL を取得しました（${label}。組織 ID: ${B_ORG_ID}）。"
}

# 鍵一式のファイルに、1 行を追加する（同じ変数名の行があれば、置き換える）。引数: 変数名 値
_bootstrap_put() {
    local name="$1" value="$2" tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/e2e-fixture.XXXXXX") || die "一時ファイルを作成できません。"  # VAR=$(cmd) のため run 不使用
    (
        umask 077
        grep -v "^${name}=" "$FIXTURE" > "$tmp" || true  # 該当行がなくても続行（意図的エラー無視）
        printf '%s=%q\n' "$name" "$value" >> "$tmp"
    )
    cat "$tmp" > "$FIXTURE"  # run 不使用: 権限・所有者を保つため、中身だけを書き戻す
    rm -f "$tmp"  # run 不使用: 認証 URL を含む一時ファイルの削除
    chmod 600 "$FIXTURE" 2>/dev/null || true  # run 不使用: 権限保護（Windows は効果なし・意図的エラー無視）
}

# 保存してある認証 URL でログインして、組織の ID を、標準出力に返す。取得できなければ、戻り値 1
#   引数: 認証 URL 仮のエイリアス（ログインしたあと、エイリアスは、外す。認証そのものは、残る）
_bootstrap_id_of_url() {
    local url="$1" alias="$2" f id
    f=$(mktemp "${TMPDIR:-/tmp}/e2e-sfdx-url.XXXXXX") || die "一時ファイルを作成できません。"  # VAR=$(cmd) のため run 不使用
    chmod 600 "$f" 2>/dev/null || true  # run 不使用: 権限保護（Windows は効果なし・意図的エラー無視）
    printf '%s' "$url" > "$f"
    # run の標準出力（sf の警告・"Successfully authorized ..." など）は、組織 ID に混ぜない（捨てる。画面には、標準エラーが出る）
    if ! run sf org login sfdx-url --sfdx-url-file "$f" --alias "$alias" > /dev/null; then  # 条件チェック
        rm -f "$f"  # run 不使用: 認証 URL の一時ファイルの削除（秘密情報を残さない）
        return 1
    fi
    rm -f "$f"  # run 不使用: 認証 URL の一時ファイルの削除（秘密情報を残さない）
    id=$(e2e_org_id "$alias")  # VAR=$(cmd) のため run 不使用
    run sf alias unset "$alias" || true  # 後始末（意図的エラー無視）
    [[ -n "$id" ]] || return 1
    printf '%s' "$id"
}

# staging・develop の組織を追加する（既存の鍵一式に）。3 つの組織が、別々の組織であることを確認する。
#   比較の対象: main の組織・すでに登録済みの staging・develop の組織（保存してある認証 URL でログインして、ID を取得する）・
#   今回、追加する組織。重複があれば、鍵一式を更新せずに、中断する
_bootstrap_add_orgs() {
    local id_main id_stg="" id_dev=""
    log "INFO" "既存の鍵一式に、staging・develop 用のテスト用組織を追加します。"
    log "INFO" "  3 つの組織（main・staging・develop）は、別々の組織にしてください（同じ組織を、複数の段階に使わない）。"
    id_main=$(_bootstrap_id_of_url "$E2E_SFDX_AUTH_URL" "sf-tools-e2e-bootstrap-main") \
        || die "main の組織へのログイン、または、組織の ID の取得に失敗しました。"  # VAR=$(cmd) のため run 不使用
    log "INFO" "  main の組織 ID: ${id_main}"
    # すでに登録済みの staging・develop（あれば）
    if [[ -n "${E2E_SFDX_AUTH_URL_STG:-}" ]]; then
        id_stg=$(_bootstrap_id_of_url "$E2E_SFDX_AUTH_URL_STG" "sf-tools-e2e-bootstrap-stg0") \
            || die "登録済みの staging の組織へのログイン、または、組織の ID の取得に失敗しました。"  # VAR=$(cmd) のため run 不使用
        log "INFO" "  登録済みの staging の組織 ID: ${id_stg}"
        [[ "$id_stg" != "$id_main" ]] || die "登録済みの staging が、main と同じ組織です。鍵一式を、確認してください。"
    fi
    if [[ -n "${E2E_SFDX_AUTH_URL_DEV:-}" ]]; then
        id_dev=$(_bootstrap_id_of_url "$E2E_SFDX_AUTH_URL_DEV" "sf-tools-e2e-bootstrap-dev0") \
            || die "登録済みの develop の組織へのログイン、または、組織の ID の取得に失敗しました。"  # VAR=$(cmd) のため run 不使用
        log "INFO" "  登録済みの develop の組織 ID: ${id_dev}"
        [[ "$id_dev" != "$id_main" && "$id_dev" != "$id_stg" ]] || die "登録済みの develop が、ほかの段階と同じ組織です。鍵一式を、確認してください。"
    fi

    # 保存は、すべての確認が済んでから、まとめて行う（途中で中断したときに、一部だけが保存されないように）
    local new_stg_url="" new_dev_url=""
    if ask_yn "staging 用の組織を追加しますか？（2 層・3 層の通し検証に必要。登録済みなら、置き換えます）"; then
        _bootstrap_login "sf-tools-e2e-bootstrap-stg" "staging 用の"
        [[ "$B_ORG_ID" != "$id_main" && ( -z "$id_dev" || "$B_ORG_ID" != "$id_dev" ) ]] \
            || die "ほかの段階（main・develop）と同じ組織です。別の組織でログインしてください。"
        id_stg="$B_ORG_ID"
        new_stg_url="$B_URL"
    fi
    if ask_yn "develop 用の組織を追加しますか？（3 層の通し検証に必要。登録済みなら、置き換えます）"; then
        _bootstrap_login "sf-tools-e2e-bootstrap-dev" "develop 用の"
        [[ "$B_ORG_ID" != "$id_main" && ( -z "$id_stg" || "$B_ORG_ID" != "$id_stg" ) ]] \
            || die "ほかの段階（main・staging）と同じ組織です。別の組織でログインしてください。"
        id_dev="$B_ORG_ID"
        new_dev_url="$B_URL"
    fi
    [[ -z "$new_stg_url" ]] || _bootstrap_put E2E_SFDX_AUTH_URL_STG "$new_stg_url"
    [[ -z "$new_dev_url" ]] || _bootstrap_put E2E_SFDX_AUTH_URL_DEV "$new_dev_url"
    [[ -n "$new_stg_url$new_dev_url" ]] || log "WARNING" "何も追加しませんでした。"
}

# 登録済みの組織（main・staging・develop）の認証 URL が、いまも有効かを確認し、無効なものだけを、取り直す。
#   有効かどうかは、保存してある認証 URL で、実際にログインして確認する（sf org login sfdx-url）。
#   無効なものは、確認のうえ、ブラウザでログインし直して、認証 URL を取り直す。取り直した組織が、ほかの段階と
#   同じ組織なら、中断する（鍵一式を更新しない）。保存は、すべての確認が済んでから、まとめて行う。
#   戻り値: 0 = すべて有効（または、取り直した） / 1 = 取り直さなかった（無効なまま）組織がある
_bootstrap_refresh_orgs() {
    # 段階と値を、同じ添字の 2 つの配列で持つ（連想配列は Bash 4 以降のため使わない。macOS 標準の Bash 3.2 で動かす）
    local -a id_tiers=() id_vals=() new_tiers=() new_vals=()
    local -a invalid=()
    local tier var url id i skipped=0
    log "INFO" "登録済みのテスト用組織の認証 URL が、いまも有効かを確認します。"
    for tier in main staging develop; do
        case "$tier" in
            main)    var="E2E_SFDX_AUTH_URL" ;;
            staging) var="E2E_SFDX_AUTH_URL_STG" ;;
            develop) var="E2E_SFDX_AUTH_URL_DEV" ;;
        esac
        url="${!var:-}"
        if [[ -z "$url" ]]; then
            log "INFO" "  ${tier}: 未登録です（追加するときは、bootstrap.sh --add-orgs）。"
            continue
        fi
        if id=$(_bootstrap_id_of_url "$url" "sf-tools-e2e-bootstrap-chk-${tier}"); then  # 条件チェック
            # 有効な組織が、ほかの段階と同じ組織なら、鍵一式が壊れている
            for (( i = 0; i < ${#id_tiers[@]}; i++ )); do
                [[ "${id_vals[$i]}" != "$id" ]] || die "登録済みの ${tier} が、${id_tiers[$i]} と同じ組織です。鍵一式を、確認してください。"
            done
            id_tiers+=("$tier"); id_vals+=("$id")
            log "SUCCESS" "  ${tier}: 有効です（組織 ID: ${id}）。"
        else
            invalid+=("$tier")
            log "WARNING" "  ${tier}: 無効です（リフレッシュトークンが、失効した可能性があります。ログインし直しが必要です）。"
        fi
    done

    if [[ ${#invalid[@]} -eq 0 ]]; then
        log "SUCCESS" "登録済みの認証 URL は、すべて有効です。変更はありません。"
        return 0
    fi

    for tier in "${invalid[@]}"; do
        if ! ask_yn "${tier} の組織に、ブラウザでログインし直して、認証 URL を取り直しますか？（元と同じテスト用組織・同じユーザーでログインしてください）"; then  # 条件チェック
            log "WARNING" "  ${tier}: 取り直しませんでした（無効なままです）。"
            skipped=1
            continue
        fi
        _bootstrap_login "sf-tools-e2e-bootstrap-${tier}" "${tier} 用の"
        for (( i = 0; i < ${#id_tiers[@]}; i++ )); do
            [[ "${id_vals[$i]}" != "$B_ORG_ID" ]] \
                || die "ログインした組織が、${id_tiers[$i]} と同じ組織です。別の組織でログインしてください（鍵一式は、更新していません）。"
        done
        id_tiers+=("$tier"); id_vals+=("$B_ORG_ID")
        new_tiers+=("$tier"); new_vals+=("$B_URL")
    done

    # 保存は、すべての確認が済んでから、まとめて行う（途中で中断したときに、一部だけが保存されないように）
    for (( i = 0; i < ${#new_tiers[@]}; i++ )); do
        tier="${new_tiers[$i]}"
        case "$tier" in
            main)    var="E2E_SFDX_AUTH_URL" ;;
            staging) var="E2E_SFDX_AUTH_URL_STG" ;;
            develop) var="E2E_SFDX_AUTH_URL_DEV" ;;
        esac
        _bootstrap_put "$var" "${new_vals[$i]}"
        log "SUCCESS" "  ${tier}: 認証 URL を、取り直して、保存しました。"
    done
    [[ $skipped -eq 0 ]]
}

# ------------------------------------------------------------------------------
# --refresh-orgs: 登録済みの組織の認証 URL を、確認して、無効なものだけを取り直す
# ------------------------------------------------------------------------------
if [[ $REFRESH_ORGS -eq 1 ]]; then
    FIXTURE=$(e2e_fixture_path)
    [[ -f "$FIXTURE" ]] || die "鍵一式のファイルが見つかりません（先に、bootstrap.sh を実行してください）: ${FIXTURE}"
    check_sf_cli
    e2e_load_fixture
    _refresh_rc=0
    _bootstrap_refresh_orgs || _refresh_rc=$?
    e2e_load_fixture   # 保存した内容の形式を、確認する
    if [[ $_refresh_rc -ne 0 ]]; then
        log "WARNING" "無効なまま残っている組織があります。e2e を実行する前に、もう一度、bootstrap.sh --refresh-orgs を実行してください。"
        exit $RET_NG
    fi
    log "SUCCESS" "鍵一式を確認しました: ${FIXTURE}"
    exit $RET_OK
fi

# ------------------------------------------------------------------------------
# --add-orgs: 既存の鍵一式に、staging・develop の組織だけを追加する
# ------------------------------------------------------------------------------
if [[ $ADD_ORGS -eq 1 ]]; then
    FIXTURE=$(e2e_fixture_path)
    [[ -f "$FIXTURE" ]] || die "鍵一式のファイルが見つかりません（先に、bootstrap.sh を実行してください）: ${FIXTURE}"
    check_sf_cli
    e2e_load_fixture
    _bootstrap_add_orgs
    e2e_load_fixture   # 保存した内容の形式を、確認する
    log "SUCCESS" "保存しました: ${FIXTURE}"
    exit $RET_OK
fi

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
read_secret B_PAT        "  Classic PAT（repo・workflow）（* で表示されます・q で中断）："
read_secret B_SLACK      "  Slack の Bot Token（* で表示されます・q で中断）："
while true; do
    read_or_quit B_CHANNEL "  通知先の共有チャンネルの ID（C または G で始まる。q で中断）："
    [[ "$B_CHANNEL" =~ ^[CG][A-Z0-9]{8,}$ ]] && break
    log "WARNING" "「${B_CHANNEL}」はチャンネル ID の形式ではありません。入力し直してください。"
done

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
mkdir -p "$(dirname "$FIXTURE")"  # run 不使用: 鍵一式の保存先フォルダの作成
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
