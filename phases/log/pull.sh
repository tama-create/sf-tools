#!/bin/bash
# ==============================================================================
# phases/log/pull.sh - sf-log.sh の部品: pull（8 章。取得役への依頼・要約）
# ==============================================================================
# bin/sf-log.sh が source する（単独では動かさない）。変数・関数は、sf-log.sh の 1〜3 章と、先に source した部品が用意する。
# 2026-11-28 に、1665 行あった sf-log.sh を、入口と 7 つの部品に分けた（中身は変えずに移した。章の番号は、元のまま）。
# ==============================================================================
# shellcheck disable=SC2154  # 変数は、source する bin/sf-log.sh（1〜3 章）が用意する（この部品だけでは、代入が見えない）

# ------------------------------------------------------------------------------
# 8. pull（4.4）
# ------------------------------------------------------------------------------
# 取得役に、取得を頼む（9.3）。依頼は ID つきのファイル（一時ファイルに書いてから mv）。自分の ID の応答だけを待つ
#   出力: ok / error / timeout
request_collector() {
    local id i res cpid
    id="$$_$(date +%s)_${RANDOM}"
    mkdir -p "$REQ_DIR" || { echo "timeout"; return 0; }
    printf 'AT=%s\n' "$(date +%s)" > "${REQ_DIR}/.pull.${id}.tmp" && mv -f "${REQ_DIR}/.pull.${id}.tmp" "${REQ_DIR}/pull.${id}"
    cpid=$(collector_pid_local)  # VAR=$(cmd) のため run 不使用
    for ((i = 0; i < PULL_WAIT; i++)); do
        if [[ -f "${REQ_DIR}/done.${id}" ]]; then
            res=$(kv_get "${REQ_DIR}/done.${id}" RESULT)  # VAR=$(cmd) のため run 不使用
            rm -f "${REQ_DIR}/done.${id}"
            echo "${res:-error}"; return 0
        fi
        pid_alive "$cpid" || break
        sleep 1  # run 不使用: 応答を待つだけ
    done
    rm -f "${REQ_DIR}/pull.${id}"
    echo "timeout"
}

