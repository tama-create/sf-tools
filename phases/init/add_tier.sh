#!/bin/bash
# ==============================================================================
# add_tier.sh - ブランチ tier の追加（staging / develop）
# ==============================================================================
# 既存のプロジェクト（force-*）に、段階 staging または develop を追加する。
# Salesforce 組織への接続（Secrets / Variables の登録）を先に行い、そのあとブランチを作り、branches.txt の変更を PR にする。
#
# 【使い方】
#   force-* ディレクトリの中で sf-init.sh --add-tier <staging|develop> を実行する。sf-init.sh が、環境変数 ADD_TIER を
#   export して、このスクリプトを呼び出す。
#
# 【処理の流れ】
#   1. ADD_TIER が空なら die。カレントのフォルダ名が force- で始まらなければ die
#   2. origin の URL から REPO_FULL_NAME・REPO_NAME を求める（parse_github_remote。origin を取得できない・GitHub の URL で
#      なければ die）
#   3. ADD_TIER を確認する（staging / develop 以外は die）。git fetch origin main（失敗は die）のあと、
#      origin/main の sf-tools/config/branches.txt（git show。読めなければ die）で確認する: 同じ名前の行があれば die。
#      develop は、staging の行がなければ die。確認は、追記する版（origin/main）で行う（実行時の作業ツリー（admin など）の
#      branches.txt は、origin/main と食い違うことがあり、それで確認すると、重複がすり抜ける）
#   4. 管理者向けの警告（print_admin_warning）→ check_gh_owner → ask_yn（N / q は die）。GITHUB_ACTIONS=true でも省略しない
#   5. git status --porcelain が空でなければ（未コミットの変更があれば）die
#   6. Salesforce 組織に接続する。~/.sf-jwt/<REPO_NAME>/server.key がなければ die
#        - 既定: server.crt がなければ die。register_jwt_secret_eca（init-common.sh）で、ログイン先の選択 → ブラウザで
#          ログイン → 組織の種類の読み取り → 本番は main のみのガード → 外部クライアントアプリの deploy →
#          コンシューマー鍵の retrieve → JWT 接続テスト → 登録
#        - SF_INIT_LEGACY_CONNECTED_APP=1（--legacy-connected-app）: register_jwt_secret（init-common.sh。
#          コンシューマー鍵・ユーザー名を手動で入力）
#        - 関数が 0 以外を返したときも die
#   7. 実行前のブランチを記録し（取得できなければ main）、git checkout main。origin/main は、取り直さない（手順 3 の版を使う）。
#      origin に ADD_TIER のブランチがあれば作らない。なければ、origin/main から作って push --no-verify -u し、main に戻る
#      （ローカルの main は pull しない。以前は、手元の main から作っていたため、古いと、古い内容から派生した）
#   8. 作業用ブランチ system-add-tier-<ADD_TIER>-<YYYYMMDDHHMMSS> を origin/main から作り、手順 3 で確認した
#      origin/main の branches.txt の全行の末尾に ADD_TIER を足した内容を、一時ファイルに書いてから mv で置き換え、
#      git add → commit --no-verify → push --no-verify -u → gh pr create --base main（main へは、直接 push しない）
#   9. 実行前のブランチ（管理者用のクローンでは admin）に戻る
#   手順 7〜9 の各操作（一時ファイルの書き込み・mv を含む）は、失敗したら die
#
# 【前提条件】
#   - force-* ディレクトリ（リポジトリのクローン）の中で実行すること
#   - ~/.sf-jwt/<REPO_NAME>/server.key（既定では server.crt も）。sf-init Phase 10 が作る
#   - gh の認証ユーザーが、リポジトリのオーナー（組織では、その組織の有効な管理者）であること（check_gh_owner）
#
# 【補足】
#   - 登録する Secrets / Variables（ADD_TIER が staging なら接尾辞 STG、develop なら DEV）:
#       SF_CONSUMER_KEY_<接尾辞>（Secret）/ SF_USERNAME_<接尾辞>・SF_INSTANCE_URL_<接尾辞>（Variable）/
#       SF_ORG_ID_<接尾辞>・SF_ORG_NAME_<接尾辞>・SF_ORG_KIND_<接尾辞>・SF_ORG_CHECKED_<接尾辞>
#       （Variable。組織の情報を読み取れたときだけ）
#   - 手順 6 で die したときは、ブランチと branches.txt は変更しない。ただし、外部クライアントアプリは JWT 接続テストの
#     前に組織へ deploy するため、組織に残る。JWT 接続テストに失敗しても、ask_yn でスキップ（Y）を選ぶと、
#     Secrets / Variables を登録する。いずれも、自動では元に戻さない
#   - 手順 7〜9 で die したときに残るもの（Salesforce への接続（手順 6）は、完了している。自動では、元に戻さない）:
#       ・リモートの <ADD_TIER> ブランチ（手順 7 で作って push したあとに die したとき）
#       ・ローカルの <ADD_TIER> ブランチ（手順 7 で作ったあとに die したとき。カレントのブランチも、そのブランチのまま）
#       ・作業用ブランチ system-add-tier-<ADD_TIER>-<日時>（ローカル。push のあとに die したときは、リモートにも）
#       ・カレントのブランチは、実行前のブランチ（admin）に戻らず、main か、作業用ブランチ（PR_BRANCH）のままになる
#         （作業用ブランチのときは、branches.txt の変更が、未コミットで残ることがある）
#     もう一度 --add-tier を実行すると、リモートの <ADD_TIER> ブランチがあれば作らずに進み（ローカルに同名のブランチが残って
#     いても、作り直す。checkout -B）、新しい作業用ブランチで PR を作る。ただし、作業ツリーに未コミットの変更が残っていると、
#     手順 5 で中断する
#     （Salesforce への接続も、もう一度行う）
#   - branches.txt の変更は、PR をマージすると main に入る（段階として有効になる）。マージ前に、もう一度 --add-tier を
#     実行すると、origin/main にはまだないため、重複の確認では止まらない（PR が 2 本できる）
#   - 環境変数:
#       ADD_TIER                         : 追加する段階（staging | develop。sf-init.sh が export する）
#       SF_INIT_LEGACY_CONNECTED_APP=1   : 従来の接続アプリケーション（手動の入力）を使う
#       SF_INIT_LOGIN_URL_<STG|DEV>      : ログイン先を、質問せずに指定する（login | test | URL）
#       SF_INIT_JWT_RETRIES              : 既定の方式の JWT 接続テストの最大の試行回数（既定 20）
#       SF_INIT_JWT_INTERVAL             : 試行の間の待ち時間（秒。既定 30）。待つのは試行の間だけで、既定では、最大
#                                          (20 - 1) × 30 = 570 秒（約 10 分）待つ（作成したアプリの反映待ち）
#   - ログは ~/sf-tools/logs/sf-init.log に、実行ごとに新しく書く（LOG_MODE=NEW。前回の内容は消える）
#   - 終了コード: 0 = OK / 1 = die
# ==============================================================================

