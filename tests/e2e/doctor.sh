#!/bin/bash
# ==============================================================================
# doctor.sh - e2e を動かせる環境かを調べる（Windows・macOS・Linux・WSL 共通。読み取りのみ）
# ==============================================================================
# 新しい環境（Mac など）で e2e を動かす前に実行する。足りないものを、日本語で、対処つきで表示する。
# GitHub・Salesforce には何も作らず・変更せず、鍵一式の値は画面にもログにも出さない（有無と形式だけを確認する）。
# 作るのは、一時フォルダの中の、証明書の確認用ファイルだけ（終了時に削除する）。
# 管理者向けコマンドではない（読み取りのみ）ため、警告ボックスは出さない。
#
# 【確認する内容】
#   1. 環境      : OS・Bash・openssl の種類（検証の記録に書く内容）
#   2. コマンド  : git / gh / sf（npm 版）/ node / openssl と、awk / sed / base64 / mktemp
#   3. gh / git  : gh がログイン済みか・delete_repo の権限・git が GitHub に認証できるか（credential helper。無いと、https のクローンが
#                  パスワードを待って止まる。WSL・Linux で起こる）・git のユーザー名とメールアドレス（無いと、コミットで失敗する）。fixture.env の E2E_GH_USER と同じユーザーか
#   4. 鍵一式    : fixture.env の有無・権限（600。Windows は除く）・必須の項目・認証 URL の形式・作業フォルダ（E2E_HOME_ROOT）
#   5. openssl   : JWT 用の鍵と証明書を、sf-init と同じ関数で作れるか（PKCS#1 形式・発行先が空でないこと）
#   6. sf-tools  : 手元の sf-tools が development で、origin/development と一致しているか（GitHub Actions は origin を使うため）
#
# 【使い方】 bash tests/e2e/doctor.sh
# 【戻り値】 0 = 要対応なし（注意があっても 0）/ 1 = 要対応あり
# 【次の手順】 すべて OK なら: bash tests/e2e/run.sh（約 30 分）。終わりに、検証の記録の 1 行が表示される
#
# 【オプション】
#   -h, --help : このヘルプを表示する
# ==============================================================================

readonly SCRIPT_NAME="e2e-doctor"
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true  # run 不使用: ログフォルダの準備（log が使える前の処理）
readonly LOG_FILE="$HOME/sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"

export SF_INIT_MODE=1   # プロジェクト外から実行するため、force-* チェックをバイパスする
E2E_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_TOOLS_ROOT="$(cd "${E2E_SCRIPT_DIR}/../.." && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}"
    exit 0
fi

source "${SF_TOOLS_ROOT}/lib/common.sh"
source "${E2E_SCRIPT_DIR}/lib.sh"
source "${SF_TOOLS_ROOT}/phases/init/init-common.sh"   # generate_jwt_cert（sf-init と同じ証明書の作り方で確認する）

N_OK=0; N_NG=0; N_WARN=0
_ok()   { N_OK=$((N_OK + 1));     log "SUCCESS" "  [OK]   $1"; }
_ng()   { N_NG=$((N_NG + 1));     log "ERROR"   "  [要対応] $1"; [[ -n "${2:-}" ]] && log "ERROR" "           → $2"; return 0; }
_warn() { N_WARN=$((N_WARN + 1)); log "WARNING" "  [注意] $1"; [[ -n "${2:-}" ]] && log "WARNING" "           → $2"; return 0; }

# ------------------------------------------------------------------------------
# 1. 環境
# ------------------------------------------------------------------------------
log "HEADER" "e2e の環境チェック（${SCRIPT_NAME}.sh）"
log "INFO" "1. 環境"
log "INFO" "  OS     : $(e2e_os_label)"
log "INFO" "  Bash   : ${BASH_VERSION%%(*}（${BASH}）"
log "INFO" "  openssl: $(e2e_openssl_label)"

