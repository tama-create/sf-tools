#!/bin/bash
# ==============================================================================
# test_verify.sh - phases/init/verify.sh（実際のリポジトリの検証）と lib/verify-common.sh のテスト
# ==============================================================================
#
# 【テストケース】
#   1.  --help                      : 表示できる
#   2.  実行できない場所             : GitHub Actions 上・force-* の外 → 中断する（何も変更しない）
#   3.  --plan                      : 診断と実行内容だけを表示する（何も変更しない）。本番の組織は、赤く表示する
#   4.  診断で不足がある             : 確認の前に中断する（何も変更しない）
#   5.  確認                        : N / q → 中断（何も変更しない）。本番があるときは、本番を含むことを明示する
#   6.  1 層（main のみ）            : リリースと削除（PR 2 本）→ 成功
#   7.  3 層                        : develop → staging → main の順に、リリース 3 本・削除 3 本 → 成功
#   8.  失敗                        : 検証が失敗 → マージしない・案内を表示・削除のみのやり直しを案内する
#   9.  取り違えの検出               : ログに、その段階の接続ユーザーが出ていない → 失敗する
#   10. --cleanup                   : 削除のみ（PR 3 本）
#   11. lib/verify-common.sh の部品     : Hello World の本文・基準の実行 ID より新しい実行だけを対象にする
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
    "api -X POST repos/"*)   exit "${MOCK_GH_API_WRITE_EXIT:-0}" ;;
    "api -X PUT repos/"*)    exit "${MOCK_GH_API_WRITE_EXIT:-0}" ;;
    "api -X DELETE repos/"*"/git/refs/heads/"*) exit "${MOCK_GH_BRANCH_DELETE_EXIT:-0}" ;;
    "api -X DELETE repos/"*) exit 0 ;;
    "api repos/"*"/contents/"*"?ref="*)
        # MOCK_GH_HELLO_ON=<段階>: その段階のブランチに、検証用と同名のクラスのファイルが、すでにある
        if [[ -n "${MOCK_GH_HELLO_ON:-}" && "$*" == *"/classes/"*"?ref=${MOCK_GH_HELLO_ON}"* ]]; then echo "sha-existing"; exit 0; fi
        # 削除用のブランチ（verify-hello-delete-...）には、クラスのファイルが、ある（main から作られるため）。リリース用には、ない
        case "$*" in
            *"?ref=verify-hello-delete"*"/classes/"*|*"/classes/"*"?ref=verify-hello-delete"*) echo "sha-of-file"; exit 0 ;;
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
    "remote get-url") echo "https://github.com/tamashimon/force-testproject.git" ;;
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
    unset MOCK_GH_OPEN_PR_COUNT MOCK_GH_BRANCH_DELETE_EXIT MOCK_GH_CONCL MOCK_GH_MERGE_EXIT MOCK_GH_API_WRITE_EXIT MOCK_GH_RELEASE_FAIL MOCK_GH_METASYNC_FAIL MOCK_GH_WORKFLOW_EXIT SF_VERIFY_CONFIRMED MOCK_GH_OTHER_LOGIN MOCK_GH_OLD_STEPS MOCK_GH_HELLO_ON GITHUB_ACTIONS
    rm -f "$MB/pr.cnt"; : > "$MOCK_CALL_LOG"
}

# 実行する。引数: 標準入力（printf %b）、verify.sh の引数...。結果: $RC と $OUT
_run() {
    local input="$1"; shift
    printf '%b' "$input" | ( cd "$FDIR" && HOME="$HM" PATH="$MB:$PATH" bash "$SF_TOOLS_DIR/phases/init/verify.sh" "$@" ) > "$OUT" 2>&1
    RC=$?
}
_count() { grep -c "$1" "$MOCK_CALL_LOG"; }

test_help() {
    echo ""; echo -e "${CLR_HEAD}[TEST] --help${CLR_RST}"
    bash "$SF_TOOLS_DIR/phases/init/verify.sh" --help > "$OUT" 2>&1
    assert_exit_ok $? "--help が表示できる"
    assert_file_contains "$OUT" "処理の流れ" "--help: 処理の流れが表示される"
    assert_file_contains "$OUT" "--cleanup" "--help: オプションが表示される"
}

