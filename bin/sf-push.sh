#!/bin/bash
# ==============================================================================
# sf-push.sh - カレント配下をコミットしてプッシュ
# ==============================================================================
# 現在のディレクトリ配下の変更をステージし、VS Code で入力したコミットメッセージで commit / push する。
# ステージする変更がなく、未プッシュのコミットがあるときは、push だけ行う（コミット後に push が失敗したときの再実行用）。
#
# 【使い方】
#   sf-push.sh [オプション]
#
# 【オプション】
#   -v, --verbose  : コマンドの応答（出力）をコンソールにも表示する
#   -h, --help     : このヘルプを表示して終了する（1 つ目の引数のときだけ）
#   上記以外の引数は、「不明なオプションです」と表示して中断する。
#
# 【処理の流れ】
#   1. 現在のブランチを確認する。次のときは、何も変更せず、エラーで終了する
#      （コミットだけが手元に残り、プッシュは通らない状態を、作らないため）
#        - HEAD がブランチを指していない（detached HEAD）
#        - 保護ブランチ（sf-tools/config/branches.txt に書かれたブランチ。ファイルがない・空のときは main）の上にいる
#   2. git fetch origin main → git merge origin/main --no-edit で、origin/main を現在のブランチに取り込む
#      （現在のブランチが main のときは行わない）。早送りできないときは、マージのコミットが作られる。
#      マージに失敗したとき（コンフリクトなど）は、git merge --abort して、エラーで終了する
#   3. カレント配下だけを git add --all でステージする
#   4. カレント配下に、ステージ済みの変更がなければ:
#        - 未プッシュのコミット（@{u}..HEAD）があれば、コミットせず、git push だけ行って終了する
#          （2 で取り込んだコミットも、未プッシュのコミットに数える）
#        - なければ、何もせず終了する（追跡先（upstream）がないときは、未プッシュ 0 件として扱う）
#   5. sf-check.sh（引数なし）でターゲットファイルを検証する。エラーなら終了する
#   6. VS Code（code --new-window --wait）で、コミットメッセージの入力ファイルを開き、閉じるまで待つ
#   7. # で始まる行と空行を除いた内容が空なら、コミット・プッシュせず終了する
#      （2 で取り込んだ結果と、3 のステージは、元に戻さず、そのまま残る）
#   8. git commit -F（入力したメッセージ）→ git push を実行する
#
# 【前提条件】
#   - 現在のディレクトリの名前が force- で始まること（lib/common.sh が確認する）
#   - Git リポジトリの中であること。git と code（VS Code のコマンド）が使えること
#
# 【補足】
#   - 8 の git commit は、パスを指定しない。カレント配下の外で、前からステージ済みの変更も、一緒にコミットされる
#   - 4 の「変更なし」の判定は、カレント配下だけを見る
#   - 8 の git commit / git push では、インストール済みの pre-commit / pre-push フックも動く
#   - 終了コード: 0 = 正常終了（何もせず終了した場合を含む） / 1 = エラー
#   - ログ: ./sf-tools/logs/sf-push.log（実行のたびに作り直す）
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. common.sh 用の事前設定
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
reject_unknown_args "$@"   # -v / --verbose 以外の引数は、不明なオプションとして中断する

# ------------------------------------------------------------------------------
# 3. 必須コマンドのチェック
# ------------------------------------------------------------------------------
command -v git  >/dev/null 2>&1 || die "コマンドが見つかりません: git"
command -v code >/dev/null 2>&1 || die "コマンドが見つかりません: code"

# ------------------------------------------------------------------------------
# 4. リポジトリ情報の取得
# ------------------------------------------------------------------------------
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || die "現在のディレクトリから Git リポジトリを見つけられません。"

BRANCH_NAME="$(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null || git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null)" \
    || die "Git のブランチ名を取得できません。"

# ブランチの上にいない（detached HEAD）と、コミットしても、どのブランチにも残らない。コミットの前に止める
git -C "$REPO_ROOT" symbolic-ref --quiet HEAD >/dev/null 2>&1 \
    || die "HEAD がブランチを指していません（detached HEAD: ${BRANCH_NAME}）。"
# 保護ブランチ（main など）は、直接プッシュできない。コミットだけが手元に残るため、コミットの前に止める
if is_protected_branch "$BRANCH_NAME"; then
    die "${BRANCH_NAME} は保護ブランチです（ここでは、コミットもプッシュも行いません）。"
fi

REL_PREFIX="$(git rev-parse --show-prefix 2>/dev/null || true)"
if [[ -n "$REL_PREFIX" ]]; then
    TARGET_PATHSPEC="${REL_PREFIX%/}"
