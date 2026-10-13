#!/bin/bash
# ==============================================================================
# input.sh - 対話入力の関数
# ==============================================================================
# lib/common.sh から source される（呼び出し側は、common.sh だけを source すればよい。単独では、source しない）。
# common.sh の変数・関数（log / run / die / RET_* / 色の定義 など）を、使う。
#
# 【提供する関数】
#   read_input VARNAME [PROMPT]    ... readline 対応インタラクティブ入力
#   read_key VARNAME [PROMPT] [V]  ... 1文字即時入力（Enter 不要・空 Enter 無視）
#   press_enter [MSG]              ... Enter 待ち（q で中断）
#   read_or_quit VARNAME PROMPT    ... テキスト入力（空 Enter 無視・q で中断）
#   read_secret VARNAME PROMPT     ... 秘密情報の入力（* で表示・空 Enter は案内して再入力・q で中断）
#   ask_yn QUESTION                ... Y/N/q 確認（1文字即時入力）
# ==============================================================================

# read_input - readline 対応インタラクティブ入力（矢印キー・BS 等が正常に動作する）
# ------------------------------------------------------------------------------
# 【使い方】
#   read_input VARNAME [PROMPT]
#
# 【引数】
#   VARNAME : 入力値を格納する変数名
#   PROMPT  : 省略可。プロンプト文字列（stderr に出力）
#
# 【使用例】
#   read_input ORG_ALIAS "組織エイリアスを入力: "
#   read_input answer
# ------------------------------------------------------------------------------
read_input() {
    local _varname="$1" _prompt="${2:-}"
    if [[ -n "$_prompt" ]]; then
        # readline にプロンプトを渡し、ANSI カラーコードを \001..\002 で囲む
        # （カーソル位置計算を正しくし、行折り返し時のプロンプト上書きを防止）
        local _rl_prompt
        _rl_prompt=$(printf '%b' "$_prompt" | sed $'s/\033\\[[0-9;]*m/\001&\002/g')
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
#   read_key VARNAME [PROMPT]
#
# 【引数】
#   VARNAME : 入力値を格納する変数名
#   PROMPT  : 省略可。プロンプト文字列（stderr に出力）
#
# 【使用例】
#   read_key choice "  番号を入力 [1-3/q]: "
#   read_key answer "  削除してよいですか？ [Y/N/q]: "
# ------------------------------------------------------------------------------
read_key() {
    local _varname="$1" _prompt="${2:-}" _valid="${3:-}"
    while true; do
        [[ -n "$_prompt" ]] && printf "%s" "$_prompt" >&2
        # shellcheck disable=SC2229  # 同上（呼び出し側が指定した名前の変数に読み込む）
        read -rsn1 "$_varname" || { printf "\n" >&2; die "入力が中断されました。"; }
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
# 【使用例】
#   press_enter "ブラウザでログインしたら Enter を押してください..."
# ------------------------------------------------------------------------------
press_enter() {
    local msg="${1:-続行するには Enter キーを押してください（q で中断）...}"
    echo ""
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
#   VARNAME : 入力値を格納する変数名（nameref: Bash 4.3 以降必須）
#   PROMPT  : プロンプト文字列
#
# 【使用例】
#   read_or_quit JOB_NAME "  ジョブ名: "
#   read_or_quit PAT_TOKEN "  トークンを貼り付けてください（q で中断）: "
# ------------------------------------------------------------------------------
read_or_quit() {
    local -n _rq_var=$1
    local prompt="$2"
    while true; do
        read_input _rq_var "$prompt" || die "中断しました。"  # EOF → 中断
        [[ "$_rq_var" == "q" || "$_rq_var" == "Q" ]] && die "中断しました。"
        [[ -n "$_rq_var" ]] && break  # 空 Enter → 再入力
    done
}

# read_secret - 秘密情報の入力（入力した文字は * で表示する・空 Enter は案内して再入力・q で中断）
# ------------------------------------------------------------------------------
# 【使い方】
#   read_secret VARNAME PROMPT
#
# 【動作】
#   - 入力（貼り付け）した文字は、1 文字ごとに * で表示する。値そのものは、画面・スクロールバックに残らない
#     （貼り付けられたかどうかが、見て分かるようにするため。Git Bash は、右クリックで貼り付けるため、何も出ないと分からない）
#   - BackSpace で 1 文字消せる。ESC などの制御文字は無視する。末尾の CR（Windows の貼り付け）は除去する
#   - Enter で確定すると、「N 文字を受け取りました（先頭: ghp_…）」を表示する（値の先頭の「英字_」だけ。残りは出さない）
#   - 空 Enter は無視して再入力（端末のときは、貼り付け方を案内する）。q / Q だけの入力は die。EOF も die
#   - 標準入力が端末でない場合（テスト・e2e）も、同じように動く（* の表示だけ。案内は出さない）
#
# 【使用例】
#   read_secret PAT_TOKEN_VALUE "  Token を貼り付けてください（* で表示されます・q で中断）："
# ------------------------------------------------------------------------------
read_secret() {
    local -n _rs_var=$1
    local prompt="$2" _rs_ch _rs_buf _rs_prefix
    while true; do
        printf "%s" "$prompt" >&2
        _rs_buf=""
        while true; do
            if ! IFS= read -rsn1 _rs_ch; then
                # EOF: 改行なしで終わった入力は、確定として扱う。何も入力がなければ中断
                [[ -n "$_rs_buf" ]] && break
                printf "\n" >&2
                die "入力が中断されました。"
            fi
            # Enter（read は、区切りの改行を、空文字として返す）/ CR
            [[ -z "$_rs_ch" || "$_rs_ch" == $'\r' ]] && break
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
            _rs_var="$_rs_buf"
            break
        fi
        # 空 Enter → 再入力（端末のときは、貼り付け方を案内する）
        if [[ -t 0 ]]; then
            echo "  何も入力されていません。コピーした内容を、貼り付けてください（Git Bash は、右クリック、または Shift+Insert）。" >&2
        fi
    done
}

# Y / N / q を明示的に入力させる（1文字即時入力・q で即中断）
# 使い方: ask_yn "質問文" && echo "Yes" || echo "No"
ask_yn() {
    local prompt="$1" answer
    read_key answer "  ${prompt} [Y/N/q]: " "[YyNnQq]"
    case "$answer" in
        [Yy]) return 0 ;;
        [Nn]) return 1 ;;
        [Qq]) die "中断しました。" ;;
    esac
}