test_guards() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 実行できない場所${CLR_RST}"
    _env
    printf 'x\n' | ( cd "$FDIR" && HOME="$HM" PATH="$MB:$PATH" GITHUB_ACTIONS=true bash "$SF_TOOLS_DIR/phases/init/verify.sh" ) > "$OUT" 2>&1
    assert_exit_fail $? "GitHub Actions 上では、中断する"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh pr create" "GitHub Actions 上: 何も作らない"
    printf 'x\n' | ( cd "$FORCE" && HOME="$HM" PATH="$MB:$PATH" bash "$SF_TOOLS_DIR/phases/init/verify.sh" ) > "$OUT" 2>&1
    assert_exit_fail $? "force-* の外では、中断する"
    assert_file_contains "$OUT" "'force-*' ディレクトリ内で実行してください" "force-* の外: 理由が表示される"
    _run "" --unknown
    assert_exit_fail "$RC" "不明なオプションは、中断する"
}

test_entry() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 入口: sf-init.sh --verify${CLR_RST}"
    _env
    local init="$SF_TOOLS_DIR/bin/sf-init.sh"
    # sf-init.sh は、起動時に sf の終了コードを確認する（check_sf_cli）。実機の sf を使わないよう、成功するモックを置く
    create_mock_sf "$MB"
    # --verify --plan: verify.sh に、オプションが渡る（診断と、実行内容の表示だけ。何も変更しない）
    ( cd "$FDIR" && HOME="$HM" PATH="$MB:$PATH" bash "$init" --verify --plan ) > "$OUT" 2>&1 < /dev/null
    assert_exit_ok $? "--verify --plan: 正常終了する"
    assert_file_contains "$OUT" "PR を 6 本" "--verify --plan: 実行内容が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr create" "--verify --plan: PR を作らない"
    # --verify なしの --plan / --cleanup / --no-metasync は、拒否する（sf-init の通常の実行に、混ぜない）
    local opt
    for opt in --plan --cleanup --no-metasync; do
        ( cd "$FDIR" && HOME="$HM" PATH="$MB:$PATH" bash "$init" "$opt" ) > "$OUT" 2>&1 < /dev/null
        assert_exit_fail $? "${opt} だけの指定は、拒否される"
        assert_file_contains "$OUT" "--verify と一緒に指定してください" "${opt} だけの指定: 理由が表示される"
    done
    # --verify の不明なオプションは、verify.sh が、拒否する
    ( cd "$FDIR" && HOME="$HM" PATH="$MB:$PATH" bash "$init" --verify --bogus ) > "$OUT" 2>&1 < /dev/null
    assert_exit_fail $? "--verify --bogus: 拒否される"
}

test_plan() {
    echo ""; echo -e "${CLR_HEAD}[TEST] --plan（何も変更しない）${CLR_RST}"
    _env
    _run "" --plan
    assert_exit_ok "$RC" "--plan: 正常終了する"
    assert_file_contains "$OUT" "セットアップに、不足はありません" "--plan: 診断が表示される"
    assert_file_contains "$OUT" "develop → TAMA_DEVELOP" "--plan: 段階ごとの組織の名前が表示される"
    assert_file_contains "$OUT" "Developer Edition" "--plan: 組織の種類が表示される"
    assert_file_contains "$OUT" "PR を 6 本" "--plan: PR の数が表示される（3 層: リリース 3・削除 3）"
    assert_file_not_contains "$OUT" "本番（または、種類を判定できない）組織" "--plan: Developer Edition だけなら、本番の表示は出ない"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr create" "--plan: PR を作らない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs" "--plan: ブランチを作らない"
    # 本番がある
    export MOCK_GH_VAR_SF_ORG_KIND_PROD=production
    _run "" --plan
    assert_file_contains "$OUT" "本番（または、種類を判定できない）組織" "--plan: 本番の組織は、表示される"
}

test_diag_ng() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 診断で不足がある → 確認の前に中断${CLR_RST}"
    _env
    export MOCK_GH_SECRETS=$'SLACK_BOT_TOKEN\nSF_PRIVATE_KEY\nSF_CONSUMER_KEY_PROD\nSF_CONSUMER_KEY_STG\nSF_CONSUMER_KEY_DEV'
    _run "Y\n"
    assert_exit_fail "$RC" "不足があれば、中断する"
    assert_file_contains "$OUT" "検証を始められません" "理由が表示される"
    assert_file_not_contains "$OUT" "確認のため、リポジトリ名" "確認の質問は、出ない"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr create" "何も作らない"
}

