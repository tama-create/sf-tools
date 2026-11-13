#!/bin/bash
# ==============================================================================
# test_metasync-js.sh - lib/metasync.js（sf-metasync.sh の鏡像: plan / apply / detect / fingerprint / fpcompare）の単体テスト
# ==============================================================================
# 手元（A）と取得結果（B）のフォルダを、テストの中で作り、plan の計画（TSV）と終了コード、apply の反映を確かめる。
# 設計: doc/sf-metasync-redesign.md 9.2
#
# 【テストケース】
#   1. 追加・変更・削除の判定（CRLF だけの違いは、変更にしない）
#   2. 残すファイル（.gitkeep・.forceignore に当たるファイル）・否定の行の警告
#   3. 同期の対象の外（metadata.txt にない種類のフォルダ）は、触らない／共有フォルダ（objects）
#   4. 削除の守り: S2（取得の問題の報告）・S3（消えたフォルダ）・S4（件数のしきい値の境界）・S5（直近のマージ）
#   5. S1（取得の応答の status）・S8（packageDirectories が 2 つ以上）・引数の誤り・--allow-mass-delete
#   6. apply: A・M・D の反映・H は何もしない・空になったフォルダを消す・根の外のパスは、何も変えずに中断する
#   7. detect（変更の検知）: 状態なし・変更なし・履歴あり・区分 B の変化（更新日時・件数・名前・フォルダ型）・履歴の失敗・
#      一覧の失敗・状態の破損や設定の不一致・区分 A がないときは履歴を問い合わせない・引数の誤り／区分の表の整合
#   8. fingerprint（一覧の指紋。モックの SOAP サーバー tests/mock-soap-server.js を使う）: 判定（変更なし・変更あり・不審・不明）・
#      トークンの取り直し（伏せ字・期限切れ）・応答の検証（SOAP でない・0 件の自己終了タグ）・転送の拒否・https 以外の拒否・
#      時間切れ（1 回・全体・sf の呼び出し）・失敗時の中止・まとめて問い合わせ・フォルダ上限・トークンの伏せ字
#   9. fpcompare（影の比較）: 検知できた・見逃し・日時では検知できない種類・指紋の対象外・空振り／種類の表（metasync-fingerprint.txt）の整合
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== lib/metasync.js ===${CLR_RST}"

MJS="$SF_TOOLS_DIR/lib/metasync.js"
DIRS_TABLE="$SF_TOOLS_DIR/config/metadata-dirs.txt"
ROOT="force-app/main/default"

# 作業フォルダを作る。手元（R）・取得結果（F）・種類の一覧（types.txt）・メタ（sfdx-project.json）を用意する
#   結果: 変数 _TD（作業フォルダ）。R = $_TD/r、F = $_TD/f
_mk() {
    _TD=$(mktemp -d "${TMPDIR:-/tmp}/test-msjs-XXXX")
    mkdir -p "$_TD/r/$ROOT" "$_TD/f/$ROOT"
    echo '{"packageDirectories":[{"path":"force-app","default":true}]}' > "$_TD/r/sfdx-project.json"
    printf 'ApexClass\nCustomObject\nLightningComponentBundle\n' > "$_TD/types.txt"
}
# ファイルを書く。引数: 基準（r / f）・根からのパス・内容（printf の書式。既定 x）
_w() { local p="$_TD/$1/$ROOT/$2"; mkdir -p "${p%/*}"; printf "${3:-x}" > "$p"; }
# 同じ内容のファイルをまとめて作る（フォークしない）。引数: 基準（r / f）・フォルダ・接頭辞・開始・終了
_bulk() { local d="$_TD/$1/$ROOT/$2" i; mkdir -p "$d"; for (( i = $4; i <= $5; i++ )); do printf 'x\n' > "$d/$3$i.cls"; done; }
# plan を実行する。引数: 追加のオプション。結果: $_OUT（標準出力）・$_RC・$_TD/plan.tsv
_plan() {
    _OUT=$(node "$MJS" plan --repo "$_TD/r" --fetched "$_TD/f" --types-file "$_TD/types.txt" --dirs-table "$DIRS_TABLE" \
        --out "$_TD/plan.tsv" "$@" 2>&1)
    _RC=$?
}
_op() { grep -c "^$1	" "$_TD/plan.tsv"; }   # 操作の件数（A / M / D / H）

# --- 1. 追加・変更・削除 ---
test_basic_ops() {
    echo ""; echo -e "${CLR_HEAD}[TEST] metasync.js: 追加・変更・削除${CLR_RST}"
    _mk
    _w r classes/Same.cls 'same\n';   _w f classes/Same.cls 'same\n'
    _w r classes/Mod.cls 'old\n';     _w f classes/Mod.cls 'new\n'
    _w r classes/Del.cls 'del\n'
    _w f classes/Add.cls 'add\n'
    _w r classes/Crlf.cls 'a\r\nb\r\n'; _w f classes/Crlf.cls 'a\nb\n'
    _plan
    assert_exit_ok "$_RC" "plan が成功する（保留なし → 終了コード 0）"
    assert_file_contains "$_TD/plan.tsv" "A	$ROOT/classes/Add.cls" "B だけのファイルは A（追加）"
    assert_file_contains "$_TD/plan.tsv" "M	$ROOT/classes/Mod.cls" "中身が違うファイルは M（変更）"
    assert_file_contains "$_TD/plan.tsv" "D	$ROOT/classes/Del.cls" "A だけのファイルは D（削除）"
    assert_file_not_contains "$_TD/plan.tsv" "Same.cls" "同じファイルは、計画に出ない"
    assert_file_not_contains "$_TD/plan.tsv" "Crlf.cls" "CRLF と LF の違いだけは、変更にしない"
    assert_output_contains "$_OUT" "追加 1 件 / 変更 1 件 / 削除 1 件 / 削除の保留 0 件" "要約に件数が出る"
    rm -rf "$_TD"
}

# --- 2. 残すファイル ---
test_keep_files() {
    echo ""; echo -e "${CLR_HEAD}[TEST] metasync.js: 残すファイル（.gitkeep・.forceignore）${CLR_RST}"
    _mk
    printf '**/__tests__/**\n**/jsconfig.json\n!keep-me\n# comment\n\n/force-app/ignored-root.txt\n' > "$_TD/r/.forceignore"
    _w r classes/.gitkeep ''
    _w r lwc/cmp/__tests__/a.test.js 'jest\n'
    _w r lwc/cmp/jsconfig.json '{}\n'
    _w r lwc/cmp/cmp.js 'js\n'
    _w f lwc/cmp/cmp.js 'js\n'
    _w r lwc/gone/gone.js 'gone\n'
    _plan
    assert_file_not_contains "$_TD/plan.tsv" ".gitkeep" ".gitkeep は、削除しない"
    assert_file_not_contains "$_TD/plan.tsv" "__tests__" ".forceignore に当たるファイル（__tests__）は、削除しない"
    assert_file_not_contains "$_TD/plan.tsv" "jsconfig.json" ".forceignore に当たるファイル（jsconfig.json）は、削除しない"
    assert_file_contains "$_TD/plan.tsv" "D	$ROOT/lwc/gone/gone.js" "組織にない通常のファイルは、削除する"
    assert_output_contains "$_OUT" "否定の行は、解釈しません" ".forceignore の否定の行は、警告して無視する"
    rm -rf "$_TD"
}

# --- 3. 同期の対象の外・共有フォルダ ---
test_scope() {
    echo ""; echo -e "${CLR_HEAD}[TEST] metasync.js: 同期の対象の外・共有フォルダ${CLR_RST}"
    _mk
    _w r staticresources/logo.png 'png\n'         # StaticResource は metadata.txt にない → 触らない
    _w r objects/Account/fields/Gone__c.field-meta.xml 'f\n'
    _w r objects/Account/Account.object-meta.xml 'o\n'
    _w f objects/Account/Account.object-meta.xml 'o\n'
    _w f objects/Account/fields/New__c.field-meta.xml 'n\n'
    _w r unknown/x.txt 'u\n'                       # 表にも取得結果にもないフォルダ → 触らない
    _plan
    assert_file_not_contains "$_TD/plan.tsv" "staticresources" "metadata.txt にない種類のフォルダは、触らない"
    assert_file_not_contains "$_TD/plan.tsv" "unknown/" "表にも取得結果にもないフォルダは、触らない"
    assert_file_contains "$_TD/plan.tsv" "D	$ROOT/objects/Account/fields/Gone__c.field-meta.xml" "共有フォルダ（objects）は、フォルダ単位で鏡像にする（削除）"
    assert_file_contains "$_TD/plan.tsv" "A	$ROOT/objects/Account/fields/New__c.field-meta.xml" "共有フォルダ（objects）の追加"
    rm -rf "$_TD"
}

# --- 4. 削除の守り ---
test_guards() {
    echo ""; echo -e "${CLR_HEAD}[TEST] metasync.js: 削除の守り（S2〜S5）${CLR_RST}"
    # S3: 手元に 1 件以上あったフォルダが、取得結果で 0 件
    _mk
    _w r classes/A.cls 'a\n'; _w r classes/B.cls 'b\n'; _w r lwc/c/c.js 'c\n'; _w f lwc/c/c.js 'c\n'
    _plan
    assert_equals "$_RC" "3" "S3: 消えたフォルダ → 終了コード 3"
    assert_file_contains "$_TD/plan.tsv" "H	$ROOT/classes/A.cls	S3" "S3: そのフォルダの削除は保留（H）"
    assert_equals "$(_op D)" "0" "S3: 削除（D）にならない"
    _plan --allow-mass-delete
    assert_equals "$_RC" "0" "S3: --allow-mass-delete で解ける（終了コード 0）"
    assert_file_contains "$_TD/plan.tsv" "D	$ROOT/classes/A.cls" "S3: --allow-mass-delete で削除になる"
    rm -rf "$_TD"

    # S4: しきい値 max(100, 10%) の境界（手元の対象が 150 件 → しきい値 100）
    _mk
    _bulk r classes keep 1 50; _bulk f classes keep 1 50
    _bulk r classes del 1 100
    _plan
    assert_equals "$_RC" "0" "S4: 削除が 100 件ちょうど → 保留しない"
    assert_equals "$(_op D)" "100" "S4: 100 件とも削除"
    _w r classes/del101.cls 'd\n'
    _plan
    assert_equals "$_RC" "3" "S4: 削除が 101 件 → 保留（終了コード 3）"
    assert_equals "$(_op H)" "101" "S4: 101 件すべて保留"
    assert_file_contains "$_TD/plan.tsv" "S4" "S4: 理由 S4"
    _plan --allow-mass-delete
    assert_equals "$(_op D)" "101" "S4: --allow-mass-delete で 101 件とも削除"
    rm -rf "$_TD"

    # S4: 手元が多いときは割合（10%）。1500 件のうち 150 件の削除は通り、151 件は保留
    _mk
    _bulk r classes k 1 1350; _bulk f classes k 1 1350
    _bulk r classes d 1 150
    _plan
    assert_equals "$(_op D)" "150" "S4: 手元 1500 件のうち 150 件（10%）の削除は、通る"
    _w r classes/d151.cls 'd\n'
    _plan
    assert_equals "$(_op H)" "151" "S4: 151 件（10% 超）は、保留"
    rm -rf "$_TD"

    # S5: 直近にマージされたファイル（--recent-files）。終了コードは 0（時間がたてば解ける）
    _mk
    _w r classes/Recent.cls 'r\n'; _w r classes/Old.cls 'o\n'; _w f classes/Other.cls 'x\n'
    printf '%s\n' "$ROOT/classes/Recent.cls" > "$_TD/recent.txt"
    _plan --recent-files "$_TD/recent.txt"
    assert_equals "$_RC" "0" "S5: 保留が S5 だけ → 終了コード 0"
    assert_file_contains "$_TD/plan.tsv" "H	$ROOT/classes/Recent.cls	S5" "S5: 直近のファイルの削除は保留"
    assert_file_contains "$_TD/plan.tsv" "D	$ROOT/classes/Old.cls" "S5: 直近でないファイルは、削除する"
    _plan --recent-files "$_TD/recent.txt" --allow-mass-delete
    assert_file_contains "$_TD/plan.tsv" "H	$ROOT/classes/Recent.cls	S5" "S5: --allow-mass-delete では解けない"
    rm -rf "$_TD"

    # S2: 取得の応答の問題
    _mk
    _w r classes/Gone.cls 'g\n'; _w r lwc/x/x.js 'x\n'; _w f classes/Other.cls 'o\n'
    echo '{"status":0,"result":{"messages":[{"fileName":"unpackaged/package.xml","problem":"Load of metadata from db failed for metadata of type:LightningComponentBundle and file name:x"}]}}' > "$_TD/ret.json"
    _plan --retrieve-json "$_TD/ret.json"
    assert_equals "$_RC" "3" "S2: 種類の読める問題の報告 → 終了コード 3"
    assert_file_contains "$_TD/plan.tsv" "H	$ROOT/lwc/x/x.js	S2" "S2: 報告された種類のフォルダ（lwc）の削除は保留"
    assert_file_contains "$_TD/plan.tsv" "D	$ROOT/classes/Gone.cls" "S2: 報告のない種類（classes）の削除は、そのまま"
    echo '{"status":0,"result":{"messages":[{"problem":"something unexpected"}]}}' > "$_TD/ret.json"
    _plan --retrieve-json "$_TD/ret.json"
    assert_equals "$(_op D)" "0" "S2: 種類が読めない報告 → その回の削除は、すべて保留"
    assert_file_contains "$_TD/plan.tsv" "H	$ROOT/classes/Gone.cls	S2" "S2: 種類が読めない報告 → 保留（S2）"
    echo 'not json' > "$_TD/ret.json"
    _plan --retrieve-json "$_TD/ret.json"
    assert_file_contains "$_TD/plan.tsv" "D	$ROOT/classes/Gone.cls" "応答が JSON でないときは、情報なしとして扱う"
    rm -rf "$_TD"

    # S2: 「この組織・この API バージョンでは使えない種類」の報告（取得の失敗ではない。実機の応答の形）
    #   表（metadata-dirs.txt）にない種類（GlobalPicklist）→ 保留しない。表にある種類（LightningComponentBundle）→ そのフォルダだけ保留
    #   （lwc は、取得結果にも 1 件ある前提にする。0 件だと、S3（消えたフォルダ）が当たってしまい、S2 の確認にならない）
    _mk
    _w r classes/Gone.cls 'g\n'; _w r lwc/x/x.js 'x\n'; _w f classes/Other.cls 'o\n'; _w f lwc/y/y.js 'y\n'
    echo '{"status":0,"result":{"messages":[{"problem":"Entity type '"'"'GlobalPicklist'"'"' is not available in this api version"},{"problem":"Entity type '"'"'Translations'"'"' is not available in this organization"}]}}' > "$_TD/ret.json"
    _plan --retrieve-json "$_TD/ret.json"
    assert_equals "$_RC" "0" "S2: 使えない種類（表にない）の報告だけ → 保留なし（終了コード 0）"
    assert_file_contains "$_TD/plan.tsv" "D	$ROOT/classes/Gone.cls" "S2: 使えない種類（表にない）の報告では、削除を保留しない"
    assert_file_contains "$_TD/plan.tsv" "D	$ROOT/lwc/x/x.js" "S2: 使えない種類（表にない）の報告では、他のフォルダの削除も保留しない"
    assert_output_contains "$_OUT" "使えない種類" "S2: 使えない種類は、要約に出る（見逃さない）"
    echo '{"status":0,"result":{"messages":[{"problem":"Entity type '"'"'LightningComponentBundle'"'"' is not available in this organization"}]}}' > "$_TD/ret.json"
    _plan --retrieve-json "$_TD/ret.json"
    assert_equals "$_RC" "3" "S2: 使えない種類（表にある）の報告 → 終了コード 3"
    assert_file_contains "$_TD/plan.tsv" "H	$ROOT/lwc/x/x.js	S2" "S2: 使えない種類（表にある）は、そのフォルダ（lwc）だけ保留"
    assert_file_contains "$_TD/plan.tsv" "D	$ROOT/classes/Gone.cls" "S2: 使えない種類の報告があっても、他のフォルダ（classes）の削除は、そのまま"
    echo '{"status":0,"result":{"messages":[{"problem":"Entity type '"'"'GlobalPicklist'"'"' is not available in this api version"},{"problem":"something unexpected"}]}}' > "$_TD/ret.json"
    _plan --retrieve-json "$_TD/ret.json"
    assert_equals "$(_op D)" "0" "S2: 使えない種類と、読めない報告が混在 → 読めない報告のぶん、その回の削除は、すべて保留"
    assert_file_contains "$_TD/plan.tsv" "H	$ROOT/classes/Gone.cls	S2" "S2: 混在 → 保留（S2）"
    rm -rf "$_TD"

    # 表示: 使えない種類は、重複を除いて、名前を省略せずに、1 行にまとめる（種類ごとに 1 行ずつ出さない）
    _mk
    _w r classes/Gone.cls 'g\n'; _w f classes/Other.cls 'o\n'
    echo '{"status":0,"result":{"messages":[{"problem":"Entity type '"'"'GlobalPicklist'"'"' is not available in this api version"},{"problem":"Entity type '"'"'Translations'"'"' is not available in this organization"},{"problem":"Entity type '"'"'GlobalPicklist'"'"' is not available in this organization"}]}}' > "$_TD/ret.json"
    _plan --retrieve-json "$_TD/ret.json"
    assert_output_contains "$_OUT" "使えない種類が 2 個あります" "表示: 使えない種類は、重複を除いた個数を出す"
    assert_output_contains "$_OUT" "GlobalPicklist、Translations" "表示: 使えない種類は、名前を省略せずに、1 行に並べる"
    assert_equals "$(printf '%s\n' "$_OUT" | grep -c '使えない種類')" "1" "表示: 使えない種類は、1 行だけ（種類ごとに出さない）"
    rm -rf "$_TD"

    # 表示: 表（metadata-dirs.txt）にない種類の警告も、重複を除いて、1 行にまとめる（先頭は [WARNING]）
    _mk
    printf 'ApexClass\nNoSuchTypeA\nNoSuchTypeB\nNoSuchTypeA\n' > "$_TD/types.txt"
    _w r classes/Same.cls 's\n'; _w f classes/Same.cls 's\n'
    _plan
    assert_output_contains "$_OUT" "^\\[WARNING\\] 表（--dirs-table）にない種類が 2 個あります" "表示: 表にない種類は、重複を除いた個数を、警告の 1 行に出す（行頭が [WARNING]）"
    assert_output_contains "$_OUT" "NoSuchTypeA、NoSuchTypeB" "表示: 表にない種類は、名前を省略せずに、1 行に並べる"
    assert_equals "$(printf '%s\n' "$_OUT" | grep -c '表（--dirs-table）にない種類')" "1" "表示: 表にない種類の警告は、1 行だけ"
    rm -rf "$_TD"
}

