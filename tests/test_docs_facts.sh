#!/bin/bash
# ==============================================================================
# test_docs_facts.sh - 文書に書かれた「事実」が、コードと食い違っていないかの検査
# ==============================================================================
# 対象の文書: site/**/*.html と README.md（利用者・技術者向けの文書。doc/ の設計書は、対象外）
# 検査する事実（文書 → コードの向きだけ。文書を自動で書き換えることは、しない）:
#   1. コマンド名（sf-xxx.sh）が、bin/ に実在する
#   2. オプション（--xxx）が、どこかのコマンドの冒頭コメントに、書かれている
#   3. コード片（<code>・<pre>・``` ）に、sf-xxx.sh と一緒に書かれたオプションが、そのコマンドの冒頭コメントにある
#      （別のコマンドのオプションを、取り違えていないか）
#   4. リポジトリ内のパス（bin/・lib/・phases/・templates/・config/・tests/・hooks/・doc/・site/）が、実在する
#   5. 環境変数（SF_…）が、コード（bin・lib・phases・hooks・templates・config・tests/e2e）のどこかに、ある
# 例外（実在しないが、書いてよいもの。外部コマンドのオプションなど）は、tests/docs-facts-allow.txt に書く。
# 検査の部品は、壊した見本の文書で、ちゃんと検出できることも確かめる（自己テスト）。
# 速さ: Windows（Git Bash）は、コマンドの起動が遅いため、1 行ごとにコマンドを起動せず、まとめて処理する。
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== 文書の事実の検査 ===${CLR_RST}"

ALLOW_FILE="$SF_TOOLS_DIR/tests/docs-facts-allow.txt"
FACT_TMP=$(mktemp -d "${TMPDIR:-/tmp}/docs-facts-XXXX")
trap 'rm -rf "$FACT_TMP"' EXIT

# --- 準備（1 回だけ）---------------------------------------------------------

# 検査する文書の一覧（sf-tools のルートからの相対パス）
FACT_FILES=$( cd "$SF_TOOLS_DIR" && ls site/*.html site/*/*.html README.md 2>/dev/null )

# コマンドの冒頭コメント（2 つ目と 3 つ目の「# ====」の間）。引数: ファイルのパス
_fact_header() { awk '/^# ==/{f++; next} f==2{print} f==3{exit}' "$1"; }

# 例外の一覧: 「種類 値  # 理由」→ 種類ごとの、空白区切りの値
_fact_allow() { [[ -f "$ALLOW_FILE" ]] && awk -v k="$1" '$1==k {printf "%s ", $2}' "$ALLOW_FILE"; }
ALLOW_COMMANDS=" $(_fact_allow command) "
ALLOW_OPTIONS=" $(_fact_allow option) "
ALLOW_PATHS=" $(_fact_allow path) "
ALLOW_ENVS=" $(_fact_allow env) "

# コマンドごとの、冒頭コメントのオプション: 「コマンド オプション」の組（1 行に 1 組）
#   sf-init.sh は、--verify の追加の引数（phases/init/verify.sh の冒頭コメントのオプション）も受け付ける
build_pairs() {
    local f cmd
    : > "$FACT_TMP/pairs.txt"
    for f in "$SF_TOOLS_DIR"/bin/sf-*.sh; do
        cmd=$(basename "$f")
        { _fact_header "$f"; [[ "$cmd" == "sf-init.sh" ]] && _fact_header "$SF_TOOLS_DIR/phases/init/verify.sh"; } \
            | grep -oE '(^|[^-a-zA-Z0-9])--[a-z][a-z0-9-]+' | grep -oE '\-\-[a-z][a-z0-9-]+' | sort -u | sed "s/^/${cmd} /" >> "$FACT_TMP/pairs.txt"
    done
    # 全体で知られているオプション（phases/init/*.sh の冒頭コメントも含む）
    { cut -d' ' -f2 "$FACT_TMP/pairs.txt"
      for f in "$SF_TOOLS_DIR"/phases/init/*.sh; do _fact_header "$f"; done | grep -oE '(^|[^-a-zA-Z0-9])--[a-z][a-z0-9-]+' | grep -oE '\-\-[a-z][a-z0-9-]+'
    } | sort -u | tr '\n' ' ' > "$FACT_TMP/known_opts.txt"
}
build_pairs
KNOWN_OPTS=" $(cat "$FACT_TMP/known_opts.txt") "

# 環境変数の検索用: コードを 1 つのファイルにまとめる
( cd "$SF_TOOLS_DIR" && find bin lib phases hooks templates config tests/e2e -type f -exec cat {} + 2>/dev/null ) > "$FACT_TMP/code_blob.txt"

# --- 検査（引数: 文書のファイル。出力: 「ファイル: 問題」）--------------------

# 文書から、パターンに合う語を、「ファイル:語」の形で取り出す（重複なし）。引数: パターン 前置きを外す sed の式 ファイル…
#   パターンは、語の前の 1 文字（境界）も含めて取り出すため、sed の式で、その境界を外す
_fact_tokens() {
    local pattern="$1" strip="$2" f; shift 2
    for f in "$@"; do
        ( cd "$SF_TOOLS_DIR" && grep -oE "$pattern" "$f" 2>/dev/null ) | sed "$strip" | sort -u | sed "s|^|${f}:|"
    done
}

check_commands() {
    local pair f c
    _fact_tokens 'sf-[a-z]+(-[a-z]+)*\.sh' 's/^//' "$@" | while IFS= read -r pair; do
        f=${pair%%:*}; c=${pair#*:}
        [[ -f "$SF_TOOLS_DIR/bin/$c" ]] && continue
        case "$ALLOW_COMMANDS" in *" $c "*) continue;; esac
        echo "${f}: コマンド ${c} が、bin/ にない"
    done
}

check_options() {
    local pair f o
    _fact_tokens '(^|[^-a-zA-Z0-9])--[a-z][a-z0-9-]+' 's/^[^-]*//' "$@" | while IFS= read -r pair; do
        f=${pair%%:*}; o=${pair#*:}
        case "$KNOWN_OPTS" in *" $o "*) continue;; esac
        case "$ALLOW_OPTIONS" in *" $o "*) continue;; esac
        echo "${f}: オプション ${o} が、どのコマンドの冒頭コメントにもない"
    done
}

