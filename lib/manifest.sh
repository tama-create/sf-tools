#!/bin/bash
# ==============================================================================
# manifest.sh - ターゲットファイル（deploy-target.txt / remove-target.txt）から、マニフェストを作る
# ==============================================================================
# sf-release.sh（組織へ出す）と sf-promote-check.sh（一方通行の確認の R2。doc/one-way-promotion-design.md 3.2）が共有する。
# 使うスクリプトが、lib/common.sh のあとに、個別に source する（common.sh からは source しない）。
# common.sh の log / run / RET_* と、project.sh の merge_package_xml を使う。
#
# 【提供する関数】
#   manifest_parse_list FILE        ... リストを読み、sf の引数（--source-dir パス / --metadata 種別:名前）を、配列 MANIFEST_ARGS に入れる
#   manifest_generate OUT NAME ARG... ... 引数から OUT/NAME（package.xml 形式）を作る（[files] と [members] は別々に作って統合する）
#   manifest_build RELDIR OUT       ... RELDIR の deploy-target.txt・remove-target.txt から、OUT に package.xml・destructiveChanges.xml を作る
#
# 【決まり】（sf-release.sh から移したもの。動きは変えない）
#   - リストの行: [files] セクション（既定）は --source-dir、[members] セクションは --metadata。# で始まる行・空行は無視。
#     行末の CR と前後の空白は除く
#   - [files] と [members] は、別々に sf project generate manifest で作り、merge_package_xml で 1 つにする
#     （両方を同時に渡すと、sf は共通部分だけ（重なりがなければ空）を返し、しかも成功として終わるため）
#   - 作ったものにメンバーが 1 つもなければ、失敗にする（NothingToDeploy の成功扱いで、見落とさないため）
#   - deploy-target.txt が空で remove-target.txt にだけ対象があるときは、メンバーのない package.xml（version 60.0）を作る
#   - 反映と削除の重なりの確認・組織にない削除の対象を外す処理・# @ignore-missing は、組織に出すときの処理なので、ここではしない
#     （sf-release.sh に残す。R2 は、組織に問い合わせずに、宣言した対象どうしを比べる）
#   - sf のコマンドには、呼び出し側の配列 JSON_FLAG があれば、それを付ける（sf-release.sh の -j）
# ==============================================================================

