#!/bin/bash
# ==============================================================================
# test_cli_args.sh - 全コマンド（bin/sf-*.sh）の引数の頑丈さのテスト
# ==============================================================================
# 各コマンドの、--help に書かれたオプション（【オプション】の項）を、1 つずつ、値なしで実行し、
#   ・時間の上限（15 秒）内に終了すること（引数の解析が終わらない・入力待ちで止まらない）
#   ・「不明なオプションです」と言われないこと（文書に書かれたオプションを、コードが受け付けること）
# を確かめる。あわせて、文書にないオプションを渡しても、止まらずに終了することを確かめる。
# 実行場所は、モックだけを使う force-* の仮フォルダ。標準入力は閉じる（入力待ちは、EOF で終わる）。
# 冒頭コメントの【オプション】と、コードの食い違い（文書にあるのに、コードが拒否する）を、機械的に見つける。
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
source "$SF_TOOLS_DIR/lib/platform.sh"   # run_with_timeout
echo -e "${CLR_HEAD}=== 全コマンドの引数の頑丈さ ===${CLR_RST}"

# --help の【オプション】の項から、オプションを 1 行に 1 つ取り出す（-h / --help は除く）。
#   「-j, --json」のように長い形があるときは、長い形だけ。短い形だけのものは、短い形
_documented_options() {
    awk '/^# ==/{c++; next} c==2{sub(/^# ?/,""); print} c==3{exit}' "$1" \
        | awk '/^【オプション】/{on=1; next} /^【/{on=0} on' \
        | grep -E '^  (-[A-Za-z], )?--?[A-Za-z]' \
        | while IFS= read -r line; do
            if [[ "$line" =~ (--[a-z][a-z-]*) ]]; then
                echo "${BASH_REMATCH[1]}"
            elif [[ "$line" =~ (-[A-Za-z])([ ,:]|$) ]]; then
                echo "${BASH_REMATCH[1]}"
            fi
        done | grep -v -E '^(--help|-h)$' | sort -u
}

# 仮の環境で、コマンドを実行する。標準出力に出力、戻り値に終了コード
_run_cmd() {
    local td="$1" mb="$2" mh="$3" script="$4"; shift 4
    ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" run_with_timeout 15 bash "$mh/sf-tools/bin/$script" "$@" </dev/null 2>&1 )
}

test_documented_options_are_accepted() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 文書に書かれたオプションを、受け付ける（止まらない・不明と言わない）${CLR_RST}"
    local td mb mh f script opt out rc count=0
    setup_std_env td mb mh
    create_all_mocks "$mb"
    # fzf は、本物だと、対話の画面を開いて待つ。Esc で終了した状態（出力なし）のモックにする
    printf '#!/bin/bash\ncat > /dev/null\nexit 130\n' > "$mb/fzf"; chmod +x "$mb/fzf"
    for f in "$SF_TOOLS_DIR"/bin/sf-*.sh; do
        script=$(basename "$f")
        while IFS= read -r opt; do
            [[ -n "$opt" ]] || continue
            out=$(_run_cmd "$td" "$mb" "$mh" "$script" "$opt"); rc=$?
            count=$((count + 1))
            [[ "$rc" != "124" ]] && pass "${script} ${opt}: 時間内に終了する" \
                || fail "${script} ${opt}: 時間内に終了する" "終了コード 124（15 秒で打ち切り）"
            if echo "$out" | grep -q "不明なオプション"; then
                fail "${script} ${opt}: 文書に書かれたオプションを受け付ける" "「不明なオプションです」と拒否された"
            else
                pass "${script} ${opt}: 文書に書かれたオプションを受け付ける"
            fi
        done < <(_documented_options "$f")
    done
    [[ $count -gt 0 ]] && pass "文書に書かれたオプションを、${count} 個確認した" || fail "文書に書かれたオプションを確認した" "1 個も取り出せなかった"
    teardown "$td" "$mb" "$mh"
}

test_unknown_option_does_not_hang() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 文書にないオプションを渡しても、止まらずに終了する${CLR_RST}"
    local td mb mh f script rc
    setup_std_env td mb mh
    create_all_mocks "$mb"
    printf '#!/bin/bash\ncat > /dev/null\nexit 130\n' > "$mb/fzf"; chmod +x "$mb/fzf"
    for f in "$SF_TOOLS_DIR"/bin/sf-*.sh; do
        script=$(basename "$f")
        _run_cmd "$td" "$mb" "$mh" "$script" --zzz-unknown-opt > /dev/null; rc=$?
        [[ "$rc" != "124" ]] && pass "${script} --zzz-unknown-opt: 時間内に終了する" \
            || fail "${script} --zzz-unknown-opt: 時間内に終了する" "終了コード 124（15 秒で打ち切り）"
    done
    teardown "$td" "$mb" "$mh"
}

