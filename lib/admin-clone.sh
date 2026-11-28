#!/bin/bash
# ==============================================================================
# admin-clone.sh - 管理者用のクローン（admin ブランチ・クローンと状態ファイルの照合・セットアップの完了の印）
# ==============================================================================
# lib/project.sh が source する（呼び出し側は、今までどおり lib/common.sh を読むだけでよい。単独では、source しない）。
# 2026-11-28 に、1013 行あった lib/project.sh から、テーマごとに分けた（中身は変えずに移した）。
# 関数の一覧と使い方は、lib/project.sh の冒頭コメント（【提供する関数】）にまとめてある。
# ==============================================================================
# shellcheck disable=SC2154  # 変数は、lib/common.sh と、それを読み込むスクリプトが用意する

# ensure_admin_branch - 管理者用のクローンを、admin ブランチ（ローカル）にする
# ------------------------------------------------------------------------------
# 【使い方】 ensure_admin_branch DIR
# 【理由】   管理者用のクローン（admin/force-XXXX）は、セットアップ後も、メンテナンス用に残る。main のままだと、
#           main の上で作業してしまう（main は保護ブランチ。sf-update-workflows.sh も、保護ブランチでは実行を断る）。
#           そこで、main から admin ブランチを作って、そこに置く。この関数は、ローカルだけを扱う（GitHub への push は、
#           push_admin_branch）
# 【動作】   すでに admin ブランチがあれば、作り直さずに、そこへ切り替える（作業を消さない）。なければ、main から作る
# 【戻り値】 0 = admin ブランチにいる / 1 = 失敗（Git のクローンではない・切り替えに失敗）。呼び出し側は、警告にとどめる
ensure_admin_branch() {
    local dir="${1:-}" cur
    [[ -n "$dir" ]] || return $RET_NG
    git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || return $RET_NG  # if cmd のため run 不使用（クローンかどうかの確認）
    cur=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || true)    # VAR=$(cmd) のため run 不使用
    [[ "$cur" == "admin" ]] && return $RET_OK
    if git -C "$dir" rev-parse --verify --quiet refs/heads/admin >/dev/null 2>&1; then  # if cmd のため run 不使用
        run git -C "$dir" checkout admin || return $RET_NG
    else
        run git -C "$dir" checkout -b admin main || return $RET_NG
    fi
    return $RET_OK
}

# push_admin_branch - admin ブランチを、GitHub にも作る
# ------------------------------------------------------------------------------
# 【使い方】 push_admin_branch DIR        （事前に ensure_admin_branch で admin にいること）
# 【理由】   管理者の変更は、main を取り込み → 変更 → push → PR で、GitHub に反映する。どのみち push するため、
#           最初から、ローカルと GitHub の両方に、同じ admin があるほうが自然（別のコンピューターからも使える）
# 【動作】   git push --no-verify -u origin admin。--no-verify: 管理者による自動の操作のため、pre-push フック（検証の実行）を省く
#           （phases/init/add_tier.sh の push と同じ扱い）。強制 push はしない（GitHub 側の admin と食い違うときは、失敗にする）
# 【戻り値】 0 = push した（または、すでに最新）/ 1 = 失敗。呼び出し側は、警告にとどめる
push_admin_branch() {
    local dir="${1:-}"
    [[ -n "$dir" ]] || return $RET_NG
    run git -C "$dir" push --no-verify -u origin admin || return $RET_NG
    return $RET_OK
}

# clone_matches_repo - DIR が Git のクローンで、origin が GitHub の OWNER/REPO か
# ------------------------------------------------------------------------------
# 【使い方】 clone_matches_repo DIR OWNER REPO        例: clone_matches_repo "$PWD/force-acme" my-org force-acme
# 【用途】   管理者用のクローンが、これから作る（または、完了済みの）リポジトリのものかの確認。別のリポジトリのクローンに、
#           書き込み・push しないための番人（オーナーと XXXX で決まるプロジェクトを、XXXX だけのフォルダ名で扱うため）
# 【比較】   大文字と小文字は、区別しない（GitHub は、区別しない）
# 【戻り値】 0 = 一致する / 1 = 一致しない（クローンではない・origin がない・GitHub 以外・別のリポジトリ）
clone_matches_repo() {
    local dir="${1:-}" owner="${2:-}" repo="${3:-}" pair want
    [[ -n "$dir" && -n "$owner" && -n "$repo" && -d "$dir" ]] || return 1
    origin_repo pair "$dir" || return 1                                    # origin がない・GitHub 以外は、一致しない
    pair=$(printf '%s' "$pair" | tr 'A-Z' 'a-z')                           # VAR=$(cmd) のため run 不使用
    want=$(printf '%s/%s' "$owner" "$repo" | tr 'A-Z' 'a-z')               # VAR=$(cmd) のため run 不使用
    [[ "$pair" == "$want" ]]
}

