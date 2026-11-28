#!/bin/bash
# ==============================================================================
# sftools-update.sh - sf-tools 自身が origin の最新かの確認と更新（ensure_sf_tools_latest）
# ==============================================================================
# lib/project.sh が source する（呼び出し側は、今までどおり lib/common.sh を読むだけでよい。単独では、source しない）。
# 2026-11-28 に、1013 行あった lib/project.sh から、テーマごとに分けた（中身は変えずに移した）。
# 関数の一覧と使い方は、lib/project.sh の冒頭コメント（【提供する関数】）にまとめてある。
# ==============================================================================
# shellcheck disable=SC2154  # 変数は、lib/common.sh と、それを読み込むスクリプトが用意する

# ensure_sf_tools_latest - sf-tools（Git リポジトリ）が、origin の最新であることを確認する（必須の確認）
# ------------------------------------------------------------------------------
# 【使い方】
#   ensure_sf_tools_latest [--no-update] [DIR]    # DIR は、省略時 $SF_TOOLS_DIR
#
# 【戻り値】
#   RET_OK (0) : 最新である（または、Git リポジトリでない・HEAD が分離状態・origin に同じブランチがない、のどれかで、
#                確認できないため、WARNING を出して続行する）
#   2          : 遅れていたため、git pull --ff-only で更新した。実行中のスクリプトが書き換わった可能性があるため、
#                呼び出し元は、再実行（exec）すること
#   （die）    : origin に接続できない・origin から取得（fetch）できない・遅れているのに、ローカルに未コミットの変更
#                または未 push のコミットがある・更新を断った（N / q）・更新に失敗した・--no-update で遅れている
#
# 【動作】
#   - 古い sf-tools で、作成済みのプロジェクトのワークフローなどを書き換える事故を防ぐ。
#     「最新でなければ続行しない」ことが目的のため、origin に接続できないときは、続行せず、中断する
#   - 先に git ls-remote --exit-code --heads origin refs/heads/<ブランチ> で、origin に同じブランチがあるかを確かめる
#     （終了コード 2 = ない → WARNING を出して続行 / 0 = ある → fetch して比べる / それ以外 = 接続できない → die）。
#     以前は、いきなり fetch していたため、origin にないブランチ（手元だけの作業ブランチ）でも、
#     「接続できない」として中断していた
#   - --no-update: 確認の質問と更新をしない（読み取り専用の実行用）。遅れていれば、die
# ------------------------------------------------------------------------------
ensure_sf_tools_latest() {
    local no_update=0
    if [[ "${1:-}" == "--no-update" ]]; then no_update=1; shift; fi
    local dir="${1:-${SF_TOOLS_DIR:-}}"
    local cur dirty ahead behind line rc_ls

    if [[ -z "$dir" ]] || ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then  # if cmd のため run 不使用
        log "WARNING" "sf-tools が Git リポジトリではないため、最新かどうかを確認できません。"
        return $RET_OK
    fi
    cur=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
    if [[ -z "$cur" ]]; then
        log "WARNING" "sf-tools の HEAD がブランチを指していないため、最新かどうかを確認できません。"
        return $RET_OK
    fi
    # origin に、同じブランチがあるか（終了コードで分岐するため run 不使用。run は、失敗を、すべて 1 にする）
    rc_ls=0
    git -C "$dir" ls-remote --exit-code --heads origin "refs/heads/${cur}" >/dev/null 2>&1 || rc_ls=$?
    case $rc_ls in
        0) ;;
        2)
            log "WARNING" "origin に ${cur} ブランチが存在しないため、最新かどうかを確認できません。"
            return $RET_OK ;;
        *)
            die "origin に接続できないため、sf-tools が最新かどうかを確認できません。" ;;
    esac
    run git -C "$dir" fetch origin "$cur" \
        || die "origin から ${cur} を取得できないため、sf-tools が最新かどうかを確認できません。"
    if ! git -C "$dir" rev-parse --verify --quiet "origin/${cur}" >/dev/null 2>&1; then  # if cmd のため run 不使用
        log "WARNING" "origin に ${cur} ブランチが存在しないため、最新かどうかを確認できません。"
        return $RET_OK
    fi
    behind=$(git -C "$dir" rev-list --count "HEAD..origin/${cur}" 2>/dev/null || echo 0)  # VAR=$(cmd) のため run 不使用
    if [[ "$behind" -eq 0 ]]; then
        log "INFO" "sf-tools（${cur}）は最新です。"
        return $RET_OK
    fi
    log "WARNING" "sf-tools（${cur}）は origin より ${behind} コミット遅れています。"
    while IFS= read -r line; do
        log "INFO" "  ${line}"
    done < <(git -C "$dir" log --oneline -10 "HEAD..origin/${cur}" 2>/dev/null)  # プロセス置換のため run 不使用
    [[ $no_update -eq 0 ]] || die "sf-tools が最新ではありません。"
    dirty=$(git -C "$dir" status --porcelain 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
    ahead=$(git -C "$dir" rev-list --count "origin/${cur}..HEAD" 2>/dev/null || echo 0)  # VAR=$(cmd) のため run 不使用
    if [[ -n "$dirty" || "$ahead" -gt 0 ]]; then
        die "sf-tools に未コミットの変更または未 push のコミットがあるため、自動では更新できません。"
    fi
    ask_yn "▶ sf-tools を更新しますか？" update.sftools || die "sf-tools が最新ではないため、続行できません。"
    run git -C "$dir" pull --ff-only origin "$cur" || die "sf-tools の更新に失敗しました。"
    log "SUCCESS" "sf-tools を更新しました。"
    return 2
}
