#!/bin/bash
# ==============================================================================
# sf-metasync.sh - Salesforce メタデータ Git 自動同期スクリプト
# ==============================================================================
# sf-init で設定した prod エイリアスの組織（本番または Sandbox）から最新メタデータを取得し、
# main ブランチへ自動反映します。
# ※ sf-init の設定により、本番組織・Sandbox どちらにも対応します。
# ※ どのブランチから実行しても main へ自動切替して処理します。
# ※ Salesforce 組織の変更を正とする。main のローカル未コミット変更がある場合は中止。
#   1. main ブランチへ自動切替（他ブランチから実行した場合は stash して切替）
#   2. Git の最新状態をプル (Rebase)
#   3. SGD (Salesforce Git Delta) による差分抽出
#   4. 組織からのメタデータ取得 (Retrieve)
#   5. 変更がある場合のみ Git Commit & Push
#
# 【前提】
#   Salesforce CLI（sf）は npm 版であること。起動時に check_sf_cli（sf --version の終了コード）で確認し、
#   0 以外なら警告を表示する（続行する）。成功は 24 時間は確認を省略する（GitHub Actions 上では省略）。
#
# 【オプション】
#   -j, --json          : sf コマンドの出力を JSON 形式で表示します
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
log "HEADER" "メタデータ同期（Salesforce -> Git）を開始します (${SCRIPT_NAME}.sh)"

# sf が終了コードを正しく返すか確認する（npm 版が前提）。警告のみで続行し、成功は 24 時間は確認を省略する
# （GitHub Actions 上では、確認を省略する）
check_sf_cli --warn-only --cache || true  # 警告のみのため、戻り値は無視（意図的エラー無視）

# ------------------------------------------------------------------------------
# 4. 実行時引数の解析
# ------------------------------------------------------------------------------
JSON_FLAG=()

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --help|-h) show_help ;;
        --json|-j)    JSON_FLAG=("--json") ;;
        --verbose|-v) : ;;  # SILENT_EXEC は common.sh が設定済み
        --*)
            die "不明なオプションです: $1"
            ;;
        *)
            die "不明な引数です: $1"
            ;;
    esac
    shift
done

# ------------------------------------------------------------------------------
# 5. 固有設定
# ------------------------------------------------------------------------------
# sf-init で登録した prod エイリアスの組織情報を取得（本番・Sandbox どちらも許容）
readonly TARGET_ORG="prod"
ORG_DISPLAY_JSON=$(run sf org display --target-org "$TARGET_ORG" --json || echo "")
[[ -z "$ORG_DISPLAY_JSON" ]] && die "prod エイリアスの組織情報を取得できませんでした。sf-init を実行して prod 組織を登録してください。"
log "INFO" "接続先組織: ${TARGET_ORG}"

# 常に main ブランチで作業する
readonly BRANCH_NAME="main"
ORIGINAL_BRANCH=$(run git symbolic-ref --short HEAD || echo "main")

DELTA_DIR="./sf-tools/temp_delta_$$"
STASH_USED=0

# 終了時に元のブランチへ復帰し、stash した変更を復元、一時ファイルを削除
trap 'run git checkout "$ORIGINAL_BRANCH" 2>/dev/null; [[ "$STASH_USED" -eq 1 ]] && run git stash pop 2>/dev/null; rm -rf "$DELTA_DIR" ./sf-tools/cmd_out_*.tmp 2>/dev/null' EXIT

readonly COMMIT_MSG="定期更新: Salesforce変更の自動反映 ($(date +'%Y-%m-%d'))"

readonly METADATA_CONFIG="./sf-tools/config/metadata.txt"
[[ ! -f "$METADATA_CONFIG" ]] && die "メタデータ設定ファイルが見つかりません: ${METADATA_CONFIG}"
METADATA_TYPES=()
while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue  # コメント行をスキップ
    [[ -z "${line//[[:space:]]/}" ]] && continue  # 空行をスキップ
    METADATA_TYPES+=("$line")
