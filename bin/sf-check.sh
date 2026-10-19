#!/bin/bash
# ==============================================================================
# sf-check.sh - デプロイターゲットファイル構文チェッカー
# ==============================================================================
# ターゲットファイル（deploy-target.txt / remove-target.txt）の構文を検証します。
# sf-release.sh から自動呼び出しされますが、単体実行も可能です。
#
# 【使い方】
#   sf-check.sh [deploy-target.txt] [remove-target.txt]
#   引数省略時は sf-tools/release/<branch>/ 配下を自動解決します。
#
# 【チェック内容】
#   - [files]   セクション: パスがリポジトリ内に存在するか（絶対パス・.. を含むパスなど、リポジトリの外を指すパスは、存在してもエラー）
#   - [members] セクション: 「種別名:メンバー名」形式になっているか
#   - 種類の可否: config/metadata-capability.txt（sf-typecheck.sh が、実際の組織で確かめた表）で、リリース・削除できないと
#     確認済み（ng）の種類を、deploy-target.txt（リリース）・remove-target.txt（削除）に書くと、エラーにする。
#     条件によって、できない種類（limited）は、警告にする（止めない）。確認していない種類（unknown）・
#     表にない種類は、何もしない。組織の権限で、できる場合は、
#     環境変数 SF_CHECK_IGNORE_CAPABILITY=1 で、この確認を省略できる
#   - テストクラス不足: Apex クラスに対応するテストクラスが含まれていない場合に警告
#       Step A: 命名規則（MyClassTest.cls / MyClass_Test.cls）で検索
#       Step B: A で見つからない場合 @isTest を含む .cls を内容検索
#       ※ 本番/Sandbox に既に存在するテストクラスは含めなくてよいため WARNING 扱い（エラーにならない）
#
# 【終了コード】
#   0: エラーなし
#   1: 構文エラーあり
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

# 種類の可否を返す。引数: 種類 release|delete → ok / ng / （空 = 表にない・確認していない）
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
