#!/bin/bash
# ==============================================================================
# e2e-test-lib.sh - tests/e2e/ のテスト（test_e2e.sh・test_e2e2.sh）の共通の部品
# ==============================================================================
# 2 つのテストファイルが source する。時間のかかる 1 ファイル（Windows の CI で約 8 分）を、2 つに分け、並列に動かすため、
# 共通の部品（モックの gh / sf の作成・鍵一式の作成・e2e/lib.sh の関数の呼び出し・cleanup.sh / scenario.sh の実行・
# シナリオ用の台本）を、ここに置いた。テストの本体は、各ファイルにある（どちらにあるかは、各ファイルの冒頭の一覧を参照）。
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"

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
# 24. シナリオ方式（scenario.sh）と、秘密情報の検査（e2e_scan_secrets）
# ------------------------------------------------------------------------------
_run_scenario() {  # 引数: scenario.sh への引数。標準入力はそのまま使う
    (
        cd "$HM" || exit 1
        export HOME="$HM" PATH="$MB:$PATH" E2E_FIXTURE="$FX" E2E_POLL_SEC=0
        bash "$E2E_DIR/scenario.sh" "$@"
    ) > "$MB/out.log" 2>&1
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
if grep -qx SLACK_BOT_TOKEN "$d/secrets.txt" 2>/dev/null; then echo "    ✓ SLACK_BOT_TOKEN"; else echo "    ✗ SLACK_BOT_TOKEN が、ありません → force-* の中で gh secret set SLACK_BOT_TOKEN"; rc=1; fi
if grep -q '^SLACK_CHANNEL_ID=' "$d/vars.txt" 2>/dev/null; then echo "    ✓ SLACK_CHANNEL_ID"; else echo "    ✗ SLACK_CHANNEL_ID が、ありません → force-* の中で gh variable set SLACK_CHANNEL_ID --body <チャンネル ID>"; rc=1; fi
[[ "${MOCK_STATUS_BLIND:-}" == "1" ]] && exit 0   # 不足を見つけられない診断の再現
exit $rc
EOF
    chmod +x "$MB/status-stub.sh"
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
