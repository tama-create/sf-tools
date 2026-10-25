#!/bin/bash
# ==============================================================================
# sf-job.sh - 作業用ブランチの作成とローカル環境セットアップ
# ==============================================================================
# 作業フォルダ（ジョブフォルダを置く場所）をカレントにして実行する。ジョブ名（例: JOB-20260323）を入力すると、
# GitHub のリポジトリ force-XXXX に、main から作業用ブランチを作成し、./{ジョブ名}/force-XXXX にクローンして、
# そのフォルダで sf-start.sh を実行する。
#
# 【使い方】
#   cd {作業フォルダ}
#   ~/sf-tools/bin/sf-job.sh [--project XXXX] [--owner OWNER]
#
# 【オプション】
#   --project XXXX : プロジェクト名（リポジトリ force-XXXX の XXXX）。先頭の「force-」（大文字小文字を問わない）は除いて扱う。
#                    使える文字は英数字・- ・_ ・.（区切りは英数字の間に 1 つずつ。50 文字まで。末尾 .git は不可）。不正なら中断する
#   --owner OWNER  : GitHub のオーナー（組織名またはユーザー名）。英数字とハイフンのみ（先頭・末尾は英数字。39 文字まで）。
#                    不正なら中断する
#   -h, --help     : この説明を表示して終了する（第 1 引数のときのみ）
#   上記以外の引数を渡すと、「不明なオプション」で中断する（-v / --verbose も受け付けない）。
#
# 【処理の流れ】
#   1. プロジェクト（オーナーと XXXX）の特定。上にあるものを優先する:
#        a. 引数 --owner / --project
#        b. カレントの直下の */force-*/ にあるクローンの git remote（origin。フォルダ名ではなく、URL から取る）。
#           --owner の指定があれば、そのオーナーのクローンだけを対象にする。
#           --project なし: 1 種類 → 自動で決まる / 複数 → 番号で選ぶ / なし → 対話。
#           --project あり（--owner なし）: 同じ force-XXXX のクローンのオーナーが 1 つ → 自動 / 複数 → 番号で選ぶ / なし → 対話
#        c. 対話（決まっていない項目だけ聞く）。オーナー: gh のログインから、所属する組織と自分のアカウントを候補にする
#           （候補なし → 入力 / 1 つ → 自動 / 複数 → 番号で選ぶ）。XXXX: 入力して、Y/N で確認する
#   2. オーナー権限の確認は、しない（開発者が毎日使うコマンドのため）。リポジトリを読み書きする権限は、GitHub が確認する
#      （リポジトリを読めなければ手順 4 で、ブランチを作れなければ手順 6 で中断する）
#   3. 環境チェック。カレントフォルダの名前が admin、または force-* なら中断する（判定はカレントフォルダの名前のみ）。
#      gh auth status が失敗したら gh auth login を実行し、それも失敗したら中断する
#   4. リポジトリ {OWNER}/force-XXXX の存在を確認する。見つからなければ中断する
#   5. ジョブ名の入力（q で中断）。次のときは、入力し直す:
#        - 英数字で始まり、英数字・- ・_ だけの 1〜50 文字でない
#        - main / staging / develop / admin のいずれか（完全一致）
#        - ./{ジョブ名}/force-XXXX がすでにある
#      GitHub に同名のブランチがあるときは、最後のコミットの作者・日時を表示して確認する
#      （Y: そのブランチを使って続ける / N: 入力し直す / q: 中断）。
#      最後に、ジョブ名・ブランチ・クローン先を表示して確認する（N / q で中断）
#   6. GitHub 上に、main の最新コミットから、ブランチ {ジョブ名} を作成する。main がなければ中断する。
#      5 で既存のブランチを使うと選んだときは、作成しない
#   7. ./{ジョブ名}/ を作成し、git clone -c core.longpaths=true --branch {ジョブ名}
#      https://github.com/{OWNER}/force-XXXX.git ./{ジョブ名}/force-XXXX を実行する
#      （core.longpaths は Windows のパス長の上限対策。クローン先の設定に残る）
#   8. ./{ジョブ名}/force-XXXX に移動し、sf-start.sh を引数なしで実行する（組織への接続・VS Code の起動・
#      sf-launcher.sh の起動）。sf-launcher.sh を終了するまで、sf-job.sh も終わらない
#
# 【前提条件】
#   - 実行場所: 作業フォルダ（場所は任意。admin・force-* の中は不可）。おすすめは ~/sf のような短い名前のフォルダ。
#       {作業フォルダ}/
#       ├── JOB-xxx/              ← ジョブフォルダ（sf-job.sh が作成する。同じ force-XXXX を、同時に複数開くための入れ物）
#       │   └── force-XXXX/       ← クローン先（VS Code で開く単位）
#       └── admin/                ← sf-init.sh が作る管理者用の作業フォルダ
#   - GitHub CLI（gh）。gh の認証ユーザーに、そのリポジトリを読み書きする権限があること（オーナーや管理者である必要は、ない）
#
# 【補足】
#   - Ctrl+C は無効（引数の解析の前から。trap '' INT）。入力時に q で中断する。中断・失敗時の終了コードは 1。
#     シグナルの無視は、子の bash（ここから起動する sf-start.sh・sf-launcher.sh と、ランチャーから実行する bash のコマンド）に
#     継承されるため、それらも Ctrl+C を無視する。ただし、sf・npm など Node のコマンドは、起動時にシグナルの扱いを既定に戻すため、
#     実行中に Ctrl+C を押すと、そのコマンドだけが止まることがある（親の bash のスクリプトは、止まらない）
#   - gh auth status が失敗したときの gh auth login は、run を使わずに実行する（gh の対話画面を、そのまま表示するため）
#   - 途中で中断・失敗しても、それまでに作成したブランチ・フォルダ・クローンは削除しない。
#     ブランチ作成のあとに clone が失敗したときは、同じジョブ名で再実行し、既存のブランチを使う（Y）と、続きから進める
#   - sf-start.sh が 0 以外で終了すると、sf-job.sh も中断する（クローンは残る）
#   - ログ: ~/sf-tools/logs/sf-job.log（実行のたびに作り直す）
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 共通ライブラリの必須設定
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME=$(basename "$0" .sh)
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true  # run 不使用: common.sh（run）の読み込み前の準備（意図的エラー無視）
readonly LOG_FILE="$HOME/sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"

