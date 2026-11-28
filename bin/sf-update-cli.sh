#!/bin/bash
# ==============================================================================
# sf-update-cli.sh - npm・Salesforce CLI・Git の更新（2026-11-28 に sf-upgrade.sh から改名）
# ==============================================================================
# npm・Salesforce CLI（sf）・Git（Windows の Git Bash のみ）を、最新版にアップデートする。
# sf-refresh.sh が、前回から 24 時間以上たっているときに、バックグラウンドで自動で呼び出す（引数なし。標準出力は捨て、
# 標準エラー（画面への表示）は ./sf-tools/logs/sf-refresh.log に追記する）。
# 手動でも実行できる。
#
# 【使い方】
#   bash ~/sf-tools/bin/sf-update-cli.sh [オプション]     # force-* ディレクトリで実行する
#
# 【オプション】
#   -v, --verbose : コマンドの応答（出力）をコンソールにも表示する
#   -h, --help    : このヘルプを表示して終了する（第 1 引数に指定したときのみ）
#   ※ そのほかの引数は、「不明なオプションです」と表示して中断する
#
# 【処理の流れ】
#   0. sf の更新のロック（~/.sf-tools-upgrade.lock。環境変数 SF_TOOLS_UPGRADE_LOCK で差し替え可。中身は PID=<数字> の 1 行）を取る:
#        ロックは「ないときだけ作る」（set -C。O_EXCL のため、2 つが同時に起動しても、作れるのは 1 つだけ。2026-11-27 までは、
#        読んで確かめてから書いていたため、同時に起動すると、両方が重い入れ替えに進めた）。作れたら、自分のロック。
#        作れない（もうある）とき: 持ち主が動いている（PID が生きていて、ロックが 2 時間より新しい）→ 何もせずに終わる（INFO。
#          終了コード 0）。2 時間以上たったロックは、PID が生きていても、途中で切れたものとみなす（PID が別のプロセスに
#          使い回されたとき、いつまでも「動いている」と見てしまうため。sf-refresh.sh の、途中で切れたかの判定と同じ決まり）。
#          持ち主が動いていない → 途中で切れたロックとして消し、もう一度だけ「ないときだけ作る」。それも作れず、持ち主が動いて
#          いれば、ほかが先に取ったとして終わる（INFO）。持ち主が動いていなければ（消せない・書けないロック）、下の「書けない」と同じ。途中で切れたロックを、2 つが同時に見つけたときだけは、まれに両方が進むことがある（消して
#          作り直すあいだの隙間。普段の同時起動は、上の 1 回目で防げる）
#        ロックを書けない（フォルダに書けないなど）: WARNING を出して、ロックなしで続ける（更新は止めない。sf-log.sh が待たないだけ）
#        終了時（EXIT）に消す（自分の PID のときだけ）。
#        sf-log.sh は、このロックがあるあいだ、sf を呼ばずに待つ（sf の入れ替えの途中に sf を呼ぶと失敗するため。2026-11-24）
#   1. npm を確認する（npm が無ければ、WARNING を表示してスキップ）
#        現在の版（npm --version）と最新の版（npm view npm version）が同じ: 何もしない（INFO）
#        違うとき、npm install -g npm@latest で更新する（出力は取っておく。--dry-run の試し打ちはしない。補足）
#          成功                     : SUCCESS
#          出力に「Not compatible」  : Node が対応していない。npm は何も変えずに止まる。INFO で、Node の更新が必要なことを案内する
#                                     （失敗には数えない）
#          それ以外の失敗           : WARNING に、npm の出力の末尾 5 行（理由）を表示する（失敗に数える）。
#                                     npm の置き場所に書き込めないときは、その旨も表示する
#   2. Salesforce CLI（sf）をアップデートする（sf が無ければ、WARNING を表示してスキップ）
#        先に、npm の置き場所（npm root -g）の @salesforce/ の下に、入れ替えが途中で切れた跡がないかを見る:
#          退避の残り（.cli-* のフォルダ）がある、または cli/ があるのに cli/package.json か cli/bin/run.js がない
#          → 更新しない（失敗に数える）。WARNING で、跡の場所と直し方（退避された元の版を cli/ に戻すか、
#            npm install -g @salesforce/cli で入れ直す）を表示する。自動では直さない（消す・戻すは取り返しがつかないため）。
#            跡の場所を、印のファイル（~/.sf-tools-sf-broken。環境変数 SF_TOOLS_SF_BROKEN_MARK で差し替え可）にも書く
#            （この表示は sf-update-cli.log にしか残らないため。check_sf_cli が、毎回の起動の画面に WARNING で出す）。
#            npm の置き場所を読めて、跡がないときは、印を消す
#            この確認を、下の npm 版かの判定より前に置く（跡があると npm ls -g が失敗し、npm 版でないと見て sf update に
#            進んでしまう。WSL では、PATH の後ろの Windows の sf が、黙って使われていた。2026-11-27）
#        npm 版（npm があり、npm ls -g @salesforce/cli --depth=0 が成功）:
#          入っている版（npm ls の @salesforce/cli@<版>）と最新の版（npm view @salesforce/cli version）が同じ → 何もしない（INFO）。
#          どちらかが読めない・違う → npm install -g @salesforce/cli@latest（同じ版の入れ直しはしない。入れ替えは、
#          約 3.5 万ファイルを書き直す重い処理で、2026-11-27 に WSL で、同じ版の入れ直しが途中で切れ、sf がないまま残った）
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
#     （失敗があっても、終了コードは 0。sf-refresh.sh が裏で呼び出すため、呼び出し元を止めない）
#   - npm の最新版は、Node の版が新しくないと入らないことがある（npm は Node に同梱されている。npm だけを更新すると、Node との組み合わせで失敗する）。
#     その場合は、更新せず、Node の更新を案内するだけ（Windows の Git Bash では winget のコマンドを示す。自動では Node を更新しない）
#   - npm install --dry-run を、事前の確認に使わない理由: npm 12 は、--dry-run のときだけ、npm 自身（同梱の部品を持つ）の取得を、
#     EALLOWREMOTE（「remote の取得は無効」）で誤って拒否するため、npm 12 の環境（Node 26 など）で、毎回、失敗してしまう
#     （npm/cli#9800。--dry-run なしの同じコマンドは成功する）。対応外の Node は、本番のコマンドの出力（Not compatible）で見分ける
#   - 自動で呼ばれたときの表示は sf-refresh.log にだけ残る。案内を画面で見るには、手動で実行する
#   - ログ: ./sf-tools/logs/sf-update-cli.log（実行ごとに作り直す）
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

