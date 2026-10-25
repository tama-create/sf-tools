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
#   -n, --no-open       : ブラウザを開かずに実行する（sf-release.sh へ渡す）
#   -t, --target ALIAS  : 接続先組織のエイリアスを指定する（sf-release.sh へも渡す）。値がない、または値が「-」で始まる
#                         場合は、確認の前に中断する。
#                         --target=ALIAS の形式は、確認の前に中断する（-t ALIAS / --target ALIAS で指定すること）。
#   -v, --verbose       : コマンドの応答（出力）をコンソールにも表示する（このスクリプトと sf-release.sh の両方）
#   -h, --help          : このヘルプを表示して終了する（1 番目の引数のときだけ）
#   -j, --json          : sf-release.sh へ渡す（sf-release.sh が実行する sf コマンドに --json を付ける）
#   上記以外のオプション・引数は、確認（Y/N/q）の前に、「不明なオプションです」で中断する（-f / --force / -r / --release は、常に付くため、受け付けるだけ）。
#
# 【処理の流れ】
#   1. 同じディレクトリの sf-release.sh の存在を確認する。なければ中断する。
#   2. 現在のブランチ（git symbolic-ref --short HEAD）を取得する。取得できない（detached HEAD・Git リポジトリの外など）
#      とき、または sf-tools/config/branches.txt に書かれたブランチ（# の行・空行は除く。ファイルがない、または空なら
#      main のみ）なら、中断する。
#   3. 引数を調べる（【オプション】のとおり。-t の値の不備・--target=ALIAS・不明なオプションは、ここで中断する）。
#   4. 接続先組織を決める。優先順位: -t の値 > 環境変数 SF_TARGET_ORG > sf org display の alias
#      （sf org display は既定で最大 3 回試行）。決まらなければ中断する。
#   5. GitHub Actions 外（GITHUB_ACTIONS が true 以外）で、接続先が予約名（prod / staging / develop / main）なら、
#      または、本番の組織（組織の種類を読み取る）なら、中断する。種類を確認できないときも、中断する
#      （共有環境。確認（Y/N/q）より前に判定する）。
#   6. 上書きの警告を表示し、確認（Y/N/q）を表示する。N / q なら中断する（GitHub Actions 上でも、確認は省かない）。
#   7. SF_DEPLOY_CONFIRMED=1 を export し（sf-release.sh 側の確認を省く）、
#      exec bash sf-release.sh --release --force "$@" で置き換える（終了コードは sf-release.sh のもの）。
#
# 【前提条件】
#   - force-* ディレクトリ（プロジェクトのルート）で実行すること。その他の前提は sf-release.sh と同じ。
#   - branches.txt に書かれていないブランチ（作業用ブランチ）にいること。
#
# 【補足】
#   - 共有環境（エイリアスが予約名 prod / staging / develop / main の組織）には、ローカルからリリースできない。
#     GitHub にコミットし、レビューを通して、GitHub Actions で行う。名前だけでは、別の名前を付けた本番組織を止められないため、
#     組織の種類も確認し（org_local_release_check）、本番の組織、または種類を確認できない組織は、名前にかかわらず、実行できない。
#   - 2 番目以降の -h / --help は、不明なオプションとして、確認の前に中断する（第 1 引数の -h だけが、ヘルプを表示する）。
#   - 終了コード: 中断は 1。それ以外は sf-release.sh の終了コード。
#   - ログ: ./sf-tools/logs/sf-deploy.log（実行のたびに作り直す）。手順 7 以降（sf-release.sh）のログは、
#     ./sf-tools/logs/sf-release.log
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
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}"  # run 不使用: common.sh の読み込み前（run が未定義）
    exit 0
fi
source "$COMMON_LIB"
source "${SCRIPT_DIR}/../lib/org.sh"   # org_local_release_check（組織の種類の確認）

# ------------------------------------------------------------------------------
# 3. 初期チェック
# ------------------------------------------------------------------------------
log "HEADER" "強制デプロイを開始します (${SCRIPT_NAME}.sh)"

RELEASE_SH="${SCRIPT_DIR}/sf-release.sh"
[[ -f "$RELEASE_SH" ]] || die "スクリプトが見つかりません: ${RELEASE_SH}"

# 保護ブランチ（branches.txt のブランチ）の上では実行しない。
#   ブランチを取得できない（detached HEAD・Git リポジトリの外など）ときも、中断する
#   （以前は失敗を見ず、git のエラーの文言をブランチ名として扱い、保護ブランチの確認を素通りしていた）
CURRENT_BRANCH=$(run git symbolic-ref --short HEAD) \
    || die "現在のブランチを取得できません（detached HEAD、または Git リポジトリの外）。"
if is_protected_branch "$CURRENT_BRANCH"; then
    die "${CURRENT_BRANCH} は保護ブランチ（sf-tools/config/branches.txt）のため、実行できません。"
fi

# 引数を調べる（不明なものは、確認の前に拒否する）。続けて接続先を特定し、共有環境（予約名: prod / staging / develop / main）
#   なら、ローカルから強制リリースできないため、確認の前に拒否する。
# 接続先は、-t / --target の指定を優先し、なければ sf-release.sh と同じ方法（SF_TARGET_ORG、接続中の組織）で特定する
TARGET_ARG=""
ARGS=("$@")
for ((i = 0; i < ${#ARGS[@]}; i++)); do
    case "${ARGS[i]}" in
        -t|--target)
            # sf-release.sh と同じ規則で解析する（値が無い・次のオプションを値にする指定は受け付けない）
            [[ -n "${ARGS[i+1]:-}" && "${ARGS[i+1]}" != -* ]] || die "-t / --target の値（組織のエイリアス）がない、または - で始まっています。"
            TARGET_ARG="${ARGS[i+1]}"
            i=$((i + 1))   # 値は、次の繰り返しで、オプションとして調べない
            ;;
        -n|--no-open|-v|--verbose|-j|--json|-f|--force|-r|--release) ;;   # sf-release.sh が受け付けるもの（-f・-r は、常に付く）
        --target=*)
            # sf-release.sh は --target=ALIAS 形式に対応していないため、確認の前に拒否する
            die "--target=ALIAS の形式には対応していません: ${ARGS[i]}"
            ;;
        *)
            # 確認（Y/N/q）の前に拒否する（以前は、確認のあとで、sf-release.sh が拒否していた。2 番目以降の -h も、ここで拒否する）
            die "不明なオプションです: ${ARGS[i]}"
            ;;
    esac
done
TARGET_ORG=$(get_target_org "$TARGET_ARG") || die "接続先の組織エイリアスを特定できません。"
if [[ "${GITHUB_ACTIONS:-false}" != "true" ]] && is_reserved_org_alias "$TARGET_ORG"; then
    die "${TARGET_ORG} は共有環境（予約名）のため、ローカルから強制リリースできません。"
fi
if [[ "${GITHUB_ACTIONS:-false}" != "true" ]]; then
    # 名前を付け替えた本番組織も止める（組織の種類を調べる。本番、または種類を確認できないときは、中断する）
    _org_rc=0
    org_local_release_check "$TARGET_ORG" || _org_rc=$?  # run 不使用: 戻り値で分岐する（run は、戻り値を変える）
    case "$_org_rc" in
        1) die "${TARGET_ORG} は本番組織のため、ローカルから強制リリースできません。" ;;
        2) die "${TARGET_ORG} の組織の種類を確認できないため、ローカルから強制リリースできません。" ;;
    esac
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
exec bash "$RELEASE_SH" --release --force "$@"  # run 不使用: exec で sf-release.sh に置き換える（画面の入出力・終了コードを、そのまま渡す）
