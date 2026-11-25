#!/bin/bash
# ==============================================================================
# wsl-gitfile.sh - WSL のテスト用の写しの .git（worktree の印）を、WSL から読めるパスに直す（tests/run_tests.sh から呼ぶ）
# ==============================================================================
# Git worktree の .git は、ディレクトリではなく「gitdir: <本体の .git/worktrees/<名前>>」の 1 行のファイル。
# Windows の Git Bash で作った worktree では、これが「gitdir: C:/Users/…」（Windows のドライブのパス）になり、
# WSL の git は読めない（fatal: not a git repository）。run_tests.sh が写した ~/.cache/sf-tools-test の中では、
# git diff・git ls-files がすべて失敗し、--changed が全件に倒れ、test_docs.sh の Markdown の一覧が空になっていた（2026-11-25）。
#
# 【使い方】
#   bash tests/wsl-gitfile.sh <写し元> <写し先>
#     写し元・写し先: リポジトリの根のフォルダ（写し先は、rsync で写したあとのもの）
#   環境変数 SF_WSL_MNT_ROOT : Windows のドライブが見える場所（既定 /mnt。テスト用。CI の Linux には /mnt/c がないため）
#
# 【処理の流れ】
#   1. 写し元の .git がファイルでなければ（ふつうのリポジトリの .git フォルダ・.git なし）、何もせず終わる（終了コード 0）
#   2. 1 行目の「gitdir: <パス>」を読む。この形でなければ、何もせず終わる（推測で書き換えない）
#   3. パスを、写し先から読める形に直す:
#        C:/… や C:\…（Windows のドライブ）→ /mnt/c/…（ドライブの文字は小文字。\ は / に。/mnt は SF_WSL_MNT_ROOT）
#        相対のパス（../.git/worktrees/x など）→ 写し元を基準にした絶対のパス（写し先からは、基準が変わるため）
#        / で始まるパス（WSL・Linux で作った worktree）→ そのまま
#   4. 直したパスが、写し先の .git と違えば、写し先の .git に書く。直したパスが「gitdir: …」で読めることも確かめ、
#      フォルダがなければ、書かずに終わる（壊れた印を作らない）
#
# 【補足】
#   - 書き換えるのは、写し先の .git の 1 ファイルだけ。写し元（Windows 側の worktree）と、本体の .git には書かない。
#     次の rsync で、写し先の .git は、写し元の内容に戻る（そのあとで、また直す）
#   - 写しの中の git は、本体の .git（/mnt/c 越し）の索引を読む。索引を書き換えないよう、run_tests.sh は
#     GIT_OPTIONAL_LOCKS=0 を付ける（git diff などが、ついでに索引を更新するのを止める）
#   - Bash 3.2 で動く（大文字を小文字にするのは tr）
# ==============================================================================
set -u

src="${1:-}"
dst="${2:-}"
if [[ -z "$src" || -z "$dst" || ! -d "$src" || ! -d "$dst" ]]; then
    echo "wsl-gitfile.sh: 写し元と写し先のフォルダを指定してください。" >&2
    exit 2
fi

# 1. worktree の印（ファイルの .git）でなければ、何もしない
[[ -f "$src/.git" ]] || exit 0

# 2. 「gitdir: <パス>」を読む（改行の CR は除く）
line=$(head -n 1 "$src/.git" | tr -d '\r')
case "$line" in
    "gitdir: "*) gd="${line#gitdir: }" ;;
    *) exit 0 ;;
esac
[[ -n "$gd" ]] || exit 0

# 3. 写し先から読める形に直す
case "$gd" in
    [A-Za-z]:[/\\]*)
        drive=$(printf '%s' "${gd%%:*}" | tr 'A-Z' 'a-z')
        rest=$(printf '%s' "${gd#?:}" | tr '\\' '/')
        new="${SF_WSL_MNT_ROOT:-/mnt}/${drive}${rest}"
        ;;
    /*)
        new="$gd"
        ;;
    *)
        # 相対のパスは、.git のファイルがあるフォルダ（写し元）が基準
        new=$(cd "$src" 2>/dev/null && cd "$gd" 2>/dev/null && pwd) || new=""
        ;;
esac

# 4. フォルダがなければ書かない（壊れた印を作らない）。同じなら書かない
if [[ -z "$new" || ! -d "$new" ]]; then
    echo "wsl-gitfile.sh: worktree の本体の .git が見つかりません（${gd}）。写しの .git は直しません。" >&2
    exit 0
fi
cur=$(head -n 1 "$dst/.git" 2>/dev/null | tr -d '\r')
[[ "$cur" == "gitdir: $new" ]] && exit 0
printf 'gitdir: %s\n' "$new" > "$dst/.git"
exit 0
