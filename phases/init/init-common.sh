#!/bin/bash
# ==============================================================================
# init-common.sh - sf-init.sh 専用ヘルパー関数ライブラリ
# ==============================================================================
# sf-init.sh の各フェーズスクリプトが source して使用する共通ヘルパー関数集。
# このファイルは lib/common.sh の source 後に読み込むこと。
#
# 【提供する関数】
#   open_browser URL          ... OS を判定してブラウザを開く（lib/common.sh に同名関数あり）
#   generate_jwt_cert         ... JWT 用秘密鍵・証明書を openssl で生成する（生成後に、発行先が空でないことを確認する）
#   ensure_jwt_cert_subject   ... 既存の証明書の発行先が空なら、秘密鍵はそのままで、証明書だけを作り直す
#   register_jwt_secret       ... JWT 認証情報を取得・テストして GitHub Secret に登録する
#                                 テスト失敗時はスキップして続行するか確認する（DE 組織対応）
#   ensure_sf_tools_branch BR ... 選択した環境（main / development）に合わせて ~/sf-tools の最新化を確認する
#                                 （ブランチ違い・遅れ・ローカル変更を検出。更新したら die で中断）
#
# 【lib/common.sh から利用可能な関数】
#   press_enter [MSG]         ... Enter 待ち（q で中断）
#   read_or_quit VAR PROMPT   ... 入力受付（q で中断）
# ==============================================================================

# Salesforce 組織の接続情報の共通部品（ログイン先の選択・組織の種類の読み取り・本番は main のみ）
_INIT_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_INIT_COMMON_DIR}/../../lib/org.sh"

# ------------------------------------------------------------------------------
# ブラウザを開く（OS 判定）- lib/common.sh で定義済みなら再定義しない
# ------------------------------------------------------------------------------
if ! declare -f open_browser &>/dev/null; then
    open_browser() {
        local url="$1"
        if command -v start &>/dev/null; then
            start "" "$url" 2>/dev/null || true
        elif command -v open &>/dev/null; then
            open "$url" 2>/dev/null || true
        elif command -v xdg-open &>/dev/null; then
            xdg-open "$url" 2>/dev/null || true
        fi
    }
fi

# ------------------------------------------------------------------------------
# 証明書の発行先（subject）の部品
# ------------------------------------------------------------------------------
# _jwt_cert_subject_arg REPO_NAME - openssl req の -subj に渡す値を返す
#   Git Bash は、-subj の先頭の / を Windows のパスと取り違えるため、// で書く（Git Bash が / に直して渡す）。
#   Git Bash 以外（macOS・Linux・WSL）で // のまま渡すと、openssl は「/CN は未知の属性」と読み飛ばし、
#   発行先が空の証明書を、終了コード 0 で作る。Salesforce は「アップロードされたファイルは証明書ではありません」と拒否する。
_jwt_cert_subject_arg() {
    if is_gitbash; then
        printf '%s' "//CN=sf-jwt-$1"
    else
        printf '%s' "/CN=sf-jwt-$1"
    fi
}

# _jwt_cert_subject_state CRT_FILE - 証明書に、発行先（subject）が入っているか
#   戻り値: 0=入っている / 1=空 / 2=読み取れない（証明書ではない・ファイルがない）
_jwt_cert_subject_state() {
    local subj
    subj=$(openssl x509 -in "$1" -noout -subject 2>/dev/null) || return 2  # VAR=$(cmd) のため run 不使用
    subj="${subj#subject=}"
    subj="${subj//[[:space:]]/}"
    [[ -n "$subj" ]]
}

# _issue_jwt_cert KEY_FILE CRT_FILE REPO_NAME - 秘密鍵から、発行先つきの自己署名証明書（10 年）を作る。鍵は変えない
_issue_jwt_cert() {
    # run 不使用: 呼び出し元が、終了コードを直接確認する
    openssl req -new -x509 -days 3650 -key "$1" -out "$2" -subj "$(_jwt_cert_subject_arg "$3")"
}

# ensure_jwt_cert_subject JWT_DIR REPO_NAME
#   既存の証明書の発行先が空なら、秘密鍵はそのままで、証明書だけを作り直す。
#   以前の sf-tools は、Mac・Linux で、発行先が空の証明書を作っていた（上の _jwt_cert_subject_arg）。
#   空の証明書は、Salesforce が拒否するため、どの組織にもアップロードされていない。
#   秘密鍵は変えないので、GitHub に登録済みの SF_PRIVATE_KEY は、そのまま有効（ずれない）。
#   発行先が入っているもの・読み取れないものは、触らない。
ensure_jwt_cert_subject() {
    local jwt_dir="$1" repo_name="$2" crt state
    crt="${jwt_dir}/server.crt"
    _jwt_cert_subject_state "$crt"; state=$?
    [[ $state -eq 1 ]] || return 0
    log "WARNING" "既存の証明書の発行先（subject）が空です。このままでは、Salesforce が「証明書ではありません」と拒否します。"
    log "WARNING" "  秘密鍵はそのままで、証明書だけを作り直します: ${crt}"
    if ! _issue_jwt_cert "${jwt_dir}/server.key" "${crt}.tmp" "$repo_name"; then
        rm -f "${crt}.tmp"  # run 不使用: 失敗時の後始末（なくても続行）
        die "証明書の再発行に失敗しました。"
    fi
    if ! _jwt_cert_subject_state "${crt}.tmp"; then
        rm -f "${crt}.tmp"  # run 不使用: 失敗時の後始末（なくても続行）
        die "再発行した証明書の発行先（subject）が空、または読み取れません。"
    fi
    mv -f "${crt}.tmp" "$crt" || die "証明書の置き換えに失敗しました: ${crt}"  # run 不使用: 終了コードを直接確認
    log "SUCCESS" "証明書を作り直しました（秘密鍵は、そのままです）。"
}

