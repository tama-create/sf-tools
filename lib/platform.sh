#!/bin/bash
# ==============================================================================
# platform.sh - OS・外部コマンド（sf / ブラウザ）に関する関数
# ==============================================================================
# lib/common.sh から source される（呼び出し側は、common.sh だけを source すればよい。単独では、source しない）。
# common.sh の変数・関数（log / die / RET_*）を、使う。
#
# 【提供する関数】
#   is_gitbash                     ... Windows の Git Bash か判定（$OSTYPE が msys / mingw / cygwin）
#   set_var VARNAME VALUE          ... 指定した名前の変数に代入する（nameref の代わり。Bash 3.2 で動く）
#   sed_inplace SCRIPT FILE        ... ファイルを、その場で置換する（GNU / BSD の sed 共通）
#   base64_oneline                 ... 標準入力を base64 にして、1 行で出す（GNU の -w 0 は macOS にないため、改行を tr で除く）
#   run_with_timeout 秒 CMD [ARGS] ... 時間の上限つきで実行する（timeout がない macOS でも動く。時間切れは 124）
#   run_isolated_home CMD [ARGS]   ... 一時的なホームフォルダの中でコマンドを実行（sf の認証・エイリアスを隔離）
#   check_sf_cli [--warn-only] [--cache] ... sf が終了コードを正しく返すか確認（npm 版が前提。NG なら案内して die。--warn-only は戻り値 1）
#   open_browser URL               ... OS を判定してブラウザを開く（Git Bash/WSL/macOS/Linux 対応）
#   ここの関数は、コマンドの実行に run を使わない（理由は、各行の「run 不使用」のコメントを参照）
# ==============================================================================

# is_gitbash - Windows の Git Bash（MSYS2 / Cygwin 系の Bash）かどうか
# ------------------------------------------------------------------------------
# $OSTYPE は、Git Bash でも環境により msys / mingw / cygwin のいずれにもなる
# （cygwin になる環境があり、msys / mingw だけを見ていると判定を外す）。
# 【使い方】  if is_gitbash; then ...
# ------------------------------------------------------------------------------
is_gitbash() { [[ "$OSTYPE" == "msys"* || "$OSTYPE" == "mingw"* || "$OSTYPE" == "cygwin"* ]]; }

# set_var - 呼び出し元が指定した名前の変数に、値を代入する（nameref（local -n）の代わり。Bash 3.2 で動く）
# ------------------------------------------------------------------------------
# 【使い方】 set_var VARNAME VALUE      例: set_var "$1" "$result"
# 【理由】   nameref は Bash 4.3 以降の機能で、macOS 標準の Bash（3.2）にはない。printf -v は 3.1 以降で使える。
#           eval は使わない。変数名は、英数字と _ だけ（先頭は英字か _）を通す（それ以外は die）。値は、そのまま入れる（評価しない）。
# 【注意】   呼び出し元の関数に、VARNAME と同じ名前の local 変数があると、そちらに代入される。
#           結果を返す関数の local 変数は、接頭辞（_xx_）を付けて、名前の衝突を避ける。
# ------------------------------------------------------------------------------
set_var() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "set_var: 変数名が正しくありません: ${1}"
    printf -v "$1" '%s' "$2"  # run 不使用: 変数への代入（組み込みの printf -v。コマンドの実行ではない）
}

# sed_inplace - ファイルを、その場で置換する（GNU の sed と BSD の sed（macOS）の、両方で動く）
# ------------------------------------------------------------------------------
# 【使い方】 sed_inplace SCRIPT FILE      例: sed_inplace '/^PAT_TOKEN_VALUE=/d' "$ENV_FILE"
# 【理由】   `sed -i SCRIPT FILE` は、BSD の sed では、-i の直後に、バックアップの拡張子が必要（GNU では、不要）。
#           拡張子を、-i に続けて書く形（-i.bak）は、どちらでも動く。バックアップ（FILE.bak）は、sed のあとで、成否に
#           かかわらず消す。
# 【戻り値】 sed の戻り値（失敗しても、バックアップは、残さない）
# ------------------------------------------------------------------------------
sed_inplace() {
    local script="$1" file="$2" rc
    sed -i.bak "$script" "$file"  # run 不使用: 戻り値を、そのまま返す部品（呼び出し側が判定する）
    rc=$?
    rm -f "${file}.bak"  # run 不使用: バックアップの削除（なくても続行）
    return $rc
}

