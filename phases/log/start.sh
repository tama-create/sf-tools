#!/bin/bash
# ==============================================================================
# phases/log/start.sh - sf-log.sh の部品: 接続先の確認（5 章）と start（6 章。同意・DebugLevel・TraceFlag）
# ==============================================================================
# bin/sf-log.sh が source する（単独では動かさない）。変数・関数は、sf-log.sh の 1〜3 章と、先に source した部品が用意する。
# 2026-11-28 に、1665 行あった sf-log.sh を、入口と 7 つの部品に分けた（中身は変えずに移した。章の番号は、元のまま）。
# ==============================================================================
# shellcheck disable=SC2154  # 変数は、source する bin/sf-log.sh（1〜3 章）が用意する（この部品だけでは、代入が見えない）

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

# 確認（10.2）。begin（sf-start の前面）が、手元の答え（.consent の AUTO・ORG（エイリアス）・VERSION）だけで、その場で判定する
#   （sf を呼ばない。ランチャーを待たせないため。2026-11-23。13.3）。答えがない・エイリアスが変わった・文面の版が変わったときだけ聞く。
#   端末でない・q・N は「取らない」。0 = 取る／1 = 取らない
consent_local() {
    local a o v ans
    a=$(kv_get "$CONSENT_F" AUTO); o=$(kv_get "$CONSENT_F" ORG); v=$(kv_get "$CONSENT_F" VERSION)  # VAR=$(cmd) のため run 不使用
    if [[ -n "$a" && "$o" == "$TARGET_ORG" && "$v" == "$CONSENT_VERSION" ]]; then
        [[ "$a" == "on" ]] && return 0
        return 1
    fi
    log "INFO" "ランチャーの起動中、この組織（${TARGET_ORG}）のデバッグログを、裏で自動で手元に保存できます。"
    log "INFO" "  ${NOTICE_TEXT}"
    log "INFO" "  あとから sf-log.sh auto on|off で変えられます。"
    if [[ ! -t 0 ]]; then
        log "INFO" "  確認できない（端末ではない）ため、今回は取りません（答えは保存しません）。"
        return 1
    fi
    # read_key は EOF で die するため、$( ) の中で呼ぶ（ランチャーを止めない）。q も「取らない」。
    #   AI 操作（SF_TOOLS_AI=1）では、標準入力が端末でないため、上で「今回は取らない」と返り、ここには来ない
    #   （入力の関数を $( ) の中で呼ぶのは、この 1 か所だけ。tests/test_common.sh の書き方の検査で、理由つきで除外する）
    ans=$(read_key _k "  自動で取りますか？ [Y/N/q]: " "[YyNnQq]"; printf '%s' "${_k:-}") || ans=""  # VAR=$(cmd) のため run 不使用
    case "$ans" in
        [Yy]) state_set "$CONSENT_F" "AUTO=on" "ORG=${TARGET_ORG}" "ORG_ID=" "VERSION=${CONSENT_VERSION}" "ANSWERED_AT=$(now_z)" || true; return 0 ;;
        [Nn]|[Qq]) state_set "$CONSENT_F" "AUTO=off" "ORG=${TARGET_ORG}" "ORG_ID=" "VERSION=${CONSENT_VERSION}" "ANSWERED_AT=$(now_z)" || true; return 1 ;;
        *) return 1 ;;
    esac
}

