#!/bin/bash
# ==============================================================================
# run.sh - sf-init の通し検証（e2e）。実際の GitHub / Salesforce で Phase 1〜10 を自動実行する
# ==============================================================================
# テスト用のリポジトリ（force-e2e-日時）と外部クライアントアプリを実際に作り、検証する（既定では、終了後も残し、次回の最初に削除する）。
# 通常のテスト（bash tests/run_tests.sh）には含まれない。実環境を使うため、開発者が手動で実行する。
#
# 【処理の流れ】
#   1. 前掃除      : 前回の失敗で残ったテスト用リソースを削除する（名前の形式とオーナーが一致するものだけ）
#   2. 実行        : sf-init を Phase 1〜10 まで自動で実行する（検証環境 = SF_TOOLS_BRANCH=development。層数は --layout で選ぶ。既定は main のみ）
#                    ・既定は、引数なしの対話（管理者が実際に行う操作）: オーナーの選択 → XXXX の入力 → 確認を、標準入力で流す。
#                      --with-args を付けると、引数 --owner / --project で指定する（対話の画面は通らない）
#                    ・質問への答えは標準入力に流す
#                    ・sf org login web は、認証 URL でのログインに差し替える（tests/e2e/shims/sf）
#                    ・ブラウザは開かない（tests/e2e/shims の start / xdg-open / open）
#   3. 確認        : Secret / Variable / ブランチ / ワークフローの存在、トークンがログに出ていないこと、
#                    GitHub Actions の実行: wf-metasync（手動起動。完了を待つ。Hello World と同時に動かすと、組織へのデプロイと取得が重なって失敗する）、続けて Hello World の Apex を PR 経由で
#                    リリース（wf-validate → マージ → wf-release）し、続けて削除する（sf-tools の本来の機能の通し）。
#                    リリース・削除の作業は、通常の運用と同じく、sf-tools のコマンドで行う: sf-job.sh（ブランチ作成・clone・sf-start.sh）
#                    → ファイルを書く → sf-dryrun.sh（ローカルの検証）→ sf-push.sh（commit・push・pre-push フック）。PR の作成・マージは gh。
#                    リリース後は、sf-next.sh（マージ済みの表示）と、sf-deploy.sh（共有環境への強制リリースの拒否）も確認する
#                    【管理者用フォルダ（admin）の確認】 admin/force-XXXX ができたこと・状態ファイルがプロジェクト名つきであること・
#                    古い形のフォルダ（init / init-*）がないこと・クローンが admin ブランチ（ローカルと GitHub の両方）であること・
#                    完了画面の案内・admin ブランチで sf-sync-wf.sh --check が実行でき、main では断られること。
#                    sf-job.sh は、既定では引数なしで実行し、作業フォルダの下のクローンの git remote から、プロジェクトが決まること
#                    【--add-tier の確認】 1 層のとき（鍵一式に staging の組織があれば）、最後に、管理者用のクローン（admin ブランチ）で
#                    sf-init.sh --add-tier staging を実行し、組織への接続・Secret / Variable・ブランチ・PR ができること、
#                    終わったあとも admin ブランチにいること、main へ直接 push していないことを確認する（約 4 分）
#                    【層数に応じた確認】 リポジトリの構成（main のみ / main + staging / main + staging + develop）を、自動で判定し、
#                    段階の数だけ、リリースを繰り返す（同じブランチから、develop → staging → main の順に、段階ごとの PR を出す）:
#                      ・各段階の PR をマージするたびに、その段階の組織にだけ、クラスができること（まだ先の段階の組織には、入っていないこと）
#                      ・main へのマージのあと、wf-propagate が成功し、staging・develop のブランチに、main の最新が入ること
#                      ・削除は、main への PR で行い、ほかの段階の組織には及ばないこと（残りは、管理者の削除デプロイで掃除する）
#                    2 層・3 層には、**層の数だけ、別々の Salesforce 組織が必要**（2 層 = 2 つ、3 層 = 3 つ）。鍵一式に、
#                    staging・develop の組織が必要（bootstrap.sh --add-orgs で追加する）。1 つの組織では、層数を再現できない
#   4. 終了        : sf のエイリアスを実行前の状態に戻す。テスト用のリポジトリ・外部クライアントアプリなどは、既定では削除せずに残す
#                    （終了後に、GitHub の画面で、Actions の実行・PR・ファイルを見返せるようにするため。次回の前掃除で、自動で削除される）。
#                    --cleanup を付けると、終了時に削除する（途中で止まって残った Hello World の Apex も含む）
#
#   5. 検証の記録  : 最後に、どの環境（OS・Bash・openssl）で、どのコミットを、何件確認したかを、表の 1 行にして表示する
#                    （README の「検証済み動作環境」の根拠。成功したら、doc/dev-reference.md 9.7 の表に追記する）
#
# 【前提】
#   ・新しい環境（Mac など）で動かす前に、bash tests/e2e/doctor.sh で、足りないものを確認できる（読み取りのみ）
#   ・~/.sf-tools-e2e/fixture.env（鍵一式。bootstrap.sh で作成。E2E_FIXTURE 環境変数で場所を変更できる）
#   ・gh のログインユーザーが、fixture.env の E2E_GH_USER であること（テスト用の組織の管理者）
#   ・gh に delete_repo の権限があること: gh auth refresh -h github.com -s delete_repo
#   ・~/sf-tools が development ブランチで、origin/development と一致していること
#     （GitHub Actions は sf-tools の origin/development を使うため）
#
# 【関連】 管理者の実際のリポジトリ・実際の組織での検証は、phases/init/verify.sh（この e2e は、sf-tools の開発者の回帰テスト）
#
# 【オプション】
#   --cleanup     : 終了時に、テスト用のものを削除する（既定は削除しない。次回の前掃除、または cleanup.sh で削除される）
#   --keep        : 何もしない（以前の名残り。既定が「削除しない」になったため）
#   --resume      : 前回残したテスト用リポジトリ（最新の 1 つ）を使い、Hello World の部分（sf-job → sf-dryrun → sf-push → PR → リリース → 削除、
#                   sf-next・sf-deploy の確認）だけを再実行する。前掃除・sf-init・wf-metasync は、行わない（約 15 分。直しの確認を、早く繰り返すため）。
#                   ジョブ名は、毎回、時刻付きの別の名前になる。前回の残りの Hello World の Apex が、組織にあれば、最初に削除する
#   --no-add-tier : --add-tier の確認（1 層のとき、最後に staging を足す。約 4 分）を省略する
#   --with-args   : sf-init.sh / sf-job.sh に、引数 --owner / --project を付けて実行する（既定は、引数なしの対話・自動判定）
#   --layout N    : 新しく作るリポジトリの層数（1 = main のみ（既定）/ 2 = main + staging / 3 = main + staging + develop）。
#                   2・3 には、鍵一式に staging（3 は develop も）の組織が必要。--resume では、リポジトリの構成を、自動で判定する
#   --no-actions  : GitHub Actions の実行確認（wf-metasync・Hello World のリリースと削除）を省略する（約 8〜12 分短くなる）
#   -h, --help    : このヘルプを表示する
# ==============================================================================

readonly SCRIPT_NAME="e2e-run"
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true  # run 不使用: ログフォルダの準備（log が使える前の処理）
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

