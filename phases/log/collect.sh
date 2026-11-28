#!/bin/bash
# ==============================================================================
# phases/log/collect.sh - sf-log.sh の部品: collect（9c 章。裏の取得役）
# ==============================================================================
# bin/sf-log.sh が source する（単独では動かさない）。変数・関数は、sf-log.sh の 1〜3 章と、先に source した部品が用意する。
# 2026-11-28 に、1665 行あった sf-log.sh を、入口と 7 つの部品に分けた（中身は変えずに移した。章の番号は、元のまま）。
# ==============================================================================
# shellcheck disable=SC2154  # 変数は、source する bin/sf-log.sh（1〜3 章）が用意する（この部品だけでは、代入が見えない）

# ------------------------------------------------------------------------------
# 9c. collect（4.3。裏の取得役）。sf-start.sh が、start --auto の成功のあとに裏で起動する。人は打たない
# ------------------------------------------------------------------------------
# 取得役が止まるべきか（停止の依頼・後始末の最中・印の入れ替わり）。止まるべき = 0
collector_should_quit() {
    if [[ -f "${REQ_DIR}/stop" ]]; then rm -f "${REQ_DIR}/stop"; note_log "取得役: 停止の依頼で止まります"; return 0; fi
    [[ -n "$(kv_get "$OWNERS_F" CLOSING)" ]] && { note_log "取得役: 後始末の最中のため止まります"; return 0; }
    [[ "$(kv_get "$COLLECTOR_F" PID)" == "$$" ]] || { note_log "取得役: 印が入れ替わったため止まります"; return 0; }
    return 1
}

# 取得役が自分で後始末をして止まる（持ち主がいなくなった・12 時間）。引数: 理由
collector_finish() {
    local reason="$1"
    lock_take "$LOCK_DIR" 50 || exit 1
    if [[ -n "$(kv_get "$OWNERS_F" CLOSING)" ]]; then lock_drop "$LOCK_DIR"; exit 0; fi   # ほかの人が後始末をしている
    printf 'CLOSING=%s\n' "$$:$(date +%s):collector" >> "$OWNERS_F"
    lock_drop "$LOCK_DIR"
    note_log "取得役: ${reason}"
    local rc=0
    do_cleanup "$reason" 1 || rc=$?   # 失敗は、取得役は表示先がない（.status と sf-log.log に書く）
    rm -f "$OWNERS_F" 2>/dev/null || true   # 意図的エラー無視: CLOSING を消す
    [[ $rc -eq 0 ]] && rm -f "$CLAIM_F" 2>/dev/null   # 名乗りは最後に消す（5.6）
    exit 0
}

# pull の依頼があるか（compgen -G は使わない。Bash 3.2 で確実に使えるとは限らないため）
has_pull_request() {
    local f
    for f in "${REQ_DIR}"/pull.*; do [[ -e "$f" ]] && return 0; done
    return 1
}

# 待っている pull に応答する（9.3）。引数: ok / error
respond_pulls() {
    local f id
    for f in "${REQ_DIR}"/pull.*; do
        [[ -e "$f" ]] || continue
        id="${f##*/pull.}"
        if [[ "$id" =~ ^[0-9]+_[0-9]+_[0-9]+$ ]]; then
            printf 'RESULT=%s\n' "$1" > "${REQ_DIR}/.done.${id}.tmp" && mv -f "${REQ_DIR}/.done.${id}.tmp" "${REQ_DIR}/done.${id}"
        fi
        rm -f "$f"
    done
}

