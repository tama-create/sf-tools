#!/bin/bash
# ==============================================================================
# reconnect.sh - 1 つの段階の接続先（Salesforce 組織）を、付け替える（sf-init.sh --reconnect <段階>）
# ==============================================================================
# 「お試しで Sandbox に入れた → 本番に入れる」「組織を作り直した」ときなどに、1 つの段階（main / staging / develop）の
# 接続先だけを、同じ画面の流れで、やり直す。外部クライアントアプリの自動作成まで含む。
# 段階（ブランチ）は、増やさない（増やすときは --add-tier）。鍵・ユーザー名の部分的な更新は sf-update-secret.sh。
#
# 【使い方】
#   force-* ディレクトリの中で sf-init.sh --reconnect <main|staging|develop> を実行する。sf-init.sh が、
#   環境変数 RECONNECT_TIER を export して、このスクリプトを呼び出す。
#
# 【処理の流れ】（doc/wizard-ux-design.md 4.7.7）
#   1. RECONNECT_TIER が空なら die。カレントのフォルダ名が force- で始まらなければ die。origin の URL から
#      リポジトリ名を求める（parse_github_remote。origin がない・GitHub の URL でなければ die）。
#      段階は main（prod も main として扱う）/ staging / develop 以外なら die。
#      staging / develop は、sf-tools/config/branches.txt にその行がなければ die
#   2. いまの接続（Variables のログイン先・種類・ユーザー・組織名・組織 ID）を表示する。
#      管理者向けの警告（print_admin_warning）→ check_gh_owner → ask_yn「付け替えますか」（N / q は die）
#   3. ~/.sf-jwt/<REPO_NAME>/server.key・server.crt のどちらかがなければ die
#   4. 既定: register_jwt_secret_eca（init-common.sh）で、ログイン先の選択 → ブラウザでログイン → 組織の種類の読み取り →
#      本番は main のみのガード（F8）→ 外部クライアントアプリの deploy → コンシューマー鍵の retrieve → JWT 接続テスト →
#      Secrets / Variables の更新。
#      SF_INIT_LEGACY_CONNECTED_APP=1: register_jwt_secret（init-common.sh。コンシューマー鍵・ユーザー名を手動で入力 →
#      JWT 接続テスト → 本番は main のみのガード → 更新）。関数が 0 以外を返したときも die
#   5. 以前の組織 ID（SF_ORG_ID_<接尾辞>）と、新しい組織 ID が両方あって違うときは、以前の組織に、以前の接続に使った
#      アプリが残っていることと、削除の場所を表示する（自動では削除しない）。以前の接続の方式は分からない（GitHub に
#      保存していない）ため、いまの方式（SF_INIT_LEGACY_CONNECTED_APP）にかかわらず、両方を表示する:
#      sf-init が作った外部クライアントアプリ SF_TOOLS_<REPO_NAME の英数字以外を _ にした名前>（外部クライアントアプリ
#      マネージャ）/ --legacy-connected-app で手動で作った接続アプリケーション（アプリケーションマネージャ）。
#      以前の組織 ID が保存されていなかったときは、確認を促す INFO を表示する。同じ組織のとき・新しい組織 ID を
#      読み取れなかったときは、何も表示しない
#
# 【前提条件】
#   - ~/.sf-jwt/<REPO_NAME>/server.key・server.crt（sf-init.sh を実行した管理者の PC にある、JWT 用の鍵と証明書。
#     SF_INIT_LEGACY_CONNECTED_APP=1 のときも、両方が必要）
#   - gh の認証ユーザーが、リポジトリのオーナー（組織では、その組織の有効な管理者）であること（check_gh_owner）
#
# 【補足】
#   - 環境変数:
#       RECONNECT_TIER                   : 段階（main | prod | staging | develop。sf-init.sh が export する）
#       SF_INIT_LEGACY_CONNECTED_APP=1   : 従来の接続アプリケーション（手動の入力）を使う
#       SF_INIT_LOGIN_URL_<PROD|STG|DEV> : ログイン先を、質問せずに指定する（login | test | URL）
#       SF_INIT_JWT_RETRIES              : 既定の方式の JWT 接続テストの最大の試行回数（既定 20）
#       SF_INIT_JWT_INTERVAL             : 試行の間の待ち時間（秒。既定 30）。待つのは試行の間だけで、既定では、最大
#                                          (20 - 1) × 30 = 570 秒（約 10 分）待つ（作成したアプリの反映待ち）
#   - 手順 4 の途中で die したときに残るもの（自動では、元に戻さない）:
#       ・既定の方式では、外部クライアントアプリを、JWT 接続テストの前に、新しい組織へ deploy する。deploy のあとで die すると
#         （コンシューマー鍵の取得の失敗・JWT 接続テストの失敗で N / q・登録の失敗）、新しい組織にアプリが残る
#       ・JWT 接続テストに失敗しても、ask_yn でスキップ（Y）を選ぶと、Secrets / Variables を登録する
#       ・登録は SF_CONSUMER_KEY_<接尾辞> → SF_USERNAME_<接尾辞> → SF_INSTANCE_URL_<接尾辞> の順に 1 つずつ行い、
#         失敗したところで die する。途中で止まると、Secrets / Variables に、新しい組織の値と、以前の組織の値が
#         混在する（SF_ORG_* も、以前の組織の値のまま）。もう一度 --reconnect を実行して、そろえること
#   - ログは ~/sf-tools/logs/sf-init.log に、実行ごとに新しく書く（LOG_MODE=NEW。前回の内容は消える）
#   - 終了コード: 0 = OK / 1 = die
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

