#!/bin/bash
# ==============================================================================
# test_sf-promote-check.sh - sf-promote-check.sh（一方通行のリリースの確認）のテスト
# ==============================================================================
# 本物の git（手元の bare リポジトリを origin にする）と、偽の gh・偽の sf で確かめる。
#   偽の gh: 応答は MOCK_GHP_DIR のファイル（下の _ghp_* で書く）。
#     pr_<番号>.txt               … gh pr view の応答（先端\tブランチ\t段階\tフォークか\tURL）
#     st_<SHA>_<段階>.txt         … gh api --paginate …/statuses の応答（その context の状態の「作成日時\t状態\t付けた者\tURL」の行。なければ空）
#     run_<ID>.txt                … gh api …/actions/runs/<ID> の応答（リポジトリ\tパス\tイベント\t結果\tSHA）
#     prl_<ブランチ>_<段階>_<状態>.txt … gh pr list の応答（番号\t先端\tフォークか の行。状態 open は番号だけ）
#   origin の URL は、git の包み（偽の git）で https://github.com/o/r.git を返す（ほかは本物の git に渡す）
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-promote-check.sh ===${CLR_RST}"

PC="$SF_TOOLS_DIR/bin/sf-promote-check.sh"
REAL_GIT="$(command -v git)"

# 偽の gh
_make_fake_gh() {
    cat > "$1/gh" <<'EOF'
#!/bin/bash
echo "gh $*" >> "${MOCK_CALL_LOG:-/dev/null}"
d="${MOCK_GHP_DIR:?}"
_out() { [[ -f "$1" ]] || exit 1; cat "$1"; exit 0; }
case "$1 $2" in
    "pr view") _out "$d/pr_$3.txt" ;;
    "pr list")
        h=""; b=""; s=""; prev=""
        for a in "$@"; do
            [[ "$prev" == "--head" ]] && h="$a"; [[ "$prev" == "--base" ]] && b="$a"; [[ "$prev" == "--state" ]] && s="$a"
            prev="$a"
        done
        f="$d/prl_${h//\//_}_${b}_${s}.txt"; [[ -f "$f" ]] && cat "$f"; exit 0 ;;
    "api "*)
        p="$2"; [[ "$p" == "--paginate" ]] && p="$3"   # 道（repos/…）は、--paginate のあと
        case "$p" in
            repos/*/commits/*/statuses*)
                sha="${p#*/commits/}"; sha="${sha%%/*}"
                tier=""; [[ "$*" =~ sf-tools/released-([a-z]+) ]] && tier="${BASH_REMATCH[1]}"
                f="$d/st_${sha}_${tier}.txt"; [[ -f "$f" ]] && cat "$f"; exit 0 ;;
            repos/*/actions/runs/*) _out "$d/run_${p##*/}.txt" ;;
        esac ;;
esac
exit 1
EOF
    chmod +x "$1/gh"
}
# 偽の git（origin の URL だけ、GitHub の URL を返す）
_make_git_wrapper() {
    cat > "$1/git" <<EOF
#!/bin/bash
if [[ "\$1 \$2 \$3" == "remote get-url origin" ]]; then echo "https://github.com/o/r.git"; exit 0; fi
exec "$REAL_GIT" "\$@"
EOF
    chmod +x "$1/git"
}

