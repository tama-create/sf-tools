#!/bin/bash
# ==============================================================================
# phases/metasync/retrieve.sh - sf-metasync.sh の部品: 変更の検知・一覧の指紋・メタデータの取得・追加の取得・直近のコミット（6 章の DETECT〜RECENT）
# ==============================================================================
# bin/sf-metasync.sh が source する（単独では動かさない）。変数・関数は、sf-metasync.sh の 1〜5 章 と、先に source した部品が用意する。
# 2026-11-28 に、sf-metasync.sh の 6 章（フェーズ定義） を、部品に分けた（中身は変えずに移した）。
# ==============================================================================
# shellcheck disable=SC2154  # 変数は、source する bin/sf-metasync.sh が用意する（この部品だけでは、代入が見えない）

# 【DETECT】組織に変更があるかを、全件取得の前に調べる（手順 5。SF_METASYNC_DETECT が off 以外のとき）
#   結果は DETECT_RC に入る: 0 = 変更なし ／ 10 = 変更あり ／ 11 = 不明 ／ -1 = 検知しなかった（off）。0 以外は、すべて全件取得に進む。
#   検知の失敗は、取得を止めない（検知は、取得を省くための手がかりで、失敗が取りこぼしにならないように、全件取得へ倒す）
DETECT_RC=-1
DETECT_STATE_NEW=""
phase_detect_changes() {
    [[ "$DETECT_MODE" == "off" ]] && return $RET_OK
    local table="${SCRIPT_DIR}/../config/metasync-detect.txt" out
    if [[ ! -f "$table" ]]; then
        log "WARNING" "検知の区分の表が見つかりません（${table}）。検知は行わず、全件取得します。"
        return $RET_OK
    fi
    DETECT_STATE_NEW="$WORK_DIR/state.new.json"
    log "INFO" "変更の検知を行います（SF_METASYNC_DETECT=${DETECT_MODE}。読み取りのみ）..."
    # run 不使用: 戻り値（0 / 10 / 11）で分岐し、要約をログにも記録するため
    out=$("$NODE_BIN" "$METASYNC_JS" detect --org "$TARGET_ORG" --types-file "$METADATA_CONFIG" --table "$table" \
        --state "$STATE_FILE" --out-state "$DETECT_STATE_NEW" 2>&1)
    DETECT_RC=$?
    _log_node_lines "$out"
    if [[ $DETECT_RC -ne 0 && $DETECT_RC -ne 10 ]]; then
        [[ $DETECT_RC -eq 11 ]] || log "WARNING" "検知が異常終了しました（終了コード ${DETECT_RC}）。不明として扱い、全件取得します。"
        DETECT_RC=11
    fi
    return $RET_OK
}

# 【FINGERPRINT】一覧の指紋を作り、前回と比べる（手順 5。SF_METASYNC_FINGERPRINT が shadow・on のとき。読み取りのみ）
#   結果は FP_RC に入る: 0 = 変更なし ／ 10 = 変更あり ／ 11 = 不明 ／ -1 = 行わなかった（off・表がない）。
#   取得を省くかは、呼び出し側（手順 5 の判定）が決める（on で 0 のときだけ省く。shadow は、取得を省かない影の比較）。
#   失敗は、取得を止めない（WARNING を出して、不明として全件取得に進む）
FP_RC=-1
FP_STATE_NEW=""
FP_REPORT=""
phase_fingerprint() {
    [[ "$FP_MODE" == "off" ]] && return $RET_OK
    local table="${SCRIPT_DIR}/../config/metasync-fingerprint.txt" out
    if [[ ! -f "$table" ]]; then
        log "WARNING" "指紋の種類の表が見つかりません（${table}）。指紋は作りません。"
        return $RET_OK
    fi
    FP_STATE_NEW="$WORK_DIR/fp.new.json"
    FP_REPORT="$WORK_DIR/fp.report.json"
    log "INFO" "一覧の指紋を作ります（SF_METASYNC_FINGERPRINT=${FP_MODE}。読み取りのみ）..."
    # 取得の範囲（metadata.txt の種類と、追加の取得の表。off のときは渡さない）も渡す。範囲が前回と変わった回は、指紋を不明（11）にする
    #   （組織が同じでも、取得の範囲の変更でファイルが増減するため。影の比較で、見逃しに数えない）
    local scope=(--types-file "$METADATA_CONFIG")
    [[ "$EXTRA_MODE" != "off" && -f "$EXTRA_TABLE" ]] && scope+=(--extra-config "$EXTRA_TABLE")
    # run 不使用: 戻り値（0 / 10 / 11）で分岐し、要約をログにも記録するため
    out=$("$NODE_BIN" "$METASYNC_JS" fingerprint --org "$TARGET_ORG" --fp-config "$table" --repo . "${scope[@]}" \
        --state "$FP_STATE_FILE" --out-state "$FP_STATE_NEW" --out-report "$FP_REPORT" 2>&1)
    FP_RC=$?
    _log_node_lines "$out"
    if [[ $FP_RC -ne 0 && $FP_RC -ne 10 ]]; then
        [[ $FP_RC -eq 11 ]] || log "WARNING" "指紋の作成が異常終了しました（終了コード ${FP_RC}）。不明として扱います（取得は、省かずに行います）。"
        FP_RC=11
    fi
    return $RET_OK
}