# ------------------------------------------------------------------------------
# JWT 用秘密鍵・証明書を openssl で生成する
# 引数:
#   $1 - jwt_dir  : 保存先ディレクトリ（例: ~/.sf-jwt/force-test）
#   $2 - repo_name: リポジトリ名（証明書の CN に使用）
# 出力:
#   $jwt_dir/server.key（秘密鍵）
#   $jwt_dir/server.crt（公開鍵証明書）
# ------------------------------------------------------------------------------
generate_jwt_cert() {
    local jwt_dir="$1"
    local repo_name="$2"

    mkdir -p "$jwt_dir"
    chmod 700 "$jwt_dir" 2>/dev/null || true  # run 不使用: ファイル権限保護（Windows は効果なし）

    # 既存の証明書があればスキップ（--resume 時の再生成による Salesforce との不一致を防ぐ）
    if [[ -f "${jwt_dir}/server.key" && -f "${jwt_dir}/server.crt" ]]; then
        log "INFO" "既存の証明書を使用します（スキップ）: ${jwt_dir}/"
        log "INFO" "  秘密鍵: ${jwt_dir}/server.key"
        log "INFO" "  証明書: ${jwt_dir}/server.crt"
        ensure_jwt_cert_subject "$jwt_dir" "$repo_name"   # 発行先が空の証明書（以前の不具合）なら、直す
        return 0
    fi

    log "INFO" "JWT 用証明書を生成中: ${jwt_dir}/"
    # run 不使用: 変数代入・openssl の終了コードを直接確認するため
    # OpenSSL 3.x は genrsa が PKCS#8 を出力するため、-traditional で PKCS#1(RSA) に変換する
    # Salesforce JWT Bearer Flow は PKCS#1 形式（-----BEGIN RSA PRIVATE KEY-----）を要求する
    openssl genrsa -out "${jwt_dir}/server.key.tmp" 2048 2>/dev/null \
        || die "秘密鍵の生成に失敗しました。openssl がインストールされているか確認してください。"
    # -traditional: OpenSSL 3.x で PKCS#1 形式を強制。1.x では不要なためフォールバック
    if openssl rsa -traditional -in "${jwt_dir}/server.key.tmp" \
                                -out "${jwt_dir}/server.key" 2>/dev/null; then
        rm -f "${jwt_dir}/server.key.tmp"
    else
        # OpenSSL 1.x は genrsa が元から PKCS#1 を出力するため tmp をそのまま使用
        mv "${jwt_dir}/server.key.tmp" "${jwt_dir}/server.key"
    fi
    # -subj の書き方は OS で違う（_jwt_cert_subject_arg）。// を Git Bash 以外に渡すと、発行先が空の証明書ができる
    _issue_jwt_cert "${jwt_dir}/server.key" "${jwt_dir}/server.crt" "$repo_name" \
        || die "証明書の生成に失敗しました。"
    # openssl は、発行先が空でも成功（終了コード 0）を返す。Salesforce が拒否するため、ここで確認する
    _jwt_cert_subject_state "${jwt_dir}/server.crt" \
        || die "生成した証明書の発行先（subject）が空、または読み取れません: ${jwt_dir}/server.crt"

    chmod 600 "${jwt_dir}/server.key" 2>/dev/null || true  # run 不使用: 秘密鍵の権限保護

    log "SUCCESS" "証明書を生成しました。"
    log "INFO"    "  秘密鍵: ${jwt_dir}/server.key"
    log "INFO"    "  証明書: ${jwt_dir}/server.crt"
}

