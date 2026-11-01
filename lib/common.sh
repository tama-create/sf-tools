#!/bin/bash
# ==============================================================================
# common.sh - sf-tools 共通関数ライブラリ
# ==============================================================================
# sf-tools のスクリプト（bin/ の sf-*.sh。lib/common.sh を読み込まない sf-launcher.sh を除く）・phases/ のサブスクリプトが
# source して使用する共通ライブラリです。
#
# 【source 前に定義する変数】（各スクリプトは readonly で定義している）
#   LOG_FILE=...      ログファイルパス（例: ./sf-tools/logs/${SCRIPT_NAME}.log）。必須（未定義なら [FATAL ERROR] を表示して exit 1）
#   SCRIPT_NAME=...   スクリプト名（拡張子なし）。run のログの行（[SCRIPT_NAME.sh]）に使う
#   LOG_MODE=...      NEW = source 時にログファイルを空にする / それ以外（APPEND など）= 追記
#   ※ SILENT_EXEC は source 後に自動設定されます（--verbose / -v オプションで制御）
#
# 【source 時の動作】
#   - Bash 3.2 未満なら、エラーを表示して exit 1
#   - カレントディレクトリ名が force- で始まらなければ、エラーを表示して exit 1（SF_INIT_MODE=1 のときは確認しない）
#   - LOG_FILE のフォルダを作り（chmod 700）、LOG_MODE=NEW ならログファイルを空にする
#   - 最後に、同じフォルダの input.sh / platform.sh / project.sh を source する
#
# 【提供する関数】
#   log LEVEL MESSAGE [DEST]  ... 画面とログファイルへ出力
#   run CMD [ARGS...]         ... コマンドを実行してログに記録
#   die MESSAGE [EXIT_CODE]   ... エラーログを出力して終了
#   show_help                 ... 呼び出し元スクリプトの冒頭コメント（--help 用の部分）を表示して exit 0
#   reject_unknown_args "$@"  ... -v / --verbose 以外の引数があれば die
#   print_admin_warning [--standard] [行...] ... 管理者向けの警告ボックス（赤）を表示する（確認は、含まない）
#   json_get JSON パス...     ... JSON から値を取り出す（Node の標準機能のみ。sf CLI の出力など）
#   _mask_secrets TEXT        ... 文字列中の Token らしい文字列を伏せ字にして、標準出力に返す
#   _strip_ansi               ... 標準入力から ANSI エスケープコードを除いて、標準出力に出す（GNU / BSD の sed 共通）
#   _strip_term_codes         ... _strip_ansi に加えて、絵文字も除く
#   （上の 3 つは、名前が _ で始まるが、外からも使ってよい（phases/init/verify.sh・tests/e2e/ が使う。sed の \x1b などを
#     直書きせず、これらを使う: CLAUDE.md 2.2）。内部用: _display_width（print_admin_warning の幅の計算）
#   内部用（run と log が使う）: _mask_secrets_var / _now_ts / _has_term_codes / _prefix_lines。1 回ごとに外部のプログラム
#     （sed・date）を起動しないための部品。プロセスの起動が遅い Windows の Git Bash で、1 回の run が約 600ms → 約 200ms になる
#
#   以下は、責務ごとのファイルに分けてあり、この common.sh が source する（呼び出し側は、common.sh だけでよい）。
#   主な関数を挙げる。一覧は、各ファイルの冒頭の【提供する関数】を参照:
#   project.sh   ... get_target_org / check_force_dir / resolve_init_identity / resolve_job_identity / check_gh_owner / get_branch_list /
#                    is_reserved_org_alias / is_protected_branch / required_status_check_names / ensure_sf_tools_latest など
#   platform.sh  ... is_gitbash / set_var / sed_inplace / base64_oneline / run_with_timeout / run_isolated_home / check_sf_cli / open_browser
#   input.sh     ... read_input / read_key / press_enter / read_or_quit / read_secret / ask_yn
#   lib/ の org.sh / wizard.sh / diag.sh / verify-common.sh は、common.sh からは source しない（使うスクリプトが、個別に source する）
#
# 【定数】
#   CLR_INFO / CLR_SUCCESS / CLR_WARNING / CLR_ERR / CLR_FATAL / CLR_PROMPT / CLR_RESET ... 色（端末でないときは空）
#   SF_HOOK_MARKER / BRANCH_LIST_FILE / SF_RESERVED_ORG_ALIASES                         ... 下の各節を参照
#
# 【戻り値定数】
#   RET_OK=0        正常終了
#   RET_NG=1        異常終了
#   RET_NO_CHANGE=2 変更なし（NothingToDeploy）
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Bash バージョンチェック
# ------------------------------------------------------------------------------
# macOS 標準の Bash（/bin/bash）は 3.2。追加のインストールなしで動くように、3.2 を下限にする。
# Bash 4 以降の機能（local -n / declare -A / mapfile / ${x^} / ${x,,} / wait -n など）は、使わない。
if (( BASH_VERSINFO[0] < 3 || (BASH_VERSINFO[0] == 3 && BASH_VERSINFO[1] < 2) )); then
    echo "[ERROR] Bash 3.2 以上が必要です（現在: ${BASH_VERSION}）" >&2
    exit 1
