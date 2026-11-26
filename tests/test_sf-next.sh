#!/bin/bash
# ==============================================================================
# test_sf-next.sh - sf-next.sh のテスト
# ==============================================================================
# 判定の本体は sf-promote-check.sh --plan（tests/test_sf-promote-check.sh が確かめる）。ここでは、偽の判定
# （環境変数 SF_PROMOTE_CHECK_CMD。終了コードと JSON を MOCK_PC_RC・MOCK_PC_JSON で決める）を使い、表示・確認・
# PR の作成画面の URL を確かめる。
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-next.sh ===${CLR_RST}"

# git モック（symbolic-ref・remote get-url だけ）
_make_git() {
    cat > "$1/git" << 'EOF'
#!/bin/bash
echo "git $*" >> "${MOCK_CALL_LOG:-/dev/null}"
case "$1" in
    symbolic-ref) echo "${MOCK_GIT_BRANCH:-feature/test}"; exit 0 ;;
    remote)
        # MOCK_GIT_REMOTE_URL が未設定なら既定の URL。空を設定すると、origin がない（何も出さない）
        [[ "$2" == "get-url" ]] && echo "${MOCK_GIT_REMOTE_URL-https://github.com/test-owner/force-tama.git}"
        exit 0 ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$1/git"
}
# 偽の判定（sf-promote-check.sh --plan --json の代わり）
_make_pc() {
    cat > "$1/fake-pc.sh" << 'EOF'
#!/bin/bash
echo "pc $*" >> "${MOCK_CALL_LOG:-/dev/null}"
echo "[INFO] 偽の判定" >&2
printf '%s\n' "$MOCK_PC_JSON"
exit "${MOCK_PC_RC:-0}"
EOF
    chmod +x "$1/fake-pc.sh"
}
# JSON を作る。引数: next_tier [pr_open] [skipped] [tiers（空白区切り。既定 develop staging main）]
_pc_json() {
    local t="" x
    for x in ${4:-develop staging main}; do t="${t}${t:+,}\"${x}\""; done
    printf '{"mode":"plan","ok":true,"skipped":%s,"branch":"feature/my-feature","head":"h","target":"%s","next_tier":"%s","pr_open":"%s","tiers":[%s],"violations":[],"error":""}' \
        "${3:-false}" "$1" "$1" "${2:-}" "$t"
}
_env() { # 変数名 td mb mh
    setup_std_env "$1" "$2" "$3"
    local mbv; mbv="${!2}"
    _make_git "$mbv"; _make_pc "$mbv"; create_mock_browser "$mbv"
    export SF_PROMOTE_CHECK_CMD="$mbv/fake-pc.sh" MOCK_GIT_BRANCH="feature/my-feature" MOCK_PC_RC=0
}
_unset() { unset SF_PROMOTE_CHECK_CMD MOCK_GIT_BRANCH MOCK_PC_RC MOCK_PC_JSON MOCK_GIT_REMOTE_URL; }
_next() { # 標準入力の答え [追加の環境変数...] → 出力。終了コードは NX_RC
    local ans="$1"; shift
    NX_OUT=$(cd "$TD" && printf '%s\n' "$ans" | env PATH="$MB:$PATH" "$@" bash "$SF_TOOLS_DIR/bin/sf-next.sh" 2>&1); NX_RC=$?
}