# リポジトリを作る。引数: 作業フォルダ branches.txt の中身（NONE なら置かない）
#   main（branches.txt）→ ブランチ feat（sf-tools/release/feat/ に、クラス A・B の deploy-target.txt）を作り、bare の origin に push する
_setup_repo() {
    local td="$1" branches="$2" g="$REAL_GIT"
    "$g" init -q --bare "$td/origin.git"
    "$g" init -q -b main "$td/force-t"
    ( cd "$td/force-t" || exit 1
      "$g" config user.email t@example.com; "$g" config user.name t
      "$g" remote add origin "$td/origin.git"
      printf '{"packageDirectories":[{"path":"force-app","default":true}]}\n' > sfdx-project.json
      mkdir -p sf-tools/config
      [[ "$branches" == "NONE" ]] || printf "$branches" > sf-tools/config/branches.txt
      "$g" add -A; "$g" commit -q -m init; "$g" push -q origin main
      "$g" checkout -q -b feat
      mkdir -p sf-tools/release/feat force-app/main/default/classes
      touch force-app/main/default/classes/A.cls force-app/main/default/classes/B.cls
      printf '[files]\nforce-app/main/default/classes/A.cls\nforce-app/main/default/classes/B.cls\n' > sf-tools/release/feat/deploy-target.txt
      printf '[files]\n' > sf-tools/release/feat/remove-target.txt
      "$g" add -A; "$g" commit -q -m feat1; "$g" push -q origin feat )
}
_head() { "$REAL_GIT" -C "$1/force-t" rev-parse HEAD; }
# 応答を書く
_ghp_pr()   { printf '%s\t%s\t%s\t%s\t%s' "$2" "$3" "$4" "${5:-false}" "${6:-https://github.com/o/r/pull/$1}" > "$MOCK_GHP_DIR/pr_$1.txt"; }
_ghp_mark() { # SHA 段階 [状態] [付けた者] [実行ID] [実行のSHA] [実行のパス] [実行のリポジトリ]
    local id="${5:-9$RANDOM}"
    printf '%s\t%s\t%s\t%s\n' "2026-11-01T00:00:00Z" "${3:-success}" "${4:-github-actions[bot]}" "https://github.com/o/r/actions/runs/${id}" > "$MOCK_GHP_DIR/st_$1_$2.txt"
    printf '%s\t%s\t%s\t%s\t%s' "${8:-o/r}" "${7:-.github/workflows/wf-release.yml}" "pull_request" "success" "${6:-$1}" > "$MOCK_GHP_DIR/run_${id}.txt"
}
_run_pc() { # 作業フォルダ 引数... → 出力（標準出力・エラー）。終了コードは PC_RC
    local td="$1"; shift
    PC_OUT=$(cd "$td/force-t" && PATH="$td/bin:$PATH" bash "$PC" "$@" 2>&1); PC_RC=$?
}
_new_env() { # 変数名 [branches.txt の中身]
    local _ne
    _ne=$(mktemp -d "${TMPDIR:-/tmp}/test-pc-XXXX")
    mkdir -p "$_ne/bin" "$_ne/ghp"
    create_mock_sf "$_ne/bin"
    _make_fake_gh "$_ne/bin"; _make_git_wrapper "$_ne/bin"
    export MOCK_GHP_DIR="$_ne/ghp" MOCK_CALL_LOG="$_ne/calls.log"
    _setup_repo "$_ne" "${2:-main\nstaging\ndevelop\n}"
    printf -v "$1" '%s' "$_ne"
}

