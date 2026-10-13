#!/bin/bash
# ==============================================================================
# platform.sh - OS・外部コマンド（sf / ブラウザ）に関する関数
# ==============================================================================
# lib/common.sh から source される（呼び出し側は、common.sh だけを source すればよい。単独では、source しない）。
# common.sh の変数・関数（log / run / die / RET_* / 色の定義 など）を、使う。
#
# 【提供する関数】
#   is_gitbash                     ... Windows の Git Bash か判定（$OSTYPE が msys / mingw / cygwin）
#   run_isolated_home CMD [ARGS]   ... 一時的なホームフォルダの中でコマンドを実行（sf の認証・エイリアスを隔離）
#   check_sf_cli [--warn-only] [--cache] ... sf が終了コードを正しく返すか確認（npm 版が前提。NG なら案内して die）
#   open_browser URL               ... OS を判定してブラウザを開く（Git Bash/WSL/macOS/Linux 対応）
# ==============================================================================

# is_gitbash - Windows の Git Bash（MSYS2 / Cygwin 系の Bash）かどうか
# ------------------------------------------------------------------------------
# $OSTYPE は、Git Bash でも環境により msys / mingw / cygwin のいずれにもなる
# （cygwin になる環境があり、msys / mingw だけを見ていると判定を外す）。
# 【使い方】  if is_gitbash; then ...
# ------------------------------------------------------------------------------
is_gitbash() { [[ "$OSTYPE" == "msys"* || "$OSTYPE" == "mingw"* || "$OSTYPE" == "cygwin"* ]]; }

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
#   ・終了後に、一時フォルダを削除する（アクセストークンなどが入るため、必ず消す）
#   ・出力（標準出力と標準エラー）を、標準出力に返す。戻り値は、コマンドの終了コード
# ------------------------------------------------------------------------------
run_isolated_home() {
    local tmp_home out rc
    tmp_home=$(mktemp -d "${TMPDIR:-/tmp}/sf-tools-home.XXXXXX") || return $RET_NG  # VAR=$(cmd) のため run 不使用
    out=$(HOME="$tmp_home" USERPROFILE="$tmp_home" "$@" 2>&1)  # VAR=$(cmd) のため run 不使用（認証情報をログに出さない）
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
#     記録し、同じ場所の sf なら、24 時間は sf --version（1〜2 秒）の実行を省略する。失敗は、記録せず、毎回確認する
#   ・sf --version の終了コードが 0 なら、何も表示しない
#   ・0 以外なら、sf の場所と対処（npm 版への入れ替え）を ERROR で表示する
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
          && -n "$(find "$stamp" -mmin -1440 2>/dev/null)" ]]; then
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
# 【対応環境】
#   Git Bash : start ""
#   WSL      : powershell.exe Start-Process
#   macOS    : open
#   Linux    : xdg-open
# ------------------------------------------------------------------------------
open_browser() {
    local url="$1"
    # stdin を /dev/null にリダイレクトし、パイプ入力の消費を防止する
    # （Git Bash の判定を先にする。WSL の判定は /proc/version を読むため、$OSTYPE の判定のほうが確実）
    if is_gitbash; then
        # Git Bash / MSYS2 / Cygwin
        start "" "$url" < /dev/null 2>/dev/null || true
    elif grep -qi microsoft /proc/version 2>/dev/null; then
        # WSL 環境
        powershell.exe -c "Start-Process '$url'" < /dev/null 2>/dev/null || true
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        open "$url" < /dev/null 2>/dev/null || true  # open は macOS 標準のため直接実行
    elif command -v xdg-open &>/dev/null; then
        # Linux
        xdg-open "$url" < /dev/null 2>/dev/null || true  # xdg-open は存在確認のため直接実行
    fi
}
