#!/bin/bash
# ==============================================================================
# sf-update-secret.sh - GitHub Secrets の JWT 認証情報を更新する
# ==============================================================================
# GitHub Actions の JWT 認証に使う GitHub Secrets / Variables を、対話形式で更新する（管理者向け）。
# 対象のリポジトリは、git remote（origin）から決める。
#
# 【使い方】
#   bash ~/sf-tools/bin/sf-update-secret.sh     # force-* ディレクトリで実行する
#
# 【オプション】
#   -v, --verbose : コマンドの応答（出力）をコンソールにも表示する
#   -h, --help    : このヘルプを表示して終了する（第 1 引数に指定したときのみ）
#   ※ そのほかの引数は、「不明なオプションです」と表示して中断する
#
# 【処理の流れ】
#   1. sf・gh・git・openssl のどれかが見つからなければ、中断する
#   2. 管理者向けの警告を表示し、続行の確認（Y/N）を取る。N・q なら中断する（GitHub Actions 上では、表示・確認しない）
#   3. git remote get-url origin の URL から「オーナー/リポジトリ名」を取り出す（取得できなければ、中断する）
#   4. gh の認証ユーザーが、リポジトリのオーナーと一致しなければ、中断する（check_gh_owner）
#      （オーナーが組織で、認証ユーザーがその組織の有効な管理者（admin）なら、続行する。gh から認証ユーザーを取得できないときは、確認しない）
#   5. sf の確認: sf --version の終了コードが 0 以外なら、案内を表示して中断する（check_sf_cli --cache）
#   6. 更新する項目をメニューで選ぶ（1〜4 / q）
#      1) 秘密鍵: 秘密鍵ファイルのパスを入力し、確認（Y/N）のあと、SF_PRIVATE_KEY を登録する（接続テストは行わない）
#      2) コンシューマーキー: 組織を選び、コンシューマーキーを入力し、接続ユーザー名（SF_USERNAME_<組織> があれば、
#         それを使うかを確認）・ログイン先を決めて、接続テストに成功したら、SF_CONSUMER_KEY_<組織> を登録する
#      3) ユーザー名: 組織を選び、コンシューマーキー（接続テスト用。登録しない）と新しい接続ユーザー名を入力し、
#         ログイン先を決めて、接続テストに成功したら、SF_USERNAME_<組織> を登録する
#      4) すべて: 確認（Y/N）で Y なら、まず SF_PRIVATE_KEY を登録する（接続テストより前。N なら登録しない）。続けて、組織ごとに、
#         コンシューマーキー・接続ユーザー名を入力し、ログイン先を決めて、接続テストに成功したら、
#         SF_CONSUMER_KEY_<組織>・SF_USERNAME_<組織>・SF_INSTANCE_URL_<組織> を登録する
#   7. 「JWT Secrets の更新が完了しました。」を表示して終了する（手順 6 の確認で N と答えて、登録しなかったときも表示する）
#
# 【前提条件】
#   - force-* ディレクトリ（フォルダ名が force- で始まる）で実行すること。それ以外では lib/common.sh が終了する（終了コード 1）
#   - origin が GitHub のリポジトリであること。gh で、そのリポジトリの Secrets / Variables を更新できる権限があること
#   - Salesforce CLI（sf）は npm 版であること。手順 5 の確認は、成功したら 24 時間は省略する（GitHub Actions 上では、確認しない）
#
# 【補足】
#   - 組織の選択肢: ./sf-tools/config/branches.txt の有効な行数（コメント行・空行を除く。ファイルが無ければ 1）で決まる
#       1 行: PROD（main の組織）/ 2 行: + STG（ステージング組織）/ 3 行以上: + DEV（開発組織）
#   - 秘密鍵ファイル: メニュー 2〜4 は ~/.sf-jwt/<リポジトリ名>/server.key があれば、それを使う（無ければ、パスを入力する）。
#     メニュー 1 は、常にパスを入力する。先頭の ~ はホームフォルダに展開する。ファイルが無ければ、中断する
#   - SF_PRIVATE_KEY には、秘密鍵ファイルから CR を除き、1 行の Base64 にした値を登録する
#   - ログイン先（接続テストと SF_INSTANCE_URL_<組織> に使う URL）: https://login.salesforce.com・
#     https://test.salesforce.com（Enter の既定）・組織の URL（My Domain）の 3 択。環境変数 SF_INIT_LOGIN_URL_<組織>
#     （login / test / URL）があれば、質問しない。メニュー 2・3 では、選んだ URL を接続テストにだけ使い、登録しない
#   - 接続テスト: sf org login jwt と、組織の情報（Organization）の読み取りを、一時的なホームフォルダの中で実行する
#     （run_isolated_home）。ユーザーの sf に、エイリアスは増えず、同じユーザーの既存の認証も置き換わらない。
#     sf org login jwt が失敗したら、中断する（それより前に登録した値は、そのまま残る）。組織の情報を読み取れなかったときは、
#     中断せず、種類を判定できない組織として、下の本番組織のガードで扱う
#   - 本番組織のガード: 接続テストのあと、STG・DEV に、本番組織、または種類を判定できない組織をつなごうとしたら、
#     登録する前に中断する（PROD で種類を判定できないときは、WARNING を表示して続行する）
#   - 接続テストで組織の ID を読み取れたら、GitHub Variables の SF_ORG_ID_<組織>・SF_ORG_NAME_<組織>・
#     SF_ORG_KIND_<組織>・SF_ORG_CHECKED_<組織> も保存する（SF_CONSUMER_KEY などの登録より前。失敗しても WARNING で続行）
#   - 更新する GitHub Secrets（機密）: SF_PRIVATE_KEY（全組織共通）・SF_CONSUMER_KEY_PROD / _STG / _DEV（組織別）
#     更新する GitHub Variables（平文）: SF_USERNAME_PROD / _STG / _DEV・SF_INSTANCE_URL_PROD / _STG / _DEV（メニュー 4 のみ）・
#     SF_ORG_ID / NAME / KIND / CHECKED_<組織>（上記）
#   - 登録（gh secret set / gh variable set）に失敗したら、中断する
#   - 入力中に q を押すと、中断する
#   - ログ: ./sf-tools/logs/sf-update-secret.log（実行のたびに作り直す）
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. common.sh 用の事前設定
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME=$(basename "$0" .sh)
readonly LOG_FILE="./sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"