# base64_oneline - 標準入力を base64 にして、改行なしの 1 行で、標準出力に出す（GNU / BSD（macOS）の、両方で動く）
# ------------------------------------------------------------------------------
# 【使い方】 tr -d '\r' < server.key | base64_oneline | gh secret set ...
# 【理由】   `base64 -w 0`（折り返しなし）は GNU 版だけのオプションで、macOS の base64 にはない（エラーになる）。
#           GNU 版は 76 文字で折り返し、BSD 版は折り返さない。どちらも、改行を除けば同じ 1 行になる。
#           出力の末尾にも改行は付かない（CR も除く）。
# ------------------------------------------------------------------------------
base64_oneline() { base64 | tr -d '\r\n'; }  # run 不使用: パイプの部品（標準入力 → 標準出力。秘密鍵などを、ログに残さない）

# run_with_timeout - コマンドを、時間の上限つきで実行する（timeout コマンドがない macOS でも動く）
# ------------------------------------------------------------------------------
# 【使い方】 run_with_timeout 秒 CMD [ARGS...]      例: run_with_timeout 120 gh pr view 1 </dev/null
# 【理由】   timeout（GNU coreutils）は、Linux と Git Bash にはあるが、macOS の標準にはない。
#           ない環境で、上限なしで実行すると、応答しないコマンドで、止まり続ける。
# 【動作】   timeout（コマンド）があれば、`timeout 秒 CMD` で実行する。なければ、背景で実行して、0.1 秒ごとに終了を確認し、上限を超えたら終了させる
#           （TERM を送り、約 2 秒待っても動いていれば KILL する。TERM を無視するコマンドでも、上限を守る）。
#           標準入力は、呼び出し元のものを、そのまま渡す（非対話のシェルでは、背景のコマンドの標準入力は /dev/null になるため、
#           <&0 で明示する）。秒は整数（timeout がないときは、0.1 秒単位の回数に換算するため）。
#           CMD は、外部コマンドにする（timeout があるときは、シェルの関数を実行できない）
# 【戻り値】 コマンドの終了コード。時間切れは 124（timeout コマンドと同じ）
# ------------------------------------------------------------------------------
run_with_timeout() {
    local _rt_secs="$1" _rt_pid _rt_ticks=0 _rt_limit _rt_grace
    shift
    if command -v timeout >/dev/null 2>&1; then  # 存在確認のため run 不使用
        timeout "$_rt_secs" "$@"  # run 不使用: 終了コードを、そのまま返す（124 = 時間切れ）
        return $?
    fi
    "$@" <&0 &  # 背景で起動し、下のループで時間を監視する
    _rt_pid=$!
    _rt_limit=$(( _rt_secs * 10 ))
    while kill -0 "$_rt_pid" 2>/dev/null; do  # 存在確認のため run 不使用
        if (( _rt_ticks >= _rt_limit )); then
            pkill -TERM -P "$_rt_pid" 2>/dev/null || true  # 子プロセスも止める（なくても続行）
            kill -TERM "$_rt_pid" 2>/dev/null || true      # すでに終了していても続行
            # TERM を無視するコマンドのために、約 2 秒待って、まだ動いていれば KILL する
            #   （待たずに wait すると、TERM を無視する相手では、永久に戻らない。上限を守れない）
            _rt_grace=0
            while kill -0 "$_rt_pid" 2>/dev/null && (( _rt_grace < 20 )); do  # 存在確認のため run 不使用
                sleep 0.1  # run 不使用: 待機
                _rt_grace=$(( _rt_grace + 1 ))
            done
            if kill -0 "$_rt_pid" 2>/dev/null; then  # 存在確認のため run 不使用
                pkill -KILL -P "$_rt_pid" 2>/dev/null || true  # 子プロセスも止める（なくても続行）
                kill -KILL "$_rt_pid" 2>/dev/null || true      # すでに終了していても続行
            fi
            wait "$_rt_pid" 2>/dev/null
            return 124
        fi
        sleep 0.1  # run 不使用: 待機
        _rt_ticks=$(( _rt_ticks + 1 ))
    done
    wait "$_rt_pid"
}