test_confirm() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 確認（Y/N）${CLR_RST}"
    _env
    _run "N\n"
    assert_exit_fail "$RC" "N で中断する"
    assert_file_contains "$OUT" "中断しました" "N: 中断したと表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs" "N: ブランチを作らない"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr create" "N: PR を作らない"
    _run "q\n"
    assert_exit_fail "$RC" "q で中断する"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs" "q: ブランチを作らない"
    _run ""
    assert_exit_fail "$RC" "入力がない（EOF）と、中断する（勝手に進めない）"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs" "EOF: ブランチを作らない"
    # 本番がある: 本番を含むことを明示した確認になる
    export MOCK_GH_VAR_SF_ORG_KIND_PROD=production
    _run "N\n"
    assert_exit_fail "$RC" "本番がある: N で中断する"
    assert_file_contains "$OUT" "に、Hello World を、リリースして、削除します" "本番がある: 本番に、リリースして、削除する旨が、表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs" "本番がある・N: ブランチを作らない"
    # 種類を判定できない組織も、本番と同じ扱い
    export MOCK_GH_VAR_SF_ORG_KIND_PROD=""
    _run "N\n"
    assert_file_contains "$OUT" "に、Hello World を、リリースして、削除します" "種類が分からない組織も、本番と同じ扱いで、明示される"
}

test_one_tier() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 1 層（main のみ）: リリースと削除${CLR_RST}"
    _env
    export MOCK_GH_BRANCHES="main"
    export MOCK_GH_SECRETS=$'PAT_TOKEN\nSLACK_BOT_TOKEN\nSF_PRIVATE_KEY\nSF_CONSUMER_KEY_PROD'
    export MOCK_GH_VARIABLES=$'SLACK_CHANNEL_ID\nSF_TOOLS_BRANCH\nSF_USERNAME_PROD\nSF_INSTANCE_URL_PROD\nSF_ORG_ID_PROD'
    _run "\n"   # Enter だけ（Y の入力も、不要）
    assert_exit_ok "$RC" "1 層: Enter だけで、正常終了する"
    assert_file_contains "$OUT" "検証: すべて成功しました" "1 層: 成功の表示"
    [[ "$(_count 'gh pr create')" -eq 2 ]] && pass "1 層: PR は 2 本（リリース・削除）" || fail "1 層: PR は 2 本" "$(_count 'gh pr create')"
    assert_file_contains "$MOCK_CALL_LOG" "pr create -R tamashimon/force-testproject --base main" "1 層: main 向けの PR"
    assert_file_contains "$MOCK_CALL_LOG" "api -X POST repos/tamashimon/force-testproject/git/refs" "1 層: ブランチを API で作る"
    assert_file_contains "$MOCK_CALL_LOG" "contents/force-app/main/default/classes/SfToolsE2eHello.cls" "1 層: クラスのファイルを追加する"
    assert_file_contains "$MOCK_CALL_LOG" "api -X DELETE repos/tamashimon/force-testproject/contents/force-app/main/default/classes/SfToolsE2eHello.cls" "1 層: 削除用のブランチで、クラスのファイルを消す"
    assert_file_contains "$MOCK_CALL_LOG" "pr merge" "1 層: PR をマージする"
    assert_file_not_contains "$MOCK_CALL_LOG" "--base develop" "1 層: develop 向けの PR は、作らない"
}

test_three_tiers() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 3 層: develop → staging → main の順${CLR_RST}"
    _env
    _run "Y\n"
    assert_exit_ok "$RC" "3 層: 正常終了する"
    [[ "$(_count 'gh pr create')" -eq 6 ]] && pass "3 層: PR は 6 本" || fail "3 層: PR は 6 本" "$(_count 'gh pr create')"
    # PR の作成の順（base）: develop, staging, main（リリース）→ develop, staging, main（削除）
    local order
    order=$(grep -o -- '--base [a-z]*' "$MOCK_CALL_LOG" | awk '{print $2}' | tr '\n' ',')
    assert_equals "$order" "develop,staging,main,develop,staging,main," "3 層: develop → staging → main の順に、リリースと削除をする"
    assert_file_contains "$OUT" "wf-propagate が成功した" "3 層: wf-propagate が確認される"
    assert_file_contains "$OUT" "dev@example.com" "3 層: develop の接続ユーザーが確認される"
}

