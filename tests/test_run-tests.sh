#!/bin/bash
# ==============================================================================
# test_run-tests.sh - tests/run_tests.sh の --shard（テストファイルを N 組に分けて、I 番目だけ実行する）と --changed のテスト
# ==============================================================================
# 実際のテストは動かさない（SF_TEST_LIST_ONLY=1: 対象のファイル名を表示して終わる）。
# GitHub Actions の Windows で、複数のジョブに分けて並列に動かすときの、分け方が正しいことを確かめる。
#
# 【テストケース】
#   1. N=1 は、分けない場合と、同じ
#   2. N 組を全部合わせると、全ファイルが、ちょうど 1 回ずつ（漏れも重複もない）
#   3. 分け方は、いつも同じ（どの環境でも、同じジョブに、同じファイルが入る）
#   4. 重い 3 つのファイルは、別の組に入る（1 つの組に、重いものが、集まらない）
#   5. 不正な指定は、終了コード 2
#   6. 組の数が、ファイルの数より多いとき、空の組は、何もせず、成功で終わる
#   7. SF_TEST_SKIP_INTEGRATION=1 と組み合わせても、結合テストは、外れたまま
#   8. --changed は、まだ git add していない新しいファイルに対応するテストも選ぶ。.gitignore の対象は数えない。
#      配布物のコード（bin/・phases/・lib/・hooks/）の変更では、セキュリティの静的な検査（test_security.sh）も選ぶ。
#      git のリポジトリとして読めないときは、全件に倒れず、終了コード 1
#   9. tests/wsl-gitfile.sh（WSL の写しの .git を、WSL から読めるパスに直す）: ふつうの .git フォルダは触らない・
#      Windows のドライブ（C:/…・D:\…・大文字）→ /mnt/<小文字>/…・相対のパス → 写し元を基準にした絶対のパス・
#      / で始まるパスはそのまま・本体の .git がなければ書かない・CR を除く・引数の誤り → 終了コード 2
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== run_tests.sh --shard・--changed ===${CLR_RST}"

RT="$SF_TOOLS_DIR/tests/run_tests.sh"
# 対象のファイル名を、1 行ずつ返す（実行はしない）。引数: run_tests.sh への引数
# 呼び出し元の環境（CI の Linux は SF_TEST_SKIP_INTEGRATION=1）に左右されないよう、既定では外す。外す指定を調べるときは LIST_SKIP=1
_list() { SF_TEST_SKIP_INTEGRATION="${LIST_SKIP:-}" SF_TEST_NO_WSL=1 SF_TEST_LIST_ONLY=1 bash "$RT" "$@" 2>/dev/null; }

test_shard_partition() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 分け方（N=1 は同じ・全部合わせて、ちょうど 1 回ずつ・いつも同じ）${CLR_RST}"
    local all one n i merged b; b=$(mktemp -d "${TMPDIR:-/tmp}/test-shard-XXXX")
    all=$(_list | sort)
    [[ -n "$all" ]] && pass "全件の一覧を取得できる（$(printf '%s\n' "$all" | wc -l | tr -d ' ') 件）" || fail "全件の一覧を取得できる"
    one=$(_list --shard 1/1 | sort)
    assert_equals "$one" "$all" "N=1（1/1）は、分けない場合と、同じ"
    for n in 6; do
        merged=""
        for i in $(seq 1 "$n"); do
            _list --shard "$i/$n" > "$b/s.$n.$i"
            merged="${merged}$(cat "$b/s.$n.$i")"$'\n'
        done
        assert_equals "$(printf '%s' "$merged" | sed '/^$/d' | sort)" "$all" "N=${n}: 全部合わせると、全ファイルが、ちょうど 1 回ずつ（漏れも重複もない）"
    done
    # いつも同じ分け方
    _list --shard 2/6 > "$b/again.txt"
    assert_equals "$(cat "$b/again.txt")" "$(cat "$b/s.6.2")" "同じ指定は、いつも、同じファイルになる（再現できる）"
    # 重い 3 つ（test_integration-init.sh / -init3.sh / -init2.sh）は、N=6 で、別々の組に入る
    local heavy_shards=""
    for f in test_integration-init.sh test_integration-init3.sh test_integration-init2.sh; do
        for i in 1 2 3 4 5 6; do
            grep -qx "$f" "$b/s.6.$i" && heavy_shards="${heavy_shards}${i} "
        done
    done
    assert_equals "$(printf '%s\n' $heavy_shards | sort -u | wc -l | tr -d ' ')" "3" "重い 3 つの結合テストは、別々の組に入る（1 つの組に、集まらない）"
    teardown "$b"
}