else
    TARGET_PATHSPEC="."
fi

# ------------------------------------------------------------------------------
# 5. 開始ログ
# ------------------------------------------------------------------------------
log "HEADER" "カレント配下のコミット・プッシュを開始します (${SCRIPT_NAME}.sh)"
log "INFO" "対象: ${BRANCH_NAME}"

# ------------------------------------------------------------------------------
# 6. origin/main を取り込む（コンフリクトがあればエラー中止）
# ------------------------------------------------------------------------------
if [[ "$BRANCH_NAME" != "main" ]]; then
    log "INFO" "origin/main を取り込みます。"
    run git -C "$REPO_ROOT" fetch origin main \
        || die "git fetch に失敗しました。"
    if ! run git -C "$REPO_ROOT" merge origin/main --no-edit; then
        git -C "$REPO_ROOT" merge --abort 2>/dev/null || true  # マージ中断（例外: エラー無視）
        die "origin/main とのマージでコンフリクトが発生しました。手動で解決してください。"
    fi
fi

# ------------------------------------------------------------------------------
# 7. カレント配下だけをステージング
# ------------------------------------------------------------------------------
run git -C "$REPO_ROOT" add --all -- "$TARGET_PATHSPEC" \
    || die "git add に失敗しました。"

if git -C "$REPO_ROOT" diff --cached --quiet -- "$TARGET_PATHSPEC"; then
    # 変更がなくても、未プッシュのコミットがあれば、プッシュだけ行う
    #   （コミットは成功し、プッシュが失敗した後の再実行で、取り残されないように）。追跡先（upstream）がないときは、0 件として扱う
    _unpushed=$(git -C "$REPO_ROOT" rev-list --count '@{u}..HEAD' 2>/dev/null) || _unpushed=0  # VAR=$(cmd) のため run 不使用
    if [[ "$_unpushed" =~ ^[0-9]+$ && "$_unpushed" -gt 0 ]]; then
        log "INFO" "未プッシュのコミットが ${_unpushed} 件あります。コミットはせず、プッシュだけ行います。"
        run git -C "$REPO_ROOT" push \
            || die "git push に失敗しました。"
        log "SUCCESS" "未プッシュのコミットのプッシュが完了しました。"
        exit $RET_OK
    fi
    log "WARNING" "現在のディレクトリ配下に、コミット対象の変更がありません。"
    exit $RET_OK
fi

# ------------------------------------------------------------------------------
# 8. ターゲットファイルの検証（sf-check.sh）
# ------------------------------------------------------------------------------
log "INFO" "sf-check.sh でターゲットファイルを検証します。"
run bash "${SCRIPT_DIR}/sf-check.sh" \
    || die "ターゲットファイルの検証に失敗しました。コミットを中止します。"

# ------------------------------------------------------------------------------
# 9. コミットメッセージ入力ファイルを作成
# ------------------------------------------------------------------------------
COMMIT_MSG_FILE="$(mktemp "${TMPDIR:-/tmp}/sf-push-commit-msg.XXXXXX.txt")" \
    || die "一時ファイルの作成に失敗しました。"
trap 'rm -f "$COMMIT_MSG_FILE"' EXIT

printf '%s\n' \
    "# 1行目に要約を書いてください。" \
    "# 例: deploy-target.txt を更新" \
    "#" \
    "# 必要なら詳細を下に書いてください。" \
    > "$COMMIT_MSG_FILE"

# ------------------------------------------------------------------------------
# 10. VS Code で入力してもらう
# ------------------------------------------------------------------------------
log "INFO" "VS Code でコミットメッセージ入力画面を開きます。"
run code --new-window --wait "$COMMIT_MSG_FILE" \
    || die "VS Code の起動に失敗しました。"

COMMIT_MSG="$(grep -v '^[[:space:]]*#' "$COMMIT_MSG_FILE" | sed '/^[[:space:]]*$/d')"
if [[ -z "$COMMIT_MSG" ]]; then
    log "INFO" "コミットメッセージが未入力のため、何もせず終了します。"
    exit $RET_OK
fi

# コメント除去済みのメッセージでファイルを上書き
printf '%s\n' "$COMMIT_MSG" > "$COMMIT_MSG_FILE"

# ------------------------------------------------------------------------------
# 11. commit / push
# ------------------------------------------------------------------------------
log "INFO" "git commit を実行します。"
run git -C "$REPO_ROOT" commit -F "$COMMIT_MSG_FILE" \
    || die "git commit に失敗しました。"

log "INFO" "git push を実行します。"
run git -C "$REPO_ROOT" push \
    || die "git push に失敗しました。"

log "SUCCESS" "カレント配下のコミット・プッシュが完了しました。"