# 自分の TraceFlag を延ばす（4.3 の 2d）。延ばす前に、ID・種類を確かめる（人が置き換えたものを延ばさない）
collector_extend() {
    local tf j tsv id type st ex state dl found=0 now newexp
    tf=$(kv_get "$STATE_F" TRACE_FLAG_ID)  # VAR=$(cmd) のため run 不使用
    [[ "$tf" =~ $ID_RE ]] || { state_set "$STATUS_F" "WARNING=TraceFlag がないため、延ばせません" || true; return 1; }
    heartbeat
    j=$(run sf data query --use-tooling-api --target-org "$TARGET_ORG" --json \
        --query "SELECT Id, LogType, StartDate, ExpirationDate, DebugLevel.DeveloperName FROM TraceFlag WHERE TracedEntityId = '${USER_ID}'") || return 1
    tsv=$(printf '%s' "$j" | aj tflist 2>/dev/null) || return 1
    while IFS=$'\t' read -r id type st ex state dl; do
        [[ "$id" == "$tf" && "$type" == "USER_DEBUG" ]] && found=1
    done <<< "$tsv"
    if [[ $found -eq 0 ]]; then
        state_set "$STATUS_F" "WARNING=自分の TraceFlag が消えた・置き換わったため、延ばせません" || true   # 意図的エラー無視: 表示用
        return 1
    fi
    collector_should_quit && exit 0   # 書き込む直前にも確かめる（消された TraceFlag を延ばし直さない）
    now=$(now_z); newexp=$(aj time add "$now" --sec 7200)
    heartbeat
    run sf data update record --use-tooling-api --sobject TraceFlag --record-id "$tf" --target-org "$TARGET_ORG" --json \
        --values "StartDate=${now} ExpirationDate=${newexp}" >/dev/null || return 1
    state_set "$STATUS_F" "EXPIRES=${newexp}" "EXPIRES_AT=$(local_hm "$newexp")" "WARNING=" || true   # 意図的エラー無視: 表示用
    note_log "取得役: TraceFlag を延ばしました（期限 ${newexp}）"
    COLLECT_EXPIRES="$newexp"
}

# 別の場所の sf-start に引き継がれたので、取得をやめて止まる（4.3 の 2c2）。組織には書き込まない（相手の TraceFlag に触れない）。
#   持ち主の一覧（.owners）は残す: この sf-start の終了時の leave と、ランチャーの Start（取り戻す）が、そのまま働くため。
#   引数: 自分の TraceFlag の ID・相手の TraceFlag の ID。手元が、確かめたあとに変わっていたら、何もせずに戻る
collector_yield() {
    local tf="$1" other="$2"
    lock_take "$LOCK_DIR" 50 || return 0
    if [[ "$(kv_get "$STATE_F" TRACE_FLAG_ID)" != "$tf" || "$(kv_get "$STATE_F" ORG)" != "$TARGET_ORG" \
          || -n "$(kv_get "$OWNERS_F" CLOSING)" || "$(kv_get "$COLLECTOR_F" PID)" != "$$" ]]; then
        lock_drop "$LOCK_DIR"; return 0
    fi
    kv_set "$STATE_F" "TRACE_FLAG_ID="
    kv_set "$STATUS_F" "STATE=stopped" "EXPIRES=" "EXPIRES_AT=" "BACKLOG=" "WARNING=" "TAKEOVER=" "REASON=別の場所の sf-start に引き継がれたため"
    rm -f "$COLLECTOR_F" 2>/dev/null || true   # 意図的エラー無視: 取得役の印を消す
    same_rt "$(kv_get "$CLAIM_F" RUNTIME)" && rm -f "$CLAIM_F" 2>/dev/null   # 自分の環境の名乗りも消す（取得役がいなくなるため）
    lock_drop "$LOCK_DIR"
    note_log "取得役: 別の場所の sf-start（TraceFlag ${other}）に引き継がれたため、止まります"
    exit 0
}