test_shard_invalid() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 不正な指定（終了コード 2）${CLR_RST}"
    local rc
    for spec in 0/3 4/3 a/3 3 1/0 x; do
        SF_TEST_NO_WSL=1 SF_TEST_LIST_ONLY=1 bash "$RT" --shard "$spec" > /dev/null 2>&1; rc=$?
        assert_equals "$rc" "2" "--shard ${spec} は、終了コード 2"
    done
}

test_shard_empty_and_skip() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 空の組・結合テストを外す指定との組み合わせ${CLR_RST}"
    local out rc
    out=$(_list --shard 100/100); rc=$?
    assert_exit_ok "$rc" "ファイルの数より多い組の、後ろの組（100/100）は、成功で終わる"
    assert_equals "$out" "" "空の組は、何も実行しない（一覧が空）"
    out=$(LIST_SKIP=1 _list --shard 1/1)
    if printf '%s\n' "$out" | grep -E '^test_integration' | grep -qv '^test_integration-coverage.sh$'; then
        fail "SF_TEST_SKIP_INTEGRATION=1 と --shard の組み合わせで、結合テスト L1 が、外れたまま"
    else
        pass "SF_TEST_SKIP_INTEGRATION=1 と --shard の組み合わせで、結合テスト L1 が、外れたまま"
    fi
}

# --changed は、まだ git add していない新しいファイルも、対象に入れる（.gitignore の対象は除く）
#   本物のリポジトリに、追跡していないファイルを作らないため、一時フォルダに、run_tests.sh だけを置いた小さなリポジトリを作って確かめる
test_changed_untracked() {
    echo ""; echo -e "${CLR_HEAD}[TEST] --changed: まだ git add していない新しいファイル${CLR_RST}"
    local repo out
    repo=$(mktemp -d "${TMPDIR:-/tmp}/test-rt-changed-XXXX")
    mkdir -p "$repo/tests" "$repo/lib"
    cp "$RT" "$repo/tests/run_tests.sh"
    printf 'logs/\n' > "$repo/.gitignore"   # run_tests.sh が書く logs/ を、追跡していないファイルに数えないため（本物と同じ）
    (
        cd "$repo" || exit 1
        git init -q && git config core.autocrlf false && git add -A \
            && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m init
    ) || { fail "--changed: 一時のリポジトリを作れた"; rm -rf "$repo"; return; }

    # 追跡していない新しいファイル（lib/apexlog.js）に対応するテストが、選ばれる
    echo "x" > "$repo/lib/apexlog.js"
    out=$(SF_TEST_SKIP_INTEGRATION="" SF_TEST_NO_WSL=1 SF_TEST_LIST_ONLY=1 bash "$repo/tests/run_tests.sh" --changed 2>/dev/null)
    assert_output_contains "$out" "対象テスト: test_apexlog-js.sh" "まだ git add していない新しいファイルに対応するテストを、選ぶ"
    assert_output_contains "$out" "test_security.sh" "配布物のコード（lib/）の変更 → セキュリティの静的な検査も選ぶ"

    # .gitignore の対象は、追跡していないファイルに数えない（対応するテストなし → 全件）
    printf 'logs/\nlib/apexlog.js\n' > "$repo/.gitignore"
    git -C "$repo" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -am ignore
    out=$(SF_TEST_SKIP_INTEGRATION="" SF_TEST_NO_WSL=1 SF_TEST_LIST_ONLY=1 bash "$repo/tests/run_tests.sh" --changed 2>/dev/null)
    assert_output_contains "$out" "変更ファイルに対応するテストなし" ".gitignore の対象のファイルは、追跡していないファイルに数えない"

    # git のリポジトリとして読めない（worktree の写しで、.git が読めないパスを指す）→ 全件に倒れず、止める
    rm -rf "$repo/.git" && printf 'gitdir: %s\n' "$repo/no-such-dir" > "$repo/.git"
    out=$(SF_TEST_SKIP_INTEGRATION="" SF_TEST_NO_WSL=1 SF_TEST_LIST_ONLY=1 bash "$repo/tests/run_tests.sh" --changed 2>&1); local rc=$?
    assert_exit_fail "$rc" "git のリポジトリとして読めない → 終了コード 1"
    assert_output_contains "$out" "git の差分を読めません" "git が使えないことを書く"
    assert_output_not_contains "$out" "全テスト実行" "黙って全件に倒れない"
    rm -rf "$repo"
}

