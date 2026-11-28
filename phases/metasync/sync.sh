#!/bin/bash
# ==============================================================================
# phases/metasync/sync.sh - sf-metasync.sh の部品: Git への反映（6 章の SYNC）
# ==============================================================================
# bin/sf-metasync.sh が source する（単独では動かさない）。変数・関数は、sf-metasync.sh の 1〜5 章 と、先に source した部品が用意する。
# 2026-11-28 に、sf-metasync.sh の 6 章（フェーズ定義） を、部品に分けた（中身は変えずに移した）。
# ==============================================================================
# shellcheck disable=SC2154  # 変数は、source する bin/sf-metasync.sh が用意する（この部品だけでは、代入が見えない）

# 【SYNC】変更を Git へ反映
phase_git_sync() {
    log "INFO" "Git リポジトリへ反映中..."
    # 同期の対象のパッケージのフォルダ（と、書いたときは検知の状態ファイル）だけをステージする
    #   （それ以外が変わる理由がない。sf-tools/release/ も含めない）
    local add_paths=("$PKG_PATH")
    [[ "$STATE_WRITTEN" -eq 1 ]] && add_paths+=("$STATE_FILE")
    [[ "$FP_WRITTEN" -eq 1 ]] && add_paths+=("$FP_STATE_FILE")
    run git add -A -- "${add_paths[@]}" || return $RET_NG

    # ステージに変更がなければ、未プッシュのコミットを確認する。あれば（前回、コミットのあとに push が失敗した）、push だけ行う。
    #   なければ、早期終了（組織側に変更なし）
    if run git diff-index --quiet HEAD --; then
        local _ahead
        _ahead=$(git rev-list --count "origin/${BRANCH_NAME}..HEAD" 2>/dev/null || echo 0)  # VAR=$(cmd) のため run 不使用
        if [[ "$_ahead" =~ ^[0-9]+$ && "$_ahead" -gt 0 ]]; then
            log "INFO" "未プッシュのコミットが ${_ahead} 件あります（前回の同期のコミットの push が、失敗した可能性があります）。push だけ行います。"
            if [[ "${GITHUB_ACTIONS:-false}" != "true" ]]; then
                git log --oneline "origin/${BRANCH_NAME}..HEAD" >&2  # run 不使用: 確認表示のため
                ask_yn "上記のコミットを main にプッシュします。よろしいですか？" || die "中断しました。"
            fi
            run git push --no-verify origin "$BRANCH_NAME" || return $RET_NG
            return $RET_OK
        fi
        return $RET_NO_CHANGE
    fi

    # コミットの本文に、計画の件数を書く（確認は、手順 9 で済んでいる）。検知・指紋の状態を更新したときは、その旨も書く
    local body="$PLAN_COUNTS"
    if [[ "$STATE_WRITTEN" -eq 1 || "$FP_WRITTEN" -eq 1 ]]; then
        local _label="検知の状態"   # 検知だけのときは、従来の文言のまま。指紋の状態が加わるときだけ変える
        if [[ "$FP_WRITTEN" -eq 1 ]]; then _label=$([[ "$STATE_WRITTEN" -eq 1 ]] && echo "検知・指紋の状態" || echo "指紋の状態"); fi  # VAR=$(cmd) のため run 不使用
        if [[ "$PLAN_CHANGES" -eq 0 ]]; then body="${body}（${_label}の更新のみ）"; else body="${body}（${_label}も更新）"; fi
    fi
    run git commit -m "$COMMIT_MSG" -m "$body" || return $RET_NG
    COMMITTED=1
    # --no-verify: このコマンドは、main への同期の専用（管理者が、確認して実行する。GitHub Actions では、フックがない）。
    #   pre-push フック（開発者の main への直接 push を止める）を、ここでだけ通さない。サーバー側の保護（Ruleset）は、そのまま効く
    run git push --no-verify origin "$BRANCH_NAME" || return $RET_NG
}
