#!/bin/bash
# ==============================================================================
# sf-prepush.sh - プッシュ前チェックスクリプト
# ==============================================================================
# git push のときに、pre-push フック（sf-hook.sh が hooks/pre-push を .git/hooks/pre-push にコピーしたもの）から
# 呼ばれる本体。保護ブランチの上からのプッシュと、保護ブランチへのプッシュを拒否し、ターゲットファイルを検証したうえで、
# origin/<現在のブランチ> と origin/main の未取り込みのコミットを、現在のブランチに merge で取り込む
# （取り込みをしたときは、そのプッシュを中止する。もう一度プッシュすると、通る）。
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
#   1. 次のどれかなら、拒否して終了する（保護ブランチ = sf-tools/config/branches.txt のブランチ。ファイルがない・空のときは main）
#        - 現在の HEAD がブランチを指していない（git symbolic-ref -q --short HEAD の終了コードが 0 以外。detached HEAD）
#        - 現在のブランチ（git symbolic-ref -q --short HEAD）が、保護ブランチ
#        - プッシュ先（フックの標準入力に、git が渡す、リモートの ref = refs/heads/<名前>）に、保護ブランチがある
#          （git push origin feature:main や、保護ブランチの削除（:main）も、拒否する。標準入力は、最初に、1 行ごとに最大 2 秒
#          待って読み切る。端末から手動で実行したときは、標準入力を読まない）
#   2. sf-check.sh（引数なし）でターゲットファイルを検証する。エラーなら中断する
#   3. git fetch -q origin -- <対象> で、リモートの最新を取得する。対象は次のとおり（失敗したら中断する）
#        - 現在のブランチ（origin にあるときだけ）
#        - 保護ブランチ（1 と同じ）。英数字で始まり、英数字・. _ / - だけで構成される名前のみ
#          （branches.txt はリポジトリで共有されるため。使えない名前・origin にまだないブランチは、警告を表示して飛ばす）
#        origin にあるかは git ls-remote --exit-code で確かめる。対象が 1 つもなければ、git fetch を行わない
#   4. origin に現在のブランチがあり、origin/<現在のブランチ> に未取り込みのコミットがあれば、
#      そのコミットを表示して、git merge origin/<現在のブランチ> で取り込む。失敗したら git merge --abort して中断する
#   5. origin/main に未取り込みのコミットがあれば、そのコミットを表示して、git merge origin/main で取り込む。
#      失敗したら git merge --abort して中断する
#      4・5 の未取り込みのコミットの確認（git log <現在のブランチ>..origin/<対象> --oneline）が失敗したとき
#      （手元に origin/main がないなど）は、取り込みを試みずに中断する
#   6. 4・5 で取り込んだ（早送り（fast-forward）を含む）ときは、exit 1（プッシュ中止）。git は、フックを呼ぶ前に、プッシュする
#      コミットを決めているため、そのままでは、取り込みが含まれないまま、プッシュが成功と表示される。取り込み後に、もう一度
#      プッシュすれば、取り込みは済んでいるため、中止しない
#   7. すべて通り、取り込みもなければ exit 0（プッシュ続行）
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
#   - ログ: ./sf-tools/logs/sf-prepush.log（実行のたびに追記する）
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 共通ライブラリの必須設定
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME=$(basename "$0" .sh)  # run 不使用: common.sh の読み込み前（run が未定義）
readonly LOG_FILE="./sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="APPEND"


# ------------------------------------------------------------------------------
# 2. 共通ライブラリの読み込み
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"  # run 不使用: common.sh の読み込み前（run が未定義）
COMMON_LIB="${SCRIPT_DIR}/../lib/common.sh"

if [[ ! -f "$COMMON_LIB" ]]; then
    echo "[FATAL ERROR] Library not found: $COMMON_LIB" >&2
    exit 1
