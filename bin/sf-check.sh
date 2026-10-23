#!/bin/bash
# ==============================================================================
# sf-check.sh - デプロイターゲットファイル構文チェッカー
# ==============================================================================
# ターゲットファイル（deploy-target.txt / remove-target.txt）の内容を検証する。
# sf-release.sh・sf-push.sh・sf-precommit.sh・sf-prepush.sh から呼ばれる。単体でも実行できる。
#
# 【使い方】
#   sf-check.sh [deploy-target.txt のパス] [remove-target.txt のパス]
#     引数 2 つ以上: 1 つ目を deploy-target.txt、2 つ目を remove-target.txt として検証する（3 つ目以降は無視）
#     引数 1 つ    : deploy-target.txt だけを検証する
#     引数なし     : sf-tools/release/branch_name.txt（sf-start.sh / sf-install.sh が保存する）に書かれたブランチ名で、
#                    sf-tools/release/<ブランチ名>/deploy-target.txt と remove-target.txt を検証する。
#                    branch_name.txt がないときは、何も検証せず、終了コード 0 で終了する
#                    （ブランチ名は、今の Git のブランチではなく、branch_name.txt の内容を使う）
#
# 【オプション】
#   -h, --help : このヘルプを表示して終了する（1 つ目の引数のときだけ。ほかの引数は、すべてファイルのパスとして扱う）
#
# 【処理の流れ】
#   1. 各ターゲットファイルを 1 行ずつ検証する。CR と前後の空白を除き、空行と # で始まる行は読み飛ばす。
#      セクションは [files] / [members]。最初のマーカーより前の行は [files] として扱う
#        - [files]  : 次のときはエラー
#                       ・リポジトリの外を指すパス（/ ・C:/ ・C:\ で始まる絶対パス、.. を含むパス）。存在してもエラー
#                       ・カレントディレクトリからの相対パスで、通常のファイルとして存在しない（ディレクトリもエラー）
#        - [members]: 「種別名:メンバー名」の形でない（: がない・: の前か後ろが空）ときはエラー
#   2. 1 でエラーにならなかった行について、種類の可否を確認する
#      （config/metadata-capability.txt。sf-typecheck.sh が実際の組織で確かめた表）
#        deploy-target.txt は release 列、remove-target.txt は delete 列を見る
#        ng: エラー / limited: 警告（止めない） / ok・unknown・表にない種類: 何もしない
#        種類は、[members] では最初の「:」より前。[files] では、パスから推定できる次の種類だけ（ほかは確認しない）:
#          */flows/*.flow-meta.xml → Flow / */classes/*.cls → ApexClass / */triggers/*.trigger → ApexTrigger /
#          */lwc/* → LightningComponentBundle / */aura/* → AuraDefinitionBundle /
#          */servicePresenceStatuses/* → ServicePresenceStatus / */standardValueSets/* → StandardValueSet
#        組織の権限で、できる場合は、環境変数 SF_CHECK_IGNORE_CAPABILITY=1 で、この確認を省略できる
#   3. テストクラス不足を確認する（警告のみ。エラーにしない）
#        対象: deploy-target.txt の [files] の .cls のうち、存在し、@isTest（大文字・小文字を区別しない）を含まないもの
#        Step A: 同じディレクトリの <クラス名>Test.cls / <クラス名>_Test.cls を探す
#        Step B: A で見つからなければ、カレントディレクトリ以下の、@isTest（大文字・小文字を区別する）を含む .cls のうち、
#                クラス名を単語として含む最初のファイルを探す
#        見つかったテストクラスのパスが、deploy-target.txt の [files] の行と、文字列として一致しなければ、警告する
#        （本番/Sandbox に既にあるテストクラスは、含めなくてよいため）。テストクラスが見つからないときは、何も表示しない
#
# 【補足】
#   - ターゲットファイルが存在しないときは、そのファイルの検証を飛ばす（エラーにしない）。何も書かれていないときは、警告だけ
#   - Step B で見つかったパスは ./ で始まる形（例: ./force-app/...）のまま、deploy-target.txt の行と比べる
#   - 可否の表のパスは、環境変数 SF_CHECK_CAPABILITY_FILE で変えられる（既定: sf-tools の config/metadata-capability.txt）。
#     表のファイルがないときは、可否の確認をしない
#   - 終了コード: 0 = エラーなし（警告のみ・検証を飛ばした場合を含む） / 1 = エラーあり（書式・パス・可否の ng）
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 共通ライブラリの必須設定
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME=$(basename "$0" .sh)
readonly LOG_FILE="./sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="APPEND"

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