# ------------------------------------------------------------------------------
# JWT 認証情報を取得・テストして GitHub Secret に登録する
# 引数:
#   $1 - org_alias        : Salesforce 組織エイリアス（例: prod, staging, develop）
#   $2 - suffix           : Secret 名のサフィックス（例: PROD, STG, DEV）
#   $3 - label            : 表示用ラベル（例: 本番組織）
#   $4 - key_file         : 秘密鍵ファイルパス
#   $5 - is_sandbox_override: "Y"/"N" で対話をスキップ（省略時は対話で確認）
# 登録する Secrets / Variables:
#   SF_CONSUMER_KEY_<suffix>  （Secret）
#   SF_USERNAME_<suffix>      （Variable）
#   SF_INSTANCE_URL_<suffix>  （Variable）
# ------------------------------------------------------------------------------
register_jwt_secret() {
    local org_alias="$1"
    local suffix="$2"
    local label="$3"
    local key_file="$4"
    local is_sandbox_override="${5:-}"  # 省略時は対話で確認

    log "HEADER" "${label}（SF_*_${suffix}）の設定"

    # 接続 URL（ログイン先）を決定する。種類ではなく、URL で選ぶ（段階と組織の種類は、結びつけない）
    local instance_url="https://login.salesforce.com"
    local tier
    tier=$(org_tier_of_suffix "$suffix")  # VAR=$(cmd) のため run 不使用
    if [[ -n "$is_sandbox_override" ]]; then
        # 自動実行・テスト用: "Y" = test.salesforce.com / "N" = login.salesforce.com
        [[ "$is_sandbox_override" =~ ^[Yy] ]] && instance_url="https://test.salesforce.com"
    else
        org_choose_login_url instance_url "$label" "${tier:-main}" "$suffix"
    fi
    log "INFO" "  接続 URL: ${instance_url}"

    # コンシューマーキーを入力
    local consumer_key
    read_or_quit consumer_key "  コンシューマーキーを入力してください："

    # 接続ユーザー名を入力
    local username
    read_or_quit username "  接続ユーザー名を入力してください（例: admin@example.com）："

    # JWT 接続テスト
    log "INFO" "  JWT 接続テストを実行中..."
    log "INFO" "  [jwt cmd] sf org login jwt --client-id ***masked*** --jwt-key-file ${key_file} --username ${username} --instance-url ${instance_url} --alias ${org_alias}"
    # 成否は sf の終了コードで判定する（sf は npm 版が前提）。一時的なホームフォルダの中で実行する（エイリアスが増えず、
    # 同じユーザーの既存の sf の認証も置き換わらない）。組織の種類の読み取りも、同じ一時的なホームの中で行う（org_jwt_test）
    local jwt_err
    if ! org_jwt_test "$org_alias" "$consumer_key" "$key_file" "$username" "$instance_url"; then  # 条件チェック
        jwt_err="$SF_ORG_JWT_OUT"
        log "ERROR" "  [jwt error] ${jwt_err}"
        log "WARNING" "  JWT 接続テストに失敗しました。以下を確認してください:"
        log "WARNING" "  ・コンシューマーキーが正しいか（コピーミスに注意）"
        log "WARNING" "  ・ユーザー名が正しいか"
        log "WARNING" "  ・プロファイルに接続ユーザーが割り当てられているか"
        log "WARNING" "  ・Connected App 保存後 2〜10 分経過しているか（反映待ち）"
        log "WARNING" "  ・Trailhead Playground / orgfarm-* 系は JWT Bearer Flow 非対応のため使用不可"
        log "WARNING" "  ・Developer Edition 組織では認証反映が遅延・失敗する場合があります"
        # テスト失敗時はスキップして続行するか確認する
        # （DE 組織などローカルで認証できない場合でも GitHub Secrets への登録だけ済ませて
        #   GitHub Actions で動作確認できるようにするため）
        if ask_yn "  接続テストをスキップして GitHub Secrets への登録のみ行いますか？（GitHub Actions で後でテストできます）"; then
            log "WARNING" "  接続テストをスキップします。GitHub Actions で動作を確認してください。"
        else
            die "  JWT 接続テストに失敗しました。設定を見直してから再実行してください。"
        fi
    else
        log "SUCCESS" "  JWT 接続テスト成功。"
    fi

    # 本番組織は main にしか、つなげない（F8）。Secrets を登録する前に確認する。
    #   組織の種類を読み取れなかった場合（接続テストのスキップなど）は、main 以外では、つなげない（確認で、通さない）
    if ! org_guard "${tier:-main}" "$label"; then
        die "${label}（${tier:-main}）に、Salesforce の本番組織、または、種類を判定できない組織は、つなげません（本番組織は main のみです）。"
    fi

    # GitHub Secrets / Variables に登録
    # SF_CONSUMER_KEY は機密情報のため Secret、SF_USERNAME と SF_INSTANCE_URL は Variable（平文で管理）
    printf '%s' "$consumer_key" | run gh secret set "SF_CONSUMER_KEY_${suffix}" -R "$REPO_FULL_NAME" \
        || die "SF_CONSUMER_KEY_${suffix} の登録に失敗しました。"
    run gh variable set      "SF_USERNAME_${suffix}"     --body "$username"     -R "$REPO_FULL_NAME" \
        || die "SF_USERNAME_${suffix} の登録に失敗しました。"
    run gh variable set      "SF_INSTANCE_URL_${suffix}" --body "$instance_url" -R "$REPO_FULL_NAME" \
        || die "SF_INSTANCE_URL_${suffix} の登録に失敗しました。"

    log "SUCCESS" "  SF_CONSUMER_KEY_${suffix}（Secret）/ SF_USERNAME_${suffix}（Variable）/ SF_INSTANCE_URL_${suffix}（Variable）を登録しました。"
    # 組織の情報（ID・名前・種類・確認日時）を保存する（--status の表示用。読み取れていなければ、保存しない）
    org_save "$suffix"
}

