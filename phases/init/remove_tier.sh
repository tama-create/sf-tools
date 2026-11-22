#!/bin/bash
# ==============================================================================
# remove_tier.sh - 段階を外す（sf-init.sh --remove-tier staging|develop [--purge-secrets]）
# ==============================================================================
# 既存のプロジェクト（force-*）から、段階 staging または develop を外す。設計は doc/tier-scaling-design.md の 5 章。
# 本体は、sf-tools/config/branches.txt からその段階の行を消す PR を作ることだけ。PR をマージすると、伝播・リリース・PR の検証が
# 止まる（workflow が、origin/main の branches.txt で段階を判定するため。同 3 章）。ブランチ・Secrets / Variables・Ruleset・
# Salesforce 組織の中のものは、変えない（戻すときは --add-tier で、接続情報が残っていれば、行を戻すだけで済む）。
# --purge-secrets は、行を消す PR のマージ後に、その段階の接続情報（Secrets / Variables）を消す、別のモード。
#
# 【使い方】
#   force-* ディレクトリの中で sf-init.sh --remove-tier <staging|develop> [--purge-secrets] を実行する。sf-init.sh が、
#   環境変数 REMOVE_TIER（段階）と REMOVE_TIER_PURGE（--purge-secrets のとき 1）を export して、このスクリプトを呼び出す。
#
# 【処理の流れ】（段階を外す。REMOVE_TIER_PURGE が 1 でないとき）
#   1. REMOVE_TIER が staging / develop でなければ die。カレントのフォルダ名が force- で始まらなければ die。
#      origin の URL から REPO_FULL_NAME を求める（parse_github_remote。GitHub の URL でなければ die）
#   2. git fetch origin main（失敗は die）。origin/main の sf-tools/config/branches.txt を読む（読めなければ die）。
#      行の比べ方は、CR と前後の空白を除いて、段階の名前と一致するか（lib/project.sh の get_tier_list と同じ）
#        その段階の行がない → die（すでに外れている）
#        staging を外すのに、develop の行がある → die（develop を先に外す）
#   3. origin/main の workflow が、段階の切り替えに対応しているかを確かめる（同 5.2 の 3）:
#        wf-propagate.yml・wf-release.yml・wf-validate.yml: 判定の部分（# >>> sf-tools: tier-switch v1 〜 # <<<）が、
#          この sf-tools の雛形と同じ（行頭の空白を除いて比べる）で、判定の呼び出しの印（# sf-tools: tier-check）がある
#        wf-metasync.yml: sf-metasync.sh を呼んでいて、workflow の中に（コメントの行を除いて）git push がない
#      満たさないファイルがあれば、INFO で、そのファイル名と、sf-sync-wf.sh で workflow を main まで入れてから実行すること、を
#      表示して die
#   4. 影響を表示する（読み取りのみ。読めないものは WARNING を出して続ける）:
#        a. その段階にだけあって、main にない変更（git log --no-merges --oneline origin/main..origin/<段階>。最大 20 行と件数）
#        b. その段階をマージ先にする、開いている PR（gh pr list --base <段階> --state open）
#        c. その段階の Secrets / Variables の名前（値は出さない）
#        d. その段階のブランチを対象にする Ruleset の名前（gh api repos/<R>/rulesets）
#   5. 管理者向けの警告（print_admin_warning）→ check_gh_owner → ask_yn（N / q は die）。GITHUB_ACTIONS=true でも省略しない
#   6. git status --porcelain が空でなければ die
#   7. 実行前のブランチを記録する。作業用ブランチ system-remove-tier-<段階>-<YYYYMMDDHHMMSS> を origin/main から作り、
#      手順 2 で読んだ branches.txt から、その段階の行だけを除いた内容を、一時ファイルに書いてから mv で置き換える。
#      git add → commit --no-verify → push --no-verify -u → gh pr create --base main
#   8. 実行前のブランチ（管理者用のクローンでは admin）に戻る
#   9. 次にすることを表示する（PR のマージで止まる・残したもの・戻し方・--purge-secrets）
#   手順 7〜8 の各操作は、失敗したら die
#
# 【処理の流れ】（--purge-secrets。REMOVE_TIER_PURGE=1 のとき）
#   1. 上の 1・2 と同じ確かめ。ただし、origin/main の branches.txt に、その段階の行が「ない」こと（PR がマージ済み）を求める
#      （ある → die）。workflow の確かめ（上の 3）はしない（段階はすでに外れている。接続情報を消せば、書き込みは、むしろ止まる）
#   2. 消す候補（決まった名前の一覧: SF_CONSUMER_KEY_<接尾辞>（Secret）・SF_USERNAME_<接尾辞>・SF_INSTANCE_URL_<接尾辞>・
#      SF_ORG_ID_<接尾辞>・SF_ORG_NAME_<接尾辞>・SF_ORG_KIND_<接尾辞>・SF_ORG_CHECKED_<接尾辞>（Variable）。接尾辞は STG / DEV）のうち、
#      GitHub にあるものを表示する（名前だけ）。1 つもなければ、その旨を表示して終了する（終了コード 0）
#   3. 管理者向けの警告 → 値は戻せない旨 → check_gh_owner → ask_yn（N / q は die）
#   4. gh secret delete / gh variable delete を 1 つずつ実行し、結果を表示する。失敗が 1 つでもあれば、終了コード 1
#      （もう一度実行すると、残っているものだけを消す）
#
# 【前提条件】
#   - force-* ディレクトリ（リポジトリのクローン）の中で実行すること
#   - gh の認証ユーザーが、リポジトリのオーナー（組織では、その組織の有効な管理者）であること（check_gh_owner）
#
# 【補足】
#   - 変えるのは、作業用ブランチの push と PR だけ（--purge-secrets を除く）。PR を閉じれば、何も変わっていない状態に戻る
#   - 手順 7 の途中で die したときに残るもの（自動では、元に戻さない）:
#       ・作業用ブランチ system-remove-tier-<段階>-<日時>（ローカル。push のあとに die したときは、リモートにも）
#       ・カレントのブランチは、実行前のブランチに戻らず、作業用ブランチのままになる（branches.txt の変更が、未コミットで残ることがある）
#     もう一度実行すると、新しい作業用ブランチで PR を作る。ただし、未コミットの変更が残っていると、手順 6 で中断する
#   - branches.txt の変更は、PR をマージすると main に入る（段階として無効になる）。マージ前にもう一度実行すると、origin/main には
#     まだ行があるため止まらない（PR が 2 本できる）
#   - ログは ~/sf-tools/logs/sf-init.log に、実行ごとに新しく書く（LOG_MODE=NEW）
#   - 終了コード: 0 = OK / 1 = die・--purge-secrets の一部の失敗
# ==============================================================================

