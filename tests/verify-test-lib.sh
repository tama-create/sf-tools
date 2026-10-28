#!/bin/bash
# ==============================================================================
# verify-test-lib.sh - phases/init/verify.sh のテスト（test_verify.sh・test_verify2.sh・test_verify3.sh）の共通の部品
# ==============================================================================
# 3 つのテストファイルが source する。時間のかかる 1 ファイル（Windows の CI で約 10 分）を、3 つに分け、並列に動かすため、
# 共通の準備（gh / git のモック・環境の設定 _env・実行 _run・呼び出し回数 _count）を、ここに置いた。
# 読み込むと、モックのフォルダ・作業フォルダが作られる。テストの終わりに、各ファイルが teardown する。
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== phases/init/verify.sh / lib/verify-common.sh ===${CLR_RST}"

MB=$(setup_mock_bin)
export MOCK_CALL_LOG="$MB/calls.log"

# gh のモック（状態つき。PR の番号・実行の ID は、呼び出しのたびに、増える）
#   MOCK_GH_BRANCHES / MOCK_GH_SECRETS / MOCK_GH_VARIABLES / MOCK_GH_WORKFLOWS : 一覧（改行区切り）
#   MOCK_GH_VAR_<名前>        : variable get の値
#   MOCK_GH_LOG_USERS         : 実行のログに出す接続ユーザー（スペース区切り）
#   MOCK_GH_CONCL             : 実行の結果（既定 success。failure で、検証の失敗を再現）
#   MOCK_GH_MERGE_EXIT        : pr merge の終了コード
cat > "$MB/gh" << 'GHEOF'
#!/bin/bash
echo "gh $*" >> "${MOCK_CALL_LOG:-/dev/null}"
_d="${MOCK_CALL_LOG%/*}"
_list() { local n; while IFS= read -r n; do [[ -n "$n" ]] && printf '%s\t2026-10-11T08:00:00Z\n' "$n"; done <<< "$1"; }
case "$*" in
    "repo view"*)            exit 0 ;;
    "api user"*)             echo "tamashimon"; exit 0 ;;
    "secret list"*)          _list "${MOCK_GH_SECRETS:-}"; exit 0 ;;
    "variable list"*)        _list "${MOCK_GH_VARIABLES:-}"; exit 0 ;;
    "variable get "*)
        _vn="MOCK_GH_VAR_$3"
        [[ -n "${!_vn:-}" ]] && { echo "${!_vn}"; exit 0; }
        exit 1 ;;
    "api repos/"*"/branches"*)                  printf '%s\n' "${MOCK_GH_BRANCHES:-main}"; exit 0 ;;
    "api repos/"*"/contents/.github/workflows"*) printf '%s\n' "${MOCK_GH_WORKFLOWS:-}"; exit 0 ;;
    "api repos/"*"/git/ref/heads/main"*)        echo "abc123def456"; exit 0 ;;
    "api repos/"*"/git/ref/heads/develop"*)     echo "dev123def456"; exit 0 ;;
    "api -X POST repos/"*)   exit "${MOCK_GH_API_WRITE_EXIT:-0}" ;;
    "api -X PUT repos/"*)    exit "${MOCK_GH_API_WRITE_EXIT:-0}" ;;
    "api -X DELETE repos/"*"/git/refs/heads/"*) exit "${MOCK_GH_BRANCH_DELETE_EXIT:-0}" ;;
    "api -X DELETE repos/"*) exit 0 ;;
    "api repos/"*"/contents/"*"?ref="*)
        # MOCK_GH_HELLO_ON=<段階>: その段階のブランチに、検証用と同名のクラスのファイルが、すでにある
        if [[ -n "${MOCK_GH_HELLO_ON:-}" && "$*" == *"/classes/"*"?ref=${MOCK_GH_HELLO_ON}"* ]]; then echo "sha-existing"; exit 0; fi
        # MOCK_GH_LABELS_EXIST=1: develop に、すでに labels のファイルがある（--components が、上書きしないことの確認）
        #   MOCK_GH_LABELS_EXIST=ours: そのファイルは、サンプルのラベルだけ（前回の検証の残り）
        if [[ -n "${MOCK_GH_LABELS_EXIST:-}" && "$*" == *"/labels/CustomLabels.labels-meta.xml?ref=develop"* ]]; then
            if [[ "$*" == *"@base64d"* ]]; then
                if [[ "$MOCK_GH_LABELS_EXIST" == "ours" ]]; then
                    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<CustomLabels xmlns="http://soap.sforce.com/2006/04/metadata">' \
                        '    <labels>' '        <fullName>SfToolsE2eHello</fullName>' '        <value>Hello, World!</value>' '    </labels>' '</CustomLabels>'
                else
                    printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<CustomLabels xmlns="http://soap.sforce.com/2006/04/metadata">' \
                        '    <labels>' '        <fullName>MyOwnLabel</fullName>' '        <value>x</value>' '    </labels>' \
                        '    <labels>' '        <fullName>SfToolsE2eHello</fullName>' '        <value>y</value>' '    </labels>' '</CustomLabels>'
                fi
                exit 0
            fi
            echo "sha-labels"; exit 0
        fi
        # 削除用のブランチ（verify-hello-delete-...）には、クラスのファイルが、ある（main から作られるため）。リリース用には、ない
        case "$*" in
            *"?ref=verify-hello-delete"*"/classes/"*|*"/classes/"*"?ref=verify-hello-delete"*) echo "sha-of-file"; exit 0 ;;
            # --components の削除用のブランチ（verify-comp-delete...）には、サンプルのファイルが、ある（develop から作られるため）
            *"?ref=verify-comp-delete"*) echo "sha-of-file"; exit 0 ;;
        esac
        exit 1 ;;
    "pr create"*)
        _n=$(( $(cat "$_d/pr.cnt" 2>/dev/null || echo 0) + 1 )); echo "$_n" > "$_d/pr.cnt"
        # 先の段階（--base の値）を覚える（ログインのステップの結果を、対象の段階だけ success にするため）
        _pa=("$@"); for ((_i = 0; _i < ${#_pa[@]}; _i++)); do [[ "${_pa[_i]}" == "--base" ]] && echo "${_pa[_i+1]}" > "$_d/last_base"; done
        echo "https://github.com/tamashimon/force-testproject/pull/${_n}"; exit 0 ;;
    "pr list"*"--state open"*) echo "${MOCK_GH_OPEN_PR_COUNT:-0}"; exit 0 ;;
    "pr merge"*)             exit "${MOCK_GH_MERGE_EXIT:-0}" ;;
    "pr close"*)             exit 0 ;;
    "workflow run"*)         exit "${MOCK_GH_WORKFLOW_EXIT:-0}" ;;
    "run list"*"--event workflow_dispatch"*)
        # 手動起動した実行の ID: 最初の問い合わせ（起動の前）は 100、以後は 101
        _n=$(( $(cat "$_d/disp.cnt" 2>/dev/null || echo 0) + 1 )); echo "$_n" > "$_d/disp.cnt"
        if [[ $_n -eq 1 ]]; then echo 100; else echo 101; fi
        exit 0 ;;
    "run list"*)
        # 実行の ID: PR を作った数（pr.cnt）が増えると、新しい ID になる（基準より新しい実行だけを、対象にする仕組みの確認）
        _c=$(cat "$_d/pr.cnt" 2>/dev/null || echo 0)
        case "$*" in
            *wf-validate*)  _k=1 ;;
            *wf-release*)   _k=2 ;;
            *wf-propagate*) _k=3 ;;
            *)              _k=4 ;;
        esac
        echo $(( 1000 + _c * 10 + _k )); exit 0 ;;
    "run view "*"--log-failed"*) echo "失敗したステップのログ ghp_fakesecret"; exit 0 ;;
    "run view "*"--json status"*)     echo "completed"; exit 0 ;;
    "run view "*"--json conclusion"*)
        # MOCK_GH_RELEASE_FAIL=1: wf-release の実行（ID の下 1 桁が 2）だけ、失敗させる
        if [[ "${MOCK_GH_RELEASE_FAIL:-}" == "1" && "${3: -1}" == "2" ]]; then echo "failure"
        elif [[ "${MOCK_GH_METASYNC_FAIL:-}" == "1" && "$3" == "101" ]]; then echo "failure"
        else echo "${MOCK_GH_CONCL:-success}"; fi
        exit 0 ;;
    "run view "*"--json jobs"*)
        # ログインのステップ: 対象の段階（直前の PR の先）だけ success。ほかの段階は skipped
        #   MOCK_GH_OTHER_LOGIN=success: ほかの段階も success（別の組織に入ったことの再現）
        #   MOCK_GH_OLD_STEPS=1: 古いステップ名（本番組織・ステージング組織・開発組織）のワークフローの再現
        _b=$(cat "$_d/last_base" 2>/dev/null)
        case "$*" in
            *"組織にログイン（JWT）"*)
                if [[ "${MOCK_GH_OLD_STEPS:-}" == "1" ]]; then
                    case "$*" in *"main の組織"*|*"staging の組織"*|*"develop の組織"*) exit 0 ;; esac   # 新しい名前は、ない
                    case "$_b" in main) _mine="本番組織" ;; staging) _mine="ステージング組織" ;; develop) _mine="開発組織" ;; esac
                    case "$*" in *"\"${_mine}にログイン"*) echo "success" ;; *) echo "${MOCK_GH_OTHER_LOGIN:-skipped}" ;; esac
                    exit 0
                fi
                case "$*" in *"\"${_b} の組織にログイン"*) echo "success" ;; *) echo "${MOCK_GH_OTHER_LOGIN:-skipped}" ;; esac
                exit 0 ;;
        esac
        echo "success"; exit 0 ;;
    "run view "*"--json attempt"*)    echo "1"; exit 0 ;;
    "run view "*"--log"*)
        for _u in ${MOCK_GH_LOG_USERS:-}; do echo "Successfully authorized ${_u} with org ID 00D000000000001"; done
        echo "Deployed Source: SfToolsE2eHello"
        echo "Deleted Source: SfToolsE2eHello__c"
        echo 'Slack response: {"ok":true}'
        exit 0 ;;
