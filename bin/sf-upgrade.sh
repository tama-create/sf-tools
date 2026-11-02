#!/bin/bash
# ==============================================================================
# sf-upgrade.sh - 開発ツール一括アップデートスクリプト
# ==============================================================================
# npm・Salesforce CLI（sf）・Git（Windows の Git Bash のみ）を、最新版にアップデートする。
# sf-install.sh が、前回から 24 時間以上たっているときに、バックグラウンドで自動で呼び出す（引数なし。標準出力は捨て、
# 標準エラー（画面への表示）は ./sf-tools/logs/sf-install.log に追記する）。
# 手動でも実行できる。
#
# 【使い方】
#   bash ~/sf-tools/bin/sf-upgrade.sh [オプション]     # force-* ディレクトリで実行する
#
# 【オプション】
#   -v, --verbose : コマンドの応答（出力）をコンソールにも表示する
#   -h, --help    : このヘルプを表示して終了する（第 1 引数に指定したときのみ）
#   ※ そのほかの引数は、「不明なオプションです」と表示して中断する
#
# 【処理の流れ】
#   1. npm を確認する（npm が無ければ、WARNING を表示してスキップ）
#        現在の版（npm --version）と最新の版（npm view npm version）が同じ: 何もしない（INFO）
#        違うとき、まず npm install -g npm@latest --dry-run（何も書き込まない）で、今の Node で入れられるかを確かめる
#          入れられる               : npm install -g npm@latest で更新する
#          Node が対応していない    : 更新しない。INFO で、Node の更新が必要なことを案内する（失敗には数えない）
#          それ以外のエラー         : WARNING（失敗に数える）
#   2. Salesforce CLI（sf）をアップデートする（sf が無ければ、WARNING を表示してスキップ）
#        npm 版（npm があり、npm ls -g @salesforce/cli --depth=0 が成功）: npm install -g @salesforce/cli@latest
#        それ以外（公式インストーラー・pkg など）                           : sf update
#        失敗したとき、npm の置き場所（npm config get prefix）に書き込めなければ、その旨を WARNING で表示する
#   3. Git をアップデートする（最後に実行）
#        Windows の Git Bash（$OSTYPE が msys* / mingw* / cygwin*）: git update-git-for-windows --yes
#        それ以外（macOS・Linux・WSL）: 実行しない（パッケージマネージャーで行うよう INFO を表示する）
#
# 【前提条件】
#   - force-* ディレクトリ（フォルダ名が force- で始まる）で実行すること。それ以外では lib/common.sh が終了する
#     （終了コード 1。SF_INIT_MODE=1 のときは、確認しない）
#
# 【補足】
#   - どの手順が失敗しても、WARNING を表示して続行する。最後に、失敗した手順（npm・Salesforce CLI・Git のうち、
#     見つからなかった・更新できなかったもの）があれば、その名前を WARNING で一覧し、なければ「すべてのアップデートが完了しました」を表示する
#     （失敗があっても、終了コードは 0。sf-install.sh が裏で呼び出すため、呼び出し元を止めない）
#   - npm の最新版は、Node の版が新しくないと入らないことがある（npm は Node に同梱されている。npm だけを更新すると、Node との組み合わせで失敗する）。
#     その場合は、更新せず、Node の更新を案内するだけ（Windows の Git Bash では winget のコマンドを示す。自動では Node を更新しない）
#   - 自動で呼ばれたときの表示は sf-install.log にだけ残る。案内を画面で見るには、手動で実行する
#   - ログ: ./sf-tools/logs/sf-upgrade.log（実行ごとに作り直す）
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 共通ライブラリの必須設定
# ------------------------------------------------------------------------------
SCRIPT_NAME="${0##*/}"; readonly SCRIPT_NAME="${SCRIPT_NAME%.sh}"
readonly LOG_FILE="./sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"


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
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}"
    exit 0
fi
source "$COMMON_LIB"
reject_unknown_args "$@"   # -v / --verbose 以外の引数は、不明なオプションとして中断する

# ==============================================================================
# メイン処理
# ==============================================================================
log "HEADER" "開発ツールのアップデートを開始します (${SCRIPT_NAME}.sh)"

# 更新できなかった手順の名前（読点区切り）。最後に、成功と言い切らず、これを一覧する
failed_steps=""
_mark_failed() { failed_steps="${failed_steps:+${failed_steps}、}$1"; }

# $1 のフォルダに、書き込めるか（一時ファイルを作って確かめる。-w は Windows の権限を正しく見ないことがあるため）
_dir_writable() {
    local t="$1/.sf-tools-write-test-$$"
    if ( : > "$t" ) 2>/dev/null; then  # 書き込みの可否を見るだけのため run 不使用
        rm -f "$t" 2>/dev/null || true  # 後始末のため run 不使用（エラーは無視）
        return 0
    fi
    return 1
}