# SF_TOOLS_DIR は sf-init.sh（司令塔）から export される
PHASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_TOOLS_DIR="${SF_TOOLS_DIR:-$(dirname "$(dirname "$PHASE_DIR")")}"

readonly SCRIPT_NAME="sf-init"
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true  # run 不使用: common.sh の読み込み前（run が未定義）
readonly LOG_FILE="$HOME/sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"
export SF_INIT_MODE=1

source "${SF_TOOLS_DIR}/lib/common.sh"
source "${SF_TOOLS_DIR}/phases/init/init-common.sh"

# ------------------------------------------------------------------------------
# 引数取得
# ------------------------------------------------------------------------------
ADD_TIER="${ADD_TIER:-}"  # sf-init.sh から export される
[[ -z "$ADD_TIER" ]] && die "ADD_TIER が未設定です。"

# ------------------------------------------------------------------------------
# 1. force-* ディレクトリであること確認
# ------------------------------------------------------------------------------
log "HEADER" "tier 追加: ${ADD_TIER}"

check_force_dir || die "force-* ディレクトリ内で実行してください。"

# ------------------------------------------------------------------------------
# 2. リポジトリ名を、origin の URL から求める
# ------------------------------------------------------------------------------
BRANCHES_FILE="${PWD}/sf-tools/config/branches.txt"
BRANCHES_REL="sf-tools/config/branches.txt"

remote_url=$(git remote get-url origin 2>/dev/null) || die "git remote を取得できません。"  # VAR=$(cmd) のため run 不使用
# GitHub の URL だけを受け付ける（parse_github_remote: lib/project.sh。出力は「owner repo」）。GitHub 以外は die
_owner_repo=$(parse_github_remote "$remote_url") \
    || die "origin が GitHub のリポジトリではありません: $(git_origin_redacted .)"  # VAR=$(cmd) のため run 不使用
REPO_NAME="${_owner_repo#* }"
REPO_FULL_NAME="${_owner_repo%% *}/${REPO_NAME}"

# ------------------------------------------------------------------------------
# 3. 追加 tier のバリデーション
# ------------------------------------------------------------------------------
case "$ADD_TIER" in
    staging)
        SUFFIX="STG"
        LABEL="ステージング組織"
        ORG_ALIAS="staging"
        ;;
    develop)
        SUFFIX="DEV"
        LABEL="開発組織"
        ORG_ALIAS="develop"
        ;;
    *)
        die "--add-tier には staging または develop を指定してください。"
        ;;
esac

