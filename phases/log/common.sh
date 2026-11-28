#!/bin/bash
# ==============================================================================
# phases/log/common.sh - sf-log.sh の部品: 小さな部品（設定ファイルの読み書き・ロック・環境の判断・持ち主の一覧・後始末。4 章）
# ==============================================================================
# bin/sf-log.sh が source する（単独では動かさない）。変数・関数は、sf-log.sh の 1〜3 章と、先に source した部品が用意する。
# 2026-11-28 に、1665 行あった sf-log.sh を、入口と 7 つの部品に分けた（中身は変えずに移した。章の番号は、元のまま）。
# ==============================================================================
# shellcheck disable=SC2154  # 変数は、source する bin/sf-log.sh（1〜3 章）が用意する（この部品だけでは、代入が見えない）

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

# ロック（mkdir。macOS に flock がないため）。中の pid ファイルに「PID 環境 取った時刻（エポック秒）」を書く（5.6）。
#   古いロックとして消すのは、次のときだけ: 環境が自分と同じ（または環境のない古い形）で、その PID が死んでいる／
#   環境が自分と違い、取った時刻から 10 分より古い（別の環境の PID は見えないため）。
#   pid ファイルがない・形が違う・時刻が未来のロックは、奪わずに待つ（上限まで待って取れなければ 1）
#   引数: フォルダ 待つ回数（0.2 秒ごと）。取れなければ 1
lock_take() {
    local d="$1" tries="$2" i=0 line
    while ! mkdir "$d" 2>/dev/null; do  # 条件チェックのため run 不使用（作れたら自分のもの）
        line=$(cat "$d/pid" 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
        if lock_is_stale "$line"; then
            rm -rf "$d" 2>/dev/null || true   # 意図的エラー無視: 古いロック（ほかの人が先に消すこともある）
            continue
        fi
        i=$((i + 1))
        [[ $i -ge $tries ]] && return 1
        sleep 0.2  # run 不使用: 待つだけ
    done
    # 一時ファイルに書いてから置き換える（書きかけの pid ファイルを、ほかの人に読ませない）
    printf '%s %s %s\n' "$$" "$RUNTIME_SELF" "$(date +%s)" > "$d/pid.tmp.$$" && mv -f "$d/pid.tmp.$$" "$d/pid"
}
# ロックの pid ファイルの 1 行から、古いロックかを判断する（lock_take）。古い = 0
lock_is_stale() {
    local pid rt at rest now
    read -r pid rt at rest <<< "$1"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    if [[ -z "$rt" || "$RUNTIME_SELF" == "unknown" ]] || same_rt "$rt"; then
        ! kill -0 "$pid" 2>/dev/null   # 条件チェックのため run 不使用（同じ環境・古い形: 持ち主の生死）
        return
    fi
    [[ "$at" =~ ^[0-9]+$ ]] || return 1
    now=$(date +%s)  # VAR=$(cmd) のため run 不使用
    [[ $at -le $now && $((now - at)) -gt $FOREIGN_LOCK_AGE ]]
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
# UTC の日時を、PC のタイムゾーンの HH:MM にする（ランチャーの表示用。ランチャーは日時を計算しない）
local_hm() {
    local t
    t=$(aj time local "$1" 2>/dev/null) || return 0  # VAR=$(cmd) のため run 不使用
    t="${t#*$'\t'}"
    printf '%s:%s' "${t:0:2}" "${t:2:2}"
}
# 今日（PC の日付）の保存済みのログの本数（ランチャーの「今日 N 本」。begin と取得役で同じ数え方にする）
count_today() {
    find "${APEX_DIR}/$(date +%Y%m%d)" -maxdepth 1 -name '*.log' 2>/dev/null | wc -l | tr -d ' '
}

# 失敗・取らないときの終わり方。手動: die（取らない理由も中断）／--auto: .status に書いて、終了コードで返す
#   引数: 終了コード（1 / 10） 理由
finish_auto_or_die() {
    local code="$1" reason="$2"
    if [[ $AUTO -eq 1 ]]; then
        # 別の組織の取得役が動いていれば、止まるよう頼む（つないでいない組織のログを取り続けないため。5.3。待たない）
        local cpid; cpid=$(collector_pid_local)  # VAR=$(cmd) のため run 不使用
        if pid_alive "$cpid" && [[ -n "${TARGET_ORG:-}" && "$(kv_get "$COLLECTOR_F" ORG)" != "$TARGET_ORG" ]]; then
            mkdir -p "$REQ_DIR" && : > "${REQ_DIR}/stop"
        fi
        if [[ "$code" -eq 10 ]]; then
            log "INFO" "デバッグログは取りません（${reason}）。"
            state_set "$STATUS_F" "STATE=skipped" "REASON=${reason}" "ORG=${TARGET_ORG:-}" || true   # 意図的エラー無視: 表示用
        else
            retry_prepare "$reason"   # やり直せるときは、ここで exec する（戻らない）。やり直さないときだけ、下へ進む
            log "WARNING" "デバッグログを取れませんでした（${reason}）。"
            state_set "$STATUS_F" "STATE=error" "REASON=${reason}" "ORG=${TARGET_ORG:-}" || true      # 意図的エラー無視: 表示用
        fi
        claim_release   # 取得役が立たない: 自分の名乗りを消す（5.6。別の環境を 30 分待たせない）
        exit "$code"
    fi
    die "$reason"
}

# 別の環境が扱っているときの終わり方（5.6）。.status・.owners・名乗りに触れない（扱っている環境の表示を、上書きしない）
#   begin・start --auto: 終了コード 10／leave・collect: 0／それ以外（start・pull・stop・auto）: 中断
refuse_other_runtime() {
    case "$CMD" in
        begin|start)
            if [[ "$CMD" == "begin" || $AUTO -eq 1 ]]; then
                log "INFO" "別の環境（${OTHER_RT}）で、デバッグログを取っています。この環境では取りません。"
                exit 10
            fi ;;
        leave)   log "INFO" "別の環境（${OTHER_RT}）で、デバッグログを取っています。この環境では何もしません。"; exit 0 ;;
        collect) note_log "取得役: 別の環境（${OTHER_RT}）が扱っているため、起動しません"; exit 0 ;;
    esac
    die "別の環境（${OTHER_RT}）で、デバッグログを取っています。"
}