# 自分の TraceFlag が、まだ自分のものかを確かめる（4.3 の 2c2。取得の回ごと）。
#   自分のものが有効でなく、別の sf-log.sh の有効な TraceFlag があれば、引き継がれたとみなして止まる（戻らない）。
#   自分のものがないだけ（人が消した・相手がもう終わった）なら、作り直さず、WARNING を書いて 1（延長もしない）。
#   期限が切れただけ（PC のスリープなど）で、相手がいなければ 0（延長で、また有効になる）。問い合わせの失敗は 0（判断しない）
collector_check_flag() {
    local tf j tsv id type st ex state dl mine_state="" other=""
    tf=$(kv_get "$STATE_F" TRACE_FLAG_ID)  # VAR=$(cmd) のため run 不使用
    [[ "$tf" =~ $ID_RE ]] || return 0
    [[ "$(kv_get "$STATE_F" ORG)" == "$TARGET_ORG" ]] || return 0   # 組織の切り替えの最中（別の組織の ID を、引き継ぎと誤らない）
    heartbeat
    j=$(run sf data query --use-tooling-api --target-org "$TARGET_ORG" --json \
        --query "SELECT Id, LogType, StartDate, ExpirationDate, DebugLevel.DeveloperName FROM TraceFlag WHERE TracedEntityId = '${USER_ID}'") || return 0
    tsv=$(printf '%s' "$j" | aj tflist 2>/dev/null) || return 0
    while IFS=$'\t' read -r id type st ex state dl; do
        [[ -n "$id" && "$type" == "USER_DEBUG" ]] || continue
        if [[ "$id" == "$tf" ]]; then mine_state="$state"
        elif [[ "$state" == "active" ]] && is_sftools_debuglevel "$dl"; then other="$id"; fi
    done <<< "$tsv"
    [[ "$mine_state" == "active" ]] && return 0
    if [[ -n "$other" ]]; then
        collector_yield "$tf" "$other"   # 引き継がれていれば、ここで終わる
        return 1
    fi
    [[ -n "$mine_state" ]] && return 0
    state_set "$STATUS_F" "WARNING=自分の TraceFlag が消えた・置き換わったため、新しいログは出ません（sf-start で取り直せます）" || true   # 意図的エラー無視: 表示用
    return 1
}