fi

# ------------------------------------------------------------------------------
# 2. 状態定数
# ------------------------------------------------------------------------------
readonly RET_OK=0           # 正常終了
readonly RET_NG=1           # 異常終了
readonly RET_NO_CHANGE=2    # 変更なし

# ------------------------------------------------------------------------------
# 3. 必須変数のバリデーションとログ初期化
# ------------------------------------------------------------------------------
if [[ -z "${LOG_FILE:-}" ]]; then
    echo "[FATAL ERROR] LOG_FILE が未定義です。source 前に定義してください。" >&2
    exit 1
fi

# force-* ディレクトリ内でのみ実行を許可（mkdir-p より前に実行）
# SF_INIT_MODE=1 の場合はチェックをスキップする（force-* の外で動く sf-init.sh とその phases/init/・sf-job.sh・
# sf-typecheck.sh・tests/e2e/ が export する）
if [[ "${SF_INIT_MODE:-0}" != "1" ]]; then
    [[ "${PWD##*/}" =~ ^force- ]] \
        || { echo "[ERROR] このスクリプトは 'force-*' ディレクトリ内で実行してください。" >&2; exit 1; }  # 条件チェックのため run 不使用（run の定義前）
fi

# ログフォルダ（dirname の代わりに文字列の加工で求める。Windows の Git Bash は外部プログラムの起動が 1 回 約 60ms かかるため、
# 起動のたびに走るこの部分では、外部プログラムを起動しない。フォルダがあれば mkdir も省く。chmod は Windows では効果がないので省く）
case "$LOG_FILE" in
    */*) _sf_log_dir="${LOG_FILE%/*}"; _sf_log_dir="${_sf_log_dir:-/}" ;;
    *)   _sf_log_dir="." ;;
esac
[[ -d "$_sf_log_dir" ]] || mkdir -p "$_sf_log_dir"  # run 不使用: run の定義前（ログファイルのフォルダの準備）
case "${OSTYPE:-}" in
    msys*|cygwin*) ;;  # Windows では chmod は効果なし
    *) chmod 700 "$_sf_log_dir" 2>/dev/null || true ;;  # run 不使用: run の定義前・意図的エラー無視
esac
unset _sf_log_dir
[[ "${LOG_MODE:-}" == "NEW" ]] && : > "$LOG_FILE"  # run 不使用: run の定義前（ログファイルを空にする）

# SILENT_EXEC: --verbose / -v が指定されていれば 0（応答表示あり）、デフォルト 1（応答表示なし）
# ※ 各スクリプトで宣言不要。common.sh が $@ をスキャンして自動設定します。
_sf_verbose=0
for _sf_arg in "$@"; do
    [[ "$_sf_arg" == "--verbose" || "$_sf_arg" == "-v" ]] && _sf_verbose=1 && break
done
readonly SILENT_EXEC=$(( _sf_verbose ? 0 : 1 ))
unset _sf_verbose _sf_arg

# ------------------------------------------------------------------------------
# 4. カラー定義（標準入力・標準エラーのどちらも端末でないときは空文字にして、制御コードの混入を防ぐ）
# ------------------------------------------------------------------------------
if [ -t 0 ] || [ -t 2 ]; then
    readonly CLR_INFO='\033[36m'     # シアン    (情報・進行中)
    readonly CLR_SUCCESS='\033[32m'  # グリーン  (成功・完了)
    readonly CLR_WARNING='\033[33m'  # イエロー  (警告)
    readonly CLR_ERR='\033[31m'      # レッド    (エラー)
    readonly CLR_FATAL='\033[1;31m'  # 太字レッド (致命的エラー・即終了)
    readonly CLR_PROMPT='\033[35m'   # マゼンタ  (ユーザー入力要求)
    readonly CLR_RESET='\033[0m'     # リセット
else
    readonly CLR_INFO=''
    readonly CLR_SUCCESS=''
    readonly CLR_WARNING=''
    readonly CLR_ERR=''
    readonly CLR_FATAL=''
    readonly CLR_PROMPT=''
    readonly CLR_RESET=''
fi

# ------------------------------------------------------------------------------
# 5. show_help - --help / -h オプションの処理
# ------------------------------------------------------------------------------
# 呼び出し元スクリプト（show_help を呼んだファイル）の冒頭コメント（2つ目の === と 3つ目の === の間）を、
# 行頭の「# 」を除いて標準出力に出力し、exit 0 で終了する。
show_help() {
    local script="${BASH_SOURCE[1]}"
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "$script"  # run 不使用: ヘルプの表示（ログに残さない）
    exit 0
}

# ------------------------------------------------------------------------------
# 5b. reject_unknown_args - 不明なオプションの拒否
# ------------------------------------------------------------------------------
# 【使い方】
#   reject_unknown_args "$@"
#     -v / --verbose 以外の引数があれば、「不明なオプションです」で中断する（die）。
#     第 1 引数の -h / --help は、各スクリプトが common.sh を読み込む前に処理済みのため、ここには届かない。
#     2 番目以降の -h / --help も、不明なオプションとして扱う。
#   引数を受け付けないコマンド（-v / --verbose だけ受け付けるもの）の、解析の代わりに使う。
#   以前は、これらのコマンドが、不明な引数を黙って無視していた（綴りの誤りに気づけない）。
reject_unknown_args() {
    local a
    for a in "$@"; do
        case "$a" in
            -v|--verbose) ;;
            *) die "不明なオプションです: ${a}" ;;
        esac
    done
}

# ------------------------------------------------------------------------------
# 6. log - 画面とログファイルへの統合出力
# ------------------------------------------------------------------------------
# 【使い方】
#   log LEVEL MESSAGE [DEST]
#
# 【引数】
#   LEVEL   : 出力レベル（下記参照）
#   MESSAGE : 出力するメッセージ本文
#   DEST    : 出力先。省略時は BOTH。
#               BOTH   = 画面とログファイルの両方（デフォルト）
#               SCREEN = 画面のみ
#               FILE   = ログファイルのみ
#   画面への出力は、すべて標準エラー（命令置換の結果に混ざらない）。ログファイル（LOG_FILE）には、色なしで追記する。
#   戻り値は、常に RET_OK。
#
# 【LEVEL の種類と用途】
#   HEADER  : 処理ブロックの開始を区切り線つきで強調表示する
#   INFO    : 処理の進行状況を通知する（シアン）
#   SUCCESS : 処理の正常完了を通知する（グリーン）
#   WARNING : 問題があるが続行可能な状態を通知する（イエロー）
#   ERROR   : エラーが発生したが処理を続行する（レッド）
#   FATAL   : 致命的エラー。die() が使用する。即終了（太字レッド）
#   CMD     : run 関数が実行コマンドを記録するために使用する（色なし）
#   上記以外 : 画面には、メッセージだけを出す（ログファイルには [LEVEL] を付ける）
#
# 【使用例】
#   log "INFO"    "処理を開始します..."
#   log "SUCCESS" "完了しました。"
#   log "WARNING" "接続に失敗しました（続行します）"
#   log "ERROR"   "エラーが発生しました（続行します）"
#   log "HEADER"  "スタートアップを開始します"
# ------------------------------------------------------------------------------
log() {
    local level="$1" message="$2" dest="${3:-BOTH}"
    local ts
    _now_ts ts  # 時刻は、プロセスを起動せずに求める（_now_ts。date は、Windows の Git Bash では、1 回 約 65ms かかる）

    # A. ログファイル出力 (色コードなし)
    if [[ "$dest" == "BOTH" || "$dest" == "FILE" ]]; then
        if [[ "$level" == "HEADER" ]]; then
            printf "\n[%s] [=== %s ===]\n" "$ts" "$message" >> "$LOG_FILE"
        elif [[ "$level" == "CMD" ]]; then
            printf "[%s] [CMD] Command: %s\n" "$ts" "$message" >> "$LOG_FILE"
        else
            printf "[%s] [%s] %s\n" "$ts" "$level" "$message" >> "$LOG_FILE"
        fi
    fi

    # B. 画面出力 (色付き)
    if [[ "$dest" == "BOTH" || "$dest" == "SCREEN" ]]; then
        case "$level" in
            HEADER)
                echo "--------------------------------------------------------" >&2
                echo -e "${CLR_INFO}>> ${message}${CLR_RESET}" >&2
                echo "--------------------------------------------------------" >&2 ;;
            INFO)
                echo -e "${CLR_INFO}[INFO] ${message}${CLR_RESET}" >&2 ;;
            SUCCESS)
                echo -e "${CLR_SUCCESS}[SUCCESS] ${message}${CLR_RESET}" >&2 ;;
            WARNING)
                echo -e "${CLR_WARNING}[WARNING] ${message}${CLR_RESET}" >&2 ;;
            ERROR)
                echo -e "${CLR_ERR}[ERROR] ${message}${CLR_RESET}" >&2 ;;
            FATAL)
                echo -e "${CLR_FATAL}[FATAL] ${message}${CLR_RESET}" >&2 ;;
            CMD)
                echo "> Command: ${message}" >&2 ;;
            *)
                echo -e "${message}" >&2 ;;
        esac
    fi
    return $RET_OK
}

# _mask_secrets - 文字列中の Token らしい文字列を伏せ字にする（コマンドのログへの混入を防ぐ保険）
# ------------------------------------------------------------------------------
# 【使い方】
#   masked=$(_mask_secrets "$text")
#
# 【対象】
#   GitHub の Token（ghp_ / gho_ / ghu_ / ghs_ / ghr_ / github_pat_）と Slack の Token（xoxa- / xoxb- / xoxp- / xoxr- / xoxs-）
#   本来は Token をコマンドの引数に含めない（環境変数・標準入力・GIT_ASKPASS で渡す）。これは万一の保険。
#   run は、これを、コマンドの行（画面とログの CMD の行）と、error.log の見出しの行（コマンドを含む）に使う。
#   コマンドの出力（ログの [OUT] の行・error.log の本文）には、使っていない。
# ------------------------------------------------------------------------------
_mask_secrets() {
    printf '%s' "$1" | sed -E \
        -e 's/(gh[pousr]_)[A-Za-z0-9]+/\1***masked***/g' \
        -e 's/github_pat_[A-Za-z0-9_]+/github_pat_***masked***/g' \
        -e 's/(xox[abprs]-)[A-Za-z0-9-]+/\1***masked***/g'
}