# 持ち主（--owner の sf-start）が、まだ一覧にいて生きているか。後始末の最中（CLOSING）なら、いないとみなす
owner_present() {
    [[ -n "$OWNER" ]] || return 1
    grep -qxF -- "$OWNER" "$OWNERS_F" 2>/dev/null || return 1   # 条件チェックのため run 不使用
    [[ -z "$(kv_get "$OWNERS_F" CLOSING)" ]] || return 1
    pid_alive "${OWNER%%:*}"
}

# 裏の準備（begin が起動した start --auto --collect --retry N）の失敗を、やり直す（sf の一時的な失敗で、その日の取得が抜けないため。
#   2026-11-23 に実機で、sf 自身の読み込みエラー（MODULE_NOT_FOUND）で準備が 1 回失敗し、2 回目の起動では通った）。
#   「取らない」判断（終了コード 10）は、やり直さない（finish_auto_or_die が、終了コード 1 のときだけ呼ぶ）。
#   持ち主がもういない・後始末の最中なら、やり直さない（戻り値 1）。やり直すときは、残りの回数を 1 減らして exec する（戻らない）
retry_prepare() {
    local reason="$1"
    [[ $AUTO -eq 1 && $COLLECT_AFTER -eq 1 && $RETRY -gt 0 && -n "$ORG_ARG" ]] || return 1
    owner_present || return 1
    log "WARNING" "デバッグログの準備に失敗しました（${reason}）。${RETRY_WAIT} 秒後に、もう一度やります。"
    state_set "$STATUS_F" "STATE=starting" "ORG=${ORG_ARG}" "REASON=" "WARNING=準備に失敗しました（${reason}）。やり直しています" || true   # 意図的エラー無視: 表示用
    sleep "$RETRY_WAIT"  # run 不使用: 待つだけ（sf の一時的な失敗が収まるのを待つ）
    owner_present || { log "INFO" "待つあいだに sf-start が終了したため、やり直しません。"; return 1; }
    exec bash "${SCRIPT_DIR}/sf-log.sh" start --auto --collect -o "$ORG_ARG" --owner "$OWNER" --retry $((RETRY - 1))
}

