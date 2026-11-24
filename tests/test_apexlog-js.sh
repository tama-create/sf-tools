#!/bin/bash
# ==============================================================================
# test_apexlog-js.sh - lib/apexlog.js（sf-log.sh の要約・一覧の検査・日時の計算）の単体テスト
# ==============================================================================
# 要約は、実ログをもとに手で作った小さな見本（tests/fixtures/apexlog/。実データを含まない）で確かめる。
# 設計: doc/sf-log-design.md 6 章（要約）・8.3（一覧）・6.4（日時）・12 章（テスト）
#
# 【テストケース】
#   1. summarize: エラー（FATAL_ERROR の複数行・EXCEPTION_THROWN・FLOW_ELEMENT_ERROR・同じものをまとめる・場所と CODE_UNIT）
#   2. summarize: ログの一覧（操作・最初の CODE_UNIT・SOQL / DML の使用量・長さ・PC のタイムゾーンでの開始時刻）
#   3. summarize: System.debug（新しい順・複数行の続き）・入力規則（規則の名前）・制限（50% を超えたもの）
#   3b. summarize: フロー・入力規則（flow.log。実機の形: フローごとの開始・完了・エラーと要素・入力規則ごとの評価・通過・停止・
#      FLOW_ELEMENT_ERROR を、同じ要素を最後に始めた実行のフローに結ぶ・文言のリンクのタグを外す・System.debug の < > は残す・
#      一覧の操作に、フロー・入力規則の名前を添える）。実機と違う並びの FLOW_ELEMENT_ERROR（odd.log）は、推測で読まずに並べる
#   4. summarize: 取れていないものを隠さない（--note・読めなかったログ・読み取れなかった行・20MB の切り詰め・タイムゾーン不明・
#      該当する行なしの区分・対象のログなし）
#   5. summarize: 一覧の形の誤り（列の数・ID・日時・数値）・--list なし → 終了コード 1
#   6. list: 自分 / 他の人の見分け（15 文字・18 文字）・日時の正規化・前に付いた文字・表に改行やタブを入れない
#   7. list: 応答の形の誤り（status・records・Id・LogUserId・StartTime・LogLength）→ 終了コード 1。エラーの文言に、応答の値を出さない
#   8. time: now・norm（+0000・+09:00・Z）・cmp・min・add・形の誤り（2 月 30 日を含む）
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== lib/apexlog.js ===${CLR_RST}"

AJS="$SF_TOOLS_DIR/lib/apexlog.js"
FX="tests/fixtures/apexlog"   # 一覧には、相対のパスで書く（--base で sf-tools の根を指す）

# 文字どおりに含むか（要約には [ ] や先頭の - が多く、grep の正規表現・オプションとして読まれるため、test_helper.sh の
# _has は使わない）。引数: 出力・探す文字列・テストの名前
_has()   { [[ "$1" == *"$2"* ]] && pass "$3" || fail "$3" "'$2' が出力に含まれていない"; }
_hasnt() { [[ "$1" == *"$2"* ]] && fail "$3" "'$2' が出力に含まれている" || pass "$3"; }

