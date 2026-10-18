#!/bin/bash
# ==============================================================================
# test_integration-coverage.sh - 結合テストのカバレッジ表（doc/integration-test-plan.md の 10）のガード
# ==============================================================================
# 実装している、すべてのコマンド・フック・ワークフローが、カバレッジ表に載っていることを確かめる。
# 新しいコマンドを足して、表に載せ忘れると、このテストが失敗する（「全コマンドの結合テストがある」という主張を、確認できる形にする）。
#
# 【確認すること】
#   1. 実体（bin/sf-*.sh・hooks/*・templates/.github/workflows/*.yml）が、すべて、表に載っている
#   2. 表に、実体のない行がない
#   3. 各行の「結合」が、あり／一部／なし のどれかで、
#        あり・一部: パターンの番号がある。番号は、計画書の中に、定義がある
#        一部・なし: 結合しない理由が、空でない
#   4. 表の行数が、十分にある（解析が失敗して、何も検査せずに通る、ということを防ぐ）
#   5. ガード自体が、行の削除・理由の削除・未定義のパターン・実体だけが増えた場合を、検出する
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== 結合テストのカバレッジ表のガード ===${CLR_RST}"

PLAN_DOC="$SF_TOOLS_DIR/doc/integration-test-plan.md"
SEP='|'   # 列の区切り。空白ではない文字（空の列を、詰めないため）。表のセルの中には、| は入らない（| で、列を分けているため）。
          # 制御文字（\001 など）は、macOS 標準の Bash 3.2 の read で、正しく分割されないため、使わない

# 計画書の 10.2〜10.4 の表を読み、1 行ずつ「区分 SEP 対象 SEP 結合 SEP パターン SEP 理由」で出す
#   区分: cmd（10.2）/ hook（10.3）/ wf（10.4）。引数: 計画書
_cov_rows() {
    awk -F'|' '
        function trim(x) { gsub(/^[ ]+/, "", x); gsub(/[ ]+$/, "", x); return x }
        /^#+ / {
            sec = ""
            if ($0 ~ /^### 10\.2 /) sec = "cmd"
            else if ($0 ~ /^### 10\.3 /) sec = "hook"
            else if ($0 ~ /^### 10\.4 /) sec = "wf"
            next
        }
        sec != "" && /^\| `/ {
            gsub(/`/, "", $2); gsub(/\*/, "", $3)
            printf "%s|%s|%s|%s|%s\n", sec, trim($2), trim($3), trim($4), trim($5)
        }
    ' "$1"
}

# パターンの番号（A13・X2-1・X4-1a など）が、計画書の中で、定義されているか
#   定義: 表の行の先頭（| A13 |）、または、見出し（### 6.2 X2. ...）。引数: 計画書 番号
_cov_id_defined() {
    grep -qE "^\\| $2 \\|" "$1" || grep -qE "^#{3,4} [0-9.]+ $2\\. " "$1"
}

# 誤りを、1 行ずつ、標準出力に出す（なければ、何も出さない）。引数: 計画書 リポジトリのルート
_cov_check() {
    local doc="$1" root="$2" rows kind name join pat reason id f n listed
    rows=$(_cov_rows "$doc")

    # 3. 各行の内容
    while IFS="$SEP" read -r kind name join pat reason; do
        [[ -n "$kind" ]] || continue
        case "$join" in
            あり*|一部*)
                if [[ -z "$pat" || "$pat" == "—" ]]; then
                    echo "ERR: ${name}: 結合ありなのに、パターンの番号がない"
                fi
                for id in $(printf '%s' "$pat" | grep -oE '[ABCX][0-9]+(-[0-9]+[a-z]?)?'); do
                    _cov_id_defined "$doc" "$id" || echo "ERR: ${name}: パターン ${id} の定義が、計画書にない"
                done
                if [[ "$join" == 一部* && ( -z "$reason" || "$reason" == "—" ) ]]; then
                    echo "ERR: ${name}: 一部だけ結合する理由（結合しない部分の理由）がない"
                fi
                ;;
            なし*)
                if [[ -z "$reason" || "$reason" == "—" ]]; then
                    echo "ERR: ${name}: 結合なしなのに、理由がない"
                fi
                ;;
            *)
                echo "ERR: ${name}: 「結合」の欄が、あり・一部・なし のどれでもない（${join}）"
                ;;
        esac
    done <<EOF