# 確認は、追記する版（origin/main の branches.txt）で行う。実行時の作業ツリー（管理者用のクローンでは admin ブランチ）の
#   branches.txt は、origin/main と食い違うことがある（例: 作業ツリーに staging がなく、origin/main にはある → 重複して追記する）。
#   ここで取得した origin/main を、手順 7・8 でもそのまま使う（取り直さない。確認した版と、追記する版を、同じにするため）
run git fetch origin main || die "origin/main の取得に失敗しました。"
MAIN_BRANCHES=$(git show "origin/main:${BRANCHES_REL}" 2>/dev/null) \
    || die "origin/main の ${BRANCHES_REL} を読めません。"  # VAR=$(cmd) のため run 不使用
MAIN_BRANCHES="${MAIN_BRANCHES//$'\r'/}"

# origin/main の branches.txt に、すでにあるか確認
if printf '%s\n' "$MAIN_BRANCHES" | grep -qx "$ADD_TIER"; then  # 条件チェックのため run 不使用
    die "${ADD_TIER} はすでに branches.txt（origin/main）に登録されています。"
fi

# develop を追加する場合は staging が先に存在するか確認（origin/main の branches.txt で）
if [[ "$ADD_TIER" == "develop" ]]; then
    if ! printf '%s\n' "$MAIN_BRANCHES" | grep -qx "staging"; then  # 条件チェックのため run 不使用
        die "develop を追加するには先に staging が必要です（origin/main の branches.txt にありません）。"
    fi
fi

log "INFO" "  対象リポジトリ: ${REPO_FULL_NAME}"
log "INFO" "  追加 tier     : ${ADD_TIER}（${LABEL}）"

# 管理者向けの警告と確認（CLAUDE.md 2.4）。GITHUB_ACTIONS=true のときも、省略しない（Actions 上で実行する想定がない）
print_admin_warning "!!  このコマンドは管理者専用です" "    段階（ブランチ）と、Salesforce 組織への接続を" "    追加します。Secrets / Variables が書き換わります"
if [[ "${SF_INIT_LEGACY_CONNECTED_APP:-}" == "1" ]]; then
    log "WARNING" "途中で失敗しても、登録した Secrets / Variables と、作成したブランチは、自動では、元に戻しません。"
else
    log "WARNING" "途中で失敗しても、Salesforce 側に作った外部クライアントアプリと、登録した Secrets / Variables と、作成したブランチは、自動では、元に戻しません。"
fi
check_gh_owner "${REPO_FULL_NAME%%/*}"
ask_yn "  続行しますか？" || die "中断しました。"

# 未コミットの変更があると、main への切り替え・ブランチの作成で、衝突するため、先に確認する
if [[ -n "$(git status --porcelain 2>/dev/null)" ]]; then  # 条件チェックのため run 不使用
    die "未コミットの変更があります。コミットまたは退避してから、実行してください。"
fi

# ------------------------------------------------------------------------------
# 4. Salesforce 組織に接続する（先に行う: 本番組織は main にしか、つなげない。接続できなければ、何も変更しない）
# ------------------------------------------------------------------------------
log "HEADER" "Step 1: ${LABEL} を、Salesforce 組織に接続します。"

JWT_DIR="$HOME/.sf-jwt/${REPO_NAME}"
[[ ! -f "${JWT_DIR}/server.key" ]] && die "秘密鍵が見つかりません: ${JWT_DIR}/server.key
  sf-init Phase 10 を先に実行してください。"

if [[ "${SF_INIT_LEGACY_CONNECTED_APP:-}" == "1" ]]; then
    # 従来の接続アプリケーション（今後廃止予定）: コンシューマー鍵・ユーザー名を、手動で入力する
    register_jwt_secret "$ORG_ALIAS" "$SUFFIX" "$LABEL" "${JWT_DIR}/server.key"
else
    # 既定: 外部クライアントアプリケーション（自動で作成する）
    [[ ! -f "${JWT_DIR}/server.crt" ]] && die "証明書が見つかりません: ${JWT_DIR}/server.crt"
    register_jwt_secret_eca "$ORG_ALIAS" "$SUFFIX" "$LABEL" "${JWT_DIR}/server.key" "${JWT_DIR}/server.crt"
fi || die "${LABEL}（${SUFFIX}）の接続に失敗しました。"  # 失敗は関数の中で die する。0 以外が返ったときも、ブランチの追加に進まない

# ------------------------------------------------------------------------------
# 5. branches.txt の更新と、ブランチの追加
#    main への直接 push は、しない（main は、保護されているため）。作業用のブランチで、branches.txt を更新し、
#    PR を作成する。PR をマージすると、branches.txt が main に反映される（管理者が、マージする）
# ------------------------------------------------------------------------------
log "HEADER" "Step 2: ${ADD_TIER} ブランチを追加します。"

