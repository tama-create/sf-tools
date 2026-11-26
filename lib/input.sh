#!/bin/bash
# ==============================================================================
# input.sh - 対話入力の関数
# ==============================================================================
# lib/common.sh から source される（呼び出し側は、common.sh だけを source すればよい。単独では、source しない）。
# common.sh の die と、platform.sh の set_var（common.sh が、このファイルのあとに source する）を、使う。
# プロンプト・エコーは、すべて標準エラーに出す（命令置換の中で呼んでも、結果に混ざらない）。
# 「中断」は、すべて die（終了コード 1）。
#
# 【提供する関数】
#   read_input VARNAME [PROMPT]    ... readline 対応インタラクティブ入力（戻り値は read のもの。EOF で 0 以外）
#   read_key VARNAME [PROMPT] [V]  ... 1文字即時入力（Enter 不要・空 Enter と V（正規表現）に合わない文字は無視・EOF で die。
#                                      V の省略時は、空 Enter 以外のすべての文字（空白・タブを含む）を受け付ける）
#   press_enter [MSG]              ... Enter 待ち（q / Q・EOF で中断）
#   read_or_quit VARNAME PROMPT    ... テキスト入力（空 Enter 無視・q / Q・EOF で中断）
#   read_secret VARNAME PROMPT     ... 秘密情報の入力（* で表示・空 Enter は再入力・q / Q・EOF（入力なし）で中断）
#   ask_yn QUESTION [NAME]         ... Y/N/q 確認（1文字即時入力。Y = 0 / N = 1 / q = 中断）。NAME は、AI 操作の質問の名前
#   need_answer NAME QUESTION      ... AI 操作の確認待ち（「[確認待ち] NAME: QUESTION」を出し、終了コード 20 で終わる）
#
# 【AI 操作（SF_TOOLS_AI=1 のときだけ。doc/ai-operation-design.md）】
#   - ask_yn は、名前（NAME）の答えが SF_TOOLS_ANSWERS（「名前=y|n」の空白区切り）にあれば、それを使う（1 回の実行で 1 回だけ）。
#     なければ need_answer で止まる（入力を待たない・標準入力を読まない）
#   - read_key・read_input・read_secret は、入力のループの前で need_answer で止まる（名前なし）。press_enter・read_or_quit・
#     wizard_confirm（lib/wizard.sh）も、これらを通るため止まる。read_secret は、答えがあっても止まる（秘密の値を AI に扱わせない）
#   - 答えの受け取り（_ai_answers_init。common.sh の読み込みの最後に呼ぶ）: SF_TOOLS_ANSWERS の各項目の形（名前は
#     <コマンド>.<質問>、値は y / n）を確かめ（違う・同じ名前が 2 つ → 中断）、名前の先頭が自分（SCRIPT_NAME から sf- を除いたもの）か
#     update のものを受け取り、残りだけを SF_TOOLS_ANSWERS として export し直す（子・孫は、親の答えを使えない）
#   - 入力の関数は、$( ) の中で呼ばない（サブシェルの exit 20 は外に伝わらないため）
#   - AI の印がないときは、今までと同じ（標準入力を読む。テスト・GitHub Actions の動きは変わらない）
# ==============================================================================

# ------------------------------------------------------------------------------
# AI 操作（SF_TOOLS_AI=1）の確認待ちと、答えの受け取り（doc/ai-operation-design.md 1.4）
# ------------------------------------------------------------------------------
_SF_AI_MY_ANSWERS=""   # このプロセスが受け取った答え（「名前=y|n」の空白区切り。形は確かめ済み）
_SF_AI_USED=""         # このプロセスで使った名前（空白区切り。同じ名前の 2 回目は、答えがないものとして止める）
_SF_AI_ANS=""          # _ai_take_answer が取り出した値（y / n）
# 名前の形: <コマンド>.<質問>（英小文字・数字・-。. で区切る）
_SF_AI_ITEM_RE='^([a-z][a-z0-9-]*(\.[a-z0-9-]+)+)=([yn])$'

# _ai_mode - AI 操作の印（SF_TOOLS_AI=1）があれば 0
_ai_mode() { [[ "${SF_TOOLS_AI:-}" == "1" ]]; }

