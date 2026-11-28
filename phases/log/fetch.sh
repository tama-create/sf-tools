#!/bin/bash
# ==============================================================================
# phases/log/fetch.sh - sf-log.sh の部品: ログの取得（7 章。1 回分の取得・遅れて届くログの見直し・一覧の印）
# ==============================================================================
# bin/sf-log.sh が source する（単独では動かさない）。変数・関数は、sf-log.sh の 1〜3 章と、先に source した部品が用意する。
# 2026-11-28 に、1665 行あった sf-log.sh を、入口と 7 つの部品に分けた（中身は変えずに移した。章の番号は、元のまま）。
# ==============================================================================
# shellcheck disable=SC2154  # 変数は、source する bin/sf-log.sh（1〜3 章）が用意する（この部品だけでは、代入が見えない）

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
    heartbeat   # ログを 1 本保存するたび（5.6。取得役のときだけ書く）
}

# sf-log.log にだけ書く（画面に出さない。取得の件数など）
note_log() { printf '[%s] [INFO] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"; }
note_warn() { printf '[%s] [WARNING] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG_FILE"; }

# 目録（.index）の写しを作る（改行で終わる行だけ。取得役が書いている途中の行を読まないため。4.4 の 3）。引数: 写しのファイル
index_snapshot() {
    local out="$1"
    : > "$out" || return 1
    [[ -f "$INDEX_F" ]] || return 0
    cp "$INDEX_F" "$out" || return 1
    if [[ -s "$out" && -n "$(tail -c 1 "$out")" ]]; then   # 最後が改行で終わらない → 書きかけの行を除く
        sed '$d' "$out" > "${out}.t" && mv -f "${out}.t" "$out" || return 1
    fi
}
# 目録（の写し）の行数と、最後の行のログの ID（タブ区切り。空なら「0<タブ>」）。要約のしおり（LAST_READ_LINE・LAST_READ_ID）にする
index_mark() {
    [[ -s "$1" ]] || { printf '0\t'; return 0; }
    awk -F'\t' 'END { printf "%d\t%s", NR, $2 }' "$1"
}
# 今の目録の印（start・組織の切り替えで、要約のしおりを「今」にするため）
index_mark_now() {
    local t m
    t=$(mktemp "${TMPDIR:-/tmp}/sf-log-idx.XXXXXX") || { printf '0\t'; return 0; }  # VAR=$(cmd) のため run 不使用
    if index_snapshot "$t"; then m=$(index_mark "$t"); else m=$'0\t'; fi  # VAR=$(cmd) のため run 不使用
    rm -f "$t" "${t}.t" 2>/dev/null || true   # 意図的エラー無視: 一時ファイルの後始末
    printf '%s' "$m"
}

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
    heartbeat   # sf を呼ぶ直前（5.6。取得役のときだけ書く）
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
        heartbeat
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
                heartbeat
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

# 遅れて現れるログの拾い直し（doc/sf-log-design.md 8.3。冒頭コメントの「拾い直し」）。
#   取得のロックを持ったまま、通常の取得が追いついた回（fetch_round が 0）に 1 回だけ呼ぶ。
#   結果: LATE_WARN（空 = 知らせることなし）。戻り値は常に 0（失敗しても、その回の取得は成功として扱う。しおりは進めてある）
#   2026-11-24 に tama-dev で、9.5 秒の匿名 Apex のログが、あとから始まった短い処理のログより遅れて一覧に現れることを確かめた
late_recheck() {
    local last now lower lf page=0 before_st="" before_id="" where q lj tsv n got=0 seen=0 failed=0 full=0 i f
    local ids=() mine=() starts=() lens=() durs=() ops=() stats=() id m st len dur op status
    LATE_WARN=""
    last=$(kv_get "$STATE_F" LAST_FETCH)  # VAR=$(cmd) のため run 不使用
    [[ "$last" =~ $ISO_RE ]] || return 0
    now=$(now_z); lower=$(aj time add "$now" --sec "-${LATE_WINDOW}")  # VAR=$(cmd) のため run 不使用
    lf=$(kv_get "$STATE_F" LATE_FROM)  # VAR=$(cmd) のため run 不使用
    if [[ -n "$lf" && ! "$lf" =~ $ISO_RE ]]; then state_set "$STATE_F" "LATE_FROM=" || true; lf=""; fi   # 意図的エラー無視: 形が違えば消すだけ
    if [[ -n "$lf" && "$(aj time cmp "$lf" "$(aj time add "$now" --sec "-${LATE_MAX_AGE}")")" == "-1" ]]; then
        state_set "$STATE_F" "LATE_FROM=" || true   # 意図的エラー無視: 次の回にも同じ判定で消える
        LATE_WARN="遅れて現れたログの拾い直しの失敗が 24 時間続いたため、${lf}（UTC）からの分の拾い直しをやめました"
        note_warn "拾い直し: ${LATE_WARN}"
        lf=""
    fi
    # しおりが 30 分より古く、前の回の失敗もなければ、範囲が空（しおりより後は、通常の取得が取る）
    if [[ -z "$lf" && "$(aj time cmp "$last" "$lower")" == "-1" ]]; then return 0; fi
    [[ -n "$lf" && "$(aj time cmp "$lf" "$lower")" == "-1" ]] && lower="$lf"
    if [[ "$(aj time cmp "$lower" "$last")" == "1" ]]; then state_set "$STATE_F" "LATE_FROM=" || true; return 0; fi   # 意図的エラー無視: 範囲が空

    while [[ $page -lt $LATE_MAX_PAGES ]]; do
        page=$((page + 1))
        where="LogUserId = '${USER_ID}' AND StartTime >= ${lower} AND StartTime <= ${last}"
        [[ -n "$before_st" ]] && where="${where} AND (StartTime < ${before_st} OR (StartTime = ${before_st} AND Id < '${before_id}'))"
        q="SELECT Id, LogUserId, StartTime, Operation, Request, Status, LogLength, DurationMilliseconds FROM ApexLog WHERE ${where} ORDER BY StartTime DESC, Id DESC LIMIT ${LATE_PAGE}"
        # run を通さない（8.3 の一覧と扱いをそろえる。応答は自分のログの見出しだけ）
        heartbeat
        if ! lj=$(sf data query --use-tooling-api --target-org "$TARGET_ORG" --json --query "$q" 2>/dev/null); then  # VAR=$(cmd) のため run 不使用（上の理由）
            note_warn "拾い直し: 一覧の失敗（$(sf_err_name "$lj")）"; failed=1; break
        fi
        if ! tsv=$(printf '%s' "$lj" | aj list --user "$USER_ID" 2>/dev/null); then  # VAR=$(cmd) のため run 不使用
            note_warn "拾い直し: 一覧の応答の形が正しくありません"; failed=1; break
        fi
        lj=""
        # 先に配列へ読む（本文の取得の sf が、標準入力の残りを読まないため）
        ids=(); mine=(); starts=(); lens=(); durs=(); ops=(); stats=()
        while IFS=$'\t' read -r id m st len dur op status; do
            [[ -n "$id" ]] || continue
            ids+=("$id"); mine+=("$m"); starts+=("$st"); lens+=("$len"); durs+=("$dur"); ops+=("$op"); stats+=("$status")
        done <<< "$tsv"
        tsv=""
        n=${#ids[@]}
        for ((i = 0; i < n; i++)); do
            before_st="${starts[i]}"; before_id="${ids[i]}"
            [[ "${mine[i]}" == "1" ]] || continue   # 念のため（検索は自分のログだけ）
            seen=$((seen + 1))
            grep -qF -- "	${ids[i]}	" "$INDEX_F" 2>/dev/null && continue  # 条件チェックのため run 不使用（目録にあれば取らない）
            # -i で 1 本だけ取る（ID を指定するので、他の人のログは入らない）
            { rm -rf "$FETCH_TMP" && mkdir -p "${FETCH_TMP}/one"; } || { failed=1; break; }
            heartbeat
            run sf apex get log -i "${ids[i]}" -d "${FETCH_TMP}/one" --target-org "$TARGET_ORG" >/dev/null || { failed=1; break; }
            f="${FETCH_TMP}/one/${ids[i]}.log"
            [[ -f "$f" ]] || { note_warn "拾い直し: ${ids[i]} のファイルがありません"; failed=1; break; }
            save_one "$f" "${ids[i]}" "${starts[i]}" "${ops[i]}" "${stats[i]}" "${lens[i]}" "${durs[i]}" || { failed=1; break; }
            got=$((got + 1))
        done
        [[ $failed -eq 1 ]] && break
        [[ $n -lt $LATE_PAGE ]] && break
        [[ $page -ge $LATE_MAX_PAGES ]] && full=1
    done
    rm -rf "$FETCH_TMP" 2>/dev/null || true   # 意図的エラー無視: 次の取得の最初にも空にする
    note_log "拾い直し: 自分のログ ${seen} 本を見て、${got} 本を拾い直しました（${lower}〜${last}。UTC）"
    if [[ $failed -eq 1 ]]; then
        # その回の下限を残す（範囲の下限は毎回進むため、残さないと、失敗したログが次の回には範囲の外に出ることがある）
        state_set "$STATE_F" "LATE_FROM=${lower}" || true   # 意図的エラー無視: 書けなければ、次の回は「今から 30 分前」から
        LATE_WARN="${LATE_WARN:+${LATE_WARN}。}遅れて現れたログの拾い直しに失敗しました（次の回に、${lower}（UTC）からやり直します）"
        note_warn "拾い直し: ${LATE_WARN}"
        return 0
    fi
    state_set "$STATE_F" "LATE_FROM=" || true   # 意図的エラー無視: 残っても、次の回に拾い直すだけ
    if [[ $full -eq 1 ]]; then
        LATE_WARN="${LATE_WARN:+${LATE_WARN}。}拾い直しの範囲に自分のログが $((LATE_PAGE * LATE_MAX_PAGES)) 本を超えてあったため、${lower}〜${before_st}（UTC）に始まったログの一部は、拾い直していないかもしれません"
        note_warn "拾い直し: ${LATE_WARN}"
    fi
    return 0
}