# _mask_secrets_var - _mask_secrets の結果を、変数に入れる（run が、1 回ごとに呼ぶため、速くする）
# ------------------------------------------------------------------------------
# 【使い方】 _mask_secrets_var 出力変数名 文字列        （set_var で代入）
# 【理由】   $(_mask_secrets …) は、サブシェルと sed を、1 回ごとに起動する（Windows の Git Bash では、約 130ms）。
#           Token らしい文字列を含まない文字列（ほとんどすべて）は、そのまま返す。含むときだけ、_mask_secrets（sed）を使う。
#           この判定は、_mask_secrets の 3 つの置換が、必ず含む文字列（gh?_・github_pat_・xox?-）と同じ（含まなければ、置換は起きない）
# ------------------------------------------------------------------------------
_mask_secrets_var() {
    local _ms_text="$2"
    case "$_ms_text" in
        *gh[pousr]_*|*github_pat_*|*xox[abprs]-*) _ms_text=$(_mask_secrets "$_ms_text") ;;  # VAR=$(cmd) のため run 不使用（Token らしい文字列を含むときだけ）
    esac
    set_var "$1" "$_ms_text"
}

# _now_ts - 現在の時刻（YYYY-MM-DD HH:MM:SS）を、変数に入れる
# ------------------------------------------------------------------------------
# 【使い方】 _now_ts 出力変数名                          （set_var は使わない: log が、1 回ごとに呼ぶため）
# 【理由】   date は、プロセスの起動が遅い Windows の Git Bash で、1 回 約 65ms かかる。Bash 4.2 以上の printf '%(...)T' は、
#           組み込みで、プロセスを起動しない。Bash 3.2（macOS 標準）には、これがないため、date を使う（起動時に、どちらかを定義する）
# 【注意】   呼び出し元の関数に、同じ名前の local 変数があると、そちらに代入される（set_var と同じ。名前の衝突に注意）
# ------------------------------------------------------------------------------
if (( BASH_VERSINFO[0] > 4 || ( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 2 ) )); then
    _now_ts() { printf -v "$1" '%(%Y-%m-%d %H:%M:%S)T' -1; }