# --- 5. 中断する条件・引数 ---
test_aborts() {
    echo ""; echo -e "${CLR_HEAD}[TEST] metasync.js: 中断する条件（S1・S8・引数）${CLR_RST}"
    _mk
    _w r classes/A.cls 'a\n'
    echo '{"status":1,"result":{}}' > "$_TD/ret.json"
    _plan --retrieve-json "$_TD/ret.json"
    assert_equals "$_RC" "1" "S1: 取得の応答の status が 0 以外 → 中断（終了コード 1）"
    assert_output_contains "$_OUT" "S1" "S1: 理由が出る"
    rm -f "$_TD/plan.tsv"
    echo '{"packageDirectories":[{"path":"force-app"},{"path":"other"}]}' > "$_TD/r/sfdx-project.json"
    _plan
    assert_equals "$_RC" "1" "S8: packageDirectories が 2 つ → 中断"
    assert_output_contains "$_OUT" "S8" "S8: 理由が出る"
    assert_file_not_contains "$_TD/plan.tsv" "x" "S8: 計画を書かない" 2>/dev/null || true
    rm -f "$_TD/r/sfdx-project.json"
    _plan
    assert_equals "$_RC" "1" "sfdx-project.json がない → 中断"
    out=$(node "$MJS" bogus 2>&1); assert_exit_fail $? "不明なコマンド → 中断"
    out=$(node "$MJS" plan --bogus 2>&1); assert_exit_fail $? "不明なオプション → 中断"
    out=$(node "$MJS" plan --repo 2>&1); assert_exit_fail $? "値のないオプション → 中断"
    out=$(node "$MJS" plan --repo x 2>&1); assert_exit_fail $? "必須のオプション不足 → 中断"
    rm -rf "$_TD"
}

# --- 6. apply ---
test_apply() {
    echo ""; echo -e "${CLR_HEAD}[TEST] metasync.js: apply${CLR_RST}"
    _mk
    _w r classes/Mod.cls 'old\n'; _w f classes/Mod.cls 'new\n'
    _w r classes/Del.cls 'del\n'
    _w f classes/Add.cls 'add\n'
    _w r lwc/gone/gone.js 'gone\n'; _w f classes/Other.cls 'o\n'
    _w r pages/Held.page 'held\n'
    printf 'A\t%s\t\nM\t%s\t\nD\t%s\t\nD\t%s\t\nH\t%s\tS4\n' \
        "$ROOT/classes/Add.cls" "$ROOT/classes/Mod.cls" "$ROOT/classes/Del.cls" "$ROOT/lwc/gone/gone.js" "$ROOT/pages/Held.page" > "$_TD/p.tsv"
    local out; out=$(node "$MJS" apply --plan "$_TD/p.tsv" --repo "$_TD/r" --fetched "$_TD/f" 2>&1); local rc=$?
    assert_exit_ok "$rc" "apply が成功する"
    assert_output_contains "$out" "追加 1 件 / 変更 1 件 / 削除 2 件" "apply: 件数が出る"
    assert_file_contains "$_TD/r/$ROOT/classes/Add.cls" "add" "A: 追加された"
    assert_file_contains "$_TD/r/$ROOT/classes/Mod.cls" "new" "M: 上書きされた"
    [[ ! -e "$_TD/r/$ROOT/classes/Del.cls" ]] && pass "D: 削除された" || fail "D: 削除された"
    [[ ! -e "$_TD/r/$ROOT/lwc" ]] && pass "D: 空になったフォルダ（lwc/gone・lwc）は、根の直下まで消える" || fail "D: 空になったフォルダは消える"
    [[ -d "$_TD/r/$ROOT" ]] && pass "D: 根（force-app/main/default）は、残る" || fail "D: 根は残る"
    assert_file_contains "$_TD/r/$ROOT/pages/Held.page" "held" "H: 保留したファイルは、そのまま残る"

    # 根の外を指すパス → 何も変えずに中断（先に全部検査する）
    printf 'A\t%s\t\nA\t%s\t\n' "$ROOT/classes/Add2.cls" "force-app/../../evil.txt" > "$_TD/p2.tsv"
    _w f classes/Add2.cls 'add2\n'
    out=$(node "$MJS" apply --plan "$_TD/p2.tsv" --repo "$_TD/r" --fetched "$_TD/f" 2>&1); rc=$?
    assert_equals "$rc" "1" "根の外を指すパス → 中断（終了コード 1）"
    [[ ! -e "$_TD/r/$ROOT/classes/Add2.cls" ]] && pass "根の外を指すパスがあるとき、ほかの行も反映しない（半端に反映しない）" || fail "根の外を指すパスがあるとき、ほかの行も反映しない"
    printf 'X\t%s\t\n' "$ROOT/classes/Add2.cls" > "$_TD/p3.tsv"
    out=$(node "$MJS" apply --plan "$_TD/p3.tsv" --repo "$_TD/r" --fetched "$_TD/f" 2>&1); assert_exit_fail $? "不正な操作 → 中断"
    rm -rf "$_TD"
}

# --- 7. detect（変更の検知）---
#   sf は、モック（SF_METASYNC_SF で差し替え。一覧は MOCK_SF_LIST_DIR の JSON、履歴の件数は MOCK_SF_AUDIT_COUNT）。
#   種類の表は、本物（config/metasync-detect.txt）を使う: ApexClass = A（履歴）／ ReportType・Report = B（一覧。Report はフォルダ型）
DETECT_TABLE="$SF_TOOLS_DIR/config/metasync-detect.txt"
# 準備: 作業フォルダ（$_DD）に、モックの sf・種類の一覧・一覧の JSON のフォルダ（lists）を作る
_det_mk() {
    _DD=$(mktemp -d "${TMPDIR:-/tmp}/test-msdet-XXXX")
    mkdir -p "$_DD/bin" "$_DD/lists"
    create_mock_sf "$_DD/bin"
    printf 'ApexClass\nReportType\nReport\nCustomLabels\n' > "$_DD/types.txt"
    echo '[{"fullName":"RT1","lastModifiedDate":"2026-11-01T01:00:00.000Z"}]' > "$_DD/lists/ReportType.json"
    echo '[{"fullName":"F1","lastModifiedDate":"2026-11-01T01:00:00.000Z"}]' > "$_DD/lists/ReportFolder.json"
    echo '[{"fullName":"F1/R1","lastModifiedDate":"2026-11-01T02:00:00.000Z"}]' > "$_DD/lists/Report__F1.json"
    echo '[]' > "$_DD/lists/Report__unfiled__public.json"
}
# detect を実行する。引数: 追加のオプション。環境変数 MOCK_SF_*（呼び出し側で指定）。結果: $_OUT・$_RC・$_DD/new.json
_det() {
    rm -f "$_DD/new.json"
    _OUT=$(SF_METASYNC_SF="bash $_DD/bin/sf" MOCK_SF_LIST_DIR="$_DD/lists" MOCK_CALL_LOG="$_DD/calls.log" \
        node "$MJS" detect --org prod --types-file "$_DD/types.txt" --table "$DETECT_TABLE" --state "$_DD/state.json" \
        --out-state "$_DD/new.json" --now 2026-11-02T00:00:00Z "$@" 2>&1)
    _RC=$?
}

test_detect() {
    echo ""; echo -e "${CLR_HEAD}[TEST] metasync.js: detect（変更の検知）${CLR_RST}"
    _det_mk
    # 状態がない → 不明（11）。今回の状態を書く（区分 B の記録を含む）
    _det
    assert_equals "$_RC" "11" "状態がない → 不明（終了コード 11）"
    assert_output_contains "$_OUT" "前回の状態がありません" "状態がない理由が出る"
    assert_output_contains "$_OUT" "A 1 種類（履歴）/ B 2 種類（更新日時の一覧）/ C 1 種類" "区分ごとの種類の数が出る（CustomLabels は表にない = C）"
    assert_file_contains "$_DD/new.json" '"lastFullSyncAt": "2026-11-02T00:00:00Z"' "今回の状態に、開始時刻が入る"
    assert_file_contains "$_DD/new.json" '"ReportType"' "今回の状態に、区分 B の種類が入る"
    assert_file_contains "$_DD/new.json" '"count": 2' "フォルダ型（Report）は、フォルダ自身と、中の部品を合わせて数える"

    # 前回と同じ → 変更なし（0）。状態は書かない。履歴の問い合わせは 1 回
    cp "$_DD/new.json" "$_DD/state.json"
    _det
    assert_equals "$_RC" "0" "前回と同じ・履歴 0 件 → 変更なし（終了コード 0）"
    assert_output_contains "$_OUT" "変更なし" "変更なしと表示される"
    [[ ! -f "$_DD/new.json" ]] && pass "変更なしのときは、状態を書かない" || fail "変更なしのときは、状態を書かない"
    assert_equals "$(grep -c 'SetupAuditTrail' "$_DD/calls.log")" "1" "履歴の問い合わせは 1 回"
    assert_file_contains "$_DD/calls.log" "2026-11-01T23:50:00Z" "履歴の基準は、前回の開始時刻の 10 分前"

    # 履歴に記録がある → 変更あり（10）
    MOCK_SF_AUDIT_COUNT=3 _det
    assert_equals "$_RC" "10" "履歴に記録がある → 変更あり（終了コード 10）"
    assert_output_contains "$_OUT" "履歴に 3 件" "履歴の件数が理由に出る"
    [[ -f "$_DD/new.json" ]] && pass "変更ありのときは、状態を書く" || fail "変更ありのときは、状態を書く"

    # 区分 B: 更新日時が進んだ・件数が変わった・名前が変わった → 変更あり
    echo '[{"fullName":"RT1","lastModifiedDate":"2026-11-01T05:00:00.000Z"}]' > "$_DD/lists/ReportType.json"
    _det
    assert_equals "$_RC" "10" "区分 B の更新日時が進んだ → 変更あり"
    assert_output_contains "$_OUT" "ReportType: 更新日時が変わりました" "更新日時の変化が理由に出る"
    echo '[{"fullName":"RT1","lastModifiedDate":"2026-11-01T01:00:00.000Z"},{"fullName":"RT2","lastModifiedDate":"2026-10-01T00:00:00.000Z"}]' > "$_DD/lists/ReportType.json"
    _det
    assert_output_contains "$_OUT" "ReportType: 件数が変わりました（1 → 2）" "件数の変化が理由に出る"
    echo '[{"fullName":"RT9","lastModifiedDate":"2026-11-01T01:00:00.000Z"}]' > "$_DD/lists/ReportType.json"
    _det
    assert_output_contains "$_OUT" "ReportType: 名前が変わりました" "名前の変化（件数・更新日時は同じ）が理由に出る"
    echo '[{"fullName":"RT1","lastModifiedDate":"2026-11-01T01:00:00.000Z"}]' > "$_DD/lists/ReportType.json"

    # フォルダ型: フォルダの中の部品が変わった → 変更あり
    echo '[{"fullName":"F1/R1","lastModifiedDate":"2026-11-01T09:00:00.000Z"}]' > "$_DD/lists/Report__F1.json"
    _det
    assert_equals "$_RC" "10" "フォルダの中の部品の更新日時が進んだ → 変更あり"
    assert_output_contains "$_OUT" "Report: 更新日時が変わりました" "フォルダ型の変化が理由に出る"
    echo '[{"fullName":"F1/R1","lastModifiedDate":"2026-11-01T02:00:00.000Z"}]' > "$_DD/lists/Report__F1.json"

    # 履歴の問い合わせの失敗 → 不明（11）。一覧は取れているので、状態は書く
    MOCK_SF_AUDIT_EXIT=1 _det
    assert_equals "$_RC" "11" "履歴の問い合わせの失敗 → 不明（終了コード 11）"
    assert_output_contains "$_OUT" "履歴の問い合わせに失敗" "失敗の理由が出る"
    [[ -f "$_DD/new.json" ]] && pass "履歴の失敗でも、一覧が取れていれば状態を書く（全件取得の基準にする）" || fail "履歴の失敗でも、一覧が取れていれば状態を書く"

    # 一覧の失敗 → 不明（11）。状態は書かない
    MOCK_SF_LIST_FAIL=ReportType _det
    assert_equals "$_RC" "11" "一覧の取得の失敗 → 不明（終了コード 11）"
    assert_output_contains "$_OUT" "更新日時の一覧を取得できませんでした" "一覧の失敗の理由が出る"
    [[ ! -f "$_DD/new.json" ]] && pass "一覧が取れないときは、状態を書かない" || fail "一覧が取れないときは、状態を書かない"

    # 状態が使えない（壊れている・設定が違う）→ 不明
    echo '{broken' > "$_DD/state.json"; _det
    assert_equals "$_RC" "11" "状態が壊れている → 不明"
    assert_output_contains "$_OUT" "読めません" "壊れている理由が出る"
    cp "$_DD/new.json" "$_DD/state.json"
    printf 'ApexClass\nReportType\n' > "$_DD/types.txt"; _det
    assert_equals "$_RC" "11" "種類の一覧（metadata.txt）が変わった → 不明（設定のハッシュが合わない）"
    assert_output_contains "$_OUT" "版または設定" "設定の不一致の理由が出る"

    # 区分 A の種類がなければ、履歴は問い合わせない
    printf 'ReportType\n' > "$_DD/types.txt"; rm -f "$_DD/state.json"; _det; cp "$_DD/new.json" "$_DD/state.json"
    : > "$_DD/calls.log"; _det
    assert_equals "$_RC" "0" "区分 A の種類がなく、B も同じ → 変更なし"
    assert_equals "$(grep -c 'SetupAuditTrail' "$_DD/calls.log")" "0" "区分 A の種類がなければ、履歴は問い合わせない"

    # 引数の誤り
    out=$(node "$MJS" detect --org prod 2>&1); assert_equals "$?" "1" "detect の必須オプションがない → 中断（終了コード 1）"
    out=$(node "$MJS" detect --org prod --types-file "$_DD/types.txt" --table "$DETECT_TABLE" --state "$_DD/state.json" --out-state "$_DD/n.json" --now bad 2>&1)
    assert_equals "$?" "1" "--now が日時でない → 中断"
    rm -rf "$_DD"
}

