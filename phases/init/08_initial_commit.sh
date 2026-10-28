#!/bin/bash
# ==============================================================================
# 08_initial_commit.sh - Phase 8: 初回コミット＆プッシュ
# ==============================================================================
# クローンの変更を初回コミットし、PAT（PAT_TOKEN_VALUE）で main と、branches.txt の main 以外のブランチを push する。
# 最後に sf-hook.sh で pre-commit / pre-push フックを入れなおす。
#
# 【使い方】
#   sf-init.sh が、管理者用の作業フォルダ（admin）をカレントにして、bash で呼び出す。
#
# 【処理の流れ】
#   1. 状態ファイルの REPO_DIR / REPO_FULL_NAME / PAT_TOKEN_VALUE のいずれかが空なら die
#   2. REPO_DIR で git add -A。ステージに差分があれば git commit -m "chore: sf-tools 初期セットアップ"（失敗は die）。
#      差分がなければ、コミットしない。--no-verify を付けないため、Phase 4 で入れた pre-commit フックが実行される
#   3. git -c credential.helper= push --no-verify origin main（失敗は die）
#   4. sf-tools/config/branches.txt の、コメント・空行・main 以外の各ブランチについて:
#        origin にあれば、何もしない。なければ、現在の main から git checkout -B <ブランチ> → push --no-verify -u →
#        git checkout main（いずれも失敗は die）
#   5. 状態ファイルから PAT_TOKEN_VALUE の行を削除する（sed_inplace。失敗したとき・削除のあとに行が残っているときは die。
#      Token が平文のまま残るため。sf-init.sh の後処理でも、Token の値の行を消す）
#   6. bash sf-hook.sh を実行し、pre-commit / pre-push フックを上書きで入れなおす（失敗は die）
#
# 【前提条件】
#   - Phase 3〜5 で用意したクローン（REPO_DIR）と branches.txt
#   - Phase 6 が状態ファイルに書き出した PAT_TOKEN_VALUE（repo + workflow スコープ）
#   - 環境変数 SF_TOOLS_DIR（sf-tools のルート。sf-init.sh が export する）
#
# 【補足】
#   - PAT を使う理由: gh の OAuth 認証は workflow スコープを持たないため、ワークフロー（.github/workflows/）を含む
#     push には PAT を使う
#   - PAT の渡し方: Token は URL やコマンドの引数に含めない（コマンドのログ・.git/config・プロセス一覧に残さないため）。
#     GIT_ASKPASS（一時スクリプト。終了時に trap で削除）と環境変数 SF_INIT_PUSH_TOKEN で git に渡し、
#     -c credential.helper= で gh などの認証ヘルパーを無効にする。origin の URL は書き換えない
#   - 手順 2〜4 で die したときは、PAT_TOKEN_VALUE の行は状態ファイルに残る（手順 5 に進まないため。続きから再開するとき、
#     この Phase が、もう一度使う）
#   - 一時スクリプト（GIT_ASKPASS）の書き込み・chmod 700 の失敗は die
#   - 終了コード: 0 = OK / 1 = die
# ==============================================================================

# SF_TOOLS_DIR は sf-init.sh（司令塔）から export される
PHASE_DIR="${BASH_SOURCE[0]%/*}"
[[ "$PHASE_DIR/" == /* && "$PHASE_DIR/" != *//* && "$PHASE_DIR/" != */./* && "$PHASE_DIR/" != */../* ]] || PHASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

[[ -z "$REPO_DIR" ]]          && die "REPO_DIR が未設定です。Phase 2 が完了しているか確認してください。"
[[ -z "$REPO_FULL_NAME" ]]    && die "REPO_FULL_NAME が未設定です。Phase 2 が完了しているか確認してください。"
[[ -z "$PAT_TOKEN_VALUE" ]]   && die "PAT_TOKEN_VALUE が未設定です。Phase 6 が完了しているか確認してください。"

# ------------------------------------------------------------------------------
# メイン処理
# ------------------------------------------------------------------------------
log "HEADER" "初回コミット＆プッシュ"

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
# run 不使用: ファイル生成（ヒアドキュメントのリダイレクト。失敗は die）
cat > "$askpass_script" << 'ASKEOF' || die "一時ファイルに書き込めません: ${askpass_script}"
#!/bin/bash
# GIT_ASKPASS: Username には固定値、Password には環境変数の Token を返す
case "$1" in
    Username*) echo "x-access-token" ;;
    *)         echo "$SF_INIT_PUSH_TOKEN" ;;
esac
ASKEOF
run chmod 700 "$askpass_script" || die "一時ファイルに実行の権限を付けられません: ${askpass_script}"
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
        if git -c credential.helper= ls-remote --exit-code --heads origin "$branch" > /dev/null 2>&1; then  # 条件チェックのため run 不使用
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

# push が完了したら、PAT を .sf-init.env に残さない（後続フェーズでは使用しない）。
#   削除できなかったら die（Token が平文のまま残るため。WARNING で続けない）。削除のあとに、行が残っていないことも確かめる
unset GIT_ASKPASS SF_INIT_PUSH_TOKEN
run sed_inplace '/^PAT_TOKEN_VALUE=/d' "$SF_INIT_ENV_FILE" \
    || die "状態ファイルから PAT_TOKEN_VALUE の行を削除できませんでした: ${SF_INIT_ENV_FILE}"
if grep -q '^PAT_TOKEN_VALUE=' "$SF_INIT_ENV_FILE" 2>/dev/null; then  # 条件チェックのため run 不使用
    die "状態ファイルに PAT_TOKEN_VALUE の行が残っています: ${SF_INIT_ENV_FILE}"
fi

log "SUCCESS" "初回コミット＆プッシュ完了。"

# pre-commit / pre-push フックを、上書きで入れなおす
# （フックは Phase 4 の sf-install.sh でも入れている。この Phase の push は --no-verify のため、フックを実行しない）
log "INFO" "pre-push フックをインストール中..."
run bash "${SF_TOOLS_DIR}/bin/sf-hook.sh" \
    || die "sf-hook.sh の実行に失敗しました。"

log "SUCCESS" "完了: 初回コミット＆プッシュ OK。"
exit $RET_OK
