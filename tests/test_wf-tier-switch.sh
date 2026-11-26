#!/bin/bash
# ==============================================================================
# test_wf-tier-switch.sh - 段階の切り替え（branches.txt）の、workflow の判定のテスト
# ==============================================================================
# 対象: templates/.github/workflows/ の wf-release.yml・wf-validate.yml（doc/tier-scaling-design.md 3 章・9 章。wf-propagate.yml は 2026-11-26 に廃止）
# YAML から、step の run のスクリプトを取り出して、実際の git リポジトリ（ローカルのリモートつき）で、GitHub Actions と同じ
# シェル（bash --noprofile --norc -eo pipefail）で実行する（tests/test_wf-sequence.sh と同じ方式）。
# 確認すること:
#   - 2 つの workflow の判定の部分（>>> sf-tools: tier-switch v1 〜 <<<）が同じ中身で、判定の呼び出しの印 sf-tools: tier-check がある
#     （wf-sequence.yml・wf-metasync.yml には、ない）
#   - wf-release: PR のマージで、無効の段階なら skip=true。main は常に今までどおり。workflow_dispatch がない・wf-propagate.yml がない
#   - wf-validate: マージ先ごとに、検証に使う段階の有効・無効で skip が決まる
#   - branches.txt がない → 今までの動き（::warning）／ main を取得できない → 失敗（::error）／名前でない行 → ::warning
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== 段階の切り替え（wf-release・wf-validate）===${CLR_RST}"

WF_DIR="$SF_TOOLS_DIR/templates/.github/workflows"
_GH_BASH=(bash --noprofile --norc -eo pipefail -c)

# YAML から、step「id: <ID>」（または「- id: <ID>」）の run のスクリプトを取り出す（インデント 10 を除く）
#   引数: 1=ファイル名（wf-*.yml）  2=step の id
_extract() {
    awk -v id="$2" '
        $0 ~ ("id: " id "$") { f = 1 }
        f && /^        run: \|/ { r = 1; next }
        r && /^$/ { print ""; next }
        r && /^          / { sub(/^          /, ""); print; next }
        r { exit }
    ' "$WF_DIR/$1"
}

# 判定の部分（印の間）を取り出す
_block() { awk '/# >>> sf-tools: tier-switch v1/{f=1} f{print} /# <<< sf-tools: tier-switch v1/{exit}' "$WF_DIR/$1"; }

# テスト用のリポジトリを作る（ローカルのリモートつき）
#   引数: 1=main の branches.txt の中身（printf の書式。NONE ならファイルを置かない）
#   main / staging / develop / feature-a を作る。feature-a には、デプロイ対象のある sf-tools/release/feature-a/deploy-target.txt
#   出力: 作業ディレクトリのパス
_make_repo() {
    local base clone
    base=$(mktemp -d "${TMPDIR:-/tmp}/wftier-XXXX")
    git init -q --bare "$base/origin.git"
    git clone -q "$base/origin.git" "$base/work" 2>/dev/null
    clone="$base/work"
    git -C "$clone" config core.autocrlf false
    (
        cd "$clone" || exit 1
        export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
        git checkout -q -b main
        mkdir -p sf-tools/config
        if [[ "$1" != "NONE" ]]; then printf "$1" > sf-tools/config/branches.txt; else echo x > dummy.txt; fi
        git add -A && git commit -q -m init
        git push -q origin main
        git branch staging && git branch develop
        git push -q origin staging develop
        git checkout -q -b feature-a
        mkdir -p sf-tools/release/feature-a
        printf '[files]\nforce-app/main/default/classes/A.cls\n' > sf-tools/release/feature-a/deploy-target.txt
        git add -A && git commit -q -m a
        git push -q origin feature-a
        git checkout -q main
        echo "next" > next.txt && git add next.txt && git commit -q -m next && git push -q origin main
        # PR の検証・リリースの判定は、PR の中身（デプロイ対象）を見るため、feature-a を取り出した状態で終える
        #   （Actions では、PR のマージ結果を取り出す。伝播の手順は、自分でブランチを切り替える）
        git checkout -q feature-a
    )
    echo "$clone"
}

