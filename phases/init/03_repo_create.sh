#!/bin/bash
# ==============================================================================
# 03_repo_create.sh - Phase 3: リポジトリ作成
# ==============================================================================
# GitHub リポジトリ（Private）を作成してクローンし、sf-tools/templates/ の内容をクローンにコピーする。
# リポジトリ・クローンがすでにあるときは、作成・クローンをせずに使う（再実行できる）。
#
# 【使い方】
#   sf-init.sh が、管理者用の作業フォルダ（admin）をカレントにして、bash で呼び出す。
#
# 【処理の流れ】
#   1. 状態ファイルの REPO_FULL_NAME / REPO_DIR / REPO_NAME のいずれかが空なら die
#   2. gh repo view で確認できれば、作成しない（WARNING）。確認できなければ gh repo create --private で作成し、
#      もう一度 gh repo view で確認できなければ die
#   3. クローン
#        - REPO_DIR/.git がある: origin が {GITHUB_OWNER}/{REPO_NAME} でなければ die（大文字と小文字は区別しない）。
#          現在のブランチが main でなければ git checkout main（失敗は die）。origin に main があれば
#          git pull --ff-only origin main（失敗は die）
#        - REPO_DIR はあるが、.git がない: die
#        - REPO_DIR がない: git clone -c core.longpaths=true https://github.com/{REPO_FULL_NAME}.git（失敗は die）
#   4. ${SF_TOOLS_DIR}/templates/ の全ファイル・全フォルダ（. で始まるものを含む）を、cp -r で REPO_DIR にコピーする（失敗は die）。
#      同名のファイルは上書きする。再実行でも同じで、クローンで変更した同名のファイルは、テンプレートの内容に戻る
#   5. REPO_DIR/sfdx-project.json があれば、__REPO_NAME__ を REPO_NAME に置換する（sed_inplace。失敗は die）
#
# 【前提条件】
#   - Phase 2 が書き出した状態ファイル（SF_INIT_ENV_FILE）
#   - 環境変数 SF_TOOLS_DIR（sf-tools のルート。sf-init.sh が export する）
#
# 【補足】
#   - 可視性は、常に Private
#   - sf-tools/templates/ が、雛形の唯一の正本（force-template リポジトリは廃止済み）
#   - core.longpaths=true は、この Phase でクローンしたときだけ付け、クローンの設定に残る（Windows のパスの長さの上限対策。
#     ほかの OS では無視される）。既存のクローンには、設定しない
#   - 終了コード: 0 = OK / 1 = die
# ==============================================================================

# SF_TOOLS_DIR は sf-init.sh（司令塔）から export される
PHASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_TOOLS_DIR="${SF_TOOLS_DIR:-$(dirname "$(dirname "$PHASE_DIR")")}"

readonly SCRIPT_NAME="sf-init"
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true  # run 不使用: common.sh の読み込み前（run が未定義）
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
log "HEADER" "リポジトリ作成"

# --- リポジトリ作成（冪等: すでに存在する場合はスキップ） ---
if run gh repo view "$REPO_FULL_NAME" --json name 2>/dev/null; then
    log "WARNING" "リポジトリはすでに存在します。作成をスキップします: ${REPO_FULL_NAME}"
else
    log "INFO" "GitHub リポジトリを作成中..."
    # 常に Private で作成する（作成の成否は、終了コードではなく、直後の gh repo view で確認する）
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
    # すでにあるクローンは、これから作る（使う）リポジトリのものであること。別のリポジトリのクローン（オーナー違い・
    #   XXXX は同じ）に、このあとの Phase が、コミット・push しないため。大文字と小文字は、区別しない
    clone_matches_repo "$REPO_DIR" "$GITHUB_OWNER" "$REPO_NAME" \
        || die "クローン先（${REPO_DIR}）は、${REPO_FULL_NAME} のクローンではありません（origin: $(git_origin_redacted "$REPO_DIR")）。"
    log "WARNING" "クローン先ディレクトリが既に存在します。クローンをスキップします: ${REPO_DIR}"
    # main にいること（admin ブランチのまま、あとの Phase が git add / commit すると、main に入らず、admin に入ってしまう）
    _cur_branch=$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
    if [[ "$_cur_branch" != "main" ]]; then
        run git -C "$REPO_DIR" checkout main || die "クローンを main に切り替えられません（現在: ${_cur_branch:-不明}）: ${REPO_DIR}"
    fi
    # リモートに main があれば、最新を取り込む（リモートが空の新しいリポジトリでは、取り込まない）
    if git -C "$REPO_DIR" ls-remote --exit-code --heads origin main >/dev/null 2>&1; then  # 条件チェックのため run 不使用
        run git -C "$REPO_DIR" pull --ff-only origin main || die "main を最新にできません（git pull --ff-only に失敗）: ${REPO_DIR}"
    fi
elif [[ -d "$REPO_DIR" ]]; then
    die "クローン先ディレクトリが既に存在しますが Git リポジトリではありません: ${REPO_DIR}
手動で削除してから再実行してください。"
else
    log "INFO" "リポジトリをクローン中..."
    clone_base="$(dirname "$REPO_DIR")"
    run mkdir -p "$clone_base" || die "クローン先ディレクトリを作成できません: $clone_base"
    # core.longpaths=true: Windows のパスの長さの上限（260 文字）対策。設定は、クローン先に残る（あとで、同期したメタデータを
    #   git pull するとき、長い名前のメタデータ（例: DevOps Center の objectTranslations）で、失敗しないため。sf-job.sh も同じ）。
    #   Windows 以外では、無視される
    run git clone -c core.longpaths=true "https://github.com/${REPO_FULL_NAME}.git" "$REPO_DIR" \
        || die "クローンに失敗しました。"
    log "SUCCESS" "リポジトリをクローンしました: ${REPO_DIR}"
fi

# --- テンプレートファイルのコピー（sf-tools/templates/ が正本） ---
tmpl_src="${SF_TOOLS_DIR}/templates"
log "INFO" "テンプレートファイルをコピー中: ${tmpl_src} → ${REPO_DIR}"
run mkdir -p "$REPO_DIR" || die "REPO_DIR を作成できません: $REPO_DIR"
# cp -r でテンプレート配下の全ファイル・ディレクトリをコピー（上書き）
# サブディレクトリ（.github/workflows/, force-app/, .vscode/ 等）も含む
run cp -r "${tmpl_src}/." "$REPO_DIR/" \
    || die "テンプレートファイルのコピーに失敗しました。"
log "SUCCESS" "テンプレートファイルをコピーしました"

# --- sfdx-project.json のプレースホルダー置換 ---
sfdx_json="${REPO_DIR}/sfdx-project.json"
if [[ -f "$sfdx_json" ]]; then
    # sed_inplace（lib/platform.sh）: GNU / BSD（macOS）の sed の、どちらでも動く、その場の置換
    run sed_inplace "s/__REPO_NAME__/${REPO_NAME}/g" "$sfdx_json" \
        || die "sfdx-project.json のプレースホルダー置換に失敗しました。"
    log "SUCCESS" "sfdx-project.json のプロジェクト名を設定しました: ${REPO_NAME}"
fi

log "SUCCESS" "完了: リポジトリ作成 OK。"
exit $RET_OK