test_failure() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 失敗 → マージしない・案内を表示する${CLR_RST}"
    _env
    export MOCK_GH_CONCL=failure
    _run "Y\n" --no-metasync   # すべての実行が失敗する設定のため、wf-metasync は省略（wf-validate の失敗を、確認する）
    assert_exit_fail "$RC" "検証が失敗すれば、非ゼロで終了する"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh pr merge" "wf-validate が失敗: マージしない"
    assert_file_contains "$OUT" "検証を、途中で止めました" "案内が表示される"
    assert_file_not_contains "$OUT" "ghp_fakesecret" "失敗のログの Token は、伏せ字になる"
    # マージの拒否（ブランチ保護など）
    _env
    export MOCK_GH_MERGE_EXIT=1
    _run "Y\n"
    assert_exit_fail "$RC" "マージが拒否されれば、中断する"
    assert_file_contains "$OUT" "PR をマージした" "マージの失敗が表示される"
    # リリースをマージしたあとで、wf-release が失敗 → 組織に残った可能性と、削除のやり直しを案内する
    _env
    export MOCK_GH_RELEASE_FAIL=1
    _run "\n"   # Enter だけ
    assert_exit_fail "$RC" "wf-release が失敗すれば、中断する"
    assert_file_contains "$OUT" "残っている可能性があります: develop" "リリースをマージした段階が、残っている可能性として表示される"
    assert_file_contains "$OUT" "sf-init.sh --verify --cleanup" "削除のみのやり直しが、案内される"
}

test_identity_mismatch() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 取り違えの検出（ログに、その段階の接続ユーザーが出ていない）${CLR_RST}"
    _env
    export MOCK_GH_LOG_USERS="prod@example.com stg@example.com"   # develop のユーザーが、出ていない
    _run "Y\n"
    assert_exit_fail "$RC" "接続ユーザーが出ていなければ、失敗する"
    assert_file_contains "$OUT" "[NG] リリース（develop）: ログインしたユーザーが、develop の接続ユーザー（dev@example.com）と一致する" "失敗した確認が、表示される"
    # 失敗しても、削除まで進める（組織を、元に戻す）
    [[ "$(_count 'gh pr create')" -eq 6 ]] && pass "確認が失敗しても、削除まで進める（PR は 6 本）" || fail "確認が失敗しても、削除まで進める" "$(_count 'gh pr create')"
}

test_review_fixes() {
    echo ""; echo -e "${CLR_HEAD}[TEST] レビューの指摘への対応（別の組織の取り違え・ユーザー未登録・古いステップ名・同名のファイル）${CLR_RST}"
    # 別の段階のログインのステップが、実行されていた（別の組織に入った）→ 失敗
    _env
    export MOCK_GH_OTHER_LOGIN=success
    _run "\n"
    assert_exit_fail "$RC" "別の段階のログインが、実行されていれば、失敗する"
    assert_file_contains "$OUT" "[NG] リリース（develop）: staging の組織へのログインは、実行されていない" "別の組織に入ったことが、NG として表示される"
    # 正常: ほかの段階のログインは skipped（確認が表示される）
    _env
    _run "\n"
    assert_exit_ok "$RC" "正常: 3 層が成功する"
    assert_file_contains "$OUT" "[OK] リリース（main）: develop の組織へのログインは、実行されていない" "ほかの段階のログインが skipped であることを確認する"
    # SF_USERNAME_* が空（未登録）→ 失敗（ユーザーの照合を、黙ってスキップしない）
    _env
    export MOCK_GH_VAR_SF_USERNAME_DEV=""
    _run "\n"
    assert_exit_fail "$RC" "接続ユーザーが空なら、失敗する"
    assert_file_contains "$OUT" "[NG] リリース（develop）: develop の接続ユーザー（SF_USERNAME_DEV）が、登録されている" "未登録が、NG として表示される"
    # 古いステップ名（本番組織・ステージング組織・開発組織）のワークフロー → 正しく確認できる
    _env
    export MOCK_GH_OLD_STEPS=1
    _run "\n"
    assert_exit_ok "$RC" "古いステップ名のワークフローでも、確認できる"
    assert_file_contains "$OUT" "[OK] リリース（staging）: staging の組織への JWT ログインが成功した" "古い名前（ステージング組織）を、読める"
    # 検証用と同名のクラスのファイルが、すでにある → 実行しない（何も作らない）
    _env
    export MOCK_GH_HELLO_ON=staging
    _run "\n"
    assert_exit_fail "$RC" "同名のファイルが、すでにあれば、実行しない"
    assert_file_contains "$OUT" "検証用と同じ名前のファイルが、すでにあります" "理由が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs" "同名のファイルがある: ブランチを作らない"
    assert_file_not_contains "$MOCK_CALL_LOG" "pr create" "同名のファイルがある: PR を作らない"
    # --cleanup は、前回の残りの後始末のため、同名のファイルがあっても、実行できる
    _run "\n" --cleanup
    assert_exit_ok "$RC" "--cleanup は、同名のファイルがあっても、実行できる"
}

