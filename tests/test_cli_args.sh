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

test_documented_options_are_accepted
test_unknown_option_does_not_hang

print_summary