# ------------------------------------------------------------------------------
# 2. 共通ライブラリの読み込み
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="${SCRIPT_DIR}/../lib/common.sh"

if [[ ! -f "$COMMON_LIB" ]]; then
    echo "[FATAL ERROR] Library not found: $COMMON_LIB" >&2
    exit 1
fi
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}"
    exit 0
fi
source "$COMMON_LIB"
reject_unknown_args "$@"   # -v / --verbose 以外の引数は、不明なオプションとして中断する
source "${SCRIPT_DIR}/../lib/org.sh"   # ログイン先の選択（種類ではなく URL）・本番は main のみの確認

# ------------------------------------------------------------------------------
# 3. 必須コマンドのチェック
# ------------------------------------------------------------------------------
command -v sf      >/dev/null 2>&1 || die "コマンドが見つかりません: sf"       # 存在確認のため run 不使用
command -v gh      >/dev/null 2>&1 || die "コマンドが見つかりません: gh"       # 存在確認のため run 不使用
command -v git     >/dev/null 2>&1 || die "コマンドが見つかりません: git"      # 存在確認のため run 不使用
command -v openssl >/dev/null 2>&1 || die "コマンドが見つかりません: openssl"  # 存在確認のため run 不使用

# ------------------------------------------------------------------------------
# 4. force-* ディレクトリかチェック + 管理者向け警告
#    ※ force-* 以外での実行は、lib/common.sh が source の時点で終了させる。下の check_force_dir の戻り値は、使っていない
# ------------------------------------------------------------------------------
check_force_dir
if [[ "${GITHUB_ACTIONS:-false}" != "true" ]]; then
    print_admin_warning --standard "GitHub Secrets を更新します。" "誤った値を設定すると CI/CD が停止します。"
    ask_yn "続行しますか？" || die "中断しました。"
