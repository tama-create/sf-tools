#!/bin/bash
# ==============================================================================
# sf-hook.sh - Git フックのインストールスクリプト
# ==============================================================================
# pre-commit / pre-push フックをカレントプロジェクトの .git/hooks/ にインストール。
#
# 【インストールされるフック】
#   pre-commit : コミット前に sf-check.sh でターゲットファイルを検証
#   pre-push   : プッシュ前に Salesforce 組織への検証(dry-run)を実行
#
# 生成されるフックは ~/sf-tools/hooks/ 配下の呼び出しラッパーです。
# sf-tools 本体を更新するだけで、全プロジェクトのフック動作に即時反映されます。
#
# 【オプション】
#   -v, --verbose       : コマンドの応答（出力）をコンソールにも表示します
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
