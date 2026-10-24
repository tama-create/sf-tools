#!/bin/bash
# ==============================================================================
# test_diag.sh - lib/diag.sh（セットアップの診断）のテスト
# ==============================================================================
#
# 【テストケース】
#   1. すべてそろっている         : 3 段階・不足 0 件（DIAG_NG=0）
#   2. 不足がある                 : ブランチ・ワークフロー・Secrets・Variables の不足を ✗ と直し方で表示（件数が合う）
#   3. 一覧を取得できない         : ？ と表示し、不足に数えない（通信エラー・権限不足を、不足と誤認しない）
#   4. 段階の数に応じた確認       : main のみ → STG / DEV は確認しない
#   5. 組織の種類の記録がない     : ！ 注意（不足に数えない）
#   6. 直近のワークフローの実行   : 成功 ✓ / 失敗 ！ / 実行なし ？
#   7. 読み取りのみ               : 変更系のコマンド（set / create / delete）を呼ばない
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== lib/diag.sh ===${CLR_RST}"

MB=$(setup_mock_bin)
export MOCK_CALL_LOG="$MB/calls.log"

# gh のモック（環境変数で、一覧の内容と、失敗を制御する）
#   MOCK_GH_SECRETS / MOCK_GH_VARIABLES : 一覧（改行区切りの名前。実際の gh と同じく、名前の後ろに TAB と更新日時が付く）
#   MOCK_GH_BRANCHES / MOCK_GH_WORKFLOWS : 一覧（改行区切り）
#   MOCK_GH_RUN_OUT : 直近の実行（"completed success 2026-10-11T08:00:00Z" / "none" など）
#   MOCK_GH_FAIL    : 失敗させる種類（secret / variable / branches / workflows / run のスペース区切り）
cat > "$MB/gh" << 'GHEOF'
#!/bin/bash
echo "gh $*" >> "${MOCK_CALL_LOG:-/dev/null}"
_fail() { [[ " ${MOCK_GH_FAIL:-} " == *" $1 "* ]]; }
_list() { local n; while IFS= read -r n; do [[ -n "$n" ]] && printf '%s\t2026-10-11T08:00:00Z\n' "$n"; done <<< "$1"; }
case "$1 $2" in
    "secret list")   _fail secret && exit 1;   _list "${MOCK_GH_SECRETS:-}"; exit 0 ;;
    "variable list") _fail variable && exit 1; _list "${MOCK_GH_VARIABLES:-}"; exit 0 ;;
    "repo view")     exit "${MOCK_GH_REPO_VIEW_EXIT:-0}" ;;
    "run list")      _fail run && exit 1; printf '%s\n' "${MOCK_GH_RUN_OUT:-completed success 2026-10-11T08:00:00Z}"; exit 0 ;;
    "api repos/"*)
        case "$2" in
            */rulesets)  _fail rulesets && exit 1; printf '%s\n' "${MOCK_GH_RULESETS_LIST:-}"; exit 0 ;;
            */rulesets/*) printf '%s\n' "${MOCK_GH_RULESET_CHECKS:-}"; exit 0 ;;
            */branches)  _fail branches && exit 1; printf '%s\n' "${MOCK_GH_BRANCHES:-}"; exit 0 ;;
            */contents/.github/workflows) _fail workflows && exit 1; printf '%s\n' "${MOCK_GH_WORKFLOWS:-}"; exit 0 ;;
        esac
        exit 0 ;;
esac
exit 0
GHEOF
chmod +x "$MB/gh"