# ------------------------------------------------------------------------------
test_r1_order() {
    echo ""; echo -e "${CLR_HEAD}[TEST] R1: 前の段階の印${CLR_RST}"
    local td h
    _new_env td; h=$(_head "$td")
    _ghp_pr 5 "$h" feat staging
    _run_pc "$td" --pr 5 --only sequence
    assert_equals "$PC_RC" "1" "印なし → 1"
    assert_output_contains "$PC_OUT" "まだ develop に出ていません" "印なし → 理由"
    _ghp_mark "$h" develop
    _run_pc "$td" --pr 5 --only sequence
    assert_equals "$PC_RC" "0" "develop の印あり → 0"
    _ghp_mark "$h" develop success "someone"
    _run_pc "$td" --pr 5 --only sequence
    assert_equals "$PC_RC" "1" "人が付けた印 → 無視して 1"
    assert_output_contains "$PC_OUT" "github-actions\[bot\] 以外" "人が付けた印 → WARNING"
    _ghp_mark "$h" develop success "github-actions[bot]" 111 "0000000000000000000000000000000000000000"
    _run_pc "$td" --pr 5 --only sequence
    assert_equals "$PC_RC" "1" "実行の head_sha が違う → 1"
    _ghp_mark "$h" develop success "github-actions[bot]" 112 "" ".github/workflows/other.yml"
    _run_pc "$td" --pr 5 --only sequence
    assert_equals "$PC_RC" "1" "ほかのワークフローの実行 → 1"
    _ghp_mark "$h" develop success "github-actions[bot]" 113 "" "" "x/other"
    _run_pc "$td" --pr 5 --only sequence
    assert_equals "$PC_RC" "1" "実行のリポジトリが違う → 1"
    _ghp_mark "$h" develop failure
    _run_pc "$td" --pr 5 --only sequence
    assert_equals "$PC_RC" "1" "一番新しい状態が failure → 1"
    # 古い success と新しい failure が、API の順番どおりでなく混ざっている（2 ページ目から来た）→ 作成日時で新しい failure を選ぶ → 1
    _ghp_mark "$h" develop success "github-actions[bot]" 114
    printf '%s\t%s\t%s\t%s\n' "2026-11-02T00:00:00Z" failure "github-actions[bot]" "https://github.com/o/r/actions/runs/114" >> "$MOCK_GHP_DIR/st_${h}_develop.txt"
    _run_pc "$td" --pr 5 --only sequence
    assert_equals "$PC_RC" "1" "古い success と新しい failure（順番がばらばら）→ 新しい failure を見て 1"
    assert_file_contains "$MOCK_CALL_LOG" "api --paginate repos/o/r/commits/" "印は、全ページを取って確かめる（--paginate）"
    printf '%s\t%s\t%s\t%s\n' "2026-11-02T00:00:00Z" success "github-actions[bot]" "https://github.com/o/r/actions/runs/114" "2026-11-01T00:00:00Z" failure "github-actions[bot]" "https://github.com/o/r/actions/runs/114" > "$MOCK_GHP_DIR/st_${h}_develop.txt"
    _run_pc "$td" --pr 5 --only sequence
    assert_equals "$PC_RC" "0" "新しい success・古い failure → 0"
    printf '2026-11-01T00:00:00Z\tsuccess\tgithub-actions[bot]\thttps://github.com/x/other/actions/runs/7\n' > "$MOCK_GHP_DIR/st_${h}_develop.txt"
    _run_pc "$td" --pr 5 --only sequence
    assert_equals "$PC_RC" "1" "URL がほかのリポジトリ → 1"
    printf '2026-11-01T00:00:00Z\tsuccess\tgithub-actions[bot]\thttps://example.com/broken\n' > "$MOCK_GHP_DIR/st_${h}_develop.txt"
    _run_pc "$td" --pr 5 --only sequence
    assert_equals "$PC_RC" "2" "URL が壊れている → 2"
    _ghp_pr 6 "$h" feat develop
    _run_pc "$td" --pr 6 --only sequence
    assert_equals "$PC_RC" "0" "一番下の段階（develop）→ R1 は見ない"
    teardown "$td"
}

test_r0_r3_and_args() {
    echo ""; echo -e "${CLR_HEAD}[TEST] R0・R3・引数${CLR_RST}"
    local td h
    _new_env td; h=$(_head "$td")
    _ghp_pr 5 "$h" feat staging true
    _run_pc "$td" --pr 5 --only sequence
    assert_equals "$PC_RC" "2" "フォーク → 2"
    _ghp_pr 5 "0000000000000000000000000000000000000000" feat staging
    _run_pc "$td" --pr 5 --only sequence
    assert_equals "$PC_RC" "2" "HEAD が PR の先端と違う → 2"
    _ghp_pr 5 "$h" feat staging false "https://github.com/x/y/pull/5"
    _run_pc "$td" --pr 5 --only sequence
    assert_equals "$PC_RC" "2" "PR のリポジトリが origin と違う → 2"
    _ghp_pr 5 "$h" staging main
    _run_pc "$td" --pr 5 --only sequence
    assert_equals "$PC_RC" "1" "環境ブランチから → 1（R3）"
    assert_output_contains "$PC_OUT" "\[R3\]" "環境ブランチ → R3"
    _ghp_pr 5 "$h" feat uat
    _run_pc "$td" --pr 5
    assert_equals "$PC_RC" "0" "段階でない先 → スキップ 0"
    _run_pc "$td" --pr 5 --only R1;        assert_equals "$PC_RC" "2" "--only の不正な値 → 2"
    _run_pc "$td" --pr 5 --only sequence --only stack; assert_equals "$PC_RC" "2" "--only を 2 回 → 2"
    _run_pc "$td" --pr 5 --only;           assert_equals "$PC_RC" "2" "--only の値が空 → 2"
    _run_pc "$td" --plan --only stack;     assert_equals "$PC_RC" "2" "--plan と --only → 2"
    _run_pc "$td";                         assert_equals "$PC_RC" "2" "モードなし → 2"
    _run_pc "$td" --pr abc;                assert_equals "$PC_RC" "2" "--pr の番号が不正 → 2"
    teardown "$td"
    _new_env td "main\ndevelop\n"; h=$(_head "$td")
    _ghp_pr 5 "$h" feat develop
    _run_pc "$td" --pr 5 --only sequence
    assert_equals "$PC_RC" "2" "branches.txt が不正（develop だけ）→ 2"
    teardown "$td"
    _new_env td NONE; h=$(_head "$td")
    _ghp_pr 5 "$h" feat main
    _run_pc "$td" --pr 5 --only sequence
    assert_equals "$PC_RC" "2" "branches.txt がない → 2"
    teardown "$td"
}

