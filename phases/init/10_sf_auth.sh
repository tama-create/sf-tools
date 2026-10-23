#!/bin/bash
# ==============================================================================
# 10_sf_auth.sh - Phase 10: JWT 認証情報の設定
# ==============================================================================
# JWT（OAuth 2.0 JWT Bearer Flow）方式で、Salesforce 組織への認証情報を GitHub の Secrets / Variables に登録する。
#
# 【使い方】
#   sf-init.sh が、管理者用の作業フォルダ（admin）をカレントにして、bash で呼び出す。
#
# 【処理の流れ】
#   1.   JWT 用の秘密鍵・証明書（~/.sf-jwt/<REPO_NAME>/server.key・server.crt）を用意する
#          - 両方あるとき: ask_yn で再利用するかを確認する
#              Y: そのまま使う（証明書の発行先（subject）が空なら、秘密鍵はそのままで、証明書だけを作り直す）
#              N: 両方を削除して、generate_jwt_cert で新しく作る（秘密鍵も変わる）。手順 4 の「前回完了済み」のスキップは、
#                 この実行ではしない（古い証明書が残る組織が出ないように、完了済みの段階も、設定しなおす）
#              q: die
#          - どちらかがないとき: generate_jwt_cert で作る（RSA 2048 ビット・PKCS#1、自己署名 3650 日、CN=sf-jwt-<REPO_NAME>）
#   1.5. アプリの種類（APP_TYPE）を決める（利用者には聞かない）
#          - 状態ファイルに APP_TYPE があるとき: その値を使う。ただし SF_INIT_LEGACY_CONNECTED_APP=1
#            （sf-init.sh --legacy-connected-app）で、APP_TYPE が 1 以外なら die。
#            APP_TYPE=1 が保存済みで、SF_INIT_LEGACY_CONNECTED_APP=1 の指定がないときは、1 のまま使う
#          - ないとき: SF_INIT_LEGACY_CONNECTED_APP=1 なら 1（接続アプリケーション）、それ以外は 2（外部クライアント
#            アプリケーション）とし、状態ファイルに追記する
#   2.   APP_TYPE=1: 接続アプリケーションの設定手順を表示し、Enter を待つ（q は die）。
#        APP_TYPE=2: 自動で作成する旨を表示するだけ
#   3.   server.key（CR を除去）を base64 の 1 行にして、Secret SF_PRIVATE_KEY に登録する（毎回上書き。失敗は die）
#   4.   段階ごとに登録する: メイン組織（PROD）は常に、ステージング組織（STG）は BRANCH_COUNT が 2 以上、
#        開発組織（DEV）は 3 以上のとき
#          - 次の 3 つを満たす段階は、スキップする（前回完了済み）
#              ・SF_INIT_TIER_RESUME=1（sf-init.sh が、--only 以外のときに export する）
#              ・進捗ファイル（SF_INIT_PROGRESS_FILE）に SF_INIT_DONE_TIER_<接尾辞>=1 がある
#              ・gh secret list に SF_CONSUMER_KEY_<接尾辞> がある（一覧を取得できなければ、スキップしない）
#          - APP_TYPE=1: register_jwt_secret（init-common.sh。コンシューマー鍵・ユーザー名を手動で入力）
#            APP_TYPE=2: register_jwt_secret_eca（init-common.sh。ブラウザでログインし、外部クライアントアプリを
#            deploy で作成して、コンシューマー鍵を retrieve で取得する）
#          - 成功したら、SF_INIT_TIER_RESUME=1 のときだけ、進捗ファイルに SF_INIT_DONE_TIER_<接尾辞>=1 を追記する
#
# 【前提条件】
#   - Phase 2 が書き出した状態ファイル（REPO_FULL_NAME・REPO_NAME。空なら die）。BRANCH_COUNT（Phase 5）が
#     ないときは 1 として扱う
#   - 環境変数 SF_TOOLS_DIR（sf-tools のルート。sf-init.sh が export する）
#   - openssl・sf（npm 版）・gh
#
# 【補足】
#   - 登録する Secrets: SF_PRIVATE_KEY（全段階で共通）/ SF_CONSUMER_KEY_PROD・_STG・_DEV
#   - 登録する Variables: SF_USERNAME_PROD・_STG・_DEV / SF_INSTANCE_URL_PROD・_STG・_DEV /
#     SF_ORG_ID_*・SF_ORG_NAME_*・SF_ORG_KIND_*・SF_ORG_CHECKED_*（組織の ID・名前・種類・確認日時。
#     sf-init.sh --status の表示用。組織の情報を読み取れたときだけ登録する）
#   - ログイン先は、組織の種類ではなく URL で選ぶ（3 択: login.salesforce.com / test.salesforce.com / 組織の URL。
#     Enter は test.salesforce.com）。環境変数 SF_INIT_LOGIN_URL_<接尾辞>（login / test / URL）があれば、質問しない
#   - 段階と組織の種類は結びつけない。ただし、Salesforce の本番組織は main にしかつなげない（org_guard）。
#     種類を判定できない組織も、main 以外にはつなげない。APP_TYPE=2 は deploy の前に、APP_TYPE=1 は JWT 接続テストの
#     あと・登録の前に判定する
#   - JWT 接続テストに失敗したときは、ask_yn で「テストをスキップして登録だけ行う」かを選べる（Y で登録、N / q は die）
#   - 手順 1 で N を選んで鍵を作り直したときは、手順 4 の「前回完了済み」のスキップをしない（SF_INIT_TIER_RESUME=0 にする）。
#     完了済みの段階も、設定しなおす（Secret SF_PRIVATE_KEY は新しい秘密鍵に置き換わるため、組織のアプリに以前の証明書が
#     残ると、JWT 接続ができなくなる）
#   - 進捗ファイルは、sf-init.sh が Phase の成功ごとに上書きする（Phase 10 が成功すると、段階の記録は消える）
#   - 証明書（server.crt）は、APP_TYPE=1 では利用者が各組織へアップロードし、APP_TYPE=2 では deploy で登録する
#   - 接続アプリケーションの注意:
#       ・作成した接続アプリケーションを「外部クライアントアプリへの移行」または「削除」しないこと。
#         OAuth の内部状態が壊れ、client_identifier_invalid エラーが発生する。
#         問題が起きた場合は、同じアプリを修正せず、別名で新規作成すること
#       ・Developer Edition 組織では、事前承認（pre-authorization）の反映が遅れる・失敗する場合がある。
#         JWT Bearer Flow は Production / Sandbox 組織での使用を推奨する
# ==============================================================================