# ------------------------------------------------------------------------------
# sf の更新のロック（処理の流れ 0）。sf-log.sh が読む（場所・形は sf-log.sh の UPGRADE_LOCK と同じ。PID=<数字> の 1 行）
# ------------------------------------------------------------------------------
UPGRADE_LOCK="${SF_TOOLS_UPGRADE_LOCK:-${HOME}/.sf-tools-upgrade.lock}"
readonly UPGRADE_LOCK_STALE_MIN=120   # これより古い（分）ロックは、PID が生きていても、途中で切れたものとみなす（PID の使い回し。sf-refresh.sh と同じ 2 時間）
# ないときだけ作る（set -C は、> を O_EXCL で開く。Bash 3.2・Git Bash でも同じ）。作れたら 0
_try_lock() { ( set -C; printf 'PID=%s\n' "$$" > "$UPGRADE_LOCK" ) 2>/dev/null; }  # 条件チェックのため run 不使用
# 今のロックの持ち主が動いているか（PID が生きていて、ロックが 2 時間より新しい）。持ち主の PID は _lock_pid に入れる
_lock_holder_alive() {
    _lock_pid=$(sed -n 's/^PID=//p' "$UPGRADE_LOCK" 2>/dev/null | head -n 1)  # VAR=$(cmd) のため run 不使用
    [[ "$_lock_pid" =~ ^[0-9]+$ && "$_lock_pid" != "$$" ]] || return 1
    [[ -n "$(find "$UPGRADE_LOCK" -mmin -"$UPGRADE_LOCK_STALE_MIN" 2>/dev/null)" ]] || return 1  # 条件チェックのため run 不使用（find -mmin は macOS・Linux・Git Bash で同じ）
    kill -0 "$_lock_pid" 2>/dev/null  # 条件チェックのため run 不使用
}
_lock_pid=""
if ! _try_lock; then
    if [[ -e "$UPGRADE_LOCK" ]]; then
        if _lock_holder_alive; then
            log "INFO" "ほかの sf-update-cli.sh（PID ${_lock_pid}）が動いているため、何もせずに終わります。"
            exit 0
        fi
        # 持ち主が動いていない（途中で切れた）→ 消して、もう一度だけ取る
        rm -f "$UPGRADE_LOCK" 2>/dev/null || true  # 後始末のため run 不使用（消せなければ、下の取り直しが失敗する）
        if ! _try_lock; then
            # ほかが先に取った（持ち主が動いている）なら終わる。そうでなければ、消せない・書けないロック（読み取り専用など）
            #   → 「ほかが取った」と取り違えて更新を止めないよう、ロックなしで続ける（以前と同じ）
            if [[ -e "$UPGRADE_LOCK" ]] && _lock_holder_alive; then
                log "INFO" "ほかの sf-update-cli.sh（PID ${_lock_pid}）が、先にロックを取ったため、何もせずに終わります。"
                exit 0
            fi
            log "WARNING" "sf の更新のロックを書けません（${UPGRADE_LOCK}）。続行します。"   # 書けなくても更新は続ける（sf-log.sh が待たないだけ）
        fi
    else
        log "WARNING" "sf の更新のロックを書けません（${UPGRADE_LOCK}）。続行します。"   # 書けなくても更新は続ける（sf-log.sh が待たないだけ）
    fi
