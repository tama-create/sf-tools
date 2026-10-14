#!/bin/bash
# ==============================================================================
# sf-deploy.sh - 強制リリーススクリプト（sf-release.sh のラッパー）
# ==============================================================================
# Sandbox 乗り換え時などに現在の開発物を接続中の組織へ強制リリースします。
# sf-release.sh を --release --force オプション付きで呼び出します。
# 追加オプションはそのまま sf-release.sh へ引き渡されます。
#
# 【用途と制限】
#   個人用の Sandbox / Developer Edition / Scratch Org への強制リリース用です。
#   共有環境（エイリアスが予約名 prod / staging / develop / main の組織）には、
#   ローカルからリリースできません。GitHub にコミットし、レビューを通して、GitHub Actions で行います。
#   予約名の判定は、確認（Y/N/q）より前に行います。予約名以外の名前に付け替えた場合は、動作を保証しません。
#   確認（Y/N/q）で N または q なら、中断します。
#
# 【固定オプション】
#   --release           : リリースモードで実行（dry-run しない）
#   --force             : コンフリクト検知を無効化して強制上書きする（--ignore-conflicts 相当）
#
# 【追加オプション（sf-release.sh に転送）】
#   -n, --no-open       : ブラウザを開かずに実行します
#   -t, --target ALIAS  : 接続先組織のエイリアスを明示的に指定します
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
log "HEADER" "強制デプロイを開始します (${SCRIPT_NAME}.sh)"

RELEASE_SH="${SCRIPT_DIR}/sf-release.sh"
[[ -f "$RELEASE_SH" ]] || die "スクリプトが見つかりません: ${RELEASE_SH}"

CURRENT_BRANCH=$(run git symbolic-ref --short HEAD)
if is_protected_branch "$CURRENT_BRANCH"; then
    die "${CURRENT_BRANCH} ブランチでは実行できません。現在のブランチ: ${CURRENT_BRANCH}"
fi

# 共有環境（予約名: prod / staging / develop / main）には、ローカルから強制リリースできない（確認の前に拒否する）。
# 接続先は、-t / --target の指定を優先し、なければ sf-release.sh と同じ方法（SF_TARGET_ORG、接続中の組織）で特定する
TARGET_ARG=""
ARGS=("$@")
for ((i = 0; i < ${#ARGS[@]}; i++)); do
    case "${ARGS[i]}" in
        -t|--target)
            # sf-release.sh と同じ規則で解析する（値が無い・次のオプションを値にする指定は受け付けない）
            [[ -n "${ARGS[i+1]:-}" && "${ARGS[i+1]}" != -* ]] || die "-t / --target には、組織のエイリアスを指定してください。"
            TARGET_ARG="${ARGS[i+1]}"
            ;;
        --target=*)
            # sf-release.sh は --target=ALIAS 形式に対応していないため、確認の前に拒否する
            die "--target=ALIAS の形式には対応していません。-t ALIAS または --target ALIAS で指定してください。"
            ;;
    esac
done
TARGET_ORG=$(get_target_org "$TARGET_ARG") || die "接続先の組織エイリアスを特定できません。"
if [[ "${GITHUB_ACTIONS:-false}" != "true" ]] && is_reserved_org_alias "$TARGET_ORG"; then
    die "${TARGET_ORG} は共有環境のため、ローカルから強制リリースできません。PR 経由で GitHub Actions を使用してください。"
fi

# ------------------------------------------------------------------------------
# 4. 強制デプロイ確認
# ------------------------------------------------------------------------------
log "WARNING" "--force（--ignore-conflicts）が指定されています。コンフリクトは強制上書きされます。"
ask_yn "強制デプロイ（--force）を実行します。続行しますか？" || die "中断しました。"

# sf-release.sh 側の二重確認を抑制するため確認済みフラグをエクスポート
export SF_DEPLOY_CONFIRMED=1

# ------------------------------------------------------------------------------
# 5. sf-release.sh を強制リリースモードで呼び出す
# ------------------------------------------------------------------------------
exec bash "$RELEASE_SH" --release --force "$@"
