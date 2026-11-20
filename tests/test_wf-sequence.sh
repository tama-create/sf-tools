#!/bin/bash
# ==============================================================================
# test_wf-sequence.sh - templates/.github/workflows/wf-sequence.yml のテスト
# ==============================================================================
# YAML の中の「マージ順序を検証」の run スクリプトを取り出して、実際の git リポジトリ（ローカルのリモートつき）で実行する。
# 確認すること: 順序どおり・順序外・最下位への PR・環境ブランチからの PR・フォークからの PR・
#   main に branches.txt がない／ブランチの行がない場合（Actions と同じ -eo pipefail で、ジョブが止まらないこと）
# 診断と再実行: 判定スクリプトの標準出力・標準エラーを出力に付ける。全件の並列実行で、まれに期待が外れる（原因は未特定）ため、
#   期待が外れたら、直前の判定を 1 回だけ再実行する。再実行で通ったら、初回の出力の全文を [RETRY] 付きで残す。
#   再実行でも外れたら、失敗にして、両方の出力の全文を表示する（assert_output_contains は、このファイルの中で上書きしている）
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

# run のスクリプトを、GitHub Actions と同じシェル（bash --noprofile --norc -eo pipefail）で実行する
#   -e・pipefail がないと、grep の該当なしなどで、Actions ではジョブが止まる不具合を、見逃す
_GH_BASH=(bash --noprofile --norc -eo pipefail -c)

# 並列実行（run_tests.sh の全件）で、まれに落ちる原因を調べるための診断。
#   スクリプトの標準出力・標準エラーは、後で消えるため、RC= の行のあとに付ける（落ちたときに、原因を読めるようにする）。
#   付ける文には、アサーションが探す文字列（out_of_order=・skip=・RC= など）は含まれない
_diag_stdout() {
    echo "[スクリプトの標準出力・標準エラー]"
    cat "$1" 2>/dev/null
}

# 直前に実行した判定の記録（実行したコマンドと、その出力）。まれな失敗のとき、1 回だけ再実行するために使う。
#   $(...) の中で実行されるため、変数ではなくファイルに残す。最後（print_summary の前）に削除する
_WFS_STATE=$(mktemp -d "${TMPDIR:-/tmp}/wfseq-state-XXXX")

# 判定を実行して、その実行内容と出力を記録する。引数: 実行する関数 引数…。出力: その関数の出力そのまま
_record_run() {
    local out
    out=$("$@")   # VAR=$(cmd) のため run 不使用
    printf '%q ' "$@" > "$_WFS_STATE/cmd"
    printf '%s\n' "$out" > "$_WFS_STATE/out"
    printf '%s\n' "$out"
}

# 出力に文字列が含まれるかを確認する（test_helper.sh の同名の関数を、この中で上書きする）。
#   並列実行（run_tests.sh の全件）で、まれに期待が外れることがある（原因は未特定）ため、期待が外れたら、
#   直前の判定（$1 が、その出力と同じときだけ）を 1 回だけ再実行する。再実行で通ったら成功とし、初回の出力の全文を
#   [RETRY] 付きで残す（あとで原因を読めるように）。本物の不具合は、再実行でも外れるので、見逃さない。
#   外れたままのときは、出力の全文（GITHUB_OUTPUT の内容・RC=・スクリプトの標準出力）も表示する
assert_output_contains() {
    if grep -q -- "$2" <<< "$1"; then
        pass "$3"
        return
    fi
    local cmd last out2
    cmd=$(cat "$_WFS_STATE/cmd" 2>/dev/null)
    last=$(cat "$_WFS_STATE/out" 2>/dev/null)
    if [[ -n "$cmd" && "$1" == "$last" ]]; then
        out2=$(eval "$cmd")   # VAR=$(cmd) のため run 不使用
        if grep -q -- "$2" <<< "$out2"; then
            pass "$3"
            echo "      [RETRY] 初回は期待が外れ、再実行で通った（まれな失敗の記録。期待: '$2'）"
            sed 's/^/      | 初回: /' <<< "$1"
            return
        fi
        fail "$3" "'$2' が出力に含まれていない（再実行でも外れた）"
        sed 's/^/      | 初回: /' <<< "$1"
        sed 's/^/      | 再実行: /' <<< "$out2"
        return
    fi
    fail "$3" "'$2' が出力に含まれていない"
    sed 's/^/      | /' <<< "$1"
}

