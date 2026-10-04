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
#   E2E_SF_TOOLS_TOKEN    SF_TOOLS_TOKEN に登録する Fine-grained PAT
#   E2E_SFDX_AUTH_URL     テスト用組織の認証 URL（sf org login sfdx-url 用。リフレッシュトークンを含む）
#   E2E_SF_REDIRECTED     （任意）1 を指定すると sf の起動方式を切り替える。Git Bash で sf の終了コードが
#                         常に 1 になる環境（公式インストーラー版 + 自動更新版）の回避用
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

# Windows（Git Bash）かどうか（lib/common.sh の is_gitbash を使う。$OSTYPE は msys / mingw / cygwin のいずれにもなる）
e2e_is_windows() { is_gitbash; }

# 新しいテスト用のプロジェクト名（これが作業フォルダ名になり、リポジトリは force-<名前> になる）
e2e_new_project_name() { printf 'e2e-%s' "$(date +%Y%m%d-%H%M%S)"; }

# ------------------------------------------------------------------------------
# 鍵一式の読み込み
# ------------------------------------------------------------------------------
e2e_fixture_path() { printf '%s' "${E2E_FIXTURE:-$HOME/.sf-tools-e2e/fixture.env}"; }

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
             E2E_SLACK_CHANNEL_ID E2E_SF_TOOLS_TOKEN E2E_SFDX_AUTH_URL; do
        [[ -n "${!v:-}" ]] || die "${v} が未設定です（${f}）。"
    done
    [[ -n "${E2E_SF_REDIRECTED:-}" ]] && export SF_REDIRECTED="$E2E_SF_REDIRECTED"
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
e2e_alias_dump() {
    sf alias list --json 2>/dev/null | tr -d '\n\r' \
        | grep -oE '"alias": *"[^"]*", *"value": *"[^"]*"' \
        | sed -E 's/"alias": *"([^"]*)", *"value": *"([^"]*)"/\1=\2/'  # パイプのみのため run 不使用
}

e2e_alias_snapshot() { e2e_alias_dump > "$1"; }

