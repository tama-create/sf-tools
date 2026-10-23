#!/bin/bash
# ==============================================================================
# test_docs_stamps.sh - 冒頭コメントと、文書の見直しの印（スタンプ）が、合っているかの検査
# ==============================================================================
# 冒頭コメント（階層 1）が変わったのに、それに基づく文書（階層 2・3）が見直されないまま残ることを、検出する。
# 仕組みと使い方は、tests/docs-stamp.sh の冒頭コメントを参照。文書を自動で書き換えることは、しない（検出だけ）。
#   1. 実際の印（doc/doc-stamps.txt）が、いまの冒頭コメントと合っている
#   2. 自己テスト: 仮のリポジトリで、冒頭コメントを変えると検出し、見直し（--update）で直ることを確かめる
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== 文書の見直しの印（スタンプ） ===${CLR_RST}"

STAMP_TOOL="$SF_TOOLS_DIR/tests/docs-stamp.sh"

test_stamps_are_current() {
    local out
    out=$(bash "$STAMP_TOOL" --check 2>&1); local ec=$?
    if [[ $ec -eq 0 ]]; then pass "文書の見直しの印が、いまの冒頭コメントと合っている"
    else fail "文書の見直しの印が、いまの冒頭コメントと合っている" "$(echo "$out" | head -6)"; fi
}

# 仮のリポジトリを作る: bin/sf-a.sh・bin/sf-b.sh（冒頭コメントつき）、site/p.html、印の一覧。引数: 場所
_make_sample() {
    local d="$1"
    mkdir -p "$d/tests" "$d/doc" "$d/bin" "$d/site"
    cp "$STAMP_TOOL" "$d/tests/docs-stamp.sh"
    local c
    for c in a b; do
        cat > "$d/bin/sf-$c.sh" <<EOF
#!/bin/bash
# ==============================================================================
# sf-$c.sh - サンプル
# ==============================================================================
# 概要 $c
#   --opt-$c : 説明
# ==============================================================================
echo $c
EOF
    done
    echo "<html><body>p</body></html>" > "$d/site/p.html"
    printf 'site/p.html | bin/sf-a.sh | - | -\nsite/p.html | bin/sf-b.sh | - | -\n' > "$d/doc/doc-stamps.txt"
}

test_stamps_selftest() {
    local d out ec
    d=$(mktemp -d "${TMPDIR:-/tmp}/docs-stamps-XXXX")
    _make_sample "$d"

    out=$(bash "$d/tests/docs-stamp.sh" --check 2>&1); ec=$?
    [[ $ec -ne 0 && "$out" == *"まだ見直していません"* ]] && pass "自己テスト: 見直していない（印が -）と、検出する" || fail "自己テスト: 見直していない（印が -）と、検出する" "$out"

    bash "$d/tests/docs-stamp.sh" --update site/p.html -y >/dev/null 2>&1
    out=$(bash "$d/tests/docs-stamp.sh" --check 2>&1); ec=$?
    [[ $ec -eq 0 ]] && pass "自己テスト: 見直して印を付けると、問題なしになる" || fail "自己テスト: 見直して印を付けると、問題なしになる" "$out"

    # 冒頭コメントを変える → 検出する
    sed -i.bak 's/--opt-a : 説明/--opt-a : 説明を変えた/' "$d/bin/sf-a.sh" && rm -f "$d/bin/sf-a.sh.bak"
    out=$(bash "$d/tests/docs-stamp.sh" --check 2>&1); ec=$?
    [[ $ec -ne 0 && "$out" == *"bin/sf-a.sh の冒頭コメントが、見直したあとで変わりました"* ]] && pass "自己テスト: 冒頭コメントが変わると、検出する" || fail "自己テスト: 冒頭コメントが変わると、検出する" "$out"
    [[ "$out" != *"bin/sf-b.sh"* ]] && pass "自己テスト: 変わっていない sf-b.sh は、指摘しない" || fail "自己テスト: 変わっていない sf-b.sh は、指摘しない" "$out"

    # コードの本体（冒頭コメントの外）だけを変えても、検出しない
    sed -i.bak 's/--opt-a : 説明を変えた/--opt-a : 説明/' "$d/bin/sf-a.sh" && rm -f "$d/bin/sf-a.sh.bak"
    sed -i.bak 's/^echo a$/echo aa/' "$d/bin/sf-a.sh" && rm -f "$d/bin/sf-a.sh.bak"
    out=$(bash "$d/tests/docs-stamp.sh" --check 2>&1); ec=$?
    [[ $ec -eq 0 ]] && pass "自己テスト: 冒頭コメントの外（コード本体）の変更は、検出しない" || fail "自己テスト: 冒頭コメントの外（コード本体）の変更は、検出しない" "$out"

    # 新しいコマンドが、どの文書の基にもなっていない → 検出する
    cp "$d/bin/sf-b.sh" "$d/bin/sf-c.sh"
    out=$(bash "$d/tests/docs-stamp.sh" --check 2>&1); ec=$?
    [[ $ec -ne 0 && "$out" == *"bin/sf-c.sh: どの文書の基にもなっていません"* ]] && pass "自己テスト: 文書の基になっていない新しいコマンドを、検出する" || fail "自己テスト: 文書の基になっていない新しいコマンドを、検出する" "$out"
    rm -f "$d/bin/sf-c.sh"

    # 文書が消えた → 検出する
    rm -f "$d/site/p.html"
    out=$(bash "$d/tests/docs-stamp.sh" --check 2>&1); ec=$?
    [[ $ec -ne 0 && "$out" == *"文書がない"* ]] && pass "自己テスト: 文書が消えたら、検出する" || fail "自己テスト: 文書が消えたら、検出する" "$out"

    # --update で、一覧にない文書は、拒否する
    out=$(bash "$d/tests/docs-stamp.sh" --update site/none.html -y 2>&1); ec=$?
    [[ $ec -ne 0 ]] && pass "自己テスト: 一覧にない文書の --update は、拒否する" || fail "自己テスト: 一覧にない文書の --update は、拒否する" "$out"
    rm -rf "$d"
}

test_stamps_are_current
test_stamps_selftest

print_summary
