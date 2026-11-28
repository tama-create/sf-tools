#!/bin/bash
# ==============================================================================
# phases/log/status.sh - sf-log.sh の部品: status（10 章）・auto（10 章）・begin（10b 章。sf-start の前面）
# ==============================================================================
# bin/sf-log.sh が source する（単独では動かさない）。変数・関数は、sf-log.sh の 1〜3 章と、先に source した部品が用意する。
# 2026-11-28 に、1665 行あった sf-log.sh を、入口と 7 つの部品に分けた（中身は変えずに移した。章の番号は、元のまま）。
# ==============================================================================
# shellcheck disable=SC2154  # 変数は、source する bin/sf-log.sh（1〜3 章）が用意する（この部品だけでは、代入が見えない）

# ------------------------------------------------------------------------------
# 10. status（4.6）・auto（4.7）
# ------------------------------------------------------------------------------
# 「N 秒前」の表示（分からなければ、そう書く）
ago_text() { if [[ "$1" =~ ^[0-9]+$ ]]; then printf '%s 秒前' "$1"; else printf '時刻が分からない'; fi; }

# status の取得役の行（5.6）。別の環境が扱っているか・記録が読めるかで、言い切らない
status_collector_line() {
    local cpid now hb crt
    now=$(date +%s)  # VAR=$(cmd) のため run 不使用
    if other_runtime_active; then
        crt=$(kv_get "$COLLECTOR_F" RUNTIME)  # VAR=$(cmd) のため run 不使用
        if [[ "$OTHER_SRC" == "claim" && ( ! -f "$COLLECTOR_F" || "$crt" != "$(kv_get "$CLAIM_F" RUNTIME)" ) ]]; then
            echo "  取得役: 取得役の起動待ち（環境 ${OTHER_RT}・名乗りは $(ago_text "$OTHER_AGO")）"
        elif [[ "$OTHER_SRC" == "collector" && -z "$crt" ]]; then
            echo "  取得役: 状態不明（環境の記録のない、古い形の取得役の記録です。起動から 12 時間は、動いているものとみなします）"
        else
            hb=$(kv_get "$COLLECTOR_F" HEARTBEAT)  # VAR=$(cmd) のため run 不使用
            [[ "$hb" =~ ^[0-9]+$ && $hb -le $now ]] && hb=$((now - hb)) || hb=""
            echo "  取得役: 別の環境（${OTHER_RT}）で動作中（最後の合図は $(ago_text "$hb")・組織 $(kv_get "$COLLECTOR_F" ORG)）"
        fi
        return 0
    fi
    if [[ -f "$COLLECTOR_F" ]] && ! [[ "$(kv_get "$COLLECTOR_F" PID)" =~ ^[0-9]+$ && "$(kv_get "$COLLECTOR_F" STARTED)" =~ ^[0-9]+$ ]]; then
        echo "  取得役: 状態不明（${COLLECTOR_F} の形が正しくありません）"
        return 0
    fi
    cpid=$(collector_pid_local)  # VAR=$(cmd) のため run 不使用
    if pid_alive "$cpid"; then
        echo "  取得役: 動作中（PID ${cpid}・組織 $(kv_get "$COLLECTOR_F" ORG)・間隔 ${INTERVAL} 秒）"
    elif [[ -f "$CLAIM_F" ]] && same_rt "$(kv_get "$CLAIM_F" RUNTIME)"; then
        hb=$(kv_get "$CLAIM_F" AT)  # VAR=$(cmd) のため run 不使用
        [[ "$hb" =~ ^[0-9]+$ && $hb -le $now ]] && hb=$((now - hb)) || hb=""
        echo "  取得役: 取得役の起動待ち（この環境・名乗りは $(ago_text "$hb")）"
    else
        echo "  取得役: 動いていません"
    fi
}

