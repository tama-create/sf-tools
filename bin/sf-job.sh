#!/bin/bash
# ==============================================================================
# sf-job.sh - 作業用ブランチの作成とローカル環境セットアップ
# ==============================================================================
# company フォルダをカレントに実行する。ジョブ名（例: JOB-20260323）を入力すると
# GitHub 上にブランチを作成し、ローカルにクローンして sf-start.sh まで一気に実行する。
#
# 【前提フォルダ構成】
#   ~/home/
#   └── {github-owner}/          ← GitHub ユーザー名（フォルダ名から自動取得）
#       └── {company}/           ← このフォルダをカレントにして実行すること
#           └── JOB-xxx/         ← sf-job.sh が作成するジョブフォルダ
#               └── force-company/  ← クローン先
#
# 【処理フロー】
#   Phase 1: 環境チェック（company フォルダから実行されているか確認）
#   Phase 2: プロジェクト情報の確認（フォルダ構成からOWNERとREPO_NAMEを自動導出）
#   Phase 3: ジョブ名の入力と重複チェック（ローカル・GitHub ブランチ）
#   Phase 4: GitHub 上にジョブブランチを作成
#   Phase 5: ローカルにクローン（Windows のパス長の上限対策で、core.longpaths=true を付ける）
#   Phase 6: sf-start.sh を起動（Sandbox 接続・VSCode 起動・sf-launcher.sh 起動）
#
# 【使い方】
#   cd ~/home/{github-owner}/{company}
#   ~/sf-tools/bin/sf-job.sh
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 共通ライブラリの必須設定
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME=$(basename "$0" .sh)
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true
readonly LOG_FILE="$HOME/sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"

# ------------------------------------------------------------------------------
# 2. 共通ライブラリの読み込み
# ------------------------------------------------------------------------------
export SF_INIT_MODE=1   # force-* チェックをバイパス

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

trap '' INT  # Ctrl+C を無効化（q で中断すること）

# ------------------------------------------------------------------------------
# 3. 変数定義
# ------------------------------------------------------------------------------
COMPANY_NAME=""       # company フォルダ名（カレントディレクトリ名）
REPO_NAME=""          # force-company 形式のリポジトリ名
GITHUB_OWNER=""       # GitHub ユーザー名または組織名（1つ上のフォルダ名から自動取得）
REPO_FULL_NAME=""     # OWNER/REPO 形式
JOB_NAME=""           # ジョブ名（例: JOB-20260323）
JOB_DIR=""            # ジョブフォルダの絶対パス
REPO_DIR=""           # クローン先の絶対パス
BASE_BRANCH=""        # ジョブブランチの分岐元ブランチ

# ------------------------------------------------------------------------------
# 4. ヘルパー関数
# ------------------------------------------------------------------------------

# press_enter / read_or_quit は lib/common.sh で定義済み

# ------------------------------------------------------------------------------
# 5. フェーズ定義
# ------------------------------------------------------------------------------

# 【CHECK】company フォルダから実行されているか確認
phase_check_environment() {
    local current_dir
    current_dir=$(basename "$PWD")

    # init フォルダ・force-* フォルダからは実行禁止
    if [[ "$current_dir" == "init" ]]; then
        die "sf-job.sh は init フォルダからは実行できません。
  company フォルダに移動して実行してください:
    cd ..
    ~/sf-tools/bin/sf-job.sh"
    fi
    if [[ "$current_dir" == force-* ]]; then
        die "sf-job.sh は force-* フォルダからは実行できません。
  company フォルダに移動して実行してください:
    cd ../..
    ~/sf-tools/bin/sf-job.sh"
    fi

    log "INFO" "GitHub CLI の認証状態を確認中..."
    if ! run gh auth status; then
        log "WARNING" "GitHub CLI が未認証です。ログインします..."
        run gh auth login || die "GitHub 認証に失敗しました。"
    fi

    log "SUCCESS" "環境チェック完了。"
    return $RET_OK
}

# 【INFO】プロジェクト情報の確認（フォルダ構成から OWNER と REPO_NAME を自動導出）
phase_load_project_info() {
    log "INFO" "プロジェクト情報を確認中..."

    # GITHUB_OWNER / COMPANY_NAME はメイン処理の check_home_dir でセット済み
    REPO_NAME="force-${COMPANY_NAME}"
    REPO_FULL_NAME="${GITHUB_OWNER}/${REPO_NAME}"

    log "INFO" "  GitHub オーナー（フォルダ自動取得）: ${GITHUB_OWNER}"
    log "INFO" "  リポジトリ名（自動導出）: ${REPO_NAME}"

    # リポジトリの存在確認
    if ! gh repo view "$REPO_FULL_NAME" --json name &>/dev/null; then
        die "リポジトリが見つかりません: ${REPO_FULL_NAME}
  フォルダ構成 \"{github-owner}/{company-name}\" から自動導出しました。
  正しいフォルダ構成で実行しているか確認してください:
    ~/home/{github-owner}/{company-name}/"
    fi

    log "SUCCESS" "プロジェクト情報確認完了: ${REPO_FULL_NAME}"
    return $RET_OK
}

