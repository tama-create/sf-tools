#!/bin/bash
# ==============================================================================
# sf-hook.sh - Git フックのインストールスクリプト
# ==============================================================================
# ~/sf-tools/hooks/ の pre-commit / pre-push（呼び出し用のラッパー）を、カレントプロジェクトの
# .git/hooks/ へコピーし、実行権限を付ける。
#
# 【使い方】
#   sf-hook.sh [オプション]
#
# 【オプション】
#   -v, --verbose       : コマンドの応答（出力）をコンソールにも表示する
#   -h, --help          : このヘルプを表示して終了する（1 番目の引数のときだけ）
#   引数の解析はしない。上記以外の引数（2 番目以降の -h / --help を含む）は無視し、インストールを実行する。
#
# 【処理の流れ】
#   1. カレントディレクトリに .git ディレクトリがなければ中断する。
#   2. git config --local core.hooksPath の値に「husky」が含まれていれば、確認なしに --unset で削除する。
#   3. ~/sf-tools/hooks/pre-commit を .git/hooks/pre-commit へコピーし（既存のファイルは確認・バックアップなしに
#      上書き）、chmod +x する。コピー元がなければ中断する。
#   4. ~/sf-tools/hooks/pre-push を .git/hooks/pre-push へ、同じ方法でコピーし、chmod +x する。
#
# 【前提条件】
#   - force-* ディレクトリで、かつ Git リポジトリのルート（.git ディレクトリがある場所）で実行すること。
#   - コピー元は $HOME/sf-tools/hooks/ に固定（このスクリプトの場所ではない）。
#
# 【補足】
#   - インストールされるフック:
#       pre-commit : ~/sf-tools/bin/sf-precommit.sh --verbose を呼ぶ。sf-check.sh でターゲットファイルを検査し、
#                    エラーならコミットを中止する。
#       pre-push   : ~/sf-tools/bin/sf-prepush.sh --verbose を呼ぶ。branches.txt のブランチへの直接プッシュの禁止、
#                    sf-check.sh による構文検査、origin の自ブランチと main の取り込み（git merge）を行う。
#                    Salesforce 組織への検証（dry-run）は行わない。詳細は sf-prepush.sh --help。
#   - コピーされるフックは、$HOME/sf-tools/bin/ のスクリプトを呼ぶだけのラッパー。bin/ の sf-precommit.sh・
#     sf-prepush.sh の更新は、全プロジェクトに即時反映される。ラッパー（hooks/ のファイル）自体の変更は、
#     各プロジェクトで sf-hook.sh を再実行するまで反映されない。
#   - 削除は sf-unhook.sh（pre-push だけを削除する。pre-commit は残る）。
#   - 終了コード: 成功は 0。中断は 1。
#   - ログ: ./sf-tools/logs/sf-hook.log（実行のたびに作り直す）
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
# 3. 定数定義
# ------------------------------------------------------------------------------
# インストール先: カレントプロジェクトの Git フックディレクトリ
readonly HOOK_DEST_PRECOMMIT=".git/hooks/pre-commit"
readonly HOOK_DEST=".git/hooks/pre-push"

# SF_HOOK_MARKER は lib/common.sh で定義済み

# ------------------------------------------------------------------------------
# 4. フェーズ定義
# ------------------------------------------------------------------------------

# 【CHECK】実行環境の検証
phase_check_environment() {
    log "INFO" "実行環境を確認中..."

    # Git リポジトリのルートであることを確認
    if [[ ! -d ".git" ]]; then
        die "Gitリポジトリのルートで実行してください（.git ディレクトリが見つかりません）。"
    fi

    return $RET_OK
}

# 【FIX】hooksPath が .husky 系に設定されていれば削除
phase_fix_hooks_path() {
    local hooks_path
    hooks_path=$(run git config --local core.hooksPath 2>/dev/null || true)
    if [[ "$hooks_path" == *husky* ]]; then
        log "WARNING" "core.hooksPath が '$hooks_path' に設定されています。削除します..."
        run git config --local --unset core.hooksPath \
            || die "core.hooksPath の削除に失敗しました。"
        log "SUCCESS" "core.hooksPath を削除しました。"
    fi
    return $RET_OK
}

# 【INSTALL】pre-commit フックのコピーと権限付与
phase_install_precommit_hook() {
    log "INFO" "pre-commit フックをコピー（強制上書き）中..."

    local hook_src="$HOME/sf-tools/hooks/pre-commit"

    if [[ ! -f "$hook_src" ]]; then
        die "コピー元のフックスクリプトが見つかりません: $hook_src"
    fi

    run mkdir -p "$(dirname "$HOOK_DEST_PRECOMMIT")" || return $RET_NG
    run cp "$hook_src" "$HOOK_DEST_PRECOMMIT" || return $RET_NG
    run chmod +x "$HOOK_DEST_PRECOMMIT" || return $RET_NG
    return $RET_OK
}

# 【INSTALL】pre-push フックのコピーと権限付与
phase_install_hook() {
    log "INFO" "pre-push フックをコピー（強制上書き）中..."

    local hook_src="$HOME/sf-tools/hooks/pre-push"

    if [[ ! -f "$hook_src" ]]; then
        die "コピー元のフックスクリプトが見つかりません: $hook_src"
    fi

    run mkdir -p "$(dirname "$HOOK_DEST")" || return $RET_NG
    run cp "$hook_src" "$HOOK_DEST" || return $RET_NG
    run chmod +x "$HOOK_DEST" || return $RET_NG
    return $RET_OK
}

# ------------------------------------------------------------------------------
# 5. メイン実行フロー
# ------------------------------------------------------------------------------
log "HEADER" "Git Hook (pre-commit / pre-push) の有効化を開始します (${SCRIPT_NAME}.sh)"

phase_check_environment || die "初期チェックに失敗しました。"
log "SUCCESS" "環境確認完了。"

phase_fix_hooks_path || die "hooksPath の修正に失敗しました。"

phase_install_precommit_hook || die "pre-commit フックのインストールに失敗しました。"
log "SUCCESS" "pre-commit フックを強制適用しました。"

phase_install_hook || die "pre-push フックのインストールに失敗しました。"
log "SUCCESS" "pre-push フックを強制適用しました。"

echo "--------------------------------------------------------"
log "INFO" "次回以降の git commit / push 時に自動的に検証が実行されます。"
log "HEADER" "セットアップが完了しました"

exit $RET_OK