# npm install -g が失敗したときに、置き場所に書き込めない（管理者権限が要る場所）なら、その旨を表示する
_warn_if_prefix_unwritable() {
    local prefix; prefix=$(npm config get prefix 2>/dev/null || true)
    if [[ -n "$prefix" && -d "$prefix" ]] && ! _dir_writable "$prefix"; then
        log "WARNING" "npm のインストール先（${prefix}）に書き込めません。自分のフォルダに変えると、管理者権限なしで更新できます（npm config set prefix <自分のフォルダ>。sf は入れ直しが必要）"
    fi
}

# ------------------------------------------------------------------------------
# npm の確認・アップデート
# ------------------------------------------------------------------------------
log "INFO" "npm を確認します..."
if command -v npm >/dev/null 2>&1; then  # 存在確認のため run 不使用
    npm_cur=$(npm --version 2>/dev/null || true)
    npm_new=$(npm view npm version 2>/dev/null || true)
    if [[ -z "$npm_cur" || -z "$npm_new" ]]; then
        log "WARNING" "npm の版を確認できませんでした（続行します）"
        _mark_failed "npm"
    elif [[ "$npm_cur" == "$npm_new" ]]; then
        log "INFO" "npm は最新です（${npm_cur}）"
    else
        # --dry-run は何も書き込まない。今の Node で最新の npm を入れられるかを、先に確かめる
        if npm_probe=$(npm install -g npm@latest --dry-run 2>&1); then  # 判定のみのため run 不使用
            run npm install -g npm@latest \
                || { log "WARNING" "npm のアップデートに失敗しました（続行します）"; _warn_if_prefix_unwritable; _mark_failed "npm"; }
        elif [[ "$npm_probe" == *"Not compatible"* ]]; then
            # npm は Node に同梱されている。最新の npm が今の Node を対応外にすることがある（失敗ではなく、案内だけ）
            node_cur=$(node --version 2>/dev/null || true)
            log "INFO" "npm の最新版（${npm_new}）は、今の Node（${node_cur}）では入れられません。現在の npm（${npm_cur}）のままにします"
            if is_gitbash; then
                log "INFO" "更新するには、Node を更新してください（winget upgrade --id OpenJS.NodeJS.LTS。管理者の確認画面が 1 回出ます）"
            else
                log "INFO" "更新するには、Node を更新してください（お使いのパッケージマネージャーで）"
            fi
        else
            log "WARNING" "npm のアップデートに失敗しました（続行します）"
            _mark_failed "npm"
        fi
    fi
else
    log "WARNING" "npm が見つかりません。Node.js のインストールを確認してください。"
    _mark_failed "npm"
fi

# ------------------------------------------------------------------------------
# Salesforce CLI のアップデート
# ------------------------------------------------------------------------------
log "INFO" "Salesforce CLI をアップデートします..."
if command -v sf >/dev/null 2>&1; then  # 存在確認のため run 不使用
    sf_via_npm=0
    if command -v npm >/dev/null 2>&1; then  # 存在確認のため run 不使用
        if npm ls -g @salesforce/cli --depth=0 >/dev/null 2>&1; then sf_via_npm=1; fi  # 判定のみのため run 不使用
    fi
    if [[ $sf_via_npm -eq 1 ]]; then
        # npm 版（sf-tools が前提とする入れ方）: npm で更新する（sf update は npm 版では使えない）
        run npm install -g @salesforce/cli@latest \
            || { log "WARNING" "Salesforce CLI のアップデートに失敗しました（続行します）"; _warn_if_prefix_unwritable; _mark_failed "Salesforce CLI"; }
    else
        # npm 版以外（公式インストーラー・pkg など）: sf update で更新する
        run sf update \
            || { log "WARNING" "Salesforce CLI のアップデートに失敗しました（続行します）"; _mark_failed "Salesforce CLI"; }
    fi
else
    log "WARNING" "sf コマンドが見つかりません。Salesforce CLI のインストールを確認してください。"
    _mark_failed "Salesforce CLI"
fi

# ------------------------------------------------------------------------------
# Git のアップデート（最後に実行 ※アップデート時は GUI インストーラーが起動する）
# ------------------------------------------------------------------------------
log "INFO" "Git をアップデートします..."
if is_gitbash; then
    run git update-git-for-windows --yes \
        || { log "WARNING" "Git のアップデートに失敗しました（続行します）"; _mark_failed "Git"; }
else
    log "INFO" "Git のアップデートはパッケージマネージャーで行ってください（スキップ）"
fi

# 失敗があれば、成功とは言わず、名前を一覧する（終了コードは 0 のまま。裏で呼ぶ sf-install.sh を止めない）
if [[ -n "$failed_steps" ]]; then
    log "WARNING" "更新できなかったものがあります: ${failed_steps}"
else
    log "SUCCESS" "すべてのアップデートが完了しました"
fi
