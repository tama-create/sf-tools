#!/bin/bash
# ==============================================================================
# phases/metasync/plan.sh - sf-metasync.sh の部品: 計画・秘密の検査・作業ツリーへの反映（6 章の PLAN・SCAN・APPLY）
# ==============================================================================
# bin/sf-metasync.sh が source する（単独では動かさない）。変数・関数は、sf-metasync.sh の 1〜5 章 と、先に source した部品が用意する。
# 2026-11-28 に、sf-metasync.sh の 6 章（フェーズ定義） を、部品に分けた（中身は変えずに移した）。
# ==============================================================================
# shellcheck disable=SC2154  # 変数は、source する bin/sf-metasync.sh が用意する（この部品だけでは、代入が見えない）

# 【PLAN】手元と取得結果を比べて、計画（追加・変更・削除・保留）を作り、要約を表示する（手順 8・9）
#   戻り値: 0（計画できた）／ NG（作れなかった）。保留の有無は PLAN_RC（0 または 3）に入る
PLAN_RC=0
phase_plan() {
    local args=(plan --repo . --fetched "$WORK_DIR" --types-file "$METADATA_CONFIG" --dirs-table "${SCRIPT_DIR}/../config/metadata-dirs.txt"
                --out "$PLAN_FILE" --recent-files "$RECENT_FILES" --retrieve-json "$RETRIEVE_JSON")
    [[ "$ALLOW_MASS" -eq 1 ]] && args+=(--allow-mass-delete)
    # 追加の取得の扱い: off でも表と状態（off）を渡す（on で入れた標準オブジェクトの部品を、off に戻した回に消さないため）。on は、結果（ok / failed）と、
    #   取るのに使った package.xml（取れたかを、ディスクで確かめる）も渡す
    if [[ "$EXTRA_MODE" == "on" && ! -f "$EXTRA_TABLE" ]]; then
        log "ERROR" "追加の取得の表が見つかりません（${EXTRA_TABLE}）。標準オブジェクトの部品を守れないため、計画を作りません（sf-tools の更新を確認してください）。"
        return $RET_NG
    fi
    if [[ -f "$EXTRA_TABLE" ]]; then
        if [[ "$EXTRA_MODE" == "on" ]]; then
            args+=(--extra-config "$EXTRA_TABLE" --extra-json "$EXTRA_JSON" --extra-state "$EXTRA_STATE")
            [[ "$EXTRA_STATE" == "ok" && -f "$WORK_DIR/extra.package.xml" ]] && args+=(--extra-manifest "$WORK_DIR/extra.package.xml")
        else
            args+=(--extra-config "$EXTRA_TABLE" --extra-state off)
        fi
    fi
    local summary line
    # run 不使用: 戻り値（0 / 3 / 1）で分岐し、要約をログにも記録するため
    summary=$("$NODE_BIN" "$METASYNC_JS" "${args[@]}" 2>&1)
    PLAN_RC=$?
    _log_node_lines "$summary"
    [[ $PLAN_RC -eq 0 || $PLAN_RC -eq 3 ]] || return $RET_NG
    # コミットの本文・確認の要否に使う件数（VAR=$(cmd) のため run 不使用）
    PLAN_COUNTS=$(awk -F'\t' '{c[$1]++} END{printf "追加 %d 件 / 変更 %d 件 / 削除 %d 件 / 削除の保留 %d 件", c["A"], c["M"], c["D"], c["H"]}' "$PLAN_FILE")
    PLAN_CHANGES=$(awk -F'\t' '$1=="A"||$1=="M"||$1=="D"{n++} END{print n+0}' "$PLAN_FILE")
    # 検知が「変更なし」だったのに、実際は変更があったとき（shadow の確かめ、および --full の日次の取得）は、一覧を出す。
    #   区分 C の種類（検知できない）の変更を含む。検知の取りこぼしの有無を、運用で確かめるための記録
    if [[ "$DETECT_RC" -eq 0 && "$PLAN_CHANGES" -gt 0 ]]; then
        log "WARNING" "検知は「変更なし」でしたが、実際は ${PLAN_CHANGES} 件の変更がありました（区分 C の種類の変更を含む）。先頭 10 件:"
        awk -F'\t' '$1=="A"||$1=="M"||$1=="D"{print "  " $1 " " $2}' "$PLAN_FILE" | head -10 | while IFS= read -r line; do log "WARNING" "$line"; done
    fi
    # 一覧の指紋の影の比較（実際の変更と、指紋の変化を突き合わせて、見逃しを記録する。情報のみ。失敗しても、同期は続ける）
    if [[ "$FP_MODE" != "off" && "$FP_RC" -ge 0 && -f "$FP_REPORT" ]]; then
        local cmp
        cmp=$("$NODE_BIN" "$METASYNC_JS" fpcompare --report "$FP_REPORT" --plan "$PLAN_FILE" \
            --fp-config "${SCRIPT_DIR}/../config/metasync-fingerprint.txt" --dirs-table "${SCRIPT_DIR}/../config/metadata-dirs.txt" 2>&1) \
            || log "WARNING" "指紋の影の比較に失敗しました（同期には影響しません）。"  # run 不使用: 出力を変数に受ける
        [[ -n "$cmp" ]] && _log_node_lines "$cmp"
    fi
    return $RET_OK
}

