#!/bin/bash
# ==============================================================================
# test_sf-typecheck.sh - sf-typecheck.sh / lib/typecheck.js のテスト
# ==============================================================================
# 実際の組織には、つながない。sf は、モック（SF_TYPECHECK_CMD で、差し替える）。
# 確認すること: 安全の確認（予約名・本番・GitHub Actions）・--list・結果の表の形式・許可した sf のコマンドだけを呼ぶこと
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-typecheck.sh ===${CLR_RST}"

# node が無い環境（WSL など）では、実行できない（lib/typecheck.js は、Node で動く）。CI の各 OS には、node がある
if ! command -v node > /dev/null 2>&1; then  # 存在確認のため run 不使用
    echo "  [SKIP] node が見つからないため、このテストは、スキップします"
    print_summary
    exit 0
fi

# 結果を返すだけの sf のモック。引数を記録する。FAKE_FAIL_DELETE=1 のときは、削除（--pre-destructive-changes）を失敗させる
_create_fake_sf() {
    cat > "$1/fakesf" << 'FEOF'
#!/bin/bash
echo "$*" >> "${FAKE_SF_LOG:-/dev/null}"
if [[ "$*" == *"--pre-destructive-changes"* && "${FAKE_FAIL_DELETE:-}" == "1" ]]; then
    echo '{"status":1,"message":"insufficient access rights on cross-reference id"}'
    exit 1
fi
echo '{"status":0,"result":{"success":true}}'
exit 0
FEOF
    chmod +x "$1/fakesf"
}

_run_typecheck() {   # 引数: mb mh td [追加の引数...]  （環境変数は、呼び出し側で設定）
    local mb="$1" mh="$2" td="$3"; shift 3
    ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$mh/sf-tools/bin/sf-typecheck.sh" "$@" 2>&1 )
}

test_typecheck_help_and_list() {
    local td mb mh; setup_std_env td mb mh
    create_mock_sf "$mb"
    local out; out=$(_run_typecheck "$mb" "$mh" "$td" --help)
    assert_exit_ok "$?" "--help → 正常終了"
    assert_output_contains "$out" "validate-only" "--help → オプションの説明が表示された"
    out=$(_run_typecheck "$mb" "$mh" "$td" --list -y)
    assert_exit_ok "$?" "--list → 正常終了"
    assert_output_contains "$out" "ApexClass" "--list → 種類の一覧が表示された"
    assert_output_contains "$out" "LightningComponentBundle" "--list → LWC も含まれる"
    [[ ! -s "$MOCK_CALL_LOG" ]] && pass "--list → 組織には、接続しない（sf を呼ばない）" || fail "--list → sf を呼ばない" "$(cat "$MOCK_CALL_LOG")"
    teardown "$td" "$mb" "$mh"
}

test_typecheck_refuses_reserved_alias() {
    local td mb mh a out; setup_std_env td mb mh
    create_mock_sf "$mb"
    for a in prod staging develop main; do
        out=$(_run_typecheck "$mb" "$mh" "$td" --org "$a" -y)
        assert_exit_fail "$?" "予約名 ${a} → 拒否"
    done
    assert_output_contains "$out" "共有環境の予約名" "予約名 → 理由が表示された"
    teardown "$td" "$mb" "$mh"
}

test_typecheck_refuses_missing_org_and_actions() {
    local td mb mh out; setup_std_env td mb mh
    create_mock_sf "$mb"
    out=$(_run_typecheck "$mb" "$mh" "$td" -y)
    assert_exit_fail "$?" "--org なし → 拒否"
    out=$(GITHUB_ACTIONS=true _run_typecheck "$mb" "$mh" "$td" --org mydev -y)
    assert_exit_fail "$?" "GitHub Actions 上 → 拒否"
    assert_output_contains "$out" "GitHub Actions" "GitHub Actions 上 → 理由が表示された"
    teardown "$td" "$mb" "$mh"
}

test_typecheck_refuses_production_and_unknown() {
    local td mb mh out; setup_std_env td mb mh
    create_mock_sf "$mb"
    local prod='{"status":0,"result":{"records":[{"Id":"00D000000000001AAA","Name":"Prod","IsSandbox":false,"OrganizationType":"Enterprise Edition","TrialExpirationDate":null}]}}'
    out=$(MOCK_SF_ORG_INFO="$prod" _run_typecheck "$mb" "$mh" "$td" --org mydev -y)
    assert_exit_fail "$?" "本番の組織 → 拒否"
    assert_output_contains "$out" "本番の組織" "本番の組織 → 理由が表示された"
    out=$(MOCK_SF_ORG_QUERY_EXIT=1 _run_typecheck "$mb" "$mh" "$td" --org mydev -y)
    assert_exit_fail "$?" "組織の種類を読み取れない → 拒否（推測しない）"
    teardown "$td" "$mb" "$mh"
}

