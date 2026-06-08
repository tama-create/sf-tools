#!/bin/bash
# ==============================================================================
# 10_sf_auth.sh - Phase 10: JWT 認証情報の設定
# ==============================================================================
# JWT（OAuth 2.0 JWT Bearer Flow）方式で Salesforce 組織への認証情報を
# GitHub Secrets / Variables に登録する。
#
# 【処理フロー】
#   1.   openssl で秘密鍵・証明書を生成（~/.sf-jwt/<REPO_NAME>/）
#   1.5. アプリ種別を選択（接続アプリケーション / 外部クライアントアプリケーション）
#   2.   選択種別に応じた Salesforce 設定手順を案内（証明書アップロードまで待機）
#   3.   秘密鍵を SF_PRIVATE_KEY として GitHub Secrets に登録
#   4.   組織ごとに本番 or Sandbox を選択・コンシューマーキー・ユーザー名を入力して JWT 接続テスト
#   5.   SF_CONSUMER_KEY_xxx を Secret / SF_USERNAME_xxx・SF_INSTANCE_URL_xxx を Variable に登録
#
# 【登録する GitHub Secrets（機密）】
#   SF_PRIVATE_KEY              （全組織共通・秘密鍵 PEM）
#   SF_CONSUMER_KEY_PROD / _STG / _DEV
#
# 【登録する GitHub Variables（平文）】
#   SF_USERNAME_PROD     / _STG / _DEV
#   SF_INSTANCE_URL_PROD / _STG / _DEV
#
# 【備考】
#   秘密鍵は ~/.sf-jwt/<REPO_NAME>/server.key に保存される。
#   証明書（server.crt）は各組織の Connected App または外部クライアントアプリにアップロードが必要。
#   BRANCH_COUNT は Phase 5 で .sf-init.env に書き出される。
#   APP_TYPE は選択後に .sf-init.env に書き出す（--resume 時の再利用のため）。
#
# 【接続アプリケーション運用上の注意】
#   ・作成した接続アプリケーションを「外部クライアントアプリへの移行」または「削除」しないこと。
#     OAuth 内部状態が破損し client_identifier_invalid エラーが発生する。
#     問題が起きた場合は同じアプリを修正せず、別名で新規作成すること。
#   ・Developer Edition 組織では pre-authorization の反映が遅延・失敗する場合がある。
#     JWT Bearer Flow は Production / Sandbox 組織での使用を推奨。
# ==============================================================================

# SF_TOOLS_DIR は sf-init.sh（司令塔）から export される
PHASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_TOOLS_DIR="${SF_TOOLS_DIR:-$(dirname "$PHASE_DIR")}"

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
    log "HEADER" "Phase 10-2: Salesforce 接続アプリケーション を設定してください。"
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
# Step 2 案内文: 外部クライアントアプリケーション（External Client App）
# ------------------------------------------------------------------------------
_show_external_client_app_guide() {
    log "HEADER" "Phase 10-2: Salesforce 外部クライアントアプリケーション を設定してください。"
    log "INFO" ""
    log "INFO" "  ▼ アップロードする証明書ファイル（server.crt）のパス:"
    log "INFO" "    ${JWT_DIR}/server.crt"
    log "INFO" ""
    log "INFO" "  ╔══════════════════════════════════════════════════╗"
    log "INFO" "  ║  STEP A: 外部クライアントアプリを作成する        ║"
    log "INFO" "  ╚══════════════════════════════════════════════════╝"
    log "INFO" "  1. 設定の検索窓に「外部クライアントアプリケーション」と入力 → 「新規」"
    log "INFO" "  2. 基本情報を入力（アプリケーション名: SF_TOOLS・API 参照名: SF_TOOLS・連絡先メール: 任意）"
    log "INFO" "  3. 「フロー」タブ → 「JWT Bearer」を有効化"
    log "INFO" "     コールバック URL: https://login.salesforce.com/services/oauth2/callback"
    log "INFO" "  4. 「OAuth 範囲」に以下を追加"
    log "INFO" "     ・フルアクセス (full)"
    log "INFO" "     ・いつでも要求を実行 (refresh_token, offline_access)"
    log "INFO" "  5. 「デジタル署名を使用」にチェック → 上記の server.crt をアップロード"
    log "INFO" "  6. 保存 → 「コンシューマー鍵（クライアント ID）」をコピー"
    log "INFO" ""
    log "INFO" "  ★ 保存後 2〜10 分待ってから STEP B へ進んでください ★"
    log "INFO" ""
    log "INFO" "  ╔══════════════════════════════════════════════════╗"
    log "INFO" "  ║  STEP B: ポリシーとプロファイルを設定する        ║"
    log "INFO" "  ╚══════════════════════════════════════════════════╝"
    log "INFO" "  作成したアプリを開く → 「ポリシー」タブ"
    log "INFO" "  ・「許可されているユーザー」→「管理者が承認したユーザーは事前承認済み」→ 保存"
    log "INFO" "  「プロファイル」タブ → 接続ユーザーのプロファイル（例: システム管理者）を追加"
    log "INFO" ""
    press_enter "設定が完了したら Enter を押してください（q で中断）"
}

