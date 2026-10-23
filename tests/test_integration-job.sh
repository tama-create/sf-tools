#!/bin/bash
# ==============================================================================
# test_integration-job.sh - 結合テスト L1: sf-job の失敗・入力の不正・途中の失敗
# ==============================================================================
# 実際の git と fake の gh で、sf-job（ブランチの作成 → clone → sf-start）が、失敗したときに、
# 途中までの副作用を残さないこと、入力の不正を拒否すること、失敗後に再実行できることを確かめる。
# ハーネスと fake は tests/integration/lib.sh。計画: doc/integration-test-plan.md
#
# 【シナリオ】
#   X1-2 / X1-3  gh の認証・権限・リポジトリ・ブランチの失敗 → 何も作らない（ブランチ・フォルダ・clone）
#   X1-1         GitHub の API の一時的な失敗（ブランチ作成の失敗）→ 何も作らず、再実行で成功する
#   X2-2         ブランチ作成後に clone が失敗（ネットワークの断）→ 再実行したときの状態
#   X5-1 / X5-2  ジョブ名の不正・パスの空白（作業フォルダ名）
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
source "$(dirname "${BASH_SOURCE[0]}")/integration/lib.sh"
echo -e "${CLR_HEAD}=== 結合テスト L1: sf-job の失敗・入力の不正 ===${CLR_RST}"

trap 'it_teardown' EXIT

