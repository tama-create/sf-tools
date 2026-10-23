#!/bin/bash
# ==============================================================================
# sf-deploy.sh - 強制リリーススクリプト（sf-release.sh のラッパー）
# ==============================================================================
# Sandbox 乗り換え時などに、現在の開発物を接続先の組織へ強制リリースする。
# sf-release.sh を --release --force 付きで呼び出す。受け取った引数は、すべてその後ろに付けて sf-release.sh へ渡す。
# 個人用の Sandbox / Developer Edition / Scratch Org への強制リリース用。
#
# 【使い方】
#   sf-deploy.sh [オプション]
#
# 【オプション】
#   （固定）--release   : リリースモードで実行する（dry-run しない）。常に付く。
#   （固定）--force     : コンフリクト検知を無効にして上書きする（--ignore-conflicts 相当）。常に付く。
#   -n, --no-open       : ブラウザを開かずに実行する
#   -t, --target ALIAS  : 接続先組織のエイリアスを指定する。値がない、または値が「-」で始まる場合は、確認の前に中断する。
#                         --target=ALIAS の形式は、確認の前に中断する（-t ALIAS / --target ALIAS で指定すること）。
#   -v, --verbose       : コマンドの応答（出力）をコンソールにも表示する
#   -h, --help          : このヘルプを表示して終了する（1 番目の引数のときだけ）
#   -j, --json          : sf コマンドの出力を JSON 形式で表示する（sf-release.sh へ渡す）
#   上記以外のオプション・引数は、確認（Y/N/q）の前に、「不明なオプションです」で中断する（-f / -r は、常に付くため、受け付けるだけ）。
#
# 【処理の流れ】
#   1. 同じディレクトリの sf-release.sh の存在を確認する。なければ中断する。
#   2. 現在のブランチ（git symbolic-ref --short HEAD）が、sf-tools/config/branches.txt に書かれたブランチ
#      （# の行・空行は除く。ファイルがない、または空なら main のみ）なら、中断する。
#   3. 接続先組織を決める。優先順位: -t の値 > 環境変数 SF_TARGET_ORG > sf org display の alias。決まらなければ中断する。
#   4. GitHub Actions 外（GITHUB_ACTIONS が true 以外）で、接続先が予約名（prod / staging / develop / main）なら、
#      中断する（共有環境。確認（Y/N/q）より前に判定する）。
#   5. 上書きの警告を表示し、確認（Y/N/q）を表示する。N / q なら中断する。
#   6. SF_DEPLOY_CONFIRMED=1 を export し（sf-release.sh 側の確認を省く）、
#      exec bash sf-release.sh --release --force "$@" で置き換える（終了コードは sf-release.sh のもの）。
#
# 【前提条件】
#   - force-* ディレクトリ（プロジェクトのルート）で実行すること。その他の前提は sf-release.sh と同じ。
#   - branches.txt に書かれていないブランチ（作業用ブランチ）にいること。
#
# 【補足】
#   - 共有環境（エイリアスが予約名 prod / staging / develop / main の組織）には、ローカルからリリースできない。
#     GitHub にコミットし、レビューを通して、GitHub Actions で行う。予約名以外の名前に付け替えた場合は、
#     動作を保証しない。
#   - 2 番目以降の -h / --help は、不明なオプションとして、確認の前に中断する（第 1 引数の -h だけが、ヘルプを表示する）。
#   - 終了コード: 中断は 1。それ以外は sf-release.sh の終了コード。
#   - ログ: ./sf-tools/logs/sf-deploy.log（実行のたびに作り直す）
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
            i=$((i + 1))   # 値は、次の繰り返しで、オプションとして調べない
            ;;
        -n|--no-open|-v|--verbose|-j|--json|-f|--force|-r|--release) ;;   # sf-release.sh が受け付けるもの（-f・-r は、常に付く）
        --target=*)
            # sf-release.sh は --target=ALIAS 形式に対応していないため、確認の前に拒否する
            die "--target=ALIAS の形式には対応していません。-t ALIAS または --target ALIAS で指定してください。"
            ;;
        *)
            # 確認（Y/N/q）の前に拒否する（以前は、確認のあとで、sf-release.sh が拒否していた。2 番目以降の -h も、ここで拒否する）
            die "不明なオプションです: ${ARGS[i]}"
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