# 一覧（TSV）を作る。引数: 「ファイル名 ID 開始 操作 状態 長さ 所要」を 1 本ずつ、7 つずつ並べる
#   結果: $_LIST（一覧のファイル）
_list() {
    _LIST=$(mktemp "${TMPDIR:-/tmp}/test-apexlog-XXXX")
    : > "$_LIST"
    while [[ $# -ge 7 ]]; do
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$FX/$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$_LIST"
        shift 7
    done
}
# 要約を作る。引数: 追加のオプション。結果: $_OUT（標準出力と標準エラー）・$_RC
_sum() {
    _OUT=$(node "$AJS" summarize --list "$_LIST" --base "$SF_TOOLS_DIR" --now 2026-11-23T02:30:00Z --local-offset 540 "$@" 2>&1); _RC=$?
}

# ------------------------------------------------------------------------------
test_summarize_errors() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] summarize: エラー${CLR_RST}"
    _list ok.log 07L000000000001AAA 2026-11-23T02:06:40Z Api 成功 3074 644 \
          fatal.log 07L000000000002AAA 2026-11-23T02:06:50Z Api "Attempt to de-reference a null object" 1777 107 \
          thrown.log 07L000000000003AAA 2026-11-23T02:08:05Z /aura 成功 4088 90 \
          odd.log 07L000000000004AAA 2026-11-23T02:09:00Z Api 成功 900 10
    _sum
    assert_exit_ok "$_RC" "要約を作れる"
    _has "$_OUT" "# デバッグログの要約（2026-11-23 11:30:00 作成・4 本・エラー 5）" "見出し: 作成時刻（--local-offset の時差）・本数・エラーの数（まとめる前）"
    # PC のタイムゾーンが UTC でも、--local-offset の時差で表示する（GitHub Actions の Windows と同じ状態を、TZ で作る）
    local o2
    o2=$(TZ=UTC node "$AJS" summarize --list "$_LIST" --base "$SF_TOOLS_DIR" --now 2026-11-23T02:30:00Z --local-offset 540 2>&1)
    _has "$o2" "（2026-11-23 11:30:00 作成・" "--local-offset は、PC のタイムゾーン（TZ=UTC）より優先する"
    o2=$(node "$AJS" summarize --list "$_LIST" --base "$SF_TOOLS_DIR" --local-offset 900 2>&1)
    [[ $? -ne 0 ]] && pass "--local-offset の範囲外（900）→ 終了コード 1" || fail "--local-offset の範囲外（900）→ 終了コード 1"
    _has "$_OUT" "[$FX/fatal.log:10] FATAL_ERROR System.NullPointerException: Attempt to de-reference a null object" "FATAL_ERROR: 行番号つきの参照と文言"
    _has "$_OUT" "場所: AnonymousBlock: line 4, column 1（直前の CODE_UNIT: execute_anonymous_apex）" "FATAL_ERROR: 続きの行のスタックトレースを場所にする"
    _has "$_OUT" "EXCEPTION_THROWN System.IllegalArgumentException: MARK 自分で投げた例外" "EXCEPTION_THROWN: 文言"
    _has "$_OUT" "場所: 行 2（直前の CODE_UNIT: AccountService.updateRating）" "EXCEPTION_THROWN: 行と、入れ子の内側の CODE_UNIT"
    _has "$_OUT" "（同じものが 2 件）" "同じ種類と文言のエラーは 1 つにまとめる"
    _has "$_OUT" "FLOW_ELEMENT_ERROR FlowRecordUpdate / Update_Account / この項目は更新できません" "フローのエラーも、エラーに入れる（実機と違う並びは、推測で読まずに項目を並べる）"
    # エラーが先（1 の見出しが、2 の見出しより前）
    local p1 p2
    p1=$(printf '%s\n' "$_OUT" | grep -n '^## 1. エラー' | cut -d: -f1)
    p2=$(printf '%s\n' "$_OUT" | grep -n '^## 2. ログの一覧' | cut -d: -f1)
    [[ -n "$p1" && -n "$p2" && "$p1" -lt "$p2" ]] && pass "エラーを先に書く" || fail "エラーを先に書く"
    rm -f "$_LIST"
}

test_summarize_list_debug_limits() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] summarize: 一覧・System.debug・入力規則・制限${CLR_RST}"
    _list ok.log 07L000000000001AAA 2026-11-23T02:06:40Z "/services/data/v68.0/tooling/executeAnonymous/" 成功 3074 644 \
          odd.log 07L000000000004AAA 2026-11-23T02:09:00Z Api 成功 900 10
    _sum
    _has "$_OUT" "| 2026-11-23 11:06:40 | /services/data/v68.0/tooling/executeAnonymous/（execute_anonymous_apex） | 成功 | 3.0KB | 644ms | 1/100 | 3/150 | $FX/ok.log |" "一覧: 開始（PC のタイムゾーン）・操作と最初の CODE_UNIT・長さ・所要・SOQL・DML"
    _has "$_OUT" "[$FX/ok.log:13] 11:06:40.9 ERROR 行 7: MARK 3: 複数行の（続き 2 行は本文を見てください）" "System.debug: 複数行は 1 行目と、続きの行数"
    # 新しい順（ok.log の行 13 が、行 7 より前に出る）
    local a b
    a=$(printf '%s\n' "$_OUT" | grep -n "ok.log:13\]" | cut -d: -f1)
    b=$(printf '%s\n' "$_OUT" | grep -n "ok.log:7\]" | cut -d: -f1)
    [[ -n "$a" && -n "$b" && "$a" -lt "$b" ]] && pass "System.debug: 新しい順" || fail "System.debug: 新しい順"
    _has "$_OUT" "VALIDATION_ERROR 取引先名は必須です（規則: Account_Name_Required）" "入力規則: 直前の VALIDATION_RULE の名前を添える"
    _has "$_OUT" "Number of SOQL queries: 80 / 100（80%）" "制限: 50% を超えたものを書く"
    _has "$_OUT" "Maximum CPU time: 9000 / 10000（90%）" "制限: CPU 時間"
    _hasnt "$_OUT" "Number of DML statements: 10 / 150" "制限: 50% 以下は書かない"
    _hasnt "$_OUT" "Execute Anonymous" "匿名 Apex のコードの行は、要約に入れない"
    rm -f "$_LIST"
}

