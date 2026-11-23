#!/bin/bash
# ==============================================================================
# sf-log.sh - AI の開発サイクル用に、Apex ログを手元に取り、AI 向けの要約を作る
# ==============================================================================
# 自分のユーザーの Apex ログを、TraceFlag で出させて手元（logs/apex/）に保存し、AI が最初に読む要約
# （logs/apex/latest.md）を作る。ログを読むのは人ではなく AI（Claude Code など）。
# 設計: doc/sf-log-design.md（要約・一覧の検査・日時の計算は lib/apexlog.js）
#
# 【使い方】
#   sf-log.sh pull [-o ALIAS] [--max N] [--since 分]      # 新しいログを取って、要約を作る（AI が実行する。組織には書き込まない）
#   sf-log.sh status [-o ALIAS]                           # 状態を表示する（読み取りのみ）
#   sf-log.sh auto on|off [-o ALIAS]                      # sf-start のときに自動で取るか（このプロジェクトの答え）を変える
#   sf-log.sh start [-o ALIAS] [--level standard|detail] [--hours N] [-y]   # 取り始める（TraceFlag を作る・延ばす）
#   sf-log.sh stop [-o ALIAS]                             # 止める（自分が作った TraceFlag を消す）
#   sf-log.sh start --auto [--owner 印]                   # 内部用（sf-start.sh が呼ぶ。確認で止まらない）
#
# 【オプション】
#   -o ALIAS            : 接続先の組織のエイリアス（省略時: 環境変数 SF_TARGET_ORG > sf org display の alias）
#   --level standard|detail : （start）ログの詳しさ（doc/sf-log-design.md 7 章）。既定 standard。--auto は常に standard
#   --hours N           : （start）TraceFlag の期限（時間）。1〜23 の整数（公式: 開始から 24 時間未満）。既定 2
#   -y                  : （start）AI への送信の確認と、ほかの USER_DEBUG の TraceFlag を止める確認を省く（手動のみ）
#   --auto              : （start）sf-start.sh からの自動の取り始め。終了コード 0 = 取り始めた／10 = 取らない／1 = 失敗
#   --owner 印          : （start --auto）持ち主（sf-start）の印。「数字:数字:英数字」
#   --max N             : （pull）要約に入れるログの数の上限（1 以上の整数。既定 50。超えたら新しいほうから）
#   --since 分          : （pull）前回の pull を無視して、直近 N 分に始まったログを要約する（1 以上の整数）
#   -v, --verbose       : コマンドの応答（出力）をコンソールにも表示する
#   -h, --help          : このヘルプを表示する（1 番目の引数のときだけ）
#
# 【処理の流れ】
#   共通（status・auto 以外）:
#     1. sf の確認（check_sf_cli --cache）・接続先の決定（get_target_org）
#     2. （start・pull）接続先が予約名（prod / staging / develop / main）・本番・種類を確認できない組織なら止める
#        （手動: 中断／--auto: 終了コード 10）
#     3. 自分のユーザー ID と組織 ID（sf org display user --json）
#   start:
#     4. （--auto）GitHub Actions 上なら 10。このプロジェクトの答え（logs/apex/.consent）が「取らない」なら 10。
#        答えがない・組織が変わった・注意の文面の版が変わったときは、注意を表示して Y/N で聞く（端末でない・q・N は「取らない」）
#        （手動）注意を表示し、ask_yn || die（-y で省く）
#     5. DebugLevel「sf_tools_log_<level>」を名前で探し、あれば 7 章の値で上書き、なければ作る（2 つ以上なら止める）
#     6. 自分のユーザーの TraceFlag を探す（lib/apexlog.js tflist で、有効・期限切れ・これから始まるものに分ける）
#        a. .state の TRACE_FLAG_ID と一致する USER_DEBUG → DebugLevel・開始（今）・期限（今から --hours 時間）を更新
#        b. ほかの有効な USER_DEBUG が 2 つ以上 → 止める／1 つ → 手動: 表示して確認のあと、期限を「元の期限」と
#           「今から 2 分後」の早いほうに縮める（今にはできない）。--auto: 触らずに 10
#           DEVELOPER_LOG・ほかの種類には触れない（USER_DEBUG とぶつからない）
#        c. 作る（USER_DEBUG。開始は今。b で縮めたときは、その期限の 1 秒後。それが過ぎていれば今）。
#           b で縮めたあとに作成が失敗しても、元に戻さない（縮めた ID・元の期限・縮めた期限を書く）
#     7. .state に組織・ユーザー ID・TraceFlag の ID を書く（組織・ユーザーが変わったら、取得と要約の時刻を今にする）
#     8. 組織のログの量を表示し、700MB を超えていれば WARNING（組織の上限は 1,000MB）
#   pull:
#     4. 取得のロック（logs/apex/.fetch.lock。最大 90 秒待つ）を持ち、しおり（.state の LAST_FETCH・LAST_FETCH_ID）から
#        古い順に取る（1 回 50 本。最大 4 回 = 200 本）。一覧は全ユーザーの見出し（run を通さない。他の人の ID を記録しない）、
#        本文は自分のログだけを保存する。取りたいログより新しいログがすべて自分のものなら sf apex get log -n でまとめて、
#        それ以外は -i で 1 本ずつ取る。本文は logs/apex/.fetch/ に書かせ、取りたい ID 以外は中を読まずに消す
#     5. 保存: logs/apex/<日付>/<時刻>_<ID>_<操作>.log（日付・時刻は PC のタイムゾーン）と、目録 logs/apex/.index
#     6. 目録から、前回の要約（.state の LAST_READ）より後に始まったログを選ぶ（--since なら直近 N 分。--max を超えたら新しいほう）
#     7. 要約を作り（node lib/apexlog.js summarize）、logs/apex/summaries/<時刻>.md と logs/apex/latest.md に書く
#     8. 要約に入れた最も新しいログの開始時刻を LAST_READ にする。要約の 1 行目と latest.md のパスを表示する
#   stop:
#     4. .owners に CLOSING を書き、.state の TRACE_FLAG_ID の TraceFlag を消す（すでになければ WARNING）
#     5. TRACE_FLAG_ID・.owners を消し、.status を stopped にする。DebugLevel・手元のログは消さない
#   status: 手元の状態（.status・.state）、自分のユーザーの TraceFlag、自分のログの本数と合計を表示する（読み取りのみ）
#   auto on|off: logs/apex/.consent の AUTO・ORG_ID・VERSION を書く（組織には書き込まない）
#
# 【前提条件】
#   - force-* ディレクトリ（プロジェクトのルート）で実行すること
#   - Salesforce CLI（npm 版）と Node（sf に含まれる）。接続ユーザーが DebugLevel・TraceFlag を作れること
#   - 一人用の開発組織（Developer Edition・Sandbox・スクラッチ組織）で、ダミーデータで使うこと
#
# 【補足】
#   - 終了コード: 0 = 成功／1 = 失敗（手動の中断を含む）／10 = 取らない（start --auto のみ）
#   - ログには、レコードの値・SOQL の条件などが載る。AI に読ませると、AI の提供元に送られる（start の確認）
#   - 手元のログ（logs/apex/）は Git の管理外。stop も消さない。消すときは、日付のフォルダを手で消す
#   - 他の人のログは、本文を保存・記録・要約しない。sf apex get log -n の直後にできた他の人のログが
#     logs/apex/.fetch/ に一瞬書かれることがあるが、中を読まずに消す（取得のたびに空にする）
#   - 裏の取得役（collect）・sf-start からの後始末（leave）・ランチャーの表示は、まだない（設計 4.3・5 章。第 2 段で作る）
#   - ログ: ./sf-tools/logs/sf-log.log（追記）
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 共通ライブラリの必須設定
# ------------------------------------------------------------------------------
SCRIPT_NAME="${0##*/}"; readonly SCRIPT_NAME="${SCRIPT_NAME%.sh}"
readonly LOG_FILE="./sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="APPEND"   # pull・start・stop が同じログに書く（取得の記録を残す）