# sf-job を動かす。引数: 作業フォルダ 入力 [追加の引数...]（既定の引数は --owner/--project）。結果: IT_RC・IT_OUT
_job() {
    local dir="$1" inp="$2"; shift 2
    local -a args=("$@")
    [[ ${#args[@]} -eq 0 ]] && args=(--owner "$IT_OWNER" --project "$IT_PROJECT")
    [[ "${args[0]:-}" == "NOARGS" ]] && args=()   # 引数なし（NOARGS を渡す）
    it_run "$dir" -i "$inp" bash "$IT_HOME/sf-tools/bin/sf-job.sh" "${args[@]}"
}
_branches() { it_remote_snap | awk '{print $1}' | sed 's|refs/heads/||' | sort | tr '\n' ','; }
# 何も作られていないこと。引数: 作業フォルダ ジョブ名 リモートの一覧（実行前）
_nothing_created() {
    local dir="$1" job="$2" before="$3" what="$4"
    assert_equals "$(_branches)" "$before" "${what}: origin にブランチが増えない"
    [[ -d "$dir/$job" ]] && fail "${what}: ジョブフォルダが作られない" "$dir/$job がある" || pass "${what}: ジョブフォルダが作られない"
}

test_setup() {
    it_setup || { fail "サンドボックスの作成"; return 1; }
    it_seed_repo 1 || { fail "リポジトリの生成"; return 1; }
    mkdir -p "$IT_WORK/proj"
    pass "準備: サンドボックスとリポジトリを作った"
}

test_gh_failures() {
    echo -e "\n${CLR_HEAD}--- X1-1〜X1-3: gh・GitHub の失敗 ---${CLR_RST}"
    local p="$IT_WORK/proj" b0; b0=$(_branches)
    IT_TIMEOUT=240

    # gh に未ログイン
    it_fault_clear
    it_fault gh "auth status" 1 99 1 "You are not logged into any GitHub hosts. To log in, run: gh auth login"
    it_fault gh "auth login*" 1 99 1 "error: authentication was cancelled"
    _job "$p" 'JOB-1\nY\nitorg\n1\n'
    assert_exit_fail "$IT_RC" "X1-2: gh に未ログインなら、sf-job は失敗で終わる"
    _nothing_created "$p" JOB-1 "$b0" "X1-2（未ログイン）"
    assert_equals "$(it_mutating_calls | wc -l | tr -d ' ')" "0" "X1-2（未ログイン）: 外部へ書き込まない"

    # リポジトリが見つからない（名前の違い・権限なしで見えない）
    it_fault_clear; it_calls_clear
    _job "$p" 'JOB-1\nY\nitorg\n1\n' --owner "$IT_OWNER" --project nosuchproject
    assert_exit_fail "$IT_RC" "X1-3: 存在しない（または見えない）リポジトリなら、失敗で終わる"
    _nothing_created "$p" JOB-1 "$b0" "X1-3（リポジトリなし）"

    # ジョブ名が、すでに origin にある（同名のブランチ）
    it_origin_commit main "docs/x.md" "x" "別のコミット" || { fail "X1-3: 準備"; return; }
    _it_git --git-dir="$IT_ORIGIN" branch JOB-EXIST main
    b0=$(_branches)
    it_calls_clear
    _job "$p" 'JOB-EXIST\nq\n'
    assert_exit_fail "$IT_RC" "X1-3: origin に、同名のブランチがあるときは、作らず、失敗（または中断）で終わる"
    assert_equals "$(_branches)" "$b0" "X1-3（同名のブランチ）: origin のブランチは、変わらない"
    assert_equals "$(it_calls gh | grep -c 'git/refs')" "0" "X1-3（同名のブランチ）: ブランチ作成の API を呼ばない"
    [[ -d "$p/JOB-EXIST" ]] && fail "X1-3（同名のブランチ）: ジョブフォルダが作られない" || pass "X1-3（同名のブランチ）: ジョブフォルダが作られない"

    # ブランチ作成の API が、一時的に失敗（403・レート制限など）→ 何も作らず、再実行で成功
    it_fault_clear; it_fault gh "api repos/*/git/refs*" 1 1 1 "gh: Resource not accessible by personal access token (HTTP 403)"
    b0=$(_branches)
    _job "$p" 'JOB-RETRY\nY\nitorg\n1\n'
    assert_exit_fail "$IT_RC" "X1-1: ブランチの作成が失敗すると、sf-job は失敗で終わる"
    _nothing_created "$p" JOB-RETRY "$b0" "X1-1（ブランチ作成の失敗）"
    # 再実行（失敗は 1 回だけ）→ 成功する
    _job "$p" 'JOB-RETRY\nY\nitorg\n1\n'
    [[ $IT_RC -eq 0 ]] || it_out | tail -12
    assert_exit_ok "$IT_RC" "X1-1: 一時的な失敗の後の再実行は、成功する"
    assert_dir_exists "$p/JOB-RETRY/$IT_REPO/.git" "X1-1: 再実行で、clone までできる"
    it_remote_snap | grep -q 'refs/heads/JOB-RETRY ' && pass "X1-1: 再実行で、origin にブランチができる" || fail "X1-1: 再実行で、origin にブランチができる"
    it_fault_clear
    IT_TIMEOUT=300
}

test_clone_failure() {
    echo -e "\n${CLR_HEAD}--- X2-2: ブランチ作成後に clone が失敗 → 再実行 ---${CLR_RST}"
    local p="$IT_WORK/proj" n_before n_after
    IT_TIMEOUT=240
    it_ssh_fail on
    _job "$p" 'JOB-NET\nY\nitorg\n1\n'
    assert_exit_fail "$IT_RC" "X2-2: clone が失敗すると、sf-job は失敗で終わる"
    it_remote_snap | grep -q 'refs/heads/JOB-NET ' && pass "X2-2: ブランチは、すでに origin にできている（作成後の失敗）" || fail "X2-2: ブランチは、すでに origin にできている"
    [[ -d "$p/JOB-NET/$IT_REPO/.git" ]] && fail "X2-2: 壊れた clone が、残らない" || pass "X2-2: 壊れた clone が、残らない"
    it_ssh_fail off

    # 再実行（同じジョブ名）: 同名のブランチが、すでにある → 「続ける」で、ブランチを作らず、clone だけをやり直せる
    n_before=$(it_remote_snap | wc -l | tr -d ' ')
    it_calls_clear
    _job "$p" 'JOB-NET\nN\nq\n'
    assert_exit_fail "$IT_RC" "X2-2: 同名のブランチがあり、続けない（N）→ 別のジョブ名を求められ、q で中断する"
    assert_equals "$(it_remote_snap | wc -l | tr -d ' ')" "$n_before" "X2-2: N のとき、origin のブランチは、重複しない"
    it_calls_clear
    _job "$p" 'JOB-NET\nY\nY\nitorg\n1\n'
    assert_exit_ok "$IT_RC" "X2-2: 同名のブランチがあり、続ける（Y）→ clone をやり直して、成功する"
    assert_dir_exists "$p/JOB-NET/$IT_REPO/.git" "X2-2: やり直しで、clone ができる"
    assert_equals "$(it_calls gh | grep -c 'git/refs')" "0" "X2-2: 続けるとき、ブランチの作成の API を呼ばない（重複して作らない）"
    assert_equals "$(it_remote_snap | wc -l | tr -d ' ')" "$n_before" "X2-2: 続けても、origin のブランチは、増えない"
    assert_equals "$(_it_git -C "$p/JOB-NET/$IT_REPO" rev-parse --abbrev-ref HEAD)" "JOB-NET" "X2-2: clone は、既存のジョブブランチをチェックアウトしている"
    # 別のジョブ名なら、通常どおり、進める
    _job "$p" 'JOB-NET2\nY\nitorg\n1\n'
    assert_exit_ok "$IT_RC" "X2-2: 別のジョブ名なら、通常どおり成功する"
    IT_TIMEOUT=300
}

test_invalid_input() {
    echo -e "\n${CLR_HEAD}--- X5-1・X5-2: ジョブ名の不正・パスの空白 ---${CLR_RST}"
    local p="$IT_WORK/proj" b0 name label
    IT_TIMEOUT=180
    b0=$(_branches)
    while IFS='|' read -r label name; do
        [[ -n "$label" ]] || continue
        it_calls_clear
        _job "$p" "${name}\nq\n"
        assert_exit_fail "$IT_RC" "X5-1: ジョブ名（${label}）は、拒否される"
        assert_equals "$(_branches)" "$b0" "X5-1: ジョブ名（${label}）→ origin にブランチが増えない"
        assert_equals "$(it_calls gh | grep -c 'git/refs')" "0" "X5-1: ジョブ名（${label}）→ ブランチ作成の API を呼ばない"
    done << 'ROWS'
空白を含む|bad name
スラッシュ|a/b
親ディレクトリ|../x
先頭がハイフン|-rf
セミコロン|JOB;ls
日本語|ジョブ
環境ブランチ（main）|main
環境ブランチ（develop）|develop
管理者用（admin）|admin
長すぎる（51 文字）|AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
ROWS
    IT_TIMEOUT=300

    # 作業フォルダの名前に、空白・日本語があっても、動く（X5-2）
    local sp="$IT_WORK/作業 フォルダ"
    mkdir -p "$sp"
    _job "$sp" 'JOB-SPACE\nY\nitorg\n1\n'
    assert_exit_ok "$IT_RC" "X5-2: 作業フォルダの名前に、空白・日本語があっても、sf-job が成功する"
    assert_dir_exists "$sp/JOB-SPACE/$IT_REPO/.git" "X5-2: 空白を含むパスに、clone できる"
}

# ------------------------------------------------------------------------------
# A14: プロジェクトの判定（複数のクローン・同名で別のオーナー）
# ------------------------------------------------------------------------------
test_A14() {
    echo -e "\n${CLR_HEAD}--- A14: クローンの git remote からの、プロジェクトの判定 ---${CLR_RST}"
    local p="$IT_WORK/a14" b0; b0=$(_branches)
    IT_TIMEOUT=180
    mkdir -p "$p"
    _mk() { mkdir -p "$p/$1"; _it_git init -q "$p/$1/$2"; _it_git -C "$p/$1/$2" remote add origin "ssh://git@github.com/$3/$2.git"; }
    _mk JOB-1 force-itproj ownerA; _mk JOB-2 force-itproj ownerB; _mk JOB-3 force-other ownerA

    # 引数なし: 複数のプロジェクトがあるとき、選ばせる
    _job "$p" '1\n' NOARGS
    it_out_has "どのプロジェクトですか" && pass "A14: クローンが複数あるとき、プロジェクトを選ばせる" || fail "A14: クローンが複数あるとき、プロジェクトを選ばせる" "$(it_out | tail -6)"

    # --project だけ、同じ XXXX が、別のオーナーに 2 つ → 黙って最初のものを使わず、選ばせる
    it_calls_clear
    _job "$p" '2\n' --project itproj
    it_out_has "どのオーナーの force-itproj ですか" && pass "A14: 同じ名前で、別のオーナーのクローンがあるとき、オーナーを選ばせる" || fail "A14: 同じ名前で、別のオーナーのクローンがあるとき、オーナーを選ばせる" "$(it_out | tail -6)"
    # 選んだオーナーは、リポジトリの確認の呼び出し（gh repo view <オーナー>/force-itproj）で分かる
    #   （以前は、オーナー権限の確認の失敗メッセージで調べていた。sf-job は、その確認をしなくなった）
    it_calls gh | grep -q "repo view ownerB/force-itproj" && pass "A14: 選んだオーナー（ownerB）で、先へ進む（ownerA を、黙って使わない）" || fail "A14: 選んだオーナー（ownerB）で、先へ進む" "$(it_calls gh | head -5)"
    it_calls_clear
    _job "$p" '1\n' --project itproj
    it_calls gh | grep -q "repo view ownerA/force-itproj" && pass "A14: 選んだオーナー（ownerA）で、先へ進む" || fail "A14: 選んだオーナー（ownerA）で、先へ進む" "$(it_calls gh | head -5)"

    # --owner を指定すれば、選ばせず、そのオーナーのクローンから決まる
    it_calls_clear
    _job "$p" '' --owner ownerB --project itproj
    it_out_has "どのオーナーの" && fail "A14: --owner 指定のときは、選ばせない" || pass "A14: --owner 指定のときは、選ばせない"
    it_calls gh | grep -q "repo view ownerB/force-itproj" && pass "A14: --owner ownerB → ownerB で進む" || fail "A14: --owner ownerB → ownerB で進む" "$(it_calls gh | head -5)"
    assert_equals "$(_branches)" "$b0" "A14: どの場合も、origin にブランチを作らない"
    IT_TIMEOUT=300
}

_it_timed() { local t0=$SECONDS rc; "$@"; rc=$?; echo "  （所要時間: $1 = $((SECONDS - t0)) 秒）"; return $rc; }

test_setup || { print_summary; exit 1; }
for _sc in ${IT_SCENARIOS:-gh_failures clone_failure invalid_input A14}; do
    _it_timed "test_${_sc}" || break
done

print_summary