# 【RETRIEVE】組織からメタデータを、一時プロジェクトに取得する（手順 6）
#   run 不使用: 応答（JSON）を判定に使うため、ファイルへ受ける（run は、出力をログに記録し、戻り値も変える。JSON は大きい）
phase_retrieve_metadata() {
    local cmd=(sf project retrieve start --target-org "$TARGET_ORG" --ignore-conflicts --json)
    local type attempt rc
    for type in "${METADATA_TYPES[@]}"; do
        cmd+=(--metadata "$type")
    done
    for attempt in 1 2; do
        log "INFO" "組織からメタデータを取得します（一時プロジェクトへ。種類 ${#METADATA_TYPES[@]} 件。試行 ${attempt}/2）..."
        ( cd "$WORK_DIR" && "${cmd[@]}" ) > "$RETRIEVE_JSON" 2> "$RETRIEVE_ERR"
        rc=$?
        if [[ "$JSON_ECHO" -eq 1 ]]; then
            log "INFO" "取得の応答（先頭 2000 バイト）: $(_mask_secrets "$(head -c 2000 "$RETRIEVE_JSON")")"
        fi
        [[ $rc -eq 0 ]] && return $RET_OK
        log "WARNING" "取得が失敗しました（終了コード ${rc}）: $(_mask_secrets "$(head -c 600 "$RETRIEVE_ERR"; head -c 600 "$RETRIEVE_JSON")" | tr '\n' ' ')"
        # 一時的なエラー（組織側の処理・接続の切断）なら、待って 1 回だけやり直す（読み取りのみのため、やり直しても安全）
        if [[ $attempt -eq 1 ]] && grep -qE 'MetadataTransferError|UNKNOWN_EXCEPTION|ERROR_HTTP_404|ECONNRESET|ETIMEDOUT|socket hang up|fetch failed|503|Service Unavailable' "$RETRIEVE_JSON" "$RETRIEVE_ERR" 2>/dev/null; then
            log "WARNING" "一時的なエラーの可能性があるため、${SF_METASYNC_RETRY_WAIT:-60} 秒待って 1 回だけやり直します。"
            sleep "${SF_METASYNC_RETRY_WAIT:-60}"  # run 不使用: 待機
            continue
        fi
        break
    done
    return $RET_NG
}

