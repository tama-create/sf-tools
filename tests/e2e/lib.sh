#!/bin/bash
# ==============================================================================
# lib.sh - e2e テスト（実環境での sf-init 通し検証）の共通関数
# ==============================================================================
# run.sh / cleanup.sh / bootstrap.sh から source して使う。呼び出し側が先に
# lib/common.sh を source し、SCRIPT_NAME / LOG_FILE / LOG_MODE を定義しておくこと。
#
# 【このテストの考え方】
#   ・sf-init 本体のコードは変えず、外から標準入力・PATH の差し替えで自動操作する
#   ・実際の GitHub / Salesforce に、テスト用のリポジトリとアプリを作り、終了時に削除する
#   ・削除は「名前の形式」と「オーナー」が両方一致するものだけ（下記のガードを参照）
#
# 【削除の安全ガード】
#   1. e2e_guard_env を通らないと、削除系の関数は動かない（E2E_GUARD_OK=1）
#   2. 対象は、タイムスタンプ付きの決まった名前だけ（他のリポジトリ・アプリは対象外）
#        リポジトリ        : force-e2e-YYYYMMDD-HHMMSS
#        外部クライアントアプリ : SF_TOOLS_force_e2e_YYYYMMDD_HHMMSS
#        作業フォルダ      : e2e-YYYYMMDD-HHMMSS
#        一時ファイル・フォルダ（強制終了で残ったもの）: $TMPDIR の e2e-run.XXXXXX / e2e-eca-del.XXXXXX /
#                          e2e-sfdx-url.XXXXXX（実行中の run.sh のものと、30 分以内のものは対象外）
#   3. オーナーは、鍵一式のファイルで明示した E2E_OWNER だけ。gh のログインユーザーも E2E_GH_USER と一致が必須
#   4. GitHub Actions 上では動かない
#
# 【鍵一式のファイル】（リポジトリの外。~/.sf-tools-e2e/fixture.env。bootstrap.sh が作成する）
#   E2E_OWNER             テスト用リポジトリのオーナー（組織名）
#   E2E_GH_USER           gh のログインユーザー（このユーザーで動かすこと）
#   E2E_HOME_ROOT         作業フォルダの root（例: /c/home。この下に {owner}/{project} を作る）
#   E2E_PAT_TOKEN         PAT_TOKEN に登録する Classic PAT
#   E2E_SLACK_BOT_TOKEN   Slack の Bot Token
#   E2E_SLACK_CHANNEL_ID  通知先（共有チャンネル）の ID
#   E2E_SFDX_AUTH_URL     テスト用組織の認証 URL（sf org login sfdx-url 用。リフレッシュトークンを含む）
#
# 【前提】 sf は npm 版（終了コードで成否を判定する。run.sh / bootstrap.sh の冒頭の check_sf_cli が確認する）
# ==============================================================================

E2E_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
E2E_ADMIN_ALIAS="sf-tools-e2e-admin"     # 削除・一覧用にログインするときの一時エイリアス

# ------------------------------------------------------------------------------
# 名前の判定（削除対象かどうか）
# ------------------------------------------------------------------------------
e2e_is_target_repo()    { [[ "$1" =~ ^force-e2e-[0-9]{8}-[0-9]{6}$ ]]; }
e2e_is_target_eca()     { [[ "$1" =~ ^SF_TOOLS_force_e2e_[0-9]{8}_[0-9]{6}$ ]]; }
e2e_is_target_project() { [[ "$1" =~ ^e2e-[0-9]{8}-[0-9]{6}$ ]]; }
e2e_is_target_jwt_dir() { [[ "$1" =~ ^force-e2e-[0-9]{8}-[0-9]{6}$ ]]; }
# 一時ファイル・フォルダ（mktemp が作る 6 文字の英数字つき）: e2e-run.XXXXXX / e2e-eca-del.XXXXXX / e2e-sfdx-url.XXXXXX
e2e_is_target_tmp()     { [[ "$1" =~ ^e2e-(run|eca-del|sfdx-url)\.[A-Za-z0-9]{6}$ ]]; }

# 1 行の文字列から、秘密情報を伏せる（表示・ログに出す前に、必ず通す）。
#   鍵一式の値（完全一致）→ 認証 URL の形式（リフレッシュトークン）→ Token らしい文字列（lib/common.sh の _mask_secrets）
_e2e_mask_line() {
    local line="$1" v
    for v in "${E2E_PAT_TOKEN:-}" "${E2E_SLACK_BOT_TOKEN:-}" "${E2E_SFDX_AUTH_URL:-}"; do
        [[ -n "$v" ]] && line="${line//"$v"/***}"
    done
    line=$(printf '%s' "$line" | sed -E 's#(force://[^:@ ]*:[^:@ ]*:)[^@ ]*@#\1***masked***@#')  # パイプのみのため run 不使用
    _mask_secrets "$line"
}

# Windows（Git Bash）かどうか（lib/common.sh の is_gitbash を使う。$OSTYPE は msys / mingw / cygwin のいずれにもなる）
e2e_is_windows() { is_gitbash; }

# 新しいテスト用のプロジェクト名（これが作業フォルダ名になり、リポジトリは force-<名前> になる）
e2e_new_project_name() { printf 'e2e-%s' "$(date +%Y%m%d-%H%M%S)"; }

# ------------------------------------------------------------------------------
# 鍵一式の読み込み
# ------------------------------------------------------------------------------
e2e_fixture_path() { printf '%s' "${E2E_FIXTURE:-$HOME/.sf-tools-e2e/fixture.env}"; }

