#!/bin/bash
# ==============================================================================
# test_site.sh - HTML の文書サイト（site/）の整合性のテスト
# ==============================================================================
# ページが増えても、リンク切れ・目次への登録漏れ・書式の崩れが、CI で見つかるようにする。
# 見た目は確認できない（それは、ブラウザで見る）。ここで確かめるのは、機械で判定できる決まりごとだけ。
#
# 【テストケース】
#   1. 各ページの決まった書き出し（doctype・言語・文字コード・title・viewport・共通のスタイルとスクリプト・data-root が、深さと合っている）
#   2. 相対リンクが、実在するページ・見出しを指している（リンク切れがない）
#   3. 目次（assets/site.js の NAV）のリンクが、実在する。すべてのページが、目次に載っている（孤立したページがない）
#   4. 改行が LF だけ（CR が混ざっていない）
#   5. コードのブロックの中に、エスケープしていない「<」がない（ブラウザで、タグとして消えてしまうため）
#   6. 公開用のワークフロー（pages.yml）が、site/ を公開する
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== site/（HTML の文書サイト）===${CLR_RST}"

SITE="$SF_TOOLS_DIR/site"
NAVJS="$SITE/assets/site.js"

# site/ の中の HTML を、site/ からの相対パスで 1 行ずつ返す（並べ替え済み）
_pages() { ( cd "$SITE" && find . -name '*.html' | sed 's#^\./##' | sort ); }

test_site_head() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 各ページの決まった書き出し${CLR_RST}"
    local p n=0 depth want
    [[ -f "$SITE/index.html" ]] && pass "トップページ（index.html）がある" || fail "トップページ（index.html）がある"
    while IFS= read -r p; do
        n=$((n + 1))
        local f="$SITE/$p" bad=""
        head -1 "$f" | grep -qi '^<!doctype html>' || bad="$bad doctype"
        grep -q '<html lang="ja">' "$f"             || bad="$bad lang"
        grep -q '<meta charset="utf-8">' "$f"       || bad="$bad charset"
        grep -q '<meta name="viewport"' "$f"        || bad="$bad viewport"
        grep -q '<title>[^<]\+</title>' "$f"        || bad="$bad title"
        # 深さ（site/ からのフォルダの数）に応じた、共通のファイルへの相対パス
        depth=$(printf '%s' "$p" | tr -cd '/' | wc -c | tr -d ' ')
        want=""; local i=0; while [[ $i -lt $depth ]]; do want="${want}../"; i=$((i + 1)); done
        grep -q "<body data-root=\"${want}\">" "$f"                       || bad="$bad data-root(期待: '${want}')"
        grep -q "href=\"${want}assets/style.css\"" "$f"                   || bad="$bad style.css"
        grep -q "src=\"${want}assets/site.js\"" "$f"                      || bad="$bad site.js"
        grep -q 'id="doc"' "$f" && grep -q 'id="top"' "$f" && grep -q 'id="side"' "$f" || bad="$bad 骨組み(top/side/doc)"
        [[ -z "$bad" ]] && pass "$p: 書き出しが決まりどおり" || fail "$p: 書き出しが決まりと違う" "$bad"
    done < <(_pages)
    [[ $n -gt 0 ]] && pass "ページが ${n} 件ある" || fail "ページが 1 件以上ある"
}

test_site_links() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 相対リンクが、実在するページ・見出しを指す${CLR_RST}"
    local p h path anchor target total=0 broken=""
    while IFS= read -r p; do
        while IFS= read -r h; do
            case "$h" in
                http://*|https://*|mailto:*|"") continue ;;
            esac
            total=$((total + 1))
            path="${h%%#*}"; anchor=""
            [[ "$h" == *"#"* ]] && anchor="${h#*#}"
            if [[ -z "$path" ]]; then target="$SITE/$p"; else target="$(dirname "$SITE/$p")/$path"; fi
            if [[ ! -f "$target" ]]; then broken="$broken
  $p → $h（ファイルがない）"; continue; fi
            if [[ -n "$anchor" ]] && ! grep -q "id=\"${anchor}\"" "$target"; then
                broken="$broken
  $p → $h（見出し #${anchor} がない）"
            fi
        done < <(grep -o 'href="[^"]*"' "$SITE/$p" | sed 's/^href="//; s/"$//')
    done < <(_pages)
    [[ -z "$broken" ]] && pass "相対リンク ${total} 件が、すべて実在する" || fail "リンク切れがある" "$broken"
}

