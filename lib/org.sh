#!/bin/bash
# ==============================================================================
# org.sh - Salesforce 組織の接続情報の共通部品（ログイン先の選択・組織の種類の読み取り・本番のガード）
# ==============================================================================
# 段階（main / staging / develop）と、Salesforce 組織の種類（本番・Sandbox・Developer Edition など）は、
# 基本的に独立している。ただし、**本番組織は、main にしか、つなげない**（F8。doc/wizard-ux-design.md 4.7）。
# phases/init/init-common.sh（sf-init.sh の各 Phase・add_tier.sh・reconnect.sh・status.sh）・phases/init/verify.sh・
# sf-start.sh・sf-update-secret.sh・sf-typecheck.sh・sf-release.sh・sf-deploy.sh が、この部品を source して共有する（common.sh からは source しない）。
#
# 【前提】
#   lib/common.sh を source 済みであること（log / run / die / json_get / read_input / read_or_quit / set_var /
#   run_isolated_home を使う）。
#
# 【定数】
#   SF_ORG_URL_LOGIN = https://login.salesforce.com / SF_ORG_URL_TEST = https://test.salesforce.com
#
# 【提供する関数】
#   org_tier_of_suffix SUFFIX             ... PROD→main / STG→staging / DEV→develop を出力する（それ以外は空行）
#   org_validate_url URL                  ... Salesforce のログイン先として正しい URL か（https かつ salesforce.com / force.com）
#   org_choose_login_url VAR LABEL TIER [SUFFIX]
#                                            ... ログイン先（URL）を、3 択で選ぶ。種類ではなく、URL で決める（F2）
#   org_read_info ALIAS                   ... ログイン済みの組織から、ID・名前・種類を読み取る（ORG_* 変数にセット）
#   org_kind                              ... ORG_* から、production / sandbox / developer / trial / unknown を出力する
#   org_kind_label KIND                   ... 種類の表示名
#   org_guard TIER LABEL                  ... 本番は main のみ（F8）。違反・判定不能（main 以外）は戻り値 2
#   org_local_release_check ALIAS         ... ローカルからのリリースの保護用。本番（または種類を確認できない）組織かを返す（戻り値 0 / 1 / 2）
#   org_parse_info JSON                   ... sf data query の JSON から、ORG_* を取り出す
#   org_jwt_test ALIAS KEY KEYFILE USER URL ... JWT 接続テストと、組織情報の読み取り（一時的なホームの中。従来の接続アプリ用）
#                                            （KEY = コンシューマー鍵 / KEYFILE = 秘密鍵ファイル / URL = ログイン先。出力は SF_ORG_JWT_OUT）
#   org_save SUFFIX                       ... 組織 ID・名前・種類・確認日時を、GitHub の Variables に保存する
#
# 【ORG_* 変数】（org_read_info / org_parse_info / org_jwt_test がセットする。最初に空にしてから読み取る）
#   ORG_ID / ORG_NAME / ORG_IS_SANDBOX(true|false|"") / ORG_EDITION（OrganizationType）/ ORG_TRIAL_EXPIRES（TrialExpirationDate）
# ==============================================================================

SF_ORG_URL_LOGIN="https://login.salesforce.com"
SF_ORG_URL_TEST="https://test.salesforce.com"

# 段階の識別子（Secrets / Variables の接尾辞）から、段階の名前を出す（PROD / STG / DEV 以外は、空行。戻り値は常に 0）
org_tier_of_suffix() {
    case "$1" in
        PROD) echo "main" ;;
        STG)  echo "staging" ;;
        DEV)  echo "develop" ;;
        *)    echo "" ;;
    esac
}

