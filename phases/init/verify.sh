#!/bin/bash
# ==============================================================================
# verify.sh - 実際のリポジトリと組織で、リリース・削除が動くことを検証する（sf-init.sh --verify。管理者向け）
# ==============================================================================
# sf-init で作った、実際のリポジトリ（force-*）が、実際の Salesforce 組織に対して、正しく動くことを確認する。
# 誰も使わない、単純な Apex（Hello World: SfToolsE2eHello / SfToolsE2eHelloTest）を、各段階にリリースして、削除する。
# 何をするかを先に表示し、Enter を 1 回押して確認してから、実行する。
#
# 【使い方】
#   force-* ディレクトリの中で、sf-init.sh --verify [オプション] を実行する。下の【オプション】は、すべて、そのまま、
#   このスクリプトに渡る。sf-init.sh は、セットアップの最後のステップ（動作の確認）と、完了済みのときのメニューからも、
#   このスクリプトを呼び出す。
#
# 【オプション】
#   --plan     : 診断と、実行内容の表示だけを行う（何も変更しない。確認も出さない）
#   --no-metasync : 環境の確認のうち、wf-metasync の実行を、省略する（組織からの同期を、いま行いたくないとき）
#   --cleanup   : 削除のみを行う（リリースの途中で止まって、組織に Hello World が残ったときの後始末）。
#                 対象は、固定名のクラス（SfToolsE2eHello / SfToolsE2eHelloTest）だけ。ほかのクラスには、触れない
#                 （--components と一緒のときは、サンプルが対象）。すべての段階に削除の PR を出し、remove-target.txt に
#                 # @ignore-missing を付けて、組織にない削除対象をエラーにしない
#   --components : Hello World の代わりに、パターン別のサンプル（Apex・トリガー・LWC・Aura・Flow・権限セット・Layout・
#                 メール テンプレート・カスタム表示ラベル・オブジェクト・項目）を、develop の組織だけに、リリースして、削除する
#                 （lib/verify-samples.sh。リリースと削除の通しでは、オブジェクト系は --with-objects のときだけ、Flow は含めない。
#                 --validate-only では、すべて含める）。ターゲットファイルの書式（[files] / [members]）・パス・名前の書き方が、種類ごとに
#                 違っても、リリースの仕組みが動くことの確認。develop の組織がある構成（3 層）だけで、実行できる。
#                 削除は、段階 1（ほかから参照されないもの）。--with-objects のときは、続けて段階 2（項目・オブジェクト）も行う
#                 --components で、develop に、サンプル以外のラベルを含む labels のファイル（CustomLabels）がすでにあるときは、
#                 上書きを避けるため、CustomLabels をサンプルに含めない
#   --with-objects : （--components と一緒に。なければ die）オブジェクト系（ApexTrigger とそのテスト・Layout・CustomObject・CustomField）も、
#                 リリースして、削除する（削除は 2 段階）。既定では、含めない: カスタムオブジェクトは、削除すると、15 日間、
#                 削除済みの状態で名前が予約され、同じ API 名を再作成できない（ごみ箱から消すまで）ため。--validate-only は、
#                 何も作らないため、常に含める（オブジェクトへの依存関係まで、実際の組織で検証する）
#   （Flow は、接続ユーザーに、API で削除する権限がない場合があるため、通しには含めず、--validate-only だけで検証する。
#     --cleanup は、リポジトリの Flow のファイルを削除する。組織に残った Flow は、画面（設定 → フロー）で、手動で削除する）
#   --validate-only : （--components と一緒に。なければ die。--cleanup とは一緒に指定できない）検証だけを行う。
#                 サンプルの PR を develop 向けに出し、wf-validate（dry-run）の成功を確認して、PR は、マージせずに閉じる。
#                 組織には、何も反映しない
#   -h, --help  : このヘルプを表示して終了する（第 1 引数に指定したときのみ。sf-init.sh --verify -h では、sf-init.sh の
#                 ヘルプが出る）
#   ※ そのほかの引数は、「不明なオプションです」で終了する（終了コード 1）
#
# 【処理の流れ】
#   0. 前提の確認    : オプションの組み合わせが不正なら die。GITHUB_ACTIONS=true なら die。カレントのフォルダ名が force- で
#                      始まらなければ die。origin の URL からリポジトリ名（OWNER/REPO）を求める（parse_github_remote。
#                      origin がない・GitHub の URL でなければ die）。check_gh_owner。
#                      段階は、リモートのブランチから決める（一覧を取得できない・main がなければ die。staging があれば staging、
#                      develop と staging の両方があれば develop も。--components のときは develop だけで、develop がなければ die）。
#                      --components では、develop の labels のファイルを確かめる（【オプション】--components）
#   1. 診断          : セットアップの状態（sf-init.sh --status と同じ lib/diag.sh の診断。対象は、手順 0 で決めた段階だけ）。
#                      不足があれば die。
#                      --cleanup 以外では、検証用と同じパスのファイルが、いずれかの段階のブランチにすでにあれば die
#   2. 実行内容の表示 : リポジトリ・段階ごとの組織の名前と種類・実行する内容・目安の時間。本番（または種類を判定できない）
#                      組織は、赤く表示する。--plan は、ここで終了する
#   3. 確認          : 管理者向けの警告と、Enter の確認（Enter / Y で進む。N / q は、何も変更せずに中断）。本番（または
#                      種類を判定できない）組織があるときは、質問の文面で、本番を含むことを明示する。
#                      SF_VERIFY_CONFIRMED=1（sf-init.sh のセットアップの最後のステップから呼ばれたとき。sf-init.sh 側で
#                      確認済み）は、警告と確認を省く
#   3b. 環境の確認   : --cleanup 以外のとき、環境全体を、最初に確認する（e2e の確認と同じ観点）。NG があれば、そこで止める
#                      （組織に、何も変更しない。wf-metasync は、手前の 2 つの確認が OK のときだけ、実行する）
#                        ・SF_TOOLS_BRANCH が、main または development である
#                        ・ローカルのログ（~/sf-tools/logs/*.log）に、Token・認証 URL が残っていない
#                        ・wf-metasync（Salesforce → Git の同期）を、手動で 1 回実行し、成功する（--no-metasync で省略）
#                          （JWT ログイン・sf-tools の取得を含む。main の組織の変更が、main にコミットされることがある）
#   4. リリース      : --cleanup 以外のとき。リリース用のブランチ（main の先頭から作り、検証用のファイルと、リリース対象を置く）
#                      1 本から、develop → staging → main の順（ない段階は、とばす）に、段階ごとの PR を出して、
#                      wf-validate（検証）→ マージ → wf-release（リリース）。wf-validate・wf-release・wf-propagate が
#                      失敗したときは、ログの末尾を表示して、1 回だけ再実行する。段階ごとに、次を確認する:
#                        ・その段階の組織への JWT ログインが成功した
#                        ・ほかの段階のログインのステップは、実行されていない（別の組織に、ログインしていない。
#                          ステップが見つからないときは、注意の表示のみ）
#                        ・接続ユーザー（SF_USERNAME_*）が登録されていて、ログに、そのユーザーが出ている
#                        ・ログに、Hello World のクラス名が出ている
#                        ・（参考）Slack への通知の成功。確認できなくても、注意の表示のみで、成否に含めない
#                      main へのマージのあとは、wf-propagate も確認する（失敗しても、続きを進める）。
#                      上の確認の失敗は、記録して続ける（削除まで行って、組織を元に戻すため）。PR の作成・ワークフローの
#                      実行・マージなど、流れそのものが失敗したときは、そこで止めて、案内を表示し、終了コード 1 で終わる。
#                      --validate-only は、wf-validate の成功を確認して、PR をマージせずに閉じる（手順 5 は行わない）
#   5. 削除          : 削除用のブランチ（main の先頭から作る。remove-target.txt と、リポジトリのクラスのファイルの削除）から、
#                      同じ順に、各段階へ PR → wf-validate → マージ → wf-release（main のあとは wf-propagate も）。
#                      段階ごとに、手順 4 と同じ確認を行う。組織のクラスと、リポジトリのファイルの両方が、消える
#                      （--components は develop の先頭から作り、--with-objects のときは、2 段階で削除する。段階 2 では、
#                      ログに、サンプルのオブジェクトの名前が出ていることを確認する）
#   5b. 後始末       : 今回作った作業用ブランチを、削除する（verify-hello-HHMMSS / verify-hello-delete-HHMMSS。
#                      --components では verify-comp-HHMMSS / verify-comp-delete-HHMMSS / verify-comp-delete2-HHMMSS）。
#                      名前がこの形式でないもの・開いている PR がある（または確認できない）ものは、削除しない。
#                      PR の履歴は、PR の番号で残る。途中で止めたときは、調査のために、残す。削除の失敗は、検証の成否に含めない
#   6. 結果の表示    : 確認の成功・失敗の件数（再実行で成功したワークフローがあれば、その件数も）
#
# 【前提条件】
#   - force-* ディレクトリ（origin が GitHub のリポジトリ）の中で実行すること
#   - gh の認証ユーザーが、リポジトリのオーナー（組織では、その組織の有効な管理者）であること（check_gh_owner）
#   - sf-init のセットアップが済んでいること（手順 1 の診断が OK であること）
#
# 【補足】
#   ・リポジトリに、PR・コミット（追加と削除）が、残る（作業用ブランチは、最後に削除する）。Slack に、通知が届く。
#     リリースの間、組織が、短時間、占有される
#   ・作業の少ない時間帯に、実行すること
#   ・失敗したとき: リリースのあとで止まった場合、組織に Hello World が残ることがある。
#     残った段階と、削除のみをやり直す方法（--cleanup）を、表示する
#   ・ブランチ保護で、PR のマージが拒否されると、その段階で止まり、PR が残る
#   ・検証用と同じパスのファイル（Hello World では SfToolsE2eHello / SfToolsE2eHelloTest）が、すでにリポジトリにあると、
#     上書きして削除してしまうため、実行しない（--cleanup を除く）。組織だけにある同名のクラスは、検出できない
#   ・ログは ~/sf-tools/logs/verify.log に、実行ごとに新しく書く（sf-init.log とは別）
#   ・終了コード: 0 = すべての確認が成功（--plan・--help を含む）/ 1 = 失敗した確認がある・途中で止めた・die
# ==============================================================================

PHASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_TOOLS_DIR="${SF_TOOLS_DIR:-$(dirname "$(dirname "$PHASE_DIR")")}"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}"  # run 不使用: common.sh の読み込み前（run が未定義）
    exit 0
fi

# ログは、sf-init.log とは別のファイルに書く（sf-init.sh のステップ 9 から呼ばれたとき、sf-init のログを、上書きしないため）
readonly SCRIPT_NAME="verify"
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true  # run 不使用: common.sh の読み込み前（run が未定義）
readonly LOG_FILE="$HOME/sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"
export SF_INIT_MODE=1   # sf-init.sh の一部として動く（force-* のチェックは、下で行う）

source "${SF_TOOLS_DIR}/lib/common.sh"
source "${SF_TOOLS_DIR}/lib/wizard.sh"
source "${SF_TOOLS_DIR}/lib/org.sh"
source "${SF_TOOLS_DIR}/lib/diag.sh"
source "${SF_TOOLS_DIR}/lib/verify-common.sh"

PLAN_ONLY=0
CLEANUP_ONLY=0
NO_METASYNC=0
COMPONENTS=0
VALIDATE_ONLY=0
WITH_OBJECTS=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --plan)    PLAN_ONLY=1 ;;
        --cleanup) CLEANUP_ONLY=1 ;;
        --no-metasync) NO_METASYNC=1 ;;
        --components) COMPONENTS=1 ;;
        --validate-only) VALIDATE_ONLY=1 ;;
        --with-objects) WITH_OBJECTS=1 ;;
        *) die "不明なオプションです: $1" ;;
    esac
    shift
done
[[ $VALIDATE_ONLY -eq 1 && $COMPONENTS -eq 0 ]] && die "--validate-only は、--components と一緒に指定してください。"
[[ $VALIDATE_ONLY -eq 1 && $CLEANUP_ONLY -eq 1 ]] && die "--validate-only と --cleanup は、一緒に指定できません（検証だけのときは、組織に、何も残りません）。"
[[ $WITH_OBJECTS -eq 1 && $COMPONENTS -eq 0 ]] && die "--with-objects は、--components と一緒に指定してください。"
[[ $COMPONENTS -eq 1 ]] && VERIFY_SET="components"
# オブジェクト系（トリガー・Layout・オブジェクト・項目）を、サンプルに含めるか: 検証のみは、常に含める（何も作らない）。
# リリースと削除の通しは、--with-objects のときだけ（削除したオブジェクトの名前が、15 日間、予約されるため）
VERIFY_SAMPLE_OBJECTS=0
[[ $COMPONENTS -eq 1 && ( $VALIDATE_ONLY -eq 1 || $WITH_OBJECTS -eq 1 ) ]] && VERIFY_SAMPLE_OBJECTS=1
# Flow は、API で削除できない場合がある（権限）ため、通しには含めない。検証のみ（何も作らない）と --cleanup（リポジトリの
# ファイルの削除。組織の Flow は、画面で、手動で削除する）では、含める
VERIFY_SAMPLE_FLOW=0
[[ $COMPONENTS -eq 1 && ( $VALIDATE_ONLY -eq 1 || $CLEANUP_ONLY -eq 1 ) ]] && VERIFY_SAMPLE_FLOW=1
# 削除の PR の本数（--components: 段階 1 のみ / オブジェクト系を含めるときは、段階 2 も）
_DEL_PRS=1
[[ $VERIFY_SAMPLE_OBJECTS -eq 1 ]] && _DEL_PRS=2
# 後始末（--cleanup）の案内に使う、オプションの指定
_CLEANUP_CMD="sf-init.sh --verify --cleanup"
if [[ $COMPONENTS -eq 1 ]]; then
    _CLEANUP_CMD="sf-init.sh --verify --components"
    [[ $VERIFY_SAMPLE_OBJECTS -eq 1 ]] && _CLEANUP_CMD+=" --with-objects"
    _CLEANUP_CMD+=" --cleanup"