test_display_and_next() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 表示と次の PR 先${CLR_RST}"
    local TD MB MH; _env TD MB MH
    export MOCK_PC_JSON; MOCK_PC_JSON=$(_pc_json staging)
    _next n
    assert_exit_ok "$NX_RC" "staging が次 → 0"
    assert_output_contains "$NX_OUT" "✓.*develop.*リリース済み" "develop は ✓（このコミットでリリース済み）"
    assert_output_contains "$NX_OUT" "▶.*staging.*次のPR先" "staging は ▶（次の PR 先）"
    assert_output_contains "$NX_OUT" "✗.*main" "main は ✗"
    assert_output_contains "$NX_OUT" "develop の組織で、動作を確かめ終えましたか？ staging にPRを出しますか？" "staging へは、develop の組織での確認を聞く"
    assert_file_contains "$MOCK_CALL_LOG" "pc --plan --json" "判定は sf-promote-check.sh --plan --json"
    MOCK_PC_JSON=$(_pc_json develop)
    _next n
    assert_output_contains "$NX_OUT" "▶.*develop.*次のPR先" "develop が次（develop に出したあと変えたときも、ここに戻る）"
    assert_output_contains "$NX_OUT" "develop にPRを出しますか？" "一番下の段階は、前の組織の確認を聞かない"
    assert_output_not_contains "$NX_OUT" "の組織で、動作を確かめ終えましたか？ develop" "develop へは、前の段階の確認を付けない"
    MOCK_PC_JSON=$(_pc_json main)
    _next n
    assert_output_contains "$NX_OUT" "staging の組織で、動作を確かめ終えましたか？ main にPRを出しますか？" "main へは、staging の組織での確認を聞く"
    MOCK_PC_JSON=$(_pc_json none)
    _next n
    assert_exit_ok "$NX_RC" "全段階にリリース済み → 0"
    assert_output_contains "$NX_OUT" "全段階にリリース済みです" "全段階にリリース済み → 案内"
    MOCK_PC_JSON=$(_pc_json staging 12)
    _next n
    assert_output_contains "$NX_OUT" "→.*staging.*PR発行中（#12）" "開いている PR → PR 発行中（番号つき）"
    assert_output_contains "$NX_OUT" "検証が緑になってから、マージしてください" "開いている PR → マージを待つ案内"
    assert_output_not_contains "$NX_OUT" "PRを出しますか" "開いている PR → 新しく PR を勧めない"
    MOCK_PC_JSON=$(_pc_json main "" false "staging main")
    _next n
    assert_output_contains "$NX_OUT" "staging の組織で、動作を確かめ終えましたか？ main にPRを出しますか？" "2 段階（staging・main）でも、前の段階を聞く"
    MOCK_PC_JSON=$(_pc_json develop "" true)
    _next n
    assert_exit_ok "$NX_RC" "対象が空 → 0"
    assert_output_contains "$NX_OUT" "出すものがありません" "対象が空 → 案内（PR を勧めない）"
    _unset; teardown "$TD" "$MB"
}

test_rules_broken_or_unknown() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 決まりを破っている・判断できない${CLR_RST}"
    local TD MB MH; _env TD MB MH
    export MOCK_PC_RC=1 MOCK_PC_JSON='{"mode":"plan","ok":false,"skipped":false,"next_tier":"develop","pr_open":"","tiers":["develop"],"violations":[{"rule":"R2","detail":"前に develop へ出したリリース（PR #3）の部品が、今回にありません: ApexClass:B"}],"error":""}'
    _next y
    assert_exit_fail "$NX_RC" "R2 を破っている → エラー終了"
    assert_output_contains "$NX_OUT" "ApexClass:B" "破った理由を表示する"
    assert_file_not_contains "$MOCK_CALL_LOG" "compare/" "破っている → ブラウザを開かない"
    export MOCK_PC_RC=2 MOCK_PC_JSON='{"mode":"plan","ok":false,"next_tier":"","tiers":[],"violations":[],"error":"手元（abc1234）と origin/feature/my-feature（def5678）が違います（push していない変更があるか、取り込んでいない変更があります）。"}'
    _next y
    assert_exit_fail "$NX_RC" "判断できない → エラー終了"
    assert_output_contains "$NX_OUT" "push していない変更" "判断できない理由を表示する"
    export MOCK_PC_RC=2 MOCK_PC_JSON='これは JSON ではない'
    _next y
    assert_exit_fail "$NX_RC" "結果を読めない → エラー終了"
    _unset; teardown "$TD" "$MB"
}

test_protected_branch_blocked() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 保護ブランチの上では、実行しない${CLR_RST}"
    local TD MB MH; _env TD MB MH
    printf 'main\nstaging\ndevelop\n' > "$TD/sf-tools/config/branches.txt"
    export MOCK_GIT_BRANCH="develop"
    _next n
    assert_exit_fail "$NX_RC" "保護ブランチ（develop）→ エラー終了"
    assert_output_contains "$NX_OUT" "保護ブランチ" "保護ブランチ → 理由"
    assert_file_not_contains "$MOCK_CALL_LOG" "pc --plan" "保護ブランチ → 判定を呼ばない"
    _unset; teardown "$TD" "$MB"
}