START_SEC=$SECONDS   # 経過時間の表示用
KEEP=1   # 既定は、終了時に削除しない（あとから見返せるように。次回の前掃除で削除される）
SKIP_ACTIONS=0
RESUME=0
ADD_TIER_CHECK=1 # 1 = 最後に、admin ブランチから --add-tier staging を実行して確認する（1 層で、staging の組織があるとき）
WITH_ARGS=0      # 1 = sf-init / sf-job に、引数 --owner / --project を付ける（既定: 引数なし。対話と、クローンからの自動判定を確認する）
LAYOUT=""        # 新しく作るリポジトリの層数（1 / 2 / 3）。--resume では、リポジトリの構成から判定する
while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep)       KEEP=1 ;;
        --cleanup)    KEEP=0 ;;
        --no-actions) SKIP_ACTIONS=1 ;;
        --resume)     RESUME=1 ;;
        --with-args)  WITH_ARGS=1 ;;
        --no-add-tier) ADD_TIER_CHECK=0 ;;
        --layout)     [[ -n "${2:-}" ]] || die "--layout には、1・2・3 のいずれかを指定してください。"
                      LAYOUT="$2"; shift ;;
        *) die "不明なオプションです: $1" ;;
    esac
    shift
done
if [[ -n "$LAYOUT" ]]; then
    [[ "$LAYOUT" =~ ^[123]$ ]] || die "--layout は、1・2・3 のいずれかです: ${LAYOUT}"
    [[ $RESUME -eq 0 ]] || die "--layout は、新しくリポジトリを作るときだけ指定できます（--resume では、リポジトリの構成を自動で判定します）。"
fi
[[ -n "$LAYOUT" ]] || LAYOUT=1
e2e_load_fixture
e2e_guard_env
check_sf_cli  # sf が終了コードを正しく返すか確認（npm 版が前提。異常なら中断）

# 新しく作るリポジトリの層数に必要な、テスト用組織が、鍵一式にあること
if [[ $RESUME -eq 0 ]]; then
    for _t in $(e2e_layout_tiers "$LAYOUT"); do
        e2e_tier_available "$_t" \
            || die "${LAYOUT} 層の検証には、${_t} の組織が必要ですが、鍵一式にありません（bootstrap.sh --add-orgs で追加してください）。"
    done
fi

# ------------------------------------------------------------------------------
# 管理者向けの警告（実際のリポジトリ・組織を作成・削除する）
# ------------------------------------------------------------------------------
log "HEADER" "sf-init の通し検証（e2e）を開始します (${SCRIPT_NAME}.sh)"
echo -e "${CLR_ERR}╔══════════════════════════════════════════════════════╗${CLR_RESET}" >&2
echo -e "${CLR_ERR}║  !!  実際の GitHub / Salesforce を操作します         ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║                                                      ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║  ・テスト用のリポジトリ・外部クライアントアプリ・    ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║    Hello World の Apex を作成します（Apex は削除）   ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║  ・終了後も、リポジトリなどは残します（見返す用）    ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║    前回の残りは、最初に削除します                    ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║  ・sf の認証が、テスト用組織の認証 URL で置き換わり  ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}╚══════════════════════════════════════════════════════╝${CLR_RESET}" >&2
log "INFO" "  オーナー: ${E2E_OWNER}  /  gh ユーザー: ${E2E_GH_USER}"
ask_yn "続行しますか？" || die "中断しました。"

# 手元の sf-tools が origin/development と違うと、GitHub Actions の確認結果が手元の変更を反映しない
_head=$(git -C "$SF_TOOLS_ROOT" rev-parse HEAD 2>/dev/null)                 # VAR=$(cmd) のため run 不使用
_origin=$(git -C "$SF_TOOLS_ROOT" rev-parse origin/development 2>/dev/null)  # VAR=$(cmd) のため run 不使用
if [[ -n "$_head" && "$_head" != "$_origin" ]]; then
    log "WARNING" "手元の sf-tools が origin/development と一致していません。GitHub Actions は origin/development を使うため、Actions の確認結果は手元の未 push の変更を反映しません。"
fi

# ------------------------------------------------------------------------------
# 一時領域の準備（差し替え用のコマンド・認証 URL のファイル・エイリアスの保存先）
# ------------------------------------------------------------------------------
E2E_TMP=$(mktemp -d "${TMPDIR:-/tmp}/e2e-run.XXXXXX") || die "一時ディレクトリを作成できません。"  # VAR=$(cmd) のため run 不使用
_finish() {
    # 異常終了でも、sf のエイリアスを戻し、認証 URL のファイルを消す
    [[ -f "${E2E_TMP}/aliases.txt.ok" ]] && e2e_alias_restore "${E2E_TMP}/aliases.txt"
    rm -rf "$E2E_TMP"  # run 不使用: 一時フォルダの後始末（trap 内。認証 URL のファイルを残さない）
}
trap _finish EXIT
e2e_alias_snapshot "${E2E_TMP}/aliases.txt" || die "sf のエイリアスの一覧を取得できません（実行前の状態を保存できないため、中断します）。"

