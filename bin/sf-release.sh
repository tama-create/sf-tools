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
#      package.xml と destructiveChanges.xml の両方にある「種類:メンバー」があれば、それを表示して中断する
#      （削除のあとの反映で、作り直されるため。【補足】の「反映と削除の重なり」参照）。
#      続けて、destructiveChanges.xml の対象のうち、組織にないもの（すでに消えたもの）を、確かめられたものだけ外す
#      （種類ごとに sf org list metadata を 1 回。外したものは WARNING で表示し、最後にもう一度表示する。【補足】の
#      「組織にない削除の対象」参照）。すべて外れたら --pre-destructive-changes を付けず、反映するものもなければ、
#      何もせず終了コード 0 で終了する。remove-target.txt に # @ignore-missing があれば、この確認をしない。
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
#   - 反映と削除の重なり: --pre-destructive-changes は、削除を反映より先に行う。両方に同じものがあると、消したあとに
#     作り直し、項目なら、項目は残って中のデータだけが消える（Salesforce はエラーにしない）。deploy-target.txt に
#     オブジェクトの本体（*.object-meta.xml）やフォルダを書くと、sf project generate manifest が配下の項目などを全部入れるため、
#     remove-target.txt に書いた項目と重なる（2026-11-26 に force-test-win で判明。sf-check.sh も dry-run も通った）。
#     マニフェストを作った直後に lib/project.sh の manifest_overlap で確かめ、重なりがあれば中断する（ワイルドカード * は比べない）。
#   - 組織にない削除の対象: 同じブランチで、削除を含む変更を何度も出すと（develop に出したあと、続きの変更をもう一度出す・
#     個人の組織で Deploy したあと Dryrun するなど）、2 回目からは、消す対象が組織にない。Salesforce は
#     「No ApexClass named: X found」で、検証・リリースの全体を失敗にする（2026-11-26 に force-test-win で発生）。そのため、
#     マニフェストを作ったあと、lib/project.sh の manifest_missing_in_org で、組織にない対象を調べ、manifest_drop_pairs で外す。
#     外すのは、組織の一覧（sf org list metadata）が取れて、名前がそこにないものだけ（大文字・小文字は区別しない）。
#     一覧が取れない種類（WARNING を表示）・フォルダの中の種類（Report・Dashboard・Document・EmailTemplate）・
#     ワイルドカード（*）・英数字と「_」「.」「-」以外を含む名前は、確かめずに残す（今までどおり、Salesforce が判断する）。
#     外しすぎると、消すはずのものが黙って残るため、迷うものは残す側に倒す。[members] の名前の書き間違いも、組織にない
#     ものとして外れるため、外したものは WARNING で 1 件ずつ表示し、デプロイのあとにもう一度表示する。GitHub Actions 上では、
#     実行の要約（GITHUB_STEP_SUMMARY）にも書く。
#   - 存在しない削除対象を許す指示（# @ignore-missing）: remove-target.txt に、`# @ignore-missing` で始まる
#     コメント行（行頭・# の後の空白は可）があるときだけ、sf project deploy start に --ignore-warnings を付ける。
#     削除対象が組織に存在しなくても、エラーにしない（「No ApexClass named: X found」を、警告として扱う）。
#     後始末（sf-project.sh --verify --cleanup）のように、どこまで消えているか分からない削除を、何度でも実行できる
#     ようにするための指示。--ignore-warnings はデプロイ全体に付くため、削除以外の警告も、エラーにならない。
#     指示があるときは、上の「組織にない削除の対象」の確認をせず、Salesforce に任せる（従来どおり）。指示がなければ、
#     組織にない対象は、上の確認で外れる（確かめられなかったものは、Salesforce のエラーになる）。通常のリリース・削除には、
#     付けないこと（--ignore-warnings は、削除以外の警告も、エラーにしなくなるため）。
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
source "${SCRIPT_DIR}/../lib/manifest.sh"   # manifest_build（マニフェストの生成。sf-promote-check.sh と共有）

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