$rows
EOF

    # 1. 実体が、すべて、表に載っている
    # 区切りの文字が、制御文字のため、awk の -F ではなく、read で分ける（BSD の awk の違いを避ける）
    listed=$(printf '%s\n' "$rows" | while IFS="$SEP" read -r kind name _; do [[ -n "$kind" ]] && echo "${kind}:${name}"; done)
    for f in "$root"/bin/sf-*.sh; do
        [[ -e "$f" ]] || continue
        n=$(basename "$f" .sh)
        printf '%s\n' "$listed" | grep -qxF "cmd:${n}" || echo "ERR: コマンド ${n} が、10.2 の表に載っていない"
    done
    for f in "$root"/hooks/*; do
        [[ -e "$f" ]] || continue
        n="hooks/$(basename "$f")"
        printf '%s\n' "$listed" | grep -qxF "hook:${n}" || echo "ERR: フック ${n} が、10.3 の表に載っていない"
    done
    for f in "$root"/templates/.github/workflows/*.yml; do
        [[ -e "$f" ]] || continue
        n=$(basename "$f")
        printf '%s\n' "$listed" | grep -qxF "wf:${n}" || echo "ERR: ワークフロー ${n} が、10.4 の表に載っていない"
    done

    # 2. 表に、実体のない行がない
    while IFS=: read -r kind name; do
        [[ -n "$kind" ]] || continue
        case "$kind" in
            cmd)  [[ -f "$root/bin/${name}.sh" ]] || echo "ERR: 表の ${name} は、実在しない（bin/${name}.sh がない）" ;;
            hook) [[ -f "$root/${name}" ]] || echo "ERR: 表の ${name} は、実在しない" ;;
            wf)   [[ -f "$root/templates/.github/workflows/${name}" ]] || echo "ERR: 表の ${name} は、実在しない" ;;
        esac
    done <<EOF
$listed
EOF
}

# ------------------------------------------------------------------------------
# 本物の計画書と、実際のリポジトリ
# ------------------------------------------------------------------------------
test_coverage_real() {
    echo ""; echo -e "${CLR_HEAD}[TEST] カバレッジ表: 全コマンド・フック・ワークフローが、載っている${CLR_RST}"
    local out nrows
    [[ -f "$PLAN_DOC" ]] && pass "計画書がある（doc/integration-test-plan.md）" || { fail "計画書がある" "$PLAN_DOC"; return; }
    nrows=$(_cov_rows "$PLAN_DOC" | grep -c .)
    # 解析が失敗して、何も検査せずに通る、ということを防ぐ（今の実体は、コマンド 21 + フック 2 + ワークフロー 5 = 28）
    [[ "$nrows" -ge 28 ]] && pass "表の行を、読めた（${nrows} 行）" || fail "表の行を、読めた" "${nrows} 行（28 行以上のはず。表の形式が変わって、読めていない可能性）"
    out=$(_cov_check "$PLAN_DOC" "$SF_TOOLS_DIR")
    if [[ -z "$out" ]]; then
        pass "実体が、すべて表に載っている・各行の結合・パターン・理由が、そろっている"
    else
        fail "カバレッジ表に、誤りがある" "$(printf '%s' "$out" | tr '\n' ' ')"
    fi
}

# ------------------------------------------------------------------------------
# ガード自体のテスト（誤りを、ちゃんと検出するか）
# ------------------------------------------------------------------------------
test_coverage_guard_detects() {
    echo ""; echo -e "${CLR_HEAD}[TEST] カバレッジ表のガード: 誤りを検出する${CLR_RST}"
    local td out root f
    td=$(mktemp -d "${TMPDIR:-/tmp}/test-cov-XXXX")

    # (a) 行の削除: sf-push の行を消す → 載っていない
    grep -v '^| `sf-push` |' "$PLAN_DOC" > "$td/a.md"
    out=$(_cov_check "$td/a.md" "$SF_TOOLS_DIR")
    [[ "$out" == *"sf-push が、10.2 の表に載っていない"* ]] && pass "行を削除 → 載っていないと、検出する" || fail "行を削除 → 検出する" "$out"

    # (b) 結合なしの理由を消す: sf-launcher の理由を「—」にする
    sed 's/^\(| `sf-launcher` | なし | — | \).*$/\1— |/' "$PLAN_DOC" > "$td/b.md"
    out=$(_cov_check "$td/b.md" "$SF_TOOLS_DIR")
    [[ "$out" == *"sf-launcher: 結合なしなのに、理由がない"* ]] && pass "結合なしの理由を削除 → 検出する" || fail "結合なしの理由を削除 → 検出する" "$out"

    # (c) 結合ありのパターンを消す: sf-job のパターンを「—」にする
    sed 's/^\(| `sf-job` | あり | \)[^|]* |/\1— |/' "$PLAN_DOC" > "$td/c.md"
    out=$(_cov_check "$td/c.md" "$SF_TOOLS_DIR")
    [[ "$out" == *"sf-job: 結合ありなのに、パターンの番号がない"* ]] && pass "結合ありのパターンを削除 → 検出する" || fail "結合ありのパターンを削除 → 検出する" "$out"

    # (d) 未定義のパターンの番号: sf-job の A7 を A99 に変える
    sed 's/^\(| `sf-job` | あり | \)A7/\1A99/' "$PLAN_DOC" > "$td/d.md"
    out=$(_cov_check "$td/d.md" "$SF_TOOLS_DIR")
    [[ "$out" == *"sf-job: パターン A99 の定義が、計画書にない"* ]] && pass "未定義のパターンの番号 → 検出する" || fail "未定義のパターンの番号 → 検出する" "$out"

    # (e) 「結合」の欄が、不正
    sed 's/^\(| `sf-job` | \)あり/\1たぶん/' "$PLAN_DOC" > "$td/e.md"
    out=$(_cov_check "$td/e.md" "$SF_TOOLS_DIR")
    [[ "$out" == *"sf-job: 「結合」の欄が、あり・一部・なし のどれでもない"* ]] && pass "「結合」の欄が不正 → 検出する" || fail "「結合」の欄が不正 → 検出する" "$out"

    # (f) 実体だけが増える（新しいコマンドを足して、表に載せ忘れた）: 本物のルートの写し（名前だけ）に、sf-newcmd.sh を足す
    root="$td/root"
    mkdir -p "$root/bin" "$root/hooks" "$root/templates/.github/workflows"
    for f in "$SF_TOOLS_DIR"/bin/sf-*.sh; do : > "$root/bin/$(basename "$f")"; done
    for f in "$SF_TOOLS_DIR"/hooks/*; do : > "$root/hooks/$(basename "$f")"; done
    for f in "$SF_TOOLS_DIR"/templates/.github/workflows/*.yml; do : > "$root/templates/.github/workflows/$(basename "$f")"; done
    out=$(_cov_check "$PLAN_DOC" "$root")
    [[ -z "$out" ]] && pass "名前だけの写しでは、誤りがない（比較の基準）" || fail "名前だけの写しでは、誤りがない" "$out"
    : > "$root/bin/sf-newcmd.sh"
    out=$(_cov_check "$PLAN_DOC" "$root")
    [[ "$out" == *"コマンド sf-newcmd が、10.2 の表に載っていない"* ]] && pass "新しいコマンドを足して、表に載せ忘れる → 検出する" || fail "新しいコマンドの載せ忘れ → 検出する" "$out"
    rm -f "$root/bin/sf-newcmd.sh"
    : > "$root/hooks/pre-newhook"
    out=$(_cov_check "$PLAN_DOC" "$root")
    [[ "$out" == *"フック hooks/pre-newhook が、10.3 の表に載っていない"* ]] && pass "新しいフックの載せ忘れ → 検出する" || fail "新しいフックの載せ忘れ → 検出する" "$out"
    rm -f "$root/hooks/pre-newhook"
    : > "$root/templates/.github/workflows/wf-new.yml"
    out=$(_cov_check "$PLAN_DOC" "$root")
    [[ "$out" == *"ワークフロー wf-new.yml が、10.4 の表に載っていない"* ]] && pass "新しいワークフローの載せ忘れ → 検出する" || fail "新しいワークフローの載せ忘れ → 検出する" "$out"
    rm -f "$root/templates/.github/workflows/wf-new.yml"

    # (g) 表にだけ、あって、実体がない（コマンドを消して、表に残した）
    rm -f "$root/bin/sf-typecheck.sh"
    out=$(_cov_check "$PLAN_DOC" "$root")
    [[ "$out" == *"表の sf-typecheck は、実在しない"* ]] && pass "表にだけあって、実体がない → 検出する" || fail "表にだけあって、実体がない → 検出する" "$out"

    rm -rf "$td"
}

test_coverage_real
test_coverage_guard_detects

print_summary
