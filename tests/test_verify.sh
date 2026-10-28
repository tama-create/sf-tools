#!/bin/bash
# ==============================================================================
# test_verify.sh - phases/init/verify.sh（実際のリポジトリの検証）と lib/verify-common.sh のテスト
# ==============================================================================
#
# テストが多く、時間がかかる（Windows の CI で約 10 分）ため、3 つのファイル（test_verify.sh・test_verify2.sh・test_verify3.sh）に
# 分け、並列に動かす。共通の部品（gh / git のモック・環境の設定・_env・_run・_count）は tests/verify-test-lib.sh。
#   test_verify.sh  : 1〜10 と 13（--help・ガード・--plan・診断・確認・1 層・3 層・失敗・取り違え・--cleanup・サンプル）
#   test_verify2.sh : test_review_fixes・test_environment
#   test_verify3.sh : test_branch_cleanup・test_components（12）
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
#   12. --components               : パターン別のサンプルを、develop だけにリリースして削除する（PR 3 本）。--validate-only は、
#                                    マージせずに閉じる。develop がない構成は、拒否する。既存の labels は、上書きしない
#   13. lib/verify-samples.sh      : サンプルのパス・本文・リリース対象・削除対象（段階 1 → 段階 2）
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/verify-test-lib.sh"

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
    # 回帰: origin が GitHub 以外 → 中断する（以前は、sed だけで解析し、owner/repo の形なら、GitHub 以外でも進んだ）
    _env
    MOCK_GIT_REMOTE_URL="https://gitlab.com/tamashimon/force-testproject.git" _run "" --plan
    assert_exit_fail "$RC" "origin が GitHub 以外 → 中断する"
    assert_file_contains "$OUT" "origin が GitHub のリポジトリではありません" "origin が GitHub 以外 → 理由が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh api repos/" "origin が GitHub 以外 → GitHub に問い合わせない"
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