test_empty_targets_skip() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 対象が空 → スキップ${CLR_RST}"
    local td h
    _new_env td
    ( cd "$td/force-t" && printf '[files]\n' > sf-tools/release/feat/deploy-target.txt && "$REAL_GIT" commit -qam empty && "$REAL_GIT" push -q origin feat )
    h=$(_head "$td"); _ghp_pr 5 "$h" feat main
    _run_pc "$td" --pr 5 --json
    assert_equals "$PC_RC" "0" "対象が空 → 0（R1 も見ない）"
    assert_output_contains "$PC_OUT" '"skipped":true' "対象が空 → skipped"
    teardown "$td"
}

test_r2_stack() {
    echo ""; echo -e "${CLR_HEAD}[TEST] R2: 積み重ね${CLR_RST}"
    local td h1 h2
    _new_env td; h1=$(_head "$td")
    # 1 回目（クラス A・B）を develop に出した（develop の印あり・main の印なし）
    printf '1\t%s\tfalse\n' "$h1" > "$MOCK_GHP_DIR/prl_feat_develop_merged.txt"
    _ghp_mark "$h1" develop
    # 2 回目: B を一覧から外した
    ( cd "$td/force-t" && printf '[files]\nforce-app/main/default/classes/A.cls\n' > sf-tools/release/feat/deploy-target.txt && "$REAL_GIT" commit -qam feat2 && "$REAL_GIT" push -q origin feat )
    h2=$(_head "$td"); _ghp_pr 7 "$h2" feat develop
    _run_pc "$td" --pr 7 --only stack
    assert_equals "$PC_RC" "1" "前のリリースの部品（B）が抜けた → 1"
    assert_output_contains "$PC_OUT" "ApexClass:B" "抜けた部品を出す"
    assert_file_contains "$MOCK_CALL_LOG" "--head feat --base develop" "前のリリースは、同じブランチ・同じ段階の PR だけを見る"
    # 前のリリースの PR が、一覧の上限（1000 件）まで返った → 取りこぼしがありうるため、判断できない（2）
    cp "$MOCK_GHP_DIR/prl_feat_develop_merged.txt" "$MOCK_GHP_DIR/prl.bak"
    for _i in $(seq 1 1000); do printf '%s\t%s\tfalse\n' "$((_i + 100))" "$h1"; done > "$MOCK_GHP_DIR/prl_feat_develop_merged.txt"
    _run_pc "$td" --pr 7 --only stack
    assert_equals "$PC_RC" "2" "前のリリースの PR が 1000 件以上 → 判断できない（2）"
    assert_output_contains "$PC_OUT" "1000 件以上" "件数の上限に達したことを出す"
    mv "$MOCK_GHP_DIR/prl.bak" "$MOCK_GHP_DIR/prl_feat_develop_merged.txt"
    # B を remove-target に移した → 含まれる
    ( cd "$td/force-t" && printf '[files]\n\n[members]\nApexClass:B\n' > sf-tools/release/feat/remove-target.txt && "$REAL_GIT" commit -qam feat3 && "$REAL_GIT" push -q origin feat )
    h2=$(_head "$td"); _ghp_pr 7 "$h2" feat develop
    _run_pc "$td" --pr 7 --only stack
    assert_equals "$PC_RC" "0" "抜けた部品を remove-target に移した → 0"
    # 前のリリースが main まで届いている → 対象外
    ( cd "$td/force-t" && printf '[files]\n' > sf-tools/release/feat/remove-target.txt && "$REAL_GIT" commit -qam feat4 && "$REAL_GIT" push -q origin feat )
    h2=$(_head "$td"); _ghp_pr 7 "$h2" feat develop
    _ghp_mark "$h1" main
    _run_pc "$td" --pr 7 --only stack
    assert_equals "$PC_RC" "0" "前のリリースが main まで届いた → 対象外 0"
    rm -f "$MOCK_GHP_DIR/st_${h1}_main.txt"
    # 前の PR に develop の印がない（リリースに失敗した）→ 対象外
    rm -f "$MOCK_GHP_DIR/st_${h1}_develop.txt"
    _run_pc "$td" --pr 7 --only stack
    assert_equals "$PC_RC" "0" "前の PR に印がない → 対象外 0"
    # フォークの PR は対象外
    _ghp_mark "$h1" develop
    printf '1\t%s\ttrue\n' "$h1" > "$MOCK_GHP_DIR/prl_feat_develop_merged.txt"
    _run_pc "$td" --pr 7 --only stack
    assert_equals "$PC_RC" "0" "前の PR がフォーク → 対象外 0"
    # --only sequence は R2 を見ない
    printf '1\t%s\tfalse\n' "$h1" > "$MOCK_GHP_DIR/prl_feat_develop_merged.txt"
    _run_pc "$td" --pr 7 --only sequence
    assert_equals "$PC_RC" "0" "--only sequence は R2 を見ない"
    _run_pc "$td" --pr 7
    assert_equals "$PC_RC" "1" "--only なし（wf-release）は R2 も見る"
    teardown "$td"
}

