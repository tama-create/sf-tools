#!/bin/bash
# ==============================================================================
# 09_repo_rules.sh - Phase 9: GitHub リポジトリ設定・Ruleset の適用
# ==============================================================================
# リポジトリの基本設定と Ruleset（protect-main / protect-staging）を、GitHub API で設定する。
# 開発版（SF_TOOLS_BRANCH=development）のときは、Variable SF_TOOLS_BRANCH も登録する。
#
# 【使い方】
#   sf-init.sh が、管理者用の作業フォルダ（admin）をカレントにして、bash で呼び出す。
#
# 【処理の流れ】
#   1. gh repo edit で基本設定を適用する（失敗は WARNING）
#        既定のブランチ main・Issues / Projects / Wiki を有効・Discussions を無効・
#        マージコミット / スカッシュ / リベースのマージをすべて許可・マージ後のブランチの自動削除を無効
#   2. Ruleset protect-main: 同名の Ruleset を削除してから（delete_existing_ruleset）、作成する（失敗は WARNING）
#        対象      : refs/heads/main
#        ルール    : 削除の禁止・強制プッシュの禁止（non_fast_forward）・必須のステータスチェック 3 つ
#                    （対象ファイル確認・デプロイ検証・順序チェック。名前は、ワークフローの「ジョブ名」だけで、ワークフロー名は
#                    含めない: 「validate / 対象ファイル確認」の形では、永久に満たされず、PR がマージできなくなる
#                    （2026-10-24 に、実際の GitHub で確認）。名前は required_status_check_names（lib/project.sh）が正本。
#                    integration_id 15368 = GitHub Actions。strict なし）
#        バイパス  : RepositoryRole の ID 5（リポジトリの Admin ロール）。bypass_mode は always
#   3. Ruleset protect-staging: 対象を refs/heads/staging にして、手順 2 と同じ内容で作成する。
#      ブランチ構成（BRANCH_COUNT）に関係なく作成する
#   4. SF_TOOLS_BRANCH が development のときだけ、Variable SF_TOOLS_BRANCH=development を登録する（失敗は WARNING）。
#      main のときは、登録しない
#
# 【前提条件】
#   - Phase 2 が書き出した状態ファイル（REPO_FULL_NAME。空なら die。SF_TOOLS_BRANCH は、未設定なら main として扱う）
#   - 環境変数 SF_TOOLS_DIR（sf-tools のルート。未設定のときは、このファイルの 2 つ上のフォルダ）
#
# 【補足】
#   - 失敗を WARNING にする理由: 無料プランの Private リポジトリなど、Ruleset が使えない場合があるため。
#     手順 1〜4 のどれが失敗しても、終了コードは 0
#   - delete_existing_ruleset（init-common.sh）: 同名の Ruleset の ID を取得して削除する（再実行のため）。
#     ID は数字のときだけ有効とみなす（gh api が失敗すると、エラーの応答本文が標準出力に出るため）。
#     確認できなかった場合は WARNING を表示して削除しない。削除の成否は、そのまま表示する
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
log "HEADER" "GitHub リポジトリ設定・Ruleset の適用"

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

# 必須のステータスチェックの JSON（名前は、ワークフローの「ジョブ名」だけ。ワークフロー名は含めない。
# 「validate / 対象ファイル確認」の形は、永久に満たされず、PR がマージできなくなる: required_status_check_names（lib/project.sh））
checks_json=""
while IFS= read -r _check_name; do
    [[ -n "$_check_name" ]] || continue
    checks_json="${checks_json:+${checks_json},
          }{ \"context\": \"${_check_name}\", \"integration_id\": 15368 }"
done < <(required_status_check_names)
unset _check_name

# --- 2. Ruleset: protect-main ---
log "INFO" "[2/3] Ruleset: protect-main を作成中..."

# 既存の protect-main を削除（冪等性確保）
delete_existing_ruleset "$REPO_FULL_NAME" "protect-main"

if run gh api --method POST "repos/${REPO_FULL_NAME}/rulesets" \
    --input - << EOF
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
          ${checks_json}
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
delete_existing_ruleset "$REPO_FULL_NAME" "protect-staging"

if run gh api --method POST "repos/${REPO_FULL_NAME}/rulesets" \
    --input - << EOF
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
          ${checks_json}
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

# --- 4. SF_TOOLS_BRANCH GitHub Variable 登録（開発版 = SF_TOOLS_BRANCH=development のときのみ）---
if [[ "${SF_TOOLS_BRANCH:-main}" == "development" ]]; then
    log "INFO" "SF_TOOLS_BRANCH=development を GitHub Variable に登録中..."
    if run gh variable set SF_TOOLS_BRANCH --body "development" -R "$REPO_FULL_NAME"; then
        log "SUCCESS" "SF_TOOLS_BRANCH=development を登録しました。GitHub Actions は sf-tools development ブランチを使用します。"
    else
        log "WARNING" "SF_TOOLS_BRANCH の登録に失敗しました。手動で設定してください:"
        log "WARNING" "  gh variable set SF_TOOLS_BRANCH --body \"development\" -R \"${REPO_FULL_NAME}\""
    fi
fi

log "SUCCESS" "完了: GitHub リポジトリ設定・Ruleset の適用 OK。"

exit $RET_OK