fi

# ------------------------------------------------------------------------------
# 5. git remote からリポジトリ名を取得
# ------------------------------------------------------------------------------
# 以下の REMOTE_URL・REPO_FULL_NAME・REPO_NAME は、VAR=$(cmd) のため run 不使用
REMOTE_URL=$(git remote get-url origin 2>/dev/null) \
    || die "git remote（origin）の URL を取得できませんでした。"

# GitHub の URL から「owner repo」を取り出す（parse_github_remote。GitHub 以外の URL・形が違う URL は、ここで中断する。
# URL に認証情報が入っていることがあるため、メッセージには URL を出さない）
_remote_pair=$(parse_github_remote "$REMOTE_URL") \
    || die "origin の URL から、リポジトリ名を取得できませんでした（GitHub のリポジトリではない、または形式が違います）。"
REPO_FULL_NAME="${_remote_pair%% *}/${_remote_pair#* }"
REPO_NAME="${_remote_pair#* }"

JWT_DIR="$HOME/.sf-jwt/${REPO_NAME}"

check_gh_owner "${REPO_FULL_NAME%%/*}"

log "HEADER" "GitHub Secrets（JWT 認証情報）を更新します (${SCRIPT_NAME}.sh)"
log "INFO" "リポジトリ: ${REPO_FULL_NAME}"

# sf が終了コードを正しく返すか確認する（npm 版が前提。異常なら中断する）。成功は 24 時間は確認を省略する
check_sf_cli --cache

# ------------------------------------------------------------------------------
# 共通: JWT 接続テスト関数
# 引数: $1=org_alias $2=suffix $3=label $4=consumer_key $5=username
#       $6=instance_url $7=key_file
# ------------------------------------------------------------------------------
_test_jwt_login() {
    local org_alias="$1" suffix="$2" label="$3"
    local consumer_key="$4" username="$5" instance_url="$6" key_file="$7"

    log "INFO" "JWT 接続テスト中: ${label}..."
    log "INFO" "  sf org login jwt --client-id *** --jwt-key-file ${key_file} --username ${username} --instance-url ${instance_url} --alias ${org_alias}"

    # 出力（stderr 含む）をキャプチャしてログに残し、成否は sf の終了コードで判定する（sf は npm 版が前提）
    # 一時的なホームフォルダの中で実行する: エイリアスが増えず、同じユーザーの既存の sf の認証も置き換わらない。
    # 組織の種類の読み取りも、同じ一時的なホームの中で行う（org_jwt_test）
    local jwt_out
    if ! org_jwt_test "$org_alias" "$consumer_key" "$key_file" "$username" "$instance_url"; then  # 条件チェック
        jwt_out="$SF_ORG_JWT_OUT"
        log "ERROR" "  ${jwt_out//$consumer_key/***masked***}"
        die "JWT 接続テストに失敗しました（${label}）。"
    fi
    jwt_out="$SF_ORG_JWT_OUT"

    log "INFO" "  ${jwt_out//$consumer_key/***masked***}"  # 成功時の出力にも、コンシューマー鍵が入りうるため、伏せ字にする
    log "SUCCESS" "JWT 接続テスト成功: ${label}"

    # 本番組織は main にしか、つなげない（F8）。Secrets を更新する前に確認する（判定できない組織も、main 以外には、つなげない）
    local _t
    _t=$(org_tier_of_suffix "$suffix")  # VAR=$(cmd) のため run 不使用
    org_guard "${_t:-main}" "$label" \
        || die "${label}（${_t:-main}）に、Salesforce の本番組織、または、種類を判定できない組織は、つなげません（本番組織は main のみです）。"
    # 組織の情報（ID・名前・種類・確認日時）を保存する（--status の表示用。読み取れていなければ、保存しない）
    org_save "$suffix"
}