# need_answer NAME QUESTION - 確認待ちの 1 行を出して、終了コード 20（RET_NEED_ANSWER）で終わる。入力は待たない
#   NAME が空なら「(名前なし)」（AI からは答えられない質問。人に頼む合図）。プロセスごと終わる（die ではない）
need_answer() {
    local _na_name="${1:-}" _na_q="${2:-}"
    # 質問の文の前後の空白を除く（AI が、そのまま人に聞けるように）
    _na_q="${_na_q#"${_na_q%%[![:space:]]*}"}"
    _na_q="${_na_q%"${_na_q##*[![:space:]]}"}"
    printf '[確認待ち] %s: %s
' "${_na_name:-(名前なし)}" "$_na_q" >&2
    [[ -n "${LOG_FILE:-}" ]] && printf '[確認待ち] %s: %s
' "${_na_name:-(名前なし)}" "$_na_q" >> "$LOG_FILE" 2>/dev/null
    exit "$RET_NEED_ANSWER"
}

# _ai_answers_init - 自分の先頭の答えを受け取り、残りを SF_TOOLS_ANSWERS として export し直す（AI の印がなければ何もしない）
_ai_answers_init() {
    _ai_mode || return 0
    local _prefix="${SCRIPT_NAME:-}" _item _name _head _rest="" _seen=" " _items=()
    _prefix="${_prefix#sf-}"
    # 空白で区切って読む（read -a は Bash 3.2 でも使える。パス名の展開を起こさない）
    read -r -a _items <<< "${SF_TOOLS_ANSWERS:-}"
    for _item in ${_items[@]+"${_items[@]}"}; do
        [[ "$_item" =~ $_SF_AI_ITEM_RE ]] || die "SF_TOOLS_ANSWERS の形が正しくありません: ${_item}（名前=y または 名前=n。名前は <コマンド>.<質問>）"
        _name="${BASH_REMATCH[1]}"
        case "$_seen" in *" ${_name} "*) die "SF_TOOLS_ANSWERS に、同じ名前が 2 つあります: ${_name}" ;; esac
        _seen+="${_name} "
        _head="${_name%%.*}"
        if [[ "$_head" == "$_prefix" || "$_head" == "update" ]]; then
            _SF_AI_MY_ANSWERS+="${_item} "
        else
            _rest+="${_item} "
        fi
    done
    export SF_TOOLS_ANSWERS="${_rest% }"
    [[ -n "$_SF_AI_MY_ANSWERS" ]] && printf '  （AI 経由の答えを受け取りました: %s）
' "${_SF_AI_MY_ANSWERS% }" >&2
    return 0
}

# _ai_take_answer NAME - 自分の答えに NAME があり、まだ使っていなければ、_SF_AI_ANS に値を入れて 0（使ったことにする）
_ai_take_answer() {
    local _name="$1" _item
    [[ -z "$_name" ]] && return 1
    case " ${_SF_AI_USED} " in *" ${_name} "*) return 1 ;; esac
    # _SF_AI_MY_ANSWERS の各項目は、形を確かめ済み（空白・展開の文字を含まない）
    for _item in $_SF_AI_MY_ANSWERS; do
        if [[ "${_item%=*}" == "$_name" ]]; then
            _SF_AI_ANS="${_item##*=}"
            _SF_AI_USED+="${_name} "
            return 0
        fi
    done
    return 1
}

# read_input - readline 対応インタラクティブ入力（矢印キー・BS 等が正常に動作する）
# ------------------------------------------------------------------------------
# 【使い方】
#   read_input VARNAME [PROMPT]
#
# 【引数】
#   VARNAME : 入力値を格納する変数名（read -r。前後の空白は、IFS により除かれる）
#   PROMPT  : 省略可。プロンプト文字列（stderr に出力）。\033 などのエスケープは printf '%b' で解釈する
#
# 【戻り値】
#   read の戻り値（EOF なら 0 以外）。呼び出し側が「|| die」などで扱う
#
# 【補足】
#   readline（-e）とプロンプトの表示（-p）は、標準入力が端末のときだけ働く（read の仕様。テストでは、プロンプトは出ない）
#
# 【使用例】
#   read_input ORG_ALIAS "組織エイリアスを入力: "
#   read_input answer
# ------------------------------------------------------------------------------
read_input() {
    local _varname="$1" _prompt="${2:-}"
    _ai_mode && need_answer "" "$_prompt"   # AI 操作: 入力を読まずに、確認待ちで止まる（名前なし）
    if [[ -n "$_prompt" ]]; then
        # readline にプロンプトを渡し、ANSI カラーコードを \001..\002 で囲む
        # （カーソル位置計算を正しくし、行折り返し時のプロンプト上書きを防止）
        local _rl_prompt
        _rl_prompt=$(printf '%b' "$_prompt" | sed $'s/\033\\[[0-9;]*m/\001&\002/g')  # VAR=$(cmd) のため run 不使用
        # shellcheck disable=SC2229  # 呼び出し側が指定した名前の変数に読み込む（意図的な間接参照）
        read -rep "$_rl_prompt" "$_varname"
    else
        # shellcheck disable=SC2229  # 同上
        read -re "$_varname"
    fi
}

