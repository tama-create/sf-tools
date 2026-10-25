#!/bin/bash
# ==============================================================================
# sf-install.sh - sf-tools の最新化・プロジェクト初期セットアップスクリプト
# ==============================================================================
# ~/sf-tools を最新化し、カレントの force-* プロジェクトに、Git フック・リリース管理ディレクトリなどを準備する。
# sf-start.sh がバックグラウンドで、sf-init.sh が Phase 4 で、自動で呼び出す。単独でも実行できる。
# 時間のかかる開発ツールのアップデートは、sf-upgrade.sh に任せ、最後にバックグラウンドで起動する。
#
# 【使い方】
#   bash ~/sf-tools/bin/sf-install.sh [オプション]     # force-* ディレクトリで実行する
#
# 【オプション】
#   -v, --verbose : コマンドの応答（出力）をコンソールにも表示する（sf-hook.sh にも引き渡す。sf-upgrade.sh には引き渡さない）
#   -h, --help    : このヘルプを表示して終了する（第 1 引数に指定したときのみ）
#   ※ そのほかの引数は、「不明なオプションです」と表示して中断する（sf-hook.sh に渡るのは、受け付けた -v / --verbose だけ）
#
# 【処理の流れ】
#   1. sf の確認: sf --version の終了コードが 0 以外なら、ERROR で案内を表示する。中断はしない
#      （中断すると、sf-tools 自身の最新化まで止まるため）。sf が未インストールのとき・GitHub Actions 上では、確認しない
#   2. ~/sf-tools の現在のブランチ（取得できなければ main）を git pull origin <ブランチ> で最新化する。
#      失敗しても WARNING を表示して続行する。sf-init.sh から呼ばれたとき（SF_INIT_RUNNING が空でない）は、スキップする
#   3. 設定ファイル ./sf-tools/config/metadata.txt・branches.txt を確認する
#      - sf-init.sh から呼ばれたとき: 存在しないものだけ、~/sf-tools/templates/sf-tools/config/ からコピーする。失敗したら中断する
#      - それ以外: どちらかが存在しなければ、中断する（プロジェクトの破損として扱う。生成はしない）
#   4. Git フック（pre-commit / pre-push）を sf-hook.sh でインストールする。失敗しても WARNING を表示して続行する
#   5. リリース管理ディレクトリを準備する。失敗しても WARNING を表示して続行する
#      - 現在のブランチ名を取得できない（git symbolic-ref -q --short HEAD の終了コードが 0 以外。detached HEAD など）ときは、
#        WARNING を表示して、何もしない
#      - ./sf-tools/release/ と ./sf-tools/release/.gitkeep を作成する
#      - main ブランチのときは、ここで終わる（release/<ブランチ>/ と branch_name.txt は、作成・更新しない）
#      - それ以外のブランチ: release/<ブランチ>/ を作成し、deploy-target.txt・remove-target.txt が無ければ
#        ~/sf-tools/templates/sf-tools/release/__BRANCH__/ からコピーし、release/branch_name.txt にブランチ名を書き込む
#   6. （sf-init.sh から呼ばれたときのみ）~/sf-tools/templates/gitmessage を ./.gitmessage にコピーし、
#      git config commit.template .gitmessage を設定する。テンプレートが無い・コピーか設定に失敗したときは、WARNING を表示して
#      続行する（完了の SUCCESS は表示しない）
#   7. ./package.json があれば、npm install を実行する。失敗しても WARNING を表示して続行する。次のときは、スキップする:
#      - sf-init.sh から呼ばれたとき（sf-init が、このクローンで行うのは、ファイルの準備とプッシュだけで、node_modules を
#        使わないため。npm install は、のちに sf-start.sh からこのスクリプトを実行したときに行われる）
#      - node_modules/.package-lock.json の更新時刻が、package-lock.json の更新時刻以上のとき
#        （package-lock.json が無いときは、スキップしない）
#   8. ~/.sf-tools-last-update が無い、またはその更新時刻から 24 時間以上たっていれば、sf-upgrade.sh をバックグラウンドで
#      起動する（引数なし。標準出力は捨て、標準エラーは ./sf-tools/logs/sf-install.log に追記する）。
#      起動を確認できたら、~/.sf-tools-last-update の更新時刻を更新する（完了の時点ではなく、起動の時点）
#
# 【前提条件】
#   - force-* ディレクトリ（フォルダ名が force- で始まる）で実行すること。それ以外では lib/common.sh が終了する
#     （終了コード 1。SF_INIT_MODE=1 のときは、確認しない）
#   - ~/sf-tools は初回インストール済みであること
#     初回インストール: git clone https://github.com/tama-create/sf-tools.git ~/sf-tools
#   - Salesforce CLI（sf）は npm 版（npm install -g @salesforce/cli）であること（手順 1 の確認は、警告のみ）
#
# 【補足】
#   - 終了コード: 0。手順 3 で中断したとき・不明なオプションのときは 1。手順 3 以外の失敗は、WARNING を表示して続行する
#   - GitHub Actions のワークフロー（.github/workflows/）は扱わない。新規作成時は sf-init.sh（Phase 3）が
#     ~/sf-tools/templates/ からコピーし、作成済みのプロジェクトへの反映は sf-sync-wf.sh（管理者が手動で実行）が行う
#   - ログ: ./sf-tools/logs/sf-install.log（実行ごとに作り直す）
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 共通ライブラリの必須設定
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME=$(basename "$0" .sh)  # run 不使用: common.sh の読み込み前（run が未定義）
readonly LOG_FILE="./sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"