# 【JOB】ジョブ名の入力と重複チェック
phase_ask_job_name() {
    log "INFO" "ジョブ名を入力してください。（例: JOB-20260323 / q で中断）"
    echo ""

    while true; do
        read_or_quit JOB_NAME "  ジョブ名："

        if [[ -z "$JOB_NAME" ]]; then
            log "WARNING" "ジョブ名を入力してください。"
            continue
        fi

        # バリデーション: 英数字・ハイフン・アンダースコアのみ・1〜50文字
        if [[ ! "$JOB_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,49}$ ]]; then
            log "WARNING" "無効なジョブ名です。英数字・ハイフン・アンダースコアのみ使用可能です（例: JOB-20260323）"
            JOB_NAME=""
            continue
        fi

        # --- ローカルフォルダの重複チェック ---
        JOB_DIR="${PWD}/${JOB_NAME}"
        if [[ -d "$JOB_DIR" ]]; then
            log "WARNING" "同名のフォルダがすでに存在します: ${JOB_DIR}"
            log "WARNING" "別のジョブ名を入力してください。"
            JOB_NAME=""
            continue
        fi

        # --- GitHub ブランチの重複チェック ---
        log "INFO" "GitHub ブランチの存在を確認中..."
        local branch_exists=0
        for check_branch in develop staging main; do
            if gh api "repos/${REPO_FULL_NAME}/branches/${JOB_NAME}" &>/dev/null 2>&1; then
                branch_exists=1
                break
            fi
        done

        if [[ $branch_exists -eq 1 ]]; then
            log "WARNING" "GitHub 上にすでに同名のブランチが存在します: ${JOB_NAME}"
            log "WARNING" "別のジョブ名を入力してください。"
            JOB_NAME=""
            continue
        fi

        # OK
        break
    done

    REPO_DIR="${JOB_DIR}/${REPO_NAME}"

    echo ""
    echo "  --------------------------------------------------"
    echo "  ジョブ名   : ${JOB_NAME}"
    echo "  ブランチ   : ${JOB_NAME}（${REPO_FULL_NAME} から作成）"
    echo "  クローン先 : ${REPO_DIR}"
    echo "  --------------------------------------------------"
    echo ""
    ask_yn "▶ よろしいですか？" || die "中断しました。"

    return $RET_OK
}

# 【BRANCH】GitHub 上にジョブブランチを作成
phase_create_branch() {
    log "INFO" "分岐元ブランチを確認中..."

    # 作業用ブランチは常に main から作成する
    BASE_BRANCH="main"
    if ! gh api "repos/${REPO_FULL_NAME}/branches/${BASE_BRANCH}" &>/dev/null 2>&1; then
        die "分岐元ブランチ（main）が見つかりません。"
    fi

    log "INFO" "ジョブブランチを作成中: ${JOB_NAME}（分岐元: ${BASE_BRANCH}）"

    # 分岐元ブランチの最新 SHA を取得
    local base_sha
    base_sha=$(gh api "repos/${REPO_FULL_NAME}/branches/${BASE_BRANCH}" --jq '.commit.sha') \
        || die "分岐元ブランチの SHA を取得できません: ${BASE_BRANCH}"

    # ブランチ作成
    run gh api "repos/${REPO_FULL_NAME}/git/refs" \
        --method POST \
        --field "ref=refs/heads/${JOB_NAME}" \
        --field "sha=${base_sha}" \
        || die "ジョブブランチの作成に失敗しました: ${JOB_NAME}"

    log "SUCCESS" "ジョブブランチを作成しました: ${JOB_NAME}"
    return $RET_OK
}

# 【CLONE】ジョブフォルダを作成してクローン
phase_clone_repository() {
    log "INFO" "ジョブフォルダを作成中: ${JOB_DIR}"
    run mkdir -p "$JOB_DIR" || die "ジョブフォルダを作成できません: ${JOB_DIR}"

    log "INFO" "リポジトリをクローン中（ブランチ: ${JOB_NAME}）..."
    # Windows のパスの長さの上限（260 文字）対策: core.longpaths=true を付ける。
    # 設定はクローン先に残り、以降の git add / commit / push にも効く。Windows 以外では無視される。
    # 組織に長い名前のメタデータ（例: DevOps Center の objectTranslations）があると、付けないと clone のチェックアウトに失敗する
    run git clone -c core.longpaths=true \
        --branch "${JOB_NAME}" \
        "https://github.com/${REPO_FULL_NAME}.git" \
        "$REPO_DIR" \
        || die "クローンに失敗しました。"

    log "SUCCESS" "クローン完了: ${REPO_DIR}"
    return $RET_OK
}

# 【START】sf-start.sh を起動（Sandbox 接続・VSCode 起動）
phase_sf_start() {
    log "INFO" "sf-start.sh を起動します..."
    cd "$REPO_DIR" || die "ディレクトリに移動できません: ${REPO_DIR}"

    # インタラクティブなため run を使わない（run 内の pipe が read プロンプトを破壊する）
    bash "$SCRIPT_DIR/sf-start.sh" \
        || die "sf-start.sh の実行に失敗しました。"

    return $RET_OK
}

# ------------------------------------------------------------------------------
# 6. メイン実行フロー
# ------------------------------------------------------------------------------
log "HEADER" "作業環境セットアップを開始します (${SCRIPT_NAME}.sh)"

check_home_dir            # GITHUB_OWNER / COMPANY_NAME をセット（失敗時は die）
check_gh_owner "$GITHUB_OWNER"

log "INFO" "中断するには q を入力してください。"

phase_check_environment   || die "環境チェックに失敗しました。"

phase_load_project_info   || die "プロジェクト情報の読み込みに失敗しました。"

phase_ask_job_name        || die "ジョブ名の入力に失敗しました。"

phase_create_branch       || die "ジョブブランチの作成に失敗しました。"

phase_clone_repository    || die "クローンに失敗しました。"

phase_sf_start            || die "sf-start.sh の実行に失敗しました。"

exit $RET_OK
