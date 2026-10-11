#!/bin/bash
# ==============================================================================
# sf-init.sh - 新規 Salesforce プロジェクトの初期セットアップ
# ==============================================================================
# 新しい force-xxx プロジェクトを GitHub に作成し、sf-tools と連携させるまでの
# 一連のセットアップを自動化する。
#
# 【前提フォルダ構成】
#   ~/home/
#   └── {github-owner}/   ← GitHub ユーザー名（フォルダ名から自動取得）
#       └── {company}/    ← プロジェクト名として使用（例: yamada → force-yamada）
#           ↑ここをカレントにして実行すること（init/ フォルダは自動作成）
#           ※ {company}/system/ 等のサブフォルダから実行するとエラー
#
# 【処理フロー】
#   Phase 1:  環境チェック（ツール確認・GitHub CLI 認証確認）
#   Phase 2:  プロジェクト情報の確認（フォルダ構成からOWNERとプロジェクト名を自動導出）
#   Phase 3:  リポジトリ作成（gh repo create + git clone）
#   Phase 4:  ファイル生成（sf-install.sh / sf-hook.sh）
#   Phase 5:  ブランチ構成（対話選択 → branches.txt 更新）
#   Phase 6:  PAT_TOKEN の設定
#   Phase 7:  Slack 連携の設定
#   Phase 8:  初回コミット＆プッシュ
#   Phase 9:  GitHub リポジトリ設定・Ruleset の適用
#   Phase 10: JWT 認証情報の設定（Salesforce GitHub Secrets 登録）
#
# 【前提】
#   Salesforce CLI（sf）は npm 版（npm install -g @salesforce/cli）であること。
#   起動時に sf --version の終了コードを確認し、0 以外なら案内を表示して中断する
#   （Windows の Git Bash で公式インストーラー版を使うと、成功しても終了コード 1 になるため）。
#
# 【手動操作が必要なステップ】
#   - Salesforce 組織へのブラウザログイン
#   - GitHub Classic PAT トークンの作成（repo + workflow スコープ）
#   - Slack App の作成・Bot Token の取得
#   - 通知先 Slack チャンネルで Bot を招待（/invite @sf-notify-<プロジェクト名>）
#
# 【使い方】
#   cd ~/home/{github-owner}/{company}
#   ~/sf-tools/bin/sf-init.sh [--resume N] [--only N]
#
#   cd ~/home/{github-owner}/{company}/system/force-xxx
#   ~/sf-tools/bin/sf-init.sh --add-tier staging   # staging tier を追加
#   ~/sf-tools/bin/sf-init.sh --add-tier develop   # develop tier を追加
#
# 【途中で止まったとき（続きから）】
#   各 Phase が成功するたびに、進捗を init/.sf-init.progress に記録する（SF_INIT_DONE_PHASE）。
#   途中（Phase 2〜9 まで完了）で止まった状態が残っていて、そのリポジトリがこの作業フォルダのものなら、
#   引数なしで起動したとき、次の 2 つから選ばせる（既定値はなく、番号を入力する）。
#     [1] 次の Phase から続きをやる（Phase 1 の環境チェックを実行したうえで、続きから。保存済みの入力内容を使う）
#     [2] 最初からやり直す（保存した状態を消して Phase 1 から。作成済みのリポジトリ・init フォルダは、そのまま使う）
#   管理者向けの警告・確認と gh のオーナー確認は、どちらの場合も、毎回、実行する。
#   --resume N / --only N を指定した場合は、この質問をせず、指定を優先する。
#
# 【オプション】
#   --resume N            : Phase N から再開（Phase N 以降を、質問なしで実行する）
#   --only N              : Phase N のみ実行（デバッグ・単体テストに使用。進捗は記録しない）
#   --add-tier staging    : 既存プロジェクトに staging tier を追加
#   --add-tier develop    : 既存プロジェクトに develop tier を追加
#   --reconnect <段階>    : 1 つの段階（main / staging / develop）の、接続先の Salesforce 組織を付け替える（force-* 内で実行）
#   --status              : 段階ごとの、接続先（ログイン先・組織の種類・ユーザー・組織 ID）を一覧にする（読み取りのみ。force-* 内で実行）
#   --legacy-connected-app: 従来の接続アプリケーション（手動の入力。今後廃止予定）を使う。既定は、外部クライアントアプリ（自動で作成）
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 共通ライブラリの必須設定
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME=$(basename "$0" .sh)
# sf-init.sh はプロジェクト外から実行するため、ログは sf-tools 配下に記録する
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true
readonly LOG_FILE="$HOME/sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"  # 司令塔が起動のたびにログをリセットする