# tests/wsl-gitfile.sh（WSL の写しの .git を直す。run_tests.sh が、写したあとに呼ぶ）
test_wsl_gitfile() {
    echo ""; echo -e "${CLR_HEAD}[TEST] wsl-gitfile.sh: 写しの .git を、WSL から読めるパスに直す${CLR_RST}"
    local b src dst mnt rc GF="$SF_TOOLS_DIR/tests/wsl-gitfile.sh"
    b=$(mktemp -d "${TMPDIR:-/tmp}/test-wslgit-XXXX")
    src="$b/src"; dst="$b/dst"; mnt="$b/mnt"
    mkdir -p "$src" "$dst" "$mnt/c/Users/u/repo/.git/worktrees/w" "$mnt/d/a/.git/worktrees/w" "$b/main/.git/worktrees/w"
    # 写し元と写し先に、同じ .git を置く（rsync で写した直後と同じ）。引数: .git の中身（printf の書式ではなく、文字どおり）
    _put() { printf '%s' "$1" > "$src/.git"; printf '%s' "$1" > "$dst/.git"; }
    _gf() { SF_WSL_MNT_ROOT="$mnt" bash "$GF" "$src" "$dst" 2>/dev/null; }

    # ふつうの .git フォルダは、触らない
    mkdir -p "$src/.git" "$dst/.git"
    _gf; rc=$?
    assert_exit_ok "$rc" ".git がフォルダ → 終了コード 0"
    [[ -d "$dst/.git" ]] && pass ".git がフォルダなら、写しの .git を触らない" || fail ".git がフォルダなら、写しの .git を触らない"
    rm -rf "$src/.git" "$dst/.git"

    # Windows のドライブ（C:/…）→ /mnt/c/…
    _put $'gitdir: C:/Users/u/repo/.git/worktrees/w\n'
    _gf
    assert_equals "$(cat "$dst/.git")" "gitdir: $mnt/c/Users/u/repo/.git/worktrees/w" "C:/… → /mnt/c/…"
    assert_equals "$(cat "$src/.git")" "gitdir: C:/Users/u/repo/.git/worktrees/w" "写し元の .git は、書き換えない"

    # \ の区切り・大文字のドライブ・CRLF → /mnt/d/…（小文字・/）
    _put 'gitdir: D:\a\.git\worktrees\w'$'\r\n'
    _gf
    assert_equals "$(cat "$dst/.git")" "gitdir: $mnt/d/a/.git/worktrees/w" "D:\…（CRLF）→ /mnt/d/…（小文字・/ の区切り・CR を除く）"

    # 相対のパス → 写し元を基準にした絶対のパス
    _put $'gitdir: ../main/.git/worktrees/w\n'
    _gf
    assert_equals "$(cat "$dst/.git")" "gitdir: $(cd "$b/main/.git/worktrees/w" && pwd)" "相対のパス → 写し元を基準にした絶対のパス"

    # / で始まるパス（WSL・Linux で作った worktree）は、そのまま
    _put "gitdir: $b/main/.git/worktrees/w"$'\n'
    _gf
    assert_equals "$(cat "$dst/.git")" "gitdir: $b/main/.git/worktrees/w" "/ で始まるパスは、そのまま"

    # 本体の .git がなければ、書かない（壊れた印を作らない）
    _put $'gitdir: C:/no/such/.git/worktrees/w\n'
    _gf; rc=$?
    assert_exit_ok "$rc" "本体の .git がない → 終了コード 0（テストは続ける）"
    assert_equals "$(cat "$dst/.git")" "gitdir: C:/no/such/.git/worktrees/w" "本体の .git がなければ、写しの .git を書き換えない"

    # 「gitdir: 」で始まらない .git は、推測で書き換えない
    _put $'something else\n'
    _gf
    assert_equals "$(cat "$dst/.git")" "something else" "知らない形の .git は、書き換えない"

    # 引数の誤り → 終了コード 2
    bash "$GF" "$src" 2>/dev/null; rc=$?
    assert_equals "$rc" "2" "写し先がない → 終了コード 2"
    bash "$GF" "$src" "$b/no-such" 2>/dev/null; rc=$?
    assert_equals "$rc" "2" "写し先のフォルダがない → 終了コード 2"
    rm -rf "$b"
}

test_shard_partition
test_shard_invalid
test_shard_empty_and_skip
test_changed_untracked
test_wsl_gitfile

print_summary
