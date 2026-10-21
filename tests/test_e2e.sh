#!/bin/bash
# ==============================================================================
# test_e2e.sh - tests/e2e/（実環境での sf-init 通し検証）の安全ガードと部品のテスト
# ==============================================================================
# 実際の GitHub / Salesforce には接続しない（gh / sf はモック）。
# e2e 本体（run.sh）は実環境を使うため、通常のテストには含めない。ここでは、
# 「消してはいけないものを消さない」ことを中心に確認する。
#
# 【テストケース】
#   1. 名前の判定（削除対象かどうか）
#   2. ガード（GitHub Actions 上は、専用ワークフロー e2e.yml だけ通る。gh ユーザー不一致では動かない）
#   3. 削除関数は、ガードを通らない・対象外の名前なら動かない
#   4. 鍵一式の読み込み（未設定・権限）
#   5. cleanup.sh の既定（一覧のみ。何も削除しない）
#   6. cleanup.sh --yes（対象だけを削除し、他は残す）
#   7. cleanup.sh の確認（N・delete 以外の入力で中止）
#   8. sf の差し替え（login web だけを置き換え、他はそのまま渡す）
#   9. sf のエイリアスの保存・復元
#  10. sf-init に流す入力の台本
#  11. run.sh のガード（GitHub Actions 上・鍵一式なしでは動かない）
#  15. 一覧の取得に失敗したとき（再試行・「対象なし」と取り違えない）
#  16. ローカルの削除の補強（想定外の中身・シンボリックリンクは消さない）
#  17. Hello World の Apex（名前の判定・一覧・件数・削除・後掃除）
#  18. GitHub の PR を使った流れ（ブランチ・ファイル・PR・マージ・Actions の待ち）
#  19. sf-tools のコマンドの実行（sf-job.sh / sf-push.sh など）と、code の差し替え
#  20. doctor.sh（e2e を動かせる環境かの確認。秘密の値を出さない）
#  21. 検証の記録（e2e の最後に表示する、表の 1 行）
#  22. ブラウザの差し替え（OS ごとの open_browser が使うコマンドを、すべて差し替える）
#  23. wf-sequence の確認の部品（PR を閉じる・コメントの確認・動き出した検証の取り消し）
#  24. シナリオ方式（scenario.sh。読み取りのみ・状態の確認・ガード）と、秘密情報の検査（e2e_scan_secrets）
#  25. シナリオ manual-delete（Secret・Variable の削除 → 検出 → 元に戻す。終了時に必ず戻す）
#  26. シナリオ validate-fail（壊れた Apex の PR → wf-validate が失敗 → 直すと成功。マージしない・必ず後始末する）
#  27. シナリオ dist-main（配布版 = SF_TOOLS_BRANCH 未設定で、sf-tools の main が使われる。rr の直後だけ）
#  28. シナリオ metasync-diff（組織側だけの Apex が、wf-metasync で main に反映される。組織と main を、必ず戻す）
#  29. 中断→再開（run.sh --interrupt）と、git の shim（main への push を 1 回だけ失敗させる）
#  30. シナリオ propagate-fail（main → staging の伝播のコンフリクト。失敗し、通知され、staging は変わらない）
#  31. シナリオ restart-org（sf-restart で接続先を staging の組織に切り替え → dry-run → 元に戻す）
#  33. シナリオ sync-wf（改変したワークフローを sf-sync-wf が見つけて直す・--remove は雛形にあるファイルを拒否・クローンの中だけ）
#  34. シナリオ update-secret（sf-update-secret で秘密鍵を同じ鍵で上書き・更新日時が進む・誤ったパスは拒否される）
#  35. シナリオ cross-os（別の OS が作ったリポジトリの確認: CRLF がない・フックが同じ内容で実行できる・sf-sync-wf --check が成功する。読み取りのみ）
#  32. GitHub Actions で動かす準備（ci-fixture.sh が鍵一式を作る・e2e.yml とガードの整合。ガードは 2 で、Actions 上でも専用ワークフローだけ通る）
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== tests/e2e（安全ガードと部品）===${CLR_RST}"

E2E_DIR="$SF_TOOLS_DIR/tests/e2e"

# ------------------------------------------------------------------------------
# ヘルパー: モックの gh / sf
# ------------------------------------------------------------------------------
_mk_mocks() {
    local mb="$1"
    create_mock_node "$mb"   # json_get が使う node（-e だけ本物へ渡す。WSL には node がなく node.exe だけがある）
    cat > "$mb/gh" << 'EOF'
#!/bin/bash
echo "gh $*" >> "${MOCK_CALL_LOG:-/dev/null}"
# PR を使った流れの再現（ブランチ作成・ファイル追加・PR・Actions の実行）
case "$*" in
    # シナリオ（scenario.sh）の読み取り: 実行の一覧（MOCK_GH_RUN_IDS）・ログ（MOCK_GH_RUN_LOG）・PR の一覧（MOCK_GH_PR_NUMBERS）・PR の本文とコメント（MOCK_GH_PR_BODY）
    #   main の SHA（MOCK_GH_MAIN_SHA。MOCK_GH_MAIN_SHA_CHANGE=1: 2 回目以降は、別の値を返す）・ブランチ・PR の数
    "run list -R "*" --limit "[0-9]*" --json databaseId --jq .[].databaseId")  [[ "${MOCK_GH_RUN_LIST_EXIT:-0}" -ne 0 ]] && exit "$MOCK_GH_RUN_LIST_EXIT"; for _i in ${MOCK_GH_RUN_IDS:-}; do echo "$_i"; done; exit 0 ;;
    "run view"*" --log")                 printf '%s\n' "${MOCK_GH_RUN_LOG:-}"; exit 0 ;;
    "pr list"*"--jq length")             echo "${MOCK_GH_PR_COUNT:-3}"; exit 0 ;;
    "pr list"*"--jq .[].number")         for _i in ${MOCK_GH_PR_NUMBERS:-}; do echo "$_i"; done; exit 0 ;;
    "pr view"*"--json body,comments"*)   printf '%s\n' "${MOCK_GH_PR_BODY:-}"; exit 0 ;;
    "api repos/"*"/git/ref/heads/main"*)
        _d="${MOCK_CALL_LOG%/*}"
        _n=$(( $(cat "$_d/mainsha.cnt" 2>/dev/null || echo 0) + 1 )); echo "$_n" > "$_d/mainsha.cnt"
        if [[ "${MOCK_GH_MAIN_SHA_CHANGE:-}" == "1" && $_n -ge 2 ]]; then echo "changedsha"; else echo "${MOCK_GH_MAIN_SHA:-abc123}"; fi
        exit 0 ;;
    # update-secret の再現: SF_PRIVATE_KEY の更新日時は、secret set SF_PRIVATE_KEY のたびに、1 秒ずつ進む（$MB/pk.ver。MOCK_GH_NO_PK=1: Secret がない）
    "api repos/"*"/actions/secrets/SF_PRIVATE_KEY"*)
        [[ "${MOCK_GH_NO_PK:-}" == "1" ]] && exit 1
        echo "2026-10-21T00:00:0$(cat "${MOCK_CALL_LOG%/*}/pk.ver" 2>/dev/null || echo 0)Z"; exit 0 ;;
    "api repos/"*"/branches"*)           printf 'main\nadmin\n'; exit 0 ;;
    # Secret・Variable の状態（manual-delete の再現）: $MB/secrets.txt（名前の行）・$MB/vars.txt（「名前=値」の行）。ファイルがなければ、空
    #   MOCK_GH_SECRET_SET_FAIL_FIRST=1: secret set の 1 回目が失敗する（元に戻す処理の失敗と、終了時の再試行の再現）
    "secret list"*"--jq .[].name")       cat "${MOCK_CALL_LOG%/*}/secrets.txt" 2>/dev/null; exit 0 ;;
    "secret delete "*)                   _d="${MOCK_CALL_LOG%/*}"; grep -vx "$3" "$_d/secrets.txt" > "$_d/secrets.new" 2>/dev/null; mv "$_d/secrets.new" "$_d/secrets.txt"; exit 0 ;;
    "secret set "*)
        _d="${MOCK_CALL_LOG%/*}"; cat > "$_d/secretval.$3"   # 標準入力で渡された値を記録する（空で設定されたかを、確かめるため）
        if [[ "${MOCK_GH_SECRET_SET_FAIL_FIRST:-}" == "1" && ! -f "$_d/secretset.failed" ]]; then : > "$_d/secretset.failed"; echo "HTTP 502" >&2; exit 1; fi
        if [[ "$3" == "SF_PRIVATE_KEY" ]]; then echo $(( $(cat "$_d/pk.ver" 2>/dev/null || echo 0) + 1 )) > "$_d/pk.ver"; grep -qx "$3" "$_d/secrets.txt" 2>/dev/null || echo "$3" >> "$_d/secrets.txt"; exit 0; fi
        echo "$3" >> "$_d/secrets.txt"; exit 0 ;;
    "variable list"*"--jq .[].name")     cut -d= -f1 "${MOCK_CALL_LOG%/*}/vars.txt" 2>/dev/null; exit 0 ;;
    "variable get "*)                    grep "^$3=" "${MOCK_CALL_LOG%/*}/vars.txt" 2>/dev/null | head -1 | cut -d= -f2-; exit 0 ;;
    "variable delete "*)                 _d="${MOCK_CALL_LOG%/*}"; grep -v "^$3=" "$_d/vars.txt" > "$_d/vars.new" 2>/dev/null; mv "$_d/vars.new" "$_d/vars.txt"; exit 0 ;;
    "variable set "*)                    _d="${MOCK_CALL_LOG%/*}"; echo "$3=${@: -1}" >> "$_d/vars.txt"; exit 0 ;;
    # metasync-diff の再現: wf-metasync を起動すると、組織に Apex があれば（MOCK_GH_METASYNC_REFLECT=1）、main に Hello World のファイルが反映される
    #   main のファイルは $MB/mainfiles.txt（1 行 1 パス）。contents の取得（?ref=main）は、あれば 0・なければ 1。削除（-X DELETE）で、行を消す
    "workflow run wf-metasync.yml"*)
        _d="${MOCK_CALL_LOG%/*}"
        if [[ "${MOCK_GH_METASYNC_REFLECT:-}" == "1" && -s "$_d/apex_created.txt" ]]; then
            for _f in SfToolsE2eHello.cls SfToolsE2eHello.cls-meta.xml SfToolsE2eHelloTest.cls SfToolsE2eHelloTest.cls-meta.xml; do
                echo "force-app/main/default/classes/$_f" >> "$_d/mainfiles.txt"
            done
        fi
        exit "${MOCK_GH_WORKFLOW_EXIT:-0}" ;;
    "api -H Accept: application/vnd.github.raw repos/"*"/contents/"*) printf 'public class SfToolsE2eHello { return Hello, World!; }\n'; exit 0 ;;
    "api repos/"*"/contents/"*"?ref=main"*)
        _p="${2#repos/*/contents/}"; _p="${_p%%\?*}"
        grep -qxF "$_p" "${MOCK_CALL_LOG%/*}/mainfiles.txt" 2>/dev/null && { echo "sha-$_p"; exit 0; }
        exit 1 ;;
    # propagate-fail の再現: staging ブランチ（先頭の SHA。MOCK_GH_NO_STAGING=1: なし / MOCK_GH_STAGING_MOVE=1: 3 回目以降は、別の SHA）と、そのファイル（$MB/stagingfiles.txt）
    "api repos/"*"/git/ref/heads/staging"*)
        [[ "${MOCK_GH_NO_STAGING:-}" == "1" ]] && exit 1
        _d="${MOCK_CALL_LOG%/*}"
        _n=$(( $(cat "$_d/stg.cnt" 2>/dev/null || echo 0) + 1 )); echo "$_n" > "$_d/stg.cnt"
        if [[ "${MOCK_GH_STAGING_MOVE:-}" == "1" && $_n -ge 3 ]]; then echo "stgsha-moved"; else echo "stgsha-1"; fi
        exit 0 ;;
    "api repos/"*"/contents/"*"?ref=staging"*)
        _p="${2#repos/*/contents/}"; _p="${_p%%\?*}"
        grep -qxF "$_p" "${MOCK_CALL_LOG%/*}/stagingfiles.txt" 2>/dev/null && { echo "sha-$_p"; exit 0; }
        exit 1 ;;
    "api -X PUT repos/"*"/contents/"*"branch=staging"*)
        _d="${MOCK_CALL_LOG%/*}"; cat > /dev/null; _p="${4#repos/*/contents/}"; echo "$_p" >> "$_d/stagingfiles.txt"; exit 0 ;;
    "api -X PUT repos/"*"/contents/"*"branch=main"*)
        _d="${MOCK_CALL_LOG%/*}"; cat > /dev/null; _p="${4#repos/*/contents/}"; echo "$_p" >> "$_d/mainfiles.txt"; exit 0 ;;
    "api -X DELETE repos/"*"/contents/"*)
        _d="${MOCK_CALL_LOG%/*}"; _p="${4#repos/*/contents/}"; _lf="$_d/mainfiles.txt"
        [[ "$*" == *"branch=staging"* ]] && _lf="$_d/stagingfiles.txt"
        grep -vxF "$_p" "$_lf" > "$_lf.new" 2>/dev/null; mv "$_lf.new" "$_lf"; exit 0 ;;
    "pr create"*)                        [[ "${MOCK_GH_PR_EXIT:-0}" -ne 0 ]] && exit "$MOCK_GH_PR_EXIT"; echo "https://github.com/tamashimon-org/force-e2e-20260101-000000/pull/${MOCK_GH_PR_NUMBER:-7}"; exit 0 ;;
    "pr merge"*)                         exit "${MOCK_GH_MERGE_EXIT:-0}" ;;
    # 手動起動（gh workflow run / 起動した実行の ID）。MOCK_GH_WORKFLOW_EXIT=1: 起動の呼び出しが失敗する
    #   起動した実行の ID: 最初の問い合わせ（起動の前）は MOCK_GH_DISPATCH_BEFORE（既定 100）、以後は MOCK_GH_DISPATCH_AFTER（既定 101）
    "workflow run"*)                     exit "${MOCK_GH_WORKFLOW_EXIT:-0}" ;;
    "run list"*"--event workflow_dispatch"*)
        _d="${MOCK_CALL_LOG%/*}"
        _n=$(( $(cat "$_d/disp.cnt" 2>/dev/null || echo 0) + 1 )); echo "$_n" > "$_d/disp.cnt"
        if [[ $_n -eq 1 ]]; then echo "${MOCK_GH_DISPATCH_BEFORE:-100}"; else echo "${MOCK_GH_DISPATCH_AFTER:-101}"; fi
        exit 0 ;;
    # PR のイベントの実行の ID（validate-fail の再現）。MOCK_GH_RUN_SEQ=1: 呼び出しごとに 100・200・200・300… と増える（基準より新しい実行が、見える）
    #   未設定のときは、従来どおり（MOCK_GH_RUN_NONE=1: 実行なし / MOCK_GH_RUN_ID: 固定の ID）
    "run list"*"--event pull_request"*"--limit 1"*)
        if [[ "${MOCK_GH_RUN_SEQ:-}" == "1" ]]; then
            _d="${MOCK_CALL_LOG%/*}"
            _n=$(( $(cat "$_d/prrun.cnt" 2>/dev/null || echo 0) + 1 )); echo "$_n" > "$_d/prrun.cnt"
            echo $(( 100 * (1 + _n / 2) )); exit 0
        fi
        [[ "${MOCK_GH_RUN_NONE:-}" == "1" ]] && exit 0; echo "${MOCK_GH_RUN_ID:-555}"; exit 0 ;;
    # 動いている（待ち・実行中の）実行の一覧（e2e_cancel_pr_runs）: MOCK_GH_ACTIVE_RUNS に、空白区切りの ID を入れる
    "run list"*"--status"*)              for _i in ${MOCK_GH_ACTIVE_RUNS:-}; do echo "$_i"; done; exit 0 ;;
    "run list"*)                         [[ "${MOCK_GH_RUN_NONE:-}" == "1" ]] && exit 0; echo "${MOCK_GH_RUN_ID:-555}"; exit 0 ;;
    "run cancel"*)                       exit "${MOCK_GH_CANCEL_EXIT:-0}" ;;
    # PR の会話欄のコメント（MOCK_GH_PR_COMMENTS: 本文。MOCK_GH_PR_VIEW_EXIT=1: 取得に失敗する）
    "pr view"*"--json comments"*)        [[ "${MOCK_GH_PR_VIEW_EXIT:-0}" -ne 0 ]] && exit "$MOCK_GH_PR_VIEW_EXIT"; printf '%s\n' "${MOCK_GH_PR_COMMENTS:-}"; exit 0 ;;
    "pr close"*)                         exit "${MOCK_GH_PR_CLOSE_EXIT:-0}" ;;
    # 失敗したステップのログ（形式: ジョブ名 TAB ステップ名 TAB 時刻 本文。色の指定と Token を含む）
    "run view"*"--log-failed"*)
        [[ "${MOCK_GH_LOG_NONE:-}" == "1" ]] && exit 0
        printf 'job1\tステップA\t2026-10-05T08:00:00.1Z \033[31mError\033[0m: 失敗の本文 ghp_fakepat\n'
        printf 'job1\tステップA\t2026-10-05T08:00:01.2Z 2 行目\n'
        exit 0 ;;
    # 再実行（gh run rerun）: 再実行したことを記録する。試行番号（attempt）は、再実行のあとで 2 になる
    #   MOCK_GH_RERUN_EXIT=1: 再実行の呼び出しが失敗する。MOCK_GH_ATTEMPT_STUCK=1: 試行番号が増えない（完了が見えない再現）
    "run rerun"*)
        [[ "${MOCK_GH_RERUN_EXIT:-0}" -ne 0 ]] && exit "$MOCK_GH_RERUN_EXIT"
        : > "${MOCK_CALL_LOG%/*}/rerun.flag"; exit 0 ;;
    "run view"*"--json attempt"*)
        if [[ -f "${MOCK_CALL_LOG%/*}/rerun.flag" && "${MOCK_GH_ATTEMPT_STUCK:-}" != "1" ]]; then echo 2; else echo 1; fi
        exit 0 ;;
    # 実行の結果（conclusion）/ ステップの結果。MOCK_GH_CONCL_EMPTY_FIRST=N: 最初の N 回は、空を返す（反映の遅れの再現）
    #   MOCK_GH_CONCL_AFTER: 再実行のあとの結果（既定は、再実行の前と同じ MOCK_GH_CONCL）
    "run view"*"--json conclusion"*|"run view"*"--json jobs"*)
        _d="${MOCK_CALL_LOG%/*}"
        _n=$(( $(cat "$_d/concl.cnt" 2>/dev/null || echo 0) + 1 )); echo "$_n" > "$_d/concl.cnt"
        [[ -n "${MOCK_GH_CONCL_EMPTY_FIRST:-}" && ( "$MOCK_GH_CONCL_EMPTY_FIRST" == "all" || $_n -le $MOCK_GH_CONCL_EMPTY_FIRST ) ]] && exit 0
        # MOCK_GH_CONCL_LIST: 空白区切りの結果を、呼び出しの順に返す（最後の値は、以後も返す）。失敗 → 成功の再現
        if [[ -n "${MOCK_GH_CONCL_LIST:-}" ]]; then set -- $MOCK_GH_CONCL_LIST; _i=$_n; (( _i > $# )) && _i=$#; echo "${!_i}"; exit 0; fi
        if [[ -f "$_d/rerun.flag" && -n "${MOCK_GH_CONCL_AFTER:-}" ]]; then echo "$MOCK_GH_CONCL_AFTER"; else echo "${MOCK_GH_CONCL:-success}"; fi
        exit 0 ;;
    "run view"*)                         echo "${MOCK_GH_RUN_STATUS:-completed}"; exit 0 ;;
esac
case "$1 $2" in
    "api user")    echo "${MOCK_GH_API_USER:-tamashimon}" ;;
    "repo list")
        # 一覧の取得失敗の再現（MOCK_GH_LIST_FAIL_FIRST=N: 最初の N 回は失敗。all なら、ずっと失敗）
        if [[ -n "${MOCK_GH_LIST_FAIL_FIRST:-}" ]]; then
            _d="${MOCK_CALL_LOG%/*}"
            _n=$(( $(cat "$_d/ghlist.cnt" 2>/dev/null || echo 0) + 1 )); echo "$_n" > "$_d/ghlist.cnt"
            if [[ "$MOCK_GH_LIST_FAIL_FIRST" == "all" || $_n -le $MOCK_GH_LIST_FAIL_FIRST ]]; then
                echo "error connecting to api.github.com" >&2; exit 1
            fi
        fi
        for n in ${MOCK_GH_REPOS:-}; do echo "$n"; done ;;
    "repo view")   exit "${MOCK_GH_REPO_VIEW_EXIT:-0}" ;;
    # clone（cross-os）: MOCK_GH_CLONE_SRC のリポジトリを、指定の場所（3 つ目の引数）に clone する。未設定なら、何もしない（clone できない再現）
    "repo clone")  [[ -n "${MOCK_GH_CLONE_SRC:-}" ]] && git clone -q "$MOCK_GH_CLONE_SRC" "$4"; exit 0 ;;
    "repo delete") exit 0 ;;
    *)             exit 0 ;;
esac
EOF
    cat > "$mb/sf" << 'EOF'
#!/bin/bash
echo "sf $*" >> "${MOCK_CALL_LOG:-/dev/null}"
_dir="${MOCK_CALL_LOG%/*}"
case "$1 $2" in
    "alias list")
        [[ "${MOCK_SF_ALIAS_FAIL:-}" == "1" ]] && { echo "error" >&2; exit 1; }
        echo '{'; echo '  "status": 0,'; echo '  "result": ['
        _first=1
        for kv in ${MOCK_SF_ALIASES:-}; do
            [[ $_first -eq 0 ]] && echo '    },'
            _first=0
            echo '    {'; echo "      \"alias\": \"${kv%%=*}\","; echo "      \"value\": \"${kv#*=}\""
        done
        [[ $_first -eq 0 ]] && echo '    }'
        echo '  ],'; echo '  "warnings": []'; echo '}' ;;
    "org display")
        # 管理用ログインの失敗の再現（MOCK_SF_ADMIN_FAIL_FIRST=N: sfdx-url のログインが N 回失敗する間は、未接続）
        if [[ -n "${MOCK_SF_ADMIN_FAIL_FIRST:-}" && "$*" == *"--target-org sf-tools-e2e-admin"* && ! -f "$_dir/admin_ok" ]]; then
            echo "Error: No authorization information found" >&2; exit 1
        fi
        # --verbose: 認証 URL を返す。新しい sf のように隠す（既定）か、MOCK_SF_DISPLAY_URL の値を返す
        if [[ "$*" == *"--verbose"* ]]; then
            echo "{\"status\":0,\"result\":{\"username\":\"admin@example.com\",\"sfdxAuthUrl\":\"${MOCK_SF_DISPLAY_URL:-[REDACTED] Use 'sf org auth show-sfdx-auth-url' to view}\"}}"
            exit 0
        fi
        _t=""; _pv=""; for _a in "$@"; do [[ "$_pv" == "--target-org" ]] && _t="$_a"; _pv="$_a"; done
        if [[ -n "$_t" && -f "$_dir/org_user.$_t" ]]; then
            echo "{\"status\":0,\"result\":{\"username\":\"$(cat "$_dir/org_user.$_t")\"}}"; exit 0
        fi
        echo '{"status":0,"result":{"username":"admin@example.com"}}' ;;
    "org auth")
        # sf org auth show-sfdx-auth-url（MOCK_SF_SHOW_URL=none で、使えない古い sf を再現）
        [[ "${MOCK_SF_SHOW_URL:-}" == "none" ]] && { echo "Error: command not found" >&2; exit 1; }
        echo "{\"status\":0,\"result\":{\"sfdxAuthUrl\":\"${MOCK_SF_SHOW_URL:-force://PlatformCLI::fakeshowtoken@example.my.salesforce.com}\"},\"warnings\":[\"exposes an SFDX Auth URL\"]}" ;;
    "org login")
        if [[ "$3" == "sfdx-url" ]]; then
            _t=""; _pv=""; for _a in "$@"; do [[ "$_pv" == "--alias" ]] && _t="$_a"; _pv="$_a"; done
            case "$_t" in "") ;; *STG) echo "stg@example.com" > "$_dir/org_user.$_t" ;; *) echo "main@example.com" > "$_dir/org_user.$_t" ;; esac
        fi
        # sfdx-url のログインを、最初の N 回だけ失敗させる（MOCK_SF_ADMIN_FAIL_FIRST=N。一時的な失敗・再試行の再現）
        if [[ "$3" == "sfdx-url" && -n "${MOCK_SF_ADMIN_FAIL_FIRST:-}" ]]; then
            _n=$(( $(cat "$_dir/login.cnt" 2>/dev/null || echo 0) + 1 )); echo "$_n" > "$_dir/login.cnt"
            if [[ $_n -le ${MOCK_SF_ADMIN_FAIL_FIRST} ]]; then
                echo "Error (RefreshTokenAuthError): Error authenticating with the refresh token due to:" >&2
                echo "force://PlatformCLI::secretrefreshtoken123@example.my.salesforce.com" >&2
                exit 1
            fi
            : > "$_dir/admin_ok"
        fi
        exit 0 ;;
    "org list")
        # 一覧の取得失敗の再現（MOCK_SF_LIST_FAIL_FIRST=N: 最初の N 回は失敗。all なら、ずっと失敗）
        if [[ -n "${MOCK_SF_LIST_FAIL_FIRST:-}" ]]; then
            _n=$(( $(cat "$_dir/sflist.cnt" 2>/dev/null || echo 0) + 1 )); echo "$_n" > "$_dir/sflist.cnt"
            if [[ "$MOCK_SF_LIST_FAIL_FIRST" == "all" || $_n -le $MOCK_SF_LIST_FAIL_FIRST ]]; then
                echo '{"status":1,"name":"Error","message":"connection reset"}'; exit 1
            fi
        fi
        echo '{'; echo '  "status": 0,'; echo '  "result": ['
        for n in ${MOCK_SF_ECAS:-}; do
            grep -qx "$n" "$_dir/deleted.txt" 2>/dev/null && continue
            echo "    { \"fullName\": \"$n\", \"type\": \"ExternalClientApplication\" },"
        done
        echo '  ]'; echo '}' ;;
    "data query")
        # Apex クラスの問い合わせの再現（MOCK_SF_APEX: 組織にあるクラス名。削除用デプロイで消えたものは除く）
        #   MOCK_SF_APEX_FAIL_FIRST=N: 最初の N 回は失敗（all なら、ずっと失敗）
        if [[ -n "${MOCK_SF_APEX_FAIL_FIRST:-}" ]]; then
            _n=$(( $(cat "$_dir/sfapex.cnt" 2>/dev/null || echo 0) + 1 )); echo "$_n" > "$_dir/sfapex.cnt"
            if [[ "$MOCK_SF_APEX_FAIL_FIRST" == "all" || $_n -le $MOCK_SF_APEX_FAIL_FIRST ]]; then
                echo '{"status":1,"name":"Error","message":"connection reset"}'; exit 1
            fi
        fi
        _names=""
        for n in ${MOCK_SF_APEX:-} $(cat "$_dir/apex_created.txt" 2>/dev/null); do
            grep -qx "$n" "$_dir/deleted.txt" 2>/dev/null && continue
            _names="$_names $n"
        done
        if [[ "$*" == *"COUNT()"* ]]; then
            _target=$(echo "$*" | grep -oE "Name = '[^']*'" | sed -E "s/Name = '(.*)'/\1/")
            _c=0; for n in $_names; do [[ "$n" == "$_target" ]] && _c=1; done
            echo "{\"status\":0,\"result\":{\"totalSize\":${_c},\"records\":[]}}"
        else
            echo '{"status":0,"result":{"records":['
            _f=1; for n in $_names; do [[ $_f -eq 0 ]] && echo ','; _f=0; echo "  {\"attributes\": {\"type\": \"ApexClass\"}, \"Name\": \"$n\"}"; done
            echo '],"totalSize":0}}'
        fi
        exit 0 ;;
    "project deploy")
        # 組織への直接のデプロイ（メタデータ API の形式。e2e_deploy_hello）: 作った Apex を記録する（MOCK_SF_DEPLOY_EXIT=1: 失敗）
        if [[ "$*" == *"--metadata-dir"* ]]; then
            [[ "${MOCK_SF_DEPLOY_EXIT:-0}" -ne 0 ]] && exit "$MOCK_SF_DEPLOY_EXIT"
            printf 'SfToolsE2eHello\nSfToolsE2eHelloTest\n' >> "$_dir/apex_created.txt"; exit 0
        fi
        if [[ -f destructiveChanges.xml ]]; then
            cat destructiveChanges.xml >> "${MOCK_CALL_LOG}"
            # 削除用のデプロイの失敗の再現（MOCK_SF_DEPLOY_EXIT=1: 失敗。アプリは消えない）
            [[ "${MOCK_SF_DEPLOY_EXIT:-0}" -ne 0 ]] && exit "$MOCK_SF_DEPLOY_EXIT"
            grep -oE '<members>[^<]*</members><name>ExternalClientApplication</name>' destructiveChanges.xml \
                | sed -E 's:<members>([^<]*)</members>.*:\1:' >> "$_dir/deleted.txt"
            # Apex クラスの削除: <name>ApexClass</name> のとき、<members> の名前をすべて記録する
            if grep -q '<name>ApexClass</name>' destructiveChanges.xml; then
                grep -oE '<members>[^<]*</members>' destructiveChanges.xml | sed -E 's:<members>([^<]*)</members>:\1:' >> "$_dir/deleted.txt"
            fi
        fi
        exit 0 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$mb/gh" "$mb/sf"
}

# 鍵一式のファイルを作る（引数: 出力先 [E2E_GH_USER]）
_mk_fixture() {
    local f="$1" ghu="${2:-tamashimon}"
    {
        echo "E2E_OWNER=tamashimon-org"
        echo "E2E_GH_USER=${ghu}"
        echo "E2E_HOME_ROOT=${3:-/tmp/none/home}"
        echo "E2E_PAT_TOKEN=ghp_fakepat"
        echo "E2E_SLACK_BOT_TOKEN=xoxb-fakeslack"
        echo "E2E_SLACK_CHANNEL_ID=C01ABCDEFGH"
        echo "E2E_SFDX_AUTH_URL=force://PlatformCLI::fakeurl@example.my.salesforce.com"
    } > "$f"
    chmod 600 "$f"
}

# e2e/lib.sh の関数を、モックの PATH で実行する。引数: 実行するシェルコード
# 事前に MB（モックのフォルダ）、FX（鍵一式）、HM（HOME）をセットしておくこと
_e2e_call() {
    (
        cd "$HM" || exit 1
        export HOME="$HM" PATH="$MB:$PATH" SF_INIT_MODE=1 E2E_FIXTURE="$FX"
        bash -c "
            readonly SCRIPT_NAME=test; readonly LOG_FILE=/dev/null; readonly LOG_MODE=NEW
            source '$SF_TOOLS_DIR/lib/common.sh'
            source '$E2E_DIR/lib.sh'
            $1
        "
    ) > "$MB/out.log" 2>&1
}