# ------------------------------------------------------------------------------
# 2. 共通ライブラリの読み込み
# ------------------------------------------------------------------------------
# sf-init.sh はプロジェクト外から実行するため、force-* チェックをバイパスする
export SF_INIT_MODE=1

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
source "${SCRIPT_DIR}/../lib/wizard.sh"                 # ウィザード形式の画面の部品（doc/wizard-ux-design.md）
source "${SCRIPT_DIR}/../phases/init/init-common.sh"    # ensure_sf_tools_branch など（各フェーズと共通）

trap '' INT  # Ctrl+C を無効化（子プロセスにも継承される）

ORIG_ARGS=("$@")   # sf-tools を更新したあと、同じ引数で、実行しなおすために覚えておく

# ------------------------------------------------------------------------------
# 3. 引数解析
# ------------------------------------------------------------------------------
ONLY_PHASE=""
RESUME_PHASE=1
ADD_TIER_MODE=""
RECONNECT_MODE=""
STATUS_MODE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h) show_help ;;
        --only)
            ONLY_PHASE="$2"
            shift 2
            ;;
        --resume)
            RESUME_PHASE="$2"
            shift 2
            ;;
        --add-tier)
            ADD_TIER_MODE="$2"
            shift 2
            ;;
        --reconnect)
            RECONNECT_MODE="$2"
            [[ -n "$RECONNECT_MODE" ]] || die "--reconnect には、main・staging・develop のいずれかを指定してください。"
            shift 2
            ;;
        --status)
            STATUS_MODE=1
            shift
            ;;
        --legacy-connected-app)
            # 従来の接続アプリケーション（今後廃止予定）を使う。既定は、外部クライアントアプリ（自動で作成）
            export SF_INIT_LEGACY_CONNECTED_APP=1
            shift
            ;;
        *)
            die "不明なオプションです: $1
使い方:
  ~/sf-tools/bin/sf-init.sh                       # Phase 1〜10 を順次実行（途中で止まった状態があれば、続き / 最初からを選ぶ）
  ~/sf-tools/bin/sf-init.sh --resume N             # Phase N から最後まで順次実行（質問なし）
  ~/sf-tools/bin/sf-init.sh --only N               # Phase N のみ実行
  ~/sf-tools/bin/sf-init.sh --add-tier staging     # staging tier を追加
  ~/sf-tools/bin/sf-init.sh --add-tier develop     # develop tier を追加
  ~/sf-tools/bin/sf-init.sh --reconnect main       # main の接続先（Salesforce 組織）を付け替える
  ~/sf-tools/bin/sf-init.sh --status               # 段階ごとの接続先を一覧にする
  ~/sf-tools/bin/sf-init.sh --legacy-connected-app # 従来の接続アプリケーションを使う（今後廃止予定）"
            ;;
    esac
done

# sf が終了コードを正しく返すか確認する（npm 版が前提。NG なら案内を表示して中断する）
# --resume / --only / --add-tier のときも確認する（どの Phase でも sf を使うため）
check_sf_cli