# ------------------------------------------------------------------------------
# メイン処理
# ------------------------------------------------------------------------------
log "HEADER" "Phase 10: JWT 認証情報の設定"

# --------------------------------------------------------------------------
# Step 1: 証明書の生成
# --------------------------------------------------------------------------
log "HEADER" "Phase 10-1: JWT 用証明書を生成します。"

if [[ -f "${JWT_DIR}/server.key" && -f "${JWT_DIR}/server.crt" ]]; then
    log "INFO" "既存の証明書が見つかりました: ${JWT_DIR}/"
    if ask_yn "  既存の証明書を再利用しますか？（N を選ぶと再生成します）"; then
        log "INFO" "  既存の証明書を使用します。"
    else
        # N を選んだ場合は既存ファイルを削除してから再生成
        # （削除しないと generate_jwt_cert 内のスキップ判定に引っかかるため）
        rm -f "${JWT_DIR}/server.key" "${JWT_DIR}/server.crt"
        generate_jwt_cert "$JWT_DIR" "$REPO_NAME"
    fi
else
    generate_jwt_cert "$JWT_DIR" "$REPO_NAME"
fi

# --------------------------------------------------------------------------
# Step 1.5: アプリ種別の選択
# --------------------------------------------------------------------------
log "HEADER" "Phase 10-1.5: Salesforce アプリ種別を選択してください。"
log "INFO" ""
log "INFO" "  [1] 接続アプリケーション（Connected App）"
log "INFO" "      ※ 今後廃止予定。既存プロジェクトとの互換維持に使用"
log "INFO" "  [2] 外部クライアントアプリケーション（External Client App）"
log "INFO" "      ※ Salesforce 推奨の新方式"
log "INFO" ""

# --resume 時は .sf-init.env に保存済みの種別を再利用
if [[ -n "${APP_TYPE:-}" ]]; then
    log "INFO" "  前回選択済みの種別を使用します: [${APP_TYPE}]"
else
    APP_TYPE=""
    read_key APP_TYPE "  選択してください [1-2/q]: " "[12Qq]"
    [[ "$APP_TYPE" =~ [Qq] ]] && die "中断しました。"
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
    _show_external_client_app_guide
fi

# --------------------------------------------------------------------------
# Step 3: SF_PRIVATE_KEY を GitHub Secrets に登録
# --------------------------------------------------------------------------
log "HEADER" "Phase 10-3: SF_PRIVATE_KEY を GitHub Secrets に登録します。"
# run 不使用: 秘密鍵の内容をログに記録しないため直接実行（base64 エンコードして改行コード問題を回避）
# tr -d '\r': Windows(Git Bash)環境で生成された PEM に含まれる CR(0x0D) を除去してから base64 エンコード
tr -d '\r' < "${JWT_DIR}/server.key" | base64 -w 0 | gh secret set "SF_PRIVATE_KEY" -R "$REPO_FULL_NAME" \
    || die "SF_PRIVATE_KEY の登録に失敗しました。"
log "SUCCESS" "SF_PRIVATE_KEY を登録しました。"

# --------------------------------------------------------------------------
# Step 4: 組織ごとの JWT 設定
# --------------------------------------------------------------------------
log "HEADER" "Phase 10-4: 各組織の JWT 認証情報を設定します。"

# 10-4-1. メイン組織（必須・本番 or Sandbox を選択）
register_jwt_secret "prod" "PROD" "メイン組織" "${JWT_DIR}/server.key"

# 10-4-2. ステージング組織（2 階層以上）
if [[ $BRANCH_COUNT -ge 2 ]]; then
    register_jwt_secret "staging" "STG" "ステージング組織" "${JWT_DIR}/server.key"
fi

# 10-4-3. 開発組織（3 階層）
if [[ $BRANCH_COUNT -ge 3 ]]; then
    register_jwt_secret "develop" "DEV" "開発組織" "${JWT_DIR}/server.key"
fi

log "SUCCESS" "Phase 10 完了: JWT 認証情報の設定 OK。"
exit $RET_OK
