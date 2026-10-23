#!/bin/bash
# ==============================================================================
# sf-metasync.sh - Salesforce メタデータ Git 自動同期スクリプト
# ==============================================================================
# sf-init で登録した prod エイリアスの組織（本番・Sandbox どちらでもよい）から、メタデータを取得し、
# main ブランチにコミットして push する。push したときは、branches.txt の main 以外のブランチへ、main をマージして push する。
# Salesforce 組織の内容を正とする。どのブランチから実行しても、main に切り替えて処理し、終了時に元のブランチへ戻る。
#
# 【使い方】
#   bash ~/sf-tools/bin/sf-metasync.sh [オプション]     # force-* ディレクトリで実行する（管理者向け）
#
# 【オプション】
#   -j, --json    : 手順 7 の sf project retrieve start に --json を付ける（sf の出力を JSON 形式にする）
#   -v, --verbose : コマンドの応答（出力）をコンソールにも表示する
#   -h, --help    : このヘルプを表示して終了する
#   ※ 上記以外のオプション・引数を指定すると、中断する（終了コード 1）
#
# 【処理の流れ】
#   1. sf の確認: sf --version の終了コードが 0 以外なら、案内を表示して中断する（check_sf_cli --cache）
#   2. 事前の確認（どれかが満たされなければ、中断する）
#      - sf org display --target-org prod が成功すること（prod エイリアスの組織が登録済み）
#      - ./sf-tools/config/metadata.txt が存在すること（コメント行・空行を除いた各行を、取得するメタデータの種類とする）
#   3. 管理者向けの警告を表示し、続行の確認（Y/N）を取る。N・q なら中断する（GitHub Actions 上では、表示・確認しない）
#   4. main ブランチへ切り替える（実行時のブランチが main 以外のとき）
#      - 追跡中のファイルに未コミットの変更があれば、git stash で退避してから git checkout main する
#   5. リモートの最新を取り込む
#      - main で、追跡中のファイルに未コミットの変更があれば、中断する（ローカルの変更は、同期に含めない）
#      - git fetch origin（失敗しても WARNING を表示して続行）→ git pull origin main --rebase
#        （失敗したら git rebase --abort して中断する）
#   6. 差分の解析: sf sgd source delta --from origin/main --to HEAD --output-dir ./sf-tools/temp_delta_<PID>
#      （失敗したら中断する）
#   7. 組織からメタデータを取得する（どちらも --target-org prod --ignore-conflicts）
#      - 手順 6 の package/package.xml があれば、それで取得する（この取得の成否は、判定しない）
#      - metadata.txt の全種類を --metadata で指定して取得する（失敗したら中断する）
#   8. git add -A でステージし（sf-tools/release/ は除く）、HEAD との差分で分岐する
#      - 差分あり: 変更の一覧（git status --short）を表示して確認を取り、
#        「定期更新: Salesforce変更の自動反映 (YYYY-MM-DD)」でコミットし、git push --no-verify origin main する
#      - 差分なし・origin/main より先のコミットあり（前回の同期の push の失敗など）: そのコミットの一覧（git log --oneline）を
#        表示して確認を取り、git push --no-verify origin main だけ行う
#      - 差分なし・先のコミットなし: 「組織側に変更はありませんでした」と表示して終了する（手順 9 は行わない）
#      確認は Y/N で、N・q なら中断する（GitHub Actions 上では、表示・確認しない）。コミット・push の失敗は、中断する
#   9. （手順 8 で push したときのみ）branches.txt の main 以外の各ブランチへ、main を伝播する
#      - リモートに無いブランチは、WARNING を表示してスキップする
#      - git checkout <ブランチ> → git pull origin <ブランチ> --rebase → git merge main --no-edit → git push origin <ブランチ>
#        （この push には --no-verify を付けない）。失敗したら、WARNING を表示して、そのブランチをスキップする
#        （pull の失敗: git rebase --abort → git checkout main。merge の失敗: git merge --abort → git checkout main。
#         push の失敗: git checkout main。checkout の失敗: そのままスキップ）
#      - 最後に git checkout main する（失敗したら中断する）
#   10. 終了時（中断したときも）: 元のブランチへ git checkout し、手順 4 で退避していれば git stash pop する。
#       ./sf-tools/temp_delta_<PID> を削除する
#
# 【前提条件】
#   - force-* ディレクトリ（フォルダ名が force- で始まる）で実行すること。それ以外では lib/common.sh が終了する（終了コード 1）
#   - sf-init で prod エイリアスの組織が登録済みであること
#   - Salesforce CLI（sf）は npm 版であること。手順 1 の確認は、成功したら 24 時間は省略する（GitHub Actions 上では、確認しない）
#   - sf のプラグイン sfdx-git-delta（sf sgd）がインストール済みであること（無ければ、手順 6 で中断する）
#
# 【補足】
#   - 終了コード: 0（同期した・変更がなかった）／ 1（中断した）
#   - 手順 4・5 の「未コミットの変更」の判定（git diff-index HEAD）と git stash は、追跡中のファイルだけが対象。
#   - 追跡していないファイル（.gitignore の対象と、sf-tools/release/ を除く）がある場合、手元で実行したときは、手順 5 で中断する
#     （手順 8 の git add -A で、無関係なファイルが、同期のコミットに含まれてしまうため）。GitHub Actions 上では、確認しない。
#     sf-tools/release/（作業ブランチの作業用ファイル）は、確認の対象外で、同期のコミットにも含めない
#   - main への push は --no-verify（pre-push フックを通さない）。サーバー側の保護（Ruleset）は、そのまま効く
#   - branches.txt が無い・ブランチの定義が無いときは、WARNING を表示し、main のみとして扱う（手順 9 の対象なし）
#   - 手順 9 の完了のメッセージは、実際に伝播できたブランチだけを表示する。スキップしたブランチ（リモートにない・失敗）が
#     あれば、WARNING で一覧する（終了コードは 0 のまま）
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

