#!/bin/bash
# ==============================================================================
# scenario.sh - e2e のシナリオ方式（実環境の L2。シナリオを 1 つずつ、短く動かす）
# ==============================================================================
# run.sh（sf-init の通し検証）が前回残したテスト用リポジトリを使い、名前で選んだシナリオだけを実行する。
# 通常のテスト（bash tests/run_tests.sh）には含まれない。実環境を使うため、e2e.yml（Actions）が、run.sh のあとに実行する。手元では、調査・新しい環境の確認のときだけ実行する。
# 設計: doc/integration-test-plan.md の 11
#
# 【使い方】
#   bash tests/e2e/scenario.sh --list              # シナリオの一覧（実環境に接続しない）
#   bash tests/e2e/scenario.sh log-secrets         # 名前で選んで実行する（複数指定可。名前なしは、何も実行しない）
#
# 【処理の流れ】
#   1. 前提の確認  : 鍵一式・gh のログインユーザー（既存のガード）。前回残したテスト用リポジトリ（最新の 1 つ。
#                    名前の形式とオーナーが一致するものだけ）が、GitHub にあること。なければ、run.sh で作るよう案内して終わる
#                    （シナリオ側では、リポジトリを、黙って作らない）
#   2. 状態の記録  : 実行の前に、main の SHA・ブランチの一覧・PR の数を記録する
#   3. 実行        : シナリオごとに、確認して、結果（成功 / 失敗 / 実行できない）と所要時間を表示する
#   4. 状態の確認  : 実行のあとに、2 と比べる。差があれば、報告して、後続のシナリオを実行しない
#   5. 結果        : 1 シナリオ = 1 行。失敗があれば、終了コード 1。「実行できない」は、成功に数えない
#
# 【シナリオ】（--list でも表示する）
#   log-secrets    : 直近の Actions の実行ログと PR のコメントに、PAT・Slack の Token・認証 URL・秘密鍵が出ていない（読み取りのみ）
#   validate-fail  : 壊れた Apex の PR → wf-validate が失敗し、PR に「検証失敗」のコメントが付く → 直して push → 再検証が成功する
#                    （組織へは dry-run だけ。PR は、マージせずに閉じ、ブランチを削除する。書き込みあり）
#   dist-main      : 配布版（Variable SF_TOOLS_BRANCH 未設定）で、ワークフローが sf-tools の main を使う（wf-validate のログで確認）。
#                    origin/main と origin/development の配布物に差がないとき（rr の直後）だけ実行する。Variable は、一時的に削除し、必ず戻す
#   metasync-diff  : 組織側だけに Hello World の Apex を作る → wf-metasync を起動 → main に反映される（B3）。組織・main に書き込む。
#                    run.sh のあと、main には、Hello World のファイルが残っている（リリースの履歴）。いったん外し（組織側だけの差分にするため）、
#                    終了時に、組織の Apex を削除し、main を、実行前の状態（Hello World のファイルの有無）に戻す
#   propagate-fail : main と staging に、同じファイルの、違う内容を入れて、wf-propagate を起動 → コンフリクトで失敗し、Slack に通知され、
#                    staging は変わらない（X4-5）。main・staging に、コミットする（終了時に、そのファイルを削除する。2 層以上のリポジトリが要る）
#   restart-org    : sf-restart.sh で、ジョブのクローンの接続先を、別の組織（staging の組織）に切り替える → 接続先が変わり、sf-dryrun が新しい組織を使う → 元の組織に戻す（A8。
#                    鍵一式に staging の組織があるときだけ。ログインは、認証 URL への差し替え。終了時に、必ず、元の組織へ戻す）
#   update-secret  : 管理者用のクローンで、sf-update-secret.sh の「1) 秘密鍵」を、同じ秘密鍵（~/.sf-jwt/force-XXXX/server.key）で実行 → Secret SF_PRIVATE_KEY の
#                    更新日時が進む・ほかの Secret は変わらない・出力に秘密鍵が出ない・誤ったパスは拒否され、更新されない（B2）。値は変わらない（同じ鍵で上書き）。
#                    このあとの validate-fail などが、上書きした鍵で、JWT ログインできることを、実際のワークフローで確かめる（順番を、その前にしている）
#   cross-os       : リポジトリを clone し（GitHub から。手元の作業フォルダを使わない）、OS 混在の問題（C2）を確認する: 記録されたテキストファイルに CRLF が
#                    ない・sf-hook.sh で入れたフック（pre-commit・pre-push）が、sf-tools の hooks/ と同じ内容で、CR がなく、実行できる・作業用ブランチで
#                    sf-sync-wf.sh --check が成功する（雛形と同じ）。リポジトリを作った OS とは別の OS で動かすと、OS 混在の確認になる
#                    （e2e.yml の macOS のジョブが、Windows が作ったリポジトリに対して動かす）。GitHub・組織へは書き込まない（一時フォルダの中だけ）
#   sync-wf        : 管理者用のクローン（admin ブランチ）で、ワークフローを改変 → sf-sync-wf.sh --check が見つける → sf-sync-wf.sh が雛形の内容に直す
#                    （コミット・push はしない）→ 雛形にあるファイルの --remove は拒否される・雛形にない不要なファイルは --remove で消せる（B4）。
#                    クローンの中だけ（GitHub・組織へは、書き込まない）。終了時に、クローンの .github/workflows を、元（HEAD）に戻す
#   manual-delete  : テスト用リポジトリの Secret（SLACK_BOT_TOKEN）と Variable（SLACK_CHANNEL_ID）を、手で削除 → sf-init.sh --status が
#                    不足を見つけ、直し方を示す → 元に戻す → 診断が、元に戻る（書き込みあり。終了時に、必ず元に戻す）
#
# 【安全】
#   ・既存の安全ガード（テスト用リポジトリの名前の形式・オーナーの一致）を、必ず通す。削除の経路は、持たない
#   ・書き込みを行うシナリオは、冒頭の警告に、書き込む内容を明記する（_scn_writes）。書き込んだものは、終了時（中断・異常終了を含む）に、
#     必ず元に戻す（_scn_restore）。元の値を読めない Secret は、鍵一式の値で戻せるものだけを、対象にする
#   ・秘密の値は、表示しない（見つかった「種類」だけを表示する）
#
# 【オプション】
#   --list        : シナリオの一覧を表示して終わる
#   -y, --yes     : 開始の確認を省略する
#   --repo NAME   : 対象のリポジトリを指定する（force-e2e-日時。名前の形式とオーナーの確認は、同じ）。省略すると、run.sh が前回残した最新のもの。
#                   手元に作業フォルダがない OS（別の OS が作ったリポジトリを使う cross-os）で使う。作業フォルダを使うほかのシナリオは、実行できない
#   -h, --help    : このヘルプを表示する
# ==============================================================================

readonly SCRIPT_NAME="e2e-scenario"
mkdir -p "$HOME/sf-tools/logs" 2>/dev/null || true  # run 不使用: ログフォルダの準備（log が使える前の処理）
readonly LOG_FILE="$HOME/sf-tools/logs/${SCRIPT_NAME}.log"
readonly LOG_MODE="NEW"

export SF_INIT_MODE=1   # プロジェクト外から実行するため、force-* チェックをバイパスする
E2E_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SF_TOOLS_ROOT="$(cd "${E2E_SCRIPT_DIR}/../.." && pwd)"

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}"
    exit 0
fi

source "${SF_TOOLS_ROOT}/lib/common.sh"
source "${E2E_SCRIPT_DIR}/lib.sh"

# ------------------------------------------------------------------------------
# 1. シナリオの一覧
# ------------------------------------------------------------------------------
SCENARIO_NAMES="log-secrets manual-delete update-secret sync-wf cross-os validate-fail dist-main metasync-diff propagate-fail restart-org"   # 実行の順番どおり
_scn_desc() {
    case "$1" in
        log-secrets)   echo "Actions のログ・PR のコメントに、秘密情報が出ていない（読み取りのみ）" ;;
        manual-delete) echo "Secret・Variable を手で削除 → --status が見つけ、直し方を示す → 元に戻す（書き込みあり）" ;;
        validate-fail) echo "壊れた Apex の PR で wf-validate が失敗し、コメントが付く → 直すと成功する（ブランチと PR を作り、後で閉じる）" ;;
        dist-main)     echo "配布版（SF_TOOLS_BRANCH 未設定）で、sf-tools の main が使われる。rr の直後だけ（Variable を一時的に削除し、戻す）" ;;
        metasync-diff) echo "組織側だけの Apex が、wf-metasync で main に反映される（組織と main に書き込み、必ず戻す）" ;;
        propagate-fail) echo "main → staging の伝播がコンフリクトで失敗し、通知され、staging は変わらない（main・staging にファイルを置き、削除する）" ;;
        update-secret) echo "sf-update-secret で秘密鍵を同じ鍵で上書き → 更新日時が進む・ほかは変わらない・誤ったパスは拒否される（同じ値で上書き。あとのシナリオが、JWT ログインを確かめる）" ;;
        cross-os)      echo "リポジトリを clone して、OS 混在の問題を確認する: CRLF がない・フックが同じ内容で実行できる・sf-sync-wf --check が成功する（読み取りのみ）" ;;
        sync-wf)       echo "sf-sync-wf が、改変したワークフローを見つけて、雛形に戻す。--remove は、雛形にあるファイルを拒否し、不要なファイルだけ消す（クローンの中だけ）" ;;
        restart-org)   echo "sf-restart で接続先を staging の組織に切り替え、sf-dryrun が新しい組織を使う → 元に戻す（ジョブのクローンの接続設定を、一時的に変える）" ;;
        *) echo "" ;;
    esac
}
# 書き込みを行うシナリオが、書き込む内容（なければ空）。開始の警告に表示する
_scn_writes() {
    case "$1" in
        manual-delete) echo "Secret（SLACK_BOT_TOKEN）と Variable（SLACK_CHANNEL_ID）を、一時的に削除し、すぐに元に戻します" ;;
        validate-fail) echo "テスト用ブランチ（e2e-vf-時刻）と PR を作り、wf-validate を動かします（組織へは dry-run のみ。マージしない）。終了時に、PR を閉じ、ブランチを削除します" ;;
        dist-main)     echo "Variable SF_TOOLS_BRANCH を一時的に削除し、テスト用ブランチ（e2e-dm-時刻）と PR で wf-validate を動かします（dry-run のみ）。終了時に、Variable を戻し、PR を閉じ、ブランチを削除します" ;;
        propagate-fail) echo "main と staging に、同じファイル（e2e-propagate-conflict.txt）の、違う内容をコミットし、wf-propagate を起動します（コンフリクトで失敗する想定）。終了時に、両方から、そのファイルを削除します" ;;
        update-secret) echo "Secret SF_PRIVATE_KEY を、同じ秘密鍵（~/.sf-jwt/${REPO_NAME}/server.key）で上書きします（値は変わりません。更新日時だけが進みます）" ;;
        sync-wf)       echo "管理者用のクローンの .github/workflows を、一時的に改変し（wf-validate.yml に 1 行・不要なファイル e2e-obsolete.yml）、sf-sync-wf.sh で直します。GitHub・組織へは書き込みません。終了時に、HEAD の状態へ戻します" ;;
        restart-org)   echo "ジョブのクローンの接続先を、sf-restart.sh で、staging の組織に切り替え（sf のエイリアス sf-tools-e2e-restart-STG を、一時的に作る）、dry-run を行います。終了時に、元の組織へ戻し、エイリアスを元の状態にします" ;;
        metasync-diff) echo "テスト用の組織に Apex（SfToolsE2eHello・SfToolsE2eHelloTest）を直接デプロイし、wf-metasync を起動します。main に、その Apex のファイルが、コミットされます（main にすでにあるものは、いったん外します）。終了時に、組織の Apex を削除し、main を実行前の状態に戻します" ;;
        *) echo "" ;;
    esac
}
_scn_known() { local n; for n in $SCENARIO_NAMES; do [[ "$n" == "$1" ]] && return 0; done; return 1; }
_scn_list() {
    local n
    for n in $SCENARIO_NAMES; do printf '  %-14s %s\n' "$n" "$(_scn_desc "$n")"; done
}