ALL_SECRETS=$'PAT_TOKEN\nSLACK_BOT_TOKEN\nSF_PRIVATE_KEY\nSF_CONSUMER_KEY_PROD\nSF_CONSUMER_KEY_STG\nSF_CONSUMER_KEY_DEV'
ALL_VARS=$'SLACK_CHANNEL_ID\nSF_TOOLS_BRANCH\nSF_USERNAME_PROD\nSF_INSTANCE_URL_PROD\nSF_ORG_ID_PROD\nSF_USERNAME_STG\nSF_INSTANCE_URL_STG\nSF_ORG_ID_STG\nSF_USERNAME_DEV\nSF_INSTANCE_URL_DEV\nSF_ORG_ID_DEV'
ALL_WF=$'wf-metasync.yml\nwf-propagate.yml\nwf-release.yml\nwf-sequence.yml\nwf-validate.yml'
ALL_BRANCHES=$'main\nstaging\ndevelop'

# 診断を、子プロセスで実行する。標準エラー（表示）を $OUT に、DIAG_NG を $NG に入れる
#   引数: 段階（ブランチ名）...
_d() {
    OUT=$(mktemp "${TMPDIR:-/tmp}/test-sfdiag-XXXX")
    NG=$(
        export SF_INIT_MODE=1 PATH="$MB:$PATH"
        readonly SCRIPT_NAME=test
        readonly LOG_FILE=/dev/null
        readonly LOG_MODE=NEW
        source "${SF_TOOLS_DIR}/lib/common.sh"
        source "${SF_TOOLS_DIR}/lib/diag.sh"
        diag_run "owner/force-x" "$@" 2> "$OUT"
        echo "$DIAG_NG"
    )
}
_dc() { rm -f "$OUT"; }

_all_ok_env() {
    export MOCK_GH_SECRETS="$ALL_SECRETS" MOCK_GH_VARIABLES="$ALL_VARS" MOCK_GH_WORKFLOWS="$ALL_WF" MOCK_GH_BRANCHES="$ALL_BRANCHES"
    unset MOCK_GH_FAIL MOCK_GH_RUN_OUT MOCK_GH_REPO_VIEW_EXIT
}

test_all_ok() {
    echo ""; echo -e "${CLR_HEAD}[TEST] すべてそろっている（3 段階）→ 不足 0 件${CLR_RST}"
    _all_ok_env
    : > "$MOCK_CALL_LOG"
    _d main staging develop
    assert_equals "$NG" "0"                                                       "不足は 0 件"
    assert_file_contains "$OUT" "セットアップに、不足はありません"                   "不足なしの案内が表示される"
    assert_file_contains "$OUT" "ブランチ develop があります"                        "各段階のブランチが確認される"
    assert_file_contains "$OUT" "SF_CONSUMER_KEY_STG"                              "段階ごとの Secret が確認される"
    assert_file_contains "$OUT" "SF_INSTANCE_URL_DEV"                              "段階ごとの Variable が確認される"
    assert_file_contains "$OUT" "wf-sequence.yml があります"                        "ワークフロー 5 本が確認される"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh secret set"                      "変更系のコマンド（secret set）を呼ばない"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh variable set"                    "変更系のコマンド（variable set）を呼ばない"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo create"                     "変更系のコマンド（repo create）を呼ばない"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh repo delete"                     "変更系のコマンド（repo delete）を呼ばない"
    assert_file_not_contains "$MOCK_CALL_LOG" "--method"                           "変更系の API 呼び出し（--method）をしない"
    _dc
}