# sf が終了コードを正しく返すか確認する（npm 版が前提。異常なら中断する）。成功は 24 時間は確認を省略する
# （GitHub Actions 上では、確認を省略する）
check_sf_cli --cache

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
# 6. フェーズ定義
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

    # 手元で実行したときは、追跡していないファイル（.gitignore の対象と、sf-tools/release/ を除く）がある場合も中止する。
    #   後の git add -A で、無関係なファイルが、同期のコミットに含まれてしまうため（以前は、含めていた）。
    #   sf-tools/release/ は、作業ブランチの日常的な作業用ファイル（sf-install.sh が作る）のため、対象外（ステージもしない）。
    #   GitHub Actions 上では、確認しない（クリーンなチェックアウトで、定期の同期を、予期しないファイルで止めないため）
    if [[ "${GITHUB_ACTIONS:-false}" != "true" ]]; then
        local untracked
        untracked=$(git ls-files --others --exclude-standard -- . ':!sf-tools/release' | head -5)  # VAR=$(cmd) のため run 不使用
        if [[ -n "$untracked" ]]; then
            die "main ブランチに、追跡していないファイルがあります（同期のコミットに含まれてしまうため中止します）: $(echo "$untracked" | tr '
' ' ')"
        fi
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
    # sf-tools/release/ は、ステージしない。作業ブランチのクローンには、sf-install.sh が作る release/<ジョブ名>/ の
    #   未追跡のファイルが、日常的にある（main に切り替えても、そのまま残る）。以前は、git add -A で、これらが、
    #   main の同期のコミットに含まれていた
    run git add -A -- . ':!sf-tools/release' || return $RET_NG

    # ステージに変更がなければ、未プッシュのコミットを確認する。あれば（前回、コミットのあとに push が失敗した）、push だけ行う。
    #   なければ、早期終了（組織側に変更なし）
    if run git diff-index --quiet HEAD --; then
        local _ahead
        _ahead=$(git rev-list --count "origin/${BRANCH_NAME}..HEAD" 2>/dev/null || echo 0)  # VAR=$(cmd) のため run 不使用
        if [[ "$_ahead" =~ ^[0-9]+$ && "$_ahead" -gt 0 ]]; then
            log "INFO" "未プッシュのコミットが ${_ahead} 件あります（前回の同期のコミットの push が、失敗した可能性があります）。push だけ行います。"
            if [[ "${GITHUB_ACTIONS:-false}" != "true" ]]; then
                git log --oneline "origin/${BRANCH_NAME}..HEAD" >&2  # run 不使用: 確認表示のため
                ask_yn "上記のコミットを main にプッシュします。よろしいですか？" || die "中断しました。"
            fi
            run git push --no-verify origin "$BRANCH_NAME" || return $RET_NG
            return $RET_OK
        fi
        return $RET_NO_CHANGE
    fi

    # ローカル実行時はコミット前に変更内容を表示して確認する
    if [[ "${GITHUB_ACTIONS:-false}" != "true" ]]; then
        git status --short >&2  # run 不使用: 確認表示のため
        ask_yn "上記の変更を main にコミット&プッシュします。よろしいですか？" || die "中断しました。"
    fi

    run git commit -m "$COMMIT_MSG" || return $RET_NG
    # --no-verify: このコマンドは、main への同期の専用（管理者が、確認して実行する。GitHub Actions では、フックがない）。
    #   pre-push フック（開発者の main への直接 push を止める）を、ここでだけ通さない。サーバー側の保護（Ruleset）は、そのまま効く
    run git push --no-verify origin "$BRANCH_NAME" || return $RET_NG
}