# Salesforce のログイン先として正しい URL か。https で、ホストが salesforce.com または force.com のサブドメイン
#   （login.salesforce.com・xxx.my.salesforce.com など。salesforce.com そのものは不可）。空白を含まないパスは、付いていてもよい
#   戻り値: 0 = 正しい / 1 = 正しくない
org_validate_url() {
    [[ "$1" =~ ^https://[A-Za-z0-9.-]+\.(salesforce\.com|force\.com)(/[^[:space:]]*)?$ ]]
}

# ログイン先（URL）を選ぶ。引数: 結果の変数名 / 表示名（例: メイン組織）/ 段階（main|staging|develop）/ 接尾辞（任意）
#   ・選択肢は、種類ではなく、ログイン先の URL（F2）。3 択: login.salesforce.com / test.salesforce.com / 組織の URL
#   ・Enter は、[2] test.salesforce.com（Sandbox。安全な既定。段階に依存しない: F7）
#   ・環境変数 SF_INIT_LOGIN_URL_<接尾辞>（login / test / URL）が指定されていれば、質問しない（自動実行用。
#     URL が正しくなければ die）。接尾辞を省略したときは、環境変数を見ない
#   ・[3] で入力した URL は、正しい形式になるまで再入力（q で中断）。URL の末尾の / は除く
#   ・選んだ URL を INFO で表示し、VAR に入れる。q / EOF は die
org_choose_login_url() {
    # 結果は、最後に set_var で、$1 の名前の変数に代入する（nameref は Bash 4.3 以降のため使わない）
    local _sfo_name="$1" _sfo_out=""
    local label="$2" tier="${3:-main}" suffix="${4:-}"
    local envname preset="" hint1 ans url

    if [[ -n "$suffix" ]]; then
        envname="SF_INIT_LOGIN_URL_${suffix}"
        preset="${!envname:-}"
    fi
    if [[ -n "$preset" ]]; then
        case "$preset" in
            login) _sfo_out="$SF_ORG_URL_LOGIN" ;;
            test)  _sfo_out="$SF_ORG_URL_TEST" ;;
            *)
                org_validate_url "$preset" || die "${envname} の値が、Salesforce のログイン先として正しくありません: ${preset}"
                _sfo_out="${preset%/}" ;;
        esac
        log "INFO" "  ${label}のログイン先: ${_sfo_out}（環境変数 ${envname} の指定）"
        set_var "$_sfo_name" "$_sfo_out"
        return 0
    fi

    hint1="本番・Developer Edition・Trial など"
    [[ "$tier" != "main" ]] && hint1="Developer Edition・Trial など（※ Salesforce の本番は、main のみ）"

    echo "" >&2
    echo "  ▶ ${label}（${tier}）には、どこからログインしますか？" >&2
    echo "      [1] ${SF_ORG_URL_LOGIN}   ${hint1}" >&2
    echo "      [2] ${SF_ORG_URL_TEST}    Sandbox   ← 安全なおすすめ（本番に影響しません）" >&2
    echo "      [3] 組織の URL を入力する   My Domain（例: https://会社名.my.salesforce.com）" >&2
    while true; do
        read_input ans "  ▶ 番号を選んでください [Enter=2 / 1 / 3 / q=中断]: " || die "中断しました。"  # EOF → 中断
        case "$ans" in
            ""|2) _sfo_out="$SF_ORG_URL_TEST"; break ;;
            1)    _sfo_out="$SF_ORG_URL_LOGIN"; break ;;
            3)
                while true; do
                    read_or_quit url "  組織の URL（q で中断）: "
                    url="${url%/}"
                    org_validate_url "$url" && break
                    log "WARNING" "「${url}」は、Salesforce のログイン先の形式ではありません（https:// で始まり、salesforce.com または force.com のドメインです）。"
                done
                _sfo_out="$url"; break ;;
            q|Q)  die "中断しました。" ;;
            *)    echo "  1・2・3 のいずれかを入力してください（Enter は 2）。" >&2 ;;
        esac
    done
    log "INFO" "  ${label}のログイン先: ${_sfo_out}"
    set_var "$_sfo_name" "$_sfo_out"
}

# sf data query の JSON（文字列）から、組織の ID・名前・種類を読み取る。引数: JSON
#   戻り値: 0=読み取れた / 1=読み取れなかった（JSON として読めない・status があって 0 ではない・ID や IsSandbox がない。推測しない）
#   ORG_* は、最初に空にする（status が 0 でないときは、空のまま）
#   JSON は json_get（lib/common.sh。Node の標準機能のみ）で読む。パスで項目を指定する（result.records.0.Id など）
org_parse_info() {
    local out="$1" vals
    local -a v=()
    ORG_ID=""; ORG_NAME=""; ORG_IS_SANDBOX=""; ORG_EDITION=""; ORG_TRIAL_EXPIRES=""
    # JSON として読み取れなければ、失敗（6 項目を、1 回で取る。終了コードを確認してから、代入する）
    vals=$(json_get "$out" status result.records.0.Id result.records.0.Name result.records.0.IsSandbox \
                           result.records.0.OrganizationType result.records.0.TrialExpirationDate) || return 1  # VAR=$(cmd) のため run 不使用
    # 1 行を 1 要素にする（mapfile は Bash 4 以降のため使わない。空行も、1 要素として残す）
    local _line
    while IFS= read -r _line; do v+=("$_line"); done <<< "$vals"
    # status が、あって、0 以外なら、失敗として扱う（項目は、空のまま）
    if [[ -n "${v[0]:-}" && "${v[0]}" != "0" ]]; then return 1; fi
    ORG_ID="${v[1]:-}"
    ORG_NAME="${v[2]:-}"
    ORG_IS_SANDBOX="${v[3]:-}"
    ORG_EDITION="${v[4]:-}"
    ORG_TRIAL_EXPIRES="${v[5]:-}"
    [[ -n "$ORG_ID" && -n "$ORG_IS_SANDBOX" ]]
}