else
    _now_ts() { printf -v "$1" '%s' "$(date +'%Y-%m-%d %H:%M:%S')"; }  # VAR=$(cmd) のため run 不使用（Bash 3.2: 組み込みの時刻の書式がない）
fi

# ------------------------------------------------------------------------------
# 端末の制御コードの除去（標準入力 → 標準出力。GNU / BSD の sed の、どちらでも動く）
#   BSD の sed（macOS）は、\x1b のような 16 進の表記を解釈しない。そのため、Bash が、実際の文字に展開してから、sed に渡す。
#   LC_ALL=C により、. が任意の 1 バイトにマッチする（日本語は 0xe3〜0xe9 始まりのため、除去の対象外）。
#   _strip_ansi        : ANSI エスケープコード（色・カーソル操作）だけを除く
#   _strip_term_codes  : 上に加えて、絵文字を除く（0xf0 + 3 バイト = U+10000 以降 / 0xe2 + 2 バイト = U+2000〜U+2FFF /
#                        異体字セレクタ U+FE0F = 0xef 0xb8 0x8f）。U+2000〜U+2FFF には、絵文字以外の記号（… — → ✓ ═ など）
#                        も含まれ、それらも除かれる
# ------------------------------------------------------------------------------
_strip_ansi() {
    local esc=$'\033'
    LC_ALL=C sed "s/${esc}\[[0-9;?]*[a-zA-Z]//g"
}
_strip_term_codes() {
    local esc=$'\033' b_f0=$'\xf0' b_e2=$'\xe2' b_ef=$'\xef' b_b8=$'\xb8' b_8f=$'\x8f'
    LC_ALL=C sed "s/${esc}\[[0-9;?]*[a-zA-Z]//g; s/${b_f0}...//g; s/${b_e2}..//g; s/${b_ef}${b_b8}${b_8f}//g"
}