# 【RETRIEVE-EXTRA】追加の取得（設計 16 章の P2。SF_METASYNC_EXTRA が on のとき。手順 6 のあと）
#   現行の取得で取れていないもの（フォルダ型・StandardValueSet・標準オブジェクト上の部品）の名前を、組織の一覧から集めて（node lib/metasync.js
#   manifest）、package.xml で取る（同じ一時プロジェクトへ）。結果は EXTRA_STATE に入る: ok = 取れた（取る部品がない場合を含む）／ failed = 失敗。
#   失敗しても、同期は止めない: plan が、その種類のフォルダと標準オブジェクトの部品の削除を、すべて保留する（取れなかったものを、削除と取り違えない）
#   run 不使用: 応答（JSON）を判定に使うため、ファイルへ受ける（phase_retrieve_metadata と同じ）
EXTRA_STATE="off"
EXTRA_JSON=""
EXTRA_TABLE="${SCRIPT_DIR}/../config/metasync-extra.txt"
phase_retrieve_extra() {
    [[ "$EXTRA_MODE" == "off" ]] && return $RET_OK
    EXTRA_STATE="failed"
    local manifest="$WORK_DIR/extra.package.xml" err="$WORK_DIR/extra.retrieve.err" out rc attempt
    EXTRA_JSON="$WORK_DIR/extra.retrieve.json"
    if [[ ! -f "$EXTRA_TABLE" ]]; then
        log "WARNING" "追加の取得の表が見つかりません（${EXTRA_TABLE}）。追加の取得は行いません（その種類の削除は保留します）。"
        return $RET_OK
    fi
    log "INFO" "追加の取得: 名前を集めます（SF_METASYNC_EXTRA=${EXTRA_MODE}。読み取りのみ）..."
    out=$("$NODE_BIN" "$METASYNC_JS" manifest --org "$TARGET_ORG" --extra-config "$EXTRA_TABLE" --repo . --out "$manifest" 2>&1)
    rc=$?
    _log_node_lines "$out"
    if [[ $rc -eq 12 ]]; then
        EXTRA_STATE="ok"
        log "INFO" "追加の取得: 取る部品がありません。"
        return $RET_OK
    fi
    if [[ $rc -ne 0 ]]; then
        log "WARNING" "追加の取得: 名前を集められませんでした。今回は取りません（その種類と標準オブジェクトの部品の削除は保留します）。"
        return $RET_OK
    fi
    for attempt in 1 2; do
        log "INFO" "追加の取得: 組織から取得します（package.xml。試行 ${attempt}/2）..."
        ( cd "$WORK_DIR" && sf project retrieve start --target-org "$TARGET_ORG" --ignore-conflicts --json --manifest "$manifest" ) > "$EXTRA_JSON" 2> "$err"
        rc=$?
        if [[ $rc -eq 0 ]]; then
            EXTRA_STATE="ok"
            log "SUCCESS" "追加の取得: 完了"
            return $RET_OK
        fi
        log "WARNING" "追加の取得が失敗しました（終了コード ${rc}）: $(_mask_secrets "$(head -c 600 "$err"; head -c 600 "$EXTRA_JSON")" | tr '\n' ' ')"
        if [[ $attempt -eq 1 ]] && grep -qE 'MetadataTransferError|UNKNOWN_EXCEPTION|ERROR_HTTP_404|ECONNRESET|ETIMEDOUT|socket hang up|fetch failed|503|Service Unavailable' "$EXTRA_JSON" "$err" 2>/dev/null; then
            log "WARNING" "一時的なエラーの可能性があるため、${SF_METASYNC_RETRY_WAIT:-60} 秒待って 1 回だけやり直します。"
            sleep "${SF_METASYNC_RETRY_WAIT:-60}"  # run 不使用: 待機
            continue
        fi
        break
    done
    log "WARNING" "追加の取得は行えませんでした。その種類と標準オブジェクトの部品の削除は保留します。"
    return $RET_OK
}

# 【RECENT】直近 24 時間に、同期以外のコミット（PR のマージなど）で変わったファイルの一覧を作る（手順 7。S5 用）
#   組織にまだリリースされていない（リリース中・失敗した）部品は、組織にないため、鏡像では削除の対象になってしまう。それを保留にする
#   run 不使用: 出力をファイルへ受けるため。失敗しても、空の一覧にして続ける（S5 が働かないだけ）
phase_recent_files() {
    git log --first-parent -m --since="24 hours ago" --invert-grep --grep='^定期更新: Salesforce変更の自動反映' \
        --name-only --format= HEAD -- "$PKG_PATH" > "$RECENT_FILES" 2>/dev/null || : > "$RECENT_FILES"
    return $RET_OK
}