# 【MANIFEST】テキストリストからマニフェストファイル(XML)を自動生成
#   生成は lib/manifest.sh の manifest_build（sf-promote-check.sh の R2 と共有。決まりは lib/manifest.sh の冒頭）。
#   ここでは、組織に出すときだけの処理（@isTest のクラスの検出・反映と削除の重なりの確認）を行う
phase_generate_manifest() {
    local i=0 filepath classname build_ret=0

    # @isTest アノテーションを持つ .cls ファイルを検出して RUN_TESTS に登録（生成の前に表示する）
    manifest_parse_list "$DEPLOY_LIST" || return $RET_NG
    while [[ $i -lt ${#MANIFEST_ARGS[@]} ]]; do
        if [[ "${MANIFEST_ARGS[$i]}" == "--source-dir" ]]; then
            filepath="${MANIFEST_ARGS[$((i+1))]}"
            if [[ "$filepath" == *.cls ]] && grep -qi "@isTest" "$filepath" 2>/dev/null; then
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

    manifest_build "$RELEASE_DIR" "$RELEASE_DIR" || build_ret=$?
    if [[ $build_ret -eq $RET_NO_CHANGE ]]; then
        log "WARNING" "デプロイ対象がありません。${DEPLOY_LIST} または ${REMOVE_LIST} にパスを記入してください。"
        return $RET_NO_CHANGE
    fi
    [[ $build_ret -eq 0 ]] || return $RET_NG

    # 反映と削除の両方に同じものがあれば、止める（先に消して、反映で作り直す。項目なら、データだけが黙って消える。
    # オブジェクトの本体やフォルダを deploy-target.txt に書くと、配下の全部が反映に入るため、起きる。lib/project.sh の manifest_overlap）
    if [[ -f "$REMOVE_XML" ]]; then
        local overlap item
        overlap=$(manifest_overlap "$DEPLOY_XML" "$REMOVE_XML") || {  # VAR=$(cmd) のため run 不使用
            log "ERROR" "マニフェストの重なりを確かめられません（package.xml / destructiveChanges.xml を読めません）。"
            return $RET_NG
        }
        if [[ -n "$overlap" ]]; then
            log "ERROR" "反映（package.xml）と削除（destructiveChanges.xml）の両方に、同じものがあります:"
            while IFS= read -r item; do
                [[ -n "$item" ]] && log "ERROR" "  ${item}"
            done <<< "$overlap"
            log "ERROR" "このまま進めると、削除のあとの反映で、作り直されます（項目なら、中のデータだけが消えます）。"
            log "ERROR" "deploy-target.txt に書いたオブジェクトの本体（*.object-meta.xml）やフォルダは、配下の項目などを、すべて反映に含めます。"
            return $RET_NG
        fi
    fi

    return $RET_OK
}

# 【PRUNE】削除の対象のうち、組織にないもの（すでに消えたもの）を、destructiveChanges.xml から外す
#   同じブランチで削除を含む変更を何度も出すと、2 回目からは、消す対象が組織にない。Salesforce は「No ApexClass named: X found」で、
#   検証・リリースの全体を失敗にするため、先に外す（lib/project.sh の manifest_missing_in_org・manifest_drop_pairs）。
#   確かめられたものだけを外す（一覧が取れない種類・フォルダの中の種類などは、外さない）。外したものは PRUNED_ITEMS に入れ、
#   最後にもう一度表示する（[members] の書き間違いも、組織にないとして外れるため、見落とさないように）。
#   remove-target.txt に「# @ignore-missing」があれば、何もしない（--ignore-warnings で、Salesforce に任せる。従来どおり）
#   戻り値: RET_OK / RET_NO_CHANGE（削除がすべて外れ、反映するものもない）/ RET_NG（XML を読めない・書き換えられない）
PRUNED_ITEMS=()
phase_prune_destructive() {
    [[ -f "$REMOVE_XML" ]] || return $RET_OK
    if grep -qE '^[[:space:]]*#[[:space:]]*@ignore-missing' "$REMOVE_LIST"; then  # 条件チェック
        return $RET_OK
    fi
    local missing item list="${RELEASE_DIR}/.missing-in-org.txt"
    log "INFO" "削除の対象が、組織（${TARGET_ORG}）にあるかを確かめます..."
    missing=$(manifest_missing_in_org "$REMOVE_XML" "$TARGET_ORG") || {  # VAR=$(cmd) のため run 不使用
        log "ERROR" "削除の対象を読めません（${REMOVE_XML}）。"
        return $RET_NG
    }
    if [[ -z "$missing" ]]; then
        log "SUCCESS" "削除の対象は、すべて組織にあります（確かめられなかったものは、上の WARNING）。"
        return $RET_OK
    fi
    printf '%s\n' "$missing" > "$list" || return $RET_NG  # run 不使用: 一時ファイルへの書き込み
    if ! manifest_drop_pairs "$REMOVE_XML" "$list"; then  # 条件チェック
        rm -f "$list"  # run 不使用: 一時ファイルの除去
        log "ERROR" "destructiveChanges.xml から、組織にないものを外せませんでした。"
        return $RET_NG
    fi
    rm -f "$list"  # run 不使用: 一時ファイルの除去
    while IFS= read -r item; do
        [[ -n "$item" ]] && PRUNED_ITEMS+=("$item")
    done <<< "$missing"
    _report_pruned summary
    if ! grep -q '<members>' "$REMOVE_XML" 2>/dev/null; then  # 条件チェック
        run rm -f "$REMOVE_XML"
        log "INFO" "削除の対象が、すべて組織にないため、削除は行いません（--pre-destructive-changes を付けません）。"
        if ! grep -q '<members>' "$DEPLOY_XML" 2>/dev/null; then  # 条件チェック（反映するものもない）
            return $RET_NO_CHANGE
        fi
    fi
    return $RET_OK
}

# _report_pruned [summary] - 組織にないため削除から外したもの（PRUNED_ITEMS）を、WARNING で表示する。
#   summary を付けると、GitHub Actions 上では、実行の要約（GITHUB_STEP_SUMMARY）にも書く（ログを開かなくても見えるように。
#   外した直後の 1 回だけ付ける。最後の再表示では付けない）
_report_pruned() {
    local item
    [[ ${#PRUNED_ITEMS[@]} -gt 0 ]] || return 0
    log "WARNING" "組織（${TARGET_ORG}）にないため、削除の対象から外しました（すでに消えているもの）: ${#PRUNED_ITEMS[@]} 件"
    for item in "${PRUNED_ITEMS[@]}"; do
        log "WARNING" "  ${item}"
    done
    log "WARNING" "  remove-target.txt の [members] の名前の書き間違いも、ここに出ます。消したいものが、ここにないかを確かめてください。"
    if [[ "${1:-}" == "summary" && -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
        # run 不使用: 実行の要約への追記
        {
            printf '### 削除の対象から外したもの（組織 %s にないため）\n\n' "$TARGET_ORG"
            for item in "${PRUNED_ITEMS[@]}"; do printf -- '- `%s`\n' "$item"; done
            printf '\nremove-target.txt の [members] の名前の書き間違いも、ここに出ます。\n\n'
        } >> "$GITHUB_STEP_SUMMARY" 2>/dev/null || true
    fi
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

phase_prune_destructive
prune_ret=$?
[[ $prune_ret -eq $RET_NG ]] && die "削除の対象の確認に失敗しました。"
if [[ $prune_ret -eq $RET_NO_CHANGE ]]; then
    log "SUCCESS" "反映・削除するものがありません（削除の対象は、すべて組織にありません）。正常終了します。"
    exit 0
fi

phase_release
res=$?

# 外したものは、最後にもう一度表示する（デプロイの出力の上に流れて、見落とさないように）
_report_pruned
if [[ $res -eq $RET_OK ]]; then
    log "SUCCESS" "デプロイ/検証が完了しました。"
elif [[ $res -eq $RET_NO_CHANGE ]]; then
    log "SUCCESS" "変更がないため処理をスキップしました。"
else
    die "Salesforce へのデプロイ/検証の実行に失敗しました。"
fi

exit $RET_OK