# 区分の表（config/metasync-detect.txt）の整合: 書式が正しく、A・B に重複がなく、metadata-dirs.txt にない種類を書いていない
test_detect_table() {
    echo ""; echo -e "${CLR_HEAD}[TEST] config/metasync-detect.txt: 書式と整合${CLR_RST}"
    local bad dup unknown
    bad=$(grep -v -E '^\s*(#.*)?$' "$DETECT_TABLE" | grep -v -E '^[AB] [A-Za-z0-9_]+\s*(#.*)?$')
    [[ -z "$bad" ]] && pass "すべての行が「A|B 種類名」の書式" || fail "書式が正しくない行: $bad"
    dup=$(grep -E '^[AB] ' "$DETECT_TABLE" | awk '{print $2}' | sort | uniq -d)
    [[ -z "$dup" ]] && pass "同じ種類が、2 回書かれていない" || fail "重複: $dup"
    unknown=$(grep -E '^[AB] ' "$DETECT_TABLE" | awk '{print $2}' | while read -r t; do grep -q "^$t " "$DIRS_TABLE" || echo "$t"; done)
    [[ -z "$unknown" ]] && pass "表の種類は、すべて metadata-dirs.txt にある" || fail "metadata-dirs.txt にない種類: $unknown"
}

# --- 8. fingerprint（一覧の指紋。設計 16 章の P1）---
#   Metadata API は、モックのサーバー（tests/mock-soap-server.js。127.0.0.1 のランダムなポート。データの JSON を書き換えて挙動を変える）。
#   sf は、モック（org display が、アクセストークンと、モックのサーバーの URL を返す。org auth show-access-token は、取り直したトークン）。
FP_SERVER_PID=""
_fp_server_start() {   # $_FD に、サーバーのデータ・ポート・リクエストの記録を置く。結果: $_FD/port.txt
    node "$SF_TOOLS_DIR/tests/mock-soap-server.js" "$_FD/data.json" "$_FD/port.txt" "$_FD/requests.log" &   # & はバックグラウンド起動（run 不使用の例外）
    FP_SERVER_PID=$!
    local i; for i in $(seq 1 100); do [[ -s "$_FD/port.txt" ]] && break; sleep 0.1; done
    [[ -s "$_FD/port.txt" ]] || fail "モックの SOAP サーバーが起動しなかった（10 秒待った）"
    trap '_fp_server_stop; rm -rf "$_FD"' EXIT   # テストが途中で止まっても、モックのサーバーを残さない
}
_fp_server_stop() { [[ -n "$FP_SERVER_PID" ]] && { kill "$FP_SERVER_PID" 2>/dev/null; wait "$FP_SERVER_PID" 2>/dev/null; }; FP_SERVER_PID=""; }
# 準備: 作業フォルダ（$_FD）に、モックの sf・種類の表（fp.txt）・リポジトリ（repo。sfdx-project.json）・サーバーのデータを作り、サーバーを起動する
_fp_mk() {
    _FD=$(mktemp -d "${TMPDIR:-/tmp}/test-msfp-XXXX")
    mkdir -p "$_FD/bin" "$_FD/repo"
    create_mock_sf "$_FD/bin"
    echo '{"packageDirectories":[{"path":"force-app","default":true}]}' > "$_FD/repo/sfdx-project.json"
    cat > "$_FD/fp.txt" << 'EOF'
ApexClass
CustomField  dir=objects
ReportType
Report       folder=ReportFolder unfiled=unfiled$public dir=reports
Gone
EOF
    cat > "$_FD/data.json" << 'EOF'
{"validToken":"TESTTOKEN","lists":{
 "ApexClass":[{"fullName":"A1","lastModifiedDate":"2026-11-01T01:00:00.000Z"},{"fullName":"A2","lastModifiedDate":"2026-11-01T02:00:00.000Z"}],
 "CustomField":[{"fullName":"Account.F1__c","lastModifiedDate":"2026-11-01T03:00:00.000Z"}],
 "ReportType":[{"fullName":"RT1","lastModifiedDate":"2026-11-01T04:00:00.000Z"}],
 "ReportFolder":[{"fullName":"F1","lastModifiedDate":"2026-11-01T05:00:00.000Z"}],
 "Report|F1":[{"fullName":"F1/R1","lastModifiedDate":"2026-11-01T06:00:00.000Z"}],
 "Report|unfiled$public":[],
 "Gone":{"fault":"INVALID_TYPE: Cannot use: Gone in this organization"}}}
EOF
    : > "$_FD/requests.log"
    _fp_server_start
    _FD_PORT=$(cat "$_FD/port.txt")
    _FD_ORG="{\"status\":0,\"result\":{\"accessToken\":\"TESTTOKEN\",\"instanceUrl\":\"http://127.0.0.1:${_FD_PORT}\"}}"
}
# サーバーのデータを書き換える。引数: キー（lists の下。"ApexClass"・"Report|F1" など）・JSON の値
_fp_set() {
    node -e 'const fs=require("fs");const f=process.argv[1],k=process.argv[2],v=process.argv[3];const d=JSON.parse(fs.readFileSync(f,"utf8"));d.lists=d.lists||{};d.lists[k]=JSON.parse(v);fs.writeFileSync(f,JSON.stringify(d));' "$_FD/data.json" "$1" "$2"
}
_fp_token() {   # サーバーが受け付けるトークンを変える（セッション切れの再現）
    node -e 'const fs=require("fs");const f=process.argv[1];const d=JSON.parse(fs.readFileSync(f,"utf8"));d.validToken=process.argv[2];fs.writeFileSync(f,JSON.stringify(d));' "$_FD/data.json" "$1"
}
# fingerprint を実行する。引数: 追加のオプション。環境変数 MOCK_SF_*（呼び出し側で指定）。結果: $_OUT・$_RC・$_FD/new.json・$_FD/report.json
_fp() {
    rm -f "$_FD/new.json" "$_FD/report.json"
    _OUT=$(SF_METASYNC_SF="bash $_FD/bin/sf" MOCK_CALL_LOG="$_FD/calls.log" MOCK_SF_ORG_JSON="$_FD_ORG" \
        node "$MJS" fingerprint --org prod --fp-config "$_FD/fp.txt" --state "$_FD/state.json" --out-state "$_FD/new.json" \
        --out-report "$_FD/report.json" --repo "$_FD/repo" --now 2026-11-02T00:00:00Z "$@" 2>&1)
    _RC=$?
}
_fp_json() { node -e 'const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(eval("j."+process.argv[2]))' "$1" "$2"; }