# ------------------------------------------------------------------------------
# 3. ターゲットファイルの解決
# ------------------------------------------------------------------------------
if [[ $# -ge 2 ]]; then
    DEPLOY_LIST="$1"
    REMOVE_LIST="$2"
elif [[ $# -eq 1 ]]; then
    DEPLOY_LIST="$1"
    REMOVE_LIST=""
else
    # 引数省略時: sf-tools/release/branch_name.txt から自動解決
    BRANCH_NAME_FILE="sf-tools/release/branch_name.txt"
    if [[ ! -f "$BRANCH_NAME_FILE" ]]; then
        log "INFO" "ブランチ情報ファイルが見つかりません。構文チェックをスキップします。(${BRANCH_NAME_FILE})"
        exit 0
    fi
    BRANCH_NAME=$(tr -d '\r\n' < "$BRANCH_NAME_FILE")
    DEPLOY_LIST="sf-tools/release/${BRANCH_NAME}/deploy-target.txt"
    REMOVE_LIST="sf-tools/release/${BRANCH_NAME}/remove-target.txt"
fi

# ------------------------------------------------------------------------------
# 4. ユーティリティ関数
# ------------------------------------------------------------------------------

# ------------------------------------------------------------------------------
# 種類の可否（config/metadata-capability.txt）
#   形式（タブ区切り）: 種類 / release / delete / 備考。release・delete は、ok / ng / limited / unknown
# ------------------------------------------------------------------------------
CAPABILITY_FILE="${SF_CHECK_CAPABILITY_FILE:-${SCRIPT_DIR}/../config/metadata-capability.txt}"

# 種類の可否を返す。引数: 種類 release|delete → 表の値（ok / ng / limited / unknown）。表にない・表のファイルがないときは、空
capability_status() {
    [[ -f "$CAPABILITY_FILE" ]] || return 0
    awk -F'\t' -v t="$1" -v c="$2" '$0 !~ /^#/ && $1 == t { v = (c == "release") ? $2 : $3; gsub(/\r/, "", v); print v; exit }' "$CAPABILITY_FILE"
}
capability_note() {
    [[ -f "$CAPABILITY_FILE" ]] || return 0
    awk -F'\t' -v t="$1" '$0 !~ /^#/ && $1 == t { v = $4; gsub(/\r/, "", v); print v; exit }' "$CAPABILITY_FILE"
}

# [files] のパスから、種類を推定する（確認済みの NG がありうる主な種類だけ）。分からなければ、空
type_of_path() {
    case "$1" in
        */flows/*.flow-meta.xml)        echo "Flow" ;;
        */classes/*.cls)                echo "ApexClass" ;;
        */triggers/*.trigger)           echo "ApexTrigger" ;;
        */lwc/*)                        echo "LightningComponentBundle" ;;
        */aura/*)                       echo "AuraDefinitionBundle" ;;
        */servicePresenceStatuses/*)    echo "ServicePresenceStatus" ;;
        */standardValueSets/*)          echo "StandardValueSet" ;;
        *) ;;
    esac
}

# 種類の可否の確認（エラーなら、戻り値 1）。引数: ラベル 行番号 行の内容 種類
#   ラベルが deploy-target.txt のときは release を、remove-target.txt のときは delete を、確認する
check_capability() {
    local label="$1" lineno="$2" content="$3" type="$4" which="release" what="リリース" st note
    [[ -n "$type" ]] || return 0
    [[ "${SF_CHECK_IGNORE_CAPABILITY:-}" == "1" ]] && return 0
    if [[ "$label" == remove* ]]; then which="delete"; what="削除"; fi
    st=$(capability_status "$type" "$which")  # VAR=$(cmd) のため run 不使用
    case "$st" in
        ng)
            note=$(capability_note "$type")  # VAR=$(cmd) のため run 不使用
            print_gcc_message "error" "$label" "$lineno" "$content" "「${type}」は、API で${what}できないことを確認済みです${note:+（${note}）}。組織の権限で、できる場合は、SF_CHECK_IGNORE_CAPABILITY=1 で、この確認を省略できます"
            return 1 ;;
        limited)
            note=$(capability_note "$type")  # VAR=$(cmd) のため run 不使用
            print_gcc_message "warning" "$label" "$lineno" "$content" "「${type}」は、条件によって、${what}できないことがあります${note:+（${note}）}" ;;
        *) ;;
    esac
    return 0
}

# \r 除去・前後空白トリムした結果を変数に格納する
# 引数: $1 = 出力変数名（set_var で代入）, $2 = 入力行
trim_line() {
    local _tl_tmp="$2"
    _tl_tmp="${_tl_tmp//$'\r'/}"
    _tl_tmp="${_tl_tmp#"${_tl_tmp%%[^[:space:]]*}"}"
    _tl_tmp="${_tl_tmp%"${_tl_tmp##*[^[:space:]]}"}"
    set_var "$1" "$_tl_tmp"
}

# セクションマーカーを判定し、セクション変数を更新する
# 引数: $1 = セクション変数名（set_var で代入）, $2 = トリム済み行
# 戻り値: 0=マーカーだった（呼び出し元で continue すべき） / 1=マーカーではない
parse_section() {
    local _ps_line="$2"
    if [[ "$_ps_line" == "[files]" ]]; then
        set_var "$1" "files"; return 0
    elif [[ "$_ps_line" == "[members]" ]]; then
        set_var "$1" "members"; return 0
    fi
    return 1
}

# GCC/Clang スタイルでメッセージを表示する
# 引数: $1 = レベル(error|warning), $2 = ファイル名, $3 = 行番号(空文字可), $4 = 行内容, $5 = メッセージ
print_gcc_message() {
    local level="$1" file="$2" lineno="$3" content="$4" message="$5"
    local level_color
    if [[ "$level" == "error" ]]; then
        level_color="$CLR_ERR"
    else
        level_color="$CLR_WARNING"
    fi
    if [[ -n "$lineno" ]]; then
        printf "  ${CLR_INFO}%s:%s:${CLR_RESET} ${level_color}%s:${CLR_RESET} %s\n" "$file" "$lineno" "$level" "$message"
    else
        printf "  ${CLR_INFO}%s:${CLR_RESET} ${level_color}%s:${CLR_RESET} %s\n" "$file" "$level" "$message"
    fi
    printf "    ${CLR_WARNING}→${CLR_RESET} %s\n" "$content"
}

# ------------------------------------------------------------------------------
# 5. チェック関数
# ------------------------------------------------------------------------------

# ターゲットファイルの構文チェック
# 引数: $1 = ファイルパス, $2 = ファイル種別ラベル
# エラー数は _CHECK_ERRORS に加算する（return のオーバーフロー防止）
check_target_file() {
    local file="$1"
    local label="$2"
    local error_count=0
    local entry_count=0
    local section="files"
    local lineno=0

    if [[ ! -f "$file" ]]; then
        log "INFO" "${label}: ファイルが存在しません。スキップします。(${file})"
        return 0
    fi

    log "INFO" "${label} を検証します: ${file}"

    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$(( lineno + 1 ))

        local clean
        trim_line clean "$line"

        # 空行・コメント行はスキップ
        [[ -z "$clean" || "$clean" == \#* ]] && continue

        # セクションマーカー判定
        parse_section section "$clean" && continue

        entry_count=$(( entry_count + 1 ))

        if [[ "$section" == "files" ]]; then
            # [files]: リポジトリの外を指すパス（絶対パス・.. を含むパス）は使えない。そのうえで、ファイルとして存在するか
            #   （外のファイルを、リリース・削除の対象にしないため。存在するファイルでも、エラーにする）
            if [[ "$clean" == /* || "$clean" == [A-Za-z]:/* || "$clean" == [A-Za-z]:\\* || "$clean" == ".." || "$clean" == ../* || "$clean" == */../* || "$clean" == */.. ]]; then
                print_gcc_message "error" "$label" "$lineno" "$clean" "リポジトリの外を指すパスは使えません（絶対パス・.. を含むパス）"
                error_count=$(( error_count + 1 ))
            elif [[ ! -f "$clean" ]]; then
                print_gcc_message "error" "$label" "$lineno" "$clean" "パスが存在しません"
                error_count=$(( error_count + 1 ))
            else
                check_capability "$label" "$lineno" "$clean" "$(type_of_path "$clean")" || error_count=$(( error_count + 1 ))
            fi
        else
            # [members]: 「種別名:メンバー名」形式チェック（コロン必須・両側が非空）
            if [[ "$clean" != *:* || "$clean" == :* || "$clean" == *: ]]; then
                print_gcc_message "error" "$label" "$lineno" "$clean" "書式エラー（種別名:メンバー名）"
                error_count=$(( error_count + 1 ))
            else
                check_capability "$label" "$lineno" "$clean" "${clean%%:*}" || error_count=$(( error_count + 1 ))
            fi
        fi
    done < "$file"

    if [[ "$entry_count" -eq 0 ]]; then
        log "WARNING" "${label}: 何も書かれていません。"
        return 0
    fi

    if [[ "$error_count" -eq 0 ]]; then
        log "SUCCESS" "${label}: 問題なし。"
    fi

    # グローバル変数にエラー数を加算（return 255 上限を回避）
    _CHECK_ERRORS=$(( _CHECK_ERRORS + error_count ))
    return 0
}

# Apex クラスに対応するテストクラスが deploy-target.txt に含まれているか検証
# 不足している場合は WARNING を表示（エラーにはしない）
check_missing_tests() {
    local deploy_list="$1"
    [[ ! -f "$deploy_list" ]] && return 0

    # [files] セクションの .cls ファイルを収集
    local deployed_files=()
    local section="files"
    while IFS= read -r line || [[ -n "$line" ]]; do
        local clean
        trim_line clean "$line"
        [[ -z "$clean" || "$clean" == \#* ]] && continue
        parse_section section "$clean" && continue
        [[ "$section" == "files" && "$clean" == *.cls ]] && deployed_files+=("$clean")
    done < "$deploy_list"

    [[ ${#deployed_files[@]} -eq 0 ]] && return 0

    log "INFO" "テストクラス不足チェックを実行します..."
    local warning_count=0

    for filepath in "${deployed_files[@]}"; do
        [[ ! -f "$filepath" ]] && continue
        # @isTest があればテストクラス自身なのでスキップ
        grep -qi "@isTest" "$filepath" 2>/dev/null && continue

        local classname class_dir
        classname=$(basename "$filepath" .cls)  # VAR=$(cmd) のため run 不使用
        class_dir=$(dirname "$filepath")         # VAR=$(cmd) のため run 不使用

        # Step A: 命名規則（同一ディレクトリ内で MyClassTest.cls / MyClass_Test.cls を探す）
        local found_test=""
        for candidate in "${class_dir}/${classname}Test.cls" "${class_dir}/${classname}_Test.cls"; do
            if [[ -f "$candidate" ]]; then
                found_test="$candidate"
                break
            fi
        done

        # Step B: 命名規則で見つからなければ @isTest ファイルをコンテンツ検索
        if [[ -z "$found_test" ]]; then
            found_test=$(grep -rl --include="*.cls" "@isTest" . 2>/dev/null \
                | xargs grep -lw "$classname" 2>/dev/null \
                | head -1 || true)  # VAR=$(cmd) のため run 不使用
        fi

        [[ -z "$found_test" ]] && continue

        # 見つかったテストクラスが deploy-target.txt に含まれているか確認
        local in_deploy=false
        for df in "${deployed_files[@]}"; do
            [[ "$df" == "$found_test" ]] && in_deploy=true && break
        done

        if [[ "$in_deploy" == false ]]; then
            print_gcc_message "warning" "$deploy_list" "" "$found_test" \
                "${classname} のテストクラスが deploy-target.txt に含まれていません（本番/Sandbox に存在する場合は無視可）"
            warning_count=$(( warning_count + 1 ))
        fi
    done

    if [[ $warning_count -gt 0 ]]; then
        log "WARNING" "テストクラス不足の可能性: ${warning_count}件"
    else
        log "SUCCESS" "テストクラスチェック: 問題なし。"
    fi
    return 0
}

# ------------------------------------------------------------------------------
# 6. メイン処理
# ------------------------------------------------------------------------------
log "HEADER" "デプロイターゲットファイルを検証します (${SCRIPT_NAME}.sh)"

# エラー数の集計用グローバル変数（check_target_file 内で加算される）
_CHECK_ERRORS=0

check_target_file "$DEPLOY_LIST" "deploy-target.txt"
check_target_file "$REMOVE_LIST" "remove-target.txt"
check_missing_tests "$DEPLOY_LIST"

if [[ "$_CHECK_ERRORS" -gt 0 ]]; then
    printf "\n${CLR_ERR}error${CLR_RESET}: %s 件のエラーが検出されました。ターゲットファイルを修正してください。\n\n" "$_CHECK_ERRORS"
    exit 1
fi

log "SUCCESS" "構文チェック完了。問題はありませんでした。"
exit 0