test_environment() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 環境の確認（リリースの前。NG があれば、リリースへ進まない）${CLR_RST}"
    # 正常: wf-metasync を実行して、成功する
    _env
    _run "\n" --plan
    assert_file_contains "$OUT" "最初の確認 : 環境全体（SF_TOOLS_BRANCH・ログに Token が残っていないこと・wf-metasync の実行）" "--plan: 最初の確認の内容が表示される"
    assert_file_contains "$OUT" "wf-metasync は、Salesforce（main の組織）の変更を、main に同期します" "--plan: wf-metasync の影響が表示される"
    _env
    _run "\n"
    assert_exit_ok "$RC" "環境の確認とリリースが、成功する"
    assert_file_contains "$OUT" "環境（wf-metasync）: 成功した" "wf-metasync の成功が確認される"
    assert_file_contains "$OUT" "環境（wf-metasync）: sf-tools の取得が成功した" "wf-metasync の中の sf-tools の取得が確認される"
    assert_file_contains "$MOCK_CALL_LOG" "workflow run wf-metasync.yml" "wf-metasync が手動で起動される"
    # wf-metasync は、リリースの前に実行される（先に、PR を作らない）
    local first_dispatch first_pr
    first_dispatch=$(grep -n "workflow run wf-metasync" "$MOCK_CALL_LOG" | head -1 | cut -d: -f1)
    first_pr=$(grep -n "gh pr create" "$MOCK_CALL_LOG" | head -1 | cut -d: -f1)
    [[ -n "$first_dispatch" && -n "$first_pr" && "$first_dispatch" -lt "$first_pr" ]] \
        && pass "wf-metasync は、リリースの PR より前に実行される" || fail "wf-metasync は、リリースの PR より前に実行される" "dispatch=$first_dispatch pr=$first_pr"

    # SF_TOOLS_BRANCH が、不正 → リリースへ進まない
    _env
    export MOCK_GH_VAR_SF_TOOLS_BRANCH=feature-x
    _run "\n"
    assert_exit_fail "$RC" "SF_TOOLS_BRANCH が不正なら、中断する"
    assert_file_contains "$OUT" "これ以上は、進みません" "先に進まないことが表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh pr create" "環境の NG: PR を作らない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git/refs" "環境の NG: ブランチを作らない"
    assert_file_not_contains "$MOCK_CALL_LOG" "workflow run" "環境の NG（SF_TOOLS_BRANCH）: wf-metasync も、起動しない（組織に、何も変更しない）"

    # ログに、Token が残っている → リリースへ進まない
    _env
    mkdir -p "$HM/sf-tools/logs"
    printf 'token=ghp_%s\n' "abcdefghijklmnopqrstuvwxyz0123456789" > "$HM/sf-tools/logs/old.log"
    _run "\n"
    assert_exit_fail "$RC" "ログに Token が残っていれば、中断する"
    assert_file_contains "$OUT" "Token（または認証 URL）らしい文字列が、ログに残っています" "どのログかが表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh pr create" "ログに Token: PR を作らない"
    assert_file_not_contains "$MOCK_CALL_LOG" "workflow run" "ログに Token: wf-metasync も、起動しない（組織に、何も変更しない）"
    rm -f "$HM/sf-tools/logs/old.log"

    # wf-metasync が、失敗 → リリースへ進まない
    _env
    export MOCK_GH_METASYNC_FAIL=1
    _run "\n"
    assert_exit_fail "$RC" "wf-metasync が失敗すれば、中断する"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh pr create" "wf-metasync の失敗: PR を作らない"

    # --no-metasync: wf-metasync を実行しない
    _env
    _run "\n" --no-metasync
    assert_exit_ok "$RC" "--no-metasync: 成功する"
    assert_file_not_contains "$MOCK_CALL_LOG" "workflow run" "--no-metasync: wf-metasync を起動しない"

    # --cleanup: 環境の確認は、行わない（後始末のため）
    _env
    export MOCK_GH_VAR_SF_TOOLS_BRANCH=feature-x
    _run "\n" --cleanup
    assert_exit_ok "$RC" "--cleanup: 環境の確認の NG に、影響されない"
    assert_file_not_contains "$MOCK_CALL_LOG" "workflow run" "--cleanup: wf-metasync を起動しない"

    # sf-init から呼ばれたとき（SF_VERIFY_CONFIRMED=1）: 確認を、二重には聞かない（標準入力が空でも、進む）
    _env
    export SF_VERIFY_CONFIRMED=1
    _run ""
    assert_exit_ok "$RC" "SF_VERIFY_CONFIRMED=1: 確認なしで進む"
    assert_file_not_contains "$OUT" "Enter で、" "SF_VERIFY_CONFIRMED=1: 確認の質問を出さない"
}