esac
exit 0
GHEOF
chmod +x "$MB/gh"

# git のモック（リモートの URL だけ）
cat > "$MB/git" << 'GITEOF'
#!/bin/bash
echo "git $*" >> "${MOCK_CALL_LOG:-/dev/null}"
case "$1 $2" in
    "remote get-url") echo "${MOCK_GIT_REMOTE_URL:-https://github.com/tamashimon/force-testproject.git}" ;;
esac
exit 0
GITEOF
chmod +x "$MB/git"

ALL_SECRETS=$'PAT_TOKEN\nSLACK_BOT_TOKEN\nSF_PRIVATE_KEY\nSF_CONSUMER_KEY_PROD\nSF_CONSUMER_KEY_STG\nSF_CONSUMER_KEY_DEV'
ALL_VARS=$'SLACK_CHANNEL_ID\nSF_TOOLS_BRANCH\nSF_USERNAME_PROD\nSF_INSTANCE_URL_PROD\nSF_ORG_ID_PROD\nSF_USERNAME_STG\nSF_INSTANCE_URL_STG\nSF_ORG_ID_STG\nSF_USERNAME_DEV\nSF_INSTANCE_URL_DEV\nSF_ORG_ID_DEV'
ALL_WF=$'wf-metasync.yml\nwf-propagate.yml\nwf-release.yml\nwf-sequence.yml\nwf-validate.yml'