# run のスクリプトを実行する。出力: 「RC=<終了コード>」の行・GITHUB_OUTPUT の中身・標準出力と標準エラー
#   引数: 1=作業ディレクトリ  2=スクリプト  残り=環境変数（K=V）
_run() {
    local dir="$1" script="$2" out rc
    shift 2
    out=$(mktemp "${TMPDIR:-/tmp}/wftier-out-XXXX")
    local log
    log=$( cd "$dir" && env GITHUB_OUTPUT="$out" GITHUB_REF_NAME="${GITHUB_REF_NAME:-main}" "$@" "${_GH_BASH[@]}" "$script" 2>&1 ); rc=$?
    printf 'RC=%s\n%s\n%s\n' "$rc" "$(cat "$out")" "$log"
    rm -f "$out"
}

# ------------------------------------------------------------------------------
# 構造: 判定の部分が同じ・印がある
# ------------------------------------------------------------------------------
test_structure() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 判定の部分が 2 つで同じ・印がある・伝播のワークフローがない${CLR_RST}"
    local r v
    r=$(_block wf-release.yml   | sed 's/^[[:space:]]*//')
    v=$(_block wf-validate.yml  | sed 's/^[[:space:]]*//')
    [[ -n "$r" ]] && pass "wf-release.yml に判定の部分がある" || fail "wf-release.yml に判定の部分がある"
    assert_equals "$v" "$r" "wf-validate.yml の判定の部分が、wf-release.yml と同じ"
    local f
    for f in wf-release.yml wf-validate.yml; do
        assert_file_contains "$WF_DIR/$f" "# sf-tools: tier-check" "${f} に判定の呼び出しの印がある"
    done
    for f in wf-sequence.yml wf-metasync.yml; do
        assert_file_not_contains "$WF_DIR/$f" "sf-tools: tier-check" "${f} には印がない（本書の変更の対象外）"
        assert_file_not_contains "$WF_DIR/$f" "sf-tools: tier-switch" "${f} には判定の部分がない"
    done
    # 下りの伝播はない（一方通行の原則。doc/one-way-promotion-design.md 3.7）
    assert_file_not_exists "$WF_DIR/wf-propagate.yml" "wf-propagate.yml がない（main → staging・develop の伝播をしない）"
    # 手動の実行はない（doc/one-way-promotion-design.md 3.5）
    if grep -q '^  workflow_dispatch:' "$WF_DIR/wf-release.yml"; then fail "wf-release.yml に workflow_dispatch がない"; else pass "wf-release.yml に workflow_dispatch がない"; fi
    assert_file_contains "$WF_DIR/wf-release.yml" "if: github.event.pull_request.merged == true && needs.check-branch.outputs.skip != 'true'" "wf-release: リリース実行は、PR のマージで、skip を見る"
}