# 【PROPAGATE】main の変更を、branches.txt の main 以外の各ブランチへ、マージして push する（例: main → staging、main → develop）
PROPAGATED_OK=""        # 伝播できたブランチ（空白区切り）
PROPAGATED_SKIPPED=""   # 伝播をスキップしたブランチ（ない・失敗）
phase_propagate_downstream() {
    local downstream_branches
    downstream_branches=$(get_branch_list | grep -v '^main$')
    for branch in $downstream_branches; do
        # リモートにブランチが存在するか確認（出力は不要なため直接呼び出し）
        if ! git ls-remote --exit-code --heads origin "$branch" > /dev/null 2>&1; then
            log "WARNING" "${branch} ブランチがリモートに存在しないためスキップします"
            PROPAGATED_SKIPPED="${PROPAGATED_SKIPPED}${branch} "
            continue
        fi

        log "INFO" "main → ${branch} へマージします..."

        if ! run git checkout "$branch"; then
            log "WARNING" "${branch} のチェックアウトに失敗しました（スキップ）"
            PROPAGATED_SKIPPED="${PROPAGATED_SKIPPED}${branch} "
            continue
        fi

        if ! run git pull origin "$branch" --rebase; then
            log "WARNING" "${branch} の pull に失敗しました（スキップ）"
            run git rebase --abort
            run git checkout main
            PROPAGATED_SKIPPED="${PROPAGATED_SKIPPED}${branch} "
            continue
        fi

        if ! run git merge "main" --no-edit; then
            log "WARNING" "${branch} へのマージに失敗しました（スキップ）"
            run git merge --abort
            run git checkout main
            PROPAGATED_SKIPPED="${PROPAGATED_SKIPPED}${branch} "
            continue
        fi

        if ! run git push origin "$branch"; then
            log "WARNING" "${branch} の push に失敗しました（スキップ）"
            run git checkout main
            PROPAGATED_SKIPPED="${PROPAGATED_SKIPPED}${branch} "
            continue
        fi

        log "SUCCESS" "${branch} への伝播が完了しました"
        PROPAGATED_OK="${PROPAGATED_OK}${branch} "
    done

    # 作業ブランチを main に戻す
    run git checkout main || die "main ブランチへの復帰に失敗しました。"
}

# ------------------------------------------------------------------------------
# 7. メインフロー
# ------------------------------------------------------------------------------
if [[ "${GITHUB_ACTIONS:-false}" != "true" ]]; then
    print_admin_warning --standard "main の Salesforce 組織からメタデータを取得し" "main ブランチへ push します。"
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
    # 実際に伝播できたブランチだけを表示する（以前は、branches.txt の内容や、スキップの有無にかかわらず、固定の文言を出していた）
    log "SUCCESS" "下流ブランチへの伝播完了（伝播したブランチ: ${PROPAGATED_OK% }${PROPAGATED_OK:+}$([[ -z "$PROPAGATED_OK" ]] && echo なし)）"
    [[ -z "$PROPAGATED_SKIPPED" ]] || log "WARNING" "伝播できなかったブランチ（スキップ）: ${PROPAGATED_SKIPPED% }"
elif [[ $RES -eq $RET_NO_CHANGE ]]; then
    log "SUCCESS" "完了: Salesforce 組織側に変更はありませんでした。"
else
    die "Git への同期中にエラーが発生しました。"
fi

exit $RET_OK
