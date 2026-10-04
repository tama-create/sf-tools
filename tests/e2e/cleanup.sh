#!/bin/bash
# ==============================================================================
# cleanup.sh - e2e テストで作ったテスト用のものを削除する（GitHub / Salesforce / ローカル）
# ==============================================================================
# 既定では、削除対象の一覧を表示するだけで、何も削除しない。--yes を付けたときだけ削除する。
#
# 【削除の対象】（名前の形式とオーナーが一致するものだけ。他のものは絶対に消えない）
#   1. GitHub    : {E2E_OWNER}/force-e2e-YYYYMMDD-HHMMSS のリポジトリ
#   2. Salesforce: SF_TOOLS_force_e2e_YYYYMMDD_HHMMSS の外部クライアントアプリ（5 つの構成要素）
#   3. ローカル  : {E2E_HOME_ROOT}/{E2E_OWNER}/e2e-YYYYMMDD-HHMMSS と ~/.sf-jwt/force-e2e-YYYYMMDD-HHMMSS
#                  と、強制終了で残った一時ファイル・フォルダ（$TMPDIR の e2e-run.* / e2e-eca-del.* / e2e-sfdx-url.*。
#                  認証 URL を含むことがある。30 分以内のものは、実行中の可能性があるため対象外）
#
# 【オプション】
#   --yes         : 実際に削除する（確認のため、delete と入力させる）
#   --no-confirm  : --yes のときの確認（警告・delete の入力）を省略する（run.sh が使う）
#   -h, --help    : このヘルプを表示する
#
# 【注意】
#   ・Salesforce の一覧・削除のため、認証 URL でテスト用組織にログインし直す（組織の認証が置き換わる）
#   ・リポジトリの削除には、gh に delete_repo の権限が必要
#       gh auth refresh -h github.com -s delete_repo
#   ・一覧の取得に失敗したときは、数回やり直し、それでも失敗なら「対象なし」とは表示せず、エラーで終わる
# ==============================================================================

readonly SCRIPT_NAME="e2e-cleanup"
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true
readonly LOG_FILE="$HOME/sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"

export SF_INIT_MODE=1   # プロジェクト外から実行するため、force-* チェックをバイパスする
E2E_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_TOOLS_ROOT="$(cd "${E2E_SCRIPT_DIR}/../.." && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}"
    exit 0
fi

source "${SF_TOOLS_ROOT}/lib/common.sh"
source "${E2E_SCRIPT_DIR}/lib.sh"

DO_DELETE=0
NO_CONFIRM=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)        DO_DELETE=1 ;;
        --no-confirm) NO_CONFIRM=1 ;;
        *) die "不明なオプションです: $1" ;;
    esac
    shift
done

e2e_load_fixture
e2e_guard_env

# 管理用ログインで付けた一時エイリアスは、終了時に外す（認証そのものは残る）
trap 'sf alias unset "$E2E_ADMIN_ALIAS" >/dev/null 2>&1 || true' EXIT  # 後始末のため run 不使用・エラー無視

log "HEADER" "e2e のテスト用リソースの削除 (${SCRIPT_NAME}.sh)"

if [[ $DO_DELETE -eq 0 ]]; then
    e2e_cleanup_all list || die "一覧を取得できなかったものがあります。"
    log "INFO" "一覧の表示のみです。削除するには --yes を付けて実行してください。"
    exit $RET_OK
fi

if [[ $NO_CONFIRM -eq 0 ]]; then
    echo -e "${CLR_ERR}╔══════════════════════════════════════════════════════╗${CLR_RESET}" >&2
    echo -e "${CLR_ERR}║  !!  e2e のテスト用リソースを削除します              ║${CLR_RESET}" >&2
    echo -e "${CLR_ERR}║      GitHub のリポジトリ・Salesforce のアプリ・      ║${CLR_RESET}" >&2
    echo -e "${CLR_ERR}║      ローカルのフォルダが対象です（名前が一致する    ║${CLR_RESET}" >&2
    echo -e "${CLR_ERR}║      e2e 用のものだけ）。元に戻せません。            ║${CLR_RESET}" >&2
    echo -e "${CLR_ERR}╚══════════════════════════════════════════════════════╝${CLR_RESET}" >&2
    e2e_cleanup_all list || die "一覧を取得できなかったものがあります。"
    ask_yn "上の一覧を削除しますか？" || die "中断しました。"
    answer=""
    read_input answer "  確認のため delete と入力してください: " || die "中断しました。"
    [[ "$answer" == "delete" ]] || die "中断しました。"
fi

e2e_cleanup_all delete || die "削除に失敗したものがあります。"
log "SUCCESS" "削除が完了しました。"
exit $RET_OK