# 実行前のブランチを覚える（管理者用のクローンは admin ブランチに置くため、終わったら、そこへ戻る。main に居座らない）
ORIGINAL_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
[[ -n "$ORIGINAL_BRANCH" ]] || ORIGINAL_BRANCH="main"
log "INFO" "実行前のブランチ: ${ORIGINAL_BRANCH}（終わったら、ここへ戻ります）"

run git checkout main || die "main ブランチへの切り替えに失敗しました。"
# 新しいブランチは、リモートの main（手順 3 で取得した origin/main）から作る（手元の main が古いと、古い内容から
#   派生してしまうため。以前は、手元の main から作っていた。手元の main は、更新しない）。
#   origin/main は、ここでは取り直さない（branches.txt を確認した版と、追記する版を、同じにするため）

# 5-1. リモートに ${ADD_TIER} ブランチを作成（origin/main から派生）
if git ls-remote --exit-code --heads origin "$ADD_TIER" > /dev/null 2>&1; then
    # 条件チェックのため run 不使用
    log "INFO" "${ADD_TIER} ブランチはリモートに既に存在します（スキップ）。"
else
    run git checkout -B "$ADD_TIER" origin/main || die "${ADD_TIER} ブランチの作成に失敗しました。"  # -B: 前回の失敗で、ローカルに同名のブランチが残っていても、作り直す
    run git push --no-verify -u origin "$ADD_TIER" \
        || die "${ADD_TIER} ブランチのプッシュに失敗しました。"
    run git checkout main            || die "main ブランチへの切り替えに失敗しました。"
    log "SUCCESS" "${ADD_TIER} ブランチを作成しました。"
fi

# 5-2. 作業用のブランチで branches.txt を更新し、PR を作成する
PR_BRANCH="system-add-tier-${ADD_TIER}-$(date +%Y%m%d%H%M%S)"   # 秒まで含める（同じ分の再実行で、衝突しないため）
run git checkout -b "$PR_BRANCH" origin/main || die "作業用ブランチの作成に失敗しました: ${PR_BRANCH}"

# 書き出す内容は、手順 3 で確認した origin/main の branches.txt（MAIN_BRANCHES。CR は除去済み）の全行（コメント・
#   ブランチ）+ ADD_TIER。作業用ブランチ（origin/main から作った）の作業ツリーの内容と同じ版
TMP_BRANCH_FILE="${BRANCHES_FILE}.tmp"
# run 不使用: 一時ファイルへの書き出し（リダイレクト。失敗は die）
{
    [[ -n "$MAIN_BRANCHES" ]] && printf '%s\n' "$MAIN_BRANCHES"
    echo "$ADD_TIER"
} > "$TMP_BRANCH_FILE" || die "branches.txt の一時ファイルに書き込めません: ${TMP_BRANCH_FILE}"
run mv "$TMP_BRANCH_FILE" "$BRANCHES_FILE" || die "branches.txt の更新に失敗しました: ${BRANCHES_FILE}"
log "SUCCESS" "branches.txt に ${ADD_TIER} を追記しました。"

run git add sf-tools/config/branches.txt \
    || die "git add に失敗しました。"
run git commit --no-verify -m "chore: ${ADD_TIER} tier を追加" \
    || die "git commit に失敗しました。"
# --no-verify: この push は、作業用ブランチへの、管理者による自動の操作のため、pre-push フック（検証の実行）を省く
run git push --no-verify -u origin "$PR_BRANCH" \
    || die "git push に失敗しました（作業用ブランチ: ${PR_BRANCH}。Salesforce への接続は、完了しています）。"

PR_URL=$(run gh pr create --base main --head "$PR_BRANCH" -R "$REPO_FULL_NAME" \
    --title "chore: ${ADD_TIER} tier を追加" \
    --body "branches.txt に ${ADD_TIER} を追加します（sf-init.sh --add-tier ${ADD_TIER} で作成）。マージすると、段階として有効になります。") \
    || die "PR の作成に失敗しました。"  # VAR=$(cmd) のため、PR の URL を取得する
run git checkout "$ORIGINAL_BRANCH" || die "${ORIGINAL_BRANCH} ブランチへの切り替えに失敗しました。"

log "SUCCESS" "tier 追加の準備ができました: ${ADD_TIER}（${LABEL}）"
log "INFO"    "次のステップ:"
log "INFO"    "  ・PR をマージしてください（マージすると、branches.txt が main に反映されます）: $(echo "$PR_URL" | tail -n 1)"
log "INFO"    "  ・GitHub Actions（wf-release / wf-validate）が ${ADD_TIER} ブランチに対して動作することを確認してください。"
log "INFO"    "  ・いまの接続を見る: sf-init.sh --status"

exit $RET_OK