test_site_nav() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 目次（assets/site.js の NAV）と、ページの対応${CLR_RST}"
    local h p missing="" orphan="" navlist
    navlist=$(grep -o 'h: "[^"]*"' "$NAVJS" | sed 's/^h: "//; s/"$//')  # VAR=$(cmd) のため run 不使用
    [[ -n "$navlist" ]] && pass "目次に、リンクのある項目がある" || fail "目次に、リンクのある項目がある"
    while IFS= read -r h; do
        [[ -z "$h" ]] && continue
        [[ -f "$SITE/$h" ]] || missing="$missing $h"
    done <<< "$navlist"
    [[ -z "$missing" ]] && pass "目次のリンクが、すべて実在する" || fail "目次に、存在しないページがある" "$missing"
    while IFS= read -r p; do
        printf '%s\n' "$navlist" | grep -qxF "$p" || orphan="$orphan $p"
    done < <(_pages)
    [[ -z "$orphan" ]] && pass "すべてのページが、目次に載っている" || fail "目次に載っていないページがある（孤立）" "$orphan"
    # 同じページを、2 回登録していない
    [[ -z "$(printf '%s\n' "$navlist" | sort | uniq -d)" ]] && pass "目次に、同じページが 2 回載っていない" || fail "目次に、同じページが 2 回載っている"
}

test_site_format() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 改行（LF）と、コードのブロックのエスケープ${CLR_RST}"
    local f crlf="" bad
    while IFS= read -r f; do
        grep -q $'\r' "$f" && crlf="$crlf ${f#$SITE/}"
    done < <(find "$SITE" -type f \( -name '*.html' -o -name '*.css' -o -name '*.js' \))
    [[ -z "$crlf" ]] && pass "site/ のファイルは、LF だけ（CR がない）" || fail "CR が混ざっているファイルがある" "$crlf"
    bad=""
    local p
    while IFS= read -r p; do
        # <pre><code> と </code></pre> の間に、「<」＋英字・「</」がある（タグに見える）行
        local r
        r=$(awk '
            { line = $0
              if (index(line, "<pre><code>")) { inpre = 1; sub(/.*<pre><code>/, "", line) }
              if (inpre) { l = line; sub(/<\/code><\/pre>.*/, "", l); if (l ~ /<[A-Za-z\/]/) print FILENAME ":" NR ": " l }
              if (index($0, "</code></pre>")) inpre = 0 }' "$SITE/$p")  # VAR=$(cmd) のため run 不使用
        [[ -n "$r" ]] && bad="$bad
$r"
    done < <(_pages)
    [[ -z "$bad" ]] && pass "コードのブロックに、エスケープしていない「<」がない" || fail "コードのブロックに、エスケープしていない「<」がある（&lt; にする）" "$bad"
}

test_site_pages_workflow() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 公開用のワークフロー（pages.yml）${CLR_RST}"
    local wf="$SF_TOOLS_DIR/.github/workflows/pages.yml"
    [[ -f "$wf" ]] && pass "pages.yml がある" || { fail "pages.yml がある"; return; }
    assert_file_contains "$wf" "path: site"              "pages.yml: site/ を公開する"
    assert_file_contains "$wf" "branches: [main]"        "pages.yml: main のときだけ公開する（development の途中経過は出さない）"
    assert_file_contains "$wf" "- 'site/**'"             "pages.yml: site/ の変更で動く"
    assert_file_contains "$wf" "pages: write"            "pages.yml: Pages への書き込み権限を、このワークフローだけに与える"
    assert_file_not_contains "$wf" "pull_request"        "pages.yml: pull_request では動かさない（権限を渡さない）"
}

test_site_head
test_site_links
test_site_nav
test_site_format
test_site_pages_workflow

print_summary