test_summarize_flow() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] summarize: フロー・入力規則${CLR_RST}"
    _list flow.log 07L000000000006AAA 2026-11-23T23:00:36Z "/services/data/v68.0/sobjects/Account" 成功 4183 943
    _sum
    assert_exit_ok "$_RC" "要約を作れる"
    _has "$_OUT" "/services/data/v68.0/sobjects/Account（Validation:Account:new／フロー: Account_After_Save／入力規則: Account_Check） |" "一覧: 操作に、最初の CODE_UNIT と、ログの中のフロー・入力規則の名前を添える"
    _has "$_OUT" "## 4. フロー・入力規則・重複ルール" "4 の見出し"
    _has "$_OUT" "- [$FX/flow.log:16] フロー Account_After_Save: 開始 2・完了 1・エラー 1・要素: Check_Type（FlowDecision）、Set_Description（FlowRecordUpdate）" "フロー: 開始・完了・エラーの数と、実行した要素（最初の開始の場所）"
    _has "$_OUT" "- [$FX/flow.log:5] 入力規則 Account_Check: 評価 2・通過 1・停止 1" "入力規則: 評価・通過・停止の数"
    _has "$_OUT" "- 入力規則のエラー: 1 件" "入力規則のエラーの数"
    _has "$_OUT" "  - [$FX/flow.log:41] VALIDATION_FAIL（規則: Account_Check）" "入力規則のエラー: 場所と規則の名前"
    _has "$_OUT" "[$FX/flow.log:44] FLOW_ELEMENT_ERROR フローで次のレコードの更新が試行されました: 001000000000002。次のエラーが発生しました: FIELD_CUSTOM_VALIDATION_EXCEPTION: 保存できません。詳細は 『開発者ガイド』を参照してください。" "フローのエラー: 文言（リンクのタグは外し、中の文字は残す）"
    _hasnt "$_OUT" "<a href='https://example.com" "フローのエラー: リンクのタグを残さない"
    _has "$_OUT" "場所: フロー Account_After_Save の要素 Set_Description（FlowRecordUpdate）（直前の CODE_UNIT: Flow:Account）" "フローのエラー: 同じ要素を最後に始めた実行のフローに結ぶ"
    _has "$_OUT" "MARK <a href='x'>そのまま</a> List<String>" "System.debug の < > は、そのまま残す"
    _has "$_OUT" "エラー 1）" "見出しのエラーの数に、フローのエラーを数える"
    # 区分は CATEGORIES の順（エラー・入力規則・フロー・重複ルール・…・制限・件数）。「）: 重複ルール・制限・件数」なら、その前の区分は出ている
    _has "$_OUT" "（詳しさが足りずに出なかった可能性もある）: 重複ルール・制限・件数" "フロー・入力規則・エラーの行があれば、出なかった区分に入れない（重複ルール・制限・件数だけ）"
    # フロー・入力規則の行がないログ
    _list ok.log 07L000000000001AAA 2026-11-23T02:06:40Z Api 成功 3074 644
    _sum
    _has "$_OUT" "- フロー: なし" "フローがなければ、なしと書く"
    _has "$_OUT" "- 入力規則: なし" "入力規則がなければ、なしと書く"
    _has "$_OUT" "- 入力規則のエラー: なし" "入力規則のエラーがなければ、なしと書く"
    _has "$_OUT" "- 重複ルール: なし" "重複ルールがなければ、なしと書く"
    _hasnt "$_OUT" "allowSave" "重複ありの保存がなければ、止められる注意を書かない"
    rm -f "$_LIST"
}

