#!/bin/bash
# ==============================================================================
# 08_initial_commit.sh - Phase 8: 初回コミット＆プッシュ
# ==============================================================================
# リポジトリに変更があれば初回コミットし、PAT_TOKEN_VALUE を使って push する。
# push 後に sf-hook.sh で pre-push フックをインストールする。
#
# 【PAT 使用理由】
#   gh の OAuth 認証は workflow スコープを持たないため、
#   ワークフロー YML を含む push には PAT（repo + workflow スコープ）を使用する。
#
# 【PAT の渡し方】
#   Token は URL やコマンドの引数に含めない（コマンドのログ・.git/config・プロセス一覧に残さないため）。
#   GIT_ASKPASS（一時スクリプト。終了時に削除）と環境変数 SF_INIT_PUSH_TOKEN で git に渡し、
#   -c credential.helper= で gh 等の認証ヘルパーを無効化して PAT を確実に使う。origin の URL は書き換えない。
#   push が完了したら、.sf-init.env から PAT_TOKEN_VALUE の行を削除する。
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

[[ -z "$REPO_DIR" ]]          && die "REPO_DIR が未設定です。Phase 2 が完了しているか確認してください。"
[[ -z "$REPO_FULL_NAME" ]]    && die "REPO_FULL_NAME が未設定です。Phase 2 が完了しているか確認してください。"
[[ -z "$PAT_TOKEN_VALUE" ]]   && die "PAT_TOKEN_VALUE が未設定です。Phase 6 が完了しているか確認してください。"

# ------------------------------------------------------------------------------
# メイン処理
# ------------------------------------------------------------------------------
log "HEADER" "Phase 8: 初回コミット＆プッシュ"

log "INFO" "初回コミット＆プッシュを実行中..."

cd "$REPO_DIR" || die "ディレクトリに移動できません: $REPO_DIR"

run git add -A \
    || die "git add に失敗しました。"

# ステージングに差分がなければコミット不要
# if による条件チェックのため run を使わない（run を使うと戻り値が変わる）
if git diff --cached --quiet 2>/dev/null; then
    log "INFO" "コミットする変更がありません。コミットをスキップします。"
else
    log "INFO" "変更ファイル:"
    run git status --short

    run git commit -m "chore: sf-tools 初期セットアップ" \
        || die "git commit に失敗しました。"
fi

# PAT トークン（workflow スコープ付き）で push
# gh の OAuth 認証は workflow スコープを持たないため PAT を使用する。
# Token は URL やコマンドの引数に含めず、GIT_ASKPASS（一時スクリプト）経由で git に渡す
# （コマンドのログ・.git/config・プロセス一覧に Token が残らないようにするため）。
# origin の URL は書き換えない。-c credential.helper= で gh 等の認証ヘルパーを無効化し、PAT を確実に使う。
askpass_script=$(mktemp "${TMPDIR:-/tmp}/sf-init-askpass.XXXXXX") \
    || die "一時ファイルを作成できません。"  # VAR=$(cmd) 形式のため run 不要
trap 'rm -f "$askpass_script"' EXIT
cat > "$askpass_script" << 'ASKEOF'
#!/bin/bash
# GIT_ASKPASS: Username には固定値、Password には環境変数の Token を返す
case "$1" in
    Username*) echo "x-access-token" ;;
    *)         echo "$SF_INIT_PUSH_TOKEN" ;;
esac
ASKEOF
chmod 700 "$askpass_script"
export GIT_ASKPASS="$askpass_script" GIT_TERMINAL_PROMPT=0 SF_INIT_PUSH_TOKEN="$PAT_TOKEN_VALUE"

# main をプッシュ（.github/workflows/ を含むため workflow スコープ付き PAT が必須）
run git -c credential.helper= push --no-verify origin main \
    || die "git push に失敗しました。"

# main 以外のブランチを作成・プッシュ
# Phase 5 では branches.txt の更新のみ行い、リモートブランチ作成はここで実施する
branches_file="${REPO_DIR}/sf-tools/config/branches.txt"
if [[ -f "$branches_file" ]]; then
    while IFS= read -r branch || [[ -n "$branch" ]]; do
        branch="${branch%$'\r'}"
        [[ "$branch" =~ ^[[:space:]]*# ]] && continue  # コメント行スキップ
        [[ -z "${branch// }" ]]            && continue  # 空行スキップ
        [[ "$branch" == "main" ]]          && continue  # main はスキップ
        # リモートに既に存在するか確認
        if git -c credential.helper= ls-remote --exit-code --heads origin "$branch" > /dev/null 2>&1; then
            log "INFO" "${branch} — スキップ（既に存在）"
            continue
        fi
        run git checkout -B "$branch" \
            || die "${branch} ブランチの作成に失敗しました。"
        run git -c credential.helper= push --no-verify -u origin "$branch" \
            || die "${branch} ブランチのプッシュに失敗しました。"
        run git checkout main \
            || die "main への切り替えに失敗しました。"
        log "SUCCESS" "${branch} ブランチを作成しました。"
    done < "$branches_file"
fi

# push が完了したら、PAT を .sf-init.env に残さない（後続フェーズでは使用しない）
unset GIT_ASKPASS SF_INIT_PUSH_TOKEN
run sed -i '/^PAT_TOKEN_VALUE=/d' "$SF_INIT_ENV_FILE"

log "SUCCESS" "初回コミット＆プッシュ完了。"

# 初回コミット後に pre-push フックをインストール
# （main への直接 push をブロックするため先に入れない）
log "INFO" "pre-push フックをインストール中..."
run bash "${SF_TOOLS_DIR}/bin/sf-hook.sh" \
    || die "sf-hook.sh の実行に失敗しました。"

log "SUCCESS" "Phase 8 完了: 初回コミット＆プッシュ OK。"
exit $RET_OK