FORCE=$(mktemp -d "${TMPDIR:-/tmp}/test-verify-XXXX")
mkdir -p "$FORCE/force-testproject"
FDIR="$FORCE/force-testproject"
HM=$(setup_mock_home)
OUT="$MB/out.log"

# 環境を整える（既定: 3 層・すべてそろっている・組織は Developer Edition）
_env() {
    export MOCK_GH_SECRETS="$ALL_SECRETS" MOCK_GH_VARIABLES="$ALL_VARS" MOCK_GH_WORKFLOWS="$ALL_WF" MOCK_GH_BRANCHES=$'main\nstaging\ndevelop'
    export MOCK_GH_VAR_SF_ORG_KIND_PROD=developer MOCK_GH_VAR_SF_ORG_KIND_STG=developer MOCK_GH_VAR_SF_ORG_KIND_DEV=developer
    export MOCK_GH_VAR_SF_USERNAME_PROD=prod@example.com MOCK_GH_VAR_SF_USERNAME_STG=stg@example.com MOCK_GH_VAR_SF_USERNAME_DEV=dev@example.com
    export MOCK_GH_VAR_SF_ORG_NAME_PROD=TAMA_PROD MOCK_GH_VAR_SF_ORG_NAME_STG=TAMA_STAGING MOCK_GH_VAR_SF_ORG_NAME_DEV=TAMA_DEVELOP
    export MOCK_GH_LOG_USERS="prod@example.com stg@example.com dev@example.com"
    export MOCK_GH_VAR_SF_TOOLS_BRANCH=development
    rm -f "$MB/disp.cnt" "$HM"/sf-tools/logs/*.log
    export VERIFY_POLL_SEC=0 VERIFY_RUN_FIND_TRIES=3 VERIFY_CONCLUSION_TRIES=1 VERIFY_WF_TIMEOUT=5
    unset MOCK_GH_LABELS_EXIST MOCK_GH_OPEN_PR_COUNT MOCK_GH_BRANCH_DELETE_EXIT MOCK_GH_CONCL MOCK_GH_MERGE_EXIT MOCK_GH_API_WRITE_EXIT MOCK_GH_RELEASE_FAIL MOCK_GH_METASYNC_FAIL MOCK_GH_WORKFLOW_EXIT SF_VERIFY_CONFIRMED MOCK_GH_OTHER_LOGIN MOCK_GH_OLD_STEPS MOCK_GH_HELLO_ON GITHUB_ACTIONS
    rm -f "$MB/pr.cnt"; : > "$MOCK_CALL_LOG"
}

# 実行する。引数: 標準入力（printf %b）、verify.sh の引数...。結果: $RC と $OUT
_run() {
    local input="$1"; shift
    printf '%b' "$input" | ( cd "$FDIR" && HOME="$HM" PATH="$MB:$PATH" bash "$SF_TOOLS_DIR/phases/init/verify.sh" "$@" ) > "$OUT" 2>&1
    RC=$?
}
_count() { grep -c "$1" "$MOCK_CALL_LOG"; }
