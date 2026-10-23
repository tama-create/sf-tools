#!/bin/bash
# ==============================================================================
# sf-prepush.sh - プッシュ前チェックスクリプト
# ==============================================================================
# git push のときに、pre-push フック（sf-hook.sh が hooks/pre-push を .git/hooks/pre-push にコピーしたもの）から
# 呼ばれる本体。保護ブランチの上からのプッシュを拒否し、ターゲットファイルを検証したうえで、
# origin/<現在のブランチ> と origin/main の未取り込みのコミットを、現在のブランチに merge で取り込む。
#
# 【使い方】
#   sf-prepush.sh [オプション]
#
# 【オプション】
#   -v, --verbose  : コマンドの応答（出力）をコンソールにも表示する（フックは、この指定で呼ぶ）
#   -h, --help     : このヘルプを表示して終了する
#   上記以外の引数・オプションを指定すると、エラーで終了する
#
# 【処理の流れ】
#   1. 現在のブランチ（git symbolic-ref --short HEAD）が、保護ブランチ（sf-tools/config/branches.txt のブランチ。
#      ファイルがない・空のときは main）なら、拒否して終了する。判定するのは現在のブランチだけで、プッシュ先のブランチは見ない
#   2. sf-check.sh（引数なし）でターゲットファイルを検証する。エラーなら中断する
#   3. git fetch -q origin -- <対象> で、リモートの最新を取得する。対象は次のとおり（失敗したら中断する）
#        - 現在のブランチ（origin にあるときだけ）
#        - branches.txt のブランチ。英数字で始まり、英数字・. _ / - だけで構成される名前のみ
#          （branches.txt はリポジトリで共有されるため。使えない名前・origin にまだないブランチは、警告を表示して飛ばす）
#   4. origin に現在のブランチがあり、origin/<現在のブランチ> に未取り込みのコミットがあれば、
#      そのコミットを表示して、git merge origin/<現在のブランチ> で取り込む。失敗したら git merge --abort して中断する
#   5. origin/main に未取り込みのコミットがあれば、そのコミットを表示して、git merge origin/main で取り込む。
#      失敗したら git merge --abort して中断する
#   6. すべて通れば exit 0（プッシュ続行）
#
# 【前提条件】
#   - 現在のディレクトリ（フックから呼ばれたときは、リポジトリのルート）の名前が force- で始まること
#     （lib/common.sh が確認する）
#
# 【補足】
#   - 取り込みは merge で行う（rebase ではない）
#   - 2 の検証は、4・5 の取り込みより前に行う。4・5 で取り込んだ変更は、検証しない
#   - 5 は、3 で main を取得したかにかかわらず、手元の origin/main を見る
#   - 中断したときは、終了コード 1 で終わり、プッシュも中止される
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 共通ライブラリの必須設定
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME=$(basename "$0" .sh)
readonly LOG_FILE="./sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="APPEND"


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
log "HEADER" "main 同期チェックを開始します (${SCRIPT_NAME}.sh)"

# ------------------------------------------------------------------------------
# 4. 実行時引数の解析
# ------------------------------------------------------------------------------
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --help|-h) show_help ;;
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
# 5. フェーズ定義
# ------------------------------------------------------------------------------