test_fingerprint() {
    echo ""; echo -e "${CLR_HEAD}[TEST] metasync.js: fingerprint（一覧の指紋）${CLR_RST}"
    _fp_mk
    # 状態がない → 不明（11）。今回の状態と、種類ごとの結果を書く。フォルダ型は、フォルダを先に一覧し、フォルダごとに部品を一覧する
    _fp
    assert_equals "$_RC" "11" "指紋: 状態がない → 不明（終了コード 11）"
    assert_output_contains "$_OUT" "前回の指紋がありません" "状態がない理由が出る"
    assert_output_contains "$_OUT" "指紋: 5 種類（使える 4 / この組織では使えない 1）" "種類の数と、使えない種類（INVALID_TYPE）の数が出る"
    assert_output_not_contains "$_OUT" "TESTTOKEN" "アクセストークンは、出力に出さない"
    assert_file_contains "$_FD/new.json" '"count": 2' "今回の状態に、種類ごとの件数が入る"
    assert_file_contains "$_FD/new.json" '"unavailable": true' "使えない種類は、「使えない」として記録する"
    assert_equals "$(_fp_json "$_FD/report.json" verdict)" "11" "結果の JSON に、判定が入る"
    assert_equals "$(_fp_json "$_FD/report.json" 'types.ApexClass.status')" "new" "状態がないときは、種類ごとに new"
    assert_file_contains "$_FD/requests.log" 'ReportFolder||TESTTOKEN|64.0' "フォルダ型: フォルダの種類を先に一覧する（API バージョンは既定 64.0）"
    assert_file_contains "$_FD/requests.log" 'Report|F1|TESTTOKEN' "フォルダ型: フォルダごとに部品を一覧する"
    assert_file_contains "$_FD/requests.log" 'Report|unfiled$public|TESTTOKEN' "フォルダ型: フォルダに入っていない部品の置き場所も一覧する"
    assert_equals "$(grep -c '^ApexClass|' "$_FD/requests.log")" "1" "1 種類の一覧は 1 回"
    # 前回と同じ → 変更なし（0）。状態は書かない
    cp "$_FD/new.json" "$_FD/state.json"
    _fp
    assert_equals "$_RC" "0" "前回と同じ → 変更なし（終了コード 0）"
    assert_output_contains "$_OUT" "変更なし" "変更なしと表示される"
    [[ ! -f "$_FD/new.json" ]] && pass "変更なしのときは、状態を書かない" || fail "変更なしのときは、状態を書かない"
    assert_equals "$(_fp_json "$_FD/report.json" 'types.ApexClass.status')" "unchanged" "種類ごとの結果: unchanged"
    assert_equals "$(_fp_json "$_FD/report.json" 'types.Gone.status')" "unavailable" "使えない種類のまま: unavailable（変更にしない）"
    # 更新日時が進んだ・件数が変わった → 変更あり（10）
    _fp_set ApexClass '[{"fullName":"A1","lastModifiedDate":"2026-11-01T09:00:00.000Z"},{"fullName":"A2","lastModifiedDate":"2026-11-01T02:00:00.000Z"}]'
    _fp
    assert_equals "$_RC" "10" "更新日時が進んだ → 変更あり（終了コード 10）"
    assert_output_contains "$_OUT" "ApexClass（件数 2 → 2）" "変わった種類が出る"
    [[ -f "$_FD/new.json" ]] && pass "変更ありのときは、状態を書く" || fail "変更ありのときは、状態を書く"
    assert_equals "$(_fp_json "$_FD/report.json" 'types.ApexClass.status')" "changed" "種類ごとの結果: changed"
    assert_equals "$(_fp_json "$_FD/report.json" 'types.ReportType.status')" "unchanged" "ほかの種類は unchanged"
    _fp_set ApexClass '[{"fullName":"A1","lastModifiedDate":"2026-11-01T01:00:00.000Z"},{"fullName":"A2","lastModifiedDate":"2026-11-01T02:00:00.000Z"},{"fullName":"A3","lastModifiedDate":"2026-11-01T03:00:00.000Z"}]'
    _fp
    assert_output_contains "$_OUT" "ApexClass（件数 2 → 3）" "件数の変化が出る"
    # 管理パッケージ本体の部品（installed）は、指紋に入れない
    _fp_set ApexClass '[{"fullName":"A1","lastModifiedDate":"2026-11-01T01:00:00.000Z"},{"fullName":"A2","lastModifiedDate":"2026-11-01T02:00:00.000Z"},{"fullName":"ns__P1","lastModifiedDate":"2026-11-01T09:00:00.000Z","manageableState":"installed"}]'
    _fp
    assert_equals "$_RC" "0" "管理パッケージ本体（installed）の部品が増えても、変更なし"
    # フォルダ型: フォルダの中の部品が変わった・フォルダに入っていない部品が増えた → 変更あり
    _fp_set 'Report|F1' '[{"fullName":"F1/R1","lastModifiedDate":"2026-11-01T09:00:00.000Z"}]'
    _fp
    assert_equals "$_RC" "10" "フォルダの中の部品の更新日時が進んだ → 変更あり"
    assert_output_contains "$_OUT" "Report（" "フォルダ型の変化が出る"
    _fp_set 'Report|F1' '[{"fullName":"F1/R1","lastModifiedDate":"2026-11-01T06:00:00.000Z"}]'
    _fp_set 'Report|unfiled$public' '[{"fullName":"unfiled$public/R9","lastModifiedDate":"2026-11-01T06:00:00.000Z"}]'
    _fp
    assert_equals "$_RC" "10" "フォルダに入っていない部品が増えた → 変更あり"
    _fp_set 'Report|unfiled$public' '[]'
    # 使えなかった種類が、使えるようになった → 変更あり
    _fp_set Gone '[{"fullName":"G1","lastModifiedDate":"2026-11-01T06:00:00.000Z"}]'
    _fp
    assert_equals "$_RC" "10" "使えなかった種類が、使えるようになった → 変更あり"
    assert_output_contains "$_OUT" "Gone（件数 - → 1）" "使えるようになった種類が出る"
    _fp_set Gone '{"fault":"INVALID_TYPE: Cannot use: Gone in this organization"}'
    # 件数が半分以下に減った（前回が 4 件以上）→ 不審 → 不明（11）。一覧が欠けた回に、全件取得へ倒す
    _fp_set ApexClass '[{"fullName":"A1","lastModifiedDate":"2026-11-01T01:00:00.000Z"},{"fullName":"A2","lastModifiedDate":"2026-11-01T01:00:00.000Z"},{"fullName":"A3","lastModifiedDate":"2026-11-01T01:00:00.000Z"},{"fullName":"A4","lastModifiedDate":"2026-11-01T01:00:00.000Z"},{"fullName":"A5","lastModifiedDate":"2026-11-01T01:00:00.000Z"},{"fullName":"A6","lastModifiedDate":"2026-11-01T01:00:00.000Z"}]'
    _fp; cp "$_FD/new.json" "$_FD/state.json"
    _fp_set ApexClass '[{"fullName":"A1","lastModifiedDate":"2026-11-01T01:00:00.000Z"},{"fullName":"A2","lastModifiedDate":"2026-11-01T01:00:00.000Z"}]'
    _fp
    assert_equals "$_RC" "11" "件数が前回の半分以下 → 不明（終了コード 11）"
    assert_output_contains "$_OUT" "ApexClass（6 → 2）" "不審な種類と件数が出る"
    assert_output_contains "$_OUT" "\[WARNING\] 不明: 件数が前回の半分以下" "不審は、WARNING で出る（一覧が欠けた疑い）"
    assert_equals "$(_fp_json "$_FD/report.json" 'types.ApexClass.status')" "suspect" "種類ごとの結果: suspect"
    [[ -f "$_FD/new.json" ]] && pass "不審でも、一覧が取れていれば状態を書く（全件取得の基準にする）" || fail "不審でも、一覧が取れていれば状態を書く"
    # 前回が 4 件未満なら、減っても疑わない（状態は、件数 2 のものにしてから、1 件に減らす）
    cp "$_FD/new.json" "$_FD/state.json"
    _fp_set ApexClass '[{"fullName":"A1","lastModifiedDate":"2026-11-01T01:00:00.000Z"}]'; _fp
    assert_equals "$_RC" "10" "前回が 4 件未満なら、半分に減っても不審にしない（変更あり）"
    # 一覧の失敗（INVALID_TYPE 以外の Fault・HTTP エラー）→ 不明（11）。状態は書かない
    _fp_set ReportType '{"fault":"UNKNOWN_EXCEPTION: boom"}'
    _fp
    assert_equals "$_RC" "11" "一覧の取得の失敗（Fault）→ 不明（終了コード 11）"
    assert_output_contains "$_OUT" "一覧の取得に失敗した種類があります" "失敗の理由が出る"
    assert_output_contains "$_OUT" "ReportType" "失敗した種類が出る"
    [[ ! -f "$_FD/new.json" ]] && pass "一覧が取れないときは、状態を書かない" || fail "一覧が取れないときは、状態を書かない"
    assert_equals "$(_fp_json "$_FD/report.json" verdict)" "11" "失敗のときも、結果の JSON に判定を書く（影の比較が、比べない）"
    _fp_set ReportType '{"http":503}'
    _fp
    assert_equals "$_RC" "11" "一覧の取得の失敗（HTTP 503）→ 不明"
    assert_output_contains "$_OUT" "HTTP 503" "HTTP のエラーが出る"
    _fp_set ReportType '[{"fullName":"RT1","lastModifiedDate":"2026-11-01T04:00:00.000Z"}]'
    # 状態が使えない（壊れている・種類の表が違う・API バージョンが違う）→ 不明
    echo '{broken' > "$_FD/state.json"; _fp
    assert_equals "$_RC" "11" "状態が壊れている → 不明"
    assert_output_contains "$_OUT" "前回の指紋を読めません" "壊れている理由が出る"
    rm -f "$_FD/state.json"; _fp; cp "$_FD/new.json" "$_FD/state.json"
    _fp; assert_equals "$_RC" "0" "状態を作り直せば、同じ内容は変更なし"
    cp "$_FD/fp.txt" "$_FD/fp.orig"; echo 'Gone2' >> "$_FD/fp.txt"; _fp
    assert_equals "$_RC" "11" "種類の表が変わった → 不明（設定のハッシュが合わない）"
    assert_output_contains "$_OUT" "版または設定" "設定の不一致の理由が出る"
    cp "$_FD/fp.orig" "$_FD/fp.txt"
    echo '{"packageDirectories":[{"path":"force-app"}],"sourceApiVersion":"63.0"}' > "$_FD/repo/sfdx-project.json"
    : > "$_FD/requests.log"; _fp
    assert_equals "$_RC" "11" "API バージョンが変わった → 不明（指紋は、API バージョンごと）"
    assert_file_contains "$_FD/requests.log" '|63.0' "API バージョンは、sfdx-project.json の sourceApiVersion"
    echo '{"packageDirectories":[{"path":"force-app"}]}' > "$_FD/repo/sfdx-project.json"
    # 引数・設定の誤り
    local out
    out=$(node "$MJS" fingerprint --org prod 2>&1); assert_equals "$?" "1" "fingerprint の必須オプションがない → 中断（終了コード 1）"
    out=$(node "$MJS" fingerprint --org prod --fp-config "$_FD/fp.txt" --state "$_FD/s.json" --out-state "$_FD/n.json" --now bad 2>&1)
    assert_equals "$?" "1" "--now が日時でない → 中断"
    printf 'ApexClass bogus=1\n' > "$_FD/bad.txt"
    out=$(node "$MJS" fingerprint --org prod --fp-config "$_FD/bad.txt" --state "$_FD/s.json" --out-state "$_FD/n.json" 2>&1)
    assert_equals "$?" "1" "種類の表に、不明な指定 → 中断"; assert_output_contains "$out" "不明な指定" "不明な指定の理由が出る"
    printf 'ApexClass\nApexClass\n' > "$_FD/bad.txt"
    out=$(node "$MJS" fingerprint --org prod --fp-config "$_FD/bad.txt" --state "$_FD/s.json" --out-state "$_FD/n.json" 2>&1)
    assert_equals "$?" "1" "種類の表に、同じ種類が 2 回 → 中断"
    printf 'ApexClass unfiled=x\n' > "$_FD/bad.txt"
    out=$(node "$MJS" fingerprint --org prod --fp-config "$_FD/bad.txt" --state "$_FD/s.json" --out-state "$_FD/n.json" 2>&1)
    assert_equals "$?" "1" "unfiled= だけの指定（folder= がない）→ 中断"
    _fp_server_stop; rm -rf "$_FD"
}

# セッション切れ: sf org display のトークンが無効なとき、sf org auth show-access-token で 1 回だけ取り直して、やり直す
test_fingerprint_token_refresh() {
    echo ""; echo -e "${CLR_HEAD}[TEST] metasync.js: fingerprint（トークンの取り直し・接続の失敗）${CLR_RST}"
    _fp_mk
    _fp_token "TESTTOKEN-FRESH"     # サーバーは、取り直したトークンだけ受け付ける。sf org display のトークン（TESTTOKEN）は、期限切れ
    : > "$_FD/calls.log"
    MOCK_SF_FRESH_TOKEN="TESTTOKEN-FRESH" _fp
    assert_equals "$_RC" "11" "セッション切れ → 取り直して、一覧が取れる（状態がないので、不明 11）"
    assert_output_not_contains "$_OUT" "INVALID_SESSION_ID" "取り直しで解決すれば、失敗は出ない"
    assert_equals "$(grep -c 'org auth show-access-token' "$_FD/calls.log")" "1" "同時に失敗しても、トークンの取り直しは 1 回だけ"
    assert_file_contains "$_FD/requests.log" 'TESTTOKEN-FRESH' "やり直しは、取り直したトークンで行う"
    assert_output_not_contains "$_OUT" "TESTTOKEN" "トークンは、出力に出さない"
    # 現行の sf: org display のトークンは伏せ字。伏せ字を SOAP に送らず、最初から show-access-token で取る
    _fp_token "TESTTOKEN-FRESH"; : > "$_FD/calls.log"; : > "$_FD/requests.log"
    _FD_ORG="{\"status\":0,\"result\":{\"accessToken\":\"[REDACTED] Use 'sf org auth show-access-token' to view\",\"instanceUrl\":\"http://127.0.0.1:${_FD_PORT}\"}}" \
        MOCK_SF_FRESH_TOKEN="TESTTOKEN-FRESH" _fp
    assert_equals "$_RC" "11" "伏せ字のトークン → 取り直して、一覧が取れる（状態がないので、不明 11）"
    assert_output_not_contains "$_OUT" "INVALID_SESSION_ID" "伏せ字のときは、セッション切れの失敗にならない"
    assert_equals "$(grep -c 'REDACTED' "$_FD/requests.log")" "0" "伏せ字は、SOAP に送らない"
    assert_equals "$(grep -c 'org auth show-access-token' "$_FD/calls.log")" "1" "伏せ字のときは、最初に 1 回だけ show-access-token で取る"
    assert_file_contains "$_FD/requests.log" 'TESTTOKEN-FRESH' "取ったトークンで一覧を取る"
    # 伏せ字で、show-access-token も失敗 → SOAP を呼ばずに不明
    : > "$_FD/requests.log"
    _FD_ORG="{\"status\":0,\"result\":{\"accessToken\":\"[REDACTED] Use 'sf org auth show-access-token' to view\",\"instanceUrl\":\"http://127.0.0.1:${_FD_PORT}\"}}" \
        MOCK_SF_TOKEN_EXIT=1 _fp
    assert_equals "$_RC" "11" "伏せ字で、取得も失敗 → 不明"
    assert_output_contains "$_OUT" "アクセストークンを取得できませんでした" "取得できない理由が出る"
    assert_equals "$(wc -l < "$_FD/requests.log" | tr -d ' ')" "0" "取得できないときは、SOAP を呼ばない"
    # 取り直しが失敗 → 一覧の取得に失敗 → 不明
    MOCK_SF_TOKEN_EXIT=1 _fp
    assert_equals "$_RC" "11" "取り直しも失敗 → 不明"
    assert_output_contains "$_OUT" "INVALID_SESSION_ID" "セッションが無効な理由が出る"
    [[ ! -f "$_FD/new.json" ]] && pass "取り直しも失敗 → 状態を書かない" || fail "取り直しも失敗 → 状態を書かない"
    # 接続情報（アクセストークン・URL）がない → 不明
    _FD_ORG='{"status":0,"result":{"alias":"x"}}' _fp
    assert_equals "$_RC" "11" "接続情報がない → 不明"
    assert_output_contains "$_OUT" "接続情報" "接続情報を取得できない理由が出る"
    # サーバーに接続できない → 不明（2 回試して諦める）。使われていないポート（1）に向ける（サーバーを止めて空いたポートを狙うと、
    #   並列に動く別のテストのモックが同じポートを取ることがある）
    _FD_ORG='{"status":0,"result":{"accessToken":"TESTTOKEN","instanceUrl":"http://127.0.0.1:1"}}' _fp
    assert_equals "$_RC" "11" "接続できない → 不明"
    assert_output_contains "$_OUT" "接続エラー" "接続エラーが出る"
    _fp_server_stop; rm -rf "$_FD"
}

