#!/bin/bash
# ==============================================================================
# test_wf-one-way.sh - 一方通行のリリース（doc/one-way-promotion-design.md 7 章）の、ワークフローの雛形の静的テスト
# ==============================================================================
# templates/.github/workflows/ の wf-release.yml・wf-validate.yml・wf-sequence.yml を読み、次を確かめる（実行はしない）:
#   - wf-release: 手動の実行（workflow_dispatch）がない・権限 statuses: write がある・sf-promote-check.sh を --only なしで呼ぶ・
#     確認はリリースの前・リリースの印はリリースのあと（always() で動かない）・確認とリリースが同じコミット（PR の先端・マージのコミット）
#   - wf-validate: --only stack で呼び、0 のときだけ sf-release.sh（dry-run）を動かす・PR の先端のコミットで確かめる
#   - wf-sequence: --only sequence で呼ぶ
#   - wf-propagate.yml が雛形にない
# 判定の本体（sf-promote-check.sh）は tests/test_sf-promote-check.sh、wf-sequence の実行は tests/test_wf-sequence.sh が確かめる
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== ワークフローの雛形（一方通行のリリース）===${CLR_RST}"

WFD="$SF_TOOLS_DIR/templates/.github/workflows"
REL="$WFD/wf-release.yml"
VAL="$WFD/wf-validate.yml"
SEQ="$WFD/wf-sequence.yml"

# パターンに合う最初の行の番号（なければ 0）。引数: ファイル 固定の文字列
_line_of() { local n; n=$(grep -nF -- "$2" "$1" | head -1 | cut -d: -f1); echo "${n:-0}"; }
# 「- name: <名前>」のステップの本文（次の「- name:」の前まで）。引数: ファイル ステップ名
_step_body() {
    awk -v nm="- name: $2" '
        index($0, nm) { f = 1; print; next }
        f && /^      - (name|uses|id):/ { exit }
        f { print }
    ' "$1"
}

test_release() {
    echo ""; echo -e "${CLR_HEAD}[TEST] wf-release.yml${CLR_RST}"
    assert_file_not_contains "$REL" "workflow_dispatch:" "手動の実行（workflow_dispatch）の起動がない"
    assert_file_contains "$REL" "statuses: write" "リリースの印を付ける権限（statuses: write）がある"
    local promote release mark body
    promote=$(_line_of "$REL" 'bash ~/sf-tools/bin/sf-promote-check.sh --pr "$PR_NUMBER"')
    release=$(_line_of "$REL" '~/sf-tools/bin/sf-release.sh --release --no-open')
    mark=$(_line_of "$REL" '- name: リリースの印を付ける')
    [[ "$promote" -gt 0 ]] && pass "一方通行の確認（sf-promote-check.sh --pr）を呼ぶ" || fail "一方通行の確認（sf-promote-check.sh --pr）を呼ぶ"
    sed -n "${promote}p" "$REL" | grep -q -- "--only" && fail "確認は --only なし（R0〜R3 のすべて）" || pass "確認は --only なし（R0〜R3 のすべて）"
    [[ "$promote" -gt 0 && "$release" -gt "$promote" ]] && pass "確認は、組織へのリリースの前" || fail "確認は、組織へのリリースの前" "promote=${promote} release=${release}"
    [[ "$release" -gt 0 && "$mark" -gt "$release" ]] && pass "リリースの印は、リリースのあと" || fail "リリースの印は、リリースのあと" "release=${release} mark=${mark}"
    body=$(_step_body "$REL" "リリースの印を付ける")
    printf '%s\n' "$body" | grep -q "if:" && fail "印を付けるステップに if: がない（前のステップが成功したときだけ動く）" "$(printf '%s\n' "$body" | grep 'if:')" \
        || pass "印を付けるステップに if: がない（前のステップが成功したときだけ動く）"
    printf '%s\n' "$body" | grep -qF 'context=sf-tools/released-${BASE_REF}' && pass "印の context は sf-tools/released-<段階>" || fail "印の context は sf-tools/released-<段階>"
    printf '%s\n' "$body" | grep -qF 'statuses/${HEAD_SHA}' && pass "印は、PR の先端のコミット（head.sha）に付ける" || fail "印は、PR の先端のコミット（head.sha）に付ける"
    printf '%s\n' "$body" | grep -qF 'HEAD_SHA: ${{ github.event.pull_request.head.sha }}' && pass "HEAD_SHA は pull_request.head.sha" || fail "HEAD_SHA は pull_request.head.sha"
    body=$(_step_body "$REL" "一方通行の確認用に、PR の先端のコミットを取得")
    printf '%s\n' "$body" | grep -qF 'ref: ${{ github.event.pull_request.head.sha }}' && pass "確認は、PR の先端のコミットで行う" || fail "確認は、PR の先端のコミットで行う"
    body=$(_step_body "$REL" "ソースコードを取得")
    printf '%s\n' "$body" | grep -qF 'ref: ${{ github.event.pull_request.merge_commit_sha }}' && pass "リリースは、この PR のマージのコミットで行う（マージ先の最新ではない）" || fail "リリースは、この PR のマージのコミットで行う" "$body"
    assert_file_contains "$REL" "PROMOTE_OUTCOME" "Slack の通知が、一方通行の確認で止めたことを書き分ける"
}

test_validate() {
    echo ""; echo -e "${CLR_HEAD}[TEST] wf-validate.yml${CLR_RST}"
    assert_file_not_contains "$VAL" "workflow_dispatch:" "手動の実行がない"
    assert_file_contains "$VAL" 'sf-promote-check.sh" --pr "$PR_NUMBER" --only stack' "積み重ねの確認（--only stack）を呼ぶ"
    local promote release
    promote=$(_line_of "$VAL" '--only stack')
    release=$(_line_of "$VAL" 'sf-tools/bin/sf-release.sh" --no-open')
    [[ "$promote" -gt 0 && "$release" -gt "$promote" ]] && pass "確認は、dry-run の前" || fail "確認は、dry-run の前" "promote=${promote} release=${release}"
    sed -n "$((promote + 1)),$((release - 1))p" "$VAL" | grep -qF 'if [ "$EXIT_CODE" -eq 0 ]; then' && pass "確認が 0 のときだけ、dry-run をする" || fail "確認が 0 のときだけ、dry-run をする"
    assert_file_contains "$VAL" 'ref: ${{ github.event.pull_request.head.sha }}' "確認は、PR の先端のコミットで行う"
    assert_file_contains "$VAL" "statuses: read" "リリースの印を読む権限がある"
}

test_sequence() {
    echo ""; echo -e "${CLR_HEAD}[TEST] wf-sequence.yml・雛形の一覧${CLR_RST}"
    assert_file_contains "$SEQ" '--only sequence --json' "順序の確認（--only sequence）を呼ぶ"
    assert_file_not_contains "$SEQ" "workflow_dispatch:" "手動の実行がない"
    [[ ! -e "$WFD/wf-propagate.yml" ]] && pass "雛形に wf-propagate.yml がない（下りの伝播はしない）" || fail "雛形に wf-propagate.yml がない"
    grep -lF "sf-promote-check.sh" "$WFD"/*.yml | sed 's|.*/||' | sort | tr '\n' ' ' | grep -qx "wf-release.yml wf-sequence.yml wf-validate.yml " \
        && pass "sf-promote-check.sh を呼ぶのは、release・sequence・validate の 3 つ" || fail "sf-promote-check.sh を呼ぶのは、release・sequence・validate の 3 つ" "$(grep -lF sf-promote-check.sh "$WFD"/*.yml)"
}

test_release
test_validate
test_sequence

print_summary
