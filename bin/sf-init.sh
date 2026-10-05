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
# 【オプション】
#   --resume N            : Phase N から再開（エラー後の再試行に使用）
#   --only N              : Phase N のみ実行（デバッグ・単体テストに使用）
#   --add-tier staging    : 既存プロジェクトに staging tier を追加
#   --add-tier develop    : 既存プロジェクトに develop tier を追加
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

trap '' INT  # Ctrl+C を無効化（子プロセスにも継承される）

# ------------------------------------------------------------------------------
# 3. 引数解析
# ------------------------------------------------------------------------------
ONLY_PHASE=""
RESUME_PHASE=1
ADD_TIER_MODE=""

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
        *)
            die "不明なオプションです: $1
使い方:
  ~/sf-tools/bin/sf-init.sh                       # Phase 1〜10 を順次実行
  ~/sf-tools/bin/sf-init.sh --resume N             # Phase N から最後まで順次実行
  ~/sf-tools/bin/sf-init.sh --only N               # Phase N のみ実行
  ~/sf-tools/bin/sf-init.sh --add-tier staging     # staging tier を追加
  ~/sf-tools/bin/sf-init.sh --add-tier develop     # develop tier を追加"
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

# 実行範囲を決定する
if [[ -n "$ONLY_PHASE" ]]; then
    START_PHASE=$ONLY_PHASE
    END_PHASE=$ONLY_PHASE
else
    START_PHASE=$RESUME_PHASE
    END_PHASE=10
fi

# ------------------------------------------------------------------------------
# 4. タイトル表示・実行ディレクトリの検証（~/home/{owner}/{company}/ であること）
# ------------------------------------------------------------------------------
log "HEADER" "新規 Salesforce プロジェクトの初期セットアップを開始します (${SCRIPT_NAME}.sh)"

echo -e "${CLR_ERR}╔══════════════════════════════════════════════════════╗${CLR_RESET}" >&2
echo -e "${CLR_ERR}║  !!  このコマンドは管理者専用です                    ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║      管理者以外は絶対に実行しないでください          ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║                                                      ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║  新規 Salesforce リポジトリを GitHub に作成し        ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║  初期セットアップを行います。                        ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}╚══════════════════════════════════════════════════════╝${CLR_RESET}" >&2
ask_yn "続行しますか？" || die "中断しました。"

check_home_dir  # GITHUB_OWNER / COMPANY_NAME をセット（失敗時は die）
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

# --resume / --only 時以外は前回の残骸を削除する（空ファイルは作らない）
if [[ "$RESUME_PHASE" -eq 1 && -z "$ONLY_PHASE" ]]; then
    rm -f "$SF_INIT_ENV_FILE"  # 新規実行時は残骸削除のみ（Phase 2 が初回書き出し）
fi

# ------------------------------------------------------------------------------
# 7. メイン実行フロー（フェーズループ）
# ------------------------------------------------------------------------------
log "INFO" "実行フェーズ: Phase ${START_PHASE} 〜 Phase ${END_PHASE}"

for phase_num in $(seq "$START_PHASE" "$END_PHASE"); do
    phase_script=$(ls "${SCRIPT_DIR}/../phases/init/$(printf '%02d' "$phase_num")"_*.sh 2>/dev/null | head -1)
    if [[ -z "$phase_script" ]]; then
        die "Phase ${phase_num} のスクリプトが見つかりません: ${SCRIPT_DIR}/../phases/init/"
    fi
    bash "$phase_script" \
        || die "Phase ${phase_num} が失敗しました。
  再開するには: ~/sf-tools/bin/sf-init.sh --resume ${phase_num}"
done

# ------------------------------------------------------------------------------
# 8. 後処理（全フェーズ完了後）
# ------------------------------------------------------------------------------
# .sf-init.env から REPO_DIR を取得（init フォルダ削除の基準に使用）
[[ -f "$SF_INIT_ENV_FILE" ]] && source "$SF_INIT_ENV_FILE"

echo "-------------------------------------------------------"

# init フォルダごと削除（開発時は別途クローンし直すため）
if [[ -n "$REPO_DIR" ]]; then
    INIT_DIR="$(dirname "$REPO_DIR")"   # init フォルダのパス
    cd "$(dirname "$INIT_DIR")" || true
    if [[ -d "$INIT_DIR" ]]; then
        read_key answer "  ▶ init フォルダ（${INIT_DIR}）を削除してよいですか？ [Y/N/q]: " "[YyNnQq]"
        if [[ "$answer" == "q" || "$answer" == "Q" ]]; then
            log "INFO" "削除をスキップしました。手動で削除してください: ${INIT_DIR}"
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
            log "INFO" "削除をスキップしました。手動で削除してください: ${INIT_DIR}"
        fi
    fi
fi

log "HEADER" "セットアップが完了しました"

exit $RET_OK