# ------------------------------------------------------------------------------
# 2. 共通ライブラリの読み込み
# ------------------------------------------------------------------------------
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR/" == /* && "$SCRIPT_DIR/" != *//* && "$SCRIPT_DIR/" != */./* && "$SCRIPT_DIR/" != */../* ]] || SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
# 3. 定数・引数
# ------------------------------------------------------------------------------
readonly AJS="${SCRIPT_DIR}/../lib/apexlog.js"
readonly APEX_DIR="logs/apex"
readonly STATE_F="${APEX_DIR}/.state"
readonly STATUS_F="${APEX_DIR}/.status"
readonly CONSENT_F="${APEX_DIR}/.consent"
readonly OWNERS_F="${APEX_DIR}/.owners"
readonly COLLECTOR_F="${APEX_DIR}/.collector"
readonly INDEX_F="${APEX_DIR}/.index"
readonly LOCK_DIR="${APEX_DIR}/.lock"
readonly FETCH_LOCK="${APEX_DIR}/.fetch.lock"
readonly FETCH_TMP="${APEX_DIR}/.fetch"
readonly CONSENT_VERSION="1"            # AI への送信の注意の文面の版（変えたら上げる。10.2）
readonly ORG_LOG_WARN_BYTES=$((700 * 1024 * 1024))
readonly ID_RE='^[A-Za-z0-9]{15}([A-Za-z0-9]{3})?$'
readonly ISO_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'

CMD="${1:-}"
[[ -n "$CMD" ]] || die "サブコマンドを指定してください（pull / status / auto / start / stop）。"
shift
AUTO_ARG=""
if [[ "$CMD" == "auto" ]]; then
    AUTO_ARG="${1:-}"
    [[ "$AUTO_ARG" == "on" || "$AUTO_ARG" == "off" ]] || die "auto には on か off を指定してください。"
    shift
fi
ORG_ARG=""; LEVEL="standard"; HOURS=2; YES=0; AUTO=0; OWNER=""; MAX_LOGS=50; SINCE_MIN=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o)        [[ -n "${2:-}" && "${2:-}" != -* ]] || die "-o の値（組織のエイリアス）がありません。"; ORG_ARG="$2"; shift ;;
        --level)   LEVEL="${2:-}"; shift ;;
        --hours)   HOURS="${2:-}"; shift ;;
        -y)        YES=1 ;;
        --auto)    AUTO=1 ;;
        --owner)   OWNER="${2:-}"; shift ;;
        --max)     MAX_LOGS="${2:-}"; shift ;;
        --since)   SINCE_MIN="${2:-}"; shift ;;
        -v|--verbose) : ;;   # SILENT_EXEC は common.sh が設定済み
        *)         die "不明なオプションです: $1" ;;
    esac
    shift
done
case "$CMD" in
    start|pull|stop|status|auto) ;;
    *) die "不明なサブコマンドです: ${CMD}（pull / status / auto / start / stop）" ;;
esac
[[ "$LEVEL" == "standard" || "$LEVEL" == "detail" ]] || die "--level は standard か detail です: ${LEVEL}"
[[ "$HOURS" =~ ^[0-9]+$ && "$HOURS" -ge 1 && "$HOURS" -le 23 ]] || die "--hours は 1〜23 の整数です: ${HOURS}"
[[ "$MAX_LOGS" =~ ^[0-9]+$ && "$MAX_LOGS" -ge 1 ]] || die "--max は 1 以上の整数です: ${MAX_LOGS}"
[[ -z "$SINCE_MIN" || ( "$SINCE_MIN" =~ ^[0-9]+$ && "$SINCE_MIN" -ge 1 ) ]] || die "--since は 1 以上の整数（分）です: ${SINCE_MIN}"
[[ -z "$OWNER" || "$OWNER" =~ ^[0-9]+:[0-9]+:[A-Za-z0-9]+$ ]] || die "--owner の形が正しくありません: ${OWNER}"
if [[ $AUTO -eq 1 ]]; then
    [[ "$CMD" == "start" ]] || die "--auto は start だけに付けられます。"
    LEVEL="standard"; YES=0
fi
command -v node >/dev/null 2>&1 || die "node が見つかりません（sf CLI の npm 版に必要です）。"  # 存在確認のため run 不使用
mkdir -p "$APEX_DIR"  # run 不使用: 自分の作業フォルダを作るだけ（失敗は、次の書き込みで分かる）

