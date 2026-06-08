#!/bin/bash
# ==============================================================================
# sf-install.sh - sf-tools の最新化・プロジェクト初期セットアップスクリプト
# ==============================================================================
# sf-start.sh のバックグラウンドから自動呼び出しされますが、単独実行も有効です。
# ※ 時間のかかるツールアップデートは sf-upgrade.sh に委譲し、バックグラウンドで最後に実行。
#
# 【処理の流れ】
#   1. ~/sf-tools を git pull で最新化
#   2. sf-tools/config/ 配下の設定ファイルを生成（未存在時のみ）
#   3. Git フック (pre-push) をインストール
#   4. リリース管理ディレクトリの準備 & branch_name.txt を更新
#   5. コミットメッセージテンプレートを設置（.gitmessage）
#   6. package.json があれば npm install を実行（時間がかかる場合あり）
#   7. 開発ツールのアップデート（sf-upgrade.sh をバックグラウンドで起動）※24 時間に 1 回のみ
#
# 【WF について】
#   GitHub Actions ワークフローは sf-init.sh（Phase 3）が sf-tools/templates/ からコピーするため、
#   sf-install.sh では管理しない。WF はセルフコンテインド（ロジック内包）設計であり、
#   sf-tools リポジトリへの実行時依存はない。
#
# 【前提】
#   ~/sf-tools は初回インストール済みであること。
#   初回インストール: git clone https://github.com/tama-create/sf-tools.git ~/sf-tools
#
# 【オプション】
#   -v, --verbose       : コマンドの応答（出力）をコンソールにも表示します
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 共通ライブラリの必須設定
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME=$(basename "$0" .sh)
readonly LOG_FILE="./sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"


# ------------------------------------------------------------------------------
# 2. 共通ライブラリの読み込み
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

# ------------------------------------------------------------------------------
# 3. 初期チェック
# ------------------------------------------------------------------------------
log "HEADER" "sf-tools のセットアップを開始します (${SCRIPT_NAME}.sh)"

trap 'rm -f ./sf-tools/cmd_out_'"$$"'_*.tmp 2>/dev/null' EXIT

# ------------------------------------------------------------------------------
# 4. 定数定義
# ------------------------------------------------------------------------------
readonly TARGET_DIR="$HOME/sf-tools"
readonly UPDATE_STAMP_FILE="$HOME/.sf-tools-last-update"
readonly UPDATE_INTERVAL_SEC=86400  # 24時間（秒）

# _get_mtime - ファイルの更新タイムスタンプ（Unix秒）を取得する（macOS / Linux / Git Bash 対応）
_get_mtime() {
    local file="$1"
    if [[ "$(uname -s)" == Darwin* ]]; then
        stat -f "%m" "$file" 2>/dev/null || echo 0
    else
        stat -c "%Y" "$file" 2>/dev/null || echo 0
    fi
}

# _is_tool_update_needed - 前回のツールアップデートから一定時間が経過しているか判定
# 戻り値: 0=実行が必要 / 1=スキップ可
_is_tool_update_needed() {
    [[ ! -f "$UPDATE_STAMP_FILE" ]] && return 0
    local last_update elapsed
    last_update=$(_get_mtime "$UPDATE_STAMP_FILE")
    elapsed=$(( $(date +%s) - last_update ))
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
        return $RET_OK
    fi
    log "INFO" "sf-tools を最新化します (${TARGET_DIR})..."
    local branch
    branch=$(git -C "$TARGET_DIR" symbolic-ref --short HEAD 2>/dev/null || echo "main")
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


# 【NPM INSTALL】依存パッケージのインストール（毎回実行）
phase_npm_install() {
    if [[ ! -f "./package.json" ]]; then
        log "INFO" "package.json が見つかりません。npm install をスキップします。"
        return $RET_OK
    fi
    # node_modules/.package-lock.json が package-lock.json より新しければスキップ
    # （_get_mtime は macOS / Linux / Git Bash 共通）
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

# 【HOOK】Git フック (pre-push) のインストール
phase_setup_hook() {
    log "INFO" "Git フックをインストールします..."
    run bash "$SCRIPT_DIR/sf-hook.sh" "$@" || return $RET_NG
    return $RET_OK
}

# 【RELEASE DIR】リリース管理ディレクトリの準備 & ブランチ名保存
phase_setup_release_dir() {
    log "INFO" "リリース管理用のディレクトリを準備します..."
    local branch_name
    branch_name=$(run git symbolic-ref --short HEAD 2>/dev/null || echo "")
    if [[ -z "$branch_name" ]]; then
        log "WARNING" "ブランチ名を取得できませんでした。スキップします。"
        return $RET_OK
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
    if [[ ! -f "$template" ]]; then
        log "WARNING" "gitmessage テンプレートが見つかりません: $template"
        return $RET_OK
    fi
    run cp "$template" ".gitmessage" || return $RET_NG
    git config commit.template .gitmessage
    log "INFO" "コミットメッセージテンプレートを設置しました (.gitmessage)"
    return $RET_OK
}

# 【UPGRADE】開発ツールのアップデート（バックグラウンド実行）
phase_upgrade_tools_bg() {
    if _is_tool_update_needed; then
        log "INFO" "開発ツールのアップデートをバックグラウンドで開始します（sf-upgrade.sh）..."
        if [[ ! -f "$SCRIPT_DIR/sf-upgrade.sh" ]]; then
            log "WARNING" "sf-upgrade.sh が見つかりません。スキップします。"
            return $RET_OK
        fi
        bash "$SCRIPT_DIR/sf-upgrade.sh" "$@" >/dev/null 2>>"$LOG_FILE" &  # stdout は sf-upgrade.sh の自前ログへ・stderr はこのスクリプトのログへ記録
        local bg_pid=$!
        if kill -0 "$bg_pid" 2>/dev/null; then
            run touch "$UPDATE_STAMP_FILE"
            log "INFO" "次回の自動アップデートは $((UPDATE_INTERVAL_SEC / 3600)) 時間後です。"
        else
            log "WARNING" "sf-upgrade.sh の起動を確認できませんでした。スタンプは更新しません。"
        fi
    else
        local last_update elapsed_h
        last_update=$(_get_mtime "$UPDATE_STAMP_FILE")
        elapsed_h=$(( ( $(date +%s) - last_update ) / 3600 ))
        log "INFO" "開発ツールは ${elapsed_h} 時間前にアップデート済みのためスキップします（間隔: $((UPDATE_INTERVAL_SEC / 3600))h）。"
    fi

    return $RET_OK
}

# ------------------------------------------------------------------------------
# 6. メインフロー
# ------------------------------------------------------------------------------
if phase_update; then
    log "SUCCESS" "sf-tools を最新化しました。"
else
    log "WARNING" "sf-tools の最新化に失敗しました（続行します）"
fi

if [[ -n "${SF_INIT_RUNNING:-}" ]]; then
    # sf-init 時: テンプレートから設定ファイルを生成
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

if phase_setup_release_dir; then
    log "SUCCESS" "リリース管理ディレクトリの準備が完了しました。"
else
    log "WARNING" "リリース管理ディレクトリの準備に失敗しました（続行します）"
fi

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