test_cleanup() {
    echo ""; echo -e "${CLR_HEAD}[TEST] --cleanup（削除のみ）${CLR_RST}"
    _env
    _run "Y\n" --cleanup
    assert_exit_ok "$RC" "--cleanup: 正常終了する"
    [[ "$(_count 'gh pr create')" -eq 3 ]] && pass "--cleanup: PR は 3 本（削除のみ）" || fail "--cleanup: PR は 3 本" "$(_count 'gh pr create')"
    assert_file_contains "$OUT" "削除のみ" "--cleanup: 内容が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "api -X PUT repos/tamashimon/force-testproject/contents/force-app" "--cleanup: クラスのファイルを追加しない"
    assert_file_contains "$MOCK_CALL_LOG" "api -X DELETE repos/tamashimon/force-testproject/contents/force-app/main/default/classes/SfToolsE2eHello.cls" "--cleanup: リポジトリのクラスのファイルを消す"
}

test_branch_cleanup() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 後始末: 今回作った作業用ブランチを削除する${CLR_RST}"
    local del='api -X DELETE repos/tamashimon/force-testproject/git/refs/heads/verify-hello'

    # 正常: リリース用・削除用の 2 本のブランチを、削除する（PR の履歴は、PR の番号で残る）
    _env
    _run "Y\n"
    assert_exit_ok "$RC" "正常: 正常終了する"
    assert_equals "$(grep -c "${del}-[0-9]" "$MOCK_CALL_LOG")" "1" "正常: リリース用ブランチ（verify-hello-HHMMSS）を削除する"
    assert_equals "$(grep -c "${del}-delete-[0-9]" "$MOCK_CALL_LOG")" "1" "正常: 削除用ブランチ（verify-hello-delete-HHMMSS）を削除する"
    assert_file_contains "$OUT" "作業用ブランチを削除しました" "正常: 削除した旨が表示される"
    assert_file_contains "$OUT" "PR の履歴は、PR の番号で残っています" "正常: PR の履歴が残る旨が表示される"
    # 削除は、すべての PR の処理が終わったあと（最後の PR の作成より後）
    local last_pr first_del
    last_pr=$(grep -n 'gh pr create' "$MOCK_CALL_LOG" | tail -1 | cut -d: -f1)
    first_del=$(grep -n "${del}" "$MOCK_CALL_LOG" | head -1 | cut -d: -f1)
    assert_equals "$([[ -n "$last_pr" && -n "$first_del" && "$first_del" -gt "$last_pr" ]] && echo yes || echo no)" "yes" "正常: 削除は、すべての PR の後"

    # 開いている PR があるブランチは、削除しない（警告のみ。検証の成否には、含めない）
    _env
    export MOCK_GH_OPEN_PR_COUNT=1
    _run "Y\n"
    assert_exit_ok "$RC" "開いている PR あり: 検証は、成功のまま"
    assert_file_not_contains "$MOCK_CALL_LOG" "${del}" "開いている PR あり: ブランチを削除しない"
    assert_file_contains "$OUT" "開いている PR がある" "開いている PR あり: 理由が表示される"

    # 削除に失敗しても、検証は、成功のまま（警告のみ。手動の削除方法を案内する）
    _env
    export MOCK_GH_BRANCH_DELETE_EXIT=1
    _run "Y\n"
    assert_exit_ok "$RC" "削除に失敗: 検証は、成功のまま"
    assert_file_contains "$OUT" "削除できませんでした" "削除に失敗: 警告が表示される"
    assert_file_contains "$OUT" "gh api -X DELETE repos/tamashimon/force-testproject/git/refs/heads/verify-hello-" "削除に失敗: 手動の削除方法が案内される"

    # 途中で止めたときは、調査のために、ブランチを残す
    _env
    export MOCK_GH_MERGE_EXIT=1
    _run "Y\n"
    assert_exit_fail "$RC" "途中で止まった: 非ゼロで終了する"
    assert_file_not_contains "$MOCK_CALL_LOG" "${del}" "途中で止まった: ブランチを削除しない（調査のために残す）"

    # --cleanup: 削除用ブランチだけ（リリース用は、作っていない）
    _env
    _run "Y\n" --cleanup
    assert_exit_ok "$RC" "--cleanup: 正常終了する"
    assert_equals "$(grep -c "${del}-delete-[0-9]" "$MOCK_CALL_LOG")" "1" "--cleanup: 削除用ブランチを削除する"
    assert_equals "$(grep -c "${del}-[0-9]" "$MOCK_CALL_LOG")" "0" "--cleanup: リリース用ブランチは、対象にしない（作っていない）"

    # 部品: 名前の形式の確認は、verify.sh 側（想定外の名前は、削除しない）
    _env
    unset MOCK_GH_OPEN_PR_COUNT MOCK_GH_BRANCH_DELETE_EXIT
}