# ------------------------------------------------------------------------------
# wf-release（リリース対象確認）
# ------------------------------------------------------------------------------
_rel() {  # 1=branches.txt  2=EVENT_NAME  3=TARGET_REF  [4=remove-origin]
    local repo s r
    repo=$(_make_repo "$1")
    [[ "${4:-}" == "noorigin" ]] && git -C "$repo" remote set-url origin "$repo/../nowhere.git"
    s=$(_extract wf-release.yml check)
    r=$(_run "$repo" "$s" EVENT_NAME="$2" HEAD_REF=feature-a TARGET_REF="$3" GITHUB_REF_NAME="$3")
    rm -rf "${repo%/work}"
    printf '%s' "$r"
}
test_release() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] wf-release: リリース対象確認${CLR_RST}"
    local r
    r=$(_rel 'main\nstaging\ndevelop\n' pull_request develop)
    assert_output_contains "$r" "skip=false" "3 段階・develop への PR のマージ → リリースする"
    r=$(_rel 'main\nstaging\n' pull_request develop)
    assert_output_contains "$r" "skip=true" "main/staging・develop への PR のマージ → リリースしない"
    assert_output_contains "$r" "段階として無効" "  → ::notice で理由を出す"
    r=$(_rel 'main\nstaging\n' pull_request develop)
    assert_output_contains "$r" "skip=true" "main/staging・develop への PR のマージ → リリースしない"
    r=$(_rel 'main\n' pull_request staging)
    assert_output_contains "$r" "skip=true" "main だけ・staging への PR のマージ → リリースしない"
    r=$(_rel 'main\n' pull_request staging)
    assert_output_contains "$r" "skip=true" "main だけ・staging への PR のマージ → リリースしない"
    r=$(_rel 'main\ndevelop\n' pull_request develop)
    assert_output_contains "$r" "skip=true" "staging のない develop → 無効（リリースしない）"
    r=$(_rel 'main\n' pull_request main)
    assert_output_contains "$r" "skip=false" "main への PR のマージ → どの構成でもリリースする"
    r=$(_rel 'main\n' pull_request main)
    assert_output_contains "$r" "skip=false" "main への PR のマージ（2 回目）→ どの構成でもリリースする"
    r=$(_rel 'main\n' pull_request main noorigin)
    assert_output_contains "$r" "RC=0" "main は判定しない（main を取得できなくても、止めない）"
    r=$(_rel 'main\nstaging\ndevelop\n' pull_request develop noorigin)
    assert_output_contains "$r" "RC=1" "main を取得できない・develop → ジョブを失敗にする"
    assert_output_not_contains "$r" "skip=" "  → skip を出さない（リリース実行は needs のため動かない）"
    r=$(_rel NONE pull_request develop)
    assert_output_contains "$r" "skip=false" "branches.txt がない → 今までの動き（判定しない）"
    assert_output_contains "$r" "::warning" "  → ::warning を出す"
    r=$(_rel 'main\nuat\nstaging\n' pull_request staging)
    assert_output_contains "$r" "skip=false" "名前でない行があっても、staging は有効"
    assert_output_contains "$r" "「uat」" "  → 名前でない行に ::warning"
    r=$(_rel '  main \r\n\tstaging\t\r\n develop\r\n' pull_request develop)
    assert_output_contains "$r" "skip=false" "CR・前後の空白があっても、判定できる"
}

# ------------------------------------------------------------------------------
# wf-validate（対象ファイル確認）
# ------------------------------------------------------------------------------
_val() {  # 1=branches.txt  2=BASE_REF  [3=noorigin]
    local repo s r
    repo=$(_make_repo "$1")
    [[ "${3:-}" == "noorigin" ]] && git -C "$repo" remote set-url origin "$repo/../nowhere.git"
    s=$(_extract wf-validate.yml check)
    r=$(_run "$repo" "$s" HEAD_REF=feature-a BASE_REF="$2")
    rm -rf "${repo%/work}"
    printf '%s' "$r"
}
test_validate() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] wf-validate: 対象ファイル確認${CLR_RST}"
    local r
    r=$(_val 'main\n' main noorigin)
    assert_output_contains "$r" "skip=false" "main への PR → 判定しない（main を取得できなくても、検証する）"
    r=$(_val 'main\nstaging\n' staging)
    assert_output_contains "$r" "skip=false" "staging が有効・staging への PR → 検証する"
    r=$(_val 'main\n' staging)
    assert_output_contains "$r" "skip=true" "staging が無効・staging への PR → 検証しない"
    r=$(_val 'main\nstaging\n' develop)
    assert_output_contains "$r" "skip=true" "develop が無効・develop への PR → 検証しない"
    r=$(_val 'main\nstaging\n' feature-x)
    assert_output_contains "$r" "skip=true" "develop が無効・feature への PR → 検証しない（develop の組織を使わない）"
    r=$(_val 'main\nstaging\ndevelop\n' feature-x)
    assert_output_contains "$r" "skip=false" "3 段階・feature への PR → 今までどおり検証する"
    r=$(_val 'main\nstaging\ndevelop\n' staging noorigin)
    assert_output_contains "$r" "RC=1" "main を取得できない・staging への PR → ジョブを失敗にする"
    r=$(_val NONE develop)
    assert_output_contains "$r" "skip=false" "branches.txt がない → 今までの動き"
}

test_structure
test_release
test_validate

print_summary