# --add-tier モードは通常のフェーズループとは別処理
if [[ -n "$ADD_TIER_MODE" ]]; then
    log "HEADER" "tier 追加モード: ${ADD_TIER_MODE} (${SCRIPT_NAME}.sh)"
    export SF_TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    export ADD_TIER="$ADD_TIER_MODE"
    bash "${SCRIPT_DIR}/../phases/init/add_tier.sh" \
        || die "--add-tier ${ADD_TIER_MODE} が失敗しました。"
    exit $RET_OK
fi

# --status モード（読み取りのみ。force-* ディレクトリの中で実行する）
if [[ "$STATUS_MODE" -eq 1 ]]; then
    export SF_TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    bash "${SCRIPT_DIR}/../phases/init/status.sh" || die "--status が失敗しました。"
    exit $RET_OK
fi

# --reconnect モード（1 つの段階の接続先を付け替える。force-* ディレクトリの中で実行する）
if [[ -n "$RECONNECT_MODE" ]]; then
    export SF_TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
    export RECONNECT_TIER="$RECONNECT_MODE"
    bash "${SCRIPT_DIR}/../phases/init/reconnect.sh" || die "--reconnect ${RECONNECT_MODE} が失敗しました。"
    exit $RET_OK
fi

# 実行範囲を決定する
if [[ -n "$ONLY_PHASE" ]]; then
    START_PHASE=$ONLY_PHASE
    END_PHASE=$ONLY_PHASE
else
    START_PHASE=$RESUME_PHASE
    END_PHASE=10
fi

# ------------------------------------------------------------------------------
# 4. 開始画面・実行ディレクトリの検証（~/home/{owner}/{company}/ であること）
# ------------------------------------------------------------------------------
# 利用者に見せるステップ（全 8 つ）と、内部の Phase の対応。表示と実行順は一致させる（doc/wizard-ux-design.md 4.1）
WIZ_TOTAL=8
WIZ_STEP_TITLES=("" "準備の確認" "プロジェクトの確認" "リポジトリの作成" "ブランチの構成" "GitHub の Token" "Slack の通知" "リポジトリの設定" "Salesforce の接続")
WIZ_STEP_PURPOSES=("" \
    "必要なツールと、GitHub へのログインを確認します。" \
    "作るリポジトリの名前と場所を、確認します。" \
    "GitHub にリポジトリを作り、設定ファイルを用意します。" \
    "コードを、段階的に確認してから本番に出す流れ（ブランチの構成）を選びます。" \
    "自動で動くワークフローが、リポジトリを更新するための、Token を登録します。" \
    "ワークフローの結果を、Slack に通知するための設定をします。" \
    "ここまでの内容を、リポジトリに反映し、保護のルールを設定します。" \
    "Salesforce の各組織と、GitHub を、接続します。")
#                      Phase:  0  1  2  3  4  5  6  7  8  9 10
WIZ_PHASE_STEP=(0 1 2 3 3 4 5 6 7 7 8)
# Phase ごとの、利用者向けの名前（「前回は、○○まで完了しています」の表示に使う）
WIZ_PHASE_TITLES=("" "準備の確認" "プロジェクトの確認" "リポジトリの作成" "設定ファイルの作成" "ブランチの構成" "GitHub の Token" "Slack の通知" "初回のコミット" "リポジトリの設定" "Salesforce の接続")

export SF_TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# --only / --resume N の指定がない（通常の新規実行）か。開始画面の全体像は、このときだけ出す
FULL_START=0
[[ "$RESUME_PHASE" -eq 1 && -z "$ONLY_PHASE" ]] && FULL_START=1

check_home_dir  # GITHUB_OWNER / COMPANY_NAME をセット（失敗時は die）

# 開始画面（通常の新規実行は、全体像つき。--only / --resume N は、簡易表示）
if [[ "$FULL_START" -eq 1 ]]; then
    wizard_banner "新しい Salesforce プロジェクトを作ります"
    echo "" >&2
    echo "  作るもの   : ${GITHUB_OWNER}/force-${COMPANY_NAME}（GitHub のリポジトリ）" >&2
    echo "  かかる時間 : 30〜60 分ほどが目安です（ブラウザでの作業・Salesforce の反映待ちを含みます）" >&2
    echo "" >&2
