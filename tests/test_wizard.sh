#!/bin/bash
# ==============================================================================
# test_wizard.sh - lib/wizard.sh（ウィザード形式の画面の共通部品）のテスト
# ==============================================================================
#
# 【テストケース】
#   1. wizard_step      : 現在地（n / 全体）・タイトル・完了済み・目的の 1 文
#   2. wizard_checklist : 「□ 項目」の一覧
#   3. wizard_do        : 「あなたがやること」が、番号付きで出る
#   4. wizard_next / wizard_hint / wizard_auto
#   5. wizard_confirm   : Enter・Y で進む / N・q・EOF は中断 / それ以外は、再入力
#   6. wizard_fail      : 原因・直し方・やり直しの三点セット
#   7. wizard_done      : できたこと・次にやること
#   8. 表示は標準エラー出力のみ（標準出力に出さない）
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== lib/wizard.sh ===${CLR_RST}"

# wizard.sh の関数を、子プロセスで実行する。引数: 実行する式（標準入力は、呼び出し側のパイプ）
#   標準エラー出力を $WOUT に、標準出力を $WSTD に、終了コードを $WRC に入れる
_w() {
    WOUT=$(mktemp "${TMPDIR:-/tmp}/test-wiz-out-XXXX")
    WSTD=$(mktemp "${TMPDIR:-/tmp}/test-wiz-std-XXXX")
    (
        export SF_INIT_MODE=1
        readonly SCRIPT_NAME=test
        readonly LOG_FILE=/dev/null
        readonly LOG_MODE=NEW
        source "${SF_TOOLS_DIR}/lib/common.sh"
        source "${SF_TOOLS_DIR}/lib/wizard.sh"
        eval "$1"
    ) > "$WSTD" 2> "$WOUT"
    WRC=$?
}
_wc() { rm -f "$WOUT" "$WSTD"; }

test_step() {
    echo ""; echo -e "${CLR_HEAD}[TEST] wizard_step: 現在地・完了済み・目的${CLR_RST}"
    _w 'wizard_step 3 8 "リポジトリの作成" "GitHub にリポジトリを作ります。" "準備の確認" "プロジェクトの確認"'
    assert_exit_ok       "$WRC"                                              "正常終了する"
    assert_file_contains "$WOUT" "ステップ 3 / 8: リポジトリの作成"            "現在地（3 / 8）とタイトルが出る"
    assert_file_contains "$WOUT" "（完了: 準備の確認・プロジェクトの確認）"      "完了したステップが出る"
    assert_file_contains "$WOUT" "GitHub にリポジトリを作ります。"             "目的の 1 文が出る"
    _wc
    _w 'wizard_step 1 8 "準備の確認" "ツールを確認します。"'
    assert_file_contains     "$WOUT" "ステップ 1 / 8: 準備の確認"               "最初のステップ: 現在地が出る"
    assert_file_not_contains "$WOUT" "完了:"                                   "最初のステップ: 完了済みは出ない"
    _wc
    # 引数が 4 つ未満（目的の 1 文を省略）→ 完了済みは出ない（以前は shift 4 が失敗し、番号などが完了済みとして出た）
    _w 'wizard_step 2 8 "タイトルだけ"'
    assert_exit_ok           "$WRC"                                              "引数 3 つ: 正常終了する"
    assert_file_contains     "$WOUT" "ステップ 2 / 8: タイトルだけ"              "引数 3 つ: 現在地とタイトルが出る"
    assert_file_not_contains "$WOUT" "完了:"                                   "引数 3 つ: 完了済みは出ない"
    _wc
}

test_checklist_do() {
    echo ""; echo -e "${CLR_HEAD}[TEST] wizard_checklist / wizard_do / wizard_next / wizard_hint / wizard_auto${CLR_RST}"
    _w 'wizard_checklist "【先に、用意してください】" "GitHub のブラウザ" "Slack のチャンネル"; wizard_do "ボタンを押す" "コピーする"; wizard_next "貼り付けます"; wizard_hint "[Enter] 次へ   [q] 中断"; wizard_auto "リポジトリを作りました"'
    assert_file_contains "$WOUT" "【先に、用意してください】"                  "チェックリストの見出しが出る"
    assert_file_contains "$WOUT" "□ GitHub のブラウザ"                         "項目が「□」付きで出る"
    assert_file_contains "$WOUT" "□ Slack のチャンネル"                        "2 つ目の項目も出る"
    assert_file_contains "$WOUT" "あなたがやること"                             "「あなたがやること」が出る"
    assert_file_contains "$WOUT" "1. ボタンを押す"                             "手順に番号が付く（1）"
    assert_file_contains "$WOUT" "2. コピーする"                               "手順に番号が付く（2）"
    assert_file_contains "$WOUT" "そのあと"                                    "「そのあと」が出る"
    assert_file_contains "$WOUT" "貼り付けます"                                "「そのあと」の説明が出る"
    assert_file_contains "$WOUT" "[Enter] 次へ   [q] 中断"                     "操作のヒントが出る"
    assert_file_contains "$WOUT" "✔"                                           "自動の処理が ✔ で出る"
    _wc
}