# 回帰: phases/init/*.sh は、SF_TOOLS_DIR が未設定でも、sf-tools のルートを使い、lib/common.sh を読み込める
#   （以前は、既定値が 1 つ上の phases/ を指し、14 本のうち 12 本が lib/common.sh を読み込めなかった。
#   通常は sf-init.sh が SF_TOOLS_DIR を export するため、直接実行したときにだけ起きた）
test_phase_scripts_default_sf_tools_dir() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] phases/init/*.sh は、SF_TOOLS_DIR が未設定でも、lib/common.sh を読み込める${CLR_RST}"
    local td mb mh f name out count=0
    setup_std_env td mb mh
    create_all_mocks "$mb"
    for f in "$SF_TOOLS_DIR"/phases/init/*.sh; do
        name=$(basename "$f")
        [[ "$name" == "init-common.sh" ]] && continue   # 関数の集まり（単独では実行しない）
        out=$( ( cd "$td" && run_with_timeout 15 env -u SF_TOOLS_DIR HOME="$mh" PATH="$mb:$PATH" bash "$mh/sf-tools/phases/init/$name" </dev/null 2>&1 ) )
        count=$((count + 1))
        if echo "$out" | grep -q "lib/common.sh: No such file\|common.sh: そのようなファイル"; then
            fail "${name}: SF_TOOLS_DIR が未設定でも、lib/common.sh を読み込める" "$(echo "$out" | grep "common.sh" | head -1)"
        else
            pass "${name}: SF_TOOLS_DIR が未設定でも、lib/common.sh を読み込める"
        fi
    done
    [[ $count -ge 10 ]] && pass "phases の ${count} 本を確認した" || fail "phases の本数を確認した" "${count} 本だけ"
    teardown "$td" "$mb" "$mh"
}

# 冒頭コメントの【オプション】が、コードの引数の扱いと食い違っていないか（静的な確認。実行しない）。
#   reject_unknown_args を呼ぶコマンド（-v 以外の引数を、不明なオプションとして中断する）の【オプション】の項に、
#   「不明なオプション」の記述があり、「検査しない・引数の解析はしない・無視する・そのまま渡す」の記述がないこと。
#   （以前、コード側だけに reject_unknown_args を足して、冒頭コメントが「無視する」のまま残った）
_header_options_section() {
    awk '/^# ==/{c++; next} c==2{sub(/^# ?/,""); print} c==3{exit}' "$1" | awk '/^【オプション】/{on=1; next} /^【/{on=0} on'
}

test_header_matches_unknown_arg_policy() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 冒頭コメントの【オプション】が、引数の拒否（reject_unknown_args）と食い違っていない${CLR_RST}"
    local f script opts count=0
    for f in "$SF_TOOLS_DIR"/bin/sf-*.sh; do
        script=$(basename "$f")
        grep -qE '^[^#]*reject_unknown_args "\$@"' "$f" || continue  # 条件チェック（呼ばないコマンドは、独自の解析のため対象外）
        count=$((count + 1))
        opts=$(_header_options_section "$f")  # VAR=$(cmd) のため run 不使用
        if ! echo "$opts" | grep -q "不明なオプション"; then
            fail "${script}: 冒頭コメントの【オプション】に、「不明なオプション」で中断する旨がある" "reject_unknown_args を呼ぶのに、記述がない"
        elif echo "$opts" | grep -qE "検査しない|引数の解析はしない|引数は.*無視|そのまま.*渡"; then
            fail "${script}: 冒頭コメントが、引数を無視する・そのまま渡すと書いていない" "$(echo "$opts" | grep -E '検査しない|引数の解析はしない|引数は.*無視|そのまま.*渡' | head -1)"
        else
            pass "${script}: 冒頭コメントの【オプション】が、引数の拒否と合っている"
        fi
    done
    [[ $count -ge 5 ]] && pass "reject_unknown_args を呼ぶコマンド ${count} 本を確認した" || fail "reject_unknown_args を呼ぶコマンドを確認した" "${count} 本だけ"
}

test_documented_options_are_accepted
test_header_matches_unknown_arg_policy
test_unknown_option_does_not_hang
test_phase_scripts_default_sf_tools_dir

print_summary