# SF_TOOLS_DIR は sf-init.sh（司令塔）から export される
PHASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_TOOLS_DIR="${SF_TOOLS_DIR:-$(dirname "$(dirname "$PHASE_DIR")")}"

readonly SCRIPT_NAME="sf-init"
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true
readonly LOG_FILE="$HOME/sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="APPEND"  # 司令塔が NEW で初期化済みのため追記
export SF_INIT_MODE=1

source "${SF_TOOLS_DIR}/lib/common.sh"
source "${SF_TOOLS_DIR}/phases/init/init-common.sh"

# 変数の復元（前フェーズで書き出した .sf-init.env を読み込む）
SF_INIT_ENV_FILE="${SF_INIT_ENV_FILE:-${PWD}/.sf-init.env}"
[[ -f "$SF_INIT_ENV_FILE" ]] && source "$SF_INIT_ENV_FILE"

[[ -z "$REPO_FULL_NAME" ]] && die "REPO_FULL_NAME が未設定です。Phase 2 が完了しているか確認してください。"
[[ -z "$REPO_NAME" ]]      && die "REPO_NAME が未設定です。Phase 2 が完了しているか確認してください。"
BRANCH_COUNT="${BRANCH_COUNT:-1}"

# JWT 証明書の保存先
JWT_DIR="$HOME/.sf-jwt/${REPO_NAME}"

