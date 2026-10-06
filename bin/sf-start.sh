#!/bin/bash
# ==============================================================================
# sf-start.sh - 開発環境スタートアップスクリプト
# ==============================================================================
# ワンコマンドで開発環境を整えます。
#   1. Salesforce 組織への接続確認・ログイン
#   2. VS Code 設定の同期と起動
#   ↓ VS Code 起動後にバックグラウンドで実行
#   3. sf-tools 自動更新 & Git フック有効化
#   4. リリース管理ディレクトリの準備
#   5. 現在のブランチ名を sf-tools/release/branch_name.txt に保存
#   6. sf-launcher.sh を起動
#
# 【前提】
#   Salesforce CLI（sf）は npm 版であること。起動時に check_sf_cli（sf --version の終了コード）で確認し、
#   0 以外なら、案内を表示して中断する。成功は 24 時間は確認を省略する。
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
# 3. 初期チェック
# ------------------------------------------------------------------------------
log "HEADER" "開発タスクのスタートアップを開始します (${SCRIPT_NAME}.sh)"

# sf が終了コードを正しく返すか確認する（npm 版が前提。異常なら中断する）。成功は 24 時間は確認を省略する
check_sf_cli --cache

trap '' INT  # Ctrl+C を無効化（q で中断すること）
trap 'rm -f ./sf-tools/cmd_out_*.tmp 2>/dev/null; rm -rf /tmp/sf-wsl-bin 2>/dev/null' EXIT

# ------------------------------------------------------------------------------
# 4. Salesforce 接続確認・ログイン
# ------------------------------------------------------------------------------
log "INFO" "Salesforce 接続確認中..."
SKIP_LOGIN=0

# パターンA: 接続済みの場合はログインをスキップ
#   FORCE_RELOGIN=1（sf-restart.sh 経由）の場合はこのブロックを飛ばして強制ログイン
#   .sf/config.json が存在しない場合はプロジェクト初回起動とみなし、強制的にエイリアス入力へ
if [ "$FORCE_RELOGIN" != "1" ] && [ -f ".sf/config.json" ]; then
    DISPLAY_JSON=$(run sf org display --json || echo "")
    CURRENT_ALIAS=$(echo "$DISPLAY_JSON" | grep '"alias"' | head -n 1 | cut -d '"' -f 4 | tr -d '\r')
    CURRENT_ID=$(echo "$DISPLAY_JSON"    | grep '"id"'    | head -n 1 | cut -d '"' -f 4 | tr -d '\r')

    # エイリアスと本番/Sandbox 組織ID（00D始まり）が取得できた場合は接続済みと判断
    if [ -n "$CURRENT_ALIAS" ] && [ "$CURRENT_ALIAS" != "null" ] && [[ "$CURRENT_ID" == 00D* ]]; then
        log "INFO" "組織 (${CURRENT_ALIAS}) に接続済みです。"
        ORG_ALIAS="$CURRENT_ALIAS"
        SKIP_LOGIN=1
    fi
fi