# ------------------------------------------------------------------------------
# 共通: 組織選択プロンプト → suffix・label・エイリアスを、指定した名前の変数に返す（set_var）
# ------------------------------------------------------------------------------
_select_org() {
    local _so_suffix="$1" _so_label="$2" _so_alias="$3"

    # branches.txt からブランチ数を取得（なければ 1 固定）
    local branch_count=1
    local branch_count_file="./sf-tools/config/branches.txt"
    if [[ -f "$branch_count_file" ]]; then
        branch_count=$(grep -v '^[[:space:]]*#' "$branch_count_file" \
            | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')  # VAR=$(cmd) のため run 不使用
    fi
    [[ $branch_count -gt 3 ]] && branch_count=3

    # ブランチ数に応じたメニュー表示
    log "INFO" "対象組織を選択してください:"
    log "INFO" "  1) main の組織（PROD）"
    [[ $branch_count -ge 2 ]] && log "INFO" "  2) ステージング組織（STG）"
    [[ $branch_count -ge 3 ]] && log "INFO" "  3) 開発組織（DEV）"

    # 有効キーとプロンプトをブランチ数に合わせて動的構築
    local valid="1"
    [[ $branch_count -ge 2 ]] && valid="${valid}2"
    [[ $branch_count -ge 3 ]] && valid="${valid}3"
    local prompt="  選択してください [1/q]: "
    [[ $branch_count -ge 2 ]] && prompt="  選択してください [1-${branch_count}/q]: "

    local key
    read_key key "$prompt" "[${valid}Qq]"
    case "$key" in
        1) set_var "$_so_suffix" "PROD"; set_var "$_so_label" "main の組織";     set_var "$_so_alias" "prod"    ;;
        2) set_var "$_so_suffix" "STG";  set_var "$_so_label" "ステージング組織"; set_var "$_so_alias" "staging" ;;
        3) set_var "$_so_suffix" "DEV";  set_var "$_so_label" "開発組織";         set_var "$_so_alias" "develop" ;;
        q|Q) die "中断しました。" ;;
    esac
}

# ------------------------------------------------------------------------------
# 更新処理: 秘密鍵（SF_PRIVATE_KEY）
# ------------------------------------------------------------------------------
_update_private_key() {
    log "HEADER" "秘密鍵（SF_PRIVATE_KEY）を更新します"

    local key_file
    read_or_quit key_file "  秘密鍵ファイルのパスを入力してください（例: ~/.sf-jwt/${REPO_NAME}/server.key）："
    # ~ を展開
    key_file="${key_file/#\~/$HOME}"
    [[ -f "$key_file" ]] || die "ファイルが存在しません: ${key_file}"

    ask_yn "  SF_PRIVATE_KEY を更新してよいですか？" || { log "INFO" "スキップしました。"; return; }

    # run 不使用: 秘密鍵の内容をログに記録しないため直接実行
    # tr -d '\r': Windows(Git Bash)環境で生成された PEM の CR を除去してから base64 エンコード
    tr -d '\r' < "$key_file" | base64_oneline | gh secret set "SF_PRIVATE_KEY" -R "$REPO_FULL_NAME" \
        || die "SF_PRIVATE_KEY の更新に失敗しました。"
    log "SUCCESS" "SF_PRIVATE_KEY を更新しました。"
}