test_pr_url() {
    echo ""; echo -e "${CLR_HEAD}[TEST] PR の作成画面の URL${CLR_RST}"
    local TD MB MH u; _env TD MB MH
    export MOCK_PC_JSON; MOCK_PC_JSON=$(_pc_json staging)
    for u in "https://github.com/test-owner/force-tama.git" "git@github.com:test-owner/force-tama.git" "ssh://git@github.com/test-owner/force-tama.git"; do
        : > "$MOCK_CALL_LOG"
        export MOCK_GIT_REMOTE_URL="$u"
        _next y
        assert_output_contains "$NX_OUT" "https://github.com/test-owner/force-tama/compare/staging...feature/my-feature" "origin が ${u} → https の PR 作成画面の URL"
    done
    assert_file_contains "$MOCK_CALL_LOG" "compare/staging...feature/my-feature" "ブラウザで、PR 作成画面を開く"
    for u in "https://x-access-token:ghp_SECRETTOKEN123@github.com/test-owner/force-tama.git" "http://user@github.com/test-owner/force-tama.git"; do
        : > "$MOCK_CALL_LOG"
        export MOCK_GIT_REMOTE_URL="$u"
        _next y
        assert_output_contains "$NX_OUT" "//github.com/test-owner/force-tama/compare/staging...feature/my-feature" "認証情報つきの origin（${u%%@*}@...）→ 認証情報を除いた URL"
        echo "$NX_OUT" | grep -q "SECRETTOKEN\|user@" && fail "認証情報を画面に出さない" || pass "認証情報を画面に出さない"
        grep -v "remote get-url" "$MOCK_CALL_LOG" | grep -q "SECRETTOKEN\|user@" && fail "認証情報をブラウザに渡さない" || pass "認証情報をブラウザに渡さない"
    done
    : > "$MOCK_CALL_LOG"
    export MOCK_GIT_REMOTE_URL=""
    _next y
    assert_exit_fail "$NX_RC" "origin の URL がない → エラー終了"
    assert_output_contains "$NX_OUT" "origin の URL を取得できません" "origin の URL がない → 理由"
    assert_file_not_contains "$MOCK_CALL_LOG" "compare/" "origin の URL がない → ブラウザを開かない"
    _unset; teardown "$TD" "$MB"
}

# AI 操作（SF_TOOLS_AI=1）: next.pr=n → 表示だけ／=y → 開く／答えなし → ブラウザを開く前に 20
test_ai_mode() {
    echo ""; echo -e "${CLR_HEAD}[TEST] AI 操作${CLR_RST}"
    local TD MB MH; _env TD MB MH
    export MOCK_PC_JSON; MOCK_PC_JSON=$(_pc_json staging)
    _next y SF_TOOLS_AI=1
    assert_equals "$NX_RC" "20" "AI・答えなし → 20（標準入力の y は読まない）"
    assert_output_contains "$NX_OUT" "\[確認待ち\] next.pr: develop の組織で、動作を確かめ終えましたか？ staging にPRを出しますか？" "AI・答えなし → 確認待ちの行"
    assert_file_not_contains "$MOCK_CALL_LOG" "compare/" "AI・答えなし → ブラウザを開かない"
    : > "$MOCK_CALL_LOG"
    _next "" SF_TOOLS_AI=1 SF_TOOLS_ANSWERS="next.pr=n"
    assert_exit_ok "$NX_RC" "AI・next.pr=n → 正常終了"
    assert_output_contains "$NX_OUT" "▶.*staging" "AI・next.pr=n → 状況を表示する"
    assert_file_not_contains "$MOCK_CALL_LOG" "compare/" "AI・next.pr=n → ブラウザを開かない"
    : > "$MOCK_CALL_LOG"
    _next "" SF_TOOLS_AI=1 SF_TOOLS_ANSWERS="next.pr=y"
    assert_exit_ok "$NX_RC" "AI・next.pr=y → 正常終了"
    assert_file_contains "$MOCK_CALL_LOG" "compare/staging...feature/my-feature" "AI・next.pr=y → PR の作成画面を開く"
    _unset; teardown "$TD" "$MB"
}

test_display_and_next
test_rules_broken_or_unknown
test_protected_branch_blocked
test_pr_url
test_ai_mode

print_summary