# ログイン済みの組織から、ID・名前・種類を読み取る。引数: エイリアス（またはユーザー名）
#   sf data query（Organization を 1 件）を実行し、org_parse_info で ORG_* にセットする
#   戻り値: 0=読み取れた / 1=読み取れなかった（権限不足・通信の失敗など。推測しない）
org_read_info() {
    local out
    ORG_ID=""; ORG_NAME=""; ORG_IS_SANDBOX=""; ORG_EDITION=""; ORG_TRIAL_EXPIRES=""
    out=$(sf data query \
        --query "SELECT Id, Name, IsSandbox, OrganizationType, TrialExpirationDate FROM Organization LIMIT 1" \
        --target-org "$1" --json 2>/dev/null) || return 1  # VAR=$(cmd) のため run 不使用（出力の取得。成否は終了コードで判定）
    org_parse_info "$out"
}

# JWT 接続テストと、組織情報の読み取りを、同じ一時的なホームフォルダの中で行う（従来の接続アプリ用）
#   一時的なホームの中で実行する: エイリアスが増えず、同じユーザーの既存の sf の認証も置き換わらない（run_isolated_home）。
#   認証は、一時的なホームと一緒に消えるため、組織情報の読み取りも、その中で行う。
#   引数: エイリアス コンシューマー鍵 秘密鍵ファイル ユーザー名 ログイン入口（--instance-url）
#   戻り値: sf org login jwt の終了コード（組織情報の読み取りの成否は、戻り値に含めない）。
#           ログインの出力（標準出力と標準エラー。コンシューマー鍵を含みうる）は SF_ORG_JWT_OUT。
#           成功したときは、ORG_*（org_parse_info）も、セットする（読み取れなければ、空のまま）
org_jwt_test() {
    local out rc marker="---SF_ORG_INFO---"
    SF_ORG_JWT_OUT=""
    ORG_ID=""; ORG_NAME=""; ORG_IS_SANDBOX=""; ORG_EDITION=""; ORG_TRIAL_EXPIRES=""
    out=$(run_isolated_home bash -c '
        sf org login jwt --client-id "$1" --jwt-key-file "$2" --username "$3" --instance-url "$4" --alias "$5" || exit $?
        echo "---SF_ORG_INFO---"
        sf data query --query "SELECT Id, Name, IsSandbox, OrganizationType, TrialExpirationDate FROM Organization LIMIT 1" --target-org "$5" --json 2>/dev/null
        exit 0
    ' _ "$2" "$3" "$4" "$5" "$1")  # VAR=$(cmd) のため run 不使用（出力と終了コードを、ここで扱う）
    rc=$?
    SF_ORG_JWT_OUT="${out%%"$marker"*}"
    if [[ $rc -eq 0 && "$out" == *"$marker"* ]]; then
        org_parse_info "${out#*"$marker"}" || true
    fi
    return $rc
}

# 組織の種類。IsSandbox / OrganizationType / TrialExpirationDate から判定し、標準出力に出す（org_read_info のあとに呼ぶ）
#   上から順に判定する:
#   unknown    : ORG_ID または ORG_IS_SANDBOX が空（読み取れていない。推測しない）
#   sandbox    : IsSandbox が true
#   developer  : OrganizationType に「Developer」を含む（Developer Edition）
#   trial      : TrialExpirationDate がある
#   unknown    : OrganizationType が空
#   production : 上のどれにも当たらない（Sandbox ではなく、Developer Edition でも Trial でもない）
org_kind() {
    if [[ -z "${ORG_ID:-}" || -z "${ORG_IS_SANDBOX:-}" ]]; then echo "unknown"; return 0; fi
    if [[ "$ORG_IS_SANDBOX" == "true" ]]; then echo "sandbox"; return 0; fi
    if [[ "${ORG_EDITION:-}" == *"Developer"* ]]; then echo "developer"; return 0; fi
    if [[ -n "${ORG_TRIAL_EXPIRES:-}" ]]; then echo "trial"; return 0; fi
    if [[ -z "${ORG_EDITION:-}" ]]; then echo "unknown"; return 0; fi
    echo "production"
}

# ローカルからのリリースの保護用: 組織が本番でないことを確かめる。引数: エイリアス
#   エイリアスの名前（予約名）だけでは、別の名前を付けた本番組織を止められないため、組織そのものの種類を調べる
#   （org_read_info で読み取り、org_kind で判定する。推測しない）
#   戻り値: 0=本番ではない（sandbox / developer / trial） / 1=本番 / 2=確認できない（読み取れない・種類を判定できない）
org_local_release_check() {
    org_read_info "$1" || return 2
    case "$(org_kind)" in
        production)                 return 1 ;;
        sandbox|developer|trial)    return 0 ;;
        *)                          return 2 ;;
    esac
}