fi
# 確認の対象の表示名（実行内容・確認の文面で使う）
_WHAT="Hello World"
[[ $COMPONENTS -eq 1 ]] && _WHAT="サンプル（パターン別のコンポーネント）"

# ------------------------------------------------------------------------------
# 0. 前提の確認
# ------------------------------------------------------------------------------
[[ "${GITHUB_ACTIONS:-}" == "true" ]] && die "GitHub Actions 上では、実行できません。"
check_force_dir || die "このスクリプトは 'force-*' ディレクトリ内で実行してください。"

remote_url=$(git remote get-url origin 2>/dev/null) || die "git remote を取得できません。"  # VAR=$(cmd) のため run 不使用
# GitHub の URL だけを受け付ける（parse_github_remote: lib/project.sh。出力は「owner repo」）。GitHub 以外は die
_owner_repo=$(parse_github_remote "$remote_url") \
    || die "origin が GitHub のリポジトリではありません: $(git_origin_redacted .)"  # VAR=$(cmd) のため run 不使用
OWNER="${_owner_repo%% *}"
REPO="${OWNER}/${_owner_repo#* }"

log "HEADER" "リポジトリの検証（${REPO}）"
check_gh_owner "$OWNER"

# 段階: リモートのブランチから判定する（develop → staging → main の順に、リリースする）
branches=$(verify_gh api "repos/${REPO}/branches" --paginate --jq '.[].name' 2>/dev/null | tr -d '\r') \
    || die "ブランチの一覧を取得できません。"  # VAR=$(cmd) のため run 不使用
grep -qx "main" <<< "$branches" || die "ブランチ main が見つかりません。"  # 条件チェックのため run 不使用
TIERS=()
grep -qx "develop" <<< "$branches" && grep -qx "staging" <<< "$branches" && TIERS+=("develop")  # 条件チェックのため run 不使用
grep -qx "staging" <<< "$branches" && TIERS+=("staging")  # 条件チェックのため run 不使用
TIERS+=("main")

# --components: サンプルは、develop の組織だけに入れる（本番・staging には、入れない）。develop がない構成では、実行しない
if [[ $COMPONENTS -eq 1 ]]; then
    # 条件チェックのため run 不使用（develop がなければ die）
    printf '%s\n' "${TIERS[@]}" | grep -qx "develop" \
        || die "--components は、develop の組織がある構成（develop・staging・main の 3 層）だけで、実行できます（サンプルを、staging・本番の組織には、入れません）。"
    TIERS=("develop")
    # 既存の labels のファイルがあると、サンプルが、それを上書きして、削除してしまう。その場合は、CustomLabels を、サンプルに含めない。
    # ただし、サンプルのラベルだけを含むファイル（前回の検証の残り）は、サンプルのものとして扱う（含めないと、後始末でも消えない）
    if verify_file_sha "$REPO" develop "$VERIFY_SAMPLE_LABELS_PATH" > /dev/null; then  # 条件チェック
        _labels_body=$(verify_gh api "repos/${REPO}/contents/$(_verify_urlpath "$VERIFY_SAMPLE_LABELS_PATH")?ref=develop" --jq '.content | @base64d' 2>/dev/null) || _labels_body=""  # VAR=$(cmd) のため run 不使用
        if printf '%s\n' "$_labels_body" | verify_sample_labels_file_is_ours; then  # 条件チェック
            log "INFO" "  develop の labels のファイルは、サンプルのラベル（前回の検証の残り）だけです。サンプルの一部として扱います。"
        else
            VERIFY_SAMPLE_LABELS=0
            log "WARNING" "  develop に、すでに labels のファイル（${VERIFY_SAMPLE_LABELS_PATH}）があるため、CustomLabels は、サンプルに含めません（上書きを避けるため）。"
        fi
    fi
fi

_suffix_of() { case "$1" in main) echo "PROD" ;; staging) echo "STG" ;; develop) echo "DEV" ;; esac; }
_var() { verify_gh variable get "$1" -R "$REPO" 2>/dev/null | tr -d '\r' || true; }  # 取得専用のため run 不使用

# ------------------------------------------------------------------------------
# 1. 診断（不足があれば、ここで中断する）
# ------------------------------------------------------------------------------
diag_run "$REPO" "${TIERS[@]}"
[[ "$DIAG_NG" -eq 0 ]] || die "セットアップに不足があるため、検証を始められません（上の「直し方」を実行してください）。"

# 同名のクラスのファイルが、すでにリポジトリにないこと。あれば、検証のクラスが、それを上書きして、削除してしまう。
#   --cleanup は、前回の検証の残りの後始末のため、対象外（残りがあるのが、前提）。組織だけにある同名のクラスは、ここでは検出できない
if [[ $CLEANUP_ONLY -eq 0 ]]; then
    for t in "${TIERS[@]}"; do
        while IFS= read -r p; do
            if verify_file_sha "$REPO" "$t" "$p" > /dev/null; then  # 条件チェック
                log "ERROR" "  ${t} ブランチに、検証用と同じ名前のファイルが、すでにあります: ${p}"
                log "WARNING" "  このまま実行すると、そのクラスを、上書きして、削除します。前回の検証の残りであれば、sf-init.sh --verify --cleanup を実行してください。"
                die "検証用と同名のクラスのファイルが、すでにあります（${t}: ${p}）。"
            fi
        done < <(verify_set_paths all)
    done
fi