cmd_pull() {
    local rc=0 round since now notes=() tmp_list snap cnt omitted first_om last_om ts out_md hdr cpid corg res v mark
    local mode rl rid old at found base
    prepare_org full
    # しおりが別の組織・ユーザーのものなら、今から取り直す（別の組織の時刻・ID を使わない）
    if [[ "$(kv_get "$STATE_F" ORG)" != "$TARGET_ORG" || "$(kv_get "$STATE_F" USER_ID)" != "$USER_ID" ]]; then
        now=$(now_z)
        mark=$(index_mark_now)  # VAR=$(cmd) のため run 不使用
        state_set "$STATE_F" "ORG=${TARGET_ORG}" "USER_ID=${USER_ID}" "LAST_FETCH=$(aj time add "$now" --sec -1800)" "LAST_FETCH_ID=" \
            "LATE_FROM=" "LAST_READ_LINE=${mark%%$'\t'*}" "LAST_READ_ID=${mark#*$'\t'}" "LAST_READ=" "LAST_READ_IDS=" || die "手元の状態を書けません。"
    fi

    cpid=$(collector_pid_local); corg=$(kv_get "$COLLECTOR_F" ORG)  # VAR=$(cmd) のため run 不使用
    if pid_alive "$cpid"; then
        # 取得役が生きている → 自分では取らず、取得役に頼む（組織から取って、しおりを書くのは取得役だけ。9.3）
        [[ "$corg" == "$TARGET_ORG" ]] || die "取得役が、別の組織（${corg}）で動いています（PID ${cpid}）。"
        res=$(request_collector)  # VAR=$(cmd) のため run 不使用
        case "$res" in
            ok)    notes+=("取得役: 動作中（最後の取得 $(kv_get "$STATUS_F" LAST_FETCH)）")
                   v=$(kv_get "$STATUS_F" LATE_WARNING); [[ -n "$v" ]] && notes+=("$v") ;;  # VAR=$(cmd) のため run 不使用
            error) notes+=("取得役: 直前の取得に失敗しています（sf-tools/logs/sf-log.log を参照）。手元にある分で要約しました") ;;
            *)     log "WARNING" "取得役の取り込みが、${PULL_WAIT} 秒で終わりませんでした。手元にある分で要約します。"
                   notes+=("取り込みが終わっていません（残り約 $(kv_get "$STATUS_F" BACKLOG) 本）。手元にある分で要約しました。少し待って、もう一度 pull してください") ;;
        esac
    else
        # 取得役がいない → 自分で取る（取得のロックを持つ。最大 90 秒待つ）
        lock_take "$FETCH_LOCK" 450 || die "取得のロックを取れませんでした（${FETCH_LOCK}。ほかの取得が終わりません）。"
        for round in 1 2 3 4; do
            rc=0; fetch_round || rc=$?
            [[ $rc -eq 2 ]] || break
        done
        LATE_WARN=""
        [[ $rc -eq 0 ]] && late_recheck   # 追いついたときだけ（200 本の上限で止まったら、次の回に回す。8.3）
        lock_drop "$FETCH_LOCK"
        [[ -n "$LATE_WARN" ]] && notes+=("$LATE_WARN")
        [[ $rc -eq 1 ]] && die "ログを取得できませんでした（sf-tools/logs/sf-log.log を参照）。"
        [[ $rc -eq 2 ]] && notes+=("取り込みの残りがあります（200 本を超えました）。もう一度 sf-log.sh pull を実行すると、続きを取ります。")
        notes+=("取得役: 動いていません（この pull が、組織から直接取りました）")
    fi
    if [[ -z "$(kv_get "$STATE_F" TRACE_FLAG_ID)" ]]; then
        # 止まった理由（別の場所の sf-start に引き継がれた、など）があれば添える（AI が、状況を知れるように）
        v=""
        [[ "$(kv_get "$STATUS_F" STATE)" == "stopped" ]] && v=$(kv_get "$STATUS_F" REASON)  # VAR=$(cmd) のため run 不使用
        notes+=("sf-log.sh の TraceFlag がありません（新しいログは出ません${v:+。理由: ${v}}）。人に sf-start か sf-log.sh start を頼んでください")
    fi
    v=$(kv_get "$STATUS_F" EXPIRES); [[ -n "$v" ]] && notes+=("TraceFlag の期限: ${v}（UTC）")  # VAR=$(cmd) のため run 不使用

    # 要約に入れるログを選ぶ（4.4 の 3）。要約のロックを取ってから、しおりを読む（同時に動く pull が、先にしおりを進めることがあるため）。
    #   開始時刻ではなく、目録に足された順で選ぶ（遅れて拾い直したログ（8.3）は、開始時刻が、前回の要約のログより前のことがある）
    now=$(now_z)
    tmp_list=$(mktemp "${TMPDIR:-/tmp}/sf-log-list.XXXXXX") || die "一時ファイルを作れません。"
    snap=$(mktemp "${TMPDIR:-/tmp}/sf-log-snap.XXXXXX") || { rm -f "$tmp_list"; die "一時ファイルを作れません。"; }
    READ_LOCK_HELD=0
    trap 'rm -f "$tmp_list" "$snap" "${snap}.t"; [[ ${READ_LOCK_HELD:-0} -eq 1 ]] && lock_drop "$READ_LOCK"' EXIT
    if lock_take "$READ_LOCK" "$READ_TRIES"; then
        READ_LOCK_HELD=1
    else
        log "WARNING" "要約のロックを取れませんでした（${READ_LOCK}）。しおりを読まず・進めずに要約します。"
        notes+=("要約のロックを取れませんでした（ほかの pull が動いています）。しおりを進めずに、直近 ${SINCE_MIN:-30} 分に始まったログで要約しました")
    fi
    index_snapshot "$snap" || die "目録（${INDEX_F}）を読めません。"
    mode="time"; since=""
    if [[ -n "$SINCE_MIN" ]]; then
        since=$(aj time add "$now" --sec "-$((SINCE_MIN * 60))")
    elif [[ $READ_LOCK_HELD -eq 1 ]]; then
        rl=$(kv_get "$STATE_F" LAST_READ_LINE); rid=$(kv_get "$STATE_F" LAST_READ_ID)  # VAR=$(cmd) のため run 不使用
        old=$(kv_get "$STATE_F" LAST_READ)  # VAR=$(cmd) のため run 不使用
        if [[ -z "$rl" && "$old" =~ $ISO_RE ]]; then
            # 古い .state からの移す（9.2）: 開始が LAST_READ より前の行と、同じ秒で LAST_READ_IDS にある行を「見た」とする
            rl=$(awk -F'\t' -v s="$old" -v ids=",$(kv_get "$STATE_F" LAST_READ_IDS)," \
                '!(($3 < s) || ($3 == s && index(ids, "," $2 ",") > 0)) { print NR - 1; f = 1; exit } END { if (!f) print NR }' "$snap")
            rid=""; [[ "$rl" -gt 0 ]] && rid=$(awk -F'\t' -v n="$rl" 'NR == n { print $2; exit }' "$snap")
            log "INFO" "要約のしおりを、新しい形（目録の ${rl} 行目）に移しました。"
        fi
        if [[ "$rl" == "0" && -z "$rid" ]]; then
            mode="line"; base=0
        elif [[ "$rl" =~ ^[0-9]+$ && "$rid" =~ $ID_RE ]]; then
            at=$(awk -F'\t' -v n="$rl" 'NR == n { print $2; exit }' "$snap")
            if [[ "$at" == "$rid" ]]; then
                mode="line"; base="$rl"
            else
                found=$(awk -F'\t' -v id="$rid" '$2 == id { print NR; exit }' "$snap")
                if [[ -n "$found" ]]; then
                    log "WARNING" "目録の行がずれていたため、要約のしおりの行を探し直しました（${rl} → ${found} 行目）。"
                    mode="line"; base="$found"
                fi
            fi
        fi
        if [[ "$mode" != "line" ]]; then
            [[ -n "${rl}${rid}" ]] && log "WARNING" "前回の要約のしおりが使えないため、直近 30 分に始まったログを対象にします。"
        fi
    fi
    if [[ "$mode" == "line" ]]; then
        awk -F'\t' -v b="$base" 'NR > b' "$snap" | LC_ALL=C sort -t$'\t' -k3,3 -k2,2 > "$tmp_list"  # 選ぶだけ（失敗は、下の件数で分かる）
    else
        [[ -n "$since" ]] || since=$(aj time add "$now" --sec -1800)
        awk -F'\t' -v s="$since" '$3 >= s' "$snap" | LC_ALL=C sort -t$'\t' -k3,3 -k2,2 > "$tmp_list"  # 選ぶだけ（同上）
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

    # 要約のしおりを、読んだ目録の最後の行に進める（成功したときだけ。--since・ロックが取れないときは進めない。4.4 の 5）
    if [[ $READ_LOCK_HELD -eq 1 && -z "$SINCE_MIN" ]]; then
        mark=$(index_mark "$snap")  # VAR=$(cmd) のため run 不使用
        state_set "$STATE_F" "LAST_READ_LINE=${mark%%$'\t'*}" "LAST_READ_ID=${mark#*$'\t'}" "LAST_READ=" "LAST_READ_IDS=" \
            || log "WARNING" "要約のしおりを書けませんでした。"
    fi
    if [[ $READ_LOCK_HELD -eq 1 ]]; then lock_drop "$READ_LOCK"; READ_LOCK_HELD=0; fi
    hdr=$(head -1 "${APEX_DIR}/latest.md")
    printf '%s\n%s\n' "${hdr#\# }" "${APEX_DIR}/latest.md"
    exit 0
}