test_samples() {
    echo ""; echo -e "${CLR_HEAD}[TEST] lib/verify-samples.sh: サンプルの定義${CLR_RST}"
    _env
    local out
    out=$( (
        export SF_INIT_MODE=1 PATH="$MB:$PATH"
        readonly SCRIPT_NAME=test LOG_FILE=/dev/null LOG_MODE=NEW
        source "$SF_TOOLS_DIR/lib/common.sh"
        source "$SF_TOOLS_DIR/lib/verify-common.sh"
        # すべてのパスに、本文がある。XML は、先頭と末尾が閉じている
        _bad=0; _xml=0
        while IFS= read -r p; do
            c=$(verify_sample_content_for "$p") || { echo "NOCONTENT=$p"; _bad=1; continue; }
            [[ -n "$c" ]] || { echo "EMPTY=$p"; _bad=1; }
            case "$p" in *-meta.xml)
                _xml=$((_xml + 1))
                [[ "$(printf '%s' "$c" | head -n 1)" == '<?xml version="1.0" encoding="UTF-8"?>' ]] || { echo "XMLHEAD=$p"; _bad=1; }
                printf '%s' "$c" | tail -n 1 | grep -q '^</[A-Za-z]*>$' || { echo "XMLTAIL=$p"; _bad=1; } ;;
            esac
        done < <(verify_sample_paths all)
        echo "BAD=$_bad"
        echo "XML=$_xml"
        echo "ALL=$(verify_sample_paths all | wc -l | tr -d ' ')"
        echo "S1=$(verify_sample_paths stage1 | wc -l | tr -d ' ')"
        echo "S2=$(verify_sample_paths stage2 | wc -l | tr -d ' ')"
        echo "DUP=$(verify_sample_paths all | sort | uniq -d | wc -l | tr -d ' ')"
        echo "OBJ_IN_S1=$(verify_sample_paths stage1 | grep -c 'objects/')"
        echo "NONAME=$(verify_sample_paths all | grep -v 'labels/' | grep -v 'SfToolsE2eHello\|sfToolsE2eHello' | wc -l | tr -d ' ')"
        echo "TESTS=$(verify_sample_deploy_target_text | grep -c '\.cls$')"
        echo "MEMBERS=$(verify_sample_deploy_target_text | sed -n '/^\[members\]/,$p' | grep -c ':')"
        echo "FILES_ARE_FILES=$(verify_sample_deploy_target_text | sed -n '/^\[files\]/,/^\[members\]/p' | grep -v '^\[' | grep -v '^$' | while IFS= read -r f; do verify_sample_paths all | grep -qxF "$f" || echo "$f"; done | wc -l | tr -d ' ')"
        echo "R1=$(verify_sample_remove_target_text stage1 | grep -c ':')"
        echo "R1_LAYOUT=$(verify_sample_remove_target_text stage1 | grep -c '^Layout:')"
        echo "R1_FLOWDEF=$(verify_sample_remove_target_text stage1 | grep -c '^FlowDefinition:')$(verify_sample_remove_target_text stage1 | grep -c '^Flow:')"
        echo "R2=$(verify_sample_remove_target_text stage2 | grep -c ':')"
        echo "R2_OBJ_LAST=$(verify_sample_remove_target_text stage2 | grep ':' | tail -n 1)"
        echo "TRIGGER_BEFORE_OBJ=$(verify_sample_remove_target_text stage1 | grep -c 'CustomObject')"
        # CustomLabels を、含めない
        VERIFY_SAMPLE_LABELS=0
        echo "NL_ALL=$(verify_sample_paths all | wc -l | tr -d ' ')"
        echo "NL_LABELS=$(verify_sample_paths all | grep -c 'labels/')$(verify_sample_deploy_target_text | grep -c CustomLabel)$(verify_sample_remove_target_text stage1 | grep -c CustomLabel)"
        # オブジェクト系を含めない（通しの既定）
        VERIFY_SAMPLE_OBJECTS=0; VERIFY_SAMPLE_LABELS=1
        echo "NO_ALL=$(verify_sample_paths all | wc -l | tr -d ' ')"
        echo "NO_S2=$(verify_sample_paths stage2 | wc -l | tr -d ' ')"
        echo "NO_OBJ_PATHS=$(verify_sample_paths all | grep -c 'objects/\|layouts/\|triggers/\|TriggerTest')"
        echo "NO_OBJ_DEPLOY=$(verify_sample_deploy_target_text | grep -c 'CustomObject\|CustomField\|Layout\|Trigger')"
        echo "NO_R1=$(verify_sample_remove_target_text stage1 | grep -c ':')"
        echo "NO_R2=$(verify_sample_remove_target_text stage2 | grep -c ':')"
        echo "NO_MIXED=$(verify_sample_deploy_target_text | grep -c '^\[files\]')$(verify_sample_deploy_target_text | grep -c '^\[members\]')"
        # Flow を含めない（通しの既定）
        VERIFY_SAMPLE_FLOW=0
        echo "NOFLOW_ALL=$(verify_sample_paths all | wc -l | tr -d ' ')"
        echo "NOFLOW_PATH=$(verify_sample_paths all | grep -c 'flows/')"
        echo "NOFLOW_DEPLOY=$(verify_sample_deploy_target_text | grep -c 'flows/')"
        VERIFY_SAMPLE_FLOW=1
        echo "FLOW_DEPLOY=$(verify_sample_deploy_target_text | grep -c 'flows/')"
        VERIFY_SAMPLE_OBJECTS=1
        # 切替: hello（既定）と components
        VERIFY_SET=hello; echo "SET_HELLO=$(verify_set_paths all | wc -l | tr -d ' ')"
        VERIFY_SET=components; VERIFY_SAMPLE_LABELS=1; echo "SET_COMP=$(verify_set_paths all | wc -l | tr -d ' ')"
        # URL エンコード
        # labels のファイルの判定: サンプルのラベルだけ → サンプルのもの。ほかのラベルを含む・空 → 利用者のもの
        printf '<CustomLabels>\n<labels>\n<fullName>SfToolsE2eHello</fullName>\n</labels>\n</CustomLabels>\n' | verify_sample_labels_file_is_ours && echo "LBL_OURS=yes" || echo "LBL_OURS=no"
        printf '<CustomLabels>\n<labels>\n<fullName>Mine</fullName>\n</labels>\n<labels>\n<fullName>SfToolsE2eHello</fullName>\n</labels>\n</CustomLabels>\n' | verify_sample_labels_file_is_ours && echo "LBL_MIXED=ours" || echo "LBL_MIXED=theirs"
        printf '' | verify_sample_labels_file_is_ours && echo "LBL_EMPTY=ours" || echo "LBL_EMPTY=theirs"
        printf '<CustomLabels>\n<labels>\n<fullName>Other</fullName>\n</labels>\n</CustomLabels>\n' | verify_sample_labels_file_is_ours && echo "LBL_OTHER=ours" || echo "LBL_OTHER=theirs"
        # LWC と Aura は、同じ名前空間。大文字・小文字を無視して、同名にならないこと（実際の組織が拒否した）
        echo "AURA_LWC_DIFF=$([[ "$(printf '%s' "$VERIFY_SAMPLE_AURA" | tr 'A-Z' 'a-z')" != "$(printf '%s' "$VERIFY_SAMPLE_LWC" | tr 'A-Z' 'a-z')" ]] && echo yes || echo no)"
        echo "URLPATH=$(_verify_urlpath 'a/SfToolsE2eHello__c-SfToolsE2eHello Layout%28x%29.xml')"
    ) 2>&1 )
    assert_output_contains "$out" "BAD=0"          "サンプル: すべてのパスに本文がある・XML の形式が正しい"
    assert_output_not_contains "$out" "NOCONTENT"  "サンプル: 本文のないパスがない"
    assert_output_contains "$out" "ALL=21"         "サンプル: パスは 21 個（段階 1: 19 + 段階 2: 2）"
    assert_output_contains "$out" "S1=19"          "サンプル: 段階 1 は 19 個"
    assert_output_contains "$out" "S2=2"           "サンプル: 段階 2 は 2 個（オブジェクト・項目）"
    assert_output_contains "$out" "DUP=0"          "サンプル: パスが重複しない"
    assert_output_contains "$out" "OBJ_IN_S1=0"    "サンプル: オブジェクトは、段階 2（段階 1 には入れない）"
    assert_output_contains "$out" "NONAME=0"       "サンプル: labels 以外は、すべて SfToolsE2eHello 系の名前（ほかのファイルを、上書きしない）"
    assert_output_contains "$out" "TESTS=3"        "リリース対象: Apex クラスが 3 つ（Hello・テスト・トリガーのテスト）"
    assert_output_contains "$out" "FILES_ARE_FILES=0" "リリース対象: [files] のパスは、すべて、サンプルのファイルを指す"
    assert_output_contains "$out" "R1=9"           "削除対象（段階 1）: 9 件"
    assert_output_contains "$out" "R1_LAYOUT=0"    "削除対象（段階 1）: Layout は、含めない（最後の 1 つは削除できない。オブジェクトの削除に任せる）"
    assert_output_contains "$out" "R1_FLOWDEF=00"  "削除対象: Flow は、含めない（接続ユーザーに、API で削除する権限がない場合がある。Flow 型・FlowDefinition 型とも拒否された）"
    assert_output_contains "$out" "R2=2"           "削除対象（段階 2）: 項目・オブジェクト"
    assert_output_contains "$out" "R2_OBJ_LAST=CustomObject:SfToolsE2eHello__c" "削除対象（段階 2）: オブジェクトは、項目のあと"
    assert_output_contains "$out" "TRIGGER_BEFORE_OBJ=0" "削除対象: オブジェクトは、段階 1 には入れない（トリガーなどを、先に消す）"
    assert_output_contains "$out" "NL_ALL=20"      "CustomLabels なし: パスは 20 個"
    assert_output_contains "$out" "NL_LABELS=000"  "CustomLabels なし: labels のファイル・メンバーを、含めない"
    assert_output_contains "$out" "NO_ALL=14"      "オブジェクト系なし: パスは 14 個"
    assert_output_contains "$out" "NO_S2=0"        "オブジェクト系なし: 段階 2 は、空"
    assert_output_contains "$out" "NO_OBJ_PATHS=0" "オブジェクト系なし: オブジェクト・Layout・トリガーのパスを、含めない"
    assert_output_contains "$out" "NO_OBJ_DEPLOY=0" "オブジェクト系なし: リリース対象に、オブジェクト・項目・Layout・トリガーを、含めない"
    assert_output_contains "$out" "NO_R1=7"        "オブジェクト系なし: 削除対象（段階 1）は 7 件"
    assert_output_contains "$out" "NOFLOW_ALL=13"  "Flow なし: パスは 13 個（オブジェクト系なし）"
    assert_output_contains "$out" "NOFLOW_PATH=0"  "Flow なし: Flow のパスを、含めない"
    assert_output_contains "$out" "NOFLOW_DEPLOY=0" "Flow なし: リリース対象に、Flow を含めない"
    assert_output_contains "$out" "FLOW_DEPLOY=1"  "Flow あり: リリース対象に、Flow を含める（検証のみ）"
    assert_output_contains "$out" "NO_R2=0"        "オブジェクト系なし: 削除対象（段階 2）は、空"
    assert_output_contains "$out" "NO_MIXED=11"    "オブジェクト系なし: [files] と [members] の混在は、維持する（混在の確認）"
    assert_output_contains "$out" "SET_HELLO=4"    "切替: hello は 4 ファイル（従来どおり）"
    assert_output_contains "$out" "SET_COMP=21"    "切替: components は 21 ファイル"
    assert_output_contains "$out" "LBL_OURS=yes"     "labels の判定: サンプルのラベルだけのファイルは、サンプルのもの"
    assert_output_contains "$out" "LBL_MIXED=theirs" "labels の判定: ほかのラベルを含むファイルは、利用者のもの（同名のラベルを含んでいても）"
    assert_output_contains "$out" "LBL_EMPTY=theirs" "labels の判定: 空・読めないときは、利用者のもの（触らない）"
    assert_output_contains "$out" "LBL_OTHER=theirs" "labels の判定: 別のラベルだけのファイルは、利用者のもの"
    assert_output_contains "$out" "AURA_LWC_DIFF=yes" "サンプル: Aura と LWC は、別名（同じ名前空間のため。同名だと、組織が拒否する）"
    assert_output_contains "$out" "URLPATH=a/SfToolsE2eHello__c-SfToolsE2eHello%20Layout%2528x%2529.xml" "パスの URL エンコード: 空白 → %20・% → %25"
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
        # PR の作成: 番号が取れれば戻り値 0。作成できても番号が取れなければ戻り値 1（以前は、空のまま 0）
        n=$(verify_pr_create tamashimon/force-testproject br t); echo "PR_OK=[$n] RC=$?"
        verify_gh() { printf 'https://github.com/o/r/pull/12\r\n'; }   # 行末に CR がある出力
        n=$(verify_pr_create tamashimon/force-testproject br t); echo "PR_CR=[$n] RC=$?"
        verify_gh() { echo "created"; }   # 番号を含まない出力
        n=$(verify_pr_create tamashimon/force-testproject br t); echo "PR_NONUM=[$n] RC=$?"
        # 本文: 末尾が .cls-meta.xml のパスは、クラス名を問わず、メタデータ。それ以外は戻り値 1
        verify_hello_content_for "x/Other.cls-meta.xml" | grep -q "<ApexClass" && echo "META_ANY=ok"
        verify_hello_content_for "x/Other.cls" > /dev/null; echo "OTHER_RC=$?"
    ) 2>&1 )
    [[ "$out" == *"PR_CR=[12] RC=0"* ]]  && pass "PR の作成: 行末に CR があっても、番号を返す" || fail "PR の作成: 行末に CR があっても、番号を返す" "$out"
    [[ "$out" == *"PR_NONUM=[] RC=1"* ]] && pass "PR の作成: 番号が取れなければ、戻り値 1" || fail "PR の作成: 番号が取れなければ、戻り値 1" "$out"
    assert_output_contains "$out" "META_ANY=ok"      "本文: 末尾が .cls-meta.xml のパスは、メタデータの本文"
    assert_output_contains "$out" "OTHER_RC=1"       "本文: それ以外のパスは、戻り値 1"
    [[ "$out" =~ PR_OK=\[[0-9]+\]\ RC=0 ]] && pass "PR の作成: 番号を返し、戻り値 0" || fail "PR の作成: 番号を返し、戻り値 0" "$out"
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
test_cleanup
test_samples
test_lib

teardown "$MB" "$FORCE" "$HM"
print_summary