# ------------------------------------------------------------------------------
# 1. 名前の判定
# ------------------------------------------------------------------------------
test_e2e_names() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 名前の判定（削除対象かどうか）${CLR_RST}"
    local mb; mb=$(setup_mock_bin); MB="$mb"; FX="$mb/fx.env"; HM="$mb"
    _e2e_call '
        e2e_is_target_repo force-e2e-20261004-103000 || echo BAD1
        e2e_is_target_repo force-test-win            && echo BAD2
        e2e_is_target_repo force-e2e-abc             && echo BAD3
        e2e_is_target_repo force-e2e-20261004-1030   && echo BAD4
        e2e_is_target_repo xforce-e2e-20261004-103000 && echo BAD5
        e2e_is_target_repo "force-e2e-20261004-103000;rm" && echo BAD6
        e2e_is_target_eca SF_TOOLS_force_e2e_20261004_103000 || echo BAD7
        e2e_is_target_eca SF_TOOLS                    && echo BAD8
        e2e_is_target_eca SF_TOOLS_force_test_win     && echo BAD9
        e2e_is_target_eca SF_TOOLS_force_e2e_abc      && echo BAD10
        e2e_is_target_project e2e-20261004-103000 || echo BAD11
        e2e_is_target_project test-win               && echo BAD12
        e2e_is_target_jwt_dir force-e2e-20261004-103000 || echo BAD13
        e2e_is_target_jwt_dir force-test-win          && echo BAD14
        [[ "$(e2e_new_project_name)" =~ ^e2e-[0-9]{8}-[0-9]{6}$ ]] || echo BAD15
        e2e_is_target_tmp e2e-run.AbCdEf        || echo BAD21
        e2e_is_target_tmp e2e-sfdx-url.AbCdEf   || echo BAD22
        e2e_is_target_tmp e2e-eca-del.123456    || echo BAD23
        e2e_is_target_tmp e2e-run.AbC           && echo BAD24
        e2e_is_target_tmp e2e-run.AbCdEf1       && echo BAD25
        e2e_is_target_tmp other.AbCdEf          && echo BAD26
        e2e_is_target_tmp "e2e-run.AbCdEf;rm"   && echo BAD27
        OSTYPE=cygwin;    e2e_is_windows || echo BAD16
        OSTYPE=msys;      e2e_is_windows || echo BAD17
        OSTYPE=mingw64;   e2e_is_windows || echo BAD18
        OSTYPE=linux-gnu; e2e_is_windows && echo BAD19
        OSTYPE=darwin22;  e2e_is_windows && echo BAD20
        echo DONE'
    assert_file_contains     "$mb/out.log" "DONE"  "判定の関数が最後まで実行された"
    assert_file_not_contains "$mb/out.log" "BAD"   "対象は一致し、対象外（他のリポジトリ・アプリ・不正な名前）は一致しない"
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# 2. ガード
# ------------------------------------------------------------------------------
test_e2e_guard() {
    echo ""; echo -e "${CLR_HEAD}[TEST] ガード（GitHub Actions 上・gh ユーザー不一致では動かない）${CLR_RST}"
    local mb; mb=$(setup_mock_bin); MB="$mb"; FX="$mb/fx.env"; HM="$mb"
    export MOCK_CALL_LOG="$mb/calls.log"; _mk_mocks "$mb"; _mk_fixture "$FX"

    _e2e_call 'e2e_load_fixture; e2e_guard_env; echo "GUARD=${E2E_GUARD_OK}"'
    assert_file_contains "$mb/out.log" "GUARD=1" "正常: ガードを通る（E2E_GUARD_OK=1）"

    GITHUB_ACTIONS=true _e2e_call 'e2e_load_fixture; e2e_guard_env; echo "GUARD=${E2E_GUARD_OK}"'
    assert_file_not_contains "$mb/out.log" "GUARD=1" "GitHub Actions 上では、ガードを通らない"
    assert_file_contains     "$mb/out.log" "GitHub Actions 上では" "その旨が表示される"

    # GitHub Actions 上でも、専用のワークフロー（e2e.yml）の条件が、すべてそろえば通る。1 つでも欠けると通らない
    local _wf="tama-create/sf-tools/.github/workflows/e2e.yml@refs/heads/development"
    local _body='e2e_load_fixture; e2e_guard_env; echo "GUARD=${E2E_GUARD_OK}"; echo "GA=${GITHUB_ACTIONS:-unset} CI=${CI:-unset}"'
    GITHUB_ACTIONS=true CI=true E2E_ALLOW_ACTIONS=1 GITHUB_WORKFLOW_REF="$_wf" GITHUB_EVENT_NAME=push _e2e_call "$_body"
    assert_file_contains "$mb/out.log" "GUARD=1" "専用のワークフロー（e2e.yml・development・push）なら、Actions 上でも、ガードを通る"
    assert_file_contains "$mb/out.log" "GA=unset CI=unset" "通ったあとは、GITHUB_ACTIONS・CI を外す（クライアント PC と同じ動きを確かめるため）"
    GITHUB_ACTIONS=true E2E_ALLOW_ACTIONS=1 GITHUB_WORKFLOW_REF="${_wf/development/main}" GITHUB_EVENT_NAME=workflow_dispatch _e2e_call "$_body"
    assert_file_contains "$mb/out.log" "GUARD=1" "main の上の手動実行（workflow_dispatch）も通る"
    GITHUB_ACTIONS=true E2E_ALLOW_ACTIONS=1 GITHUB_WORKFLOW_REF="$_wf" GITHUB_EVENT_NAME=schedule _e2e_call "$_body"
    assert_file_contains "$mb/out.log" "GUARD=1" "定期実行（schedule）も通る"
    GITHUB_ACTIONS=true GITHUB_WORKFLOW_REF="$_wf" GITHUB_EVENT_NAME=push _e2e_call "$_body"
    assert_file_not_contains "$mb/out.log" "GUARD=1" "E2E_ALLOW_ACTIONS=1 の印がないと、通らない"
    GITHUB_ACTIONS=true E2E_ALLOW_ACTIONS=1 GITHUB_WORKFLOW_REF="tama-create/sf-tools/.github/workflows/test.yml@refs/heads/development" GITHUB_EVENT_NAME=push _e2e_call "$_body"
    assert_file_not_contains "$mb/out.log" "GUARD=1" "ほかのワークフロー（test.yml）からは、通らない"
    GITHUB_ACTIONS=true E2E_ALLOW_ACTIONS=1 GITHUB_WORKFLOW_REF="someone/sf-tools/.github/workflows/e2e.yml@refs/heads/development" GITHUB_EVENT_NAME=push _e2e_call "$_body"
    assert_file_not_contains "$mb/out.log" "GUARD=1" "ほかのリポジトリの e2e.yml（フォークなど）からは、通らない"
    GITHUB_ACTIONS=true E2E_ALLOW_ACTIONS=1 GITHUB_WORKFLOW_REF="${_wf/development/feature-x}" GITHUB_EVENT_NAME=push _e2e_call "$_body"
    assert_file_not_contains "$mb/out.log" "GUARD=1" "development・main 以外のブランチの上では、通らない"
    GITHUB_ACTIONS=true E2E_ALLOW_ACTIONS=1 GITHUB_WORKFLOW_REF="$_wf" GITHUB_EVENT_NAME=pull_request _e2e_call "$_body"
    assert_file_not_contains "$mb/out.log" "GUARD=1" "pull_request のイベントでは、通らない"
    GITHUB_ACTIONS=true E2E_ALLOW_ACTIONS=1 GITHUB_WORKFLOW_REF="$_wf" GITHUB_EVENT_NAME=push MOCK_GH_API_USER=someone-else _e2e_call "$_body"
    assert_file_not_contains "$mb/out.log" "GUARD=1" "Actions 上でも、gh のユーザーが E2E_GH_USER と違うと、通らない（既存のガードは、そのまま）"

    MOCK_GH_API_USER=someone-else _e2e_call 'e2e_load_fixture; e2e_guard_env; echo "GUARD=${E2E_GUARD_OK}"'
    assert_file_not_contains "$mb/out.log" "GUARD=1" "gh のユーザーが E2E_GH_USER と違うと、ガードを通らない"
    assert_file_contains     "$mb/out.log" "一致しません" "その旨が表示される"

    unset MOCK_CALL_LOG
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# 3. 削除関数のガード
# ------------------------------------------------------------------------------
test_e2e_delete_guards() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 削除関数は、ガードを通らない・対象外の名前なら動かない${CLR_RST}"
    local mb; mb=$(setup_mock_bin); MB="$mb"; FX="$mb/fx.env"; HM="$mb"
    export MOCK_CALL_LOG="$mb/calls.log"; _mk_mocks "$mb"; _mk_fixture "$FX"
    : > "$MOCK_CALL_LOG"

    _e2e_call 'e2e_load_fixture; e2e_delete_repo force-e2e-20261004-103000'
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete" "ガードを通っていないと、リポジトリを削除しない"

    _e2e_call 'e2e_load_fixture; e2e_guard_env; e2e_delete_repo force-test-win'
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete" "対象外の名前（force-test-win）は削除しない"

    _e2e_call 'e2e_load_fixture; e2e_guard_env; e2e_delete_repo "force-e2e-20261004-103000 force-test-win"'
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete" "空白を含む名前（複数指定）は削除しない"

    _e2e_call 'e2e_load_fixture; e2e_guard_env; e2e_delete_eca SF_TOOLS'
    assert_file_not_contains "$MOCK_CALL_LOG" "project deploy" "対象外のアプリ（SF_TOOLS）は削除しない"

    _e2e_call 'e2e_load_fixture; e2e_guard_env; e2e_delete_local /tmp/some/test-win; echo DONE'
    assert_file_not_contains "$MB/out.log" "DONE" "対象外のフォルダ名は削除しない（異常終了する）"

    _e2e_call 'e2e_load_fixture; e2e_guard_env; e2e_delete_repo force-e2e-20261004-103000'
    assert_file_contains "$MOCK_CALL_LOG" "gh repo delete tamashimon-org/force-e2e-20261004-103000 --yes" "対象の名前は削除する（オーナーは鍵一式の E2E_OWNER）"

    unset MOCK_CALL_LOG
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# 4. 鍵一式の読み込み
# ------------------------------------------------------------------------------
test_e2e_fixture() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 鍵一式の読み込み${CLR_RST}"
    local mb; mb=$(setup_mock_bin); MB="$mb"; FX="$mb/fx.env"; HM="$mb"
    export MOCK_CALL_LOG="$mb/calls.log"; _mk_mocks "$mb"

    FX="$mb/none.env" _e2e_call 'e2e_load_fixture; echo LOADED'
    assert_file_not_contains "$mb/out.log" "LOADED" "ファイルが無いと、読み込みに失敗する"

    _mk_fixture "$FX"; sedi '/E2E_PAT_TOKEN/d' "$FX"
    _e2e_call 'e2e_load_fixture; echo LOADED'
    assert_file_not_contains "$mb/out.log" "LOADED" "必須の項目が未設定だと、読み込みに失敗する"
    assert_file_contains     "$mb/out.log" "E2E_PAT_TOKEN が未設定" "未設定の項目名が表示される"

    if [[ "$OSTYPE" != "msys"* && "$OSTYPE" != "mingw"* && "$OSTYPE" != "cygwin"* ]]; then
        _mk_fixture "$FX"; chmod 644 "$FX"
        _e2e_call 'e2e_load_fixture; echo LOADED'
        assert_file_not_contains "$mb/out.log" "LOADED" "権限が 600 でないと、読み込みに失敗する"
        _mk_fixture "$FX"
        _e2e_call 'e2e_load_fixture; echo LOADED'
        assert_file_contains     "$mb/out.log" "LOADED" "権限が 600 なら、読み込める"
    fi

    unset MOCK_CALL_LOG
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# cleanup.sh 用: 対象と対象外が混在する環境を作る
#   戻り値（変数）: CB=ベースdir
# ------------------------------------------------------------------------------
_mk_cleanup_env() {
    CB=$(mktemp -d "${TMPDIR:-/tmp}/test-e2e-cl-XXXX")
    MB="$CB/bin"; mkdir -p "$MB"; HM="$CB/home-dir"; mkdir -p "$HM"
    FX="$CB/fx.env"
    _mk_mocks "$MB"
    _mk_fixture "$FX" tamashimon "$CB/root/home"
    export MOCK_CALL_LOG="$MB/calls.log"; : > "$MOCK_CALL_LOG"
    export MOCK_GH_REPOS="force-e2e-20260101-000000 force-test-win force-e2e-abc force-e2e-20260102-010101"
    export MOCK_SF_ECAS="SF_TOOLS SF_TOOLS_force_test_win SF_TOOLS_force_e2e_20260101_000000"
    mkdir -p "$CB/root/home/tamashimon-org/e2e-20260101-000000" "$CB/root/home/tamashimon-org/test-win" \
             "$HM/.sf-jwt/force-e2e-20260101-000000" "$HM/.sf-jwt/force-test-win"
}

_run_cleanup() {  # 引数: オプション。標準入力はそのまま使う
    (
        cd "$HM" || exit 1
        export HOME="$HM" PATH="$MB:$PATH" E2E_FIXTURE="$FX"
        bash "$E2E_DIR/cleanup.sh" "$@"
    ) > "$MB/out.log" 2>&1
}

# ------------------------------------------------------------------------------
# 5. cleanup.sh の既定（一覧のみ）
# ------------------------------------------------------------------------------
test_e2e_cleanup_list() {
    echo ""; echo -e "${CLR_HEAD}[TEST] cleanup.sh の既定は、一覧のみ（何も削除しない）${CLR_RST}"
    _mk_cleanup_env
    _run_cleanup; local rc=$?
    assert_exit_ok "$rc" "一覧のみ → 終了コード 0"
    assert_file_contains     "$MB/out.log" "GitHub: tamashimon-org/force-e2e-20260101-000000" "対象のリポジトリが一覧に出る"
    assert_file_contains     "$MB/out.log" "GitHub: tamashimon-org/force-e2e-20260102-010101" "対象のリポジトリ（2 件目）が一覧に出る"
    assert_file_not_contains "$MB/out.log" "force-test-win"  "対象外のリポジトリは一覧に出ない"
    assert_file_not_contains "$MB/out.log" "force-e2e-abc"   "形式が違うリポジトリは一覧に出ない"
    assert_file_contains     "$MB/out.log" "Salesforce: SF_TOOLS_force_e2e_20260101_000000" "対象のアプリが一覧に出る"
    assert_file_not_contains "$MB/out.log" "Salesforce: SF_TOOLS_force_test_win" "対象外のアプリは一覧に出ない"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete"      "リポジトリを削除しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "post-destructive"    "アプリを削除しない"
    assert_dir_exists "$CB/root/home/tamashimon-org/e2e-20260101-000000" "ローカルの作業フォルダが残っている"
    assert_dir_exists "$HM/.sf-jwt/force-e2e-20260101-000000"            "ローカルの証明書フォルダが残っている"
    unset MOCK_CALL_LOG MOCK_GH_REPOS MOCK_SF_ECAS
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 6. cleanup.sh --yes（対象だけを削除する）
# ------------------------------------------------------------------------------
test_e2e_cleanup_delete() {
    echo ""; echo -e "${CLR_HEAD}[TEST] cleanup.sh --yes は、対象だけを削除し、他は残す${CLR_RST}"
    _mk_cleanup_env
    _run_cleanup --yes --no-confirm; local rc=$?
    assert_exit_ok "$rc" "削除 → 終了コード 0"
    assert_file_contains     "$MOCK_CALL_LOG" "gh repo delete tamashimon-org/force-e2e-20260101-000000 --yes" "対象のリポジトリを削除する"
    assert_file_contains     "$MOCK_CALL_LOG" "gh repo delete tamashimon-org/force-e2e-20260102-010101 --yes" "対象のリポジトリ（2 件目）を削除する"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete tamashimon-org/force-test-win" "対象外のリポジトリ（force-test-win）は削除しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "force-e2e-abc"                              "形式が違うリポジトリは削除しない"
    assert_file_contains     "$MOCK_CALL_LOG" "post-destructive-changes destructiveChanges.xml" "アプリを削除用のデプロイで消す"
    assert_file_contains     "$MOCK_CALL_LOG" "<members>SF_TOOLS_force_e2e_20260101_000000</members><name>ExternalClientApplication</name>" "対象のアプリ本体を指定する"
    assert_file_contains     "$MOCK_CALL_LOG" "<members>SF_TOOLS_force_e2e_20260101_000000_glbloauth</members><name>ExtlClntAppGlobalOauthSettings</name>" "構成要素（グローバル OAuth 設定）も指定する"
    assert_file_contains     "$MOCK_CALL_LOG" "<name>ExtlClntAppOauthConfigurablePolicies</name>" "構成要素（OAuth ポリシー）も指定する"
    assert_file_contains     "$MOCK_CALL_LOG" "<name>ExtlClntAppConfigurablePolicies</name>"      "構成要素（ポリシー）も指定する"
    assert_file_not_contains "$MOCK_CALL_LOG" "<members>SF_TOOLS</members>"                 "元からあるアプリ（SF_TOOLS）は削除しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "SF_TOOLS_force_test_win"                    "対象外のアプリ（SF_TOOLS_force_test_win）は削除しない"
    assert_dir_not_exists "$CB/root/home/tamashimon-org/e2e-20260101-000000" "対象のローカル作業フォルダを削除する"
    assert_dir_not_exists "$HM/.sf-jwt/force-e2e-20260101-000000"            "対象の証明書フォルダを削除する"
    assert_dir_exists     "$CB/root/home/tamashimon-org/test-win"            "対象外の作業フォルダ（test-win）は残る"
    assert_dir_exists     "$HM/.sf-jwt/force-test-win"                       "対象外の証明書フォルダ（force-test-win）は残る"
    assert_file_contains  "$MOCK_CALL_LOG" "sf alias unset sf-tools-e2e-admin" "終了時に、管理用の一時エイリアスを外す"
    unset MOCK_CALL_LOG MOCK_GH_REPOS MOCK_SF_ECAS
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 7. cleanup.sh の確認
# ------------------------------------------------------------------------------
test_e2e_cleanup_confirm() {
    echo ""; echo -e "${CLR_HEAD}[TEST] cleanup.sh --yes の確認（N・delete 以外の入力で中止）${CLR_RST}"
    _mk_cleanup_env
    printf 'N' | _run_cleanup --yes; local rc=$?
    assert_exit_fail "$rc" "確認で N → 中止"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete" "確認で N → 削除しない"

    printf 'Ynodelete\n' | _run_cleanup --yes; rc=$?
    assert_exit_fail "$rc" "delete 以外の入力 → 中止"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete" "delete 以外の入力 → 削除しない"

    printf 'Ydelete\n' | _run_cleanup --yes; rc=$?
    assert_exit_ok "$rc" "delete と入力 → 削除を実行"
    assert_file_contains "$MOCK_CALL_LOG" "gh repo delete tamashimon-org/force-e2e-20260101-000000 --yes" "delete と入力 → リポジトリを削除する"
    unset MOCK_CALL_LOG MOCK_GH_REPOS MOCK_SF_ECAS
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 8. sf の差し替え
# ------------------------------------------------------------------------------
test_e2e_sf_shim() {
    echo ""; echo -e "${CLR_HEAD}[TEST] sf の差し替え（login web だけを置き換え、他はそのまま渡す）${CLR_RST}"
    local b mb sd; b=$(mktemp -d "${TMPDIR:-/tmp}/test-e2e-shim-XXXX")
    mb="$b/real"; sd="$b/shim"; mkdir -p "$mb" "$sd"
    export MOCK_CALL_LOG="$b/calls.log"; : > "$MOCK_CALL_LOG"
    _mk_mocks "$mb"
    cp "$E2E_DIR/shims/sf" "$sd/sf"; chmod +x "$sd/sf"
    printf 'force://PlatformCLI::fakeurl@example.my.salesforce.com' > "$b/url.txt"

    ( export E2E_SHIM_DIR="$sd" E2E_SFDX_URL_FILE="$b/url.txt" PATH="$sd:$mb:$PATH"
      sf org login web --instance-url https://login.salesforce.com --alias sf-tools-PROD ) > /dev/null 2>&1
    assert_file_contains     "$MOCK_CALL_LOG" "sf org login sfdx-url --sfdx-url-file $b/url.txt --alias sf-tools-PROD" "login web は、認証 URL でのログインに置き換わる（エイリアスを引き継ぐ）"
    assert_file_not_contains "$MOCK_CALL_LOG" "org login web" "本物の login web（ブラウザ）は呼ばれない"

    : > "$MOCK_CALL_LOG"
    ( export E2E_SHIM_DIR="$sd" E2E_SFDX_URL_FILE="$b/url.txt" PATH="$sd:$mb:$PATH"
      sf project deploy start --source-dir force-app --target-org sf-tools-PROD ) > /dev/null 2>&1
    assert_file_contains "$MOCK_CALL_LOG" "sf project deploy start --source-dir force-app --target-org sf-tools-PROD" "login web 以外は、本物の sf にそのまま渡る"

    : > "$MOCK_CALL_LOG"
    ( export E2E_SHIM_DIR="$sd" E2E_SFDX_URL_FILE="$b/none.txt" PATH="$sd:$mb:$PATH"
      sf org login web --alias x ) > /dev/null 2>&1
    assert_exit_fail $? "認証 URL のファイルが無いと、失敗する"
    assert_file_not_contains "$MOCK_CALL_LOG" "org login" "認証 URL のファイルが無いと、ログインを呼ばない"

    # 段階ごとの組織: エイリアスの末尾（STG / DEV）で、認証 URL のファイルを選ぶ
    printf 'force://PlatformCLI::stgurl@stg.my.salesforce.com' > "$b/url-stg.txt"
    printf 'force://PlatformCLI::devurl@dev.my.salesforce.com' > "$b/url-dev.txt"
    : > "$MOCK_CALL_LOG"
    ( export E2E_SHIM_DIR="$sd" E2E_SFDX_URL_FILE="$b/url.txt" E2E_SFDX_URL_FILE_STG="$b/url-stg.txt" E2E_SFDX_URL_FILE_DEV="$b/url-dev.txt" PATH="$sd:$mb:$PATH"
      sf org login web --instance-url https://login.salesforce.com --alias sf-tools-STG
      sf org login web --instance-url https://login.salesforce.com --alias sf-tools-DEV
      sf org login web --instance-url https://login.salesforce.com --alias sf-tools-PROD ) > /dev/null 2>&1
    assert_file_contains "$MOCK_CALL_LOG" "--sfdx-url-file $b/url-stg.txt --alias sf-tools-STG" "末尾が STG のエイリアスは、staging の認証 URL を使う"
    assert_file_contains "$MOCK_CALL_LOG" "--sfdx-url-file $b/url-dev.txt --alias sf-tools-DEV" "末尾が DEV のエイリアスは、develop の認証 URL を使う"
    assert_file_contains "$MOCK_CALL_LOG" "--sfdx-url-file $b/url.txt --alias sf-tools-PROD"    "それ以外は、main の認証 URL を使う"

    # staging の認証 URL のファイルがないとき: main の組織に、ログインしない（別の組織に、つながらない）
    : > "$MOCK_CALL_LOG"
    ( export E2E_SHIM_DIR="$sd" E2E_SFDX_URL_FILE="$b/url.txt" PATH="$sd:$mb:$PATH"
      sf org login web --instance-url https://login.salesforce.com --alias sf-tools-STG ) > /dev/null 2>&1
    assert_exit_fail $? "STG の認証 URL のファイルが無いと、失敗する"
    assert_file_not_contains "$MOCK_CALL_LOG" "org login" "STG のファイルが無いとき、main の組織にログインしない"

    # 一時的なログインの失敗: 待って、やり直す（上限まで）
    : > "$MOCK_CALL_LOG"; rm -f "$b/login.cnt"
    ( export E2E_SHIM_DIR="$sd" E2E_SFDX_URL_FILE="$b/url.txt" E2E_SHIM_LOGIN_WAIT=0 MOCK_SF_ADMIN_FAIL_FIRST=2 PATH="$sd:$mb:$PATH"
      sf org login web --instance-url https://login.salesforce.com --alias sf-tools-PROD ) > /dev/null 2>&1
    assert_exit_ok $? "認証 URL でのログインが 2 回失敗しても、3 回目で成功する（一時的な失敗のやり直し）"
    assert_equals "$(grep -c 'org login sfdx-url' "$MOCK_CALL_LOG")" "3" "やり直しは、3 回まで"
    : > "$MOCK_CALL_LOG"; rm -f "$b/login.cnt"
    ( export E2E_SHIM_DIR="$sd" E2E_SFDX_URL_FILE="$b/url.txt" E2E_SHIM_LOGIN_WAIT=0 MOCK_SF_ADMIN_FAIL_FIRST=9 PATH="$sd:$mb:$PATH"
      sf org login web --instance-url https://login.salesforce.com --alias sf-tools-PROD ) > /dev/null 2>&1
    assert_exit_fail $? "ログインが上限まで失敗し続けたら、失敗する"
    assert_equals "$(grep -c 'org login sfdx-url' "$MOCK_CALL_LOG")" "3" "失敗し続けても、試行は 3 回で止まる"

    unset MOCK_CALL_LOG
    teardown "$b"
}

# ------------------------------------------------------------------------------
# 9. sf のエイリアスの保存・復元
# ------------------------------------------------------------------------------
test_e2e_alias_restore() {
    echo ""; echo -e "${CLR_HEAD}[TEST] sf のエイリアスの保存・復元${CLR_RST}"
    local mb; mb=$(setup_mock_bin); MB="$mb"; FX="$mb/fx.env"; HM="$mb"
    export MOCK_CALL_LOG="$mb/calls.log"; _mk_mocks "$mb"

    MOCK_SF_ALIASES="DevHub=hub@example.com develop=dev@example.com" _e2e_call 'e2e_alias_snapshot "'"$mb"'/snap.txt"'
    assert_file_contains "$mb/snap.txt" "DevHub=hub@example.com" "エイリアスを保存できる（1 件目）"
    assert_file_contains "$mb/snap.txt" "develop=dev@example.com" "エイリアスを保存できる（2 件目）"

    # テスト中に、prod が増え、develop の指す先が変わった状態
    : > "$MOCK_CALL_LOG"
    MOCK_SF_ALIASES="DevHub=hub@example.com develop=CHANGED@example.com prod=p@example.com" \
        _e2e_call 'e2e_alias_restore "'"$mb"'/snap.txt"'
    assert_file_contains     "$MOCK_CALL_LOG" "sf alias unset prod"                    "増えたエイリアス（prod）は外す"
    assert_file_contains     "$MOCK_CALL_LOG" "sf alias set develop=dev@example.com"   "指す先が変わったエイリアス（develop）は元に戻す"
    assert_file_not_contains "$MOCK_CALL_LOG" "sf alias set DevHub"                    "変わっていないエイリアスは触らない"
    assert_file_not_contains "$MOCK_CALL_LOG" "sf alias unset develop"                 "元からあったエイリアスは外さない"

    # テスト中に、develop が消えた状態
    : > "$MOCK_CALL_LOG"
    MOCK_SF_ALIASES="DevHub=hub@example.com" _e2e_call 'e2e_alias_restore "'"$mb"'/snap.txt"'
    assert_file_contains "$MOCK_CALL_LOG" "sf alias set develop=dev@example.com" "消えたエイリアスは付け直す"

    unset MOCK_CALL_LOG
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# 10. sf-init に流す入力の台本
# ------------------------------------------------------------------------------
test_e2e_input() {
    echo ""; echo -e "${CLR_HEAD}[TEST] sf-init に流す入力の台本${CLR_RST}"
    local mb out; mb=$(setup_mock_bin); MB="$mb"; FX="$mb/fx.env"; HM="$mb"
    export MOCK_CALL_LOG="$mb/calls.log"; _mk_mocks "$mb"; _mk_fixture "$FX"
    _e2e_call 'e2e_load_fixture; e2e_make_input'
    out=$(cat "$mb/out.log")
    local expected
    expected=$'Y\nY\n2\nY\n3\nghp_fakepat\n\nxoxb-fakeslack\nC01ABCDEFGH\n\n1'
    assert_equals "$out" "$expected" "台本が、質問の順番どおりである（Y→Y→2→Y→3→PAT→空→Slack→ID→空→ログイン先 1）"
    unset MOCK_CALL_LOG
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# 11. run.sh のガード
# ------------------------------------------------------------------------------
test_e2e_run_guard() {
    echo ""; echo -e "${CLR_HEAD}[TEST] run.sh のガード（GitHub Actions 上・鍵一式なしでは動かない）${CLR_RST}"
    _mk_cleanup_env
    local rc

    ( cd "$HM" && export HOME="$HM" PATH="$MB:$PATH" E2E_FIXTURE="$FX" GITHUB_ACTIONS=true
      printf 'Y' | bash "$E2E_DIR/run.sh" ) > "$MB/out.log" 2>&1; rc=$?
    assert_exit_fail "$rc" "GitHub Actions 上では、run.sh は中止する"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete" "GitHub Actions 上では、何も削除しない"

    ( cd "$HM" && export HOME="$HM" PATH="$MB:$PATH" E2E_FIXTURE="$CB/none.env"
      printf 'Y' | bash "$E2E_DIR/run.sh" ) > "$MB/out.log" 2>&1; rc=$?
    assert_exit_fail "$rc" "鍵一式が無いと、run.sh は中止する"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete" "鍵一式が無いと、何も削除しない"

    ( cd "$HM" && export HOME="$HM" PATH="$MB:$PATH" E2E_FIXTURE="$FX"
      printf 'N' | bash "$E2E_DIR/run.sh" ) > "$MB/out.log" 2>&1; rc=$?
    assert_exit_fail "$rc" "確認で N → run.sh は中止する"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete" "確認で N → 何も削除しない"

    local f
    for f in run.sh cleanup.sh bootstrap.sh; do
        bash "$E2E_DIR/$f" --help 2>&1 | grep -q "オプション\|処理の流れ" \
            && pass "${f} --help が表示できる" || fail "${f} --help が表示できる"
    done

    # --layout の指定の検証（何も実行せずに、中止する）
    : > "$MOCK_CALL_LOG"
    ( cd "$HM" && export HOME="$HM" PATH="$MB:$PATH" E2E_FIXTURE="$FX"
      printf 'Y' | bash "$E2E_DIR/run.sh" --layout 4 ) > "$MB/out.log" 2>&1; rc=$?
    assert_exit_fail "$rc" "--layout 4（範囲外）→ 中止する"
    assert_file_contains "$MB/out.log" "--layout は、1・2・3 のいずれかです" "--layout: 理由が表示される"
    ( cd "$HM" && export HOME="$HM" PATH="$MB:$PATH" E2E_FIXTURE="$FX"
      printf 'Y' | bash "$E2E_DIR/run.sh" --layout 2 --resume ) > "$MB/out.log" 2>&1; rc=$?
    assert_exit_fail "$rc" "--layout と --resume の同時指定 → 中止する"
    assert_file_contains "$MB/out.log" "新しくリポジトリを作るときだけ" "--layout + --resume: 理由が表示される"
    ( cd "$HM" && export HOME="$HM" PATH="$MB:$PATH" E2E_FIXTURE="$FX"
      printf 'Y' | bash "$E2E_DIR/run.sh" --layout ) > "$MB/out.log" 2>&1; rc=$?
    assert_exit_fail "$rc" "--layout に値がない → 中止する"
    # 2 層・3 層に必要な組織が、鍵一式にない（main だけ）→ 何もせずに、中止する
    ( cd "$HM" && export HOME="$HM" PATH="$MB:$PATH" E2E_FIXTURE="$FX"
      printf 'Y' | bash "$E2E_DIR/run.sh" --layout 3 ) > "$MB/out.log" 2>&1; rc=$?
    assert_exit_fail "$rc" "--layout 3 で、鍵一式に develop の組織がない → 中止する"
    assert_file_contains "$MB/out.log" "bootstrap.sh --add-orgs" "鍵一式にない組織: 追加の方法が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete" "オプションの検証で中止したとき: 何も削除しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo create" "オプションの検証で中止したとき: 何も作らない"
    unset MOCK_CALL_LOG MOCK_GH_REPOS MOCK_SF_ECAS
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 12. 認証 URL の検証と取得
# ------------------------------------------------------------------------------
test_e2e_sfdx_url() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 認証 URL の検証と取得（新しい sf は --verbose で隠すため）${CLR_RST}"
    local mb out; mb=$(setup_mock_bin); MB="$mb"; FX="$mb/fx.env"; HM="$mb"
    export MOCK_CALL_LOG="$mb/calls.log"; _mk_mocks "$mb"; _mk_fixture "$FX"

    # 形式の判定
    _e2e_call '
        e2e_valid_sfdx_url "force://PlatformCLI::abc123.def@host.my.salesforce.com"            || echo BAD1
        e2e_valid_sfdx_url "force://clientid:clientsecret:abc123@host.my.salesforce.com"       || echo BAD2
        e2e_valid_sfdx_url "[REDACTED] Use '"'"'sf org auth show-sfdx-auth-url'"'"' to view"      && echo BAD3
        e2e_valid_sfdx_url ""                                                                  && echo BAD4
        e2e_valid_sfdx_url "force://x@y"                                                       && echo BAD5
        e2e_valid_sfdx_url "https://PlatformCLI::abc@host"                                     && echo BAD6
        e2e_valid_sfdx_url "force://PlatformCLI::abc@host extra"                               && echo BAD7
        echo DONE'
    assert_file_contains     "$mb/out.log" "DONE" "形式の判定が最後まで実行された"
    assert_file_not_contains "$mb/out.log" "BAD"  "認証 URL の形式は通り、隠された文章・不正な形式は通らない"

    # 鍵一式の読み込みで、形式の違う認証 URL を拒否する
    _mk_fixture "$FX"; sedi "s|^E2E_SFDX_AUTH_URL=.*|E2E_SFDX_AUTH_URL='[REDACTED] Use sf org auth show-sfdx-auth-url to view'|" "$FX"
    _e2e_call 'e2e_load_fixture; echo LOADED'
    assert_file_not_contains "$mb/out.log" "LOADED" "鍵一式の認証 URL が隠された文章だと、読み込みに失敗する"
    assert_file_contains     "$mb/out.log" "認証 URL の形式ではありません" "その旨が表示される"
    _mk_fixture "$FX"

    # 取得: 新しい sf（show-sfdx-auth-url が使える）
    _e2e_call 'u=$(e2e_get_sfdx_auth_url prod); echo "URL=[$u]"'
    assert_file_contains "$mb/out.log" "URL=[force://PlatformCLI::fakeshowtoken@example.my.salesforce.com]" "新しい sf: show-sfdx-auth-url から取得できる"

    # 取得: 古い sf（show が使えず、display --verbose に認証 URL がある）
    MOCK_SF_SHOW_URL=none MOCK_SF_DISPLAY_URL="force://PlatformCLI::olddisplaytoken@example.my.salesforce.com" \
        _e2e_call 'u=$(e2e_get_sfdx_auth_url prod); echo "URL=[$u]"'
    assert_file_contains "$mb/out.log" "URL=[force://PlatformCLI::olddisplaytoken@example.my.salesforce.com]" "古い sf: display --verbose から取得できる"

    # 取得: show が不正な値を返す → display にフォールバック
    MOCK_SF_SHOW_URL="[REDACTED]" MOCK_SF_DISPLAY_URL="force://PlatformCLI::fallbacktoken@example.my.salesforce.com" \
        _e2e_call 'u=$(e2e_get_sfdx_auth_url prod); echo "URL=[$u]"'
    assert_file_contains "$mb/out.log" "URL=[force://PlatformCLI::fallbacktoken@example.my.salesforce.com]" "show が不正な値 → display にフォールバックする"

    # 取得: どちらでも取れない（show が使えず、display は隠される）→ 失敗（隠された文章を返さない）
    MOCK_SF_SHOW_URL=none _e2e_call 'u=$(e2e_get_sfdx_auth_url prod); rc=$?; echo "RC=$rc URL=[$u]"'
    assert_file_contains     "$mb/out.log" "RC=1 URL=[]" "どちらでも取れない → 空で、戻り値 1"
    assert_file_not_contains "$mb/out.log" "REDACTED"   "隠された文章を、認証 URL として返さない"

    unset MOCK_CALL_LOG
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# 13. 管理用ログインの失敗時の表示と再試行
# ------------------------------------------------------------------------------
test_e2e_admin_login_retry() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 管理用ログイン: 失敗時に原因を表示し、1 回だけやり直す${CLR_RST}"
    local mb n; mb=$(setup_mock_bin); MB="$mb"; FX="$mb/fx.env"; HM="$mb"
    export MOCK_CALL_LOG="$mb/calls.log"; _mk_mocks "$mb"; _mk_fixture "$FX"
    export E2E_ADMIN_RETRY_WAIT=0
    local script='e2e_load_fixture; e2e_guard_env; e2e_sf_admin_login; echo LOGGED_IN'
    _attempts() { grep -c "^sf org login sfdx-url" "$MOCK_CALL_LOG"; }
    _reset() { rm -f "$mb/login.cnt" "$mb/admin_ok"; : > "$MOCK_CALL_LOG"; }

    _reset; _e2e_call "$script"
    assert_file_contains "$mb/out.log" "LOGGED_IN" "正常: 1 回でログインできる"
    [[ "$(_attempts)" -eq 1 ]] && pass "正常: 試行は 1 回" || fail "正常: 試行は 1 回" "試行: $(_attempts)"

    _reset; MOCK_SF_ADMIN_FAIL_FIRST=1 _e2e_call "$script"
    assert_file_contains "$mb/out.log" "LOGGED_IN" "1 回目が失敗しても、やり直してログインできる"
    [[ "$(_attempts)" -eq 2 ]] && pass "1 回目が失敗 → 試行は 2 回" || fail "1 回目が失敗 → 試行は 2 回" "試行: $(_attempts)"
    assert_file_contains "$mb/out.log" "管理用ログインに失敗しました（1/2）" "1 回目の失敗が、表示される"

    _reset; MOCK_SF_ADMIN_FAIL_FIRST=2 _e2e_call "$script"
    assert_file_not_contains "$mb/out.log" "LOGGED_IN" "2 回とも失敗 → 中断する"
    [[ "$(_attempts)" -eq 2 ]] && pass "2 回とも失敗 → 試行は 2 回で、止まる" || fail "2 回とも失敗 → 試行は 2 回で、止まる" "試行: $(_attempts)"
    assert_file_contains     "$mb/out.log" "RefreshTokenAuthError" "失敗時に、sf の出力（原因）が表示される"
    assert_file_contains     "$mb/out.log" "***masked***"          "認証 URL のリフレッシュトークンは、伏せ字で表示される"
    assert_file_not_contains "$mb/out.log" "secretrefreshtoken123" "リフレッシュトークンの値は、画面に出ない"
    assert_file_contains     "$mb/out.log" "管理用ログインに失敗しました。" "最後に、失敗の旨で中断する"

    unset -f _attempts _reset
    unset MOCK_CALL_LOG E2E_ADMIN_RETRY_WAIT
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# 14. 強制終了で残った一時ファイル・フォルダの掃除
# ------------------------------------------------------------------------------
test_e2e_tmp_cleanup() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 強制終了で残った一時ファイル・フォルダの掃除（認証 URL を含むことがある）${CLR_RST}"
    _mk_cleanup_env
    local t="$CB/tmpdir"; mkdir -p "$t"
    # 掃除の対象（古い）
    mkdir -p "$t/e2e-run.AbCdEf" "$t/e2e-eca-del.123456"
    echo secret > "$t/e2e-run.AbCdEf/sfdx-url.txt"
    echo secret > "$t/e2e-sfdx-url.QwErTy"
    # 対象外: 新しいもの（別の実行の途中かもしれない）、実行中の run.sh のもの、名前が違うもの
    mkdir -p "$t/e2e-run.NewOne" "$t/e2e-run.Curren" "$t/e2e-run.toolong1" "$t/other.AbCdEf" "$t/e2e-run.AbC"
    touch_ago 120 "$t/e2e-run.AbCdEf" "$t/e2e-run.AbCdEf/sfdx-url.txt" "$t/e2e-eca-del.123456" "$t/e2e-sfdx-url.QwErTy" \
        "$t/e2e-run.Curren" "$t/e2e-run.toolong1" "$t/other.AbCdEf" "$t/e2e-run.AbC"

    # 一覧（実行中の run.sh の一時フォルダは、E2E_TMP で除外される）
    TMPDIR="$t" E2E_TMP="$t/e2e-run.Curren" _e2e_call 'e2e_load_fixture; e2e_guard_env; e2e_list_target_local'
    assert_file_contains     "$MB/out.log" "$t/e2e-run.AbCdEf"       "古い e2e-run.* が、掃除の対象になる"
    assert_file_contains     "$MB/out.log" "$t/e2e-eca-del.123456"   "古い e2e-eca-del.* が、掃除の対象になる"
    assert_file_contains     "$MB/out.log" "$t/e2e-sfdx-url.QwErTy"  "古い e2e-sfdx-url.*（ファイル）が、掃除の対象になる"
    assert_file_not_contains "$MB/out.log" "e2e-run.NewOne"          "新しいもの（30 分以内）は、対象外"
    assert_file_not_contains "$MB/out.log" "e2e-run.Curren"          "実行中の run.sh の一時フォルダ（E2E_TMP）は、対象外"
    assert_file_not_contains "$MB/out.log" "toolong1"                "名前の形式が違うもの（文字数が違う）は、対象外"
    assert_file_not_contains "$MB/out.log" "other.AbCdEf"            "ほかの名前は、対象外"

    # cleanup.sh（既定は一覧のみ。何も消さない）
    TMPDIR="$t" _run_cleanup
    assert_dir_exists "$t/e2e-run.AbCdEf" "一覧のみの間は、一時フォルダを消さない"

    # cleanup.sh --yes --no-confirm（対象だけを消す）
    TMPDIR="$t" _run_cleanup --yes --no-confirm; local rc=$?
    assert_exit_ok "$rc" "削除 → 終了コード 0"
    assert_dir_not_exists "$t/e2e-run.AbCdEf"     "古い e2e-run.* を削除する"
    assert_dir_not_exists "$t/e2e-eca-del.123456" "古い e2e-eca-del.* を削除する"
    assert_file_not_exists "$t/e2e-sfdx-url.QwErTy" "古い e2e-sfdx-url.* を削除する"
    assert_dir_exists "$t/e2e-run.NewOne"   "新しいものは残る"
    assert_dir_exists "$t/e2e-run.toolong1" "名前の形式が違うものは残る"
    assert_dir_exists "$t/other.AbCdEf"     "ほかの名前は残る"

    # 削除関数は、対象外の名前なら動かない
    _e2e_call 'e2e_load_fixture; e2e_guard_env; e2e_delete_local "'"$t"'/other.AbCdEf"; echo DONE'
    assert_file_not_contains "$MB/out.log" "DONE" "対象外の名前は、削除しない（異常終了する）"
    assert_dir_exists "$t/other.AbCdEf" "対象外のフォルダが残っている"

    unset MOCK_CALL_LOG MOCK_GH_REPOS MOCK_SF_ECAS
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 15. 一覧の取得に失敗したとき（「対象なし」と取り違えない）
#   背景: 一覧の取得に失敗したのを「対象なし」とみなし、アプリが削除されないまま e2e が「成功」した実例がある
# ------------------------------------------------------------------------------
test_e2e_list_failure() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 一覧の取得に失敗したとき: 再試行し、それでも失敗なら「対象なし」とみなさない${CLR_RST}"
    _mk_cleanup_env
    export E2E_LIST_RETRY_WAIT=0
    local fn='e2e_load_fixture; e2e_guard_env; out=$(e2e_list_target_ecas); rc=$?; echo "RC=$rc OUT=[$out]"'
    _reset() { rm -f "$MB/sflist.cnt" "$MB/ghlist.cnt"; : > "$MOCK_CALL_LOG"; }

    # --- Salesforce 側（関数）---
    _reset; _e2e_call "$fn"
    assert_file_contains "$MB/out.log" "RC=0 OUT=[SF_TOOLS_force_e2e_20260101_000000]" "正常: 一覧が取れる"

    _reset; MOCK_SF_LIST_FAIL_FIRST=2 _e2e_call "$fn"
    assert_file_contains "$MB/out.log" "RC=0 OUT=[SF_TOOLS_force_e2e_20260101_000000]" "2 回失敗しても、3 回目で取れる（再試行）"
    [[ "$(grep -c '^sf org list' "$MOCK_CALL_LOG")" -eq 3 ]] && pass "再試行は 3 回までで、取れたら止まる" || fail "再試行は 3 回までで、取れたら止まる" "回数: $(grep -c '^sf org list' "$MOCK_CALL_LOG")"

    _reset; MOCK_SF_LIST_FAIL_FIRST=all _e2e_call "$fn"
    assert_file_contains "$MB/out.log" "RC=1 OUT=[]" "ずっと失敗 → 戻り値 1（何も出力しない）"
    [[ "$(grep -c '^sf org list' "$MOCK_CALL_LOG")" -eq 3 ]] && pass "ずっと失敗 → 3 回で諦める" || fail "ずっと失敗 → 3 回で諦める" "回数: $(grep -c '^sf org list' "$MOCK_CALL_LOG")"


    # --- Salesforce 側（cleanup.sh）---
    _reset; MOCK_SF_LIST_FAIL_FIRST=all _run_cleanup --yes --no-confirm; local rc=$?
    assert_exit_fail "$rc" "アプリの一覧を取れない → 失敗で終わる（成功と報告しない）"
    assert_file_contains     "$MB/out.log" "外部クライアントアプリの一覧を取得できませんでした" "取得失敗の旨が表示される"
    assert_file_not_contains "$MB/out.log" "対象の外部クライアントアプリはありません" "「対象なし」とは表示しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "post-destructive" "取得できないときは、アプリの削除をしない"
    assert_file_contains     "$MOCK_CALL_LOG" "gh repo delete tamashimon-org/force-e2e-20260101-000000 --yes" "GitHub 側の削除は、続けて行う（途中で止まらない）"
    assert_dir_not_exists "$CB/root/home/tamashimon-org/e2e-20260101-000000" "ローカルの掃除も、続けて行う（途中で止まらない）"

    # --- アプリの削除（deploy）が失敗したとき（終了コードで判定する）---
    teardown "$CB"
    _mk_cleanup_env
    _reset; MOCK_SF_DEPLOY_EXIT=1 _run_cleanup --yes --no-confirm; rc=$?
    assert_exit_fail         "$rc" "削除用の deploy が失敗 → 失敗で終わる"
    assert_file_contains     "$MB/out.log" "の削除（deploy）に失敗しました" "削除の失敗が表示される"

    _reset; MOCK_SF_LIST_FAIL_FIRST=all _run_cleanup; rc=$?
    assert_exit_fail "$rc" "一覧のみの表示でも、取れなければ失敗で終わる"

    # --- GitHub 側 ---
    teardown "$CB"
    _mk_cleanup_env
    _reset; MOCK_GH_LIST_FAIL_FIRST=1 _e2e_call 'e2e_load_fixture; e2e_guard_env; out=$(e2e_list_target_repos); echo "RC=$? OUT=[$out]"'
    assert_file_contains "$MB/out.log" "RC=0 OUT=[force-e2e-20260101-000000" "リポジトリ一覧: 1 回失敗しても、取れる（再試行）"

    _reset; MOCK_GH_LIST_FAIL_FIRST=all _run_cleanup --yes --no-confirm; rc=$?
    assert_exit_fail "$rc" "リポジトリの一覧を取れない → 失敗で終わる"
    assert_file_contains     "$MB/out.log" "リポジトリの一覧を取得できませんでした" "リポジトリの取得失敗の旨が表示される"
    assert_file_not_contains "$MB/out.log" "対象のリポジトリはありません" "「対象なし」とは表示しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete" "取得できないときは、リポジトリを削除しない"
    assert_file_contains     "$MOCK_CALL_LOG" "post-destructive-changes" "Salesforce 側の削除は、続けて行う（途中で止まらない）"

    unset -f _reset
    unset MOCK_CALL_LOG MOCK_GH_REPOS MOCK_SF_ECAS E2E_LIST_RETRY_WAIT
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 16. ローカルの削除の補強（名前が一致しても、中身が想定外・シンボリックリンクなら消さない）
#   背景: Codex のレビューで、JWT 用フォルダを、名前だけで rm -rf していることを指摘された
# ------------------------------------------------------------------------------
test_e2e_local_guard() {
    echo ""; echo -e "${CLR_HEAD}[TEST] ローカルの削除: 中身が想定外のフォルダ・シンボリックリンクは、消さない${CLR_RST}"
    _mk_cleanup_env
    local j="$HM/.sf-jwt/force-e2e-20260101-000000"
    printf 'k' > "$j/server.key"; printf 'c' > "$j/server.crt"

    # 想定どおりの中身（server.key / server.crt だけ）→ 削除される
    _run_cleanup --yes --no-confirm; local rc=$?
    assert_exit_ok "$rc" "中身が server.key / server.crt だけ → 削除できる（終了コード 0）"
    assert_dir_not_exists "$j" "中身が server.key / server.crt だけのフォルダは、削除される"
    teardown "$CB"

    # 想定外のファイルが入っている → 削除しない（失敗として返す）
    _mk_cleanup_env
    j="$HM/.sf-jwt/force-e2e-20260101-000000"
    printf 'k' > "$j/server.key"; printf 'important' > "$j/notes.txt"
    _run_cleanup --yes --no-confirm; rc=$?
    assert_exit_fail "$rc" "想定外のファイルあり → 失敗で終わる"
    assert_dir_exists "$j" "想定外のファイルが入っているフォルダは、削除しない"
    assert_file_exists "$j/notes.txt" "想定外のファイルが残っている"
    assert_file_contains "$MB/out.log" "想定外のファイル（notes.txt）があるため、削除しません" "削除しない理由が表示される"
    assert_dir_not_exists "$CB/root/home/tamashimon-org/e2e-20260101-000000" "ほかの掃除（作業フォルダ）は、続けて行う"
    teardown "$CB"

    # シンボリックリンクは、一覧に出さない
    _mk_cleanup_env
    local t="$CB/tmpdir" real="$CB/real-target"; mkdir -p "$t" "$real"
    ln -s "$real" "$t/e2e-run.LnKdIr" 2>/dev/null
    ln -s "$real" "$HM/.sf-jwt/force-e2e-20260202-020202" 2>/dev/null
    touch -h -d "2 hours ago" "$t/e2e-run.LnKdIr" 2>/dev/null
    if [[ -L "$t/e2e-run.LnKdIr" ]]; then
        TMPDIR="$t" _e2e_call 'e2e_load_fixture; e2e_guard_env; e2e_list_target_local'
        assert_file_not_contains "$MB/out.log" "e2e-run.LnKdIr" "一時フォルダのシンボリックリンクは、対象外"
        assert_file_not_contains "$MB/out.log" "force-e2e-20260202-020202" "証明書フォルダのシンボリックリンクは、対象外"
    else
        pass "（シンボリックリンクを作れない環境のため省略）"
    fi
    unset MOCK_CALL_LOG MOCK_GH_REPOS MOCK_SF_ECAS
    teardown "$CB"
}
# ------------------------------------------------------------------------------
# 17. Hello World の Apex（名前の判定・一覧・件数・削除・後掃除）
# ------------------------------------------------------------------------------
test_e2e_apex() {
    echo ""; echo -e "${CLR_HEAD}[TEST] Hello World の Apex: 名前の判定・一覧・件数・削除・後掃除${CLR_RST}"
    _mk_cleanup_env
    export MOCK_SF_APEX="SfToolsE2eHello SfToolsE2eHelloTest OtherClass"
    export E2E_LIST_RETRY_WAIT=0
    local pre='e2e_load_fixture; e2e_guard_env;'
    local rc

    # 名前の判定: 完全に一致する 2 つだけ
    _e2e_call 'for n in SfToolsE2eHello SfToolsE2eHelloTest SfToolsE2eHelloX sftoolse2ehello OtherClass "SfToolsE2eHello "; do if e2e_is_target_apex "$n"; then echo "OK:[$n]"; else echo "NO:[$n]"; fi; done'
    assert_file_contains "$MB/out.log" "OK:[SfToolsE2eHello]"     "名前の判定: SfToolsE2eHello は対象"
    assert_file_contains "$MB/out.log" "OK:[SfToolsE2eHelloTest]" "名前の判定: SfToolsE2eHelloTest は対象"
    assert_file_contains "$MB/out.log" "NO:[SfToolsE2eHelloX]"    "名前の判定: 前方一致だけのものは対象外"
    assert_file_contains "$MB/out.log" "NO:[sftoolse2ehello]"     "名前の判定: 大文字小文字が違うものは対象外"
    assert_file_contains "$MB/out.log" "NO:[OtherClass]"          "名前の判定: 無関係のクラスは対象外"
    assert_file_contains "$MB/out.log" "NO:[SfToolsE2eHello ]"    "名前の判定: 末尾に空白があるものは対象外"

    # 一覧: 対象だけが出る
    _e2e_call "$pre"' out=$(e2e_list_target_apex); echo "RC=$? OUT=[$(echo $out)]"'
    assert_file_contains     "$MB/out.log" "RC=0 OUT=[SfToolsE2eHello SfToolsE2eHelloTest]" "一覧: 対象の 2 つだけが出る"
    assert_file_not_contains "$MB/out.log" "OtherClass" "一覧: 無関係のクラスは出ない"

    # 一覧: 失敗は再試行し、ずっと失敗なら戻り値 1
    rm -f "$MB/sfapex.cnt"; MOCK_SF_APEX_FAIL_FIRST=2 _e2e_call "$pre"' out=$(e2e_list_target_apex); echo "RC=$? OUT=[$(echo $out)]"'
    assert_file_contains "$MB/out.log" "RC=0 OUT=[SfToolsE2eHello SfToolsE2eHelloTest]" "一覧: 2 回失敗しても、3 回目で取れる（再試行）"
    rm -f "$MB/sfapex.cnt"; MOCK_SF_APEX_FAIL_FIRST=all _e2e_call "$pre"' out=$(e2e_list_target_apex); echo "RC=$? OUT=[$out]"'
    assert_file_contains "$MB/out.log" "RC=1 OUT=[]" "一覧: ずっと失敗 → 戻り値 1（何も出力しない）"

    # 件数
    _e2e_call "$pre"' echo "HELLO=$(e2e_apex_count SfToolsE2eHello) TEST=$(e2e_apex_count SfToolsE2eHelloTest)"'
    assert_file_contains "$MB/out.log" "HELLO=1 TEST=1" "件数: あるクラスは 1"
    _e2e_call "$pre"' e2e_apex_count OtherClass; echo DONE'
    assert_file_not_contains "$MB/out.log" "DONE" "件数: 対象外のクラス名は、拒否する（異常終了）"
    rm -f "$MB/sfapex.cnt"; MOCK_SF_APEX_FAIL_FIRST=all _e2e_call "$pre"' e2e_apex_count SfToolsE2eHello; echo "RC=$?"'
    assert_file_contains "$MB/out.log" "RC=1" "件数: 取得に失敗 → 戻り値 1"
assert_file_contains "$MB/out.log" "件数の取得に失敗しました"  "件数: 取得に失敗 → 警告を表示する（原因が分かるように）"    assert_file_contains "$MB/out.log" "connection reset"        "件数: 取得に失敗 → sf のエラーの要点を表示する"

    # 削除: 対象外の名前は、拒否する
    : > "$MOCK_CALL_LOG"
    _e2e_call "$pre"' e2e_delete_apex OtherClass; echo DONE'
    assert_file_not_contains "$MB/out.log" "DONE" "削除: 対象外のクラス名は、拒否する（異常終了）"
    assert_file_not_contains "$MOCK_CALL_LOG" "post-destructive" "削除: 対象外のクラス名では、削除用のデプロイをしない"
    _e2e_call "$pre"' e2e_delete_apex SfToolsE2eHello OtherClass; echo DONE'
    assert_file_not_contains "$MOCK_CALL_LOG" "post-destructive" "削除: 1 つでも対象外が混ざれば、何も削除しない"

    # 削除: 対象の 2 つを、削除用のデプロイで消す
    _e2e_call "$pre"' e2e_delete_apex SfToolsE2eHello SfToolsE2eHelloTest; echo "RC=$?"'
    assert_file_contains "$MB/out.log" "RC=0" "削除: 成功 → 戻り値 0"
    assert_file_contains "$MOCK_CALL_LOG" "post-destructive-changes destructiveChanges.xml" "削除: 削除用のデプロイを使う"
    assert_file_contains "$MOCK_CALL_LOG" "<members>SfToolsE2eHello</members>"     "削除: SfToolsE2eHello を指定する"
    assert_file_contains "$MOCK_CALL_LOG" "<members>SfToolsE2eHelloTest</members>" "削除: SfToolsE2eHelloTest を指定する"
    assert_file_contains "$MOCK_CALL_LOG" "<name>ApexClass</name>"                 "削除: メタデータの種類は ApexClass"
    assert_file_not_contains "$MOCK_CALL_LOG" "OtherClass" "削除: 無関係のクラスは、指定しない"
    _e2e_call "$pre"' echo "HELLO=$(e2e_apex_count SfToolsE2eHello) TEST=$(e2e_apex_count SfToolsE2eHelloTest)"'
    assert_file_contains "$MB/out.log" "HELLO=0 TEST=0" "削除後: 件数は 0"
    MOCK_SF_DEPLOY_EXIT=1 _e2e_call "$pre"' e2e_delete_apex SfToolsE2eHello; echo "RC=$?"'
    assert_file_contains "$MB/out.log" "RC=1" "削除: デプロイが失敗 → 戻り値 1"
    teardown "$CB"

    # 後掃除（cleanup.sh）: 一覧のみ → 何も消さない / --yes → 対象だけ消す
    _mk_cleanup_env
    export MOCK_SF_APEX="SfToolsE2eHello SfToolsE2eHelloTest OtherClass"
    _run_cleanup; rc=$?
    assert_exit_ok "$rc" "後掃除（一覧のみ）→ 終了コード 0"
    assert_file_contains     "$MB/out.log" "Salesforce: Apex クラス SfToolsE2eHello"     "後掃除（一覧）: テスト用の Apex クラスが一覧に出る"
    assert_file_not_contains "$MB/out.log" "Apex クラス OtherClass"                      "後掃除（一覧）: 無関係のクラスは出ない"
    assert_file_not_contains "$MOCK_CALL_LOG" "<name>ApexClass</name>"                    "後掃除（一覧のみ）: Apex を削除しない"
    _run_cleanup --yes --no-confirm; rc=$?
    assert_exit_ok "$rc" "後掃除（削除）→ 終了コード 0"
    assert_file_contains     "$MOCK_CALL_LOG" "<members>SfToolsE2eHello</members>"       "後掃除（削除）: テスト用の Apex クラスを削除する"
    assert_file_not_contains "$MOCK_CALL_LOG" "OtherClass"                                "後掃除（削除）: 無関係のクラスは、削除しない"

    # 後掃除: 一覧が取れなければ「対象なし」とは言わず、ほかの掃除は続ける
    rm -f "$MB/sfapex.cnt" "$MB/deleted.txt"; : > "$MOCK_CALL_LOG"
    MOCK_SF_APEX_FAIL_FIRST=all _run_cleanup --yes --no-confirm; rc=$?
    assert_exit_fail "$rc" "後掃除: Apex の一覧を取れない → 失敗で終わる"
    assert_file_contains     "$MB/out.log" "Apex クラスの一覧を取得できませんでした" "後掃除: 取得失敗の旨が表示される"
    assert_file_not_contains "$MB/out.log" "対象の Apex クラスはありません"          "後掃除: 「対象なし」とは表示しない"
    assert_file_contains     "$MOCK_CALL_LOG" "gh repo delete tamashimon-org/force-e2e-20260101-000000 --yes" "後掃除: ほかの掃除（リポジトリ）は続ける"
    unset MOCK_SF_APEX MOCK_CALL_LOG MOCK_GH_REPOS MOCK_SF_ECAS E2E_LIST_RETRY_WAIT
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 18. GitHub での PR を使った流れ（ブランチ・ファイル・PR・マージ・Actions の待ち）
# ------------------------------------------------------------------------------
test_e2e_gh_flow() {
    echo ""; echo -e "${CLR_HEAD}[TEST] GitHub の PR を使った流れ（テスト用のリポジトリだけを操作する）${CLR_RST}"
    _mk_cleanup_env
    local pre='e2e_load_fixture; e2e_guard_env;'
    local repo="tamashimon-org/force-e2e-20260101-000000"

    # ガード: テスト用ではないリポジトリ・別のオーナーは、操作しない
    : > "$MOCK_CALL_LOG"
    _e2e_call "$pre"' e2e_gh_pr_create "tamashimon-org/force-test-win" b t; echo DONE'
    assert_file_not_contains "$MB/out.log" "DONE" "ガード: テスト用ではないリポジトリは、拒否する（異常終了）"
    _e2e_call "$pre"' e2e_gh_pr_create "other-org/force-e2e-20260101-000000" b t; echo DONE'
    assert_file_not_contains "$MB/out.log" "DONE" "ガード: 別のオーナーは、拒否する（異常終了）"
    _e2e_call "$pre"' e2e_gh_pr_merge "tamashimon-org/force-test-win" 1; echo DONE'
    assert_file_not_contains "$MB/out.log" "DONE" "ガード: テスト用ではないリポジトリの PR は、マージしない"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr merge" "ガード: マージのコマンドは、実行されない"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr create" "ガード: PR 作成のコマンドは、実行されない"

    # PR の作成・マージ
    : > "$MOCK_CALL_LOG"
    _e2e_call "$pre"" n=\$(e2e_gh_pr_create $repo e2e-hello 'e2e: Hello'); echo \"PR=[\$n]\""
    assert_file_contains "$MB/out.log" "PR=[7]" "PR 作成: PR 番号を返す"
    assert_file_contains "$MOCK_CALL_LOG" "pr create -R ${repo} --base main --head e2e-hello --title e2e: Hello" "PR 作成: main への PR を作る"
    MOCK_GH_PR_EXIT=1 _e2e_call "$pre"" n=\$(e2e_gh_pr_create $repo e2e-hello t); echo \"RC=\$? PR=[\$n]\""
    assert_file_contains "$MB/out.log" "RC=1 PR=[]" "PR 作成: 失敗 → 戻り値 1（番号なし）"
    _e2e_call "$pre"" e2e_gh_pr_merge $repo 7; echo RC=\$?"
    assert_file_contains "$MOCK_CALL_LOG" "pr merge 7 -R ${repo} --merge" "PR マージ: マージコミットでマージする"
    assert_file_contains "$MB/out.log" "RC=0" "PR マージ: 成功 → 戻り値 0"
    MOCK_GH_MERGE_EXIT=1 _e2e_call "$pre"" e2e_gh_pr_merge $repo 7; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=1" "PR マージ: 失敗 → 戻り値 1"

    # Actions の実行の待ち
    : > "$MOCK_CALL_LOG"
    E2E_POLL_SEC=1 _e2e_call "$pre"" id=\$(e2e_wait_pr_run $repo wf-validate.yml e2e-hello); echo \"RC=\$? ID=[\$id]\""
    assert_file_contains "$MB/out.log" "RC=0 ID=[555]" "Actions の待ち: 完了した実行の ID を返す"
    assert_file_contains "$MOCK_CALL_LOG" "run list -R ${repo} --workflow wf-validate.yml --branch e2e-hello --event pull_request" "Actions の待ち: ブランチと PR のイベントで、実行を探す"
    MOCK_GH_RUN_NONE=1 E2E_RUN_FIND_TRIES=2 E2E_POLL_SEC=0 _e2e_call "$pre"" id=\$(e2e_wait_pr_run $repo wf-release.yml e2e-hello); echo \"RC=\$? ID=[\$id]\""
    assert_file_contains "$MB/out.log" "RC=1 ID=[]" "Actions の待ち: 実行が起動しない → 戻り値 1"
    MOCK_GH_RUN_STATUS=in_progress E2E_WF_TIMEOUT=2 E2E_POLL_SEC=1 _e2e_call "$pre"" id=\$(e2e_wait_pr_run $repo wf-release.yml e2e-hello); echo \"RC=\$? ID=[\$id]\""
    assert_file_contains "$MB/out.log" "RC=1 ID=[]" "Actions の待ち: 時間内に完了しない → 戻り値 1"

    # gh の時間の上限: 応答しない gh は、E2E_GH_TIMEOUT 秒で打ち切り、失敗（戻り値 1 以上）として返す
    cat > "$MB/gh" << 'EOF'
#!/bin/bash
echo "gh $*" >> "${MOCK_CALL_LOG:-/dev/null}"
[[ "$1 $2" == "api user" ]] && { echo "${MOCK_GH_API_USER:-tamashimon}"; exit 0; }  # ガード（e2e_guard_env）の確認は、すぐ返す
exec sleep 20
EOF
    chmod +x "$MB/gh"
    local t0 t1
    t0=$(date +%s)
    E2E_GH_TIMEOUT=1 _e2e_call "$pre"" e2e_gh_pr_merge $repo 7; echo RC=\$?"
    t1=$(date +%s)
    assert_file_not_contains "$MB/out.log" "RC=0" "gh の時間の上限: 応答しない gh は、失敗として返す"
    [[ $((t1 - t0)) -lt 15 ]] && pass "gh の時間の上限: 設定した秒数で打ち切る（待ち続けない）" || fail "gh の時間の上限: 設定した秒数で打ち切る（待ち続けない）" "所要: $((t1 - t0)) 秒"
    _mk_mocks "$MB"

    # ワークフローの結果の読み取り: 空のときだけ、やり直す（完了直後の、反映の遅れ・gh の一時的な失敗への対策）
    local r="tamashimon-org/force-e2e-20260101-000000" rcp='E2E_CONCLUSION_TRIES=4 E2E_POLL_SEC=0'
    _creset() { rm -f "$MB/concl.cnt"; : > "$MOCK_CALL_LOG"; }
    _creset; _e2e_call "$pre"" $rcp; out=\$(e2e_run_conclusion $r 555); echo \"OUT=[\$out]\""
    assert_file_contains "$MB/out.log" "OUT=[success]"  "結果の読み取り: 値があれば、そのまま返す"
    [[ "$(grep -c 'json conclusion' "$MOCK_CALL_LOG")" -eq 1 ]] && pass "結果の読み取り: 値があれば、やり直さない（1 回）" || fail "結果の読み取り: 値があれば、やり直さない" "回数: $(grep -c 'json conclusion' "$MOCK_CALL_LOG")"
    _creset; MOCK_GH_CONCL_EMPTY_FIRST=2 _e2e_call "$pre"" $rcp; out=\$(e2e_run_conclusion $r 555); echo \"OUT=[\$out]\""
    assert_file_contains "$MB/out.log" "OUT=[success]"  "結果の読み取り: 最初の 2 回が空でも、3 回目で値が取れる"
    [[ "$(grep -c 'json conclusion' "$MOCK_CALL_LOG")" -eq 3 ]] && pass "結果の読み取り: 取れたら止まる（3 回）" || fail "結果の読み取り: 取れたら止まる" "回数: $(grep -c 'json conclusion' "$MOCK_CALL_LOG")"
    _creset; MOCK_GH_CONCL_EMPTY_FIRST=all _e2e_call "$pre"" $rcp; out=\$(e2e_run_conclusion $r 555); echo \"OUT=[\$out]\""
    assert_file_contains "$MB/out.log" "OUT=[]"         "結果の読み取り: ずっと空なら、空のまま返す"
    [[ "$(grep -c 'json conclusion' "$MOCK_CALL_LOG")" -eq 4 ]] && pass "結果の読み取り: 上限（4 回）で諦める" || fail "結果の読み取り: 上限で諦める" "回数: $(grep -c 'json conclusion' "$MOCK_CALL_LOG")"
    _creset; MOCK_GH_CONCL=failure _e2e_call "$pre"" $rcp; out=\$(e2e_run_conclusion $r 555); echo \"OUT=[\$out]\""
    assert_file_contains "$MB/out.log" "OUT=[failure]"  "結果の読み取り: failure は、そのまま返す（本当の失敗を、成功にしない）"
    [[ "$(grep -c 'json conclusion' "$MOCK_CALL_LOG")" -eq 1 ]] && pass "結果の読み取り: failure は、やり直さない" || fail "結果の読み取り: failure は、やり直さない" "回数: $(grep -c 'json conclusion' "$MOCK_CALL_LOG")"
    _creset; MOCK_GH_CONCL_EMPTY_FIRST=1 _e2e_call "$pre"" $rcp; out=\$(e2e_step_conclusion $r 555 'ステップ'); echo \"OUT=[\$out]\""
    assert_file_contains "$MB/out.log" "OUT=[success]"  "ステップの結果の読み取り: 空のときは、やり直す"

    # 失敗したワークフローの再実行（1 回だけ）: 試行番号が増えて、完了するまで待つ
    _creset
    _e2e_call "$pre"" E2E_POLL_SEC=0 e2e_rerun_and_wait $r 555; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=0"                                "再実行: 試行番号が増えて完了したら、戻り値 0"
    assert_file_contains "$MOCK_CALL_LOG" "run rerun 555 -R ${r} --failed"   "再実行: 失敗したジョブだけを再実行する（gh run rerun --failed）"
    _creset; rm -f "$MB/rerun.flag"
    MOCK_GH_RERUN_EXIT=1 _e2e_call "$pre"" E2E_POLL_SEC=0 e2e_rerun_and_wait $r 555; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=1"                                "再実行: 再実行の呼び出しが失敗したら、戻り値 1"
    _creset; rm -f "$MB/rerun.flag"
    MOCK_GH_ATTEMPT_STUCK=1 E2E_WF_TIMEOUT=2 E2E_POLL_SEC=1 _e2e_call "$pre"" e2e_rerun_and_wait $r 555; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=1"                                "再実行: 試行番号が増えない（完了が見えない）ときは、時間切れで戻り値 1"
    rm -f "$MB/rerun.flag"

    # run.sh の _run_ok（失敗したら、ログを表示し、1 回だけ再実行する）: run.sh から関数を取り出して、動かす
    { echo "REPO_FULL=$r"; echo '_run_conclusion() { e2e_run_conclusion "$REPO_FULL" "$1"; }'; awk '/^FLAKY_RUNS=0/,/^}/' "$E2E_DIR/run.sh"; } > "$CB/okfuncs.sh"
    local ok="E2E_CONCLUSION_TRIES=1 E2E_POLL_SEC=0; source $CB/okfuncs.sh"
    _creset; rm -f "$MB/rerun.flag"
    _e2e_call "$pre"" $ok; _run_ok 555 wf-x; echo RC=\$? FLAKY=\$FLAKY_RUNS"
    assert_file_contains "$MB/out.log" "RC=0 FLAKY=0"                        "_run_ok: 最初から成功 → 戻り値 0、再実行しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "run rerun"                    "_run_ok: 最初から成功 → 再実行しない"
    _creset; rm -f "$MB/rerun.flag"
    MOCK_GH_CONCL=failure MOCK_GH_CONCL_AFTER=success _e2e_call "$pre"" $ok; _run_ok 555 wf-x; echo RC=\$? FLAKY=\$FLAKY_RUNS"
    assert_file_contains "$MB/out.log" "RC=0 FLAKY=1"                        "_run_ok: 失敗 → 再実行で成功 → 戻り値 0（一時的な失敗として数える）"
    assert_file_contains "$MB/out.log" "再実行で成功しました"                  "_run_ok: 再実行で成功したことを、警告として表示する"
    assert_file_contains "$MB/out.log" "失敗したステップのログ"                "_run_ok: 最初の失敗のログを表示する"
    assert_file_contains "$MOCK_CALL_LOG" "run rerun 555"                    "_run_ok: 1 回、再実行する"
    _creset; rm -f "$MB/rerun.flag"
    MOCK_GH_CONCL=failure _e2e_call "$pre"" $ok; _run_ok 555 wf-x; echo RC=\$? FLAKY=\$FLAKY_RUNS"
    assert_file_contains "$MB/out.log" "RC=1 FLAKY=0"                        "_run_ok: 失敗 → 再実行でも失敗 → 戻り値 1（FAIL）"
    assert_file_contains "$MB/out.log" "再実行でも失敗しました"                "_run_ok: 再実行でも失敗したことを表示する"
    [[ "$(grep -c 'run rerun' "$MOCK_CALL_LOG")" -eq 1 ]] && pass "_run_ok: 再実行は、1 回だけ" || fail "_run_ok: 再実行は、1 回だけ" "回数: $(grep -c 'run rerun' "$MOCK_CALL_LOG")"
    _creset; rm -f "$MB/rerun.flag"
    MOCK_GH_CONCL=failure MOCK_GH_RERUN_EXIT=1 _e2e_call "$pre"" $ok; _run_ok 555 wf-x; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=1"                                "_run_ok: 再実行できなかったら、戻り値 1"
    assert_file_contains "$MB/out.log" "再実行できなかった"                    "_run_ok: 再実行できなかったことを表示する"
    unset -f _creset

    # 失敗した実行のログの表示: ステップ名を付け、色の指定を除き、Token は伏せる。戻り値は 0
    _e2e_call "$pre"" e2e_show_run_failure $repo 555 'wf-validate'; echo RC=\$?"
    assert_file_contains     "$MB/out.log" "[ステップA] Error: 失敗の本文 ***" "失敗ログ: ステップ名付きで表示され、色の指定が除かれる"
    assert_file_contains     "$MB/out.log" "[ステップA] 2 行目"                "失敗ログ: 複数行を表示する"
    assert_file_not_contains "$MB/out.log" "ghp_fakepat"                        "失敗ログ: Token の値は、表示しない（*** に置き換える）"
    assert_file_contains     "$MB/out.log" "RC=0"                               "失敗ログ: 戻り値は 0（表示だけ）"
    MOCK_GH_LOG_NONE=1 _e2e_call "$pre"" e2e_show_run_failure $repo 555 'wf-validate'; echo RC=\$?"
    assert_file_contains     "$MB/out.log" "ログを取得できませんでした"        "失敗ログ: 取得できないときは、その旨を表示する"
    assert_file_contains     "$MB/out.log" "RC=0"                               "失敗ログ: 取得できなくても、戻り値は 0"
    _e2e_call "$pre"' e2e_show_run_failure tamashimon-org/force-test-win 1 x; echo DONE'
    assert_file_not_contains "$MB/out.log" "DONE"                               "失敗ログ: テスト用ではないリポジトリは、拒否する"
assert_file_contains "$E2E_DIR/run.sh" "削除後: Salesforce への管理用ログイン（問い合わせ用）をやり直した" "run.sh: 削除後の件数の確認の前に、管理用ログインをやり直す"    assert_file_contains "$E2E_DIR/run.sh" "リリース後: Salesforce への管理用ログイン（問い合わせ用）をやり直した" "run.sh: リリース後の件数の確認の前に、管理用ログインをやり直す"
    assert_file_contains "$E2E_DIR/run.sh" '_run_ok "$_meta_id" "wf-metasync"' "run.sh: wf-metasync の失敗時は、ログを表示し、1 回だけ再実行する"
    assert_file_contains "$E2E_DIR/run.sh" "再実行で成功したワークフローが" "run.sh: 再実行で成功したワークフローの数を、結果に警告として表示する"
    assert_file_contains "$E2E_DIR/run.sh" '"${label}: wf-validate"' "run.sh: wf-validate の失敗時にログを表示する"
    assert_file_contains "$E2E_DIR/run.sh" '"${label}: wf-release"'  "run.sh: wf-release の失敗時にログを表示する"
    assert_file_contains "$E2E_DIR/run.sh" 'wf-propagate.yml "$br"' "run.sh: マージ時の wf-propagate の実行と成功を確認する"
    assert_file_contains "$E2E_DIR/run.sh" '"${label}: wf-propagate"' "run.sh: wf-propagate の失敗時にログを表示する"
    # 終了時の掃除: 既定は、削除せずに残す（あとから見返せる）。--cleanup で削除する
    assert_file_contains "$E2E_DIR/run.sh" "KEEP=1   # 既定は、終了時に削除しない" "run.sh: 既定は、終了時に削除しない"
    assert_file_contains "$E2E_DIR/run.sh" "--cleanup)    KEEP=0"         "run.sh: --cleanup で、終了時に削除する"
    assert_file_contains "$E2E_DIR/run.sh" 'https://github.com/${REPO_FULL}/actions' "run.sh: 残したリポジトリの URL を表示する"
    # wf-metasync は、Hello World の流れの前に、完了まで待つ（同時に動かすと、取得とデプロイが重なって失敗する）
    local ln_meta ln_hello
    ln_meta=$(grep -n 'chk "wf-metasync が成功した' "$E2E_DIR/run.sh" | head -1 | cut -d: -f1)
    ln_hello=$(grep -n '^        _hello_flow$' "$E2E_DIR/run.sh" | head -1 | cut -d: -f1)
    [[ -n "$ln_meta" && -n "$ln_hello" && "$ln_meta" -lt "$ln_hello" ]] \
        && pass "run.sh: wf-metasync の完了を待ってから、Hello World の流れに進む" \
        || fail "run.sh: wf-metasync の完了を待ってから、Hello World の流れに進む" "metasync=${ln_meta} hello=${ln_hello}"

    # deploy-target.txt / remove-target.txt の本文
    _e2e_call "$pre"' e2e_hello_deploy_target_text; echo "-----"; e2e_hello_remove_target_text'
    assert_file_contains "$MB/out.log" "force-app/main/default/classes/SfToolsE2eHello.cls"     "deploy-target: クラスを [files] で指定する"
    assert_file_contains "$MB/out.log" "force-app/main/default/classes/SfToolsE2eHelloTest.cls" "deploy-target: テストクラスも指定する（テストの自動実行のため）"
    assert_file_contains "$MB/out.log" "ApexClass:SfToolsE2eHelloTest" "remove-target: テストクラスを [members] で指定する"
    assert_file_contains "$MB/out.log" "ApexClass:SfToolsE2eHello"     "remove-target: クラスを [members] で指定する"
    # run.sh: 各 PR に、deploy-target.txt と remove-target.txt の両方を置く（sf-release.sh は両方が無いと止まる）
    assert_file_contains "$E2E_DIR/run.sh" "sf-job.sh" "run.sh: リリースは、sf-job.sh でブランチ作成・clone する（通常の運用と同じ道）"
    assert_file_contains "$E2E_DIR/run.sh" "sf-dryrun.sh" "run.sh: リリースは、sf-dryrun.sh でローカルの検証をする"
    assert_file_contains "$E2E_DIR/run.sh" "sf-push.sh" "run.sh: リリースは、sf-push.sh で commit・push する"
    assert_file_contains "$E2E_DIR/run.sh" 'release/${job}/remove-target.txt' "run.sh: sf-install が用意した remove-target.txt の雛形を確認する"
    assert_file_contains "$E2E_DIR/run.sh" "_hello_write_remove" "run.sh: 削除も、sf-job.sh のジョブで、remove-target.txt を書いて sf-push.sh する"
    assert_file_contains "$E2E_DIR/run.sh" "sf-next.sh" "run.sh: sf-next.sh で、マージ済みの表示を確認する"
    assert_file_contains "$E2E_DIR/run.sh" "sf-deploy.sh" "run.sh: sf-deploy.sh が、共有環境（予約名）への強制リリースを拒否することを確認する"

    # Hello World の Apex のソース: 共有の部品（lib/verify-common.sh）から、そろっている
    _e2e_call 'echo "N=$(verify_hello_paths | wc -l | tr -d " ")"; verify_hello_content_for force-app/main/default/classes/SfToolsE2eHelloTest.cls | grep -q @isTest && echo ISTEST'
    assert_file_contains "$MB/out.log" "N=4" "Hello World: クラスのファイルが 4 つある"
    assert_file_contains "$MB/out.log" "ISTEST" "Hello World: テストクラスに @isTest がある（RunSpecifiedTests の自動検出に必要）"
    unset MOCK_CALL_LOG MOCK_GH_REPOS MOCK_SF_ECAS
    teardown "$CB"
}


# ------------------------------------------------------------------------------
# 19. sf-tools のコマンドを、通常の運用と同じように実行する部品（sf-job.sh / sf-push.sh などの実行・待ち・code の差し替え）
# ------------------------------------------------------------------------------
test_e2e_sf_cmd() {
    echo ""; echo -e "${CLR_HEAD}[TEST] sf-tools のコマンドの実行（標準入力・出力の記録・失敗時の表示・安全ガード）と、code の差し替え${CLR_RST}"
    _mk_cleanup_env
    local root="$CB/root/home/tamashimon-org/e2e-20260101-000000"   # _mk_cleanup_env が作る、テスト用の作業フォルダ
    local tmp="$CB/tmp"; mkdir -p "$tmp"
    local pre='e2e_load_fixture; e2e_guard_env; export E2E_TMP='"$tmp"';'

    # 実行するスクリプト（標準入力をそのまま出力し、cwd と SF_LAUNCHER_ACTIVE を記録する）
    cat > "$CB/fake.sh" << 'EOF2'
#!/bin/bash
echo "cwd=$(basename "$PWD") launcher=${SF_LAUNCHER_ACTIVE:-} args=$*"
while IFS= read -r l; do echo "in=[$l]"; done
exit "${FAKE_EXIT:-0}"
EOF2
    _e2e_call "$pre"" e2e_run_sf_cmd lbl $root 'job-1\nY\nalias\n' $CB/fake.sh --opt x; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=0"                               "コマンド実行: 成功 → 戻り値 0"
    assert_file_contains "$tmp/lbl.out" "cwd=e2e-20260101-000000 launcher=1 args=--opt x" "コマンド実行: 指定のフォルダで、SF_LAUNCHER_ACTIVE=1 で、引数付きで実行される"
    assert_file_contains "$tmp/lbl.out" "in=[job-1]"                         "コマンド実行: 標準入力（1 行目）が渡る"
    assert_file_contains "$tmp/lbl.out" "in=[Y]"                             "コマンド実行: 標準入力（2 行目）が渡る"
    assert_file_contains "$tmp/lbl.out" "in=[alias]"                         "コマンド実行: 標準入力（3 行目）が渡る"

    # 失敗: 終了コードが 0 以外 → 戻り値 1 と、出力の末尾の表示（鍵の値は伏せる）
    printf '#!/bin/bash\necho "失敗の本文 ghp_fakepat"\nexit 3\n' > "$CB/fail.sh"
    _e2e_call "$pre"" e2e_run_sf_cmd lbl2 $root '' $CB/fail.sh; echo RC=\$?"
    assert_file_contains     "$MB/out.log" "RC=1"                            "コマンド実行: 失敗 → 戻り値 1"
    assert_file_contains     "$MB/out.log" "終了コード 3"                    "コマンド実行: 失敗 → 終了コードを表示する"
    assert_file_contains     "$MB/out.log" "失敗の本文 ***"                  "コマンド実行: 失敗 → 出力の末尾を表示する（Token は *** に置き換える）"
    assert_file_not_contains "$MB/out.log" "ghp_fakepat"                     "コマンド実行: 失敗 → Token の値は表示しない"

    # 安全ガード: テスト用の作業フォルダの外では、実行しない
    _e2e_call "$pre"" e2e_run_sf_cmd lbl3 $HM '' $CB/fake.sh; echo DONE"
    assert_file_not_contains "$MB/out.log" "DONE"                            "安全ガード: テスト用の作業フォルダの外では、実行しない"
    _e2e_call "$pre"" e2e_run_sf_cmd lbl4 $CB/root/home/tamashimon-org/test-win '' $CB/fake.sh; echo DONE"
    assert_file_not_contains "$MB/out.log" "DONE"                            "安全ガード: 名前が e2e- で始まらないフォルダ（test-win）では、実行しない"
    assert_file_not_exists "$tmp/lbl3.out"                                   "安全ガード: 拒否したときは、実行しない（出力ファイルがない）"

    # 経過の表示と、時間の上限: 長い処理が、止まったのか動いているのか分かる。上限を超えたら、打ち切る
    printf '#!/bin/bash\nsleep 3\necho done\n' > "$CB/slow.sh"
    _e2e_call "$pre"" E2E_HEARTBEAT_SEC=1 E2E_CMD_POLL_SEC=1 e2e_run_sf_cmd hb $root '' $CB/slow.sh; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=0"                                "経過の表示: 時間内に終われば、成功"
    assert_file_contains "$MB/out.log" "実行中: hb（経過"                     "経過の表示: 長い処理の途中で、経過時間を表示する"
    printf '#!/bin/bash\nexec sleep 30\n' > "$CB/hang.sh"
    local t0 t1; t0=$(date +%s)
    _e2e_call "$pre"" E2E_CMD_TIMEOUT=2 E2E_CMD_POLL_SEC=1 e2e_run_sf_cmd to $root '' $CB/hang.sh; echo RC=\$?"
    t1=$(date +%s)
    assert_file_contains "$MB/out.log" "RC=1"                                "時間の上限: 止まったままの処理は、打ち切って、戻り値 1"
    assert_file_contains "$MB/out.log" "時間切れ"                             "時間の上限: 時間切れであることを表示する"
    [[ $((t1 - t0)) -lt 20 ]] && pass "時間の上限: 上限の秒数で打ち切る（待ち続けない）" || fail "時間の上限: 上限の秒数で打ち切る（待ち続けない）" "所要: $((t1 - t0)) 秒"

    # 拒否されること（終了コード 0 以外）の確認: 拒否されれば戻り値 0、成功してしまえば 1
    printf '#!/bin/bash\necho "prod は共有環境のため、拒否します"\nexit 1\n' > "$CB/refuse.sh"
    _e2e_call "$pre"" e2e_run_sf_cmd_refused rf $root '' $CB/refuse.sh; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=0"                                "拒否の確認: 終了コード 1 → 拒否された → 戻り値 0"
    assert_file_contains "$tmp/rf.out" "共有環境のため"                       "拒否の確認: 出力が、ファイルに残る"
    _e2e_call "$pre"" e2e_run_sf_cmd_refused rf2 $root '' $CB/fake.sh; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=1"                                "拒否の確認: 成功してしまった → 戻り値 1"
    assert_file_contains "$MB/out.log" "拒否されるはずが"                     "拒否の確認: 成功してしまったことを表示する"
    _e2e_call "$pre"" e2e_run_sf_cmd_refused rf3 $HM '' $CB/refuse.sh; echo DONE"
    assert_file_not_contains "$MB/out.log" "DONE"                            "拒否の確認: テスト用の作業フォルダの外では、実行しない"

    # sf-install の完了待ち（ログの完了メッセージ）
    mkdir -p "$root/clone1/sf-tools/logs" "$root/clone2/sf-tools/logs"
    echo "[SUCCESS] npm install の確認が完了しました。" > "$root/clone1/sf-tools/logs/sf-install.log"
    echo "[INFO] 途中" > "$root/clone2/sf-tools/logs/sf-install.log"
    _e2e_call "$pre"" E2E_INSTALL_TIMEOUT=2 E2E_POLL_SEC=1 e2e_wait_sf_install $root/clone1; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=0"                                "sf-install の待ち: 完了メッセージがあれば、戻り値 0"
    _e2e_call "$pre"" E2E_INSTALL_TIMEOUT=2 E2E_POLL_SEC=1 e2e_wait_sf_install $root/clone2; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=1"                                "sf-install の待ち: 完了しなければ、時間切れで戻り値 1"
    _e2e_call "$pre"" E2E_INSTALL_TIMEOUT=2 E2E_POLL_SEC=1 e2e_wait_sf_install $root/none; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=1"                                "sf-install の待ち: ログがなければ、戻り値 1"

    # code の差し替え: --wait とファイルでメッセージを書き込む。code . は何もしない
    local sh="$E2E_DIR/shims/code" f="$CB/msg.txt"
    printf '# コメント\n' > "$f"
    E2E_COMMIT_MSG="e2e: テスト" bash "$sh" --new-window --wait "$f"; local rc=$?
    assert_exit_ok "$rc" "code の差し替え: --wait → 終了コード 0"
    assert_file_contains "$f" "e2e: テスト" "code の差し替え: --wait → コミットメッセージを書き込む"
    printf '# コメント\n' > "$f"
    bash "$sh" .; rc=$?
    assert_exit_ok "$rc" "code の差し替え: code . → 終了コード 0"
    assert_file_not_contains "$f" "e2e" "code の差し替え: code . → ファイルは変えない"
    unset MOCK_CALL_LOG MOCK_GH_REPOS MOCK_SF_ECAS
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 20. コードレビュー（2026-10-06）の指摘への対応: 本物のエイリアスを守る・掃除を止めない・取り違えを防ぐ
# ------------------------------------------------------------------------------
test_e2e_review_fixes() {
    echo ""; echo -e "${CLR_HEAD}[TEST] レビューの指摘への対応（エイリアスの保護・掃除の継続・実行の取り違え・秘密の伏せ字）${CLR_RST}"
    _mk_cleanup_env
    local snap="$CB/snap.txt"
    local pre='e2e_load_fixture; e2e_guard_env;'

    # エイリアスの保存: sf alias list に失敗したら、空の一覧を保存せず、失敗として返す（復元で、本物のエイリアスを外さないため）
    MOCK_SF_ALIAS_FAIL=1 _e2e_call "e2e_alias_snapshot $snap; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=1"                                "エイリアスの保存: sf alias list の失敗 → 戻り値 1"
    assert_file_not_exists "${snap}.ok"                                      "エイリアスの保存: 失敗 → 保存成功の目印を作らない"
    MOCK_SF_ALIASES="prod=real@example.com" _e2e_call "e2e_alias_snapshot $snap; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=0"                                "エイリアスの保存: 成功 → 戻り値 0"
    assert_file_exists "${snap}.ok"                                          "エイリアスの保存: 成功 → 目印ができる"
    # エイリアスが 0 件でも、正常に保存できる
    rm -f "$snap" "${snap}.ok"
    _e2e_call "e2e_alias_snapshot $snap; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=0"                                "エイリアスの保存: エイリアスが 0 件でも、成功する"

    # 復元: 目印がなければ、何もしない。sf alias list に失敗したときも、何も外さない
    : > "$MOCK_CALL_LOG"; rm -f "${snap}.ok"; printf '' > "$snap"
    MOCK_SF_ALIASES="prod=real@example.com" _e2e_call "e2e_alias_restore $snap; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=1"                                "エイリアスの復元: 保存の目印がない → 戻り値 1"
    assert_file_not_contains "$MOCK_CALL_LOG" "alias unset"                  "エイリアスの復元: 保存の目印がない → 何も外さない（本物の prod を守る）"
    : > "${snap}.ok"; : > "$MOCK_CALL_LOG"
    MOCK_SF_ALIAS_FAIL=1 _e2e_call "e2e_alias_restore $snap; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=1"                                "エイリアスの復元: sf alias list の失敗 → 戻り値 1"
    assert_file_not_contains "$MOCK_CALL_LOG" "alias unset"                  "エイリアスの復元: sf alias list の失敗 → 何も外さない"

    # 掃除: 管理用ログインに失敗しても、ローカルの掃除は続ける（失敗として終わる）
    : > "$MOCK_CALL_LOG"
    MOCK_SF_ADMIN_FAIL_FIRST=99 E2E_ADMIN_RETRY_WAIT=0 _run_cleanup --yes --no-confirm; local rc=$?
    assert_exit_fail "$rc"                                                   "掃除: 管理用ログインに失敗 → 失敗で終わる"
    assert_file_contains "$MB/out.log" "管理用ログインに失敗したため"          "掃除: 管理用ログインの失敗を表示する"
    assert_file_contains "$MOCK_CALL_LOG" "gh repo delete tamashimon-org/force-e2e-20260101-000000 --yes" "掃除: ログインに失敗しても、GitHub の掃除はする"
    assert_dir_not_exists "$CB/root/home/tamashimon-org/e2e-20260101-000000" "掃除: ログインに失敗しても、ローカルの掃除は続ける"
    assert_file_not_contains "$MOCK_CALL_LOG" "post-destructive"             "掃除: ログインに失敗 → Salesforce の削除は、しない"

    # 秘密の伏せ字: 鍵一式の値・認証 URL の形式・Token らしい文字列
    _e2e_call "$pre"' _e2e_mask_line "a ghp_fakepat b xoxb-fakeslack c force://PlatformCLI::someothertoken@x.my.salesforce.com d ghp_ANOTHERtoken123"'
    assert_file_not_contains "$MB/out.log" "ghp_fakepat"                     "伏せ字: 鍵一式の PAT を伏せる"
    assert_file_not_contains "$MB/out.log" "xoxb-fakeslack"                  "伏せ字: 鍵一式の Slack Token を伏せる"
    assert_file_not_contains "$MB/out.log" "someothertoken"                  "伏せ字: 認証 URL の形式のリフレッシュトークンを伏せる（鍵一式と別の値でも）"
    assert_file_not_contains "$MB/out.log" "ANOTHERtoken123"                 "伏せ字: 鍵一式と別の PAT らしい文字列も伏せる"

    # 拒否の確認: フォルダがない（実行そのものの失敗）を、拒否と取り違えない
    _e2e_call "$pre"" E2E_TMP=$CB/tmp; mkdir -p \$E2E_TMP; e2e_run_sf_cmd_refused rf $CB/root/home/tamashimon-org/e2e-nothere '' $CB/fake.sh; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=1"                                "拒否の確認: フォルダがない（終了コード 125）→ 拒否とみなさない（戻り値 1）"
    assert_file_contains "$MB/out.log" "実行そのものに失敗しました"             "拒否の確認: 実行そのものの失敗として表示する"

    # run.sh から関数を取り出して動かす（_pushed_to_remote / _dispatch_workflow）
    { echo "REPO_FULL=tamashimon-org/force-e2e-20260101-000000"; echo 'sleep() { :; }'
      awk '/^_pushed_to_remote\(\) \{/,/^}/' "$E2E_DIR/run.sh"
      awk '/^_dispatch_workflow\(\) \{/,/^}/' "$E2E_DIR/run.sh"; } > "$CB/runfuncs.sh"
    # push した内容の一致: 空どうし（読めない）は、一致とみなさない。本物の git で、一致・不一致を確認する
    _e2e_call "$pre"" source $CB/runfuncs.sh; _pushed_to_remote $CB/no-such-dir job; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=1"                                "push の一致: 両方読めない（空どうし）→ 一致とみなさない"
    local g="git -c user.name=t -c user.email=t@example.com"
    git init -q --bare "$CB/o.git" 2>/dev/null; git clone -q "$CB/o.git" "$CB/w" 2>/dev/null
    ( cd "$CB/w" && git checkout -q -b job 2>/dev/null; echo a > a; git add a; $g commit -q -m i; git push -q origin job 2>/dev/null )
    _e2e_call "$pre"" source $CB/runfuncs.sh; _pushed_to_remote $CB/w job; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=0"                                "push の一致: 手元の HEAD と、リモートが一致 → 一致"
    ( cd "$CB/w" && echo b > b; git add b; $g commit -q -m j )
    _e2e_call "$pre"" source $CB/runfuncs.sh; _pushed_to_remote $CB/w job; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=1"                                "push の一致: push していないコミットがある → 不一致"

    # 手動起動した実行の特定: 起動の前の実行（古い実行）を取り違えない
    : > "$MOCK_CALL_LOG"; rm -f "$MB/disp.cnt"
    _e2e_call "$pre"" source $CB/runfuncs.sh; id=\$(_dispatch_workflow wf-metasync.yml); echo \"RC=\$? ID=[\$id]\""
    assert_file_contains "$MB/out.log" "RC=0 ID=[101]"                       "手動起動: 起動のあとに現れた新しい実行の ID を返す"
    assert_file_contains "$MOCK_CALL_LOG" "workflow run wf-metasync.yml"     "手動起動: 起動を呼び出す"
    rm -f "$MB/disp.cnt"
    MOCK_GH_DISPATCH_AFTER=100 _e2e_call "$pre"" source $CB/runfuncs.sh; id=\$(_dispatch_workflow wf-metasync.yml); echo \"RC=\$? ID=[\$id]\""
    assert_file_contains "$MB/out.log" "RC=1 ID=[]"                          "手動起動: 新しい実行が現れない（古い実行のまま）→ 古い実行を返さず、戻り値 1"
    rm -f "$MB/disp.cnt"; : > "$MOCK_CALL_LOG"
    MOCK_GH_WORKFLOW_EXIT=1 _e2e_call "$pre"" source $CB/runfuncs.sh; id=\$(_dispatch_workflow wf-metasync.yml); echo \"RC=\$? ID=[\$id]\""
    assert_file_contains "$MB/out.log" "RC=1 ID=[]"                          "手動起動: 起動の呼び出しがすべて失敗 → 戻り値 1（実行を探さない）"
    [[ "$(grep -c 'event workflow_dispatch' "$MOCK_CALL_LOG")" -le 1 ]] && pass "手動起動: 起動に失敗したら、実行の ID を探さない" || fail "手動起動: 起動に失敗したら、実行の ID を探さない"


    # --resume: 前回残したテスト用の作業フォルダ（最新の 1 つ）を使う / 前回の残りの Hello World の Apex を削除する
    { echo 'sleep() { :; }'
      awk '/^_find_resume_project\(\) \{/,/^}/' "$E2E_DIR/run.sh"
      awk '/^_resume_clean_apex\(\) \{/,/^}/' "$E2E_DIR/run.sh"; } > "$CB/resumefuncs.sh"
    mkdir -p "$CB/root/home/tamashimon-org/e2e-20260101-000000"   # 直前の掃除のテストで、消えているため、作り直す
    _e2e_call "$pre"" source $CB/resumefuncs.sh; p=\$(_find_resume_project); echo \"RC=\$? P=[\$p]\""
    assert_file_contains "$MB/out.log" "RC=0 P=[e2e-20260101-000000]"       "再開: 前回の作業フォルダがあれば、その名前を返す"
    mkdir -p "$CB/root/home/tamashimon-org/e2e-20260202-020202" "$CB/root/home/tamashimon-org/e2e-notatimestamp"
    _e2e_call "$pre"" source $CB/resumefuncs.sh; p=\$(_find_resume_project); echo \"RC=\$? P=[\$p]\""
    assert_file_contains "$MB/out.log" "RC=0 P=[e2e-20260202-020202]"       "再開: 複数あれば、最新の（日時が新しい）ものを返す。形式が違う名前は、無視する"
    rm -rf "$CB"/root/home/tamashimon-org/e2e-*
    _e2e_call "$pre"" source $CB/resumefuncs.sh; p=\$(_find_resume_project); echo \"RC=\$? P=[\$p]\""
    assert_file_contains "$MB/out.log" "RC=1 P=[]"                           "再開: 前回の作業フォルダがなければ、戻り値 1"
    : > "$MOCK_CALL_LOG"
    MOCK_SF_APEX="SfToolsE2eHello SfToolsE2eHelloTest OtherClass" _e2e_call "$pre"" source $CB/resumefuncs.sh; _resume_clean_apex; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=0"                                "再開: 前回の残りの Apex があれば、削除して、戻り値 0"
    assert_file_contains "$MOCK_CALL_LOG" "<members>SfToolsE2eHello</members>"  "再開: 前回の残りの Hello World の Apex を削除する"
    assert_file_not_contains "$MOCK_CALL_LOG" "OtherClass"                   "再開: 無関係のクラスは、削除しない"
    : > "$MOCK_CALL_LOG"
    MOCK_SF_APEX="OtherClass" _e2e_call "$pre"" source $CB/resumefuncs.sh; _resume_clean_apex; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=0"                                "再開: 残りがなければ、何もせず、戻り値 0"
    assert_file_not_contains "$MOCK_CALL_LOG" "post-destructive"             "再開: 残りがなければ、削除のデプロイをしない"
    assert_file_contains "$E2E_DIR/run.sh" "--resume)     RESUME=1 ;;"       "run.sh: --resume のオプションがある"
    assert_file_contains "$E2E_DIR/run.sh" "if [[ \$RESUME -eq 0 ]]; then"   "run.sh: --resume では、wf-metasync を行わない"
    assert_file_contains "$E2E_DIR/run.sh" 'JOB_RELEASE="e2e-hello-${RUN_ID}"' "run.sh: ジョブ名は、時刻付き（--resume で、同じリポジトリを使っても、ぶつからない）"
    assert_file_contains "$E2E_DIR/run.sh" "-t main --no-open" "run.sh: sf-deploy の拒否の確認は、予約名 main で行う（開発者の本物の prod を避ける）"
    unset MOCK_CALL_LOG MOCK_GH_REPOS MOCK_SF_ECAS
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 段階ごとのテスト用組織（staging・develop は任意）・層数ごとの段階の一覧
# ------------------------------------------------------------------------------
test_e2e_tiers() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 段階ごとのテスト用組織・層数ごとの段階の一覧${CLR_RST}"
    local mb out; mb=$(setup_mock_bin); MB="$mb"; FX="$mb/fx.env"; HM="$mb"
    export MOCK_CALL_LOG="$mb/calls.log"; _mk_mocks "$mb"

    # main だけの鍵一式: staging・develop は、使えない
    _mk_fixture "$FX"
    _e2e_call 'e2e_load_fixture; e2e_tier_available main && echo MAIN_OK; e2e_tier_available staging && echo STG_OK; e2e_tier_available develop && echo DEV_OK; echo LOADED'
    assert_file_contains     "$mb/out.log" "LOADED"   "main だけの鍵一式を、読み込める（staging・develop は任意）"
    assert_file_contains     "$mb/out.log" "MAIN_OK"  "main の組織は、使える"
    assert_file_not_contains "$mb/out.log" "STG_OK"   "staging の組織がなければ、使えない"
    assert_file_not_contains "$mb/out.log" "DEV_OK"   "develop の組織がなければ、使えない"

    # staging・develop も入った鍵一式
    _mk_fixture "$FX"
    echo "E2E_SFDX_AUTH_URL_STG=force://PlatformCLI::stgurl@stg.my.salesforce.com" >> "$FX"
    echo "E2E_SFDX_AUTH_URL_DEV=force://PlatformCLI::devurl@dev.my.salesforce.com" >> "$FX"
    _e2e_call 'e2e_load_fixture; e2e_tier_available staging && echo STG_OK; e2e_tier_available develop && echo DEV_OK
               echo "URL_STG=$(e2e_tier_url staging)"; echo "ALIAS_MAIN=$(e2e_tier_alias main)"; echo "ALIAS_STG=$(e2e_tier_alias staging)"; echo "ALIAS_DEV=$(e2e_tier_alias develop)"'
    assert_file_contains     "$mb/out.log" "STG_OK"   "staging の組織が、使える"
    assert_file_contains     "$mb/out.log" "DEV_OK"   "develop の組織が、使える"
    assert_file_contains     "$mb/out.log" "URL_STG=force://PlatformCLI::stgurl@stg.my.salesforce.com" "段階の認証 URL を取得できる"
    assert_file_contains     "$mb/out.log" "ALIAS_MAIN=sf-tools-e2e-admin"      "main の管理用エイリアスは、従来どおり"
    assert_file_contains     "$mb/out.log" "ALIAS_STG=sf-tools-e2e-admin-stg"   "staging の管理用エイリアス"
    assert_file_contains     "$mb/out.log" "ALIAS_DEV=sf-tools-e2e-admin-dev"   "develop の管理用エイリアス"

    # 認証 URL の値は、表示・ログに出ない（伏せ字になる）
    _e2e_call 'e2e_load_fixture; _e2e_mask_line "x force://PlatformCLI::stgurl@stg.my.salesforce.com y"'
    assert_file_not_contains "$mb/out.log" "stgurl"   "staging の認証 URL は、伏せ字になる"

    # 形式が違う staging の認証 URL → 読み込みに失敗する
    _mk_fixture "$FX"; echo "E2E_SFDX_AUTH_URL_STG='[REDACTED] not-a-url'" >> "$FX"
    _e2e_call 'e2e_load_fixture; echo LOADED'
    assert_file_not_contains "$mb/out.log" "LOADED"                         "staging の認証 URL の形式が違うと、読み込みに失敗する"
    assert_file_contains     "$mb/out.log" "E2E_SFDX_AUTH_URL_STG が認証 URL の形式ではありません" "理由が表示される"

    # 層数 → 段階の一覧（develop → staging → main の順）
    _mk_fixture "$FX"
    _e2e_call 'echo "L1=$(e2e_layout_tiers 1 | tr "\n" ",")"; echo "L2=$(e2e_layout_tiers 2 | tr "\n" ",")"; echo "L3=$(e2e_layout_tiers 3 | tr "\n" ",")"; e2e_layout_tiers 4 || echo "L4=NG"'
    assert_file_contains     "$mb/out.log" "L1=main,"                     "1 層: main"
    assert_file_contains     "$mb/out.log" "L2=staging,main,"             "2 層: staging → main"
    assert_file_contains     "$mb/out.log" "L3=develop,staging,main,"     "3 層: develop → staging → main"
    assert_file_contains     "$mb/out.log" "L4=NG"                        "範囲外の層数は、エラー"

    # 組織 ID の取得（sf org display の JSON から、00D で始まる ID を取り出す）
    cat > "$mb/sf" << 'EOF'
#!/bin/bash
echo "sf $*" >> "${MOCK_CALL_LOG:-/dev/null}"
case "$1 $2" in
    "org display") echo "${MOCK_SF_DISPLAY_JSON:-}"; exit "${MOCK_SF_DISPLAY_EXIT:-0}" ;;
esac
exit 0
EOF
    chmod +x "$mb/sf"
    export MOCK_SF_DISPLAY_JSON='{"status":0,"result":{"id":"00D5g00000FDr1YEAT","username":"a@example.com","instanceUrl":"https://x.my.salesforce.com"}}'
    _e2e_call 'echo "ID=$(e2e_org_id some-alias)"'
    assert_file_contains     "$mb/out.log" "ID=00D5g00000FDr1YEAT"        "組織 ID を取得できる"
    export MOCK_SF_DISPLAY_JSON='{"status":0,"result":{"username":"a@example.com"}}'
    _e2e_call 'e2e_org_id some-alias && echo "GOT" || echo "NONE"'
    assert_file_contains     "$mb/out.log" "NONE"                         "組織 ID が JSON にないときは、取得失敗"
    unset MOCK_SF_DISPLAY_JSON MOCK_CALL_LOG
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# 層数対応（段階ごとの PR・実行の取り違えの防止・段階ごとの掃除・sf-init の入力）
# ------------------------------------------------------------------------------
test_e2e_layout() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 層数対応（段階ごとの PR・実行の基準・段階ごとの掃除・入力の台本）${CLR_RST}"
    _mk_cleanup_env
    local pre='e2e_load_fixture; e2e_guard_env;'
    local repo="tamashimon-org/force-e2e-20260101-000000"

    # PR の作成: base（段階）を指定できる。省略は main
    : > "$MOCK_CALL_LOG"
    _e2e_call "$pre"" n=\$(e2e_gh_pr_create $repo e2e-hello 'e2e: Hello' staging); echo \"PR=[\$n]\""
    assert_file_contains "$MOCK_CALL_LOG" "pr create -R ${repo} --base staging --head e2e-hello" "PR 作成: 指定した段階（staging）への PR を作る"

    # 実行の基準: 最新の実行 ID（なければ 0）
    _e2e_call "$pre"" id=\$(e2e_latest_run_id $repo wf-validate.yml e2e-hello); echo \"ID=[\$id]\""
    assert_file_contains "$MB/out.log" "ID=[555]" "最新の実行 ID を返す"
    MOCK_GH_RUN_NONE=1 _e2e_call "$pre"" id=\$(e2e_latest_run_id $repo wf-validate.yml e2e-hello); echo \"ID=[\$id]\""
    assert_file_contains "$MB/out.log" "ID=[0]" "実行がなければ 0"

    # 実行の待ち: 「この ID より新しい実行」だけを対象にする（前の PR の実行を、取り違えない）
    MOCK_GH_RUN_ID=555 E2E_RUN_FIND_TRIES=2 E2E_POLL_SEC=0 _e2e_call "$pre"" id=\$(e2e_wait_pr_run $repo wf-release.yml e2e-hello 555); echo \"RC=\$? ID=[\$id]\""
    assert_file_contains "$MB/out.log" "RC=1 ID=[]" "実行の待ち: 基準と同じ ID（前の PR の実行）は、対象にしない"
    MOCK_GH_RUN_ID=556 E2E_RUN_FIND_TRIES=2 E2E_POLL_SEC=0 _e2e_call "$pre"" id=\$(e2e_wait_pr_run $repo wf-release.yml e2e-hello 555); echo \"RC=\$? ID=[\$id]\""
    assert_file_contains "$MB/out.log" "RC=0 ID=[556]" "実行の待ち: 基準より新しい実行を、対象にする"

    # 段階ごとの掃除: 鍵一式にある staging・develop の組織にも、ログインして掃除する
    echo "E2E_SFDX_AUTH_URL_STG=force://PlatformCLI::stgurl@stg.my.salesforce.com" >> "$FX"
    echo "E2E_SFDX_AUTH_URL_DEV=force://PlatformCLI::devurl@dev.my.salesforce.com" >> "$FX"
    : > "$MOCK_CALL_LOG"
    _e2e_call "$pre"" e2e_cleanup_all list; echo RC=\$?"
    assert_file_contains "$MOCK_CALL_LOG" "--alias sf-tools-e2e-admin-stg" "掃除: staging の組織にログインする（段階のエイリアス）"
    assert_file_contains "$MOCK_CALL_LOG" "--alias sf-tools-e2e-admin-dev" "掃除: develop の組織にログインする（段階のエイリアス）"
    assert_file_contains "$MOCK_CALL_LOG" "--alias sf-tools-e2e-admin" "掃除: main の組織にも、ログインする"

    # 段階を指定した管理用ログイン: 鍵一式にない段階は、中断する
    _mk_fixture "$FX"
    _e2e_call "$pre"" ( E2E_TIER=develop; e2e_sf_admin_login; echo LOGGED_IN ); echo RC=\$?"
    assert_file_not_contains "$MB/out.log" "LOGGED_IN" "鍵一式にない段階の組織へは、ログインしない（中断する）"
    assert_file_contains     "$MB/out.log" "RC=1" "中断する（終了コード 1）"
    assert_file_contains     "$MB/out.log" "bootstrap.sh --add-orgs" "追加の方法が表示される"

    # sf-init に流す入力の台本（層数ごと）: Phase 5 の番号と、ログイン先の答えの数
    _e2e_call 'e2e_load_fixture; e2e_make_input 2 | tr "\n" ","'
    assert_file_contains "$MB/out.log" "Y,Y,2,Y,2,ghp_fakepat,,xoxb-fakeslack,C01ABCDEFGH,,1,1," "台本（2 層）: Phase 5 は 2・ログイン先は 2 つ"
    _e2e_call 'e2e_load_fixture; e2e_make_input 3 | tr "\n" ","'
    assert_file_contains "$MB/out.log" "Y,Y,2,Y,1,ghp_fakepat,,xoxb-fakeslack,C01ABCDEFGH,,1,1,1," "台本（3 層）: Phase 5 は 1・ログイン先は 3 つ"
    _e2e_call 'e2e_load_fixture; e2e_make_input | tr "\n" ","'
    assert_file_contains "$MB/out.log" "Y,Y,2,Y,3,ghp_fakepat,,xoxb-fakeslack,C01ABCDEFGH,,1," "台本（既定 = 1 層）: Phase 5 は 3・ログイン先は 1 つ"
    _e2e_call 'e2e_load_fixture; e2e_make_input 4; echo "RC=$?"'
    assert_file_contains "$MB/out.log" "RC=1" "範囲外の層数は、エラー"

    unset MOCK_CALL_LOG MOCK_GH_REPOS MOCK_SF_ECAS
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 対話（引数なし）の sf-init に流す、先頭の入力（オーナーの選択 → XXXX → 確認）
# ------------------------------------------------------------------------------
test_e2e_identity_input() {
    echo ""; echo -e "${CLR_HEAD}[TEST] e2e_make_identity_input: 対話の入力の台本（オーナーの選択・XXXX・確認）${CLR_RST}"
    local mb; mb=$(setup_mock_bin); MB="$mb"; FX="$mb/fx.env"; HM="$mb"
    create_mock_gh "$mb"; _mk_fixture "$FX"

    # 候補が複数（org-a・tamashimon-org・自分の tama）→ tamashimon-org は 2 番目
    export MOCK_GH_ORGS_ADMIN=$'org-a\ntamashimon-org' MOCK_GH_API_USER=tama
    _e2e_call 'e2e_make_identity_input tamashimon-org e2e-1 | tr "\n" ","; echo "RC=${PIPESTATUS[0]}"'
    assert_file_contains "$MB/out.log" "2,e2e-1,Y,RC=0" "候補が複数 → 番号（位置）で選び、XXXX と確認 Y を続ける"

    # 候補が 1 つ（自分のアカウントだけ）で、それがオーナー → 番号は聞かれない
    export MOCK_GH_ORGS_ADMIN="" MOCK_GH_API_USER=tamashimon-org
    _e2e_call 'e2e_make_identity_input tamashimon-org e2e-1 | tr "\n" ","; echo "RC=${PIPESTATUS[0]}"'
    assert_file_contains "$MB/out.log" "e2e-1,Y,RC=0" "候補が 1 つ → 番号なしで、XXXX と確認 Y だけ"

    # オーナーが候補にない → 戻り値 1（誤った組織を選ばない）
    export MOCK_GH_ORGS_ADMIN=$'org-a\norg-b' MOCK_GH_API_USER=tama
    _e2e_call 'e2e_make_identity_input tamashimon-org e2e-1 > /dev/null; echo "RC=$?"'
    assert_file_contains "$MB/out.log" "RC=1" "オーナーが候補にない → 戻り値 1"

    # gh が使えない（候補なし）→ オーナーを入力する
    printf '#!/bin/bash\nexit 1\n' > "$mb/gh"; chmod +x "$mb/gh"
    _e2e_call 'e2e_make_identity_input tamashimon-org e2e-1 | tr "\n" ","; echo "RC=${PIPESTATUS[0]}"'
    assert_file_contains "$MB/out.log" "tamashimon-org,e2e-1,Y,RC=0" "候補がない → オーナーを入力してから、XXXX と確認 Y"

    unset MOCK_GH_ORGS_ADMIN MOCK_GH_API_USER
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# bootstrap.sh --add-orgs: staging・develop の組織の追加（別々の組織であることの確認）
#   sf のモック: 組織の ID は、認証 URL から決まる（同じ URL = 同じ組織）。login web は、MOCK_SF_WEB_URLS（改行区切り）を、順に使う
# ------------------------------------------------------------------------------
test_e2e_bootstrap_add_orgs() {
    echo ""; echo -e "${CLR_HEAD}[TEST] bootstrap.sh --add-orgs（別々の組織であることの確認）${CLR_RST}"
    local mb d fx rc
    mb=$(setup_mock_bin); MB="$mb"; HM="$mb"; d="$mb"
    export MOCK_CALL_LOG="$mb/calls.log"; : > "$MOCK_CALL_LOG"
    _mk_mocks "$mb"
    cat > "$mb/sf" << 'EOF'
#!/bin/bash
echo "sf $*" >> "${MOCK_CALL_LOG:-/dev/null}"
_d="${MOCK_CALL_LOG%/*}"
_id_of() { printf '00D%012d' "$(printf '%s' "$1" | cksum | awk '{print $1}')"; }
_arg() { local k="$1"; shift; while [[ $# -gt 0 ]]; do [[ "$1" == "$k" ]] && { echo "$2"; return; }; shift; done; }
case "$1 $2 $3" in
    "org login sfdx-url")
        f=$(_arg --sfdx-url-file "$@"); a=$(_arg --alias "$@")
        cat "$f" > "$_d/alias_$a.url"; exit 0 ;;
    "org login web")
        a=$(_arg --alias "$@")
        u=$(head -1 "$_d/web_urls"); tail -n +2 "$_d/web_urls" > "$_d/web_urls.t"; mv "$_d/web_urls.t" "$_d/web_urls"
        printf '%s' "$u" > "$_d/alias_$a.url"; exit 0 ;;
    "org display "*)
        a=$(_arg --target-org "$@"); u=$(cat "$_d/alias_$a.url" 2>/dev/null)
        [[ -n "$u" ]] || exit 1
        printf '{"status":0,"result":{"id":"%s"}}\n' "$(_id_of "$u")"; exit 0 ;;
    "org auth show-sfdx-auth-url")
        a=$(_arg --target-org "$@"); u=$(cat "$_d/alias_$a.url" 2>/dev/null)
        printf '{"status":0,"result":{"sfdxAuthUrl":"%s"}}\n' "$u"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$mb/sf"
    fx="$mb/fx.env"
    local U_MAIN="force://PlatformCLI::fakeurl@example.my.salesforce.com"
    local U_STG="force://PlatformCLI::stgurl@stg.my.salesforce.com"
    local U_DEV="force://PlatformCLI::devurl@dev.my.salesforce.com"
    _run_boot() {   # 引数: 標準入力 / web ログインの URL（改行区切り）
        printf '%s' "$2" > "$mb/web_urls"
        printf '%b' "$1" | ( cd "$mb" && HOME="$mb" PATH="$mb:$PATH" SF_INIT_MODE=1 E2E_FIXTURE="$fx" \
            bash "$E2E_DIR/bootstrap.sh" --add-orgs ) > "$mb/out.log" 2>&1
        rc=$?
    }

    # 1. 正常: staging・develop が、別々の組織 → 両方、保存される
    _mk_fixture "$fx"
    _run_boot 'Y\nY\n' "${U_STG}"$'\n'"${U_DEV}"$'\n'
    assert_exit_ok "$rc" "別々の組織なら、追加できる"
    assert_file_contains "$fx" "E2E_SFDX_AUTH_URL_STG=" "staging の認証 URL が、保存される"
    assert_file_contains "$fx" "E2E_SFDX_AUTH_URL_DEV=" "develop の認証 URL が、保存される"

    # 2. staging が、main と同じ組織 → 中断（保存しない）
    _mk_fixture "$fx"
    _run_boot 'Y\nN\n' "${U_MAIN}"$'\n'
    assert_exit_fail "$rc" "staging が main と同じ組織なら、中断する"
    assert_file_contains "$mb/out.log" "ほかの段階（main・develop）と同じ組織です" "理由が表示される"
    assert_file_not_contains "$fx" "E2E_SFDX_AUTH_URL_STG" "中断したときは、鍵一式に、保存しない"

    # 3. すでに登録済みの staging と、同じ組織を、develop に登録しようとする（2 回目の実行）→ 中断
    _mk_fixture "$fx"
    echo "E2E_SFDX_AUTH_URL_STG=${U_STG}" >> "$fx"
    _run_boot 'N\nY\n' "${U_STG}"$'\n'
    assert_exit_fail "$rc" "登録済みの staging と同じ組織を、develop に登録しようとすると、中断する"
    assert_file_contains "$mb/out.log" "ほかの段階（main・staging）と同じ組織です" "理由が表示される"
    assert_file_not_contains "$fx" "E2E_SFDX_AUTH_URL_DEV" "中断したときは、develop を、保存しない"

    # 4. 同じ実行の中で、staging と develop が、同じ組織 → develop で中断（先に確認した staging も、保存しない）
    _mk_fixture "$fx"
    cp "$fx" "$mb/before4.env"
    _run_boot 'Y\nY\n' "${U_STG}"$'\n'"${U_STG}"$'\n'
    assert_exit_fail "$rc" "staging と develop が同じ組織なら、中断する"
    assert_file_not_contains "$fx" "E2E_SFDX_AUTH_URL_DEV" "develop は、保存しない"
    assert_file_not_contains "$fx" "E2E_SFDX_AUTH_URL_STG" "先に確認した staging も、保存しない（一部だけの保存にしない）"
    assert_equals "$(cat "$fx")" "$(cat "$mb/before4.env")" "中断したときは、鍵一式が、実行の前と同じ"

    # 5. 登録済みの staging と develop が、すでに同じ組織（鍵一式が、壊れている）→ 中断
    _mk_fixture "$fx"
    echo "E2E_SFDX_AUTH_URL_STG=${U_STG}" >> "$fx"
    echo "E2E_SFDX_AUTH_URL_DEV=${U_STG}" >> "$fx"
    _run_boot 'N\nN\n' ""
    assert_exit_fail "$rc" "登録済みの staging と develop が同じ組織なら、中断する"
    assert_file_contains "$mb/out.log" "登録済みの develop が、ほかの段階と同じ組織です" "理由が表示される"

    unset MOCK_CALL_LOG
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# bootstrap.sh --refresh-orgs: 登録済みの認証 URL の有効性を確認し、無効なものだけを取り直す
#   sf のモック: URL に EXPIRED を含む認証 URL は、sfdx-url でのログインに失敗する（リフレッシュトークンの失効の再現）。
#   組織の ID は、認証 URL から決まる。login web は、web_urls（改行区切り）を、順に使う
# ------------------------------------------------------------------------------
test_e2e_bootstrap_refresh_orgs() {
    echo ""; echo -e "${CLR_HEAD}[TEST] bootstrap.sh --refresh-orgs（無効な認証 URL だけを、取り直す）${CLR_RST}"
    local mb fx rc
    mb=$(setup_mock_bin)
    export MOCK_CALL_LOG="$mb/calls.log"; : > "$MOCK_CALL_LOG"
    _mk_mocks "$mb"
    cat > "$mb/sf" << 'EOF'
#!/bin/bash
echo "sf $*" >> "${MOCK_CALL_LOG:-/dev/null}"
_d="${MOCK_CALL_LOG%/*}"
_id_of() { printf '00D%012d' "$(printf '%s' "$1" | sed 's/EXPIRED//g' | cksum | awk '{print $1}')"; }
_arg() { local k="$1"; shift; while [[ $# -gt 0 ]]; do [[ "$1" == "$k" ]] && { echo "$2"; return; }; shift; done; }
case "$1 $2 $3" in
    "org login sfdx-url")
        f=$(_arg --sfdx-url-file "$@"); a=$(_arg --alias "$@")
        if grep -q EXPIRED "$f"; then
            echo "Error (RefreshTokenAuthError): Error authenticating with the refresh token" >&2
            exit 1
        fi
        echo " »   Warning: @salesforce/cli update available from 2.1 to 2.2."
        echo "Successfully authorized user@example.com with org ID 00D000000000099"
        cat "$f" > "$_d/alias_$a.url"; exit 0 ;;
    "org login web")
        a=$(_arg --alias "$@")
        u=$(head -1 "$_d/web_urls"); tail -n +2 "$_d/web_urls" > "$_d/web_urls.t"; mv "$_d/web_urls.t" "$_d/web_urls"
        printf '%s' "$u" > "$_d/alias_$a.url"; exit 0 ;;
    "org display "*)
        a=$(_arg --target-org "$@"); u=$(cat "$_d/alias_$a.url" 2>/dev/null)
        [[ -n "$u" ]] || exit 1
        printf '{"status":0,"result":{"id":"%s"}}\n' "$(_id_of "$u")"; exit 0 ;;
    "org auth show-sfdx-auth-url")
        a=$(_arg --target-org "$@"); u=$(cat "$_d/alias_$a.url" 2>/dev/null)
        printf '{"status":0,"result":{"sfdxAuthUrl":"%s"}}\n' "$u"; exit 0 ;;
esac
exit 0
EOF
    chmod +x "$mb/sf"
    fx="$mb/fx.env"
    local U_MAIN="force://PlatformCLI::fakeurl@example.my.salesforce.com"
    local U_STG="force://PlatformCLI::stgurl@stg.my.salesforce.com"
    local U_DEV="force://PlatformCLI::devurl@dev.my.salesforce.com"
    local U_MAIN_X="force://PlatformCLI::EXPIREDfakeurl@example.my.salesforce.com"
    local U_STG_X="force://PlatformCLI::EXPIREDstgurl@stg.my.salesforce.com"
    _run_ref() {   # 引数: 標準入力 / web ログインの URL（改行区切り）
        printf '%s' "$2" > "$mb/web_urls"
        printf '%b' "$1" | ( cd "$mb" && HOME="$mb" PATH="$mb:$PATH" SF_INIT_MODE=1 E2E_FIXTURE="$fx" \
            bash "$E2E_DIR/bootstrap.sh" --refresh-orgs ) > "$mb/out.log" 2>&1
        rc=$?
    }

    # 1. すべて有効 → 何も聞かず、何も変更しない（ブラウザでのログインもしない）
    _mk_fixture "$fx"
    echo "E2E_SFDX_AUTH_URL_STG=${U_STG}" >> "$fx"
    cp "$fx" "$mb/before1.env"
    _run_ref "" ""
    assert_exit_ok "$rc" "すべて有効なら、正常終了する"
    assert_file_contains "$mb/out.log" "すべて有効です" "有効である旨が表示される"
    assert_equals "$(grep -cE '有効です（組織 ID: 00D[0-9]+）' "$mb/out.log")" "2" "組織 ID は、ID だけが表示される（sf の警告・出力を、混ぜない）"
    assert_equals "$(cat "$fx")" "$(cat "$mb/before1.env")" "鍵一式は、変更されない"
    assert_file_not_contains "$MOCK_CALL_LOG" "org login web" "有効なときは、ブラウザでログインしない"

    # 2. main だけが無効 → 確認のうえ、ブラウザで取り直す。staging（有効）は、そのまま
    : > "$MOCK_CALL_LOG"
    _mk_fixture "$fx"
    sedi "s|^E2E_SFDX_AUTH_URL=.*|E2E_SFDX_AUTH_URL=${U_MAIN_X}|" "$fx"
    echo "E2E_SFDX_AUTH_URL_STG=${U_STG}" >> "$fx"
    _run_ref 'Y\n' "${U_MAIN}"$'\n'
    assert_exit_ok "$rc" "main だけが無効: 取り直して、正常終了する"
    assert_file_contains "$mb/out.log" "main: 無効です" "無効な段階が表示される"
    assert_file_contains "$mb/out.log" "staging: 有効です" "有効な段階も表示される"
    assert_file_contains "$fx" "fakeurl@example.my.salesforce.com" "main の認証 URL が、新しいものに置き換わる"
    assert_file_not_contains "$fx" "EXPIRED" "古い（無効な）認証 URL は、残らない"
    assert_file_contains "$fx" "E2E_SFDX_AUTH_URL_STG=" "staging は、そのまま残る"
    assert_file_contains "$fx" "E2E_PAT_TOKEN=" "Token などの、ほかの値は、そのまま残る"
    assert_equals "$(grep -c '^E2E_SFDX_AUTH_URL=' "$fx")" "1" "main の行は、1 つだけ"
    assert_equals "$(grep -c 'org login web' "$MOCK_CALL_LOG")" "1" "ブラウザでのログインは、無効な段階の分だけ（1 回）"

    # 3. 無効なものを、取り直さない（N）→ 変更せず、非ゼロで終了（無効なまま残る旨を、表示する）
    _mk_fixture "$fx"
    sedi "s|^E2E_SFDX_AUTH_URL=.*|E2E_SFDX_AUTH_URL=${U_MAIN_X}|" "$fx"
    cp "$fx" "$mb/before3.env"
    _run_ref 'N\n' ""
    assert_exit_fail "$rc" "取り直さなければ、非ゼロで終了する"
    assert_file_contains "$mb/out.log" "無効なまま残っている組織があります" "無効なまま残る旨が表示される"
    assert_equals "$(cat "$fx")" "$(cat "$mb/before3.env")" "取り直さなかったときは、鍵一式は、変更されない"

    # 4. 取り直した組織が、有効な staging と同じ組織 → 中断（鍵一式を更新しない）
    _mk_fixture "$fx"
    sedi "s|^E2E_SFDX_AUTH_URL=.*|E2E_SFDX_AUTH_URL=${U_MAIN_X}|" "$fx"
    echo "E2E_SFDX_AUTH_URL_STG=${U_STG}" >> "$fx"
    cp "$fx" "$mb/before4.env"
    _run_ref 'Y\n' "${U_STG}"$'\n'
    assert_exit_fail "$rc" "ほかの段階と同じ組織でログインしたら、中断する"
    assert_file_contains "$mb/out.log" "同じ組織です" "理由が表示される"
    assert_equals "$(cat "$fx")" "$(cat "$mb/before4.env")" "中断したときは、鍵一式は、変更されない"

    # 5. main と staging の両方が無効 → 両方を取り直す。どちらも、保存される（まとめて保存）
    : > "$MOCK_CALL_LOG"
    _mk_fixture "$fx"
    sedi "s|^E2E_SFDX_AUTH_URL=.*|E2E_SFDX_AUTH_URL=${U_MAIN_X}|" "$fx"
    echo "E2E_SFDX_AUTH_URL_STG=${U_STG_X}" >> "$fx"
    _run_ref 'Y\nY\n' "${U_MAIN}"$'\n'"${U_STG}"$'\n'
    assert_exit_ok "$rc" "両方が無効: 両方を取り直して、正常終了する"
    assert_file_not_contains "$fx" "EXPIRED" "無効な認証 URL は、残らない"
    assert_equals "$(grep -c 'org login web' "$MOCK_CALL_LOG")" "2" "ブラウザでのログインは、2 回"

    # 6. 未登録の段階（staging・develop なし）は、無視する
    _mk_fixture "$fx"
    _run_ref "" ""
    assert_exit_ok "$rc" "main だけの登録: 正常終了する"
    assert_file_contains "$mb/out.log" "staging: 未登録です" "未登録の段階は、その旨が表示される"

    # 7. --add-orgs と同時には、指定できない
    _mk_fixture "$fx"
    ( cd "$mb" && HOME="$mb" PATH="$mb:$PATH" SF_INIT_MODE=1 E2E_FIXTURE="$fx" \
        bash "$E2E_DIR/bootstrap.sh" --add-orgs --refresh-orgs ) > "$mb/out.log" 2>&1 < /dev/null
    assert_exit_fail "$?" "--add-orgs と --refresh-orgs の同時指定は、拒否される"
    assert_file_contains "$mb/out.log" "同時に指定できません" "理由が表示される"

    unset MOCK_CALL_LOG
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# 20. doctor.sh（e2e を動かせる環境かの確認。読み取りのみ。秘密の値を出さない）
# ------------------------------------------------------------------------------
test_e2e_doctor() {
    echo ""; echo -e "${CLR_HEAD}[TEST] doctor.sh（e2e の環境チェック。秘密の値を出さない）${CLR_RST}"
    local mb rc
    mb=$(setup_mock_bin); MB="$mb"; FX="$mb/fx.env"; HM="$mb"
    export MOCK_CALL_LOG="$mb/calls.log"; _mk_mocks "$mb"
    mkdir -p "$mb/root/home"
    _run_doctor() {  # 引数: doctor.sh のオプション。結果は $MB/out.log。戻り値は doctor.sh の終了コード
        (
            cd "$HM" || exit 1
            export HOME="$HM" PATH="$MB:$PATH" E2E_FIXTURE="$FX" TMPDIR="$MB"
            bash "$E2E_DIR/doctor.sh" "$@"
        ) > "$MB/out.log" 2>&1
    }

    _run_doctor --help; rc=$?
    assert_exit_ok "$rc" "--help: 正常終了する"
    assert_file_contains     "$mb/out.log" "e2e を動かす前に実行する" "--help: 説明が表示される"
    assert_file_not_contains "$mb/out.log" "[OK]" "--help: 確認は、実行しない"

    FX="$mb/none.env"; _run_doctor; rc=$?
    assert_exit_fail "$rc" "鍵一式がない: 要対応として、非ゼロで終わる"
    assert_file_contains "$mb/out.log" "鍵一式のファイルがありません" "鍵一式がない: その旨と対処を表示する"

    FX="$mb/fx.env"; _mk_fixture "$FX" tamashimon "$mb/root/home"
    _run_doctor
    assert_file_contains "$mb/out.log" "必須の項目が、すべて設定されている" "鍵一式あり: 必須の項目の確認が通る"
    assert_file_contains "$mb/out.log" "gh: ログイン済み（tamashimon）" "gh のログインユーザーを表示する"
    assert_file_contains "$mb/out.log" "E2E_GH_USER（tamashimon）と一致している" "gh のユーザーと E2E_GH_USER の一致を確認する"
    assert_file_contains "$mb/out.log" "作業フォルダ（E2E_HOME_ROOT）がある" "作業フォルダがあれば、OK"
    assert_file_not_contains "$mb/out.log" "ghp_fakepat"    "画面に、PAT の値を出さない"
    assert_file_not_contains "$mb/out.log" "xoxb-fakeslack" "画面に、Slack の Token の値を出さない"
    assert_file_not_contains "$mb/out.log" "fakeurl"        "画面に、認証 URL の値を出さない"
    assert_file_not_contains "$mb/sf-tools/logs/e2e-doctor.log" "ghp_fakepat" "ログにも、PAT の値を出さない"

    # git のコミットの作者: 環境変数で、決まる・決まらないを作り分ける（名前が空だと、git は「empty ident name」で拒否する）
    GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME= GIT_AUTHOR_EMAIL=a@example.com GIT_COMMITTER_NAME= GIT_COMMITTER_EMAIL=a@example.com _run_doctor; rc=$?
    assert_exit_fail "$rc" "コミットの作者が決まらない: 非ゼロで終わる"
    assert_file_contains "$mb/out.log" "ユーザー名・メールアドレスが決まりません" "コミットの作者が決まらない: その旨と対処を表示する"
    GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=Tester GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=Tester GIT_COMMITTER_EMAIL=t@example.com _run_doctor
    assert_file_contains "$mb/out.log" "コミットの作者（ユーザー名・メールアドレス）が決まる" "コミットの作者が決まれば、OK"

    # git の認証の仕組み（credential helper）: システム・ユーザーの設定を読まず（HOME は、モックの場所）、環境変数で、有無を作り分ける
    GIT_CONFIG_NOSYSTEM=1 _run_doctor; rc=$?
    assert_exit_fail "$rc" "credential helper がない: 非ゼロで終わる"
    assert_file_contains "$mb/out.log" "GitHub の認証の仕組み（credential helper）がありません" "credential helper がない: その旨と対処を表示する"
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=credential.helper GIT_CONFIG_VALUE_0=store _run_doctor
    assert_file_contains "$mb/out.log" "credential helper）が設定されている" "credential helper があれば、OK"

    sedi '/E2E_PAT_TOKEN/d' "$FX"; _run_doctor; rc=$?
    assert_exit_fail "$rc" "項目が未設定: 非ゼロで終わる"
    assert_file_contains "$mb/out.log" "未設定の項目があります: E2E_PAT_TOKEN" "項目が未設定: 項目名を表示する"

    _mk_fixture "$FX" tamashimon "$mb/none/root"; _run_doctor; rc=$?
    assert_exit_fail "$rc" "作業フォルダがない: 非ゼロで終わる"
    assert_file_contains "$mb/out.log" "作業フォルダ（E2E_HOME_ROOT）がない" "作業フォルダがない: その旨と対処を表示する"

    _mk_fixture "$FX" tamashimon "$mb/root/home"; MOCK_GH_API_USER=someone-else _run_doctor; rc=$?
    assert_exit_fail "$rc" "gh のユーザーが違う: 非ゼロで終わる"
    assert_file_contains "$mb/out.log" "と一致しません" "gh のユーザーが違う: その旨を表示する"

    if [[ "$OSTYPE" != "msys"* && "$OSTYPE" != "mingw"* && "$OSTYPE" != "cygwin"* ]]; then
        _mk_fixture "$FX" tamashimon "$mb/root/home"; chmod 644 "$FX"; _run_doctor; rc=$?
        assert_exit_fail "$rc" "権限が 600 でない: 非ゼロで終わる"
        assert_file_contains "$mb/out.log" "権限が 600 ではありません" "権限が 600 でない: その旨と対処を表示する"
    fi

    unset MOCK_CALL_LOG
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# 21. 検証の記録（e2e の最後に表示する、表の 1 行）
# ------------------------------------------------------------------------------
test_e2e_record_line() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 検証の記録（e2e_record_line / e2e_os_label）${CLR_RST}"
    local mb line today
    mb=$(setup_mock_bin); MB="$mb"; FX="$mb/fx.env"; HM="$mb"
    _mk_mocks "$mb"
    _e2e_call 'e2e_record_line "e2e 3 件成功 / 0 件失敗（1 層）"; echo "OS=$(e2e_os_label)"'
    line=$(grep '^| ' "$mb/out.log" | head -1)
    today=$(date +%Y-%m-%d)
    assert_equals "$([[ "$line" == "| "* && "$line" == *" |" ]] && echo yes || echo no)" "yes" "表の 1 行の形（| ... |）になっている"
    assert_equals "$(printf '%s' "$line" | tr -cd '|' | wc -c | tr -d ' ')" "7" "6 列（OS・Bash・openssl・コミット・日付・結果）ある"
    assert_equals "$([[ "$line" == *"Bash "* ]] && echo yes || echo no)" "yes" "Bash のバージョンが入っている"
    assert_equals "$([[ "$line" == *"| ${today} |"* ]] && echo yes || echo no)" "yes" "日付が入っている"
    assert_equals "$([[ "$line" == *"| e2e 3 件成功 / 0 件失敗（1 層） |" ]] && echo yes || echo no)" "yes" "結果が、そのまま入っている"
    assert_equals "$(grep -c '^OS=.\+' "$mb/out.log")" "1" "OS の表示名が、空でない"
    assert_file_contains "$E2E_DIR/run.sh" 'e2e_record_line' "run.sh は、終わりに、検証の記録を表示する"
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# 22. ブラウザの差し替え（OS ごとの open_browser が使うコマンドを、すべて差し替える）
# ------------------------------------------------------------------------------
test_e2e_browser_shims() {
    echo ""; echo -e "${CLR_HEAD}[TEST] e2e のブラウザの差し替え（Git Bash: start / macOS: open / Linux: xdg-open / WSL: powershell.exe）${CLR_RST}"
    local n
    for n in start open xdg-open powershell.exe wslview; do
        assert_file_contains "$E2E_DIR/run.sh" "$n" "run.sh は、${n} を差し替える（実際のブラウザを開かない）"
    done
    assert_file_contains "$E2E_DIR/run.sh" 'for _n in start xdg-open open powershell.exe wslview' "差し替えのコマンドを、1 つの一覧で、コピーしている"
    bash "$E2E_DIR/shims/browser"; assert_exit_ok $? "差し替え用のブラウザは、何もせず、正常終了する"
}

# ------------------------------------------------------------------------------
# 23. wf-sequence の確認の部品（PR を閉じる・コメントの確認・動き出した検証の取り消し）
# ------------------------------------------------------------------------------
test_e2e_sequence_parts() {
    echo ""; echo -e "${CLR_HEAD}[TEST] wf-sequence の確認の部品（マージしない PR・コメント・取り消し）${CLR_RST}"
    _mk_cleanup_env
    local pre='e2e_load_fixture; e2e_guard_env;'
    local repo="tamashimon-org/force-e2e-20260101-000000"

    # PR を、マージせずに閉じる
    : > "$MOCK_CALL_LOG"
    _e2e_call "$pre"" e2e_gh_pr_close $repo 9; echo RC=\$?"
    assert_file_contains "$MOCK_CALL_LOG" "pr close 9 -R ${repo}" "PR を閉じる: 閉じるコマンドを実行する"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr merge" "PR を閉じる: マージは、しない"
    assert_file_contains "$MB/out.log" "RC=0" "PR を閉じる: 成功 → 戻り値 0"
    MOCK_GH_PR_CLOSE_EXIT=1 _e2e_call "$pre"" e2e_gh_pr_close $repo 9; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=1" "PR を閉じる: 失敗 → 戻り値 1"
    : > "$MOCK_CALL_LOG"
    _e2e_call "$pre"' e2e_gh_pr_close "tamashimon-org/force-test-win" 9; echo DONE'
    assert_file_not_contains "$MB/out.log" "DONE" "PR を閉じる: テスト用ではないリポジトリは、拒否する（異常終了）"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr close" "PR を閉じる: テスト用ではないリポジトリでは、閉じるコマンドを実行しない"

    # コメントに文字列があるか
    MOCK_GH_PR_COMMENTS=$'<!-- sf-tools:sequence -->\n## ⚠️ マージ順序の確認が必要です\nブランチ x は staging, develop にまだマージされていません。' \
        E2E_POLL_SEC=0 _e2e_call "$pre"" e2e_pr_comment_has $repo 9 'sf-tools:sequence'; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=0" "コメントの確認（ある）: 目印があれば、戻り値 0"
    MOCK_GH_PR_COMMENTS=$'<!-- sf-tools:sequence -->\n## ⚠️ マージ順序の確認が必要です\nブランチ x は staging, develop にまだマージされていません。' \
        E2E_POLL_SEC=0 _e2e_call "$pre"" e2e_pr_comment_has $repo 9 'にまだマージされていません'; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=0" "コメントの確認（ある）: 文言があれば、戻り値 0"
    : > "$MOCK_CALL_LOG"
    MOCK_GH_PR_COMMENTS='関係のないコメント' E2E_COMMENT_TRIES=3 E2E_POLL_SEC=0 _e2e_call "$pre"" e2e_pr_comment_has $repo 9 'sf-tools:sequence'; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=1" "コメントの確認（ある）: 見つからなければ、戻り値 1"
    [[ "$(grep -c 'pr view' "$MOCK_CALL_LOG")" -eq 3 ]] && pass "コメントの確認（ある）: 上限（3 回）まで、やり直す" || fail "コメントの確認（ある）: 上限まで、やり直す" "回数: $(grep -c 'pr view' "$MOCK_CALL_LOG")"
    _e2e_call "$pre"' e2e_pr_comment_has "tamashimon-org/force-test-win" 9 x; echo DONE'
    assert_file_not_contains "$MB/out.log" "DONE" "コメントの確認（ある）: テスト用ではないリポジトリは、拒否する（異常終了）"

    # コメントに文字列がないこと（取得の失敗を、「ない」と取り違えない）
    MOCK_GH_PR_COMMENTS='関係のないコメント' _e2e_call "$pre"" e2e_pr_comment_absent $repo 9 'sf-tools:sequence'; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=0" "コメントの確認（ない）: 含まれていなければ、戻り値 0"
    MOCK_GH_PR_COMMENTS='<!-- sf-tools:sequence -->' _e2e_call "$pre"" e2e_pr_comment_absent $repo 9 'sf-tools:sequence'; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=1" "コメントの確認（ない）: 含まれていれば、戻り値 1"
    MOCK_GH_PR_VIEW_EXIT=1 _e2e_call "$pre"" e2e_pr_comment_absent $repo 9 'sf-tools:sequence'; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=1" "コメントの確認（ない）: 取得に失敗したら、「ない」とせず、戻り値 1"

    # 動き出した検証の取り消し
    : > "$MOCK_CALL_LOG"
    MOCK_GH_ACTIVE_RUNS="701 702" _e2e_call "$pre"" e2e_cancel_pr_runs $repo develop; echo RC=\$?"
    assert_file_contains "$MOCK_CALL_LOG" "run cancel 701 -R ${repo}" "取り消し: 動いている実行（1 つ目）を取り消す"
    assert_file_contains "$MOCK_CALL_LOG" "run cancel 702 -R ${repo}" "取り消し: 動いている実行（2 つ目）を取り消す"
    assert_file_contains "$MOCK_CALL_LOG" "--branch develop --event pull_request --status queued" "取り消し: 待ちの実行を、ブランチと PR のイベントで探す"
    assert_file_contains "$MOCK_CALL_LOG" "--branch develop --event pull_request --status in_progress" "取り消し: 実行中の実行を、ブランチと PR のイベントで探す"
    assert_file_contains "$MB/out.log" "RC=0" "取り消し: 戻り値は、0"
    : > "$MOCK_CALL_LOG"
    MOCK_GH_ACTIVE_RUNS="701" MOCK_GH_CANCEL_EXIT=1 _e2e_call "$pre"" e2e_cancel_pr_runs $repo develop; echo RC=\$?"
    assert_file_contains "$MB/out.log" "RC=0" "取り消し: 取り消せなくても、失敗にしない（戻り値 0）"
    : > "$MOCK_CALL_LOG"
    MOCK_GH_ACTIVE_RUNS="" _e2e_call "$pre"" e2e_cancel_pr_runs $repo develop; echo RC=\$?"
    assert_file_not_contains "$MOCK_CALL_LOG" "run cancel" "取り消し: 動いている実行がなければ、取り消さない"
    : > "$MOCK_CALL_LOG"
    MOCK_GH_ACTIVE_RUNS="701" _e2e_call "$pre"' e2e_cancel_pr_runs "tamashimon-org/force-test-win" develop; echo DONE'
    assert_file_not_contains "$MB/out.log" "DONE" "取り消し: テスト用ではないリポジトリは、拒否する（異常終了）"
    assert_file_not_contains "$MOCK_CALL_LOG" "run cancel" "取り消し: テスト用ではないリポジトリでは、取り消さない"

    # run.sh の流れ（実環境でしか動かせないため、骨組みを確認する）
    assert_file_contains "$E2E_DIR/run.sh" "_sequence_pr_check" "run.sh: wf-sequence の、順序を守らない PR の確認がある"
    assert_file_contains "$E2E_DIR/run.sh" 'にまだマージされていません' "run.sh: 順序外のコメントの文言を確認する"
    assert_file_contains "$E2E_DIR/run.sh" '環境ブランチからの PR は、許可されていません' "run.sh: 環境ブランチからの PR のコメントの文言を確認する"
    assert_file_contains "$E2E_DIR/run.sh" 'label" == リリース*' "run.sh: 順序どおりの確認は、リリースの PR だけ（削除の PR は、順序外が正しい動き）"
    assert_file_contains "$E2E_DIR/run.sh" 'SEQ_CHECK=1' "run.sh: wf-sequence の確認は、2 層以上のときだけ"

    unset MOCK_CALL_LOG MOCK_GH_ACTIVE_RUNS
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 24. シナリオ方式（scenario.sh）と、秘密情報の検査（e2e_scan_secrets）
# ------------------------------------------------------------------------------
_run_scenario() {  # 引数: scenario.sh への引数。標準入力はそのまま使う
    (
        cd "$HM" || exit 1
        export HOME="$HM" PATH="$MB:$PATH" E2E_FIXTURE="$FX" E2E_POLL_SEC=0
        bash "$E2E_DIR/scenario.sh" "$@"
    ) > "$MB/out.log" 2>&1
}

test_e2e_scenario() {
    echo ""; echo -e "${CLR_HEAD}[TEST] scenario.sh（シナリオ方式。読み取りのみ・状態の確認・ガード）と e2e_scan_secrets${CLR_RST}"
    _mk_cleanup_env
    local rc pre='e2e_load_fixture;'

    # --- e2e_scan_secrets: 見つけた「種類」だけを返し、値は出さない ---
    _e2e_call "$pre"' printf "%s" "ふつうの ログ ***" | e2e_scan_secrets; echo RC=$?'
    assert_file_contains "$MB/out.log" "RC=0" "秘密の検査: 何も含まれなければ、戻り値 0"
    _e2e_call "$pre"' printf "%s" "token=ghp_fakepat done" | e2e_scan_secrets; echo RC=$?'
    assert_file_contains "$MB/out.log" "E2E_PAT_TOKEN の値" "秘密の検査: PAT の値が含まれていれば、種類を返す"
    assert_file_contains "$MB/out.log" "RC=1" "秘密の検査: 含まれていれば、戻り値 1"
    assert_file_not_contains "$MB/out.log" "ghp_fakepat" "秘密の検査: 値そのものは、出力しない"
    _e2e_call "$pre"' printf "%s" "x xoxb-fakeslack y" | e2e_scan_secrets; echo RC=$?'
    assert_file_contains "$MB/out.log" "E2E_SLACK_BOT_TOKEN の値" "秘密の検査: Slack の Token の値を検出する"
    _e2e_call "$pre"' printf "%s\n" "-----BEGIN RSA PRIVATE KEY-----" "MIIE" | e2e_scan_secrets; echo RC=$?'
    assert_file_contains "$MB/out.log" "秘密鍵の本文" "秘密の検査: 秘密鍵の開始行を検出する（形式）"
    _e2e_call "$pre"' printf "%s" "url=force://PlatformCLI::abcdefghijklmnopqrstuvwxyz1234@a.my.salesforce.com" | e2e_scan_secrets; echo RC=$?'
    assert_file_contains "$MB/out.log" "伏せられていない認証 URL" "秘密の検査: 伏せられていない認証 URL を検出する（形式）"
    _e2e_call "$pre"' printf "%s" "url=force://PlatformCLI::***@a.my.salesforce.com" | e2e_scan_secrets; echo RC=$?'
    assert_file_contains "$MB/out.log" "RC=0" "秘密の検査: 伏せられた認証 URL（***）は、漏れとして数えない"

    # --- 一覧・名前なし・不明な名前・ヘルプ: 実環境に接続しない ---
    : > "$MOCK_CALL_LOG"
    _run_scenario --list; rc=$?
    assert_exit_ok "$rc" "scenario.sh --list は成功する"
    assert_file_contains "$MB/out.log" "log-secrets" "--list: シナリオの名前が表示される"
    _run_scenario; rc=$?
    assert_exit_ok "$rc" "シナリオ名なしは、何も実行せずに成功で終わる"
    assert_file_contains "$MB/out.log" "何も実行していません" "名前なし: 何も実行していないと表示される"
    _run_scenario nope; rc=$?
    assert_exit_fail "$rc" "不明なシナリオ名は、中止する"
    bash "$E2E_DIR/scenario.sh" --help 2>&1 | grep -q "処理の流れ" && pass "scenario.sh --help が表示できる" || fail "scenario.sh --help が表示できる"
    assert_equals "$(grep -c '^gh ' "$MOCK_CALL_LOG")" "0" "一覧・名前なし・不明な名前・ヘルプでは、gh を呼ばない"

    # --- ガード ---
    : > "$MOCK_CALL_LOG"
    ( cd "$HM" && export HOME="$HM" PATH="$MB:$PATH" E2E_FIXTURE="$FX" GITHUB_ACTIONS=true
      bash "$E2E_DIR/scenario.sh" -y log-secrets ) > "$MB/out.log" 2>&1; rc=$?
    assert_exit_fail "$rc" "GitHub Actions 上では、シナリオを実行しない"
    assert_equals "$(grep -c 'run list' "$MOCK_CALL_LOG")" "0" "GitHub Actions 上: 何も読まない"
    MOCK_GH_API_USER=someone-else _run_scenario -y log-secrets; rc=$?
    assert_exit_fail "$rc" "gh のログインユーザーが E2E_GH_USER と違うと、中止する"
    assert_equals "$(grep -c 'run list' "$MOCK_CALL_LOG")" "0" "ユーザー不一致: 何も読まない"
    ( cd "$HM" && export HOME="$HM" PATH="$MB:$PATH" E2E_FIXTURE="$CB/none.env"
      bash "$E2E_DIR/scenario.sh" -y log-secrets ) > "$MB/out.log" 2>&1; rc=$?
    assert_exit_fail "$rc" "鍵一式がないと、中止する"
    MOCK_GH_REPO_VIEW_EXIT=1 _run_scenario -y log-secrets; rc=$?
    assert_exit_fail "$rc" "テスト用リポジトリが GitHub にないと、中止する"
    assert_file_contains "$MB/out.log" "run.sh" "リポジトリがない: run.sh で作るよう案内する"
    rm -rf "$CB/root/home/tamashimon-org/e2e-20260101-000000"
    _run_scenario -y log-secrets; rc=$?
    assert_exit_fail "$rc" "前回残したテスト用の作業フォルダがないと、中止する（黙って、作らない）"
    assert_file_contains "$MB/out.log" "run.sh" "作業フォルダがない: run.sh で作るよう案内する"
    mkdir -p "$CB/root/home/tamashimon-org/e2e-20260101-000000"
    : > "$MOCK_CALL_LOG"
    _run_scenario log-secrets < <(printf 'N\n'); rc=$?
    assert_exit_fail "$rc" "開始の確認で N → 中止する"
    assert_equals "$(grep -c 'run list' "$MOCK_CALL_LOG")" "0" "確認で N: 何も読まない"

    # --- log-secrets: 成功 ---
    : > "$MOCK_CALL_LOG"
    MOCK_GH_RUN_IDS="101 102" MOCK_GH_PR_NUMBERS="1 2" MOCK_GH_RUN_LOG="ふつうのログ ***" MOCK_GH_PR_BODY="ふつうの本文" \
        _run_scenario -y log-secrets; rc=$?
    assert_exit_ok "$rc" "log-secrets: 秘密が出ていなければ、成功する"
    assert_file_contains "$MB/out.log" "成功（4 件）" "log-secrets: 実行 2 件・PR 2 件で、4 件の確認"
    assert_file_contains "$MB/out.log" "検証の記録" "log-secrets: 成功したら、検証の記録の行を表示する"
    assert_file_not_contains "$MOCK_CALL_LOG" "repo delete" "log-secrets: 何も削除しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr merge" "log-secrets: マージしない"
    assert_file_not_contains "$MOCK_CALL_LOG" "workflow run" "log-secrets: ワークフローを起動しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr create" "log-secrets: PR を作らない"
    assert_file_not_contains "$MOCK_CALL_LOG" "--method POST" "log-secrets: 書き込みの API を呼ばない"

    # --- log-secrets: 漏れを見つけたら、失敗（種類だけを表示）---
    MOCK_GH_RUN_IDS="101" MOCK_GH_PR_NUMBERS="1" MOCK_GH_RUN_LOG="leak ghp_fakepat" MOCK_GH_PR_BODY="ok" \
        _run_scenario -y log-secrets; rc=$?
    assert_exit_fail "$rc" "log-secrets: ログに PAT が出ていたら、失敗する"
    assert_file_contains "$MB/out.log" "E2E_PAT_TOKEN の値" "log-secrets: 見つけた種類が表示される"
    MOCK_GH_RUN_IDS="101" MOCK_GH_PR_NUMBERS="1" MOCK_GH_RUN_LOG="ok" MOCK_GH_PR_BODY="leak xoxb-fakeslack" \
        _run_scenario -y log-secrets; rc=$?
    assert_exit_fail "$rc" "log-secrets: PR の本文・コメントに Token が出ていたら、失敗する"

    # --- log-secrets: 検査できないときは、成功にしない ---
    MOCK_GH_RUN_IDS="" MOCK_GH_PR_NUMBERS="1" MOCK_GH_PR_BODY="ok" _run_scenario -y log-secrets; rc=$?
    assert_exit_fail "$rc" "log-secrets: 実行が 0 件なら、成功にしない"
    assert_file_contains "$MB/out.log" "実行できない" "log-secrets: 「実行できない」と報告する"
    MOCK_GH_RUN_IDS="101" MOCK_GH_RUN_LOG="" MOCK_GH_PR_NUMBERS="" _run_scenario -y log-secrets; rc=$?
    assert_exit_fail "$rc" "log-secrets: ログが空なら、成功にしない（検査していない）"
    MOCK_GH_RUN_LIST_EXIT=1 _run_scenario -y log-secrets; rc=$?
    assert_exit_fail "$rc" "log-secrets: 一覧を取得できなければ、成功にしない"

    # --- 状態の確認: シナリオの前後で main の SHA が変わったら、失敗（後続は実行しない）---
    rm -f "$MB/mainsha.cnt"
    MOCK_GH_MAIN_SHA_CHANGE=1 MOCK_GH_RUN_IDS="101" MOCK_GH_PR_NUMBERS="1" MOCK_GH_RUN_LOG="ok" MOCK_GH_PR_BODY="ok" \
        _run_scenario -y log-secrets log-secrets; rc=$?
    assert_exit_fail "$rc" "状態の確認: main の SHA が変わったら、失敗する"
    assert_file_contains "$MB/out.log" "状態" "状態の確認: 変わったことが表示される"
    assert_file_contains "$MB/out.log" "以降のシナリオは実行していません" "状態の確認: 後続のシナリオは、実行しない"
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 25. シナリオ manual-delete（Secret・Variable を手で削除 → --status が見つける → 元に戻す）
# ------------------------------------------------------------------------------
# --status の代わりの台本（E2E_SF_INIT）: mock の Secret・Variable の状態を見て、不足があれば、終了コード 1 を返す（診断の形式を真似る）
_mk_status_stub() {
    cat > "$MB/status-stub.sh" << 'EOF'
#!/bin/bash
d="${MOCK_CALL_LOG%/*}"
[[ "${1:-}" == "--status" ]] || exit 9
echo "$PWD" >> "$d/status.cwd"
rc=0
if grep -qx SLACK_BOT_TOKEN "$d/secrets.txt" 2>/dev/null; then echo "    ✓ SLACK_BOT_TOKEN"; else echo "    ✗ SLACK_BOT_TOKEN が、ありません → プロジェクトのフォルダで sf-init.sh --only 7"; rc=1; fi
if grep -q '^SLACK_CHANNEL_ID=' "$d/vars.txt" 2>/dev/null; then echo "    ✓ SLACK_CHANNEL_ID"; else echo "    ✗ SLACK_CHANNEL_ID が、ありません → プロジェクトのフォルダで sf-init.sh --only 7"; rc=1; fi
[[ "${MOCK_STATUS_BLIND:-}" == "1" ]] && exit 0   # 不足を見つけられない診断の再現
exit $rc
EOF
    chmod +x "$MB/status-stub.sh"
}

test_e2e_scenario_manual_delete() {
    echo ""; echo -e "${CLR_HEAD}[TEST] scenario.sh manual-delete（削除 → 検出 → 元に戻す。終了時に必ず戻す）${CLR_RST}"
    _mk_cleanup_env
    _mk_status_stub
    local rc admin="$CB/root/home/tamashimon-org/e2e-20260101-000000/admin/force-e2e-20260101-000000"
    mkdir -p "$admin/.git"
    _reset_state() { printf 'PAT_TOKEN\nSLACK_BOT_TOKEN\n' > "$MB/secrets.txt"; printf 'SLACK_CHANNEL_ID=C01ABCDEFGH\nSF_USERNAME_PROD=a@example.com\n' > "$MB/vars.txt"; rm -f "$MB/secretset.failed" "$MB/status.cwd"; : > "$MOCK_CALL_LOG"; }
    export E2E_SF_INIT="$MB/status-stub.sh" E2E_STATUS_TRIES=2

    # --- 成功: 削除 → 検出（直し方つき）→ 元に戻る ---
    _reset_state
    _run_scenario -y manual-delete; rc=$?
    assert_exit_ok "$rc" "manual-delete: 成功する"
    assert_file_contains "$MB/out.log" "成功（15 件）" "manual-delete: 15 件の確認が成功する"
    assert_file_contains "$MB/out.log" "sf-init.sh --only 7" "manual-delete: 直し方が、確認されている"
    assert_equals "$(sort "$MB/secrets.txt" | tr '\n' ',')" "PAT_TOKEN,SLACK_BOT_TOKEN," "manual-delete: Secret が、元の一覧に戻る"
    assert_equals "$(cat "$MB/secretval.SLACK_BOT_TOKEN" 2>/dev/null)" "xoxb-fakeslack" "manual-delete: 戻した Secret の値が、鍵一式の Token と同じ（空で戻さない）"
    assert_equals "$(grep '^SLACK_CHANNEL_ID=' "$MB/vars.txt")" "SLACK_CHANNEL_ID=C01ABCDEFGH" "manual-delete: Variable が、元の値で戻る"
    assert_equals "$(sort "$MB/vars.txt" | tr '\n' ',')" "SF_USERNAME_PROD=a@example.com,SLACK_CHANNEL_ID=C01ABCDEFGH," "manual-delete: 触っていない Variable は、そのまま"
    assert_equals "$(grep -c 'secret delete SLACK_BOT_TOKEN' "$MOCK_CALL_LOG")" "1" "manual-delete: 削除するのは、SLACK_BOT_TOKEN だけ（1 回）"
    assert_equals "$(grep -c 'secret delete' "$MOCK_CALL_LOG")" "1" "manual-delete: ほかの Secret は、削除しない"
    assert_equals "$(grep -c 'variable delete SLACK_CHANNEL_ID' "$MOCK_CALL_LOG")" "1" "manual-delete: 削除する Variable は、SLACK_CHANNEL_ID だけ（1 回）"
    assert_equals "$(grep -c 'variable delete' "$MOCK_CALL_LOG")" "1" "manual-delete: ほかの Variable は、削除しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "repo delete" "manual-delete: リポジトリは、削除しない"
    grep -qx "$admin" "$MB/status.cwd" && pass "manual-delete: --status は、管理者用のクローンで実行される" || fail "manual-delete: --status は、管理者用のクローンで実行される" "$(cat "$MB/status.cwd")"

    # --- 診断が不足を見つけられない → 失敗（それでも、元に戻す）---
    _reset_state
    MOCK_STATUS_BLIND=1 _run_scenario -y manual-delete; rc=$?
    assert_exit_fail "$rc" "manual-delete: 診断が、不足を見つけなければ、失敗する"
    assert_equals "$(sort "$MB/secrets.txt" | tr '\n' ',')" "PAT_TOKEN,SLACK_BOT_TOKEN," "manual-delete: 失敗しても、Secret は、元に戻る"
    assert_equals "$(grep '^SLACK_CHANNEL_ID=' "$MB/vars.txt")" "SLACK_CHANNEL_ID=C01ABCDEFGH" "manual-delete: 失敗しても、Variable は、元に戻る"

    # --- 元に戻す処理の 1 回目が失敗 → 終了時に、再試行して、戻る ---
    _reset_state
    MOCK_GH_SECRET_SET_FAIL_FIRST=1 _run_scenario -y manual-delete; rc=$?
    assert_exit_fail "$rc" "manual-delete: 元に戻す処理が失敗すると、失敗として報告する"
    assert_file_contains "$MB/out.log" "元に戻せませんでした" "manual-delete: 戻せなかったことと、手での戻し方が表示される"
    assert_equals "$(sort "$MB/secrets.txt" | tr '\n' ',')" "PAT_TOKEN,SLACK_BOT_TOKEN," "manual-delete: 終了時の再試行で、Secret が、戻る"

    # --- 前提が満たされないとき: 実行できない（何も削除しない）---
    _reset_state
    rm -rf "$admin"
    _run_scenario -y manual-delete; rc=$?
    assert_exit_fail "$rc" "manual-delete: 管理者用のクローンがなければ、実行できない"
    assert_file_contains "$MB/out.log" "実行できない" "manual-delete: 「実行できない」と報告する"
    assert_file_not_contains "$MOCK_CALL_LOG" "secret delete" "manual-delete: 実行できないときは、何も削除しない"
    mkdir -p "$admin/.git"
    _reset_state; printf 'PAT_TOKEN\n' > "$MB/secrets.txt"
    _run_scenario -y manual-delete; rc=$?
    assert_exit_fail "$rc" "manual-delete: もともと不足があれば、実行できない"
    assert_file_not_contains "$MOCK_CALL_LOG" "secret delete" "manual-delete: もともと不足があるときは、何も削除しない"

    # --- 開始の警告: 書き込む内容が表示され、N で中止すると、何も削除しない ---
    _reset_state
    _run_scenario manual-delete < <(printf 'N\n'); rc=$?
    assert_exit_fail "$rc" "manual-delete: 開始の確認で N → 中止する"
    assert_file_contains "$MB/out.log" "書き込み（manual-delete）" "manual-delete: 警告に、書き込む内容が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "secret delete" "manual-delete: N のとき、何も削除しない"
    unset E2E_SF_INIT E2E_STATUS_TRIES
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 26. シナリオ validate-fail（壊れた Apex の PR → wf-validate が失敗 → 直すと成功。ブランチ・PR は後で戻す）
# ------------------------------------------------------------------------------
test_e2e_scenario_validate_fail() {
    echo ""; echo -e "${CLR_HEAD}[TEST] scenario.sh validate-fail（失敗 → 直す → 成功。マージしない・必ず後始末する）${CLR_RST}"
    _mk_cleanup_env
    local rc
    local ok_comments=$'## ❌ Salesforce 検証結果: 検証失敗\nSfToolsE2eHello.cls (1:40): Unexpected token\n---\n## ✅ Salesforce 検証結果: 検証成功'
    export E2E_RUN_FIND_TRIES=2 E2E_CONCLUSION_TRIES=1

    # --- 成功: 失敗 → 直す → 成功。マージせず、PR を閉じ、ブランチを削除する ---
    : > "$MOCK_CALL_LOG"; rm -f "$MB/prrun.cnt" "$MB/concl.cnt"
    MOCK_GH_RUN_SEQ=1 MOCK_GH_CONCL_LIST="failure success" MOCK_GH_PR_COMMENTS="$ok_comments" _run_scenario -y validate-fail; rc=$?
    [[ $rc -eq 0 ]] || sed 's/\x1b\[[0-9;]*m//g' "$MB/out.log" | tail -20
    assert_exit_ok "$rc" "validate-fail: 成功する"
    assert_file_contains "$MB/out.log" "成功（" "validate-fail: 結果が成功と表示される"
    assert_equals "$(grep -c 'api -X POST repos/.*/git/refs ' "$MOCK_CALL_LOG")" "1" "validate-fail: テスト用ブランチを 1 つ作る"
    assert_file_contains "$MOCK_CALL_LOG" "ref=refs/heads/e2e-vf-" "validate-fail: ブランチ名は、e2e-vf-時刻の形式"
    assert_equals "$(grep -c 'api -X PUT .*contents/' "$MOCK_CALL_LOG")" "7" "validate-fail: ファイルは 7 回（リリース対象 2・クラス 4・直し 1）書く"
    assert_file_not_contains "$MOCK_CALL_LOG" "branch=main" "validate-fail: main には、書き込まない"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr merge" "validate-fail: PR を、マージしない"
    assert_file_contains "$MOCK_CALL_LOG" "pr close 7" "validate-fail: PR を閉じる"
    assert_file_contains "$MOCK_CALL_LOG" "api -X DELETE repos/tamashimon-org/force-e2e-20260101-000000/git/refs/heads/e2e-vf-" "validate-fail: テスト用ブランチを削除する"
    assert_file_not_contains "$MOCK_CALL_LOG" "repo delete" "validate-fail: リポジトリは、削除しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "workflow run" "validate-fail: ワークフローを、手で起動しない"

    # --- 壊れた Apex なのに、検証が成功した → 失敗（それでも、後始末はする）---
    : > "$MOCK_CALL_LOG"; rm -f "$MB/prrun.cnt" "$MB/concl.cnt"
    MOCK_GH_RUN_SEQ=1 MOCK_GH_CONCL_LIST="success success" MOCK_GH_PR_COMMENTS="$ok_comments" _run_scenario -y validate-fail; rc=$?
    assert_exit_fail "$rc" "validate-fail: 壊れた Apex で検証が成功したら、失敗する"
    assert_file_contains "$MOCK_CALL_LOG" "pr close 7" "validate-fail: 失敗しても、PR を閉じる"
    assert_file_contains "$MOCK_CALL_LOG" "git/refs/heads/e2e-vf-" "validate-fail: 失敗しても、ブランチを削除する"

    # --- 失敗のコメントが付かない → 失敗 ---
    : > "$MOCK_CALL_LOG"; rm -f "$MB/prrun.cnt" "$MB/concl.cnt"
    MOCK_GH_RUN_SEQ=1 MOCK_GH_CONCL_LIST="failure success" MOCK_GH_PR_COMMENTS="## ✅ Salesforce 検証結果: 検証成功" E2E_COMMENT_TRIES=1 \
        _run_scenario -y validate-fail; rc=$?
    assert_exit_fail "$rc" "validate-fail: 「検証失敗」のコメントが付かなければ、失敗する"

    # --- 直しても、再検証が失敗 → 失敗 ---
    : > "$MOCK_CALL_LOG"; rm -f "$MB/prrun.cnt" "$MB/concl.cnt"
    MOCK_GH_RUN_SEQ=1 MOCK_GH_CONCL_LIST="failure failure" MOCK_GH_PR_COMMENTS="$ok_comments" _run_scenario -y validate-fail; rc=$?
    assert_exit_fail "$rc" "validate-fail: 直したあとも失敗するなら、失敗する"

    # --- ワークフローが動かない → 失敗（途中で止まっても、PR を閉じ、ブランチを削除する）---
    : > "$MOCK_CALL_LOG"; rm -f "$MB/prrun.cnt" "$MB/concl.cnt"
    MOCK_GH_RUN_NONE=1 _run_scenario -y validate-fail; rc=$?
    assert_exit_fail "$rc" "validate-fail: wf-validate が動かなければ、失敗する"
    assert_file_contains "$MOCK_CALL_LOG" "pr close 7" "validate-fail: 途中で止まっても、PR を閉じる"
    assert_file_contains "$MOCK_CALL_LOG" "git/refs/heads/e2e-vf-" "validate-fail: 途中で止まっても、ブランチを削除する"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr merge" "validate-fail: 途中で止まっても、マージしない"

    # --- 開始の警告: 書き込む内容が表示され、N で中止すると、何も作らない ---
    : > "$MOCK_CALL_LOG"
    _run_scenario validate-fail < <(printf 'N\n'); rc=$?
    assert_exit_fail "$rc" "validate-fail: 開始の確認で N → 中止する"
    assert_file_contains "$MB/out.log" "書き込み（validate-fail）" "validate-fail: 警告に、書き込む内容が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs" "validate-fail: N のとき、ブランチを作らない"
    unset E2E_RUN_FIND_TRIES E2E_CONCLUSION_TRIES
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 27. シナリオ dist-main（配布版 = SF_TOOLS_BRANCH 未設定で、sf-tools の main が使われる。rr の直後だけ）
# ------------------------------------------------------------------------------
test_e2e_scenario_dist_main() {
    echo ""; echo -e "${CLR_HEAD}[TEST] scenario.sh dist-main（Variable を一時的に削除 → main が使われる → 必ず戻す）${CLR_RST}"
    _mk_cleanup_env
    local rc g="$CB/sftools-git" o="$CB/sftools-origin.git" log_main log_dev
    local gc=(git -c user.name=t -c user.email=t@example.com)
    log_main="Run git clone -b main https://github.com/tama-create/sf-tools.git /home/runner/sf-tools"
    log_dev="Run git clone -b development https://github.com/tama-create/sf-tools.git /home/runner/sf-tools"
    # sf-tools の origin の代わり（main と development が同じ内容）
    git init -q --bare "$o"; git init -q "$g"
    mkdir -p "$g/bin" "$g/doc"; echo a > "$g/bin/x.sh"
    ( cd "$g" && "${gc[@]}" add -A && "${gc[@]}" commit -q -m first && git branch -M main && git remote add origin "$o" \
        && git push -q origin main && git push -q origin main:development ) > "$MB/gitsetup.log" 2>&1
    export E2E_SF_TOOLS_GIT_DIR="$g" E2E_RUN_FIND_TRIES=2 E2E_CONCLUSION_TRIES=1
    _reset_dm() {
        printf 'PAT_TOKEN\nSLACK_BOT_TOKEN\n' > "$MB/secrets.txt"
        printf 'SLACK_CHANNEL_ID=C01ABCDEFGH\nSF_TOOLS_BRANCH=development\n' > "$MB/vars.txt"
        : > "$MOCK_CALL_LOG"; rm -f "$MB/prrun.cnt" "$MB/concl.cnt"
    }

    # --- 成功: 削除 → main が使われる → 戻る ---
    _reset_dm
    MOCK_GH_RUN_SEQ=1 MOCK_GH_CONCL_LIST="success" MOCK_GH_RUN_LOG="$log_main" _run_scenario -y dist-main; rc=$?
    [[ $rc -eq 0 ]] || sed 's/\x1b\[[0-9;]*m//g' "$MB/out.log" | tail -20
    assert_exit_ok "$rc" "dist-main: 成功する"
    assert_file_contains "$MB/out.log" "成功（" "dist-main: 結果が成功と表示される"
    assert_equals "$(grep -c 'variable delete SF_TOOLS_BRANCH' "$MOCK_CALL_LOG")" "1" "dist-main: 削除する Variable は、SF_TOOLS_BRANCH だけ（1 回）"
    assert_equals "$(grep -c 'variable delete' "$MOCK_CALL_LOG")" "1" "dist-main: ほかの Variable は、削除しない"
    assert_equals "$(grep '^SF_TOOLS_BRANCH=' "$MB/vars.txt")" "SF_TOOLS_BRANCH=development" "dist-main: Variable が、元の値で戻る"
    assert_file_contains "$MOCK_CALL_LOG" "pr close 7" "dist-main: PR を閉じる"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr merge" "dist-main: PR を、マージしない"
    assert_file_contains "$MOCK_CALL_LOG" "git/refs/heads/e2e-dm-" "dist-main: テスト用ブランチ（e2e-dm-）を削除する"
    assert_file_not_contains "$MOCK_CALL_LOG" "branch=main" "dist-main: main には、書き込まない"

    # --- ログが development を取得していた → 失敗（それでも、Variable・PR・ブランチは戻す）---
    _reset_dm
    MOCK_GH_RUN_SEQ=1 MOCK_GH_CONCL_LIST="success" MOCK_GH_RUN_LOG="$log_dev" _run_scenario -y dist-main; rc=$?
    assert_exit_fail "$rc" "dist-main: main を取得していなければ、失敗する"
    assert_equals "$(grep '^SF_TOOLS_BRANCH=' "$MB/vars.txt")" "SF_TOOLS_BRANCH=development" "dist-main: 失敗しても、Variable は戻る"
    assert_file_contains "$MOCK_CALL_LOG" "pr close 7" "dist-main: 失敗しても、PR を閉じる"

    # --- 検証が失敗 → 失敗 ---
    _reset_dm
    MOCK_GH_RUN_SEQ=1 MOCK_GH_CONCL_LIST="failure" MOCK_GH_RUN_LOG="$log_main" _run_scenario -y dist-main; rc=$?
    assert_exit_fail "$rc" "dist-main: wf-validate が失敗したら、失敗する"

    # --- ワークフローが動かない → 失敗（途中で止まっても、すべて戻す）---
    _reset_dm
    MOCK_GH_RUN_NONE=1 _run_scenario -y dist-main; rc=$?
    assert_exit_fail "$rc" "dist-main: wf-validate が動かなければ、失敗する"
    assert_equals "$(grep '^SF_TOOLS_BRANCH=' "$MB/vars.txt")" "SF_TOOLS_BRANCH=development" "dist-main: 途中で止まっても、Variable は戻る"
    assert_file_contains "$MOCK_CALL_LOG" "pr close 7" "dist-main: 途中で止まっても、PR を閉じる"
    assert_file_contains "$MOCK_CALL_LOG" "git/refs/heads/e2e-dm-" "dist-main: 途中で止まっても、ブランチを削除する"

    # --- 前提: Variable がもともと未設定 → 実行できない（何も作らない）---
    _reset_dm; printf 'SLACK_CHANNEL_ID=C01ABCDEFGH\n' > "$MB/vars.txt"
    _run_scenario -y dist-main; rc=$?
    assert_exit_fail "$rc" "dist-main: Variable がもともと未設定なら、実行できない"
    assert_file_contains "$MB/out.log" "実行できない" "dist-main: 「実行できない」と報告する"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs" "dist-main: 実行できないときは、ブランチを作らない"

    # --- 前提: main と development の配布物に差がある → 実行できない（rr の前）---
    _reset_dm
    ( cd "$g" && git checkout -q development && echo b >> bin/x.sh && "${gc[@]}" commit -q -am dev-change && git push -q origin development ) > "$MB/gitsetup.log" 2>&1
    _run_scenario -y dist-main; rc=$?
    assert_exit_fail "$rc" "dist-main: main と development の配布物に差があれば、実行できない"
    assert_file_contains "$MB/out.log" "差があります" "dist-main: 差があることが、表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "variable delete" "dist-main: 差があるときは、Variable を削除しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs" "dist-main: 差があるときは、ブランチを作らない"
    # 配布物以外（doc）だけの差は、実行できる（rr の対象外のパス）
    ( cd "$g" && git checkout -q -f main && git push -q -f origin main:development && git checkout -q development 2>/dev/null; git reset -q --hard origin/development; echo d > doc/a.md && "${gc[@]}" add -A && "${gc[@]}" commit -q -m doc && git push -q origin development ) > "$MB/gitsetup.log" 2>&1
    _reset_dm
    MOCK_GH_RUN_SEQ=1 MOCK_GH_CONCL_LIST="success" MOCK_GH_RUN_LOG="$log_main" _run_scenario -y dist-main; rc=$?
    assert_exit_ok "$rc" "dist-main: doc だけの差なら、実行できる（配布物のパスではない）"

    # --- 前提: sf-tools の origin を取得できない → 実行できない ---
    _reset_dm
    E2E_SF_TOOLS_GIT_DIR="$CB/none" _run_scenario -y dist-main; rc=$?
    assert_exit_fail "$rc" "dist-main: sf-tools の origin を取得できなければ、実行できない"
    assert_file_not_contains "$MOCK_CALL_LOG" "variable delete" "dist-main: 取得できないときは、Variable を削除しない"

    # --- 開始の警告 ---
    _reset_dm
    _run_scenario dist-main < <(printf 'N\n'); rc=$?
    assert_exit_fail "$rc" "dist-main: 開始の確認で N → 中止する"
    assert_file_contains "$MB/out.log" "書き込み（dist-main）" "dist-main: 警告に、書き込む内容が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "variable delete" "dist-main: N のとき、何も削除しない"
    unset E2E_SF_TOOLS_GIT_DIR E2E_RUN_FIND_TRIES E2E_CONCLUSION_TRIES
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 28. シナリオ metasync-diff（組織側だけの Apex が、wf-metasync で main に反映される。組織と main を、必ず戻す）
# ------------------------------------------------------------------------------
test_e2e_scenario_metasync_diff() {
    echo ""; echo -e "${CLR_HEAD}[TEST] scenario.sh metasync-diff（組織に直接デプロイ → wf-metasync → main に反映 → 組織・main を戻す）${CLR_RST}"
    _mk_cleanup_env
    local rc cls="force-app/main/default/classes/SfToolsE2eHello.cls"
    export E2E_CONCLUSION_TRIES=1 VERIFY_DISPATCH_TRIES=2 E2E_LIST_RETRY=1
    _reset_ms() {
        rm -f "$MB/apex_created.txt" "$MB/deleted.txt" "$MB/disp.cnt" "$MB/concl.cnt" "$MB/mainfiles.txt"
        : > "$MB/mainfiles.txt"; : > "$MOCK_CALL_LOG"
        unset MOCK_SF_APEX
    }

    # --- 成功: 組織に作る → wf-metasync → main に反映 → 組織・main を戻す ---
    _reset_ms
    MOCK_GH_METASYNC_REFLECT=1 MOCK_GH_CONCL_LIST="success" _run_scenario -y metasync-diff; rc=$?
    [[ $rc -eq 0 ]] || sed 's/\x1b\[[0-9;]*m//g' "$MB/out.log" | tail -25
    assert_exit_ok "$rc" "metasync-diff: 成功する"
    assert_file_contains "$MB/out.log" "成功（" "metasync-diff: 結果が成功と表示される"
    assert_equals "$(grep -c -- '--metadata-dir' "$MOCK_CALL_LOG")" "1" "metasync-diff: 組織への直接のデプロイは、1 回"
    assert_equals "$(sort "$MB/deleted.txt" | tr '\n' ',')" "SfToolsE2eHello,SfToolsE2eHelloTest," "metasync-diff: 組織の Apex（許可された 2 つの名前）を削除する"
    assert_equals "$(grep -c 'workflow run wf-metasync.yml' "$MOCK_CALL_LOG")" "1" "metasync-diff: wf-metasync を 1 回起動する"
    assert_equals "$(grep -c 'workflow run' "$MOCK_CALL_LOG")" "1" "metasync-diff: ほかのワークフローは、起動しない"
    assert_equals "$(grep -c 'api -X DELETE repos/.*/contents/' "$MOCK_CALL_LOG")" "4" "metasync-diff: main から削除するファイルは、Hello World の 4 つだけ"
    assert_file_contains "$MOCK_CALL_LOG" "api -X DELETE repos/tamashimon-org/force-e2e-20260101-000000/contents/${cls}" "metasync-diff: main の ${cls##*/} を削除する"
    assert_equals "$(wc -c < "$MB/mainfiles.txt" | tr -d ' ')" "0" "metasync-diff: main に、Hello World のファイルが残らない"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr merge" "metasync-diff: PR は、扱わない"
    assert_file_not_contains "$MOCK_CALL_LOG" "repo delete" "metasync-diff: リポジトリは、削除しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "alias unset sf-tools-e2e-admin" "metasync-diff: （エイリアスは、保存した一覧へ戻す）"

    # --- main に反映されない → 失敗（それでも、組織は戻す）---
    _reset_ms
    MOCK_GH_CONCL_LIST="success" _run_scenario -y metasync-diff; rc=$?
    assert_exit_fail "$rc" "metasync-diff: main に反映されなければ、失敗する"
    assert_equals "$(sort "$MB/deleted.txt" | tr '\n' ',')" "SfToolsE2eHello,SfToolsE2eHelloTest," "metasync-diff: 失敗しても、組織の Apex は削除される"

    # --- wf-metasync が失敗 → 失敗（それでも、組織・main は戻す）---
    _reset_ms
    MOCK_GH_METASYNC_REFLECT=1 MOCK_GH_CONCL_LIST="failure" _run_scenario -y metasync-diff; rc=$?
    assert_exit_fail "$rc" "metasync-diff: wf-metasync が失敗したら、失敗する"
    assert_equals "$(sort "$MB/deleted.txt" | tr '\n' ',')" "SfToolsE2eHello,SfToolsE2eHelloTest," "metasync-diff: wf-metasync が失敗しても、組織の Apex は削除される"
    assert_equals "$(wc -c < "$MB/mainfiles.txt" | tr -d ' ')" "0" "metasync-diff: wf-metasync が失敗しても、main に残ったファイルは削除される"

    # --- 組織への直接のデプロイが失敗 → 失敗（削除も失敗するときは、手での戻し方を案内する）---
    _reset_ms
    MOCK_SF_DEPLOY_EXIT=1 _run_scenario -y metasync-diff; rc=$?
    assert_exit_fail "$rc" "metasync-diff: デプロイに失敗したら、失敗する"
    assert_file_contains "$MB/out.log" "cleanup.sh --yes" "metasync-diff: 組織を戻せなかったときは、cleanup.sh を案内する"

    # --- 前提: 組織にすでにある → 実行できない（何もデプロイしない）---
    _reset_ms
    MOCK_SF_APEX="SfToolsE2eHello" _run_scenario -y metasync-diff; rc=$?
    assert_exit_fail "$rc" "metasync-diff: 組織にすでに Apex があれば、実行できない"
    assert_file_contains "$MB/out.log" "実行できない" "metasync-diff: 「実行できない」と報告する"
    assert_file_not_contains "$MOCK_CALL_LOG" "--metadata-dir" "metasync-diff: 実行できないときは、デプロイしない"
    assert_file_not_contains "$MOCK_CALL_LOG" "api -X DELETE repos/.*/contents/" "metasync-diff: 実行できないときは、main のファイルを削除しない"

    # --- main に（run.sh のリリースの履歴として）すでにある → いったん外し、反映を確認し、実行前の状態へ戻す ---
    _reset_ms
    printf '%s\n' "$cls" "${cls}-meta.xml" > "$MB/mainfiles.txt"
    MOCK_GH_METASYNC_REFLECT=1 MOCK_GH_CONCL_LIST="success" _run_scenario -y metasync-diff; rc=$?
    [[ $rc -eq 0 ]] || sed 's/\x1b\[[0-9;]*m//g' "$MB/out.log" | tail -25
    assert_exit_ok "$rc" "metasync-diff: main にすでにファイルがあっても、成功する（いったん外す）"
    assert_equals "$(sort "$MB/mainfiles.txt" | tr '\n' ',')" "${cls},${cls}-meta.xml," "metasync-diff: 終了後、main は、実行前の状態（元からあった 2 つだけ）に戻る"
    assert_equals "$(grep -c 'api -X PUT .*contents/.*branch=main' "$MOCK_CALL_LOG")" "2" "metasync-diff: 元からあった 2 つのファイルを、元の本文で戻す"
    assert_file_contains "$MB/out.log" "いったん外した" "metasync-diff: いったん外したことが、表示される"


    # --- 開始の警告 ---
    _reset_ms
    _run_scenario metasync-diff < <(printf 'N\n'); rc=$?
    assert_exit_fail "$rc" "metasync-diff: 開始の確認で N → 中止する"
    assert_file_contains "$MB/out.log" "書き込み（metasync-diff）" "metasync-diff: 警告に、書き込む内容が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "--metadata-dir" "metasync-diff: N のとき、デプロイしない"
    unset E2E_CONCLUSION_TRIES VERIFY_DISPATCH_TRIES E2E_LIST_RETRY
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 29. 中断→再開（run.sh --interrupt）と、git の shim
# ------------------------------------------------------------------------------
test_e2e_interrupt() {
    echo ""; echo -e "${CLR_HEAD}[TEST] run.sh --interrupt（Phase 8 の push を 1 回だけ失敗させる git の shim）${CLR_RST}"
    _mk_cleanup_env
    local rc shim="$E2E_DIR/shims/git"
    # 本物の git の代わり: 呼ばれた引数を記録する
    cat > "$MB/realgit" << 'EOF'
#!/bin/bash
echo "REAL: $*" >> "${MOCK_CALL_LOG%/*}/realgit.log"
exit 0
EOF
    chmod +x "$MB/realgit"
    _git_shim() { E2E_REAL_GIT="$MB/realgit" E2E_GIT_FAIL_MARK="$MB/mark" bash "$shim" "$@" > "$MB/shim.out" 2>&1; }

    # --- main への push は、1 回目だけ失敗する ---
    rm -f "$MB/mark" "$MB/realgit.log"
    _git_shim -c credential.helper= push --no-verify origin main; rc=$?
    assert_equals "$rc" "128" "git の shim: main への push の 1 回目は、失敗する（終了コード 128）"
    assert_file_exists "$MB/mark" "git の shim: 失敗させた印のファイルができる"
    assert_file_contains "$MB/shim.out" "わざと失敗させました" "git の shim: 理由が表示される"
    assert_file_not_exists "$MB/realgit.log" "git の shim: 失敗させたとき、本物の git は呼ばない"
    _git_shim -c credential.helper= push --no-verify origin main; rc=$?
    assert_exit_ok "$rc" "git の shim: 2 回目の push は、通る"
    assert_file_contains "$MB/realgit.log" "REAL: -c credential.helper= push --no-verify origin main" "git の shim: 2 回目は、本物の git に、引数をそのまま渡す"

    # --- main 以外の push・push 以外は、失敗させない ---
    rm -f "$MB/mark" "$MB/realgit.log"
    _git_shim push origin admin; rc=$?
    assert_exit_ok "$rc" "git の shim: main 以外の push は、失敗させない"
    assert_file_not_exists "$MB/mark" "git の shim: main 以外の push では、印を作らない"
    _git_shim commit -m "main の変更"; rc=$?
    assert_exit_ok "$rc" "git の shim: push 以外（commit）は、失敗させない"
    _git_shim checkout main; rc=$?
    assert_exit_ok "$rc" "git の shim: push 以外（checkout main）は、失敗させない"
    assert_file_not_exists "$MB/mark" "git の shim: push 以外では、印を作らない"

    # --- 印の指定がなければ、何も失敗させない / 本物の git の指定がなければ、失敗する ---
    rm -f "$MB/mark" "$MB/realgit.log"
    ( E2E_REAL_GIT="$MB/realgit" bash "$shim" push origin main ) > "$MB/shim.out" 2>&1; rc=$?
    assert_exit_ok "$rc" "git の shim: 印の指定がなければ、main への push も失敗させない"
    ( unset E2E_REAL_GIT; E2E_GIT_FAIL_MARK="$MB/mark" bash "$shim" push origin main ) > "$MB/shim.out" 2>&1; rc=$?
    assert_exit_fail "$rc" "git の shim: 本物の git の指定がなければ、動かない"

    # --- run.sh のオプション ---
    : > "$MOCK_CALL_LOG"
    ( cd "$HM" && export HOME="$HM" PATH="$MB:$PATH" E2E_FIXTURE="$FX"
      printf 'Y' | bash "$E2E_DIR/run.sh" --interrupt --resume ) > "$MB/out.log" 2>&1; rc=$?
    assert_exit_fail "$rc" "run.sh: --interrupt と --resume の同時指定は、中止する"
    assert_file_contains "$MB/out.log" "新しくリポジトリを作るときだけ" "run.sh: --interrupt + --resume: 理由が表示される"
    assert_equals "$(grep -c 'gh repo delete\|gh repo create' "$MOCK_CALL_LOG")" "0" "run.sh: オプションの検証で中止したとき、何も削除・作成しない"
    bash "$E2E_DIR/run.sh" --help 2>&1 | grep -q -- "--interrupt" && pass "run.sh --help に、--interrupt の説明がある" || fail "run.sh --help に、--interrupt の説明がある"
    assert_file_contains "$E2E_DIR/run.sh" "_interrupt_first_run" "run.sh: 1 回目（わざと失敗）の関数がある"
    assert_file_contains "$E2E_DIR/run.sh" "shims/git" "run.sh: git の shim を使う"
    assert_file_contains "$E2E_DIR/run.sh" "「続きをやる」を選ぶと" "run.sh: 失敗の画面の復旧の案内を、確認する"
    unset MOCK_CALL_LOG MOCK_GH_REPOS MOCK_SF_ECAS
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 30. シナリオ propagate-fail（main → staging の伝播のコンフリクト。失敗し、通知され、staging は変わらない）
# ------------------------------------------------------------------------------
test_e2e_scenario_propagate_fail() {
    echo ""; echo -e "${CLR_HEAD}[TEST] scenario.sh propagate-fail（main・staging に衝突を作る → wf-propagate が失敗 → 削除して戻す）${CLR_RST}"
    _mk_cleanup_env
    local rc f="e2e-propagate-conflict.txt"
    local ok_log=$'##[error]コンフリクト: main → staging のマージでコンフリクトが発生しました\nSlack response: {"ok":true}'
    export E2E_CONCLUSION_TRIES=1 VERIFY_DISPATCH_TRIES=2
    _reset_pf() {
        rm -f "$MB/disp.cnt" "$MB/concl.cnt" "$MB/stg.cnt"
        : > "$MB/mainfiles.txt"; : > "$MB/stagingfiles.txt"; : > "$MOCK_CALL_LOG"
        unset MOCK_GH_NO_STAGING MOCK_GH_STAGING_MOVE
    }

    # --- 成功: 衝突を作る → wf-propagate が失敗・通知 → staging は変わらない → ファイルを削除 ---
    _reset_pf
    MOCK_GH_CONCL_LIST="failure" MOCK_GH_RUN_LOG="$ok_log" _run_scenario -y propagate-fail; rc=$?
    [[ $rc -eq 0 ]] || sed 's/\x1b\[[0-9;]*m//g' "$MB/out.log" | tail -25
    assert_exit_ok "$rc" "propagate-fail: 成功する"
    assert_file_contains "$MB/out.log" "成功（" "propagate-fail: 結果が成功と表示される"
    assert_equals "$(grep -c "api -X PUT .*contents/${f}.*branch=main" "$MOCK_CALL_LOG")" "1" "propagate-fail: main に、ファイルを 1 回コミットする"
    assert_equals "$(grep -c "api -X PUT .*contents/${f}.*branch=staging" "$MOCK_CALL_LOG")" "1" "propagate-fail: staging に、ファイルを 1 回コミットする"
    assert_equals "$(grep -c 'workflow run wf-propagate.yml' "$MOCK_CALL_LOG")" "1" "propagate-fail: wf-propagate を 1 回起動する"
    assert_equals "$(grep -c 'workflow run' "$MOCK_CALL_LOG")" "1" "propagate-fail: ほかのワークフローは、起動しない"
    assert_equals "$(grep -c 'api -X DELETE repos/.*/contents/' "$MOCK_CALL_LOG")" "2" "propagate-fail: 削除は、main・staging の 2 回だけ"
    assert_equals "$(wc -c < "$MB/mainfiles.txt" | tr -d ' ')" "0" "propagate-fail: main に、ファイルが残らない"
    assert_equals "$(wc -c < "$MB/stagingfiles.txt" | tr -d ' ')" "0" "propagate-fail: staging に、ファイルが残らない"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr merge" "propagate-fail: PR は、扱わない"

    # --- 伝播が成功してしまった（衝突を検出できない）→ 失敗（それでも、削除する）---
    # --- 続けて動かす: main にコミットしてよいシナリオのあとも、次のシナリオが、「main が変わった」と誤判定されない（基準を更新する）---
    _reset_pf; rm -f "$MB/mainsha.cnt"   # main の SHA の呼び出し回数を、0 に戻す（1 回目は、元の SHA・2 回目以降は、変わった SHA を返すため）
    MOCK_GH_MAIN_SHA_CHANGE=1 MOCK_GH_RUN_IDS="11" MOCK_GH_CONCL_LIST="failure" MOCK_GH_RUN_LOG="$ok_log" _run_scenario -y propagate-fail log-secrets; rc=$?
    [[ $rc -eq 0 ]] || sed 's/\x1b\[[0-9;]*m//g' "$MB/out.log" | tail -15
    assert_exit_ok "$rc" "propagate-fail → log-secrets: 続けて動かしても、成功する（main の基準を更新する）"
    assert_file_contains "$MB/out.log" "log-secrets: 成功" "propagate-fail → log-secrets: あとのシナリオも、実行される（状態が変わったと誤判定しない）"
    assert_file_not_contains "$MB/out.log" "状態（main の SHA" "propagate-fail → log-secrets: 状態の変化として、報告されない"

    _reset_pf
    MOCK_GH_CONCL_LIST="success" MOCK_GH_RUN_LOG="$ok_log" _run_scenario -y propagate-fail; rc=$?
    assert_exit_fail "$rc" "propagate-fail: wf-propagate が成功してしまったら、失敗する"
    assert_equals "$(wc -c < "$MB/mainfiles.txt" | tr -d ' ')" "0" "propagate-fail: 失敗しても、main のファイルは削除される"
    assert_equals "$(wc -c < "$MB/stagingfiles.txt" | tr -d ' ')" "0" "propagate-fail: 失敗しても、staging のファイルは削除される"

    # --- Slack への通知が出ていない → 失敗 ---
    _reset_pf
    MOCK_GH_CONCL_LIST="failure" MOCK_GH_RUN_LOG="コンフリクト" _run_scenario -y propagate-fail; rc=$?
    assert_exit_fail "$rc" "propagate-fail: Slack への通知（ok:true）がなければ、失敗する"

    # --- staging が、失敗したのに、動いた（壊した）→ 失敗 ---
    _reset_pf
    MOCK_GH_STAGING_MOVE=1 MOCK_GH_CONCL_LIST="failure" MOCK_GH_RUN_LOG="$ok_log" _run_scenario -y propagate-fail; rc=$?
    assert_exit_fail "$rc" "propagate-fail: 失敗した伝播で、staging の先頭が動いたら、失敗する"
    assert_file_contains "$MB/out.log" "ブランチを壊さない" "propagate-fail: 確認の項目が、表示される"

    # --- ワークフローが動かない → 失敗（途中で止まっても、削除する）---
    _reset_pf
    MOCK_GH_WORKFLOW_EXIT=1 _run_scenario -y propagate-fail; rc=$?
    assert_exit_fail "$rc" "propagate-fail: wf-propagate を起動できなければ、失敗する"
    assert_equals "$(wc -c < "$MB/mainfiles.txt" | tr -d ' ')" "0" "propagate-fail: 途中で止まっても、main のファイルは削除される"
    assert_equals "$(wc -c < "$MB/stagingfiles.txt" | tr -d ' ')" "0" "propagate-fail: 途中で止まっても、staging のファイルは削除される"

    # --- 前提: staging がない → 実行できない（何もコミットしない）---
    _reset_pf
    MOCK_GH_NO_STAGING=1 _run_scenario -y propagate-fail; rc=$?
    assert_exit_fail "$rc" "propagate-fail: staging がなければ、実行できない"
    assert_file_contains "$MB/out.log" "実行できない" "propagate-fail: 「実行できない」と報告する"
    assert_file_not_contains "$MOCK_CALL_LOG" "api -X PUT" "propagate-fail: 実行できないときは、何もコミットしない"
    assert_file_not_contains "$MOCK_CALL_LOG" "api -X DELETE" "propagate-fail: 実行できないときは、何も削除しない"

    # --- 前提: すでにファイルがある → 実行できない（触れない）---
    _reset_pf; echo "$f" > "$MB/mainfiles.txt"
    _run_scenario -y propagate-fail; rc=$?
    assert_exit_fail "$rc" "propagate-fail: main にすでにファイルがあれば、実行できない"
    assert_file_contains "$MB/mainfiles.txt" "$f" "propagate-fail: 実行できないときは、既存のファイルに触れない"

    # --- 開始の警告 ---
    _reset_pf
    _run_scenario propagate-fail < <(printf 'N\n'); rc=$?
    assert_exit_fail "$rc" "propagate-fail: 開始の確認で N → 中止する"
    assert_file_contains "$MB/out.log" "書き込み（propagate-fail）" "propagate-fail: 警告に、書き込む内容が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "api -X PUT" "propagate-fail: N のとき、何もコミットしない"
    unset E2E_CONCLUSION_TRIES VERIFY_DISPATCH_TRIES
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 31. シナリオ restart-org（sf-restart で接続先を staging の組織に切り替え → dry-run → 元に戻す）
# ------------------------------------------------------------------------------
# sf-restart.sh の代わりの台本（E2E_SF_RESTART）: 標準入力の 1 行目（エイリアス）で、.sf/config.json を作り直し、その組織のユーザーを記録する
#   （末尾が STG なら staging のユーザー・それ以外は main のユーザー）。sf-install.sh の完了メッセージも、ログに書く
_mk_restart_stubs() {
    cat > "$MB/restart-stub.sh" << 'EOF'
#!/bin/bash
d="${MOCK_CALL_LOG%/*}"
read -r alias
echo "restart $alias" >> "$d/restart.log"
[[ "${MOCK_RESTART_FAIL:-}" == "1" ]] && { echo "restart stub: 失敗" >&2; exit 1; }
mkdir -p .sf sf-tools/logs
printf '{"target-org": "%s"}\n' "$alias" > .sf/config.json
case "$alias" in *STG) echo "stg@example.com" > "$d/org_user.$alias" ;; *) echo "main@example.com" > "$d/org_user.$alias" ;; esac
echo "npm install の確認が完了しました" > sf-tools/logs/sf-install.log
exit 0
EOF
    cat > "$MB/dryrun-stub.sh" << 'EOF'
#!/bin/bash
echo "接続先組織: $(sed -n 's/.*"target-org": *"\([^"]*\)".*/\1/p' .sf/config.json)"
exit "${MOCK_DRYRUN_EXIT:-0}"
EOF
    chmod +x "$MB/restart-stub.sh" "$MB/dryrun-stub.sh"
}

test_e2e_scenario_restart_org() {
    echo ""; echo -e "${CLR_HEAD}[TEST] scenario.sh restart-org（接続先を staging の組織に切り替え → dry-run → 元に戻す）${CLR_RST}"
    _mk_cleanup_env
    _mk_restart_stubs
    local rc proj="e2e-20260101-000000" repo="force-e2e-20260101-000000"
    local clone="$CB/root/home/tamashimon-org/$proj/e2e-hello-123456/$repo"
    local fx_stg="$CB/fx-stg.env"
    cp "$FX" "$fx_stg"; echo 'E2E_SFDX_AUTH_URL_STG=force://PlatformCLI::stgurl@example.my.salesforce.com' >> "$fx_stg"
    export E2E_SF_RESTART="$MB/restart-stub.sh" E2E_SF_DRYRUN="$MB/dryrun-stub.sh" E2E_INSTALL_TIMEOUT=2 E2E_CMD_POLL_SEC=1 E2E_HEARTBEAT_SEC=100
    _reset_ro() {
        rm -rf "$clone"; mkdir -p "$clone/.sf"
        printf '{"target-org": "sf-tools-e2e-job"}\n' > "$clone/.sf/config.json"
        rm -f "$MB"/org_user.* "$MB/restart.log"
        printf 'SLACK_CHANNEL_ID=C01ABCDEFGH\nSF_USERNAME_STG=stg@example.com\n' > "$MB/vars.txt"; : > "$MB/secrets.txt"
        : > "$MOCK_CALL_LOG"
    }
    _run_scn_stg() { ( cd "$HM" && export HOME="$HM" PATH="$MB:$PATH" E2E_FIXTURE="$fx_stg" E2E_POLL_SEC=0; bash "$E2E_DIR/scenario.sh" "$@" ) > "$MB/out.log" 2>&1; }

    # --- 成功: 切り替え → 組織が変わる → dry-run → 元に戻る ---
    _reset_ro
    _run_scn_stg -y restart-org; rc=$?
    [[ $rc -eq 0 ]] || sed 's/\x1b\[[0-9;]*m//g' "$MB/out.log" | tail -25
    assert_exit_ok "$rc" "restart-org: 成功する"
    assert_file_contains "$MB/out.log" "成功（" "restart-org: 結果が成功と表示される"
    assert_equals "$(tr '\n' ',' < "$MB/restart.log")" "restart sf-tools-e2e-restart-STG,restart sf-tools-e2e-job," "restart-org: 切り替え（STG）→ 戻す（元のエイリアス）の順に、sf-restart を呼ぶ"
    assert_file_contains "$clone/.sf/config.json" "sf-tools-e2e-job" "restart-org: 終了後、クローンの接続先は、元のエイリアスに戻る"
    assert_file_contains "$MOCK_CALL_LOG" "org login sfdx-url" "restart-org: 元のエイリアスで、認証 URL でログインし直してから、ユーザーを読む"
    assert_file_not_contains "$MOCK_CALL_LOG" "project deploy" "restart-org: 組織へ、デプロイしない（dry-run は、台本）"
    assert_file_not_contains "$MOCK_CALL_LOG" "repo delete" "restart-org: リポジトリは、削除しない"

    # --- dry-run が失敗 → 失敗（それでも、元に戻す）---
    _reset_ro
    MOCK_DRYRUN_EXIT=1 _run_scn_stg -y restart-org; rc=$?
    assert_exit_fail "$rc" "restart-org: dry-run が失敗したら、失敗する"
    assert_equals "$(tr '\n' ',' < "$MB/restart.log")" "restart sf-tools-e2e-restart-STG,restart sf-tools-e2e-job," "restart-org: 失敗しても、元の組織へ戻す"
    assert_file_contains "$clone/.sf/config.json" "sf-tools-e2e-job" "restart-org: 失敗しても、クローンの接続先は、元に戻る"

    # --- 切り替え自体が失敗 → 失敗（元に戻す処理も、同じように失敗したら、手での戻し方を案内する）---
    _reset_ro
    MOCK_RESTART_FAIL=1 _run_scn_stg -y restart-org; rc=$?
    assert_exit_fail "$rc" "restart-org: sf-restart が失敗したら、失敗する"
    assert_file_contains "$MB/out.log" "sf-restart.sh を実行して" "restart-org: 戻せなかったときは、手での戻し方を案内する"

    # --- 前提: staging の組織が、鍵一式にない → 実行できない ---
    _reset_ro
    _run_scenario -y restart-org; rc=$?
    assert_exit_fail "$rc" "restart-org: 鍵一式に staging の組織がなければ、実行できない"
    assert_file_contains "$MB/out.log" "実行できない" "restart-org: 「実行できない」と報告する"
    assert_equals "$(wc -l < "$MB/restart.log" 2>/dev/null | tr -d ' ')" "" "restart-org: 実行できないときは、sf-restart を呼ばない"

    # --- 前提: 接続済みのジョブのクローンがない / SF_USERNAME_STG がない → 実行できない ---
    _reset_ro; rm -rf "$clone"
    _run_scn_stg -y restart-org; rc=$?
    assert_exit_fail "$rc" "restart-org: ジョブのクローンがなければ、実行できない"
    _reset_ro; printf 'SLACK_CHANNEL_ID=C01ABCDEFGH\n' > "$MB/vars.txt"
    _run_scn_stg -y restart-org; rc=$?
    assert_exit_fail "$rc" "restart-org: Variable SF_USERNAME_STG がなければ、実行できない"
    assert_file_not_contains "$MOCK_CALL_LOG" "org login" "restart-org: 実行できないときは、ログインしない"

    # --- 開始の警告 ---
    _reset_ro
    _run_scn_stg restart-org < <(printf 'N\n'); rc=$?
    assert_exit_fail "$rc" "restart-org: 開始の確認で N → 中止する"
    assert_file_contains "$MB/out.log" "書き込み（restart-org）" "restart-org: 警告に、書き込む内容が表示される"
    assert_equals "$(wc -l < "$MB/restart.log" 2>/dev/null | tr -d ' ')" "" "restart-org: N のとき、sf-restart を呼ばない"
    unset E2E_SF_RESTART E2E_SF_DRYRUN E2E_INSTALL_TIMEOUT E2E_CMD_POLL_SEC E2E_HEARTBEAT_SEC
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 32. GitHub Actions で動かす準備（ci-fixture.sh と、専用ワークフロー e2e.yml の整合）
# ------------------------------------------------------------------------------
test_e2e_ci() {
    echo ""; echo -e "${CLR_HEAD}[TEST] Actions で動かす準備（ci-fixture.sh・e2e.yml）${CLR_RST}"
    local mb; mb=$(setup_mock_bin); MB="$mb"; HM="$mb/home"; mkdir -p "$HM"
    local CF="$E2E_DIR/ci-fixture.sh" rc
    local _env=(E2E_OWNER=acme-org E2E_GH_USER=bot-user E2E_SLACK_CHANNEL_ID=C0123456789
                E2E_PAT_TOKEN='ghp_pat$x y' E2E_SLACK_BOT_TOKEN=xoxb-slack
                E2E_SFDX_AUTH_URL='force://PlatformCLI::tok@example.my.salesforce.com')

    # Actions 上でなければ、動かない（手元の鍵一式を、上書きしない）
    ( export HOME="$HM"; env "${_env[@]}" bash "$CF" ) > "$mb/out.log" 2>&1; rc=$?
    assert_exit_fail "$rc" "GitHub Actions 上でなければ、動かない（手元の鍵一式を上書きしない）"
    [[ ! -e "$HM/.sf-tools-e2e/fixture.env" ]] && pass "手元では、鍵一式を作らない" || fail "手元では、鍵一式を作らない"

    # 必須の値が空なら、値は出さず、変数名だけを表示して終わる
    ( export HOME="$HM" GITHUB_ACTIONS=true; env "${_env[@]}" E2E_PAT_TOKEN= bash "$CF" ) > "$mb/out.log" 2>&1; rc=$?
    assert_exit_fail "$rc" "必須の値が空なら、失敗する"
    assert_file_contains     "$mb/out.log" "E2E_PAT_TOKEN" "未登録の変数名が表示される"
    assert_file_not_contains "$mb/out.log" "xoxb-slack"    "ほかの値は、表示されない"

    # 作った鍵一式を、e2e の読み込み（e2e_load_fixture）が、そのまま読める（空白・記号を含む値も、そのまま）
    ( export HOME="$HM" GITHUB_ACTIONS=true; env "${_env[@]}" bash "$CF" ) > "$mb/out.log" 2>&1; rc=$?
    assert_exit_ok "$rc" "必須の値がそろえば、鍵一式を作る"
    assert_file_not_contains "$mb/out.log" "xoxb-slack" "作るときに、値を表示しない"
    ( export HOME="$HM" SF_INIT_MODE=1; unset E2E_FIXTURE
      bash -c "
          readonly SCRIPT_NAME=test; readonly LOG_FILE=/dev/null; readonly LOG_MODE=NEW
          source '$SF_TOOLS_DIR/lib/common.sh'; source '$E2E_DIR/lib.sh'
          e2e_load_fixture
          echo \"OWNER=\$E2E_OWNER|PAT=\$E2E_PAT_TOKEN|ROOT=\$E2E_HOME_ROOT|STG=\${E2E_SFDX_AUTH_URL_STG:-none}\"
      " ) > "$mb/out.log" 2>&1
    assert_file_contains "$mb/out.log" 'OWNER=acme-org|PAT=ghp_pat$x y|ROOT='"$HM"'/e2e-home|STG=none' "e2e_load_fixture が読める（記号・空白を含む値もそのまま。staging の組織は、なければ空）"
    if [[ "$OSTYPE" != msys* && "$OSTYPE" != mingw* && "$OSTYPE" != cygwin* ]]; then  # Windows（Git Bash）は、権限が効かない
        assert_equals "$(stat -c %a "$HM/.sf-tools-e2e/fixture.env" 2>/dev/null || stat -f %Lp "$HM/.sf-tools-e2e/fixture.env")" "600" "鍵一式の権限は、本人のみ（600）"
    fi
    ( export HOME="$HM" GITHUB_ACTIONS=true; env "${_env[@]}" E2E_SFDX_AUTH_URL_STG='force://PlatformCLI::stg@example.my.salesforce.com' bash "$CF" ) > /dev/null 2>&1
    assert_file_contains "$HM/.sf-tools-e2e/fixture.env" "E2E_SFDX_AUTH_URL_STG=" "staging の組織が渡されたら、鍵一式に入れる"

    # ci-mask.sh: 組織の ID・ユーザー名・URL・アクセストークンを、「::add-mask::」で伏せる（偽の sf で確認）
    local CM="$E2E_DIR/ci-mask.sh"
    cat > "$mb/sf" <<'SFEOF'
#!/bin/bash
case "$1 $2 $3" in
    "org login sfdx-url") [[ -n "${MOCK_SF_LOGIN_FAIL:-}" ]] && exit 1; exit 0 ;;
    "org display "*)
        printf '{"status":0,"result":{"id":"00D5g00000FDr1YEAT","username":"mask.user@example.com","accessToken":"00D5g00000FDr1Y!AQEAQtoken123","instanceUrl":"https://orgfarm-abc123.my.salesforce.com","alias":"e2e-mask-probe"}}
' ;;
    "org logout "*) exit 0 ;;
esac
exit 0
SFEOF
    chmod +x "$mb/sf"
    ( export HOME="$HM" PATH="$mb:$PATH" E2E_SFDX_AUTH_URL='force://PlatformCLI::tok@example.my.salesforce.com'; bash "$CM" ) > "$mb/out.log" 2>&1; rc=$?
    assert_exit_fail "$rc" "ci-mask.sh は、GitHub Actions 上でなければ、動かない"
    ( export HOME="$HM" PATH="$mb:$PATH" GITHUB_ACTIONS=true E2E_SFDX_AUTH_URL='force://PlatformCLI::tok@example.my.salesforce.com'; bash "$CM" ) > "$mb/out.log" 2>&1; rc=$?
    assert_exit_ok "$rc" "ci-mask.sh: 組織にログインして、値を調べる"
    assert_file_contains "$mb/out.log" "::add-mask::00D5g00000FDr1YEAT"   "ci-mask.sh: 組織 ID（18 桁）を伏せる"
    assert_file_contains "$mb/out.log" "::add-mask::00D5g00000FDr1Y"      "ci-mask.sh: 組織 ID（15 桁）を伏せる"
    assert_file_contains "$mb/out.log" "::add-mask::mask.user@example.com" "ci-mask.sh: ユーザー名を伏せる"
    assert_file_contains "$mb/out.log" "::add-mask::00D5g00000FDr1Y!AQEAQtoken123" "ci-mask.sh: アクセストークンを伏せる"
    assert_file_contains "$mb/out.log" "::add-mask::https://orgfarm-abc123.my.salesforce.com" "ci-mask.sh: My Domain の URL を伏せる"
    assert_file_contains "$mb/out.log" "::add-mask::orgfarm-abc123.my.salesforce.com"         "ci-mask.sh: My Domain のホスト名を伏せる"
    assert_file_not_contains "$mb/out.log" "force://" "ci-mask.sh: 認証 URL を表示しない"
    ( export HOME="$HM" PATH="$mb:$PATH" GITHUB_ACTIONS=true MOCK_SF_LOGIN_FAIL=1 E2E_SFDX_AUTH_URL='force://PlatformCLI::tok@example.my.salesforce.com'; bash "$CM" ) > "$mb/out.log" 2>&1; rc=$?
    assert_exit_ok "$rc" "ci-mask.sh: ログインできなくても、失敗にしない（e2e の本体が、原因を表示する）"
    assert_file_contains "$mb/out.log" "ログインできなかった" "ci-mask.sh: ログインできなかったことを表示する"
    rm -f "$mb/sf"

    # ci-notify.sh: 失敗を Slack に通知する（偽の curl で確認）。入力の形式が不正なら、通知しない
    local CN="$E2E_DIR/ci-notify.sh"
    cat > "$mb/curl" <<'CEOF'
#!/bin/bash
printf '%s
' "$@" > "${MOCK_CURL_ARGS:?}"
if [[ -n "${MOCK_CURL_FAIL:-}" ]]; then printf '{"ok":false,"error":"channel_not_found"}'; else printf '{"ok":true}'; fi
CEOF
    chmod +x "$mb/curl"
    local _nenv=(SLACK_BOT_TOKEN=xoxb-secret-token SLACK_CHANNEL_ID=C0ABCDEFGHI
                 RUN_URL=https://github.com/tama-create/sf-tools/actions/runs/123456 EVENT=schedule REF=main SHA=0123456789abcdef0123456789abcdef01234567)
    ( export PATH="$mb:$PATH" MOCK_CURL_ARGS="$mb/curl.args"; env "${_nenv[@]}" bash "$CN" ) > "$mb/out.log" 2>&1; rc=$?
    assert_exit_fail "$rc" "ci-notify.sh は、GitHub Actions 上でなければ、動かない"
    ( export PATH="$mb:$PATH" GITHUB_ACTIONS=true MOCK_CURL_ARGS="$mb/curl.args"; env "${_nenv[@]}" bash "$CN" ) > "$mb/out.log" 2>&1; rc=$?
    assert_exit_ok "$rc" "ci-notify.sh: Slack に通知する"
    assert_file_contains "$mb/curl.args" "chat.postMessage"             "ci-notify.sh: Slack の chat.postMessage に送る"
    assert_file_contains "$mb/curl.args" '"channel":"C0ABCDEFGHI"'      "ci-notify.sh: 通知先のチャンネルに送る"
    assert_file_contains "$mb/curl.args" "schedule / main / 0123456"    "ci-notify.sh: イベント・ブランチ・コミット（7 桁）を入れる"
    assert_file_contains "$mb/curl.args" "actions/runs/123456"          "ci-notify.sh: 実行の URL を入れる"
    assert_file_not_contains "$mb/out.log" "xoxb-secret-token"          "ci-notify.sh: Token を表示しない"
    ( export PATH="$mb:$PATH" GITHUB_ACTIONS=true MOCK_CURL_ARGS="$mb/curl.args" MOCK_CURL_FAIL=1; env "${_nenv[@]}" bash "$CN" ) > "$mb/out.log" 2>&1; rc=$?
    assert_exit_fail "$rc" "ci-notify.sh: Slack が拒否したら、失敗にする"
    assert_file_contains "$mb/out.log" "channel_not_found" "ci-notify.sh: 失敗の理由（error のコード）を表示する"
    rm -f "$mb/curl.args"
    ( export PATH="$mb:$PATH" GITHUB_ACTIONS=true MOCK_CURL_ARGS="$mb/curl.args"; env "${_nenv[@]}" 'REF=main"},{"x":"' bash "$CN" ) > "$mb/out.log" 2>&1; rc=$?
    assert_exit_fail "$rc" "ci-notify.sh: 引用符を含む入力は、通知しない（JSON を壊さない）"
    [[ ! -e "$mb/curl.args" ]] && pass "ci-notify.sh: 不正な入力では、curl を呼ばない" || fail "ci-notify.sh: 不正な入力では、curl を呼ばない"
    ( export PATH="$mb:$PATH" GITHUB_ACTIONS=true MOCK_CURL_ARGS="$mb/curl.args"; env "${_nenv[@]}" SLACK_BOT_TOKEN= bash "$CN" ) > "$mb/out.log" 2>&1; rc=$?
    assert_exit_fail "$rc" "ci-notify.sh: 必須の値が空なら、失敗する"
    assert_file_contains "$mb/out.log" "SLACK_BOT_TOKEN" "ci-notify.sh: 空の変数名を表示する"
    rm -f "$mb/curl"

    # 専用ワークフロー e2e.yml が、ガード（lib.sh の e2e_actions_allowed）と食い違っていない
    local wf="$SF_TOOLS_DIR/.github/workflows/e2e.yml"
    assert_file_contains     "$wf" "environment: e2e"      "e2e.yml: Secrets を置く Environment（e2e）を使う"
    assert_file_contains     "$wf" "group: e2e"            "e2e.yml: 同じ組織を使うため、実行どうしを一列にする（concurrency）"
    assert_file_contains     "$wf" 'cancel-in-progress: false' "e2e.yml: 実行中のものを、止めない"
    assert_file_contains     "$wf" 'E2E_ALLOW_ACTIONS: "1"' "e2e.yml: ガードを通す印を、渡す"
    assert_file_contains     "$wf" "needs: windows"        "e2e.yml: macOS は、Windows のあとに動かす（同じ組織を、同時に使わない）"
    assert_file_contains     "$wf" "--no-actions --no-add-tier" "e2e.yml: macOS は、クライアント側だけ"
    assert_file_contains     "$wf" "branches: [development]" "e2e.yml: push は、development だけ（rr のときには、すでに緑にする）"
    assert_file_contains     "$wf" "- 'bin/**'"            "e2e.yml: 配布物（bin/）の変更で動く"
    assert_file_not_contains "$wf" "- 'doc/**'"            "e2e.yml: ドキュメントだけの変更では、動かさない"
    assert_file_contains     "$wf" 'touch "$HOME/.sf-tools-last-update"' "e2e.yml: 更新済みの印を先に置く（e2e の実行中に、バックグラウンドの sf-upgrade.sh が、sf を入れ替えない）"
    assert_equals "$(grep -c 'touch "$HOME/.sf-tools-last-update"' "$wf")" "2" "e2e.yml: 更新済みの印は、Windows・macOS の両方のジョブで置く"
    # 組織名・ユーザー名・チャンネル ID は、公開ログに出さないため、Secrets から読む（Variables は使わない）
    for _n in E2E_OWNER E2E_GH_USER E2E_SLACK_CHANNEL_ID; do
        assert_file_contains "$wf" 'secrets.'"${_n}"' }}' "e2e.yml: ${_n} は、Secrets から読む"
    done
    assert_file_not_contains "$wf" 'vars.' "e2e.yml: Variables を使わない（公開ログに値が出るため、すべて Secrets）"
    assert_file_contains "$wf" "cron: '0 18 * * 0'"        "e2e.yml: 週 1 回（月曜 03:00 日本時間）、定期実行する"
    assert_file_contains "$wf" "scenario.sh\" -y log-secrets manual-delete update-secret sync-wf cross-os validate-fail metasync-diff propagate-fail restart-org" "e2e.yml: Windows の最後に、実環境のシナリオを動かす（dist-main は、rr の直後だけなので、除く）"
    assert_file_not_contains "$wf" "scenario.sh\" -y .*dist-main" "e2e.yml: dist-main は、動かさない（origin/main と origin/development に差がないときだけ動くため）"
    # OS 混在の確認（C2）: Windows が作ったリポジトリの名前を渡し、macOS が、自分の run.sh（開始時に、残りを全部削除する）より前に、確認する
    assert_file_contains "$wf" 'repo: ${{ steps.repo.outputs.name }}' "e2e.yml: Windows のジョブが、テスト用リポジトリの名前を、macOS のジョブへ渡す"
    assert_file_contains "$wf" 'REPO: ${{ needs.windows.outputs.repo }}' "e2e.yml: macOS のジョブが、渡された名前を使う"
    assert_file_contains "$wf" 'scenario.sh" -y --repo "$REPO" cross-os' "e2e.yml: macOS が、Windows の作ったリポジトリに対して、OS 混在の確認（cross-os）を行う"
    assert_equals "$(grep -n 'scenario.sh" -y --repo "$REPO" cross-os' "$wf" | cut -d: -f1 | head -1 | awk '{ print ($1 > 0 && $1 < '"$(grep -n -- '--no-actions --no-add-tier --cleanup' "$wf" | cut -d: -f1 | head -1)"') ? "before" : "after" }')" "before" "e2e.yml: cross-os は、macOS の run.sh（残ったリポジトリを、すべて削除する）より前に動かす"
    assert_file_contains "$wf" "needs: [windows, macos]"   "e2e.yml: 通知は、Windows・macOS の両方の結果を見る"
    assert_file_contains "$wf" "ci-notify.sh"              "e2e.yml: 失敗したとき、Slack に通知する"
    assert_equals "$(grep -c 'ci-mask.sh"$' "$wf" | tr -d ' ')" "2"  "e2e.yml: 組織の ID・ユーザー名・URL を伏せる手順を、Windows・macOS の両方に置く"
    assert_file_not_contains "$wf" "pull_request"          "e2e.yml: pull_request では動かさない（Secrets を渡さない）"
    assert_file_not_contains "$wf" "pull_request_target"   "e2e.yml: pull_request_target では動かさない"
    assert_file_not_contains "$wf" "secrets: inherit"      "e2e.yml: Secrets を、ほかのワークフローに引き渡さない"
    # ガードが許すファイル名と、実際のファイル名が同じ
    assert_file_contains "$E2E_DIR/lib.sh" 'workflows/e2e\.yml@refs/heads/' "lib.sh: ガードが見るワークフローは、e2e.yml"
    [[ -f "$wf" ]] && pass "e2e.yml がある（ガードが許すファイル名と同じ）" || fail "e2e.yml がある"
    teardown "$mb"
}

# ------------------------------------------------------------------------------
# 33. シナリオ sync-wf（改変したワークフローを sf-sync-wf が見つけて直す。--remove は、雛形にあるファイルを拒否する）
# ------------------------------------------------------------------------------
test_e2e_scenario_sync_wf() {
    echo ""; echo -e "${CLR_HEAD}[TEST] scenario.sh sync-wf（B4。管理者用のクローンの中だけ）${CLR_RST}"
    _mk_cleanup_env
    # git の改行の自動変換（core.autocrlf）を、テストの中で、そろえる。シナリオは、HOME を一時フォルダに差し替えて動くため、Windows の標準の
    #   設定（true）で git を動かし、テストの確認（git status）は、CI の設定（false）で動くと、LF と CRLF の違いが、変更に見える（Windows の CI だけで失敗した）
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=false
    local rc proj="e2e-20260101-000000" repo="force-e2e-20260101-000000"
    local clone="$CB/root/home/tamashimon-org/$proj/admin/$repo" tpl="$MB/tpl"
    mkdir -p "$tpl"; printf 'name: wf-validate
on: pull_request
' > "$tpl/wf-validate.yml"
    # 代役の sf-sync-wf.sh（雛形は $tpl。--check: 差分があれば終了コード 1・雛形にないファイルは案内だけ / 引数なし: 雛形で上書き / --remove: 雛形にあれば拒否）
    cat > "$MB/syncwf-stub.sh" <<'SWEOF'
#!/bin/bash
tpl="${SYNCWF_TPL:?}"; dst=".github/workflows"
case "${1:-}" in
    --check)
        rc=0
        for f in "$tpl"/*; do n=$(basename "$f"); cmp -s "$f" "$dst/$n" || { echo "差分: $n"; rc=1; }; done
        for f in "$dst"/*; do n=$(basename "$f"); [[ -e "$tpl/$n" ]] || echo "雛形にないワークフロー（変更しません）: $n"; done
        exit $rc ;;
    --remove)
        [[ ! -e "$tpl/$2" ]] || { echo "$2 は、雛形にあるため、削除できません"; exit 1; }
        [[ -f "$dst/$2" ]] || { echo "削除対象が見つかりません"; exit 1; }
        rm -f "$dst/$2"; exit 0 ;;
    "")
        cp "$tpl"/* "$dst"/; exit 0 ;;
esac
exit 2
SWEOF
    chmod +x "$MB/syncwf-stub.sh"
    export E2E_SF_SYNC_WF="$MB/syncwf-stub.sh" SYNCWF_TPL="$tpl" E2E_CMD_POLL_SEC=1 E2E_HEARTBEAT_SEC=100
    _reset_sw() {   # 本物の git で、管理者用のクローン（admin ブランチ・雛形と同じ内容をコミット済み）を作る
        rm -rf "$clone"; mkdir -p "$clone/.github/workflows"
        cp "$tpl/wf-validate.yml" "$clone/.github/workflows/wf-validate.yml"
        ( cd "$clone" && git init -q -b admin . && git -c user.name=t -c user.email=t@example.com add -A && git -c user.name=t -c user.email=t@example.com commit -q -m init )
        : > "$MOCK_CALL_LOG"
    }

    # --- 成功: 改変 → 見つかる → 雛形に戻る → --remove の拒否と、不要なファイルの削除 → きれいに戻る ---
    _reset_sw
    _run_scenario -y sync-wf; rc=$?
    [[ $rc -eq 0 ]] || sed 's/\[[0-9;]*m//g' "$MB/out.log" | tail -25
    assert_exit_ok "$rc" "sync-wf: 成功する"
    assert_file_contains "$MB/out.log" "成功（" "sync-wf: 結果が成功と表示される"
    assert_equals "$(git -C "$clone" status --porcelain)" "" "sync-wf: 終了後、クローンの作業ツリーは、きれい（改変も、不要なファイルも、残らない）"
    assert_equals "$(git -C "$clone" rev-list --count HEAD)" "1" "sync-wf: コミットを増やさない"
    assert_file_not_contains "$MOCK_CALL_LOG" "repo delete" "sync-wf: リポジトリは、削除しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "secret set" "sync-wf: GitHub に、書き込まない（Secret）"

    # --- sf-sync-wf が、雛形に戻せない（上書きが効かない）→ 失敗する。それでも、終了時に、クローンを元に戻す ---
    _reset_sw
    # 上書き（引数なし）だけを、何もせずに成功させる代役（壊れた sf-sync-wf.sh）。ほかは、元の代役に渡す
    printf '#!/bin/bash
[[ -n "${1:-}" ]] || exit 0
exec "%s" "$@"
' "$MB/syncwf-stub.sh" > "$MB/syncwf-broken.sh"; chmod +x "$MB/syncwf-broken.sh"
    E2E_SF_SYNC_WF="$MB/syncwf-broken.sh" _run_scenario -y sync-wf; rc=$?
    assert_exit_fail "$rc" "sync-wf: 雛形に戻らなければ、失敗する"
    assert_equals "$(git -C "$clone" status --porcelain)" "" "sync-wf: 失敗しても、終了時に、クローンを元に戻す"

    # --- 前提: クローンがない / 環境ブランチの上 / 未コミットの変更 → 実行できない ---
    _reset_sw; rm -rf "$clone"
    _run_scenario -y sync-wf; rc=$?
    assert_exit_fail "$rc" "sync-wf: 管理者用のクローンがなければ、実行できない"
    assert_file_contains "$MB/out.log" "実行できない" "sync-wf: 「実行できない」と報告する"
    _reset_sw; ( cd "$clone" && git branch -q -m main )
    _run_scenario -y sync-wf; rc=$?
    assert_exit_fail "$rc" "sync-wf: 環境ブランチ（main）の上では、実行できない"
    _reset_sw; printf 'x
' >> "$clone/.github/workflows/wf-validate.yml"
    _run_scenario -y sync-wf; rc=$?
    assert_exit_fail "$rc" "sync-wf: 未コミットの変更があれば、実行できない（元に戻せなくなるため）"
    assert_equals "$(tail -n 1 "$clone/.github/workflows/wf-validate.yml")" "x" "sync-wf: 実行できないときは、あった変更に、触らない"

    # --- 開始の警告 ---
    _reset_sw
    _run_scenario sync-wf < <(printf 'N
'); rc=$?
    assert_exit_fail "$rc" "sync-wf: 開始の確認で N → 中止する"
    assert_file_contains "$MB/out.log" "書き込み（sync-wf）" "sync-wf: 警告に、書き込む内容が表示される"
    unset E2E_SF_SYNC_WF SYNCWF_TPL E2E_CMD_POLL_SEC E2E_HEARTBEAT_SEC GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 34. シナリオ update-secret（sf-update-secret で秘密鍵を同じ鍵で上書き。更新日時が進む・誤ったパスは拒否される）
# ------------------------------------------------------------------------------
test_e2e_scenario_update_secret() {
    echo ""; echo -e "${CLR_HEAD}[TEST] scenario.sh update-secret（B2。同じ秘密鍵で上書き）${CLR_RST}"
    _mk_cleanup_env
    local rc proj="e2e-20260101-000000" repo="force-e2e-20260101-000000"
    local clone="$CB/root/home/tamashimon-org/$proj/admin/$repo" key="$HM/.sf-jwt/$repo/server.key"
    # 代役の sf-update-secret.sh（入力: 続行 Y・メニュー 1・鍵のパス・更新 Y。鍵がなければ、拒否。あれば、gh secret set SF_PRIVATE_KEY）
    cat > "$MB/updsecret-stub.sh" <<'USEOF'
#!/bin/bash
read -r _a; read -r _b; read -r path
[[ -f "$path" ]] || { echo "ファイルが存在しません: $path"; exit 1; }
read -r _c
echo "更新します（秘密鍵の中身は表示しません）"
printf 'SECRET-VALUE' | gh secret set SF_PRIVATE_KEY -R tamashimon-org/force-e2e-20260101-000000
USEOF
    chmod +x "$MB/updsecret-stub.sh"
    export E2E_SF_UPDATE_SECRET="$MB/updsecret-stub.sh" E2E_SECRET_WAIT=0 E2E_CMD_POLL_SEC=1 E2E_HEARTBEAT_SEC=100
    _reset_us() {
        rm -rf "$clone" "$HM/.sf-jwt"; mkdir -p "$clone/.git" "$HM/.sf-jwt/$repo"
        printf -- '-----BEGIN PRIVATE KEY-----\nabc\n-----END PRIVATE KEY-----\n' > "$key"
        printf 'SF_PRIVATE_KEY\nSLACK_BOT_TOKEN\nPAT_TOKEN\n' > "$MB/secrets.txt"; rm -f "$MB/pk.ver"
        : > "$MOCK_CALL_LOG"
    }

    # --- 成功: 誤ったパスは拒否（更新されない）→ 同じ鍵で上書き（更新日時が進む・一覧は変わらない・鍵の中身は出ない）---
    _reset_us
    _run_scenario -y update-secret; rc=$?
    [[ $rc -eq 0 ]] || sed 's/\x1b\[[0-9;]*m//g' "$MB/out.log" | tail -25
    assert_exit_ok "$rc" "update-secret: 成功する"
    assert_file_contains "$MB/out.log" "成功（" "update-secret: 結果が成功と表示される"
    assert_equals "$(cat "$MB/pk.ver")" "1" "update-secret: SF_PRIVATE_KEY の更新は、1 回だけ（誤ったパスでは、更新しない）"
    assert_file_not_contains "$MB/out.log" "BEGIN PRIVATE KEY" "update-secret: 秘密鍵の中身を表示しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "repo delete" "update-secret: リポジトリは、削除しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "secret delete" "update-secret: Secret は、削除しない"

    # --- sf-update-secret が、実際には更新しない（更新日時が進まない）→ 失敗する ---
    _reset_us
    printf '#!/bin/bash\nread -r a; read -r b; read -r p; [[ -f "$p" ]] || exit 1\nexit 0\n' > "$MB/updsecret-noop.sh"; chmod +x "$MB/updsecret-noop.sh"
    E2E_SF_UPDATE_SECRET="$MB/updsecret-noop.sh" _run_scenario -y update-secret; rc=$?
    assert_exit_fail "$rc" "update-secret: 更新日時が進まなければ、失敗する"

    # --- 誤ったパスでも、更新してしまう（拒否しない）→ 失敗する ---
    _reset_us
    printf '#!/bin/bash\nread -r a; read -r b; read -r p; read -r c\nprintf x | gh secret set SF_PRIVATE_KEY -R tamashimon-org/force-e2e-20260101-000000\n' > "$MB/updsecret-bad.sh"; chmod +x "$MB/updsecret-bad.sh"
    E2E_SF_UPDATE_SECRET="$MB/updsecret-bad.sh" _run_scenario -y update-secret; rc=$?
    assert_exit_fail "$rc" "update-secret: 誤ったパスでも更新してしまうなら、失敗する"

    # --- 前提: 管理者用のクローンがない / 秘密鍵がない / Secret がない → 実行できない ---
    _reset_us; rm -rf "$clone"
    _run_scenario -y update-secret; rc=$?
    assert_exit_fail "$rc" "update-secret: 管理者用のクローンがなければ、実行できない"
    assert_file_contains "$MB/out.log" "実行できない" "update-secret: 「実行できない」と報告する"
    _reset_us; rm -f "$key"
    _run_scenario -y update-secret; rc=$?
    assert_exit_fail "$rc" "update-secret: 秘密鍵がなければ、実行できない"
    assert_file_not_contains "$MOCK_CALL_LOG" "secret set" "update-secret: 実行できないときは、Secret を更新しない"
    _reset_us
    MOCK_GH_NO_PK=1 _run_scenario -y update-secret; rc=$?
    assert_exit_fail "$rc" "update-secret: Secret SF_PRIVATE_KEY がなければ、実行できない"

    # --- 開始の警告 ---
    _reset_us
    _run_scenario update-secret < <(printf 'N\n'); rc=$?
    assert_exit_fail "$rc" "update-secret: 開始の確認で N → 中止する"
    assert_file_contains "$MB/out.log" "書き込み（update-secret）" "update-secret: 警告に、書き込む内容が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "secret set" "update-secret: N のとき、Secret を更新しない"
    unset E2E_SF_UPDATE_SECRET E2E_SECRET_WAIT E2E_CMD_POLL_SEC E2E_HEARTBEAT_SEC
    teardown "$CB"
}

# ------------------------------------------------------------------------------
# 35. シナリオ cross-os（別の OS が作ったリポジトリを clone して、改行・フック・ワークフローを確認する。読み取りのみ・--repo で指定）
# ------------------------------------------------------------------------------
test_e2e_scenario_cross_os() {
    echo ""; echo -e "${CLR_HEAD}[TEST] scenario.sh cross-os（C2。別の OS が作ったリポジトリを、clone して確認する）${CLR_RST}"
    _mk_cleanup_env
    # git の改行の自動変換を切る（CRLF のファイルを、そのまま記録する。Windows の標準の設定でも、同じ結果にする）
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.autocrlf GIT_CONFIG_VALUE_0=false
    local rc repo="force-e2e-20260101-000000" src="$MB/xos-src" hsrc="$MB/xos-hooks" tpl="$MB/xos-tpl"
    local base="$CB/root/home/tamashimon-org"
    mkdir -p "$hsrc" "$tpl" "$src"
    printf '#!/bin/bash\necho pre-commit\n' > "$hsrc/pre-commit"; printf '#!/bin/bash\necho pre-push\n' > "$hsrc/pre-push"
    printf 'name: wf-validate\non: pull_request\n' > "$tpl/wf-validate.yml"
    # 代役の sf-hook.sh（XOS_HOOK_MODE: ok = 同じ内容・実行できる / crlf = 行末が CRLF / diff = 内容が違う / none = 入れない / noexec = 実行権限なし）
    cat > "$MB/xos-hook.sh" <<'XHEOF'
#!/bin/bash
src="${XOS_HOOKS_SRC:?}"; mkdir -p .git/hooks
case "${XOS_HOOK_MODE:-ok}" in
    none) exit 0 ;;
    crlf) for h in pre-commit pre-push; do printf '#!/bin/bash\r\necho %s\r\n' "$h" > ".git/hooks/$h"; chmod +x ".git/hooks/$h"; done ;;
    diff) for h in pre-commit pre-push; do printf '#!/bin/bash\necho other\n' > ".git/hooks/$h"; chmod +x ".git/hooks/$h"; done ;;
    noexec) cp "$src/pre-commit" "$src/pre-push" .git/hooks/; chmod -x .git/hooks/pre-commit .git/hooks/pre-push ;;
    *) cp "$src/pre-commit" "$src/pre-push" .git/hooks/; chmod +x .git/hooks/pre-commit .git/hooks/pre-push ;;
esac
exit 0
XHEOF
    # 代役の sf-sync-wf.sh（--check: 雛形と同じなら 0、違えば 1）
    cat > "$MB/xos-sync.sh" <<'XSEOF'
#!/bin/bash
[[ "${1:-}" == "--check" ]] || exit 2
cmp -s "${SYNCWF_TPL:?}/wf-validate.yml" .github/workflows/wf-validate.yml || { echo "差分: wf-validate.yml"; exit 1; }
XSEOF
    chmod +x "$MB/xos-hook.sh" "$MB/xos-sync.sh"
    export E2E_SF_HOOK="$MB/xos-hook.sh" E2E_SF_SYNC_WF="$MB/xos-sync.sh" E2E_SF_HOOKS_DIR="$hsrc" XOS_HOOKS_SRC="$hsrc" SYNCWF_TPL="$tpl" \
           MOCK_GH_CLONE_SRC="$src" E2E_CMD_POLL_SEC=1 E2E_HEARTBEAT_SEC=100
    _reset_xos() {   # 本物の git で、clone 元のリポジトリ（main・LF のファイル）を作る。macOS のように、手元の作業フォルダは、ない
        rm -rf "$src"; mkdir -p "$src/.github/workflows" "$src/config"
        cp "$tpl/wf-validate.yml" "$src/.github/workflows/wf-validate.yml"
        printf 'main\nstaging\n' > "$src/config/branches.txt"
        ( cd "$src" && git init -q -b main . && git -c user.name=t -c user.email=t@example.com add -A && git -c user.name=t -c user.email=t@example.com commit -q -m init )
        rm -rf "$base"/e2e-20260101-000000 "$base"/e2e-xos.*
        : > "$MOCK_CALL_LOG"
    }
    _xos_left() { ls -d "$base"/e2e-xos.* 2>/dev/null | wc -l | tr -d ' '; }

    # --- 成功: --repo で指定（手元の作業フォルダがなくても動く）。一時フォルダは、残らない。GitHub には、書き込まない ---
    _reset_xos
    _run_scenario -y --repo "$repo" cross-os; rc=$?
    [[ $rc -eq 0 ]] || sed 's/\x1b\[[0-9;]*m//g' "$MB/out.log" | tail -25
    assert_exit_ok "$rc" "cross-os: 成功する（--repo で指定。手元の作業フォルダはない）"
    assert_file_contains "$MB/out.log" "成功（" "cross-os: 結果が成功と表示される"
    assert_file_contains "$MB/out.log" "CRLF（または、混在）がない" "cross-os: 改行（CRLF がない）を確認する"
    assert_file_contains "$MB/out.log" "同じ内容である" "cross-os: フックが、sf-tools のものと同じ内容かを確認する"
    assert_file_contains "$MB/out.log" "sf-sync-wf.sh --check が成功した" "cross-os: ワークフローが、雛形と同じかを確認する"
    assert_file_contains "$MOCK_CALL_LOG" "gh repo clone tamashimon-org/$repo" "cross-os: 指定されたリポジトリを clone する"
    assert_file_contains "$MOCK_CALL_LOG" "core.longpaths=true" "cross-os: Windows のパス長の上限対策（core.longpaths=true）を付けて clone する（通常の運用と同じ）"
    assert_equals "$(_xos_left)" "0" "cross-os: 終了後、clone した一時フォルダは、残らない"
    assert_file_not_contains "$MOCK_CALL_LOG" "repo delete" "cross-os: リポジトリは、削除しない"
    assert_file_not_contains "$MOCK_CALL_LOG" "secret set" "cross-os: GitHub に、書き込まない（Secret）"
    assert_file_not_contains "$MOCK_CALL_LOG" "git push" "cross-os: push しない"

    # --- 記録されたテキストファイルに CRLF がある（Windows が作ったファイルの改行が、そのまま入った）→ 失敗する ---
    _reset_xos
    printf 'a: 1\r\nb: 2\r\n' > "$src/crlf.yml"; ( cd "$src" && git -c user.name=t -c user.email=t@example.com add -A && git -c user.name=t -c user.email=t@example.com commit -q -m crlf )
    _run_scenario -y --repo "$repo" cross-os; rc=$?
    assert_exit_fail "$rc" "cross-os: 記録されたファイルに CRLF があれば、失敗する"
    assert_file_contains "$MB/out.log" "crlf.yml" "cross-os: CRLF のファイル名を表示する"
    assert_equals "$(_xos_left)" "0" "cross-os: 失敗しても、一時フォルダは、残らない"

    # --- フック: CR が入っている / 内容が違う / 入らない / 実行できない → 失敗する ---
    _reset_xos
    XOS_HOOK_MODE=crlf _run_scenario -y --repo "$repo" cross-os; rc=$?
    assert_exit_fail "$rc" "cross-os: フックに CR があれば、失敗する"
    _reset_xos
    XOS_HOOK_MODE=diff _run_scenario -y --repo "$repo" cross-os; rc=$?
    assert_exit_fail "$rc" "cross-os: フックの内容が、sf-tools のものと違えば、失敗する"
    _reset_xos
    XOS_HOOK_MODE=none _run_scenario -y --repo "$repo" cross-os; rc=$?
    assert_exit_fail "$rc" "cross-os: フックが入らなければ、失敗する"
    if [[ "$OSTYPE" != msys* && "$OSTYPE" != cygwin* ]]; then   # Windows（Git Bash）は、実行権限を同じようには判定できないため、確認しない
        _reset_xos
        XOS_HOOK_MODE=noexec _run_scenario -y --repo "$repo" cross-os; rc=$?
        assert_exit_fail "$rc" "cross-os: フックが実行できなければ、失敗する"
    fi

    # --- ワークフローが、雛形と違う → 失敗する ---
    _reset_xos
    printf 'name: drift\n' > "$src/.github/workflows/wf-validate.yml"; ( cd "$src" && git -c user.name=t -c user.email=t@example.com add -A && git -c user.name=t -c user.email=t@example.com commit -q -m drift )
    _run_scenario -y --repo "$repo" cross-os; rc=$?
    assert_exit_fail "$rc" "cross-os: ワークフローが雛形と違えば、失敗する"

    # --- clone できない → 実行できない（失敗にはするが、何も残さない）---
    _reset_xos
    MOCK_GH_CLONE_SRC="" _run_scenario -y --repo "$repo" cross-os; rc=$?
    assert_exit_fail "$rc" "cross-os: clone できなければ、実行できない"
    assert_file_contains "$MB/out.log" "実行できない" "cross-os: 「実行できない」と報告する"
    assert_equals "$(_xos_left)" "0" "cross-os: clone できなくても、一時フォルダは、残らない"

    # --- --repo のガード: 名前の形式・値の欠落・指定なし（作業フォルダもない）---
    _reset_xos
    _run_scenario -y --repo force-test-win cross-os; rc=$?
    assert_exit_fail "$rc" "--repo: テスト用の名前の形式でなければ、拒否する"
    assert_file_contains "$MB/out.log" "テスト用のリポジトリ名" "--repo: 拒否の理由（名前の形式）を表示する"
    assert_file_not_contains "$MOCK_CALL_LOG" "repo clone" "--repo: 拒否したら、clone しない"
    _run_scenario -y cross-os --repo; rc=$?
    assert_exit_fail "$rc" "--repo: 値がなければ、拒否する"
    _run_scenario -y --repo cross-os; rc=$?
    assert_file_contains "$MB/out.log" "シナリオ名を指定してください" "--repo: 次の語は、値として扱う（シナリオ名がなくなるため、何も実行しない）"
    assert_file_not_contains "$MOCK_CALL_LOG" "repo clone" "--repo: 何も実行しないときは、clone しない"
    _run_scenario -y cross-os; rc=$?
    assert_exit_fail "$rc" "--repo なし: 手元の作業フォルダがなければ、実行できない（macOS の CI では、--repo を指定する）"
    MOCK_GH_REPO_VIEW_EXIT=1 _run_scenario -y --repo "$repo" cross-os; rc=$?
    assert_exit_fail "$rc" "--repo: GitHub にないリポジトリは、実行できない"
    assert_file_not_contains "$MOCK_CALL_LOG" "repo clone" "--repo: GitHub にないときは、clone しない"

    # --- 開始の警告（読み取りのみ）---
    _reset_xos
    _run_scenario --repo "$repo" cross-os < <(printf 'N\n'); rc=$?
    assert_exit_fail "$rc" "cross-os: 開始の確認で N → 中止する"
    assert_file_contains "$MB/out.log" "読み取りのみ" "cross-os: 警告に、読み取りのみと表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "repo clone" "cross-os: N のとき、clone しない"
    unset E2E_SF_HOOK E2E_SF_SYNC_WF E2E_SF_HOOKS_DIR XOS_HOOKS_SRC SYNCWF_TPL MOCK_GH_CLONE_SRC E2E_CMD_POLL_SEC E2E_HEARTBEAT_SEC GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
    teardown "$CB"
}

test_e2e_names
test_e2e_guard
test_e2e_ci
test_e2e_delete_guards
test_e2e_fixture
test_e2e_cleanup_list
test_e2e_cleanup_delete
test_e2e_cleanup_confirm
test_e2e_sf_shim
test_e2e_alias_restore
test_e2e_input
test_e2e_run_guard
test_e2e_sfdx_url
test_e2e_admin_login_retry
test_e2e_tmp_cleanup
test_e2e_list_failure
test_e2e_local_guard
test_e2e_apex
test_e2e_gh_flow
test_e2e_sf_cmd
test_e2e_review_fixes
test_e2e_tiers
test_e2e_layout
test_e2e_identity_input
test_e2e_bootstrap_add_orgs
test_e2e_bootstrap_refresh_orgs
test_e2e_doctor
test_e2e_record_line
test_e2e_browser_shims
test_e2e_sequence_parts
test_e2e_scenario
test_e2e_scenario_manual_delete
test_e2e_scenario_validate_fail
test_e2e_scenario_dist_main
test_e2e_scenario_metasync_diff
test_e2e_interrupt
test_e2e_scenario_propagate_fail
test_e2e_scenario_restart_org
test_e2e_scenario_sync_wf
test_e2e_scenario_update_secret
test_e2e_scenario_cross_os

print_summary
