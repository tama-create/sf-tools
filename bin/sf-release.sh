#!/bin/bash
# ==============================================================================
# sf-release.sh - デプロイ/検証スクリプト
# ==============================================================================
# ターゲットファイル（deploy-target.txt / remove-target.txt）からマニフェスト（package.xml /
# destructiveChanges.xml）を生成し、sf project deploy start で Salesforce 組織へ検証（既定）またはリリースする。
#
# 【使い方】
#   sf-release.sh [オプション]
#
# 【オプション】
#   （指定なし）          : 検証モード（sf project deploy start --dry-run）で実行する。
#   --validate, --dry-run : 検証モードを明示する（指定なしと同じ）。
#   -r, --release         : 実際に組織へリリースする（--dry-run を付けない）。
#   -n, --no-open         : 組織のデプロイ状況の画面をブラウザで開かない（CI/CD 等）。
#   -f, --force           : sf project deploy start に --ignore-conflicts を付け、コンフリクト検知を無効にして上書きする。
#   -t, --target ALIAS    : 接続先組織のエイリアスを指定する。値がない、または値が「-」で始まる場合は中断する。
#                           --target=ALIAS の形式には対応しない（不明なオプションとして中断する）。
#   -j, --json            : このスクリプトが実行する sf コマンド（manifest 生成・org open・deploy start）に --json を付ける。
#   -v, --verbose         : コマンドの応答（出力）をコンソールにも表示する（既定はログファイルのみ）。
#   -h, --help            : このヘルプを表示して終了する。
#   上記以外のオプション・引数は、エラーで中断する。
#
# 【処理の流れ】
#   1. sf の終了コードを check_sf_cli --cache で確認する（【前提条件】参照）。
#   2. 接続先組織を決める。優先順位: -t の値 > 環境変数 SF_TARGET_ORG > sf org display の alias
#      （sf org display は既定で最大 3 回試行）。決まらなければ中断する。
#   3. GitHub Actions 外（GITHUB_ACTIONS が true 以外）で、接続先が予約名（prod / staging / develop / main）なら、
#      または、本番の組織（sf data query で組織の種類を読み取る）なら、検証モードでも中断する。種類を確認できないときも、
#      中断する（【補足】の「共有環境の保護」参照）。
#   4. GitHub Actions 外・--release 指定・SF_DEPLOY_CONFIRMED が 1 以外のとき、確認（Y/N/q）を表示する。
#      N / q なら中断する。-f も指定されていれば、確認の前に上書きの警告を表示する。
#   5. sf-tools/release/branch_name.txt からブランチ名を読み、sf-tools/release/<ブランチ名>/ を対象にする。
#   6. deploy-target.txt / remove-target.txt の存在を確認し、sf-check.sh で構文を検査する。エラーなら中断する。
#   7. 既存の package.xml / destructiveChanges.xml を削除してから、マニフェストを生成する（【補足】参照）。
#      両方のリストに対象が 1 件もなければ、何もせず終了コード 0 で終了する。
#   8. deploy-target.txt の [files] にある .cls のうち、ファイル中に「@isTest」（大文字小文字を区別しない）を
#      含むものをテストクラスとして検出し、--test-level RunSpecifiedTests と --tests <クラス名>（クラスごと）を付ける。
#      検出されなければ、--test-level を付けない。
#   9. -n がなければ、sf org open で「lightning/setup/DeployStatus/home」を開き、5 秒待つ。
#  10. sf project deploy start --target-org <組織> --manifest package.xml を実行する。
#      destructiveChanges.xml があれば --pre-destructive-changes で渡す（削除はデプロイより先に行われる）。
#      検証モードなら --dry-run を付ける。失敗すれば中断する。
#
# 【前提条件】
#   - force-* ディレクトリ（プロジェクトのルート）で実行すること。ログは ./sf-tools/logs/sf-release.log（毎回上書き）。
#   - Salesforce CLI（sf）は npm 版であること。起動時に check_sf_cli（sf --version の終了コード）で確認し、
#     0 以外なら、案内を表示して中断する。成功は 24 時間は確認を省略する（GitHub Actions 上・sf が未インストールの
#     場合は確認しない）。
#   - sf-tools/release/branch_name.txt と、sf-tools/release/<ブランチ名>/ の deploy-target.txt・remove-target.txt が
#     存在すること（いずれかがなければ中断する）。
#
# 【補足】
#   - マニフェストの生成: リストの行は、[files] セクション（既定）なら --source-dir <パス>、[members] セクションなら
#     --metadata <種別名:メンバー名> として扱う（# で始まる行と空行は無視）。[files] と [members] は、別々に
#     sf project generate manifest で生成し、1 つの XML に統合する（両方を同時に渡すと、sf CLI は、共通部分だけ
#     （重なりがなければ空）を返すため）。統合後にメンバーが 1 つもなければ、エラーで中断する（「変更なし」の
#     成功扱いで、見落とさないため）。
#   - deploy-target.txt と remove-target.txt の両方に対象がないとき（コメント・空行だけ）は、「デプロイ対象なし。正常終了します。」と表示して、
#     正常に終了する（CI で、リリースの定義だけを先に準備する運用を許すため）。
#   - deploy-target.txt が空で remove-target.txt にだけ対象があるときは、メンバーのない package.xml（version 60.0）を
#     作成し、削除だけを行う。
#   - 存在しない削除対象を許す指示（# @ignore-missing）: remove-target.txt に、`# @ignore-missing` で始まる
#     コメント行（行頭・# の後の空白は可）があるときだけ、sf project deploy start に --ignore-warnings を付ける。
#     削除対象が組織に存在しなくても、エラーにしない（「No ApexClass named: X found」を、警告として扱う）。
#     後始末（sf-init.sh --verify --cleanup）のように、どこまで消えているか分からない削除を、何度でも実行できる
#     ようにするための指示。--ignore-warnings はデプロイ全体に付くため、削除以外の警告も、エラーにならない。
#     指示がなければ、存在しない対象は、エラーになる（綴りの誤りなどを、見落とさないため。通常のリリース・削除には、
#     付けないこと）。
#   - 共有環境の保護: 接続先のエイリアスが予約名（prod / staging / develop / main）の組織（共有環境）には、
#     ローカルからは実行できない（dry-run を含む）。リリースは、GitHub にコミットし、レビューを通して、
#     GitHub Actions で行う。個人用の Sandbox / Developer Edition / Scratch Org は、ローカルから実行できる。
#     名前だけでは、別の名前を付けた本番組織を止められないため、GitHub Actions 外では、組織の種類も確認し（org_local_release_check。
#     sf data query で Organization を読み取る）、本番の組織、または種類を確認できない組織は、名前にかかわらず、実行できない。
#   - -h / --help は、1 番目の引数なら、他の処理の前にヘルプを表示して終了する。2 番目以降なら、手順 1 の後の
#     引数の解析で、そこに到達した時点で表示して終了する（それより前の引数がエラーなら、そのエラーで中断する）。
#   - sf-check.sh の出力（どの行が、なぜエラーか）は、run を通さずに呼ぶため、-v がなくても画面に出る（sf-release.log には残らない）。
#   - 終了コード: 成功（対象なしを含む）は 0。中断・失敗は 1。
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 共通ライブラリの必須設定
# ------------------------------------------------------------------------------
SCRIPT_NAME="${0##*/}"; readonly SCRIPT_NAME="${SCRIPT_NAME%.sh}"
readonly LOG_FILE="./sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"