# ------------------------------------------------------------------------------
# 更新処理: コンシューマーキー（SF_CONSUMER_KEY_xxx）
# ------------------------------------------------------------------------------
_update_consumer_key() {
    log "HEADER" "コンシューマーキー（SF_CONSUMER_KEY_xxx）を更新します"

    local suffix label org_alias
    _select_org suffix label org_alias

    # 秘密鍵ファイルの確認（接続テスト用）
    local key_file="${JWT_DIR}/server.key"
    if [[ ! -f "$key_file" ]]; then
        read_or_quit key_file "  秘密鍵ファイルのパスを入力してください："
        key_file="${key_file/#\~/$HOME}"
        [[ -f "$key_file" ]] || die "ファイルが存在しません: ${key_file}"
    fi

    local consumer_key
    read_or_quit consumer_key "  ${label}のコンシューマーキーを入力してください："

    # SF_USERNAME_xxx は GitHub Variables に保存されているため gh variable get で取得可能
    local username instance_url
    # VAR=$(cmd) 形式のため run 不使用
    username=$(gh variable get "SF_USERNAME_${suffix}" -R "$REPO_FULL_NAME" 2>/dev/null || true)
    if [[ -n "$username" ]]; then
        log "INFO" "  現在の接続ユーザー名: ${username}"
        ask_yn "  このユーザー名で接続テストを実行しますか？" \
            || read_or_quit username "  ${label}の接続ユーザー名を入力してください（接続テスト用）："
    else
        read_or_quit username "  ${label}の接続ユーザー名を入力してください（接続テスト用）："
    fi

    # 接続 URL（ログイン先）: 種類ではなく、URL で選ぶ。段階と組織の種類は、結びつけない（PROD も、選択する）
    local _tier
    _tier=$(org_tier_of_suffix "$suffix")  # VAR=$(cmd) のため run 不使用
    org_choose_login_url instance_url "$label" "${_tier:-main}" "$suffix"

    _test_jwt_login "$org_alias" "$suffix" "$label" "$consumer_key" "$username" "$instance_url" "$key_file"

    printf '%s' "$consumer_key" | run gh secret set "SF_CONSUMER_KEY_${suffix}" -R "$REPO_FULL_NAME" \
        || die "SF_CONSUMER_KEY_${suffix} の更新に失敗しました。"
    log "SUCCESS" "SF_CONSUMER_KEY_${suffix} を更新しました。"
}