# 認証 URL の形式（force://<クライアント ID>:<シークレット（空でもよい）>:<リフレッシュトークン>@<ホスト>）か判定する。
# 新しい sf は、認証 URL の代わりに「[REDACTED] Use 'sf org auth show-sfdx-auth-url' to view」という文章を返すため、
# その文章を認証 URL として保存・使用しないように、形式で確認する
e2e_valid_sfdx_url() { [[ "$1" =~ ^force://[^:@[:space:]]+:[^:@[:space:]]*:[^@[:space:]]+@[^@[:space:]]+$ ]]; }

# ログイン済みの組織（エイリアスまたはユーザー名）の認証 URL を、標準出力に返す。取得できなければ、何も出さず、戻り値 1
#   1. 新しい sf: sf org auth show-sfdx-auth-url（--no-prompt で、確認を省く）
#   2. 古い sf  : sf org display --verbose（sfdxAuthUrl）。新しい sf では、値が隠されるため、形式の確認で除外する
# 値を画面・ログに出さない（呼び出し側が、変数に受け取る）
e2e_get_sfdx_auth_url() {
    local alias="$1" out url
    out=$(sf org auth show-sfdx-auth-url --target-org "$alias" --no-prompt --json 2>/dev/null)  # VAR=$(cmd) のため run 不使用（値をログに出さない）
    url=$(printf '%s' "$out" | grep -oE 'force://[^"]*' | head -1)
    if ! e2e_valid_sfdx_url "$url"; then
        out=$(sf org display --target-org "$alias" --verbose --json 2>/dev/null)  # VAR=$(cmd) のため run 不使用（値をログに出さない）
        url=$(printf '%s' "$out" | grep -oE '"sfdxAuthUrl": *"force://[^"]*"' | head -1 | sed -E 's/.*: *"(.*)"/\1/')
    fi
    e2e_valid_sfdx_url "$url" || return 1
    printf '%s' "$url"
}

e2e_load_fixture() {
    local f perm v
    f=$(e2e_fixture_path)
    [[ -f "$f" ]] || die "鍵一式のファイルが見つかりません: ${f}"

    # 権限は本人のみ（600）であること。Windows（Git Bash）は権限が効かないため確認しない
    # （Git Bash の $OSTYPE は、環境により msys / mingw / cygwin のいずれにもなる）
    if ! e2e_is_windows; then
        perm=$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f" 2>/dev/null)  # VAR=$(cmd) のため run 不使用
        [[ "$perm" == "600" ]] || die "鍵一式のファイルの権限が 600 ではありません（${perm}）: ${f}"
    fi

    # shellcheck disable=SC1090
    source "$f"
    for v in E2E_OWNER E2E_GH_USER E2E_HOME_ROOT E2E_PAT_TOKEN E2E_SLACK_BOT_TOKEN \
             E2E_SLACK_CHANNEL_ID E2E_SFDX_AUTH_URL; do
        [[ -n "${!v:-}" ]] || die "${v} が未設定です（${f}）。"
    done
    e2e_valid_sfdx_url "$E2E_SFDX_AUTH_URL" \
        || die "E2E_SFDX_AUTH_URL が認証 URL の形式ではありません（${f}）。"
    return 0
}

# ------------------------------------------------------------------------------
# ガード（削除系の関数は、これを通らないと動かない）
# ------------------------------------------------------------------------------
e2e_guard_env() {
    local login
    [[ "${GITHUB_ACTIONS:-}" == "true" ]] && die "GitHub Actions 上では e2e を実行できません。"
    [[ "${E2E_OWNER:-}" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,37}[a-zA-Z0-9])?$ ]] \
        || die "E2E_OWNER が不正です: ${E2E_OWNER:-}"
    login=$(gh api user --jq .login 2>/dev/null) || die "gh のログインユーザーを取得できません。"  # VAR=$(cmd) のため run 不使用
    [[ "$login" == "${E2E_GH_USER:-}" ]] \
        || die "gh のログインユーザー（${login}）が E2E_GH_USER（${E2E_GH_USER:-}）と一致しません。"
    export E2E_GUARD_OK=1
}

e2e_require_guard() {
    [[ "${E2E_GUARD_OK:-}" == "1" ]] || die "e2e のガードを通っていないため実行できません。"
}

# ------------------------------------------------------------------------------
# sf のエイリアスの保存・復元（sf-init は prod / staging / develop を付けるため、テスト後に元へ戻す）
# ------------------------------------------------------------------------------
# 出力形式: 1 行に 1 つ「エイリアス=値」
# sf alias list の失敗（戻り値 1）を、空の一覧と取り違えない。取り違えると、保存した一覧が空になり、
# 復元のときに、開発者の本物のエイリアス（prod / staging / develop など）を、すべて外してしまう
e2e_alias_dump() {
    local out
    out=$(sf alias list --json 2>/dev/null) || return 1  # VAR=$(cmd) のため run 不使用
    printf '%s' "$out" | tr -d '\n\r' \
        | grep -oE '"alias": *"[^"]*", *"value": *"[^"]*"' \
        | sed -E 's/"alias": *"([^"]*)", *"value": *"([^"]*)"/\1=\2/' || true  # パイプのみのため run 不使用。エイリアスが 0 件なら、grep が 1 を返す（正常）
}

# 戻り値 1: sf alias list に失敗した（保存できていない。呼び出し側は、中断すること）
e2e_alias_snapshot() {
    local out
    out=$(e2e_alias_dump) || return 1  # VAR=$(cmd) のため run 不使用
    printf '%s\n' "$out" > "$1"
    : > "${1}.ok"  # 保存に成功した目印（これがないと、復元しない）
}

# 保存時点に戻す: いま増えているものは外し、変わった・消えたものは付け直す
e2e_alias_restore() {
    local snap="$1" now line key val cur
    [[ -f "${snap}.ok" ]] || { log "WARNING" "  sf のエイリアスの保存に成功していないため、復元しません。"; return 1; }
    now=$(e2e_alias_dump) || { log "WARNING" "  sf alias list に失敗したため、エイリアスを復元できません（開発者のエイリアスを、誤って外さないため、何もしません）。"; return 1; }  # VAR=$(cmd) のため run 不使用
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        key="${line%%=*}"
        grep -q "^${key}=" "$snap" 2>/dev/null || run sf alias unset "$key" || true  # 意図的エラー無視
    done <<< "$now"
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        key="${line%%=*}"; val="${line#*=}"
        cur=$(printf '%s\n' "$now" | grep "^${key}=" | head -1)  # VAR=$(cmd) のため run 不使用
        [[ "$cur" == "${key}=${val}" ]] || run sf alias set "${key}=${val}" || true  # 意図的エラー無視
    done < "$snap"
}

# ------------------------------------------------------------------------------
# テスト用組織への管理用ログイン（認証 URL を使うため、ブラウザは開かない）
# ------------------------------------------------------------------------------
# 成否は sf の終了コードで判定する（sf は npm 版が前提）
# 失敗したら、sf の出力（原因）を表示し、一時的な失敗に備えて、待ってから 1 回だけやり直す
#   E2E_ADMIN_RETRY_WAIT: やり直すまでの待ち時間（秒。既定 5）
e2e_sf_admin_login() {
    local urlfile try out max=2 wait_sec="${E2E_ADMIN_RETRY_WAIT:-5}"
    urlfile=$(mktemp "${TMPDIR:-/tmp}/e2e-sfdx-url.XXXXXX") || die "一時ファイルを作成できません。"  # VAR=$(cmd) のため run 不使用
    chmod 600 "$urlfile" 2>/dev/null || true  # run 不使用: ファイル権限保護（Windows は効果なし・意図的エラー無視）
    printf '%s' "$E2E_SFDX_AUTH_URL" > "$urlfile"
    for ((try = 1; try <= max; try++)); do
        # 成否は終了コードで判定する。出力は、失敗時の表示のために受け取る
        if out=$(run sf org login sfdx-url --sfdx-url-file "$urlfile" --alias "$E2E_ADMIN_ALIAS"); then  # 条件チェック
            rm -f "$urlfile"  # run 不使用: 認証 URL の一時ファイルの削除（秘密情報を残さない）
            return 0
        fi
        log "WARNING" "  管理用ログインに失敗しました（${try}/${max}）。sf の出力:"
        printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | head -6 | while IFS= read -r line; do
            log "WARNING" "    $(_e2e_mask_line "$line")"  # トークン・認証 URL のリフレッシュトークンは、伏せ字にして表示する
        done
        if (( try < max )); then
            sleep "$wait_sec"  # run 不使用: 待機
        fi
    done
    rm -f "$urlfile"  # run 不使用: 認証 URL の一時ファイルの削除（秘密情報を残さない）
    die "テスト用組織への管理用ログインに失敗しました。"
}

# ------------------------------------------------------------------------------
# 削除対象の一覧・削除
# ------------------------------------------------------------------------------
# 一覧の取得に失敗したときの再試行（回数・待機秒）。
#   一覧の取得に失敗したのを「対象なし」と取り違えると、削除されないまま「成功」と報告してしまうため、
#   取得の成否を必ず確認し、失敗が続いたら呼び出し側で中断する（戻り値 1）。
#   これらの関数は $(...) の中で呼ばれる（標準出力が一覧になる）ため、ここでは log を出さない。
E2E_LIST_RETRY="${E2E_LIST_RETRY:-3}"
E2E_LIST_RETRY_WAIT="${E2E_LIST_RETRY_WAIT:-5}"

# GitHub のテスト用リポジトリの一覧（名前のみ）。取得に失敗したら、戻り値 1（何も出力しない）
e2e_list_target_repos() {
    local name out try
    e2e_require_guard
    for (( try = 1; try <= E2E_LIST_RETRY; try++ )); do
        if out=$(gh repo list "$E2E_OWNER" --limit 200 --json name --jq '.[].name' 2>/dev/null); then  # 条件チェック（成否は gh の終了コード）
            while IFS= read -r name; do
                name="${name%$'\r'}"
                e2e_is_target_repo "$name" && printf '%s\n' "$name"
            done <<< "$out"
            return 0
        fi
        (( try < E2E_LIST_RETRY )) && sleep "$E2E_LIST_RETRY_WAIT"  # run 不使用: 待機
    done
    return 1
}

e2e_delete_repo() {
    local name="$1"
    e2e_require_guard
    e2e_is_target_repo "$name" || die "削除対象外のリポジトリ名です: ${name}"
    run gh repo delete "${E2E_OWNER}/${name}" --yes || die "リポジトリの削除に失敗しました: ${E2E_OWNER}/${name}"
}

# Salesforce のテスト用外部クライアントアプリの一覧（名前のみ。管理用ログイン済みであること）
#   取得の成否は、sf の終了コードで判定する。取得に失敗したら、戻り値 1（何も出力しない）
e2e_list_target_ecas() {
    local name out try
    e2e_require_guard
    for (( try = 1; try <= E2E_LIST_RETRY; try++ )); do
        if out=$(sf org list metadata --metadata-type ExternalClientApplication --target-org "$E2E_ADMIN_ALIAS" --json 2>/dev/null); then  # 条件チェック（出力の取得のため run 不使用）
            printf '%s\n' "$out" | grep -oE '"fullName": *"[^"]*"' | sed -E 's/.*: *"(.*)"/\1/' \
                | while IFS= read -r name; do
                      name="${name%$'\r'}"
                      e2e_is_target_eca "$name" && printf '%s\n' "$name"
                  done  # パイプのみのため run 不使用
            return 0
        fi
        (( try < E2E_LIST_RETRY )) && sleep "$E2E_LIST_RETRY_WAIT"  # run 不使用: 待機
    done
    return 1
}

# 外部クライアントアプリ 1 つ（5 つの構成要素）を、削除用のデプロイ（destructiveChanges）で消す
e2e_delete_eca() {
    local name="$1" work
    e2e_require_guard
    e2e_is_target_eca "$name" || die "削除対象外のアプリ名です: ${name}"
    work=$(mktemp -d "${TMPDIR:-/tmp}/e2e-eca-del.XXXXXX") || die "一時ディレクトリを作成できません。"  # VAR=$(cmd) のため run 不使用
    mkdir -p "$work/force-app/main/default"  # run 不使用: 削除用デプロイの一時フォルダの準備
    printf '%s\n' '{ "packageDirectories": [ { "path": "force-app", "default": true } ], "namespace": "", "sourceApiVersion": "64.0" }' \
        > "$work/sfdx-project.json"
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
        '<Package xmlns="http://soap.sforce.com/2006/04/metadata"><version>64.0</version></Package>' \
        > "$work/package.xml"
    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<Package xmlns="http://soap.sforce.com/2006/04/metadata">'
        printf '  <types><members>%s</members><name>%s</name></types>\n' \
            "${name}"           "ExternalClientApplication" \
            "${name}_glbloauth" "ExtlClntAppGlobalOauthSettings" \
            "${name}_oauth"     "ExtlClntAppOauthSettings" \
            "${name}_oauthPlcy" "ExtlClntAppOauthConfigurablePolicies" \
            "${name}_plcy"      "ExtlClntAppConfigurablePolicies"
        printf '%s\n' '  <version>64.0</version>' '</Package>'
    } > "$work/destructiveChanges.xml"
    # 成否は終了コードで判定する（呼び出し側は、さらに一覧の再取得で、消えたことを確認する）
    local rc=0
    (cd "$work" && run sf project deploy start --manifest package.xml \
        --post-destructive-changes destructiveChanges.xml --target-org "$E2E_ADMIN_ALIAS" --wait 10) || rc=$?
    rm -rf "$work"  # run 不使用: 削除用デプロイの一時フォルダの後始末
    return $rc
}

