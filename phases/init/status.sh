#!/bin/bash
# ==============================================================================
# status.sh - セットアップの診断と、段階ごとの Salesforce 接続先の一覧（sf-init.sh --status）
# ==============================================================================
# force-* ディレクトリの中で、セットアップの診断と、段階ごとの Salesforce 組織の接続先を表示する。
# 何も変更しない（読み取りのみ）。
#
# 【使い方】
#   force-* ディレクトリの中で sf-init.sh --status を実行する（sf-init.sh が、このスクリプトを呼び出す）。
#   sf-init.sh は、完了済みのプロジェクトの選択画面（[1] いまの Salesforce の接続を見る）からも、呼び出す。
#
# 【処理の流れ】
#   1. カレントのフォルダ名が force- で始まらなければ die。origin の URL からリポジトリ名を求める（parse_github_remote。
#      origin がない・GitHub の URL でなければ die）
#   2. セットアップの診断（lib/diag.sh の diag_run）: リポジトリ・ブランチ・ワークフロー・Secrets・Variables が、そろっているか。
#      ブランチ保護（Ruleset protect-main / protect-staging）の必須チェックの名前が、ワークフローのジョブ名と合っているか。
#      不足している項目には、直し方を表示する。直近のワークフローの実行結果も表示する（参考）。
#      対象の段階は、main と、sf-tools/config/branches.txt にある staging / develop
#   3. 段階（main / staging / develop）ごとの接続先: GitHub の Variables（SF_USERNAME_* / SF_INSTANCE_URL_* / SF_ORG_*）を読み、
#      ログイン先（URL）/ 組織の種類 / 接続ユーザー / 組織名 / 組織 ID / 最終確認日時 を表示する。
#      staging / develop は、branches.txt にあるときだけ表示する（main は、必ず表示する）。
#      SF_INSTANCE_URL_* と SF_USERNAME_* の両方がない段階は「（未接続）」と表示する
#        - 同じ組織 ID の段階が、すでに表示した段階にあれば、WARNING（デプロイが、同じ組織の中で、循環する）
#        - 保存された種類が本番（production）の段階が、main 以外にあれば、ERROR（本番組織は main のみ: F8）
#      接続情報が、どの段階にもなければ、WARNING
#
# 【補足】
#   - 組織の種類・ID・名前・確認日時は、sf-init.sh（または --reconnect / --add-tier）が、ログイン後に、組織から読み取って
#     保存したもの。保存されていない（以前のバージョンで作ったプロジェクト）場合は、組織は「未確認」、種類は
#     「種類を判定できません」と表示する。ここに表示するのは「GitHub に保存された値」であり、いま実際にログインして確認した値ではない
#   - 管理者向けの警告・確認は、出さない（読み取りのみのため）
#   - 終了コード: 0 = 不足なし・違反なし / 1 = 診断で不足がある（DIAG_NG が 1 以上）、または、本番組織が main 以外に
#     つながっている（die のときも 1）
# ==============================================================================

PHASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_TOOLS_DIR="${SF_TOOLS_DIR:-$(dirname "$(dirname "$PHASE_DIR")")}"

readonly SCRIPT_NAME="sf-init"
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true  # run 不使用: common.sh の読み込み前（run が未定義）
readonly LOG_FILE="$HOME/sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"
export SF_INIT_MODE=1

source "${SF_TOOLS_DIR}/lib/common.sh"
source "${SF_TOOLS_DIR}/phases/init/init-common.sh"
source "${SF_TOOLS_DIR}/lib/diag.sh"

log "HEADER" "セットアップの診断と、Salesforce 接続（段階ごと）"

check_force_dir || die "force-* ディレクトリ内で実行してください。"

# リポジトリ名を、git remote から取得する
remote_url=$(git remote get-url origin 2>/dev/null) || die "git remote を取得できません。"  # VAR=$(cmd) のため run 不使用
# GitHub の URL だけを受け付ける（parse_github_remote: lib/project.sh。出力は「owner repo」）。GitHub 以外は die
_owner_repo=$(parse_github_remote "$remote_url") \
    || die "origin が GitHub のリポジトリではありません: $(git_origin_redacted .)"  # VAR=$(cmd) のため run 不使用