# 保存時点に戻す: いま増えているものは外し、変わった・消えたものは付け直す
e2e_alias_restore() {
    local snap="$1" now line key val cur
    now=$(e2e_alias_dump)  # VAR=$(cmd) のため run 不使用
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
# sf は成功しても終了コード 1 を返す環境があるため、成否は出力の username で判定する
e2e_sf_connected() {
    sf org display --target-org "$1" --json 2>/dev/null | grep -q '"username": *"[^"]*"'  # 判定のみのため run 不使用
}

e2e_sf_admin_login() {
    local urlfile
    urlfile=$(mktemp "${TMPDIR:-/tmp}/e2e-sfdx-url.XXXXXX") || die "一時ファイルを作成できません。"  # VAR=$(cmd) のため run 不使用
    chmod 600 "$urlfile" 2>/dev/null || true  # run 不使用: ファイル権限保護（Windows は効果なし・意図的エラー無視）
    printf '%s' "$E2E_SFDX_AUTH_URL" > "$urlfile"
    run sf org login sfdx-url --sfdx-url-file "$urlfile" --alias "$E2E_ADMIN_ALIAS" || true  # 終了コードを信頼できないため無視
    rm -f "$urlfile"
    e2e_sf_connected "$E2E_ADMIN_ALIAS" || die "テスト用組織への管理用ログインに失敗しました。"
}

# ------------------------------------------------------------------------------
# 削除対象の一覧・削除
# ------------------------------------------------------------------------------
# GitHub のテスト用リポジトリの一覧（名前のみ）
e2e_list_target_repos() {
    local name
    e2e_require_guard
    gh repo list "$E2E_OWNER" --limit 200 --json name --jq '.[].name' 2>/dev/null \
        | while IFS= read -r name; do
              name="${name%$'\r'}"
              e2e_is_target_repo "$name" && printf '%s\n' "$name"
          done  # パイプのみのため run 不使用
}

e2e_delete_repo() {
    local name="$1"
    e2e_require_guard
    e2e_is_target_repo "$name" || die "削除対象外のリポジトリ名です: ${name}"
    run gh repo delete "${E2E_OWNER}/${name}" --yes || die "リポジトリの削除に失敗しました: ${E2E_OWNER}/${name}"
}

# Salesforce のテスト用外部クライアントアプリの一覧（名前のみ。管理用ログイン済みであること）
e2e_list_target_ecas() {
    local name
    e2e_require_guard
    sf org list metadata --metadata-type ExternalClientApplication --target-org "$E2E_ADMIN_ALIAS" --json 2>/dev/null \
        | grep -oE '"fullName": *"[^"]*"' | sed -E 's/.*: *"(.*)"/\1/' \
        | while IFS= read -r name; do
              name="${name%$'\r'}"
              e2e_is_target_eca "$name" && printf '%s\n' "$name"
          done  # パイプのみのため run 不使用
}

# 外部クライアントアプリ 1 つ（5 つの構成要素）を、削除用のデプロイ（destructiveChanges）で消す
e2e_delete_eca() {
    local name="$1" work
    e2e_require_guard
    e2e_is_target_eca "$name" || die "削除対象外のアプリ名です: ${name}"
    work=$(mktemp -d "${TMPDIR:-/tmp}/e2e-eca-del.XXXXXX") || die "一時ディレクトリを作成できません。"  # VAR=$(cmd) のため run 不使用
    mkdir -p "$work/force-app/main/default"
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
    # 終了コードを信頼できない環境があるため、成否は呼び出し側が一覧の再取得で確認する
    (cd "$work" && run sf project deploy start --manifest package.xml \
        --post-destructive-changes destructiveChanges.xml --target-org "$E2E_ADMIN_ALIAS" --wait 10) || true  # 終了コードを信頼できないため無視
    rm -rf "$work"
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
        [[ -d "$d" ]] || continue
        base=$(basename "$d")  # VAR=$(cmd) のため run 不使用
        e2e_is_target_jwt_dir "$base" && printf '%s\n' "$d"
    done
}

e2e_delete_local() {
    local d="$1" base
    e2e_require_guard
    base=$(basename "$d")  # VAR=$(cmd) のため run 不使用
    e2e_is_target_project "$base" || e2e_is_target_jwt_dir "$base" || die "削除対象外のフォルダ名です: ${d}"
    run rm -rf "${d:?}" || die "フォルダの削除に失敗しました: ${d}"
}

# ------------------------------------------------------------------------------
# 一括の掃除
#   e2e_cleanup_all MODE   MODE = list（一覧のみ。何も消さない）/ delete（消す）
#   失敗が残った場合は、非ゼロを返す
# ------------------------------------------------------------------------------
e2e_cleanup_all() {
    local mode="$1" failed=0 name d list
    e2e_require_guard

    log "HEADER" "e2e の掃除（${mode}）"

    # GitHub
    list=$(e2e_list_target_repos)  # VAR=$(cmd) のため run 不使用
    if [[ -z "$list" ]]; then
        log "INFO" "  GitHub: 対象のリポジトリはありません。"
    else
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            log "INFO" "  GitHub: ${E2E_OWNER}/${name}"
            [[ "$mode" == "delete" ]] && { e2e_delete_repo "$name" || failed=1; }
        done <<< "$list"
    fi

    # Salesforce
    e2e_sf_admin_login
    list=$(e2e_list_target_ecas)  # VAR=$(cmd) のため run 不使用
    if [[ -z "$list" ]]; then
        log "INFO" "  Salesforce: 対象の外部クライアントアプリはありません。"
    else
        while IFS= read -r name; do
            [[ -z "$name" ]] && continue
            log "INFO" "  Salesforce: ${name}"
            if [[ "$mode" == "delete" ]]; then
                e2e_delete_eca "$name"
                if e2e_list_target_ecas | grep -qx "$name"; then
                    log "ERROR" "  Salesforce: ${name} を削除できませんでした。"
                    failed=1
                fi
            fi
        done <<< "$list"
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
#   → Phase 11 SF_TOOLS_TOKEN（直前の入力の残りを press_enter が消費）→ init フォルダ削除 N
e2e_make_input() {
    printf '%s\n' "Y" "Y" "2" "Y" "3" \
        "$E2E_PAT_TOKEN" "" \
        "$E2E_SLACK_BOT_TOKEN" "$E2E_SLACK_CHANNEL_ID" "" \
        "2" "N" \
        "$E2E_SF_TOOLS_TOKEN" "N"
}
