#!/bin/bash
# ==============================================================================
# phases/metasync/git.sh - sf-metasync.sh の部品: main への切り替え・リモートの取り込み・取得先の一時プロジェクト（6 章の SWITCH・GIT・PREPARE）
# ==============================================================================
# bin/sf-metasync.sh が source する（単独では動かさない）。変数・関数は、sf-metasync.sh の 1〜5 章 と、先に source した部品が用意する。
# 2026-11-28 に、sf-metasync.sh の 6 章（フェーズ定義） を、部品に分けた（中身は変えずに移した）。
# ==============================================================================
# shellcheck disable=SC2154  # 変数は、source する bin/sf-metasync.sh が用意する（この部品だけでは、代入が見えない）

# 【SWITCH】main ブランチへ切替（他ブランチから実行した場合は、追跡中のファイルに未コミットの変更があれば stash してから切替）
phase_switch_to_main() {
    if [[ "$ORIGINAL_BRANCH" == "main" ]]; then
        return $RET_OK
    fi

    log "INFO" "main ブランチへ切り替えます（現在: ${ORIGINAL_BRANCH}）..."

    # 作業中の変更を一時退避
    if ! run git diff-index --quiet HEAD --; then
        log "INFO" "ローカルの変更を一時退避します (git stash)..."
        run git stash || return $RET_NG
        STASH_USED=1  # trap で stash pop するためフラグを立てる
    fi

    run git checkout main || return $RET_NG
    return $RET_OK
}

# 【GIT】リモートの変更を取り込む
phase_git_update() {
    log "INFO" "リモートの最新状態を取り込んでいます..."

    # main ブランチのローカル変更は Salesforce 組織の内容より優先されないため中止する
    # （stash して復元すると、ローカル変更が retrieve 後にコミットされてしまうため）
    if ! run git diff-index --quiet HEAD --; then
        die "main ブランチに、追跡中のファイルの未コミットの変更があります（Salesforce 組織の内容を正として同期するため、ローカルの変更は、同期に含めません）。"
    fi

    # 手元で実行したときは、追跡していないファイル（.gitignore の対象と、sf-tools/release/ を除く）がある場合も中止する。
    #   後の git add -A で、無関係なファイルが、同期のコミットに含まれてしまうため（以前は、含めていた）。
    #   sf-tools/release/ は、作業ブランチの日常的な作業用ファイル（sf-refresh.sh が作る）のため、対象外（ステージもしない）。
    #   GitHub Actions 上では、確認しない（クリーンなチェックアウトで、定期の同期を、予期しないファイルで止めないため）
    if [[ "${GITHUB_ACTIONS:-false}" != "true" ]]; then
        local untracked
        untracked=$(git ls-files --others --exclude-standard -- . ':!sf-tools/release' | head -5)  # VAR=$(cmd) のため run 不使用
        if [[ -n "$untracked" ]]; then
            die "main ブランチに、追跡していないファイルがあります（同期のコミットに含まれてしまうため中止します）: $(echo "$untracked" | tr '
' ' ')"
        fi
    fi

    run git fetch origin || log "WARNING" "git fetch に失敗しました。ローカルキャッシュで続行します。"

    if ! run git pull origin "$BRANCH_NAME" --rebase; then
        run git rebase --abort
        return $RET_NG
    fi

    return $RET_OK
}

# 【PREPARE】取得先の一時プロジェクトを作る（手順 5）。作業ツリーには、まだ何も書かない
phase_prepare_work() {
    # run 不使用: 標準出力（パッケージのフォルダの path）を変数に受けるため。S8（packageDirectories が 1 つでない）もここで検出する
    PKG_PATH=$("$NODE_BIN" "$METASYNC_JS" root --repo .) || return $RET_NG
    [[ -n "$PKG_PATH" ]] || return $RET_NG
    WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/sf-metasync-XXXXXX") || return $RET_NG  # VAR=$(cmd) のため run 不使用
    run cp sfdx-project.json "$WORK_DIR/" || return $RET_NG
    [[ -f .forceignore ]] && { run cp .forceignore "$WORK_DIR/" || return $RET_NG; }
    run mkdir -p "$WORK_DIR/$PKG_PATH" || return $RET_NG
    RETRIEVE_JSON="$WORK_DIR/retrieve.json"
    RETRIEVE_ERR="$WORK_DIR/retrieve.err"
    PLAN_FILE="$WORK_DIR/plan.tsv"
    RECENT_FILES="$WORK_DIR/recent.txt"
    return $RET_OK
}