# 応答の検証・転送の拒否・時間切れ・まとめて問い合わせ・上限（設計 16 章の P1。レビューでの指摘の対応）
_fp_top() {   # サーバーのデータの先頭の項目（nonSoap・redirect・delay）を設定する。引数: キー・JSON の値（null で消す）
    node -e 'const fs=require("fs");const f=process.argv[1];const d=JSON.parse(fs.readFileSync(f,"utf8"));const v=JSON.parse(process.argv[3]);if(v===null)delete d[process.argv[2]];else d[process.argv[2]]=v;fs.writeFileSync(f,JSON.stringify(d));' "$_FD/data.json" "$1" "$2"
}
test_fingerprint_hardening() {
    echo ""; echo -e "${CLR_HEAD}[TEST] metasync.js: fingerprint（応答の検証・転送の拒否・時間切れ・上限）${CLR_RST}"
    _fp_mk
    # 0 件の種類: 実機は自己終了タグ（<listMetadataResponse/>）で返す。失敗ではなく「件数 0」として扱う（モックも同じ形で返す）
    _fp_set ApexClass '[]'
    _fp
    assert_output_not_contains "$_OUT" "Metadata API の形ではありません" "0 件の一覧（自己終了タグ）は、失敗にしない"
    assert_equals "$(_fp_json "$_FD/report.json" 'types.ApexClass.count')" "0" "0 件の種類は、件数 0 として記録する"
    assert_output_not_contains "$_OUT" "一覧の取得に失敗した種類があります" "0 件の種類があっても、全体は失敗にならない"
    _fp_set ApexClass '[{"fullName":"A1","lastModifiedDate":"2026-11-01T01:00:00.000Z"},{"fullName":"A2","lastModifiedDate":"2026-11-01T02:00:00.000Z"}]'
    # HTTP 200 でも SOAP の応答でない本文（メンテナンス画面など）→ 「0 件の一覧」にせず、失敗（不明 11）
    _fp_top nonSoap true
    _fp
    assert_equals "$_RC" "11" "HTTP 200 で SOAP でない応答 → 不明（空の一覧とみなさない）"
    assert_output_contains "$_OUT" "Metadata API の形ではありません" "SOAP でない応答の理由が出る"
    assert_output_contains "$_OUT" "\[WARNING\] 不明" "不明になった理由は WARNING で出る"
    [[ ! -f "$_FD/new.json" ]] && pass "SOAP でない応答のときは、状態を書かない" || fail "SOAP でない応答のときは、状態を書かない"
    # 1 種類が失敗したら、残りの問い合わせは中止する（応答しない組織で、全種類ぶん待たない）。種類が多い表で、要求の数を見る
    for i in $(seq 1 40); do echo "TypeN$i"; done > "$_FD/fp.big"
    : > "$_FD/requests.log"
    _OUT=$(SF_METASYNC_SF="bash $_FD/bin/sf" MOCK_CALL_LOG="$_FD/calls.log" MOCK_SF_ORG_JSON="$_FD_ORG" \
        node "$MJS" fingerprint --org prod --fp-config "$_FD/fp.big" --state "$_FD/state.json" --out-state "$_FD/new.json" \
        --out-report "$_FD/report.json" --repo "$_FD/repo" 2>&1); _RC=$?
    assert_equals "$_RC" "11" "多くの種類が失敗 → 不明"
    [[ "$(wc -l < "$_FD/requests.log" | tr -d ' ')" -le 6 ]] && pass "失敗したら、残りの問い合わせは中止する（同時に走る 6 件より多く出さない。中止がなければ 40 回）" || fail "失敗したら、残りの問い合わせは中止する"
    assert_output_not_contains "$_OUT" "(中止)" "中止した種類は、失敗の一覧に出さない"
    assert_output_contains "$_OUT" "ほかの種類は、中止しました" "中止したときは、失敗の件数が部分的な数である旨を添える"
    # 種類が 1 つだけ（待ち行列ができない）で失敗した回は、中止した問い合わせがないので、注記を付けない
    _fp_top nonSoap null
    echo "ReportType" > "$_FD/fp.one"; _fp_set ReportType '{"http":503}'
    _OUT=$(SF_METASYNC_SF="bash $_FD/bin/sf" MOCK_CALL_LOG="$_FD/calls.log" MOCK_SF_ORG_JSON="$_FD_ORG" \
        node "$MJS" fingerprint --org prod --fp-config "$_FD/fp.one" --state "$_FD/state.json" --out-state "$_FD/new.json" \
        --out-report "$_FD/report.json" --repo "$_FD/repo" 2>&1); _RC=$?
    assert_equals "$_RC" "11" "1 種類だけの失敗 → 不明"
    assert_output_contains "$_OUT" "HTTP 503" "意図した失敗（HTTP 503）で不明になる"
    assert_output_not_contains "$_OUT" "中止しました" "中止した問い合わせがない回には、中止の注記を付けない"
    _fp_set ReportType '[{"fullName":"RT1","lastModifiedDate":"2026-11-01T04:00:00.000Z"}]'
    _fp_top nonSoap null
    # 転送（307）→ 追わない（トークン入りの本文を、別のホストへ再送しない）。同じ問い合わせは 2 回（やり直しの 1 回）で諦める
    : > "$_FD/requests.log"
    _fp_top redirect '"http://127.0.0.1:9/elsewhere"'
    _fp
    assert_equals "$_RC" "11" "転送された → 不明（追わない）"
    assert_equals "$(grep -c '^ApexClass|' "$_FD/requests.log")" "2" "転送は追わない（追うと、何度も要求が来る）。やり直しの 1 回だけ"
    assert_output_not_contains "$_OUT" "TESTTOKEN" "転送のときも、トークンを出力しない"
    _fp_top redirect null
    # 応答が遅い → 1 回の待ちの上限で諦める（不明）
    _fp_top delay 1500
    SF_METASYNC_FP_TIMEOUT_MS=200 _fp
    assert_equals "$_RC" "11" "応答が遅すぎる → 不明（1 回の待ちの上限）"
    assert_output_contains "$_OUT" "接続エラー" "時間切れは接続エラーとして出る"
    # 全体の期限: フォルダ型は 2 段階（フォルダ → 部品）。最初の段階で期限を超えると、次の段階に進まない。
    #   （遅い環境では sf の呼び出しだけで期限を過ぎることがあるが、どちらの経路でも「時間切れ」と出て、不明になる）
    _fp_top delay 2000
    SF_METASYNC_FP_DEADLINE_MS=1500 _fp
    assert_equals "$_RC" "11" "全体の期限を超えた → 不明"
    assert_output_contains "$_OUT" "時間切れ" "全体の期限切れの理由が出る"
    _fp_top delay null
    # sf の呼び出しも、全体の期限に含める（遅い sf を、残り時間で打ち切る。応答が空でも「JSON が読めない」とは区別する）
    cat > "$_FD/slowsf" << 'EOS'
#!/bin/bash
# 引数に $SLOW_ON を含む呼び出しだけ、$SLOW_SEC 秒（既定 3）眠る。SLOW_THEN=1 なら、眠ったあと、モックの sf に任せる（正しい応答を返す）。
#   そうでなければ、応答は空で終わる。ほかの呼び出しは、すぐモックの sf に任せる
case "$*" in *"$SLOW_ON"*) sleep "${SLOW_SEC:-3}"; [[ "${SLOW_THEN:-}" == "1" ]] || exit 0 ;; esac
exec bash "$(dirname "$0")/bin/sf" "$@"
EOS
    SLOW_ON="org display" SF_METASYNC_FP_DEADLINE_MS=1000 SF_METASYNC_SF="bash $_FD/slowsf" MOCK_CALL_LOG="$_FD/calls.log" MOCK_SF_ORG_JSON="$_FD_ORG" \
        node "$MJS" fingerprint --org prod --fp-config "$_FD/fp.txt" --state "$_FD/state.json" --out-state "$_FD/new.json" --out-report "$_FD/report.json" --repo "$_FD/repo" > "$_FD/slow.out" 2>&1
    assert_equals "$?" "11" "sf の呼び出しが期限を超えた → 不明"
    assert_file_contains "$_FD/slow.out" "sf が時間切れです" "sf の時間切れは、「応答を読めません」とは別の理由で出る"
    # トークンの取り直し（sf org auth show-access-token）も、期限で打ち切る
    _fp_token "TESTTOKEN-FRESH"
    # 眠りが期限より長く、眠ったあとは正しいトークンを返す: 打ち切られなければ取り直しに成功し、INVALID_SESSION_ID は出ない
    SLOW_ON="show-access-token" SLOW_SEC=8 SLOW_THEN=1 MOCK_SF_FRESH_TOKEN="TESTTOKEN-FRESH" SF_METASYNC_FP_DEADLINE_MS=5000 SF_METASYNC_SF="bash $_FD/slowsf" MOCK_CALL_LOG="$_FD/calls.log" MOCK_SF_ORG_JSON="$_FD_ORG" \
        node "$MJS" fingerprint --org prod --fp-config "$_FD/fp.txt" --state "$_FD/state.json" --out-state "$_FD/new.json" --out-report "$_FD/report.json" --repo "$_FD/repo" > "$_FD/slow.out" 2>&1
    assert_equals "$?" "11" "トークンの取り直しが遅すぎる → 不明（取り直しも期限で打ち切る）"
    assert_file_contains "$_FD/slow.out" "INVALID_SESSION_ID" "取り直せなかったので、セッションが無効な理由が出る（打ち切られなければ、取り直しに成功してしまう）"
    _fp_token "TESTTOKEN"
    # インスタンス URL が https でない（手元のモック以外の http）→ トークンを送らず、不明
    : > "$_FD/requests.log"
    _FD_ORG='{"status":0,"result":{"accessToken":"TESTTOKEN","instanceUrl":"http://example.com"}}' _fp
    assert_equals "$_RC" "11" "https でないインスタンス URL → 不明"
    assert_output_contains "$_OUT" "https ではない" "https でない理由が出る"
    assert_equals "$(wc -l < "$_FD/requests.log" | tr -d ' ')" "0" "https でないときは、要求を出さない"
    _FD_ORG='{"status":0,"result":{"accessToken":"TESTTOKEN","instanceUrl":"not a url"}}' _fp
    assert_output_contains "$_OUT" "インスタンス URL を読めません" "URL として読めない → 不明"
    # 失敗の文面にトークンが入っていても、出力では伏せる
    _fp_set ReportType '{"fault":"UNKNOWN_EXCEPTION: bad TESTTOKEN here"}'
    _fp
    assert_output_not_contains "$_OUT" "TESTTOKEN" "Fault の文面にトークンがあっても、出力しない"
    assert_output_contains "$_OUT" "bad \*\*\* here" "トークンは *** に置き換える"
    _fp_set ReportType '[{"fullName":"RT1","lastModifiedDate":"2026-11-01T04:00:00.000Z"}]'
    # フォルダの問い合わせは、3 つずつまとめる（呼び出しの回数を減らす）
    node -e 'const fs=require("fs");const f=process.argv[1];const d=JSON.parse(fs.readFileSync(f,"utf8"));
      d.lists.ReportFolder=[1,2,3,4,5,6,7].map(i=>({fullName:"G"+i,lastModifiedDate:"2026-11-01T05:00:00.000Z"}));
      fs.writeFileSync(f,JSON.stringify(d));' "$_FD/data.json"
    : > "$_FD/requests.log"; : > "$_FD/requests.log.calls"
    _fp
    assert_file_contains "$_FD/requests.log" 'Report|G7|TESTTOKEN' "まとめても、フォルダごとに一覧される"
    assert_file_contains "$_FD/requests.log" 'Report|unfiled$public|TESTTOKEN' "まとめても、フォルダに入っていない部品の置き場所も一覧される"
    assert_equals "$(grep -c '^3$' "$_FD/requests.log.calls")" "2" "8 か所（7 フォルダ + 置き場所）は、3 + 3 + 2 の 3 回で一覧（3 つの回は 2 回）"
    assert_equals "$(grep -c '^2$' "$_FD/requests.log.calls")" "1" "残りの 2 か所は 1 回にまとまる"
    assert_output_contains "$_OUT" "一覧の呼び出し 8 回" "全体の呼び出しは、フォルダの種類 1 + 部品 3 + ほかの 4 種類（Gone を含む）= 8 回"
    # フォルダが多すぎる → 不明（上限 900）
    node -e 'const fs=require("fs");const f=process.argv[1];const d=JSON.parse(fs.readFileSync(f,"utf8"));
      d.lists.ReportFolder=Array.from({length:901},(_,i)=>({fullName:"H"+i,lastModifiedDate:"2026-11-01T05:00:00.000Z"}));
      fs.writeFileSync(f,JSON.stringify(d));' "$_FD/data.json"
    _fp
    assert_equals "$_RC" "11" "フォルダが上限を超えた → 不明"
    assert_output_contains "$_OUT" "フォルダが多すぎます" "上限超過の理由が出る"
    assert_output_not_contains "$_OUT" "Report: Report" "失敗した種類の名前が、二重にならない"
    # フォルダ上限超えで中止したとき、実行中の別の種類の要求は、時間切れのあとにやり直さない（遅い種類への要求は 1 回だけ）
    _fp_set ApexClass '{"delay":6000}'; : > "$_FD/requests.log"
    SF_METASYNC_FP_TIMEOUT_MS=2000 _fp   # 中止の旗が立つ（901 件の応答）より先に、遅い種類が時間切れにならない余裕（負荷のかかった CI を考えて 2 秒）
    assert_equals "$_RC" "11" "フォルダ上限超え + 遅い種類 → 不明"
    assert_equals "$(grep -c '^ApexClass|' "$_FD/requests.log")" "1" "中止したあとは、実行中の要求もやり直さない"
    # 更新日時が 1970 年のままの部品の数（epoch）が、結果に入る（影の比較用）
    _fp_set ApexClass '[{"fullName":"A1","lastModifiedDate":"1970-01-01T00:00:00.000Z"},{"fullName":"A2","lastModifiedDate":"2026-11-01T02:00:00.000Z"}]'
    node -e 'const fs=require("fs");const f=process.argv[1];const d=JSON.parse(fs.readFileSync(f,"utf8"));d.lists.ReportFolder=[];fs.writeFileSync(f,JSON.stringify(d));' "$_FD/data.json"
    _fp
    assert_equals "$(_fp_json "$_FD/report.json" 'types.ApexClass.epoch')" "1" "結果に、更新日時が 1970 年のままの件数が入る"
    assert_file_not_contains "$_FD/new.json" "epoch" "状態ファイルには、epoch を入れない（影の比較用）"
    _fp_server_stop; rm -rf "$_FD"
}