# 重複ルール（2026-11-24 に tama-dev で確かめた形をまねた duplicate.log。6.3）
test_summarize_duplicate() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] summarize: 重複ルール${CLR_RST}"
    _list duplicate.log 07L000000000007AAA 2026-11-24T03:00:00Z "/services/data/v68.0/tooling/executeAnonymous/" 成功 3000 10
    _sum
    assert_exit_ok "$_RC" "要約を作れる"
    _has "$_OUT" "（execute_anonymous_apex／重複: Standard Account Duplicate Rule・Standard Contact Duplicate Rule） |" "一覧: 操作に、重複ルールの名前を添える"
    _has "$_OUT" "- [$FX/duplicate.log:9] 重複ルール Standard Account Duplicate Rule（Account・INSERT）: 保存の中で 1 回（保存しようとした 1 件のうち、重複あり 1 件）・保存の後で 1 回（重複あり 1 件）・見つかった重複: 001000000000001・動作: 許可（警告・記録）" "重複ルール: 保存の中と保存の後を分けて数え、見つかった重複と動作を書く"
    _has "$_OUT" "- [$FX/duplicate.log:19] 重複ルール Standard Contact Duplicate Rule（Contact・INSERT）: 保存の中で 1 回（保存しようとした 2 件のうち、重複あり 0 件）・動作: 許可（警告・記録）" "重複がないルール: 見つかった重複を書かない"
    _has "$_OUT" "許可の指定（DuplicateRuleHeader.allowSave）がなければ止められます" "保存の中で重複ありなら、止められる注意を書く"
    _has "$_OUT" "DUPLICATES_DETECTED, Use one of these records?" "止められたときの例外は、1 のエラーに入る"
    _hasnt "$_OUT" "出なかった可能性もある）: エラー・入力規則・フロー・重複ルール" "重複ルールの行があれば、出なかった区分に入れない"
    rm -f "$_LIST"
}

test_summarize_gaps() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] summarize: 取れていないものを隠さない${CLR_RST}"
    _list ok.log 07L000000000001AAA 2026-11-23T02:06:40Z Api 成功 3074 644 \
          odd.log 07L000000000004AAA 2026-11-23T02:09:00Z Api 成功 21000000 10 \
          none.log 07L000000000005AAA 2026-11-23T02:10:00Z Api 成功 10 1
    _sum --note "取得役: 動作中（最後の取得 11:29）" --note "入れなかった古いログ: 3 本"
    _has "$_OUT" "> 取得役: 動作中（最後の取得 11:29）" "--note を先頭に書く（1 つ目）"
    _has "$_OUT" "> 入れなかった古いログ: 3 本" "--note を先頭に書く（2 つ目）"
    _has "$_OUT" "> 読めなかったログ: 1 本（$FX/none.log）" "ファイルのないログを、読めなかったログとして書く"
    _has "$_OUT" "$FX/none.log（読めません） |" "一覧にも、読めないことを書く"
    _has "$_OUT" "> 読み取れなかった行: 1 行" "想定と違う形の行を、数えて書く"
    _has "$_OUT" "- 読み取れなかった行: 1 行（$FX/odd.log:2）" "読み取れなかった行の場所を書く"
    _has "$_OUT" "> 20MB で切り詰められたログ: 1 本" "20MB 以上のログを、切り詰めとして書く"
    _has "$_OUT" "- 切り詰めあり: $FX/odd.log（20.0MB）" "切り詰めのログの場所"
    _has "$_OUT" "> タイムゾーン不明のログ: 1 本" "USER_INFO のないログは、タイムゾーン不明と書く"
    # 該当する行なし（ok.log だけ: エラー・入力規則・フローの行がない）
    _list ok.log 07L000000000001AAA 2026-11-23T02:06:40Z Api 成功 3074 644
    _sum
    _has "$_OUT" "該当する行なし（詳しさが足りずに出なかった可能性もある）: エラー・入力規則・フロー" "1 行も出なかった区分を書く"
    _hasnt "$_OUT" "タイムゾーン不明" "USER_INFO があれば、タイムゾーン不明と書かない"
    # 対象のログなし
    : > "$_LIST"
    _sum
    assert_exit_ok "$_RC" "対象のログがなくても、要約を作る"
    _has "$_OUT" "> 対象のログはありません。" "対象のログがないことを書く"
    _hasnt "$_OUT" "該当する行なし" "ログがないときは、区分の有無を書かない（判断できないため）"
    rm -f "$_LIST"
}