# ------------------------------------------------------------------------------
# 4. 小さな部品
# ------------------------------------------------------------------------------
# キー=値 のファイルから 1 つ読む（source しない。決まったキーだけ）
kv_get() {
    local f="$1" k="$2" line
    [[ -f "$f" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        if [[ "$line" == "$k="* ]]; then printf '%s' "${line#*=}"; return 0; fi
    done < "$f"
}

# キー=値 のファイルの、指定したキーだけを差し替える（一時ファイルに書いてから mv。短いロックの中で呼ぶ）
#   引数: ファイル KEY=VALUE ...（値に改行を入れない）
kv_set() {
    local f="$1"; shift
    local tmp="${f}.tmp.$$" line kv skip
    : > "$tmp" || return 1
    if [[ -f "$f" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            skip=0
            for kv in "$@"; do [[ "$line" == "${kv%%=*}="* ]] && skip=1; done
            [[ $skip -eq 1 ]] || printf '%s\n' "$line" >> "$tmp"
        done < "$f"
    fi
    for kv in "$@"; do printf '%s\n' "${kv//$'\n'/ }" >> "$tmp"; done
    mv -f "$tmp" "$f"
}

# ロック（mkdir。macOS に flock がないため）。中に PID を書き、その PID が死んでいれば古いロックとして消す
#   引数: フォルダ 待つ回数（0.2 秒ごと）。取れなければ 1
lock_take() {
    local d="$1" tries="$2" i=0 pid
    while ! mkdir "$d" 2>/dev/null; do  # 条件チェックのため run 不使用（作れたら自分のもの）
        pid=$(cat "$d/pid" 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
        if [[ "$pid" =~ ^[0-9]+$ ]] && ! kill -0 "$pid" 2>/dev/null; then  # 条件チェックのため run 不使用（持ち主の生死）
            rm -rf "$d" 2>/dev/null || true   # 意図的エラー無視: 古いロック（ほかの人が先に消すこともある）
            continue
        fi
        i=$((i + 1))
        [[ $i -ge $tries ]] && return 1
        sleep 0.2  # run 不使用: 待つだけ
    done
    printf '%s\n' "$$" > "$d/pid"
}
lock_drop() { rm -rf "$1" 2>/dev/null || true; }  # 意図的エラー無視: 自分のロックを外すだけ

# .state などを書き換える（短いロックの中で kv_set）
state_set() {
    local f="$1"; shift
    lock_take "$LOCK_DIR" 50 || { log "WARNING" "手元の状態のロックを取れませんでした（${LOCK_DIR}）。"; return 1; }
    kv_set "$f" "$@"; local rc=$?
    lock_drop "$LOCK_DIR"
    return $rc
}

aj() { node "$AJS" "$@"; }   # lib/apexlog.js（境界は 1 か所）
now_z() { aj time now; }

# 失敗・取らないときの終わり方。手動: die（取らない理由も中断）／--auto: .status に書いて、終了コードで返す
#   引数: 終了コード（1 / 10） 理由
finish_auto_or_die() {
    local code="$1" reason="$2"
    if [[ $AUTO -eq 1 ]]; then
        if [[ "$code" -eq 10 ]]; then
            log "INFO" "Apex ログは取りません（${reason}）。"
            state_set "$STATUS_F" "STATE=skipped" "REASON=${reason}" "ORG=${TARGET_ORG:-}" || true   # 意図的エラー無視: 表示用
        else
            log "WARNING" "Apex ログを取れませんでした（${reason}）。"
            state_set "$STATUS_F" "STATE=error" "REASON=${reason}" "ORG=${TARGET_ORG:-}" || true      # 意図的エラー無視: 表示用
        fi
        exit "$code"
    fi
    die "$reason"
}

# sf の --json の応答から name を読む（読めなければ「不明」）
sf_err_name() { local n; n=$(json_get "$1" name 2>/dev/null) || n=""; printf '%s' "${n:-不明}"; }  # VAR=$(cmd) のため run 不使用

# ------------------------------------------------------------------------------
# 5. 接続先の確認（4.1）
#   引数: full（予約名・本番も確かめる）/ light
# ------------------------------------------------------------------------------
TARGET_ORG=""; USER_ID=""; ORG_ID=""
prepare_org() {
    local mode="$1" rc j
    check_sf_cli --cache
    TARGET_ORG=$(get_target_org "$ORG_ARG") || finish_auto_or_die 1 "接続先の組織エイリアスを特定できません"
    if [[ "$mode" == "full" ]]; then
        if is_reserved_org_alias "$TARGET_ORG"; then
            finish_auto_or_die 10 "${TARGET_ORG} は共有環境（予約名）のため"
        fi
        rc=0
        org_local_release_check "$TARGET_ORG" || rc=$?  # run 不使用: 戻り値で分岐する（run は、戻り値を変える）
        case "$rc" in
            1) finish_auto_or_die 10 "${TARGET_ORG} は本番組織のため" ;;
            2) finish_auto_or_die 10 "${TARGET_ORG} の組織の種類を確認できないため" ;;
        esac
    fi
    j=$(run sf org display user --target-org "$TARGET_ORG" --json) || finish_auto_or_die 1 "ユーザーの情報を取得できません（$(sf_err_name "$j")）"
    USER_ID=$(json_get "$j" result.id) || USER_ID=""   # VAR=$(cmd) のため run 不使用
    ORG_ID=$(json_get "$j" result.orgId) || ORG_ID=""  # VAR=$(cmd) のため run 不使用
    [[ "$USER_ID" =~ $ID_RE ]] || finish_auto_or_die 1 "ユーザー ID の形が正しくありません"
    [[ "$ORG_ID" =~ $ID_RE ]] || finish_auto_or_die 1 "組織 ID の形が正しくありません"
}

# ------------------------------------------------------------------------------
# 6. start（4.2）
# ------------------------------------------------------------------------------
NOTICE_TEXT="ログには、レコードの値・SOQL の条件・コールアウトの内容が載ります。ログは AI に読ませる前提で、読ませると AI の提供元に送られます。ダミーデータの組織で使ってください。本番のデータを写した Sandbox（Full・Partial）では、使わないでください。"

# --auto の確認（10.2）。0 = 取る／1 = 取らない
auto_consent() {
    local a o v ans
    a=$(kv_get "$CONSENT_F" AUTO); o=$(kv_get "$CONSENT_F" ORG_ID); v=$(kv_get "$CONSENT_F" VERSION)  # VAR=$(cmd) のため run 不使用
    if [[ -n "$a" && "$o" == "$ORG_ID" && "$v" == "$CONSENT_VERSION" ]]; then
        [[ "$a" == "on" ]] && return 0
        return 1
    fi
    log "INFO" "ランチャーの起動中、この組織（${TARGET_ORG}）の Apex ログを、裏で自動で手元に保存できます。"
    log "INFO" "  ${NOTICE_TEXT}"
    log "INFO" "  あとから sf-log.sh auto on|off で変えられます。"
    if [[ ! -t 0 ]]; then
        log "INFO" "  確認できない（端末ではない）ため、今回は取りません（答えは保存しません）。"
        return 1
    fi
    # read_key は EOF で die するため、$( ) の中で呼ぶ（ランチャーを止めない）。q も「取らない」
    ans=$(read_key _k "  自動で取りますか？ [Y/N/q]: " "[YyNnQq]"; printf '%s' "${_k:-}") || ans=""  # VAR=$(cmd) のため run 不使用
    case "$ans" in
        [Yy]) state_set "$CONSENT_F" "AUTO=on" "ORG_ID=${ORG_ID}" "VERSION=${CONSENT_VERSION}" "ANSWERED_AT=$(now_z)" || true; return 0 ;;
        [Nn]|[Qq]) state_set "$CONSENT_F" "AUTO=off" "ORG_ID=${ORG_ID}" "VERSION=${CONSENT_VERSION}" "ANSWERED_AT=$(now_z)" || true; return 1 ;;
        *) return 1 ;;
    esac
}

