#!/bin/bash
# ==============================================================================
# sf-check.sh - デプロイターゲットファイル構文チェッカー
# ==============================================================================
# ターゲットファイル（deploy-target.txt / remove-target.txt）の内容を検証する。
# sf-release.sh・sf-push.sh・sf-precommit.sh・sf-prepush.sh・sf-launcher.sh（メニューの Check）から呼ばれる。単体でも実行できる。
#
# 【使い方】
#   sf-check.sh [deploy-target.txt のパス] [remove-target.txt のパス]
#     引数 2 つ以上: 1 つ目を deploy-target.txt、2 つ目を remove-target.txt として検証する（3 つ目以降は無視）
#     引数 1 つ    : deploy-target.txt だけを検証する
#     引数なし     : sf-tools/release/branch_name.txt（sf-install.sh が保存する。sf-start.sh が sf-install.sh を実行する）に書かれたブランチ名で、
#                    sf-tools/release/<ブランチ名>/deploy-target.txt と remove-target.txt を検証する。
#                    branch_name.txt がないときは、何も検証せず、WARNING を表示して、終了コード 0 で終了する
#                    （branch_name.txt は Git の管理外の、手元のファイル。一度も作られていないとき（新しいクローンの
#                    main など）は、このファイルがない。コミットは止めない）
#                    （ブランチ名は、今の Git のブランチではなく、branch_name.txt の内容を使う。sf-install.sh は、main では
#                    branch_name.txt を書き込みも削除もしないため、作業用ブランチのあと main に切り替えると、前のブランチの
#                    値が残り、そのブランチのターゲットファイルを検証する）
#
# 【オプション】
#   -v, --verbose : 受け付けるだけで、表示は変わらない（このスクリプトは run を使わないため、コマンドの応答の表示がない）
#   -h, --help : このヘルプを表示して終了する（1 つ目の引数のときだけ）
#   上記以外の - で始まる引数（2 つ目以降の -h / --help を含む）は、「不明なオプションです」で中断する。
#   それ以外の引数は、ファイルのパスとして扱う（-v / --verbose は、どの位置でもよく、引数の数には数えない）
#
# 【処理の流れ】
#   1. 各ターゲットファイルを 1 行ずつ検証する。CR と前後の空白を除き、空行と # で始まる行は読み飛ばす。
#      セクションは [files] / [members]。最初のマーカーより前の行は [files] として扱う
#        - [files]  : 次のときはエラー
#                       ・リポジトリの外を指すパス（/ ・C:/ ・C:\ で始まる絶対パス、要素に .. を含むパス
#                         （..・../〜・〜/../〜・〜/..））。存在してもエラー
#                       ・カレントディレクトリからの相対パスで、ファイルまたはディレクトリとして存在しない
#                       ・ディレクトリは、LWC・Aura のコンポーネントと、オブジェクトのフォルダ（lwc/<名前>・aura/<名前>・
#                         objects/<名前>）だけ書ける。classes や . など、ほかのディレクトリは、リリース・削除の対象が
#                         広がりすぎるため、エラー
#        - [members]: 「種別名:メンバー名」の形でない（: がない・先頭か末尾が :）ときはエラー
#   2. 1 でエラーにならなかった行について、種類の可否を確認する
#      （config/metadata-capability.txt。sf-typecheck.sh が実際の組織で確かめた表）
#        deploy-target.txt は release 列、remove-target.txt は delete 列を見る
#        ng: エラー / limited: 警告（止めない） / ok・unknown・表にない種類: 何もしない
#        種類は、[members] では最初の「:」より前。[files] では、パスから推定できる次の種類だけ（ほかは確認しない）:
#          */flows/*.flow-meta.xml → Flow / */classes/*.cls → ApexClass / */triggers/*.trigger → ApexTrigger /
#          */lwc/* → LightningComponentBundle / */aura/* → AuraDefinitionBundle /
#          */servicePresenceStatuses/* → ServicePresenceStatus / */standardValueSets/* → StandardValueSet
#        組織の権限で、できる場合は、環境変数 SF_CHECK_IGNORE_CAPABILITY=1 で、この確認を省略できる
#   3. テストクラス不足を確認する（警告のみ。エラーにしない。1・2 のエラーの有無にかかわらず行う）
#        対象: deploy-target.txt の [files] の .cls のうち、存在し、@isTest（大文字・小文字を区別しない）を含まないもの
#        Step A: 同じディレクトリの <クラス名>Test.cls / <クラス名>_Test.cls を探す
#        Step B: A で見つからなければ、カレントディレクトリ以下の、@isTest（大文字・小文字を区別する）を含む .cls のうち、
#                クラス名を単語として含む最初のファイルを探す
#        見つかったテストクラスのパスが、deploy-target.txt の [files] の行と、文字列として一致しなければ、警告する
#        （本番/Sandbox に既にあるテストクラスは、含めなくてよいため）。テストクラスが見つからないときは、何も表示しない
#
# 【前提条件】
#   - force-* ディレクトリ（プロジェクトのルート）で実行すること（lib/common.sh が確認する。違えば終了コード 1）
#
# 【補足】
#   - ターゲットファイルが存在しないときは、そのファイルの検証を飛ばす（エラーにしない）。何も書かれていないときは、警告だけ
#   - 1・2 のエラー・警告は「<ファイル名>:<行番号>: error|warning: <理由>」と、その行の内容を、標準出力に表示する
#     （<ファイル名> は、渡したパスではなく deploy-target.txt / remove-target.txt）。3 の警告は、行番号なしで、
#     deploy-target.txt のパスと、見つかったテストクラスのパスを表示する
#   - 3 で、見つかったテストクラスのパスと deploy-target.txt の行は、どちらも先頭の ./ を除いてから比べる
#     （例: ./force-app/... → force-app/...。deploy-target.txt に ./ 付きで書いても、書かなくても、同じ結果になる）
#   - 3 の Step B は、空白を含むパスでも動く（ファイル名を NUL 区切りで受け取る）
#   - 可否の表のパスは、環境変数 SF_CHECK_CAPABILITY_FILE で変えられる（既定: sf-tools の config/metadata-capability.txt）。
#     表のファイルがないときは、可否の確認をしない
#   - 終了コード: 0 = エラーなし（警告のみ・検証を飛ばした場合を含む） / 1 = エラーあり（書式・パス・可否の ng）・不明なオプション・
#     force-* ディレクトリの外で実行した
#   - ログ: ./sf-tools/logs/sf-check.log（実行のたびに追記する）
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 共通ライブラリの必須設定
# ------------------------------------------------------------------------------
SCRIPT_NAME="${0##*/}"; readonly SCRIPT_NAME="${SCRIPT_NAME%.sh}"
readonly LOG_FILE="./sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="APPEND"

