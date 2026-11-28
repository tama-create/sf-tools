#!/bin/bash
# ==============================================================================
# phases/log/stop.sh - sf-log.sh の部品: stop（9 章）と leave（9b 章。sf-start の終了時）
# ==============================================================================
# bin/sf-log.sh が source する（単独では動かさない）。変数・関数は、sf-log.sh の 1〜3 章と、先に source した部品が用意する。
# 2026-11-28 に、1665 行あった sf-log.sh を、入口と 7 つの部品に分けた（中身は変えずに移した。章の番号は、元のまま）。
# ==============================================================================
# shellcheck disable=SC2154  # 変数は、source する bin/sf-log.sh（1〜3 章）が用意する（この部品だけでは、代入が見えない）

# ------------------------------------------------------------------------------
# 9. stop（4.5）
# ------------------------------------------------------------------------------
cmd_stop() {
    local mark rc=0
    # 人の判断で止める: 持ち主の一覧にかかわらず止める（一覧も空にする）。後始末の最中は CLOSING を書く（5.2）
    mark="$$:$(date +%s):stop"
    if lock_take "$LOCK_DIR" 50; then
        printf 'CLOSING=%s\n' "$mark" > "$OWNERS_F"
        lock_drop "$LOCK_DIR"
    fi
    do_cleanup "sf-log.sh stop で止めました" || rc=$?
    rm -f "$OWNERS_F" 2>/dev/null || true   # 意図的エラー無視: 一覧（と CLOSING）を消す
    [[ $rc -eq 0 ]] && rm -f "$CLAIM_F" 2>/dev/null   # 名乗りは最後に消す（5.6。別の環境は、このあとで名乗れる）
    case "$rc" in
        1) die "取得役が止まらないため、TraceFlag を残しました。" ;;
        2) die "TraceFlag を消せませんでした（sf-tools/logs/sf-log.log を参照）。" ;;
    esac
    log "INFO" "手元のログ（${APEX_DIR}/）は残しました。"
    exit 0
}

# ------------------------------------------------------------------------------
# 9b. leave（5.2。sf-start の終了時）: 持ち主の一覧から自分を外し、誰もいなければ止める
# ------------------------------------------------------------------------------
cmd_leave() {
    local n rc=0
    lock_take "$LOCK_DIR" 50 || { log "WARNING" "手元の状態のロックを取れませんでした。"; exit 0; }
    if ! grep -qxF -- "$OWNER" "$OWNERS_F" 2>/dev/null; then  # 条件チェックのため run 不使用
        lock_drop "$LOCK_DIR"
        log "INFO" "持ち主の一覧に、この印はありません（何もしません）。"
        exit 0   # 登録していない sf-start の終了で、ほかの人・手動の start の TraceFlag を消さない
    fi
    owners_remove_locked "$OWNER" >/dev/null
    # 残りは、生きている sf-start だけを数える。PC の再起動などで後始末できずに終わった印は、取得役がいないと残ったままになり、
    #   数えると、最後の sf-start を終了しても TraceFlag を消さない（2026-11-28 に再現）
    n=$(owners_drop_dead_locked)  # VAR=$(cmd) のため run 不使用
    if [[ "$n" -gt 0 ]]; then
        lock_drop "$LOCK_DIR"
        log "INFO" "ほかの sf-start が起動中（残り ${n} 件）のため、デバッグログの取得は止めません（組織のログの設定は残ります。すべての sf-start を終了すると消します）。"
        exit 0
    fi
    printf 'CLOSING=%s\n' "$OWNER" >> "$OWNERS_F"   # 後始末の最中（新しい sf-start は、終わるまで登録を待つ）
    lock_drop "$LOCK_DIR"
    do_cleanup "すべての sf-start が終了したため" || rc=$?
    rm -f "$OWNERS_F" 2>/dev/null || true   # 意図的エラー無視: CLOSING を消す
    [[ $rc -eq 0 ]] && rm -f "$CLAIM_F" 2>/dev/null   # 名乗りは最後に消す（5.6。別の環境は、このあとで名乗れる）
    [[ $rc -eq 0 ]] || log "WARNING" "デバッグログの後始末が、最後まで終わりませんでした（sf-tools/logs/sf-log.log を参照）。"
    exit 0   # sf-start の終了を止めない（WARNING だけ）
}
