#!/bin/bash
# ==============================================================================
# test_wf-sequence.sh - templates/.github/workflows/wf-sequence.yml のテスト
# ==============================================================================
# YAML の中の「マージ順序を検証」の run スクリプトを取り出して、実際の git リポジトリ（ローカルのリモートつき）で実行する。
# 確認すること: 順序どおり・順序外・最下位への PR・環境ブランチからの PR
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== wf-sequence.yml ===${CLR_RST}"

WF="$SF_TOOLS_DIR/templates/.github/workflows/wf-sequence.yml"

# YAML から、step「id: sequence_check」の run のスクリプトを取り出す（インデント 10 を除く）
_extract_script() {
    awk -v id="${1:-sequence_check}" '
        $0 ~ ("id: " id "$") { f = 1 }
        f && /^        run: \|/ { r = 1; next }
        r && /^$/ { print ""; next }
        r && /^          / { sub(/^          /, ""); print; next }
        r { exit }
    ' "$WF"
}

# テスト用のリポジトリを作る（ローカルのリモートつき）。main / staging / develop と、feature-a を作る
#   出力: 作業ディレクトリのパス
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
        git branch staging && git branch develop
        git push -q origin staging develop
        git checkout -q -b feature-a
        echo a > a.txt && git add a.txt && git commit -q -m a
        git push -q origin feature-a
        git checkout -q main
    )
    echo "$clone"
}

# 判定スクリプトを実行する。引数: リポジトリ FEATURE BASE。出力: GITHUB_OUTPUT の内容 + 終了コード（RC=）
_run_check() {
    local repo="$1" feature="$2" base="$3" script rc
    local out="$repo/.gh_output"   # repo を使うため、local を分ける（同じ local 内では、$repo が展開されない）
    script=$(_extract_script)
    : > "$out"
    ( cd "$repo" && FEATURE_REF="$feature" BASE_REF="$base" GITHUB_OUTPUT="$out" bash -c "$script" > "$repo/.gh_stdout" 2>&1 )
    rc=$?
    cat "$out"
    echo "RC=$rc"
}

# 「対象ファイル確認」（スキップの判定）を実行する。引数: リポジトリ HEAD_REF。出力: GITHUB_OUTPUT の内容 + RC=
_run_skipcheck() {
    local repo="$1" head="$2" script rc
    local out="$repo/.gh_output_skip"   # repo を使うため、local を分ける
    script=$(_extract_script check)
    : > "$out"
    ( cd "$repo" && HEAD_REF="$head" GITHUB_OUTPUT="$out" bash -c "$script" > "$repo/.gh_stdout_skip" 2>&1 )
    rc=$?
    cat "$out"
    echo "RC=$rc"
}

# feature-a を、指定したブランチへマージして、リモートへ push する（前の段階にマージ済みの状態を作る）
_merge_into() {
    local repo="$1" branch="$2"
    (
        cd "$repo" || exit 1
        export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
        git checkout -q "$branch" && git merge -q --no-ff -m "merge feature-a" feature-a && git push -q origin "$branch"
        git checkout -q main
    )
}

test_wf_sequence_extractable() {
    local s; s=$(_extract_script)
    [[ -n "$s" && "$s" == *"origin/main:sf-tools/config/branches.txt"* ]] && pass "YAML から、判定のスクリプトを取り出せた" || fail "YAML から、判定のスクリプトを取り出せた"
    assert_file_contains "$WF" "pull-requests: write" "PR にコメントを投稿するための権限（pull-requests: write）がある"
    assert_file_contains "$WF" "sf-tools:sequence" "コメントの目印（既存コメントの更新用）がある"
}

test_wf_sequence_in_order() {
    local repo out; repo=$(_make_repo)
    _merge_into "$repo" develop
    _merge_into "$repo" staging
    out=$(_run_check "$repo" feature-a main)
    assert_output_contains "$out" "out_of_order=false" "順序どおり（develop・staging にマージ済み）→ out_of_order=false"
    assert_output_contains "$out" "RC=0" "順序どおり → 終了コード 0"
    rm -rf "$(dirname "$repo")"
}

test_wf_sequence_out_of_order() {
    local repo out; repo=$(_make_repo)
    # develop にだけマージ済み。staging にマージされていない状態で、main へ PR（飛び越し）
    _merge_into "$repo" develop
    out=$(_run_check "$repo" feature-a main)
    assert_output_contains "$out" "out_of_order=true" "staging 未マージ → out_of_order=true"
    assert_output_contains "$out" "prev=staging" "未マージの段階（staging）が出力される"
    assert_output_contains "$out" "feature=feature-a" "対象のブランチ名が出力される"
    assert_output_contains "$out" "RC=0" "判定スクリプト自体は、成功で終わる（失敗にするのは、後の step）"
    # 何もマージされていない状態で、staging へ PR → develop が未マージ
    rm -rf "$(dirname "$repo")"; repo=$(_make_repo)
    out=$(_run_check "$repo" feature-a staging)
    assert_output_contains "$out" "out_of_order=true" "develop 未マージで staging へ PR → out_of_order=true"
    assert_output_contains "$out" "prev=develop" "未マージの段階（develop）が出力される"
    rm -rf "$(dirname "$repo")"
}