# ------------------------------------------------------------------------------
# Hello World の Apex（リリースと削除の通しの確認用）
#   e2e は、Hello World のクラス（SfToolsE2eHello・そのテスト）を、PR 経由でリリースし、続けて削除する。
#   途中で止まって残った場合に備え、後掃除でも、名前が完全に一致するものだけを削除する。
# ------------------------------------------------------------------------------
E2E_APEX_HELLO="SfToolsE2eHello"
E2E_APEX_HELLO_TEST="SfToolsE2eHelloTest"
E2E_JOB_ALIAS="sf-tools-e2e-job"          # sf-start.sh で、接続する組織に付けるエイリアス（予約名ではない。終了時に、実行前の状態へ戻る）
e2e_is_target_apex() { [[ "$1" =~ ^SfToolsE2eHello(Test)?$ ]]; }

# Salesforce のテスト用 Apex クラスの一覧（名前のみ。管理用ログイン済みであること）
#   取得の成否は、sf の終了コードで判定する。取得に失敗したら、戻り値 1（何も出力しない）
e2e_list_target_apex() {
    local name out try
    e2e_require_guard
    for (( try = 1; try <= E2E_LIST_RETRY; try++ )); do
        if out=$(sf data query --query "SELECT Name FROM ApexClass WHERE Name IN ('${E2E_APEX_HELLO}','${E2E_APEX_HELLO_TEST}')" --target-org "$E2E_ADMIN_ALIAS" --json 2>/dev/null); then  # 条件チェック（出力の取得のため run 不使用）
            printf '%s\n' "$out" | grep -oE '"Name": *"[^"]*"' | sed -E 's/.*: *"(.*)"/\1/' \
                | while IFS= read -r name; do
                      name="${name%$'\r'}"
                      e2e_is_target_apex "$name" && printf '%s\n' "$name"
                  done  # パイプのみのため run 不使用
            return 0
        fi
        (( try < E2E_LIST_RETRY )) && sleep "$E2E_LIST_RETRY_WAIT"  # run 不使用: 待機
    done
    return 1
}