RECONNECT_TIER="${RECONNECT_TIER:-}"
[[ -n "$RECONNECT_TIER" ]] || die "RECONNECT_TIER が未設定です。"

log "HEADER" "接続先の付け替え: ${RECONNECT_TIER}"

check_force_dir || die "force-* ディレクトリ内で実行してください。"

# ------------------------------------------------------------------------------
# 1. リポジトリ・段階の確認
# ------------------------------------------------------------------------------
remote_url=$(git remote get-url origin 2>/dev/null) || die "git remote を取得できません。"  # VAR=$(cmd) のため run 不使用
# GitHub の URL だけを受け付ける（parse_github_remote: lib/project.sh。出力は「owner repo」）。GitHub 以外は die
_owner_repo=$(parse_github_remote "$remote_url") \
    || die "origin が GitHub のリポジトリではありません: $(git_origin_redacted .)"  # VAR=$(cmd) のため run 不使用
REPO_NAME="${_owner_repo#* }"
REPO_FULL_NAME="${_owner_repo%% *}/${REPO_NAME}"

BRANCHES_FILE="${PWD}/sf-tools/config/branches.txt"
case "$RECONNECT_TIER" in
    main|prod)  TIER="main";    SUFFIX="PROD"; LABEL="メイン組織";       ORG_ALIAS="prod" ;;
    staging)    TIER="staging"; SUFFIX="STG";  LABEL="ステージング組織"; ORG_ALIAS="staging" ;;
    develop)    TIER="develop"; SUFFIX="DEV";  LABEL="開発組織";         ORG_ALIAS="develop" ;;
    *)          die "--reconnect には、main・staging・develop のいずれかを指定してください。" ;;
esac
if [[ "$TIER" != "main" ]] && ! grep -qx "$TIER" "$BRANCHES_FILE" 2>/dev/null; then  # 条件チェックのため run 不使用
    die "${TIER} は、branches.txt にありません（段階を増やすときは --add-tier ${TIER}）。"
fi

# ------------------------------------------------------------------------------
# 2. いまの接続を表示し、確認する
# ------------------------------------------------------------------------------
_var() { gh variable get "$1" -R "$REPO_FULL_NAME" 2>/dev/null | tr -d '\r' || true; }  # 取得専用のため run 不使用
old_url=$(_var "SF_INSTANCE_URL_${SUFFIX}")   # VAR=$(cmd) のため run 不使用
old_user=$(_var "SF_USERNAME_${SUFFIX}")      # VAR=$(cmd) のため run 不使用
old_kind=$(_var "SF_ORG_KIND_${SUFFIX}")      # VAR=$(cmd) のため run 不使用
old_id=$(_var "SF_ORG_ID_${SUFFIX}")          # VAR=$(cmd) のため run 不使用
old_name=$(_var "SF_ORG_NAME_${SUFFIX}")      # VAR=$(cmd) のため run 不使用