# ------------------------------------------------------------------------------
# 2. 実行内容の表示
# ------------------------------------------------------------------------------
NEED_PROD_CONFIRM=0
echo "" >&2
echo -e "  ${CLR_WARNING}【これから行うこと】${CLR_RESET}" >&2
echo "    リポジトリ : ${REPO}" >&2
echo "    段階（リリースの順）:" >&2
for t in "${TIERS[@]}"; do
    sfx=$(_suffix_of "$t")                     # VAR=$(cmd) のため run 不使用
    kind=$(_var "SF_ORG_KIND_${sfx}")          # VAR=$(cmd) のため run 不使用
    oname=$(_var "SF_ORG_NAME_${sfx}")         # VAR=$(cmd) のため run 不使用
    user=$(_var "SF_USERNAME_${sfx}")          # VAR=$(cmd) のため run 不使用
    label=$(org_kind_label "${kind:-unknown}") # VAR=$(cmd) のため run 不使用
    case "$kind" in
        developer|sandbox|trial) mark="" ;;
        *) mark="  ← 本番（または、種類を判定できない）組織"; NEED_PROD_CONFIRM=1 ;;
    esac
    if [[ -n "$mark" ]]; then
        echo -e "      ${CLR_ERR}${t} → ${oname:-（名前なし）} / ${label} / ${user:-（ユーザー未設定）}${mark}${CLR_RESET}" >&2
    else
        echo "      ${t} → ${oname:-（名前なし）} / ${label} / ${user:-（ユーザー未設定）}" >&2
    fi