test_typecheck_full_run_ok() {
    local td mb mh out; setup_std_env td mb mh
    create_mock_sf "$mb"; _create_fake_sf "$mb"
    local res="$td/result.txt"
    out=$(FAKE_SF_LOG="$mb/fake.log" SF_TYPECHECK_CMD="bash $mb/fakesf" \
        MOCK_SF_ORG_INFO='{"status":0,"result":{"records":[{"Id":"00D000000000001AAA","Name":"Dev","IsSandbox":false,"OrganizationType":"Developer Edition","TrialExpirationDate":null}]}}' \
        _run_typecheck "$mb" "$mh" "$td" --org mydev --only ApexClass,CustomLabel --out "$res" -y)
    assert_exit_ok "$?" "全部 ok → 正常終了"
    assert_file_exists "$res" "結果の表が出力された"
    assert_file_contains "$res" "$(printf 'ApexClass\tok\tok')" "結果の表: ApexClass が release ok / delete ok"
    assert_file_contains "$res" "$(printf 'CustomLabel\tok\tok')" "結果の表: CustomLabel が release ok / delete ok"
    # 呼んだ sf は、deploy start / deploy validate だけ（--mode full は、start のみのはず）
    local bad
    bad=$(awk '$0 !~ /^project deploy (start|validate) /' "$mb/fake.log")
    assert_equals "$bad" "" "許可した sf のコマンド（project deploy start / validate）だけを呼ぶ"
    assert_file_contains "$mb/fake.log" "--pre-destructive-changes" "削除は、destructive changes で行う"
    assert_file_contains "$mb/fake.log" "--target-org mydev" "指定した組織だけを対象にする"
    teardown "$td" "$mb" "$mh"
}

# 回帰: LWC のサンプル（lwc/sfToolsE2eMinLwc/。コンポーネント名は先頭が小文字）が、安全の確認で中断していた
test_typecheck_lwc_passes_safety_check() {
    local td mb mh out rc; setup_std_env td mb mh
    create_mock_sf "$mb"; _create_fake_sf "$mb"
    local res="$td/result.txt"
    out=$(FAKE_SF_LOG="$mb/fake.log" SF_TYPECHECK_CMD="bash $mb/fakesf"         MOCK_SF_ORG_INFO='{"status":0,"result":{"records":[{"Id":"00D000000000001AAA","Name":"Dev","IsSandbox":false,"OrganizationType":"Developer Edition","TrialExpirationDate":null}]}}'         _run_typecheck "$mb" "$mh" "$td" --org mydev --only LightningComponentBundle --out "$res" -y); rc=$?
    assert_exit_ok "$rc" "LWC のサンプル → 安全の確認で中断せず、正常終了"
    assert_file_contains "$res" "$(printf 'LightningComponentBundle	ok	ok')" "結果の表: LightningComponentBundle が release ok / delete ok"
    assert_file_contains "$mb/fake.log" "--target-org mydev" "LWC のサンプルを、指定した組織へリリースした"
    teardown "$td" "$mb" "$mh"
}

test_typecheck_delete_failure_reported() {
    local td mb mh out; setup_std_env td mb mh
    create_mock_sf "$mb"; _create_fake_sf "$mb"
    local res="$td/result.txt"
    out=$(FAKE_FAIL_DELETE=1 SF_TYPECHECK_CMD="bash $mb/fakesf" \
        MOCK_SF_ORG_INFO='{"status":0,"result":{"records":[{"Id":"00D000000000001AAA","Name":"Dev","IsSandbox":false,"OrganizationType":"Developer Edition","TrialExpirationDate":null}]}}' \
        _run_typecheck "$mb" "$mh" "$td" --org mydev --only ApexClass --out "$res" -y)
    assert_exit_ok "$?" "削除できない種類がある → 警告を出して、正常終了（結果の表で判断する）"
    assert_file_contains "$res" "$(printf 'ApexClass\tok\tng')" "結果の表: 削除に失敗 → delete ng"
    assert_file_contains "$res" "insufficient access rights" "結果の表: 備考に、失敗の理由が入る"
    teardown "$td" "$mb" "$mh"
}