# ------------------------------------------------------------------------------
# 2. 共通ライブラリの読み込み
# ------------------------------------------------------------------------------
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR/" == /* && "$SCRIPT_DIR/" != *//* && "$SCRIPT_DIR/" != */./* && "$SCRIPT_DIR/" != */../* ]] || SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="${SCRIPT_DIR}/../lib/common.sh"

if [[ ! -f "$COMMON_LIB" ]]; then
    echo "[FATAL ERROR] Library not found: $COMMON_LIB" >&2
    exit 1
fi
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}"  # run 不使用: common.sh の読み込み前（run が未定義）
    exit 0
fi
source "$COMMON_LIB"

# ------------------------------------------------------------------------------
# 3. ターゲットファイルの解決
# ------------------------------------------------------------------------------
# 引数は、ファイルのパス。-v / --verbose は受け付ける。それ以外の - で始まる引数は、不明なオプションとして中断する
#   （以前は、パスとして扱い、「ファイルがない」と黙って検証を飛ばしていた）
_check_args=()
for _a in "$@"; do
    case "$_a" in
        -v|--verbose) ;;
        -*) die "不明なオプションです: ${_a}" ;;
        *) _check_args+=("$_a") ;;
    esac
done
set -- ${_check_args[@]+"${_check_args[@]}"}
unset _check_args _a

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
        # 以前は INFO で、気づけなかった。検証を飛ばしたことを、警告として目立たせる（コミット・プッシュは止めない:
        #   branch_name.txt は Git の管理外の手元のファイルで、一度も作られていないとき（新しいクローンの main など）はないため。
        #   なお、sf-install.sh は main では書き込みも削除もしないため、main でも、前のブランチの値が残っていることがある）
        log "WARNING" "ブランチ情報ファイル（${BRANCH_NAME_FILE}）がありません。ターゲットファイルの構文チェックを、スキップしました。"
        exit 0
    fi
    BRANCH_NAME=$(tr -d '\r\n' < "$BRANCH_NAME_FILE")  # VAR=$(cmd) のため run 不使用
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