test_summarize_bad_list() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] summarize: 一覧の形の誤り${CLR_RST}"
    _LIST=$(mktemp "${TMPDIR:-/tmp}/test-apexlog-XXXX")
    local bad
    for bad in \
        "$FX/ok.log	07L000000000001AAA	2026-11-23T02:06:40Z	Api	成功	3074" \
        "$FX/ok.log	07L-bad	2026-11-23T02:06:40Z	Api	成功	3074	644" \
        "$FX/ok.log	07L000000000001AAA	2026-11-23 02:06:40	Api	成功	3074	644" \
        "$FX/ok.log	07L000000000001AAA	2026-02-30T02:06:40Z	Api	成功	3074	644" \
        "$FX/ok.log	07L000000000001AAA	2026-11-23T02:06:40Z	Api	成功	3.5KB	644" \
        "	07L000000000001AAA	2026-11-23T02:06:40Z	Api	成功	3074	644"; do
        printf '%s\n' "$bad" > "$_LIST"
        _sum
        assert_exit_fail "$_RC" "形の誤り → 終了コード 1: $(printf '%s' "$bad" | cut -f2-3 | tr '\t' ' ')"
    done
    _OUT=$(node "$AJS" summarize 2>&1); _RC=$?
    assert_exit_fail "$_RC" "--list なし → 終了コード 1"
    _OUT=$(node "$AJS" nothing 2>&1); _RC=$?
    assert_exit_fail "$_RC" "知らないサブコマンド → 終了コード 1"
    rm -f "$_LIST"
}

# ------------------------------------------------------------------------------
# list（8.3）
# ------------------------------------------------------------------------------
ME18="005000000000001AAA"
OTHER="005000000000002AAA"
_lst() { _OUT=$(printf '%s' "$1" | node "$AJS" list --user "${2:-$ME18}" 2>&1); _RC=$?; }

test_list() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] list: 一覧の検査と表${CLR_RST}"
    local ok_json
    ok_json='{"status":0,"result":{"records":[
      {"attributes":{"type":"ApexLog"},"Id":"07L000000000001AAA","LogUserId":"005000000000001AAA","StartTime":"2026-11-23T02:06:40.000+0000","LogLength":3074,"DurationMilliseconds":644,"Operation":"/aura","Status":"成功"},
      {"attributes":{"type":"ApexLog"},"Id":"07L000000000002AAA","LogUserId":"005000000000002AAA","StartTime":"2026-11-23T02:06:41.000+0000","LogLength":10,"DurationMilliseconds":1,"Operation":"Api\tx","Status":"a\nb"}
    ],"totalSize":2,"done":true}}'
    _lst "$ok_json"
    assert_exit_ok "$_RC" "正しい応答を読める"
    _has "$_OUT" "07L000000000001AAA	1	2026-11-23T02:06:40Z	3074	644	/aura	成功" "自分のログ: 自分=1・日時を Z の形にする"
    _has "$_OUT" "07L000000000002AAA	0	2026-11-23T02:06:41Z	10	1	Api x	a b" "他の人のログ: 自分=0・タブと改行を空白にする"
    [[ $(printf '%s\n' "$_OUT" | wc -l | tr -d ' ') == "2" ]] && pass "1 件 1 行（改行が入らない）" || fail "1 件 1 行（改行が入らない）"
    _lst "$ok_json" "005000000000001"
    _has "$_OUT" "07L000000000001AAA	1	" "15 文字のユーザー ID でも、自分のログと分かる"
    _lst " »   Warning: update available
