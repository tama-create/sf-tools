#!/bin/bash
# ==============================================================================
# test_metasync-js.sh - lib/metasync.js（sf-metasync.sh の鏡像: plan / apply）の単体テスト
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

test_basic_ops
test_keep_files
test_scope
test_guards
test_aborts
test_apply

print_summary
