#!/bin/bash
# ==============================================================================
# test_wf-sequence.sh - templates/.github/workflows/wf-sequence.yml のテスト
# ==============================================================================
# YAML の中の run スクリプトを取り出して、GitHub Actions と同じシェル（bash --noprofile --norc -eo pipefail）で実行する。
#   - 「マージ順序を検証」（id: sequence_check）: 判定の本体は sf-promote-check.sh（tests/test_sf-promote-check.sh が確かめる）。
#     ここでは、偽の sf-promote-check.sh（HOME/sf-tools/bin/ に置く。終了コードと JSON を環境変数で決める）で、
#     呼び出し方（--pr <番号> --only sequence --json）と、出力（out_of_order・env_branch・feature・detail）と終了コードの対応を確かめる
#   - 「デプロイ対象ファイルを確認」（id: check）: 実際の git リポジトリ（ローカルのリモートつき）で、スキップの判定を確かめる
#   - 構造: 権限・コメントの目印・always() の通知・警告だけにしないこと（Hotfix の例外がないこと）
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== wf-sequence.yml ===${CLR_RST}"

WF="$SF_TOOLS_DIR/templates/.github/workflows/wf-sequence.yml"
_GH_BASH=(bash --noprofile --norc -eo pipefail -c)

# YAML から、step「id: <ID>」の run のスクリプトを取り出す（インデント 10 を除く）
_extract_script() {
    awk -v id="${1:-sequence_check}" '
        $0 ~ ("id: " id "$") { f = 1 }
        f && /^        run: \|/ { r = 1; next }
        r && /^$/ { print ""; next }
        r && /^          / { sub(/^          /, ""); print; next }
        r { exit }
    ' "$WF"
}

# 「マージ順序を検証」を、偽の sf-promote-check.sh で動かす。引数: 終了コード JSON。出力: GITHUB_OUTPUT の内容 + RC= + 呼び出しの引数
_run_seq() {
    local rc="$1" json="$2" td out script code
    td=$(mktemp -d "${TMPDIR:-/tmp}/wfseq-XXXX")
    mkdir -p "$td/home/sf-tools/bin" "$td/w/force-promote-check"
    cat > "$td/home/sf-tools/bin/sf-promote-check.sh" <<'EOF'
#!/bin/bash
echo "$*" > "$HOME/args.txt"
echo "[INFO] 偽の確認" >&2
printf '%s\n' "$MOCK_PC_JSON"
exit "$MOCK_PC_RC"
EOF
    script=$(_extract_script)
    : > "$td/out"
    ( cd "$td/w" && HOME="$td/home" MOCK_PC_RC="$rc" MOCK_PC_JSON="$json" GH_TOKEN=x PR_NUMBER=42 FEATURE_REF=feature-a \
        GITHUB_OUTPUT="$td/out" "${_GH_BASH[@]}" "$script" > "$td/stdout" 2>&1 )
    code=$?
    cat "$td/out"
    echo "RC=$code"
    echo "ARGS=$(cat "$td/home/args.txt" 2>/dev/null)"
    cat "$td/stdout"
    rm -rf "$td"
}

test_wf_sequence_structure() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 構造${CLR_RST}"
    local s; s=$(_extract_script)
    [[ "$s" == *"sf-promote-check.sh --pr \"\$PR_NUMBER\" --only sequence --json"* ]] && pass "判定は sf-promote-check.sh --pr <番号> --only sequence" || fail "判定は sf-promote-check.sh --pr <番号> --only sequence"
    assert_file_contains "$WF" "ref: \${{ github.event.pull_request.head.sha }}" "PR の先端のコミットを取得する"
    assert_file_contains "$WF" "path: force-promote-check" "force- で始まるフォルダに取得する"
    assert_file_contains "$WF" "statuses: read" "リリースの印を読む権限がある"
    assert_file_contains "$WF" "actions: read" "印を付けた実行を読む権限がある"
    assert_file_contains "$WF" "pull-requests: write" "PR にコメントを投稿するための権限がある"
    assert_file_contains "$WF" "sf-tools:sequence" "コメントの目印（既存コメントの更新用）がある"
    assert_file_not_contains "$WF" "意図的な場合はそのまま進めてください" "順序外を警告だけにしない（Hotfix の例外がない）"
    local n; n=$(grep -c "if: always()" "$WF")
    assert_equals "$n" "2" "コメントと Slack の step は、always() で、エラーのあとも実行される"
    assert_file_contains "$WF" "steps.sequence_check.outputs.env_branch == 'true'" "コメント・Slack の条件に、環境ブランチからの PR がある"
    assert_file_contains "$WF" "環境ブランチからの PR は、許可されていません" "PR のコメントに、環境ブランチからの PR の文面がある"
    assert_file_contains "$WF" "一方通行の決まりにより、この PR はマージできません" "PR のコメント・Slack に、順序外で止めた文面がある"
}