# 【FETCH】リモートの最新情報を取得
phase_fetch() {
    local current_branch="$1"
    log "INFO" "リモート(origin)の最新情報を確認中..."
    local branches
    branches=$(get_branch_list)
    # fetch 対象は配列で持ち、1 つずつ引用して渡す（branches.txt はリポジトリで共有されるファイルのため、
    # 空白・ワイルドカード・"-" で始まる値が、git fetch のオプションや別の引数として解釈されないようにする）
    local -a fetch_targets=()
    local b
    # 現在のブランチがリモートに存在する場合のみ fetch 対象に含める（新規ブランチは除外）
    if git ls-remote --exit-code origin "$current_branch" > /dev/null 2>&1; then
        fetch_targets+=("$current_branch")
    fi
    while IFS= read -r b; do
        b="${b#"${b%%[![:space:]]*}"}"   # 前後の空白を除去
        b="${b%"${b##*[![:space:]]}"}"
        [[ -z "$b" ]] && continue
        # 英数字で始まり、英数字・. _ / - だけで構成されるブランチ名のみ許可する（それ以外は、取得せずスキップ）
        if [[ ! "$b" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]]; then
            log "WARNING" "branches.txt に、使えないブランチ名があります（取得しません）: ${b}"
            continue
        fi
        # origin に、まだないブランチ（branches.txt にだけ書かれている・消された）は、取得しない（git fetch が「見つからない」で失敗し、
        #   すべての push が止まるため）。警告だけ出す
        if ! git ls-remote --exit-code origin "$b" > /dev/null 2>&1; then  # 条件チェックのため run 不使用
            log "WARNING" "branches.txt のブランチが、origin に、まだありません（取得しません）: ${b}"
            continue
        fi
        fetch_targets+=("$b")
    done <<< "$branches"
    [[ ${#fetch_targets[@]} -gt 0 ]] || return $RET_OK
    run git fetch -q origin -- "${fetch_targets[@]}" || return $RET_NG
    return $RET_OK
}

# 【PULL】自分のブランチのリモートを先に同期
phase_pull_own() {
    local current_branch="$1"

    # リモートに同名ブランチが存在するか確認
    if ! git ls-remote --exit-code origin "$current_branch" > /dev/null 2>&1; then
        log "INFO" "リモートに ${current_branch} ブランチがまだ存在しません。スキップします。"
        return $RET_OK
    fi

    local missing_commits
    missing_commits=$(run git log "${current_branch}..origin/${current_branch}" --oneline)

    if [[ -n "$missing_commits" ]]; then
        log "WARNING" "リモートの ${current_branch} ブランチが更新されています。自動的に取り込みます..."
        log "INFO" "取り込むコミット:"
        echo "--------------------------------------------------"
        echo "$missing_commits"
        echo "--------------------------------------------------"
        run git merge "origin/${current_branch}" \
            || { run git merge --abort; die "${current_branch} の自動取り込みに失敗しました。コンフリクトを解消してから再度プッシュしてください。"; }
        log "SUCCESS" "${current_branch} ブランチのリモート変更を取り込みました。"
    else
        log "INFO" "${current_branch} ブランチはリモートと同期されています。"
    fi

    return $RET_OK
}

# 【CHECK】main ブランチとの同期を検証・自動取り込み
phase_check_main() {
    local current_branch="$1"

    # リモート main に未取り込みコミットがあれば自動取り込み（merge）
    local missing_commits
    missing_commits=$(run git log "${current_branch}..origin/main" --oneline)

    if [[ -n "$missing_commits" ]]; then
        log "WARNING" "リモートの main ブランチが更新されています。自動的に取り込みます..."
        log "INFO" "取り込むコミット:"
        echo "--------------------------------------------------"
        echo "$missing_commits"
        echo "--------------------------------------------------"
        run git merge origin/main \
            || { run git merge --abort; die "main の自動取り込みに失敗しました。コンフリクトを解消してから再度プッシュしてください。"; }
        log "SUCCESS" "main ブランチの変更を自動的に取り込みました。"
    else
        log "SUCCESS" "main ブランチと同期されています。"
    fi

    return $RET_OK
}

# 【SYNTAX】ターゲットファイルの構文チェック
phase_check_syntax() {
    run bash "${SCRIPT_DIR}/sf-check.sh" || die "ターゲットファイルに構文エラーがあります。プッシュを中断しました。"
    return $RET_OK
}

# ------------------------------------------------------------------------------
# 6. メイン実行フロー
# ------------------------------------------------------------------------------
CURRENT_BRANCH=$(run git symbolic-ref --short HEAD)

# 現在のブランチが保護ブランチなら、プッシュを拒否する（プッシュ先のブランチは見ない）
if is_protected_branch "$CURRENT_BRANCH"; then
    die "${CURRENT_BRANCH} ブランチへの直接プッシュは禁止されています。PR を作成してください。"
fi

phase_check_syntax || die "構文チェックに失敗しました。"

phase_fetch "$CURRENT_BRANCH" || die "リモート情報の取得に失敗しました。"

phase_pull_own "$CURRENT_BRANCH" || die "自ブランチのリモート同期に失敗しました。"

phase_check_main "$CURRENT_BRANCH" || die "main ブランチとの同期確認に失敗しました。"
log "SUCCESS" "すべてのチェックが完了しました。プッシュを継続します。"

exit $RET_OK