done < "$METADATA_CONFIG"
readonly METADATA_TYPES
log "INFO" "対象メタデータ (${#METADATA_TYPES[@]} 件): ${METADATA_TYPES[*]}"

# ------------------------------------------------------------------------------
# 5. フェーズ定義
# ------------------------------------------------------------------------------

# 【SWITCH】main ブランチへ切替（他ブランチから実行した場合は stash して切替）
phase_switch_to_main() {
    if [[ "$ORIGINAL_BRANCH" == "main" ]]; then
        return $RET_OK
    fi

    log "INFO" "main ブランチへ切り替えます（現在: ${ORIGINAL_BRANCH}）..."

    # 作業中の変更を一時退避
    if ! run git diff-index --quiet HEAD --; then
        log "INFO" "ローカルの変更を一時退避します (git stash)..."
        run git stash || return $RET_NG
        STASH_USED=1  # trap で stash pop するためフラグを立てる
    fi

    run git checkout main || return $RET_NG
    return $RET_OK
}

# 【GIT】リモートの変更を取り込む
phase_git_update() {
    log "INFO" "リモートの最新状態を取り込んでいます..."

    # main ブランチのローカル変更は Salesforce 組織の内容より優先されないため中止する
    # （stash して復元すると、ローカル変更が retrieve 後にコミットされてしまうため）
    if ! run git diff-index --quiet HEAD --; then
        die "main ブランチにローカルの未コミット変更があります。Salesforce 組織の内容を正として同期するため、ローカル変更は反映しません。変更を破棄（git checkout .）してから再実行してください。"
    fi

    run git fetch origin || log "WARNING" "git fetch に失敗しました。ローカルキャッシュで続行します。"

    if ! run git pull origin "$BRANCH_NAME" --rebase; then
        run git rebase --abort
        return $RET_NG
    fi

    return $RET_OK
}

# 【DELTA】SGD による差分解析
phase_analyze_delta() {
    log "INFO" "前回の同期からの変更箇所 (SGD) を解析中..."
    run mkdir -p "$DELTA_DIR"
    run sf sgd source delta --from "origin/$BRANCH_NAME" --to HEAD --output-dir "$DELTA_DIR" || return $RET_NG
    return $RET_OK
}

# 【RETRIEVE】組織からメタデータを取得
phase_retrieve_metadata() {
    # SGD で生成された package.xml があればそれを使用して差分取得
    if [[ -f "$DELTA_DIR/package/package.xml" ]]; then
        log "INFO" "SGD で特定された差分ファイルをダウンロード中..."
        run sf project retrieve start \
            --manifest "$DELTA_DIR/package/package.xml" \
            --target-org "$TARGET_ORG" \
            --ignore-conflicts \
            "${JSON_FLAG[@]}"
    fi

    # 主要メタデータの整合性確保のために再取得（型ごとに --metadata を分けて指定）
    log "INFO" "主要メタデータの整合性をチェック中..."
    local retrieve_cmd=("sf" "project" "retrieve" "start" "--target-org" "$TARGET_ORG" "--ignore-conflicts" "${JSON_FLAG[@]}")
    for type in "${METADATA_TYPES[@]}"; do
        retrieve_cmd+=("--metadata" "$type")
    done
    run "${retrieve_cmd[@]}"
}

# 【SYNC】変更を Git へ反映
phase_git_sync() {
    log "INFO" "Git リポジトリへ反映中..."
    run git add -A || return $RET_NG

    # ステージに変更がなければ早期終了
    if run git diff-index --quiet HEAD --; then
        return $RET_NO_CHANGE
    fi

    # ローカル実行時はコミット前に変更内容を表示して確認する
    if [[ "${GITHUB_ACTIONS:-false}" != "true" ]]; then
        git status --short >&2  # run 不使用: 確認表示のため
        ask_yn "上記の変更を main にコミット&プッシュします。よろしいですか？"
    fi

    run git commit -m "$COMMIT_MSG" || return $RET_NG
    run git push origin "$BRANCH_NAME" || return $RET_NG
}