# sf の --json の応答から name を読む（読めなければ「不明」）
sf_err_name() { local n; n=$(json_get "$1" name 2>/dev/null) || n=""; printf '%s' "${n:-不明}"; }  # VAR=$(cmd) のため run 不使用

# 消そうとしたものが、もうないというエラーか（引数: sf_err_name の結果）
sf_err_is_gone() {
    case "$1" in *NOT_FOUND*|*ENTITY_IS_DELETED*|*INVALID_CROSS_REFERENCE_KEY*) return 0 ;; esac
    return 1
}

# sf-log.sh が作るログの設定の DebugLevel の名前か（引数: DebugLevel の名前）。TraceFlag がこの DebugLevel を使っていれば、
#   別の場所の sf-log.sh のものとみなし、自動の取り始めで引き継ぐ。人・ほかの道具の設定は、自動では触らない（4.2）
is_sftools_debuglevel() {
    case "$1" in sf_tools_log_standard|sf_tools_log_detail) return 0 ;; esac
    return 1
}

# プロセスが生きているか（kill -0。PID が使い回されたときは「生きている」に見えるため、取得役は 12 時間で必ず止まる。5.5）
pid_alive() { [[ "$1" =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null; }  # 条件チェックのため run 不使用

# ---- 環境の混在（5.6）。1 つのプロジェクトのログは、同時には 1 つの環境だけが扱う ----
# 記録の環境の名前が、決まった 4 つのどれかか（unknown・空・不正な値は「環境不明」）
rt_known() { case "$1" in gitbash|wsl|macos|linux) return 0 ;; esac; return 1; }
# 記録の環境が、自分と同じか（unknown は、unknown 同士でも同じとみなさない）
same_rt() { [[ "$RUNTIME_SELF" != "unknown" && "$1" == "$RUNTIME_SELF" ]]; }
# 表示用の環境の名前
rt_label() { if rt_known "$1"; then printf '%s' "$1"; elif [[ -z "$1" ]]; then printf '不明（古い形の記録）'; else printf '不明'; fi; }
# 持ち主の印（PID:起動の時刻:環境の名前と乱数）が生きているか。環境の名前が自分と違う印は、生きていないとみなす
#   （別の環境の PID は、自分の環境の kill -0 では分からない。名乗りのない別の環境は、印を登録しないため、残りだけ）。
#   環境の名前のない古い印は、これまでどおり kill -0。自分の環境が unknown のときは、環境を見ない（これまでの動き）
mark_alive() {
    local r="${1##*:}" rt=""
    case "$r" in gitbash*) rt=gitbash ;; wsl*) rt=wsl ;; macos*) rt=macos ;; linux*) rt=linux ;; unknown*) rt=unknown ;; esac
    if [[ -n "$rt" && "$RUNTIME_SELF" != "unknown" ]] && ! same_rt "$rt"; then return 1; fi
    pid_alive "${1%%:*}"
}
# 取得役の PID（この環境のものだけ。別の環境の記録なら空。環境の記録のない古い形は、これまでどおり PID を出す）。
#   別の環境の PID に、kill -0・TERM を使わないため（たまたま同じ番号の、関係のないプロセスがある）
collector_pid_local() {
    local rt; rt=$(kv_get "$COLLECTOR_F" RUNTIME)  # VAR=$(cmd) のため run 不使用
    if [[ -n "$rt" && "$RUNTIME_SELF" != "unknown" ]] && ! same_rt "$rt"; then return 0; fi
    kv_get "$COLLECTOR_F" PID
}
# 時刻（エポック秒）が、今から sec 秒以内か。読めない・未来の時刻も「以内」とみなす（分からないものは、扱っているかもしれない側に倒す）
#   引数: 時刻 秒 今
_recent() { [[ ! "$1" =~ ^[0-9]+$ ]] || [[ $1 -gt $3 ]] || [[ $(($3 - $1)) -le $2 ]]; }
# 別の環境が、このプロジェクトのログを扱っているか（5.6 の判断。上から順に見る）。扱っている = 0。
#   結果: OTHER_RT（表示用の環境の名前）・OTHER_AGO（最後の合図・名乗りから何秒前か。分からなければ空）・OTHER_SRC（claim / collector）
#   自分の環境が unknown のときは、判断しない（1 を返す。これまでの動き）
other_runtime_active() {
    local now rt at started hb
    OTHER_RT=""; OTHER_AGO=""; OTHER_SRC=""
    [[ "$RUNTIME_SELF" == "unknown" ]] && return 1
    now=$(date +%s)  # VAR=$(cmd) のため run 不使用
    # 1. 名乗り（.claim）が別の環境で、30 分以内（読めない・未来の時刻を含む）
    if [[ -f "$CLAIM_F" ]]; then
        rt=$(kv_get "$CLAIM_F" RUNTIME); at=$(kv_get "$CLAIM_F" AT)  # VAR=$(cmd) のため run 不使用
        if ! same_rt "$rt" && _recent "$at" "$MIX_STALE" "$now"; then
            OTHER_RT=$(rt_label "$rt"); OTHER_SRC="claim"
            [[ "$at" =~ ^[0-9]+$ && $at -le $now ]] && OTHER_AGO=$((now - at))
            return 0
        fi
    fi
    # 2. 取得役の記録がない
    [[ -f "$COLLECTOR_F" ]] || return 1
    # 3. 起動の時刻が読めない・12 時間（取得役の上限）より古い → 止まったものとみなす
    started=$(kv_get "$COLLECTOR_F" STARTED)  # VAR=$(cmd) のため run 不使用
    [[ "$started" =~ ^[0-9]+$ ]] || return 1
    [[ $started -le $now && $((now - started)) -ge $MAX_RUN ]] && return 1
    rt=$(kv_get "$COLLECTOR_F" RUNTIME)  # VAR=$(cmd) のため run 不使用
    # 4. 環境の記録がない（この変更の前の取得役）→ kill -0 によらず「環境不明が扱っている」
    if [[ -z "$rt" ]]; then OTHER_RT=$(rt_label ""); OTHER_SRC="collector"; return 0; fi
    # 5. 自分と同じ環境 → これまでどおり（kill -0 は、呼び出し側が見る）
    same_rt "$rt" && return 1
    # 6. 別の環境 → 合図が 30 分以内（読めない・未来の時刻を含む）なら、扱っている
    hb=$(kv_get "$COLLECTOR_F" HEARTBEAT)  # VAR=$(cmd) のため run 不使用
    _recent "$hb" "$MIX_STALE" "$now" || return 1
    OTHER_RT=$(rt_label "$rt"); OTHER_SRC="collector"
    [[ "$hb" =~ ^[0-9]+$ && $hb -le $now ]] && OTHER_AGO=$((now - hb))
    return 0
}
# 持ち主の一覧に、指定した印のほかに、同じ環境の生きている印があるか（名乗りを消すかの判断）。ある = 0
same_env_owner_other() {
    local line
    [[ -f "$OWNERS_F" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ -n "$line" && "$line" != CLOSING=* && "$line" != "$1" ]] || continue
        mark_alive "$line" && return 0
    done < "$OWNERS_F"
    return 1
}
# 名乗り（.claim）を書く・書き直す（短いロック .lock の中で呼ぶ）。引数: 印 今
#   同じ環境の名乗りがあり、その印の持ち主が生きていれば、印は変えずに AT だけ今にする（入れ子・2 つ目の sf-start）
claim_write_locked() {
    local mark="$1" now="$2" cown
    if [[ -f "$CLAIM_F" ]] && same_rt "$(kv_get "$CLAIM_F" RUNTIME)"; then
        cown=$(kv_get "$CLAIM_F" OWNER)  # VAR=$(cmd) のため run 不使用
        if [[ -n "$cown" ]] && grep -qxF -- "$cown" "$OWNERS_F" 2>/dev/null && mark_alive "$cown"; then  # 条件チェックのため run 不使用
            kv_set "$CLAIM_F" "AT=${now}"
            return
        fi
    fi
    kv_set "$CLAIM_F" "RUNTIME=${RUNTIME_SELF}" "OWNER=${mark}" "AT=${now}"
}
# 取り始めに失敗して取得役が立たないときに、自分の名乗りを消す（start --auto・begin の失敗。5.6）。
#   消すのは、名乗りの印が自分の印で、同じ環境のほかの生きている持ち主がいなくて、この環境の取得役も動いていないときだけ
claim_release() {
    [[ -n "$OWNER" && -f "$CLAIM_F" ]] || return 0
    lock_take "$LOCK_DIR" 50 || return 0
    if [[ "$(kv_get "$CLAIM_F" OWNER)" == "$OWNER" ]] && ! same_env_owner_other "$OWNER" && ! pid_alive "$(collector_pid_local)"; then
        rm -f "$CLAIM_F" 2>/dev/null || true   # 意図的エラー無視: 消せなくても、30 分で古いとみなされる
    fi
    lock_drop "$LOCK_DIR"
}
# 取得役の生きている合図（.collector の HEARTBEAT）と、名乗りの AT を書き直す（5.6）。取得役のときだけ。
#   目を覚ますたび・sf を呼ぶ直前・ログを 1 本保存するたびに呼ぶ（HB_EVERY 秒より短い間隔では書かない）
heartbeat() {
    local now
    [[ $IS_COLLECTOR -eq 1 ]] || return 0
    now=$(date +%s)  # VAR=$(cmd) のため run 不使用
    [[ $((now - HB_LAST)) -ge $HB_EVERY ]] || return 0
    lock_take "$LOCK_DIR" 5 || return 0   # 取れなければ、次の機会に書く
    if [[ "$(kv_get "$COLLECTOR_F" PID)" == "$$" ]]; then   # 後始末で消えた印を、書き直して作り直さない
        kv_set "$COLLECTOR_F" "HEARTBEAT=${now}"
        claim_refresh_locked "$now"
    fi
    lock_drop "$LOCK_DIR"
    HB_LAST=$now
}
# 取得役が、名乗りの AT を書き直す（短いロックの中）。名乗りがない・古い別の環境のものなら、自分の環境で書く。
#   新しい別の環境の名乗りには触れない
claim_refresh_locked() {
    local now="$1" rt
    rt=$(kv_get "$CLAIM_F" RUNTIME)  # VAR=$(cmd) のため run 不使用
    if [[ -f "$CLAIM_F" ]] && same_rt "$rt"; then
        kv_set "$CLAIM_F" "AT=${now}"
    elif [[ ! -f "$CLAIM_F" ]] || ! _recent "$(kv_get "$CLAIM_F" AT)" "$MIX_STALE" "$now"; then
        kv_set "$CLAIM_F" "RUNTIME=${RUNTIME_SELF}" "OWNER=$$:$(date +%s):collector" "AT=${now}"
    fi
}