else
    log "HEADER" "新規 Salesforce プロジェクトの初期セットアップを開始します (${SCRIPT_NAME}.sh)"
fi
[[ -n "${SF_INIT_RESTARTED:-}" ]] && log "INFO" "sf-tools を更新しました。更新した sf-tools で、はじめから実行しています。"

echo -e "${CLR_ERR}╔══════════════════════════════════════════════════════╗${CLR_RESET}" >&2
echo -e "${CLR_ERR}║  !!  このコマンドは管理者専用です                    ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║      管理者以外は絶対に実行しないでください          ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║                                                      ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║  新規 Salesforce リポジトリを GitHub に作成し        ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║  初期セットアップを行います。                        ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}╚══════════════════════════════════════════════════════╝${CLR_RESET}" >&2

# sf-tools が古いと、古い雛形でプロジェクトを作ってしまうため、最初に最新かを確認する（P14）。
#   管理者向けの警告の後（確認の前）に行う。更新した場合は、警告・確認から、もう一度、やりなおす（確認を、飛ばさない）。
#   現在のブランチを対象にする（本番 / 検証の選択には、依存しない）。遅れていれば、確認のうえ更新し、
#   更新した sf-tools で、自動的に、もう一度、実行する（利用者に、実行しなおしを、させない）。
#   実行しなおした後（SF_INIT_RESTARTED）は、確認しない（無限に実行しなおさないため）
_cur_branch=""
if [[ -z "${SF_INIT_RESTARTED:-}" ]]; then
    # Git リポジトリのときだけ、現在のブランチを調べる（リポジトリでなければ、確認しない）
    if git -C "$SF_TOOLS_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then  # if cmd のため run 不使用
        _cur_branch=$(git -C "$SF_TOOLS_DIR" symbolic-ref --short HEAD 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
    fi
    if [[ -n "$_cur_branch" ]]; then
        ensure_sf_tools_branch "$_cur_branch"
        if [[ $? -eq 2 ]]; then
            export SF_INIT_RESTARTED=1
            log "INFO" "更新した sf-tools で、もう一度、はじめから実行します。"
            exec bash "${BASH_SOURCE[0]}" "${ORIG_ARGS[@]}"
        fi
    fi
fi
# このブランチは、確認済み（Phase 2 の確認を、省略するため）
export SF_INIT_TOOLS_CHECKED_BRANCH="$_cur_branch"

if [[ "$FULL_START" -eq 1 ]]; then
    wizard_checklist "【先に、用意してください】" \
        "GitHub : ${GITHUB_OWNER} の管理者としてログインしたブラウザ" \
        "Slack : 通知用の「共有チャンネル」（全員が参加するもの）。まだなければ、いま Slack で作ってください" \
        "Salesforce : 接続する組織の、システム管理者のアカウント（ブランチの構成で選ぶ数: 1〜3 組織）"
    echo "" >&2
    echo -e "  ${CLR_WARNING}【これから行うこと】${CLR_RESET}" >&2
    for _i in $(seq 1 "$WIZ_TOTAL"); do
        echo "    ${_i}. ${WIZ_STEP_TITLES[$_i]}" >&2
    done
    # 管理者向けの確認（Enter / Y で進む。N / q は中断）
    wizard_confirm "用意ができたら Enter を押してください（q で中断）"
else
    ask_yn "続行しますか？" || die "中断しました。"
fi

check_gh_owner "$GITHUB_OWNER"

log "INFO" "セットアップ中は Ctrl+C が無効です。中断するにはターミナルを閉じてください。"

# ------------------------------------------------------------------------------
# 5. init フォルダの作成・移動
# ------------------------------------------------------------------------------
INIT_DIR="${PWD}/init"
run mkdir -p "$INIT_DIR" || die "init フォルダの作成に失敗しました: ${INIT_DIR}"
cd "$INIT_DIR" || die "init フォルダに移動できません: ${INIT_DIR}"

# ------------------------------------------------------------------------------
# 6. 環境変数の export（各フェーズスクリプトから参照）
# ------------------------------------------------------------------------------
export SF_TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# .sf-init.env は init フォルダに配置する（cd 後の PWD が init/ になる）
export SF_INIT_ENV_FILE="${PWD}/.sf-init.env"

# 進捗ファイル（成功した Phase を記録する。.sf-init.env とは別にする: 書き換えるときに、外部コマンドを使わないため）
export SF_INIT_PROGRESS_FILE="${PWD}/.sf-init.progress"

# ファイル（KEY=値 の行）から、値を 1 つ取り出す（source しない）。引数: キー ファイル。なければ空
_kv_value() {
    grep "^${1}=" "$2" 2>/dev/null | tail -n 1 | sed 's/^[^=]*=//; s/\r$//; s/^"//; s/"$//'  # 取得専用のため run 不使用
}

# 前回の続きの確認（引数なしで起動したときだけ）
#   前回、途中まで進んでいて（SF_INIT_DONE_PHASE が 2〜9）、そのリポジトリが、この作業フォルダのものなら、
#   「続きをやる / 最初からやり直す」を選ばせる。続きを選ぶと、Phase 1（環境チェック）を実行したうえで、次の Phase から始める
#   表示は、Phase の番号ではなく、利用者向けの名前（WIZ_PHASE_TITLES）で出す
RESUMED=0
if [[ "$RESUME_PHASE" -eq 1 && -z "$ONLY_PHASE" && -f "$SF_INIT_ENV_FILE" && -f "$SF_INIT_PROGRESS_FILE" ]]; then
    prev_done=$(_kv_value SF_INIT_DONE_PHASE "$SF_INIT_PROGRESS_FILE")   # VAR=$(cmd) のため run 不使用
    prev_at=$(_kv_value SF_INIT_DONE_AT "$SF_INIT_PROGRESS_FILE")        # VAR=$(cmd) のため run 不使用
    prev_repo=$(_kv_value REPO_FULL_NAME "$SF_INIT_ENV_FILE")            # VAR=$(cmd) のため run 不使用
    if [[ "$prev_done" =~ ^[0-9]+$ && "$prev_done" -ge 2 && "$prev_done" -lt 10 \
          && "$prev_repo" == "${GITHUB_OWNER}/force-${COMPANY_NAME}" ]]; then
        next_phase=$((prev_done + 1))
        echo "" >&2
        log "INFO" "前回のセットアップは、「${WIZ_PHASE_TITLES[$prev_done]}」まで完了しています${prev_at:+（${prev_at}）}。（${prev_repo}）"
        echo "" >&2
        echo "    [1] 「${WIZ_PHASE_TITLES[$next_phase]}」から、続きをやる   ← おすすめ" >&2
        echo "    [2] 最初からやり直す（作成済みのリポジトリ・init フォルダは、そのまま使います）" >&2
        echo "    [q] 中断" >&2
        echo "" >&2
        read_key resume_choice "  ▶ 番号を入力してください [1-2/q]: " "[12Qq]"
        case "$resume_choice" in
            1) RESUMED=1
               START_PHASE=$next_phase
               END_PHASE=10
               ;;
            2) ;;  # 最初から（下で .sf-init.env を削除する）
            *) die "中断しました。" ;;
        esac
    fi
