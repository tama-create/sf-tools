#!/bin/bash
# ==============================================================================
# test_docs.sh - Markdown 文書の見出しの番号のテスト
# ==============================================================================
# CLAUDE.md の決まり: 「`*.md` ファイルには必ず項目番号を付けること（大項目 `1`・中項目 `1.1`・小項目 `1.1.1`）」を、機械で確かめる。
# （HTML の文書サイト site/ は、番号を assets/site.js が自動で付ける。そちらは tests/test_site.sh）
#
# 【テストケース】
#   1. すべての見出し（`##` 以下。コードブロックの中は除く）に、番号がある
#   2. 番号の深さが、見出しの階層と合っている（`##` は 1、`###` は 1.1、`####` は 1.1.1）
#   3. 連番になっている（同じ親の下で、1 から順に。重複・飛び・逆戻りがない）
#   4. 改行が LF だけ（CR が混ざっていない）
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== Markdown 文書の見出しの番号 ===${CLR_RST}"

cd "$SF_TOOLS_DIR" || exit 1

# 1 つのファイルの、見出しの問題を、1 行ずつ返す（問題がなければ、何も返さない）
#   種類: 番号なし / 深さ違い / 連番。コードブロック（```）の中は見ない。タイトル（`#`）は対象外
_check_headings() {
    awk '
        /^```/ { fence = !fence; next }
        fence { next }
        /^#+[ \t]/ {
            match($0, /^#+/); lv = RLENGTH
            if (lv == 1) next
            t = substr($0, lv + 2)
            if (!match(t, /^[0-9]+(\.[0-9]+)*\.?[ \t]/)) { print FILENAME ":" NR ": 番号がない: " $0; next }
            num = substr(t, 1, RLENGTH); gsub(/[ \t]/, "", num); sub(/\.$/, "", num)
            n = split(num, a, ".")
            if (n != lv - 1) { print FILENAME ":" NR ": 番号の深さが、階層と違う（" lv " 階層目に、" num "）: " $0 }
            parent = ""
            for (i = 1; i < n; i++) parent = parent (i > 1 ? "." : "") a[i]
            cur = a[n] + 0; prev = last[parent] + 0
            if (cur != prev + 1) { print FILENAME ":" NR ": 連番でない（" (parent == "" ? "" : parent ".") prev " の次が " num "）: " $0 }
            # 直前の、1 つ上の階層の見出しが、親になっているか（別の大項目の下に、前の大項目の番号が戻っていないか）
            if (n > 1 && parent != stk[n - 1]) { print FILENAME ":" NR ": 連番でない（親の見出し " stk[n - 1] " の下に、" num " がある）: " $0 }
            stk[n] = num
            last[parent] = cur
            for (k in last) if (index(k, num ".") == 1) delete last[k]
            delete last[num]
        }
    ' "$1"
}

test_docs_headings() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 見出しの番号（番号がある・深さが合う・連番）${CLR_RST}"
    local f n=0 bad="" r
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        n=$((n + 1))
        r=$(_check_headings "$f")  # VAR=$(cmd) のため run 不使用
        [[ -z "$r" ]] || bad="$bad
$r"
    done < <(git ls-files '*.md')
    [[ $n -gt 0 ]] && pass "Markdown ${n} ファイルを確認した" || fail "Markdown のファイルが 1 件以上ある"
    [[ -z "$bad" ]] && pass "すべての見出しに、番号がある・深さが階層と合っている・連番になっている" || fail "見出しの番号に、問題がある" "$bad"
}

test_docs_checker() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 確認の仕組み自体（わざと壊した文書を、見つけられる）${CLR_RST}"
    local t; t=$(mktemp -d "${TMPDIR:-/tmp}/test-docs-XXXX")
    printf '# 題\n\n## 1. 大\n\n### 1.1 中\n\n#### 1.1.1 小\n\n### 1.2 中\n\n## 2. 大\n' > "$t/ok.md"
    [[ -z "$(_check_headings "$t/ok.md")" ]] && pass "正しい文書は、問題なし" || fail "正しい文書は、問題なし"
    printf '# 題\n\n## 大\n' > "$t/none.md"
    _check_headings "$t/none.md" | grep -q "番号がない" && pass "番号のない見出しを、見つける" || fail "番号のない見出しを、見つける"
    printf '# 題\n\n## 1. 大\n\n### 1.1.1 深すぎ\n' > "$t/depth.md"
    _check_headings "$t/depth.md" | grep -q "深さが、階層と違う" && pass "番号の深さが違う見出しを、見つける" || fail "番号の深さが違う見出しを、見つける"
    printf '# 題\n\n## 1. 大\n\n## 3. 飛んだ\n' > "$t/seq.md"
    _check_headings "$t/seq.md" | grep -q "連番でない" && pass "連番の飛びを、見つける" || fail "連番の飛びを、見つける"
    printf '# 題\n\n## 1. 大\n\n### 1.1 中\n\n## 2. 大\n\n### 1.2 戻った\n' > "$t/back.md"
    _check_headings "$t/back.md" | grep -q "連番でない" && pass "番号が戻った見出しを、見つける" || fail "番号が戻った見出しを、見つける"
    printf '# 題\n\n## 1. 大\n\n```\n# コメント\n## 番号のない行（コードの中）\n```\n' > "$t/fence.md"
    [[ -z "$(_check_headings "$t/fence.md")" ]] && pass "コードブロックの中は、見ない" || fail "コードブロックの中は、見ない"
    rm -rf "$t"  # run 不使用: 後始末（この関数が作った一時フォルダだけ）
}

test_docs_crlf() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 改行（LF）${CLR_RST}"
    local f crlf=""
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        grep -q $'\r' "$f" && crlf="$crlf $f"
    done < <(git ls-files '*.md')
    [[ -z "$crlf" ]] && pass "Markdown は、LF だけ（CR がない）" || fail "CR が混ざっている Markdown がある" "$crlf"
}

test_docs_headings
test_docs_checker
test_docs_crlf

print_summary
