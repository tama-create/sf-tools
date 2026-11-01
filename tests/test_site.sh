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
#   7. 見出し: 番号を手で書かない（大項目 1. / 中項目 1.1 / 小項目 1.1.1 は、assets/site.js が自動で付ける）・階層を飛ばさない（h2 → h3 → h4）
#   8. 囲み（<div class="box ...">）に、必ず題（<div class="title">）がある（アイコンは、題の前に、スタイルが自動で付ける）
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

test_site_headings() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 見出し（番号は自動・階層を飛ばさない）${CLR_RST}"
    local p line lv text prev manual="" skipped="" total=0
    while IFS= read -r p; do
        prev=1
        # 各見出しを「レベル 本文」の 1 行にする（h2・h3・h4 だけ。<main> の中だけ）
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            lv="${line%% *}"; text="${line#* }"
            [[ "$lv" =~ ^[234]$ ]] || continue
            total=$((total + 1))
            if [[ "$text" =~ ^[0-9]+(\.[0-9]+)*\.?[[:space:]] ]]; then manual="$manual
  $p: $text"; fi
            if [[ $lv -gt $((prev + 1)) ]]; then skipped="$skipped
  $p: h${prev} の次が h${lv}（${text}）"; fi
            prev=$lv
        done < <(sed -n '/<main/,/<\/main>/p' "$SITE/$p" | grep -oE '<h[234]( [^>]*)?>[^<]*' | sed -E 's/<h([234])( [^>]*)?>/\1 /')
    done < <(_pages)
    [[ $total -gt 0 ]] && pass "見出し ${total} 件を確認した" || fail "見出しが 1 件以上ある"
    [[ -z "$manual" ]] && pass "見出しに、手書きの番号がない（番号は、assets/site.js が自動で付ける）" || fail "見出しに、手書きの番号がある（消す。自動で付くため、二重になる）" "$manual"
    [[ -z "$skipped" ]] && pass "見出しの階層を、飛ばしていない（h2 → h3 → h4）" || fail "見出しの階層を飛ばしている（h2 の次は h3、h3 の次は h4）" "$skipped"
    assert_file_contains "$NAVJS" 'cnt[lv] += 1' "assets/site.js: 見出しの番号を、自動で付ける"
}

test_site_boxes() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 囲み（題がある・種類が決まっている）${CLR_RST}"
    local p nb nt r bad="" kinds=""
    while IFS= read -r p; do
        nb=$(grep -c '<div class="box' "$SITE/$p")  # VAR=$(cmd) のため run 不使用
        nt=$(grep -c '<div class="title">' "$SITE/$p")  # VAR=$(cmd) のため run 不使用
        [[ "$nb" == "$nt" ]] || bad="$bad
  $p: 囲み ${nb} 個に対して、題が ${nt} 個"
        # 種類は、warn・danger・ok・next・admin だけ（アイコンが決まっているもの。ほかの名前は、アイコンが付かない）
        r=$(grep -o '<div class="box[^"]*"' "$SITE/$p" | grep -vE '<div class="box( (warn|danger|ok|next|admin))?"' | awk -v f="$p" '{ print "  " f ": " $0 }')  # VAR=$(cmd) のため run 不使用
        [[ -z "$r" ]] || kinds="$kinds
$r"
    done < <(_pages)
    [[ -z "$bad" ]] && pass "すべての囲みに、題がある（アイコンは、題の前に付く）" || fail "題のない囲みがある" "$bad"
    [[ -z "$kinds" ]] && pass "囲みの種類は、決まったもの（通常・warn・danger・ok・next・admin）だけ" || fail "決まっていない種類の囲みがある（アイコンが付かない）" "$kinds"
    assert_file_contains "$SITE/assets/style.css" '.box.admin .title::before' "style.css: 囲みの種類ごとに、アイコンを自動で付ける"
}

test_site_figures() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 図（説明文がある・色の種類が決まっている）${CLR_RST}"
    local p nf nc r bad="" kinds="" total=0
    while IFS= read -r p; do
        nf=$(grep -cE '<figure class="(diagram|photo)"' "$SITE/$p")  # VAR=$(cmd) のため run 不使用（HTML/CSS の図 diagram と、画像の図 photo）
        nc=$(grep -c '<figcaption>' "$SITE/$p")  # VAR=$(cmd) のため run 不使用
        total=$((total + nf))
        [[ "$nf" == "$nc" ]] || bad="$bad
  $p: 図 ${nf} 個に対して、説明文（figcaption）が ${nc} 個"
        # 流れ図の箱の色は、admin・dev・auto・ok・warn だけ（style.css に定義がある）
        r=$(grep -o '<div class="node[^"]*"' "$SITE/$p" | grep -vE '<div class="node (admin|dev|auto|ok|warn)"' | awk -v f="$p" '{ print "  " f ": " $0 }')  # VAR=$(cmd) のため run 不使用
        [[ -z "$r" ]] || kinds="$kinds
$r"
    done < <(_pages)
    [[ $total -gt 0 ]] && pass "図が ${total} 個ある" || fail "図が 1 個以上ある"
    [[ -z "$bad" ]] && pass "すべての図に、説明文（figcaption）がある" || fail "説明文のない図がある" "$bad"
    # 画像（img）には、代替文字（alt）が要る（画像が見えない人・読み込めないときのため。空の alt は不可）
    local noalt=""
    while IFS= read -r p; do
        r=$(grep -o '<img [^>]*>' "$SITE/$p" | grep -vE ' alt="[^"]+"' | awk -v f="$p" '{ print "  " f ": " $0 }')  # VAR=$(cmd) のため run 不使用
        [[ -z "$r" ]] || noalt="$noalt
$r"
    done < <(_pages)
    [[ -z "$noalt" ]] && pass "すべての画像（img）に、代替文字（alt）がある" || fail "代替文字のない画像がある" "$noalt"
    [[ -z "$kinds" ]] && pass "流れ図の箱の色は、決まったもの（admin・dev・auto・ok・warn）だけ" || fail "決まっていない色の箱がある" "$kinds"
    assert_file_contains "$SITE/assets/style.css" 'figure.diagram' "style.css: 図のスタイルがある"
}

test_site_head
test_site_links
test_site_nav
test_site_format
test_site_pages_workflow
test_site_headings
test_site_boxes
test_site_figures

print_summary
