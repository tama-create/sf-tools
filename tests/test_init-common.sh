#!/bin/bash
# ==============================================================================
# test_init-common.sh - phases/init/init-common.sh の ensure_sf_tools_branch テスト
# ==============================================================================
# 実際の Git（一時ディレクトリのローカル bare リポジトリ）を使う。外部ネットワークには接続しない。
#
# 【テストケース】
#   1. 最新・同じブランチ                → 通過
#   2. 遅れ + Y                          → pull して中断（異常終了）
#   3. 遅れ + N                          → 更新せず続行
#   4. ブランチ違い + N                  → 中断
#   5. ブランチ違い + Y                  → 続行
#   6. 未コミット変更あり + 遅れ         → 更新せず続行
#   7. git fetch 失敗                    → 警告して続行
#   8. 遅れ + q                          → 中断
#   9. Git リポジトリでない              → 警告して続行
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== init-common.sh (ensure_sf_tools_branch) ===${CLR_RST}"

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

# origin(bare) と、更新用の作業用 clone(w)、検証対象の clone(sf-tools: development) を作る
# 戻り値: ベースディレクトリ
_mk_repos() {
    local b
    b=$(mktemp -d "${TMPDIR:-/tmp}/test-esb-XXXX")
    git init -q --bare "$b/origin.git"
    git clone -q "$b/origin.git" "$b/w" 2>/dev/null
    (
        cd "$b/w" || exit 1
        git checkout -q -b main && echo 1 > f && git add f && git commit -qm c1 && git push -q origin main
        git checkout -q -b development && echo 2 > f && git commit -qam c2 && git push -q origin development
    ) > /dev/null 2>&1
    git clone -q "$b/origin.git" "$b/sf-tools" 2>/dev/null
    git -C "$b/sf-tools" checkout -q development
    echo "$b"
}

# origin の development に新しいコミットを 1 つ追加する（検証対象を遅れさせる）
_advance_origin() {
    (
        cd "$1/w" || exit 1
        git checkout -q development && echo "$RANDOM" >> f && git commit -qam "new" && git push -q origin development
    ) > /dev/null 2>&1
}

# ensure_sf_tools_branch を単体で実行する
# 引数: $1=ベースdir（SF_TOOLS_DIR は $1/sf-tools）, $2=目標ブランチ, $3=標準入力
_run_esb() {
    printf '%b' "$3" | (
        export SF_INIT_MODE=1
        export SF_TOOLS_DIR="${4:-$1/sf-tools}"
        readonly SCRIPT_NAME=test
        readonly LOG_FILE=/dev/null
        readonly LOG_MODE=NEW
        source "${SF_TOOLS_DIR_REPO}/lib/common.sh"
        source "${SF_TOOLS_DIR_REPO}/phases/init/init-common.sh"
        ensure_sf_tools_branch "$2"
    ) > "$1/out.log" 2>&1
}
SF_TOOLS_DIR_REPO="$SF_TOOLS_DIR"

test_esb_up_to_date() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 最新・同じブランチ → 通過${CLR_RST}"
    local b; b=$(_mk_repos)
    _run_esb "$b" development ""
    assert_exit_ok $? "最新 → 終了コード 0"
    assert_file_contains "$b/out.log" "最新です" "「最新です」と表示される"
    teardown "$b"
}

test_esb_behind_yes() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 遅れ + Y → pull して中断${CLR_RST}"
    local b before after
    b=$(_mk_repos); _advance_origin "$b"
    before=$(git -C "$b/sf-tools" rev-list --count HEAD)
    _run_esb "$b" development 'Y\n'
    assert_exit_fail $? "遅れ + Y → 中断（異常終了）"
    after=$(git -C "$b/sf-tools" rev-list --count HEAD)
    [[ "$after" -eq $((before + 1)) ]] && pass "pull で 1 コミット進んだ" || fail "pull で 1 コミット進んだ" "前=${before} 後=${after}"
    assert_file_contains "$b/out.log" "更新したため" "中断の理由が表示される"
    teardown "$b"
}