test_missing() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 不足がある → ✗ と直し方・件数${CLR_RST}"
    _all_ok_env
    # PAT_TOKEN・SF_CONSUMER_KEY_STG・SLACK_CHANNEL_ID・SF_USERNAME_DEV・ブランチ develop・wf-release.yml が、ない（6 件）
    export MOCK_GH_SECRETS=$'SLACK_BOT_TOKEN\nSF_PRIVATE_KEY\nSF_CONSUMER_KEY_PROD\nSF_CONSUMER_KEY_DEV'
    export MOCK_GH_VARIABLES=$'SF_TOOLS_BRANCH\nSF_USERNAME_PROD\nSF_INSTANCE_URL_PROD\nSF_ORG_ID_PROD\nSF_USERNAME_STG\nSF_INSTANCE_URL_STG\nSF_ORG_ID_STG\nSF_INSTANCE_URL_DEV\nSF_ORG_ID_DEV'
    export MOCK_GH_BRANCHES=$'main\nstaging'
    export MOCK_GH_WORKFLOWS=$'wf-metasync.yml\nwf-propagate.yml\nwf-sequence.yml\nwf-validate.yml'
    _d main staging develop
    assert_equals "$NG" "6"                                                        "不足は 6 件"
    assert_file_contains "$OUT" "PAT_TOKEN がありません"                             "Secret の不足が表示される"
    assert_file_contains "$OUT" "gh secret set PAT_TOKEN"                           "PAT_TOKEN の直し方（gh secret set）が表示される"
    assert_file_contains "$OUT" "SF_CONSUMER_KEY_STG がありません"                    "段階ごとの Secret の不足が表示される"
    assert_file_contains "$OUT" "sf-init.sh --reconnect staging"                    "段階の接続の直し方（--reconnect）が表示される"
    assert_file_contains "$OUT" "SLACK_CHANNEL_ID がありません"                       "Variable の不足が表示される"
    assert_file_contains "$OUT" "SF_USERNAME_DEV がありません"                        "段階ごとの Variable の不足が表示される"
    assert_file_contains "$OUT" "ブランチ develop がありません"                       "ブランチの不足が表示される"
    assert_file_contains "$OUT" "sf-init.sh --add-tier develop"                     "ブランチの直し方（--add-tier）が表示される"
    assert_file_contains "$OUT" "ワークフロー wf-release.yml がありません"            "ワークフローの不足が表示される"
    assert_file_contains "$OUT" "sf-sync-wf.sh"                                     "ワークフローの直し方（sf-sync-wf.sh）が表示される"
    assert_file_contains "$OUT" "不足が 6 件あります"                                 "不足の件数が表示される"
    _dc
}

test_unknown() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 一覧を取得できない → ？（不足に数えない）${CLR_RST}"
    _all_ok_env
    export MOCK_GH_FAIL="secret variable branches workflows run"
    _d main staging develop
    assert_equals "$NG" "0"                                                        "取得できないものは、不足に数えない"
    assert_file_contains "$OUT" "Secrets の一覧を、確認できませんでした"              "Secrets: 確認できなかったと表示される"
    assert_file_contains "$OUT" "Variables の一覧を、確認できませんでした"            "Variables: 確認できなかったと表示される"
    assert_file_contains "$OUT" "ブランチの一覧を、確認できませんでした"              "ブランチ: 確認できなかったと表示される"
    assert_file_contains "$OUT" "ワークフローの一覧を、確認できませんでした"          "ワークフロー: 確認できなかったと表示される"
    assert_file_contains "$OUT" "直近の実行を、確認できませんでした"                  "実行結果: 確認できなかったと表示される"
    assert_file_not_contains "$OUT" "がありません"                                    "取得できないのに、「ない」とは言わない"
    _dc
    unset MOCK_GH_FAIL
}

test_tier_count() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 段階の数に応じた確認（main のみ）${CLR_RST}"
    _all_ok_env
    export MOCK_GH_SECRETS=$'PAT_TOKEN\nSLACK_BOT_TOKEN\nSF_PRIVATE_KEY\nSF_CONSUMER_KEY_PROD'
    export MOCK_GH_VARIABLES=$'SLACK_CHANNEL_ID\nSF_TOOLS_BRANCH\nSF_USERNAME_PROD\nSF_INSTANCE_URL_PROD\nSF_ORG_ID_PROD'
    export MOCK_GH_BRANCHES="main"
    _d main
    assert_equals "$NG" "0"                                                        "main のみ: STG / DEV が、なくても、不足は 0 件"
    assert_file_not_contains "$OUT" "SF_CONSUMER_KEY_STG"                           "main のみ: STG の Secret は、確認しない"
    assert_file_not_contains "$OUT" "ブランチ staging"                               "main のみ: staging のブランチは、確認しない"
    _dc
}