# ------------------------------------------------------------------------------
# Step 2 案内文: 接続アプリケーション（Connected App）
# ------------------------------------------------------------------------------
_show_connected_app_guide() {
    log "HEADER" "Salesforce 接続アプリケーション を設定してください。"
    log "INFO" ""
    log "INFO" "  ▼ アップロードする証明書ファイル（server.crt）のパス:"
    log "INFO" "    ${JWT_DIR}/server.crt"
    log "INFO" ""
    log "INFO" "  ╔══════════════════════════════════════════════════╗"
    log "INFO" "  ║  STEP A: 接続アプリケーションを作成する          ║"
    log "INFO" "  ╚══════════════════════════════════════════════════╝"
    log "INFO" "  1. 設定の検索窓に「アプリケーションマネージャ」と入力 → 「新規接続アプリケーション」"
    log "INFO" "  2. 基本情報を入力（アプリケーション名: SF_TOOLS・API 参照名: SF_TOOLS・連絡先メール: 任意）"
    log "INFO" "  3. 「OAuth 設定の有効化」にチェック"
    log "INFO" "     コールバック URL: https://login.salesforce.com/services/oauth2/callback"
    log "INFO" "  4. 「選択した OAuth 範囲」に以下を追加"
    log "INFO" "     ・フルアクセス (full)"
    log "INFO" "     ・いつでも要求を実行 (refresh_token, offline_access)"
    log "INFO" "  5. 「デジタル署名を使用」にチェック → 上記の server.crt をアップロード"
    log "INFO" "  6. 保存 → 次へ → [コンシューマーの詳細管理] をクリック → 「コンシューマー鍵」をコピー"
    log "INFO" ""
    log "INFO" "  ★ 保存後 2〜10 分待ってから STEP B へ進んでください ★"
    log "INFO" ""
    log "INFO" "  ╔══════════════════════════════════════════════════╗"
    log "INFO" "  ║  STEP B: 管理画面でポリシーを設定する            ║"
    log "INFO" "  ╚══════════════════════════════════════════════════╝"
    log "INFO" "  設定の検索窓に「接続アプリケーションを管理」と入力 → 作成したアプリ（SF_TOOLS）をクリック"
    log "INFO" "  ・「ポリシーを編集」→「許可されているユーザー」→「管理者が承認したユーザーは事前承認済み」→ 保存"
    log "INFO" "  ・「プロファイルを管理する」→ 接続ユーザーのプロファイル（例: システム管理者）を追加"
    log "INFO" ""
    press_enter "設定が完了したら Enter を押してください（q で中断）"
}

# ------------------------------------------------------------------------------
# メイン処理
# ------------------------------------------------------------------------------
log "HEADER" "JWT 認証情報の設定"

# --------------------------------------------------------------------------
# Step 1: 証明書の生成
# --------------------------------------------------------------------------
log "HEADER" "JWT 用証明書を生成します。"

if [[ -f "${JWT_DIR}/server.key" && -f "${JWT_DIR}/server.crt" ]]; then
    log "INFO" "既存の証明書が見つかりました: ${JWT_DIR}/"
    if ask_yn "  既存の証明書を再利用しますか？（N を選ぶと再生成します）"; then
        log "INFO" "  既存の証明書を使用します。"
        # 以前の sf-tools は、Mac・Linux で、発行先が空の証明書を作っていた。空なら、秘密鍵はそのままで、証明書だけを作り直す
        ensure_jwt_cert_subject "$JWT_DIR" "$REPO_NAME"
    else
        # N を選んだ場合は既存ファイルを削除してから再生成
        # （削除しないと generate_jwt_cert 内のスキップ判定に引っかかるため）
        rm -f "${JWT_DIR}/server.key" "${JWT_DIR}/server.crt"
        generate_jwt_cert "$JWT_DIR" "$REPO_NAME"
        # 秘密鍵が新しくなる（Step 3 で SF_PRIVATE_KEY が置き換わる）。前回完了した段階をスキップすると、その段階の組織の
        # アプリには以前の証明書が残り、新しい秘密鍵と合わなくなる。すべての段階を設定しなおす（_tier_done は、この値を見る）
        if [[ "${SF_INIT_TIER_RESUME:-}" == "1" ]]; then
            SF_INIT_TIER_RESUME=0
            log "INFO" "  証明書を作り直したため、前回、設定が完了した段階も、設定しなおします。"
        fi
    fi