done
n_tiers=${#TIERS[@]}
if [[ $COMPONENTS -eq 1 && $VALIDATE_ONLY -eq 1 ]]; then
    echo "    内容       : サンプル（$(verify_set_paths all | wc -l | tr -d ' ') ファイル）の検証のみ（wf-validate = dry-run）。PR は、マージせずに閉じる" >&2
    echo "                 組織には、何も反映しません（develop のみ）" >&2
elif [[ $COMPONENTS -eq 1 && $CLEANUP_ONLY -eq 1 ]]; then
    echo "    内容       : 削除のみ（サンプルを、develop の組織から消す。${_DEL_PRS} 本の PR）" >&2
elif [[ $COMPONENTS -eq 1 ]]; then
    # 含める種類の表示は、実際の内容に合わせる（表示ラベルは VERIFY_SAMPLE_LABELS=1 のときだけ。リリースと削除の通しでは、
    # Flow は含めない: VERIFY_SAMPLE_FLOW=0）
    _labels_kind=""
    [[ "${VERIFY_SAMPLE_LABELS:-1}" == "1" ]] && _labels_kind="・表示ラベル"
    if [[ $VERIFY_SAMPLE_OBJECTS -eq 1 ]]; then
        echo "    内容       : サンプル（$(verify_set_paths all | wc -l | tr -d ' ') ファイル。Apex・トリガー・LWC・Aura・権限セット・Layout・メール テンプレート${_labels_kind}・" >&2
        echo "                 オブジェクト・項目）を、develop の組織にリリースして、削除する（develop のみ。Flow は、含めません: 検証のみ（--validate-only）で検証します）" >&2
        echo "                 PR を 3 本（リリース 1・削除 2: 段階 1 → 段階 2）作成してマージする。組織と、リポジトリのファイルは、最後に消える" >&2
        echo -e "                 ${CLR_WARNING}※ 削除したカスタムオブジェクトの名前は、15 日間、予約されます（再作成には、ごみ箱から消す必要があります）${CLR_RESET}" >&2
    else
        echo "    内容       : サンプル（$(verify_set_paths all | wc -l | tr -d ' ') ファイル。Apex・LWC・Aura・権限セット・メール テンプレート${_labels_kind}）を、" >&2
        echo "                 develop の組織にリリースして、削除する（develop のみ。オブジェクト系・Flow は、含めません: 検証のみ（--validate-only）で検証します）" >&2
        echo "                 PR を 2 本（リリース 1・削除 1）作成してマージする。組織と、リポジトリのファイルは、最後に消える" >&2
    fi
elif [[ $CLEANUP_ONLY -eq 1 ]]; then
    echo "    内容       : 削除のみ（Hello World のクラスを、各段階の組織から消す。${n_tiers} 本の PR）" >&2
else
    echo "    内容       : Hello World（${VERIFY_APEX_HELLO} / ${VERIFY_APEX_HELLO_TEST}）を、各段階にリリースして、削除する" >&2
    echo "                 PR を $((n_tiers * 2)) 本（リリース ${n_tiers}・削除 ${n_tiers}）作成してマージする。組織のクラスと、リポジトリのファイルは、最後に消える" >&2
fi
if [[ $CLEANUP_ONLY -eq 0 ]]; then
    _env_items="SF_TOOLS_BRANCH・ログに Token が残っていないこと"
    [[ $NO_METASYNC -eq 1 ]] || _env_items+="・wf-metasync の実行"
    echo "    最初の確認 : 環境全体（${_env_items}）。NG があれば、リリースへ進みません" >&2
    if [[ $NO_METASYNC -eq 0 ]]; then
        echo "                 ※ wf-metasync は、Salesforce（main の組織）の変更を、main に同期します。変更があれば、main にコミットされます" >&2
    fi
fi
# 目安: PR 1 本（検証 → マージ → リリース）が、約 3 分。wf-metasync が、約 3 分（実測: 3 層・PR 6 本・metasync で、約 20 分）
_est=$((n_tiers * (CLEANUP_ONLY == 1 ? 1 : 2) * 3))
if [[ $COMPONENTS -eq 1 ]]; then
    if [[ $VALIDATE_ONLY -eq 1 ]]; then _est=4; elif [[ $CLEANUP_ONLY -eq 1 ]]; then _est=$((_DEL_PRS * 3)); else _est=$(((1 + _DEL_PRS) * 3 + 1)); fi   # PR 1 本 = 約 3 分（検証のみは、マージ・リリースがない）
fi
[[ $CLEANUP_ONLY -eq 0 && $NO_METASYNC -eq 0 ]] && _est=$((_est + 3))
echo "    目安の時間 : 約 ${_est} 分（Actions の混み具合で、前後します）" >&2
echo "    残るもの   : リポジトリに、PR・コミットの履歴（作業用ブランチは、最後に削除します）。Slack に、通知（段階ごとに数通）" >&2

if [[ $PLAN_ONLY -eq 1 ]]; then
    log "INFO" "--plan のため、ここで終了します（何も変更していません）。"
    exit $RET_OK
fi

# ------------------------------------------------------------------------------
# 3. 確認（管理者向けの警告・Enter の確認。本番を含むときは、文面で明示する）
#    sf-init.sh から呼ばれたとき（SF_VERIFY_CONFIRMED=1）は、sf-init が、確認済みのため、二重には聞かない
# ------------------------------------------------------------------------------
if [[ "${SF_VERIFY_CONFIRMED:-}" != "1" ]]; then
    echo "" >&2
    if [[ $COMPONENTS -eq 1 && $VALIDATE_ONLY -eq 1 ]]; then
        _vw_what="サンプルを、検証します（反映はしません）"
    elif [[ $COMPONENTS -eq 1 ]]; then
        _vw_what="サンプルを、リリースして、削除します"
    else
        _vw_what="Hello World を、リリースして、削除します"
    fi
    print_admin_warning "!!  実際のリポジトリと組織に、リリースします" "    ${_vw_what}" "    管理者以外は、実行しないでください"
    echo "" >&2
    # 確認は、Enter を 1 回押すだけ（q で中断）。入力を、最小にするため。本番を含むときは、文面で、明示する
    if [[ $NEED_PROD_CONFIRM -eq 1 ]]; then
        echo -e "  ${CLR_ERR}本番（または、種類を判定できない）組織に、${_WHAT} を、リリースして、削除します。${CLR_RESET}" >&2
        wizard_confirm "本番の組織を含みます。Enter で、${REPO} の検証を始めます（q で中断）"
    else
        wizard_confirm "Enter で、${REPO} の検証を始めます（q で中断）"
    fi
fi

# ------------------------------------------------------------------------------
# 4・5. リリースと削除
# ------------------------------------------------------------------------------
OK_COUNT=0
NG_COUNT=0
FLAKY=0
LEFT=()   # 組織に、Hello World が残っている可能性のある段階（リリースの PR をマージしてから、削除が成功するまで）
# LEFT に、段階を入れる / 消す（連想配列は Bash 4 以降のため使わない。段階の名前の配列で持つ）
_left_add() {
    local t
    for t in "${LEFT[@]}"; do [[ "$t" == "$1" ]] && return 0; done
    LEFT+=("$1")
}
_left_del() {
    local t
    local -a rest=()
    for t in "${LEFT[@]}"; do [[ "$t" == "$1" ]] || rest+=("$t"); done
    LEFT=("${rest[@]}")
}
STOPPED=0

# 1 件の確認: 説明 コマンド...
_vchk() {
    local desc="$1"; shift
    if "$@"; then
        log "SUCCESS" "  [OK] ${desc}"
        OK_COUNT=$((OK_COUNT + 1))
        return 0
    fi
    log "ERROR" "  [NG] ${desc}"
    NG_COUNT=$((NG_COUNT + 1))
    return 1
}

# Slack への通知が成功したか（ログに、Slack の応答 "ok":true があるか）。引数: 実行 ID
_slack_ok() { verify_gh run view "$1" -R "$REPO" --log 2>/dev/null | grep -F "Slack response" | grep -q '"ok":true'; }  # 戻り値で判定するため run 不使用

# 実行が成功したか。失敗したら、ログを表示し、1 回だけ再実行する（一時的な失敗への対策）。引数: 実行 ID ラベル
_run_ok() {
    local id="$1" label="$2" out line
    [[ "$(verify_run_conclusion "$REPO" "$id")" == "success" ]] && return 0
    log "WARNING" "${label}: 失敗しました。失敗したステップのログ（末尾 30 行）:"
    out=$(verify_gh run view "$id" -R "$REPO" --log-failed 2>/dev/null | _strip_ansi | tail -n 30) || true  # VAR=$(cmd) のため run 不使用
    while IFS= read -r line; do printf '    %s\n' "$(_mask_secrets "$line")" >&2; done <<< "$out"
    log "WARNING" "${label}: 一時的な失敗の可能性があるため、1 回だけ再実行します。"
    verify_rerun_and_wait "$REPO" "$id" || return 1
    if [[ "$(verify_run_conclusion "$REPO" "$id")" == "success" ]]; then
        FLAKY=$((FLAKY + 1))
        log "WARNING" "${label}: 再実行で成功しました（一時的な失敗だった可能性があります）。"
        return 0
    fi
    return 1
}

# ワークフローの、ログインのステップ名（段階ごと）。文言を中立化する前に作られたリポジトリのワークフローは、古い名前
_login_step_names() {
    case "$1" in
        main)    printf '%s\n' "main の組織にログイン（JWT）" "本番組織にログイン（JWT）" ;;
        staging) printf '%s\n' "staging の組織にログイン（JWT）" "ステージング組織にログイン（JWT）" ;;
        develop) printf '%s\n' "develop の組織にログイン（JWT）" "開発組織にログイン（JWT）" ;;
    esac
}
# 段階のログインのステップの結果（success / skipped など）。見つからなければ、空。引数: 実行 ID 段階
#   名前の候補を、順に探す（見つからないものを、何度も待たないよう、各候補を 1 回ずつ読む）。どの候補も見つからなければ、
#   反映の遅れに備えて、最初の候補名（新しい名前）だけを、verify_step_conclusion の既定の回数（VERIFY_CONCLUSION_TRIES。
#   既定 6 回）まで、間隔（_sfv_poll。既定 5 秒）をあけて読み直す
_login_conclusion() {
    local id="$1" t="$2" name c
    while IFS= read -r name; do
        c=$(VERIFY_CONCLUSION_TRIES=1 verify_step_conclusion "$REPO" "$id" "$name")  # VAR=$(cmd) のため run 不使用
        if [[ -n "$c" ]]; then printf '%s' "$c"; return 0; fi
    done < <(_login_step_names "$t")
    name=$(_login_step_names "$t" | head -1)  # VAR=$(cmd) のため run 不使用
    verify_step_conclusion "$REPO" "$id" "$name"
}

