#!/bin/bash
# ==============================================================================
# sf-typecheck.sh - メタデータの種類ごとに、リリースと削除ができるかを、実際の組織で確かめる（管理者・開発者向け）
# ==============================================================================
# 種類ごとの最小のサンプル（lib/typecheck.js）を、使い捨てのプロジェクトに作り、指定した組織に、実際にリリースして、
# 削除し、結果を表（種類 / release / delete / 備考）にする。この表は、config/metadata-capability.txt の元になる。
# sf-check.sh が、この表を読んで、リリース・削除できない種類を、ターゲットファイルに書いた時点で、止める。
#
# 【安全】
#   ・個人用の組織だけ（Developer Edition・Sandbox・Scratch・Trial）。本番の組織・種類を判定できない組織は、拒否する
#   ・共有環境の予約名のエイリアス（prod / staging / develop / main）は、拒否する（共有環境は、GitHub Actions だけ）
#   ・作成・削除するのは、名前に SfToolsE2eMin を含むものだけ
#   ・既存のものには、触れない（Account などの標準のものには、追加するだけ）
#   ・GitHub Actions 上では、実行しない
#
# 【使い方】
#   sf-typecheck.sh --org ALIAS                       # リリースして、削除する（確認あり）
#   sf-typecheck.sh --org ALIAS --validate-only       # 検証だけ（組織には、何も反映しない。削除は、確認できない）
#   sf-typecheck.sh --org ALIAS --only ApexPage,Queue # 種類を絞る
#   sf-typecheck.sh --list                            # 確認する種類の一覧だけ
#   sf-typecheck.sh --coverage                        # 変更セット対応の種類のうち、確認済み・未確認の数と一覧（組織には、接続しない）
#
# 【オプション】
#   --org ALIAS        : 接続先の組織のエイリアス（必須。予約名・本番は、拒否）
#   --validate-only    : 検証（deploy validate）だけ行う
#   --only A,B         : 指定した種類だけ確認する
#   --out FILE         : 結果の表（TSV）の出力先（既定: ./sf-typecheck-result.txt）
#   --list             : 確認する種類の一覧を出して終了する
#   --coverage         : config/changeset-types.txt（変更セットで扱える種類。公式の一覧）と、
#                        config/metadata-capability.txt（実機で確認した結果）を突き合わせて、確認済み・未確認の数と一覧を出す。
#                        組織には、接続しない（安全の確認・警告は、不要）
#   -y, --yes          : 確認（Enter）を省略する（自動実行用。警告は、表示する）
#   -h, --help         : このヘルプを表示する
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 共通ライブラリの必須設定
# ------------------------------------------------------------------------------
readonly SCRIPT_NAME=$(basename "$0" .sh)
readonly LOG_FILE="${HOME}/sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"
mkdir -p "${HOME}/sf-tools/logs" 2>/dev/null || true  # run 不使用: ログフォルダの準備（log が使える前の処理）

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
export SF_INIT_MODE=1   # force-* ディレクトリの外でも、実行できる（組織だけを対象にするため）
source "$COMMON_LIB"
source "${SCRIPT_DIR}/../lib/org.sh"

# ------------------------------------------------------------------------------
# 3. 引数
# ------------------------------------------------------------------------------
ORG_ALIAS=""
MODE="full"
ONLY=""
OUT_FILE="./sf-typecheck-result.txt"
LIST_ONLY=0
COVERAGE=0
ASSUME_YES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --org)
            [[ $# -ge 2 && "$2" != --* ]] || die "--org にエイリアスを指定してください。"
            ORG_ALIAS="$2"; shift ;;
        --validate-only) MODE="validate" ;;
        --only)
            [[ $# -ge 2 && "$2" != --* ]] || die "--only に種類を指定してください（例: ApexPage,Queue）。"
            ONLY="$2"; shift ;;
        --out)
            [[ $# -ge 2 && "$2" != --* ]] || die "--out にファイルを指定してください。"
            OUT_FILE="$2"; shift ;;
        --list) LIST_ONLY=1 ;;
        --coverage) COVERAGE=1 ;;
        -y|--yes) ASSUME_YES=1 ;;
        *) die "不明なオプションです: $1" ;;
    esac
    shift