REPO_FULL_NAME="${_owner_repo%% *}/${_owner_repo#* }"

# 変数 1 つを取得する（なければ空）
_var() { gh variable get "$1" -R "$REPO_FULL_NAME" 2>/dev/null | tr -d '\r' || true; }  # 取得専用のため run 不使用

echo "" >&2
echo "  リポジトリ: ${REPO_FULL_NAME}" >&2
echo "" >&2

BRANCHES_FILE="${PWD}/sf-tools/config/branches.txt"

# セットアップの診断（リポジトリ・ブランチ・ワークフロー・Secrets・Variables・ブランチ保護（Ruleset）・直近の実行）
diag_tiers=("main")
for _t in staging develop; do
    grep -qx "$_t" "$BRANCHES_FILE" 2>/dev/null && diag_tiers+=("$_t")  # 条件チェックのため run 不使用
done
diag_run "$REPO_FULL_NAME" "${diag_tiers[@]}"

echo "" >&2
echo -e "  ${CLR_WARNING}【Salesforce の接続（段階ごと）】${CLR_RESET}" >&2
echo "" >&2
found=0
violation=0   # 本番が main 以外にある場合は、1（終了コードを、非ゼロにする）
# 表示済みの組織 ID と、その段階（同じ添字で対応する。連想配列は Bash 4 以降のため使わない）
SEEN_ORG_IDS=()
SEEN_ORG_TIERS=()
for tier in main staging develop; do
    case "$tier" in
        main)    suffix="PROD" ;;
        staging) suffix="STG" ;;
        develop) suffix="DEV" ;;
    esac
    # branches.txt にない段階は、表示しない（main は、必ず表示する）
    if [[ "$tier" != "main" ]] && ! grep -qx "$tier" "$BRANCHES_FILE" 2>/dev/null; then  # 条件チェックのため run 不使用
        continue
    fi
    url=$(_var "SF_INSTANCE_URL_${suffix}")    # VAR=$(cmd) のため run 不使用
    user=$(_var "SF_USERNAME_${suffix}")       # VAR=$(cmd) のため run 不使用
    kind=$(_var "SF_ORG_KIND_${suffix}")       # VAR=$(cmd) のため run 不使用
    oid=$(_var "SF_ORG_ID_${suffix}")          # VAR=$(cmd) のため run 不使用
    oname=$(_var "SF_ORG_NAME_${suffix}")      # VAR=$(cmd) のため run 不使用
    chk=$(_var "SF_ORG_CHECKED_${suffix}")     # VAR=$(cmd) のため run 不使用
    if [[ -z "$url" && -z "$user" ]]; then
        printf '  %-8s → （未接続）\n' "$tier" >&2
        continue
    fi
    found=1
    printf '  %-8s → %s\n' "$tier" "${url:-（ログイン先が未設定）}" >&2
    printf '             種類: %s / ユーザー: %s\n' "$(org_kind_label "${kind:-unknown}")" "${user:-（未設定）}" >&2
    if [[ -n "$oid" ]]; then
        printf '             組織: %s（ID %s）/ 最終確認: %s\n' "${oname:-（名前なし）}" "$oid" "${chk:-不明}" >&2
        # 同じ組織 ID が、すでにあれば警告する（複数あるときは、あとの段階を表示する。上書きしていた従来と同じ）
        seen_tier=""
        for (( _i = 0; _i < ${#SEEN_ORG_IDS[@]}; _i++ )); do
            [[ "${SEEN_ORG_IDS[$_i]}" == "$oid" ]] && seen_tier="${SEEN_ORG_TIERS[$_i]}"
        done
        if [[ -n "$seen_tier" ]]; then
            log "WARNING" "  ${tier} は、${seen_tier} と、同じ組織につながっています（デプロイが、同じ組織の中で、循環します）。"
        fi
        SEEN_ORG_IDS+=("$oid")
        SEEN_ORG_TIERS+=("$tier")
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
# 本番が main 以外にある、または、診断で不足があれば、非ゼロで終了する（管理者のスクリプトから、検知できるように）
[[ $violation -eq 0 && "$DIAG_NG" -eq 0 ]] || exit $RET_NG
exit $RET_OK