# 段階ごとの確認: その段階の組織に、入ったか（別の組織に、入っていないか）。引数: 段階 実行 ID 種類（リリース / 削除）
#   1. その段階の組織への JWT ログインが成功した
#   2. ほかの段階のログインのステップは、実行されていない（skipped）。別の組織に、ログインしていない
#   3. 接続ユーザー（SF_USERNAME_*）が登録されていて、ログに、そのユーザーが出ている
#   4. ログに、Hello World のクラス名が出ている
#   ほかに、Slack への通知の成功（ok:true）を見る（確認できなくても、注意の表示のみ。件数に含めない）。
#   2 のステップが見つからない段階（古いワークフロー）も、注意の表示のみ
_evidence() {
    local t="$1" id="$2" kind="$3" user u c
    user=$(_var "SF_USERNAME_$(_suffix_of "$t")")  # VAR=$(cmd) のため run 不使用
    _vchk "${kind}（${t}）: ${t} の組織への JWT ログインが成功した" test "$(_login_conclusion "$id" "$t")" == "success"
    for u in develop staging main; do
        [[ "$u" == "$t" ]] && continue
        c=$(_login_conclusion "$id" "$u")  # VAR=$(cmd) のため run 不使用
        if [[ -n "$c" ]]; then
            _vchk "${kind}（${t}）: ${u} の組織へのログインは、実行されていない（別の組織に入っていない）" test "$c" == "skipped"
        else
            log "WARNING" "  [注意] ${kind}（${t}）: ${u} のログインのステップを、見つけられませんでした（古いワークフローの可能性）。"
        fi
    done
    _vchk "${kind}（${t}）: ${t} の接続ユーザー（SF_USERNAME_$(_suffix_of "$t")）が、登録されている" test -n "$user"
    if [[ -n "$user" ]]; then
        _vchk "${kind}（${t}）: ログインしたユーザーが、${t} の接続ユーザー（${user}）と一致する" verify_run_log_has "$REPO" "$id" "$user"
    fi
    _vchk "${kind}（${t}）: ログに、${VERIFY_APEX_HELLO} が出ている" verify_run_log_has "$REPO" "$id" "$VERIFY_APEX_HELLO"
    if ! _slack_ok "$id"; then
        log "WARNING" "  [注意] ${kind}（${t}）: Slack への通知の成功（ok:true）を、確認できませんでした（検証の成否には、含めません）。"
    fi
}

