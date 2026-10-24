#!/bin/bash
# ==============================================================================
# sf-restart.sh - 接続組織の切り替えスクリプト
# ==============================================================================
# 接続する Salesforce 組織を切り替える。ローカルの接続設定ファイルを削除し、環境変数 FORCE_RELOGIN=1 を付けて
# sf-start.sh を実行する（接続済みでも、エイリアスの入力とログインからやり直す）。
#
# 【使い方】
#   cd {ジョブフォルダ}/force-XXXX
#   ~/sf-tools/bin/sf-restart.sh [-v]
#
# 【オプション】
#   -v, --verbose : run で実行したコマンドの応答（出力）を、コンソールにも表示する
#   -h, --help    : この説明を表示して終了する（第 1 引数のときのみ）
#   上記以外の引数は、「不明なオプションです」と表示して中断する。-v は、sf-start.sh にも渡す。
#
# 【処理の流れ】
#   1. このスクリプトと同じフォルダの sf-start.sh があるかを確認する（なければ、何も削除せずに中断）
#   2. .sf/config.json と .sfdx/sfdx-config.json を、一時フォルダに退避してから、確認なしで削除する
#   3. sf-start.sh を、FORCE_RELOGIN=1 で実行する。
#      以降の動き（エイリアスの入力・ログイン先の選択・ログイン・VS Code の起動など）は sf-start.sh の冒頭コメントを参照
#   4. sf-start.sh が失敗したとき（ログインの失敗・入力の中断など）で、新しい設定ファイルが書かれていなければ、
#      退避した元の設定ファイルを戻す（戻したときは、WARNING を表示する）。退避した一時フォルダは、終了時に削除する
#
# 【前提条件】
#   - force-* フォルダ（カレントフォルダの名前が force- で始まる）で実行する。違えばエラーで終了する
#
# 【補足】
#   - 2 の削除は、sf-start.sh が成功したときは、そのまま（新しい設定ファイルに置き換わる）。失敗したときは、4 で元に戻す
#   - 終了コードは sf-start.sh の終了コード
#   - ログ: ./sf-tools/logs/sf-restart.log（実行のたびに作り直す）
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 共通ライブラリの必須設定
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME=$(basename "$0" .sh)
readonly LOG_FILE="./sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"


# ------------------------------------------------------------------------------
# 2. 共通ライブラリの読み込み
# ------------------------------------------------------------------------------
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
reject_unknown_args "$@"   # -v / --verbose 以外の引数は、不明なオプションとして中断する

# ------------------------------------------------------------------------------
# 3. 初期チェック
# ------------------------------------------------------------------------------
log "HEADER" "接続組織の切り替え（Switch）を開始します (${SCRIPT_NAME}.sh)"

# ------------------------------------------------------------------------------
# 4. ローカルの接続設定をクリア
# ------------------------------------------------------------------------------
# .sf/config.json と .sfdx/sfdx-config.json を削除することで、
# sf-start.sh 内の「接続済み自動スキップ」を無効化する。
# sf-start.sh が失敗した（ログインの失敗・入力の中断など）ときに、設定ファイルがない状態のまま終わらないよう、
# 削除する前に退避しておき、失敗したら戻す（以前は、戻さなかった）
[ -f "$SCRIPT_DIR/sf-start.sh" ] || die "sf-start.sh が見つかりません: $SCRIPT_DIR/sf-start.sh"

BACKUP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sf-restart-XXXXXX") || die "退避用の一時フォルダを作成できません。"  # VAR=$(cmd) のため run 不使用
trap 'rm -rf "$BACKUP_DIR"' EXIT
[ -f .sf/config.json ] && cp .sf/config.json "$BACKUP_DIR/sf-config.json"                 # run 不使用: 退避（なければ何もしない）
[ -f .sfdx/sfdx-config.json ] && cp .sfdx/sfdx-config.json "$BACKUP_DIR/sfdx-config.json" # run 不使用: 同上

log "INFO" "現在のローカル接続設定をクリアしています..."
run rm -f .sf/config.json .sfdx/sfdx-config.json

# ------------------------------------------------------------------------------
# 5. 強制再ログインフラグを立てて sf-start.sh を呼び出す
# ------------------------------------------------------------------------------
FORCE_RELOGIN=1 bash "$SCRIPT_DIR/sf-start.sh" "$@"
RESTART_RC=$?

if [ "$RESTART_RC" -ne 0 ]; then
    # 失敗したときは、sf-start.sh が新しい設定を書けていなければ、元の設定を戻す
    RESTORED=0
    if [ ! -f .sf/config.json ] && [ -f "$BACKUP_DIR/sf-config.json" ]; then
        mkdir -p .sf && cp "$BACKUP_DIR/sf-config.json" .sf/config.json && RESTORED=1                 # run 不使用: 復元
    fi
    if [ ! -f .sfdx/sfdx-config.json ] && [ -f "$BACKUP_DIR/sfdx-config.json" ]; then
        mkdir -p .sfdx && cp "$BACKUP_DIR/sfdx-config.json" .sfdx/sfdx-config.json && RESTORED=1       # run 不使用: 復元
    fi
    [ "$RESTORED" -eq 1 ] && log "WARNING" "sf-start.sh が失敗したため、元の接続設定（.sf/config.json・.sfdx/sfdx-config.json）を戻しました。"
fi
exit $RESTART_RC