$ok_json"
    assert_exit_ok "$_RC" "前に sf の更新のお知らせが付いていても読める"
    _lst '{"status":0,"result":{"records":[],"totalSize":0,"done":true}}'
    assert_exit_ok "$_RC" "0 件の応答を読める"
    [[ -z "$_OUT" ]] && pass "0 件なら何も出さない" || fail "0 件なら何も出さない" "$_OUT"

    # 形の誤り（エラーの文言に、応答の値（他の人の ID など）を出さない）
    local bad
    while IFS= read -r bad; do
        _lst "$bad"
        assert_exit_fail "$_RC" "形の誤り → 終了コード 1: ${bad:0:60}"
        _hasnt "$_OUT" "$OTHER" "エラーの文言に、応答の値を出さない: ${bad:0:40}"
    done <<'EOF'
{"status":1,"name":"X","message":"005000000000002AAA"}
{"status":0,"result":{"records":"005000000000002AAA"}}
{"status":0,"result":{"records":[{"Id":"bad","LogUserId":"005000000000002AAA","StartTime":"2026-11-23T02:06:40.000+0000","LogLength":1}]}}
{"status":0,"result":{"records":[{"Id":"07L000000000001AAA","LogUserId":"005000000000002AA","StartTime":"2026-11-23T02:06:40.000+0000","LogLength":1}]}}
{"status":0,"result":{"records":[{"Id":"07L000000000001AAA","LogUserId":"005000000000002AAA","StartTime":"2026/11/23","LogLength":1}]}}
{"status":0,"result":{"records":[{"Id":"07L000000000001AAA","LogUserId":"005000000000002AAA","StartTime":"2026-11-23T02:06:40.000+0000"}]}}
not json 005000000000002AAA
EOF
    _OUT=$(printf '{}' | node "$AJS" list --user bad 2>&1); _RC=$?
    assert_exit_fail "$_RC" "--user の形の誤り → 終了コード 1"
}

# ------------------------------------------------------------------------------
# time（6.4）
# ------------------------------------------------------------------------------
_t() { _OUT=$(node "$AJS" time "$@" 2>&1); _RC=$?; }

test_time() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] time: 日時の計算${CLR_RST}"
    _t now
    [[ "$_RC" -eq 0 && "$_OUT" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && pass "now: YYYY-MM-DDTHH:MM:SSZ" || fail "now: YYYY-MM-DDTHH:MM:SSZ" "$_OUT"
    local a b
    a=$(node "$AJS" time now); b=$(node "$AJS" time now --plus-sec 120)
    _t cmp "$a" "$b"
    assert_equals "$_OUT" "-1" "now --plus-sec 120 は、今より後"
    _t norm "2026-11-23T02:04:12.000+0000"
    assert_equals "$_OUT" "2026-11-23T02:04:12Z" "norm: Salesforce の +0000 の形を Z にする"
    _t norm "2026-11-23T11:04:12+09:00"
    assert_equals "$_OUT" "2026-11-23T02:04:12Z" "norm: +09:00 を UTC に直す"
    _t norm "2026-11-23T02:04:12Z"
    assert_equals "$_OUT" "2026-11-23T02:04:12Z" "norm: Z はそのまま"
    _t cmp "2026-11-23T02:04:12Z" "2026-11-23T02:04:12.000+0000"
    assert_equals "$_OUT" "0" "cmp: 形が違っても同じ時刻なら 0"
    _t cmp "2026-11-23T02:05:00Z" "2026-11-23T02:04:12Z"
    assert_equals "$_OUT" "1" "cmp: 後なら 1"
    _t min "2026-11-23T02:34:12.000+0000" "2026-11-23T02:06:00Z"
    assert_equals "$_OUT" "2026-11-23T02:06:00Z" "min: 早いほう（元の期限と今から 2 分後の早いほう。4.2）"
    _t add "2026-11-23T02:04:12Z" --sec 1
    assert_equals "$_OUT" "2026-11-23T02:04:13Z" "add: 1 秒後（止めたものの期限の 1 秒後。4.2）"
    _t add "2026-11-23T02:04:12Z" --sec -1800
    assert_equals "$_OUT" "2026-11-23T01:34:12Z" "add: 負の秒数（直近 30 分）"
    local bad
    for bad in "2026-02-30T00:00:00Z" "2026-11-23 02:04:12" "2026-11-23T02:04:12" "x"; do
        _t norm "$bad"
        assert_exit_fail "$_RC" "norm: 形の誤り → 終了コード 1: $bad"
    done
    _t add "2026-11-23T02:04:12Z" --sec 1.5
    assert_exit_fail "$_RC" "add: 秒数が整数でない → 終了コード 1"
    _t now --plus-sec
    assert_exit_fail "$_RC" "値のないオプション → 終了コード 1"
    _t nothing
    assert_exit_fail "$_RC" "知らない time のサブコマンド → 終了コード 1"
}

test_summarize_errors
test_summarize_list_debug_limits
test_summarize_flow
test_summarize_duplicate
test_summarize_gaps
test_summarize_bad_list
test_list
test_time

print_summary