test_confirm() {
    echo ""; echo -e "${CLR_HEAD}[TEST] wizard_confirm: Enter・Y で進む / N・q・EOF は中断 / それ以外は再入力${CLR_RST}"
    # 注意: パイプ（printf | _w）では、_w が子プロセスになり、結果の変数が失われる。ヒアストリングで渡す
    _w 'wizard_confirm "用意ができたら Enter"' <<< ""
    assert_exit_ok "$WRC" "Enter（空）→ 進む"; _wc
    _w 'wizard_confirm' <<< "Y"
    assert_exit_ok "$WRC" "Y → 進む"; _wc
    _w 'wizard_confirm' <<< "y"
    assert_exit_ok "$WRC" "y → 進む"; _wc
    _w 'wizard_confirm' <<< "q"
    assert_exit_fail "$WRC" "q → 中断"
    assert_file_contains "$WOUT" "中断しました" "q → 中断の表示が出る"; _wc
    _w 'wizard_confirm' <<< "N"
    assert_exit_fail "$WRC" "N → 中断（管理者向けの確認: N で必ず中断）"; _wc
    _w 'wizard_confirm' <<< "n"
    assert_exit_fail "$WRC" "n → 中断"; _wc
    _w 'wizard_confirm' <<< $'x\n'
    assert_exit_ok "$WRC" "打ち間違い（x）→ 再入力 → Enter で進む"
    assert_file_contains "$WOUT" "Enter を押すと、進みます" "打ち間違い → 案内が出る"; _wc
    _w 'wizard_confirm' < /dev/null
    assert_exit_fail "$WRC" "EOF（入力なし）→ 中断"; _wc
}

test_fail_done() {
    echo ""; echo -e "${CLR_HEAD}[TEST] wizard_fail / wizard_done${CLR_RST}"
    _w 'wizard_fail "workflow の権限がありません" "作成ページで、workflow にチェックを入れる" "もう一度 sf-init.sh を実行する"'
    assert_file_contains "$WOUT" "うまくいきませんでした"                       "失敗の見出しが出る"
    assert_file_contains "$WOUT" "原因     : workflow の権限がありません"        "原因が出る"
    assert_file_contains "$WOUT" "【直し方】 作成ページで、workflow にチェックを入れる" "直し方が出る"
    assert_file_contains "$WOUT" "【やり直し】 もう一度 sf-init.sh を実行する"    "やり直しの方法が出る"
    _wc
    _w 'wizard_fail "原因だけ"'
    assert_file_not_contains "$WOUT" "【直し方】"                              "直し方が空なら、出さない"
    _wc
    _w 'wizard_done "できました: owner/force-x" "GitHub / Slack" -- "1. sf-job.sh を実行する" "2. URL を見る"'
    assert_file_contains "$WOUT" "できました: owner/force-x"                    "完了のタイトルが出る"
    assert_file_contains "$WOUT" "設定したもの : GitHub / Slack"                "できたことが出る"
    assert_file_contains "$WOUT" "【次にやること】"                             "「次にやること」が出る"
    assert_file_contains "$WOUT" "1. sf-job.sh を実行する"                      "次にやることの項目が出る"
    _wc
    _w 'wizard_done "できました" "GitHub"'
    assert_file_not_contains "$WOUT" "【次にやること】"                         "次にやることがなければ、見出しを出さない"
    _wc
}

test_stdout_clean() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 表示は標準エラー出力のみ（標準出力に出さない）${CLR_RST}"
    _w 'wizard_banner "T"; wizard_step 1 8 "A" "B"; wizard_do "x"; wizard_next "y"; wizard_auto "z"; wizard_fail "c" "f" "r"; wizard_done "D" "m" -- "n"'
    [[ ! -s "$WSTD" ]] && pass "標準出力は、空（命令置換で値を返す関数と、混ざらない）" || fail "標準出力は、空" "$(cat "$WSTD")"
    _wc
}

test_step
test_checklist_do
test_confirm
test_fail_done
test_stdout_clean

print_summary