# ------------------------------------------------------------------------------
# 2. 共通ライブラリの読み込み
# ------------------------------------------------------------------------------
export SF_INIT_MODE=1   # force-* チェックをバイパス（export のため、子の sf-start.sh・sf-launcher.sh とその先にも引き継がれる）

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

trap '' INT  # Ctrl+C を無効化（q で中断すること。無視の設定は子プロセスにも継承される）

# 引数の解析
ARG_OWNER=""
ARG_PROJECT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --owner)
            [[ -n "${2:-}" ]] || die "--owner には、GitHub のオーナー（組織名またはユーザー名）を指定してください。"
            ARG_OWNER="$2"; shift 2 ;;
        --project)
            [[ -n "${2:-}" ]] || die "--project には、プロジェクト名（force-XXXX の XXXX の部分）を指定してください。"
            ARG_PROJECT="$2"; shift 2 ;;
        *)
            die "不明なオプションです: $1
使い方: ~/sf-tools/bin/sf-job.sh [--project XXXX] [--owner OWNER]" ;;
    esac
done

# ------------------------------------------------------------------------------
# 3. 変数定義
# ------------------------------------------------------------------------------
COMPANY_NAME=""       # プロジェクト名 XXXX（リポジトリ force-XXXX の XXXX の部分）
REPO_NAME=""          # force-XXXX 形式のリポジトリ名
GITHUB_OWNER=""       # GitHub ユーザー名または組織名（引数・クローンの git remote・対話のいずれかで決まる）
REPO_FULL_NAME=""     # OWNER/REPO 形式
JOB_NAME=""           # ジョブ名（例: JOB-20260323）
JOB_DIR=""            # ジョブフォルダの絶対パス
REPO_DIR=""           # クローン先の絶対パス
BASE_BRANCH=""        # ジョブブランチの分岐元ブランチ
USE_EXISTING_BRANCH=0 # 1 = GitHub 上に、すでにある同名のブランチを使う（前回、ブランチ作成のあとの clone で失敗したジョブの、続き）

