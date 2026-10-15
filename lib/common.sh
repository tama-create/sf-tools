#!/bin/bash
# ==============================================================================
# common.sh - sf-tools 共通関数ライブラリ
# ==============================================================================
# sf-tools の全スクリプトが source して使用する共通ライブラリです。
#
# 【source 前に必須の変数定義】
#   readonly SCRIPT_NAME=...   スクリプト名（拡張子なし）
#   readonly LOG_FILE=...      ログファイルパス（例: ./logs/${SCRIPT_NAME}.log）
#   readonly LOG_MODE=...      NEW=実行ごとにリセット / APPEND=追記
#   ※ SILENT_EXEC は source 後に自動設定されます（--verbose / -v オプションで制御）
#
# 【提供する関数】
#   log LEVEL MESSAGE [DEST]  ... 画面とログファイルへ出力
#   run CMD [ARGS...]         ... コマンドを実行してログに記録
#   die MESSAGE [EXIT_CODE]   ... エラーログを出力して終了
#   print_admin_warning [--standard] [行...] ... 管理者向けの警告ボックス（赤）を表示する（確認は、含まない）
#   json_get JSON パス...     ... JSON から値を取り出す（Node の標準機能のみ。sf CLI の出力など）
#
#   以下は、責務ごとのファイルに分けてあり、この common.sh が source する（呼び出し側は、common.sh だけでよい）:
#   project.sh   ... get_target_org / check_force_dir / check_home_dir / check_gh_owner / get_branch_list /
#                    is_reserved_org_alias / is_protected_branch / ensure_sf_tools_latest
#   platform.sh  ... is_gitbash / run_isolated_home / check_sf_cli / open_browser
#   input.sh     ... read_input / read_key / press_enter / read_or_quit / read_secret / ask_yn
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
# SF_INIT_MODE=1 の場合は sf-init.sh による初期化実行のためチェックをスキップする
if [[ "${SF_INIT_MODE:-0}" != "1" ]]; then
    [[ "$(basename "$PWD")" =~ ^force- ]] \
        || { echo "[ERROR] このスクリプトは 'force-*' ディレクトリ内で実行してください。" >&2; exit 1; }
fi

mkdir -p "$(dirname "$LOG_FILE")"
chmod 700 "$(dirname "$LOG_FILE")" 2>/dev/null || true  # run 不使用: Windows では効果なし・意図的エラー無視
[[ "${LOG_MODE:-}" == "NEW" ]] && : > "$LOG_FILE"

# SILENT_EXEC: --verbose / -v が指定されていれば 0（応答表示あり）、デフォルト 1（応答表示なし）
# ※ 各スクリプトで宣言不要。common.sh が $@ をスキャンして自動設定します。
_sf_verbose=0
for _sf_arg in "$@"; do
    [[ "$_sf_arg" == "--verbose" || "$_sf_arg" == "-v" ]] && _sf_verbose=1 && break
done
readonly SILENT_EXEC=$(( _sf_verbose ? 0 : 1 ))
unset _sf_verbose _sf_arg