# 【PROPAGATE】main の変更を下流ブランチへ直接伝播 (main → staging、main → develop)
phase_propagate_downstream() {
    local downstream_branches
    downstream_branches=$(get_branch_list | grep -v '^main$')
    for branch in $downstream_branches; do
        # リモートにブランチが存在するか確認（出力は不要なため直接呼び出し）
        if ! git ls-remote --exit-code --heads origin "$branch" > /dev/null 2>&1; then
            log "WARNING" "${branch} ブランチがリモートに存在しないためスキップします"
            continue
        fi

        log "INFO" "main → ${branch} へマージします..."

        if ! run git checkout "$branch"; then
            log "WARNING" "${branch} のチェックアウトに失敗しました（スキップ）"
            continue
        fi

        if ! run git pull origin "$branch" --rebase; then
            log "WARNING" "${branch} の pull に失敗しました（スキップ）"
            run git rebase --abort
            run git checkout main
            continue
        fi

        if ! run git merge "main" --no-edit; then
            log "WARNING" "${branch} へのマージに失敗しました（スキップ）"
            run git merge --abort
            run git checkout main
            continue
        fi

        if ! run git push origin "$branch"; then
            log "WARNING" "${branch} の push に失敗しました（スキップ）"
            run git checkout main
            continue
        fi

        log "SUCCESS" "${branch} への伝播が完了しました"
    done

    # 作業ブランチを main に戻す
    run git checkout main || die "main ブランチへの復帰に失敗しました。"
}

# ------------------------------------------------------------------------------
# 6. メインフロー
# ------------------------------------------------------------------------------
if [[ "${GITHUB_ACTIONS:-false}" != "true" ]]; then
    echo -e "${CLR_ERR}╔══════════════════════════════════════════════════════╗${CLR_RESET}" >&2
    echo -e "${CLR_ERR}║  !!  このコマンドは管理者専用です                    ║${CLR_RESET}" >&2
    echo -e "${CLR_ERR}║      管理者以外は絶対に実行しないでください          ║${CLR_RESET}" >&2
    echo -e "${CLR_ERR}║                                                      ║${CLR_RESET}" >&2
    echo -e "${CLR_ERR}║  本番 Salesforce 組織からメタデータを取得し          ║${CLR_RESET}" >&2
    echo -e "${CLR_ERR}║  main ブランチへ push します。                       ║${CLR_RESET}" >&2
    echo -e "${CLR_ERR}╚══════════════════════════════════════════════════════╝${CLR_RESET}" >&2
    ask_yn "続行しますか？" || die "中断しました。"
fi

phase_switch_to_main    || die "main ブランチへの切替に失敗しました。"
log "SUCCESS" "main ブランチへの切替完了"

phase_git_update        || die "Git 更新に失敗しました。"
log "SUCCESS" "Git 更新完了"

phase_analyze_delta     || die "差分解析 (SGD) に失敗しました。"
log "SUCCESS" "差分解析完了"

phase_retrieve_metadata || die "メタデータの取得に失敗しました。"
log "SUCCESS" "メタデータ取得完了"

phase_git_sync
RES=$?

if [[ $RES -eq $RET_OK ]]; then
    log "SUCCESS" "完了: リポジトリを最新に更新しました。"
    phase_propagate_downstream || die "下流ブランチへの伝播に失敗しました。"
    log "SUCCESS" "下流ブランチへの伝播完了 (main → staging、main → develop)"
elif [[ $RES -eq $RET_NO_CHANGE ]]; then
    log "SUCCESS" "完了: Salesforce 組織側に変更はありませんでした。"
else
    die "Git への同期中にエラーが発生しました。"
fi

exit $RET_OK
