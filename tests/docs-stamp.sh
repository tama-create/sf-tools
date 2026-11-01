#!/bin/bash
# ==============================================================================
# docs-stamp.sh - 冒頭コメントと、文書の「見直しの印（スタンプ）」を管理する
# ==============================================================================
# 3 階層の文書（doc/doc-style.md）で、階層 1（コードの冒頭コメント）が変わったのに、それに基づく文書（階層 2・3）が
# 見直されないまま残ることを、検出するための道具。文書を自動で書き換えることは、しない（検出だけ）。
#
# 【仕組み】
#   doc/doc-stamps.txt に、「どの文書が、どのコードの冒頭コメントに基づくか」と、見直した時点の冒頭コメントの
#   チェックサム（cksum）を、1 行ずつ書く。冒頭コメントが変わると、チェックサムが合わなくなり、テスト
#   （tests/test_docs_stamps.sh）が失敗する。文書を読み直して、必要なら直してから、--update で印を付け直す。
#   書式: 文書 | コード | チェックサム | 見直した時点のコミット   （チェックサムが - なら、まだ見直していない）
#
# 【使い方】
#   bash tests/docs-stamp.sh --check               # 印が合っているかを調べる（問題があれば、一覧を出して終了コード 1）
#   bash tests/docs-stamp.sh --list                # 印の一覧を表示する
#   bash tests/docs-stamp.sh --diff <文書>         # その文書の基になるコードの冒頭コメントの、前回の見直しからの変更を表示する
#   bash tests/docs-stamp.sh --update <文書> [<コード>] [-y]
#                                                  # 文書を読み直したあとで、印を付け直す（確認つき。-y で確認を省略）。
#                                                  # <コード> を付けると、その 1 本の印だけを付け直す（読んでいないものの印は、残る）
#
# 【冒頭コメントの範囲】 シェル・JS とも、2 つ目と 3 つ目の区切り行（# ==== / // ====）の間
#
# 【補足】
#   - <コード> を付けずに --update すると、その文書の、すべてのコードの印が付け直される。冒頭コメントが変わったコードが
#     複数あるときは、1 本ずつ読んで、<コード> を付けて付け直すと、読み残しが、検出され続ける。
#   - 印を付け直す（--update）のは、「文書を読み直して、必要な修正をした」という意味。冒頭コメントの変更が、
#     文書に影響しないとき（誤字の修正など）も、読み直したうえで、付け直してよい。
#   - bin/sf-*.sh が、1 つも文書の基になっていないとき、--check は失敗する（新しいコマンドの文書を、忘れないため）。
# ==============================================================================
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
STAMPS="$ROOT/doc/doc-stamps.txt"

# 冒頭コメントの本文（2 つ目と 3 つ目の区切り行の間）。引数: ルートからの相対パス
header_of() {
    local f="$ROOT/$1"
    [[ -f "$f" ]] || return 1
    case "$1" in
        *.js) awk '/^\/\/ ==/{n++; next} n==2 && !/^\/\//{exit} n==2{print} n==3{exit}' "$f" ;;
        *)    awk '/^# ==/{n++; next} n==2{print} n==3{exit}' "$f" ;;
    esac
}

# 冒頭コメントのチェックサム（cksum の「値-バイト数」）
stamp_of() { header_of "$1" | cksum | awk '{print $1 "-" $2}'; }

# 印の行（コメント・空行を除く）を、「文書|コード|チェックサム|コミット」の形（前後の空白なし）で出す
stamp_lines() {
    [[ -f "$STAMPS" ]] || return 0
    grep -vE '^[[:space:]]*(#|$)' "$STAMPS" | awk -F'|' '{
        for (i = 1; i <= 4; i++) { gsub(/^[ \t]+|[ \t]+$/, "", $i) }
        print $1 "|" $2 "|" $3 "|" $4 }'
}