# sf の更新（sf-update-cli.sh）が動いているか（ロックの PID が生きている）。sf の入れ替えの途中に sf を呼ばないため（2026-11-24）
upgrade_running() { pid_alive "$(kv_get "$UPGRADE_LOCK" PID)"; }

# sf の更新が終わるのを待つ（start の最初。最大 UPGRADE_WAIT 秒）。待つあいだに持ち主がいなくなれば、準備をやめて 0 で終わる。
#   2026-11-24 に WSL の実機で、sf-start が裏で動かす sf-update-cli.sh（npm install -g @salesforce/cli@latest）と、裏の準備が重なり、
#   sf の部品が見つからずに準備が失敗した。やり直しでは、入れ替えの途中で消えていた WSL の sf の代わりに、PATH の後ろの
#   Windows の sf を拾い、とても遅くなった
wait_sf_upgrade() {
    local waited=0
    upgrade_running || return 0
    log "INFO" "sf の更新（sf-update-cli.sh）が終わるのを待ちます（最大 ${UPGRADE_WAIT} 秒）..."
    [[ $AUTO -eq 1 ]] && { state_set "$STATUS_F" "WARNING=sf の更新が終わるのを待っています" || true; }   # 意図的エラー無視: 表示用
    while upgrade_running; do
        if [[ -n "$OWNER" ]] && ! owner_present; then
            log "INFO" "待つあいだに sf-start が終了したため、準備をやめます。"
            claim_release   # 取得役が立たない: 自分の名乗りを消す（5.6）
            exit 0
        fi
        if [[ $waited -ge $UPGRADE_WAIT ]]; then
            log "WARNING" "sf の更新が ${UPGRADE_WAIT} 秒たっても終わりません。待たずに進みます。"
            return 0
        fi
        sleep "$TICK"  # run 不使用: 待つだけ
        waited=$((waited + TICK))
    done
    log "INFO" "sf の更新が終わりました（${waited} 秒待ちました）。"
    return 0
}