# ------------------------------------------------------------------------------
# 2. 共通ライブラリの読み込み
# ------------------------------------------------------------------------------
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR/" == /* && "$SCRIPT_DIR/" != *//* && "$SCRIPT_DIR/" != */./* && "$SCRIPT_DIR/" != */../* ]] || SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="${SCRIPT_DIR}/../lib/common.sh"

if [[ ! -f "$COMMON_LIB" ]]; then
    echo "[FATAL ERROR] Library not found: $COMMON_LIB" >&2
    exit 1
fi
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}"
    exit 0
fi
source "$COMMON_LIB"
source "${SCRIPT_DIR}/../lib/org.sh"   # org_local_release_check（組織の種類の確認）

# ------------------------------------------------------------------------------
# 3. 初期チェック
# ------------------------------------------------------------------------------
log "HEADER" "リリース・検証処理を開始します (${SCRIPT_NAME}.sh)"

# sf が終了コードを正しく返すか確認する（npm 版が前提。異常なら中断する）。成功は 24 時間は確認を省略する
check_sf_cli --cache

# デプロイ対象から検出したテストクラス名（phase_generate_manifest → phase_release で共有）
RUN_TESTS=()

# ------------------------------------------------------------------------------
# 4. 実行時引数の解析
# ------------------------------------------------------------------------------
# 初期状態は「最も安全な設定（検証のみ、ブラウザ開く）」に固定
IS_VALIDATE_MODE=1
OPEN_BROWSER=1
IGNORE_CONFLICTS=0
TARGET_ORG=""