# _has_term_codes - 本文に、_strip_term_codes が除くものが、ありうるか（ESC・絵文字の先頭のバイトを含むか）
# ------------------------------------------------------------------------------
# 【使い方】 _has_term_codes 本文        戻り値 0 = ありうる（sed で除く） / 1 = ない（そのまま記録してよい）
# 【判定】   ESC（0x1b）・0xf0・0xe2・0xef のバイトを含むか。_strip_term_codes の 4 つの置換が、必ず含むバイトと同じ
#           （含まなければ、置換は起きない）。0xe2・0xef は、… — → や全角の記号の先頭でもあるため、含むときは、除かれない文字
#           だけでも「ありうる」と判定する（sed に回るだけで、結果は同じ）
# 【注意】   バイトで比べるため、local LC_ALL=C にする（UTF-8 のままでは、文字の途中のバイトに、一致しない）
# ------------------------------------------------------------------------------
_has_term_codes() {
    local LC_ALL=C
    [[ "$1" == *$'\033'* || "$1" == *$'\xf0'* || "$1" == *$'\xe2'* || "$1" == *$'\xef'* ]]
}

# _prefix_lines - 標準入力の各行に、接頭辞を付けて、標準出力へ出す（空行には付けない。空行は、そのまま出す）
# ------------------------------------------------------------------------------
# 【使い方】 _prefix_lines 接頭辞 < ファイル
# 【理由】   sed "/./s/^/接頭辞/" と同じ結果を、プロセスを起動せずに得る（組み込みの read と printf だけ）。
#           最後の行に改行がなくても、改行を付けて出す（sed は、GNU 版は付けず、BSD 版は付ける。付けないと、次のログが、同じ行に続く）
# ------------------------------------------------------------------------------
_prefix_lines() {
    local _pl_prefix="$1" _pl_line
    while IFS= read -r _pl_line || [[ -n "$_pl_line" ]]; do
        if [[ -n "$_pl_line" ]]; then
            printf '%s%s\n' "$_pl_prefix" "$_pl_line"
        else
            printf '\n'
        fi
    done
}