echo "" >&2
echo "  リポジトリ : ${REPO_FULL_NAME}" >&2
echo "  段階       : ${TIER}" >&2
echo "  いまの接続 :" >&2
if [[ -n "$old_url" || -n "$old_user" ]]; then
    echo "      ログイン先 : ${old_url:-（未設定）}" >&2
    echo "      種類       : $(org_kind_label "${old_kind:-unknown}")" >&2
    echo "      ユーザー   : ${old_user:-（未設定）}" >&2
    echo "      組織       : ${old_name:-（未確認）}${old_id:+（ID ${old_id}）}" >&2
else
    echo "      （未接続）" >&2
fi
echo "" >&2
# 管理者向けの警告と確認（CLAUDE.md 2.4）。GITHUB_ACTIONS=true のときは、省略しない（Actions 上で実行する想定がない）
print_admin_warning "!!  このコマンドは管理者専用です" "    接続先（Secrets / Variables）が書き換わります" "    管理者以外は、実行しないでください"
log "WARNING" "この段階（${TIER}）の接続先を、付け替えます。Secrets / Variables が、まとめて更新されます。"
check_gh_owner "${REPO_FULL_NAME%%/*}"
ask_yn "  付け替えますか？" || die "中断しました。"

# ------------------------------------------------------------------------------
# 3〜4. ログイン → 種類の読み取り → 本番は main のみ → アプリの作成 → 登録
# ------------------------------------------------------------------------------
JWT_DIR="$HOME/.sf-jwt/${REPO_NAME}"
[[ -f "${JWT_DIR}/server.key" ]] || die "秘密鍵が見つかりません: ${JWT_DIR}/server.key"
[[ -f "${JWT_DIR}/server.crt" ]] || die "証明書が見つかりません: ${JWT_DIR}/server.crt"

#   失敗は、関数の中で die する。0 以外が返ったときも、中断する（付け替えが完了したと表示しない）
if [[ "${SF_INIT_LEGACY_CONNECTED_APP:-}" == "1" ]]; then
    register_jwt_secret "$ORG_ALIAS" "$SUFFIX" "$LABEL" "${JWT_DIR}/server.key"
else
    register_jwt_secret_eca "$ORG_ALIAS" "$SUFFIX" "$LABEL" "${JWT_DIR}/server.key" "${JWT_DIR}/server.crt"
fi || die "${LABEL}（${SUFFIX}）の接続先の付け替えに失敗しました。"

# ------------------------------------------------------------------------------
# 5. 古い組織に残るもの
# ------------------------------------------------------------------------------
echo "" >&2
#   古い組織に残るアプリの種類は、以前の接続の方式で決まり、いまの方式（SF_INIT_LEGACY_CONNECTED_APP）からは分からない
#   （GitHub には、方式を保存していない）。そのため、どちらの方式でも、両方の可能性と、それぞれの削除の場所を表示する
if [[ -n "$old_id" && -n "${ORG_ID:-}" && "$old_id" != "$ORG_ID" ]]; then
    eca_name="SF_TOOLS_${REPO_NAME//[^A-Za-z0-9]/_}"
    log "WARNING" "古い組織（${old_name:-名前なし} / ID ${old_id}）には、以前の接続に使ったアプリが、残っています（自動では、削除しません）。"
    log "INFO"    "  不要であれば、その組織で、削除してください:"
    log "INFO"    "  ・sf-init が自動で作った外部クライアントアプリ「${eca_name}」: 「設定」→「外部クライアントアプリ マネージャ」"
    log "INFO"    "  ・--legacy-connected-app で、手動で作った接続アプリケーション: 「設定」→「アプリケーションマネージャ」"
elif [[ -z "$old_id" ]]; then
    log "INFO" "以前の接続先の組織 ID は、保存されていませんでした。古い組織に、以前の接続に使ったアプリ（外部クライアントアプリ、または、接続アプリケーション）が残っていないか、必要なら、確認してください。"
fi
log "SUCCESS" "付け替えが完了しました: ${TIER}"
log "INFO"    "いまの接続を見る: sf-init.sh --status"
exit $RET_OK
