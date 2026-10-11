#!/bin/bash
# ==============================================================================
# add_tier.sh - ブランチ tier の追加（staging / develop）
# ==============================================================================
# 既存プロジェクトに staging または develop 階層を追加する。
# sf-init.sh --add-tier から呼び出される。
#
# 【処理フロー】
#   1. .sf-init.env を読み込んでプロジェクト情報を取得
#   2. 追加 tier のバリデーション（すでに存在する場合はエラー）
#   3. Salesforce 組織に接続する（先に行う）: ログイン先の選択 → ログイン → 種類の読み取り → 本番は main のみのガード
#      → 外部クライアントアプリの自動作成 → JWT 認証情報（SF_CONSUMER_KEY_xxx / SF_USERNAME_xxx / SF_INSTANCE_URL_xxx）を登録
#      （--legacy-connected-app のときは、コンシューマー鍵・ユーザー名を手動で入力）。接続できなければ、何も変更しない
#   4. GitHub にブランチを作成
#   5. 作業用ブランチで branches.txt を更新し、PR を作成する（main へは、直接 push しない）
#
# 【登録する Secrets / Variables】
#   staging 追加時: SF_CONSUMER_KEY_STG（Secret）/ SF_USERNAME_STG / SF_INSTANCE_URL_STG（Variable）
#   develop 追加時: SF_CONSUMER_KEY_DEV（Secret）/ SF_USERNAME_DEV / SF_INSTANCE_URL_DEV（Variable）
# ==============================================================================

# SF_TOOLS_DIR は sf-init.sh（司令塔）から export される
PHASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_TOOLS_DIR="${SF_TOOLS_DIR:-$(dirname "$PHASE_DIR")}"

readonly SCRIPT_NAME="sf-init"
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true
readonly LOG_FILE="$HOME/sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"
export SF_INIT_MODE=1

source "${SF_TOOLS_DIR}/lib/common.sh"
source "${SF_TOOLS_DIR}/phases/init/init-common.sh"

# ------------------------------------------------------------------------------
# 引数取得
# ------------------------------------------------------------------------------
ADD_TIER="${ADD_TIER:-}"  # sf-init.sh から export される
[[ -z "$ADD_TIER" ]] && die "ADD_TIER が未設定です。"

# ------------------------------------------------------------------------------
# 1. force-* ディレクトリであること確認
# ------------------------------------------------------------------------------
log "HEADER" "tier 追加: ${ADD_TIER}"

check_force_dir || die "force-* ディレクトリ内で実行してください。"

# ------------------------------------------------------------------------------
# 2. .sf-init.env を読み込む
# ------------------------------------------------------------------------------
BRANCHES_FILE="${PWD}/sf-tools/config/branches.txt"
SF_INIT_ENV_FILE="${PWD}/sf-tools/config/.sf-init.env"

# .sf-init.env が見つからない場合は git remote から REPO_FULL_NAME を導出する
if [[ -f "$SF_INIT_ENV_FILE" ]]; then
    source "$SF_INIT_ENV_FILE"
else
    # VAR=$(cmd) 形式のため run 不使用
    remote_url=$(git remote get-url origin 2>/dev/null) || die ".sf-init.env が見つからず、git remote も取得できません。"
    REPO_FULL_NAME=$(echo "$remote_url" | sed 's|.*github\.com[:/]\(.*\)\.git|\1|; s|.*github\.com[:/]\(.*\)|\1|')
    REPO_NAME=$(basename "$REPO_FULL_NAME")
fi

[[ -z "$REPO_FULL_NAME" ]] && die "REPO_FULL_NAME が取得できません。"
[[ -z "$REPO_NAME"      ]] && die "REPO_NAME が取得できません。"

# ------------------------------------------------------------------------------
# 3. 追加 tier のバリデーション
# ------------------------------------------------------------------------------
case "$ADD_TIER" in
    staging)
        SUFFIX="STG"
        LABEL="ステージング組織"
        ORG_ALIAS="staging"
        ;;
    develop)
        SUFFIX="DEV"
        LABEL="開発組織"
        ORG_ALIAS="develop"
        ;;
    *)
        die "--add-tier には staging または develop を指定してください。"
        ;;
esac

# branches.txt に既に存在するか確認
if [[ -f "$BRANCHES_FILE" ]]; then
    if grep -qx "$ADD_TIER" "$BRANCHES_FILE" 2>/dev/null; then
        die "${ADD_TIER} はすでに branches.txt に登録されています。"
    fi
fi

# develop を追加する場合は staging が先に存在するか確認
if [[ "$ADD_TIER" == "develop" ]]; then
    if ! grep -qx "staging" "$BRANCHES_FILE" 2>/dev/null; then
        die "develop を追加するには先に staging が必要です。先に --add-tier staging を実行してください。"
    fi
fi

log "INFO" "  対象リポジトリ: ${REPO_FULL_NAME}"
log "INFO" "  追加 tier     : ${ADD_TIER}（${LABEL}）"

# 管理者向けの警告と確認（CLAUDE.md 2.4）。GITHUB_ACTIONS=true のときも、省略しない（Actions 上で実行する想定がない）
echo -e "${CLR_ERR}╔══════════════════════════════════════════════════════╗${CLR_RESET}" >&2
echo -e "${CLR_ERR}║  !!  このコマンドは管理者専用です                    ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║      段階（ブランチ）と、Salesforce 組織への接続を   ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║      追加します。Secrets / Variables が書き換わります║${CLR_RESET}" >&2
echo -e "${CLR_ERR}╚══════════════════════════════════════════════════════╝${CLR_RESET}" >&2
log "WARNING" "途中で失敗しても、Salesforce 側に作った外部クライアントアプリと、登録した Secrets は、自動では、元に戻しません。"
check_gh_owner "${REPO_FULL_NAME%%/*}"
ask_yn "  続行しますか？" || die "中断しました。"