debuglevel_values() {
    case "$LEVEL" in
        standard) echo "ApexCode=FINE ApexProfiling=INFO Workflow=FINE Database=INFO Validation=INFO Callout=INFO System=DEBUG Visualforce=INFO" ;;
        detail)   echo "ApexCode=FINEST ApexProfiling=FINE Workflow=FINER Database=FINEST Validation=INFO Callout=FINEST System=DEBUG Visualforce=FINE" ;;
    esac
}

# DebugLevel を探し、上書きするか作る（8.1）。結果: DL_ID
DL_ID=""
ensure_debuglevel() {
    local name="sf_tools_log_${LEVEL}" j n vals
    vals=$(debuglevel_values)
    j=$(run sf data query --use-tooling-api --target-org "$TARGET_ORG" --json \
        --query "SELECT Id FROM DebugLevel WHERE DeveloperName = '${name}'") || finish_auto_or_die 1 "DebugLevel を検索できません（$(sf_err_name "$j")）"
    n=$(json_get "$j" result.totalSize) || n=""  # VAR=$(cmd) のため run 不使用
    case "$n" in
        0)
            j=$(run sf data create record --use-tooling-api --sobject DebugLevel --target-org "$TARGET_ORG" --json \
                --values "DeveloperName=${name} MasterLabel=${name} ${vals}") || finish_auto_or_die 1 "DebugLevel を作れません（$(sf_err_name "$j")）"
            DL_ID=$(json_get "$j" result.id) || DL_ID=""  # VAR=$(cmd) のため run 不使用
            ;;
        1)
            DL_ID=$(json_get "$j" result.records.0.Id) || DL_ID=""  # VAR=$(cmd) のため run 不使用
            [[ "$DL_ID" =~ $ID_RE ]] || finish_auto_or_die 1 "DebugLevel の ID の形が正しくありません"
            run sf data update record --use-tooling-api --sobject DebugLevel --record-id "$DL_ID" --target-org "$TARGET_ORG" --json \
                --values "$vals" >/dev/null || finish_auto_or_die 1 "DebugLevel を上書きできません"
            ;;
        *)
            finish_auto_or_die 10 "DebugLevel「${name}」が 1 つに決まりません（${n:-不明} 件）"
            ;;
    esac
    [[ "$DL_ID" =~ $ID_RE ]] || finish_auto_or_die 1 "DebugLevel の ID の形が正しくありません"
}