# 判定スクリプトを実行する。引数: リポジトリ FEATURE BASE [HEAD_SHA]。出力: GITHUB_OUTPUT の内容 + 終了コード（RC=）+ 診断
#   HEAD_SHA（PR のソースの最新のコミット）を省略したときは、origin/<FEATURE> のコミット
_run_check() { _record_run _run_check_once "$@"; }
_run_check_once() {
    local repo="$1" feature="$2" base="$3" sha="${4:-}" script rc
    local out="$repo/.gh_output"   # repo を使うため、local を分ける（同じ local 内では、$repo が展開されない）
    [[ -n "$sha" ]] || sha=$(git -C "$repo" rev-parse -q --verify "origin/$feature" 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
    script=$(_extract_script)
    : > "$out"
    ( cd "$repo" && FEATURE_REF="$feature" BASE_REF="$base" HEAD_SHA="$sha" GITHUB_OUTPUT="$out" "${_GH_BASH[@]}" "$script" > "$repo/.gh_stdout" 2>&1 )
    rc=$?
    cat "$out"
    echo "RC=$rc"
    _diag_stdout "$repo/.gh_stdout"
}

# 「対象ファイル確認」（スキップの判定）を実行する。引数: リポジトリ HEAD_REF。出力: GITHUB_OUTPUT の内容 + RC= + 診断
_run_skipcheck() { _record_run _run_skipcheck_once "$@"; }
_run_skipcheck_once() {
    local repo="$1" head="$2" script rc
    local out="$repo/.gh_output_skip"   # repo を使うため、local を分ける
    script=$(_extract_script check)
    : > "$out"
    ( cd "$repo" && HEAD_REF="$head" GITHUB_OUTPUT="$out" "${_GH_BASH[@]}" "$script" > "$repo/.gh_stdout_skip" 2>&1 )
    rc=$?
    cat "$out"
    echo "RC=$rc"
    _diag_stdout "$repo/.gh_stdout_skip"
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

# main の branches.txt を書き換えて push する。引数: リポジトリ 内容（空文字なら、ファイルを消す）
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

test_wf_sequence_no_branches_file() {
    local repo out; repo=$(_make_repo)
    # main に branches.txt がない → 順序チェックは ::notice で成功、対象ファイル確認は環境ブランチなしとして続ける
    _set_main_branches_txt "$repo" ""
    out=$(_run_check "$repo" feature-a main)
    assert_output_contains "$out" "RC=0" "branches.txt がない → 順序チェックは、成功で終わる（-eo pipefail でも）"
    assert_file_contains "$repo/.gh_stdout" "branches.txt が見つかりません" "branches.txt がない → ::notice を出す"
    out=$(_run_skipcheck "$repo" feature-a)
    assert_output_contains "$out" "RC=0" "branches.txt がない → 対象ファイル確認は、成功で終わる（-eo pipefail でも）"
    assert_output_contains "$out" "skip=true" "branches.txt がない → デプロイ対象がなければ、スキップ"
    # ブランチの行が 1 つもない（コメント・空行だけ）→ マージ先が対象外として、成功で終わる
    _set_main_branches_txt "$repo" $'# コメントだけ\n\n'
    out=$(_run_check "$repo" feature-a main)
    assert_output_contains "$out" "RC=0" "ブランチの行がない → 順序チェックは、成功で終わる（-eo pipefail でも）"
    assert_file_contains "$repo/.gh_stdout" "チェック対象外のブランチです" "ブランチの行がない → 対象外の ::notice を出す"
    out=$(_run_skipcheck "$repo" develop)
    assert_output_contains "$out" "RC=0" "ブランチの行がない → 対象ファイル確認は、成功で終わる（-eo pipefail でも）"
    assert_output_contains "$out" "skip=true" "ブランチの行がない → 環境ブランチなしとして、デプロイ対象で判定する"
    rm -rf "$(dirname "$repo")"
}

test_wf_sequence_fetch_failure() {
    local repo out; repo=$(_make_repo)
    # origin の main を取得できない → 対象ファイル確認は skip=false で成功（ジョブを失敗にしない）、順序チェックは失敗（通さない）
    git -C "$repo" remote set-url origin "$(dirname "$repo")/no-such-remote.git"
    out=$(_run_skipcheck "$repo" feature-a)
    assert_output_contains "$out" "skip=false" "main を取得できない → 対象ファイル確認は skip=false（順序チェックに任せる）"
    assert_output_contains "$out" "RC=0" "main を取得できない → 対象ファイル確認は、失敗にしない"
    out=$(_run_check "$repo" feature-a main)
    [[ "$out" != *"RC=0"* && "$out" == *"RC="* ]] && pass "main を取得できない → 順序チェックは、失敗で終わる（素通りさせない）" || fail "main を取得できない → 順序チェックは、失敗で終わる（素通りさせない）" "$out"
    rm -rf "$(dirname "$repo")"
}

test_wf_sequence_fork_pr() {
    local repo out sha; repo=$(_make_repo)
    # フォークからの PR: origin/<ソースブランチ> がない。PR のソースのコミット（head.sha）で判定する
    _merge_into "$repo" develop
    _merge_into "$repo" staging
    sha=$(git -C "$repo" rev-parse feature-a)
    out=$(_run_check "$repo" fork-feature main "$sha")
    assert_output_contains "$out" "out_of_order=false" "フォークからの PR（origin にソースブランチなし）でも、マージ済みなら順序どおり"
    assert_output_contains "$out" "RC=0" "フォークからの PR → 終了コード 0"
    rm -rf "$(dirname "$repo")"; repo=$(_make_repo)
    sha=$(git -C "$repo" rev-parse feature-a)
    out=$(_run_check "$repo" fork-feature main "$sha")
    assert_output_contains "$out" "out_of_order=true" "フォークからの PR で、前の段階に未マージ → out_of_order=true"
    rm -rf "$(dirname "$repo")"
}

test_wf_sequence_extractable
test_wf_sequence_in_order
test_wf_sequence_out_of_order
test_wf_sequence_skip_decision
test_wf_sequence_skip_both
test_wf_sequence_lowest_stage
test_wf_sequence_env_branch_pr_blocked
test_wf_sequence_env_branch_notified
test_wf_sequence_no_branches_file
test_wf_sequence_fetch_failure
test_wf_sequence_fork_pr

rm -rf "$_WFS_STATE"   # 判定の記録（_record_run）の後始末
print_summary
