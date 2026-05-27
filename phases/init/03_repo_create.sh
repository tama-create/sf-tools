#!/bin/bash
# ==============================================================================
# 03_repo_create.sh - Phase 3: リポジトリ作成
# ==============================================================================
# GitHub リポジトリを作成し、ローカルにクローンする。
# リポジトリ・クローン先が既に存在する場合はスキップ（冪等）。
#
# 【可視性ルール】
#   常に Private で作成する。
#
# 【テンプレートファイルの配布】
#   クローン後に sf-tools/templates/ の全ファイルを REPO_DIR/ にコピーする。
#   force-template リポジトリは廃止済み。sf-tools/templates/ が唯一の正本。
#   sfdx-project.json の __REPO_NAME__ プレースホルダーを実際のリポジトリ名に置換する。
# ==============================================================================

# SF_TOOLS_DIR は sf-init.sh（司令塔）から export される
PHASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_TOOLS_DIR="${SF_TOOLS_DIR:-$(dirname "$PHASE_DIR")}"

readonly SCRIPT_NAME="sf-init"
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true
readonly LOG_FILE="$HOME/sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="APPEND"  # 司令塔が NEW で初期化済みのため追記
export SF_INIT_MODE=1

source "${SF_TOOLS_DIR}/lib/common.sh"
source "${SF_TOOLS_DIR}/phases/init/init-common.sh"

# 変数の復元（前フェーズで書き出した .sf-init.env を読み込む）
SF_INIT_ENV_FILE="${SF_INIT_ENV_FILE:-${PWD}/.sf-init.env}"
[[ -f "$SF_INIT_ENV_FILE" ]] && source "$SF_INIT_ENV_FILE"

[[ -z "$REPO_FULL_NAME" ]] && die "REPO_FULL_NAME が未設定です。Phase 2 が完了しているか確認してください。"
[[ -z "$REPO_DIR" ]]       && die "REPO_DIR が未設定です。Phase 2 が完了しているか確認してください。"
[[ -z "$REPO_NAME" ]]      && die "REPO_NAME が未設定です。Phase 2 が完了しているか確認してください。"

# ------------------------------------------------------------------------------
# メイン処理
# ------------------------------------------------------------------------------
log "HEADER" "Phase 3: リポジトリ作成"

# --- リポジトリ作成（冪等: すでに存在する場合はスキップ） ---
if run gh repo view "$REPO_FULL_NAME" --json name 2>/dev/null; then
    log "WARNING" "リポジトリはすでに存在します。作成をスキップします: ${REPO_FULL_NAME}"
else
    log "INFO" "GitHub リポジトリを作成中..."
    # 常に Private で作成する
    run gh repo create "$REPO_FULL_NAME" --private
    if ! run gh repo view "$REPO_FULL_NAME" --json name 2>/dev/null; then
        die "リポジトリの作成に失敗しました。
考えられる原因:
  - GitHub ユーザー名・組織名が誤っている（入力値: ${GITHUB_OWNER}）
  - GitHub CLI の認証トークンの権限が不足している → gh auth status で確認
詳細は ~/sf-tools/logs/sf-init.log を確認してください。"
    fi
    log "SUCCESS" "リポジトリを作成しました: ${REPO_FULL_NAME}"
fi

# --- クローン（冪等: すでに存在する場合はスキップ） ---
if [[ -d "$REPO_DIR/.git" ]]; then
    log "WARNING" "クローン先ディレクトリが既に存在します。クローンをスキップします: ${REPO_DIR}"
elif [[ -d "$REPO_DIR" ]]; then
    die "クローン先ディレクトリが既に存在しますが Git リポジトリではありません: ${REPO_DIR}
手動で削除してから再実行してください。"
else
    log "INFO" "リポジトリをクローン中..."
    clone_base="$(dirname "$REPO_DIR")"
    run mkdir -p "$clone_base" || die "クローン先ディレクトリを作成できません: $clone_base"
    run git clone "https://github.com/${REPO_FULL_NAME}.git" "$REPO_DIR" \
        || die "クローンに失敗しました。"
    log "SUCCESS" "リポジトリをクローンしました: ${REPO_DIR}"
fi

# --- テンプレートファイルのコピー（sf-tools/templates/ が正本） ---
tmpl_src="${SF_TOOLS_DIR}/templates"
log "INFO" "テンプレートファイルをコピー中: ${tmpl_src} → ${REPO_DIR}"
run mkdir -p "$REPO_DIR" || die "REPO_DIR を作成できません: $REPO_DIR"
# cp -r でテンプレート配下の全ファイル・ディレクトリをコピー（上書き）
# サブディレクトリ（.github/workflows/, force-app/, .vscode/ 等）も含む
cp -r "${tmpl_src}/." "$REPO_DIR/" \
    || die "テンプレートファイルのコピーに失敗しました。"
log "SUCCESS" "テンプレートファイルをコピーしました"

# --- sfdx-project.json のプレースホルダー置換 ---
sfdx_json="${REPO_DIR}/sfdx-project.json"
if [[ -f "$sfdx_json" ]]; then
    # sed の -i はGitBash/macOS/Linuxで動作（インプレース置換）
    sed -i "s/__REPO_NAME__/${REPO_NAME}/g" "$sfdx_json" \
        || die "sfdx-project.json のプレースホルダー置換に失敗しました。"
    log "SUCCESS" "sfdx-project.json のプロジェクト名を設定しました: ${REPO_NAME}"
fi

log "SUCCESS" "Phase 3 完了: リポジトリ作成 OK。"
exit $RET_OK