# ------------------------------------------------------------------------------
# 6b. run - コマンド実行ラッパー（通常呼び出し・命令置換の両対応）
# ------------------------------------------------------------------------------
# 【使い方】
#   run CMD [ARGS...]           # 通常呼び出し
#   VAR=$(run CMD [ARGS...])    # 命令置換（出力を変数に受け取る）
#
# 【引数】
#   CMD     : 実行するコマンド
#   ARGS... : コマンドに渡す引数
#
# 【戻り値】
#   RET_OK        (0) : 成功
#   RET_NO_CHANGE (2) : 変更なし（NothingToDeploy / No local changes to deploy）
#   RET_NG        (1) : 失敗
#
# 【命令置換での自動判定】
#   stdout が端末でない場合（命令置換 $(...) 内・パイプ・ファイルへのリダイレクト）は、コマンドの出力
#   （標準エラーを含む）を、標準出力に返します。stdout が端末のときは、返しません。この切り替えは自動で行われます。
#   命令置換内でも CMD ログ行（> Command: ...）はコンソール（標準エラー）に表示されます。
#   例: VAR=$(run git symbolic-ref --short HEAD)
#
# 【SILENT_EXEC の挙動】
#   Command行（> Command: ...）は SILENT_EXEC の値にかかわらず常にコンソールへ表示します。
#   SILENT_EXEC=1 : コマンドの応答（出力）をログファイルのみに記録（コンソールには表示しない）【デフォルト】
#   SILENT_EXEC=0 : コマンドの応答（出力）をコンソール（標準エラー）とログファイルの両方に表示（--verbose / -v で有効）
#                   （1 以外の値・未定義も、0 と同じ扱い）
#
# 【ログファイルへの出力】
#   コマンド出力に含まれる ANSI エスケープコードおよび絵文字を除去してから記録します。
#   各行には "[timestamp] [OUT]" のプレフィックスを付与します（空行には付けない）。
#   失敗（RET_NG）のときは、LOG_FILE と同じフォルダの error.log にも、見出しの行とコマンドの出力を追記します
#   （見出しの行のコマンドは、_mask_secrets で伏せ字にする。コマンドの出力は、伏せ字にしない）。
#   出力は、一時ファイル（${TMPDIR:-/tmp} の下の cmd_out.*）に受けてから処理し、最後に削除します。
#   色・絵文字を含まない出力（ほとんどすべて）は、sed を起動せず、組み込みの read で記録します（_prefix_lines）。
#   最後の行に改行がない出力も、改行を付けて記録します（次のログが、同じ行に続かないように）。
#
# 【成功判定のルール】
#   終了コードが 0 であれば成功とします（終了コードのみを信頼する。出力の文字列では判定しない）。
#   ただし、出力に NothingToDeploy / "No local changes to deploy" が含まれる場合は RET_NO_CHANGE とします
#   （終了コードより優先）。
#   ※ 以前は出力の成功キーワード（"Successfully" 等）でも RET_OK にしていたが、失敗を成功と誤判定する
#     恐れがあるため削除した（2026-03-24）。
#   ※ Salesforce CLI が、成功しても終了コード 1 を返す環境（Windows の Git Bash で、公式インストーラー版を
#     自動更新した場合）では、終了コードに頼る処理が失敗扱いになる。そのため sf-tools は Salesforce CLI の
#     npm 版を前提とし、sf-init.sh / sf-start.sh / sf-release.sh / sf-metasync.sh / sf-update-secret.sh / sf-typecheck.sh の
#     最初に check_sf_cli で確認する（NG なら中断。sf-install.sh だけは警告のみ）。sf の成否は、すべて終了コードで判定する。
#
# 【使用例】
#   run bash "./sf-install.sh"                      || die "失敗"
#   run mkdir -p "release/${BRANCH_NAME}"           || return $RET_NG
#   run sf org login web --set-default --alias "$A" || die "失敗"
#   printf '{"target-org": "%s"}\n' "$A" | run tee .sf/config.json
#   BRANCH=$(run git symbolic-ref --short HEAD)
#   JSON=$(run sf org display --json)               # 失敗しても、エラーの文言が標準出力に混ざる。成否は、終了コードで見ること
# ------------------------------------------------------------------------------
run() {
    local cmd=("$@")
    # git add -A との競合を避けるため、プロジェクト内ディレクトリは使わずシステム tmp を使用
    local _run_tmpdir="${TMPDIR:-/tmp}"
    local tmp_out
    tmp_out=$(mktemp "${_run_tmpdir}/cmd_out.XXXXXX") \
        || tmp_out="${_run_tmpdir}/cmd_out_$$_${RANDOM}.tmp"  # run 不使用: 変数代入・mktemp フォールバック
    local status

    local _run_masked
    _mask_secrets_var _run_masked "${cmd[*]}"
    log "CMD" "[${SCRIPT_NAME}.sh] ${_run_masked}"

    if [[ "${SILENT_EXEC:-}" != "1" ]]; then
        # リアルタイム表示: stderr に流しつつ tmp に保存（命令置換の stdout には影響しない）
        "${cmd[@]}" 2>&1 | tee "$tmp_out" >&2
        status="${PIPESTATUS[0]}"
    else
        "${cmd[@]}" > "$tmp_out" 2>&1
        status=$?
    fi

    # stdout が端末でない（命令置換 $(...)・パイプ・リダイレクト）ときは、出力を返す
    if [[ ! -t 1 ]]; then
        cat "$tmp_out"
    fi

    local is_success=$RET_NG
    # 出力の全文を、組み込みの read で読む（grep を起動しない。Windows の Git Bash では、1 回 約 65ms かかる）。
    #   read は、区切り（NUL）を見つけたときだけ成功を返す。NUL がなければ、最後まで読んで、失敗を返す（読めた分は、入っている）。
    #   NUL を含む出力は、全文を読めないため、従来どおり grep を使う
    local _run_text="" _run_nul=0 _run_nothing=0
    IFS= read -r -d '' _run_text < "$tmp_out" && _run_nul=1
    if [[ "$_run_nul" -eq 0 ]]; then
        [[ "$_run_text" == *NothingToDeploy* || "$_run_text" == *"No local changes to deploy"* ]] && _run_nothing=1
    elif grep -qE "NothingToDeploy|No local changes to deploy" "$tmp_out"; then  # 条件チェックのため run 不使用（NUL を含む出力だけ）
        _run_nothing=1
    fi
    # A. 変更なし（NothingToDeploy）の検知（終了コードより優先）
    if [[ "$_run_nothing" -eq 1 ]]; then
        log "WARNING" "組織との差分が検出されませんでした (NothingToDeploy)。ローカルのソースはすでに組織と一致しています。"
        is_success=$RET_NO_CHANGE
    # B. 成功判定（終了コードのみを信頼する）
    elif [[ $status -eq 0 ]]; then
        is_success=$RET_OK
    fi

    local log_ts
    _now_ts log_ts  # 時刻は、プロセスを起動せずに求める（_now_ts）
    # ANSI エスケープコード・絵文字を除去してから記録（_strip_term_codes（上）が除く）。
    #   除去するものがない出力（ほとんどすべて）は、sed を起動せず、組み込みの read で、行ごとに記録する（_prefix_lines）。
    #   NUL を含む出力と、除去するものがありうる出力（ESC・絵文字の先頭のバイトを含む）は、従来どおり sed を使う
    local _run_plain=0
    if [[ "$_run_nul" -eq 0 ]] && ! _has_term_codes "$_run_text"; then _run_plain=1; fi
    if [[ "$_run_plain" -eq 1 ]]; then
        _prefix_lines "[${log_ts}] [OUT] " < "$tmp_out" >> "$LOG_FILE"
    else
        _strip_term_codes < "$tmp_out" | sed "/./s/^/[${log_ts}] [OUT] /" >> "$LOG_FILE"
    fi

    # 失敗時は error.log にも記録（前回エラーとの区切りが明確になるよう都度追記）
    if [[ $is_success -eq $RET_NG ]] && [[ -n "${LOG_FILE:-}" ]]; then
        local err_log
        err_log="$(dirname "$LOG_FILE")/error.log"  # VAR=$(cmd) のため run 不使用（失敗したときだけ）
        {
            echo "====== [${log_ts}] ERROR: [${SCRIPT_NAME}] ${_run_masked} ======"
            if [[ "$_run_plain" -eq 1 ]]; then
                _prefix_lines "  " < "$tmp_out"
            else
                _strip_term_codes < "$tmp_out" | sed "/./s/^/  /"
            fi
        } >> "$err_log"
    fi

    rm -f "$tmp_out"
    return $is_success
}