# ------------------------------------------------------------------------------
# 2. 共通ライブラリの読み込み
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # run 不使用: common.sh の読み込み前（run が未定義）
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
reject_unknown_args "$@"   # -v / --verbose 以外の引数は、不明なオプションとして中断する

# ------------------------------------------------------------------------------
# 3. 初期チェック
# ------------------------------------------------------------------------------
log "HEADER" "sf-tools のセットアップを開始します (${SCRIPT_NAME}.sh)"

# sf が終了コードを正しく返すか確認する（npm 版が前提）。
# 警告のみで続行する: ここで中断すると、sf-tools 自身の最新化（git pull）まで止まってしまうため
check_sf_cli --warn-only || true  # 警告のみのため、戻り値は無視（意図的エラー無視）

# ------------------------------------------------------------------------------
# 4. 定数定義
# ------------------------------------------------------------------------------
readonly TARGET_DIR="$HOME/sf-tools"
readonly UPDATE_STAMP_FILE="$HOME/.sf-tools-last-update"
readonly UPDATE_INTERVAL_SEC=86400  # 24時間（秒）

# _get_mtime - ファイルの更新タイムスタンプ（Unix秒）を取得する（macOS / Linux / Git Bash 対応）
_get_mtime() {
    local file="$1"
    if [[ "$(uname -s)" == Darwin* ]]; then  # 条件チェックのため run 不使用
        stat -f "%m" "$file" 2>/dev/null || echo 0  # run 不使用: 更新時刻を標準出力で返すため（ファイルがなければ 0）
    else
        stat -c "%Y" "$file" 2>/dev/null || echo 0  # run 不使用: 同上
    fi
}

# _is_tool_update_needed - 前回のツールアップデートから一定時間が経過しているか判定
# 戻り値: 0=実行が必要 / 1=スキップ可
_is_tool_update_needed() {
    [[ ! -f "$UPDATE_STAMP_FILE" ]] && return 0
    local last_update elapsed
    last_update=$(_get_mtime "$UPDATE_STAMP_FILE")
    elapsed=$(( $(date +%s) - last_update ))  # VAR=$(cmd) のため run 不使用（現在時刻の取得）
    [[ $elapsed -ge $UPDATE_INTERVAL_SEC ]]
}

# ------------------------------------------------------------------------------
# 5. フェーズ定義
# ------------------------------------------------------------------------------