JSON_FLAG=()

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --help|-h) show_help ;;
        --validate|--dry-run) IS_VALIDATE_MODE=1 ;;
        --release|-r)         IS_VALIDATE_MODE=0 ;;
        --no-open|-n)         OPEN_BROWSER=0 ;;
        --force|-f)           IGNORE_CONFLICTS=1 ;;
        --target|-t)
            # 値（組織のエイリアス）が無い、または次のオプションを値として取り込む指定は、受け付けない
            [[ -n "${2:-}" && "${2:-}" != -* ]] || die "-t / --target の値（組織のエイリアス）がない、または - で始まっています。"
            TARGET_ORG="$2"; shift ;;
        --json|-j)            JSON_FLAG=("--json") ;;
        --verbose|-v)         : ;;  # SILENT_EXEC は common.sh が設定済み
        --*)
            die "不明なオプションです: $1"
            ;;
        *)
            die "不明な引数です: $1"
            ;;
    esac
    shift
done

# ------------------------------------------------------------------------------
# 5. 接続先組織 (TARGET_ORG) の動的判定
# ------------------------------------------------------------------------------
# 優先順位: 1. -t 引数 > 2. 環境変数 SF_TARGET_ORG > 3. ローカル接続情報（get_target_org が解決）
TARGET_ORG=$(get_target_org "$TARGET_ORG") || die "接続先の組織エイリアスを特定できません。"
log "INFO" "接続先組織: ${TARGET_ORG}"

# ------------------------------------------------------------------------------
# 5.1 保護組織へのローカル直接実行を禁止
# ------------------------------------------------------------------------------
# 共有環境（予約名: prod / staging / develop / main。is_reserved_org_alias）と、本番の組織（名前は問わない）は、GitHub Actions 専用。ローカルからは実行不可。
if [[ "${GITHUB_ACTIONS:-false}" != "true" ]]; then
    if is_reserved_org_alias "$TARGET_ORG"; then
        die "${TARGET_ORG} は共有環境（予約名）のため、ローカルから実行できません。"
    fi
    # 名前を付け替えた本番組織も止める（組織の種類を調べる。本番、または種類を確認できないときは、中断する）
    _org_rc=0
    org_local_release_check "$TARGET_ORG" || _org_rc=$?  # run 不使用: 戻り値で分岐する（run は、戻り値を変える）
    case "$_org_rc" in
        1) die "${TARGET_ORG} は本番組織のため、ローカルから実行できません。" ;;
        2) die "${TARGET_ORG} の組織の種類を確認できないため、ローカルから実行できません。" ;;
    esac
fi

# ------------------------------------------------------------------------------
# 5.2 ローカル実行時のリリース確認
# ------------------------------------------------------------------------------
# GITHUB_ACTIONS=true の場合、または validate モード、または sf-deploy.sh 経由（確認済み）はスキップ
if [[ "${GITHUB_ACTIONS:-false}" != "true" && "$IS_VALIDATE_MODE" -eq 0 && "${SF_DEPLOY_CONFIRMED:-0}" != "1" ]]; then
    if [[ "$IGNORE_CONFLICTS" -eq 1 ]]; then
        log "WARNING" "--force（--ignore-conflicts）が指定されています。コンフリクトは強制上書きされます。"
    fi
    ask_yn "リリースを実行します（実際に、組織へ反映されます）。続行しますか？" || die "中断しました。"
fi