# ------------------------------------------------------------------------------
# 2. コマンド
# ------------------------------------------------------------------------------
log "INFO" "2. コマンド"
_hint_git="https://git-scm.com/downloads（macOS: xcode-select --install）"
_hint_gh="https://cli.github.com/（macOS: brew install gh）"
_hint_sf="npm install -g @salesforce/cli（npm 版が前提。公式インストーラー版は非対応）"
_hint_node="https://nodejs.org/（macOS: brew install node）"
_hint_openssl="macOS は標準で入っている。Linux / WSL: sudo apt install openssl"
for _c in git gh sf node openssl awk sed base64 mktemp; do
    if command -v "$_c" >/dev/null 2>&1; then   # 存在確認のため run 不使用
        _ok "${_c}: $(command -v "$_c")"
    else
        _h="OS の標準コマンドです。入っていない環境では、導入してください"
        case "$_c" in
            git) _h="$_hint_git" ;; gh) _h="$_hint_gh" ;; sf) _h="$_hint_sf" ;;
            node) _h="$_hint_node" ;; openssl) _h="$_hint_openssl" ;;
        esac
        _ng "${_c} が見つかりません" "$_h"
    fi
done
if command -v sf >/dev/null 2>&1; then
    if (check_sf_cli --warn-only) >/dev/null 2>&1; then   # 条件チェックのため run 不使用
        _ok "sf: 終了コードが正しく返る（npm 版）"
    else
        _ng "sf の終了コードが 0 ではありません（インストーラー版の可能性）" "$_hint_sf"
    fi
fi

# ------------------------------------------------------------------------------
# 3. gh
# ------------------------------------------------------------------------------
log "INFO" "3. gh（GitHub CLI）"
GH_LOGIN=""
if command -v gh >/dev/null 2>&1; then
    if GH_LOGIN=$(gh api user --jq .login 2>/dev/null) && [[ -n "$GH_LOGIN" ]]; then   # VAR=$(cmd) のため run 不使用
        _ok "gh: ログイン済み（${GH_LOGIN}）"
        if gh auth status 2>&1 | grep -q "delete_repo"; then   # パイプのみのため run 不使用
            _ok "gh: delete_repo の権限がある（テスト用リポジトリの削除に必要）"
        else
            _warn "gh: delete_repo の権限を確認できません（テスト用リポジトリを削除できない可能性）" "gh auth refresh -h github.com -s delete_repo"
        fi
    else
        GH_LOGIN=""
        _ng "gh: ログインしていない、または GitHub に接続できません" "gh auth login（テスト用の組織の管理者のアカウントで）"
    fi
fi

# git が GitHub の認証に使う仕組み（credential helper）。無いと、https で private のリポジトリをクローンするとき、
# パスワードの入力を待って止まる（Windows は GCM、macOS は osxkeychain、gh auth login / gh auth setup-git でも設定される）
_cred=$(git config --get-regexp '^credential\..*helper$' 2>/dev/null)  # VAR=$(cmd) のため run 不使用
if [[ -n "$_cred" ]]; then
    _ok "git: GitHub への認証の仕組み（credential helper）が設定されている"
else
    _ng "git に、GitHub の認証の仕組み（credential helper）がありません。https のクローンが、パスワードを待って止まります" "gh auth setup-git（gh のログインを、git にも使う）。e2e だけなら、環境変数 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.https://github.com.helper GIT_CONFIG_VALUE_0='!gh auth git-credential' でも渡せる"
fi

# git のユーザー名とメールアドレス（コミットの作者）。決まらないと、sf-init の初回のコミットで「Author identity unknown」になる
# （git var は、設定・環境変数・OS のユーザー情報から、コミットのときと同じ規則で、作者を決められるかを調べる）
if git var GIT_AUTHOR_IDENT >/dev/null 2>&1 && git var GIT_COMMITTER_IDENT >/dev/null 2>&1; then   # 条件チェックのため run 不使用
    _ok "git: コミットの作者（ユーザー名・メールアドレス）が決まる"
else
    _ng "git のユーザー名・メールアドレスが決まりません。コミットで「Author identity unknown」になります" "git config --global user.name \"（名前）\" と git config --global user.email \"（メールアドレス）\""
fi

# ------------------------------------------------------------------------------
# 4. 鍵一式（fixture.env）。値は表示しない。サブシェルで読み込み、有無と形式だけを、行にして受け取る
# ------------------------------------------------------------------------------
log "INFO" "4. 鍵一式（e2e 用の認証情報）"
FIXTURE="$(e2e_fixture_path)"
E2E_GH_USER_FROM_FIXTURE=""
if [[ ! -f "$FIXTURE" ]]; then
    _ng "鍵一式のファイルがありません: ${FIXTURE}" "別のマシンで作ったものを、安全な方法（AirDrop・USB など。チャットや Git は不可）でコピーして chmod 600 にするか、bash tests/e2e/bootstrap.sh で作る"