# run_isolated_home - コマンドを、一時的なホームフォルダの中で実行する（sf の認証・エイリアスを隔離する）
# ------------------------------------------------------------------------------
# 【背景】
#   sf の認証は「ユーザー名単位」で ~/.sfdx に保存される。JWT の接続テスト（sf org login jwt）を、そのまま
#   実行すると、エイリアスが増える上に、同じユーザーの既存の認証が、JWT の認証に置き換わってしまう
#   （その JWT の鍵・アプリを後で消すと、そのユーザーの sf が使えなくなる）。
#   HOME と USERPROFILE（Windows は USERPROFILE を見る）を一時フォルダにすると、認証・エイリアス・暗号鍵が、
#   すべて一時フォルダの中に作られ、本物の ~/.sfdx は変わらない（実機で確認）。
#
# 【使い方】
#   out=$(run_isolated_home sf org login jwt --client-id ... --alias prod)   # 標準出力・標準エラーを受け取る
#   rc=$?                                                                    # コマンドの終了コード
#
# 【動作】
#   ・mktemp -d で一時フォルダを作り、HOME / USERPROFILE をそれにしてコマンドを実行する
#   ・Windows（Git Bash）以外では、SF_USE_GENERIC_UNIX_KEYCHAIN=true も設定する（mac のキーチェーンのダイアログを避ける。
#     理由は、関数の中のコメント）
#   ・コマンドは、サブシェルの中で実行する（呼び出し元の HOME などは、変わらない。シェルの関数も呼べる）
#   ・終了後に、一時フォルダを削除する（アクセストークンなどが入るため、必ず消す）
#   ・出力（標準出力と標準エラー）を、標準出力に返す（末尾の改行は除かれる）。戻り値は、コマンドの終了コード
#   ・一時フォルダを作れなければ、何も実行せず、RET_NG
# ------------------------------------------------------------------------------
run_isolated_home() {
    local tmp_home out rc
    tmp_home=$(mktemp -d "${TMPDIR:-/tmp}/sf-tools-home.XXXXXX") || return $RET_NG  # VAR=$(cmd) のため run 不使用
    # VAR=$(cmd) のため run 不使用（認証情報をログに出さない）。サブシェルの中で環境変数を設定する（関数も呼べる）
    #   SF_USE_GENERIC_UNIX_KEYCHAIN: Windows 以外では、sf に、暗号鍵を、OS のキーチェーンではなく、一時ホームの
    #   ファイル（.sfdx/key.json）に保存させる。mac では、一時ホームに Library/Keychains がないため、設定しないと、
    #   「キーチェーンが見つかりません（"local" を保存する）」のダイアログが出る（sf は、暗号鍵を、サービス sfdx・
    #   アカウント local で、キーチェーンに保存する）。本物のキーチェーンには、触れない。Windows（Git Bash）は、従来のまま
    out=$(
        export HOME="$tmp_home" USERPROFILE="$tmp_home"
        is_gitbash || export SF_USE_GENERIC_UNIX_KEYCHAIN=true
        "$@" 2>&1
    )
    rc=$?
    rm -rf "${tmp_home:?}"  # run 不使用: 認証情報を含む一時フォルダの確実な削除
    printf '%s' "$out"
    return $rc
}