# コード片の中の、コマンドとオプションの組（awk 1 回で、全文書をまとめて処理する）
check_command_options() {
    ( cd "$SF_TOOLS_DIR" && awk -v pairs="$FACT_TMP/pairs.txt" -v allow="$ALLOW_OPTIONS" '
        function decode(s) { gsub(/<[^>]*>/, "", s); gsub(/&lt;/, "<", s); gsub(/&gt;/, ">", s); gsub(/&amp;/, "\\&", s); return s }
        function check(frag,    cmd, rest, o) {
            frag = decode(frag)
            if (!match(frag, /sf-[a-z]+(-[a-z]+)*\.sh/)) return
            cmd = substr(frag, RSTART, RLENGTH)
            if (!(cmd in known)) return
            rest = substr(frag, RSTART + RLENGTH)
            sub(/[ \t]#.*$/, "", rest)
            while (match(rest, /(^|[^-a-zA-Z0-9])--[a-z][a-z0-9-]+/)) {
                o = substr(rest, RSTART, RLENGTH); sub(/^[^-]*/, "", o)
                rest = substr(rest, RSTART + RLENGTH)
                if (!((cmd " " o) in pair) && index(allow, " " o " ") == 0)
                    print FILENAME ": " cmd " に " o " は、ない（コード片: " frag ")"
            }
        }
        FNR == NR { pair[$1 " " $2] = 1; known[$1] = 1; next }
        FILENAME ~ /\.html$/ {
            if ($0 ~ /<pre/) inpre = 1
            line = $0
            if (inpre) check(line)
            else while (match(line, /<code>[^<]*<\/code>/)) { s = RSTART; l = RLENGTH; check(substr(line, s, l)); line = substr(line, s + l) }   # check() が match() の結果を上書きするため、先に保存する
            if ($0 ~ /<\/pre>/) inpre = 0
            next
        }
        {
            if ($0 ~ /^```/) { infence = !infence; next }
            if (infence) { check($0); next }
            line = $0
            while (match(line, /`[^`]+`/)) { s = RSTART; l = RLENGTH; check(substr(line, s + 1, l - 2)); line = substr(line, s + l) }
        }
    ' "$FACT_TMP/pairs.txt" "$@" )
}

check_paths() {
    local pair f p
    _fact_tokens '(^|[^/A-Za-z0-9_.~-])(bin|lib|phases|templates|config|tests|hooks|doc|site)/[A-Za-z0-9_./*{}-]+' 's/^[^a-z]*//;s/[.,)]*$//' "$@" | while IFS= read -r pair; do
        f=${pair%%:*}; p=${pair#*:}
        case "$p" in *'*'*|*'{'*|*-) continue;; esac   # 見本の記号（*・{}）と、<名前> が続く途中の語（bin/sf- など）は、飛ばす
        [[ -e "$SF_TOOLS_DIR/$p" ]] && continue
        case "$ALLOW_PATHS" in *" $p "*) continue;; esac
        echo "${f}: パス ${p} が、ない"
    done
}

check_env_vars() {
    local pair f v
    _fact_tokens '(^|[^A-Z0-9_])SF_[A-Z0-9_]+' 's/^[^S]*//' "$@" | while IFS= read -r pair; do
        f=${pair%%:*}; v=${pair#*:}
        case "$ALLOW_ENVS" in *" $v "*) continue;; esac
        grep -qF -- "$v" "$FACT_TMP/code_blob.txt" && continue
        echo "${f}: 環境変数 ${v} が、コードにない"
    done
}

# 検査の実行: 問題がなければ pass、あれば fail（問題の一覧つき）。引数: 名前 検査の関数
_run_check() {
    local name="$1" fn="$2" out
    # shellcheck disable=SC2086
    out=$( $fn $FACT_FILES )
    if [[ -z "$out" ]]; then pass "$name"; else fail "$name" "$(echo "$out" | head -8)"; fi
}

test_facts_commands()        { _run_check "文書のコマンド名（sf-xxx.sh）が、bin/ に実在する" check_commands; }
test_facts_options()         { _run_check "文書のオプション（--xxx）が、どこかの冒頭コメントにある" check_options; }
test_facts_command_options() { _run_check "文書のコード片で、コマンドと一緒に書かれたオプションが、そのコマンドの冒頭コメントにある" check_command_options; }
test_facts_paths()           { _run_check "文書のパスが、リポジトリに実在する" check_paths; }
test_facts_env_vars()        { _run_check "文書の環境変数（SF_…）が、コードにある" check_env_vars; }

# --- 自己テスト: 壊した見本の文書で、検査が、ちゃんと検出する ---
test_facts_selftest() {
    local d out
    d="$FACT_TMP/sample"; mkdir -p "$d"
    cat > "$d/bad.html" <<'EOF'
<p><code>sf-nosuchcmd.sh</code> と <code>--no-such-option-xyz</code> と <code>sf-release.sh --no-such-release-opt</code>、
<code>tests/no_such_file.sh</code>、<code>SF_NO_SUCH_VARIABLE_XYZ</code></p>
<pre><code>sf-check.sh --release
</code></pre>
EOF
    cat > "$d/good.html" <<'EOF'
<p><code>sf-release.sh --release</code> と <code>bin/sf-check.sh</code>、<code>SF_TARGET_ORG</code></p>
<pre><code>sf-init.sh --verify --components   # 説明
</code></pre>
EOF
    cat > "$d/bad.md" <<'EOF'
`sf-push.sh --no-such-md-opt` と、
```bash
sf-start.sh --release
```
EOF
    out=$(check_commands "$d/bad.html");        [[ "$out" == *"sf-nosuchcmd.sh"* ]] && pass "自己テスト: 実在しないコマンド名を検出する" || fail "自己テスト: 実在しないコマンド名を検出する" "$out"
    out=$(check_options "$d/bad.html");         [[ "$out" == *"--no-such-option-xyz"* ]] && pass "自己テスト: 冒頭コメントにないオプションを検出する" || fail "自己テスト: 冒頭コメントにないオプションを検出する" "$out"
    out=$(check_command_options "$d/bad.html"); [[ "$out" == *"sf-release.sh に --no-such-release-opt"* ]] && pass "自己テスト: コマンドと合わないオプションを検出する（<code>）" || fail "自己テスト: コマンドと合わないオプションを検出する（<code>）" "$out"
    [[ "$out" == *"sf-check.sh に --release"* ]] && pass "自己テスト: コマンドと合わないオプションを検出する（<pre>。sf-check に --release はない）" || fail "自己テスト: コマンドと合わないオプションを検出する（<pre>）" "$out"
    out=$(check_command_options "$d/bad.md");   [[ "$out" == *"sf-push.sh に --no-such-md-opt"* && "$out" == *"sf-start.sh に --release"* ]] && pass "自己テスト: Markdown のコード片（インラインと囲み）も検出する" || fail "自己テスト: Markdown のコード片も検出する" "$out"
    out=$(check_paths "$d/bad.html");           [[ "$out" == *"tests/no_such_file.sh"* ]] && pass "自己テスト: 実在しないパスを検出する" || fail "自己テスト: 実在しないパスを検出する" "$out"
    out=$(check_env_vars "$d/bad.html");        [[ "$out" == *"SF_NO_SUCH_VARIABLE_XYZ"* ]] && pass "自己テスト: コードにない環境変数を検出する" || fail "自己テスト: コードにない環境変数を検出する" "$out"
    out="$(check_commands "$d/good.html"; check_options "$d/good.html"; check_command_options "$d/good.html"; check_paths "$d/good.html"; check_env_vars "$d/good.html")"
    [[ -z "$out" ]] && pass "自己テスト: 正しい文書は、問題なしになる" || fail "自己テスト: 正しい文書は、問題なしになる" "$out"
}

test_facts_commands
test_facts_options
test_facts_command_options
test_facts_paths
test_facts_env_vars
test_facts_selftest

print_summary