# SF_TOOLS_DIR は sf-init.sh（司令塔）から export される
PHASE_DIR="${BASH_SOURCE[0]%/*}"
[[ "$PHASE_DIR/" == /* && "$PHASE_DIR/" != *//* && "$PHASE_DIR/" != */./* && "$PHASE_DIR/" != */../* ]] || PHASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_TOOLS_DIR="${SF_TOOLS_DIR:-$(dirname "$(dirname "$PHASE_DIR")")}"

readonly SCRIPT_NAME="sf-init"
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true  # run 不使用: common.sh の読み込み前（run が未定義）
readonly LOG_FILE="$HOME/sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"
export SF_INIT_MODE=1

source "${SF_TOOLS_DIR}/lib/common.sh"
source "${SF_TOOLS_DIR}/phases/init/init-common.sh"

REMOVE_TIER="${REMOVE_TIER:-}"              # sf-init.sh から export される
REMOVE_TIER_PURGE="${REMOVE_TIER_PURGE:-}"  # --purge-secrets のとき 1
[[ -z "$REMOVE_TIER" ]] && die "REMOVE_TIER が未設定です。"

BRANCHES_REL="sf-tools/config/branches.txt"

# ------------------------------------------------------------------------------
# 1. 段階・場所・リポジトリの確認
# ------------------------------------------------------------------------------
log "HEADER" "段階を外す: ${REMOVE_TIER}$([[ "$REMOVE_TIER_PURGE" == "1" ]] && echo "（接続情報を消す: --purge-secrets）")"

case "$REMOVE_TIER" in
    staging) SUFFIX="STG" ;;
    develop) SUFFIX="DEV" ;;
    *)       die "--remove-tier には staging または develop を指定してください。" ;;
esac

check_force_dir || die "force-* ディレクトリ内で実行してください。"

remote_url=$(git remote get-url origin 2>/dev/null) || die "git remote を取得できません。"  # VAR=$(cmd) のため run 不使用
_owner_repo=$(parse_github_remote "$remote_url") \
    || die "origin が GitHub のリポジトリではありません: $(git_origin_redacted .)"  # VAR=$(cmd) のため run 不使用
REPO_NAME="${_owner_repo#* }"
REPO_FULL_NAME="${_owner_repo%% *}/${REPO_NAME}"

# ------------------------------------------------------------------------------
# 2. origin/main の branches.txt で確かめる（確かめた版と、書き換える版を同じにする。add_tier.sh と同じ考え方）
# ------------------------------------------------------------------------------
run git fetch origin main || die "origin/main の取得に失敗しました。"
# MSYS_NO_PATHCONV=1: Windows の Git Bash のパスの書き換えを止める（init-common.sh の tier_switch_wf_problems の説明を参照）
MAIN_BRANCHES=$(MSYS_NO_PATHCONV=1 git show "origin/main:${BRANCHES_REL}" 2>/dev/null) \
    || die "origin/main の ${BRANCHES_REL} を読めません。"  # VAR=$(cmd) のため run 不使用
MAIN_BRANCHES="${MAIN_BRANCHES//$'\r'/}"

log "INFO" "  対象リポジトリ: ${REPO_FULL_NAME}"
log "INFO" "  外す段階      : ${REMOVE_TIER}"

# 接続情報の名前（add_tier.sh が登録するもの。--purge-secrets が消すのは、この一覧だけ）
SECRET_NAMES="SF_CONSUMER_KEY_${SUFFIX}"
VARIABLE_NAMES="SF_USERNAME_${SUFFIX} SF_INSTANCE_URL_${SUFFIX} SF_ORG_ID_${SUFFIX} SF_ORG_NAME_${SUFFIX} SF_ORG_KIND_${SUFFIX} SF_ORG_CHECKED_${SUFFIX}"

# GitHub にある Secrets / Variables の名前（読めなければ、空。呼び出し側で扱う）
_existing_secret_names()   { gh secret list -R "$REPO_FULL_NAME" --json name --jq '.[].name' 2>/dev/null; }    # 読み取りのみ。失敗は呼び出し側で扱う
_existing_variable_names() { gh variable list -R "$REPO_FULL_NAME" --json name --jq '.[].name' 2>/dev/null; }  # 読み取りのみ

# ==============================================================================
# --purge-secrets（接続情報を消す）
# ==============================================================================
if [[ "$REMOVE_TIER_PURGE" == "1" ]]; then
    if tier_text_has_line "$MAIN_BRANCHES" "$REMOVE_TIER"; then  # 条件チェックのため run 不使用
        die "${REMOVE_TIER} は、まだ branches.txt（origin/main）にあります。段階を外す PR のマージ前には、接続情報を消せません。"
    fi
    existing_s=$(_existing_secret_names) || die "Secrets の一覧を取得できません。"    # VAR=$(cmd) のため run 不使用
    existing_v=$(_existing_variable_names) || die "Variables の一覧を取得できません。"  # VAR=$(cmd) のため run 不使用
    targets_s=""; targets_v=""
    for n in $SECRET_NAMES;   do printf '%s\n' "$existing_s" | grep -qxF -- "$n" && targets_s="${targets_s}${n} "; done  # 条件チェックのため run 不使用
    for n in $VARIABLE_NAMES; do printf '%s\n' "$existing_v" | grep -qxF -- "$n" && targets_v="${targets_v}${n} "; done  # 条件チェックのため run 不使用
    if [[ -z "$targets_s$targets_v" ]]; then
        log "SUCCESS" "${REMOVE_TIER} の接続情報（Secrets / Variables）は、ありません。消すものはありません。"
        exit $RET_OK
    fi
    print_admin_warning "!!  このコマンドは管理者専用です" "    ${REMOVE_TIER} の接続情報を消します。この段階の" "    組織に、CI からつながらなくなります"
    log "INFO" "消す Secrets  : ${targets_s:-（なし）}"
    log "INFO" "消す Variables: ${targets_v:-（なし）}"
    log "WARNING" "Secret の値は、消すと戻せません（戻すときは sf-init.sh --add-tier ${REMOVE_TIER} で、新しくつなぎ直します）。"
    check_gh_owner "${REPO_FULL_NAME%%/*}"
    ask_yn "  消しますか？" || die "中断しました。"
    failed=0
    for n in $targets_s; do
        if run gh secret delete "$n" -R "$REPO_FULL_NAME"; then log "SUCCESS" "  消しました（Secret）: ${n}"
        else log "WARNING" "  消せませんでした（Secret）: ${n}"; failed=$((failed + 1)); fi
    done
    for n in $targets_v; do
        if run gh variable delete "$n" -R "$REPO_FULL_NAME"; then log "SUCCESS" "  消しました（Variable）: ${n}"
        else log "WARNING" "  消せませんでした（Variable）: ${n}"; failed=$((failed + 1)); fi
    done
    if [[ "$failed" -gt 0 ]]; then
        log "ERROR" "${failed} 個を消せませんでした。もう一度実行すると、残っているものだけを消します。"
        exit $RET_NG
    fi
    log "SUCCESS" "${REMOVE_TIER} の接続情報を消しました。"
    exit $RET_OK
fi

# ==============================================================================
# 段階を外す（branches.txt の行を消す PR を作る）
# ==============================================================================
tier_text_has_line "$MAIN_BRANCHES" "$REMOVE_TIER" \
    || die "${REMOVE_TIER} は branches.txt（origin/main）にありません（すでに外れています）。"
if [[ "$REMOVE_TIER" == "staging" ]] && tier_text_has_line "$MAIN_BRANCHES" "develop"; then  # 条件チェックのため run 不使用
    die "staging を外すには、先に develop を外す必要があります（origin/main の branches.txt に develop があります）。"
fi

# ------------------------------------------------------------------------------
# 3. origin/main の workflow が、段階の切り替えに対応しているか
# ------------------------------------------------------------------------------
bad_wf=$(tier_switch_wf_problems)  # VAR=$(cmd) のため run 不使用（init-common.sh）
if [[ -n "$bad_wf" ]]; then
    log "INFO" "origin/main の workflow が、段階の切り替えに対応していません（または、雛形と違います）: ${bad_wf}"
    log "INFO" "  sf-tools を更新し、作業用のブランチで sf-sync-wf.sh を実行して、workflow を main まで入れてから、実行してください。"
    log "INFO" "  （古い workflow のままでは、branches.txt から行を消しても、伝播・リリース・検証は止まりません）"
    die "origin/main の workflow が、段階の切り替えに対応していません: ${bad_wf}"
fi
log "SUCCESS" "origin/main の workflow は、段階の切り替えに対応しています。"

# ------------------------------------------------------------------------------
# 4. 影響を表示する（読み取りのみ）
# ------------------------------------------------------------------------------
log "HEADER" "段階を外したときの影響（${REMOVE_TIER}）"
if run git fetch origin "$REMOVE_TIER"; then
    only_cnt=$(git rev-list --no-merges --count "origin/main..origin/${REMOVE_TIER}" 2>/dev/null || echo "?")  # VAR=$(cmd) のため run 不使用
    log "INFO" "a. ${REMOVE_TIER} にだけあって、main にない変更: ${only_cnt} 件（ブランチは消さないので、失われません。ただし、リリースされなくなります）"
    if [[ "$only_cnt" != "0" && "$only_cnt" != "?" ]]; then
        git log --no-merges --oneline "origin/main..origin/${REMOVE_TIER}" 2>/dev/null | head -20 | while IFS= read -r l; do log "INFO" "     ${l}"; done  # 表示のみのため run 不使用
    fi
else
    log "WARNING" "a. ${REMOVE_TIER} ブランチを取得できません（リモートにない可能性があります）。"
fi
prs=$(gh pr list -R "$REPO_FULL_NAME" --base "$REMOVE_TIER" --state open --json number,title --jq '.[] | "#\(.number) \(.title)"' 2>/dev/null) \
    && log "INFO" "b. ${REMOVE_TIER} をマージ先にする、開いている PR: $([[ -z "$prs" ]] && echo "なし")" \
    || log "WARNING" "b. 開いている PR を取得できません。"   # VAR=$(cmd) のため run 不使用（読み取りのみ）
[[ -n "${prs:-}" ]] && printf '%s\n' "$prs" | while IFS= read -r l; do log "INFO" "     ${l}（マージしても、リリース・検証されなくなります）"; done
es=$(_existing_secret_names || true); ev=$(_existing_variable_names || true)  # VAR=$(cmd) のため run 不使用
names=""
for n in $SECRET_NAMES $VARIABLE_NAMES; do
    printf '%s\n%s\n' "$es" "$ev" | grep -qxF -- "$n" && names="${names}${n} "  # 条件チェックのため run 不使用
done
log "INFO" "c. ${REMOVE_TIER} の接続情報（名前だけ）: ${names:-なし}"
[[ -n "$names" ]] && log "INFO" "     残します（段階が無効のあいだは、使われません）。消すには、PR のマージ後に sf-init.sh --remove-tier ${REMOVE_TIER} --purge-secrets"
rs=$(gh api "repos/${REPO_FULL_NAME}/rulesets" --jq '.[] | "\(.id) \(.name)"' 2>/dev/null) || rs="__ERR__"  # VAR=$(cmd) のため run 不使用（読み取りのみ）
if [[ "$rs" == "__ERR__" ]]; then
    log "WARNING" "d. Ruleset の一覧を取得できません。"
else
    hit=""
    while IFS= read -r l; do
        [[ -z "$l" ]] && continue
        inc=$(gh api "repos/${REPO_FULL_NAME}/rulesets/${l%% *}" --jq '.conditions.ref_name.include[]?' 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
        printf '%s\n' "$inc" | grep -qxF -- "refs/heads/${REMOVE_TIER}" && hit="${hit}${l#* } "  # 条件チェックのため run 不使用
    done <<< "$rs"
    log "INFO" "d. ${REMOVE_TIER} を対象にする Ruleset: ${hit:-なし}"
    [[ -n "$hit" ]] && log "INFO" "     残します。段階が無効のあいだは、${REMOVE_TIER} への PR を出さないでください。"
fi

# ------------------------------------------------------------------------------
# 5. 管理者向けの警告と確認（CLAUDE.md 2.4）。GITHUB_ACTIONS=true のときも、省略しない
# ------------------------------------------------------------------------------
print_admin_warning "!!  このコマンドは管理者専用です" "    段階 ${REMOVE_TIER} を外す PR を作ります" "    （マージすると、伝播・リリース・検証が止まります）"
log "INFO" "変えるのは、branches.txt の PR だけです。ブランチ・Secrets / Variables・Ruleset・Salesforce 組織は、変えません。"
check_gh_owner "${REPO_FULL_NAME%%/*}"
ask_yn "  続行しますか？" || die "中断しました。"

# 6. 未コミットの変更があると、ブランチの切り替えで衝突するため、先に確認する
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then  # 条件チェックのため run 不使用
    die "未コミットの変更があります。コミットまたは退避してから、実行してください。"
fi

# ------------------------------------------------------------------------------
# 7. 作業用ブランチで branches.txt を書き換え、PR を作る（main へは、直接 push しない）
# ------------------------------------------------------------------------------
ORIGINAL_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
[[ -n "$ORIGINAL_BRANCH" ]] || ORIGINAL_BRANCH="main"
log "INFO" "実行前のブランチ: ${ORIGINAL_BRANCH}（終わったら、ここへ戻ります）"

PR_BRANCH="system-remove-tier-${REMOVE_TIER}-$(date +%Y%m%d%H%M%S)"   # 秒まで含める（同じ分の再実行で、衝突しないため）
run git checkout -b "$PR_BRANCH" origin/main || die "作業用ブランチの作成に失敗しました: ${PR_BRANCH}"

BRANCHES_FILE="${PWD}/${BRANCHES_REL}"
TMP_BRANCH_FILE="${BRANCHES_FILE}.tmp"
# run 不使用: 一時ファイルへの書き出し（リダイレクト。失敗は die）
tier_text_without_line "$MAIN_BRANCHES" "$REMOVE_TIER" > "$TMP_BRANCH_FILE" \
    || die "branches.txt の一時ファイルに書き込めません: ${TMP_BRANCH_FILE}"
run mv "$TMP_BRANCH_FILE" "$BRANCHES_FILE" || die "branches.txt の更新に失敗しました: ${BRANCHES_FILE}"
log "SUCCESS" "branches.txt から ${REMOVE_TIER} の行を消しました。"

run git add "$BRANCHES_REL" || die "git add に失敗しました。"
run git commit --no-verify -m "chore: ${REMOVE_TIER} tier を外す" || die "git commit に失敗しました。"
# --no-verify: 作業用ブランチへの、管理者による自動の操作のため、pre-push フック（検証の実行）を省く
run git push --no-verify -u origin "$PR_BRANCH" || die "git push に失敗しました（作業用ブランチ: ${PR_BRANCH}）。"

PR_URL=$(run gh pr create --base main --head "$PR_BRANCH" -R "$REPO_FULL_NAME" \
    --title "chore: ${REMOVE_TIER} tier を外す" \
    --body "branches.txt から ${REMOVE_TIER} を外します（sf-init.sh --remove-tier ${REMOVE_TIER} で作成）。マージすると、${REMOVE_TIER} への伝播・リリース・PR の検証が止まります。ブランチ・接続情報（Secrets / Variables）・Ruleset は残すので、sf-init.sh --add-tier ${REMOVE_TIER} で戻せます。") \
    || die "PR の作成に失敗しました。"  # VAR=$(cmd) のため、PR の URL を取得する

# 8. 実行前のブランチに戻る
run git checkout "$ORIGINAL_BRANCH" || die "${ORIGINAL_BRANCH} ブランチへの切り替えに失敗しました。"

# 9. 次にすること
log "SUCCESS" "段階を外す PR を作りました: ${PR_URL}"
log "INFO"    "次のステップ:"
log "INFO"    "  1. PR をマージすると、${REMOVE_TIER} への伝播・リリース・PR の検証が止まります"
log "INFO"    "  2. 残したもの: ${REMOVE_TIER} ブランチ・接続情報（Secrets / Variables）・Ruleset・組織の外部クライアントアプリ"
log "INFO"    "  3. 戻すとき: sf-init.sh --add-tier ${REMOVE_TIER}（接続情報が残っていれば、つなぎ直さずに戻せます）"
log "INFO"    "  4. 接続情報を消すとき: PR のマージ後に sf-init.sh --remove-tier ${REMOVE_TIER} --purge-secrets"
log "INFO"    "  5. ブランチを消すときは、手で（消す前に、上の a の「main にない変更」を確かめてください）"
exit $RET_OK