fi
# 自分の PID のときだけ消す（ほかの sf-update-cli.sh が書き直したロックを消さない）
_release_upgrade_lock() {
    [[ "$(sed -n 's/^PID=//p' "$UPGRADE_LOCK" 2>/dev/null | head -n 1)" == "$$" ]] && rm -f "$UPGRADE_LOCK" 2>/dev/null  # 後始末のため run 不使用
    return 0
}
trap _release_upgrade_lock EXIT

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
        # 本番のコマンドで更新する。--dry-run の「試し打ち」は使わない（npm 12 は、--dry-run のときだけ、npm 自身の取得を
        # EALLOWREMOTE で誤って拒否し、毎回失敗する。npm/cli#9800）。出力は取っておき、失敗したときだけ、理由を表示する。
        # 今の Node が最新の npm に対応していないときは、npm は何も変えずに「Not compatible」で止まる
        log "INFO" "npm を ${npm_cur} から ${npm_new} に更新します（npm install -g npm@latest）..."
        if npm_out=$(npm install -g npm@latest 2>&1); then  # 出力を取るため run 不使用
            log "SUCCESS" "npm を更新しました（${npm_new}）"
        elif [[ "$npm_out" == *"Not compatible"* ]]; then
            # npm は Node に同梱されている。最新の npm が今の Node を対応外にすることがある（失敗ではなく、案内だけ）
            node_cur=$(node --version 2>/dev/null || true)
            log "INFO" "npm の最新版（${npm_new}）は、今の Node（${node_cur}）では入れられません。現在の npm（${npm_cur}）のままにします"
            if is_gitbash; then
                log "INFO" "更新するには、Node を更新してください（winget upgrade --id OpenJS.NodeJS.LTS。管理者の確認画面が 1 回出ます）"
            else
                log "INFO" "更新するには、Node を更新してください（お使いのパッケージマネージャーで）"
            fi
        else
            log "WARNING" "npm のアップデートに失敗しました（続行します）。npm の出力の末尾:"
            while IFS= read -r npm_line; do
                log "WARNING" "  ${npm_line}"
            done <<< "$(printf '%s\n' "$npm_out" | tail -n 5)"
            _warn_if_prefix_unwritable
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
# npm の置き場所の @salesforce/ の下に、入れ替えが途中で切れた跡があれば、その場所を 1 行ずつ出す（なければ何も出さない）
_sf_interrupted_traces() {
    local root="$1" d
    [[ -n "$root" && -d "$root/@salesforce" ]] || return 0
    for d in "$root/@salesforce"/.cli-*; do
        [[ -d "$d" ]] && printf '%s\n' "$d"   # 退避の残り（npm は、入れ替えが終われば消す）
    done
    if [[ -d "$root/@salesforce/cli" ]] && [[ ! -f "$root/@salesforce/cli/package.json" || ! -f "$root/@salesforce/cli/bin/run.js" ]]; then
        printf '%s\n' "$root/@salesforce/cli"   # 中身が欠けた本体
    fi
    return 0
}