# read_key - 1文字即時入力（Enter不要・空 Enter 無視）
# ------------------------------------------------------------------------------
# 【使い方】
#   read_key VARNAME [PROMPT] [VALID]
#
# 【引数】
#   VARNAME : 入力値を格納する変数名
#   PROMPT  : 省略可。プロンプト文字列（stderr に出力。エスケープは解釈しない）
#   VALID   : 省略可。受け付ける文字の正規表現（例: "[YyNnQq]"）。省略時は、空 Enter 以外のすべての文字（空白・タブ・
#             CR などの制御文字も含む）
#
# 【動作】
#   1 文字を IFS= read -rsn1 で読む（IFS= により、空白・タブも、その文字のまま受け取る。以前は IFS の既定値で読んでいたため、
#   空白・タブが空になり、空 Enter と同じに無視されていた）。入力した文字は表示しない（-s）。
#   空 Enter（改行。read は空文字を返す）・VALID に合わない文字は、行を消して、同じプロンプトで再入力。
#   受け付けた文字だけを、標準エラーに表示して改行する。EOF なら die。
#   q で中断する処理は、含まない（呼び出し側が判定する）
#
# 【使用例】
#   read_key choice "  番号を入力 [1-3/q]: "
#   read_key answer "  削除してよいですか？ [Y/N/q]: "
# ------------------------------------------------------------------------------
read_key() {
    local _varname="$1" _prompt="${2:-}" _valid="${3:-}"
    _ai_mode && need_answer "" "$_prompt"   # AI 操作: ループの前で 1 回だけ、確認待ちで止まる（名前なし）
    while true; do
        [[ -n "$_prompt" ]] && printf "%s" "$_prompt" >&2
        # shellcheck disable=SC2229  # 同上（呼び出し側が指定した名前の変数に読み込む）
        IFS= read -rsn1 "$_varname" || { printf "\n" >&2; die "入力が中断されました。"; }
        # 空 Enter または無効文字 → 行クリアして再プロンプト（同じ行に留まる）
        if [[ -z "${!_varname}" ]] || { [[ -n "$_valid" ]] && ! [[ "${!_varname}" =~ $_valid ]]; }; then
            printf "\r\033[K" >&2
            continue
        fi
        printf "%s\n" "${!_varname}" >&2  # 有効文字のみエコー
        break
    done
}

# press_enter - Enter キー待ち（q で中断）
# ------------------------------------------------------------------------------
# 【使い方】
#   press_enter [MSG]
#
# 【引数】
#   MSG : 省略時は「続行するには Enter キーを押してください（q で中断）...」
#
# 【動作】
#   空行を 1 行、標準エラーに出してから、「  ▶ MSG」をプロンプトにして、read_input で 1 行読む。
#   q / Q だけの入力、または EOF なら die。それ以外の入力（空 Enter を含む）は、続行（戻り値 0）。
#   標準出力には、何も出さない（以前は、空行を標準出力に出していたため、命令置換の中で呼ぶと、結果に混ざった）
#
# 【使用例】
#   press_enter "ブラウザでログインしたら Enter を押してください..."
# ------------------------------------------------------------------------------
press_enter() {
    local msg="${1:-続行するには Enter キーを押してください（q で中断）...}"
    echo "" >&2
    local _input
    read_input _input "  ▶ $msg" || die "中断しました。"  # EOF → 中断
    [[ "$_input" == "q" || "$_input" == "Q" ]] && die "中断しました。"
}