done

# 変更セット対応の種類と、実機で確認した結果の突き合わせ（組織には、接続しない。awk のみ）
if [[ $COVERAGE -eq 1 ]]; then
    CS_FILE="${SF_TYPECHECK_CHANGESET_FILE:-${SCRIPT_DIR}/../config/changeset-types.txt}"
    CAP_FILE="${SF_CHECK_CAPABILITY_FILE:-${SCRIPT_DIR}/../config/metadata-capability.txt}"
    [[ -f "$CS_FILE" ]] || die "変更セット対応の種類の一覧が見つかりません: ${CS_FILE}"
    [[ -f "$CAP_FILE" ]] || die "可否の表が見つかりません: ${CAP_FILE}"
    # 可否の表の種類名が、変更セット側の複数形・単数形と違うもの（CustomLabels など）は、別名で引く
    awk -v CAP="$CAP_FILE" '
        BEGIN {
            FS = "\t"
            while ((getline line < CAP) > 0) {
                if (line ~ /^#/ || line ~ /^[ \t\r]*$/) continue
                split(line, f, "\t"); gsub(/\r/, "", f[3]); r[f[1]] = f[2]; d[f[1]] = f[3]
            }
            alias["CustomLabels"] = "CustomLabel"; alias["AssignmentRules"] = "AssignmentRule"; alias["EscalationRules"] = "EscalationRule"
        }
        /^#/ || /^[ \t\r]*$/ { next }
        {
            t = $0; gsub(/\r/, "", t); total++
            k = t
            # 別名の表の行が、確認済みなら、そちらを使う（自分の行が、ない・判定できない場合だけ）
            if ((t in alias) && (alias[t] in r) && (!(t in r) || (r[t] == "unknown" && d[t] == "unknown"))) k = alias[t]
            if (!(k in r))                                                                   cls = "untested"
            else if (r[k] == "ok" && d[k] == "ok")                                           cls = "ok"
            else if (r[k] == "ng" || d[k] == "ng" || r[k] == "limited" || d[k] == "limited") cls = "limited"
            else if (r[k] == "ok")                                                           cls = "relonly"
            else                                                                             cls = "unknown"
            n[cls]++; L[cls] = L[cls] (L[cls] == "" ? "" : ", ") t
        }
        END {
            printf "変更セットで扱える種類: %d\n", total
            printf "  リリースも削除も、実機で確認済み       : %4d（%d%%）\n", n["ok"], (total ? int(n["ok"] * 100 / total) : 0)
            printf "  リリースのみ確認済み（削除は未確認）   : %4d\n", n["relonly"]
            printf "  条件つき・確認済みの NG                : %4d\n", n["limited"]
            printf "  判定できない（組織の機能がない など）  : %4d\n", n["unknown"]
            printf "  まだ試していない                       : %4d\n", n["untested"]
            if (n["limited"])  printf "\n【条件つき・確認済みの NG】\n%s\n", L["limited"]
            if (n["relonly"])  printf "\n【リリースのみ確認済み】\n%s\n", L["relonly"]
            if (n["unknown"])  printf "\n【判定できない】\n%s\n", L["unknown"]
            if (n["untested"]) printf "\n【まだ試していない】\n%s\n", L["untested"]
        }' "$CS_FILE" | fold -s -w 110
    exit "${PIPESTATUS[0]}"
fi

TYPECHECK_JS="${SCRIPT_DIR}/../lib/typecheck.js"
[[ -f "$TYPECHECK_JS" ]] || die "lib/typecheck.js が見つかりません: ${TYPECHECK_JS}"
command -v node > /dev/null 2>&1 || die "node が見つかりません（sf CLI は npm 版が前提のため、通常は、あります）。"  # 存在確認のため run 不使用

# 一覧だけ（組織には、接続しない）
if [[ $LIST_ONLY -eq 1 ]]; then
    node "$TYPECHECK_JS" --list  # 一覧の表示のみ・組織に接続しないため run 不使用
    exit $?
fi

# ------------------------------------------------------------------------------
# 4. 安全の確認（実行前。NG なら、何もせずに終了する）
# ------------------------------------------------------------------------------
[[ "${GITHUB_ACTIONS:-}" == "true" ]] && die "GitHub Actions 上では、実行できません。"
[[ -n "$ORG_ALIAS" ]] || die "--org で、接続先の組織のエイリアスを指定してください。"
case "$ORG_ALIAS" in
    prod|staging|develop|main)
        die "${ORG_ALIAS} は、共有環境の予約名のため、実行できません（共有環境は、GitHub Actions 経由だけです）。個人用のエイリアスで、ログインし直してください。" ;;