fi
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}"  # run 不使用: common.sh の読み込み前（run が未定義）
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
    if git ls-remote --exit-code origin "$current_branch" > /dev/null 2>&1; then  # 条件チェックのため run 不使用
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
    if ! git ls-remote --exit-code origin "$current_branch" > /dev/null 2>&1; then  # 条件チェックのため run 不使用
        log "INFO" "リモートに ${current_branch} ブランチがまだ存在しません。スキップします。"
        return $RET_OK
    fi

    local missing_commits
    # run 不使用: 終了コードで失敗を判定するため（run は、失敗しても、エラーの文言を標準出力に返す。以前は、その文言を
    #   未取り込みのコミットと見なして、merge を試みていた）
    missing_commits=$(git log "${current_branch}..origin/${current_branch}" --oneline) \
        || die "origin/${current_branch} との差分を確認できませんでした（git log ${current_branch}..origin/${current_branch} が失敗しました）。プッシュを中止しました。"

    if [[ -n "$missing_commits" ]]; then
        log "WARNING" "リモートの ${current_branch} ブランチが更新されています。自動的に取り込みます..."
        log "INFO" "取り込むコミット:"
        echo "--------------------------------------------------"
        echo "$missing_commits"
        echo "--------------------------------------------------"
        run git merge "origin/${current_branch}" \
            || { run git merge --abort; die "origin/${current_branch} の自動取り込み（git merge）に失敗しました。プッシュを中止しました。"; }
        log "SUCCESS" "${current_branch} ブランチのリモート変更を取り込みました。"
        MERGED=1
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
    # run 不使用: 終了コードで失敗を判定するため（phase_pull_own と同じ。手元に origin/main がないときなど）
    missing_commits=$(git log "${current_branch}..origin/main" --oneline) \
        || die "origin/main との差分を確認できませんでした（git log ${current_branch}..origin/main が失敗しました）。プッシュを中止しました。"

    if [[ -n "$missing_commits" ]]; then
        log "WARNING" "リモートの main ブランチが更新されています。自動的に取り込みます..."
        log "INFO" "取り込むコミット:"
        echo "--------------------------------------------------"
        echo "$missing_commits"
        echo "--------------------------------------------------"
        run git merge origin/main \
            || { run git merge --abort; die "origin/main の自動取り込み（git merge）に失敗しました。プッシュを中止しました。"; }
        log "SUCCESS" "main ブランチの変更を自動的に取り込みました。"
        MERGED=1
    else
        log "SUCCESS" "main ブランチと同期されています。"
    fi

    return $RET_OK
}

# 【SYNTAX】ターゲットファイルの検証（sf-check.sh を引数なしで実行する。書式・パス・種類の可否。エラーなら中断）
phase_check_syntax() {
    run bash "${SCRIPT_DIR}/sf-check.sh" || die "ターゲットファイルの検証でエラーがありました。プッシュを中断しました。"
    return $RET_OK
}

# ------------------------------------------------------------------------------
# 6. メイン実行フロー
# ------------------------------------------------------------------------------
# git は、pre-push フックの標準入力に、プッシュする ref を 1 行ずつ渡す:「<ローカルの ref> <ローカルの sha> <リモートの ref> <リモートの sha>」。
#   ほかのコマンドが標準入力を読む前に、最初に全部読む。端末（手動で実行したとき）では、読まない。
#   タイムアウト付き（フック以外から、閉じない標準入力で呼ばれても、止まり続けないため）
PUSH_REF_LINES=""
if [[ ! -t 0 ]]; then
    while IFS= read -r -t 2 _push_line; do
        PUSH_REF_LINES="${PUSH_REF_LINES}${_push_line}"$'
'
    done
    unset _push_line
fi

# run 不使用: 終了コードで判定するため（run は、失敗しても、エラーの文言を標準出力に返す。以前は、detached HEAD のとき、
#   その文言を現在のブランチとして扱い、中断せずに続けていた）
CURRENT_BRANCH=$(git symbolic-ref -q --short HEAD) \
    || die "現在の HEAD がブランチを指していません（detached HEAD）。プッシュを中止しました。"
MERGED=0   # フックの中で取り込んだ（merge。早送りを含む）ら 1（下の最後の確認で使う）

# 現在のブランチが保護ブランチなら、プッシュを拒否する
if is_protected_branch "$CURRENT_BRANCH"; then
    die "${CURRENT_BRANCH} ブランチ（保護ブランチ）からの直接プッシュは禁止されています。"
fi

# プッシュ先（リモートのブランチ）が保護ブランチなら、現在のブランチが何であっても、拒否する
#   （git push origin feature:main / HEAD:main / :main（削除）などで、現在のブランチの確認をすり抜けないため）
while IFS=' ' read -r _lref _lsha _rref _rsha; do
    [[ "$_rref" == refs/heads/* ]] || continue
    _target="${_rref#refs/heads/}"
    if is_protected_branch "$_target"; then
        die "${_target} ブランチへの直接プッシュは禁止されています（プッシュ先: ${_rref}）。"
    fi
done <<< "$PUSH_REF_LINES"

phase_check_syntax || die "構文チェックに失敗しました。"

phase_fetch "$CURRENT_BRANCH" || die "リモート情報の取得に失敗しました。"

phase_pull_own "$CURRENT_BRANCH" || die "自ブランチのリモート同期に失敗しました。"

phase_check_main "$CURRENT_BRANCH" || die "main ブランチとの同期確認に失敗しました。"

# フックの中で merge したときは、プッシュを中止する。git は、フックを呼ぶ前に、プッシュするコミットを決めているため、
#   このプッシュには、取り込んだ内容（merge のコミット）が含まれない。手元のブランチだけが進み、プッシュは、成功と表示される
#   （以前は、そのまま続行していた）。取り込み後の、もう一度のプッシュでは、取り込みが済んでいるため、中止しない
if [[ "$MERGED" -eq 1 ]]; then
    die "リモートの変更を、現在のブランチに取り込みました（早送りを含む）。このプッシュには、取り込みが含まれないため、中止しました。"
fi

log "SUCCESS" "すべてのチェックが完了しました。プッシュを継続します。"

exit $RET_OK