# ------------------------------------------------------------------------------
# 更新処理: ユーザー名（SF_USERNAME_xxx）
# ------------------------------------------------------------------------------
_update_username() {
    log "HEADER" "ユーザー名（SF_USERNAME_xxx）を更新します"

    local suffix label org_alias
    _select_org suffix label org_alias

    local key_file="${JWT_DIR}/server.key"
    if [[ ! -f "$key_file" ]]; then
        read_or_quit key_file "  秘密鍵ファイルのパスを入力してください："
        key_file="${key_file/#\~/$HOME}"
        [[ -f "$key_file" ]] || die "ファイルが存在しません: ${key_file}"
    fi

    local consumer_key username instance_url

    # 現在のユーザー名を GitHub Variables から取得して表示
    local current_username
    current_username=$(gh variable get "SF_USERNAME_${suffix}" -R "$REPO_FULL_NAME" 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
    [[ -n "$current_username" ]] && log "INFO" "  現在の接続ユーザー名: ${current_username}"

    read_or_quit consumer_key  "  ${label}のコンシューマーキーを入力してください（接続テスト用）："
    read_or_quit username      "  ${label}の新しい接続ユーザー名を入力してください："

    # 接続 URL（ログイン先）: 種類ではなく、URL で選ぶ。段階と組織の種類は、結びつけない（PROD も、選択する）
    local _tier
    _tier=$(org_tier_of_suffix "$suffix")  # VAR=$(cmd) のため run 不使用
    org_choose_login_url instance_url "$label" "${_tier:-main}" "$suffix"

    _test_jwt_login "$org_alias" "$suffix" "$label" "$consumer_key" "$username" "$instance_url" "$key_file"

    run gh variable set "SF_USERNAME_${suffix}" --body "$username" -R "$REPO_FULL_NAME" \
        || die "SF_USERNAME_${suffix} の更新に失敗しました。"
    log "SUCCESS" "SF_USERNAME_${suffix} を更新しました。"
}

# ------------------------------------------------------------------------------
# 更新処理: すべて更新
# ------------------------------------------------------------------------------
_update_all() {
    log "HEADER" "すべての JWT Secrets を更新します"

    # 秘密鍵
    local key_file="${JWT_DIR}/server.key"
    if [[ ! -f "$key_file" ]]; then
        read_or_quit key_file "  秘密鍵ファイルのパスを入力してください："
        key_file="${key_file/#\~/$HOME}"
        [[ -f "$key_file" ]] || die "ファイルが存在しません: ${key_file}"
    fi
    log "INFO" "  秘密鍵: ${key_file}"

    ask_yn "  SF_PRIVATE_KEY を更新しますか？" && {
        # run 不使用: 秘密鍵の内容をログに記録しないため直接実行
        # tr -d '\r': Windows(Git Bash)環境で生成された PEM の CR を除去してから base64 エンコード
        tr -d '\r' < "$key_file" | base64_oneline | gh secret set "SF_PRIVATE_KEY" -R "$REPO_FULL_NAME" \
            || die "SF_PRIVATE_KEY の更新に失敗しました。"
        log "SUCCESS" "  SF_PRIVATE_KEY を更新しました。"
    }

    # 組織ごとに更新
    local suffixes=("PROD") aliases=("prod") labels=("main の組織")
    local branch_count_file="./sf-tools/config/branches.txt"
    if [[ -f "$branch_count_file" ]]; then
        # コメント行・空行を除いた有効行数でブランチ数を判定する
        local bc; bc=$(grep -v '^[[:space:]]*#' "$branch_count_file" | grep -v '^[[:space:]]*$' | wc -l | tr -d ' ')  # VAR=$(cmd) のため run 不使用
        [[ $bc -ge 2 ]] && { suffixes+=("STG");  aliases+=("staging"); labels+=("ステージング組織"); }
        [[ $bc -ge 3 ]] && { suffixes+=("DEV");  aliases+=("develop"); labels+=("開発組織"); }
    fi

    local i
    for i in "${!suffixes[@]}"; do
        local suffix="${suffixes[$i]}" org_alias="${aliases[$i]}" label="${labels[$i]}"
        log "HEADER" "  ${label}（${suffix}）の設定"

        local consumer_key username instance_url
        read_or_quit consumer_key  "    コンシューマーキーを入力してください："
        read_or_quit username      "    接続ユーザー名を入力してください："

        # 接続 URL（ログイン先）: 種類ではなく、URL で選ぶ（段階と組織の種類は、結びつけない）
        local _tier
        _tier=$(org_tier_of_suffix "$suffix")  # VAR=$(cmd) のため run 不使用
        org_choose_login_url instance_url "$label" "${_tier:-main}" "$suffix"

        _test_jwt_login "$org_alias" "$suffix" "$label" "$consumer_key" "$username" "$instance_url" "$key_file"

        printf '%s' "$consumer_key" | run gh secret set "SF_CONSUMER_KEY_${suffix}" -R "$REPO_FULL_NAME" \
            || die "SF_CONSUMER_KEY_${suffix} の更新に失敗しました。"
        run gh variable set "SF_USERNAME_${suffix}"     --body "$username"     -R "$REPO_FULL_NAME" \
            || die "SF_USERNAME_${suffix} の更新に失敗しました。"
        run gh variable set "SF_INSTANCE_URL_${suffix}" --body "$instance_url" -R "$REPO_FULL_NAME" \
            || die "SF_INSTANCE_URL_${suffix} の更新に失敗しました。"
        log "SUCCESS" "  ${label}の Secret / Variables を更新しました。"
    done
}

# ------------------------------------------------------------------------------
# 6. メインメニュー
# ------------------------------------------------------------------------------
log "INFO" ""
log "INFO" "更新する項目を選択してください:"
log "INFO" "  1) 秘密鍵を更新（SF_PRIVATE_KEY）"
log "INFO" "  2) コンシューマーキーを更新（SF_CONSUMER_KEY_xxx）"
log "INFO" "  3) ユーザー名を更新（SF_USERNAME_xxx）"
log "INFO" "  4) すべて更新"

MENU_KEY=""
read_key MENU_KEY "  選択してください [1-4/q]: " "[1234Qq]"

case "$MENU_KEY" in
    1) _update_private_key  ;;
    2) _update_consumer_key ;;
    3) _update_username     ;;
    4) _update_all          ;;
    q|Q) die "中断しました。" ;;
esac

log "SUCCESS" "JWT Secrets の更新が完了しました。"