test_typecheck_coverage() {
    local td mb mh out; setup_std_env td mb mh
    create_mock_sf "$mb"
    printf '# コメント\nTypeA\nTypeB\nTypeC\nTypeD\nTypeE\nCustomLabels\n' > "$td/cs.txt"
    printf '# コメント\nTypeA\tok\tok\t\nTypeB\tok\tunknown\t\nTypeC\tlimited\tok\t条件\nTypeD\tunknown\tunknown\t\nCustomLabel\tok\tok\t\nCustomLabels\tunknown\tunknown\t\nOther\tok\tok\t\n' > "$td/cap.txt"
    out=$(SF_TYPECHECK_CHANGESET_FILE="$td/cs.txt" SF_CHECK_CAPABILITY_FILE="$td/cap.txt" _run_typecheck "$mb" "$mh" "$td" --coverage -y)
    assert_exit_ok "$?" "--coverage → 正常終了（--org なしでも動く）"
    assert_output_contains "$out" "変更セットで扱える種類: 6" "--coverage: 一覧の数（コメント・空行は除く）"
    assert_output_contains "$out" "確認済み *: *2" "--coverage: 両方 ok は 2（TypeA と、別名で引いた CustomLabels）"
    assert_output_contains "$out" "リリースのみ確認済み.*: *1" "--coverage: リリースのみは 1"
    assert_output_contains "$out" "条件つき.*: *1" "--coverage: 条件つきは 1"
    assert_output_contains "$out" "判定できない.*: *1" "--coverage: 判定できないは 1"
    assert_output_contains "$out" "まだ試していない *: *1" "--coverage: 未確認は 1（表にない TypeE）"
    assert_output_contains "$out" "TypeE" "--coverage: 未確認の一覧に TypeE が出る"
    [[ ! -s "$MOCK_CALL_LOG" ]] && pass "--coverage → 組織には、接続しない（sf を呼ばない）" || fail "--coverage → sf を呼ばない" "$(cat "$MOCK_CALL_LOG")"
    teardown "$td" "$mb" "$mh"
}

test_typecheck_shipped_changeset_list() {
    local f="$SF_TOOLS_DIR/config/changeset-types.txt" bad
    assert_file_exists "$f" "同梱の変更セット対応の種類の一覧がある"
    # 種類名だけの行（英数字・アンダースコア）。重複していない
    bad=$(awk '$0 !~ /^#/ && $0 != "" && $0 !~ /^[A-Za-z0-9_]+$/' "$f")
    assert_equals "$bad" "" "同梱の変更セット対応の一覧: 全行が、種類名の形式"
    bad=$(awk '$0 !~ /^#/ && $0 != "" { c[$0]++ } END { for (k in c) if (c[k] > 1) print k }' "$f")
    assert_equals "$bad" "" "同梱の変更セット対応の一覧: 種類が重複していない"
    # 主要な種類が含まれる（取得に失敗して、空の一覧になっていないことの確認）
    assert_file_contains "$f" "ApexClass" "同梱の変更セット対応の一覧: ApexClass を含む"
    assert_file_contains "$f" "CustomObject" "同梱の変更セット対応の一覧: CustomObject を含む"
}

test_typecheck_warns_first() {
    local td mb mh out; setup_std_env td mb mh
    create_mock_sf "$mb"
    # --list・--coverage（読み取りのみ）でも、管理者向けの警告を、最初に表示する（確認は、不要）
    out=$(_run_typecheck "$mb" "$mh" "$td" --list -y)
    assert_output_contains "$out" "このコマンドは管理者専用です" "--list: 管理者向けの警告が出る"
    out=$(_run_typecheck "$mb" "$mh" "$td" --coverage -y)
    assert_output_contains "$out" "このコマンドは管理者専用です" "--coverage: 管理者向けの警告が出る"
    # 拒否される場合（予約名）でも、警告が、先に出る
    out=$(_run_typecheck "$mb" "$mh" "$td" --org prod -y)
    assert_output_contains "$out" "このコマンドは管理者専用です" "予約名で拒否される場合も、警告が、先に出る"
    # 警告は、拒否の理由（ログ）より前にある
    local w r
    w=$(printf '%s\n' "$out" | grep -n "このコマンドは管理者専用です" | head -1 | cut -d: -f1)
    r=$(printf '%s\n' "$out" | grep -n "予約名" | head -1 | cut -d: -f1)
    [[ -n "$w" && -n "$r" && "$w" -lt "$r" ]] && pass "警告は、拒否の理由より前に表示される" || fail "警告は、拒否の理由より前に表示される" "warn=$w reason=$r"
    # sf（組織）に、何も呼ばない
    [[ ! -s "$MOCK_CALL_LOG" ]] && pass "警告の表示までに、sf を呼ばない" || fail "警告の表示までに、sf を呼ばない" "$(cat "$MOCK_CALL_LOG")"
    teardown "$td" "$mb" "$mh"
}