# 可否の表を、最初に 1 回だけ読み込む（1 行ごとに awk を起動すると、プロセスの起動が遅い Windows の Git Bash で、
#   行数に比例して遅くなるため）。_CAP_TABLE は、改行で始まり、改行で終わる文字列で、1 行が「種類<タブ>release<タブ>delete<タブ>備考」
#   （コメント行を除く。CR を除く。4 列に整える）
_CAP_TABLE=""
_CAP_LOADED=0
load_capability_table() {
    [[ "$_CAP_LOADED" -eq 1 ]] && return 0
    _CAP_LOADED=1
    [[ -f "$CAPABILITY_FILE" ]] || return 0
    local _cap_out
    _cap_out=$(awk -F'\t' '$0 !~ /^#/ { for (i = 1; i <= 4; i++) { v[i] = $i; gsub(/\r/, "", v[i]) } print v[1] "\t" v[2] "\t" v[3] "\t" v[4] }' "$CAPABILITY_FILE")  # 表の読み込み（1 回だけ）のため run 不使用
    _CAP_TABLE=$'\n'"${_cap_out}"$'\n'
}

# 種類の可否を引く。引数: 種類。結果は _CAP_REL（release）・_CAP_DEL（delete）・_CAP_NOTE（備考）に入る。
#   表にない・表のファイルがないときは、すべて空。最初に見つかった行を使う（プロセスは起動しない）
lookup_capability() {
    local _lc_type="$1" _lc_rest _lc_row
    _CAP_REL=""; _CAP_DEL=""; _CAP_NOTE=""
    load_capability_table
    [[ -n "$_CAP_TABLE" ]] || return 0
    _lc_rest="${_CAP_TABLE#*$'\n'"${_lc_type}"$'\t'}"
    [[ "$_lc_rest" == "$_CAP_TABLE" ]] && return 0
    _lc_row="${_lc_rest%%$'\n'*}"
    _CAP_REL="${_lc_row%%$'\t'*}"
    _lc_row="${_lc_row#*$'\t'}"
    _CAP_DEL="${_lc_row%%$'\t'*}"
    _CAP_NOTE="${_lc_row#*$'\t'}"
}