SF_BROKEN_MARK="${SF_TOOLS_SF_BROKEN_MARK:-${HOME}/.sf-tools-sf-broken}"
sf_traces=""
npm_root=""
if command -v npm >/dev/null 2>&1; then  # 存在確認のため run 不使用
    npm_root=$(npm root -g 2>/dev/null || true)   # VAR=$(cmd) のため run 不使用
    sf_traces=$(_sf_interrupted_traces "$npm_root")
fi
if [[ -n "$sf_traces" ]]; then
    printf '%s\n' "$sf_traces" > "$SF_BROKEN_MARK" 2>/dev/null \
        || log "WARNING" "印のファイルを書けません（${SF_BROKEN_MARK}）。起動の画面には出ません。"   # 書けなくても続ける
elif [[ -n "$npm_root" ]]; then
    rm -f "$SF_BROKEN_MARK" 2>/dev/null || true   # 跡がなくなった（直った）→ 印を消す（意図的なエラー無視）
fi
if [[ -n "$sf_traces" ]]; then
    log "WARNING" "Salesforce CLI の入れ替えが、前回の途中で切れた跡があります。更新しません:"
    while IFS= read -r _t; do log "WARNING" "  ${_t}"; done <<< "$sf_traces"
    log "WARNING" "  直し方: 退避された元の版（.cli-* のフォルダ）を cli に名前を戻す（中身の欠けた cli は、別の場所へよける）か、"
    log "WARNING" "  npm install -g @salesforce/cli で入れ直してください。直したら、sf --version で確かめます"
    _mark_failed "Salesforce CLI"
elif command -v sf >/dev/null 2>&1; then  # 存在確認のため run 不使用
    sf_via_npm=0
    if command -v npm >/dev/null 2>&1; then  # 存在確認のため run 不使用
        if sf_ls=$(npm ls -g @salesforce/cli --depth=0 2>/dev/null); then sf_via_npm=1; fi  # 判定と版の読み取りのため run 不使用
    fi
    if [[ $sf_via_npm -eq 1 ]]; then
        # npm 版（sf-tools が前提とする入れ方）: 最新なら何もしない。違えば npm で更新する（sf update は npm 版では使えない）
        sf_cur=$(printf '%s\n' "$sf_ls" | sed -n 's/.*@salesforce\/cli@\([0-9][0-9A-Za-z.+-]*\).*/\1/p' | head -n 1)   # VAR=$(cmd) のため run 不使用
        sf_new=$(npm view @salesforce/cli version 2>/dev/null | head -n 1)   # VAR=$(cmd) のため run 不使用
        if [[ -n "$sf_cur" && "$sf_cur" == "$sf_new" ]]; then
            log "INFO" "Salesforce CLI は最新です（${sf_cur}）"
        else
            run npm install -g @salesforce/cli@latest \
                || { log "WARNING" "Salesforce CLI のアップデートに失敗しました（続行します）"; _warn_if_prefix_unwritable; _mark_failed "Salesforce CLI"; }
        fi
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

# 失敗があれば、成功とは言わず、名前を一覧する（終了コードは 0 のまま。裏で呼ぶ sf-refresh.sh を止めない）
if [[ -n "$failed_steps" ]]; then
    log "WARNING" "更新できなかったものがあります: ${failed_steps}"
else
    log "SUCCESS" "すべてのアップデートが完了しました"
fi