cmd_status() {
    local k v j tsv id type st ex state dl mine n s
    echo "デバッグログ（sf-log.sh）の状態"
    status_collector_line
    # 表示の状態（.status）と、取得の記録（.state）。同じ名前のキーがあるため、どちらの値かを見出しで分ける
    for k in STATE ORG EXPIRES LAST_FETCH COUNT_TODAY BACKLOG REASON WARNING; do
        v=$(kv_get "$STATUS_F" "$k"); [[ -n "$v" ]] && echo "  表示の状態 ${k}: ${v}"   # VAR=$(cmd) のため run 不使用
    done
    for k in ORG TRACE_FLAG_ID LAST_FETCH LATE_FROM LAST_READ_LINE; do
        v=$(kv_get "$STATE_F" "$k"); [[ -n "$v" ]] && echo "  取得の記録 ${k}: ${v}"   # VAR=$(cmd) のため run 不使用
    done
    v=$(grep -c -v '^CLOSING=' "$OWNERS_F" 2>/dev/null || true); echo "  持ち主（起動中の sf-start）: ${v:-0}"   # VAR=$(cmd) のため run 不使用
    v=$(kv_get "$CONSENT_F" AUTO); echo "  自動（sf-start のとき）: ${v:-まだ答えていません}"
    if [[ -f "$INDEX_F" ]]; then echo "  手元のログ: $(wc -l < "$INDEX_F" | tr -d ' ') 本"; fi
    [[ -f "${APEX_DIR}/latest.md" ]] && echo "  最新の要約: ${APEX_DIR}/latest.md"
    prepare_org light
    # 表示の状態（.status）が、別の組織の古い記録なら、言い切らない（5.6）
    v=$(kv_get "$STATUS_F" ORG)  # VAR=$(cmd) のため run 不使用
    [[ -n "$v" && "$v" != "$TARGET_ORG" ]] && echo "  表示の状態: 状態不明（別の組織（${v}）の記録です。接続先は ${TARGET_ORG}）"
    mine=$(kv_get "$STATE_F" TRACE_FLAG_ID)  # VAR=$(cmd) のため run 不使用
    # 組織への問い合わせに失敗しても、止めずに、その旨を表示する（手元の状態は、上で表示済み）
    tsv=""
    if ! j=$(run sf data query --use-tooling-api --target-org "$TARGET_ORG" --json \
        --query "SELECT Id, LogType, StartDate, ExpirationDate, DebugLevel.DeveloperName FROM TraceFlag WHERE TracedEntityId = '${USER_ID}'"); then
        echo "  このユーザーの TraceFlag: 組織に問い合わせできませんでした（$(sf_err_name "$j")）"
    elif ! tsv=$(printf '%s' "$j" | aj tflist); then
        echo "  このユーザーの TraceFlag: 検索の応答の形が正しくありません"; tsv=""
    else
        echo "  このユーザーの TraceFlag（組織: ${TARGET_ORG}）:"
        [[ -n "$tsv" ]] || echo "    なし"
    fi
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
    state_set "$CONSENT_F" "AUTO=${AUTO_ARG}" "ORG=${TARGET_ORG}" "ORG_ID=${ORG_ID}" "VERSION=${CONSENT_VERSION}" "ANSWERED_AT=$(now_z)" \
        || die "答えを書けませんでした。"
    if [[ "$AUTO_ARG" == "on" ]]; then
        log "SUCCESS" "このプロジェクトでは、sf-start のときにデバッグログを自動で取ります（組織: ${TARGET_ORG}）。"
    else
        log "SUCCESS" "このプロジェクトでは、sf-start のときにデバッグログを取りません（動いている取得は止めません。今止めるなら sf-log.sh stop）。"
    fi
    exit 0
}

# ------------------------------------------------------------------------------
# 10b. begin（5.1。sf-start の前面）: sf を呼ばずに判定し、準備と取得役を裏で起動する
#   ランチャーを待たせないため（start --auto は sf を約 7 回呼び、実機で約 1 分かかった。2026-11-23。13.3）
# ------------------------------------------------------------------------------
cmd_begin() {
    AUTO=1   # 取らないときは、終了コード 10 で返す（sf-start を止めない）
    TARGET_ORG="$ORG_ARG"
    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        log "INFO" "GitHub Actions の上では、デバッグログを取りません。"
        exit 10
    fi
    is_reserved_org_alias "$TARGET_ORG" && finish_auto_or_die 10 "${TARGET_ORG} は共有環境（予約名）のため"
    consent_local || finish_auto_or_die 10 "このプロジェクトでは、自動で取らない設定のため"
    local rc=0
    register_owner "$OWNER" || rc=$?
    [[ $rc -eq 2 ]] && refuse_other_runtime   # 同じロックの中で、別の環境が名乗っていた（5.6）
    [[ $rc -eq 0 ]] || finish_auto_or_die 10 "前の後始末が終わらないため（${CLOSING_WAIT} 秒待ちました）"
    state_set "$STATUS_F" "STATE=starting" "ORG=${TARGET_ORG}" "REASON=" "WARNING=" "EXPIRES=" "EXPIRES_AT=" "BACKLOG=" || true   # 意図的エラー無視: 表示用
    # 裏で準備し、成功したらそのまま取得役になる（本番・種類の確認・組織 ID の照らし合わせは、start --auto が行う）
    # 裏での起動のため run 不使用。端末の入力・出力から切り離す。ふつうの出力は、取得役が log で同じログに書くため捨て、
    # エラー出力（bash のエラーなど、log を通らないもの）は、このスクリプトのログに追記する（捨てると、裏の失敗を追えない）
    #   --retry 1: 準備が失敗したら（「取らない」判断を除く）、持ち主が生きていれば、30 秒後に 1 回だけやり直す（retry_prepare）
    nohup bash "${SCRIPT_DIR}/sf-log.sh" start --auto --collect --retry 1 -o "$TARGET_ORG" --owner "$OWNER" </dev/null >/dev/null 2>>"$LOG_FILE" &
    disown
    log "INFO" "デバッグログの準備を、裏で始めました（組織: ${TARGET_ORG}）。状態は、ランチャーに表示します。"
    exit 0
}