# 種類の表示名
org_kind_label() {
    case "$1" in
        production) echo "本番" ;;
        sandbox)    echo "Sandbox" ;;
        developer)  echo "Developer Edition" ;;
        trial)      echo "Trial" ;;
        *)          echo "種類を判定できません" ;;
    esac
}

# 本番は main のみ（F8）。引数: 段階（main|staging|develop）/ 表示名
#   ログインした組織（名前・種類・組織 ID）を INFO で表示してから、判定する（ORG_* を使う。確認の質問はしない）
#   戻り値: 0=接続してよい（判定不能でも、main なら WARNING を出して 0）
#           2=接続できない（本番、または判定不能の組織を、main 以外に接続しようとした。ERROR を表示する）
org_guard() {
    local tier="$1" label="$2" kind
    kind=$(org_kind)
    log "INFO" "  ログインした組織: ${ORG_NAME:-（名前を取得できません）}（$(org_kind_label "$kind")${ORG_ID:+ / 組織 ID ${ORG_ID}}）"
    case "$kind" in
        production)
            if [[ "$tier" != "main" ]]; then
                log "ERROR" "  Salesforce の本番組織は、main にしか、つなげません（${label} は ${tier} です）。"
                return 2
            fi
            ;;
        unknown)
            # 判定できない組織は、main 以外には、つなげない（本番かどうか、確かめられないため。確認で、通さない）
            if [[ "$tier" != "main" ]]; then
                log "ERROR" "  組織の種類を判定できませんでした。Salesforce の本番組織は、main にしか、つなげません（${label} は ${tier} です）。"
                return 2
            fi
            log "WARNING" "  組織の種類を判定できませんでした（main のため、このまま続行します）。"
            ;;
    esac
    return 0
}

# 組織の情報を、GitHub の Variables に保存する（--status の表示用）。引数: 接尾辞（PROD|STG|DEV）
#   保存する Variables: SF_ORG_ID_<接尾辞> / SF_ORG_NAME_<接尾辞> / SF_ORG_KIND_<接尾辞>（org_kind）/ SF_ORG_CHECKED_<接尾辞>（日時）
#   REPO_FULL_NAME と、org_read_info の結果（ORG_ID）が要る。どちらかが空なら、何もしない（戻り値 0）
#   保存に失敗した項目は、WARNING を出して、続ける（die しない）
org_save() {
    local suffix="$1" kind now
    [[ -n "${REPO_FULL_NAME:-}" && -n "${ORG_ID:-}" ]] || return 0
    kind=$(org_kind)
    now=$(date '+%Y-%m-%d %H:%M')  # VAR=$(cmd) のため run 不使用
    run gh variable set "SF_ORG_ID_${suffix}"      --body "$ORG_ID"        -R "$REPO_FULL_NAME" || log "WARNING" "  SF_ORG_ID_${suffix} を保存できませんでした。"
    run gh variable set "SF_ORG_NAME_${suffix}"    --body "${ORG_NAME:-}"  -R "$REPO_FULL_NAME" || log "WARNING" "  SF_ORG_NAME_${suffix} を保存できませんでした。"
    run gh variable set "SF_ORG_KIND_${suffix}"    --body "$kind"          -R "$REPO_FULL_NAME" || log "WARNING" "  SF_ORG_KIND_${suffix} を保存できませんでした。"
    run gh variable set "SF_ORG_CHECKED_${suffix}" --body "$now"           -R "$REPO_FULL_NAME" || log "WARNING" "  SF_ORG_CHECKED_${suffix} を保存できませんでした。"
}