# テスト用 Apex クラスを、削除用のデプロイ（destructiveChanges）で消す。引数: クラス名（1 つ以上）
e2e_delete_apex() {
    local name work rc=0
    e2e_require_guard
    [[ $# -gt 0 ]] || die "削除する Apex クラスが指定されていません。"
    for name in "$@"; do
        e2e_is_target_apex "$name" || die "削除対象外の Apex クラス名です: ${name}"
    done
    work=$(mktemp -d "${TMPDIR:-/tmp}/e2e-eca-del.XXXXXX") || die "一時ディレクトリを作成できません。"  # VAR=$(cmd) のため run 不使用（後掃除の対象になる名前）
    mkdir -p "$work/force-app/main/default"  # run 不使用: 削除用デプロイの一時フォルダの準備
    printf '%s\n' '{ "packageDirectories": [ { "path": "force-app", "default": true } ], "namespace": "", "sourceApiVersion": "64.0" }' \
        > "$work/sfdx-project.json"
    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
        '<Package xmlns="http://soap.sforce.com/2006/04/metadata"><version>64.0</version></Package>' \
        > "$work/package.xml"
    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<Package xmlns="http://soap.sforce.com/2006/04/metadata">' '  <types>'
        for name in "$@"; do printf '    <members>%s</members>\n' "$name"; done
        printf '%s\n' '    <name>ApexClass</name>' '  </types>' '  <version>64.0</version>' '</Package>'
    } > "$work/destructiveChanges.xml"
    # 成否は終了コードで判定する（呼び出し側は、さらに一覧の再取得で、消えたことを確認する）
    (cd "$work" && run sf project deploy start --manifest package.xml \
        --post-destructive-changes destructiveChanges.xml --target-org "$E2E_ADMIN_ALIAS" --wait 10) || rc=$?
    rm -rf "$work"  # run 不使用: 削除用デプロイの一時フォルダの後始末
    return $rc
}

# Salesforce にある、テスト用 Apex クラスの件数を返す（標準出力）。取得に失敗したら、戻り値 1
#   失敗したときは、sf のエラーの要点（先頭の数行。Token・認証 URL は伏せる）を警告として表示する（標準エラー）。
#   これまで、エラーを捨てていたため、削除後の確認の失敗の原因が分からなかった
e2e_apex_count() {
    local out errf line
    e2e_require_guard
    e2e_is_target_apex "$1" || die "対象外の Apex クラス名です: ${1}"
    errf=$(mktemp "${E2E_TMP:-${TMPDIR:-/tmp}}/e2e-run.XXXXXX") || return 1  # VAR=$(cmd) のため run 不使用
    if ! out=$(sf data query --query "SELECT COUNT() FROM ApexClass WHERE Name = '${1}'" --target-org "$E2E_ADMIN_ALIAS" --json 2>"$errf"); then  # 条件チェック
        log "WARNING" "  Apex クラス ${1} の件数の取得に失敗しました。sf の出力:"
        { printf '%s\n' "$out"; cat "$errf"; } | grep -v '^[[:space:]]*$' | head -6 | while IFS= read -r line; do
            log "WARNING" "    $(_e2e_mask_line "$line")"
        done
        rm -f "$errf"  # run 不使用: エラー出力の一時ファイルの削除
        return 1
    fi
    rm -f "$errf"  # run 不使用: エラー出力の一時ファイルの削除
    printf '%s\n' "$out" | grep -oE '"totalSize": *[0-9]+' | grep -oE '[0-9]+$' | head -1
}

# ------------------------------------------------------------------------------
# GitHub での PR の作成・マージ・Actions の待ち（Hello World のリリースと削除の通しの確認用）
#   ブランチの作成・ファイルの追加・commit・push は、sf-tools のコマンド（sf-job.sh / sf-push.sh）で行う（通常の運用と同じ道）。
#   ここの部品が行うのは、PR の作成・マージ（通常の運用では GitHub の画面）と、Actions の実行の確認だけ。
#   操作できるのは、テスト用のリポジトリ（{E2E_OWNER}/force-e2e-日時）だけ。
# ------------------------------------------------------------------------------
# gh を、時間の上限（E2E_GH_TIMEOUT 秒。既定 120）付きで実行する。応答がないまま、e2e が止まり続けないようにする。
# 標準入力は閉じる（対話の待ちを避ける。引数は、すべてフラグで渡す）。timeout がない環境では、そのまま実行する
_e2e_gh() {
    if command -v timeout >/dev/null 2>&1; then  # 存在確認のため run 不使用
        timeout "${E2E_GH_TIMEOUT:-120}" gh "$@" </dev/null
    else
        gh "$@" </dev/null
    fi
}

_e2e_check_repo() {
    e2e_require_guard
    [[ "${1%%/*}" == "${E2E_OWNER:-}" ]] && e2e_is_target_repo "${1#*/}" \
        || die "テスト用ではないリポジトリには、操作できません: ${1}"
}

# main への PR を作り、PR 番号を標準出力に返す。引数: リポジトリ ブランチ名 タイトル
e2e_gh_pr_create() {
    local out
    _e2e_check_repo "$1"
    out=$(_e2e_gh pr create -R "$1" --base main --head "$2" --title "$3" --body "e2e の通し検証（自動作成）。マージ後に、リポジトリごと削除されます。" 2>/dev/null) || return 1  # VAR=$(cmd) のため run 不使用
    printf '%s\n' "$out" | grep -oE '[0-9]+$' | tail -1
}

# PR をマージする（マージコミット）。引数: リポジトリ PR 番号
e2e_gh_pr_merge() {
    _e2e_check_repo "$1"
    _e2e_gh pr merge "$2" -R "$1" --merge >/dev/null 2>&1  # 戻り値で判定するため run 不使用
}

# PR のイベントで起動したワークフローの実行が、完了するまで待ち、実行 ID を標準出力に返す。
#   引数: リポジトリ ワークフロー名 ブランチ名（PR の head ブランチ）
#   E2E_WF_TIMEOUT（既定 1200 秒）以内に完了しなければ、戻り値 1。E2E_POLL_SEC（既定 5 秒）おきに確認する
e2e_wait_pr_run() {
    local repo="$1" wf="$2" br="$3" i id status waited=0
    local timeout="${E2E_WF_TIMEOUT:-1200}" poll="${E2E_POLL_SEC:-5}"
    _e2e_check_repo "$repo"
    for (( i = 1; i <= ${E2E_RUN_FIND_TRIES:-24}; i++ )); do   # 起動までの待ち（既定 24 回 × poll 秒）
        id=$(_e2e_gh run list -R "$repo" --workflow "$wf" --branch "$br" --event pull_request --limit 1 --json databaseId --jq '.[0].databaseId' 2>/dev/null)  # VAR=$(cmd) のため run 不使用
        [[ -n "$id" ]] && break
        sleep "$poll"  # run 不使用: 待機
    done
    [[ -n "$id" ]] || return 1
    while (( waited < timeout )); do
        status=$(_e2e_gh run view "$id" -R "$repo" --json status --jq .status 2>/dev/null)  # VAR=$(cmd) のため run 不使用
        [[ "$status" == "completed" ]] && { printf '%s' "$id"; return 0; }
        sleep "$poll"; waited=$((waited + poll))  # run 不使用: 待機
    done
    return 1
}

# deploy-target.txt / remove-target.txt の本文（Hello World）
e2e_hello_deploy_target_text() {
    printf '%s\n' '[files]' \
        "force-app/main/default/classes/${E2E_APEX_HELLO}.cls" \
        "force-app/main/default/classes/${E2E_APEX_HELLO_TEST}.cls" \
        '' '[members]'
}
e2e_hello_remove_target_text() {
    printf '%s\n' '[files]' '' '[members]' \
        "ApexClass:${E2E_APEX_HELLO_TEST}" \
        "ApexClass:${E2E_APEX_HELLO}"
}

# ローカルのテスト用フォルダ（作業フォルダと JWT 用の証明書フォルダ）の一覧（フルパス）
e2e_list_target_local() {
    local d base
    e2e_require_guard
    for d in "${E2E_HOME_ROOT}/${E2E_OWNER}"/e2e-*; do
        [[ -d "$d" ]] || continue
        base=$(basename "$d")  # VAR=$(cmd) のため run 不使用
        e2e_is_target_project "$base" && printf '%s\n' "$d"
    done
    for d in "$HOME/.sf-jwt"/force-e2e-*; do
        [[ -d "$d" && ! -L "$d" ]] || continue  # シンボリックリンクは対象外
        base=$(basename "$d")  # VAR=$(cmd) のため run 不使用
        e2e_is_target_jwt_dir "$base" && printf '%s\n' "$d"
    done
    # 強制終了などで残った、一時ファイル・フォルダ（認証 URL を含む）。次のものは、対象外にする
    #   ・いま実行中の run.sh の一時フォルダ（E2E_TMP）
    #   ・新しいもの（E2E_TMP_MIN_AGE 分以内。既定 30。別の実行の途中かもしれない）
    local tdir="${TMPDIR:-/tmp}" age="${E2E_TMP_MIN_AGE:-30}"
    for d in "$tdir"/e2e-run.* "$tdir"/e2e-eca-del.* "$tdir"/e2e-sfdx-url.*; do
        # 自分が作ったもの（所有者が自分）だけを対象にする。シンボリックリンクは対象外（共有の一時フォルダ対策）
        [[ -e "$d" && ! -L "$d" && -O "$d" ]] || continue
        base=$(basename "$d")  # VAR=$(cmd) のため run 不使用
        e2e_is_target_tmp "$base" || continue
        [[ -n "${E2E_TMP:-}" && "$d" == "$E2E_TMP" ]] && continue
        [[ -n "$(find "$d" -maxdepth 0 -mmin +"$age" 2>/dev/null)" ]] && printf '%s\n' "$d"
    done
}

e2e_delete_local() {
    local d="$1" base
    e2e_require_guard
    base=$(basename "$d")  # VAR=$(cmd) のため run 不使用
    e2e_is_target_project "$base" || e2e_is_target_jwt_dir "$base" || e2e_is_target_tmp "$base" \
        || die "削除対象外のフォルダ名です: ${d}"
    # JWT 用の証明書フォルダは、sf-init が作る中身（server.key / server.crt）だけのときに限り、削除する
    #   名前が一致しても、ほかのファイルが入っている（e2e が作ったものではない可能性がある）場合は、消さずに失敗として返す
    if e2e_is_target_jwt_dir "$base"; then
        local f
        for f in "$d"/* "$d"/.[!.]*; do
            [[ -e "$f" || -L "$f" ]] || continue
            case "$(basename "$f")" in
                server.key|server.crt) ;;
                *) log "ERROR" "  ${d} に、想定外のファイル（$(basename "$f")）があるため、削除しません。"; return 1 ;;
            esac
        done
    fi
    run rm -rf "${d:?}" || die "フォルダの削除に失敗しました: ${d}"
}

# ------------------------------------------------------------------------------
# 一括の掃除
#   e2e_cleanup_all MODE   MODE = list（一覧のみ。何も消さない）/ delete（消す）
#   失敗が残った場合は、非ゼロを返す
# ------------------------------------------------------------------------------
# Salesforce 側の掃除（外部クライアントアプリ・Apex クラス）。戻り値 1: 失敗したものがある（ほかの掃除は止めずに続ける）
#   管理用ログインは、呼び出し側で済ませておくこと
_e2e_cleanup_salesforce() {
    local mode="$1" failed=0 name list after after_apex
    if ! list=$(e2e_list_target_ecas); then  # 条件チェック
        log "ERROR" "  Salesforce: 外部クライアントアプリの一覧を取得できませんでした（対象の有無を判断できません）。"
        failed=1
    elif [[ -z "$list" ]]; then
        log "INFO" "  Salesforce: 対象の外部クライアントアプリはありません。"
    else
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            log "INFO" "  Salesforce: ${name}"
            if [[ "$mode" == "delete" ]]; then
                if ! e2e_delete_eca "$name"; then  # 条件チェック
                    log "ERROR" "  Salesforce: ${name} の削除（deploy）に失敗しました。"
                    failed=1
                    continue
                fi
                # 消えたかは、一覧の再取得で確認する（再取得に失敗した場合も、削除できたとはみなさない）
                if ! after=$(e2e_list_target_ecas); then  # 条件チェック
                    log "ERROR" "  Salesforce: ${name} の削除後の一覧を取得できませんでした（削除できたか確認できません）。"
                    failed=1
                elif grep -qx "$name" <<< "$after"; then
                    log "ERROR" "  Salesforce: ${name} を削除できませんでした。"
                    failed=1
                fi
            fi
        done <<< "$list"
    fi

    # Salesforce の Apex クラス（Hello World。途中で止まって残った場合のため）
    if ! list=$(e2e_list_target_apex); then  # 条件チェック
        log "ERROR" "  Salesforce: Apex クラスの一覧を取得できませんでした（対象の有無を判断できません）。"
        failed=1
    elif [[ -z "$list" ]]; then
        log "INFO" "  Salesforce: 対象の Apex クラスはありません。"
    else
        local -a apex_names=()
        mapfile -t apex_names <<< "$list"
        for name in "${apex_names[@]}"; do log "INFO" "  Salesforce: Apex クラス ${name}"; done
        if [[ "$mode" == "delete" ]]; then
            if ! e2e_delete_apex "${apex_names[@]}"; then  # 条件チェック
                log "ERROR" "  Salesforce: Apex クラスの削除（deploy）に失敗しました。"
                failed=1
            elif ! after_apex=$(e2e_list_target_apex); then  # 条件チェック
                log "ERROR" "  Salesforce: Apex クラスの削除後の一覧を取得できませんでした（削除できたか確認できません）。"
                failed=1
            elif [[ -n "$after_apex" ]]; then
                log "ERROR" "  Salesforce: Apex クラスを削除できませんでした。"
                failed=1
            fi
        fi
    fi

    return $failed
}

e2e_cleanup_all() {
    local mode="$1" failed=0 name d list
    e2e_require_guard

    log "HEADER" "e2e の掃除（${mode}）"

    # GitHub
    #   一覧の取得に失敗したときは「対象なし」とみなさず、失敗として記録して次へ進む（後始末を途中で止めないため）
    if ! list=$(e2e_list_target_repos); then  # 条件チェック
        log "ERROR" "  GitHub: リポジトリの一覧を取得できませんでした（対象の有無を判断できません）。"
        failed=1
    elif [[ -z "$list" ]]; then
        log "INFO" "  GitHub: 対象のリポジトリはありません。"
    else
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            log "INFO" "  GitHub: ${E2E_OWNER}/${name}"
            [[ "$mode" == "delete" ]] && { e2e_delete_repo "$name" || failed=1; }
        done <<< "$list"
    fi

    # Salesforce（管理用ログインに失敗しても、ほかの掃除（ローカル）は止めずに続ける）
    if ( e2e_sf_admin_login ); then  # 条件チェック（失敗は、サブシェルの die で、ここに戻る）
        _e2e_cleanup_salesforce "$mode" || failed=1
    else
        log "ERROR" "  Salesforce: 管理用ログインに失敗したため、Salesforce の掃除（アプリ・Apex クラス）を行えませんでした。"
        failed=1
    fi

    # ローカル
    list=$(e2e_list_target_local)  # VAR=$(cmd) のため run 不使用
    if [[ -z "$list" ]]; then
        log "INFO" "  ローカル: 対象のフォルダはありません。"
    else
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            log "INFO" "  ローカル: ${d}"
            [[ "$mode" == "delete" ]] && { e2e_delete_local "$d" || failed=1; }
        done <<< "$list"
    fi

    return $failed
}

# ------------------------------------------------------------------------------
# sf-init に流す標準入力（質問の順番に依存する。質問を変えたら、ここも直すこと）
# ------------------------------------------------------------------------------
#   Phase 1 続行 Y → Phase 2 確認 Y → 環境種別 2（検証）→ 検証環境で続行 Y → Phase 5 ブランチ 3（main のみ）
#   → Phase 6 PAT（先頭の改行は、直前の入力の残りを press_enter が消費）→ 空行（Phase 7 の press_enter）
#   → Slack Token → チャンネル ID → 空行（招待の press_enter）→ Phase 10 アプリ種別 2 → Sandbox? N
#   → init フォルダ削除 N（Phase 10 が最後。SF_TOOLS_TOKEN は不要になった: sf-tools は公開リポジトリ）
e2e_make_input() {
    printf '%s\n' "Y" "Y" "2" "Y" "3" \
        "$E2E_PAT_TOKEN" "" \
        "$E2E_SLACK_BOT_TOKEN" "$E2E_SLACK_CHANNEL_ID" "" \
        "2" "N" \
        "N"
}

# 失敗したワークフローの実行の、失敗したステップのログ（末尾 E2E_FAIL_LOG_LINES 行。既定 40）を表示する。
#   後掃除でリポジトリが消えると、失敗の原因を追えなくなるため。引数: リポジトリ 実行ID ラベル
#   鍵一式の値（Token・認証 URL）は、念のため、*** に置き換える。表示だけで、戻り値は常に 0
e2e_show_run_failure() {
    local repo="$1" id="$2" label="$3" out line v
    _e2e_check_repo "$repo"
    log "WARNING" "${label}: 失敗したステップのログ（末尾 ${E2E_FAIL_LOG_LINES:-40} 行）:"
    # 形式: ジョブ名 TAB ステップ名 TAB 時刻 本文 → [ステップ名] 本文。色の指定は除く
    out=$(_e2e_gh run view "$id" -R "$repo" --log-failed 2>/dev/null \
        | sed -E 's/\x1b\[[0-9;]*m//g; s/^([^\t]*)\t([^\t]*)\t[^ ]+Z /[\2] /' \
        | tail -n "${E2E_FAIL_LOG_LINES:-40}") || true  # VAR=$(cmd) のため run 不使用
    if [[ -z "$out" ]]; then
        log "WARNING" "  （ログを取得できませんでした。実行 ID: ${id}）"
        return 0
    fi
    while IFS= read -r line; do
        printf '    %s\n' "$(_e2e_mask_line "$line")"
    done <<< "$out"
    return 0
}

# ------------------------------------------------------------------------------
# sf-tools のコマンド（sf-job.sh / sf-dryrun.sh / sf-push.sh など）を、通常の運用と同じように実行する
#   通常の運用: 開発者が、ターミナルで、sf-tools のコマンドを使って作業する。e2e も、同じコマンドを使う。
#   質問への答えは標準入力に流し、sf org login web / code / ブラウザは、差し替え（shims）で、自動化する。
# ------------------------------------------------------------------------------
# ファイルの末尾を、鍵一式の値を *** に置き換えて、表示する。表示だけで、戻り値は常に 0
#   引数: ファイル ラベル [行数。既定は E2E_FAIL_LOG_LINES（40）]
e2e_show_file_tail() {
    local f="$1" label="$2" n="${3:-${E2E_FAIL_LOG_LINES:-40}}" line v
    log "WARNING" "${label}: 出力の末尾（${n} 行）:"
    if [[ ! -s "$f" ]]; then
        log "WARNING" "  （出力がありません）"
        return 0
    fi
    while IFS= read -r line; do
        printf '    %s\n' "$(_e2e_mask_line "$line")"
    done < <(sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' "$f" | tail -n "$n")
    return 0
}

# sf-tools のスクリプトを、指定のフォルダで実行する。出力は ${E2E_TMP}/{ラベル}.out に残す。
#   失敗（終了コード 0 以外）なら、出力の末尾を表示して、戻り値 1
#   引数: ラベル フォルダ 標準入力（printf の %b 形式。例: 'e2e-hello\nY\nalias\n'。なければ空） スクリプト [引数...]
#   フォルダは、テスト用の作業フォルダ（{E2E_HOME_ROOT}/{E2E_OWNER}/e2e-…）の中だけ
#   SF_LAUNCHER_ACTIVE=1: sf-start.sh が、対話のメニュー（sf-launcher.sh）を起動しないようにする
# 実行して、スクリプトの終了コードを返す（失敗の表示はしない）。引数は e2e_run_sf_cmd と同じ
#   長い処理（sf-job の clone と npm install、sf-dryrun など）が、止まったのか、動いているのか分かるように、
#   E2E_HEARTBEAT_SEC 秒（既定 30）おきに、経過時間を表示する。
#   E2E_CMD_TIMEOUT 秒（既定 1200）を超えたら、打ち切る（終了コード 124）。止まったまま、e2e 全体が止まり続けないための保険
_e2e_exec_sf_cmd() {
    local label="$1" dir="$2" input="$3" outf pid start=$SECONDS next
    local hb="${E2E_HEARTBEAT_SEC:-30}" to="${E2E_CMD_TIMEOUT:-1200}" poll="${E2E_CMD_POLL_SEC:-5}"
    shift 3
    e2e_require_guard
    case "$dir" in
        "${E2E_HOME_ROOT}/${E2E_OWNER}/e2e-"*) ;;
        *) die "テスト用の作業フォルダの外では、実行できません: ${dir}" ;;
    esac
    [[ -d "$dir" ]] || { log "ERROR" "  ${label}: フォルダがありません: ${dir}"; return 125; }
    outf="${E2E_TMP:?}/${label}.out"
    log "INFO" "  実行: bash $(basename "$1") ${*:2}（出力: ${outf}。上限 ${to} 秒）"
    (
        cd "$dir" || exit 125
        if command -v timeout >/dev/null 2>&1; then  # 存在確認のため run 不使用
            printf '%b' "$input" | PATH="${E2E_SHIM_DIR:-}:${PATH}" SF_LAUNCHER_ACTIVE=1 timeout "$to" bash "$@"
        else
            printf '%b' "$input" | PATH="${E2E_SHIM_DIR:-}:${PATH}" SF_LAUNCHER_ACTIVE=1 bash "$@"
        fi
    ) > "$outf" 2>&1 &  # 背景で動かし、経過を表示しながら待つ
    pid=$!
    next=$hb
    while kill -0 "$pid" 2>/dev/null; do  # 存在確認のため run 不使用
        sleep "$poll"  # run 不使用: 待機
        if (( SECONDS - start >= next )); then
            log "INFO" "    … 実行中: ${label}（経過 $(( SECONDS - start )) 秒）"
            next=$(( next + hb ))
        fi
    done
    wait "$pid"
}

e2e_run_sf_cmd() {
    local rc
    _e2e_exec_sf_cmd "$@"
    rc=$?
    if [[ $rc -ne 0 ]]; then
        log "ERROR" "  ${1}: 終了コード ${rc}$([[ $rc -eq 124 ]] && echo "（時間切れ: E2E_CMD_TIMEOUT 秒を超えたため、打ち切りました）")"
        e2e_show_file_tail "${E2E_TMP}/${1}.out" "$1"
        return 1
    fi
    return 0
}

# 拒否されること（終了コードが 0 以外）を確認する。拒否されれば戻り値 0、成功してしまったら戻り値 1
#   出力の内容は、呼び出し側が ${E2E_TMP}/{ラベル}.out で確認する。引数は e2e_run_sf_cmd と同じ
e2e_run_sf_cmd_refused() {
    local rc
    _e2e_exec_sf_cmd "$@"
    rc=$?
    if [[ $rc -eq 0 ]]; then
        log "ERROR" "  ${1}: 拒否されるはずが、成功しました"
        return 1
    fi
    # 125（フォルダがない）・126・127（bash が起動できない・コマンドがない）は、拒否ではなく、実行の失敗
    if [[ $rc -ge 125 && $rc -le 127 ]]; then
        log "ERROR" "  ${1}: 拒否ではなく、実行そのものに失敗しました（終了コード ${rc}）"
        return 1
    fi
    return 0
}

# sf-start.sh が背景で実行する sf-install.sh（フック設置・release フォルダの準備・npm install）が終わるまで待つ。
#   引数: クローンのフォルダ。E2E_INSTALL_TIMEOUT 秒（既定 600）以内に終わらなければ、戻り値 1
e2e_wait_sf_install() {
    local log_file="$1/sf-tools/logs/sf-install.log" waited=0
    local timeout="${E2E_INSTALL_TIMEOUT:-600}" poll="${E2E_POLL_SEC:-5}"
    while (( waited < timeout )); do
        grep -q "npm install の確認が完了しました" "$log_file" 2>/dev/null && return 0
        sleep "$poll"; waited=$((waited + poll))  # run 不使用: 待機
    done
    return 1
}

# ワークフローの実行の結果（conclusion）を、標準出力に返す。引数: リポジトリ 実行ID
#   実行が完了した直後は、API の反映の遅れや、gh の一時的な失敗で、空になることがある（実機で、成功した実行が、
#   空と読まれて FAIL になった）。空のときだけ、E2E_POLL_SEC 秒（既定 5）おきに、最大 E2E_CONCLUSION_TRIES 回（既定 6）やり直す。
#   success / failure などの値が返ったら、やり直さない
e2e_run_conclusion() {
    local out="" i
    for (( i = 1; i <= ${E2E_CONCLUSION_TRIES:-6}; i++ )); do
        out=$(_e2e_gh run view "$2" -R "$1" --json conclusion --jq .conclusion 2>/dev/null)  # VAR=$(cmd) のため run 不使用
        [[ -n "$out" ]] && break
        (( i < ${E2E_CONCLUSION_TRIES:-6} )) && sleep "${E2E_POLL_SEC:-5}"  # run 不使用: 待機
    done
    printf '%s' "$out"
}

# ワークフローの実行の、特定のステップの結果を、標準出力に返す（空のときは、e2e_run_conclusion と同じ扱い）
#   引数: リポジトリ 実行ID ステップ名
e2e_step_conclusion() {
    local out="" i
    for (( i = 1; i <= ${E2E_CONCLUSION_TRIES:-6}; i++ )); do
        out=$(_e2e_gh run view "$2" -R "$1" --json jobs \
            --jq ".jobs[].steps[] | select(.name==\"$3\") | .conclusion" 2>/dev/null | head -1)  # VAR=$(cmd) のため run 不使用
        [[ -n "$out" ]] && break
        (( i < ${E2E_CONCLUSION_TRIES:-6} )) && sleep "${E2E_POLL_SEC:-5}"  # run 不使用: 待機
    done
    printf '%s' "$out"
}

# 失敗したワークフローの実行を、1 回だけ再実行し（gh run rerun --failed）、完了するまで待つ。
#   Salesforce や通信側の一時的なエラー（MetadataTransferError など）で、失敗することがある。開発者が GitHub の画面で
#   「Re-run」を押すのと同じ操作。引数: リポジトリ 実行ID。再実行できて、完了したら戻り値 0（結果は e2e_run_conclusion で読む）
#   再実行の前の試行番号（attempt）を覚え、試行番号が増えて、完了するまで待つ（再実行の直後は、前の試行の「完了」が見えるため）
#   E2E_WF_TIMEOUT 秒（既定 1200）以内に完了しなければ、戻り値 1
e2e_rerun_and_wait() {
    local repo="$1" id="$2" a0 a st waited=0
    local timeout="${E2E_WF_TIMEOUT:-1200}" poll="${E2E_POLL_SEC:-5}"
    _e2e_check_repo "$repo"
    a0=$(_e2e_gh run view "$id" -R "$repo" --json attempt --jq .attempt 2>/dev/null)  # VAR=$(cmd) のため run 不使用
    [[ "$a0" =~ ^[0-9]+$ ]] || return 1
    _e2e_gh run rerun "$id" -R "$repo" --failed >/dev/null 2>&1 || return 1  # 戻り値で判定するため run 不使用
    while (( waited < timeout )); do
        a=$(_e2e_gh run view "$id" -R "$repo" --json attempt --jq .attempt 2>/dev/null)    # VAR=$(cmd) のため run 不使用
        st=$(_e2e_gh run view "$id" -R "$repo" --json status --jq .status 2>/dev/null)     # VAR=$(cmd) のため run 不使用
        [[ "$a" =~ ^[0-9]+$ ]] && (( a > a0 )) && [[ "$st" == "completed" ]] && return 0
        sleep "$poll"; waited=$((waited + poll))  # run 不使用: 待機
    done
    return 1
}
