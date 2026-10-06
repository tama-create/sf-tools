#!/bin/bash
# ==============================================================================
# sf-sync-wf.sh - GitHub Actions ワークフローを、sf-tools の雛形に合わせて更新する（管理者向け）
# ==============================================================================
# sf-tools の雛形（templates/.github/workflows/）と、このプロジェクトの .github/workflows/ を比べ、
# 差分を表示して、確認のうえ、雛形の内容でコピー（上書き）します。
# sf-init が作成した、作成済みの force-* に、あとから、ワークフローの修正（不具合の修正・安全対策など）を
# 反映するための専用コマンドです。sf-install.sh などから自動では実行されません（利用者の意思なく、
# ワークフローが書き換わるのを防ぐため）。
#
# 【処理の流れ】
#   1. force-* のフォルダ内で、環境ブランチ（branches.txt のブランチ: main / staging / develop など）以外であることを確認
#   2. sf-tools（~/sf-tools）が最新であることを確認（必須。古い雛形で、書き換えないため）
#        遅れていれば、確認のうえ、sf-tools を更新（git pull --ff-only）し、更新した sf-tools で、同じ引数で、もう一度、実行する
#        origin に接続できない・更新を断った・未コミットの変更や未プッシュのコミットがある場合は、中断する
#        --check は、読み取り専用のため、更新せず、遅れていれば中断する
#   3. 冒頭に、赤い警告ボックスを表示し、[Y/N/q] で確認（N / q なら、中断。--check は、何も変更しないため、表示しない）
#   4. 雛形と .github/workflows/ を比較（CRLF の違いは無視）
#        差分なし → 「最新です」で終了
#        差分あり → 差分を表示（雛形にない新規ファイルも含む）
#   5. 差分を見たうえで、もう一度 [Y/N/q] で確認（N / q なら、何も変更しない）
#   6. Y → 雛形の内容をコピー（上書き）。コミット・プッシュは、行わない
#
# 【更新の手順（推奨）】
#   1. 作業用のブランチを作る:  sf-job.sh でジョブ名 system-日付（例: system-20261006）
#   2. そのフォルダで:          sf-sync-wf.sh        （差分を確認して Y）
#   3. 内容を確認:              git diff .github/workflows/
#   4. コミット・プッシュ:      sf-push.sh
#   5. PR を出してマージ（複数の環境がある構成では、通常の変更と同じ順序で。次の PR 先は sf-next.sh が案内する）
#   ※ ワークフローのファイルをプッシュするには、workflow スコープのある権限が必要です
#
# 【オプション】
#   --check           : 差分があるかだけを調べる（何も変更せず、確認も出さない）。差分なし: 終了コード 0 / あり: 1
#   --remove <ファイル名> : 指定のワークフロー（.github/workflows/<ファイル名>）を削除する（二重に確認する）。
#                           雛形にあるファイルは、削除できない（雛形から廃止されたファイルだけが対象）
#   -v, --verbose     : コマンドの応答（出力）をコンソールにも表示します
#   -h, --help        : このヘルプを表示する
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
# 3. オプションの解析
# ------------------------------------------------------------------------------
ORIG_ARGS=("$@")   # sf-tools を更新したあと、同じ引数で、再実行するために覚えておく
CHECK_ONLY=0
REMOVE_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)
            CHECK_ONLY=1 ;;
        --remove)
            [[ -n "${2:-}" && "${2}" != -* ]] || die "--remove には、削除するワークフローのファイル名を指定してください。"
            REMOVE_FILE="$2"; shift ;;
        -v|--verbose)
            ;;  # common.sh が、引数から、VERBOSE を判定する
        *)
            die "不明なオプションです: $1" ;;
    esac
    shift
done

# ------------------------------------------------------------------------------
# 4. 初期チェック
# ------------------------------------------------------------------------------
log "HEADER" "ワークフローの更新を確認します (${SCRIPT_NAME}.sh)"