# check_sf_cli - sf（Salesforce CLI）が、終了コードを正しく返すか確認する
# ------------------------------------------------------------------------------
# 【背景】
#   Windows の Git Bash で、Salesforce CLI の公式インストーラー版（自動更新後）を使うと、sf が成功しても
#   常に終了コード 1 を返す（npm 版では正しく返る。Salesforce 側の起動用ファイルの問題）。
#   run() は終了コードで成否を判定するため、この環境では、成功した処理も失敗扱いになる。
#   そのため sf-tools は、Salesforce CLI の npm 版（npm install -g @salesforce/cli）を前提とする。
#
# 【使い方】
#   check_sf_cli                       # 終了コードが 0 以外なら、案内を表示して die する
#   check_sf_cli --warn-only           # 案内を表示するだけで、続行する（戻り値 1）。die したくない呼び出し元用（sf-install.sh）
#   check_sf_cli --cache               # 日常のコマンド用。成功したら 24 時間は、確認を省略する（下記）。NG なら die する
#
# 【動作】
#   ・GitHub Actions 上（GITHUB_ACTIONS=true）では、何もしない（Linux の npm 版のため）
#   ・sf が未インストールなら、何もしない（各スクリプトの環境チェックが扱う）
#   ・--cache のとき、成功を ~/.sf-tools-sf-check（環境変数 SF_TOOLS_SF_CHECK_STAMP で変更可）に、sf の場所を
#     記録し、同じ場所の sf なら、24 時間（ファイルの更新から 1440 分）は sf --version（1〜2 秒）の実行を省略する。
#     失敗は、記録せず、毎回確認する。--cache なしでは、記録を読まず、書かない
#   ・sf --version の終了コードが 0 なら、何も表示しない（戻り値 0）
#   ・0 以外なら、sf の場所・出力の 1 行目・対処（npm 版への入れ替え）を ERROR で表示し、die する（--warn-only は戻り値 1）
# ------------------------------------------------------------------------------
check_sf_cli() {
    local warn_only=0 use_cache=0 out rc sf_path stamp arg
    for arg in "$@"; do
        case "$arg" in
            --warn-only) warn_only=1 ;;
            --cache)     use_cache=1 ;;
        esac
    done

    [[ "${GITHUB_ACTIONS:-}" == "true" ]] && return 0
    command -v sf >/dev/null 2>&1 || return 0  # 存在確認のため run 不使用

    sf_path=$(command -v sf)  # VAR=$(cmd) のため run 不使用
    stamp="${SF_TOOLS_SF_CHECK_STAMP:-$HOME/.sf-tools-sf-check}"
    if [[ $use_cache -eq 1 && -f "$stamp" && "$(cat "$stamp" 2>/dev/null)" == "$sf_path" \
          && -n "$(find "$stamp" -mmin -1440 2>/dev/null)" ]]; then  # 条件チェックのため run 不使用（記録の読み取り）
        return 0   # 24 時間以内に、同じ場所の sf で成功を確認済み
    fi

    out=$(sf --version 2>&1)  # VAR=$(cmd) のため run 不使用（終了コードを自分で判定する）
    rc=$?
    if [[ $rc -eq 0 ]]; then
        [[ $use_cache -eq 1 ]] && { printf '%s' "$sf_path" > "$stamp" 2>/dev/null || true; }  # 記録に失敗しても続行（意図的エラー無視）
        return 0
    fi

    log "ERROR" "sf（Salesforce CLI）の終了コードが 0 ではありません（sf --version: 終了コード ${rc}）。"
    log "ERROR" "  sf の場所: ${sf_path}"
    [[ -n "$out" ]] && log "ERROR" "  出力: $(printf '%s' "$out" | head -1)"
    log "ERROR" "  Windows の Git Bash で、Salesforce CLI の公式インストーラー版を使うと、成功しても終了コード 1 になり、"
    log "ERROR" "  sf-tools の処理が、成功しても失敗扱いになります。sf-tools は、npm 版の Salesforce CLI を前提としています。"
    log "ERROR" "  対処: インストーラー版をアンインストールし、npm 版をインストールしてください（詳細は README の前提条件）。"
    log "ERROR" "    npm install -g @salesforce/cli"
    if [[ $warn_only -eq 1 ]]; then
        return 1
    fi
    die "sf の終了コードが 0 ではないため、処理を中断しました。"
}

# open_browser - OS を判定してブラウザを開く
# ------------------------------------------------------------------------------
# 【使い方】
#   open_browser URL
#
# 【対応環境】（上から順に判定する）
#   Git Bash : start ""（is_gitbash）
#   WSL      : powershell.exe Start-Process（/proc/version に microsoft を含む）。URL は PowerShell の単引用符で囲んで
#              渡すため、URL の中の ' は '' にしてから埋め込む（PowerShell の単引用符の中の ' の書き方）
#   macOS    : open（$OSTYPE が darwin）
#   Linux    : xdg-open（あるときだけ。なければ、何もしない）
#
# 【戻り値】 常に 0（開けなくても、エラーにしない。エラー出力も捨てる）
# ------------------------------------------------------------------------------
open_browser() {
    local url="$1" q="'"
    local ps_url="${url//$q/$q$q}"   # WSL 用: ' → ''（PowerShell の単引用符の文字列の中で、' を表す）
    # stdin を /dev/null にリダイレクトし、パイプ入力の消費を防止する
    # （Git Bash の判定を先にする。WSL の判定は /proc/version を読むため、$OSTYPE の判定のほうが確実）
    if is_gitbash; then
        # Git Bash / MSYS2 / Cygwin
        start "" "$url" < /dev/null 2>/dev/null || true  # run 不使用: 意図的エラー無視（開けなくても続行）
    elif grep -qi microsoft /proc/version 2>/dev/null; then  # 条件チェックのため run 不使用
        # WSL 環境
        powershell.exe -c "Start-Process '${ps_url}'" < /dev/null 2>/dev/null || true  # run 不使用: 意図的エラー無視（開けなくても続行）
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        open "$url" < /dev/null 2>/dev/null || true  # run 不使用: 意図的エラー無視（開けなくても続行）
    elif command -v xdg-open &>/dev/null; then  # 存在確認のため run 不使用
        # Linux
        xdg-open "$url" < /dev/null 2>/dev/null || true  # run 不使用: 意図的エラー無視（開けなくても続行）
    fi
}