else
    _ok "鍵一式のファイルがある: ${FIXTURE}"
    if e2e_is_windows; then
        _ok "権限の確認は、Windows（Git Bash）では行わない"
    else
        _perm=$(stat -c %a "$FIXTURE" 2>/dev/null || stat -f %Lp "$FIXTURE" 2>/dev/null)  # VAR=$(cmd) のため run 不使用
        if [[ "$_perm" == "600" ]]; then
            _ok "権限が 600（本人のみ）"
        else
            _ng "鍵一式のファイルの権限が 600 ではありません（${_perm}）" "chmod 600 \"${FIXTURE}\""
        fi
    fi
    _facts=$( (
        # shellcheck disable=SC1090
        source "$FIXTURE" >/dev/null 2>&1
        _missing=""
        for _v in E2E_OWNER E2E_GH_USER E2E_HOME_ROOT E2E_PAT_TOKEN E2E_SLACK_BOT_TOKEN E2E_SLACK_CHANNEL_ID E2E_SFDX_AUTH_URL; do
            [[ -n "${!_v:-}" ]] || _missing="${_missing} ${_v}"
        done
        echo "MISSING=${_missing# }"
        echo "GHUSER=${E2E_GH_USER:-}"
        echo "HOMEROOT=${E2E_HOME_ROOT:-}"
        for _v in E2E_SFDX_AUTH_URL E2E_SFDX_AUTH_URL_STG E2E_SFDX_AUTH_URL_DEV; do
            if [[ -n "${!_v:-}" ]]; then
                e2e_valid_sfdx_url "${!_v}" && echo "URL_${_v}=ok" || echo "URL_${_v}=bad"
            else
                echo "URL_${_v}=none"
            fi
        done
    ) )   # 値そのものは出さず、有無・形式・非機密の設定（ユーザー名・フォルダ）だけを返す
    _fact() { printf '%s\n' "$_facts" | sed -n "s/^$1=//p" | head -1; }
    _m=$(_fact MISSING)
    if [[ -z "$_m" ]]; then
        _ok "必須の項目が、すべて設定されている"
    else
        _ng "未設定の項目があります: ${_m}" "bash tests/e2e/bootstrap.sh で作り直すか、元のマシンの鍵一式をコピーする"
    fi
    for _v in E2E_SFDX_AUTH_URL E2E_SFDX_AUTH_URL_STG E2E_SFDX_AUTH_URL_DEV; do
        case "$(_fact "URL_${_v}")" in
            ok)   _ok "${_v}: 認証 URL の形式が正しい" ;;
            bad)  _ng "${_v} が認証 URL の形式ではありません" "bash tests/e2e/bootstrap.sh --refresh-orgs で取り直す" ;;
            none) [[ "$_v" == "E2E_SFDX_AUTH_URL" ]] || _warn "${_v}: 設定なし（${_v##*_} の層を含む検証・--add-tier の確認が、できません）" "bash tests/e2e/bootstrap.sh --add-orgs" ;;
        esac
    done
    E2E_GH_USER_FROM_FIXTURE=$(_fact GHUSER)
    if [[ -n "$GH_LOGIN" && -n "$E2E_GH_USER_FROM_FIXTURE" ]]; then
        if [[ "$GH_LOGIN" == "$E2E_GH_USER_FROM_FIXTURE" ]]; then
            _ok "gh のログインユーザーが、E2E_GH_USER（${E2E_GH_USER_FROM_FIXTURE}）と一致している"
        else
            _ng "gh のログインユーザー（${GH_LOGIN}）が、E2E_GH_USER（${E2E_GH_USER_FROM_FIXTURE}）と一致しません" "gh auth switch、または GH_TOKEN に ${E2E_GH_USER_FROM_FIXTURE} のトークンを設定して実行する"
        fi
    fi
    _root=$(_fact HOMEROOT)
    if [[ -n "$_root" ]]; then
        if [[ -d "$_root" && -w "$_root" ]]; then
            _ok "作業フォルダ（E2E_HOME_ROOT）がある: ${_root}"
        else
            _ng "作業フォルダ（E2E_HOME_ROOT）がない、または書き込めません: ${_root}" "このマシンの場所に直す（macOS なら、たとえば ${HOME}/home。fixture.env の E2E_HOME_ROOT を書き換えて、フォルダを作る）"
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 5. openssl: sf-init と同じ関数で、JWT 用の鍵と証明書を作る（macOS の LibreSSL・Windows の Git Bash の差が出る所）
# ------------------------------------------------------------------------------
log "INFO" "5. openssl（JWT 用の鍵と証明書）"
if command -v openssl >/dev/null 2>&1; then
    _jwt_tmp=$(mktemp -d "${TMPDIR:-/tmp}/e2e-doctor.XXXXXX") || _jwt_tmp=""  # VAR=$(cmd) のため run 不使用
    if [[ -z "$_jwt_tmp" ]]; then
        _ng "一時フォルダを作れません（TMPDIR: ${TMPDIR:-/tmp}）"
    else
        if (generate_jwt_cert "${_jwt_tmp}/jwt" "force-doctor") >/dev/null 2>&1; then   # 条件チェックのため run 不使用
            if grep -q "BEGIN RSA PRIVATE KEY" "${_jwt_tmp}/jwt/server.key" 2>/dev/null; then
                _ok "秘密鍵を作れた（PKCS#1 形式。Salesforce の JWT に必要）"
            else
                _ng "秘密鍵が PKCS#1 形式（BEGIN RSA PRIVATE KEY）ではありません" "openssl のバージョンを確認する（sf-init の Phase 10 で失敗します）"
            fi
            if _jwt_cert_subject_state "${_jwt_tmp}/jwt/server.crt"; then
                _ok "証明書を作れた（発行先が入っている）"
            else
                _ng "証明書の発行先（subject）が空です" "Salesforce が「証明書ではありません」と拒否します。openssl の -subj の扱いを確認する"
            fi
        else
            _hint="openssl の動作を確認する"
            if e2e_is_windows && [[ "$(command -v openssl)" == /usr/* ]]; then
                _hint="Git Bash の openssl が MSYS 版（$(command -v openssl)）です。証明書の発行先が空になるため、標準の Git Bash（スタートメニューの Git Bash。C:\\Git\\bin\\bash.exe -l）から実行する"
            fi
            _ng "JWT 用の鍵と証明書を作れませんでした" "$_hint"
        fi
        rm -rf "$_jwt_tmp"  # run 不使用: 確認用の一時フォルダの後始末
    fi
fi

# ------------------------------------------------------------------------------
# 6. sf-tools
# ------------------------------------------------------------------------------
log "INFO" "6. sf-tools（${SF_TOOLS_ROOT}）"
_br=$(git -C "$SF_TOOLS_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)   # VAR=$(cmd) のため run 不使用
_head=$(git -C "$SF_TOOLS_ROOT" rev-parse HEAD 2>/dev/null)              # VAR=$(cmd) のため run 不使用
_origin=$(git -C "$SF_TOOLS_ROOT" rev-parse origin/development 2>/dev/null)  # VAR=$(cmd) のため run 不使用
if [[ "$_br" == "development" && -n "$_head" && "$_head" == "$_origin" ]]; then
    _ok "development ブランチで、origin/development と一致している"
else
    _warn "手元の sf-tools が、development / origin/development と一致していません（ブランチ: ${_br:-不明}）" "GitHub Actions は origin/development を使うため、Actions の確認が、手元の変更を反映しません。git checkout development && git pull"
fi

# ------------------------------------------------------------------------------
# 結果
# ------------------------------------------------------------------------------
echo ""
log "HEADER" "結果"
log "INFO" "  OK ${N_OK} 件 / 要対応 ${N_NG} 件 / 注意 ${N_WARN} 件"
if [[ $N_NG -eq 0 ]]; then
    log "SUCCESS" "e2e を動かせる環境です。次: bash tests/e2e/run.sh（約 30 分。終わりに、検証の記録の 1 行が表示されます）"
    exit $RET_OK
fi
log "ERROR" "要対応の項目があります。上の「→」の対処をしてから、もう一度実行してください。"
exit $RET_NG