# 【SCAN】これから書く内容（計画の追加・変更）に、秘密情報の疑いがないか検査する（設計 16.7。反映の前・コミットの前。読み取りのみ）
#   取得結果（一時フォルダ）と、手元のファイルを比べて、今回新しく入る疑わしい文字列だけを調べる。作業ツリーは、まだ触らない
#   （止めても、戻すものがない）。値は、ログにも通知にも出さない（規則名とパスだけ）。許可の一覧: ./sf-tools/config/metasync-secret-allow.txt
#   on で疑いがあれば、Slack に通知して、終了コード 4 で止める。検査そのものが失敗したときも、on なら止める（検査していないものを
#   コミットしない）。shadow は、WARNING を出すだけで、止めない
SCAN_REPORT=""
phase_secret_scan() {
    [[ "$SCAN_MODE" == "off" ]] && return $RET_OK
    SCAN_REPORT="$WORK_DIR/scan.report.tsv"
    local allow="./sf-tools/config/metasync-secret-allow.txt" args out rc
    args=(scan --plan "$PLAN_FILE" --repo . --fetched "$WORK_DIR" --out-report "$SCAN_REPORT")
    [[ -f "$allow" ]] && args+=(--allow "$allow")
    # run 不使用: 戻り値（0 / 10 / 1）で分岐し、要約をログにも記録するため
    out=$("$NODE_BIN" "$METASYNC_JS" "${args[@]}" 2>&1)
    rc=$?
    _log_node_lines "$out"
    if [[ $rc -eq 0 ]]; then
        return $RET_OK
    fi
    if [[ $rc -ne 10 ]]; then
        if [[ "$SCAN_MODE" == "on" ]]; then
            # 検査していない内容はコミットしない。疑いで止めたときと同じく、Slack に通知して、終了コード 4 で止める
            #   （許可の一覧の書式の誤りなどで、以後の同期が、通知なしで止まり続けないように）
            log "ERROR" "秘密情報の検査に失敗しました（終了コード ${rc}）。検査していない内容はコミットしないため、何もコミット・push せずに止めます。"
            [[ "$DRY_RUN" -eq 1 ]] || notify_slack ":rotating_light: [metasync] 秘密情報の検査に失敗したため、同期を止めました: ${REPO_FULL:-不明}" \
                "理由: 検査そのものが失敗しました（許可の一覧 sf-tools/config/metasync-secret-allow.txt の書式の誤りなど）。コミット・push は行っていません。" \
                "確認: 実行のログを見て、原因を直してください。"
            exit $EXIT_SECRET
        fi
        log "WARNING" "秘密情報の検査に失敗しました（終了コード ${rc}）。shadow のため、止めません。"
        return $RET_OK
    fi
    if [[ "$SCAN_MODE" == "shadow" ]]; then
        log "WARNING" "秘密の疑いがあります（shadow のため、止めません）。誤検知なら ${allow} に「規則 パス [キー]」を足し（パスに空白があるときは * で書く）、本物なら組織側で取り除いてください（規則が scan-error のものは、検査できなかったファイル。上の行の案内を参照）。"
        return $RET_OK
    fi
    log "ERROR" "秘密の疑いがあるため、何もコミット・push せずに止めます。本物なら組織側で取り除き、誤検知なら ${allow} に「規則 パス [キー]」を足し（パスに空白があるときは * で書く）てください（値は表示しません。規則が scan-error のものは、検査できなかったファイル。上の行の案内を参照）。"
    if [[ "$DRY_RUN" -eq 0 ]]; then
        local lines=() r f c k
        while IFS=$'\t' read -r r f c k; do
            # 4 列目 = キー（項目名・ラベル名など。scan-error では、検査できなかった規則名）
            [[ -n "$r" ]] && lines+=("・${r}  ${f}${k:+（${k}）}")
            [[ ${#lines[@]} -ge 10 ]] && break
        done < "$SCAN_REPORT"
        notify_slack ":rotating_light: [metasync] 秘密の疑いのため、同期を止めました: ${REPO_FULL:-不明}" \
            "理由: 組織から取得した内容に、秘密情報の疑いがあります（コミット・push は行っていません）。" "${lines[@]}" \
            "確認: 本物なら組織側で取り除く。誤検知なら sf-tools/config/metasync-secret-allow.txt に「規則 パス [キー]」を足す（パスの空白は * で書く）。規則が scan-error のものは、検査できなかった規則（キー）があるファイルで、中身を確かめ、問題なければ「scan-error パス キー」を足す。"
    fi
    exit $EXIT_SECRET
}

# 【APPLY】計画を作業ツリーに反映する（手順 10）。保留の削除は、行わない
phase_apply_plan() {
    APPLIED=1   # 途中で失敗しても、終了時に HEAD へ戻せるように、先に立てる
    local out
    out=$("$NODE_BIN" "$METASYNC_JS" apply --plan "$PLAN_FILE" --repo . --fetched "$WORK_DIR" 2>&1) || { log "ERROR" "$out"; return $RET_NG; }  # run 不使用: 戻り値で判定する
    log "INFO" "$out"
    # 検知の状態を書く（検知が、変更あり・不明のとき。全件取得と反映が成功したあとにだけ書く。変更なしのときは、書かない）
    if [[ "$DETECT_MODE" != "off" && ( "$DETECT_RC" -eq 10 || "$DETECT_RC" -eq 11 ) && -f "$DETECT_STATE_NEW" ]]; then
        STATE_WRITTEN=1   # 途中で失敗しても、終了時に戻せるように、先に立てる
        run mkdir -p "${STATE_FILE%/*}" || return $RET_NG
        run cp "$DETECT_STATE_NEW" "$STATE_FILE" || return $RET_NG
        log "INFO" "検知の状態を更新しました: ${STATE_FILE}"
    fi
    # 指紋の状態を書く（指紋が、変更あり・不明のとき。取得と反映が成功したあとにだけ書く。変更なしのときは、書かない）
    if [[ "$FP_MODE" != "off" && ( "$FP_RC" -eq 10 || "$FP_RC" -eq 11 ) && -f "$FP_STATE_NEW" ]]; then
        FP_WRITTEN=1   # 途中で失敗しても、終了時に戻せるように、先に立てる
        run mkdir -p "${FP_STATE_FILE%/*}" || return $RET_NG
        run cp "$FP_STATE_NEW" "$FP_STATE_FILE" || return $RET_NG
        log "INFO" "指紋の状態を更新しました: ${FP_STATE_FILE}"
    fi
    return $RET_OK
}