# パターンB: 未接続 または 強制再ログイン
if [ "$SKIP_LOGIN" -eq 0 ]; then
    while true; do
        read_input ORG_ALIAS "${CLR_PROMPT}接続する組織のエイリアスを入力してください [q で中断]: ${CLR_RESET}"
        [[ "$ORG_ALIAS" == "q" || "$ORG_ALIAS" == "Q" ]] && die "中断しました。"
        [[ -n "$ORG_ALIAS" ]] && break
        # 空 Enter → 行を戻してクリアし再プロンプト
        printf "\033[A\r\033[K" >&2
    done

    # VS Code が参照する古いエイリアス設定をクリア
    run sf alias unset vscodeOrg --json

    # prod → 本番ログイン URL、それ以外 → Sandbox ログイン URL
    LOGIN_URL="https://test.salesforce.com"
    [[ "$ORG_ALIAS" == "prod" ]] && LOGIN_URL="https://login.salesforce.com"

    log "INFO" "ブラウザでログインして接続を許可してください..."
    run sf org logout --target-org "$ORG_ALIAS" --no-prompt 2>/dev/null || true

    # WSL: sf org login web 内部の open パッケージが wslview を探すため、
    #       未インストール時は powershell.exe でブラウザを開く wslview を一時補完する
    if grep -qi microsoft /proc/version 2>/dev/null && ! command -v wslview &>/dev/null; then
        mkdir -p /tmp/sf-wsl-bin          # run 不使用: PATH export 前のシェル設定操作
        printf '#!/bin/bash\npowershell.exe Start-Process "$1" 2>/dev/null\n' \
            > /tmp/sf-wsl-bin/wslview
        chmod +x /tmp/sf-wsl-bin/wslview  # run 不使用: 同上
        export PATH="/tmp/sf-wsl-bin:$PATH"
    fi

    # ブラウザ起動に TTY が必要なため run ラッパーを使用しない
    sf org login web --set-default --alias "$ORG_ALIAS" --instance-url "$LOGIN_URL" \
        || log "WARNING" "ログインに失敗した可能性があります。接続が確立されていない場合は再実行してください。"
    log "SUCCESS" "接続完了！"
fi

log "SUCCESS" "Salesforce に接続しました"

# ------------------------------------------------------------------------------
# 5. VS Code 設定の同期と起動
# ------------------------------------------------------------------------------
log "INFO" "VS Code を起動中..."

# VS Code の Salesforce 拡張が参照する設定ファイル (.sf/config.json, .sfdx/sfdx-config.json) を更新
run mkdir -p .sfdx .sf || die "設定ディレクトリの作成に失敗しました。"
printf '{"target-org": "%s"}\n'      "$ORG_ALIAS" | run tee .sf/config.json        || die "設定ファイル (.sf/config.json) の書き込みに失敗しました。"
printf '{"defaultusername": "%s"}\n' "$ORG_ALIAS" | run tee .sfdx/sfdx-config.json || die "設定ファイル (.sfdx/sfdx-config.json) の書き込みに失敗しました。"
# sf config set は .sf/config.json の tee 書き込みで代替済みのため不要

if command -v code >/dev/null 2>&1; then
    run code .
    log "SUCCESS" "VS Code を起動しました。"
else
    log "WARNING" "'code' コマンドが見つかりません。VS Code を手動で起動してください。"
fi

# ------------------------------------------------------------------------------
# 6. バックグラウンド処理（VS Code 起動後に実行）
# ------------------------------------------------------------------------------
# sf-install.sh が以下をすべて担当する（GitHub Actions ワークフローの更新は、担当しない。管理者が sf-sync-wf.sh で手動で行う）:
#   - sf-tools 最新化 (git pull)
#   - Git フック (pre-push) インストール
#   - リリース管理ディレクトリ準備 & branch_name.txt 更新
#   - npm install / sf-upgrade.sh (24h スロットル)
log "INFO" "バックグラウンドで sf-install.sh を実行中..."
log "INFO" "  完了後に sf-tools/release/<branch>/ が準備されます（npm install を含む場合は数分かかります）"
(
    if [ -f "$HOME/sf-tools/bin/sf-install.sh" ]; then
        bash "$HOME/sf-tools/bin/sf-install.sh" "$@" 2>&1 \
            || true
    fi
) >> "$LOG_FILE" 2>&1 &
disown   # ジョブ完了通知をターミナルに表示しない

# ------------------------------------------------------------------------------
# 7. ランチャ起動
# ------------------------------------------------------------------------------
# ランチャーから Restart 経由で呼ばれた場合は二重起動しない
if [[ -f "$HOME/sf-tools/bin/sf-launcher.sh" ]] && [[ "${SF_LAUNCHER_ACTIVE:-}" != "1" ]]; then
    bash "$HOME/sf-tools/bin/sf-launcher.sh"
fi

exit $RET_OK