# state_matches_repo - 状態ファイル（.sf-init-XXXX.env）の REPO_FULL_NAME が OWNER/REPO か（大文字と小文字は区別しない）
#   使い方: state_matches_repo FILE OWNER REPO。ファイルがない・読めない・一致しないときは、戻り値 1
state_matches_repo() {
    local f="${1:-}" owner="${2:-}" repo="${3:-}" v want
    [[ -f "$f" && -n "$owner" && -n "$repo" ]] || return 1
    v=$(grep '^REPO_FULL_NAME=' "$f" 2>/dev/null | tail -n 1 | sed 's/^[^=]*=//; s/\r$//; s/^"//; s/"$//' | tr 'A-Z' 'a-z')  # VAR=$(cmd) のため run 不使用
    want=$(printf '%s/%s' "$owner" "$repo" | tr 'A-Z' 'a-z')                                                                    # VAR=$(cmd) のため run 不使用
    [[ -n "$v" && "$v" == "$want" ]]
}

# セットアップ完了の印: クローンの git config（sf-tools.setup-complete）に持たせる。値は 3 つの状態:
#   1    = 完了した
#   0    = やり直し中（「最初から、やり直す」の開始時に、0 にする。完了したら、1 にする）
#   未設定 = 印を導入する前の版（99d420d〜ff690db）で完了したプロジェクト、または、一度も完了していないクローン
#   状態ファイルは、完了時に消すため、完了済みかどうかを、ファイルなしで判定する必要がある。
#   「クローンがある」だけでは、やり直しの途中で止まったとき（状態ファイルを消したあと）に、未完了を完了と誤判定する。
#   かといって「印がない = 未完了」では、印を導入する前に完了したプロジェクトを、未完了と誤判定し、運用中のリポジトリを
#   新規セットアップとして上書きしてしまう。そこで、やり直し中は、印を消さず、0 にして、未設定と区別する。
#   印は、クローンの .git/config にあり、GitHub には送られない
#
# mark_setup_complete DIR - 印を 1（完了）にする。戻り値: 0 = 付けた / 1 = DIR が空・フォルダがない・git config の失敗
mark_setup_complete() {
    local dir="${1:-}"
    [[ -n "$dir" && -d "$dir" ]] || return 1
    run git -C "$dir" config sf-tools.setup-complete 1
}
# clear_setup_mark - やり直しの開始時に、印を 0（やり直し中）にする。クローンがなければ、何もしない（常に戻り値 0）
clear_setup_mark() {
    local dir="${1:-}"
    [[ -n "$dir" && -d "$dir" ]] || return 0
    git -C "$dir" config sf-tools.setup-complete 0 >/dev/null 2>&1 || true  # 失敗しても、やり直しは進める（意図的エラー無視）
    return 0
}

# clone_setup_completed - DIR が、OWNER/REPO の、セットアップ済みのクローンか
# ------------------------------------------------------------------------------
# 【使い方】 clone_setup_completed DIR OWNER REPO
# 【判定】   origin が OWNER/REPO（大文字と小文字は区別しない）で、かつ:
#           ・印が 1 → 完了済み
#           ・印が 0 → やり直し中（未完了）
#           ・印が未設定 → ローカルに admin ブランチがあれば、印を導入する前の版で完了したものとみなし、印を 1 にする
#             （その版は、完了時に admin ブランチを作り、状態ファイルを消すだけで、印を付けなかった）。admin ブランチがなければ、未完了
# 【戻り値】 0 = 完了済み / 1 = 未完了（origin が別のリポジトリ・クローンでない場合も）
clone_setup_completed() {
    local dir="${1:-}" v
    clone_matches_repo "$dir" "${2:-}" "${3:-}" || return 1
    v=$(git -C "$dir" config --get sf-tools.setup-complete 2>/dev/null)  # VAR=$(cmd) のため run 不使用
    case "$v" in
        1) return 0 ;;
        0) return 1 ;;
    esac
    git -C "$dir" rev-parse --verify --quiet refs/heads/admin >/dev/null 2>&1 || return 1  # 条件チェックのため run 不使用
    mark_setup_complete "$dir" || true  # 印を付けられなくても、完了済みとして扱う（次回も、同じ判定になる）
    return 0
}