# 未コミットの変更があると、main への切り替え・ブランチの作成で、衝突するため、先に確認する
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then  # 条件チェックのため run 不使用
    die "未コミットの変更があります。コミットまたは退避してから、実行してください。"
fi

# ------------------------------------------------------------------------------
# 4. Salesforce 組織に接続する（先に行う: 本番組織は main にしか、つなげない。接続できなければ、何も変更しない）
# ------------------------------------------------------------------------------
log "HEADER" "Step 1: ${LABEL} を、Salesforce 組織に接続します。"

JWT_DIR="$HOME/.sf-jwt/${REPO_NAME}"
[[ ! -f "${JWT_DIR}/server.key" ]] && die "秘密鍵が見つかりません: ${JWT_DIR}/server.key
  sf-init Phase 10 を先に実行してください。"

if [[ "${SF_INIT_LEGACY_CONNECTED_APP:-}" == "1" ]]; then
    # 従来の接続アプリケーション（今後廃止予定）: コンシューマー鍵・ユーザー名を、手動で入力する
    register_jwt_secret "$ORG_ALIAS" "$SUFFIX" "$LABEL" "${JWT_DIR}/server.key"
else
    # 既定: 外部クライアントアプリケーション（自動で作成する）
    [[ ! -f "${JWT_DIR}/server.crt" ]] && die "証明書が見つかりません: ${JWT_DIR}/server.crt"
    register_jwt_secret_eca "$ORG_ALIAS" "$SUFFIX" "$LABEL" "${JWT_DIR}/server.key" "${JWT_DIR}/server.crt"
fi

# ------------------------------------------------------------------------------
# 5. branches.txt の更新と、ブランチの追加
#    main への直接 push は、しない（main は、保護されているため）。作業用のブランチで、branches.txt を更新し、
#    PR を作成する。PR をマージすると、branches.txt が main に反映される（管理者が、マージする）
# ------------------------------------------------------------------------------
log "HEADER" "Step 2: ${ADD_TIER} ブランチを追加します。"

run git checkout main || die "main ブランチへの切り替えに失敗しました。"

# 5-1. リモートに ${ADD_TIER} ブランチを作成（main から派生）
if git ls-remote --exit-code --heads origin "$ADD_TIER" > /dev/null 2>&1; then
    # 条件チェックのため run 不使用
    log "INFO" "${ADD_TIER} ブランチはリモートに既に存在します（スキップ）。"
else
    run git checkout -b "$ADD_TIER"  || die "${ADD_TIER} ブランチの作成に失敗しました。"
    run git push --no-verify -u origin "$ADD_TIER" \
        || die "${ADD_TIER} ブランチのプッシュに失敗しました。"
    run git checkout main            || die "main ブランチへの切り替えに失敗しました。"
    log "SUCCESS" "${ADD_TIER} ブランチを作成しました。"
fi

# 5-2. 作業用のブランチで branches.txt を更新し、PR を作成する
PR_BRANCH="system-add-tier-${ADD_TIER}-$(date +%Y%m%d%H%M%S)"   # 秒まで含める（同じ分の再実行で、衝突しないため）
run git checkout -b "$PR_BRANCH" || die "作業用ブランチの作成に失敗しました: ${PR_BRANCH}"

TMP_BRANCH_FILE="${BRANCHES_FILE}.tmp"
{
    if [[ -f "$BRANCHES_FILE" ]]; then
        # 既存コメント行を保持
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            echo "$line"
        done < "$BRANCHES_FILE"
    fi
    echo "$ADD_TIER"
} > "$TMP_BRANCH_FILE"
run mv "$TMP_BRANCH_FILE" "$BRANCHES_FILE"
log "SUCCESS" "branches.txt に ${ADD_TIER} を追記しました。"

run git add sf-tools/config/branches.txt \
    || die "git add に失敗しました。"
run git commit --no-verify -m "chore: ${ADD_TIER} tier を追加" \
    || die "git commit に失敗しました。"
# --no-verify: この push は、作業用ブランチへの、管理者による自動の操作のため、pre-push フック（検証の実行）を省く
run git push --no-verify -u origin "$PR_BRANCH" \
    || die "git push に失敗しました（作業用ブランチ: ${PR_BRANCH}。Salesforce への接続は、完了しています）。"

PR_URL=$(run gh pr create --base main --head "$PR_BRANCH" -R "$REPO_FULL_NAME" \
    --title "chore: ${ADD_TIER} tier を追加" \
    --body "branches.txt に ${ADD_TIER} を追加します（sf-init.sh --add-tier ${ADD_TIER} で作成）。マージすると、段階として有効になります。") \
    || die "PR の作成に失敗しました。"  # VAR=$(cmd) のため、PR の URL を取得する
run git checkout main || die "main ブランチへの切り替えに失敗しました。"

log "SUCCESS" "tier 追加の準備ができました: ${ADD_TIER}（${LABEL}）"
log "INFO"    "次のステップ:"
log "INFO"    "  ・PR をマージしてください（マージすると、branches.txt が main に反映されます）: $(echo "$PR_URL" | tail -n 1)"
log "INFO"    "  ・GitHub Actions（wf-release / wf-validate）が ${ADD_TIER} ブランチに対して動作することを確認してください。"
log "INFO"    "  ・いまの接続を見る: sf-init.sh --status"

exit $RET_OK