test_wf_sequence_mapping() {
    echo ""; echo -e "${CLR_HEAD}[TEST] sf-promote-check.sh の結果と、出力・終了コードの対応${CLR_RST}"
    local out
    out=$(_run_seq 0 '{"ok":true,"violations":[],"error":""}')
    assert_output_contains "$out" "RC=0" "0 → 成功"
    assert_output_contains "$out" "out_of_order=false" "0 → out_of_order=false"
    assert_output_contains "$out" "feature=feature-a" "ブランチ名を出力する"
    assert_output_contains "$out" "ARGS=--pr 42 --only sequence --json" "PR 番号と --only sequence で呼ぶ"
    out=$(_run_seq 1 '{"ok":false,"violations":[{"rule":"R1","detail":"abc1234 は、まだ develop に出ていません"}],"error":""}')
    assert_output_contains "$out" "RC=1" "R1 → 失敗（警告だけにしない）"
    assert_output_contains "$out" "out_of_order=true" "R1 → out_of_order=true"
    assert_output_contains "$out" "detail=abc1234 は、まだ develop に出ていません" "R1 → 理由を detail に出す"
    assert_output_not_contains "$out" "env_branch=true" "R1 → env_branch は出さない"
    out=$(_run_seq 1 '{"ok":false,"violations":[{"rule":"R3","detail":"環境ブランチ develop から"}],"error":""}')
    assert_output_contains "$out" "RC=1" "R3 → 失敗"
    assert_output_contains "$out" "env_branch=true" "R3 → env_branch=true"
    out=$(_run_seq 2 '{"ok":false,"violations":[],"error":"origin の main を取得できません。"}')
    assert_output_contains "$out" "RC=1" "2（判断できない）→ 失敗（素通りさせない）"
    assert_output_contains "$out" "detail=origin の main を取得できません。" "2 → 理由を detail に出す"
    assert_output_not_contains "$out" "out_of_order=" "2 → out_of_order は出さない"
    out=$(_run_seq 2 'これは JSON ではない')
    assert_output_contains "$out" "RC=1" "JSON が読めない → 失敗"
}

# ------------------------------------------------------------------------------
# 「デプロイ対象ファイルを確認」（スキップの判定）
# ------------------------------------------------------------------------------
_make_repo() {
    local base clone
    base=$(mktemp -d "${TMPDIR:-/tmp}/wfseq-XXXX")
    git init -q --bare "$base/origin.git"
    git clone -q "$base/origin.git" "$base/work" 2>/dev/null
    clone="$base/work"
    git -C "$clone" config core.autocrlf false
    (
        cd "$clone" || exit 1
        export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
        git checkout -q -b main
        mkdir -p sf-tools/config
        printf 'main\nstaging\ndevelop\n' > sf-tools/config/branches.txt
        git add -A && git commit -q -m init
        git push -q origin main
    )
    echo "$clone"
}
_run_skipcheck() {
    local repo="$1" head="$2" script rc out="$1/.gh_output_skip"
    script=$(_extract_script check)
    : > "$out"
    ( cd "$repo" && HEAD_REF="$head" GITHUB_OUTPUT="$out" "${_GH_BASH[@]}" "$script" > "$repo/.gh_stdout_skip" 2>&1 )
    rc=$?
    cat "$out"
    echo "RC=$rc"
}
_set_main_branches_txt() {
    local repo="$1" content="$2"
    (
        cd "$repo" || exit 1
        export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
        git checkout -q main
        if [[ -z "$content" ]]; then git rm -q sf-tools/config/branches.txt
        else mkdir -p sf-tools/config && printf '%s' "$content" > sf-tools/config/branches.txt && git add sf-tools/config/branches.txt; fi
        git commit -q -m "branches.txt を変更" && git push -q origin main
    )
}

test_wf_sequence_skip_decision() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 対象ファイル確認（スキップの判定）${CLR_RST}"
    local repo out b; repo=$(_make_repo)
    out=$(_run_skipcheck "$repo" feature-a)
    assert_output_contains "$out" "skip=true" "デプロイ対象がない feature ブランチの PR → スキップ"
    mkdir -p "$repo/sf-tools/release/feature-a"
    printf '[members]\nCustomLabel:X\n' > "$repo/sf-tools/release/feature-a/deploy-target.txt"
    out=$(_run_skipcheck "$repo" feature-a)
    assert_output_contains "$out" "skip=false" "デプロイ対象がある feature ブランチの PR → チェックを実行"
    for b in develop staging main; do
        out=$(_run_skipcheck "$repo" "$b")
        assert_output_contains "$out" "skip=false" "環境ブランチ（$b）からの PR → デプロイ対象がなくても、チェックを実行する"
        assert_output_contains "$out" "RC=0" "環境ブランチ（$b）→ 対象ファイル確認の step は、成功で終わる"
    done
    rm -rf "$(dirname "$repo")"
}

test_wf_sequence_skip_branches_file() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 対象ファイル確認: branches.txt がない・main を取得できない${CLR_RST}"
    local repo out; repo=$(_make_repo)
    _set_main_branches_txt "$repo" ""
    out=$(_run_skipcheck "$repo" feature-a)
    assert_output_contains "$out" "RC=0" "branches.txt がない → 対象ファイル確認は、成功で終わる（-eo pipefail でも）"
    assert_output_contains "$out" "skip=true" "branches.txt がない → デプロイ対象がなければ、スキップ"
    git -C "$repo" remote set-url origin "$(dirname "$repo")/no-such-remote.git"
    out=$(_run_skipcheck "$repo" feature-a)
    assert_output_contains "$out" "skip=false" "main を取得できない → skip=false（順序チェックに任せる）"
    assert_output_contains "$out" "RC=0" "main を取得できない → 対象ファイル確認は、失敗にしない"
    rm -rf "$(dirname "$repo")"
}

test_wf_sequence_structure
test_wf_sequence_mapping
test_wf_sequence_skip_decision
test_wf_sequence_skip_branches_file

print_summary
