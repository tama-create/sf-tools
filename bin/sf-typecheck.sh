#!/bin/bash
# ==============================================================================
# sf-typecheck.sh - メタデータの種類ごとに、リリースと削除ができるかを、実際の組織で確かめる（管理者向け）
# ==============================================================================
# 種類ごとの最小のサンプル（lib/typecheck.js に定義）を、一時フォルダの使い捨てのプロジェクトに作り、指定した組織に、
# 実際にリリースして、削除し、結果を表（種類 / release / delete / 備考）にする。この表は、config/metadata-capability.txt の元になる。
# sf-check.sh が、その表を読んで、リリース・削除できないと確認済みの種類を、ターゲットファイルの検証で止める。
#
# 【使い方】
#   sf-typecheck.sh --org ALIAS                       # リリースして、削除する
#   sf-typecheck.sh --org ALIAS --validate-only       # 検証だけ（組織には、何も反映しない。削除は、確認しない）
#   sf-typecheck.sh --org ALIAS --only ApexPage,Queue # 種類を絞る
#   sf-typecheck.sh --list                            # 確認する種類の一覧だけ（組織には、接続しない）
#   sf-typecheck.sh --coverage                        # 変更セット対応の種類の、確認の進み具合（組織には、接続しない）
#
# 【オプション】
#   --org ALIAS        : 接続先の組織のエイリアス（--list・--coverage 以外では必須）
#   --validate-only    : 検証（sf project deploy validate）だけ行う。delete の列は unknown のまま
#   --only A,B         : 指定した種類だけ確認する（--list に出る名前と完全一致。一致しない名前は無視し、
#                        1 つも一致しなければ 0 種類で正常終了する）
#   --out FILE         : 結果の表（TSV・見出し行なし）の出力先。既定: ./sf-typecheck-result.txt（カレントディレクトリ）。
#                        すべての種類を処理し終えたときだけ書く（上書き）
#   --list             : 確認する種類の一覧（lib/typecheck.js のサンプルの種類）を出して終了する
#   --coverage         : config/changeset-types.txt（変更セットで扱える種類。公式の一覧）と、
#                        config/metadata-capability.txt（実機で確認した結果）を突き合わせ、次の区分ごとの数を出す:
#                        リリースも削除も ok / リリースのみ ok / ng または limited を含む / 判定できない / 表にない。
#                        種類の一覧は、ok 以外の 4 区分だけ出す。組織には、接続しない
#   -y, --yes          : 冒頭の確認（Y/N）を省略する（警告ボックスは、表示する）
#   -h, --help         : このヘルプを表示する（第 1 引数のときだけ有効）
#   上記以外の引数は「不明なオプションです」で中断する。
#
# 【処理の流れ】
#   1. 赤い警告ボックスを表示し、[Y/N/q] で確認する（N / q なら中断。-y で確認だけを省略）。--list・--coverage も同じ
#   2. --coverage のときは、表の突き合わせ（awk のみ）の結果を出して終了する
#   3. lib/typecheck.js と node があることを確認する。--list のときは、一覧を出して終了する
#   4. 安全の確認（どれかに当たれば、何もせずに中断する）
#        GITHUB_ACTIONS=true / --org がない / --org が予約名（prod・staging・develop・main）/
#        sf --version の終了コードが 0 以外（npm 版の sf が前提。24 時間以内に成功を確認済みなら、省略）/
#        組織の情報（Organization の IsSandbox・OrganizationType・TrialExpirationDate）を読み取れない /
#        組織の種類が本番、または判定できない
#      組織の種類: IsSandbox=true → Sandbox、OrganizationType に Developer を含む → Developer Edition、
#      TrialExpirationDate がある → Trial、OrganizationType が空 → 判定できない、それ以外 → 本番
#   5. 一時フォルダ（${TMPDIR:-/tmp}/sf-typecheck-XXXXXX。終了時に削除）で、lib/typecheck.js を実行する。
#      種類ごとに、sf project deploy start でリリースし、成功したら、destructiveChanges.xml で削除する。
#      --validate-only のときは、sf project deploy validate だけを行い、削除はしない（詳細は lib/typecheck.js の冒頭）
#   6. lib/typecheck.js の終了コードが 0 なら SUCCESS、3（ng の種類がある）なら WARNING を表示して、終了コード 0 で終わる。
#      それ以外は、中断する
#
# 【前提条件】
#   - force-* の外でも実行できる（組織だけを対象にする）
#   - 接続先の組織に、sf でログイン済みであること（予約名以外のエイリアス）
#   - node と、npm 版の sf（Salesforce CLI）
#
# 【補足】
#   - 拒否するのは、上の 4. の条件だけ。Sandbox が個人用か共有かは、判定しない
#   - --list・--coverage は、GitHub Actions 上でも実行できる（4. の確認より前に終了するため）
#   - 作成・削除するのは、名前（ファイルのパス・削除するメンバー名）に SfToolsE2eMin を含むものだけ
#     （大文字・小文字を区別する）。Account には、この名前のもの（ワークフロールール・項目自動更新・メールアラート・
#     承認プロセス・カスタムボタン・トリガー）を追加し、削除するときも、その名前だけを指定する。
#     冒頭の警告の文面は「SfToolsE2eMin で始まるもの」だが、判定は「含む」（例: Account.SfToolsE2eMinWr）
#   - 現在、LightningComponentBundle のサンプルの名前は sfToolsE2eMinLwc（先頭が小文字）のため、この判定に当たり、
#     lib/typecheck.js が中断する（終了コード 1）。--only でこの種類を除かない限り、6 番目の種類で中断し、
#     それまでの 5 種類のリリース・削除（--validate-only なら検証）は、実行済みになる。結果の表（--out）は、書かれない
#   - 終了コード: 0 = 完了（release / delete に ng の種類があっても 0。WARNING を表示する）・--list・--coverage /
#     1 = 中断（N / q の回答、4. の拒否、必要なファイル・node がない、lib/typecheck.js の失敗）
#   - ログ: ~/sf-tools/logs/sf-typecheck.log（実行ごとに作り直す）
#   - 環境変数: SF_TYPECHECK_CHANGESET_FILE・SF_CHECK_CAPABILITY_FILE で、--coverage が読む 2 つの表を差し替えられる
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

# ------------------------------------------------------------------------------
# 3b. 管理者向けの警告と確認（最初に行う。CLAUDE.md 2.4）。警告を出しただけで、先へ進まない: 確認して、はじめて実行する
#     --list・--coverage（読み取りのみ）も、同じ。-y で、確認を省略できる（警告は、表示する）
# ------------------------------------------------------------------------------
echo "" >&2
if [[ $COVERAGE -eq 1 || $LIST_ONLY -eq 1 ]]; then
    print_admin_warning --standard "読み取りのみです（組織には、接続しません）。"
elif [[ "$MODE" == "full" ]]; then
    print_admin_warning --standard "個人用の組織へ、実際に、リリースして、削除します。" "名前は SfToolsE2eMin で始まるものだけ扱います。"
else
    print_admin_warning --standard "個人用の組織で、検証だけ行います（何も反映しません）。" "名前は SfToolsE2eMin で始まるものだけ扱います。"
fi
echo "" >&2
if [[ $ASSUME_YES -eq 0 ]]; then
    ask_yn "続行しますか？" || die "中断しました。"
fi

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
# 5. （接続先の表示は、4. の最後で行う。警告と確認は、冒頭の 3b. で、済んでいる）
# ------------------------------------------------------------------------------

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