# manifest_parse_list - リストファイルを読み、sf の引数を、配列 MANIFEST_ARGS に入れる
#   引数: FILE。戻り値: 0（ファイルがなければ 1）。結果は配列 MANIFEST_ARGS（nameref は Bash 4.3 以降のため使わない）
MANIFEST_ARGS=()
manifest_parse_list() {
    local list="$1" section="files" line clean_line
    MANIFEST_ARGS=()
    [[ -f "$list" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        # サブプロセス不使用: \r 除去 → 前後空白トリム（Windows/Git Bash 高速化）
        clean_line="${line//$'\r'/}"
        clean_line="${clean_line#"${clean_line%%[^[:space:]]*}"}"
        clean_line="${clean_line%"${clean_line##*[^[:space:]]}"}"
        if [[ "$clean_line" == "[files]" ]]; then
            section="files"; continue
        elif [[ "$clean_line" == "[members]" ]]; then
            section="members"; continue
        fi
        [[ -z "$clean_line" || "$clean_line" == \#* ]] && continue
        if [[ "$section" == "files" ]]; then
            MANIFEST_ARGS+=("--source-dir" "$clean_line")
        else
            MANIFEST_ARGS+=("--metadata" "$clean_line")
        fi
    done < "$list"
    # TortoiseGit でのサイレントエラー対策: while ループ最終行が空行で false になっても関数として成功を返す
    return 0
}

# manifest_generate - マニフェスト（package.xml 形式）を作る
#   引数: 出力フォルダ 出力ファイル名 引数...（--source-dir パス / --metadata 種別:名前 の組）
#   戻り値: 0 = 作れた / 1 = 作れない（sf の失敗・統合の失敗・メンバーが 1 つもない）
manifest_generate() {
    local out="$1" name="$2" base src=() meta=() parts=() i=0 args=() part
    shift 2
    args=("$@")
    base="${name%.xml}"
    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            --source-dir) src+=("--source-dir" "${args[$((i+1))]}") ;;
            --metadata)   meta+=("--metadata" "${args[$((i+1))]}") ;;
        esac
        i=$((i + 2))
    done
    if [[ ${#src[@]} -gt 0 ]]; then
        part="${out}/${base}.files.xml"
        run sf project generate manifest "${src[@]}" --output-dir "$out" --name "${base}.files.xml" ${JSON_FLAG[@]+"${JSON_FLAG[@]}"} || return 1
        parts+=("$part")
    fi
    if [[ ${#meta[@]} -gt 0 ]]; then
        part="${out}/${base}.members.xml"
        run sf project generate manifest "${meta[@]}" --output-dir "$out" --name "${base}.members.xml" ${JSON_FLAG[@]+"${JSON_FLAG[@]}"} || return 1
        parts+=("$part")
    fi
    if [[ ${#parts[@]} -eq 0 ]]; then
        log "ERROR" "${name}: 生成する対象がありません。"
        return 1
    fi
    if ! merge_package_xml "${out}/${name}" "${parts[@]}"; then  # 条件チェック（失敗したら、統合前の一時ファイルを消して、中断する）
        rm -f "${parts[@]}"  # run 不使用: 統合前の一時ファイルの除去
        log "ERROR" "マニフェストの統合（merge_package_xml）に失敗しました: ${name}"
        return 1
    fi
    rm -f "${parts[@]}"  # run 不使用: 統合前の一時ファイルの除去
    if ! grep -q '<members>' "${out}/${name}" 2>/dev/null; then  # 条件チェック
        log "ERROR" "${name} に、メンバーが 1 つも含まれていません（ターゲットファイルの記述が、マニフェストに反映されていません）。"
        log "ERROR" "  ${_MB_DEPLOY_LIST:-deploy-target.txt} / ${_MB_REMOVE_LIST:-remove-target.txt} の、パス・種別名:メンバー名を確認してください。"
        return 1
    fi
    log "SUCCESS" "${name} を生成しました（ファイル指定 $(( ${#src[@]} / 2 )) 件 / メンバー指定 $(( ${#meta[@]} / 2 )) 件）"
    return 0
}

# manifest_build - リリースのフォルダのターゲットファイルから、マニフェストを作る
#   引数: リリースのフォルダ（deploy-target.txt・remove-target.txt がある） 出力のフォルダ
#   動作: 出力のフォルダの package.xml・destructiveChanges.xml を消してから作る。カレントディレクトリは、プロジェクトのルート
#         （sf project generate manifest が sfdx-project.json を読むため）。結果の引数は、配列 MANIFEST_DEPLOY_ARGS・MANIFEST_REMOVE_ARGS にも残す
#   戻り値: 0 = 作れた / RET_NO_CHANGE = 両方のリストに対象がない（何も作らない）/ 1 = 作れない（リストがない・sf の失敗など）
MANIFEST_DEPLOY_ARGS=()
MANIFEST_REMOVE_ARGS=()
manifest_build() {
    local reldir="$1" out="$2" files_count members_count
    _MB_DEPLOY_LIST="${reldir}/deploy-target.txt"
    _MB_REMOVE_LIST="${reldir}/remove-target.txt"
    MANIFEST_DEPLOY_ARGS=(); MANIFEST_REMOVE_ARGS=()
    run rm -f "${out}/package.xml" "${out}/destructiveChanges.xml"
    manifest_parse_list "$_MB_DEPLOY_LIST" || { log "ERROR" "ターゲットファイルが見つかりません: ${_MB_DEPLOY_LIST}"; return 1; }
    MANIFEST_DEPLOY_ARGS=(${MANIFEST_ARGS[@]+"${MANIFEST_ARGS[@]}"})
    manifest_parse_list "$_MB_REMOVE_LIST" || { log "ERROR" "ターゲットファイルが見つかりません: ${_MB_REMOVE_LIST}"; return 1; }
    MANIFEST_REMOVE_ARGS=(${MANIFEST_ARGS[@]+"${MANIFEST_ARGS[@]}"})

    if [[ ${#MANIFEST_DEPLOY_ARGS[@]} -eq 0 && ${#MANIFEST_REMOVE_ARGS[@]} -eq 0 ]]; then
        return $RET_NO_CHANGE
    fi
    if [[ ${#MANIFEST_DEPLOY_ARGS[@]} -gt 0 ]]; then
        files_count=$(printf '%s\n' "${MANIFEST_DEPLOY_ARGS[@]}" | grep -c "^--source-dir$" || true)
        members_count=$(printf '%s\n' "${MANIFEST_DEPLOY_ARGS[@]}" | grep -c "^--metadata$" || true)
        log "INFO" "デプロイ対象を検出 (ファイル: ${files_count}件 / メンバー: ${members_count}件)"
        manifest_generate "$out" "package.xml" "${MANIFEST_DEPLOY_ARGS[@]}" || return 1
    else
        # 対象ゼロでも CLI エラーを防ぐために最小構成の XML を作成
        printf '<?xml version="1.0" encoding="UTF-8"?><Package xmlns="http://soap.sforce.com/2006/04/metadata"><version>60.0</version></Package>\n' \
            | run tee "${out}/package.xml"
    fi
    if [[ ${#MANIFEST_REMOVE_ARGS[@]} -gt 0 ]]; then
        manifest_generate "$out" "destructiveChanges.xml" "${MANIFEST_REMOVE_ARGS[@]}" || return 1
    fi
    return 0
}