# SF_TOOLS_BRANCH は、検証環境（開発版）だけが登録する任意の Variable（未設定なら、ワークフローは main を使う）。
#   なくても、不足にしない。結合テスト X3-9 で見つかった: 配布版のプロジェクトで、--status が、必ず「不足」と表示した
test_tools_branch_optional() {
    echo ""; echo -e "${CLR_HEAD}[TEST] SF_TOOLS_BRANCH（任意）がなくても、不足にしない${CLR_RST}"
    _all_ok_env
    export MOCK_GH_SECRETS=$'PAT_TOKEN\nSLACK_BOT_TOKEN\nSF_PRIVATE_KEY\nSF_CONSUMER_KEY_PROD'
    export MOCK_GH_VARIABLES=$'SLACK_CHANNEL_ID\nSF_USERNAME_PROD\nSF_INSTANCE_URL_PROD\nSF_ORG_ID_PROD'   # SF_TOOLS_BRANCH なし（配布版）
    export MOCK_GH_BRANCHES="main"
    _d main
    assert_equals "$NG" "0"                                                        "SF_TOOLS_BRANCH がなくても、不足は 0 件（配布版は、登録しない）"
    assert_file_not_contains "$OUT" "SF_TOOLS_BRANCH"                              "SF_TOOLS_BRANCH は、不足として、表示しない"
    _dc
}

test_org_record() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 組織の種類の記録（SF_ORG_ID_*）がない → ！（不足に数えない）${CLR_RST}"
    _all_ok_env
    export MOCK_GH_VARIABLES=$'SLACK_CHANNEL_ID\nSF_TOOLS_BRANCH\nSF_USERNAME_PROD\nSF_INSTANCE_URL_PROD'
    export MOCK_GH_SECRETS=$'PAT_TOKEN\nSLACK_BOT_TOKEN\nSF_PRIVATE_KEY\nSF_CONSUMER_KEY_PROD'
    export MOCK_GH_BRANCHES="main"
    _d main
    assert_equals "$NG" "0"                                                        "記録がなくても、不足は 0 件"
    assert_file_contains "$OUT" "SF_ORG_ID_PROD がありません（組織の種類が、記録されていません）"  "注意として表示される"
    _dc
}

test_runs() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 直近のワークフローの実行${CLR_RST}"
    _all_ok_env
    export MOCK_GH_RUN_OUT="completed success 2026-10-11T08:39:33Z"
    _d main staging develop
    assert_file_contains "$OUT" "wf-release.yml: 直近の実行は、成功です（2026-10-11 08:39 UTC）"  "成功: ✓ と日時が表示される"
    _dc
    export MOCK_GH_RUN_OUT="completed failure 2026-10-11T08:39:33Z"
    _d main staging develop
    assert_file_contains "$OUT" "wf-metasync.yml: 直近の実行は、成功していません（failure"        "失敗: ！ で表示される"
    assert_equals "$NG" "0"                                                                  "失敗は、セットアップの不足に数えない"
    _dc
    export MOCK_GH_RUN_OUT="none"
    _d main staging develop
    assert_file_contains "$OUT" "wf-validate.yml: まだ、実行されていません"                     "実行なし: ？ で表示される"
    _dc
    export MOCK_GH_RUN_OUT="in_progress  2026-10-11T08:39:33Z"
    _d main staging develop
    assert_file_contains "$OUT" "実行中、または、待機中です"                                     "実行中: ？ で表示される"
    _dc
}

test_repo_missing() {
    echo ""; echo -e "${CLR_HEAD}[TEST] リポジトリがない → ✗${CLR_RST}"
    _all_ok_env
    export MOCK_GH_REPO_VIEW_EXIT=1
    _d main
    assert_file_contains "$OUT" "GitHub に、リポジトリが見つかりません"                          "リポジトリがないと表示される"
    [[ "$NG" -ge 1 ]] && pass "不足に数える" || fail "不足に数える" "NG=$NG"
    _dc
}