else
    generate_jwt_cert "$JWT_DIR" "$REPO_NAME"
fi

# --------------------------------------------------------------------------
# Step 1.5: アプリ種別の選択
# --------------------------------------------------------------------------
log "HEADER" "Salesforce アプリの種類"

# アプリ種別は、利用者に聞かない（利用者は判断できないため）。
#   既定: 外部クライアントアプリケーション（[2] Salesforce 推奨の新方式。自動で作成する）
#   従来の接続アプリケーション（[1] 今後廃止予定）は、`sf-init.sh --legacy-connected-app`（環境変数
#   SF_INIT_LEGACY_CONNECTED_APP=1）を指定したときだけ
#   --resume 時は、.sf-init.env に保存済みの種別を再利用する。--legacy-connected-app の指定があり、保存済みの種別が
#   1 以外のときだけ、中断する（保存済みが 1 で、指定がないときは、1 のまま使う）
want_type="2"
[[ "${SF_INIT_LEGACY_CONNECTED_APP:-}" == "1" ]] && want_type="1"
if [[ -n "${APP_TYPE:-}" ]]; then
    if [[ "${SF_INIT_LEGACY_CONNECTED_APP:-}" == "1" && "$APP_TYPE" != "1" ]]; then
        die "--legacy-connected-app が指定されましたが、このプロジェクトは、外部クライアントアプリ（APP_TYPE=${APP_TYPE}）で、設定を始めています。"
    fi
    log "INFO" "  前回選択済みの種別を使用します: [${APP_TYPE}]"
else
    APP_TYPE="$want_type"
    # .sf-init.env に書き出して --resume 時に再利用
    echo "APP_TYPE=${APP_TYPE}" >> "$SF_INIT_ENV_FILE"
fi

case "$APP_TYPE" in
    1) log "INFO" "  → 接続アプリケーション（Connected App）を使用します。" ;;
    2) log "INFO" "  → 外部クライアントアプリケーション（External Client App）を使用します。" ;;
    *) die "無効な選択です: ${APP_TYPE}" ;;
esac

# --------------------------------------------------------------------------
# Step 2: アプリ種別に応じた設定案内
# --------------------------------------------------------------------------
if [[ "$APP_TYPE" == "1" ]]; then
    _show_connected_app_guide
else
    # 外部クライアントアプリは、組織ごとに自動で作成する（Step 4: register_jwt_secret_eca）
    log "HEADER" "外部クライアントアプリケーションは自動で作成します。"
    log "INFO" "  各組織で、ブラウザでのログインが必要です（接続ユーザー＝管理者権限のユーザー）。"
    log "INFO" "  アプリの作成・証明書の登録・ポリシーとプロファイルの設定・コンシューマー鍵の取得は、sf-init が自動で行います。"
fi

# --------------------------------------------------------------------------
# Step 3: SF_PRIVATE_KEY を GitHub Secrets に登録
# --------------------------------------------------------------------------
log "HEADER" "SF_PRIVATE_KEY を GitHub Secrets に登録します。"
# run 不使用: 秘密鍵の内容をログに記録しないため直接実行（base64 エンコードして改行コード問題を回避）
# tr -d '\r': Windows(Git Bash)環境で生成された PEM に含まれる CR(0x0D) を除去してから base64 エンコード
tr -d '\r' < "${JWT_DIR}/server.key" | base64_oneline | gh secret set "SF_PRIVATE_KEY" -R "$REPO_FULL_NAME" \
    || die "SF_PRIVATE_KEY の登録に失敗しました。"