cmd_check() {
    local problems="" line page src stamp commit now
    while IFS= read -r line; do
        page=${line%%|*}; line=${line#*|}; src=${line%%|*}; line=${line#*|}; stamp=${line%%|*}
        [[ -f "$ROOT/$page" ]] || { problems="${problems}  ${page}: 文書がない（doc/doc-stamps.txt の行を直してください）\n"; continue; }
        [[ -f "$ROOT/$src" ]] || { problems="${problems}  ${page}: 基になるコード ${src} がない（doc/doc-stamps.txt の行を直してください）\n"; continue; }
        now=$(stamp_of "$src")
        if [[ "$stamp" == "-" ]]; then
            problems="${problems}  ${page}: ${src} は、まだ見直していません → 文書を読み直して、bash tests/docs-stamp.sh --update ${page}\n"
        elif [[ "$stamp" != "$now" ]]; then
            problems="${problems}  ${page}: ${src} の冒頭コメントが、見直したあとで変わりました → bash tests/docs-stamp.sh --diff ${page} で変更を見て、文書を読み直し、--update ${page}\n"
        fi
    done < <(stamp_lines)
    # 文書の基になっていないコマンドがないか（新しいコマンドの文書を、忘れないため）
    local c
    for c in "$ROOT"/bin/sf-*.sh; do
        c="bin/$(basename "$c")"
        stamp_lines | awk -F'|' -v c="$c" '$2 == c {f = 1} END {exit !f}' \
            || problems="${problems}  ${c}: どの文書の基にもなっていません → doc/doc-stamps.txt に、対応する文書を足してください\n"
    done
    if [[ -n "$problems" ]]; then
        printf '文書の見直しが必要です:\n%b' "$problems"
        return 1
    fi
    return 0
}

cmd_list() { stamp_lines | awk -F'|' '{printf "%-42s %-34s %s %s\n", $1, $2, $3, $4}'; }

# 文書の基になるコードの冒頭コメントの、前回の見直しからの変更
cmd_diff() {
    local page="$1" line p src stamp commit now found=0
    [[ -n "$page" ]] || { echo "使い方: docs-stamp.sh --diff <文書>" >&2; return 1; }
    while IFS= read -r line; do
        p=${line%%|*}; line=${line#*|}; src=${line%%|*}; line=${line#*|}; stamp=${line%%|*}; commit=${line#*|}
        [[ "$p" == "$page" ]] || continue
        found=1
        now=$(stamp_of "$src")
        [[ "$stamp" == "$now" ]] && { echo "== ${src}: 変更なし"; continue; }
        echo "== ${src}: 冒頭コメントの変更（前回の見直し: ${commit}）"
        if [[ "$commit" != "-" && -n "$commit" ]]; then
            git -C "$ROOT" diff "$commit" -- "$src" | grep -E '^[+-][[:space:]]*(#|//)' | grep -vE '^(\+\+\+|---)'
        else
            echo "  （まだ見直していません。冒頭コメント全体を読んでください）"
        fi
    done < <(stamp_lines)
    [[ $found -eq 1 ]] || { echo "doc/doc-stamps.txt に、${page} の行がありません" >&2; return 1; }
}

# 印を付け直す
cmd_update() {
    local page="${1:-}" only="" yes="" a line p src stamp commit found=0 head ans tmp
    shift || true
    for a in "$@"; do
        case "$a" in
            -y) yes="-y" ;;
            *)  only="$a" ;;
        esac
    done
    [[ -n "$page" ]] || { echo "使い方: docs-stamp.sh --update <文書> [<コード>] [-y]" >&2; return 1; }
    stamp_lines | awk -F'|' -v p="$page" -v o="$only" '$1 == p && (o == "" || $2 == o) {f = 1} END {exit !f}' \
        || { echo "doc/doc-stamps.txt に、${page}${only:+ と ${only}} の行がありません" >&2; return 1; }
    if [[ "$yes" != "-y" ]]; then
        cmd_diff "$page"
        printf '\n%s を読み直して、必要な修正をしましたか？ 印を付け直します [y/N]: ' "$page"
        read -r ans || ans=""
        [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "中止しました。"; return 1; }
    fi
    head=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo "-")
    tmp="${STAMPS}.tmp"
    : > "$tmp"
    # コメント・空行は、そのまま残し、対象の文書の行だけ、チェックサムとコミットを書き換える
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            ''|'#'*|[[:space:]]*'#'*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        p=$(echo "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}')
        src=$(echo "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')
        if [[ "$p" == "$page" && ( -z "$only" || "$src" == "$only" ) ]]; then
            printf '%s | %s | %s | %s\n' "$p" "$src" "$(stamp_of "$src")" "$head" >> "$tmp"
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$STAMPS"
    mv "$tmp" "$STAMPS"
    echo "印を付け直しました: ${page}（コミット ${head}）"
}

case "${1:-}" in
    --check)  cmd_check ;;
    --list)   cmd_list ;;
    --diff)   cmd_diff "${2:-}" ;;
    --update) shift; cmd_update "$@" ;;
    -h|--help|"") awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}" ;;
    *) echo "不明なオプションです: $1" >&2; exit 1 ;;
esac