esac
check_sf_cli --cache

log "HEADER" "メタデータの種類ごとの確認（${SCRIPT_NAME}.sh）"
org_read_info "$ORG_ALIAS" \
    || die "組織の種類を読み取れません（${ORG_ALIAS}）。ログイン済みのエイリアスを指定してください。推測では、実行しません。"
ORG_KIND=$(org_kind)  # VAR=$(cmd) のため run 不使用
case "$ORG_KIND" in
    production) die "${ORG_ALIAS} は、本番の組織です。実行できません（Developer Edition・Sandbox・Scratch・Trial のみ）。" ;;
    unknown)    die "${ORG_ALIAS} の種類を判定できません。実行しません（推測しません）。" ;;
esac
log "INFO" "  接続先: ${ORG_ALIAS} / ${ORG_NAME:-（名前なし）} / $(org_kind_label "$ORG_KIND")"

# ------------------------------------------------------------------------------
# 5. 警告と確認
# ------------------------------------------------------------------------------
echo "" >&2
echo -e "${CLR_ERR}╔══════════════════════════════════════════════════════╗${CLR_RESET}" >&2
if [[ "$MODE" == "full" ]]; then
    echo -e "${CLR_ERR}║  !!  実際に、組織へリリースして、削除します          ║${CLR_RESET}" >&2
else
    echo -e "${CLR_ERR}║  !!  検証だけ行います（何も反映しません）            ║${CLR_RESET}" >&2
fi
echo -e "${CLR_ERR}║      名前は SfToolsE2eMin で始まるものだけ扱います  ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}║      管理者以外は、実行しないでください              ║${CLR_RESET}" >&2
echo -e "${CLR_ERR}╚══════════════════════════════════════════════════════╝${CLR_RESET}" >&2
echo "" >&2
if [[ $ASSUME_YES -eq 0 ]]; then
    ask_yn "${ORG_ALIAS}（$(org_kind_label "$ORG_KIND")）で、種類ごとの確認を始めます。続行しますか？" || die "中断しました。"
fi

# ------------------------------------------------------------------------------
# 6. 実行（進行を、リアルタイムに表示する）
# ------------------------------------------------------------------------------
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sf-typecheck-XXXXXX") || die "作業用フォルダを作成できません。"  # VAR=$(cmd) のため run 不使用
trap 'rm -rf "$WORK_DIR"' EXIT
NODE_ARGS=(--org "$ORG_ALIAS" --work "$WORK_DIR" --mode "$MODE" --out "$OUT_FILE")
[[ -n "$ONLY" ]] && NODE_ARGS+=(--only "$ONLY")

log "INFO" "確認を始めます（種類ごとに、数十秒かかります。進行を表示します）"
node "$TYPECHECK_JS" "${NODE_ARGS[@]}"  # 進行をリアルタイムに表示するため run 不使用（終了コードで判定する）
rc=$?
case "$rc" in
    0) log "SUCCESS" "すべての種類で、確認が通りました。結果: ${OUT_FILE}" ;;
    3) log "WARNING" "リリース・削除できない種類があります（上の表と ${OUT_FILE} を確認してください）。" ;;
    *) die "確認の実行に失敗しました（終了コード ${rc}）。" ;;
esac
exit $RET_OK