SRC_DIR="${SCRIPT_DIR}/../templates/.github/workflows"
DST_DIR=".github/workflows"

check_force_dir || die "force-* ディレクトリ内で実行してください。"
[[ -d "$SRC_DIR" ]] || die "雛形のフォルダが見つかりません: ${SRC_DIR}"

CURRENT_BRANCH=$(run git symbolic-ref --short HEAD) || die "現在のブランチを取得できません。"
if is_protected_branch "$CURRENT_BRANCH"; then
    die "${CURRENT_BRANCH} ブランチでは実行できません（環境ブランチです）。作業用のブランチで実行してください。"
fi

# sf-tools が最新であること（必須）。古い雛形で、プロジェクトのワークフローを書き換えないため。
#   遅れていれば、確認のうえ、更新し、更新した sf-tools で、同じ引数で、もう一度実行する（実行中のスクリプトが書き換わるため）。
#   origin に接続できない・更新を断った・未コミットの変更があって更新できない場合は、中断する。
#   --check は、読み取り専用のため、更新せず、遅れていれば中断する
SF_TOOLS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ $CHECK_ONLY -eq 1 ]]; then
    ensure_sf_tools_latest --no-update "$SF_TOOLS_DIR"; sf_tools_rc=$?
else
    ensure_sf_tools_latest "$SF_TOOLS_DIR"; sf_tools_rc=$?
fi
if [[ $sf_tools_rc -eq 2 ]]; then
    [[ -z "${SF_SYNC_WF_RESTARTED:-}" ]] || die "sf-tools を更新しても、最新になりませんでした。"
    export SF_SYNC_WF_RESTARTED=1
    log "INFO" "更新した sf-tools で、もう一度、実行します。"
    exec bash "${BASH_SOURCE[0]}" "${ORIG_ARGS[@]}"
fi

# 管理者向けの警告ボックスと確認。引数: 確認の質問（省略可）
#   GITHUB_ACTIONS=true でも、確認を省略しない（ワークフローを書き換えるコマンドで、Actions 上で実行する想定がない）
confirm_admin() {
    echo -e "${CLR_ERR}╔══════════════════════════════════════════════════════╗${CLR_RESET}" >&2
    echo -e "${CLR_ERR}║  !!  GitHub Actions のワークフローを書き換えます     ║${CLR_RESET}" >&2
    echo -e "${CLR_ERR}║      CI/CD（リリース・検証）の動作が変わります       ║${CLR_RESET}" >&2
    echo -e "${CLR_ERR}║      管理者以外は、実行しないでください              ║${CLR_RESET}" >&2
    echo -e "${CLR_ERR}╚══════════════════════════════════════════════════════╝${CLR_RESET}" >&2
    ask_yn "${1:-続行しますか？}" || die "中断しました。"
}

# 冒頭の警告と確認（管理者向けコマンドの規約: CLAUDE.md 2.4）。--check は、何も変更しないため、表示しない
[[ $CHECK_ONLY -eq 1 ]] || confirm_admin

# ------------------------------------------------------------------------------
# 5. --remove <ファイル名>: 廃止されたワークフローの削除
# ------------------------------------------------------------------------------
if [[ -n "$REMOVE_FILE" ]]; then
    # ファイル名だけを受け付ける（パスの区切り・.. を含む名前は、拒否する）
    [[ "$REMOVE_FILE" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.ya?ml$ ]] || die "ワークフローのファイル名として正しくありません: ${REMOVE_FILE}"
    [[ -f "${DST_DIR}/${REMOVE_FILE}" ]] || die "削除対象が見つかりません: ${DST_DIR}/${REMOVE_FILE}"
    [[ ! -e "${SRC_DIR}/${REMOVE_FILE}" ]] || die "${REMOVE_FILE} は、雛形にあるため、削除できません（雛形から廃止されたファイルだけが対象です）。"
    log "INFO" "削除対象: ${DST_DIR}/${REMOVE_FILE}"
    ask_yn "${DST_DIR}/${REMOVE_FILE} を削除します。本当によろしいですか？" || die "中断しました。"
    run rm -f "${DST_DIR}/${REMOVE_FILE}" || die "削除に失敗しました: ${DST_DIR}/${REMOVE_FILE}"
    log "SUCCESS" "削除しました: ${DST_DIR}/${REMOVE_FILE}"
    log "INFO" "git status で確認して、コミットしてください（コミット・プッシュは、行いません）。"
    exit $RET_OK
