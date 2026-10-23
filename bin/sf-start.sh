#!/bin/bash
# ==============================================================================
# sf-start.sh - 開発環境スタートアップスクリプト
# ==============================================================================
# 開発環境を起動する。Salesforce 組織に接続（未接続ならログイン）し、VS Code を起動したあと、
# sf-install.sh をバックグラウンドで実行し、sf-launcher.sh を前面で起動する。
#
# 【使い方】
#   cd {ジョブフォルダ}/force-XXXX
#   ~/sf-tools/bin/sf-start.sh [-v]
#
# 【オプション】
#   -v, --verbose : run で実行したコマンドの応答（出力）を、コンソールにも表示する
#   -h, --help    : この説明を表示して終了する（第 1 引数のときのみ）
#   引数は、そのまま sf-install.sh に渡す（それ以外の解釈はしない）。
#
# 【処理の流れ】
#   1. sf の確認（check_sf_cli --cache）。sf --version の終了コードが 0 以外なら、案内を表示して中断する。
#      成功したら ~/.sf-tools-sf-check に sf の場所を記録し、同じ場所の sf なら 24 時間は確認を省略する。
#      sf が未インストールのとき・GitHub Actions 上では確認しない
#   2. 接続の確認。環境変数 FORCE_RELOGIN が 1 でなく、.sf/config.json があるときに sf org display --json を実行し、
#      エイリアスが取れ、組織 ID が 00D で始まれば、接続済みとしてログインを省略する
#   3. 未接続（または FORCE_RELOGIN=1）のときのログイン:
#        a. 接続する組織のエイリアスを入力する（空 Enter は再入力。q / EOF で中断）
#        b. sf alias unset vscodeOrg を実行する
#        c. ログイン先を選ぶ: [1] https://login.salesforce.com / [2] https://test.salesforce.com（Enter = 2）/
#           [3] 組織の URL を入力（https で、salesforce.com または force.com 配下）。q で中断。
#           環境変数 SF_INIT_LOGIN_URL_START（login / test / URL）があれば、質問せずにそれを使う
#        d. sf org logout --target-org {エイリアス} を実行する（失敗は無視。既存の同名エイリアスの認証は消える）
#        e. sf org login web --set-default --alias {エイリアス} --instance-url {ログイン先} でブラウザからログインする。
#           WSL で wslview がないときは、powershell.exe でブラウザを開く wslview を /tmp/sf-wsl-bin に作り、PATH の先頭に加える
#        ログインに失敗したら、中断する（終了コード 1。設定ファイルの書き込み・VS Code の起動・ランチャーの起動は、行わない）
#   4. .sf/config.json（{"target-org": エイリアス}）と .sfdx/sfdx-config.json（{"defaultusername": エイリアス}）を
#      上書きする（書き込めなければ中断）。code コマンドがあれば code . で VS Code を起動する（なければ警告のみ）
#   5. ~/sf-tools/bin/sf-install.sh があれば、バックグラウンドで実行する（出力は、このスクリプトのログに追記）。
#      内容: ~/sf-tools の git pull・設定ファイルの確認・Git フック（pre-push）の設置・
#      sf-tools/release/{ブランチ}/ の準備と sf-tools/release/branch_name.txt の更新（main ブランチでは行わない）・
#      npm install（package.json があるとき。node_modules/.package-lock.json が package-lock.json 以降に更新済みなら省略）・開発ツールの更新（sf-upgrade.sh。24 時間に 1 回）。詳細は sf-install.sh の冒頭コメント
#   6. ~/sf-tools/bin/sf-launcher.sh があり、環境変数 SF_LAUNCHER_ACTIVE が 1 でなければ、前面で起動する
#      （sf-launcher.sh から呼ばれたときは、二重に起動しない）
#
# 【前提条件】
#   - force-* フォルダ（カレントフォルダの名前が force- で始まる）で実行する。違えばエラーで終了する
#     （sf-job.sh から呼ばれたときは、この確認を省略する）
#   - Salesforce CLI（sf）は npm 版であること（公式インストーラー版は、Windows の Git Bash で、成功しても終了コード 1 を返すため）
#
# 【補足】
#   - Ctrl+C は無効（1 の確認のあとから）。入力時に q で中断する。中断・失敗時の終了コードは 1
#   - 終了コードは、sf-launcher.sh の終了コードによらず 0。バックグラウンドの sf-install.sh の失敗も、終了コードに影響しない
#   - 接続済みの組織を切り替えるときは sf-restart.sh を使う
#   - ログ: ./sf-tools/logs/sf-start.log（実行のたびに作り直す）。終了時に ./sf-tools/cmd_out_*.tmp と /tmp/sf-wsl-bin を削除する
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
source "${SCRIPT_DIR}/../lib/org.sh"   # ログイン先の選択（エイリアスの名前では、決めない）

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
    # エイリアスと組織 ID を、1 回で取る（JSON として読み取れなければ、どちらも空 = 未接続として扱う）
    _disp_vals=$(json_get "$DISPLAY_JSON" result.alias result.id) || _disp_vals=""  # VAR=$(cmd) のため run 不使用
    # 1 行を 1 要素にする（mapfile は Bash 4 以降のため使わない）
    _disp_v=()
    while IFS= read -r _disp_line; do _disp_v+=("$_disp_line"); done <<< "$_disp_vals"
    CURRENT_ALIAS="${_disp_v[0]:-}"
    CURRENT_ID="${_disp_v[1]:-}"

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
        read_input ORG_ALIAS "${CLR_PROMPT}接続する組織のエイリアスを入力してください [q で中断]: ${CLR_RESET}" || die "入力が中断されました。"  # EOF → 中断（空の再入力を、無限に繰り返さない）
        [[ "$ORG_ALIAS" == "q" || "$ORG_ALIAS" == "Q" ]] && die "中断しました。"
        [[ -n "$ORG_ALIAS" ]] && break
        # 空 Enter → 行を戻してクリアし再プロンプト
        printf "\033[A\r\033[K" >&2
    done

    # VS Code が参照する古いエイリアス設定をクリア
    run sf alias unset vscodeOrg --json

    # ログイン先は、エイリアスの名前では、決めない（Developer Edition や、別名の本番も、あるため）。
    #   種類ではなく、ログイン先の URL を選ぶ（Enter = Sandbox）。環境変数 SF_INIT_LOGIN_URL_START（login / test / URL）で、指定もできる
    org_choose_login_url LOGIN_URL "組織 ${ORG_ALIAS}" "main" "START"

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
    # 失敗したら、中断する（以前は、警告だけで先へ進み、「接続完了」と表示して、設定ファイルも書いていた）
    sf org login web --set-default --alias "$ORG_ALIAS" --instance-url "$LOGIN_URL" \
        || die "Salesforce へのログインに失敗しました（エイリアス: ${ORG_ALIAS}）。"
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
# ランチャーから（Start / Restart で）呼ばれた場合は二重起動しない（SF_LAUNCHER_ACTIVE=1 はランチャーが export する）
if [[ -f "$HOME/sf-tools/bin/sf-launcher.sh" ]] && [[ "${SF_LAUNCHER_ACTIVE:-}" != "1" ]]; then
    bash "$HOME/sf-tools/bin/sf-launcher.sh"
fi

exit $RET_OK