fi

# 新規実行時（--resume / --only 時、前回の続きを選んだ時以外）は、前回の残骸を削除する（空ファイルは作らない）
if [[ "$RESUME_PHASE" -eq 1 && -z "$ONLY_PHASE" && "$RESUMED" -eq 0 ]]; then
    rm -f "$SF_INIT_ENV_FILE" "$SF_INIT_PROGRESS_FILE"  # 新規実行時は残骸削除のみ（Phase 2 が初回書き出し）
fi

# ------------------------------------------------------------------------------
# 7. メイン実行フロー（フェーズループ）
# ------------------------------------------------------------------------------
# 通常の実行では、Phase の番号は出さない（ステップの見出しを出す）。--resume / --only のときだけ、範囲を出す
[[ "$FULL_START" -eq 1 ]] || log "INFO" "実行フェーズ: Phase ${START_PHASE} 〜 Phase ${END_PHASE}"

# 続きから始める場合も、Phase 1（環境チェック。状態を持たない）は、毎回実行する
PHASE_LIST="$(seq "$START_PHASE" "$END_PHASE")"
[[ "$RESUMED" -eq 1 ]] && PHASE_LIST="1 ${PHASE_LIST}"

# ステップの見出しを出す（同じステップの Phase が続くときは、最初の 1 回だけ）。引数: Phase 番号
_show_step_header() {
    local p="$1" s i done_titles=()
    s="${WIZ_PHASE_STEP[$p]}"
    [[ "$s" == "$_LAST_STEP_SHOWN" ]] && return 0
    _LAST_STEP_SHOWN="$s"
    for i in $(seq 1 $((s - 1))); do done_titles+=("${WIZ_STEP_TITLES[$i]}"); done
    wizard_step "$s" "$WIZ_TOTAL" "${WIZ_STEP_TITLES[$s]}" "${WIZ_STEP_PURPOSES[$s]}" "${done_titles[@]}"
}
_LAST_STEP_SHOWN=""