# --- 9. fpcompare（影の比較）---
test_fpcompare() {
    echo ""; echo -e "${CLR_HEAD}[TEST] metasync.js: fpcompare（影の比較）${CLR_RST}"
    _FD=$(mktemp -d "${TMPDIR:-/tmp}/test-msfc-XXXX")
    printf 'ApexClass\nCustomField dir=objects\nReportType\nReport folder=ReportFolder unfiled=unfiled$public dir=reports\n' > "$_FD/fp.txt"
    local R='force-app/main/default'
    _fpc() { _OUT=$(node "$MJS" fpcompare --report "$_FD/report.json" --plan "$_FD/plan.tsv" --fp-config "$_FD/fp.txt" --dirs-table "$DIRS_TABLE" 2>&1); _RC=$?; }
    _rep() { echo "{\"verdict\":$1,\"types\":{\"ApexClass\":{\"status\":\"$2\"},\"CustomField\":{\"status\":\"unchanged\"},\"ReportType\":{\"status\":\"unchanged\"},\"Report\":{\"status\":\"unchanged\"}}}" > "$_FD/report.json"; }
    # 検知できた: 計画の変更があるフォルダ（classes）の種類（ApexClass）が、変わっていた
    _rep 10 changed
    printf 'M\t%s/classes/A1.cls\t\nA\t%s/classes/A9.cls\t\n' "$R" "$R" > "$_FD/plan.tsv"; _fpc
    assert_equals "$_RC" "0" "影の比較は、常に終了コード 0（情報のみ）"
    assert_output_contains "$_OUT" "実際の変更 2 件（1 グループ）— 検知できた 1（2 件）/ 見逃し 0（0 件）/ 日時では検知できない種類 0（0 件）/ 指紋の対象外 0（0 件）" "指紋が変わった種類のフォルダの変更は、検知できた"
    assert_output_not_contains "$_OUT" "WARNING" "見逃しがなければ、WARNING は出ない"
    # 見逃し: 指紋の対象の種類があるのに、どれも変わっていない → WARNING
    _rep 10 unchanged
    printf 'M\t%s/classes/A1.cls\t\n' "$R" > "$_FD/plan.tsv"; _fpc
    assert_output_contains "$_OUT" "見逃し 1（1 件）" "指紋が動かなかったのに、ファイルが変わった → 見逃し"
    assert_output_contains "$_OUT" "\[WARNING\] 指紋の見逃し: classes（指紋の種類: ApexClass）" "見逃しは WARNING で、フォルダと種類を出す"
    assert_output_contains "$_OUT" "M force-app/main/default/classes/A1.cls" "見逃しのファイルの例が出る"
    # 見逃し: 指紋の変化が、ほかの種類だけ（ReportType）で、変更はフォルダ classes → 見逃し（種類は、フォルダごとに結びつける）
    printf '{"verdict":10,"types":{"ApexClass":{"status":"unchanged"},"ReportType":{"status":"changed"}}}\n' > "$_FD/report.json"
    printf 'M\t%s/classes/A1.cls\t\n' "$R" > "$_FD/plan.tsv"; _fpc
    assert_output_contains "$_OUT" "見逃し 1" "別の種類の指紋が変わっても、そのフォルダの種類が動いていなければ、見逃し"
    # objects: 子の種類ごとに結びつける（fields = CustomField）。CustomObject は、表にないので対象外
    _rep 10 changed
    printf 'M\t%s/objects/Account/fields/F1__c.field-meta.xml\t\nM\t%s/objects/Account/Account.object-meta.xml\t\nM\t%s/objects/Account/listViews/L.listView-meta.xml\t\n' "$R" "$R" "$R" > "$_FD/plan.tsv"; _fpc
    assert_output_contains "$_OUT" "見逃し 1（1 件）/ 日時では検知できない種類 0（0 件）/ 指紋の対象外 2（2 件）" "objects: 項目 = CustomField は見逃し。オブジェクト本体・リストビューは、表にない種類 = 対象外"
    assert_output_contains "$_OUT" "指紋の見逃し: objects/CustomField" "objects の見逃しは、子の種類で出る"
    # 指紋の対象外: 表にない種類のフォルダ
    _rep 10 changed
    printf 'A\t%s/staticresources/S.resource\t\n' "$R" > "$_FD/plan.tsv"; _fpc
    assert_output_contains "$_OUT" "指紋の対象外 1（1 件）" "表にない種類のフォルダの変更は、指紋の対象外"
    assert_output_contains "$_OUT" "staticresources" "対象外のフォルダが出る"
    # 削除の保留（H）は、実際の変更に数えない
    printf 'H\t%s/classes/A1.cls\tS4\n' "$R" > "$_FD/plan.tsv"; _fpc
    assert_output_contains "$_OUT" "実際の変更はありませんでした" "保留（H）は、変更に数えない"
    # 空振り: 指紋は変わったが、変更がなかった種類
    _rep 10 changed
    : > "$_FD/plan.tsv"; _fpc
    assert_output_contains "$_OUT" "指紋の空振り（指紋は変わったが、ファイルの変更はなかった種類）: ApexClass" "指紋が変わったのに、変更がなかった種類（空振り）が出る"
    # 日時では検知できない種類: Profile など（別の部品を足しても、自分の更新日時が動かない）と、一覧の日時がすべて 1970 年の種類は、見逃しと分ける
    printf 'Profile\n' >> "$_FD/fp.txt"
    printf '{"verdict":10,"types":{"ApexClass":{"status":"unchanged","count":2,"epoch":2},"Profile":{"status":"unchanged","count":3,"epoch":0},"ReportType":{"status":"changed"}}}\n' > "$_FD/report.json"
    printf 'M\t%s/classes/A1.cls\t\nM\t%s/profiles/Admin.profile-meta.xml\t\n' "$R" "$R" > "$_FD/plan.tsv"; _fpc
    assert_output_contains "$_OUT" "見逃し 0（0 件）/ 日時では検知できない種類 2（2 件）" "更新日時が動かない種類（Profile・日時がすべて 1970 年の種類）は、見逃しにしない"
    assert_output_not_contains "$_OUT" "WARNING" "日時では検知できない種類は、WARNING にしない"
    assert_output_contains "$_OUT" "日時では検知できない種類（更新日時が動かない" "その種類のフォルダが出る"
    # 同じフォルダの子の種類に 0 件のものが混じっても、日時では検知できない種類は、見逃しにしない（0 件の種類は判定から外す）
    printf 'Workflow dir=workflows\nWorkflowRule dir=workflows\n' >> "$_FD/fp.txt"
    printf '{"verdict":10,"types":{"ApexClass":{"status":"changed"},"Workflow":{"status":"unchanged","count":2,"epoch":2},"WorkflowRule":{"status":"unchanged","count":0,"epoch":0}}}\n' > "$_FD/report.json"
    printf 'M\t%s/workflows/Account.workflow-meta.xml\t\n' "$R" > "$_FD/plan.tsv"; _fpc
    assert_output_contains "$_OUT" "見逃し 0（0 件）/ 日時では検知できない種類 1（1 件）" "0 件の子の種類が混じっても、全件 1970 年の種類は、見逃しにしない"
    # 使えない種類（この組織にない）が同じフォルダに混じっても、同じ
    printf '{"verdict":10,"types":{"ApexClass":{"status":"changed"},"Workflow":{"status":"unchanged","count":2,"epoch":2},"WorkflowRule":{"status":"unavailable","count":null,"unavailable":true}}}\n' > "$_FD/report.json"
    printf 'M\t%s/workflows/Account.workflow-meta.xml\t\n' "$R" > "$_FD/plan.tsv"; _fpc
    assert_output_contains "$_OUT" "見逃し 0（0 件）/ 日時では検知できない種類 1（1 件）" "使えない子の種類が混じっても、全件 1970 年の種類は、見逃しにしない"
    # 日時が 1970 年のものが一部だけなら、日時で見分けられる種類なので、見逃しにする
    printf '{"verdict":10,"types":{"ApexClass":{"status":"unchanged","count":2,"epoch":1},"ReportType":{"status":"changed"}}}\n' > "$_FD/report.json"
    printf 'M\t%s/classes/A1.cls\t\n' "$R" > "$_FD/plan.tsv"; _fpc
    assert_output_contains "$_OUT" "見逃し 1（1 件）" "1970 年が一部だけの種類は、見逃しとして数える"
    # 指紋が不明（11）・結果が読めない → 比べない
    _rep 11 changed; _fpc
    assert_output_contains "$_OUT" "指紋が不明" "指紋が不明のときは、比べない"
    rm -f "$_FD/report.json"; _fpc
    assert_equals "$_RC" "0" "結果が読めなくても、終了コード 0"
    assert_output_contains "$_OUT" "読めないため" "結果が読めない旨が出る"
    rm -rf "$_FD"
}

# 種類の表（config/metasync-fingerprint.txt）の整合: 書式が正しく、重複がなく、Document 系を含まず、影の比較で結びつくフォルダがある
FP_TABLE="$SF_TOOLS_DIR/config/metasync-fingerprint.txt"
test_fingerprint_table() {
    echo ""; echo -e "${CLR_HEAD}[TEST] config/metasync-fingerprint.txt: 書式と整合${CLR_RST}"
    local bad dup nodir doc
    bad=$(grep -v -E '^\s*(#.*)?$' "$FP_TABLE" | grep -v -E '^[A-Za-z0-9_]+(\s+(dir|folder|unfiled)=[^[:space:]]+)*\s*(#.*)?$')
    [[ -z "$bad" ]] && pass "すべての行が「種類名 [キー=値 ...]」の書式" || fail "書式が正しくない行: $bad"
    dup=$(grep -v -E '^\s*(#.*)?$' "$FP_TABLE" | awk '{print $1}' | sort | uniq -d)
    [[ -z "$dup" ]] && pass "同じ種類が、2 回書かれていない" || fail "重複: $dup"
    nodir=$(grep -v -E '^\s*(#.*)?$' "$FP_TABLE" | while read -r t rest; do [[ "$rest" == *dir=* ]] || grep -q "^$t " "$DIRS_TABLE" || echo "$t"; done)
    [[ -z "$nodir" ]] && pass "すべての種類が、フォルダに結びつく（dir= または metadata-dirs.txt）" || fail "フォルダに結びつかない種類: $nodir"
    doc=$(grep -v -E '^\s*#' "$FP_TABLE" | grep -E '^(Document|DocumentFolder)\b')
    [[ -z "$doc" ]] && pass "Document・DocumentFolder は含まない（設計 16.3.1: 取得の対象から外した）" || fail "Document 系が入っている: $doc"
    # 本物の表を、本物の読み取り（loadFpConfig）で読めること（書式の誤り・重複・不明な指定は、ここで中断する）
    local d out; d=$(mktemp -d "${TMPDIR:-/tmp}/test-msfpt-XXXX")
    echo '{"verdict":0,"types":{}}' > "$d/report.json"; : > "$d/plan.tsv"
    out=$(node "$MJS" fpcompare --report "$d/report.json" --plan "$d/plan.tsv" --fp-config "$FP_TABLE" --dirs-table "$DIRS_TABLE" 2>&1)
    assert_equals "$?" "0" "本物の表を、読み込める"
    assert_output_contains "$out" "実際の変更はありませんでした" "本物の表で、影の比較が動く"
    rm -rf "$d"
}

# --- 10. scan（秘密情報の検査。設計 16.7）---
#   準備: $_SD に、手元（repo）・取得結果（fetched）・計画（plan.tsv）を作る。_sc_put で、ファイルを置く
_sc_mk() {
    _SD=$(mktemp -d "${TMPDIR:-/tmp}/test-mssc-XXXX")
    mkdir -p "$_SD/repo" "$_SD/fetched"
    echo '{"packageDirectories":[{"path":"force-app"}]}' > "$_SD/repo/sfdx-project.json"
    cp "$_SD/repo/sfdx-project.json" "$_SD/fetched/"
    : > "$_SD/plan.tsv"
}
# 引数: 置き場所（repo か fetched）・パス（force-app/main/default からの相対）・内容（計画への追加は、_sc_plan で別に行う）
_sc_put() {
    local where="$1" rel="$2" body="$3" f="$_SD/$1/force-app/main/default/$2"
    mkdir -p "${f%/*}"; printf '%s\n' "$body" > "$f"
}
_sc_plan() { printf '%s\tforce-app/main/default/%s\t\n' "$1" "$2" >> "$_SD/plan.tsv"; }   # 引数: 操作（A・M）・パス
_sc() { _OUT=$(node "$MJS" scan --plan "$_SD/plan.tsv" --repo "$_SD/repo" --fetched "$_SD/fetched" --out-report "$_SD/rep.tsv" "$@" 2>&1); _RC=$?; }

test_scan() {
    echo ""; echo -e "${CLR_HEAD}[TEST] metasync.js: scan（秘密情報の検査）${CLR_RST}"
    _sc_mk
    # 規則ごとに、1 件ずつ見つかる。値は、出力に出さない
    _sc_put fetched classes/A.cls "public class A { String apiKey = 'abcdef123456'; String note = 'hello world 1234'; }"; _sc_plan A classes/A.cls
    _sc_put fetched authproviders/G.authprovider-meta.xml '<AuthProvider><password>hunter2hunter2</password></AuthProvider>'; _sc_plan A authproviders/G.authprovider-meta.xml
    _sc_put fetched customMetadata/X.md-meta.xml '<CustomMetadata><values><field>Api_Key__c</field><value xsi:type="xsd:string">abcdef123456</value></values></CustomMetadata>'; _sc_plan A customMetadata/X.md-meta.xml
    _sc_put fetched labels/CustomLabels.labels-meta.xml '<CustomLabels><labels><fullName>Stripe_Secret</fullName><value>abcdef123456</value></labels></CustomLabels>'; _sc_plan A labels/CustomLabels.labels-meta.xml
    _sc_put fetched staticresources/k.txt '-----BEGIN RSA PRIVATE KEY-----'; _sc_plan A staticresources/k.txt
    _sc_put fetched pages/P.page "<apex:page>AKIAABCDEFGHIJKLMNOP</apex:page>"; _sc_plan A pages/P.page
    _sc
    assert_equals "$_RC" "10" "scan: 疑いがある → 終了コード 10"
    assert_output_contains "$_OUT" "疑い 6 件（6 ファイル）" "scan: 疑いの件数とファイル数が出る"
    assert_output_contains "$_OUT" "\[WARNING\] 秘密の疑い: code-hardcoded-secret force-app/main/default/classes/A.cls" "scan: コードへの直書き"
    assert_output_contains "$_OUT" "xml-secret-element force-app/main/default/authproviders/G.authprovider-meta.xml" "scan: 秘密の要素（password）"
    assert_output_contains "$_OUT" "custommetadata-secret-field force-app/main/default/customMetadata/X.md-meta.xml" "scan: カスタムメタデータの秘密らしい項目"
    assert_output_contains "$_OUT" "customlabel-secret force-app/main/default/labels/CustomLabels.labels-meta.xml" "scan: カスタム表示ラベルの秘密らしい名前"
    assert_output_contains "$_OUT" "private-key force-app/main/default/staticresources/k.txt" "scan: 秘密鍵"
    assert_output_contains "$_OUT" "known-token force-app/main/default/pages/P.page" "scan: 既知のトークンの形（AWS）"
    assert_output_not_contains "$_OUT" "abcdef123456" "scan: 値（秘密）は、出力に出さない"
    assert_output_not_contains "$_OUT" "hunter2" "scan: 値（秘密）は、出力に出さない（要素）"
    assert_output_not_contains "$_OUT" "AKIAABCDEF" "scan: 値（秘密）は、出力に出さない（トークン）"
    assert_file_contains "$_SD/rep.tsv" "xml-secret-element	force-app/main/default/authproviders/G.authprovider-meta.xml	1" "scan: 結果のファイルに、規則・パス・件数が入る（値は入らない）"
    assert_file_not_contains "$_SD/rep.tsv" "hunter2" "scan: 結果のファイルにも、値は入らない"
    rm -rf "$_SD"

    # 疑いにならないもの: プレースホルダ・秘密でない要素名・短い値・空・説明文・秘密でない名前の項目
    _sc_mk
    _sc_put fetched authproviders/G.authprovider-meta.xml '<AuthProvider><consumerSecret>Placeholder_abcdef</consumerSecret><consumerKey>3MVG9abcdefghijk</consumerKey><password></password><token>true</token></AuthProvider>'; _sc_plan A authproviders/G.authprovider-meta.xml
    _sc_put fetched settings/Password.settings-meta.xml '<PasswordPolicies><passwordComplexity>5</passwordComplexity><minimumPasswordLength>8</minimumPasswordLength></PasswordPolicies>'; _sc_plan A settings/Password.settings-meta.xml
    _sc_put fetched customMetadata/Y.md-meta.xml '<CustomMetadata><values><field>Api_Key__c</field><value xsi:type="xsd:string">short</value></values><values><field>Color__c</field><value xsi:type="xsd:string">abcdef123456</value></values></CustomMetadata>'; _sc_plan A customMetadata/Y.md-meta.xml
    _sc_put fetched classes/B.cls "public class B { String tokenLabel = 'Enter your token'; String msg = 'hello'; String apiKey = 'Placeholder_xxxxxxxx'; }"; _sc_plan A classes/B.cls
    _sc_put fetched reports/R.report-meta.xml '<Report><description>password reset report abcdef123456</description></Report>'; _sc_plan A reports/R.report-meta.xml
    _sc
    assert_equals "$_RC" "0" "scan: 秘密でないもの（プレースホルダ・短い値・説明文など）は、疑いにしない"
    assert_output_contains "$_OUT" "疑い 0 件" "scan: 疑い 0 件と出る"
    assert_equals "$(wc -c < "$_SD/rep.tsv" | tr -d ' ')" "0" "scan: 疑いがないとき、結果のファイルは空"
    rm -rf "$_SD"

    # 変更（M）: 手元にすでにある疑わしい文字列は、今回の新しい疑いにしない。新しく入った分だけ
    _sc_mk
    _sc_put repo classes/C.cls "public class C { String apiKey = 'abcdef123456'; }"
    _sc_put fetched classes/C.cls "public class C { String apiKey = 'abcdef123456'; String x = 1; }"; _sc_plan M classes/C.cls
    _sc
    assert_equals "$_RC" "0" "scan: 変更（M）で、すでにコミット済みの疑わしい文字列は、疑いにしない"
    _sc_put fetched classes/C.cls "public class C { String apiKey = 'abcdef123456'; String secretKey = 'zzzzzzzz9999'; }"
    _sc
    assert_equals "$_RC" "10" "scan: 変更（M）で、新しく入った疑わしい文字列は、疑いにする"
    assert_output_contains "$_OUT" "classes/C.cls（キー: secretKey）（1 件" "scan: 新しく入った分の件数だけ数える（キー = 変数名も表示する）"
    rm -rf "$_SD"

    # 追加・変更だけを検査する（削除 D・保留 H は、対象外）。バイナリは、秘密鍵・既知のトークンだけ探す（テキストの規則はかけない）。20 MB 超は検査しない
    _sc_mk
    _sc_put fetched classes/D.cls "public class D { String apiKey = 'abcdef123456'; }"
    _sc_plan D classes/D.cls; _sc_plan H classes/D.cls
    printf 'password = abcdef123456 binary' > "$_SD/fetched/force-app/main/default/classes/bin0.cls"; printf ' \0y' >> "$_SD/fetched/force-app/main/default/classes/bin0.cls"; _sc_plan A classes/bin0.cls
    _sc
    assert_equals "$_RC" "0" "scan: 削除（D）・保留（H）は検査しない／ バイナリには、テキストの規則（直書きなど）をかけない"
    assert_output_contains "$_OUT" "検査に制限があるファイル 1 個" "scan: 制限があるファイルの数が出る"
    assert_output_contains "$_OUT" "classes/bin0.cls（バイナリ" "scan: 制限があるファイルの名前が出る"
    printf 'AKIAABCDEFGHIJKLMNOP' > "$_SD/fetched/force-app/main/default/classes/bin1.cls"; printf ' \0y' >> "$_SD/fetched/force-app/main/default/classes/bin1.cls"; _sc_plan A classes/bin1.cls
    _sc
    assert_equals "$_RC" "10" "scan: バイナリでも、既知のトークンの形は検出する"
    assert_output_contains "$_OUT" "known-token force-app/main/default/classes/bin1.cls" "scan: バイナリの疑いの規則とパスが出る"
    head -c 21000000 /dev/zero > "$_SD/fetched/force-app/main/default/classes/big.cls"; : > "$_SD/plan.tsv"; _sc_plan A classes/big.cls
    _sc
    assert_equals "$_RC" "0" "scan: 20 MB 超は検査しない（疑いにしない）"
    assert_output_contains "$_OUT" "big.cls（20 MB 超" "scan: 検査しなかったファイルの名前が出る"
    node -e 'require("fs").writeFileSync(process.argv[1], Buffer.concat([Buffer.from([255,254]), Buffer.from("<AuthProvider><password>hunter2hunter2</password></AuthProvider>", "utf16le")]))' "$_SD/fetched/force-app/main/default/classes/u16.xml"
    : > "$_SD/plan.tsv"; _sc_plan A classes/u16.xml
    _sc
    assert_equals "$_RC" "10" "scan: UTF-16（BOM つき）のファイルも、テキストとして検査する"
    rm -rf "$_SD"

    # 許可の一覧（--allow）: 「規則 パス」。* が使える。なくてもよい。書式の誤りは中断
    _sc_mk
    _sc_put fetched classes/A.cls "public class A { String apiKey = 'abcdef123456'; }"; _sc_plan A classes/A.cls
    _sc_put fetched pages/P.page "<apex:page>AKIAABCDEFGHIJKLMNOP</apex:page>"; _sc_plan A pages/P.page
    printf '# 確認済みの誤検知\ncode-hardcoded-secret force-app/main/default/classes/*\n' > "$_SD/allow.txt"
    _sc --allow "$_SD/allow.txt"
    assert_equals "$_RC" "10" "scan: 許可に当たらない疑いが残れば、終了コード 10"
    assert_output_contains "$_OUT" "許可済み 1 件" "scan: 許可済みの件数が出る"
    assert_output_not_contains "$_OUT" "\[WARNING\] 秘密の疑い: code-hardcoded-secret force-app/main/default/classes/A.cls" "scan: 許可した疑いは、警告に出ない"
    assert_output_contains "$_OUT" "許可済み: code-hardcoded-secret force-app/main/default/classes/A.cls" "scan: 許可した疑いの内訳が、許可済みとして出る"
    assert_output_contains "$_OUT" "known-token force-app/main/default/pages/P.page" "scan: 許可していない疑いは、残る"
    printf '* force-app/main/default/*\n' > "$_SD/allow.txt"
    _sc --allow "$_SD/allow.txt"
    assert_equals "$_RC" "0" "scan: 規則 * とパスの * で、まとめて許可できる"
    _sc --allow "$_SD/none.txt"
    assert_equals "$_RC" "10" "scan: 許可の一覧がなくても、動く"
    printf 'known-token\n' > "$_SD/allow.txt"   # 語が 1 つだけ（規則名は正しい）
    _sc --allow "$_SD/allow.txt"
    assert_equals "$_RC" "1" "scan: 許可の一覧の書式の誤り → 中断（終了コード 1）"
    rm -rf "$_SD"

    # 引数・計画の誤り
    _sc_mk
    _sc_plan A classes/Missing.cls
    _sc
    assert_equals "$_RC" "1" "scan: 取得結果にないファイルが計画にある → 中断"
    : > "$_SD/plan.tsv"; printf 'A\tforce-app/../../etc/x\t\n' >> "$_SD/plan.tsv"
    _sc
    assert_equals "$_RC" "1" "scan: 計画のパスが対象の外を指す → 中断"
    out=$(node "$MJS" scan --repo "$_SD/repo" 2>&1); assert_equals "$?" "1" "scan: 必須オプションがない → 中断"
    : > "$_SD/plan.tsv"; _sc
    assert_equals "$_RC" "0" "scan: 計画が空 → 疑いなし"
    rm -rf "$_SD"
}