SHIM_DIR="${E2E_TMP}/shims"
mkdir -p "$SHIM_DIR"  # run 不使用: 差し替え用コマンドの置き場（一時フォルダ内）
cp "${E2E_SCRIPT_DIR}/shims/sf" "${SHIM_DIR}/sf"  # run 不使用: 差し替え用コマンドの配置（一時フォルダ内）
cp "${E2E_SCRIPT_DIR}/shims/code" "${SHIM_DIR}/code"  # run 不使用: 差し替え用コマンドの配置（一時フォルダ内）
for _n in start xdg-open open; do cp "${E2E_SCRIPT_DIR}/shims/browser" "${SHIM_DIR}/${_n}"; done
chmod +x "${SHIM_DIR}"/* 2>/dev/null || true  # run 不使用: 実行権限の付与（Windows は効果なし・意図的エラー無視）
export E2E_SHIM_DIR="$SHIM_DIR"
export E2E_SFDX_URL_FILE="${E2E_TMP}/sfdx-url.txt"
printf '%s' "$E2E_SFDX_AUTH_URL" > "$E2E_SFDX_URL_FILE"
chmod 600 "$E2E_SFDX_URL_FILE" 2>/dev/null || true  # run 不使用: ファイル権限保護（Windows は効果なし・意図的エラー無視）
# staging・develop の組織（あれば）。sf の差し替えが、--alias の末尾（STG / DEV）で選ぶ
if e2e_tier_available staging; then
    export E2E_SFDX_URL_FILE_STG="${E2E_TMP}/sfdx-url-stg.txt"
    printf '%s' "$E2E_SFDX_AUTH_URL_STG" > "$E2E_SFDX_URL_FILE_STG"
    chmod 600 "$E2E_SFDX_URL_FILE_STG" 2>/dev/null || true  # run 不使用: ファイル権限保護（Windows は効果なし・意図的エラー無視）
fi
if e2e_tier_available develop; then
    export E2E_SFDX_URL_FILE_DEV="${E2E_TMP}/sfdx-url-dev.txt"
    printf '%s' "$E2E_SFDX_AUTH_URL_DEV" > "$E2E_SFDX_URL_FILE_DEV"
    chmod 600 "$E2E_SFDX_URL_FILE_DEV" 2>/dev/null || true  # run 不使用: ファイル権限保護（Windows は効果なし・意図的エラー無視）
fi

# ------------------------------------------------------------------------------
# 経過時間の表示（どこで時間がかかっているか分かるように）と、ジョブ名
# ------------------------------------------------------------------------------
_elapsed() { local s=$(( SECONDS - START_SEC )); log "INFO" "  経過時間: $(( s / 60 )) 分 $(( s % 60 )) 秒（$1）"; }
# ジョブ名（= ブランチ名）は、毎回、時刻付きの別の名前にする（--resume で、同じリポジトリを使っても、ぶつからないように）
RUN_ID=$(date +%H%M%S)  # VAR=$(cmd) のため run 不使用
JOB_RELEASE="e2e-hello-${RUN_ID}"
JOB_DELETE="e2e-hello-delete-${RUN_ID}"

# ------------------------------------------------------------------------------
# 1・2. 前掃除 → sf-init の実行（Phase 1〜10）。--resume のときは、前回残したリポジトリを使う
# ------------------------------------------------------------------------------
# 前回残したテスト用の作業フォルダ（名前が決まった形式のもののうち、最新の 1 つ）の名前を、標準出力に返す。なければ、戻り値 1
#   名前は、日時（e2e-YYYYMMDD-HHMMSS）なので、フォルダ名の並び順が、新しい順になる
_find_resume_project() {
    local d name best=""
    for d in "${E2E_HOME_ROOT}/${E2E_OWNER}"/e2e-*; do
        [[ -d "$d" ]] || continue
        name=$(basename "$d")  # VAR=$(cmd) のため run 不使用
        e2e_is_target_project "$name" && best="$name"
    done
    [[ -n "$best" ]] || return 1
    printf '%s' "$best"
}

_set_project() {   # 引数: プロジェクト名。PROJECT / REPO_NAME / REPO_FULL / WORK を決める
    PROJECT="$1"
    REPO_NAME="force-${PROJECT}"
    REPO_FULL="${E2E_OWNER}/${REPO_NAME}"
    WORK="${E2E_HOME_ROOT}/${E2E_OWNER}/${PROJECT}"
    JOB_ARGS=()   # sf-job.sh に渡す引数。既定は、なし（作業フォルダの下のクローンの git remote から決まる）
    [[ $WITH_ARGS -eq 0 ]] || JOB_ARGS=(--owner "$E2E_OWNER" --project "$PROJECT")
}

_fresh_start() {
    e2e_cleanup_all delete || die "前回のテスト用リソースを削除できませんでした。"
    _set_project "$(e2e_new_project_name)"
    run mkdir -p "$WORK" || die "作業フォルダを作成できません: ${WORK}"

    log "HEADER" "sf-init を実行します（${REPO_FULL}。${LAYOUT} 層）"
    INIT_OUT="${E2E_TMP}/sf-init.out"
    # 既定は、引数なしの対話: 先頭に、オーナーの選択・XXXX・確認の入力を足す。--with-args は、引数で指定する
    local _init_args=() _ident_input=""
    if [[ $WITH_ARGS -eq 1 ]]; then
        _init_args=(--owner "$E2E_OWNER" --project "$PROJECT")
    else
        _ident_input=$(e2e_make_identity_input "$E2E_OWNER" "$PROJECT") \
            || die "対話の入力（オーナーの選択）を作れません: gh のログインの候補に、${E2E_OWNER} がありません。"  # VAR=$(cmd) のため run 不使用
    fi
    { [[ -z "$_ident_input" ]] || printf '%s\n' "$_ident_input"; e2e_make_input "$LAYOUT"; } \
        | ( cd "$WORK" && PATH="${SHIM_DIR}:${PATH}" bash "${SF_TOOLS_ROOT}/bin/sf-init.sh" ${_init_args[@]+"${_init_args[@]}"} 2>&1 ) \
        | tee "$INIT_OUT"
    INIT_RC=${PIPESTATUS[1]}
    _elapsed "sf-init の終了"
}

_resume_start() {
    local p
    log "HEADER" "再開（--resume）: 前回残したテスト用リポジトリを使います"
    p=$(_find_resume_project) || die "再開できる、前回のテスト用の作業フォルダがありません（${E2E_HOME_ROOT}/${E2E_OWNER}/e2e-日時）。"  # VAR=$(cmd) のため run 不使用
    _set_project "$p"
    _e2e_check_repo "$REPO_FULL"
    _e2e_gh repo view "$REPO_FULL" >/dev/null 2>&1 || die "再開できるリポジトリがありません: ${REPO_FULL}"  # 戻り値で判定するため run 不使用
    log "INFO" "  リポジトリ: https://github.com/${REPO_FULL}"
    log "INFO" "  前掃除・sf-init・wf-metasync は、行いません。Hello World の部分だけを、再実行します。"
    INIT_OUT=""
    INIT_RC=0
}

if [[ $RESUME -eq 1 ]]; then
    _resume_start
else
    _fresh_start
fi

# ------------------------------------------------------------------------------
# 3. 確認
# ------------------------------------------------------------------------------
CHECK_PASS=0
CHECK_FAIL=0
# chk 説明 コマンド...  : コマンドが成功すれば PASS、失敗すれば FAIL（失敗しても止まらない）
#   戻り値: PASS なら 0、FAIL なら 1（続きの手順を進められるかの判断に使える。失敗しても、run.sh 自体は止まらない）
chk() {
    local desc="$1"; shift
    if "$@"; then
        log "SUCCESS" "  [PASS] ${desc}"
        CHECK_PASS=$((CHECK_PASS + 1))
        return 0
    fi
    log "ERROR" "  [FAIL] ${desc}"
    CHECK_FAIL=$((CHECK_FAIL + 1))
    return 1
}

_has_secret()   { _e2e_gh secret list -R "$REPO_FULL" 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }
_has_variable() { _e2e_gh variable list -R "$REPO_FULL" 2>/dev/null | awk '{print $1}' | grep -qx "$1"; }
_var_equals()   { [[ "$(_e2e_gh variable get "$1" -R "$REPO_FULL" 2>/dev/null)" == "$2" ]]; }
_has_branch()   { _e2e_gh api "repos/${REPO_FULL}/branches" --jq '.[].name' 2>/dev/null | grep -qx "$1"; }
_has_workflow() { _e2e_gh api "repos/${REPO_FULL}/contents/.github/workflows" --jq '.[].name' 2>/dev/null | grep -qx "$1"; }
# ファイルに値が含まれていないこと（トークンの漏れの確認）
_not_in_file()  { [[ ! -f "$2" ]] || ! grep -qF -- "$1" "$2"; }

# Actions: ワークフローを手動で起動し、起動した実行の ID を標準出力に返す（完了は待たない）
#   起動の前の、最新の実行 ID を覚え、それより新しい実行だけを、起動した実行とみなす（古い実行を、取り違えないため）。
#   起動の呼び出しが、すべて失敗したら、戻り値 1
_dispatch_workflow() { verify_dispatch_workflow "$REPO_FULL" "$1" main; }

# Actions: 実行 ID の実行が、完了するまで待つ（E2E_WF_TIMEOUT 秒（既定 1200）以内。E2E_POLL_SEC 秒（既定 5）おきに確認）
_wait_run() { verify_wait_run "$REPO_FULL" "$1"; }
_run_conclusion() { e2e_run_conclusion "$REPO_FULL" "$1"; }   # 空のときは、やり直す（lib.sh）
_step_conclusion() { e2e_step_conclusion "$REPO_FULL" "$1" "$2"; }

# ------------------------------------------------------------------------------
# Hello World の Apex を、PR 経由でリリースし、続けて削除する（sf-tools の本来の機能の通しの確認）
#   wf-validate（検証）→ PR のマージ → wf-release（リリース / 削除）。テスト用の組織（本番相当）に対して行う。
#   失敗した手順があれば、そこで止める（残ったクラスは、後掃除で削除される）
# ------------------------------------------------------------------------------
_admin_login_ok() { ( e2e_sf_admin_login ); }
# wf-release の Slack 通知が成功したか（ログに、Slack の応答 ok:true がある）
_slack_ok() { _e2e_gh run view "$1" -R "$REPO_FULL" --log 2>/dev/null | grep -F "Slack response" | grep -q '"ok":true'; }

# Hello World の作業は、開発者の作業を、sf-tools のコマンドで再現する（通常の運用と同じ道）
#   sf-job.sh（ブランチ作成・clone・sf-start.sh）→ ファイルを書く → sf-dryrun.sh（ローカルの検証）→ sf-push.sh（commit・push・pre-push フック）
#   ファイルの書き込みだけが、開発者の手作業にあたる部分。そのあと、gh で PR を作る（通常の運用では GitHub の画面）
_hello_write_release() {   # 引数: クローンのフォルダ ブランチ名（リリース: クラスと deploy-target.txt。remove-target.txt は雛形のまま）
    local repo="$1" job="$2" p
    mkdir -p "${repo}/force-app/main/default/classes" || return 1  # run 不使用: テスト用の作業フォルダへの書き込み
    while IFS= read -r p; do
        verify_hello_content_for "$p" > "${repo}/${p}" || return 1  # run 不使用: 同上（本文は、lib/verify-common.sh と共有）
    done < <(verify_hello_paths)
    e2e_hello_deploy_target_text > "${repo}/sf-tools/release/${job}/deploy-target.txt"
}
_hello_write_remove() {   # 引数: クローンのフォルダ ブランチ名（削除: remove-target.txt。deploy-target.txt は雛形のまま）
    e2e_hello_remove_target_text > "${1}/sf-tools/release/${2}/remove-target.txt"
}
# push した内容（手元の HEAD）が、GitHub のブランチの先頭と一致すること。どちらかが読めない（空）場合は、一致とみなさない
_pushed_to_remote() {   # 引数: クローンのフォルダ ブランチ名
    local l r
    l=$(git -C "$1" rev-parse HEAD 2>/dev/null)  # VAR=$(cmd) のため run 不使用
    r=$(git -C "$1" ls-remote origin "refs/heads/${2}" 2>/dev/null | awk '{print $1}')  # VAR=$(cmd) のため run 不使用
    [[ -n "$l" && "$l" == "$r" ]]
}
_hello_push() { E2E_COMMIT_MSG="$2" e2e_run_sf_cmd "sf-push-$1" "$3" "" "${SF_TOOLS_ROOT}/bin/sf-push.sh"; }   # 引数: ジョブ名 メッセージ クローンのフォルダ

# ジョブの開始から push まで。引数: ラベル ブランチ名（= ジョブ名） コミットメッセージ ファイルを書く関数名 テストクラスを検出するか（1 / 0）
_hello_local_job() {
    local label="$1" job="$2" msg="$3" writefn="$4" expect_tests="$5" repo="${WORK}/$2/${REPO_NAME}"
    # 入力: ジョブ名 → 確認（Y）→ 組織のエイリアス → ログイン先（2 = Sandbox。sf-start.sh の質問。e2e では、認証 URL で
    # ログインするため、選んだ URL は、使われない）。コメントは、chk の行の外に置く（行の継続の途中に書くと、コマンドが消える）
    chk "${label}: sf-job.sh で、ジョブ（ブランチ ${job}）を開始した（ブランチ作成・clone・sf-start.sh）" \
        e2e_run_sf_cmd "sf-job-${job}" "$WORK" "${job}\nY\n${E2E_JOB_ALIAS}\n2\n" "${SF_TOOLS_ROOT}/bin/sf-job.sh" ${JOB_ARGS[@]+"${JOB_ARGS[@]}"} || return 1
    # 引数なしのとき: 作業フォルダの下のクローンの git remote から、プロジェクトが決まった（入力なしで、先へ進んだ）
    [[ $WITH_ARGS -eq 1 ]] || chk "${label}: sf-job.sh は、引数なしで、作業フォルダの下のクローンから、プロジェクトを決めた" \
        grep -qF "このフォルダの下のクローンから取得" "${E2E_TMP}/sf-job-${job}.out"
    chk "${label}: sf-install.sh（sf-start.sh が背景で実行）が完了した" e2e_wait_sf_install "$repo" || return 1
    chk "${label}: Git フック（pre-push）が設置された" test -f "${repo}/.git/hooks/pre-push"
    chk "${label}: リリース管理フォルダ release/${job}/ が用意された（雛形）" \
        test -f "${repo}/sf-tools/release/${job}/deploy-target.txt" -a -f "${repo}/sf-tools/release/${job}/remove-target.txt" || return 1
    chk "${label}: ファイルを書いた" "$writefn" "$repo" "$job" || return 1
    chk "${label}: sf-dryrun.sh で、ローカルから検証できた" \
        e2e_run_sf_cmd "sf-dryrun-${job}" "$repo" "" "${SF_TOOLS_ROOT}/bin/sf-dryrun.sh" --no-open || return 1
    if [[ "$expect_tests" == "1" ]]; then
        chk "${label}: sf-dryrun.sh が、@isTest のクラスを検出した（--tests の指定）" \
            grep -q "テストクラス合計: 1件" "${E2E_TMP}/sf-dryrun-${job}.out" || return 1
    fi
    chk "${label}: sf-push.sh で、commit と push ができた" _hello_push "$job" "$msg" "$repo" || return 1
    chk "${label}: pre-push フック（sf-prepush.sh）が動いた" test -s "${repo}/sf-tools/logs/sf-prepush.log"
    chk "${label}: push した内容が、GitHub のブランチ ${job} に届いている" _pushed_to_remote "$repo" "$job"
}
# ワークフローの実行が成功したか。失敗したら、ログを表示し、1 回だけ再実行する（一時的な失敗への対策）。
#   再実行で成功したら、PASS（警告を表示し、FLAKY_RUNS に数える）。再実行でも失敗したら、FAIL
#   引数: 実行ID ラベル
FLAKY_RUNS=0
_run_ok() {
    local id="$1" label="$2"
    [[ "$(_run_conclusion "$id")" == "success" ]] && return 0
    e2e_show_run_failure "$REPO_FULL" "$id" "$label"
    log "WARNING" "${label}: 失敗しました。一時的な失敗（Salesforce・通信側）の可能性があるため、1 回だけ再実行します（gh run rerun --failed）。"
    e2e_rerun_and_wait "$REPO_FULL" "$id" || { log "ERROR" "${label}: 再実行できなかった、または、完了しませんでした。"; return 1; }
    if [[ "$(_run_conclusion "$id")" == "success" ]]; then
        FLAKY_RUNS=$((FLAKY_RUNS + 1))
        log "WARNING" "${label}: 再実行で成功しました。一時的な失敗だった可能性があります（最初の失敗のログは、上に表示しています）。"
        return 0
    fi
    log "ERROR" "${label}: 再実行でも失敗しました。"
    e2e_show_run_failure "$REPO_FULL" "$id" "${label}（再実行後）"
    return 1
}

# PR の作成 → wf-validate → マージ → wf-release →（main のときだけ）wf-propagate。成功したら、実行 ID を HELLO_RELEASE_RUN に入れる
#   引数: ラベル ブランチ名（push 済み） PR のタイトル 先の段階（main / staging / develop。既定 main）
#   同じブランチから、段階ごとに PR を出すため、PR を作る前の最新の実行 ID を覚え、それより新しい実行だけを、この PR の実行とみなす
_hello_pr_flow() {
    local label="$1" br="$2" title="$3" base="${4:-main}" prn runid b_val b_rel b_pro
    b_val=$(e2e_latest_run_id "$REPO_FULL" wf-validate.yml "$br")    # VAR=$(cmd) のため run 不使用
    b_rel=$(e2e_latest_run_id "$REPO_FULL" wf-release.yml "$br")     # VAR=$(cmd) のため run 不使用
    b_pro=$(e2e_latest_run_id "$REPO_FULL" wf-propagate.yml "$br")   # VAR=$(cmd) のため run 不使用
    prn=$(e2e_gh_pr_create "$REPO_FULL" "$br" "$title" "$base") || prn=""   # VAR=$(cmd) のため run 不使用
    chk "${label}: PR を作成した" test -n "$prn" || return 1
    runid=$(e2e_wait_pr_run "$REPO_FULL" wf-validate.yml "$br" "$b_val") || runid=""   # VAR=$(cmd) のため run 不使用
    chk "${label}: wf-validate（検証）が実行され、完了した" test -n "$runid" || return 1
    chk "${label}: wf-validate が成功した（失敗したら、1 回だけ再実行）" _run_ok "$runid" "${label}: wf-validate" || return 1
    chk "${label}: PR をマージした" e2e_gh_pr_merge "$REPO_FULL" "$prn" || return 1
    runid=$(e2e_wait_pr_run "$REPO_FULL" wf-release.yml "$br" "$b_rel") || runid=""   # VAR=$(cmd) のため run 不使用
    chk "${label}: wf-release が実行され、完了した" test -n "$runid" || return 1
    chk "${label}: wf-release が成功した（失敗したら、1 回だけ再実行）" _run_ok "$runid" "${label}: wf-release" || return 1
    HELLO_RELEASE_RUN="$runid"
    # wf-propagate（main へのマージ時だけ起動する。staging / develop がない構成では、スキップして成功になる）。失敗しても、続きの確認は進める
    if [[ "$base" == "main" ]]; then
        local pid
        pid=$(e2e_wait_pr_run "$REPO_FULL" wf-propagate.yml "$br" "$b_pro") || pid=""   # VAR=$(cmd) のため run 不使用
        if chk "${label}: wf-propagate が実行され、完了した" test -n "$pid"; then
            chk "${label}: wf-propagate が成功した（staging / develop がない構成では、スキップ。失敗したら、1 回だけ再実行）" _run_ok "$pid" "${label}: wf-propagate"
        fi
    fi
    return 0
}

# 1 回分: ジョブ → PR → wf-validate → マージ → wf-release → wf-propagate。引数: ラベル ブランチ名 PR のタイトル ファイルを書く関数名 テストを検出するか
_hello_cycle() {
    local label="$1" br="$2" title="$3" writefn="$4" expect_tests="$5"
    _hello_local_job "$label" "$br" "$title" "$writefn" "$expect_tests" || return 1
    _hello_pr_flow "$label" "$br" "$title"
}

# sf-next.sh: リリースしたジョブのクローンで実行し、マージ済みのブランチが「マージ済み」と表示されること（質問には N で答える）
#   引数: クローンのフォルダ [段階の数（既定 1）]。段階の数以上の行に、「マージ済み」と表示されること
_hello_sf_next() { e2e_run_sf_cmd "sf-next" "$1" "N\n" "${SF_TOOLS_ROOT}/bin/sf-next.sh" && [[ "$(grep -c "マージ済み" "${E2E_TMP}/sf-next.out")" -ge "${2:-1}" ]]; }
# sf-deploy.sh: 予約名の組織へのローカルからの強制リリースは、確認の前に拒否される（終了コード 0 以外、拒否の文言、デプロイしない）
#   予約名は main を使う（開発者の本物の組織に付いていることがある prod / staging / develop は、避ける。
#   万一、拒否が働かなくなっても、main という名前の組織は、まず無いので、本物の組織への強制リリースにならない）
_hello_deploy_refused() {
    e2e_run_sf_cmd_refused "sf-deploy-refused" "$1" "N\n" "${SF_TOOLS_ROOT}/bin/sf-deploy.sh" -t main --no-open \
        && [[ -s "${E2E_TMP}/sf-deploy-refused.out" ]] \
        && grep -q "共有環境のため" "${E2E_TMP}/sf-deploy-refused.out" \
        && ! grep -q "project deploy start" "${E2E_TMP}/sf-deploy-refused.out"
}

# --resume: 前回の残りの Hello World の Apex クラスが、組織にあれば、削除する（名前が完全に一致するものだけ。なければ、何もしない）
_resume_clean_apex() {
    local list
    local -a names=()
    list=$(e2e_list_target_apex) || return 1  # VAR=$(cmd) のため run 不使用
    [[ -z "$list" ]] && return 0
    local _line
    while IFS= read -r _line; do names+=("$_line"); done <<< "$list"   # mapfile は Bash 4 以降のため使わない
    log "WARNING" "  前回の残りの Apex クラスがあります。削除します: ${names[*]}"
    e2e_delete_apex "${names[@]}"
}

# ---- 段階（main / staging / develop）ごとの確認の部品 ----
_suffix_of() { case "$1" in main) echo "PROD" ;; staging) echo "STG" ;; develop) echo "DEV" ;; esac; }
# 層数が 2 以上のとき、ラベルに付ける（「（staging の組織）」）。1 層のときは、何も付けない（従来と同じ表示）
_tag() { if (( ${#TIERS[@]} > 1 )); then printf '（%s の組織）' "$1"; fi; return 0; }
_admin_login_tier() { ( E2E_TIER="$1"; e2e_sf_admin_login ); }                  # 引数: 段階
_apex_is()          { [[ "$(E2E_TIER="$1" e2e_apex_count "$2")" == "$3" ]]; }    # 引数: 段階 クラス名 期待する件数
_resume_clean_tier() { ( E2E_TIER="$1"; _resume_clean_apex ); }                 # 引数: 段階（前回の残りの Hello World を消す）
_delete_apex_tier() { ( E2E_TIER="$1"; e2e_delete_apex "$E2E_APEX_HELLO_TEST" "$E2E_APEX_HELLO" ); }   # 引数: 段階（管理者の削除デプロイ）
# 段階のブランチに、main の最新が入っているか（wf-propagate の結果）。compare の ahead_by が 0 なら、入っている
_branch_has_main() { [[ "$(_e2e_gh api "repos/${REPO_FULL}/compare/${1}...main" --jq .ahead_by 2>/dev/null)" == "0" ]]; }
# リポジトリに保存された組織の ID（SF_ORG_ID_*）が、鍵一式のテスト用組織の ID と一致するか（管理用ログイン済みであること）
_org_id_matches() {   # 引数: 段階
    local have want
    have=$(_e2e_gh variable get "SF_ORG_ID_$(_suffix_of "$1")" -R "$REPO_FULL" 2>/dev/null | tr -d '\r')   # VAR=$(cmd) のため run 不使用
    want=$(E2E_TIER="$1" e2e_org_id "$(E2E_TIER="$1" _e2e_cur_alias)")                                      # VAR=$(cmd) のため run 不使用
    [[ -n "$have" && -n "$want" && "${have:0:15}" == "${want:0:15}" ]]
}
_hello_flow() {
    HELLO_RELEASE_RUN=""
    local t i j n=${#TIERS[@]} lbl repo
    # 各段階の組織に、管理用ログインする（問い合わせ用）
    for t in "${TIERS[@]}"; do
        chk "Hello World: Salesforce への管理用ログイン（問い合わせ用）$(_tag "$t")ができた" _admin_login_tier "$t" || return 0
    done
    # 各段階の組織が、鍵一式のテスト用組織と一致していること（組織の取り違えの確認）
    for t in "${TIERS[@]}"; do
        chk "Hello World: ${t} の組織が、鍵一式のテスト用組織と一致している" _org_id_matches "$t"
    done
    if [[ $RESUME -eq 1 ]]; then
        for t in "${TIERS[@]}"; do
            chk "Hello World: 前回の残りの Apex クラスを、確認した（あれば削除）$(_tag "$t")" _resume_clean_tier "$t" || return 0
        done
    fi
    for t in "${TIERS[@]}"; do
        chk "Hello World: リリース前は、Salesforce にクラスがない$(_tag "$t")" _apex_is "$t" "$E2E_APEX_HELLO" 0 || return 0
    done

    # ジョブの開始から push まで（1 回。同じブランチから、段階ごとに PR を出す）
    _hello_local_job "リリース" "$JOB_RELEASE" "e2e: Hello World をリリース" _hello_write_release 1 || return 0

    # 段階ごとに、PR → wf-validate → マージ → wf-release。上流（develop）から、main の順
    for (( i = 0; i < n; i++ )); do
        t="${TIERS[i]}"
        lbl="リリース"; (( n > 1 )) && lbl="リリース（${t}）"
        _hello_pr_flow "$lbl" "$JOB_RELEASE" "e2e: Hello World をリリース" "$t" || return 0
        (( n > 1 )) && _elapsed "${lbl}の終了"
        # wf-release の途中のステップ（JWT ログイン・sf-tools の取得・Slack 通知）
        # ステップ名は templates/.github/workflows/wf-release.yml の name と一致させる
        chk "wf-release: ${t} の組織へのログイン（JWT）が成功した" \
            test "$(_step_conclusion "$HELLO_RELEASE_RUN" "${t} の組織にログイン（JWT）")" == "success"
        chk "wf-release: sf-tools の取得が成功した（公開リポジトリを、Token なしで clone）" \
            test "$(_step_conclusion "$HELLO_RELEASE_RUN" "自動化ツール（sf-tools）を取得")" == "success"
        chk "wf-release: Slack への通知が成功した（ok:true）" \
            _slack_ok "$HELLO_RELEASE_RUN"
        # この段階の組織に、クラスができたこと。先の段階の組織には、まだ入っていないこと（意図した組織にだけ入る）
        chk "リリース後: Salesforce への管理用ログイン（問い合わせ用）をやり直した$(_tag "$t")" _admin_login_tier "$t" || return 0
        chk "リリース後: Salesforce に ${E2E_APEX_HELLO} ができた$(_tag "$t")" _apex_is "$t" "$E2E_APEX_HELLO" 1
        chk "リリース後: Salesforce に ${E2E_APEX_HELLO_TEST} ができた$(_tag "$t")" _apex_is "$t" "$E2E_APEX_HELLO_TEST" 1
        for (( j = i + 1; j < n; j++ )); do
            chk "リリース後: まだ、${TIERS[j]} の組織には、${E2E_APEX_HELLO} が入っていない（意図した組織にだけ入る）" \
                _apex_is "${TIERS[j]}" "$E2E_APEX_HELLO" 0
        done
    done
    _elapsed "リリース側（sf-job → PR → wf-release）の終了"

    # main へのマージのあと、wf-propagate が、staging・develop のブランチに、main の最新を入れること
    for t in "${TIERS[@]}"; do
        [[ "$t" == "main" ]] && continue
        chk "wf-propagate: ${t} のブランチに、main の最新が入った" _branch_has_main "$t"
    done

    # 通常の運用で使う、そのほかの sf-tools のコマンド（リリースしたジョブのクローンで実行する）
    repo="${WORK}/${JOB_RELEASE}/${REPO_NAME}"
    chk "sf-next.sh: マージ済みのブランチを、マージ済みと表示する" _hello_sf_next "$repo" "$n"
    chk "sf-deploy.sh: 共有環境（予約名 main）へのローカルからの強制リリースを、拒否する" _hello_deploy_refused "$repo"

    # 削除: main への PR（remove-target.txt）で行う。ほかの段階の組織には、及ばない
    _hello_cycle "削除" "$JOB_DELETE" "e2e: Hello World を削除" _hello_write_remove 0 || return 0
    # 2 回目の sf-job.sh（sf-start.sh）が、同じ組織の接続を、いったんログアウトして、ログインし直す。
    # 同じユーザーの認証は、エイリアスが違っても、共通の保存先を使うため、問い合わせ用の管理用ログインを、やり直してから確認する
    _elapsed "削除側（sf-job → PR → wf-release）の終了"
    chk "削除後: Salesforce への管理用ログイン（問い合わせ用）をやり直した$(_tag main)" _admin_login_tier main || return 0
    chk "削除後: Salesforce から ${E2E_APEX_HELLO} が消えた$(_tag main)" _apex_is main "$E2E_APEX_HELLO" 0
    chk "削除後: Salesforce から ${E2E_APEX_HELLO_TEST} が消えた$(_tag main)" _apex_is main "$E2E_APEX_HELLO_TEST" 0
    # 2 層・3 層: main の削除は、ほかの段階の組織には及ばない（まだ残っている）。残りは、管理者の削除デプロイで掃除する
    for t in "${TIERS[@]}"; do
        [[ "$t" == "main" ]] && continue
        chk "削除後: main の削除は、${t} の組織には及んでいない（まだ残っている。意図した組織にだけ作用する）" _apex_is "$t" "$E2E_APEX_HELLO" 1
        chk "後始末: ${t} の組織の Hello World を、管理者の削除デプロイで消した" _delete_apex_tier "$t"
        chk "後始末後: Salesforce から ${E2E_APEX_HELLO} が消えた$(_tag "$t")" _apex_is "$t" "$E2E_APEX_HELLO" 0
        chk "後始末後: Salesforce から ${E2E_APEX_HELLO_TEST} が消えた$(_tag "$t")" _apex_is "$t" "$E2E_APEX_HELLO_TEST" 0
    done
}

# --add-tier（管理者用のクローン = admin ブランチから、staging を追加する）の確認
#   新しく作った 1 層のリポジトリに、staging の段階を足す。確認すること: 実行できる（組織への接続・Secret / Variable・ブランチ・PR）、
#   終わったあとも admin ブランチにいる（main に居座らない）、main へ直接 push していない。
#   Hello World の確認のあとに行う（先に行うと、リポジトリが 2 層になり、リリースの確認の対象が変わるため）
_main_sha()   { _e2e_gh api "repos/${REPO_FULL}/branches/main" --jq .commit.sha 2>/dev/null; }
_has_open_pr_titled() { _e2e_gh pr list -R "$REPO_FULL" --state open --json title --jq '.[].title' 2>/dev/null | grep -qxF -- "$1"; }
_add_tier_check() {
    local t=staging sfx=STG main_before
    log "HEADER" "--add-tier ${t}（管理者用のクローン = admin ブランチから実行）"
    main_before=$(_main_sha)  # VAR=$(cmd) のため run 不使用
    chk "add-tier: 実行前、管理者用のクローンは admin ブランチにいる" _admin_branch_is admin
    # 入力: 続行（Y）→ ログイン先（1 = login.salesforce.com。e2e では、認証 URL でログインするため、選んだ URL は、使われない）
    chk "add-tier: sf-init.sh --add-tier ${t} が成功した（組織への接続・ブランチ・PR）" \
        e2e_run_sf_cmd "sf-init-add-tier" "$_ADMIN_CLONE" "Y\n1\n" "${SF_TOOLS_ROOT}/bin/sf-init.sh" --add-tier "$t" || return 0
    chk "add-tier: 終わったあとも、admin ブランチにいる（main に居座らない）" _admin_branch_is admin
    chk "add-tier: GitHub に ${t} ブランチができた" _has_branch "$t"
    chk "add-tier: Secret SF_CONSUMER_KEY_${sfx} が登録された" _has_secret "SF_CONSUMER_KEY_${sfx}"
    chk "add-tier: Variable SF_USERNAME_${sfx} が登録された" _has_variable "SF_USERNAME_${sfx}"
    chk "add-tier: Variable SF_INSTANCE_URL_${sfx} が登録された" _has_variable "SF_INSTANCE_URL_${sfx}"
    chk "add-tier: branches.txt を更新する PR が作られた" _has_open_pr_titled "chore: ${t} tier を追加"
    chk "add-tier: main へ、直接 push していない（PR を作るだけ）" test "$(_main_sha)" == "$main_before"
}

log "HEADER" "確認"
[[ $RESUME -eq 1 ]] || chk "sf-init が正常終了した（終了コード ${INIT_RC}）" test "$INIT_RC" -eq 0   # --resume では、sf-init を実行しない

# リポジトリの構成（層数）を、ブランチから判定する。TIERS は、リリースの順（develop → staging → main）
#   LAYOUT_DETECTED: 1 = main のみ / 2 = main + staging / 3 = main + staging + develop
TIERS=(main)
LAYOUT_DETECTED=1
if [[ "$INIT_RC" -eq 0 ]]; then
    if _has_branch develop && _has_branch staging; then LAYOUT_DETECTED=3
    elif _has_branch staging; then LAYOUT_DETECTED=2
    fi
    TIERS=()   # mapfile は Bash 4 以降のため使わない
    while IFS= read -r _tier_line; do TIERS+=("$_tier_line"); done < <(e2e_layout_tiers "$LAYOUT_DETECTED")
    log "INFO" "  リポジトリの構成: ${LAYOUT_DETECTED} 層（${TIERS[*]}）"
    # 新しく作ったときは、指定した層数のとおりにできていること
    [[ $RESUME -eq 1 ]] || chk "指定した層数（${LAYOUT} 層）のとおりに、ブランチができた" test "$LAYOUT_DETECTED" -eq "$LAYOUT"
    # この層数の確認に必要な、テスト用組織が、鍵一式にあること（なければ、Hello World の確認を行えない）
    for _t in "${TIERS[@]}"; do
        e2e_tier_available "$_t" \
            || die "リポジトリは ${LAYOUT_DETECTED} 層ですが、${_t} の組織が、鍵一式にありません（bootstrap.sh --add-orgs で追加してください）。"
    done
fi

if [[ "$INIT_RC" -eq 0 ]]; then
    for _s in PAT_TOKEN SF_PRIVATE_KEY SLACK_BOT_TOKEN; do
        chk "Secret ${_s} が登録されている" _has_secret "$_s"
    done
    for _v in SF_TOOLS_BRANCH SLACK_CHANNEL_ID; do
        chk "Variable ${_v} が登録されている" _has_variable "$_v"
    done
    # 段階ごとの Secret / Variable・ブランチ
    for _t in "${TIERS[@]}"; do
        _sfx=$(_suffix_of "$_t")  # VAR=$(cmd) のため run 不使用
        chk "Secret SF_CONSUMER_KEY_${_sfx} が登録されている" _has_secret "SF_CONSUMER_KEY_${_sfx}"
        chk "Variable SF_USERNAME_${_sfx} が登録されている" _has_variable "SF_USERNAME_${_sfx}"
        chk "Variable SF_INSTANCE_URL_${_sfx} が登録されている" _has_variable "SF_INSTANCE_URL_${_sfx}"
        chk "ブランチ ${_t} がある" _has_branch "$_t"
    done
    chk "SF_TOOLS_BRANCH が development" _var_equals SF_TOOLS_BRANCH development
    chk "SLACK_CHANNEL_ID が入力した共有チャンネルの ID" _var_equals SLACK_CHANNEL_ID "$E2E_SLACK_CHANNEL_ID"
    for _w in wf-metasync.yml wf-propagate.yml wf-release.yml wf-sequence.yml wf-validate.yml; do
        chk "ワークフロー ${_w} がある" _has_workflow "$_w"
    done

    # 管理者用フォルダ（admin）と、admin ブランチ（新しく作ったときだけ。--resume の前回分は、古い形のことがある）
    if [[ $RESUME -eq 0 ]]; then
        _ADMIN_CLONE="${WORK}/admin/${REPO_NAME}"
        _ADMIN_ENV="${WORK}/admin/.sf-init-${PROJECT}.env"
        _ADMIN_PROGRESS="${WORK}/admin/.sf-init-${PROJECT}.progress"
        _admin_branch_is()      { [[ "$(git -C "$_ADMIN_CLONE" symbolic-ref --short HEAD 2>/dev/null)" == "$1" ]]; }
        _admin_tracks_remote()  { [[ "$(git -C "$_ADMIN_CLONE" rev-parse --abbrev-ref 'admin@{upstream}' 2>/dev/null)" == "origin/admin" ]]; }
        _no_state_files()       { local f; for f in "${WORK}"/admin/.sf-init*; do [[ -e "$f" ]] && return 1; done; return 0; }
        _no_old_style_dirs()    { local d; for d in "${WORK}"/init "${WORK}"/init-*; do [[ -e "$d" ]] && return 1; done; return 0; }
        _in_init_out()          { grep -qF -- "$1" "$INIT_OUT"; }
        chk "管理者用フォルダ admin/${REPO_NAME} ができた（作業フォルダは、フォルダ構成に頼らない場所）" test -d "${_ADMIN_CLONE}/.git"
        # 状態ファイル（.sf-init-XXXX.env / .progress）は、最後まで終わったら、消える（完了後は、読む場所がない）
        _setup_marked() { [[ "$(git -C "$_ADMIN_CLONE" config --get sf-tools.setup-complete 2>/dev/null)" == "1" ]]; }
        chk "完了の印（クローンの git config sf-tools.setup-complete）が付いている（状態ファイルを消しても、完了済みと判定できる）" _setup_marked
        chk "完了後、状態ファイル（.sf-init-${PROJECT}.env / .progress）が、admin から消えている" \
            test ! -e "$_ADMIN_ENV" -a ! -e "$_ADMIN_PROGRESS"
        chk "admin に、状態ファイルの残骸（.sf-init-*）がない" _no_state_files
        # 完了済みの判定は、クローンで行う: 同じオーナー・XXXX で、もう一度 sf-init.sh を実行すると、完了済みの案内が出る
        #   （対話では、すでにあるプロジェクトでも、admin のクローンがあれば、受け付ける。入力: [オーナーの番号] XXXX、Y（続行の確認）、q（終了））
        if [[ $WITH_ARGS -eq 1 ]]; then
            _rerun_input="Y\nq\n"; _rerun_args=(--owner "$E2E_OWNER" --project "$PROJECT")
        else
            _rerun_input="$(e2e_make_identity_input "$E2E_OWNER" "$PROJECT" | awk '{ printf "%s\\n", $0 }')q\n"; _rerun_args=()
        fi
        chk "完了済みのプロジェクトで、sf-init.sh をもう一度実行すると、完了済みの案内が出る（クローンで判定）" \
            e2e_run_sf_cmd "sf-init-rerun" "$WORK" "$_rerun_input" "${SF_TOOLS_ROOT}/bin/sf-init.sh" ${_rerun_args[@]+"${_rerun_args[@]}"}
        chk "完了済みの案内の文言が出た（セットアップが、すでに完了しています）" grep -qF "セットアップが、すでに完了しています" "${E2E_TMP}/sf-init-rerun.out"
        chk "案内を終了（q）しても、状態ファイルは作られない（何も実行されていない）" _no_state_files
        chk "古い形のフォルダ（init / init-*）ができていない" _no_old_style_dirs
        chk "管理者用のクローンが、admin ブランチにいる（main の上で作業しない）" _admin_branch_is admin
        chk "GitHub にも、admin ブランチがある" _has_branch admin
        chk "ローカルの admin が、origin/admin を追跡している（push -u）" _admin_tracks_remote
        chk "完了画面に、admin ブランチの案内が出た（ローカルと GitHub の両方）" _in_init_out "ブランチは admin です（このコンピューターと GitHub の両方にあります）"
        chk "完了画面に、admin は main から古くなる旨が出た" _in_init_out "main から古くなります"
        # 最初のメタデータの同期: セットアップが終わった瞬間に、クローンへ、同期済みのメタデータが、全部入っている
        _clone_has_metadata()   { git -C "$_ADMIN_CLONE" ls-tree -r --name-only admin 2>/dev/null | grep '^force-app/' | grep -qv '/\.gitkeep$'; }
        _main_has_sync_commit() { _e2e_gh api "repos/${REPO_FULL}/commits?sha=main&per_page=10" --jq '.[].commit.message' 2>/dev/null | grep -qF "定期更新: Salesforce変更の自動反映"; }
        _local_main_is_remote() { [[ -n "$(git -C "$_ADMIN_CLONE" rev-parse main 2>/dev/null)" && "$(git -C "$_ADMIN_CLONE" rev-parse main 2>/dev/null)" == "$(git -C "$_ADMIN_CLONE" ls-remote origin refs/heads/main 2>/dev/null | awk '{print $1}')" ]]; }
        chk "完了画面に、メタデータが同期済みである旨が出た" _in_init_out "メタデータは、同期済みです"
        chk "完了直後のクローン（admin ブランチ）に、同期済みのメタデータが入っている（force-app が、空のひな型ではない）" _clone_has_metadata
        chk "GitHub の main に、同期のコミット（定期更新: Salesforce変更の自動反映）がある" _main_has_sync_commit
        chk "ローカルの main が、origin/main と一致している（同期した内容を、取り込み済み）" _local_main_is_remote
        [[ $WITH_ARGS -eq 1 ]] || chk "対話: 「force- は自動で付く。XXXX の部分だけ入力」の案内が出た" _in_init_out "XXXX の部分だけを入力してください"
        # sf-sync-wf.sh: admin ブランチでは実行できる（--check は、読み取りのみ）。main（保護ブランチ）では断られる
        chk "admin ブランチで、sf-sync-wf.sh --check が実行できる" \
            e2e_run_sf_cmd "sf-sync-wf-admin" "$_ADMIN_CLONE" "" "${SF_TOOLS_ROOT}/bin/sf-sync-wf.sh" --check
        if chk "管理者用のクローンを、一時的に main に切り替えた（確認のため）" git -C "$_ADMIN_CLONE" checkout -q main; then
            chk "main ブランチ（保護ブランチ）では、sf-sync-wf.sh が断られる" \
                e2e_run_sf_cmd_refused "sf-sync-wf-main" "$_ADMIN_CLONE" "" "${SF_TOOLS_ROOT}/bin/sf-sync-wf.sh" --check
            chk "断られた理由が、保護ブランチ（環境ブランチ）である" grep -qF "では実行できません" "${E2E_TMP}/sf-sync-wf-main.out"
            chk "管理者用のクローンを、admin ブランチに戻した" git -C "$_ADMIN_CLONE" checkout -q admin
        fi
    fi

    # トークンが、sf-init の出力・ログに出ていないこと
    for _f in "$INIT_OUT" "$HOME/sf-tools/logs/sf-init.log" "$HOME/sf-tools/logs/error.log"; do
        chk "PAT_TOKEN の値が $(basename "$_f") に出ていない"      _not_in_file "$E2E_PAT_TOKEN"       "$_f"
        chk "SLACK_BOT_TOKEN の値が $(basename "$_f") に出ていない" _not_in_file "$E2E_SLACK_BOT_TOKEN" "$_f"
        chk "認証 URL が $(basename "$_f") に出ていない"            _not_in_file "$E2E_SFDX_AUTH_URL"   "$_f"
        [[ -z "${E2E_SFDX_AUTH_URL_STG:-}" ]] || chk "認証 URL（staging）が $(basename "$_f") に出ていない" _not_in_file "$E2E_SFDX_AUTH_URL_STG" "$_f"
        [[ -z "${E2E_SFDX_AUTH_URL_DEV:-}" ]] || chk "認証 URL（develop）が $(basename "$_f") に出ていない" _not_in_file "$E2E_SFDX_AUTH_URL_DEV" "$_f"
    done

    if [[ $SKIP_ACTIONS -eq 0 ]]; then
        log "INFO" "GitHub Actions を実行します（各待ち: 最大 ${E2E_WF_TIMEOUT:-1200} 秒）..."
        # wf-metasync（--resume では、行わない: 前回の確認で済んでおり、Hello World の確認を、早く繰り返すため）
        if [[ $RESUME -eq 0 ]]; then
            # wf-metasync を起動して、完了を待つ。Hello World の流れと並行させない
            #   （組織からの取得と、組織へのデプロイが重なると、MetadataTransferError で失敗する）
            _meta_id=$(_dispatch_workflow wf-metasync.yml) || _meta_id=""   # VAR=$(cmd) のため run 不使用
            chk "wf-metasync が起動した" test -n "$_meta_id"
            if [[ -n "$_meta_id" ]]; then
                if chk "wf-metasync が完了した" _wait_run "$_meta_id"; then   # 完了していない実行を、成功かどうか判定しない
                    chk "wf-metasync が成功した（JWT ログイン・sf-tools の取得を含む。失敗したら、1 回だけ再実行）" _run_ok "$_meta_id" "wf-metasync"
                fi
            fi
            _elapsed "wf-metasync の確認の終了"
        fi
        # Hello World を、PR 経由でリリースし（wf-validate → マージ → wf-release）、続けて削除する
        _hello_flow
    else
        log "INFO" "GitHub Actions の実行確認を省略しました（--no-actions）。"
    fi

    # --add-tier の確認（新しく作った 1 層のリポジトリのとき。staging の組織が必要）
    if [[ $ADD_TIER_CHECK -eq 1 && $RESUME -eq 0 && "$LAYOUT_DETECTED" -eq 1 ]]; then
        if e2e_tier_available staging; then
            _add_tier_check
            _elapsed "--add-tier の確認の終了"
        else
            log "INFO" "--add-tier の確認を省略しました（鍵一式に staging の組織がありません。bootstrap.sh --add-orgs で追加できます）。"
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 4. 後掃除
# ------------------------------------------------------------------------------
CLEAN_RC=0
if [[ $KEEP -eq 1 ]]; then
    log "INFO" "テスト用のものは、削除せずに残しました（あとから見返せます。次回の e2e の最初に、自動で削除されます）。"
    log "INFO" "  リポジトリ: https://github.com/${REPO_FULL}"
    log "INFO" "  Actions   : https://github.com/${REPO_FULL}/actions"
    log "INFO" "  すぐに削除する場合: tests/e2e/cleanup.sh --yes"
else
    e2e_cleanup_all delete || CLEAN_RC=1
fi

# ------------------------------------------------------------------------------
# 結果
# ------------------------------------------------------------------------------
echo ""
log "HEADER" "結果"
log "INFO" "  確認: ${CHECK_PASS} 件成功 / ${CHECK_FAIL} 件失敗"
_elapsed "全体"
if [[ $FLAKY_RUNS -gt 0 ]]; then
    log "WARNING" "  再実行で成功したワークフローが ${FLAKY_RUNS} 件あります（一時的な失敗の可能性。上の、最初の失敗のログを確認してください）。"
fi
if [[ $CLEAN_RC -ne 0 ]]; then
    log "ERROR" "  後掃除に失敗したものがあります。tests/e2e/cleanup.sh で確認してください。"
fi
# 検証の記録（doc/dev-reference.md 9.7 の表に追記する 1 行）。省いた確認（--no-actions など）は、結果の欄に書く
_rec_opts="${LAYOUT_DETECTED:-$LAYOUT} 層"
[[ $WITH_ARGS -eq 1 ]]       && _rec_opts="${_rec_opts}・--with-args"
[[ $SKIP_ACTIONS -eq 1 ]]    && _rec_opts="${_rec_opts}・--no-actions（Actions の確認を省略）"
[[ $ADD_TIER_CHECK -eq 0 ]]  && _rec_opts="${_rec_opts}・--no-add-tier（--add-tier の確認を省略）"
[[ $RESUME -eq 1 ]]          && _rec_opts="${_rec_opts}・--resume（Hello World の部分のみ）"
log "INFO" "  検証の記録（成功したときだけ、doc/dev-reference.md 9.7 の表に追記する）:"
echo "$(e2e_record_line "e2e ${CHECK_PASS} 件成功 / ${CHECK_FAIL} 件失敗（${_rec_opts}）")"
if [[ $CHECK_FAIL -eq 0 && $CLEAN_RC -eq 0 ]]; then
    log "SUCCESS" "e2e: すべて成功しました。"
    exit $RET_OK
fi
log "ERROR" "e2e: 失敗がありました。"
exit $RET_NG