# ------------------------------------------------------------------------------
# 4. カラー定義（端末非対応環境では空文字に設定して制御コードの混入を防ぐ）
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
# 呼び出し元スクリプトの冒頭コメント（2つ目の === と 3つ目の === の間）を
# 画面に出力して終了する。
show_help() {
    local script="${BASH_SOURCE[1]}"
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "$script"
    exit 0
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
#
# 【LEVEL の種類と用途】
#   HEADER  : 処理ブロックの開始を区切り線つきで強調表示する
#   INFO    : 処理の進行状況を通知する（シアン）
#   SUCCESS : 処理の正常完了を通知する（グリーン）
#   WARNING : 問題があるが続行可能な状態を通知する（イエロー）
#   ERROR   : エラーが発生したが処理を続行する（レッド）
#   FATAL   : 致命的エラー。die() が使用する。即終了（太字レッド）
#   CMD     : run 関数が実行コマンドを記録するために使用する（色なし）
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
    ts=$(date +'%Y-%m-%d %H:%M:%S')

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
#   GitHub の Token（ghp_ / gho_ / ghu_ / ghs_ / ghr_ / github_pat_）と Slack の Token（xoxb- 等）
#   本来は Token をコマンドの引数に含めない（環境変数・標準入力・GIT_ASKPASS で渡す）。これは万一の保険。
# ------------------------------------------------------------------------------
_mask_secrets() {
    printf '%s' "$1" | sed -E \
        -e 's/(gh[pousr]_)[A-Za-z0-9]+/\1***masked***/g' \
        -e 's/github_pat_[A-Za-z0-9_]+/github_pat_***masked***/g' \
        -e 's/(xox[abprs]-)[A-Za-z0-9-]+/\1***masked***/g'
}

# ------------------------------------------------------------------------------
# 端末の制御コードの除去（標準入力 → 標準出力。GNU / BSD の sed の、どちらでも動く）
#   BSD の sed（macOS）は、\x1b のような 16 進の表記を解釈しない。そのため、Bash が、実際の文字に展開してから、sed に渡す。
#   LC_ALL=C により、. が任意の 1 バイトにマッチする（日本語は 0xe3〜0xe9 始まりのため、除去の対象外）。
#   _strip_ansi        : ANSI エスケープコード（色・カーソル操作）だけを除く
#   _strip_term_codes  : 上に加えて、絵文字を除く（0xf0 + 3 バイト = U+10000 以降 / 0xe2 + 2 バイト = U+2000〜U+2FFF /
#                        異体字セレクタ U+FE0F = 0xef 0xb8 0x8f）
# ------------------------------------------------------------------------------
_strip_ansi() {
    local esc=$'\033'
    LC_ALL=C sed "s/${esc}\[[0-9;?]*[a-zA-Z]//g"
}
_strip_term_codes() {
    local esc=$'\033' b_f0=$'\xf0' b_e2=$'\xe2' b_ef=$'\xef' b_b8=$'\xb8' b_8f=$'\x8f'
    LC_ALL=C sed "s/${esc}\[[0-9;?]*[a-zA-Z]//g; s/${b_f0}...//g; s/${b_e2}..//g; s/${b_ef}${b_b8}${b_8f}//g"
}

# ------------------------------------------------------------------------------
# 6. run - コマンド実行ラッパー（通常呼び出し・命令置換の両対応）
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
#   stdout が端末でない場合（命令置換 $(...) 内）は出力を自動的に返します。
#   通常呼び出し時は出力を返しません。この切り替えは自動で行われます。
#   命令置換内でも CMD ログ行（> Command: ...）はコンソールに表示されます。
#   例: VAR=$(run git symbolic-ref --short HEAD)
#
# 【SILENT_EXEC の挙動】
#   Command行（> Command: ...）は SILENT_EXEC の値にかかわらず常にコンソールへ表示します。
#   SILENT_EXEC=1 : コマンドの応答（出力）をログファイルのみに記録（コンソールには表示しない）【デフォルト】
#   SILENT_EXEC=0 : コマンドの応答（出力）をコンソールとログファイルの両方に表示（--verbose / -v で有効）
#
# 【ログファイルへの出力】
#   コマンド出力に含まれる ANSI エスケープコードおよび絵文字を除去してから記録します。
#   各行には "[timestamp] [OUT]" のプレフィックスを付与します（空行は除く）。
#
# 【成功判定のルール】
#   終了コードが 0 であれば成功とします（終了コードのみを信頼する。出力の文字列では判定しない）。
#   ただし、出力に NothingToDeploy / "No local changes to deploy" が含まれる場合は RET_NO_CHANGE とします
#   （終了コードより優先）。
#   ※ 以前は出力の成功キーワード（"Successfully" 等）でも RET_OK にしていたが、失敗を成功と誤判定する
#     恐れがあるため削除した（2026-03-24）。
#   ※ Salesforce CLI が、成功しても終了コード 1 を返す環境（Windows の Git Bash で、公式インストーラー版を
#     自動更新した場合）では、終了コードに頼る処理が失敗扱いになる。そのため sf-tools は Salesforce CLI の
#     npm 版を前提とし、sf-init.sh / sf-start.sh / sf-release.sh / sf-metasync.sh / sf-update-secret.sh の
#     最初に check_sf_cli で確認する（NG なら中断。sf-install.sh だけは警告のみ）。sf の成否は、すべて終了コードで判定する。
#
# 【使用例】
#   run bash "./sf-install.sh"                      || die "失敗"
#   run mkdir -p "release/${BRANCH_NAME}"           || return $RET_NG
#   run sf org login web --set-default --alias "$A" || die "失敗"
#   printf '{"target-org": "%s"}\n' "$A" | run tee .sf/config.json
#   BRANCH=$(run git symbolic-ref --short HEAD)
#   JSON=$(run sf org display --json || echo "")
# ------------------------------------------------------------------------------
run() {
    local cmd=("$@")
    # git add -A との競合を避けるため、プロジェクト内ディレクトリは使わずシステム tmp を使用
    local _run_tmpdir="${TMPDIR:-/tmp}"
    local tmp_out
    tmp_out=$(mktemp "${_run_tmpdir}/cmd_out.XXXXXX") \
        || tmp_out="${_run_tmpdir}/cmd_out_$$_${RANDOM}.tmp"  # run 不使用: 変数代入・mktemp フォールバック
    local status

    log "CMD" "[${SCRIPT_NAME}.sh] $(_mask_secrets "${cmd[*]}")"

    if [[ "${SILENT_EXEC:-}" != "1" ]]; then
        # リアルタイム表示: stderr に流しつつ tmp に保存（命令置換の stdout には影響しない）
        "${cmd[@]}" 2>&1 | tee "$tmp_out" >&2
        status="${PIPESTATUS[0]}"
    else
        "${cmd[@]}" > "$tmp_out" 2>&1
        status=$?
    fi

    # 命令置換 $(...) 内の場合（stdout が端末でない）は出力を返す
    if [[ ! -t 1 ]]; then
        cat "$tmp_out"
    fi

    local is_success=$RET_NG
    # A. 変更なし（NothingToDeploy）の検知（終了コードより優先）
    if grep -qE "NothingToDeploy|No local changes to deploy" "$tmp_out"; then
        log "WARNING" "組織との差分が検出されませんでした (NothingToDeploy)。ローカルのソースはすでに組織と一致しています。"
        is_success=$RET_NO_CHANGE
    # B. 成功判定（終了コードのみを信頼する）
    elif [[ $status -eq 0 ]]; then
        is_success=$RET_OK
    fi

    local log_ts
    log_ts=$(date +'%Y-%m-%d %H:%M:%S')
    # ANSI エスケープコード・絵文字を除去してから記録
    # _strip_term_codes（上）が、ANSI エスケープコード・絵文字を除く
    _strip_term_codes < "$tmp_out" | sed "/./s/^/[${log_ts}] [OUT] /" >> "$LOG_FILE"

    # 失敗時は error.log にも記録（前回エラーとの区切りが明確になるよう都度追記）
    if [[ $is_success -eq $RET_NG ]] && [[ -n "${LOG_FILE:-}" ]]; then
        local err_log
        err_log="$(dirname "$LOG_FILE")/error.log"
        {
            echo "====== [${log_ts}] ERROR: [${SCRIPT_NAME}] ${cmd[*]} ======"
            _strip_term_codes < "$tmp_out" | sed "/./s/^/  /"
        } >> "$err_log"
    fi

    rm -f "$tmp_out"
    return $is_success
}

# ------------------------------------------------------------------------------
# 7. Git フック共通定数
# ------------------------------------------------------------------------------
# sf-hook.sh が生成するラッパーファイルの識別マーカー。
# sf-unhook.sh はこのマーカーで「sf-tools が管理するフックか」を判定してから削除する。
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
# 9. ユーティリティ関数（JSON の読み取り）と、責務ごとのファイルの読み込み
# ------------------------------------------------------------------------------

# json_get - JSON 文字列から値を取り出す（Node の標準機能のみ。jq は使わない）
# ------------------------------------------------------------------------------
# 【使い方】
#   VALS=$(json_get "$JSON" パス...) || 失敗時の処理
#   mapfile -t V <<< "$VALS"          # 複数のパスは 1 回で取り、行ごとに配列へ（Node の起動を 1 回にするため）
#
# 【パス】 「.」区切り（配列の要素は数字）。例: result.records.0.Id / result.alias。先頭の「.」は、あってもよい
#          「*」は、配列（またはオブジェクト）の全要素に展開する。例: result.*.alias → 要素ごとに 1 行
#          （要素に、そのキーがなければ、その要素の行は空行。要素の数と、行の数が、そろう）
# 【出力】 パス 1 つにつき 1 行（「*」があれば、要素の数だけ）。値がなければ空行。オブジェクト・配列は JSON 文字列。
#          値の中の改行は、空白 1 つにする
# 【戻り値】 0 = 読み取れた / 1 = JSON として読み取れなかった・node がない
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

# get_branch_list - branches.txt からブランチ一覧を取得して echo する
# ------------------------------------------------------------------------------
# 【使い方】
#   branches=$(get_branch_list)
#
# 【ファイル参照先】
#   sf-tools/config/branches.txt（プロジェクト内）
#
# 【戻り値】
#   RET_OK (0) : ブランチ一覧を echo して正常終了（main が含まれない場合も WARNING）
#   RET_NG (1) : ファイルが存在しない場合
# ------------------------------------------------------------------------------
readonly BRANCH_LIST_FILE="sf-tools/config/branches.txt"

# is_reserved_org_alias - 共有環境の組織エイリアス（sf-tools の予約名）かを返す
# ------------------------------------------------------------------------------
# 【背景】
#   共有環境（main・staging・develop）へのリリースは、ローカルの PC からはできない。
#   GitHub にコミットし、レビューを通して、GitHub Actions で行う。
#   sf-init は、組織のエイリアスとして prod / staging / develop を付ける（prod は main の組織のエイリアス名。組織の種類は、問わない）。
#   この名前を予約名とし、ローカルからのリリースを禁止する（sf-release.sh / sf-deploy.sh）。
#   main は、ブランチ名と同じ名前（互換のため、予約名に含める）。
#   予約名以外の名前に付け替えた場合は、動作を保証しない（個人用の Sandbox / Developer Edition / Scratch Org の想定）。
#
# 【使い方】
#   is_reserved_org_alias "$TARGET_ORG" && die "ローカルからは実行できません。"
#
# 【戻り値】
#   RET_OK (0) : 予約名（共有環境）
#   RET_NG (1) : それ以外
# ------------------------------------------------------------------------------
readonly SF_RESERVED_ORG_ALIASES="prod staging develop main"

# ------------------------------------------------------------------------------
# 10. 責務ごとのファイル（ここから読み込む。呼び出し側は、common.sh だけを source すればよい）
#   input.sh     ... 対話入力（read_input / read_key / press_enter / read_or_quit / read_secret / ask_yn）
#   platform.sh  ... OS・外部コマンド（is_gitbash / run_isolated_home / check_sf_cli / open_browser）
#   project.sh   ... プロジェクト（get_target_org / check_force_dir / check_home_dir / check_gh_owner /
#                    get_branch_list / is_reserved_org_alias / is_protected_branch / ensure_sf_tools_latest）
# ------------------------------------------------------------------------------
_COMMON_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${_COMMON_LIB_DIR}/input.sh"
source "${_COMMON_LIB_DIR}/platform.sh"
source "${_COMMON_LIB_DIR}/project.sh"