# ------------------------------------------------------------------------------
# 7. Git フック共通定数
# ------------------------------------------------------------------------------
# sf-hook.sh が .git/hooks/ にコピーするラッパー（hooks/pre-push・hooks/pre-commit）に書かれている識別マーカー。
# sf-unhook.sh は、このマーカーで「sf-tools が管理するフックか」を判定してから、.git/hooks/pre-push を削除する。
readonly SF_HOOK_MARKER="# Generated by sf-tools: wrapper for pre-push hook"

# ------------------------------------------------------------------------------
# 8. die - 致命的エラーログを出力して終了
# ------------------------------------------------------------------------------
# 【使い方】
#   die MESSAGE [EXIT_CODE]
#
# 【引数】
#   MESSAGE   : エラーメッセージ（ログレベル FATAL で出力される）
#   EXIT_CODE : 終了コード。省略時は RET_NG (1)。
#
#   メッセージは、log FATAL で、画面（標準エラー）とログファイルに出す。
#   命令置換 $(...) の中で呼ぶと、終了するのは、そのサブシェルだけ（呼び出し側は、戻り値で判定する）。
#
# 【使用例】
#   check_force_dir || die "force-* ディレクトリ内で実行してください。"
#   run sf org login web ... || die "ログインに失敗しました。"
# ------------------------------------------------------------------------------
die() {
    log "FATAL" "$1"
    exit "${2:-$RET_NG}"
}