# ------------------------------------------------------------------------------
# 4. ヘルパー関数
# ------------------------------------------------------------------------------

# read_or_quit / ask_yn は lib/input.sh（lib/common.sh が読み込む）で定義済み

# ------------------------------------------------------------------------------
# 5. フェーズ定義
# ------------------------------------------------------------------------------

# 【CHECK】実行場所（カレントフォルダ名が admin・force-* でないこと）と gh の認証状態を確認
phase_check_environment() {
    local current_dir
    current_dir=$(basename "$PWD")  # VAR=$(cmd) のため run 不使用

    # 管理者用の作業フォルダ（admin）・force-* フォルダからは実行禁止
    if [[ "$current_dir" == "admin" ]]; then
        die "sf-job.sh は管理者用の作業フォルダ（${current_dir}）からは実行できません。
  作業フォルダ（作業単位のフォルダを置く場所）に移動して実行してください:
    cd ..
    ~/sf-tools/bin/sf-job.sh"
    fi
    if [[ "$current_dir" == force-* ]]; then
        die "sf-job.sh は force-* フォルダからは実行できません。
  作業フォルダ（作業単位のフォルダを置く場所）に移動して実行してください:
    cd ../..
    ~/sf-tools/bin/sf-job.sh"
    fi

    log "INFO" "GitHub CLI の認証状態を確認中..."
    if ! run gh auth status; then
        log "WARNING" "GitHub CLI が未認証です。ログインします..."
        # 対話のため run 不使用（run は出力を一時ファイルに書き出すため、gh の質問・ブラウザの案内が表示されない）
        gh auth login || die "GitHub 認証に失敗しました。"
    fi

    log "SUCCESS" "環境チェック完了。"
    return $RET_OK
}

# 【INFO】プロジェクト情報の確認（決めた OWNER と REPO_NAME で、リポジトリの存在を確認）
phase_load_project_info() {
    log "INFO" "プロジェクト情報を確認中..."

    # GITHUB_OWNER / COMPANY_NAME はメイン処理の resolve_job_identity でセット済み
    REPO_NAME="force-${COMPANY_NAME}"
    REPO_FULL_NAME="${GITHUB_OWNER}/${REPO_NAME}"

    log "INFO" "  GitHub オーナー: ${GITHUB_OWNER}"
    log "INFO" "  リポジトリ名: ${REPO_NAME}"

    # リポジトリの存在確認
    if ! gh repo view "$REPO_FULL_NAME" --json name &>/dev/null; then  # 条件チェックのため run 不使用
        log "WARNING" "プロジェクト名（force-XXXX の XXXX）とオーナーが、正しいか確認してください。指定して実行する場合: ~/sf-tools/bin/sf-job.sh --project XXXX --owner OWNER"
        die "リポジトリが見つかりません: ${REPO_FULL_NAME}"
    fi

    log "SUCCESS" "プロジェクト情報確認完了: ${REPO_FULL_NAME}"
    return $RET_OK
}