SELECTED=()
ASSUME_YES=0
LIST_ONLY=0
SCN_REPO_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --list)    LIST_ONLY=1 ;;
        -y|--yes)  ASSUME_YES=1 ;;
        --repo)    [[ -n "${2:-}" && "${2}" != -* ]] || die "--repo には、リポジトリ名（force-e2e-日時）を指定してください。"
                   SCN_REPO_ARG="$2"; shift ;;
        -*)        die "不明なオプションです: $1" ;;
        *)         _scn_known "$1" || die "不明なシナリオです: $1（--list で一覧を表示できます）"
                   SELECTED+=("$1") ;;
    esac
    shift
done

if [[ $LIST_ONLY -eq 1 ]]; then
    echo "シナリオ（run.sh が前回残したテスト用リポジトリに対して、実行します）:"
    _scn_list
    exit $RET_OK
fi
if [[ ${#SELECTED[@]} -eq 0 ]]; then
    echo "シナリオ名を指定してください（何も実行していません）。一覧:"
    _scn_list
    exit $RET_OK
fi

# ------------------------------------------------------------------------------
# 2. 前提の確認（既存のガード → テスト用リポジトリ）
# ------------------------------------------------------------------------------
e2e_load_fixture
e2e_guard_env

log "HEADER" "e2e のシナリオを開始します (${SCRIPT_NAME}.sh): ${SELECTED[*]}"
if [[ -n "$SCN_REPO_ARG" ]]; then
    # 指定されたリポジトリ（名前の形式が、テスト用のものだけ。オーナーは、鍵一式のものだけ: 下の _e2e_check_repo）
    e2e_is_target_repo "$SCN_REPO_ARG" || die "--repo に指定できるのは、テスト用のリポジトリ名（force-e2e-YYYYMMDD-HHMMSS）だけです: ${SCN_REPO_ARG}"
    PROJECT="${SCN_REPO_ARG#force-}"
else
PROJECT=$(e2e_find_latest_project) \
    || die "シナリオを実行できるテスト用の作業フォルダがありません（${E2E_HOME_ROOT}/${E2E_OWNER}/e2e-日時）。先に、bash tests/e2e/run.sh --no-add-tier で、テスト用リポジトリを作ってください。"  # VAR=$(cmd) のため run 不使用
fi
REPO_NAME="force-${PROJECT}"
REPO_FULL="${E2E_OWNER}/${REPO_NAME}"
_e2e_check_repo "$REPO_FULL"
_e2e_gh repo view "$REPO_FULL" >/dev/null 2>&1 \
    || die "テスト用のリポジトリが GitHub にありません: ${REPO_FULL}（先に、bash tests/e2e/run.sh --no-add-tier で作ってください）"  # 戻り値で判定するため run 不使用

if [[ $ASSUME_YES -eq 0 && "${GITHUB_ACTIONS:-}" != "true" ]]; then
    _warn=()
    for name in "${SELECTED[@]}"; do
        _w=$(_scn_writes "$name")  # VAR=$(cmd) のため run 不使用
        [[ -z "$_w" ]] || _warn+=("    書き込み（${name}）: ${_w}")
    done
    if [[ ${#_warn[@]} -gt 0 ]]; then
        print_admin_warning "!!  実際の GitHub に、書き込みます" "    対象: ${REPO_FULL}（テスト用。名前の形式・オーナーを確認済み）" "${_warn[@]}" "    終了時（中断を含む）に、必ず元に戻します"
    else
        print_admin_warning "!!  実際の GitHub を操作します（読み取りのみ）" "    対象: ${REPO_FULL}（テスト用。名前の形式・オーナーを確認済み）" "    シナリオ: ${SELECTED[*]}"
    fi
    ask_yn "続行しますか？" || die "中断しました。"
fi

# ------------------------------------------------------------------------------
# 元に戻す（書き込むシナリオが、削除したものを戻す。終了時に、必ず動く）
# ------------------------------------------------------------------------------
RESTORE_SECRET=""      # 削除中の Secret の名前（戻したら空にする。値は、鍵一式から戻す）
RESTORE_VAR_NAME=""    # 削除中の Variable の名前
RESTORE_VAR_VALUE=""   # その元の値
RESTORE_BRANCH=""      # 作ったテスト用ブランチ（e2e-vf-時刻。終了時に削除する）
RESTORE_PR=""          # 開いたままの PR の番号（終了時に、マージせずに閉じる）
RESTORE_APEX=0         # 1: 組織に Hello World の Apex を作った（終了時に、削除する）
RESTORE_MAIN_FILES=0   # 1: main の Hello World のファイルを、いじる（終了時に、削除して、実行前に有ったものを、戻す）
RESTORE_RESTART_CLONE=""   # 接続先を切り替えたジョブのクローン（終了時に、元の組織へ戻す）
RESTORE_RESTART_ALIAS=""   # 元の接続先のエイリアス
RESTORE_XOS_DIR=""     # cross-os が clone した一時フォルダ（終了時に、削除する。名前は e2e-xos.XXXXXX の形式だけ）
RESTORE_SYNCWF_CLONE=""   # ワークフローを改変した管理者用のクローン（終了時に、.github/workflows を HEAD の状態へ戻し、不要なファイルを消す）
RESTORE_PROP_FILE=0    # 1: main・staging に、propagate-fail のファイルを置いた（終了時に、両方から削除する）
RESTORE_MAIN_KEEP=""   # 実行前に main に有った Hello World のファイル（スペース区切り。終了時に、元の本文で戻す）
SCN_SF_TMP=""          # sf を使うシナリオの一時フォルダ（エイリアスの保存先を含む。終了時に、エイリアスを戻し、削除する）
SCN_OBSOLETE_WF="e2e-obsolete.yml"   # sync-wf が、クローンに置く、雛形にないワークフロー（終了時に消す）
SCN_PROP_FILE="e2e-propagate-conflict.txt"   # propagate-fail が、main・staging に置くファイル
SCN_ALLOW_MAIN_COMMITS=0   # 1: このシナリオは、main にコミットが増えてよい（wf-metasync が反映するため）。main の SHA の比較から外す
_scn_restore() {
    local rc=0
    if [[ -n "$RESTORE_SECRET" ]]; then
        # Secret の値は、読めない。鍵一式の値で戻せる SLACK_BOT_TOKEN だけを、削除の対象にしている
        if printf '%s' "$E2E_SLACK_BOT_TOKEN" | _e2e_gh_stdin secret set "$RESTORE_SECRET" -R "$REPO_FULL" >/dev/null 2>&1; then
            log "INFO" "  元に戻しました: Secret ${RESTORE_SECRET}"; RESTORE_SECRET=""
        else
            log "ERROR" "  Secret ${RESTORE_SECRET} を、元に戻せませんでした（${REPO_FULL}）。手で、gh secret set ${RESTORE_SECRET} -R ${REPO_FULL} を実行してください。"; rc=1
        fi
    fi
    if [[ -n "$RESTORE_VAR_NAME" ]]; then
        if _e2e_gh variable set "$RESTORE_VAR_NAME" -R "$REPO_FULL" --body "$RESTORE_VAR_VALUE" >/dev/null 2>&1; then
            log "INFO" "  元に戻しました: Variable ${RESTORE_VAR_NAME}"; RESTORE_VAR_NAME=""; RESTORE_VAR_VALUE=""
        else
            log "ERROR" "  Variable ${RESTORE_VAR_NAME} を、元に戻せませんでした（${REPO_FULL}）。元の値: ${RESTORE_VAR_VALUE}"; rc=1
        fi
    fi
    if [[ -n "$RESTORE_PR" ]]; then
        if e2e_gh_pr_close "$REPO_FULL" "$RESTORE_PR"; then
            log "INFO" "  元に戻しました: PR #${RESTORE_PR} を、マージせずに閉じました"; RESTORE_PR=""
        else
            log "ERROR" "  PR #${RESTORE_PR} を閉じられませんでした（${REPO_FULL}）。手で閉じてください（マージしないこと）。"; rc=1
        fi
    fi
    if [[ -n "$RESTORE_BRANCH" ]]; then
        # 削除してよいのは、このスクリプトが作る名前の形式だけ
        if [[ ! "$RESTORE_BRANCH" =~ ^e2e-(vf|dm)-[0-9]{6}$ ]]; then
            log "ERROR" "  削除対象外のブランチ名です: ${RESTORE_BRANCH}"; rc=1
        else
            e2e_cancel_pr_runs "$REPO_FULL" "$RESTORE_BRANCH"   # 走り出した検証を止める（取り消せなくても、続ける）
            if verify_branch_delete "$REPO_FULL" "$RESTORE_BRANCH"; then
                log "INFO" "  元に戻しました: ブランチ ${RESTORE_BRANCH} を削除しました"; RESTORE_BRANCH=""
            else
                log "ERROR" "  ブランチ ${RESTORE_BRANCH} を削除できませんでした（${REPO_FULL}）。手で削除してください。"; rc=1
            fi
        fi
    fi
    if [[ "$RESTORE_APEX" == "1" ]]; then
        # 組織の Hello World の Apex を、削除する（許可された 2 つの名前だけ。e2e_delete_apex が確認する）
        if ( e2e_sf_admin_login && e2e_delete_apex "$E2E_APEX_HELLO_TEST" "$E2E_APEX_HELLO" ); then
            log "INFO" "  元に戻しました: 組織の Apex（${E2E_APEX_HELLO}・${E2E_APEX_HELLO_TEST}）を削除しました"; RESTORE_APEX=0
        else
            log "ERROR" "  組織の Apex を削除できませんでした。bash tests/e2e/cleanup.sh --yes で、削除してください。"; rc=1
        fi
    fi
    if [[ "$RESTORE_MAIN_FILES" == "1" ]]; then
        # main の Hello World のファイルを、実行前の状態へ戻す（この 4 つのパスだけ）: 反映されたものを削除し、実行前に有ったものは、元の本文で戻す
        local p failed=0
        for p in $(verify_hello_paths); do
            verify_file_delete "$REPO_FULL" main "$p" "e2e: metasync-diff の後始末（${p##*/}）" || failed=1
        done
        for p in $RESTORE_MAIN_KEEP; do
            verify_hello_content_for "$p" | verify_file_put "$REPO_FULL" main "$p" "e2e: metasync-diff の後始末（${p##*/} を、実行前の状態に戻す）" || failed=1
        done
        if [[ $failed -eq 0 ]]; then
            log "INFO" "  元に戻しました: main の Hello World のファイルを、実行前の状態にしました"; RESTORE_MAIN_FILES=0; RESTORE_MAIN_KEEP=""
        else
            log "ERROR" "  main の Hello World のファイルを、戻せませんでした（${REPO_FULL}）。手で確認してください: $(verify_hello_paths | tr '\n' ' ')"; rc=1
        fi
    fi
    if [[ -n "$RESTORE_RESTART_CLONE" ]]; then
        # 接続先を、元の組織へ戻す（sf-restart.sh を、元のエイリアスで、もう一度。ログインは、認証 URL への差し替え）
        if e2e_run_sf_cmd "sf-restart-back" "$RESTORE_RESTART_CLONE" "${RESTORE_RESTART_ALIAS}\n2\n" "${E2E_SF_RESTART:-${SF_TOOLS_ROOT}/bin/sf-restart.sh}" \
            && e2e_wait_sf_install "$RESTORE_RESTART_CLONE"; then
            log "INFO" "  元に戻しました: ジョブのクローンの接続先を、${RESTORE_RESTART_ALIAS} に戻しました"; RESTORE_RESTART_CLONE=""
        else
            log "ERROR" "  ジョブのクローンの接続先を、元（${RESTORE_RESTART_ALIAS}）に戻せませんでした（${RESTORE_RESTART_CLONE}）。そのフォルダで、bash ~/sf-tools/bin/sf-restart.sh を実行して、${RESTORE_RESTART_ALIAS} を選んでください。"; rc=1
        fi
    fi
    if [[ -n "$RESTORE_XOS_DIR" ]]; then
        # clone した一時フォルダを削除する（このシナリオが作る名前の形式だけ）
        if [[ "$(basename "$RESTORE_XOS_DIR")" =~ ^e2e-xos\.[A-Za-z0-9]{6}$ && "$(dirname "$RESTORE_XOS_DIR")" == "${E2E_HOME_ROOT}/${E2E_OWNER}" ]]; then
            rm -rf "$RESTORE_XOS_DIR"  # run 不使用: 後始末（このシナリオが作る、決まった名前の一時フォルダだけ）
            log "INFO" "  元に戻しました: clone した一時フォルダを削除しました"; RESTORE_XOS_DIR=""
        else
            log "ERROR" "  削除対象外のフォルダ名です: ${RESTORE_XOS_DIR}"; rc=1
        fi
    fi
    if [[ -n "$RESTORE_SYNCWF_CLONE" ]]; then
        # 改変したワークフローを、HEAD の状態へ戻す。作った不要なファイル（e2e-obsolete.yml）を消す（この 2 つだけ）
        if git -C "$RESTORE_SYNCWF_CLONE" checkout -- .github/workflows 2>/dev/null             && rm -f "${RESTORE_SYNCWF_CLONE}/.github/workflows/${SCN_OBSOLETE_WF}"; then  # run 不使用: 後始末（このシナリオが作る決まった名前のファイルだけ）
            log "INFO" "  元に戻しました: 管理者用のクローンの .github/workflows を、HEAD の状態にしました"; RESTORE_SYNCWF_CLONE=""
        else
            log "ERROR" "  管理者用のクローンの .github/workflows を、戻せませんでした（${RESTORE_SYNCWF_CLONE}）。git checkout -- .github/workflows を実行し、${SCN_OBSOLETE_WF} を削除してください。"; rc=1
        fi
    fi
    if [[ "$RESTORE_PROP_FILE" == "1" ]]; then
        # main・staging に置いたファイルを削除する（このスクリプトが置く、決まった名前のファイルだけ。なければ、何もしない）
        local _br _pf=0
        for _br in main staging; do
            verify_file_delete "$REPO_FULL" "$_br" "$SCN_PROP_FILE" "e2e: propagate-fail の後始末（${_br}）" || _pf=1
        done
        if [[ $_pf -eq 0 ]]; then
            log "INFO" "  元に戻しました: main・staging から ${SCN_PROP_FILE} を削除しました"; RESTORE_PROP_FILE=0
        else
            log "ERROR" "  ${SCN_PROP_FILE} を、main・staging から削除できませんでした（${REPO_FULL}）。手で削除してください。"; rc=1
        fi
    fi
    return $rc
}
# sf のエイリアスを実行前に戻し、一時フォルダを削除する（シナリオの確認がすべて終わったあと、終了時に行う）
_scn_restore_local() {
    if [[ -n "$SCN_SF_TMP" ]]; then
        e2e_alias_restore "${SCN_SF_TMP}/aliases.txt" || true   # 失敗しても続ける（開発者のエイリアスを、誤って外さないための中断もある）
        rm -rf "$SCN_SF_TMP"  # run 不使用: 一時フォルダの後始末（認証 URL のファイルは、ここには置かない）
        SCN_SF_TMP=""
    fi
}
_scn_restore_all() { local rc=0; _scn_restore || rc=1; _scn_restore_local; return $rc; }
trap _scn_restore_all EXIT

# ------------------------------------------------------------------------------
# 3. 状態の記録と比較（シナリオが、リポジトリの状態を変えていないこと）
# ------------------------------------------------------------------------------
# 出力: main の SHA・ブランチの一覧・開いている PR の数（1 行ずつ。閉じた PR は、履歴として残るため、数えない）。取得に失敗したら、戻り値 1
_scn_state() {
    local sha br prs
    sha=$(_e2e_gh api "repos/${REPO_FULL}/git/ref/heads/main" --jq .object.sha 2>/dev/null) || return 1  # VAR=$(cmd) のため run 不使用
    br=$(_e2e_gh api "repos/${REPO_FULL}/branches" --paginate --jq '.[].name' 2>/dev/null) || return 1  # VAR=$(cmd) のため run 不使用
    br=$(printf '%s\n' "$br" | sort | tr '\n' ',')  # パイプのみのため run 不使用
    prs=$(_e2e_gh pr list -R "$REPO_FULL" --state open --limit 200 --json number --jq 'length' 2>/dev/null) || return 1  # VAR=$(cmd) のため run 不使用
    printf 'main=%s\nbranches=%s\nopen_prs=%s\n' "$sha" "$br" "$prs"
}

# ------------------------------------------------------------------------------
# 4. シナリオ
# ------------------------------------------------------------------------------
# 各シナリオは、確認を _chk で数え、「実行できない」ときは SCN_SKIP に理由を入れる
SCN_PASS=0
SCN_FAIL=0
SCN_SKIP=""
_chk() {   # 引数: 説明 結果(0=成功) [失敗の詳細]
    if [[ "$2" -eq 0 ]]; then
        SCN_PASS=$((SCN_PASS + 1)); log "SUCCESS" "  [OK] $1"
    else
        SCN_FAIL=$((SCN_FAIL + 1)); log "ERROR" "  [NG] $1${3:+ → $3}"
    fi
    return "$2"
}

# log-secrets: 直近の Actions の実行ログと、PR のコメント・本文に、秘密情報が出ていない
#   検査できなかったもの（実行が 0 件・ログが空）は、成功にしない（実行できないとして報告する）
scn_log_secrets() {
    local max="${E2E_LOG_RUNS:-10}" ids id n_runs=0 n_prs=0 kinds log pr_ids n
    ids=$(_e2e_gh run list -R "$REPO_FULL" --limit "$max" --json databaseId --jq '.[].databaseId' 2>/dev/null) \
        || { SCN_SKIP="Actions の実行の一覧を取得できません"; return; }  # VAR=$(cmd) のため run 不使用
    pr_ids=$(_e2e_gh pr list -R "$REPO_FULL" --state all --limit 30 --json number --jq '.[].number' 2>/dev/null) \
        || { SCN_SKIP="PR の一覧を取得できません"; return; }  # VAR=$(cmd) のため run 不使用
    for id in $ids; do
        [[ "$id" =~ ^[0-9]+$ ]] || continue
        log=$(_e2e_gh run view "$id" -R "$REPO_FULL" --log 2>/dev/null) || continue  # VAR=$(cmd) のため run 不使用
        [[ -n "$log" ]] || continue
        n_runs=$((n_runs + 1))
        if kinds=$(printf '%s' "$log" | e2e_scan_secrets); then   # 条件チェック（出力は、見つかった種類の名前だけ）
            _chk "実行 ${id} のログに、秘密情報が出ていない" 0
        else
            _chk "実行 ${id} のログに、秘密情報が出ていない" 1 "見つかった種類: $(printf '%s' "$kinds" | tr '\n' ' ')"
        fi
    done
    for n in $pr_ids; do
        [[ "$n" =~ ^[0-9]+$ ]] || continue
        log=$(_e2e_gh pr view "$n" -R "$REPO_FULL" --json body,comments --jq '[.body, (.comments[].body)] | join("\n---\n")' 2>/dev/null) || continue  # VAR=$(cmd) のため run 不使用
        n_prs=$((n_prs + 1))
        if kinds=$(printf '%s' "$log" | e2e_scan_secrets); then   # 条件チェック
            _chk "PR #${n} の本文・コメントに、秘密情報が出ていない" 0
        else
            _chk "PR #${n} の本文・コメントに、秘密情報が出ていない" 1 "見つかった種類: $(printf '%s' "$kinds" | tr '\n' ' ')"
        fi
    done
    if [[ $n_runs -eq 0 ]]; then
        SCN_SKIP="検査できる Actions のログがありません（実行が 0 件、またはログを取得できません。run.sh を、--no-actions なしで実行すると、できます）"
        return
    fi
    log "INFO" "  検査した範囲: Actions の実行 ${n_runs} 件・PR ${n_prs} 件"
}

# manual-delete: Secret・Variable を手で削除 → sf-init.sh --status が、不足を見つけ、直し方を示す → 元に戻す → 診断が、元に戻る
#   --status は、管理者用のクローン（admin/force-XXXX）で実行する（E2E_SF_INIT: 実行する sf-init.sh を差し替える。テスト用）。もともと診断が通らないとき（不足がある）は、確認の意味がないため、実行できないとする
_scn_status() {   # 出力を SCN_STATUS_OUT に入れ、戻り値は --status の終了コード
    local admin="${E2E_HOME_ROOT}/${E2E_OWNER}/${PROJECT}/admin/${REPO_NAME}"
    SCN_STATUS_OUT=$( cd "$admin" && printf 'Y\n' | bash "${E2E_SF_INIT:-${SF_TOOLS_ROOT}/bin/sf-init.sh}" --status 2>&1 | _strip_ansi; exit "${PIPESTATUS[1]}" )  # VAR=$(cmd) のため run 不使用
}
_scn_names() {   # 引数: secret|variable。名前の一覧（並べ替えて、カンマ区切り）
    local out
    out=$(_e2e_gh "$1" list -R "$REPO_FULL" --json name --jq '.[].name' 2>/dev/null) || return 1  # VAR=$(cmd) のため run 不使用
    printf '%s\n' "$out" | sort | tr '\n' ','  # パイプのみのため run 不使用
}
scn_manual_delete() {
    local admin="${E2E_HOME_ROOT}/${E2E_OWNER}/${PROJECT}/admin/${REPO_NAME}"
    local secrets_before vars_before saved i rc
    [[ -d "${admin}/.git" ]] || { SCN_SKIP="管理者用のクローンがありません（${admin}）。run.sh で、リポジトリを作り直してください"; return; }
    _scn_status; rc=$?
    [[ $rc -eq 0 ]] || { SCN_SKIP="もともと、診断（--status）が、不足を報告しています（終了コード ${rc}）。確認の前提が、満たされていません"; return; }
    secrets_before=$(_scn_names secret) || { SCN_SKIP="Secret の一覧を取得できません"; return; }  # VAR=$(cmd) のため run 不使用
    vars_before=$(_scn_names variable) || { SCN_SKIP="Variable の一覧を取得できません"; return; }  # VAR=$(cmd) のため run 不使用
    [[ "$secrets_before" == *SLACK_BOT_TOKEN* && "$vars_before" == *SLACK_CHANNEL_ID* ]] \
        || { SCN_SKIP="削除する対象（Secret SLACK_BOT_TOKEN・Variable SLACK_CHANNEL_ID）が、リポジトリにありません"; return; }
    saved=$(_e2e_gh variable get SLACK_CHANNEL_ID -R "$REPO_FULL" 2>/dev/null | tr -d '\r')  # パイプのみのため run 不使用
    [[ -n "$saved" ]] || { SCN_SKIP="Variable SLACK_CHANNEL_ID の値を、読み取れません"; return; }

    # --- Secret を削除 → 検出 ---
    RESTORE_SECRET="SLACK_BOT_TOKEN"   # 削除の前に登録する（途中で止まっても、終了時に戻す）
    _e2e_gh secret delete SLACK_BOT_TOKEN -R "$REPO_FULL" >/dev/null 2>&1; _chk "Secret SLACK_BOT_TOKEN を削除した" $?
    rc=0
    for (( i = 1; i <= ${E2E_STATUS_TRIES:-5}; i++ )); do
        _scn_status; rc=$?
        [[ $rc -ne 0 ]] && break
        sleep "${E2E_POLL_SEC:-5}"  # run 不使用: 反映の待機
    done
    _chk "Secret を削除すると、--status が、不足として終了する（終了コード ${rc}）" "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"
    printf '%s' "$SCN_STATUS_OUT" | grep -q "✗.*SLACK_BOT_TOKEN"; _chk "不足の一覧に、SLACK_BOT_TOKEN が出る" $?
    printf '%s' "$SCN_STATUS_OUT" | grep -q "gh secret set SLACK_BOT_TOKEN"; _chk "直し方（gh secret set SLACK_BOT_TOKEN）が、表示される" $?
    printf '%s' "$SCN_STATUS_OUT" | e2e_scan_secrets >/dev/null; _chk "--status の出力に、秘密情報が出ていない" $?   # e2e_scan_secrets は、含まれていなければ 0
    _scn_restore; _chk "Secret SLACK_BOT_TOKEN を、元に戻した" $?
    _scn_status; rc=$?; _chk "戻すと、--status が、不足なしに戻る（終了コード ${rc}）" $rc

    # --- Variable を削除 → 検出 ---
    RESTORE_VAR_NAME="SLACK_CHANNEL_ID"; RESTORE_VAR_VALUE="$saved"
    _e2e_gh variable delete SLACK_CHANNEL_ID -R "$REPO_FULL" >/dev/null 2>&1; _chk "Variable SLACK_CHANNEL_ID を削除した" $?
    rc=0
    for (( i = 1; i <= ${E2E_STATUS_TRIES:-5}; i++ )); do
        _scn_status; rc=$?
        [[ $rc -ne 0 ]] && break
        sleep "${E2E_POLL_SEC:-5}"  # run 不使用: 反映の待機
    done
    _chk "Variable を削除すると、--status が、不足として終了する（終了コード ${rc}）" "$([[ $rc -ne 0 ]] && echo 0 || echo 1)"
    printf '%s' "$SCN_STATUS_OUT" | grep -q "✗.*SLACK_CHANNEL_ID"; _chk "不足の一覧に、SLACK_CHANNEL_ID が出る" $?
    _scn_restore; _chk "Variable SLACK_CHANNEL_ID を、元に戻した" $?
    _scn_status; rc=$?; _chk "戻すと、--status が、不足なしに戻る（終了コード ${rc}）" $rc

    # --- 元の状態に戻ったこと（名前の一覧と、Variable の値）---
    _chk "Secret の名前の一覧が、実行前と同じ" "$([[ "$(_scn_names secret)" == "$secrets_before" ]] && echo 0 || echo 1)"
    _chk "Variable の名前の一覧が、実行前と同じ" "$([[ "$(_scn_names variable)" == "$vars_before" ]] && echo 0 || echo 1)"
    _chk "Variable SLACK_CHANNEL_ID の値が、実行前と同じ" "$([[ "$(_e2e_gh variable get SLACK_CHANNEL_ID -R "$REPO_FULL" 2>/dev/null | tr -d '\r')" == "$saved" ]] && echo 0 || echo 1)"
}

# ブランチに、リリース対象と Hello World の Apex を追加する（GitHub の API）。引数: ブランチ [broken]。broken のとき、クラスに文法の誤りを入れる
_scn_put_hello() {
    local br="$1" mode="${2:-}" p ok=0 cls="force-app/main/default/classes/${VERIFY_APEX_HELLO}.cls"
    verify_hello_deploy_target_text | verify_file_put "$REPO_FULL" "$br" "sf-tools/release/${br}/deploy-target.txt" "e2e: deploy-target" || ok=1
    verify_empty_target_text | verify_file_put "$REPO_FULL" "$br" "sf-tools/release/${br}/remove-target.txt" "e2e: remove-target" || ok=1
    for p in $(verify_hello_paths); do
        if [[ "$p" == "$cls" && "$mode" == "broken" ]]; then   # 壊れたクラス: 閉じる括弧の前に、文法の誤りを 1 行足す
            { verify_hello_cls | sed '$d'; printf '%s\n' "    Integer broken = ;" "}"; } | verify_file_put "$REPO_FULL" "$br" "$p" "e2e: 壊れた Apex" || ok=1
        else
            verify_hello_content_for "$p" | verify_file_put "$REPO_FULL" "$br" "$p" "e2e: ${p##*/}" || ok=1
        fi
    done
    return $ok
}

# validate-fail: 壊れた Apex の PR → wf-validate が失敗し、PR に「検証失敗」のコメントが付く → 直して push → 再検証が成功する
#   GitHub の API でブランチ・ファイルを作る（ローカルに clone しない）。組織へは dry-run（検証のみ）。PR は、マージせずに閉じ、ブランチを削除する
#   作ったブランチ・PR は、途中で止まっても、終了時（_scn_restore）に、閉じる・削除する
scn_validate_fail() {
    local br sha b1 b2 prn run1="" run2="" cls
    br="e2e-vf-$(date +%H%M%S)"  # VAR=$(cmd) のため run 不使用
    cls="force-app/main/default/classes/${VERIFY_APEX_HELLO}.cls"
    sha=$(verify_branch_sha "$REPO_FULL" main) || sha=""  # VAR=$(cmd) のため run 不使用
    [[ -n "$sha" ]] || { SCN_SKIP="main の SHA を取得できません"; return; }

    RESTORE_BRANCH="$br"   # 作る前に登録する（途中で止まっても、終了時に削除する）
    verify_branch_create "$REPO_FULL" "$br" "$sha"; _chk "テスト用ブランチ（${br}）を作った" $? || return
    _scn_put_hello "$br" broken; _chk "リリース対象と、壊れた Apex を、ブランチに追加した" $? || return

    b1=$(e2e_latest_run_id "$REPO_FULL" wf-validate.yml "$br")  # VAR=$(cmd) のため run 不使用
    prn=$(e2e_gh_pr_create "$REPO_FULL" "$br" "e2e: validate-fail (${br})" main) || prn=""  # VAR=$(cmd) のため run 不使用
    _chk "PR を作った" "$([[ -n "$prn" ]] && echo 0 || echo 1)" || return
    RESTORE_PR="$prn"

    run1=$(e2e_wait_pr_run "$REPO_FULL" wf-validate.yml "$br" "$b1") || run1=""  # VAR=$(cmd) のため run 不使用
    _chk "wf-validate が実行され、完了した（壊れた Apex）" "$([[ -n "$run1" ]] && echo 0 || echo 1)" || return
    _chk "wf-validate が失敗した（壊れた Apex。成功してはいけない）" "$([[ "$(e2e_run_conclusion "$REPO_FULL" "$run1")" == "failure" ]] && echo 0 || echo 1)"
    e2e_pr_comment_has "$REPO_FULL" "$prn" "検証失敗"; _chk "PR に、「検証失敗」のコメントが付いた"  $?
    e2e_pr_comment_has "$REPO_FULL" "$prn" "$VERIFY_APEX_HELLO"; _chk "コメントに、失敗したクラス名（${VERIFY_APEX_HELLO}）が出ている" $?

    # 直して push → 再検証が成功する
    b2="$run1"
    verify_hello_cls | verify_file_put "$REPO_FULL" "$br" "$cls" "e2e: 直した"; _chk "壊れたクラスを直して、push した" $? || return
    run2=$(e2e_wait_pr_run "$REPO_FULL" wf-validate.yml "$br" "$b2") || run2=""  # VAR=$(cmd) のため run 不使用
    _chk "wf-validate が実行され、完了した（直したあと）" "$([[ -n "$run2" ]] && echo 0 || echo 1)" || return
    _chk "wf-validate が成功した（直したあと）" "$([[ "$(e2e_run_conclusion "$REPO_FULL" "$run2")" == "success" ]] && echo 0 || echo 1)"
    e2e_pr_comment_has "$REPO_FULL" "$prn" "検証成功"; _chk "PR に、「検証成功」のコメントが付いた" $?

    # 後始末（PR は、マージせずに閉じる。ブランチを削除する）
    e2e_gh_pr_close "$REPO_FULL" "$prn"; _chk "PR を、マージせずに閉じた" $? && RESTORE_PR=""
    e2e_cancel_pr_runs "$REPO_FULL" "$br"
    verify_branch_delete "$REPO_FULL" "$br"; _chk "テスト用ブランチを削除した" $? && RESTORE_BRANCH=""
}

# dist-main: 配布版（Variable SF_TOOLS_BRANCH 未設定）で、ワークフローが sf-tools の main を使う
#   wf-validate は、「git clone -b ${{ vars.SF_TOOLS_BRANCH || 'main' }} …」で sf-tools を取得する。Variable を一時的に削除して、PR を出し、
#   実行のログに「git clone -b main」があること（development ではないこと）を確認する。Variable・PR・ブランチは、必ず戻す。
#   origin/main と origin/development の、配布物（bin・lib・phases・hooks・templates・config）に差がないときだけ、実行する
#   （差があると、main を使っていることの確認が、「rr の前の状態」の確認になり、意味が変わるため。rr の直後に実行する）
#   E2E_SF_TOOLS_GIT_DIR: 差を比べる sf-tools の git フォルダ（既定: このスクリプトの sf-tools。テスト用）
scn_dist_main() {
    local gd="${E2E_SF_TOOLS_GIT_DIR:-$SF_TOOLS_ROOT}" br sha b1 prn run1="" saved
    git -C "$gd" fetch -q origin main development >/dev/null 2>&1 \
        || { SCN_SKIP="sf-tools の origin から main・development を取得できません"; return; }  # 戻り値で判定するため run 不使用
    git -C "$gd" diff --quiet origin/main origin/development -- bin lib phases hooks templates config \
        || { SCN_SKIP="origin/main と origin/development で、配布物（bin・lib・phases・hooks・templates・config）に差があります（rr の直後だけ、実行できます）"; return; }  # 戻り値で判定するため run 不使用
    saved=$(_e2e_gh variable get SF_TOOLS_BRANCH -R "$REPO_FULL" 2>/dev/null | tr -d '\r')  # パイプのみのため run 不使用
    [[ -n "$saved" ]] || { SCN_SKIP="Variable SF_TOOLS_BRANCH が、もともと未設定です（削除して未設定の動きを確認する、この確認の前提が満たされていません）"; return; }
    sha=$(verify_branch_sha "$REPO_FULL" main) || sha=""  # VAR=$(cmd) のため run 不使用
    [[ -n "$sha" ]] || { SCN_SKIP="main の SHA を取得できません"; return; }
    br="e2e-dm-$(date +%H%M%S)"  # VAR=$(cmd) のため run 不使用

    RESTORE_VAR_NAME="SF_TOOLS_BRANCH"; RESTORE_VAR_VALUE="$saved"   # 削除の前に登録する（途中で止まっても、終了時に戻す）
    RESTORE_BRANCH="$br"
    _e2e_gh variable delete SF_TOOLS_BRANCH -R "$REPO_FULL" >/dev/null 2>&1; _chk "Variable SF_TOOLS_BRANCH を削除した（未設定にした）" $? || return
    verify_branch_create "$REPO_FULL" "$br" "$sha"; _chk "テスト用ブランチ（${br}）を作った" $? || return
    _scn_put_hello "$br"; _chk "リリース対象と Hello World の Apex を、ブランチに追加した" $? || return
    b1=$(e2e_latest_run_id "$REPO_FULL" wf-validate.yml "$br")  # VAR=$(cmd) のため run 不使用
    prn=$(e2e_gh_pr_create "$REPO_FULL" "$br" "e2e: dist-main (${br})" main) || prn=""  # VAR=$(cmd) のため run 不使用
    _chk "PR を作った" "$([[ -n "$prn" ]] && echo 0 || echo 1)" || return
    RESTORE_PR="$prn"
    run1=$(e2e_wait_pr_run "$REPO_FULL" wf-validate.yml "$br" "$b1") || run1=""  # VAR=$(cmd) のため run 不使用
    _chk "wf-validate が実行され、完了した（SF_TOOLS_BRANCH 未設定）" "$([[ -n "$run1" ]] && echo 0 || echo 1)" || return
    verify_run_log_has "$REPO_FULL" "$run1" "git clone -b main https://github.com/tama-create/sf-tools.git"; _chk "未設定のとき、sf-tools の main を取得した（git clone -b main）" $?
    verify_run_log_has "$REPO_FULL" "$run1" "git clone -b ${saved} https://github.com/tama-create/sf-tools.git"; _chk "元の設定（${saved}）の sf-tools は、取得していない" "$(( $? == 0 ? 1 : 0 ))"
    _chk "wf-validate が成功した（main の sf-tools で、Hello World を検証できた）" "$([[ "$(e2e_run_conclusion "$REPO_FULL" "$run1")" == "success" ]] && echo 0 || echo 1)"

    # 元に戻す（Variable・PR・ブランチ）
    _scn_restore; _chk "Variable・PR・ブランチを、元に戻した" $?
    _chk "Variable SF_TOOLS_BRANCH の値が、実行前と同じ（${saved}）" "$([[ "$(_e2e_gh variable get SF_TOOLS_BRANCH -R "$REPO_FULL" 2>/dev/null | tr -d '\r')" == "$saved" ]] && echo 0 || echo 1)"
}

# sf を使うシナリオの準備: 一時フォルダと、sf のエイリアスの保存（終了時に、実行前の状態へ戻す）
_scn_sf_prepare() {
    check_sf_cli   # sf が終了コードを正しく返すか（npm 版が前提。異常なら中断）
    SCN_SF_TMP=$(mktemp -d "${TMPDIR:-/tmp}/e2e-run.XXXXXX") || return 1  # VAR=$(cmd) のため run 不使用（後掃除の対象になる名前）
    E2E_TMP="$SCN_SF_TMP"
    e2e_alias_snapshot "${SCN_SF_TMP}/aliases.txt"
}

# sf・code・ブラウザの shim と、認証 URL のファイル（main・staging・develop）を、一時フォルダに用意する（run.sh と同じ。ログインを、認証 URL に差し替える）
#   認証 URL のファイルは、SCN_SF_TMP の中（終了時に、削除される）
_scn_shims_prepare() {
    local d n
    _scn_sf_prepare || return 1
    d="${SCN_SF_TMP}/shims"
    mkdir -p "$d"  # run 不使用: 差し替え用コマンドの置き場（一時フォルダ内）
    cp "${E2E_SCRIPT_DIR}/shims/sf" "${d}/sf"  # run 不使用: 差し替え用コマンドの配置（一時フォルダ内）
    cp "${E2E_SCRIPT_DIR}/shims/code" "${d}/code"  # run 不使用: 同上
    for n in start xdg-open open powershell.exe wslview; do cp "${E2E_SCRIPT_DIR}/shims/browser" "${d}/${n}"; done  # run 不使用: 同上
    chmod +x "${d}"/* 2>/dev/null || true  # run 不使用: 実行権限の付与（Windows は効果なし・意図的エラー無視）
    export E2E_SHIM_DIR="$d"
    export E2E_SFDX_URL_FILE="${SCN_SF_TMP}/sfdx-url.txt"
    printf '%s' "$E2E_SFDX_AUTH_URL" > "$E2E_SFDX_URL_FILE"
    chmod 600 "$E2E_SFDX_URL_FILE" 2>/dev/null || true  # run 不使用: ファイル権限保護（Windows は効果なし・意図的エラー無視）
    if e2e_tier_available staging; then
        export E2E_SFDX_URL_FILE_STG="${SCN_SF_TMP}/sfdx-url-stg.txt"
        printf '%s' "$E2E_SFDX_AUTH_URL_STG" > "$E2E_SFDX_URL_FILE_STG"
        chmod 600 "$E2E_SFDX_URL_FILE_STG" 2>/dev/null || true  # run 不使用: 同上
    fi
    if e2e_tier_available develop; then
        export E2E_SFDX_URL_FILE_DEV="${SCN_SF_TMP}/sfdx-url-dev.txt"
        printf '%s' "$E2E_SFDX_AUTH_URL_DEV" > "$E2E_SFDX_URL_FILE_DEV"
        chmod 600 "$E2E_SFDX_URL_FILE_DEV" 2>/dev/null || true  # run 不使用: 同上
    fi
}

# metasync-diff: 組織側だけに Hello World の Apex を作る → wf-metasync を起動 → main に反映される（B3: 実差分の反映）
#   組織へ直接デプロイする（Git を通さない）ため、Git には、組織にだけある差分になる。wf-metasync は、それを main にコミットする。
#   書き込むのは、許可された 2 つの名前（SfToolsE2eHello・SfToolsE2eHelloTest）だけ。終了時に、組織の Apex と main のファイルを、削除する
#   前提: 組織にも main にも、Hello World の Apex がないこと（あれば、実行できない。bash tests/e2e/cleanup.sh --yes で消す）
scn_metasync_diff() {
    local p cnt id concl orig=""
    SCN_ALLOW_MAIN_COMMITS=1   # wf-metasync が、main にコミットする
    _scn_sf_prepare || { SCN_SKIP="sf のエイリアスの保存に失敗しました"; return; }
    ( e2e_sf_admin_login ) || { SCN_SKIP="テスト用の組織に、ログインできません"; return; }
    cnt=$(e2e_apex_count "$E2E_APEX_HELLO") || { SCN_SKIP="組織の Apex の件数を取得できません"; return; }  # VAR=$(cmd) のため run 不使用
    [[ "$cnt" == "0" ]] || { SCN_SKIP="組織に、すでに Hello World の Apex があります（bash tests/e2e/cleanup.sh --yes で消してください）"; return; }

    # run.sh のあと、main には、リリースの履歴として、Hello World のファイルが残っている。組織側だけの差分にするため、いったん外す
    for p in $(verify_hello_paths); do
        if verify_file_sha "$REPO_FULL" main "$p" >/dev/null; then orig="${orig:+$orig }${p}"; fi
    done
    RESTORE_APEX=1; RESTORE_MAIN_FILES=1; RESTORE_MAIN_KEEP="$orig"   # いじる前に登録する（途中で止まっても、終了時に、実行前の状態へ戻す）
    for p in $orig; do
        verify_file_delete "$REPO_FULL" main "$p" "e2e: metasync-diff の前提の整備（${p##*/} を、いったん外す）"; _chk "（前提）main から ${p##*/} を、いったん外した" $? || return
    done
    e2e_deploy_hello; _chk "組織に、Hello World の Apex を直接デプロイした（Git を通さない）" $? || return
    cnt=$(e2e_apex_count "$E2E_APEX_HELLO") || cnt=""  # VAR=$(cmd) のため run 不使用
    _chk "組織に、${E2E_APEX_HELLO} が 1 つできた" "$([[ "$cnt" == "1" ]] && echo 0 || echo 1)" || return
    verify_file_sha "$REPO_FULL" main "force-app/main/default/classes/${VERIFY_APEX_HELLO}.cls" >/dev/null
    _chk "（前提）main には、まだ ${VERIFY_APEX_HELLO}.cls がない" "$(( $? == 0 ? 1 : 0 ))" || return

    id=$(verify_dispatch_workflow "$REPO_FULL" wf-metasync.yml main) || id=""  # VAR=$(cmd) のため run 不使用
    _chk "wf-metasync を起動した" "$([[ -n "$id" ]] && echo 0 || echo 1)" || return
    verify_wait_run "$REPO_FULL" "$id"; _chk "wf-metasync が完了した" $? || return
    concl=$(e2e_run_conclusion "$REPO_FULL" "$id")  # VAR=$(cmd) のため run 不使用
    _chk "wf-metasync が成功した" "$([[ "$concl" == "success" ]] && echo 0 || echo 1)" || return
    for p in $(verify_hello_paths); do
        verify_file_sha "$REPO_FULL" main "$p" >/dev/null; _chk "組織の差分が、main に反映された（${p##*/}）" $?
    done
    verify_gh api -H "Accept: application/vnd.github.raw" "repos/${REPO_FULL}/contents/force-app/main/default/classes/${VERIFY_APEX_HELLO}.cls?ref=main" 2>/dev/null | grep -qF "Hello, World!"
    _chk "反映されたクラスの中身が、組織に作ったものと同じ（Hello, World!）" $?

    # 後始末（組織の Apex・main のファイル。sf のエイリアスは、終了時に戻す）
    _scn_restore; _chk "組織の Apex と、main のファイルを、実行前の状態に戻した" $?
    cnt=$( ( e2e_sf_admin_login >/dev/null 2>&1; e2e_apex_count "$E2E_APEX_HELLO" ) ) || cnt=""  # VAR=$(cmd) のため run 不使用
    _chk "組織から、${E2E_APEX_HELLO} が消えた" "$([[ "$cnt" == "0" ]] && echo 0 || echo 1)"
    local now=""
    for p in $(verify_hello_paths); do
        if verify_file_sha "$REPO_FULL" main "$p" >/dev/null; then now="${now:+$now }${p}"; fi
    done
    _chk "main の Hello World のファイルが、実行前と同じ（$(printf '%s' "$orig" | wc -w | tr -d ' ') 個）" "$([[ "$now" == "$orig" ]] && echo 0 || echo 1)"
}

# propagate-fail: main → staging の伝播（wf-propagate）が、コンフリクトで失敗する経路（X4-5。成功の経路は、run.sh が確認している）
#   main と staging に、同じファイルの、違う内容をコミットする（どちらにも、まだないファイルの、追加どうしの衝突）。そのうえで、wf-propagate を手動で起動する。
#   確認: 実行が失敗する・ログにコンフリクトが出る・Slack への通知が成功する（ok:true）・staging の先頭が、実行の前後で変わらない（壊さない）
#   終了時に、main・staging から、そのファイルを削除する。前提: staging ブランチがある（2 層以上）・main・staging に、そのファイルがない
scn_propagate_fail() {
    local f="$SCN_PROP_FILE" br id concl stg_before stg_after
    SCN_ALLOW_MAIN_COMMITS=1   # main に、コミットする
    stg_before=$(verify_branch_sha "$REPO_FULL" staging) || stg_before=""  # VAR=$(cmd) のため run 不使用
    [[ -n "$stg_before" ]] || { SCN_SKIP="staging ブランチがありません（2 層以上のリポジトリが要ります。run.sh --layout 2 など）"; return; }
    for br in main staging; do
        if verify_file_sha "$REPO_FULL" "$br" "$f" >/dev/null; then SCN_SKIP="${br} に、すでに ${f} があります（先に消してください）"; return; fi
    done

    RESTORE_PROP_FILE=1   # 置く前に登録する（途中で止まっても、終了時に削除する）
    printf '%s\n' "main の内容（コンフリクトの確認）" | verify_file_put "$REPO_FULL" main "$f" "e2e: propagate-fail（main）"
    _chk "main に ${f} をコミットした" $? || return
    printf '%s\n' "staging の内容（コンフリクトの確認）" | verify_file_put "$REPO_FULL" staging "$f" "e2e: propagate-fail（staging）"
    _chk "staging に、同じファイルの、違う内容をコミットした" $? || return
    stg_before=$(verify_branch_sha "$REPO_FULL" staging) || stg_before=""  # VAR=$(cmd) のため run 不使用（コミットしたあとの先頭）

    id=$(verify_dispatch_workflow "$REPO_FULL" wf-propagate.yml main) || id=""  # VAR=$(cmd) のため run 不使用
    _chk "wf-propagate を起動した" "$([[ -n "$id" ]] && echo 0 || echo 1)" || return
    verify_wait_run "$REPO_FULL" "$id"; _chk "wf-propagate が完了した" $? || return
    concl=$(e2e_run_conclusion "$REPO_FULL" "$id")  # VAR=$(cmd) のため run 不使用
    _chk "wf-propagate が失敗した（コンフリクトは、失敗として止める）" "$([[ "$concl" == "failure" ]] && echo 0 || echo 1)"
    verify_run_log_has "$REPO_FULL" "$id" "コンフリクト"; _chk "ログに、コンフリクトが出ている" $?
    verify_run_log_has "$REPO_FULL" "$id" '"ok":true'; _chk "コンフリクトが、Slack に通知された（ok:true）" $?
    stg_after=$(verify_branch_sha "$REPO_FULL" staging) || stg_after=""  # VAR=$(cmd) のため run 不使用
    _chk "失敗しても、staging の先頭は、変わらない（ブランチを壊さない）" "$([[ -n "$stg_before" && "$stg_after" == "$stg_before" ]] && echo 0 || echo 1)"

    # 後始末（main・staging から、ファイルを削除する）
    _scn_restore; _chk "main・staging から、${f} を削除した" $?
    for br in main staging; do
        verify_file_sha "$REPO_FULL" "$br" "$f" >/dev/null
        _chk "${br} から、${f} が消えた" "$(( $? == 0 ? 1 : 0 ))"
    done
}

# restart-org: sf-restart.sh で、ジョブのクローンの接続先を、別の組織（staging の組織）に切り替える（A8）
#   run.sh が残した、リリース用のジョブのクローン（{作業フォルダ}/e2e-hello-時刻/force-XXXX）を使う。
#   確認: 接続先（.sf/config.json の target-org）が、新しいエイリアスに変わる・その組織のユーザーが、staging の組織のユーザー（Variable SF_USERNAME_STG）で、
#         元の組織のユーザーとは違う・sf-dryrun.sh が、新しいエイリアスの組織で、検証する。そのあと、元のエイリアスへ戻し、元の組織のユーザーに戻ったことを確認する。
#   書き込み: クローンの .sf/config.json・.sfdx/sfdx-config.json（sf-restart が作り直す）・sf のエイリアス sf-tools-e2e-restart-STG（終了時に、元の一覧へ戻す）。
#             組織への書き込みはない（dry-run のみ）
#   前提: 鍵一式に staging の組織がある・ジョブのクローン（接続済み）がある・Variable SF_USERNAME_STG がある
#   E2E_SF_RESTART / E2E_SF_DRYRUN: 実行する sf-restart.sh / sf-dryrun.sh を差し替える（テスト用）
_scn_org_user() {   # 引数: クローン エイリアス。その組織の接続ユーザー名を返す
    local out
    out=$(cd "$1" && sf org display --target-org "$2" --json 2>/dev/null) || return 1  # VAR=$(cmd) のため run 不使用
    json_get "$out" result.username
}
scn_restart_org() {
    local work="${E2E_HOME_ROOT}/${E2E_OWNER}/${PROJECT}" d clone="" alias0 alias1="sf-tools-e2e-restart-STG" user0 user1 stg_user cfg
    local restart="${E2E_SF_RESTART:-${SF_TOOLS_ROOT}/bin/sf-restart.sh}" dryrun="${E2E_SF_DRYRUN:-${SF_TOOLS_ROOT}/bin/sf-dryrun.sh}"
    e2e_tier_available staging || { SCN_SKIP="鍵一式に、staging の組織がありません（bootstrap.sh --add-orgs で追加してください）"; return; }
    for d in "$work"/e2e-hello-[0-9][0-9][0-9][0-9][0-9][0-9]; do   # 名前の並び順が、時刻順（最新が、最後）
        [[ -f "${d}/${REPO_NAME}/.sf/config.json" ]] && clone="${d}/${REPO_NAME}"
    done
    [[ -n "$clone" ]] || { SCN_SKIP="接続済みのジョブのクローン（${work}/e2e-hello-時刻/${REPO_NAME}/.sf/config.json）がありません（run.sh のリリースの確認が残すものです）"; return; }
    stg_user=$(_e2e_gh variable get SF_USERNAME_STG -R "$REPO_FULL" 2>/dev/null | tr -d '[:space:]')  # パイプのみのため run 不使用
    [[ -n "$stg_user" ]] || { SCN_SKIP="Variable SF_USERNAME_STG がありません（staging の組織が、このリポジトリに、接続されていません）"; return; }
    _scn_shims_prepare || { SCN_SKIP="sf のエイリアスの保存に失敗しました"; return; }

    cfg=$(cat "${clone}/.sf/config.json")  # VAR=$(cmd) のため run 不使用
    alias0=$(json_get "$cfg" target-org) || alias0=""  # VAR=$(cmd) のため run 不使用
    [[ -n "$alias0" ]] || { SCN_SKIP="クローンの接続先（target-org）を読み取れません"; return; }
    # run.sh の終わりに、sf のエイリアスは実行前へ戻るため、クローンの元の接続先（${alias0}）は、いまは、つながっていない。
    #   main の組織に、元のエイリアスでログインし直してから、ユーザーを読む（このエイリアスは、終了時に、保存した一覧へ戻る）
    run sf org login sfdx-url --sfdx-url-file "$E2E_SFDX_URL_FILE" --alias "$alias0" >/dev/null 2>&1 \
        || { SCN_SKIP="元の接続先（${alias0}）に、認証 URL でログインできません"; return; }
    user0=$(_scn_org_user "$clone" "$alias0") || user0=""  # VAR=$(cmd) のため run 不使用
    [[ -n "$user0" ]] || { SCN_SKIP="元の接続先（${alias0}）の、ユーザーを取得できません（接続が切れています）"; return; }
    [[ "$user0" != "$stg_user" ]] || { SCN_SKIP="元の接続先が、すでに staging の組織です（切り替えの確認ができません）"; return; }

    RESTORE_RESTART_CLONE="$clone"; RESTORE_RESTART_ALIAS="$alias0"   # 切り替える前に登録する（途中で止まっても、終了時に戻す）
    rm -f "${clone}/sf-tools/logs/sf-install.log"  # run 不使用: 前回の完了メッセージを、完了の待ちに、使わないため（ログファイルだけ）

    # --- staging の組織へ切り替える ---
    e2e_run_sf_cmd "sf-restart-stg" "$clone" "${alias1}\n2\n" "$restart"; _chk "sf-restart.sh で、接続先を ${alias1} に切り替えた" $? || return
    e2e_wait_sf_install "$clone"; _chk "切り替えのあとの sf-install.sh（背景）が完了した" $? || return
    cfg=$(cat "${clone}/.sf/config.json")  # VAR=$(cmd) のため run 不使用
    _chk "接続先（.sf/config.json の target-org）が、${alias1} に変わった" "$([[ "$(json_get "$cfg" target-org)" == "$alias1" ]] && echo 0 || echo 1)"
    user1=$(_scn_org_user "$clone" "$alias1") || user1=""  # VAR=$(cmd) のため run 不使用
    _chk "新しい接続先のユーザーが、staging の組織のユーザー（SF_USERNAME_STG）である" "$([[ "$user1" == "$stg_user" ]] && echo 0 || echo 1)"
    _chk "元の組織のユーザーとは、違う" "$([[ -n "$user1" && "$user1" != "$user0" ]] && echo 0 || echo 1)"
    e2e_run_sf_cmd "sf-dryrun-restart" "$clone" "" "$dryrun" --no-open; _chk "sf-dryrun.sh が、新しい組織で、検証できた（dry-run）" $?
    grep -qF "$alias1" "${E2E_TMP}/sf-dryrun-restart.out"; _chk "sf-dryrun.sh の接続先に、新しいエイリアス（${alias1}）が表示された" $?

    # --- 元の組織へ戻す ---
    _scn_restore; _chk "接続先を、元の組織（${alias0}）に戻した" $?
    cfg=$(cat "${clone}/.sf/config.json")  # VAR=$(cmd) のため run 不使用
    _chk "接続先（target-org）が、元の ${alias0} に戻った" "$([[ "$(json_get "$cfg" target-org)" == "$alias0" ]] && echo 0 || echo 1)"
    user1=$(_scn_org_user "$clone" "$alias0") || user1=""  # VAR=$(cmd) のため run 不使用
    _chk "元の組織のユーザーに、戻った" "$([[ "$user1" == "$user0" ]] && echo 0 || echo 1)"
}

# sync-wf: sf-sync-wf.sh（B4）。管理者用のクローン（{作業フォルダ}/admin/force-XXXX。run.sh が作る。admin ブランチ）の中だけで確認する
#   確認: 改変なしで、--check が成功する → wf-validate.yml に 1 行足すと、--check が失敗する（終了コード 1）・差分にそのファイル名が出る →
#         sf-sync-wf.sh（確認に Y）が、雛形の内容で上書きする（--check が成功・コミット済みの内容と同じ・HEAD は変わらない = コミット・push しない）→
#         雛形にあるファイルの --remove は、拒否される → 雛形にない不要なファイル（e2e-obsolete.yml）は、案内に出て、--remove で消せる
#   書き込み: クローンの .github/workflows だけ（終了時に、HEAD の状態へ戻す）。GitHub・組織へは、書き込まない
#   前提: 管理者用のクローンがある・環境ブランチ（main / staging / develop）の上ではない・作業ツリーがきれい
#   E2E_SF_SYNC_WF: 実行する sf-sync-wf.sh を差し替える（テスト用）
scn_sync_wf() {
    local work="${E2E_HOME_ROOT}/${E2E_OWNER}/${PROJECT}" clone head0 branch0 wfdir=".github/workflows" target="wf-validate.yml"
    local syncwf="${E2E_SF_SYNC_WF:-${SF_TOOLS_ROOT}/bin/sf-sync-wf.sh}"
    clone="${work}/admin/${REPO_NAME}"
    [[ -d "${clone}/.git" ]] || { SCN_SKIP="管理者用のクローン（${clone}）がありません（run.sh が作ります）"; return; }
    [[ -f "${clone}/${wfdir}/${target}" ]] || { SCN_SKIP="${wfdir}/${target} が、クローンにありません"; return; }
    branch0=$(git -C "$clone" symbolic-ref --short HEAD 2>/dev/null) || branch0=""  # VAR=$(cmd) のため run 不使用
    case "$branch0" in
        ""|main|staging|develop) SCN_SKIP="クローンのブランチが、環境ブランチ（または、ブランチの上ではない）です（${branch0:-なし}）。sf-sync-wf.sh は、環境ブランチでは動きません"; return ;;
    esac
    [[ -z "$(git -C "$clone" status --porcelain 2>/dev/null)" ]] || { SCN_SKIP="管理者用のクローンに、未コミットの変更があります（元に戻せなくなるため、実行しません）"; return; }  # VAR=$(cmd) のため run 不使用
    _scn_shims_prepare || { SCN_SKIP="一時フォルダの準備に失敗しました"; return; }   # e2e_run_sf_cmd が使う一時フォルダ（E2E_TMP）を用意する
    head0=$(git -C "$clone" rev-parse HEAD)  # VAR=$(cmd) のため run 不使用

    RESTORE_SYNCWF_CLONE="$clone"   # 改変する前に登録する（途中で止まっても、終了時に戻す）

    # --- 1. 改変なし: 差分なし ---
    e2e_run_sf_cmd "sf-sync-wf-base" "$clone" "" "$syncwf" --check; _chk "改変なしで、sf-sync-wf.sh --check が成功した（差分なし）" $?

    # --- 2. 改変 → --check が見つける ---
    printf '
# e2e: sync-wf の改変（雛形と違う）
' >> "${clone}/${wfdir}/${target}"  # run 不使用: 検証用の改変（クローンの中だけ。終了時に戻す）
    e2e_run_sf_cmd_refused "sf-sync-wf-drift" "$clone" "" "$syncwf" --check; _chk "改変したワークフローを、--check が見つけた（終了コード 0 以外）" $?
    grep -qF "$target" "${E2E_TMP}/sf-sync-wf-drift.out"; _chk "差分の表示に、改変したファイル名（${target}）が出た" $?

    # --- 3. 雛形の内容に直す（確認に Y。コミット・push はしない）---
    e2e_run_sf_cmd "sf-sync-wf-fix" "$clone" "Y
Y
" "$syncwf"; _chk "sf-sync-wf.sh が、雛形の内容で上書きした" $?
    e2e_run_sf_cmd "sf-sync-wf-recheck" "$clone" "" "$syncwf" --check; _chk "上書きのあと、--check が成功した（差分なし）" $?
    git -C "$clone" diff --quiet -- "${wfdir}/${target}"; _chk "改変が消え、コミット済みの内容と同じに戻った" $?
    _chk "コミットしていない（HEAD が変わらない）" "$([[ "$(git -C "$clone" rev-parse HEAD)" == "$head0" ]] && echo 0 || echo 1)"

    # --- 4. --remove: 雛形にあるファイルは拒否され、雛形にないファイルだけ消せる ---
    e2e_run_sf_cmd_refused "sf-sync-wf-remove-tpl" "$clone" "Y
Y
Y
" "$syncwf" --remove "$target"; _chk "雛形にあるワークフローの --remove は、拒否された" $?
    _chk "拒否されたファイルは、残っている" "$([[ -f "${clone}/${wfdir}/${target}" ]] && echo 0 || echo 1)"
    printf 'name: e2e obsolete
on: workflow_dispatch
jobs: {}
' > "${clone}/${wfdir}/${SCN_OBSOLETE_WF}"  # run 不使用: 検証用の不要なファイル（雛形にない。終了時に消す）
    e2e_run_sf_cmd "sf-sync-wf-extra" "$clone" "" "$syncwf" --check
    grep -qF "$SCN_OBSOLETE_WF" "${E2E_TMP}/sf-sync-wf-extra.out"; _chk "雛形にないワークフロー（${SCN_OBSOLETE_WF}）が、案内に出た" $?
    e2e_run_sf_cmd "sf-sync-wf-remove-extra" "$clone" "Y
Y
Y
" "$syncwf" --remove "$SCN_OBSOLETE_WF"; _chk "雛形にないワークフローを、--remove で削除した" $?
    _chk "削除されて、ファイルがない" "$([[ ! -e "${clone}/${wfdir}/${SCN_OBSOLETE_WF}" ]] && echo 0 || echo 1)"
    _chk "作業ツリーが、きれいに戻っている（コミット・push はしていない）" "$([[ -z "$(git -C "$clone" status --porcelain)" ]] && echo 0 || echo 1)"
}

# update-secret: sf-update-secret.sh（B2）。管理者用のクローンから、「1) 秘密鍵」を、sf-init が作った同じ秘密鍵で実行する
#   確認: Secret SF_PRIVATE_KEY の更新日時（updated_at）が進む・Secret の名前の一覧は変わらない・出力に、秘密鍵の中身（PEM の見出し）が出ない・
#         存在しない鍵のパスを渡すと、拒否され（終了コード 0 以外）、更新日時は変わらない
#   書き込み: Secret SF_PRIVATE_KEY を、同じ値で上書きする（値は変わらない。元に戻す必要がない）
#   前提: 管理者用のクローンがある・秘密鍵（~/.sf-jwt/force-XXXX/server.key）がある・Secret SF_PRIVATE_KEY がある
#   E2E_SF_UPDATE_SECRET: 実行する sf-update-secret.sh を差し替える（テスト用）
_scn_secret_updated_at() {   # 引数: Secret の名前。更新日時（ISO 8601）を返す。取得できなければ、戻り値 1
    _e2e_gh api "repos/${REPO_FULL}/actions/secrets/$1" --jq .updated_at 2>/dev/null | tr -d '[:space:]'  # パイプのみのため run 不使用
    return "${PIPESTATUS[0]}"
}
scn_update_secret() {
    local work="${E2E_HOME_ROOT}/${E2E_OWNER}/${PROJECT}" clone key before after names_before names_after
    local upd="${E2E_SF_UPDATE_SECRET:-${SF_TOOLS_ROOT}/bin/sf-update-secret.sh}"
    clone="${work}/admin/${REPO_NAME}"
    key="${HOME}/.sf-jwt/${REPO_NAME}/server.key"
    [[ -d "${clone}/.git" ]] || { SCN_SKIP="管理者用のクローン（${clone}）がありません（run.sh が作ります）"; return; }
    [[ -f "$key" ]] || { SCN_SKIP="秘密鍵（${key}）がありません（sf-init が作るものです）"; return; }
    before=$(_scn_secret_updated_at SF_PRIVATE_KEY) && [[ -n "$before" ]] || { SCN_SKIP="Secret SF_PRIVATE_KEY の更新日時を取得できません（Secret がありません）"; return; }  # VAR=$(cmd) のため run 不使用
    names_before=$(_scn_names secret) || { SCN_SKIP="Secret の一覧を取得できません"; return; }  # VAR=$(cmd) のため run 不使用
    _scn_shims_prepare || { SCN_SKIP="一時フォルダの準備に失敗しました"; return; }   # e2e_run_sf_cmd が使う一時フォルダ（E2E_TMP）を用意する

    # --- 存在しないパス: 拒否され、更新されない ---
    e2e_run_sf_cmd_refused "sf-update-secret-badpath" "$clone" "Y
1
${work}/no-such-dir/server.key
" "$upd"; _chk "存在しない鍵のパスは、拒否された（終了コード 0 以外）" $?
    after=$(_scn_secret_updated_at SF_PRIVATE_KEY) || after=""  # VAR=$(cmd) のため run 不使用
    _chk "拒否されたとき、SF_PRIVATE_KEY は更新されていない" "$([[ "$after" == "$before" ]] && echo 0 || echo 1)"

    # --- 同じ秘密鍵で上書き: 更新日時が進む（更新日時は、秒の単位のため、少し待ってから行う）---
    sleep "${E2E_SECRET_WAIT:-2}"  # run 不使用: 待機（更新日時が、同じ秒にならないように）
    e2e_run_sf_cmd "sf-update-secret-key" "$clone" "Y
1
${key}
Y
" "$upd"; _chk "sf-update-secret.sh で、秘密鍵を、同じ鍵で上書きした" $?
    after=$(_scn_secret_updated_at SF_PRIVATE_KEY) || after=""  # VAR=$(cmd) のため run 不使用
    _chk "SF_PRIVATE_KEY の更新日時が、進んだ（${before} → ${after:-取得できません}）" "$([[ -n "$after" && "$after" > "$before" ]] && echo 0 || echo 1)"
    names_after=$(_scn_names secret) || names_after=""  # VAR=$(cmd) のため run 不使用
    _chk "Secret の名前の一覧は、変わらない（ほかの Secret を、触っていない）" "$([[ "$names_after" == "$names_before" ]] && echo 0 || echo 1)"
    if grep -q "BEGIN" "${E2E_TMP}/sf-update-secret-key.out"; then
        _chk "出力に、秘密鍵の中身（PEM の見出し）が出ていない" 1
    else
        _chk "出力に、秘密鍵の中身（PEM の見出し）が出ていない" 0
    fi
}

# cross-os: OS 混在の問題（C2）を確認する。リポジトリを、GitHub から、一時フォルダに clone して、読み取りと、手元の確認だけを行う
#   確認: 記録された（git のインデックスの）テキストファイルに、CRLF がない（Windows で作ったファイルの改行が、別の OS で壊れない）→
#         sf-hook.sh で入れたフック（pre-commit・pre-push）が、sf-tools の hooks/ と同じ内容で、CR がなく、実行できる →
#         作業用のブランチ（手元だけ）で、sf-sync-wf.sh --check が成功する（ワークフローが、雛形と同じ）
#   書き込み: 一時フォルダの中だけ（終了時に削除する）。GitHub・組織へは、書き込まない。作業用のブランチは、push しない
#   使い方: リポジトリを作った OS とは別の OS で動かすと、OS 混在の確認になる（--repo で、別の OS が作ったリポジトリを指定する）
#   E2E_SF_HOOK / E2E_SF_SYNC_WF: 実行する sf-hook.sh / sf-sync-wf.sh を差し替える（テスト用）。E2E_SF_HOOKS_DIR: フックの元のフォルダ（既定は ~/sf-tools/hooks）
scn_cross_os() {
    local tmp base clone branch h os n eol_bad
    local hook_cmd="${E2E_SF_HOOK:-${SF_TOOLS_ROOT}/bin/sf-hook.sh}" syncwf="${E2E_SF_SYNC_WF:-${SF_TOOLS_ROOT}/bin/sf-sync-wf.sh}"
    local hooks_src="${E2E_SF_HOOKS_DIR:-${HOME}/sf-tools/hooks}"
    os=$(uname -s)  # VAR=$(cmd) のため run 不使用
    log "INFO" "  この確認を動かす OS: ${os}（リポジトリを作った OS とは別の OS で動かすと、OS 混在の確認になります）"
    # e2e_run_sf_cmd は、{E2E_HOME_ROOT}/{オーナー}/e2e-* の下でしか動かないため、その下に作る（名前は e2e-xos.XXXXXX。最新の作業フォルダの検索には、ひっかからない）
    base="${E2E_HOME_ROOT}/${E2E_OWNER}"
    mkdir -p "$base" || { SCN_SKIP="作業フォルダの置き場を作成できません"; return; }  # run 不使用: テスト用の置き場（固定の場所）
    tmp=$(mktemp -d "${base}/e2e-xos.XXXXXX") || { SCN_SKIP="一時フォルダを作成できません"; return; }  # VAR=$(cmd) のため run 不使用
    RESTORE_XOS_DIR="$tmp"   # clone する前に登録する（途中で止まっても、終了時に削除する）
    clone="${tmp}/${REPO_NAME}"
    _scn_shims_prepare || { SCN_SKIP="一時フォルダの準備に失敗しました"; return; }   # e2e_run_sf_cmd が使う一時フォルダ（E2E_TMP）を用意する
    # core.longpaths=true: 通常の運用（sf-job.sh・sf-init）と同じ。Windows のパスの長さの上限（260 文字）対策（組織に長い名前のレイアウトなどがあると、チェックアウトで失敗する）。
    #   失敗したときの原因は、出力のファイルに残し、末尾を表示する（以前は捨てていて、原因が見えなかった）
    if ! _e2e_gh repo clone "$REPO_FULL" "$clone" -- -c core.longpaths=true --quiet > "${E2E_TMP}/xos-clone.out" 2>&1; then  # 戻り値で判定するため run 不使用
        e2e_show_file_tail "${E2E_TMP}/xos-clone.out" "xos-clone"
        SCN_SKIP="リポジトリを clone できません（${REPO_FULL}）"; return
    fi
    branch="e2e-xos-$(date +%H%M%S)"
    git -C "$clone" checkout -q -b "$branch" >/dev/null 2>&1 \
        || { SCN_SKIP="作業用のブランチを作れません（clone したリポジトリが、空かもしれません）"; return; }  # 手元だけのブランチ（push しない）。環境ブランチの上では、sf-sync-wf が動かないため

    # --- 1. 記録されたテキストファイルに、CRLF がない（インデックスの改行。作業ツリーは、OS・設定で変わるため、見ない）---
    n=$(git -C "$clone" ls-files --eol 2>/dev/null | awk -F'\t' '{ split($1, a, " "); if (a[1] == "i/lf") c++ } END { print c + 0 }')  # VAR=$(cmd) のため run 不使用
    eol_bad=$(git -C "$clone" ls-files --eol 2>/dev/null | awk -F'\t' '{ split($1, a, " "); if (a[1] ~ /^i\/(crlf|mixed)$/) print $2 }')  # VAR=$(cmd) のため run 不使用
    _chk "記録されたテキストファイル（${n} 件）に、CRLF（または、混在）がない" "$([[ -z "$eol_bad" ]] && echo 0 || echo 1)" "CRLF のファイル: $(printf '%s\n' "$eol_bad" | head -5 | tr '\n' ' ')"
    _chk "確認できるテキストファイルがある（0 件ではない）" "$([[ "$n" -gt 0 ]] && echo 0 || echo 1)"

    # --- 2. フック: sf-hook.sh で入れる → 同じ内容・CR がない・実行できる ---
    e2e_run_sf_cmd "xos-hook" "$clone" "" "$hook_cmd"; _chk "sf-hook.sh で、フックを入れた" $?
    for h in pre-commit pre-push; do
        cmp -s "${hooks_src}/${h}" "${clone}/.git/hooks/${h}"; _chk "フック ${h} が、sf-tools の hooks/${h} と同じ内容である" $?
        if grep -q $'\r' "${clone}/.git/hooks/${h}" 2>/dev/null; then
            _chk "フック ${h} に、CR がない" 1
        else
            _chk "フック ${h} に、CR がない" 0
        fi
        if e2e_is_windows; then
            :   # Windows（Git Bash）は、ファイルの実行権限を、同じようには判定できないため、確認しない
        else
            [[ -x "${clone}/.git/hooks/${h}" ]]; _chk "フック ${h} が、実行できる" $?
        fi
    done

    # --- 3. ワークフローが、雛形と同じ（作業用のブランチの上で）---
    e2e_run_sf_cmd "xos-sync" "$clone" "" "$syncwf" --check; _chk "sf-sync-wf.sh --check が成功した（ワークフローが、雛形と同じ）" $?

    rm -rf "$tmp"  # run 不使用: 一時フォルダの後始末（この関数が作る、決まった名前のフォルダだけ）
    RESTORE_XOS_DIR=""
}

# ------------------------------------------------------------------------------
# 5. 実行
# ------------------------------------------------------------------------------
STATE_BEFORE=$(_scn_state) || die "実行前の状態（main の SHA・ブランチ・PR）を取得できないため、中断します。"  # VAR=$(cmd) のため run 不使用
FAILED_ANY=0
SUMMARY=()
for name in "${SELECTED[@]}"; do
    log "HEADER" "シナリオ: ${name}（$(_scn_desc "$name")）"
    SCN_PASS=0; SCN_FAIL=0; SCN_SKIP=""; SCN_ALLOW_MAIN_COMMITS=0
    t0=$SECONDS
    "scn_${name//-/_}"
    secs=$(( SECONDS - t0 ))
    if [[ -n "$SCN_SKIP" ]]; then
        result="実行できない（${SCN_SKIP}）"; FAILED_ANY=1
    elif [[ $SCN_FAIL -gt 0 ]]; then
        result="失敗（${SCN_PASS} 件成功 / ${SCN_FAIL} 件失敗）"; FAILED_ANY=1
    elif [[ $SCN_PASS -eq 0 ]]; then
        result="失敗（確認が 0 件。何も検査していません）"; FAILED_ANY=1
    else
        result="成功（${SCN_PASS} 件）"
    fi
    SUMMARY+=("${name}: ${result} — ${secs} 秒")

    # 状態の確認: シナリオが、リポジトリの状態を変えていないこと。差があれば、後続を実行しない
    STATE_AFTER=$(_scn_state) || STATE_AFTER="取得できません"  # VAR=$(cmd) のため run 不使用
    _cmp_before="$STATE_BEFORE"; _cmp_after="$STATE_AFTER"
    if [[ $SCN_ALLOW_MAIN_COMMITS -eq 1 ]]; then   # main のコミットが増えてよいシナリオ: main の SHA を、比べない（ブランチ・PR は、比べる）
        _cmp_before=$(printf '%s\n' "$STATE_BEFORE" | grep -v '^main=')  # パイプのみのため run 不使用
        _cmp_after=$(printf '%s\n' "$STATE_AFTER" | grep -v '^main=')  # パイプのみのため run 不使用
    fi
    if [[ "$_cmp_after" != "$_cmp_before" ]]; then
        log "ERROR" "シナリオ ${name} の前後で、リポジトリの状態（main の SHA・ブランチ・PR の数）が変わりました。後続のシナリオは、実行しません。"
        log "ERROR" "  前: $(printf '%s' "$STATE_BEFORE" | tr '\n' ' ')"
        log "ERROR" "  後: $(printf '%s' "$STATE_AFTER" | tr '\n' ' ')"
        FAILED_ANY=1
        SUMMARY+=("（状態が変わったため、以降のシナリオは実行していません）")
        break
    fi
    # main にコミットしてよいシナリオのあとは、main の基準を、いまの状態に更新する（続くシナリオが、前のシナリオのコミットを、変化と見なさないため。
    #   ブランチ・PR は、上で比べて、同じと確かめ済み）
    [[ $SCN_ALLOW_MAIN_COMMITS -eq 1 ]] && STATE_BEFORE="$STATE_AFTER"
done

# ------------------------------------------------------------------------------
# 6. 結果
# ------------------------------------------------------------------------------
echo "" >&2
log "HEADER" "結果（${REPO_FULL}）"
for line in "${SUMMARY[@]}"; do log "INFO" "  ${line}"; done
if [[ $FAILED_ANY -eq 0 ]]; then
    log "SUCCESS" "e2e のシナリオ: すべて成功しました。"
    log "INFO" "検証の記録（成功したときだけ、doc/dev-reference.md 9.7 の表に追記する）:"
    e2e_record_line "e2e シナリオ ${SELECTED[*]} が成功"
    exit $RET_OK
fi
die "e2e のシナリオ: 失敗、または実行できないものがあります。"
