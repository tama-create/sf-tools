#!/bin/bash
# ==============================================================================
# test_run-tests.sh - tests/run_tests.sh の --shard（テストファイルを N 組に分けて、I 番目だけ実行する）と --changed のテスト
# ==============================================================================
# 実際のテストは動かさない（SF_TEST_LIST_ONLY=1: 対象のファイル名を表示して終わる）。
# GitHub Actions の Windows で、複数のジョブに分けて並列に動かすときの、分け方が正しいことを確かめる。
#
# 【テストケース】
#   1. N=1 は、分けない場合と、同じ
#   2. N 組を全部合わせると、全ファイルが、ちょうど 1 回ずつ（漏れも重複もない）
#   3. 分け方は、いつも同じ（どの環境でも、同じジョブに、同じファイルが入る）
#   4. 重い 3 つのファイルは、別の組に入る（1 つの組に、重いものが、集まらない）
#   5. 不正な指定は、終了コード 2
#   6. 組の数が、ファイルの数より多いとき、空の組は、何もせず、成功で終わる
#   7. SF_TEST_SKIP_INTEGRATION=1 と組み合わせても、結合テストは、外れたまま
#   8. --changed は、まだ git add していない新しいファイルに対応するテストも選ぶ。.gitignore の対象は数えない
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== run_tests.sh --shard・--changed ===${CLR_RST}"

RT="$SF_TOOLS_DIR/tests/run_tests.sh"
# 対象のファイル名を、1 行ずつ返す（実行はしない）。引数: run_tests.sh への引数
# 呼び出し元の環境（CI の Linux は SF_TEST_SKIP_INTEGRATION=1）に左右されないよう、既定では外す。外す指定を調べるときは LIST_SKIP=1
_list() { SF_TEST_SKIP_INTEGRATION="${LIST_SKIP:-}" SF_TEST_NO_WSL=1 SF_TEST_LIST_ONLY=1 bash "$RT" "$@" 2>/dev/null; }

test_shard_partition() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 分け方（N=1 は同じ・全部合わせて、ちょうど 1 回ずつ・いつも同じ）${CLR_RST}"
    local all one n i merged b; b=$(mktemp -d "${TMPDIR:-/tmp}/test-shard-XXXX")
    all=$(_list | sort)
    [[ -n "$all" ]] && pass "全件の一覧を取得できる（$(printf '%s\n' "$all" | wc -l | tr -d ' ') 件）" || fail "全件の一覧を取得できる"
    one=$(_list --shard 1/1 | sort)
    assert_equals "$one" "$all" "N=1（1/1）は、分けない場合と、同じ"
    for n in 6; do
        merged=""
        for i in $(seq 1 "$n"); do
            _list --shard "$i/$n" > "$b/s.$n.$i"
            merged="${merged}$(cat "$b/s.$n.$i")"$'\n'
        done
        assert_equals "$(printf '%s' "$merged" | sed '/^$/d' | sort)" "$all" "N=${n}: 全部合わせると、全ファイルが、ちょうど 1 回ずつ（漏れも重複もない）"
    done
    # いつも同じ分け方
    _list --shard 2/6 > "$b/again.txt"
    assert_equals "$(cat "$b/again.txt")" "$(cat "$b/s.6.2")" "同じ指定は、いつも、同じファイルになる（再現できる）"
    # 重い 3 つ（test_integration-init.sh / -init3.sh / -init2.sh）は、N=6 で、別々の組に入る
    local heavy_shards=""
    for f in test_integration-init.sh test_integration-init3.sh test_integration-init2.sh; do
        for i in 1 2 3 4 5 6; do
            grep -qx "$f" "$b/s.6.$i" && heavy_shards="${heavy_shards}${i} "
        done
    done
    assert_equals "$(printf '%s\n' $heavy_shards | sort -u | wc -l | tr -d ' ')" "3" "重い 3 つの結合テストは、別々の組に入る（1 つの組に、集まらない）"
    teardown "$b"
}

test_shard_invalid() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 不正な指定（終了コード 2）${CLR_RST}"
    local rc
    for spec in 0/3 4/3 a/3 3 1/0 x; do
        SF_TEST_NO_WSL=1 SF_TEST_LIST_ONLY=1 bash "$RT" --shard "$spec" > /dev/null 2>&1; rc=$?
        assert_equals "$rc" "2" "--shard ${spec} は、終了コード 2"
    done
}

test_shard_empty_and_skip() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 空の組・結合テストを外す指定との組み合わせ${CLR_RST}"
    local out rc
    out=$(_list --shard 100/100); rc=$?
    assert_exit_ok "$rc" "ファイルの数より多い組の、後ろの組（100/100）は、成功で終わる"
    assert_equals "$out" "" "空の組は、何も実行しない（一覧が空）"
    out=$(LIST_SKIP=1 _list --shard 1/1)
    if printf '%s\n' "$out" | grep -E '^test_integration' | grep -qv '^test_integration-coverage.sh$'; then
        fail "SF_TEST_SKIP_INTEGRATION=1 と --shard の組み合わせで、結合テスト L1 が、外れたまま"
    else
        pass "SF_TEST_SKIP_INTEGRATION=1 と --shard の組み合わせで、結合テスト L1 が、外れたまま"
    fi
}

# --changed は、まだ git add していない新しいファイルも、対象に入れる（.gitignore の対象は除く）
#   本物のリポジトリに、追跡していないファイルを作らないため、一時フォルダに、run_tests.sh だけを置いた小さなリポジトリを作って確かめる
test_changed_untracked() {
    echo ""; echo -e "${CLR_HEAD}[TEST] --changed: まだ git add していない新しいファイル${CLR_RST}"
    local repo out
    repo=$(mktemp -d "${TMPDIR:-/tmp}/test-rt-changed-XXXX")
    mkdir -p "$repo/tests" "$repo/lib"
    cp "$RT" "$repo/tests/run_tests.sh"
    printf 'logs/\n' > "$repo/.gitignore"   # run_tests.sh が書く logs/ を、追跡していないファイルに数えないため（本物と同じ）
    (
        cd "$repo" || exit 1
        git init -q && git config core.autocrlf false && git add -A \
            && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m init
    ) || { fail "--changed: 一時のリポジトリを作れた"; rm -rf "$repo"; return; }

    # 追跡していない新しいファイル（lib/apexlog.js）に対応するテストが、選ばれる
    echo "x" > "$repo/lib/apexlog.js"
    out=$(SF_TEST_SKIP_INTEGRATION="" SF_TEST_NO_WSL=1 SF_TEST_LIST_ONLY=1 bash "$repo/tests/run_tests.sh" --changed 2>/dev/null)
    assert_output_contains "$out" "対象テスト: test_apexlog-js.sh" "まだ git add していない新しいファイルに対応するテストを、選ぶ"

    # .gitignore の対象は、追跡していないファイルに数えない（対応するテストなし → 全件）
    printf 'logs/\nlib/apexlog.js\n' > "$repo/.gitignore"
    git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -am ignore
    out=$(SF_TEST_SKIP_INTEGRATION="" SF_TEST_NO_WSL=1 SF_TEST_LIST_ONLY=1 bash "$repo/tests/run_tests.sh" --changed 2>/dev/null)
    assert_output_contains "$out" "変更ファイルに対応するテストなし" ".gitignore の対象のファイルは、追跡していないファイルに数えない"
    rm -rf "$repo"
}

test_shard_partition
test_shard_invalid
test_shard_empty_and_skip
test_changed_untracked

print_summary