cmd_collect() {
    local org user started pid corg i now next=0 backoff rc n first=1 today cnt soon
    trap '' INT   # Ctrl+C を無視する（止めるのは、持ち主の見張りと、stop・leave）
    org=$(kv_get "$STATE_F" ORG); user=$(kv_get "$STATE_F" USER_ID)  # VAR=$(cmd) のため run 不使用
    [[ -n "$org" && "$user" =~ $ID_RE ]] || { note_log "取得役: .state に組織・ユーザーがありません"; exit 1; }
    TARGET_ORG="$org"; USER_ID="$user"
    started=$(date +%s)
    mkdir -p "$REQ_DIR" || exit 1

    # 1. 取得役の印（二重に動かさない。別の組織の取得役なら、止めてもらって入れ替わる）
    lock_take "$LOCK_DIR" 50 || exit 1
    if other_runtime_active; then lock_drop "$LOCK_DIR"; refuse_other_runtime; fi   # 印を書くロックの中で、もう一度（5.6）
    pid=$(collector_pid_local); corg=$(kv_get "$COLLECTOR_F" ORG)  # VAR=$(cmd) のため run 不使用
    if pid_alive "$pid" && [[ "$pid" != "$$" ]]; then
        if [[ "$corg" == "$org" ]]; then
            lock_drop "$LOCK_DIR"; note_log "取得役: すでに動いています（PID ${pid}）"; exit 0
        fi
        : > "${REQ_DIR}/stop"
        lock_drop "$LOCK_DIR"
        for ((i = 0; i < STOP_WAIT; i++)); do pid_alive "$pid" || break; sleep 1; done  # run 不使用: 止まるのを待つだけ
        pid_alive "$pid" && { note_log "取得役: 前の取得役（PID ${pid}）が止まりません"; exit 1; }
        lock_take "$LOCK_DIR" 50 || exit 1
        if other_runtime_active; then lock_drop "$LOCK_DIR"; refuse_other_runtime; fi
    fi
    rm -f "${REQ_DIR}/stop"
    # RUNTIME・HEARTBEAT: 別の環境から、扱っている環境と、生きているかが分かるように（5.6）
    kv_set "$COLLECTOR_F" "PID=$$" "STARTED=${started}" "ORG=${org}" "RUNTIME=${RUNTIME_SELF}" "HEARTBEAT=${started}"
    claim_refresh_locked "$started"
    lock_drop "$LOCK_DIR"
    IS_COLLECTOR=1; HB_LAST=$started
    state_set "$STATUS_F" "STATE=collecting" "ORG=${org}" "REASON=" "WARNING=" || true   # 意図的エラー無視: 表示用
    note_log "取得役: 起動しました（PID $$・組織 ${org}・間隔 ${INTERVAL} 秒）"
    COLLECT_EXPIRES=$(kv_get "$STATUS_F" EXPIRES)  # VAR=$(cmd) のため run 不使用
    backoff=$INTERVAL

    # 2. 繰り返す
    while true; do
        [[ $first -eq 1 ]] || sleep "$TICK"  # run 不使用: 目を覚ますまで待つだけ（sf は呼ばない）
        first=0
        heartbeat   # 生きている合図（5.6）
        now=$(date +%s)
        # a. 持ち主の見張り
        n=$(owners_prune)
        [[ "$n" == "-1" ]] && { note_log "取得役: 後始末の最中のため止まります"; exit 0; }
        [[ "$n" == "0" ]] && collector_finish "持ち主（sf-start）がいなくなったため、止まりました"
        [[ $((now - started)) -ge $MAX_RUN ]] && collector_finish "12 時間で止まりました。sf-start をやり直すと再開します"
        # b. 停止の依頼・後始末の最中・印の入れ替わり
        collector_should_quit && exit 0
        # c. 取得（間隔が来た・pull の依頼がある・前回の取り残しがある）
        # sf の更新（sf-update-cli.sh）が動いているあいだは、取らずに次に回す（sf の入れ替えの途中に、sf を呼ばない）
        if { [[ $now -ge $next ]] || has_pull_request; } && ! upgrade_running; then
            if lock_take "$FETCH_LOCK" 1; then
                rc=0; fetch_round || rc=$?
                LATE_WARN=""
                [[ $rc -eq 0 ]] && late_recheck   # 追いついた回だけ。目録に書き終えてから、下で pull に応える（9.3）
                lock_drop "$FETCH_LOCK"
                cnt=$(count_today)  # VAR=$(cmd) のため run 不使用
                case "$rc" in
                    0) respond_pulls ok; backoff=$INTERVAL; next=$(( $(date +%s) + INTERVAL ))
                       state_set "$STATUS_F" "STATE=collecting" "LAST_FETCH=$(date '+%H:%M')" "COUNT_TODAY=${cnt}" "BACKLOG=0" "WARNING=${LATE_WARN}" "LATE_WARNING=${LATE_WARN}" || true ;;
                    2) next=0
                       state_set "$STATUS_F" "LAST_FETCH=$(date '+%H:%M')" "COUNT_TODAY=${cnt}" "BACKLOG=50 本以上" || true ;;
                    *) respond_pulls error; backoff=$(( backoff * 2 > 600 ? 600 : backoff * 2 )); next=$(( $(date +%s) + backoff ))
                       state_set "$STATUS_F" "WARNING=取得に失敗しました（${backoff} 秒後にやり直します）" || true ;;
                esac
                # c2. 自分の TraceFlag が、まだ自分のものかを確かめる（取得のあと。引き継がれる前のログは、取り終えている）
                # d. TraceFlag の残りが 60 分未満なら、今から 2 時間に延ばす
                if collector_check_flag && [[ "$COLLECT_EXPIRES" =~ $ISO_RE ]]; then
                    soon=$(aj time add "$(now_z)" --sec 3600)
                    if [[ "$(aj time cmp "$COLLECT_EXPIRES" "$soon")" == "-1" ]]; then
                        collector_extend || note_log "取得役: TraceFlag を延ばせませんでした"
                    fi
                fi
            fi
        fi
        # 5 分より古い依頼・応答を消す（pull が待つのをやめたあとの残り）
        find "$REQ_DIR" -type f -mmin +5 -exec rm -f {} + 2>/dev/null || true   # 意図的エラー無視: 掃除だけ
    done
}