# read_or_quit - テキスト入力（空 Enter 無視・q で中断）
# ------------------------------------------------------------------------------
# 【使い方】
#   read_or_quit VARNAME PROMPT
#
# 【引数】
#   VARNAME : 入力値を格納する変数名（set_var で代入する）
#   PROMPT  : プロンプト文字列（read_input に渡す）
#
# 【動作】
#   空 Enter は再入力。q / Q だけの入力、または EOF なら die
#
# 【使用例】
#   read_or_quit JOB_NAME "  ジョブ名: "
#   read_or_quit PAT_TOKEN "  トークンを貼り付けてください（q で中断）: "
# ------------------------------------------------------------------------------
read_or_quit() {
    local _rq_name="$1" _rq_prompt="$2" _rq_val=""
    while true; do
        read_input _rq_val "$_rq_prompt" || die "中断しました。"  # EOF → 中断
        [[ "$_rq_val" == "q" || "$_rq_val" == "Q" ]] && die "中断しました。"
        [[ -n "$_rq_val" ]] && break  # 空 Enter → 再入力
    done
    set_var "$_rq_name" "$_rq_val"
}

# read_secret - 秘密情報の入力（入力した文字は * で表示する・空 Enter は案内して再入力・q で中断）
# ------------------------------------------------------------------------------
# 【使い方】
#   read_secret VARNAME PROMPT
#
# 【動作】
#   - 入力（貼り付け）した文字は、1 文字ごとに * で表示する。値そのものは、画面・スクロールバックに残らない
#     （貼り付けられたかどうかが、見て分かるようにするため。Git Bash は、右クリックで貼り付けるため、何も出ないと分からない）
#   - BackSpace（DEL / ^H）で 1 文字消せる。ESC などの制御文字は無視する。
#     ESC のあとに [ または O が続くとき（矢印キーの ESC [ A・ESC O A など、端末の制御シーケンス）は、終わりの文字
#     （途中の文字（0x20〜0x3F。数字・; など）以外の 1 文字。Enter などもその 1 文字として読み捨てる）までを、まとめて読み捨てる（値に入れない）。
#     ESC のあとに、それ以外の文字が続くときは、ESC だけを無視し、続く文字は通常どおり扱う。
#     ESC に続く文字は、最大 1 秒だけ待つ（Bash 3.2 の read -t は、整数の秒だけ）
#   - CR（Windows の貼り付けの改行）は、Enter と同じく確定として扱う。CR で確定したときは、続く 1 文字を最大 1 秒待って
#     読み捨てる（CRLF の LF を、次の入力に残さないため。以前は、LF が残り、次の読み取りが空 Enter になった）。
#     続く文字が LF 以外でも、読み捨てる（CR だけの改行のあとに、続けて入力が来る場合は、その 1 文字が失われる）
#   - 直せていないこと: 端末が CR を LF に変換する設定（ICRNL）のときは、CRLF の貼り付けは LF 2 つとして届き、
#     2 つ目の LF が、次の入力に残る（LF のあとに、さらに入力が届いているかを、待たずに確かめる方法が、Bash 3.2 にないため）
#   - Enter で確定すると、「→ N 文字を受け取りました（先頭: ghp_…）」を表示する（先頭が「英字 2〜12 文字 + _」のときだけ、
#     その部分を出す。残りは出さない）
#   - 空 Enter は再入力（端末のときは、貼り付け方を案内する）。q / Q だけの入力は die。
#     EOF: それまでに入力があれば確定、何も入力がなければ die
#   - 標準入力が端末でない場合（テスト・e2e）も、同じように動く（* の表示だけ。案内は出さない）
#   - 表示（プロンプト・*・案内）は、すべて標準エラー。値は set_var で VARNAME に入れる
#
# 【使用例】
#   read_secret PAT_TOKEN_VALUE "  Token を貼り付けてください（* で表示されます・q で中断）："
# ------------------------------------------------------------------------------
read_secret() {
    local _rs_name="$1" _rs_prompt="$2" _rs_ch _rs_buf _rs_prefix
    _ai_mode && need_answer "" "$_rs_prompt"   # AI 操作: 秘密の値は、AI に扱わせない（答えがあっても止まる）
    # 制御シーケンス（ESC [ ...）の途中の文字（パラメーター 0x30〜0x3F・中間 0x20〜0x2F）。これ以外の文字で、シーケンスが終わる
    local _rs_csi_mid='0123456789:;<=>? !"#$%&'"'"'()*+,-./'
    while true; do
        printf "%s" "$_rs_prompt" >&2
        _rs_buf=""
        while true; do
            if ! IFS= read -rsn1 _rs_ch; then
                # EOF: 改行なしで終わった入力は、確定として扱う。何も入力がなければ中断
                [[ -n "$_rs_buf" ]] && break
                printf "\n" >&2
                die "入力が中断されました。"
            fi
            # ESC: 続く文字が [ / O なら、制御シーケンス（矢印キーなど）として、終わりの文字まで読み捨てる
            if [[ "$_rs_ch" == $'\033' ]]; then
                IFS= read -rsn1 -t 1 _rs_ch || continue   # ESC だけ（続く文字がない・EOF）→ 無視
                if [[ "$_rs_ch" == "[" || "$_rs_ch" == "O" ]]; then
                    while IFS= read -rsn1 -t 1 _rs_ch; do
                        [[ -n "$_rs_ch" && "$_rs_csi_mid" == *"$_rs_ch"* ]] || break   # 途中の文字でなければ、終わり
                    done
                    continue
                fi
                # それ以外の文字: ESC だけを無視し、その文字は、下で通常どおり扱う
            fi
            # Enter（read は、区切りの改行を、空文字として返す）
            [[ -z "$_rs_ch" ]] && break
            # CR: 確定。続く LF（CRLF の貼り付け）を、次の入力に残さないよう、1 文字を読み捨てる（最大 1 秒待つ）
            if [[ "$_rs_ch" == $'\r' ]]; then
                IFS= read -rsn1 -t 1 _rs_ch || true  # 意図的エラー無視（続く文字がなくてもよい。読んだ文字は使わない）
                break
            fi
            # BackSpace / DEL: 1 文字消す
            if [[ "$_rs_ch" == $'\x7f' || "$_rs_ch" == $'\b' ]]; then
                if [[ -n "$_rs_buf" ]]; then
                    _rs_buf="${_rs_buf%?}"
                    printf '\b \b' >&2
                fi
                continue
            fi
            # そのほかの制御文字（ESC など）は無視する
            [[ "$_rs_ch" == [[:cntrl:]] ]] && continue
            _rs_buf+="$_rs_ch"
            printf '*' >&2
        done
        printf "\n" >&2
        _rs_buf="${_rs_buf%$'\r'}"
        [[ "$_rs_buf" == "q" || "$_rs_buf" == "Q" ]] && die "中断しました。"
        if [[ -n "$_rs_buf" ]]; then
            # 受け取った内容の確認用の表示（文字数と、先頭の「英字_」だけ。残りは出さない）
            _rs_prefix=""
            [[ "$_rs_buf" =~ ^[A-Za-z]{2,12}_ ]] && _rs_prefix="${BASH_REMATCH[0]}"
            printf "  → %d 文字を受け取りました%s\n" "${#_rs_buf}" "${_rs_prefix:+（先頭: ${_rs_prefix}…）}" >&2
            set_var "$_rs_name" "$_rs_buf"
            break
        fi
        # 空 Enter → 再入力（端末のときは、貼り付け方を案内する）
        if [[ -t 0 ]]; then
            echo "  何も入力されていません。コピーした内容を、貼り付けてください（Git Bash は、右クリック、または Shift+Insert）。" >&2
        fi
    done
}