# 持ち主の一覧（.owners）から、死んだ持ち主（と、別の環境の印。5.6）を外す（短いロックの中）。出力: 生きている持ち主の数。後始末の最中（CLOSING）なら -1
owners_prune() {
    local line alive=() dead=0 closing="" tmp="${OWNERS_F}.tmp.$$"
    lock_take "$LOCK_DIR" 50 || { echo "?"; return 1; }
    if [[ -f "$OWNERS_F" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            [[ -n "$line" ]] || continue
            if [[ "$line" == CLOSING=* ]]; then closing="$line"; continue; fi
            if mark_alive "$line"; then alive+=("$line"); else dead=1; fi   # 別の環境の印は、残りとして外す（5.6）
        done < "$OWNERS_F"
        if [[ $dead -eq 1 ]]; then
            : > "$tmp"
            [[ -n "$closing" ]] && printf '%s\n' "$closing" >> "$tmp"
            [[ ${#alive[@]} -gt 0 ]] && printf '%s\n' "${alive[@]}" >> "$tmp"
            mv -f "$tmp" "$OWNERS_F"
        fi
    fi
    lock_drop "$LOCK_DIR"
    if [[ -n "$closing" ]]; then echo "-1"; else echo "${#alive[@]}"; fi
}

# 持ち主の一覧から 1 行を外し、残りの持ち主（CLOSING 以外）の数を出す（短いロックの中で呼ぶ）。引数: 外す行（空なら外さない）
owners_remove_locked() {
    local rm_line="$1" line n=0 tmp="${OWNERS_F}.tmp.$$"
    : > "$tmp"
    if [[ -f "$OWNERS_F" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            [[ -n "$line" && "$line" != "$rm_line" ]] || continue
            printf '%s\n' "$line" >> "$tmp"
            [[ "$line" == CLOSING=* ]] || n=$((n + 1))
        done < "$OWNERS_F"
    fi
    mv -f "$tmp" "$OWNERS_F"
    echo "$n"
}

# 持ち主の一覧に、自分の印を足す（5.1 の b。begin・start --auto --owner）。後始末の最中（CLOSING）なら、終わるまで最大 60 秒待つ。
#   CLOSING の印の持ち主が死んでいれば（別の環境の印を含む）、古いものとして消して進む。
#   同じロックの中で、別の環境が扱っていないかを、もう一度確かめ（5.6）、扱う環境の名乗り（.claim）を書いてから、印を足す。
#   戻り値: 0 = 足した／1 = 足せない（後始末が終わらない・ロックが取れない）／2 = 別の環境が扱っている（何も書かない）
register_owner() {
    local mark="$1" waited=0 closing
    while true; do
        lock_take "$LOCK_DIR" 50 || return 1
        if other_runtime_active; then lock_drop "$LOCK_DIR"; return 2; fi   # 後始末の最中の別の環境も、名乗りが残るため、ここで分かる
        closing=$(kv_get "$OWNERS_F" CLOSING)  # VAR=$(cmd) のため run 不使用
        if [[ -n "$closing" ]] && mark_alive "$closing"; then
            lock_drop "$LOCK_DIR"
            [[ $waited -ge $((CLOSING_WAIT * 5)) ]] && return 1
            waited=$((waited + 1)); sleep 0.2  # run 不使用: 後始末が終わるのを待つだけ
            continue
        fi
        [[ -n "$closing" ]] && owners_remove_locked "CLOSING=${closing}" >/dev/null
        claim_write_locked "$mark" "$(date +%s)"
        if ! grep -qxF -- "$mark" "$OWNERS_F" 2>/dev/null; then  # 条件チェックのため run 不使用（同じ印を 2 回足さない。入れ子の sf-start）
            printf '%s\n' "$mark" >> "$OWNERS_F"
        fi
        lock_drop "$LOCK_DIR"
        return 0
    done
}

# 取得役に止まるよう頼み、止まるのを待つ（4.5 の 1）。止まった・いない = 0／止まらない = 1
stop_collector() {
    local pid i
    pid=$(collector_pid_local)  # VAR=$(cmd) のため run 不使用（別の環境の PID には、何も送らない。5.6）
    pid_alive "$pid" || return 0
    [[ "$pid" == "$$" ]] && return 0
    mkdir -p "$REQ_DIR" && : > "${REQ_DIR}/stop"
    for ((i = 0; i < STOP_WAIT; i++)); do
        pid_alive "$pid" || { rm -f "${REQ_DIR}/stop"; return 0; }
        sleep 1  # run 不使用: 止まるのを待つだけ
    done
    kill -TERM "$pid" 2>/dev/null || true  # 意図的エラー無視: すでに止まっていることがある
    for ((i = 0; i < 10; i++)); do
        pid_alive "$pid" || { rm -f "${REQ_DIR}/stop"; return 0; }
        sleep 1  # run 不使用: 止まるのを待つだけ
    done
    return 1
}

# 後始末（4.5 の 1〜4。stop・leave・取得役の自分の後始末）。引数: 理由（.status の REASON）・self（取得役自身なら 1）
#   戻り値: 0 = 済んだ／1 = 取得役が止まらない（TraceFlag は残した）／2 = TraceFlag を消せなかった（ID は残した）
do_cleanup() {
    local reason="$1" self="${2:-0}" org tf j name
    if [[ "$self" != "1" ]] && ! stop_collector; then
        log "WARNING" "取得役が止まりません（PID $(kv_get "$COLLECTOR_F" PID)）。TraceFlag は残しました（最大 2 時間で切れます）。"
        state_set "$STATUS_F" "STATE=error" "REASON=取得役が止まりません" || true   # 意図的エラー無視: 表示用
        return 1
    fi
    org=$(kv_get "$STATE_F" ORG); tf=$(kv_get "$STATE_F" TRACE_FLAG_ID)  # VAR=$(cmd) のため run 不使用
    [[ -n "$ORG_ARG" ]] && org="$ORG_ARG"   # 消す先は、TraceFlag を作った組織（.state の ORG）。-o があれば、それ
    if [[ "$tf" =~ $ID_RE ]]; then
        check_sf_cli --cache
        if [[ -z "$org" ]]; then org=$(get_target_org "") || { log "WARNING" "接続先の組織エイリアスを特定できません。"; return 2; }; fi
        if j=$(run sf data delete record --use-tooling-api --sobject TraceFlag --record-id "$tf" --target-org "$org" --json); then
            log "SUCCESS" "TraceFlag を消しました（${tf}・組織: ${org}）。"
        else
            name=$(sf_err_name "$j")
            if sf_err_is_gone "$name"; then
                log "WARNING" "TraceFlag（${tf}）は、すでにありません（${name}）。"
            else
                log "WARNING" "TraceFlag（${tf}）を消せませんでした（${name}）。最大 2 時間で切れます。"
                state_set "$STATUS_F" "STATE=error" "REASON=TraceFlag を消せませんでした（${name}）" || true   # 意図的エラー無視: 表示用
                return 2
            fi
        fi
    else
        log "INFO" "sf-log.sh が作った TraceFlag はありません。"
    fi
    state_set "$STATE_F" "TRACE_FLAG_ID=" || true                               # 意図的エラー無視: 次の start で作り直す
    state_set "$STATUS_F" "STATE=stopped" "EXPIRES=" "EXPIRES_AT=" "REASON=${reason}" "BACKLOG=" || true   # 意図的エラー無視: 表示用（消した期限を残さない）
    rm -f "$COLLECTOR_F" 2>/dev/null || true                                    # 意図的エラー無視: 取得役の印を消す
    return 0
}