for phase_num in $PHASE_LIST; do
    phase_script=$(ls "${SCRIPT_DIR}/../phases/init/$(printf '%02d' "$phase_num")"_*.sh 2>/dev/null | head -1) # VAR=$(cmd) のため run 不使用（Phase のスクリプトの検索。空なら、直後で die）
    if [[ -z "$phase_script" ]]; then
        die "Phase ${phase_num} のスクリプトが見つかりません: ${SCRIPT_DIR}/../phases/init/"
    fi
    # 通常の実行（--only なし）では、ステップの見出しを出す
    [[ -z "$ONLY_PHASE" ]] && _show_step_header "$phase_num"
    bash "$phase_script"
    phase_rc=$?
    if [[ $phase_rc -eq 75 ]]; then
        # sf-tools を更新した（Phase 2）。更新した sf-tools で、最初から、実行しなおす（1 回だけ。無限に繰り返さない）
        [[ -z "${SF_INIT_RESTARTED:-}" ]] || die "sf-tools を更新しても、最新になりませんでした。"
        export SF_INIT_RESTARTED=1
        log "INFO" "更新した sf-tools で、もう一度、はじめから実行します。"
        exec bash "${BASH_SOURCE[0]}" "${ORIG_ARGS[@]}"
    fi
    if [[ $phase_rc -ne 0 ]]; then
        # 失敗の三点セット（原因は、直前の表示。直し方は、各 Phase の表示。ここでは、やり直しの方法を、正確に出す）
        if [[ -z "$ONLY_PHASE" && "$phase_num" -ge 3 ]]; then
            wizard_fail "「${WIZ_PHASE_TITLES[$phase_num]}」で、中断しました（上の表示を、確認してください）" \
                "" \
                "もう一度 sf-init.sh を実行し、「続きをやる」を選ぶと、「${WIZ_PHASE_TITLES[$phase_num]}」の最初から、再開します（ここまでの内容は、保存されています）"
        elif [[ -z "$ONLY_PHASE" ]]; then
            # 準備の確認・プロジェクトの確認: 保存された状態がないため、最初から、実行しなおす
            wizard_fail "「${WIZ_PHASE_TITLES[$phase_num]}」で、中断しました（上の表示を、確認してください）" \
                "" \
                "もう一度 sf-init.sh を実行してください（最初から、始まります）"
        fi
        die "「${WIZ_PHASE_TITLES[$phase_num]}」が失敗しました。"
    fi
    # 成功した Phase を記録する（Phase 1 は、状態を持たないため、記録しない。--only は、記録しない）
    if [[ -z "$ONLY_PHASE" && "$phase_num" -ge 2 && -f "$SF_INIT_ENV_FILE" ]]; then
        {
            printf 'SF_INIT_DONE_PHASE=%s\n' "$phase_num"
            printf 'SF_INIT_DONE_AT="%s"\n'  "$(date '+%Y-%m-%d %H:%M')"
        } > "$SF_INIT_PROGRESS_FILE" || die "進捗ファイルを更新できません: ${SF_INIT_PROGRESS_FILE}"
    fi