# TraceFlag を延ばすか作る（4.2 の 3・8.2）。結果: TF_ID・TF_EXPIRES
TF_ID=""; TF_EXPIRES=""
ensure_traceflag() {
    local j now tsv mine other_ids=() other_exp=() line id type st ex state dl start new_exp shrunk="" rc
    now=$(now_z)
    j=$(run sf data query --use-tooling-api --target-org "$TARGET_ORG" --json \
        --query "SELECT Id, LogType, StartDate, ExpirationDate, DebugLevel.DeveloperName FROM TraceFlag WHERE TracedEntityId = '${USER_ID}'") \
        || finish_auto_or_die 1 "TraceFlag を検索できません（$(sf_err_name "$j")）"
    tsv=$(printf '%s' "$j" | aj tflist --now "$now") || finish_auto_or_die 1 "TraceFlag の検索の応答の形が正しくありません"
    mine=$(kv_get "$STATE_F" TRACE_FLAG_ID)  # VAR=$(cmd) のため run 不使用
    [[ "$mine" =~ $ID_RE ]] || mine=""
    local found_mine=0
    while IFS=$'\t' read -r id type st ex state dl; do
        [[ -n "$id" ]] || continue
        if [[ -n "$mine" && "$id" == "$mine" && "$type" == "USER_DEBUG" ]]; then found_mine=1; continue; fi
        if [[ "$type" == "USER_DEBUG" && "$state" == "active" ]]; then other_ids+=("$id"); other_exp+=("$ex"); fi
    done <<< "$tsv"

    # a. 自分が作ったもの → 延ばす
    if [[ $found_mine -eq 1 ]]; then
        TF_EXPIRES=$(aj time add "$now" --sec $((HOURS * 3600)))
        j=$(run sf data update record --use-tooling-api --sobject TraceFlag --record-id "$mine" --target-org "$TARGET_ORG" --json \
            --values "DebugLevelId=${DL_ID} StartDate=${now} ExpirationDate=${TF_EXPIRES}") \
            || finish_auto_or_die 1 "TraceFlag を延ばせません（$(sf_err_name "$j")）"
        TF_ID="$mine"
        return 0
    fi

    # b. ほかの有効な USER_DEBUG
    start="$now"
    if [[ ${#other_ids[@]} -ge 2 ]]; then
        finish_auto_or_die 10 "このユーザーに、有効な USER_DEBUG の TraceFlag が ${#other_ids[@]} つあります"
    elif [[ ${#other_ids[@]} -eq 1 ]]; then
        if [[ $AUTO -eq 1 ]]; then
            log "WARNING" "ほかの USER_DEBUG の TraceFlag（${other_ids[0]}・期限 ${other_exp[0]}）があります。sf-log.sh start で置き換えられます。"
            finish_auto_or_die 10 "ほかの USER_DEBUG の TraceFlag があるため"
        fi
        log "WARNING" "このユーザーに、ほかの USER_DEBUG の TraceFlag があります（設定画面などで作られた、このユーザーのログの設定です）。"
        log "WARNING" "  ID: ${other_ids[0]}・期限: ${other_exp[0]}"
        log "WARNING" "  止めると、期限を「元の期限」と「今から 2 分後」の早いほうに縮めます（消しません）。"
        if [[ $YES -eq 0 ]]; then ask_yn "この TraceFlag を止めて、sf-log.sh の TraceFlag を作りますか？" || die "中断しました。"; fi
        new_exp=$(aj time min "${other_exp[0]}" "$(aj time now --plus-sec 120)")
        if [[ "$new_exp" != "${other_exp[0]}" ]]; then
            run sf data update record --use-tooling-api --sobject TraceFlag --record-id "${other_ids[0]}" --target-org "$TARGET_ORG" --json \
                --values "ExpirationDate=${new_exp}" >/dev/null || die "ほかの TraceFlag の期限を縮められません（新しい TraceFlag は作っていません）。"
            shrunk="${other_ids[0]}（元の期限 ${other_exp[0]} → ${new_exp}）"
        fi
        start=$(aj time add "$new_exp" --sec 1)
        # 作る直前に今と比べ、過ぎていれば今にする（止めたものは、もう有効でないため重ならない）
        now=$(now_z)
        [[ "$(aj time cmp "$start" "$now")" == "-1" ]] && start="$now"
    fi

    # c. 作る
    TF_EXPIRES=$(aj time add "$start" --sec $((HOURS * 3600)))
    rc=0
    j=$(run sf data create record --use-tooling-api --sobject TraceFlag --target-org "$TARGET_ORG" --json \
        --values "TracedEntityId=${USER_ID} LogType=USER_DEBUG DebugLevelId=${DL_ID} StartDate=${start} ExpirationDate=${TF_EXPIRES}") || rc=$?
    if [[ $rc -ne 0 ]]; then
        [[ -n "$shrunk" ]] && log "ERROR" "縮めた TraceFlag は、元に戻していません: ${shrunk}"
        finish_auto_or_die 1 "TraceFlag を作れません（$(sf_err_name "$j")）"
    fi
    TF_ID=$(json_get "$j" result.id) || TF_ID=""  # VAR=$(cmd) のため run 不使用
    [[ "$TF_ID" =~ $ID_RE ]] || finish_auto_or_die 1 "作った TraceFlag の ID の形が正しくありません"
}

cmd_start() {
    local prev_org prev_user now vol n s
    if [[ $AUTO -eq 1 && "${GITHUB_ACTIONS:-}" == "true" ]]; then
        log "INFO" "GitHub Actions の上では、Apex ログを取りません。"
        exit 10
    fi
    prepare_org full
    if [[ $AUTO -eq 1 ]]; then
        auto_consent || finish_auto_or_die 10 "このプロジェクトでは、自動で取らない設定のため"
    else
        log "WARNING" "$NOTICE_TEXT"
        if [[ $YES -eq 0 ]]; then ask_yn "${TARGET_ORG} の Apex ログを取り始めますか？" || die "中断しました。"; fi
    fi
    ensure_debuglevel
    ensure_traceflag

    # .state（組織・ユーザーが変わったら、取得と要約の時刻を今にする）
    prev_org=$(kv_get "$STATE_F" ORG); prev_user=$(kv_get "$STATE_F" USER_ID)  # VAR=$(cmd) のため run 不使用
    now=$(now_z)
    if [[ "$prev_org" != "$TARGET_ORG" || "$prev_user" != "$USER_ID" || -z "$(kv_get "$STATE_F" LAST_FETCH)" ]]; then
        state_set "$STATE_F" "ORG=${TARGET_ORG}" "USER_ID=${USER_ID}" "TRACE_FLAG_ID=${TF_ID}" \
            "LAST_FETCH=${now}" "LAST_FETCH_ID=" "LAST_READ=${now}" "LAST_READ_IDS=" || finish_auto_or_die 1 "手元の状態を書けません"
    else
        state_set "$STATE_F" "ORG=${TARGET_ORG}" "USER_ID=${USER_ID}" "TRACE_FLAG_ID=${TF_ID}" || finish_auto_or_die 1 "手元の状態を書けません"
    fi
    state_set "$STATUS_F" "STATE=collecting" "ORG=${TARGET_ORG}" "EXPIRES=${TF_EXPIRES}" "REASON=" || true   # 意図的エラー無視: 表示用

    # 組織のログの量（8.6）
    vol=$(run sf data query --use-tooling-api --target-org "$TARGET_ORG" --json \
        --query "SELECT COUNT(Id) n, SUM(LogLength) s FROM ApexLog") || vol=""
    n=$(json_get "$vol" result.records.0.n 2>/dev/null) || n=""   # VAR=$(cmd) のため run 不使用
    s=$(json_get "$vol" result.records.0.s 2>/dev/null) || s=""   # VAR=$(cmd) のため run 不使用
    [[ "$s" =~ ^[0-9]+$ ]] || s=0
    log "SUCCESS" "Apex ログを取り始めました（組織: ${TARGET_ORG}・TraceFlag: ${TF_ID}・期限: ${TF_EXPIRES}（UTC））。"
    [[ "$n" =~ ^[0-9]+$ ]] && log "INFO" "  組織のログ: ${n} 本・$((s / 1024 / 1024))MB（上限 1,000MB）"
    if [[ "$s" -gt "$ORG_LOG_WARN_BYTES" ]]; then
        log "WARNING" "組織のログが 700MB を超えています。1,000MB を超えると、TraceFlag を作れなくなります。"
    fi
    exit 0
}

# ------------------------------------------------------------------------------
# 7. 取得（4.3 の 2c・8.3・8.4）
# ------------------------------------------------------------------------------
# 操作名をファイル名の飾りにする（英数字・_・- 以外を _ に。先頭と末尾の _ を除く。最大 30 文字）
op_slug() {
    local s
    s=$(printf '%s' "$1" | LC_ALL=C sed 's/[^A-Za-z0-9_-]/_/g; s/^_*//; s/_*$//')  # VAR=$(cmd) のため run 不使用
    printf '%s' "${s:0:30}"
}

# 1 本を保存する（置き換えで。同じ名前がすでにあれば、成功として扱う）。引数: 元のファイル ID 開始 操作 状態 長さ 所要
save_one() {
    local src="$1" id="$2" st="$3" op="$4" status="$5" len="$6" dur="$7" dt d t slug name dir tmp
    dt=$(aj time local "$st") || return 1
    d="${dt%%$'\t'*}"; t="${dt#*$'\t'}"
    slug=$(op_slug "$op")
    name="${t}_${id}${slug:+_${slug}}.log"
    dir="${APEX_DIR}/${d}"
    mkdir -p "$dir" || return 1
    if [[ ! -e "${dir}/${name}" ]]; then
        tmp="${dir}/.tmp.${id}.$$"
        cp "$src" "$tmp" && mv -f "$tmp" "${dir}/${name}" || { rm -f "$tmp"; return 1; }
    fi
    if ! grep -qF -- "	${id}	" "$INDEX_F" 2>/dev/null; then  # 条件チェックのため run 不使用（目録に同じ ID があれば足さない）
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${dir}/${name}" "$id" "$st" "$op" "$status" "$len" "$dur" >> "$INDEX_F"
    fi
}

# sf-log.log にだけ書く（画面に出さない。取得の件数など）
note_log() { printf '[%s] [INFO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"; }

# 1 回の取得。戻り値: 0 = 追いついた／2 = まだ残りがある／1 = 失敗
fetch_round() {
    local last lastid where q lj tsv name rc
    local ids=() mine=() starts=() lens=() durs=() ops=() stats=()
    local id m st len dur op status total more=0 first=-1 others_after=0 i n f
    last=$(kv_get "$STATE_F" LAST_FETCH); lastid=$(kv_get "$STATE_F" LAST_FETCH_ID)  # VAR=$(cmd) のため run 不使用
    if [[ ! "$last" =~ $ISO_RE ]]; then last=$(aj time add "$(now_z)" --sec -1800); lastid=""; fi
    [[ "$lastid" =~ $ID_RE ]] || lastid=""
    if [[ -n "$lastid" ]]; then
        where="StartTime > ${last} OR (StartTime = ${last} AND Id > '${lastid}')"
    else
        where="StartTime >= ${last}"
    fi
    q="SELECT Id, LogUserId, StartTime, Operation, Request, Status, LogLength, DurationMilliseconds FROM ApexLog WHERE ${where} ORDER BY StartTime ASC, Id ASC LIMIT 51"
    # run を通さない（応答に他の人のログの見出しが入るため。run は出力を sf-log.log・error.log・画面に出す。8.3）
    if lj=$(sf data query --use-tooling-api --target-org "$TARGET_ORG" --json --query "$q" 2>/dev/null); then  # VAR=$(cmd) のため run 不使用（上の理由）
        if ! tsv=$(printf '%s' "$lj" | aj list --user "$USER_ID" 2>/dev/null); then  # VAR=$(cmd) のため run 不使用
            note_log "ApexLog の一覧: 失敗（応答の形が正しくありません）"
            return 1
        fi
    else
        name=$(sf_err_name "$lj")
        note_log "ApexLog の一覧: 失敗（${name}）"
        return 1
    fi
    lj=""
    while IFS=$'\t' read -r id m st len dur op status; do
        [[ -n "$id" ]] || continue
        ids+=("$id"); mine+=("$m"); starts+=("$st"); lens+=("$len"); durs+=("$dur"); ops+=("$op"); stats+=("$status")
    done <<< "$tsv"
    tsv=""
    total=${#ids[@]}
    if [[ $total -gt 50 ]]; then more=1; total=50; fi
    n=0
    for ((i = 0; i < total; i++)); do
        if [[ "${mine[i]}" == "1" ]]; then
            n=$((n + 1)); [[ $first -lt 0 ]] && first=$i
        elif [[ $first -ge 0 ]]; then
            others_after=1
        fi
    done
    if [[ $more -eq 1 ]]; then note_log "ApexLog の一覧: ${total} 本（自分のログ ${n} 本）・残りあり"
    else note_log "ApexLog の一覧: ${total} 本（自分のログ ${n} 本）"; fi
    if [[ $total -eq 0 ]]; then return 0; fi
    if [[ $first -lt 0 ]]; then
        state_set "$STATE_F" "LAST_FETCH=${starts[total-1]}" "LAST_FETCH_ID=${ids[total-1]}" || return 1
        [[ $more -eq 1 ]] && return 2
        return 0
    fi

    # 本文を取る。一時フォルダは、取得のロックを持った状態で、毎回まず空にする（他の人の本文を残さない。8.4）
    rm -rf "$FETCH_TMP" && mkdir -p "$FETCH_TMP" || return 1
    if [[ $more -eq 0 && $others_after -eq 0 ]]; then
        run sf apex get log -n "$((total - first))" -d "$FETCH_TMP" --target-org "$TARGET_ORG" >/dev/null || { rm -rf "$FETCH_TMP"; return 1; }
    fi
    for f in "$FETCH_TMP"/* "$FETCH_TMP"/.[!.]*; do
        [[ -e "$f" ]] || continue
        if [[ ! "${f##*/}" =~ ^[A-Za-z0-9]{15}([A-Za-z0-9]{3})?\.log$ ]]; then
            note_log "本文の取得: 想定しない名前のファイルがあったため、この回を失敗にします"
            rm -rf "$FETCH_TMP"; return 1
        fi
    done
    rc=0
    for ((i = 0; i < total; i++)); do
        if [[ "${mine[i]}" == "1" ]]; then
            f="${FETCH_TMP}/${ids[i]}.log"
            if [[ ! -f "$f" ]]; then
                # -n で押し出された・1 本ずつ取る場合（-i は ID を指定するので、他の人のログは入らない）
                rm -rf "${FETCH_TMP}/one" && mkdir -p "${FETCH_TMP}/one" || { rc=1; break; }
                run sf apex get log -i "${ids[i]}" -d "${FETCH_TMP}/one" --target-org "$TARGET_ORG" >/dev/null || { rc=1; break; }
                [[ -f "${FETCH_TMP}/one/${ids[i]}.log" ]] || { note_log "本文の取得: ${ids[i]} のファイルがありません"; rc=1; break; }
                f="${FETCH_TMP}/one/${ids[i]}.log"
            fi
            save_one "$f" "${ids[i]}" "${starts[i]}" "${ops[i]}" "${stats[i]}" "${lens[i]}" "${durs[i]}" || { rc=1; break; }
        fi
        state_set "$STATE_F" "LAST_FETCH=${starts[i]}" "LAST_FETCH_ID=${ids[i]}" || { rc=1; break; }
    done
    rm -rf "$FETCH_TMP" 2>/dev/null || true   # 意図的エラー無視: 次の取得の最初にも空にする
    [[ $rc -ne 0 ]] && return 1
    [[ $more -eq 1 ]] && return 2
    return 0
}

# ------------------------------------------------------------------------------
# 8. pull（4.4）
# ------------------------------------------------------------------------------
cmd_pull() {
    local rc=0 round since read_ids now notes=() sel tmp_list cnt omitted first_om last_om newest ts out_md hdr
    prepare_org full
    # しおりが別の組織・ユーザーのものなら、今から取り直す（別の組織の時刻・ID を使わない）
    if [[ "$(kv_get "$STATE_F" ORG)" != "$TARGET_ORG" || "$(kv_get "$STATE_F" USER_ID)" != "$USER_ID" ]]; then
        now=$(now_z)
        state_set "$STATE_F" "ORG=${TARGET_ORG}" "USER_ID=${USER_ID}" "LAST_FETCH=$(aj time add "$now" --sec -1800)" "LAST_FETCH_ID=" \
            "LAST_READ=" "LAST_READ_IDS=" || die "手元の状態を書けません。"
    fi

    # 取得（取得のロックを持つ。最大 90 秒待つ）
    lock_take "$FETCH_LOCK" 450 || die "取得のロックを取れませんでした（${FETCH_LOCK}。ほかの取得が終わりません）。"
    for round in 1 2 3 4; do
        rc=0; fetch_round || rc=$?
        [[ $rc -eq 2 ]] || break
    done
    lock_drop "$FETCH_LOCK"
    [[ $rc -eq 1 ]] && die "ログを取得できませんでした（sf-tools/logs/sf-log.log を参照）。"
    [[ $rc -eq 2 ]] && notes+=("取り込みの残りがあります（200 本を超えました）。もう一度 sf-log.sh pull を実行すると、続きを取ります。")
    notes+=("取得役: 動いていません（この pull が、組織から直接取りました）")

    # 要約に入れるログを選ぶ
    now=$(now_z)
    if [[ -n "$SINCE_MIN" ]]; then
        since=$(aj time add "$now" --sec "-$((SINCE_MIN * 60))"); read_ids=""
    else
        since=$(kv_get "$STATE_F" LAST_READ); read_ids=$(kv_get "$STATE_F" LAST_READ_IDS)  # VAR=$(cmd) のため run 不使用
        if [[ ! "$since" =~ $ISO_RE || "$(aj time cmp "$since" "$(aj time add "$now" --sec 300)")" == "1" ]]; then
            [[ -n "$since" ]] && log "WARNING" "前回の要約の時刻（${since}）が正しくないため、直近 30 分を対象にします。"
            since=$(aj time add "$now" --sec -1800); read_ids=""
        fi
    fi
    tmp_list=$(mktemp "${TMPDIR:-/tmp}/sf-log-list.XXXXXX") || die "一時ファイルを作れません。"
    trap 'rm -f "$tmp_list"' EXIT
    if [[ -f "$INDEX_F" ]]; then
        # 開始が since より後（同じ秒は、前回の要約に入れた ID を除く）。開始・ID の順に並べる
        awk -F'\t' -v s="$since" -v ids=",${read_ids}," -v strict="$([[ -n "$SINCE_MIN" ]] && echo 0 || echo 1)" \
            '($3 > s) || ($3 == s && (strict == 0 || index(ids, "," $2 ",") == 0))' "$INDEX_F" \
            | LC_ALL=C sort -t$'\t' -k3,3 -k2,2 > "$tmp_list"  # 選ぶだけ（失敗は、下の件数で分かる）
    fi
    cnt=$(wc -l < "$tmp_list" | tr -d ' ')
    if [[ "$cnt" -gt "$MAX_LOGS" ]]; then
        omitted=$((cnt - MAX_LOGS))
        first_om=$(head -1 "$tmp_list" | cut -f3); last_om=$(sed -n "${omitted}p" "$tmp_list" | cut -f3)
        notes+=("入れなかった古いログ: ${omitted} 本（${first_om}〜${last_om}。UTC）。入れるには sf-log.sh pull --since <分> --max <本数>")
        tail -n "$MAX_LOGS" "$tmp_list" > "${tmp_list}.t" && mv -f "${tmp_list}.t" "$tmp_list"
    fi

    # 要約を作る（置き換えで書く）
    mkdir -p "${APEX_DIR}/summaries" || die "要約のフォルダを作れません。"
    ts=$(aj time local "$now"); ts="${ts/$'\t'/_}"
    out_md="${APEX_DIR}/summaries/${ts}.md"
    local nargs=() nt
    for nt in "${notes[@]}"; do nargs+=(--note "$nt"); done
    aj summarize --list "$tmp_list" --base . --now "$now" "${nargs[@]}" > "${out_md}.tmp" || { rm -f "${out_md}.tmp"; die "要約を作れませんでした。"; }
    mv -f "${out_md}.tmp" "$out_md" && cp "$out_md" "${APEX_DIR}/latest.md.tmp" && mv -f "${APEX_DIR}/latest.md.tmp" "${APEX_DIR}/latest.md" \
        || die "要約を書けませんでした。"

    # 要約に入れた最も新しいログの開始時刻を、次の起点にする（成功したときだけ）
    if [[ -s "$tmp_list" ]]; then
        newest=$(tail -1 "$tmp_list" | cut -f3)
        read_ids=$(awk -F'\t' -v s="$newest" '$3 == s {printf "%s%s", (n++ ? "," : ""), $2}' "$tmp_list")
        if [[ "$newest" == "$(kv_get "$STATE_F" LAST_READ)" && -z "$SINCE_MIN" ]]; then
            read_ids="$(kv_get "$STATE_F" LAST_READ_IDS),${read_ids}"; read_ids="${read_ids#,}"
        fi
        state_set "$STATE_F" "LAST_READ=${newest}" "LAST_READ_IDS=${read_ids}" || log "WARNING" "前回の要約の時刻を書けませんでした。"
    fi
    hdr=$(head -1 "${APEX_DIR}/latest.md")
    printf '%s\n%s\n' "${hdr#\# }" "${APEX_DIR}/latest.md"
    exit 0
}

# ------------------------------------------------------------------------------
# 9. stop（4.5）
# ------------------------------------------------------------------------------
cmd_stop() {
    local org tf j name mark
    org=$(kv_get "$STATE_F" ORG); tf=$(kv_get "$STATE_F" TRACE_FLAG_ID)  # VAR=$(cmd) のため run 不使用
    mark="$$:$(date +%s):stop"
    state_set "$OWNERS_F" "CLOSING=${mark}" || true   # 意図的エラー無視: 後始末の最中の印（なくても止める）
    if [[ "$tf" =~ $ID_RE ]]; then
        # 消す先は、TraceFlag を作った組織（.state の ORG）。-o があれば、それを使う
        [[ -n "$ORG_ARG" ]] && org="$ORG_ARG"
        check_sf_cli --cache
        if [[ -z "$org" ]]; then org=$(get_target_org "") || die "接続先の組織エイリアスを特定できません。"; fi
        if j=$(run sf data delete record --use-tooling-api --sobject TraceFlag --record-id "$tf" --target-org "$org" --json); then
            log "SUCCESS" "TraceFlag を消しました（${tf}・組織: ${org}）。"
        else
            name=$(sf_err_name "$j")
            case "$name" in
                *NOT_FOUND*|*ENTITY_IS_DELETED*|*INVALID_CROSS_REFERENCE_KEY*)
                    log "WARNING" "TraceFlag（${tf}）は、すでにありません（${name}）。" ;;
                *)
                    rm -f "$OWNERS_F" 2>/dev/null || true   # 意図的エラー無視: 後始末の印を外す
                    die "TraceFlag（${tf}）を消せませんでした（${name}）。" ;;
            esac
        fi
    else
        log "INFO" "sf-log.sh が作った TraceFlag はありません。"
    fi
    state_set "$STATE_F" "TRACE_FLAG_ID=" || true      # 意図的エラー無視: 次の start で作り直す
    state_set "$STATUS_F" "STATE=stopped" "EXPIRES=" "REASON=" || true   # 意図的エラー無視: 表示用
    rm -f "$OWNERS_F" "$COLLECTOR_F" 2>/dev/null || true   # 意図的エラー無視: 一覧と印を空にする
    log "INFO" "手元のログ（${APEX_DIR}/）は残しました。"
    exit 0
}

# ------------------------------------------------------------------------------
# 10. status（4.6）・auto（4.7）
# ------------------------------------------------------------------------------
cmd_status() {
    local k v j tsv id type st ex state dl mine n s
    echo "Apex ログ（sf-log.sh）の状態"
    for k in STATE ORG EXPIRES REASON WARNING; do
        v=$(kv_get "$STATUS_F" "$k"); [[ -n "$v" ]] && echo "  ${k}: ${v}"   # VAR=$(cmd) のため run 不使用
    done
    for k in ORG TRACE_FLAG_ID LAST_FETCH LAST_READ; do
        v=$(kv_get "$STATE_F" "$k"); [[ -n "$v" ]] && echo "  ${k}: ${v}"   # VAR=$(cmd) のため run 不使用
    done
    v=$(kv_get "$CONSENT_F" AUTO); echo "  自動（sf-start のとき）: ${v:-まだ答えていません}"
    if [[ -f "$INDEX_F" ]]; then echo "  手元のログ: $(wc -l < "$INDEX_F" | tr -d ' ') 本"; fi
    [[ -f "${APEX_DIR}/latest.md" ]] && echo "  最新の要約: ${APEX_DIR}/latest.md"
    prepare_org light
    mine=$(kv_get "$STATE_F" TRACE_FLAG_ID)  # VAR=$(cmd) のため run 不使用
    j=$(run sf data query --use-tooling-api --target-org "$TARGET_ORG" --json \
        --query "SELECT Id, LogType, StartDate, ExpirationDate, DebugLevel.DeveloperName FROM TraceFlag WHERE TracedEntityId = '${USER_ID}'") \
        || die "TraceFlag を検索できません（$(sf_err_name "$j")）。"
    tsv=$(printf '%s' "$j" | aj tflist) || die "TraceFlag の検索の応答の形が正しくありません。"
    echo "  このユーザーの TraceFlag（組織: ${TARGET_ORG}）:"
    [[ -n "$tsv" ]] || echo "    なし"
    while IFS=$'\t' read -r id type st ex state dl; do
        [[ -n "$id" ]] || continue
        echo "    ${id}  ${type}  ${state}  期限 ${ex}  ${dl}$([[ "$id" == "$mine" ]] && echo '  （sf-log.sh が作ったもの）')"
    done <<< "$tsv"
    j=$(run sf data query --use-tooling-api --target-org "$TARGET_ORG" --json \
        --query "SELECT COUNT(Id) n, SUM(LogLength) s FROM ApexLog WHERE LogUserId = '${USER_ID}'") || j=""
    n=$(json_get "$j" result.records.0.n 2>/dev/null) || n=""   # VAR=$(cmd) のため run 不使用
    s=$(json_get "$j" result.records.0.s 2>/dev/null) || s=""   # VAR=$(cmd) のため run 不使用
    [[ "$n" =~ ^[0-9]+$ ]] && echo "  組織にある自分のログ: ${n} 本・$(( ${s:-0} / 1024 ))KB"
    exit 0
}

cmd_auto() {
    prepare_org light
    state_set "$CONSENT_F" "AUTO=${AUTO_ARG}" "ORG_ID=${ORG_ID}" "VERSION=${CONSENT_VERSION}" "ANSWERED_AT=$(now_z)" \
        || die "答えを書けませんでした。"
    if [[ "$AUTO_ARG" == "on" ]]; then
        log "SUCCESS" "このプロジェクトでは、sf-start のときに Apex ログを自動で取ります（組織: ${TARGET_ORG}）。"
    else
        log "SUCCESS" "このプロジェクトでは、sf-start のときに Apex ログを取りません（動いている取得は止めません。今止めるなら sf-log.sh stop）。"
    fi
    exit 0
}

# ------------------------------------------------------------------------------
# 11. 入口
# ------------------------------------------------------------------------------
case "$CMD" in
    start)  cmd_start ;;
    pull)   cmd_pull ;;
    stop)   cmd_stop ;;
    status) cmd_status ;;
    auto)   cmd_auto ;;
esac