test_plan() {
    echo ""; echo -e "${CLR_HEAD}[TEST] --plan: 次の出し先${CLR_RST}"
    local td h
    _new_env td; h=$(_head "$td")
    _run_pc "$td" --plan --json
    assert_equals "$PC_RC" "0" "印なし → 0"
    assert_output_contains "$PC_OUT" '"next_tier":"develop"' "印なし → develop"
    _ghp_mark "$h" develop
    printf '9\n' > "$MOCK_GHP_DIR/prl_feat_staging_open.txt"
    _run_pc "$td" --plan --json
    assert_output_contains "$PC_OUT" '"next_tier":"staging"' "develop の印あり → staging"
    assert_output_contains "$PC_OUT" '"pr_open":"9"' "開いている PR を返す"
    _ghp_mark "$h" staging; _ghp_mark "$h" main
    _run_pc "$td" --plan --json
    assert_output_contains "$PC_OUT" '"next_tier":"none"' "全部に印 → none"
    rm -f "$MOCK_GHP_DIR/st_${h}_develop.txt"
    _run_pc "$td" --plan --json
    assert_equals "$PC_RC" "2" "上の段階に印があり、下にない → 2"
    ( cd "$td/force-t" && echo x > x.txt && "$REAL_GIT" add x.txt && "$REAL_GIT" commit -qm local )
    _run_pc "$td" --plan
    assert_equals "$PC_RC" "2" "push していない変更 → 2"
    assert_output_contains "$PC_OUT" "push していない" "push していない → 理由"
    ( cd "$td/force-t" && "$REAL_GIT" checkout -q main )
    _run_pc "$td" --plan
    assert_equals "$PC_RC" "1" "環境ブランチの上 → 1（R3）"
    teardown "$td"
}

test_help() {
    echo ""; echo -e "${CLR_HEAD}[TEST] --help${CLR_RST}"
    local out; out=$(bash "$PC" --help 2>&1)
    assert_output_contains "$out" "【使い方】" "--help で使い方を出す"
}

test_r1_order
test_r0_r3_and_args
test_empty_targets_skip
test_r2_stack
test_plan
test_help

print_summary
