#!/bin/bash
# ==============================================================================
# status.sh - セットアップの診断と、段階ごとの Salesforce 接続先の一覧（sf-init.sh --status）
# ==============================================================================
# force-* ディレクトリの中で、次の 2 つを表示する。何も変更しない（読み取りのみ）。
#   1. セットアップの診断（lib/sf-diag.sh）: リポジトリ・ブランチ・ワークフロー・Secrets・Variables が、そろっているか。
#      不足している項目には、直し方を表示する。直近のワークフローの実行結果も表示する（参考）
#   2. 段階（main / staging / develop）ごとの、Salesforce 組織の接続先
#      GitHub の Variables（SF_USERNAME_* / SF_INSTANCE_URL_* / SF_ORG_*）を読む。
#
# 【表示する項目（接続先）】
#   段階 → ログイン先（URL）/ 組織の種類 / 接続ユーザー / 組織 ID / 組織名 / 最終確認日時
#
# 【終了コード】
#   0: 不足なし・違反なし / 1: 診断で不足がある、または、本番組織が main 以外につながっている
#
# 【備考】
#   組織の種類・ID・名前・確認日時は、sf-init.sh（または --reconnect / --add-tier）が、ログイン後に、
#   組織から読み取って保存したもの。保存されていない（以前のバージョンで作ったプロジェクト）場合は、「未確認」と表示する。
#   ここに表示するのは「GitHub に保存された値」であり、いま実際にログインして確認した値ではない。
# ==============================================================================

PHASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_TOOLS_DIR="${SF_TOOLS_DIR:-$(dirname "$PHASE_DIR")}"

readonly SCRIPT_NAME="sf-init"
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true
readonly LOG_FILE="$HOME/sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"
export SF_INIT_MODE=1

source "${SF_TOOLS_DIR}/lib/common.sh"
source "${SF_TOOLS_DIR}/phases/init/init-common.sh"
source "${SF_TOOLS_DIR}/lib/sf-diag.sh"

log "HEADER" "セットアップの診断と、Salesforce 接続（段階ごと）"

check_force_dir || die "force-* ディレクトリ内で実行してください。"

# リポジトリ名を、git remote から取得する
remote_url=$(git remote get-url origin 2>/dev/null) || die "git remote を取得できません。"  # VAR=$(cmd) のため run 不使用
REPO_FULL_NAME=$(echo "$remote_url" | sed 's|.*github\.com[:/]\(.*\)\.git|\1|; s|.*github\.com[:/]\(.*\)|\1|')  # VAR=$(cmd) のため run 不使用
[[ -n "$REPO_FULL_NAME" ]] || die "リポジトリ名を取得できません。"

# 変数 1 つを取得する（なければ空）
_var() { gh variable get "$1" -R "$REPO_FULL_NAME" 2>/dev/null | tr -d '\r' || true; }  # 取得専用のため run 不使用

echo "" >&2
echo "  リポジトリ: ${REPO_FULL_NAME}" >&2
echo "" >&2

BRANCHES_FILE="${PWD}/sf-tools/config/branches.txt"

# セットアップの診断（リポジトリ・ブランチ・ワークフロー・Secrets・Variables・直近の実行）
diag_tiers=("main")
for _t in staging develop; do
    grep -qx "$_t" "$BRANCHES_FILE" 2>/dev/null && diag_tiers+=("$_t")
done
sf_diag_run "$REPO_FULL_NAME" "${diag_tiers[@]}"

echo "" >&2
echo -e "  ${CLR_WARNING}【Salesforce の接続（段階ごと）】${CLR_RESET}" >&2
echo "" >&2
found=0
violation=0   # 本番が main 以外にある場合は、1（終了コードを、非ゼロにする）
declare -A SEEN_ORG
for tier in main staging develop; do
    case "$tier" in
        main)    suffix="PROD" ;;
        staging) suffix="STG" ;;
        develop) suffix="DEV" ;;
    esac
    # branches.txt にない段階は、表示しない（main は、必ず表示する）
    if [[ "$tier" != "main" ]] && ! grep -qx "$tier" "$BRANCHES_FILE" 2>/dev/null; then
        continue
    fi
    url=$(_var "SF_INSTANCE_URL_${suffix}")
    user=$(_var "SF_USERNAME_${suffix}")
    kind=$(_var "SF_ORG_KIND_${suffix}")
    oid=$(_var "SF_ORG_ID_${suffix}")
    oname=$(_var "SF_ORG_NAME_${suffix}")
    chk=$(_var "SF_ORG_CHECKED_${suffix}")
    if [[ -z "$url" && -z "$user" ]]; then
        printf '  %-8s → （未接続）\n' "$tier" >&2
        continue
    fi
    found=1
    printf '  %-8s → %s\n' "$tier" "${url:-（ログイン先が未設定）}" >&2
    printf '             種類: %s / ユーザー: %s\n' "$(sf_org_kind_label "${kind:-unknown}")" "${user:-（未設定）}" >&2
    if [[ -n "$oid" ]]; then
        printf '             組織: %s（ID %s）/ 最終確認: %s\n' "${oname:-（名前なし）}" "$oid" "${chk:-不明}" >&2
        if [[ -n "${SEEN_ORG[$oid]:-}" ]]; then
            log "WARNING" "  ${tier} は、${SEEN_ORG[$oid]} と、同じ組織につながっています（デプロイが、同じ組織の中で、循環します）。"
        fi
        SEEN_ORG[$oid]="$tier"
    else
        printf '             組織: 未確認（組織の情報が、保存されていません）\n' >&2
    fi
    # 本番は main のみ（F8）。保存された種類が、本番なのに、main 以外なら、警告する
    if [[ "$kind" == "production" && "$tier" != "main" ]]; then
        log "ERROR" "  ${tier} が、Salesforce の本番組織につながっています（本番組織は main のみです）。"
        violation=1
    fi
done
echo "" >&2
[[ $found -eq 1 ]] || log "WARNING" "接続情報が、見つかりませんでした（sf-init.sh が、完了していない可能性があります）。"
log "INFO" "接続先を変えるとき: sf-init.sh --reconnect <main|staging|develop>"
# 本番が main 以外にあれば、非ゼロで終了する（管理者のスクリプトから、検知できるように）
[[ $violation -eq 0 && "$DIAG_NG" -eq 0 ]] || exit $RET_NG
exit $RET_OK