done

# ------------------------------------------------------------------------------
# 8. 後処理（全フェーズ完了後）
# ------------------------------------------------------------------------------
# .sf-init.env から REPO_DIR などを取得（完了画面・init フォルダ削除の基準に使用）
[[ -f "$SF_INIT_ENV_FILE" ]] && source "$SF_INIT_ENV_FILE"

# 作業用の一時フォルダ（init）の片付け。リポジトリは GitHub に作成済みで、このフォルダは、もう要らない
#   （開発する人は、sf-job.sh で、自分の作業フォルダに、あらためて取得する）
if [[ -n "$REPO_DIR" ]]; then
    INIT_DIR="$(dirname "$REPO_DIR")"   # init フォルダのパス
    cd "$(dirname "$INIT_DIR")" || true
    if [[ -d "$INIT_DIR" ]]; then
        echo "" >&2
        echo "  作業用の一時フォルダ（init）を、片付けます。" >&2
        echo "    ${INIT_DIR}" >&2
        echo "  リポジトリは GitHub に作成済みのため、このフォルダは、もう要りません。" >&2
        read_key answer "  ▶ 削除してよいですか？ [Y=削除する（おすすめ） / N=残す / q=残す]: " "[YyNnQq]"
        if [[ "$answer" == "q" || "$answer" == "Q" ]]; then
            log "INFO" "削除をスキップしました。不要になったら、手動で削除してください: ${INIT_DIR}"
        elif [[ "$answer" =~ ^[Yy]$ ]]; then
            run rm -rf "$INIT_DIR"
            # Windows 環境では rm -rf で空フォルダが残る場合があるため cmd でも試みる
            if [[ -d "$INIT_DIR" ]] && command -v cmd > /dev/null 2>&1; then
                win_path=$(cygpath -w "$INIT_DIR" 2>/dev/null || echo "$INIT_DIR")  # VAR=$(cmd) のため run 不要
                cmd //c "rmdir /s /q \"$win_path\"" 2>/dev/null || true  # 失敗しても続行
            fi
            if [[ -d "$INIT_DIR" ]]; then
                log "WARNING" "init フォルダが残っています。手動で削除してください: rm -rf '${INIT_DIR}'"
            else
                log "SUCCESS" "init フォルダを削除しました。"
            fi
        else
            log "INFO" "削除をスキップしました。不要になったら、手動で削除してください: ${INIT_DIR}"
        fi
    fi
fi

# 完了画面（できたこと / 次にやること）
_org_count=$(( ${BRANCH_COUNT:-1} ))
wizard_done "できました: ${REPO_FULL_NAME:-${GITHUB_OWNER}/force-${COMPANY_NAME}}" \
    "GitHub リポジトリ / Token / Slack 通知 / Salesforce の接続（${_org_count} 組織）" \
    -- \
    "1. 開発を始める人は、次のフォルダで、次のコマンドを実行してください" \
    "     cd ~/home/${GITHUB_OWNER}/${COMPANY_NAME}" \
    "     sf-job.sh" \
    "2. リポジトリを見る:" \
    "     https://github.com/${REPO_FULL_NAME:-${GITHUB_OWNER}/force-${COMPANY_NAME}}"

exit $RET_OK