# ------------------------------------------------------------------------------
# print_admin_warning - 管理者向けの警告ボックス（赤）を、標準エラーに表示する（CLAUDE.md 2.4）
# ------------------------------------------------------------------------------
# 管理者向けのコマンドは、最初に、この警告を出す。ボックスの形を、1 か所にまとめ、書き写しによるずれをなくすための部品。
# 確認（ask_yn / wizard_confirm）は、含まない。呼び出し側が、続けて呼ぶ。
#
# 【使い方】
#   print_admin_warning --standard "GitHub Secrets を更新します。" "誤った値を設定すると CI/CD が停止します。"
#   print_admin_warning "!!  実際に、組織へリリースして、削除します" "    管理者以外は、実行しないでください"
#     --standard : 先頭に「このコマンドは管理者専用です / 管理者以外は絶対に実行しないでください」を付ける
#                  （続く行があれば、空行を 1 つ挟む）
#     行         : 1 引数 = 1 行。空文字は、空行。左に空白 2 つの余白を付ける
#                  （見出しは「!!  」で始め、続きの行は、空白 4 つで、そろえる）
#   幅は、表示の幅（全角 2・半角 1）で、そろえる（日本語は、UTF-8 の 3 バイト = 全角 1 文字として数える）。
#   枠の内側の幅は 54。これを超える行は、切り詰めず、右の枠がずれる。
#   _display_width 文字列 : 上の数え方で、表示の幅を標準出力に返す（print_admin_warning の内部用）
# ------------------------------------------------------------------------------
_display_width() {
    # locale に依存しないよう、サブシェルの中で LC_ALL=C にして、バイト数で数える
    (
        LC_ALL=C
        s="$1"
        a="${s//[! -~]/}"      # ASCII（空白〜~）だけを残す
        echo $(( ${#a} + ( (${#s} - ${#a}) / 3 ) * 2 ))
    )
}

print_admin_warning() {
    local inner=54 line w pad bar="" i
    local lines=()
    if [[ "${1:-}" == "--standard" ]]; then
        shift
        lines+=("!!  このコマンドは管理者専用です" "    管理者以外は絶対に実行しないでください")
        [[ $# -gt 0 ]] && lines+=("")
    fi
    while [[ $# -gt 0 ]]; do lines+=("$1"); shift; done
    for (( i = 0; i < inner; i++ )); do bar="${bar}═"; done
    echo -e "${CLR_ERR}╔${bar}╗${CLR_RESET}" >&2
    for line in ${lines[@]+"${lines[@]}"}; do
        line="  ${line}"
        w=$(_display_width "$line")  # VAR=$(cmd) のため run 不使用
        pad=$(( inner - w ))
        [[ $pad -lt 0 ]] && pad=0
        printf "${CLR_ERR}║%s%*s║${CLR_RESET}\n" "$line" "$pad" "" >&2
    done
    echo -e "${CLR_ERR}╚${bar}╝${CLR_RESET}" >&2
}

# ------------------------------------------------------------------------------
# 9. ユーティリティ関数（JSON の読み取り）と、project.sh が使う定数
# ------------------------------------------------------------------------------

# json_get - JSON 文字列から値を取り出す（Node の標準機能のみ。jq は使わない）
# ------------------------------------------------------------------------------
# 【使い方】
#   VALS=$(json_get "$JSON" パス...) || 失敗時の処理
#   while IFS= read -r L; do V+=("$L"); done <<< "$VALS"   # 複数のパスは 1 回で取り、行ごとに配列へ（Node の起動を 1 回にするため。
#                                                           #   mapfile は Bash 4 以降のため使わない。例: org.sh の org_parse_info）
#
# 【パス】 「.」区切り（配列の要素は数字）。例: result.records.0.Id / result.alias。先頭の「.」は、あってもよい
#          「*」は、配列（またはオブジェクト）の全要素に展開する。例: result.*.alias → 要素ごとに 1 行
#          （要素に、そのキーがなければ、その要素の行は空行。要素の数と、行の数が、そろう。
#           「*」の位置の値が、配列・オブジェクトでない（ない・null を含む）ときは、そのパスの行は 1 行も出ない）
# 【出力】 パス 1 つにつき 1 行（「*」があれば、要素の数だけ）。値がなければ空行。オブジェクト・配列は JSON 文字列。
#          値の中の改行は、空白 1 つにする
# 【戻り値】 0 = 読み取れた / 1 = JSON として読み取れなかった・node がない（node がないときは、ERROR を表示する）
# 【備考】
#   ・GitHub の情報は、gh の --jq で読む（これは使わない）。これは、sf CLI の出力（sf ... --json）など、gh が読めない JSON 用
#   ・JSON は、まず全体を厳密に読む。失敗したときだけ、最初の { から最後の } までを読む
#     （run は標準エラーも標準出力に混ぜるため、sf の警告が、JSON の前後に付くことがある）
#   ・node は、sf CLI（npm 版）の前提のため、すでにある。追加のパッケージは使わない
# ------------------------------------------------------------------------------
json_get() {
    local json="$1"
    shift
    if ! command -v node > /dev/null 2>&1; then  # 存在確認のため run 不使用
        log "ERROR" "node が見つかりません（JSON の読み取りに必要です。sf CLI は npm 版が前提のため、Node は、通常あります）。"
        return 1
    fi
    # run 不使用: 値の抽出のみ（結果を、標準出力に、そのまま返す）
    printf '%s' "$json" | node -e '
        let s = "";
        process.stdin.setEncoding("utf8");
        process.stdin.on("data", d => s += d).on("end", () => {
            let o;
            try { o = JSON.parse(s); }
            catch (e) {
                try { o = JSON.parse(s.slice(s.indexOf("{"), s.lastIndexOf("}") + 1)); }
                catch (e2) { process.exit(1); }
            }
            const walk = (v, ks) => {
                if (ks.length === 0) return [v];
                const k = ks[0], rest = ks.slice(1);
                if (k === "*") {
                    const arr = Array.isArray(v) ? v : (v !== null && typeof v === "object" ? Object.values(v) : []);
                    return arr.flatMap(x => walk(x, rest));
                }
                return v == null ? [undefined] : walk(v[k], rest);
            };
            for (const p of process.argv.slice(1)) {
                for (const v of walk(o, p.replace(/^\./, "").split("."))) {
                    const t = v == null ? "" : (typeof v === "object" ? JSON.stringify(v) : String(v));
                    console.log(t.replace(/\r?\n/g, " "));
                }
            }
        });' -- "$@"
}

# BRANCH_LIST_FILE - ブランチ構成ファイルのパス（カレントディレクトリ = force-* からの相対パス）
#   get_branch_list / is_protected_branch（project.sh）が読む。関数の説明は、project.sh を参照。
readonly BRANCH_LIST_FILE="sf-tools/config/branches.txt"

# SF_RESERVED_ORG_ALIASES - 共有環境の組織エイリアス（sf-tools の予約名。空白区切り）
#   is_reserved_org_alias（project.sh）が使う。背景・使い方は、project.sh を参照。
readonly SF_RESERVED_ORG_ALIASES="prod staging develop main"

# ------------------------------------------------------------------------------
# 10. 責務ごとのファイル（ここから読み込む。呼び出し側は、common.sh だけを source すればよい）
#   input.sh     ... 対話入力（read_input / read_key / press_enter / read_or_quit / read_secret / ask_yn）
#   platform.sh  ... OS・外部コマンド（is_gitbash / set_var / sed_inplace / base64_oneline / run_with_timeout /
#                    run_isolated_home / check_sf_cli / open_browser）
#   project.sh   ... プロジェクト（force-*・GitHub・組織・ブランチ）。関数の一覧は、project.sh の冒頭
#   読み込みの順は input.sh → platform.sh → project.sh（関数は、呼ばれる時点で定義済みであればよい。
#   input.sh の read_or_quit などが使う set_var は、platform.sh にある）
# ------------------------------------------------------------------------------
_COMMON_LIB_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_COMMON_LIB_DIR/" == /* && "$_COMMON_LIB_DIR/" != *//* && "$_COMMON_LIB_DIR/" != */./* && "$_COMMON_LIB_DIR/" != */../* ]] || _COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_COMMON_LIB_DIR}/input.sh"
source "${_COMMON_LIB_DIR}/platform.sh"
source "${_COMMON_LIB_DIR}/project.sh"