test_wf_sequence_skip_decision() {
    local repo out; repo=$(_make_repo)
    # デプロイ対象がない feature ブランチ → スキップ
    out=$(_run_skipcheck "$repo" feature-a)
    assert_output_contains "$out" "skip=true" "デプロイ対象がない feature ブランチの PR → スキップ"
    # デプロイ対象がある feature ブランチ → チェックを実行
    mkdir -p "$repo/sf-tools/release/feature-a"
    printf '[members]\nCustomLabel:X\n' > "$repo/sf-tools/release/feature-a/deploy-target.txt"
    out=$(_run_skipcheck "$repo" feature-a)
    assert_output_contains "$out" "skip=false" "デプロイ対象がある feature ブランチの PR → チェックを実行"
    # 環境ブランチから直接出された PR → デプロイ対象がなくても、必ず、チェックを実行する（これが無いと、素通りになる）
    local b
    for b in develop staging main; do
        out=$(_run_skipcheck "$repo" "$b")
        assert_output_contains "$out" "skip=false" "環境ブランチ（$b）からの PR → デプロイ対象がなくても、チェックを実行する"
        assert_output_contains "$out" "RC=0" "環境ブランチ（$b）→ 対象ファイル確認の step は、成功で終わる"
    done
    rm -rf "$(dirname "$repo")"
}

test_wf_sequence_skip_both() {
    local repo out; repo=$(_make_repo)
    # どちらにもマージされていない状態で、main へ PR（一気に飛び越し）
    out=$(_run_check "$repo" feature-a main)
    assert_output_contains "$out" "out_of_order=true" "一気に飛び越し（staging・develop とも未）→ out_of_order=true"
    assert_output_contains "$out" "prev=staging, develop" "未マージの段階が、両方（staging, develop）出力される"
    rm -rf "$(dirname "$repo")"
}

test_wf_sequence_lowest_stage() {
    local repo out; repo=$(_make_repo)
    out=$(_run_check "$repo" feature-a develop)
    assert_output_contains "$out" "out_of_order=false" "最下位（develop）への PR は、前の段階がないため、順序外にならない"
    rm -rf "$(dirname "$repo")"
}

test_wf_sequence_env_branch_pr_blocked() {
    local repo out pair; repo=$(_make_repo)
    # 環境ブランチから直接 PR（develop → main / develop → staging / staging → main）は、エラーで終わり、結果を出力する
    #   （PR のコメント・Slack が、この出力を使う。出力が、エラーの前に書かれていること）
    for pair in "develop main" "develop staging" "staging main"; do
        set -- $pair
        out=$(_run_check "$repo" "$1" "$2")
        assert_output_contains "$out" "RC=1" "環境ブランチ（$1）から $2 への PR → エラーで終わる"
        assert_output_contains "$out" "env_branch=true" "環境ブランチ（$1 → $2）→ env_branch=true を出力する"
        assert_output_contains "$out" "feature=$1" "環境ブランチ（$1 → $2）→ ブランチ名を出力する"
    done
    rm -rf "$(dirname "$repo")"
}

test_wf_sequence_env_branch_notified() {
    # 環境ブランチからの PR も、PR の会話欄のコメントと、Slack に通知する（直前の step が失敗しても実行する）
    assert_file_contains "$WF" "steps.sequence_check.outputs.env_branch == 'true'" "コメント・Slack の条件に、環境ブランチからの PR がある"
    assert_file_contains "$WF" "環境ブランチからの PR は、許可されていません" "PR のコメントに、環境ブランチからの PR の文面がある"
    assert_file_contains "$WF" "環境ブランチからの PR は許可されていません" "Slack に、環境ブランチからの PR の文面がある"
    local n; n=$(grep -c "if: always()" "$WF")
    assert_equals "$n" "2" "コメントと Slack の step は、always() で、エラーのあとも実行される"
}

test_wf_sequence_extractable
test_wf_sequence_in_order
test_wf_sequence_out_of_order
test_wf_sequence_skip_decision
test_wf_sequence_skip_both
test_wf_sequence_lowest_stage
test_wf_sequence_env_branch_pr_blocked
test_wf_sequence_env_branch_notified

print_summary