fi

# ------------------------------------------------------------------------------
# 6. 雛形との比較
# ------------------------------------------------------------------------------
CHANGED=()   # 内容が違うファイル
NEW=()       # 雛形にあり、このプロジェクトにないファイル
for f in "$SRC_DIR"/*.yml; do
    [[ -f "$f" ]] || continue
    name=$(basename "$f")  # VAR=$(cmd) のため run 不使用
    if [[ ! -f "${DST_DIR}/${name}" ]]; then
        NEW+=("$name")
    elif ! diff -q --strip-trailing-cr "${DST_DIR}/${name}" "$f" >/dev/null 2>&1; then  # 条件チェック（CRLF の違いは無視）
        CHANGED+=("$name")
    fi
done

# 雛形にないファイル（情報だけ表示する。削除は --remove のときだけ）
EXTRA=()
if [[ -d "$DST_DIR" ]]; then
    for f in "$DST_DIR"/*.yml "$DST_DIR"/*.yaml; do
        [[ -f "$f" ]] || continue
        name=$(basename "$f")  # VAR=$(cmd) のため run 不使用
        [[ -e "${SRC_DIR}/${name}" ]] || EXTRA+=("$name")
    done
fi

if [[ ${#EXTRA[@]} -gt 0 ]]; then
    log "INFO" "雛形にないワークフロー（変更しません。不要なら --remove <ファイル名>）: ${EXTRA[*]}"
fi

if [[ ${#CHANGED[@]} -eq 0 && ${#NEW[@]} -eq 0 ]]; then
    log "SUCCESS" "ワークフローは最新です（雛形と同じ内容です）。"
    exit $RET_OK
fi

# ------------------------------------------------------------------------------
# 7. 差分の表示
# ------------------------------------------------------------------------------
for name in "${NEW[@]}"; do
    log "WARNING" "新規（雛形にあり、このプロジェクトにない）: ${name}"
done
for name in "${CHANGED[@]}"; do
    log "WARNING" "差分あり: ${name}"
    diff -u --strip-trailing-cr "${DST_DIR}/${name}" "${SRC_DIR}/${name}" >&2 || true  # 差分があると終了コード 1 になるため、意図的にエラーを無視
done

if [[ $CHECK_ONLY -eq 1 ]]; then
    log "WARNING" "ワークフローが、雛形と違います（新規 ${#NEW[@]} 件 / 差分 ${#CHANGED[@]} 件）。"
    exit $RET_NG
fi

# ------------------------------------------------------------------------------
# 8. 確認 → コピー
# ------------------------------------------------------------------------------
ask_yn "雛形の内容で、上記のワークフローを上書きします。よろしいですか？" || die "中断しました。"

run mkdir -p "$DST_DIR" || die "フォルダを作成できません: ${DST_DIR}"
for name in "${NEW[@]}" "${CHANGED[@]}"; do
    run cp "${SRC_DIR}/${name}" "${DST_DIR}/${name}" || die "コピーに失敗しました: ${name}"
    log "SUCCESS" "更新しました: ${DST_DIR}/${name}"
done

log "INFO" "git diff .github/workflows/ で確認して、コミットしてください（コミット・プッシュは、行いません。推奨: sf-push.sh）。"
exit $RET_OK