# 【JOB】ジョブ名の入力と重複チェック
phase_ask_job_name() {
    log "INFO" "ジョブ名を入力してください。（例: JOB-20260323 / q で中断）"
    echo ""

    while true; do
        read_or_quit JOB_NAME "  ジョブ名："

        if [[ -z "$JOB_NAME" ]]; then
            log "WARNING" "ジョブ名を入力してください。"
            continue
        fi

        # バリデーション: 英数字・ハイフン・アンダースコアのみ・1〜50文字
        if [[ ! "$JOB_NAME" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]{0,49}$ ]]; then
            log "WARNING" "無効なジョブ名です。英数字・ハイフン・アンダースコアのみ使用可能です（例: JOB-20260323）"
            JOB_NAME=""
            continue
        fi

        # 環境ブランチ・管理者用のブランチと同じ名前は使えない（同名のブランチが、すでにあり、それを使って続けてしまわないため）
        case "$JOB_NAME" in
            main|staging|develop|admin)
                log "WARNING" "この名前は、環境ブランチ・管理者用のブランチの名前のため、使えません: ${JOB_NAME}"
                JOB_NAME=""
                continue ;;
        esac

        # --- ローカルフォルダの重複チェック ---
        #   同じジョブ名のフォルダに、同じ名前（force-XXXX）のもの（フォルダ・ファイル。オーナーは問わない）があれば、重複。
        #   別の force-* だけを含むなら、重複ではない（同じジョブ名で、複数のプロジェクトを扱える）
        JOB_DIR="${PWD}/${JOB_NAME}"
        if [[ -e "${JOB_DIR}/${REPO_NAME}" ]]; then
            log "WARNING" "同名のフォルダがすでに存在します: ${JOB_DIR}"
            log "WARNING" "別のジョブ名を入力してください。"
            JOB_NAME=""
            continue
        fi

        # --- GitHub ブランチの重複チェック ---
        log "INFO" "GitHub ブランチの存在を確認中..."
        local branch_exists=0 _last=""
        if gh api "repos/${REPO_FULL_NAME}/branches/${JOB_NAME}" &>/dev/null 2>&1; then  # 条件チェックのため run 不使用
            branch_exists=1
        fi

        if [[ $branch_exists -eq 1 ]]; then
            log "WARNING" "GitHub 上に、すでに同名のブランチがあります: ${JOB_NAME}"
            # 前回、ブランチの作成のあとに、clone が失敗した同じジョブなら、そのブランチを使って、続けられる（このフォルダには、clone がない）。
            #   ほかの人のジョブのブランチなら、別のジョブ名にする。最後のコミットの作者と日時を表示して、判断の材料にする
            _last=$(gh api "repos/${REPO_FULL_NAME}/branches/${JOB_NAME}" --jq ".commit.commit.author.name + \" / \" + .commit.commit.author.date" 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
            [[ -n "$_last" ]] && log "INFO" "  最後のコミット: ${_last}"
            log "INFO" "  自分が作った、clone に失敗したジョブなら、このブランチを使って、続けられます。ほかの人のジョブなら、N で、別のジョブ名にしてください。"
            if ask_yn "このブランチを使って、続けますか？"; then
                USE_EXISTING_BRANCH=1
                break
            fi
            log "WARNING" "別のジョブ名を入力してください。"
            JOB_NAME=""
            continue
        fi

        # OK
        break
    done

    REPO_DIR="${JOB_DIR}/${REPO_NAME}"

    echo ""
    echo "  --------------------------------------------------"
    echo "  ジョブ名   : ${JOB_NAME}"
    if [[ $USE_EXISTING_BRANCH -eq 1 ]]; then
        echo "  ブランチ   : ${JOB_NAME}（${REPO_FULL_NAME} の、すでにあるブランチを使う）"
    else
        echo "  ブランチ   : ${JOB_NAME}（${REPO_FULL_NAME} から作成）"
    fi
    echo "  クローン先 : ${REPO_DIR}"
    echo "  --------------------------------------------------"
    echo ""
    ask_yn "▶ よろしいですか？" || die "中断しました。"

    return $RET_OK
}