log "SUCCESS" "SF_PRIVATE_KEY を登録しました。"

# --------------------------------------------------------------------------
# Step 4: 組織ごとの JWT 設定
# --------------------------------------------------------------------------
log "HEADER" "各組織の JWT 認証情報を設定します。"

# アプリ種別に応じた組織ごとの登録
#   接続アプリ（1）      : コンシューマーキー・ユーザー名を入力 → JWT 接続テスト → 登録
#   外部クライアントアプリ（2）: 自動作成（deploy）→ コンシューマー鍵を自動取得 → JWT 接続テスト → 登録
#   段階ごとの再開: 完了した段階は、進捗ファイル（.sf-init.progress）に SF_INIT_DONE_TIER_<接尾辞>=1 を記録する。
#   再実行では、記録があり、登録した Secret（SF_CONSUMER_KEY_<接尾辞>）が、いまもあるときだけ、その段階をスキップする
#   （ブラウザのログインを、やり直さなくてよいように）。付け替えるときは、sf-init.sh --reconnect <段階>。
#   進捗ファイルは、Phase 10 が成功したとき、sf-init.sh が書き直す（段階の記録は、消える）。--only 10 では、使わない
_tier_done() {
    [[ "${SF_INIT_TIER_RESUME:-}" == "1" && -f "${SF_INIT_PROGRESS_FILE:-}" ]] || return 1
    grep -qx "SF_INIT_DONE_TIER_${1}=1" "$SF_INIT_PROGRESS_FILE" 2>/dev/null || return 1
    local list
    # Secret の一覧を取得できないとき（権限不足・通信エラー）は、「ない」と区別して、理由を表示し、その段階を実行する（安全側）
    if ! list=$(gh secret list -R "$REPO_FULL_NAME" 2>/dev/null); then  # 条件チェック（取得のため run 不使用）
        log "INFO" "  Secret の一覧を確認できないため、${1} の段階は、スキップせずに、実行します。"
        return 1
    fi
    printf '%s\n' "$list" | awk '{print $1}' | tr -d '\r' | grep -qx "SF_CONSUMER_KEY_${1}"
}
_register_org() {
    local alias="$1" suffix="$2" label="$3"
    if _tier_done "$suffix"; then
        log "INFO" "  ${label}（${suffix}）は、前回、設定が完了しているため、スキップします（付け替えるときは、sf-init.sh --reconnect <段階>）。"
        return 0
    fi
    if [[ "$APP_TYPE" == "1" ]]; then
        register_jwt_secret "$alias" "$suffix" "$label" "${JWT_DIR}/server.key"
    else
        register_jwt_secret_eca "$alias" "$suffix" "$label" "${JWT_DIR}/server.key" "${JWT_DIR}/server.crt"
    fi || return 1
    # この段階が完了したことを、記録する（途中で失敗しても、完了した段階を、やり直さないため）
    if [[ "${SF_INIT_TIER_RESUME:-}" == "1" && -n "${SF_INIT_PROGRESS_FILE:-}" ]]; then
        printf 'SF_INIT_DONE_TIER_%s=1\n' "$suffix" >> "$SF_INIT_PROGRESS_FILE" \
            || log "WARNING" "  進捗の記録に失敗しました（次回、この段階を、やり直します）。"
    fi
}

# 10-4-1. メイン組織（必須。ログイン先は URL で選ぶ）
_register_org "prod" "PROD" "メイン組織"

# 10-4-2. ステージング組織（2 階層以上）
if [[ $BRANCH_COUNT -ge 2 ]]; then
    _register_org "staging" "STG" "ステージング組織"
fi

# 10-4-3. 開発組織（3 階層）
if [[ $BRANCH_COUNT -ge 3 ]]; then
    _register_org "develop" "DEV" "開発組織"
fi

log "SUCCESS" "完了: JWT 認証情報の設定 OK。"
exit $RET_OK