# ------------------------------------------------------------------------------
# 6. パス定義
# ------------------------------------------------------------------------------
BRANCH_NAME_FILE="sf-tools/release/branch_name.txt"
if [[ -f "$BRANCH_NAME_FILE" ]]; then
    BRANCH_NAME=$(tr -d '\r\n' < "$BRANCH_NAME_FILE")
else
    die "ブランチ情報ファイルが見つかりません (${BRANCH_NAME_FILE})。"
fi

readonly RELEASE_BASE="sf-tools/release"
readonly RELEASE_DIR="${RELEASE_BASE}/${BRANCH_NAME}"
readonly DEPLOY_LIST="${RELEASE_DIR}/deploy-target.txt"
readonly REMOVE_LIST="${RELEASE_DIR}/remove-target.txt"
readonly DEPLOY_XML="${RELEASE_DIR}/package.xml"
readonly REMOVE_XML="${RELEASE_DIR}/destructiveChanges.xml"

log "INFO" "リリース処理開始 (Target: ${TARGET_ORG}, Branch: ${BRANCH_NAME})"

# ------------------------------------------------------------------------------
# 7. フェーズ定義
# ------------------------------------------------------------------------------

# 【CHECK】対象リストの確認（リリース用ディレクトリを mkdir -p し、deploy-target.txt / remove-target.txt が
#   なければ中断する（雛形は作らない）。続けて sf-check.sh で構文を検査する）
phase_check_target() {
    run mkdir -p "$RELEASE_DIR"

    for target in "$DEPLOY_LIST" "$REMOVE_LIST"; do
        [[ ! -f "$target" ]] && die "ターゲットファイルが見つかりません: ${target}"
    done

    # 構文チェック
    # run 不使用: sf-check.sh の出力（どの行が、なぜエラーか）を、-v がなくても画面に出すため
    bash "${SCRIPT_DIR}/sf-check.sh" "$DEPLOY_LIST" "$REMOVE_LIST" \
        || die "ターゲットファイルの検証（sf-check.sh）でエラーがありました。"
    return $RET_OK
}