test_esb_behind_no() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 遅れ + N → 更新せず続行${CLR_RST}"
    local b before after
    b=$(_mk_repos); _advance_origin "$b"
    before=$(git -C "$b/sf-tools" rev-list --count HEAD)
    _run_esb "$b" development 'N\n'
    assert_exit_ok $? "遅れ + N → 終了コード 0"
    after=$(git -C "$b/sf-tools" rev-list --count HEAD)
    [[ "$after" -eq "$before" ]] && pass "更新されていない" || fail "更新されていない" "前=${before} 後=${after}"
    teardown "$b"
}

test_esb_branch_mismatch_no() {
    echo ""; echo -e "${CLR_HEAD}[TEST] ブランチ違い + N → 中断${CLR_RST}"
    local b; b=$(_mk_repos)
    _run_esb "$b" main 'N\n'
    assert_exit_fail $? "ブランチ違い + N → 中断"
    assert_file_contains "$b/out.log" "選択した環境は main です" "ブランチ違いの警告が表示される"
    teardown "$b"
}

test_esb_branch_mismatch_yes() {
    echo ""; echo -e "${CLR_HEAD}[TEST] ブランチ違い + Y → 続行${CLR_RST}"
    local b; b=$(_mk_repos)
    _run_esb "$b" main 'Y\n'
    assert_exit_ok $? "ブランチ違い + Y → 終了コード 0"
    teardown "$b"
}

test_esb_dirty_skips_update() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 未コミット変更あり + 遅れ → 更新せず続行${CLR_RST}"
    local b before after
    b=$(_mk_repos); _advance_origin "$b"
    echo dirty >> "$b/sf-tools/f"
    before=$(git -C "$b/sf-tools" rev-list --count HEAD)
    _run_esb "$b" development ""
    assert_exit_ok $? "未コミット変更あり → 終了コード 0（確認なしで続行）"
    after=$(git -C "$b/sf-tools" rev-list --count HEAD)
    [[ "$after" -eq "$before" ]] && pass "更新されていない" || fail "更新されていない" "前=${before} 後=${after}"
    assert_file_contains "$b/out.log" "更新しません" "更新しない旨が表示される"
    teardown "$b"
}

test_esb_fetch_failure() {
    echo ""; echo -e "${CLR_HEAD}[TEST] git fetch 失敗 → 警告して続行${CLR_RST}"
    local b; b=$(_mk_repos)
    git -C "$b/sf-tools" remote set-url origin "$b/nonexistent.git"
    _run_esb "$b" development ""
    assert_exit_ok $? "fetch 失敗 → 終了コード 0"
    assert_file_contains "$b/out.log" "接続できなかった" "確認をスキップした旨が表示される"
    teardown "$b"
}

test_esb_behind_quit() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 遅れ + q → 中断${CLR_RST}"
    local b; b=$(_mk_repos); _advance_origin "$b"
    _run_esb "$b" development 'q\n'
    assert_exit_fail $? "遅れ + q → 中断"
    teardown "$b"
}

test_esb_not_a_repo() {
    echo ""; echo -e "${CLR_HEAD}[TEST] Git リポジトリでない → 警告して続行${CLR_RST}"
    local b; b=$(mktemp -d "${TMPDIR:-/tmp}/test-esb-XXXX")
    mkdir -p "$b/plain"
    _run_esb "$b" development "" "$b/plain"
    assert_exit_ok $? "Git リポジトリでない → 終了コード 0"
    assert_file_contains "$b/out.log" "Git リポジトリではない" "スキップした旨が表示される"
    teardown "$b"
}

test_esb_up_to_date
test_esb_behind_yes
test_esb_behind_no
test_esb_branch_mismatch_no
test_esb_branch_mismatch_yes
test_esb_dirty_skips_update
test_esb_fetch_failure
test_esb_behind_quit
test_esb_not_a_repo

print_summary