# scan の規則の精度: 普通のメタデータで誤検知しない／ 典型的な書き方を見逃さない（レビューでの指摘の対応）
test_scan_rules() {
    echo ""; echo -e "${CLR_HEAD}[TEST] metasync.js: scan（規則の精度）${CLR_RST}"
    # 誤検知しない: 名前・URL・API 名・日本語の文言・テストクラスのダミー値
    _sc_mk
    _sc_put fetched customMetadata/Cfg.md-meta.xml '<CustomMetadata><values><field>Token_Endpoint__c</field><value xsi:type="xsd:string">https://login.salesforce.com/services/oauth2/token</value></values><values><field>Named_Credential__c</field><value xsi:type="xsd:string">My_Named_Credential</value></values></CustomMetadata>'; _sc_plan A customMetadata/Cfg.md-meta.xml
    _sc_put fetched labels/CustomLabels.labels-meta.xml '<CustomLabels><labels><fullName>Forgot_Password</fullName><value>パスワードをお忘れですか？</value></labels><labels><fullName>Password_Label</fullName><value>Password</value></labels></CustomLabels>'; _sc_plan A labels/CustomLabels.labels-meta.xml
    _sc_put fetched classes/Consts.cls "public class Consts { static final String FIELD_PASSWORD = 'Password__c'; String apiKey = 'API_Key__c'; }"; _sc_plan A classes/Consts.cls
    _sc_put fetched classes/SiteLoginControllerTest.cls "@isTest public class SiteLoginControllerTest { void t() { controller.password = 'abcd1234'; } }"; _sc_plan A classes/SiteLoginControllerTest.cls
    _sc_put fetched lwc/login/login.js "export default class Login { fields = { password: 'Password', apiKey: 'c.API_Key_Label' }; }"; _sc_plan A lwc/login/login.js
    _sc
    assert_equals "$_RC" "0" "scan: 名前・URL・API 名・日本語の文言・テストクラスのダミー値は、疑いにしない"
    rm -rf "$_SD"
    # 見逃さない: URL の中の秘密・Bearer・Webhook・認証情報つき URL・属性つきの要素・CDATA・引用符つきのキーと =>・Key という項目名
    _sc_mk
    _sc_put fetched classes/Http.cls "public class Http { String b = 'grant_type=x&client_secret=Zq81xKd92mP4&code=1'; String h = 'Bearer abcdefghij0123456789ABCD'; String u = 'https://user:Pa55w0rd99@example.com/x'; }"; _sc_plan A classes/Http.cls
    _sc_put fetched classes/Hook.cls "public class Hook { String w = 'https://hooks.slack.com/services/T0ABCDEFG/B0ABCDEFG/abcdefghijklmnop'; }"; _sc_plan A classes/Hook.cls
    _sc_put fetched authproviders/Attr.authprovider-meta.xml '<AuthProvider><password xsi:type="xsd:string">hunter2hunter2</password></AuthProvider>'; _sc_plan A authproviders/Attr.authprovider-meta.xml
    _sc_put fetched authproviders/Cd.authprovider-meta.xml '<AuthProvider><clientSecret><![CDATA[hunter2hunter2]]></clientSecret></AuthProvider>'; _sc_plan A authproviders/Cd.authprovider-meta.xml
    _sc_put fetched classes/Map.cls "public class Map { Object m = new Map<String,String>{'password' => 'Zq81xKd92mP4'}; Object j = '{\"apiKey\": \"Zq81xKd92mP4\"}'; String q = 'secretKey=' ; String s3cret_key = 'Zq81xKd92mP4'; }"; _sc_plan A classes/Map.cls
    _sc_put fetched customMetadata/Key.md-meta.xml '<CustomMetadata><values><field>Key__c</field><value xsi:type="xsd:string">Zq81xKd92mP4wQ7aB</value></values></CustomMetadata>'; _sc_plan A customMetadata/Key.md-meta.xml
    _sc
    assert_equals "$_RC" "10" "scan: 典型的な書き方の秘密は、疑いにする"
    assert_output_contains "$_OUT" "url-secret force-app/main/default/classes/Http.cls（キー: client_secret）" "scan: URL の中の秘密（client_secret=）"
    assert_output_contains "$_OUT" "url-secret force-app/main/default/classes/Http.cls（キー: bearer）" "scan: Bearer トークン"
    assert_output_contains "$_OUT" "url-secret force-app/main/default/classes/Http.cls（キー: userinfo）" "scan: 認証情報つきの URL"
    assert_output_contains "$_OUT" "known-token force-app/main/default/classes/Hook.cls" "scan: Slack の Webhook URL"
    assert_output_contains "$_OUT" "xml-secret-element force-app/main/default/authproviders/Attr.authprovider-meta.xml（キー: password）" "scan: 属性つきの要素"
    assert_output_contains "$_OUT" "xml-secret-element force-app/main/default/authproviders/Cd.authprovider-meta.xml（キー: clientSecret）" "scan: CDATA の中の値"
    assert_output_contains "$_OUT" "code-hardcoded-secret force-app/main/default/classes/Map.cls（キー: password）" "scan: 引用符つきのキーと =>（Map の初期化）"
    assert_output_contains "$_OUT" "custommetadata-secret-field force-app/main/default/customMetadata/Key.md-meta.xml（キー: Key__c）" "scan: Key という項目名"
    assert_output_not_contains "$_OUT" "Zq81xKd92mP4" "scan: 値（秘密）は、出力に出さない"
    # 許可の一覧は、キーで絞れる（ラベル・項目・変数名の単位。パス全体を無検査にしない）
    rm -rf "$_SD"; _sc_mk
    _sc_put fetched labels/CustomLabels.labels-meta.xml '<CustomLabels><labels><fullName>Stripe_Secret_Test</fullName><value>Zq81xKd92mP4wQ</value></labels><labels><fullName>Other_Token</fullName><value>Zq81xKd92mP4wQ</value></labels></CustomLabels>'; _sc_plan A labels/CustomLabels.labels-meta.xml
    _sc
    assert_output_contains "$_OUT" "疑い 2 件" "scan: ラベルごとに疑いを数える"
    assert_output_contains "$_OUT" "customlabel-secret force-app/main/default/labels/CustomLabels.labels-meta.xml（キー: Stripe_Secret_Test）" "scan: ラベル名（キー）が出る"
    printf 'customlabel-secret force-app/main/default/labels/CustomLabels.labels-meta.xml Stripe_Secret_Test\n' > "$_SD/allow.txt"
    _sc --allow "$_SD/allow.txt"
    assert_equals "$_RC" "10" "scan: キーで許可したラベルは外れるが、別のラベルの疑いは残る"
    assert_output_contains "$_OUT" "許可済み 1 件" "scan: 許可済みの件数が出る"
    assert_output_not_contains "$_OUT" "\[WARNING\] 秘密の疑い: customlabel-secret force-app/main/default/labels/CustomLabels.labels-meta.xml（キー: Stripe_Secret_Test）" "scan: 許可したラベルは、警告に出ない"
    assert_output_contains "$_OUT" "Other_Token" "scan: 許可していないラベルは、残る"
    assert_file_contains "$_SD/rep.tsv" "customlabel-secret	force-app/main/default/labels/CustomLabels.labels-meta.xml	1	Other_Token" "scan: 結果のファイルに、キーの列が入る"
    rm -rf "$_SD"
}