# 【UPDATE】sf-tools を最新化
phase_update() {
    # sf-init.sh から呼ばれた場合は git pull をスキップ
    # （bash が sf-init.sh を実行中に git pull で sf-init.sh が書き換わると読み位置がずれてエラーになるため）
    if [[ -n "${SF_INIT_RUNNING:-}" ]]; then
        log "INFO" "sf-init.sh から実行中のため sf-tools の git pull をスキップします。"
        UPDATE_SKIPPED=1  # メインフローで「最新化しました」と誤表示しないための目印
        return $RET_OK
    fi
    log "INFO" "sf-tools を最新化します (${TARGET_DIR})..."
    local branch
    branch=$(git -C "$TARGET_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "main")  # VAR=$(cmd) のため run 不使用
    run git -C "$TARGET_DIR" pull origin "$branch" || return $RET_NG
    return $RET_OK
}

# 【CONFIG】設定ファイルの初期化（未存在時のみテンプレートからコピー）
phase_init_config() {
    log "INFO" "設定ファイルを確認します..."
    run mkdir -p "sf-tools/config"
    local file
    for file in metadata.txt branches.txt; do
        if [[ ! -f "sf-tools/config/$file" ]]; then
            run cp "$HOME/sf-tools/templates/sf-tools/config/$file" "sf-tools/config/$file" \
                || return $RET_NG
            log "INFO" "sf-tools/config/$file を生成しました。"
        else
            log "INFO" "sf-tools/config/$file は既に存在します。スキップします。"
        fi
    done
    return $RET_OK
}


# 【NPM INSTALL】依存パッケージのインストール（package.json があり、sf-init 外で、node_modules が古いときのみ）
phase_npm_install() {
    if [[ ! -f "./package.json" ]]; then
        log "INFO" "package.json が見つかりません。npm install をスキップします。"
        return $RET_OK
    fi
    # sf-init.sh から呼ばれた場合は、スキップする。
    # （sf-init が、このクローン（管理者用の作業フォルダの admin/force-XXXX。セットアップ後も残る）で行うのは、ファイルの準備と
    #   プッシュだけで、node_modules を使わないため。eslint / prettier / jest などの取得に、約 90 秒かかっていた。
    #   npm install は、のちに sf-start.sh から、このスクリプトを実行したときに、通常どおり行われる）
    if [[ -n "${SF_INIT_RUNNING:-}" ]]; then
        log "INFO" "sf-init.sh から実行中のため npm install をスキップします（sf-init は、ファイルの準備とプッシュだけを行うため）。"
        return $RET_OK
    fi
    # node_modules/.package-lock.json の更新時刻が、package-lock.json の更新時刻以上（同じか新しい）ならスキップ
    # （package-lock.json がない（更新時刻 0）ときは、スキップしない。_get_mtime は macOS / Linux / Git Bash 共通）
    local lock_mtime node_mtime
    lock_mtime=$(_get_mtime "./package-lock.json")
    node_mtime=$(_get_mtime "./node_modules/.package-lock.json")
    if [[ $lock_mtime -gt 0 && $node_mtime -ge $lock_mtime ]]; then
        log "INFO" "node_modules は最新のため npm install をスキップします。"
        return $RET_OK
    fi
    log "INFO" "npm install を実行します..."
    run npm install || log "WARNING" "npm install に失敗しました（続行します）"
    return $RET_OK
}

# 【HOOK】Git フック (pre-commit / pre-push) のインストール（sf-hook.sh に引数をそのまま渡す）
phase_setup_hook() {
    log "INFO" "Git フックをインストールします..."
    run bash "$SCRIPT_DIR/sf-hook.sh" "$@" || return $RET_NG
    return $RET_OK
}

# 【RELEASE DIR】リリース管理ディレクトリの準備 & ブランチ名保存
phase_setup_release_dir() {
    log "INFO" "リリース管理用のディレクトリを準備します..."
    local branch_name
    # run 不使用: 終了コードで判定するため（run は、失敗しても、エラーの文言を標準出力に返す。以前は、detached HEAD のとき、
    #   「fatal: ref HEAD is not a symbolic ref」がブランチ名として入り、その名前のフォルダと branch_name.txt を作っていた）
    if ! branch_name=$(git symbolic-ref -q --short HEAD) || [[ -z "$branch_name" ]]; then
        log "WARNING" "現在のブランチ名を取得できませんでした（detached HEAD など）。リリース管理ディレクトリの準備をスキップします。"
        return $RET_NO_CHANGE
    fi
    run mkdir -p "sf-tools/release" || return $RET_NG
    [[ ! -f "sf-tools/release/.gitkeep" ]] && run touch "sf-tools/release/.gitkeep"
    if [[ "$branch_name" == "main" ]]; then
        log "INFO" "main ブランチはリリース対象外のため、release/<branch> ディレクトリの作成をスキップします。"
        return $RET_OK
    fi
    local release_dir="sf-tools/release/${branch_name}"
    run mkdir -p "$release_dir" || return $RET_NG
    [[ ! -f "${release_dir}/deploy-target.txt" ]] \
        && { run cp "$HOME/sf-tools/templates/sf-tools/release/__BRANCH__/deploy-target.txt" "${release_dir}/deploy-target.txt" || return $RET_NG; }
    [[ ! -f "${release_dir}/remove-target.txt" ]] \
        && { run cp "$HOME/sf-tools/templates/sf-tools/release/__BRANCH__/remove-target.txt" "${release_dir}/remove-target.txt" || return $RET_NG; }
    printf '%s\n' "$branch_name" | run tee "sf-tools/release/branch_name.txt" > /dev/null || return $RET_NG
    log "INFO" "ブランチ: ${branch_name} / branch_name.txt を保存しました"
    return $RET_OK
}

# 【GITMESSAGE】コミットメッセージテンプレートの設置
phase_setup_gitmessage() {
    local template="$HOME/sf-tools/templates/gitmessage"
    # テンプレートが無いときは、失敗として返す（以前は、WARNING のあと成功を返し、メインフローが「設置が完了しました」も表示していた）
    if [[ ! -f "$template" ]]; then
        log "WARNING" "gitmessage テンプレートが見つかりません: $template"
        return $RET_NG
    fi
    run cp "$template" ".gitmessage" || return $RET_NG
    # 以前は run を使わず、戻り値も見ていなかった（設定に失敗しても、設置の完了と表示していた）
    run git config commit.template .gitmessage || return $RET_NG
    log "INFO" "コミットメッセージテンプレートを設置しました (.gitmessage)"
    return $RET_OK
}

# 【UPGRADE】開発ツールのアップデート（バックグラウンド実行）
# shellcheck disable=SC2120  # 受け取った "$@" を、そのまま sf-upgrade.sh に渡す（現在のメインフローは、引数を渡さない）
phase_upgrade_tools_bg() {
    if _is_tool_update_needed; then
        log "INFO" "開発ツールのアップデートをバックグラウンドで開始します（sf-upgrade.sh）..."
        if [[ ! -f "$SCRIPT_DIR/sf-upgrade.sh" ]]; then
            log "WARNING" "sf-upgrade.sh が見つかりません。スキップします。"
            return $RET_OK
        fi
        bash "$SCRIPT_DIR/sf-upgrade.sh" "$@" >/dev/null 2>>"$LOG_FILE" &  # バックグラウンド起動のため run 不使用。stdout は捨て（sf-upgrade.sh は自前のログに記録する）、stderr（画面への表示）はこのスクリプトのログへ追記
        local bg_pid=$!
        if kill -0 "$bg_pid" 2>/dev/null; then  # 条件チェック（起動の確認）のため run 不使用
            run touch "$UPDATE_STAMP_FILE"
            log "INFO" "次回の自動アップデートは $((UPDATE_INTERVAL_SEC / 3600)) 時間後です。"
        else
            log "WARNING" "sf-upgrade.sh の起動を確認できませんでした。スタンプは更新しません。"
        fi
    else
        local last_update elapsed_h
        last_update=$(_get_mtime "$UPDATE_STAMP_FILE")
        elapsed_h=$(( ( $(date +%s) - last_update ) / 3600 ))  # VAR=$(cmd) のため run 不使用（現在時刻の取得）
        log "INFO" "開発ツールは ${elapsed_h} 時間前にアップデート済みのためスキップします（間隔: $((UPDATE_INTERVAL_SEC / 3600))h）。"
    fi

    return $RET_OK
}

# ------------------------------------------------------------------------------
# 6. メインフロー
# ------------------------------------------------------------------------------
if phase_update; then
    if [[ -n "${UPDATE_SKIPPED:-}" ]]; then
        log "INFO" "sf-tools の最新化はスキップしました。"
    else
        log "SUCCESS" "sf-tools を最新化しました。"
    fi
else
    log "WARNING" "sf-tools の最新化に失敗しました（続行します）"
fi

if [[ -n "${SF_INIT_RUNNING:-}" ]]; then
    # sf-init 時: 存在しない設定ファイルだけ、テンプレートからコピーする（失敗したら中断）
    phase_init_config || die "設定ファイルの初期化に失敗しました。"
    log "SUCCESS" "設定ファイルの確認が完了しました。"
else
    # 通常起動時: 設定ファイルが存在しなければプロジェクト破損 → エラー終了
    for _cfg in "sf-tools/config/metadata.txt" "sf-tools/config/branches.txt"; do
        [[ ! -f "$_cfg" ]] && die "設定ファイルが見つかりません: ${_cfg}"
    done
    log "SUCCESS" "設定ファイルの確認が完了しました。"
fi

if phase_setup_hook "$@"; then
    log "SUCCESS" "Git フックのインストールが完了しました。"
else
    log "WARNING" "Git フックのインストールに失敗しました（続行します）"
fi

phase_setup_release_dir; _release_rc=$?
if [[ $_release_rc -eq $RET_OK ]]; then
    log "SUCCESS" "リリース管理ディレクトリの準備が完了しました。"
elif [[ $_release_rc -eq $RET_NG ]]; then
    log "WARNING" "リリース管理ディレクトリの準備に失敗しました（続行します）"
fi  # RET_NO_CHANGE（準備をスキップした）のときは、phase 内で WARNING を出し済み

# sf-init からの呼び出し時のみ実行（テンプレートコピーを伴う初期セットアップ）
if [[ -n "${SF_INIT_RUNNING:-}" ]]; then
    if phase_setup_gitmessage; then
        log "SUCCESS" "コミットメッセージテンプレートの設置が完了しました。"
    else
        log "WARNING" "コミットメッセージテンプレートの設置に失敗しました（続行します）"
    fi
fi

phase_npm_install
log "SUCCESS" "npm install の確認が完了しました。"

phase_upgrade_tools_bg

exit $RET_OK