# ブランチ保護（Ruleset）の必須チェックの名前: ジョブ名と合っていれば ✓、「validate / …」の形などで合っていなければ ✗（PR がマージできない）
#   Ruleset が無い・一覧を読めないときは、？（不足に数えない: 無料プランの非公開リポジトリでは、Ruleset を設定できない）
test_rulesets() {
    echo ""; echo -e "${CLR_HEAD}[TEST] ブランチ保護（Ruleset）の必須チェックの名前${CLR_RST}"
    _all_ok_env
    export MOCK_GH_RULESETS_LIST=$'11 protect-main\n12 protect-staging'
    export MOCK_GH_RULESET_CHECKS=$'対象ファイル確認\nデプロイ検証\n順序チェック'
    _d main staging develop
    assert_equals "$NG" "0"                                                       "名前が合っている → 不足は 0 件"
    assert_file_contains "$OUT" "Ruleset protect-main: 必須チェックの名前が、ワークフローのジョブ名と合っています"    "protect-main が ✓"
    assert_file_contains "$OUT" "Ruleset protect-staging: 必須チェックの名前が、ワークフローのジョブ名と合っています"  "protect-staging が ✓"
    _dc

    # 以前の sf-init が登録していた形（ワークフロー名つき）→ ✗ 2 件（main・staging）。余分・足りない・直し方が出る
    export MOCK_GH_RULESET_CHECKS=$'validate / 対象ファイル確認\nvalidate / デプロイ検証\nsequence / 順序チェック'
    _d main staging develop
    assert_equals "$NG" "2"                                                       "「validate / …」の形 → 不足は 2 件（main・staging）"
    assert_file_contains "$OUT" "このままでは、条件が満たされず、PR をマージできません"   "PR がマージできない旨が表示される"
    assert_file_contains "$OUT" "余分: validate / 対象ファイル確認"                    "余分な名前が表示される"
    assert_file_contains "$OUT" "足りない: 対象ファイル確認・デプロイ検証・順序チェック"  "足りない名前が表示される"
    assert_file_contains "$OUT" "対象ファイル確認・デプロイ検証・順序チェック だけにする"  "直し方（ジョブ名だけにする）が表示される"
    _dc

    # 一部だけ足りない
    export MOCK_GH_RULESET_CHECKS=$'対象ファイル確認\nデプロイ検証'
    _d main staging develop
    assert_equals "$NG" "2"                                                       "1 つ足りない → 不足は 2 件"
    assert_file_contains "$OUT" "足りない: 順序チェック"                               "足りない名前だけが表示される"
    _dc

    # Ruleset が無い（無料プランの非公開リポジトリ）→ ？。不足に数えない
    export MOCK_GH_RULESETS_LIST=""
    _d main staging develop
    assert_equals "$NG" "0"                                                       "Ruleset が無い → 不足に数えない"
    assert_file_contains "$OUT" "Ruleset protect-main が、ありません（無料プランの非公開リポジトリでは、設定できません）"  "無い旨（？）が表示される"
    _dc

    # 一覧を取得できない → ？
    export MOCK_GH_RULESETS_LIST=$'11 protect-main\n12 protect-staging' MOCK_GH_FAIL="rulesets"
    _d main staging develop
    assert_equals "$NG" "0"                                                       "一覧を取得できない → 不足に数えない"
    assert_file_contains "$OUT" "Ruleset の一覧を、確認できませんでした"                "取得できない旨（？）が表示される"
    _dc
    unset MOCK_GH_RULESETS_LIST MOCK_GH_RULESET_CHECKS MOCK_GH_FAIL
}

test_all_ok
test_missing
test_rulesets
test_unknown
test_tier_count
test_tools_branch_optional
test_org_record
test_runs
test_repo_missing

teardown "$MB"
print_summary