# 失敗したときの案内
_guidance() {
    echo "" >&2
    log "ERROR" "検証を、途中で止めました。"
    if (( ${#LEFT[@]} > 0 )); then
        log "WARNING" "  ${_WHAT} が、次の段階の組織に、残っている可能性があります: ${LEFT[*]}"
        log "WARNING" "  削除のみを、やり直すには、次を実行してください: ${_CLEANUP_CMD}"
    fi
    log "WARNING" "  PR が残っているときは、GitHub の画面で、確認してください（https://github.com/${REPO}/pulls）。"
}

# PR → wf-validate → マージ → wf-release →（main のときだけ）wf-propagate。
#   種類が validate のときは、PR → wf-validate → PR を閉じる（マージしない。FLOW_RUN は、変えない）。
#   wf-release の完了を確認した時点で、その実行 ID を FLOW_RUN に入れる（成否の確認の前）。
#   戻り値: 0 = 流れが最後まで進んだ（wf-propagate の失敗は、記録だけして 0）/ 1 = 途中で失敗した
#   引数: ラベル ブランチ タイトル 先の段階 種類（release / delete / validate。release のとき、マージした時点で、その段階を LEFT に入れる）
FLOW_RUN=""
_pr_flow() {
    local label="$1" br="$2" title="$3" base="$4" mode="$5" prn runid b_val b_rel b_pro pid
    b_val=$(verify_latest_run_id "$REPO" wf-validate.yml "$br")    # VAR=$(cmd) のため run 不使用
    b_rel=$(verify_latest_run_id "$REPO" wf-release.yml "$br")     # VAR=$(cmd) のため run 不使用
    b_pro=$(verify_latest_run_id "$REPO" wf-propagate.yml "$br")   # VAR=$(cmd) のため run 不使用
    prn=$(verify_pr_create "$REPO" "$br" "$title" "sf-init.sh --verify による検証（${_WHAT}）。" "$base") || prn=""  # VAR=$(cmd) のため run 不使用
    _vchk "${label}: PR を作成した（${base} 向け）" test -n "$prn" || return 1
    runid=$(verify_wait_pr_run "$REPO" wf-validate.yml "$br" "$b_val") || runid=""   # VAR=$(cmd) のため run 不使用
    _vchk "${label}: wf-validate（検証）が実行され、完了した" test -n "$runid" || return 1
    _vchk "${label}: wf-validate が成功した" _run_ok "$runid" "${label}: wf-validate" || return 1
    if [[ "$mode" == "validate" ]]; then
        # 検証のみ: ログに、サンプルが出ていること（警告のみ）→ PR は、マージせずに閉じる（組織には、何も反映しない）
        verify_run_log_has "$REPO" "$runid" "$VERIFY_APEX_HELLO" \
            || log "WARNING" "  [注意] ${label}: wf-validate のログに、${VERIFY_APEX_HELLO} が出ていません（検証の成否には、含めません）。"
        _vchk "${label}: PR を、マージせずに閉じた" verify_pr_close "$REPO" "$prn" || return 1
        return 0
    fi
    _vchk "${label}: PR をマージした" verify_pr_merge "$REPO" "$prn" || return 1
    [[ "$mode" == "release" ]] && _left_add "$base"   # マージした時点から、組織に、クラスが入った可能性がある
    runid=$(verify_wait_pr_run "$REPO" wf-release.yml "$br" "$b_rel") || runid=""    # VAR=$(cmd) のため run 不使用
    _vchk "${label}: wf-release が実行され、完了した" test -n "$runid" || return 1
    FLOW_RUN="$runid"
    _vchk "${label}: wf-release が成功した" _run_ok "$runid" "${label}: wf-release" || return 1
    if [[ "$base" == "main" ]]; then
        pid=$(verify_wait_pr_run "$REPO" wf-propagate.yml "$br" "$b_pro") || pid=""   # VAR=$(cmd) のため run 不使用
        if _vchk "${label}: wf-propagate が実行され、完了した" test -n "$pid"; then
            _vchk "${label}: wf-propagate が成功した" _run_ok "$pid" "${label}: wf-propagate" || true  # 失敗しても、続きの確認は進める
        fi
    fi
    return 0
}

# リリース用のブランチを作る（main の先頭から。クラスのファイルと、リリース対象・空の削除対象）。引数: ブランチ
_make_release_branch() {
    local br="$1" sha p
    sha=$(verify_branch_sha "$REPO" main)  # VAR=$(cmd) のため run 不使用
    [[ -n "$sha" ]] || return 1
    verify_branch_create "$REPO" "$br" "$sha" || return 1
    while IFS= read -r p; do
        verify_set_content_for "$p" | verify_file_put "$REPO" "$br" "$p" "verify: ${_WHAT} を追加" || return 1
    done < <(verify_set_paths all)
    verify_set_deploy_target_text | verify_file_put "$REPO" "$br" "sf-tools/release/${br}/deploy-target.txt" "verify: リリース対象" || return 1
    verify_empty_target_text        | verify_file_put "$REPO" "$br" "sf-tools/release/${br}/remove-target.txt" "verify: 削除対象（なし）" || return 1
}
# 削除用のブランチを作る（クラスのファイルの削除と、削除対象）。
#   引数: ブランチ [段階: stage1 | stage2（--components のみ。hello では、無視）] [元のブランチ（既定 main。--components は develop）]
#   --components の削除は、リリースした先（develop）の先頭から作る（main には、サンプルのファイルがないため）
_make_delete_branch() {
    local br="$1" stage="${2:-stage1}" basebr="${3:-main}" sha p
    sha=$(verify_branch_sha "$REPO" "$basebr")  # VAR=$(cmd) のため run 不使用
    [[ -n "$sha" ]] || return 1
    verify_branch_create "$REPO" "$br" "$sha" || return 1
    while IFS= read -r p; do
        verify_file_delete "$REPO" "$br" "$p" "verify: ${_WHAT} を削除" || return 1
    done < <(verify_set_paths "$stage")
    verify_empty_target_text         | verify_file_put "$REPO" "$br" "sf-tools/release/${br}/deploy-target.txt" "verify: リリース対象（なし）" || return 1
    # --cleanup: どこまで消えているか分からないため、存在しない削除対象を、エラーにしない（# @ignore-missing。sf-release.sh が解釈する）
    { [[ $CLEANUP_ONLY -eq 1 ]] && echo '# @ignore-missing'; verify_set_remove_target_text "$stage"; } \
        | verify_file_put "$REPO" "$br" "sf-tools/release/${br}/remove-target.txt" "verify: 削除対象" || return 1
}

# 環境全体の確認（リリースの前に行う。NG があれば、リリースへ進まない: 組織に、何も変更していない状態で止まる）
# ローカルのログに、Token・認証 URL が、残っていないこと（sf-init・verify などのログ）
_logs_clean() {
    local f found=0
    for f in "$HOME"/sf-tools/logs/*.log; do
        [[ -f "$f" ]] || continue
        if grep -qE 'ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[bp]-[0-9A-Za-z-]{20,}|force://[^[:space:]]*:[^[:space:]]*:[^@[:space:]]{20,}@' "$f" 2>/dev/null; then  # 条件チェックのため run 不使用
            log "ERROR" "    Token（または認証 URL）らしい文字列が、ログに残っています: ${f}"
            found=1
        fi
    done
    [[ $found -eq 0 ]]
}
_tools_branch_ok() {
    local v
    v=$(_var SF_TOOLS_BRANCH)  # VAR=$(cmd) のため run 不使用
    log "INFO" "    SF_TOOLS_BRANCH = ${v:-（未設定）}"
    [[ "$v" == "main" || "$v" == "development" ]]
}
# wf-metasync を、手動で 1 回実行して、成功を確認する（JWT ログイン・sf-tools の取得を含む）
_metasync_check() {
    local id
    id=$(verify_dispatch_workflow "$REPO" wf-metasync.yml main) || id=""  # VAR=$(cmd) のため run 不使用
    _vchk "環境（wf-metasync）: 起動した" test -n "$id" || return 1
    _vchk "環境（wf-metasync）: 完了した" verify_wait_run "$REPO" "$id" || return 1
    _vchk "環境（wf-metasync）: 成功した（Salesforce → Git の同期）" _run_ok "$id" "wf-metasync" || return 1
    _vchk "環境（wf-metasync）: Salesforce 組織への JWT ログインが成功した" \
        test "$(verify_step_conclusion "$REPO" "$id" "Salesforce 組織にログイン")" == "success"
    _vchk "環境（wf-metasync）: sf-tools の取得が成功した（公開リポジトリを、Token なしで clone）" \
        test "$(verify_step_conclusion "$REPO" "$id" "自動化ツール（sf-tools）を取得")" == "success"
}

STAMP=$(date +%H%M%S)  # VAR=$(cmd) のため run 不使用
JOB_RELEASE="verify-hello-${STAMP}"
JOB_DELETE="verify-hello-delete-${STAMP}"
JOB_DELETE2=""   # --components の削除の段階 2（項目・オブジェクト）
MADE_DELETE2=0
if [[ $COMPONENTS -eq 1 ]]; then
    JOB_RELEASE="verify-comp-${STAMP}"
    JOB_DELETE="verify-comp-delete-${STAMP}"
    JOB_DELETE2="verify-comp-delete2-${STAMP}"
fi

if [[ $CLEANUP_ONLY -eq 0 ]]; then
    log "HEADER" "環境の確認"
    # 環境の確認で、NG があれば、そこで止める。組織・リポジトリに、何も変更しない状態で終わる
    #   （wf-metasync は、組織の変更を main にコミットすることがあるため、手前の確認が、すべて OK のときだけ実行する）
    _env_stop_if_ng() {
        [[ $NG_COUNT -eq 0 ]] && return 0
        echo "" >&2
        log "ERROR" "環境の確認で、NG があります。これ以上は、進みません（リリースも、wf-metasync も、行っていません）。"
        log "WARNING" "  上の [NG] を直してから、もう一度、実行してください。"
        exit $RET_NG
    }
    _vchk "環境: SF_TOOLS_BRANCH が、main または development である" _tools_branch_ok || true
    _vchk "環境: ローカルのログに、Token・認証 URL が残っていない" _logs_clean || true
    _env_stop_if_ng
    if [[ $NO_METASYNC -eq 0 ]]; then
        _metasync_check || true
    else
        log "INFO" "  wf-metasync の実行は、省略しました（--no-metasync）。"
    fi
    _env_stop_if_ng
    if [[ $VALIDATE_ONLY -eq 1 ]]; then
        log "HEADER" "検証のみ（${TIERS[*]}。マージしない）"
    else
        log "HEADER" "リリース（${TIERS[*]}）"
    fi
    if _vchk "リリース用のブランチ ${JOB_RELEASE} を作成した（${_WHAT}のファイルとリリース対象）" _make_release_branch "$JOB_RELEASE"; then
        for t in "${TIERS[@]}"; do
            if [[ $VALIDATE_ONLY -eq 1 ]]; then
                _pr_flow "検証（${t}）" "$JOB_RELEASE" "verify: ${_WHAT} を検証（マージしない）" "$t" validate || { STOPPED=1; break; }
            elif _pr_flow "リリース（${t}）" "$JOB_RELEASE" "verify: ${_WHAT} をリリース" "$t" release; then
                _evidence "$t" "$FLOW_RUN" "リリース" || true  # 確認の失敗は、記録して、続きを進める（削除まで行って、組織を、元に戻すため）
            else
                STOPPED=1
                break
            fi
        done
    else
        STOPPED=1
    fi
    if [[ $STOPPED -eq 1 ]]; then
        _guidance
        exit $RET_NG
    fi
fi

if [[ $VALIDATE_ONLY -eq 0 ]]; then
log "HEADER" "削除（${TIERS[*]}）"
# --cleanup のときは、どの段階に残っているか分からないため、すべての段階を、対象にする
[[ $CLEANUP_ONLY -eq 1 ]] && for t in "${TIERS[@]}"; do _left_add "$t"; done
# --components の削除は、develop の先頭から作る（サンプルのファイルは、develop にだけある）
DEL_BASE="main"
[[ $COMPONENTS -eq 1 ]] && DEL_BASE="${TIERS[0]}"
if _vchk "削除用のブランチ ${JOB_DELETE} を作成した（${_WHAT}のファイルの削除と削除対象）" _make_delete_branch "$JOB_DELETE" stage1 "$DEL_BASE"; then
    for t in "${TIERS[@]}"; do
        if _pr_flow "削除（${t}）" "$JOB_DELETE" "verify: ${_WHAT} を削除" "$t" delete; then
            _evidence "$t" "$FLOW_RUN" "削除" || true
            [[ $VERIFY_SAMPLE_OBJECTS -eq 1 ]] || _left_del "$t"   # この段階のクラスは、消えた（オブジェクト系を含めるときは、段階 2 のあと）
        else
            STOPPED=1
            break
        fi
    done
else
    STOPPED=1
fi
if [[ $STOPPED -eq 1 ]]; then
    _guidance
    exit $RET_NG
fi
# --components --with-objects: 段階 2（項目・オブジェクト）。段階 1 で、参照するもの（トリガー・テストクラスなど）を消したあとに、消す
if [[ $COMPONENTS -eq 1 && $VERIFY_SAMPLE_OBJECTS -eq 1 ]]; then
    log "HEADER" "削除（項目・オブジェクト。${TIERS[*]}）"
    MADE_DELETE2=1
    if _vchk "削除用のブランチ ${JOB_DELETE2} を作成した（項目・オブジェクトの削除と削除対象）" _make_delete_branch "$JOB_DELETE2" stage2 "$DEL_BASE"; then
        for t in "${TIERS[@]}"; do
            if _pr_flow "削除・項目とオブジェクト（${t}）" "$JOB_DELETE2" "verify: ${_WHAT}（項目・オブジェクト）を削除" "$t" delete; then
                _vchk "削除・項目とオブジェクト（${t}）: ログに、${VERIFY_SAMPLE_OBJ} が出ている" verify_run_log_has "$REPO" "$FLOW_RUN" "$VERIFY_SAMPLE_OBJ" || true
                _left_del "$t"   # この段階のサンプルは、消えた
            else
                STOPPED=1
                break
            fi
        done
    else
        STOPPED=1
    fi
    if [[ $STOPPED -eq 1 ]]; then
        _guidance
        exit $RET_NG
    fi
fi
fi   # VALIDATE_ONLY

# ------------------------------------------------------------------------------
# 5b. 後始末: 今回作った作業用ブランチを削除する
#   リリースと削除の PR は、すべてマージ済み（--validate-only では、検証の PR は、閉じ済み。ここに来るのは、途中で止まらなかったときだけ。止めたときは、調査のために、
#   ブランチを残す）。PR の履歴は、PR の番号で残る。次の場合は、削除しない（警告のみ。検証の成否には、含めない）:
#     ・名前が、想定の形式（verify-hello-HHMMSS / verify-hello-delete-HHMMSS / verify-comp-HHMMSS /
#       verify-comp-delete-HHMMSS / verify-comp-delete2-HHMMSS）でない
#     ・そのブランチを head とする、開いている PR がある（確認できなかったときも、同じ）
# ------------------------------------------------------------------------------
_delete_job_branches() {
    local b deleted=0
    log "HEADER" "後始末（作業用ブランチの削除）"
    for b in "$JOB_RELEASE" "$JOB_DELETE" "$JOB_DELETE2"; do
        [[ -n "$b" ]] || continue
        # --cleanup は、リリース用のブランチを、作っていない。--validate-only は、削除用のブランチを、作っていない
        [[ $CLEANUP_ONLY -eq 1 && "$b" == "$JOB_RELEASE" ]] && continue
        [[ $VALIDATE_ONLY -eq 1 && "$b" != "$JOB_RELEASE" ]] && continue
        [[ "$b" == "$JOB_DELETE2" && $MADE_DELETE2 -eq 0 ]] && continue
        if ! [[ "$b" =~ ^verify-(hello|comp)(-delete2?)?-[0-9]{6}$ ]]; then
            log "WARNING" "  ${b}: 想定の形式の名前ではないため、削除しません。"
            continue
        fi
        if verify_branch_has_open_pr "$REPO" "$b"; then  # 条件チェック
            log "WARNING" "  ${b}: 開いている PR がある（または、確認できない）ため、削除しません。"
            continue
        fi
        if verify_branch_delete "$REPO" "$b"; then  # 条件チェック
            log "INFO" "  作業用ブランチを削除しました: ${b}"
            deleted=$((deleted + 1))
        else
            log "WARNING" "  ${b}: 削除できませんでした（GitHub の画面か、gh api -X DELETE repos/${REPO}/git/refs/heads/${b} で、削除できます）。"
        fi
    done
    [[ $deleted -eq 0 ]] || log "INFO" "  PR の履歴は、PR の番号で残っています（${REPO} の Pull requests）。"
}
_delete_job_branches

# ------------------------------------------------------------------------------
# 6. 結果
# ------------------------------------------------------------------------------
echo "" >&2
log "HEADER" "結果"
log "INFO" "  確認: ${OK_COUNT} 件成功 / ${NG_COUNT} 件失敗"
(( FLAKY > 0 )) && log "WARNING" "  再実行で成功したワークフローが ${FLAKY} 件あります（一時的な失敗の可能性）。"
if [[ $NG_COUNT -eq 0 ]]; then
    if [[ $VALIDATE_ONLY -eq 1 ]]; then
        log "SUCCESS" "検証: すべて成功しました。サンプル（パターン別のコンポーネント）の検証（dry-run）が、develop の組織に対して通りました（反映はしていません）。"
    elif [[ $COMPONENTS -eq 1 ]]; then
        log "SUCCESS" "検証: すべて成功しました。サンプル（パターン別のコンポーネント）の、リリースと削除が、develop の組織に対して動いています。"
        [[ $VERIFY_SAMPLE_OBJECTS -eq 1 ]] || log "INFO" "  オブジェクト系（トリガー・Layout・オブジェクト・項目）と Flow は、通しには含めていません（--validate-only で検証できます）。"
    else
        log "SUCCESS" "検証: すべて成功しました。${REPO} は、段階ごとの組織に対して、リリースと削除が動いています。"
    fi
    exit $RET_OK
fi
log "ERROR" "検証: 失敗した確認があります（上の [NG] を確認してください）。"
exit $RET_NG
