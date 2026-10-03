#!/bin/bash
# ==============================================================================
# 09_repo_rules.sh - Phase 9: GitHub リポジトリ設定・Ruleset の適用
# ==============================================================================
# 新規リポジトリの基本設定と Ruleset を GitHub API で設定する。
#
#   1. リポジトリ基本設定（マージ設定・デフォルトブランチ等）
#   2. Ruleset: protect-main の作成（削除禁止・強制プッシュ禁止・必須チェック）
#   3. Ruleset: protect-staging の作成（同上）
#
# 無料プランでは Ruleset が利用できない場合があるため、失敗は WARNING 扱い。
# ==============================================================================

# SF_TOOLS_DIR は sf-init.sh（司令塔）から export される
PHASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_TOOLS_DIR="${SF_TOOLS_DIR:-$(dirname "$(dirname "$PHASE_DIR")")}"

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

# ------------------------------------------------------------------------------
# メイン処理
# ------------------------------------------------------------------------------
log "HEADER" "Phase 9: GitHub リポジトリ設定・Ruleset の適用"

# --- 1. リポジトリ基本設定 ---
log "INFO" "[1/3] リポジトリ基本設定を適用中..."

if run gh repo edit "$REPO_FULL_NAME" \
    --default-branch main \
    --enable-issues \
    --enable-projects \
    --enable-wiki \
    --enable-discussions=false \
    --enable-merge-commit \
    --enable-squash-merge \
    --enable-rebase-merge \
    --delete-branch-on-merge=false; then
    log "SUCCESS" "リポジトリ基本設定を適用しました。"
else
    log "WARNING" "リポジトリ基本設定の適用に失敗しました。手動で設定してください。"
fi

# --- 2. Ruleset: protect-main ---
log "INFO" "[2/3] Ruleset: protect-main を作成中..."

# 既存の protect-main を削除（冪等性確保）
EXISTING_MAIN_ID=$(gh api "repos/${REPO_FULL_NAME}/rulesets" \
    --jq '.[] | select(.name=="protect-main") | .id' 2>/dev/null || echo "")  # 変数代入のため run 不要
if [[ -n "$EXISTING_MAIN_ID" ]]; then
    run gh api --method DELETE "repos/${REPO_FULL_NAME}/rulesets/${EXISTING_MAIN_ID}" \
        || log "WARNING" "既存の protect-main (id: ${EXISTING_MAIN_ID}) の削除に失敗しました。"
    log "INFO" "既存の protect-main (id: ${EXISTING_MAIN_ID}) を削除しました。"
fi

if run gh api --method POST "repos/${REPO_FULL_NAME}/rulesets" \
    --input - << 'EOF'
{
  "name": "protect-main",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["refs/heads/main"],
      "exclude": []
    }
  },
  "bypass_actors": [
    {
      "actor_id": 5,
      "actor_type": "RepositoryRole",
      "bypass_mode": "always"
    }
  ],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "do_not_enforce_on_create": false,
        "required_status_checks": [
          { "context": "validate / 対象ファイル確認", "integration_id": 15368 },
          { "context": "validate / デプロイ検証", "integration_id": 15368 },
          { "context": "sequence / 対象ファイル確認", "integration_id": 15368 },
          { "context": "sequence / 順序チェック", "integration_id": 15368 }
        ]
      }
    }
  ]
}
EOF
then
    log "SUCCESS" "protect-main を作成しました。"
else
    log "WARNING" "protect-main の作成に失敗しました（無料プランでは利用不可の場合があります）。"
fi

# --- 3. Ruleset: protect-staging ---
log "INFO" "[3/3] Ruleset: protect-staging を作成中..."

# 既存の protect-staging を削除（冪等性確保）
EXISTING_STAGING_ID=$(gh api "repos/${REPO_FULL_NAME}/rulesets" \
    --jq '.[] | select(.name=="protect-staging") | .id' 2>/dev/null || echo "")  # 変数代入のため run 不要
if [[ -n "$EXISTING_STAGING_ID" ]]; then
    run gh api --method DELETE "repos/${REPO_FULL_NAME}/rulesets/${EXISTING_STAGING_ID}" \
        || log "WARNING" "既存の protect-staging (id: ${EXISTING_STAGING_ID}) の削除に失敗しました。"
    log "INFO" "既存の protect-staging (id: ${EXISTING_STAGING_ID}) を削除しました。"
fi

if run gh api --method POST "repos/${REPO_FULL_NAME}/rulesets" \
    --input - << 'EOF'
{
  "name": "protect-staging",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["refs/heads/staging"],
      "exclude": []
    }
  },
  "bypass_actors": [
    {
      "actor_id": 5,
      "actor_type": "RepositoryRole",
      "bypass_mode": "always"
    }
  ],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": false,
        "do_not_enforce_on_create": false,
        "required_status_checks": [
          { "context": "validate / 対象ファイル確認", "integration_id": 15368 },
          { "context": "validate / デプロイ検証", "integration_id": 15368 },
          { "context": "sequence / 対象ファイル確認", "integration_id": 15368 },
          { "context": "sequence / 順序チェック", "integration_id": 15368 }
        ]
      }
    }
  ]
}
EOF
then
    log "SUCCESS" "protect-staging を作成しました。"
else
    log "WARNING" "protect-staging の作成に失敗しました（無料プランでは利用不可の場合があります）。"
fi

# --- 4. SF_TOOLS_BRANCH GitHub Variable 登録（検証環境のみ）---
if [[ "${SF_TOOLS_BRANCH:-main}" == "development" ]]; then
    log "INFO" "SF_TOOLS_BRANCH=development を GitHub Variable に登録中..."
    if run gh variable set SF_TOOLS_BRANCH --body "development" -R "$REPO_FULL_NAME"; then
        log "SUCCESS" "SF_TOOLS_BRANCH=development を登録しました。GitHub Actions は sf-tools development ブランチを使用します。"
    else
        log "WARNING" "SF_TOOLS_BRANCH の登録に失敗しました。手動で設定してください:"
        log "WARNING" "  gh variable set SF_TOOLS_BRANCH --body \"development\" -R \"${REPO_FULL_NAME}\""
    fi
fi

log "SUCCESS" "Phase 9 完了: GitHub リポジトリ設定・Ruleset の適用 OK。"

exit $RET_OK