# 【BRANCH】GitHub 上にジョブブランチを作成
phase_create_branch() {
    if [[ $USE_EXISTING_BRANCH -eq 1 ]]; then
        log "INFO" "GitHub 上の、すでにあるブランチを使います（作成しません）: ${JOB_NAME}"
        return $RET_OK
    fi
    log "INFO" "分岐元ブランチを確認中..."

    # 作業用ブランチは常に main から作成する
    BASE_BRANCH="main"
    if ! gh api "repos/${REPO_FULL_NAME}/branches/${BASE_BRANCH}" &>/dev/null 2>&1; then  # 条件チェックのため run 不使用
        die "分岐元ブランチ（main）が見つかりません。"
    fi

    log "INFO" "ジョブブランチを作成中: ${JOB_NAME}（分岐元: ${BASE_BRANCH}）"

    # 分岐元ブランチの最新 SHA を取得
    local base_sha
    base_sha=$(gh api "repos/${REPO_FULL_NAME}/branches/${BASE_BRANCH}" --jq '.commit.sha') \
        || die "分岐元ブランチの SHA を取得できません: ${BASE_BRANCH}"  # VAR=$(cmd) のため run 不使用

    # ブランチ作成
    run gh api "repos/${REPO_FULL_NAME}/git/refs" \
        --method POST \
        --field "ref=refs/heads/${JOB_NAME}" \
        --field "sha=${base_sha}" \
        || die "ジョブブランチの作成に失敗しました: ${JOB_NAME}"

    log "SUCCESS" "ジョブブランチを作成しました: ${JOB_NAME}"
    return $RET_OK
}

# 【CLONE】ジョブフォルダを作成してクローン
phase_clone_repository() {
    log "INFO" "ジョブフォルダを作成中: ${JOB_DIR}"
    run mkdir -p "$JOB_DIR" || die "ジョブフォルダを作成できません: ${JOB_DIR}"

    log "INFO" "リポジトリをクローン中（ブランチ: ${JOB_NAME}）..."
    # Windows のパスの長さの上限（260 文字）対策: core.longpaths=true を付ける。
    # 設定はクローン先に残り、以降の git add / commit / push にも効く。Windows 以外では無視される。
    # 組織に長い名前のメタデータ（例: DevOps Center の objectTranslations）があると、付けないと clone のチェックアウトに失敗する
    run git clone -c core.longpaths=true \
        --branch "${JOB_NAME}" \
        "https://github.com/${REPO_FULL_NAME}.git" \
        "$REPO_DIR" \
        || die "クローンに失敗しました。"

    log "SUCCESS" "クローン完了: ${REPO_DIR}"
    return $RET_OK
}

# 【START】sf-start.sh を起動（組織への接続・VS Code 起動・sf-launcher.sh 起動）
phase_sf_start() {
    log "INFO" "sf-start.sh を起動します..."
    cd "$REPO_DIR" || die "ディレクトリに移動できません: ${REPO_DIR}"

    # インタラクティブなため run を使わない（run は出力を一時ファイルに書き出すため、入力のプロンプト・画面が表示されない）
    bash "$SCRIPT_DIR/sf-start.sh" \
        || die "sf-start.sh の実行に失敗しました。"

    return $RET_OK
}

# ------------------------------------------------------------------------------
# 6. メイン実行フロー
# ------------------------------------------------------------------------------
log "HEADER" "作業環境セットアップを開始します (${SCRIPT_NAME}.sh)"

resolve_job_identity "$ARG_OWNER" "$ARG_PROJECT"   # GITHUB_OWNER / COMPANY_NAME をセット（引数 → クローン → 対話）
# オーナー権限の確認（check_gh_owner）は、しない。sf-job.sh は、開発者が毎日使うコマンドで、管理者向けではないため
#   （以前は確認していたため、オーナーでも組織の管理者でもない開発者は、実行できなかった）。
#   リポジトリを読み書きする権限は、GitHub が確認する（読めなければ phase_load_project_info で、ブランチを作れなければ phase_create_branch で中断する）

log "INFO" "中断するには q を入力してください。"

phase_check_environment   || die "環境チェックに失敗しました。"

phase_load_project_info   || die "プロジェクト情報の読み込みに失敗しました。"

phase_ask_job_name        || die "ジョブ名の入力に失敗しました。"

phase_create_branch       || die "ジョブブランチの作成に失敗しました。"

phase_clone_repository    || die "クローンに失敗しました。"

phase_sf_start            || die "sf-start.sh の実行に失敗しました。"

exit $RET_OK