test_lib() {
    echo ""; echo -e "${CLR_HEAD}[TEST] lib/verify-common.sh の部品${CLR_RST}"
    _env
    local out
    out=$( (
        export SF_INIT_MODE=1 PATH="$MB:$PATH"
        readonly SCRIPT_NAME=test LOG_FILE=/dev/null LOG_MODE=NEW
        source "$SF_TOOLS_DIR/lib/common.sh"
        source "$SF_TOOLS_DIR/lib/verify-common.sh"
        echo "PATHS=$(verify_hello_paths | wc -l | tr -d " ")"
        echo "DEPLOY=$(verify_hello_deploy_target_text | grep -c SfToolsE2eHello)"
        echo "REMOVE=$(verify_hello_remove_target_text | grep -c '^ApexClass:')"
        verify_hello_content_for "force-app/main/default/classes/SfToolsE2eHelloTest.cls" | grep -q "@isTest" && echo "TESTCLS=ok"
        verify_hello_content_for "force-app/main/default/classes/SfToolsE2eHello.cls" | grep -q "Hello, World" && echo "CLS=ok"
        echo "ID=$(verify_latest_run_id tamashimon/force-testproject wf-validate.yml br)"
        # 基準と同じ ID の実行は、対象にしない
        VERIFY_RUN_FIND_TRIES=2 verify_wait_pr_run tamashimon/force-testproject wf-validate.yml br 1001 >/dev/null && echo "WAIT_SAME=found" || echo "WAIT_SAME=none"
        VERIFY_RUN_FIND_TRIES=2 verify_wait_pr_run tamashimon/force-testproject wf-validate.yml br 1000 >/dev/null && echo "WAIT_NEW=found" || echo "WAIT_NEW=none"
    ) 2>&1 )
    assert_output_contains "$out" "PATHS=4"        "クラスのファイルは 4 つ"
    assert_output_contains "$out" "DEPLOY=2"       "リリース対象に、クラスが 2 つ"
    assert_output_contains "$out" "REMOVE=2"       "削除対象に、クラスが 2 つ"
    assert_output_contains "$out" "TESTCLS=ok"     "テストクラスに @isTest がある"
    assert_output_contains "$out" "CLS=ok"         "Hello World のクラスの本文"
    assert_output_contains "$out" "ID=1001"        "最新の実行 ID を返す"
    assert_output_contains "$out" "WAIT_SAME=none" "基準と同じ ID の実行は、対象にしない"
    assert_output_contains "$out" "WAIT_NEW=found" "基準より新しい実行を、対象にする"
}

test_help
test_guards
test_entry
test_plan
test_diag_ng
test_confirm
test_one_tier
test_three_tiers
test_failure
test_identity_mismatch
test_review_fixes
test_environment
test_cleanup
test_branch_cleanup
test_lib

teardown "$MB" "$FORCE" "$HM"
print_summary