# ------------------------------------------------------------------------------
# ensure_sf_tools_branch - 選択した環境に合わせて sf-tools（~/sf-tools）の最新化を確認する
# ------------------------------------------------------------------------------
# 【使い方】
#   ensure_sf_tools_branch main          # 本番環境を選択した場合
#   ensure_sf_tools_branch development   # 検証環境を選択した場合
#
# 【動作】（SF_TOOLS_DIR の Git リポジトリを対象にする）
#   - Git リポジトリでない / HEAD が分離状態 / origin に接続できない → WARNING で確認をスキップして続行
#   - 現在のブランチが目標ブランチと違う → WARNING + ask_yn（N/q は die。ブランチの自動切り替えはしない）
#   - 未コミットの変更または未 push のコミットがある → 更新せず WARNING のみで続行（開発者の作業を守る）
#   - origin より遅れている → 遅れたコミットを表示し ask_yn。Y なら git pull --ff-only を実行し、
#     実行中のスクリプトが書き換わるため、戻り値 2 を返す（呼び出し側は、更新した sf-tools で、実行しなおすこと）。N なら WARNING で続行
#   - 最新ならそのまま続行
# ------------------------------------------------------------------------------
ensure_sf_tools_branch() {
    local target="$1"
    local dir="${SF_TOOLS_DIR:-}"
    local cur dirty ahead behind line

    if [[ -z "$dir" ]] || ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then  # if cmd のため run 不使用
        log "WARNING" "sf-tools が Git リポジトリではないため、最新化の確認をスキップします。"
        return $RET_OK
    fi
    cur=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
    if [[ -z "$cur" ]]; then
        log "WARNING" "sf-tools の HEAD がブランチを指していないため、最新化の確認をスキップします。"
        return $RET_OK
    fi
    if [[ "$cur" != "$target" ]]; then
        log "WARNING" "ローカルの sf-tools は ${cur} ブランチですが、選択した環境は ${target} です。"
        ask_yn "▶ このまま続行しますか？" || die "セットアップを中断しました。"
    fi
    if ! run git -C "$dir" fetch origin "$cur"; then
        log "WARNING" "origin に接続できなかったため、sf-tools の最新化の確認をスキップします。"
        return $RET_OK
    fi
    if ! git -C "$dir" rev-parse --verify --quiet "origin/${cur}" >/dev/null 2>&1; then  # if cmd のため run 不使用
        log "WARNING" "origin に ${cur} ブランチが存在しないため、最新化の確認をスキップします。"
        return $RET_OK
    fi
    dirty=$(git -C "$dir" status --porcelain 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
    ahead=$(git -C "$dir" rev-list --count "origin/${cur}..HEAD" 2>/dev/null || echo 0)  # VAR=$(cmd) のため run 不使用
    behind=$(git -C "$dir" rev-list --count "HEAD..origin/${cur}" 2>/dev/null || echo 0)  # VAR=$(cmd) のため run 不使用
    if [[ "$behind" -eq 0 ]]; then
        log "INFO" "sf-tools（${cur}）は最新です。"
        return $RET_OK
    fi
    if [[ -n "$dirty" || "$ahead" -gt 0 ]]; then
        log "WARNING" "sf-tools（${cur}）は origin より ${behind} コミット遅れていますが、ローカルに未コミットの変更または未 push のコミットがあるため更新しません。"
        return $RET_OK
    fi
    log "WARNING" "sf-tools（${cur}）は origin より ${behind} コミット遅れています。"
    while IFS= read -r line; do
        log "INFO" "  ${line}"
    done < <(git -C "$dir" log --oneline -10 "HEAD..origin/${cur}" 2>/dev/null)  # プロセス置換のため run 不使用
    if ask_yn "▶ sf-tools を更新しますか？"; then
        run git -C "$dir" pull --ff-only origin "$cur" || die "sf-tools の更新に失敗しました。"
        log "SUCCESS" "sf-tools を更新しました。"
        return 2
    fi
    log "WARNING" "sf-tools を更新せずに続行します。"
    return $RET_OK
}

# ------------------------------------------------------------------------------
# delete_existing_ruleset - 同名の既存 Ruleset があれば削除する（再実行の冪等性確保）
# ------------------------------------------------------------------------------
# 【使い方】
#   delete_existing_ruleset "$REPO_FULL_NAME" "protect-main"
#
# 【動作】
#   - Ruleset 一覧から同名の ID を取得する。ID は数字のときだけ有効とみなす
#     （gh api が失敗した場合、エラーの応答本文が標準出力に出るため、数字以外は「確認できなかった」と扱う）
#   - 確認できなかった場合（無料プランの Private リポジトリなど）は WARNING を出して何も削除しない
#   - 削除の成否はそのまま表示する（失敗したのに「削除しました」と出さない）
#   - いずれの場合も呼び出し元は続行する（常に RET_OK を返す）
# ------------------------------------------------------------------------------
delete_existing_ruleset() {
    local repo="$1" name="$2" id
    id=$(gh api "repos/${repo}/rulesets" \
        --jq ".[] | select(.name==\"${name}\") | .id" 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
    if [[ ! "$id" =~ ^[0-9]+$ ]]; then
        # 空 = 同名の Ruleset なし。数字以外 = API のエラー本文など（確認できなかった）
        [[ -n "$id" ]] && log "WARNING" "既存の ${name} を確認できなかったため、削除をスキップします（プランの制限などの可能性があります）。"
        return $RET_OK
    fi
    if run gh api --method DELETE "repos/${repo}/rulesets/${id}"; then
        log "INFO" "既存の ${name} (id: ${id}) を削除しました。"
    else
        log "WARNING" "既存の ${name} (id: ${id}) の削除に失敗しました。"
    fi
    return $RET_OK
}

# ------------------------------------------------------------------------------
# _xml_escape - XML の特殊文字（& < >）をエスケープする（プロファイル名などを XML に埋め込むため）
# ------------------------------------------------------------------------------
_xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

# ------------------------------------------------------------------------------
# generate_eca_metadata - 外部クライアントアプリ（ECA）のメタデータ（ソース形式・5 ファイル）を生成する
# ------------------------------------------------------------------------------
# 【使い方】
#   generate_eca_metadata DIR APP_NAME CONTACT_EMAIL PROFILE_NAME CERT_FILE
#
# 【引数】
#   DIR           : 出力先（DIR/force-app/main/default/ 配下に生成する）
#   APP_NAME      : アプリの API 参照名（英数字と _ のみ）
#   CONTACT_EMAIL : 連絡先メール
#   PROFILE_NAME  : 事前承認するプロファイルの表示名（言語依存。日本語の組織では「システム管理者」）
#   CERT_FILE     : JWT 用の証明書（PEM）。<certificate> には BEGIN/END 行を除いた本文を入れる
#
# 【生成するもの】（JWT Bearer Flow・フルアクセス + refresh_token・管理者が承認したユーザーは事前承認済み）
#   externalClientApps / extlClntAppGlobalOauthSets / extlClntAppOauthSettings /
#   extlClntAppOauthPolicies / extlClntAppPolicies
#   consumerKey は出力項目のため書かない（deploy 後に retrieve して取得する）
# ------------------------------------------------------------------------------
generate_eca_metadata() {
    local dir="$1" app="$2" email="$3" profile="$4" cert_file="$5"
    local base="${dir}/force-app/main/default" cert esc_email esc_profile
    cert=$(grep -v -- '-----' "$cert_file" | tr -d '\r')  # VAR=$(cmd) のため run 不使用。PEM の本文のみ
    esc_email=$(_xml_escape "$email")
    esc_profile=$(_xml_escape "$profile")

    run mkdir -p "${base}/externalClientApps" "${base}/extlClntAppGlobalOauthSets" \
                 "${base}/extlClntAppOauthSettings" "${base}/extlClntAppOauthPolicies" \
                 "${base}/extlClntAppPolicies" || return $RET_NG
    # run 不使用: ファイル生成
    printf '%s\n' '{"packageDirectories":[{"path":"force-app","default":true}],"namespace":"","sourceApiVersion":"64.0"}' \
        > "${dir}/sfdx-project.json"

    # run 不使用: ファイル生成（ヒアドキュメント）
    cat > "${base}/externalClientApps/${app}.eca-meta.xml" << ECAEOF
<?xml version="1.0" encoding="UTF-8"?>
<ExternalClientApplication xmlns="http://soap.sforce.com/2006/04/metadata">
    <contactEmail>${esc_email}</contactEmail>
    <distributionState>Local</distributionState>
    <isProtected>false</isProtected>
    <label>${app}</label>
</ExternalClientApplication>
ECAEOF
    cat > "${base}/extlClntAppGlobalOauthSets/${app}_glbloauth.ecaGlblOauth-meta.xml" << ECAEOF
<?xml version="1.0" encoding="UTF-8"?>
<ExtlClntAppGlobalOauthSettings xmlns="http://soap.sforce.com/2006/04/metadata">
    <callbackUrl>https://login.salesforce.com/services/oauth2/callback</callbackUrl>
    <certificate>${cert}</certificate>
    <externalClientApplication>${app}</externalClientApplication>
    <isClientCredentialsFlowEnabled>false</isClientCredentialsFlowEnabled>
    <isCodeCredFlowEnabled>false</isCodeCredFlowEnabled>
    <isCodeCredPostOnly>false</isCodeCredPostOnly>
    <isConsumerSecretOptional>true</isConsumerSecretOptional>
    <isDeviceFlowEnabled>false</isDeviceFlowEnabled>
    <isIntrospectAllTokens>false</isIntrospectAllTokens>
    <isNamedUserJwtEnabled>false</isNamedUserJwtEnabled>
    <isPkceRequired>true</isPkceRequired>
    <isRefreshTokenRotationEnabled>true</isRefreshTokenRotationEnabled>
    <isSecretRequiredForRefreshToken>false</isSecretRequiredForRefreshToken>
    <isSecretRequiredForTokenExchange>true</isSecretRequiredForTokenExchange>
    <isTokenExchangeEnabled>false</isTokenExchangeEnabled>
    <label>${app}_glbloauth</label>
    <shouldRotateConsumerKey>false</shouldRotateConsumerKey>
    <shouldRotateConsumerSecret>false</shouldRotateConsumerSecret>
</ExtlClntAppGlobalOauthSettings>
ECAEOF
    cat > "${base}/extlClntAppOauthSettings/${app}_oauth.ecaOauth-meta.xml" << ECAEOF
<?xml version="1.0" encoding="UTF-8"?>
<ExtlClntAppOauthSettings xmlns="http://soap.sforce.com/2006/04/metadata">
    <commaSeparatedOauthScopes>Full, RefreshToken</commaSeparatedOauthScopes>
    <externalClientApplication>${app}</externalClientApplication>
    <isFirstPartyAppEnabled>false</isFirstPartyAppEnabled>
    <label>${app}_oauth</label>
</ExtlClntAppOauthSettings>
ECAEOF
    cat > "${base}/extlClntAppOauthPolicies/${app}_oauthPlcy.ecaOauthPlcy-meta.xml" << ECAEOF
<?xml version="1.0" encoding="UTF-8"?>
<ExtlClntAppOauthConfigurablePolicies xmlns="http://soap.sforce.com/2006/04/metadata">
    <commaSeparatedProfile>${esc_profile}</commaSeparatedProfile>
    <externalClientApplication>${app}</externalClientApplication>
    <ipRelaxationPolicyType>Enforce</ipRelaxationPolicyType>
    <isClientCredentialsFlowEnabled>false</isClientCredentialsFlowEnabled>
    <isGuestCodeCredFlowEnabled>false</isGuestCodeCredFlowEnabled>
    <isTokenExchangeFlowEnabled>false</isTokenExchangeFlowEnabled>
    <label>${app}_oauthPlcy</label>
    <permittedUsersPolicyType>AdminApprovedPreAuthorized</permittedUsersPolicyType>
    <refreshTokenPolicyType>SpecificInactivity</refreshTokenPolicyType>
    <refreshTokenValidityPeriod>30</refreshTokenValidityPeriod>
    <refreshTokenValidityUnit>Days</refreshTokenValidityUnit>
    <requiredSessionLevel>STANDARD</requiredSessionLevel>
</ExtlClntAppOauthConfigurablePolicies>
ECAEOF
    cat > "${base}/extlClntAppPolicies/${app}_plcy.ecaPlcy-meta.xml" << ECAEOF
<?xml version="1.0" encoding="UTF-8"?>
<ExtlClntAppConfigurablePolicies xmlns="http://soap.sforce.com/2006/04/metadata">
    <externalClientApplication>${app}</externalClientApplication>
    <isEnabled>true</isEnabled>
    <isOauthPluginEnabled>true</isOauthPluginEnabled>
    <label>${app}_plcy</label>
    <startPage>None</startPage>
</ExtlClntAppConfigurablePolicies>
ECAEOF
    return $RET_OK
}

# ------------------------------------------------------------------------------
# register_jwt_secret_eca - 外部クライアントアプリ（ECA）を自動作成し、JWT 認証情報を GitHub に登録する
# ------------------------------------------------------------------------------
# 【使い方】
#   register_jwt_secret_eca ORG_ALIAS SUFFIX LABEL KEY_FILE CERT_FILE
#
# 【処理フロー】
#   1. 本番 / Sandbox を確認して接続 URL を決める
#   2. sf org login web（ブラウザでログイン。接続ユーザーは管理者権限のユーザー）
#      成否は sf の終了コードで判定する（失敗・時間切れ・ブラウザを閉じた場合は、非 0 になり中断する。一時エイリアスは sf-tools-<suffix>）
#   3. ログインしたユーザー名と、そのプロファイル名（表示名）を取得する
#   4. generate_eca_metadata でメタデータを生成し、sf project deploy でアプリを作成する
#   5. sf project retrieve でコンシューマー鍵を自動取得する（値はログに出さない）
#   6. JWT 接続テスト（反映待ちのため、成功するまでリトライする）
#   7. SF_CONSUMER_KEY_<suffix>（Secret）/ SF_USERNAME_<suffix> / SF_INSTANCE_URL_<suffix>（Variable）を登録
#
# 【備考】
#   ・sf の認証はユーザー名単位で、エイリアスは別名にすぎない。ログイン用の一時エイリアスは
#     sf alias unset で消す（sf org logout は同じユーザー名の全エイリアスの認証を消すため使わない）
#   ・リトライ回数・間隔は環境変数 SF_INIT_JWT_RETRIES（既定 20）/ SF_INIT_JWT_INTERVAL（既定 30 秒）で変更できる
#   ・JWT 接続テスト（sf org login jwt）は、run_isolated_home で、一時的なホームフォルダの中で実行する。
#     ユーザーの sf に、エイリアス（prod 等）が増えず、同じユーザーの既存の認証も、JWT の認証に置き換わらない
# ------------------------------------------------------------------------------
register_jwt_secret_eca() {
    local org_alias="$1" suffix="$2" label="$3" key_file="$4" cert_file="$5"
    # ログイン用の一時エイリアス。ユーザーが運用中のエイリアス（prod 等）と重ならないよう sf-tools- を付ける
    local tmp_alias="sf-tools-${suffix}"
    local eca_name="SF_TOOLS_${REPO_NAME//[^A-Za-z0-9]/_}"
    local instance_url="https://login.salesforce.com"
    local username profile work consumer_key jwt_out jwt_ok=0 i
    local retries="${SF_INIT_JWT_RETRIES:-20}" interval="${SF_INIT_JWT_INTERVAL:-30}"
    local key_xml

    log "HEADER" "${label}（SF_*_${suffix}）の設定（外部クライアントアプリを自動作成）"

    # 1. ログイン先（種類ではなく、URL で選ぶ。段階と組織の種類は、結びつけない: doc/wizard-ux-design.md 4.7）
    local tier
    tier=$(org_tier_of_suffix "$suffix")  # VAR=$(cmd) のため run 不使用
    org_choose_login_url instance_url "$label" "${tier:-main}" "$suffix"
    log "INFO" "  接続 URL: ${instance_url}"

    # 2. ブラウザでログイン
    log "INFO" "  ブラウザが開きます。${label}に、接続ユーザー（管理者権限）でログインしてください。"
    log "WARNING" "  ※ ブラウザでのログインは、約 2 分で時間切れになります。ブラウザが開いたら、すぐに、ログインしてください。"
    # 前回の古い認証が残っていて「ログイン済み」と誤判定しないよう、先に一時エイリアスを外す
    run sf alias unset "$tmp_alias" || true  # 未設定でも続行（意図的エラー無視）
    # 成否は sf の終了コードで判定する（sf は npm 版が前提。check_sf_cli が確認する）。
    # 失敗・時間切れ（約 2 分）・ブラウザを閉じた場合は、終了コードが 0 以外になる
    run sf org login web --instance-url "$instance_url" --alias "$tmp_alias" \
        || die "${label}へのログインに失敗しました。"

    # 3. ユーザー名とプロファイル名（表示名）
    local org_info
    org_info=$(sf org display --target-org "$tmp_alias" --json 2>/dev/null) \
        || die "${label}の接続情報を取得できませんでした。"  # VAR=$(cmd) のため run 不使用（出力の取得。成否は終了コードで判定）
    username=$(json_get "$org_info" result.username)  # VAR=$(cmd) のため run 不使用（値の抽出のみ）
    [[ -n "$username" ]] || die "${label}の接続ユーザー名を取得できませんでした。"
    log "INFO" "  ログインに成功しました。"
    log "INFO" "  接続ユーザー: ${username}"

    # 組織の種類を、組織から読み取る（F3）。Salesforce の本番組織は、main にしか、つなげない（F8）。
    #   外部クライアントアプリを作る（deploy）前に確認する（誤って、本番に作らないため）
    if ! org_read_info "$tmp_alias"; then
        log "WARNING" "  組織の種類を、組織から読み取れませんでした（権限・通信など）。"
    fi
    if ! org_guard "${tier:-main}" "$label"; then
        run sf alias unset "$tmp_alias" || true  # 失敗しても続行（意図的エラー無視）
        die "${label}（${tier:-main}）に、Salesforce の本番組織は、つなげません（本番組織は main のみです）。"
    fi
    local prof_info
    prof_info=$(sf data query --query "SELECT Profile.Name FROM User WHERE Username='${username}'" \
        --target-org "$tmp_alias" --json 2>/dev/null) \
        || die "接続ユーザーのプロファイル名を取得できませんでした。"  # VAR=$(cmd) のため run 不使用（出力の取得。成否は終了コードで判定）
    profile=$(json_get "$prof_info" result.records.0.Profile.Name)  # VAR=$(cmd) のため run 不使用（値の抽出のみ）
    [[ -n "$profile" ]] || die "接続ユーザーのプロファイル名を取得できませんでした。"
    log "INFO" "  プロファイル: ${profile}"

    # 4. メタデータを生成して deploy（アプリ作成）
    work=$(mktemp -d "${TMPDIR:-/tmp}/sf-init-eca.XXXXXX") || die "一時ディレクトリを作成できません。"  # VAR=$(cmd) のため run 不使用
    generate_eca_metadata "$work" "$eca_name" "$username" "$profile" "$cert_file" \
        || { rm -rf "$work"; die "外部クライアントアプリのメタデータを生成できませんでした。"; }
    log "INFO" "  外部クライアントアプリ（${eca_name}）を作成します（メタデータの deploy）..."
    (cd "$work" && run sf project deploy start --source-dir force-app --target-org "$tmp_alias") \
        || { rm -rf "$work"; die "外部クライアントアプリの作成（deploy）に失敗しました。"; }

    # 5. コンシューマー鍵を取得（値はログに出さない）
    (cd "$work" && run sf project retrieve start \
        --metadata "ExtlClntAppGlobalOauthSettings:${eca_name}_glbloauth" --target-org "$tmp_alias") \
        || { rm -rf "$work"; die "コンシューマー鍵の取得（retrieve）に失敗しました。"; }
    key_xml="${work}/force-app/main/default/extlClntAppGlobalOauthSets/${eca_name}_glbloauth.ecaGlblOauth-meta.xml"
    consumer_key=$(sed -n 's:.*<consumerKey>\(.*\)</consumerKey>.*:\1:p' "$key_xml" 2>/dev/null | head -1)  # VAR=$(cmd) のため run 不使用
    rm -rf "$work"
    [[ -n "$consumer_key" ]] || die "コンシューマー鍵を取得できませんでした。"
    log "INFO" "  コンシューマー鍵を取得しました。"

    # 6. JWT 接続テスト（作成直後は反映待ちで失敗することがあるため、成功するまでリトライする）
    log "INFO" "  JWT 接続テストを実行中...（反映待ちのため、成功するまで最大 ${retries} 回リトライします）"
    for ((i = 1; i <= retries; i++)); do
        # run 不使用: VAR=$(cmd) 形式（コンシューマー鍵をコマンドのログに残さない）。成否は sf の終了コードで判定する
        # 一時的なホームフォルダの中で実行する: エイリアスが増えず、同じユーザーの既存の sf の認証も置き換わらない
        if jwt_out=$(run_isolated_home sf org login jwt --client-id "$consumer_key" --jwt-key-file "$key_file" \
            --username "$username" --instance-url "$instance_url" --alias "$org_alias"); then  # 条件チェック
            jwt_ok=1
            break
        fi
        log "INFO" "  Salesforce の反映を待っています（${i} / ${retries} 回目・最大 約 $(( retries * interval / 60 )) 分）。${interval} 秒後に、もう一度、確認します..."
        sleep "$interval"  # run 不使用: 待機
    done
    if [[ $jwt_ok -eq 1 ]]; then
        log "SUCCESS" "  JWT 接続テスト成功。"
    else
        log "ERROR" "  [jwt error] ${jwt_out//$consumer_key/***masked***}"
        log "WARNING" "  JWT 接続テストに成功しませんでした（反映待ち・ユーザーのプロファイル・組織の種類などを確認してください）。"
        if ask_yn "  接続テストをスキップして GitHub Secrets への登録のみ行いますか？（GitHub Actions で後でテストできます）"; then
            log "WARNING" "  接続テストをスキップします。GitHub Actions で動作を確認してください。"
        else
            die "  JWT 接続テストに失敗しました。"
        fi
    fi
    # ログイン用の一時エイリアスを消す（sf org logout は同じユーザー名の全エイリアスの認証を消すため使わない）
    run sf alias unset "$tmp_alias" || true  # 失敗しても続行（意図的エラー無視）

    # 7. GitHub Secrets / Variables に登録
    printf '%s' "$consumer_key" | run gh secret set "SF_CONSUMER_KEY_${suffix}" -R "$REPO_FULL_NAME" \
        || die "SF_CONSUMER_KEY_${suffix} の登録に失敗しました。"
    run gh variable set "SF_USERNAME_${suffix}"     --body "$username"     -R "$REPO_FULL_NAME" \
        || die "SF_USERNAME_${suffix} の登録に失敗しました。"
    run gh variable set "SF_INSTANCE_URL_${suffix}" --body "$instance_url" -R "$REPO_FULL_NAME" \
        || die "SF_INSTANCE_URL_${suffix} の登録に失敗しました。"
    log "SUCCESS" "  SF_CONSUMER_KEY_${suffix}（Secret）/ SF_USERNAME_${suffix}（Variable）/ SF_INSTANCE_URL_${suffix}（Variable）を登録しました。"
    # 組織の情報（ID・名前・種類・確認日時）を保存する（sf-init.sh --status の表示用。読み取れていなければ、保存しない）
    org_save "$suffix"
}