# [files] のパスから、種類を推定する（確認済みの NG がありうる主な種類だけ）。結果は _TYPE に入る。分からなければ、空
#   （$(type_of_path ...) の形は、1 回ごとにサブシェルを作るため、使わない）
type_of_path() {
    case "$1" in
        */flows/*.flow-meta.xml)        _TYPE="Flow" ;;
        */classes/*.cls)                _TYPE="ApexClass" ;;
        */triggers/*.trigger)           _TYPE="ApexTrigger" ;;
        */lwc/*)                        _TYPE="LightningComponentBundle" ;;
        */aura/*)                       _TYPE="AuraDefinitionBundle" ;;
        */servicePresenceStatuses/*)    _TYPE="ServicePresenceStatus" ;;
        */standardValueSets/*)          _TYPE="StandardValueSet" ;;
        *)                              _TYPE="" ;;
    esac
}

# 種類の可否の確認（エラーなら、戻り値 1）。引数: ラベル 行番号 行の内容 種類
#   ラベルが deploy-target.txt のときは release を、remove-target.txt のときは delete を、確認する
check_capability() {
    local label="$1" lineno="$2" content="$3" type="$4" what="リリース" st note
    [[ -n "$type" ]] || return 0
    [[ "${SF_CHECK_IGNORE_CAPABILITY:-}" == "1" ]] && return 0
    lookup_capability "$type"
    st="$_CAP_REL"; note="$_CAP_NOTE"
    if [[ "$label" == remove* ]]; then st="$_CAP_DEL"; what="削除"; fi
    case "$st" in
        ng)
            print_gcc_message "error" "$label" "$lineno" "$content" "「${type}」は、API で${what}できないことを確認済みです${note:+（${note}）}。組織の権限で、できる場合は、SF_CHECK_IGNORE_CAPABILITY=1 で、この確認を省略できます"
            return 1 ;;
        limited)
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

# ターゲットファイルの構文チェック（書式・パス）と、種類の可否の確認（check_capability）
# 引数: $1 = ファイルパス, $2 = ファイル種別ラベル（deploy-target.txt / remove-target.txt。表示と、可否の列の選択に使う）
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
            # [files]: リポジトリの外を指すパス（絶対パス・.. を含むパス）は使えない（外のファイルを、リリース・削除の対象に
            #   しないため。存在するファイルでも、エラーにする）。そのうえで、認めるフォルダ、またはファイルとして存在するか
            if [[ "$clean" == /* || "$clean" == [A-Za-z]:/* || "$clean" == [A-Za-z]:\\* || "$clean" == ".." || "$clean" == ../* || "$clean" == */../* || "$clean" == */.. ]]; then
                print_gcc_message "error" "$label" "$lineno" "$clean" "リポジトリの外を指すパスは使えません（絶対パス・.. を含むパス）"
                error_count=$(( error_count + 1 ))
            elif [[ -d "$clean" ]]; then
                # フォルダは、1 つのコンポーネント・オブジェクトを丸ごと指すもの（lwc/<名前>・aura/<名前>・objects/<名前>）だけ認める。
                #   classes や . のような、多数のメタデータを含むフォルダを書くと、リリース・削除の対象が、意図より広がるため
                #   （remove-target.txt では、組織のメタデータが、広範囲に削除される）
                if [[ "$clean" =~ (^|/)(lwc|aura|objects)/[^/]+/?$ ]]; then
                    type_of_path "$clean"; check_capability "$label" "$lineno" "$clean" "$_TYPE" || error_count=$(( error_count + 1 ))
                else
                    print_gcc_message "error" "$label" "$lineno" "$clean" "フォルダは、LWC・Aura のコンポーネントとオブジェクト（lwc/<名前>・aura/<名前>・objects/<名前>）だけ指定できます。それ以外は、ファイルのパスを書いてください"
                    error_count=$(( error_count + 1 ))
                fi
            elif [[ ! -f "$clean" ]]; then
                print_gcc_message "error" "$label" "$lineno" "$clean" "パスが存在しません"
                error_count=$(( error_count + 1 ))
            else
                type_of_path "$clean"; check_capability "$label" "$lineno" "$clean" "$_TYPE" || error_count=$(( error_count + 1 ))
            fi
        else
            # [members]: 「種別名:メンバー名」形式チェック（コロン必須・先頭と末尾がコロンでない）
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

# ファイルの本文を、変数に読み込む（組み込みの read だけを使い、プロセスを起動しない）。読めなければ、失敗
# 引数: $1 = 出力変数名（set_var で代入）, $2 = ファイルのパス
read_text() {
    local _rt_text=""
    [[ -r "$2" ]] || return 1
    IFS= read -r -d '' _rt_text < "$2" || true  # 区切りの NUL がないため、最後まで読むと失敗を返す（読めた分は、入っている）
    set_var "$1" "$_rt_text"
}

# 本文に @isTest を含むか（大文字と小文字は、区別しない。grep -qi と同じ）。プロセスを起動しない
text_has_istest() {
    local _hi_rc=1 _hi_had=0
    shopt -q nocasematch && _hi_had=1
    shopt -s nocasematch
    [[ "$1" == *"@isTest"* ]] && _hi_rc=0
    [[ "$_hi_had" -eq 1 ]] || shopt -u nocasematch
    return "$_hi_rc"
}