test_typecheck_confirms_before_running() {
    local td mb mh out; setup_std_env td mb mh
    create_mock_sf "$mb"
    # 警告のあと、確認する。N で、何も実行しない（--list の一覧も、--coverage の表も、出ない）
    out=$(printf 'n\n' | _run_typecheck "$mb" "$mh" "$td" --list)
    assert_exit_fail "$?" "--list: 確認で N → 中断（終了コードが 0 以外）"
    assert_output_contains "$out" "続行しますか" "--list: 警告のあとに、確認が出る"
    assert_output_not_contains "$out" "LightningComponentBundle" "--list: N なら、一覧は出ない"
    out=$(printf 'n\n' | _run_typecheck "$mb" "$mh" "$td" --coverage)
    assert_exit_fail "$?" "--coverage: 確認で N → 中断"
    echo "$out" | grep -q "変更セットで扱える種類" && fail "--coverage: N なら、表は出ない" || pass "--coverage: N なら、表は出ない"
    # Y なら、実行する
    out=$(printf 'Y\n' | _run_typecheck "$mb" "$mh" "$td" --coverage)
    assert_exit_ok "$?" "--coverage: 確認で Y → 実行する"
    assert_output_contains "$out" "変更セットで扱える種類" "--coverage: Y なら、表が出る"
    # 実行（組織への接続）の前に、確認する: 確認で N なら、sf を呼ばない
    out=$(printf 'n\n' | _run_typecheck "$mb" "$mh" "$td" --org mydev)
    assert_exit_fail "$?" "--org: 確認で N → 中断"
    [[ ! -s "$MOCK_CALL_LOG" ]] && pass "--org: 確認で N なら、sf を呼ばない（組織に接続しない）" || fail "--org: 確認で N なら、sf を呼ばない" "$(cat "$MOCK_CALL_LOG")"
    teardown "$td" "$mb" "$mh"
}

test_typecheck_js_syntax_and_safety() {
    node --check "$SF_TOOLS_DIR/lib/typecheck.js" 2>/dev/null && pass "lib/typecheck.js: 構文が正しい" || fail "lib/typecheck.js: 構文が正しい"
    local out; out=$(node "$SF_TOOLS_DIR/lib/typecheck.js" --org prod --work "${TMPDIR:-/tmp}/tc-test-x" 2>&1)
    assert_exit_fail "$?" "lib/typecheck.js 単体でも、予約名は拒否する"
    assert_output_contains "$out" "予約名" "lib/typecheck.js: 予約名の拒否の理由が表示された"

    # 引数の検査は、--list より先（以前は、--list が先に終了し、--mode x でも 0 だった）
    node "$SF_TOOLS_DIR/lib/typecheck.js" --list > /dev/null 2>&1
    assert_exit_ok "$?" "lib/typecheck.js --list: 終了コード 0"
    out=$(node "$SF_TOOLS_DIR/lib/typecheck.js" --list --mode x 2>&1)
    assert_exit_fail "$?" "lib/typecheck.js --list --mode x: --mode の誤りは、エラー"
    assert_output_contains "$out" "mode は full または validate" "lib/typecheck.js --list --mode x: 理由が表示された"
    out=$(node "$SF_TOOLS_DIR/lib/typecheck.js" --list --bogus 2>&1)
    assert_exit_fail "$?" "lib/typecheck.js --list --bogus: 不明なオプションは、エラー"
    out=$(node "$SF_TOOLS_DIR/lib/typecheck.js" --list --mode 2>&1)
    assert_exit_fail "$?" "lib/typecheck.js --list --mode（値なし）: エラー"
    assert_output_contains "$out" "mode の値がありません" "lib/typecheck.js: 値のないオプションの理由が表示された"
    out=$(node "$SF_TOOLS_DIR/lib/typecheck.js" --org --work "${TMPDIR:-/tmp}/tc-test-x" 2>&1)
    assert_exit_fail "$?" "lib/typecheck.js --org（値なし）: 次の --work を値として取らず、エラー"

    # sf に渡す引数の引用（POSIX）: ' を '\'' にする（以前は ''' になり、' を含む引数が壊れた）。quote 関数を取り出して確かめる
    out=$(node -e '
        const src = require("fs").readFileSync(process.argv[1], "utf8");
        const m = src.match(/function quote\(a\) \{[\s\S]*?\n\}/);
        Object.defineProperty(process, "platform", { value: "linux" });
        const quote = eval("(" + m[0] + ")");
        process.stdout.write(quote("a" + String.fromCharCode(39) + "b c"));
    ' "$SF_TOOLS_DIR/lib/typecheck.js" 2>&1)
    assert_equals "$out" "'a'\\''b c'" "quote（POSIX）: ' を '\\'' にして、単引用符で囲む"
    assert_equals "$(eval "printf '%s' $out")" "a'b c" "quote（POSIX）: シェルで、元の文字列に戻る"
}

test_typecheck_help_and_list
test_typecheck_refuses_reserved_alias
test_typecheck_refuses_missing_org_and_actions
test_typecheck_refuses_production_and_unknown
test_typecheck_full_run_ok
test_typecheck_lwc_passes_safety_check
test_typecheck_delete_failure_reported
test_typecheck_coverage
test_typecheck_warns_first
test_typecheck_confirms_before_running
test_typecheck_shipped_changeset_list
test_typecheck_js_syntax_and_safety

print_summary