# ask_yn - Y / N / q を明示的に入力させる（1文字即時入力・q で即中断）
#   プロンプトは「  質問文 [Y/N/q]: 」（read_key。Y / N / q 以外の文字・空 Enter は、無視して待ち続ける）
#   戻り値: 0 = Y / y、1 = N / n。q / Q は die
#   NAME（省略可）: AI 操作の質問の名前（<コマンド>.<質問>。例: deploy.force）。AI のとき、その答えを 1 回だけ使う。
#     答えがない・名前がない → need_answer で止まる（AI の印がなければ、NAME は使わない）
# 使い方: ask_yn "質問文" [NAME] && echo "Yes" || echo "No"
ask_yn() {
    local prompt="$1" name="${2:-}" answer
    if _ai_mode; then
        if _ai_take_answer "$name"; then
            printf '  %s [Y/N/q]: %s（AI 経由の回答: %s=%s）
' "$prompt" "$_SF_AI_ANS" "$name" "$_SF_AI_ANS" >&2
            [[ -n "${LOG_FILE:-}" ]] && printf '[AI 経由の回答] %s=%s: %s
' "$name" "$_SF_AI_ANS" "$prompt" >> "$LOG_FILE" 2>/dev/null
            [[ "$_SF_AI_ANS" == "y" ]] && return 0
            return 1
        fi
        need_answer "$name" "$prompt"
    fi
    read_key answer "  ${prompt} [Y/N/q]: " "[YyNnQq]"
    case "$answer" in
        [Yy]) return 0 ;;
        [Nn]) return 1 ;;
        [Qq]) die "中断しました。" ;;
    esac
}