# start --auto（裏）の確認。尋ねない。手元の答えが「取る」で、組織 ID が答えたときと同じなら 0
#   組織 ID がまだ空（begin で答えた直後）なら、今の組織 ID を書く。違えば（同じエイリアスで別の組織に入り直した）、
#   答えを消して 1（次の sf-start で、もう一度聞く。同意のない組織のログを取らない）。結果の理由: CONSENT_REASON
CONSENT_REASON=""
auto_consent() {
    local a o oid v
    a=$(kv_get "$CONSENT_F" AUTO); o=$(kv_get "$CONSENT_F" ORG); oid=$(kv_get "$CONSENT_F" ORG_ID); v=$(kv_get "$CONSENT_F" VERSION)  # VAR=$(cmd) のため run 不使用
    if [[ -z "$a" || "$o" != "$TARGET_ORG" || "$v" != "$CONSENT_VERSION" ]]; then
        CONSENT_REASON="この組織で自動で取るかの答えがないため（sf-start で聞きます）"; return 1
    fi
    if [[ "$a" != "on" ]]; then CONSENT_REASON="このプロジェクトでは、自動で取らない設定のため"; return 1; fi
    if [[ -n "$oid" && "$oid" != "$ORG_ID" ]]; then
        state_set "$CONSENT_F" "AUTO=" "ORG_ID=" || true   # 意図的エラー無視: 次の sf-start で聞き直す
        CONSENT_REASON="同じエイリアスで、別の組織に入り直したため（次の sf-start で、もう一度聞きます）"; return 1
    fi
    if [[ -z "$oid" ]]; then state_set "$CONSENT_F" "ORG_ID=${ORG_ID}" || true; fi   # 意図的エラー無視: 次の照らし合わせに使う
    return 0
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

# 別の場所の sf-log.sh の TraceFlag を引き継ぐ（--auto のみ。後から起動した sf-start を優先する。4.2）。引数: ID 期限（UTC）
#   期限を縮めるのではなく消す: すぐに作れる（待たない）。残すと、古い取得役の延長が、あとで生き返らせることがある。
#   古い取得役は、自分の TraceFlag がなくなったことに気づいて止まる（collect の c2）。消せなければ終了コード 1（作らない）
take_over_traceflag() {
    local j name
    # 準備のあいだに sf-start が終了していたら、引き継がない（使う人がいないのに、相手の取得を止めないため）
    if [[ -n "$OWNER" ]] && ! owner_present; then finish_auto_or_die 10 "sf-start が終了したため"; fi
    if ! j=$(run sf data delete record --use-tooling-api --sobject TraceFlag --record-id "$1" --target-org "$TARGET_ORG" --json); then
        name=$(sf_err_name "$j")  # VAR=$(cmd) のため run 不使用
        sf_err_is_gone "$name" || finish_auto_or_die 1 "別の sf-start のログ設定を消せないため、引き継げません（${name}）"
    fi
    TOOK_OVER=1
    log "WARNING" "別の場所の sf-start のログ設定（${1}・期限 ${2}）を引き継ぎました。あちらの取得は止まります。"
}

# TraceFlag を延ばすか作る（4.2 の 3・8.2）。結果: TF_ID・TF_EXPIRES・TOOK_OVER（引き継いだら 1）
TF_ID=""; TF_EXPIRES=""; TOOK_OVER=""
ensure_traceflag() {
    local j now tsv mine other_ids=() other_exp=() other_dl=() line id type st ex state dl start new_exp shrunk="" rc until_hm
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
        if [[ "$type" == "USER_DEBUG" && "$state" == "active" ]]; then other_ids+=("$id"); other_exp+=("$ex"); other_dl+=("$dl"); fi
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
    elif [[ ${#other_ids[@]} -eq 1 && $AUTO -eq 1 ]]; then
        if ! is_sftools_debuglevel "${other_dl[0]}"; then
            # 人・ほかの道具の設定は、自動では触らない。いつまで残るかと、置き換え方を表示する
            until_hm=$(local_hm "${other_exp[0]}")  # VAR=$(cmd) のため run 不使用
            log "WARNING" "ほかの USER_DEBUG の TraceFlag（${other_ids[0]}・期限 ${other_exp[0]}）があります。sf-log.sh start で置き換えられます。"
            finish_auto_or_die 10 "sf-tools 以外のログ設定があるため。期限 ${until_hm}。置き換えは sf-log.sh start"
        fi
        take_over_traceflag "${other_ids[0]}" "${other_exp[0]}"
        start=$(now_z)
    elif [[ ${#other_ids[@]} -eq 1 ]]; then
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
    local prev_org prev_user prev_tf now vol n s rc
    if [[ $AUTO -eq 1 && "${GITHUB_ACTIONS:-}" == "true" ]]; then
        log "INFO" "GitHub Actions の上では、デバッグログを取りません。"
        exit 10
    fi
    wait_sf_upgrade   # sf の入れ替えの途中に、sf を呼ばない（処理の流れ 0）
    prepare_org full
    if [[ $AUTO -eq 1 ]]; then
        auto_consent || finish_auto_or_die 10 "$CONSENT_REASON"
    else
        log "WARNING" "$NOTICE_TEXT"
        if [[ $YES -eq 0 ]]; then ask_yn "${TARGET_ORG} のデバッグログを取り始めますか？" || die "中断しました。"; fi
    fi
    # 持ち主（sf-start）の登録（5.1 の b）。後始末の最中なら、終わってから登録する（古い後始末が、新しい TraceFlag を消さないため）
    if [[ -n "$OWNER" ]]; then
        rc=0; register_owner "$OWNER" || rc=$?
        [[ $rc -eq 2 ]] && refuse_other_runtime   # 同じロックの中で、別の環境が名乗っていた（5.6）
        [[ $rc -eq 0 ]] || finish_auto_or_die 10 "前の後始末が終わらないため（${CLOSING_WAIT} 秒待ちました）"
    fi
    prev_org=$(kv_get "$STATE_F" ORG); prev_user=$(kv_get "$STATE_F" USER_ID); prev_tf=$(kv_get "$STATE_F" TRACE_FLAG_ID)  # VAR=$(cmd) のため run 不使用
    ensure_debuglevel
    ensure_traceflag

    # 組織を切り替えた（sf-switch-org）: 前の組織の、sf-log.sh が作った TraceFlag を消す（5.3。消せなければ、最大 2 時間で切れる）
    if [[ -n "$prev_org" && "$prev_org" != "$TARGET_ORG" && "$prev_tf" =~ $ID_RE ]]; then
        if run sf data delete record --use-tooling-api --sobject TraceFlag --record-id "$prev_tf" --target-org "$prev_org" --json >/dev/null; then
            log "INFO" "前の組織（${prev_org}）の TraceFlag（${prev_tf}）を消しました。"
        else
            log "WARNING" "前の組織（${prev_org}）の TraceFlag（${prev_tf}）を消せませんでした（最大 2 時間で切れます）。"
        fi
    fi

    # .state（組織・ユーザーが変わったら、取得のしおりを今に、要約のしおりを今の目録の最後の行にする）
    now=$(now_z)
    if [[ "$prev_org" != "$TARGET_ORG" || "$prev_user" != "$USER_ID" || -z "$(kv_get "$STATE_F" LAST_FETCH)" ]]; then
        local mark; mark=$(index_mark_now)  # VAR=$(cmd) のため run 不使用
        state_set "$STATE_F" "ORG=${TARGET_ORG}" "USER_ID=${USER_ID}" "TRACE_FLAG_ID=${TF_ID}" \
            "LAST_FETCH=${now}" "LAST_FETCH_ID=" "LATE_FROM=" "LAST_READ_LINE=${mark%%$'\t'*}" "LAST_READ_ID=${mark#*$'\t'}" \
            "LAST_READ=" "LAST_READ_IDS=" || finish_auto_or_die 1 "手元の状態を書けません"
    else
        state_set "$STATE_F" "ORG=${TARGET_ORG}" "USER_ID=${USER_ID}" "TRACE_FLAG_ID=${TF_ID}" || finish_auto_or_die 1 "手元の状態を書けません"
    fi
    # WARNING= : 裏の準備のやり直し（retry_prepare）の「やり直しています」を消す
    # COUNT_TODAY: 前回の値（前の日など）を残さない。ランチャーは「取得中」に変わった時点で 1 回だけ描き直すため、ここで正しい数を書く
    # TAKEOVER: 別の場所の sf-start の設定を引き継いだら 1（ランチャーが「引き継ぎ」と表示する。取得役は書き換えない）
    state_set "$STATUS_F" "STATE=collecting" "ORG=${TARGET_ORG}" "EXPIRES=${TF_EXPIRES}" "EXPIRES_AT=$(local_hm "$TF_EXPIRES")" "COUNT_TODAY=$(count_today)" "REASON=" "WARNING=" "TAKEOVER=${TOOK_OVER}" || true   # 意図的エラー無視: 表示用

    # 組織のログの量（8.6）
    vol=$(run sf data query --use-tooling-api --target-org "$TARGET_ORG" --json \
        --query "SELECT COUNT(Id) n, SUM(LogLength) s FROM ApexLog") || vol=""
    n=$(json_get "$vol" result.records.0.n 2>/dev/null) || n=""   # VAR=$(cmd) のため run 不使用
    s=$(json_get "$vol" result.records.0.s 2>/dev/null) || s=""   # VAR=$(cmd) のため run 不使用
    [[ "$s" =~ ^[0-9]+$ ]] || s=0
    log "SUCCESS" "デバッグログを取り始めました（組織: ${TARGET_ORG}・TraceFlag: ${TF_ID}・期限: ${TF_EXPIRES}（UTC））。"
    [[ "$n" =~ ^[0-9]+$ ]] && log "INFO" "  組織のログ: ${n} 本・$((s / 1024 / 1024))MB（上限 1,000MB）"
    if [[ "$s" -gt "$ORG_LOG_WARN_BYTES" ]]; then
        log "WARNING" "組織のログが 700MB を超えています。1,000MB を超えると、TraceFlag を作れなくなります。"
    fi
    if [[ $COLLECT_AFTER -eq 1 ]]; then
        exec bash "${SCRIPT_DIR}/sf-log.sh" collect   # begin から裏で起動されたとき: 準備ができたら、そのまま取得役になる
    fi
    exit 0
}