# リポジトリの中の @isTest を含む .cls（大文字と小文字を区別する）と、その本文を、最初に 1 回だけ読み込む。
#   クラスごとに、リポジトリ全体を grep し直すと、クラス数に比例して遅くなる（Windows の Git Bash では、特に）ため。
#   ファイル名は NUL 区切り（--null。GNU・BSD の grep の共通の書き方。-Z は BSD では別の意味）で受け取る。
#   一覧の順番は、grep -r の順番のまま（最初に見つかったテストクラスを使うため）
_TEST_PATHS=()
_TEST_TEXTS=()
_TESTS_LOADED=0
load_test_files() {
    [[ "$_TESTS_LOADED" -eq 1 ]] && return 0
    _TESTS_LOADED=1
    local _lt_path _lt_text
    while IFS= read -r -d '' _lt_path; do
        _lt_text=""
        read_text _lt_text "$_lt_path" || true
        _TEST_PATHS+=("$_lt_path")
        _TEST_TEXTS+=("$_lt_text")
    done < <(grep -rl --null --include="*.cls" "@isTest" . 2>/dev/null || true)  # プロセス置換で一覧を渡すため run 不使用（見つからなくても続行）
}

# 本文に、クラス名が「単語として」含まれるか（grep -qw と同じ。単語の文字は、英数字と _）。プロセスを起動しない
#   クラス名が、英数字と _ だけでないとき（grep の正規表現として、特別な意味の文字を含みうる）は、grep をそのまま使う
# 引数: $1 = クラス名, $2 = 本文, $3 = ファイルのパス（grep を使うときに読む）
text_has_word() {
    local _hw_re
    if [[ "$1" =~ ^[A-Za-z0-9_]+$ ]]; then
        _hw_re="(^|[^[:alnum:]_])${1}([^[:alnum:]_]|\$)"  # 正規表現は、変数に入れて渡す（Bash 3.2 でも、同じに解釈されるため）
        [[ "$2" =~ $_hw_re ]]
    else
        grep -qw -- "$1" "$3" 2>/dev/null  # 条件チェックのため run 不使用
    fi
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

    # deploy-target.txt の行（先頭の ./ を除いたもの）を、改行で区切って並べた文字列（含まれるかを、ループなしで調べるため）
    local deployed_set=$'\n' df
    for df in "${deployed_files[@]}"; do
        deployed_set="${deployed_set}${df#./}"$'\n'
    done

    local filepath
    for filepath in "${deployed_files[@]}"; do
        [[ ! -f "$filepath" ]] && continue
        # @isTest があればテストクラス自身なのでスキップ
        local file_text=""
        read_text file_text "$filepath" || true
        text_has_istest "$file_text" && continue

        # basename / dirname は、プロセスを起動せずに求める（パスの文字の操作だけでよいため）
        local classname class_dir
        classname="${filepath##*/}"
        classname="${classname%.cls}"
        if [[ "$filepath" == */* ]]; then
            class_dir="${filepath%/*}"
            [[ -n "$class_dir" ]] || class_dir="/"
        else
            class_dir="."
        fi

        # Step A: 命名規則（同一ディレクトリ内で MyClassTest.cls / MyClass_Test.cls を探す）
        local found_test="" candidate
        for candidate in "${class_dir}/${classname}Test.cls" "${class_dir}/${classname}_Test.cls"; do
            if [[ -f "$candidate" ]]; then
                found_test="$candidate"
                break
            fi
        done

        # Step B: 命名規則で見つからなければ @isTest ファイルをコンテンツ検索
        #   （@isTest を含むファイルの一覧と本文は、最初の 1 回だけ読み込む: load_test_files）
        if [[ -z "$found_test" ]]; then
            load_test_files
            local i
            for (( i = 0; i < ${#_TEST_PATHS[@]}; i++ )); do
                if text_has_word "$classname" "${_TEST_TEXTS[i]}" "${_TEST_PATHS[i]}"; then
                    found_test="${_TEST_PATHS[i]}"
                    break
                fi
            done
        fi

        [[ -z "$found_test" ]] && continue
        found_test="${found_test#./}"   # Step B（grep -r .）の結果は ./ で始まる（Step A も、クラスのパスが ./ で始まるときは同じ）。先頭の ./ を除いて比べる

        # 見つかったテストクラスが deploy-target.txt に含まれているか確認（deploy-target.txt の行も、先頭の ./ を除いて比べる）
        local in_deploy=false
        [[ "$deployed_set" == *$'\n'"${found_test}"$'\n'* ]] && in_deploy=true

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