# scan の規則の精度（2 回目のレビューの指摘）: 秘密でない型・名前・日付・Apex の連結／ 巨大な入力でも遅くならない／ 許可の書式
test_scan_rules2() {
    echo ""; echo -e "${CLR_HEAD}[TEST] metasync.js: scan（規則の精度 その 2）${CLR_RST}"
    _sc_mk
    _sc_put fetched customMetadata/Cfg.md-meta.xml '<CustomMetadata><values><field>Token_Endpoint__c</field><value xsi:type="xsd:string">/services/oauth2/token</value></values><values><field>Token_Expiry__c</field><value xsi:type="xsd:date">2026-12-31</value></values><values><field>Token_Lifetime_Sec__c</field><value xsi:type="xsd:double">86400000.0</value></values><values><field>Api_Key_Updated__c</field><value xsi:type="xsd:dateTime">2026-11-01T00:00:00.000Z</value></values><values><field>External_Key__c</field><value xsi:type="xsd:string">ACC-00123</value></values><values><field>Credential_Name__c</field><value xsi:type="xsd:string">MyNamedCred01</value></values></CustomMetadata>'; _sc_plan A customMetadata/Cfg.md-meta.xml
    _sc_put fetched labels/CustomLabels.labels-meta.xml '<CustomLabels><labels><fullName>Token_Url</fullName><value>/services/oauth2/token</value></labels></CustomLabels>'; _sc_plan A labels/CustomLabels.labels-meta.xml
    _sc_put fetched classes/Soap.cls "public class Soap { String x = '<password>' + pwd + '</password>'; String y = '&client_secret='+creds.get(0).Secret+'&username='; }"; _sc_plan A classes/Soap.cls
    _sc_put fetched classes/Contest.cls "@isTest public class ContestHelper { }"; _sc_plan A classes/Contest.cls
    _sc
    assert_equals "$_RC" "0" "scan: 秘密でない型（日付・数値）・名前・相対パス・Apex の文字列連結は、疑いにしない"
    rm -rf "$_SD"
    # すり抜けない: ラベルの CDATA・Flow の直書き・Contest.cls（名前が test で終わるだけの本番クラス）・UTF-16BE の奇数長
    _sc_mk
    _sc_put fetched labels/CustomLabels.labels-meta.xml '<CustomLabels><labels><fullName>Stripe_Secret</fullName><value><![CDATA[Zq81xKd92mP4wQ]]></value></labels></CustomLabels>'; _sc_plan A labels/CustomLabels.labels-meta.xml
    _sc_put fetched flows/F.flow-meta.xml '<Flow><inputAssignments><field>Api_Key__c</field><value><stringValue>Zq81xKd92mP4wQ</stringValue></value></inputAssignments></Flow>'; _sc_plan A flows/F.flow-meta.xml
    _sc_put fetched classes/Contest.cls "public class Contest { String apiKey = 'q9Zx81LmPq77aa'; }"; _sc_plan A classes/Contest.cls
    printf '\376\377abc' > "$_SD/fetched/force-app/main/default/classes/odd.cls"; _sc_plan A classes/odd.cls
    _sc
    assert_equals "$_RC" "10" "scan: CDATA のラベル・Flow の直書き・Contest.cls は、疑いにする"
    assert_output_contains "$_OUT" "customlabel-secret force-app/main/default/labels/CustomLabels.labels-meta.xml（キー: Stripe_Secret）" "scan: ラベルの CDATA の中の値"
    assert_output_contains "$_OUT" "custommetadata-secret-field force-app/main/default/flows/F.flow-meta.xml（キー: Api_Key__c）" "scan: Flow の stringValue の直書き"
    assert_output_contains "$_OUT" "code-hardcoded-secret force-app/main/default/classes/Contest.cls" "scan: Contest.cls は、テストクラスとして除外しない"
    assert_output_not_contains "$_OUT" "検査するファイルを読めません" "scan: UTF-16BE の奇数長のファイルで、検査全体が失敗しない"
    rm -rf "$_SD"
    # 巨大で閉じタグのない入力でも、遅くならない（線形）。約 3 MB の閉じない <token>・<labels>・<field> を、10 秒以内に検査できる
    _sc_mk
    node -e 'const fs=require("fs");const d=process.argv[1]+"/fetched/force-app/main/default/";fs.mkdirSync(d+"authproviders",{recursive:true});fs.mkdirSync(d+"labels",{recursive:true});fs.mkdirSync(d+"customMetadata",{recursive:true});
      fs.writeFileSync(d+"authproviders/Big.authprovider-meta.xml","<token>x".repeat(300000));
      fs.writeFileSync(d+"labels/CustomLabels.labels-meta.xml","<labels><fullName>a</fullName>".repeat(100000));
      fs.writeFileSync(d+"customMetadata/Big.md-meta.xml","<field>a</field><value>".repeat(150000));' "$_SD"
    _sc_plan A authproviders/Big.authprovider-meta.xml; _sc_plan A labels/CustomLabels.labels-meta.xml; _sc_plan A customMetadata/Big.md-meta.xml
    local t0=$SECONDS
    _sc
    [[ $((SECONDS - t0)) -lt 10 ]] && pass "scan: 閉じタグのない巨大な入力でも、遅くならない（線形）" || fail "scan: 閉じタグのない巨大な入力でも、遅くならない（線形）" "$((SECONDS - t0)) 秒かかった"
    rm -rf "$_SD"
    # 名前の除外は、末尾の「単語」で見る: 本物の鍵の名前（末尾が id・count・time・ms に当たるだけのもの）を、除外しない
    _sc_mk
    local nm
    for nm in Api_Key_Android Token_Guid Secret_Account Api_Token_Account Api_Key_Realtime Password_Onetime Token_Sms Auth_Token_Params Non_Expiring_Token Expiring_Api_Key Expiry_Secret Token_Value Password_Hash; do
        printf '<field>%s__c</field><value xsi:type="xsd:string">Zq81xKd92mP4wQ7aB</value>' "$nm"
    done > "$_SD/fields.txt"
    _sc_put fetched customMetadata/Names.md-meta.xml "<CustomMetadata><values>$(cat "$_SD/fields.txt")</values></CustomMetadata>"; _sc_plan A customMetadata/Names.md-meta.xml
    _sc
    assert_output_contains "$_OUT" "疑い 13 件" "scan: 末尾が id・count・time・ms・expir に当たるだけの本物の鍵の名前を、除外しない（13 個とも疑い）"
    rm -rf "$_SD"; _sc_mk
    for nm in Api_Key_Id Client_Secret_Name Token_Endpoint Token_Expiry Token_Lifetime_Sec Api_Key_Updated Credential_Name Password_Label; do
        printf '<field>%s__c</field><value xsi:type="xsd:string">Zq81xKd92mP4wQ7aB</value>' "$nm"
    done > "$_SD/fields.txt"
    _sc_put fetched customMetadata/Benign.md-meta.xml "<CustomMetadata><values>$(cat "$_SD/fields.txt")</values></CustomMetadata>"; _sc_plan A customMetadata/Benign.md-meta.xml
    _sc
    assert_equals "$_RC" "0" "scan: 最後の単語が id・name・label・endpoint・expiry などの名前は、除外する"
    rm -rf "$_SD"
    # 巨大で、2 乗時間になりやすい形の入力（JWT の eyJ-・属性つきの未完の要素・閉じない CDATA）でも、遅くならない
    _sc_mk
    node -e 'const fs=require("fs");const d=process.argv[1]+"/fetched/force-app/main/default/";fs.mkdirSync(d+"classes",{recursive:true});fs.mkdirSync(d+"authproviders",{recursive:true});
      fs.writeFileSync(d+"classes/Jwt.cls","eyJ-".repeat(600000));
      fs.writeFileSync(d+"authproviders/Attr.authprovider-meta.xml","<token ".repeat(400000));
      fs.writeFileSync(d+"authproviders/Cd.authprovider-meta.xml","<![CDATA[".repeat(300000));' "$_SD"
    _sc_plan A classes/Jwt.cls; _sc_plan A authproviders/Attr.authprovider-meta.xml; _sc_plan A authproviders/Cd.authprovider-meta.xml
    local t1=$SECONDS
    _sc
    [[ $((SECONDS - t1)) -lt 10 ]] && pass "scan: 2 乗時間になりやすい形（eyJ-・<token ・<![CDATA[）の巨大な入力でも、遅くならない" || fail "scan: 2 乗時間になりやすい形の巨大な入力でも、遅くならない" "$((SECONDS - t1)) 秒かかった"
    rm -rf "$_SD"
    # Flow の定数・変数・入力パラメータの直書き／ 動的な値（{!…}）は除く／ base64 の秘密（/ で始まる）／ キーの制御文字
    _sc_mk
    _sc_put fetched flows/G.flow-meta.xml '<Flow><constants><name>API_TOKEN</name><dataType>String</dataType><value><stringValue>Zq81xKd92mP4wQ7aB</stringValue></value></constants><inputParameters><name>password</name><value><stringValue>Zq81xKd92mP4wQ7aB</stringValue></value></inputParameters><constants><name>MY_TOKEN</name><dataType>String</dataType><value><stringValue>KEY-{!varName}-2024</stringValue></value></constants></Flow>'; _sc_plan A flows/G.flow-meta.xml
    _sc_put fetched customMetadata/Slash.md-meta.xml '<CustomMetadata><values><field>Client_Secret__c</field><value xsi:type="xsd:string">/x9Kd82mPq4Zw1Ab+c==</value></values></CustomMetadata>'; _sc_plan A customMetadata/Slash.md-meta.xml
    _sc
    assert_output_contains "$_OUT" "flows/G.flow-meta.xml（キー: API_TOKEN）" "scan: Flow の定数（<name> の後の <stringValue>）の直書き"
    assert_output_contains "$_OUT" "flows/G.flow-meta.xml（キー: password）" "scan: Flow の入力パラメータの直書き"
    assert_output_not_contains "$_OUT" "キー: MY_TOKEN" "scan: Flow の動的な値（{!…} を含む）は、疑いにしない"
    assert_output_contains "$_OUT" "customMetadata/Slash.md-meta.xml（キー: Client_Secret__c）" "scan: / で始まる base64 の秘密も、疑いにする（パスの形だけ除外する）"
    rm -rf "$_SD"; _sc_mk
    node -e 'const fs=require("fs");const d=process.argv[1]+"/fetched/force-app/main/default/customMetadata/";fs.mkdirSync(d,{recursive:true});
      fs.writeFileSync(d+"Ctl.md-meta.xml","<CustomMetadata><values><field>Api_Key__c\n[ERROR] forged\tx</field><value xsi:type=\"xsd:string\">Zq81xKd92mP4wQ7aB</value></values></CustomMetadata>");' "$_SD"
    _sc_plan A customMetadata/Ctl.md-meta.xml
    _sc
    assert_output_not_contains "$_OUT" "^\[ERROR\] forged" "scan: 項目名の改行・タブは、ログ・報告に出さない（行を偽装できない）"
    assert_equals "$(wc -l < "$_SD/rep.tsv" | tr -d ' ')" "1" "scan: 項目名に改行があっても、報告のファイルは 1 行"
    rm -rf "$_SD"
    # Flow の変数の既定値（<name> と <value> の間に 4 つの要素）／ Flow の巨大な入力でも遅くならない／ 数 MB の連続した文字列でも、検査全体が落ちない
    _sc_mk
    _sc_put fetched flows/V.flow-meta.xml '<Flow><variables><name>varPassword</name><dataType>String</dataType><isCollection>false</isCollection><isInput>true</isInput><isOutput>false</isOutput><value><stringValue>Zq81xKd92mP4wQ7aB</stringValue></value></variables></Flow>'; _sc_plan A flows/V.flow-meta.xml
    _sc
    assert_output_contains "$_OUT" "flows/V.flow-meta.xml（キー: varPassword）" "scan: Flow の変数の既定値（間に 4 つの要素）も、疑いにする"
    rm -rf "$_SD"; _sc_mk
    node -e 'const fs=require("fs");const d=process.argv[1]+"/fetched/force-app/main/default/";fs.mkdirSync(d+"flows",{recursive:true});fs.mkdirSync(d+"classes",{recursive:true});
      fs.writeFileSync(d+"flows/Big.flow-meta.xml","<name>a</name><a>b</a>".repeat(200000));
      fs.writeFileSync(d+"classes/Huge.cls","var u=\"https://x/y?token="+"a1".repeat(8000000)+"\"");' "$_SD"
    _sc_plan A flows/Big.flow-meta.xml; _sc_plan A classes/Huge.cls
    local t2=$SECONDS
    _sc
    [[ $((SECONDS - t2)) -lt 20 ]] && pass "scan: Flow の <name> の繰り返しの巨大な入力でも、遅くならない" || fail "scan: Flow の <name> の繰り返しの巨大な入力でも、遅くならない" "$((SECONDS - t2)) 秒かかった"
    assert_output_not_contains "$_OUT" "RangeError" "scan: 数 MB の連続した文字列でも、スタック溢れで検査全体が落ちない"
    assert_equals "$_RC" "10" "scan: 規則が失敗したファイルは、「検査できなかった」疑いとして扱う（黙って通さない。終了コード 10）"
    assert_output_contains "$_OUT" "検査できなかった規則: url-secret force-app/main/default/classes/Huge.cls" "scan: 検査できなかった規則名が出る"
    # 許可の一覧の「scan-error パス」で外せる／ 変更（M）で、手元（変更前）の側も巨大でも、検査全体が落ちない
    printf 'scan-error force-app/main/default/classes/Huge.cls\n' > "$_SD/allow.txt"
    _sc --allow "$_SD/allow.txt"
    assert_equals "$_RC" "0" "scan: 確かめた scan-error は、許可の一覧で外せる"
    mkdir -p "$_SD/repo/force-app/main/default/classes"; cp "$_SD/fetched/force-app/main/default/classes/Huge.cls" "$_SD/repo/force-app/main/default/classes/Huge.cls"
    : > "$_SD/plan.tsv"; _sc_plan M classes/Huge.cls
    _sc
    assert_equals "$_RC" "10" "scan: 変更（M）で、手元の側も巨大でも、検査全体が落ちず、scan-error になる（終了コード 1 にならない）"
    rm -rf "$_SD"
    # 項目名のバックスラッシュで、画面のログの行を偽装できない（echo -e の解釈を受けない）
    _sc_mk
    node -e 'const fs=require("fs");const d=process.argv[1]+"/fetched/force-app/main/default/customMetadata/";fs.mkdirSync(d,{recursive:true});
      fs.writeFileSync(d+"Bs.md-meta.xml","<CustomMetadata><values><field>Api_Key__c\\n[ERROR] forged \\c</field><value xsi:type=\"xsd:string\">Zq81xKd92mP4wQ7aB</value></values></CustomMetadata>");' "$_SD"
    _sc_plan A customMetadata/Bs.md-meta.xml
    _sc
    assert_output_not_contains "$_OUT" "Api_Key__c\\\\n" "scan: 項目名のバックスラッシュは、キーに残さない"
    rm -rf "$_SD"
    # 許可の一覧: 規則名の誤記は、黙って効かない行にせず、中断する
    _sc_mk
    _sc_put fetched classes/A.cls "public class A { String apiKey = 'abcdef123456'; }"; _sc_plan A classes/A.cls
    printf 'code-hardcoded force-app/main/default/classes/*\n' > "$_SD/allow.txt"
    _sc --allow "$_SD/allow.txt"
    assert_equals "$_RC" "1" "scan: 許可の規則名の誤記 → 中断"
    assert_output_contains "$_OUT" "規則名が正しくありません" "scan: 規則名の誤記の案内が出る"
    printf '\357\273\277code-hardcoded-secret force-app/main/default/classes/*\n' > "$_SD/allow.txt"
    _sc --allow "$_SD/allow.txt"
    assert_equals "$_RC" "0" "scan: 先頭に BOM があっても、許可が効く"
    rm -rf "$_SD"
    # 許可の一覧の書式: 語が 4 つ以上（パスの空白）は、黙って別の意味にせず、中断する。* で書けば効く
    _sc_mk
    _sc_put fetched "customMetadata/sp ace/B C.md-meta.xml" '<CustomMetadata><values><field>Api_Key__c</field><value xsi:type="xsd:string">Zq81xKd92mP4wQ7aB</value></values></CustomMetadata>'; _sc_plan A "customMetadata/sp ace/B C.md-meta.xml"
    printf '* force-app/main/default/customMetadata/sp ace/B C.md-meta.xml\n' > "$_SD/allow.txt"
    _sc --allow "$_SD/allow.txt"
    assert_equals "$_RC" "1" "scan: 許可の行に空白があるパス（語が 4 つ以上）→ 中断（黙って別の意味にしない）"
    assert_output_contains "$_OUT" "パスに空白があるときは" "scan: 空白のパスは、ワイルドカードで書くよう案内する"
    printf '* force-app/main/default/customMetadata/sp*ace/B*C.md-meta.xml\n' > "$_SD/allow.txt"
    _sc --allow "$_SD/allow.txt"
    assert_equals "$_RC" "0" "scan: 空白の部分を * で書けば、許可が効く"
    rm -rf "$_SD"
}

test_basic_ops
test_keep_files
test_scope
test_guards
test_aborts
test_apply
test_detect
test_detect_table
test_fingerprint
test_fingerprint_token_refresh
test_fingerprint_hardening
test_fpcompare
test_fingerprint_table
test_scan
test_scan_rules
test_scan_rules2

print_summary