# generate_manifest - マニフェスト（package.xml / destructiveChanges.xml）を生成する
#   引数: 出力ファイル名 引数...（--source-dir パス / --metadata 種別:名前 の組）。出力先は ${RELEASE_DIR}
#   sf project generate manifest は、--source-dir と --metadata を同時に渡すと、両方の共通部分だけを返す
#   （重なりがなければ空になり、しかも、成功として終わる）。そのため、別々に生成して、merge_package_xml で統合する。
#   統合したものに、メンバーが 1 つもなければ、エラーにする（NothingToDeploy の成功扱いで、検証・リリースを、見落とさないため）
generate_manifest() {
    local name="$1" base src=() meta=() parts=() i=0 args=() part
    shift
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
        part="${RELEASE_DIR}/${base}.files.xml"
        run sf project generate manifest "${src[@]}" --output-dir "$RELEASE_DIR" --name "${base}.files.xml" "${JSON_FLAG[@]}" || return 1
        parts+=("$part")
    fi
    if [[ ${#meta[@]} -gt 0 ]]; then
        part="${RELEASE_DIR}/${base}.members.xml"
        run sf project generate manifest "${meta[@]}" --output-dir "$RELEASE_DIR" --name "${base}.members.xml" "${JSON_FLAG[@]}" || return 1
        parts+=("$part")
    fi
    if [[ ${#parts[@]} -eq 0 ]]; then
        log "ERROR" "${name}: 生成する対象がありません。"
        return 1
    fi
    if ! merge_package_xml "${RELEASE_DIR}/${name}" "${parts[@]}"; then  # 条件チェック（失敗したら、統合前の一時ファイルを消して、中断する）
        rm -f "${parts[@]}"  # run 不使用: 統合前の一時ファイルの除去
        log "ERROR" "マニフェストの統合（merge_package_xml）に失敗しました: ${name}"
        return 1
    fi
    rm -f "${parts[@]}"  # run 不使用: 統合前の一時ファイルの除去
    if ! grep -q '<members>' "${RELEASE_DIR}/${name}" 2>/dev/null; then  # 条件チェック
        log "ERROR" "${name} に、メンバーが 1 つも含まれていません（ターゲットファイルの記述が、マニフェストに反映されていません）。"
        log "ERROR" "  ${DEPLOY_LIST} / ${REMOVE_LIST} の、パス・種別名:メンバー名を確認してください。"
        return 1
    fi
    log "SUCCESS" "${name} を生成しました（ファイル指定 $(( ${#src[@]} / 2 )) 件 / メンバー指定 $(( ${#meta[@]} / 2 )) 件）"
    return 0
}

# 【MANIFEST】テキストリストからマニフェストファイル(XML)を自動生成
phase_generate_manifest() {
    run rm -f "$DEPLOY_XML" "$REMOVE_XML"
    local deploy_args=()
    local remove_args=()

    # 補助関数: リストファイルを走査し、コメント・空行を除外して sf コマンド用引数を組み立てる
    # セクション:
    #   [files]   → --source-dir <パス>    ファイルパス指定（デフォルト）
    #   [members] → --metadata <種別:名前>  メンバー名指定
    #   結果は、配列 _pl_out に入れる（nameref は Bash 4.3 以降のため使わない。macOS 標準の Bash 3.2 で動かす）
    local _pl_out=()
    process_list() {
        local list=$1
        local section="files"
        _pl_out=()
        while IFS= read -r line || [[ -n "$line" ]]; do
            local clean_line
            # サブプロセス不使用: \r 除去 → 前後空白トリム（Windows/Git Bash 高速化）
            clean_line="${line//$'\r'/}"
            clean_line="${clean_line#"${clean_line%%[^[:space:]]*}"}"
            clean_line="${clean_line%"${clean_line##*[^[:space:]]}"}"

            # セクション区切りの検出
            if [[ "$clean_line" == "[files]" ]]; then
                section="files"; continue
            elif [[ "$clean_line" == "[members]" ]]; then
                section="members"; continue
            fi

            # コメント・空行をスキップ
            [[ -z "$clean_line" || "$clean_line" == \#* ]] && continue

            # セクションに応じた引数を追加
            if [[ "$section" == "files" ]]; then
                _pl_out+=("--source-dir" "$clean_line")
            else
                _pl_out+=("--metadata" "$clean_line")
            fi
        done < "$list"
        # TortoiseGit でのサイレントエラー対策:
        # while ループ最終行が空行で false になっても関数として成功を返す
        return 0
    }

    process_list "$DEPLOY_LIST" || return $RET_NG
    deploy_args=("${_pl_out[@]}")
    process_list "$REMOVE_LIST" || return $RET_NG
    remove_args=("${_pl_out[@]}")

    # @isTest アノテーションを持つ .cls ファイルを検出して RUN_TESTS に登録
    local i=0
    while [[ $i -lt ${#deploy_args[@]} ]]; do
        if [[ "${deploy_args[$i]}" == "--source-dir" ]]; then
            local filepath="${deploy_args[$((i+1))]}"
            if [[ "$filepath" == *.cls ]] && grep -qi "@isTest" "$filepath" 2>/dev/null; then
                local classname
                classname=$(basename "$filepath" .cls)  # VAR=$(cmd) のため run 不使用
                RUN_TESTS+=("$classname")
                log "INFO" "  テストクラス検出: ${classname}"
            fi
        fi
        ((i++))
    done
    if [[ ${#RUN_TESTS[@]} -gt 0 ]]; then
        log "INFO" "テストクラス合計: ${#RUN_TESTS[@]}件 → --tests に自動設定します"
    fi

    # デプロイ対象がゼロの場合は sf CLI に渡す前に早期終了
    if [[ ${#deploy_args[@]} -eq 0 && ${#remove_args[@]} -eq 0 ]]; then
        log "WARNING" "デプロイ対象がありません。${DEPLOY_LIST} または ${REMOVE_LIST} にパスを記入してください。"
        return $RET_NO_CHANGE
    fi

    # 追加/変更用の package.xml 生成
    if [[ ${#deploy_args[@]} -gt 0 ]]; then
        local files_count members_count
        files_count=$(printf '%s\n' "${deploy_args[@]}" | grep -c "^--source-dir$" || true)
        members_count=$(printf '%s\n' "${deploy_args[@]}" | grep -c "^--metadata$" || true)
        log "INFO" "デプロイ対象を検出 (ファイル: ${files_count}件 / メンバー: ${members_count}件)"
        generate_manifest "package.xml" "${deploy_args[@]}" || return $RET_NG
    else
        # 対象ゼロでも CLI エラーを防ぐために最小構成の XML を作成
        printf '<?xml version="1.0" encoding="UTF-8"?><Package xmlns="http://soap.sforce.com/2006/04/metadata"><version>60.0</version></Package>\n' \
            | run tee "$DEPLOY_XML"
    fi

    # 削除用の destructiveChanges.xml 生成（対象がある場合のみ）
    if [[ ${#remove_args[@]} -gt 0 ]]; then
        generate_manifest "destructiveChanges.xml" "${remove_args[@]}" || return $RET_NG
    fi

    return $RET_OK
}

# 【RELEASE】Salesforce へのデプロイ/検証の実行
phase_release() {
    local deploy_cmd=("sf" "project" "deploy" "start" "--target-org" "$TARGET_ORG" "--manifest" "$DEPLOY_XML" "${JSON_FLAG[@]}")
    [[ -f "$REMOVE_XML" ]]          && deploy_cmd+=("--pre-destructive-changes" "$REMOVE_XML")
    [[ "$IGNORE_CONFLICTS" -eq 1 ]] && deploy_cmd+=("--ignore-conflicts")
    # remove-target.txt に「# @ignore-missing」があれば、存在しない削除対象を、エラーにしない
    if [[ -f "$REMOVE_LIST" ]] && grep -qE '^[[:space:]]*#[[:space:]]*@ignore-missing' "$REMOVE_LIST"; then  # 条件チェック
        deploy_cmd+=("--ignore-warnings")
        log "INFO" "remove-target.txt に @ignore-missing があるため、存在しない削除対象は、エラーにしません（--ignore-warnings）"
    fi

    # テストクラスが検出されていれば RunSpecifiedTests を指定
    if [[ ${#RUN_TESTS[@]} -gt 0 ]]; then
        # sf project deploy start のフラグは --tests（--run-tests は存在しない）。複数のクラスは、--tests を繰り返して渡す
        local t tests_args=""
        deploy_cmd+=("--test-level" "RunSpecifiedTests")
        for t in "${RUN_TESTS[@]}"; do
            deploy_cmd+=("--tests" "$t")
            tests_args+=" --tests ${t}"
        done
        log "INFO" "テスト実行: --test-level RunSpecifiedTests${tests_args}"
    fi

    if [[ "$IS_VALIDATE_MODE" -eq 1 ]]; then
        log "INFO" "検証モード (Dry-Run) を開始します"
        deploy_cmd+=("--dry-run")
    else
        log "INFO" "組織へのリリースを実行します！"
    fi

    # -n / --no-open がなければ、ブラウザで進捗画面を表示する（対話かどうかは判定しない）
    if [[ "$OPEN_BROWSER" -eq 1 ]]; then
        log "INFO" "リリース状況画面をブラウザで表示します..."
        run sf org open --target-org "$TARGET_ORG" --path "lightning/setup/DeployStatus/home" "${JSON_FLAG[@]}"
        log "INFO" "ブラウザ描画待機 (5秒)"
        sleep 5
    fi

    run "${deploy_cmd[@]}"
}

# ------------------------------------------------------------------------------
# 8. メインフロー
# ------------------------------------------------------------------------------
phase_check_target      || die "対象リストの準備に失敗しました。"
log "SUCCESS" "対象リストの確認完了"

phase_generate_manifest
manifest_ret=$?
[[ $manifest_ret -eq $RET_NG ]] && die "マニフェスト生成に失敗しました。"
if [[ $manifest_ret -eq $RET_NO_CHANGE ]]; then
    log "SUCCESS" "デプロイ対象なし。正常終了します。"
    exit 0
fi
log "SUCCESS" "マニフェスト生成完了"

phase_release
res=$?

if [[ $res -eq $RET_OK ]]; then
    log "SUCCESS" "デプロイ/検証が完了しました。"
elif [[ $res -eq $RET_NO_CHANGE ]]; then
    log "SUCCESS" "変更がないため処理をスキップしました。"
else
    die "Salesforce へのデプロイ/検証の実行に失敗しました。"
fi

exit $RET_OK
