#!/bin/bash
# ==============================================================================
# phases/project/finish.sh - sf-project.sh の部品: 後処理（8 章。実行範囲の Phase が、すべて成功したあと）
# ==============================================================================
# bin/sf-project.sh が source する（単独では動かさない）。変数・関数は、sf-project.sh の 1〜2 章と、先に source した部品が用意する。
# 引数（"$@"）は、sf-project.sh のものが、そのまま見える（source に引数を渡さないため。shift も、sf-project.sh の引数に効く）。
# 2026-11-28 に、929 行あった sf-project.sh の 3〜6 章と 8 章を、部品に分けた（中身は変えずに移した。章の番号は、元のまま）。
# Phase のスクリプト（phases/init/）とは別のフォルダに置く（phases/init/ の *.sh は、単独で動かす前提のテストがあるため）。
# ==============================================================================
# shellcheck disable=SC2154  # 変数は、source する bin/sf-project.sh が用意する（この部品だけでは、代入が見えない）

# ------------------------------------------------------------------------------
# 8. 後処理（実行範囲の Phase が、すべて成功したあと）
# ------------------------------------------------------------------------------
# .sf-init-XXXX.env から REPO_DIR・REPO_FULL_NAME・BRANCH_COUNT などを取得（同期・動作の確認・admin ブランチ・完了画面に使用）
[[ -f "$SF_INIT_ENV_FILE" ]] && source "$SF_INIT_ENV_FILE"

# admin フォルダは、削除せずに残す（管理者用のフォルダ。更新・接続の確認・やり直しなどのメンテナンスに使う）
#   以前は、最後に削除する質問を出していたが、廃止した。残るファイルに、秘密情報（Token の値）が含まれないように、
#   念のため、Token の値の行を .sf-init-XXXX.env から消す（通常は、Phase 8 の push 後に、消えている）。
#   最後（Phase 10）まで実行したときだけ行う（--only 6 などの途中までの実行では、Phase 8 が、あとで使うため、消さない）
if [[ "$END_PHASE" -eq 10 && -f "$SF_INIT_ENV_FILE" ]]; then
    run sed_inplace '/^[A-Z_]*TOKEN_VALUE=/d' "$SF_INIT_ENV_FILE"
fi

# 最初のメタデータの同期: セットアップが終わった瞬間に、Salesforce のメタデータが、リポジトリ（main）と、管理者用のクローンに、
#   全部入っているようにする（初期コミットの force-app は、空のひな型。何もしないと、次の定期実行（平日 3 時間おき）まで入らない）。
#   同期は、Phase 10（接続情報の登録）のあとでないと動かないため、クローンの作成（Phase 3）よりあとになる。そこで、
#   wf-metasync を実行し、終わったら、クローンに git pull する。失敗しても、セットアップは成功のまま、完了画面で知らせる。
#   Phase 10 を実行した、最後までの実行で、状態ファイルに REPO_DIR・REPO_FULL_NAME があるときだけ（--only N では行わない）
SYNC_RESULT=""   # "" = 行わなかった / done = 同期して、クローンに取り込んだ / failed = できなかった
if [[ "$END_PHASE" -eq 10 && -z "$ONLY_PHASE" && "$START_PHASE" -le 10 && -n "${REPO_DIR:-}" && -n "${REPO_FULL_NAME:-}" ]]; then
    log "HEADER" "最初のメタデータの同期（Salesforce → GitHub → この管理者用のクローン）"
    if initial_metadata_sync "$REPO_FULL_NAME" "$REPO_DIR"; then
        SYNC_RESULT="done"
    else
        SYNC_RESULT="failed"
    fi
fi

# ステップ 9: 動作の確認（verify.sh）。聞くのは、「通しの実行」と、中断後の「続きをやる」だけ（FULL_START。
#   --resume N（2 以上）/ --only N を明示した実行では、聞かない: Phase 単位のやり直しに、20 分ほどの検証を、混ぜないため）。
#   対話できる端末のときだけ聞く（SF_INIT_VERIFY_ASK=1 で、端末でなくても聞く: テスト用。GITHUB_ACTIONS 上では、聞かない）
#   Enter = 確認する / s = あとで。標準入力が閉じている（EOF）ときは、あとで、とする。確認の失敗は、セットアップの失敗にはしない
VERIFY_RESULT=""   # "" = 聞かなかった / done = 成功 / failed = 失敗あり / skipped = あとで
if [[ "$END_PHASE" -eq 10 && "$FULL_START" -eq 1 && "${GITHUB_ACTIONS:-}" != "true" \
      && ( -t 0 || "${SF_INIT_VERIFY_ASK:-}" == "1" ) ]]; then
    _done_titles=()
    for _i in $(seq 1 $((WIZ_TOTAL - 1))); do _done_titles+=("${WIZ_STEP_TITLES[$_i]}"); done
    wizard_step "$WIZ_TOTAL" "$WIZ_TOTAL" "${WIZ_STEP_TITLES[$WIZ_TOTAL]}" "${WIZ_STEP_PURPOSES[$WIZ_TOTAL]}" "${_done_titles[@]}"
    echo "" >&2
    echo "  環境全体の確認と、Hello World（誰も使わない、単純な Apex）の、リリースと削除を、各段階の組織で行います。" >&2
    echo "  所要時間の目安: 約 $((${BRANCH_COUNT:-1} * 6 + 3)) 分（Actions の混み具合で、前後します）。実際の組織にデプロイします（Hello World は、最後に削除します）。" >&2
    echo "" >&2
    while true; do
        read_input _vans "  ▶ 動作を確認しますか？ [Enter = 確認する / s = あとで]: " || _vans="s"  # EOF → あとで
        case "$_vans" in
            ""|Y|y) _vrun=1; break ;;
            S|s|Q|q|N|n) _vrun=0; break ;;
            *) echo "  Enter を押すと、確認します。あとで確認する場合は、s を入力してください。" >&2 ;;
        esac
    done
    if [[ "$_vrun" -eq 1 ]]; then
        # REPO_DIR が空のときは、現在のフォルダで実行する（${REPO_DIR:-.}）。Bash 5.3（Git for Windows 2.55 以降）は、
        #   cd "" を「cd: null directory」のエラーにする（3.2・5.2 は、何もせず成功する）。通常は、Phase 2 が設定する
        if ( cd "${REPO_DIR:-.}" && SF_VERIFY_CONFIRMED=1 bash "${SF_TOOLS_DIR}/phases/init/verify.sh" ); then  # 条件チェックのため run 不使用
            VERIFY_RESULT="done"
        else
            VERIFY_RESULT="failed"
        fi
    else
        VERIFY_RESULT="skipped"
    fi
fi

# 管理者用のクローンを、admin ブランチにして、GitHub にも push する（main の上で、作業しないため）。
#   実行範囲の終わりが Phase 10 で、REPO_DIR があるときだけ（--only 10・--resume N を含む）。動作の確認（verify.sh）のあとに行う。
#   admin ブランチにできなければ、push はしない。どちらに失敗しても、セットアップは成功のまま、完了画面で知らせる
_admin_branch_line="     ・ブランチは admin です（このコンピューターと GitHub の両方にあります）"
_admin_stale_line="     ・admin は、main から古くなります。使う前に、main を取り込んでください（git pull origin main）"
if [[ "$END_PHASE" -eq 10 && -n "${REPO_DIR:-}" ]]; then
    # 動作の確認（verify.sh）を実行した（成功・失敗とも。Hello World のリリースと削除が main に入っている）ときは、クローンが
    #   main にいれば、最新の main を取り込んでから（失敗は警告のみ）、admin を作る
    if [[ "$VERIFY_RESULT" == "done" || "$VERIFY_RESULT" == "failed" ]] \
       && [[ "$(git -C "$REPO_DIR" symbolic-ref --short HEAD 2>/dev/null || true)" == "main" ]]; then  # 条件チェックのため run 不使用
        run git -C "$REPO_DIR" pull --ff-only origin main \
            || log "WARNING" "動作の確認のあとの main を、取り込めませんでした: ${REPO_DIR}"
    fi
    if ! ensure_admin_branch "$REPO_DIR"; then
        log "WARNING" "管理者用のクローンを admin ブランチにできませんでした: ${REPO_DIR}"
        _admin_branch_line="     ・admin ブランチを作れませんでした（main のままです）。管理者用フォルダで、git switch -c admin を実行してください"
    elif ! push_admin_branch "$REPO_DIR"; then
        log "WARNING" "admin ブランチを GitHub に push できませんでした: ${REPO_DIR}"
        _admin_branch_line="     ・admin ブランチは、このコンピューターだけにあります（GitHub に push できませんでした）。管理者用フォルダで、git push -u origin admin を実行してください"
    fi
elif [[ "$END_PHASE" -ne 10 ]]; then
    _admin_branch_line="     ・ブランチは、そのままです（途中までの実行のため）"
    _admin_stale_line=""
else
    # 最後まで実行したが、状態ファイルに REPO_DIR がない（クローンの場所が分からない）
    _admin_branch_line="     ・ブランチは、そのままです（状態ファイルに、クローンの場所（REPO_DIR）がないため）"
    _admin_stale_line=""
fi

# セットアップが最後まで終わったら、クローンに完了の印（1）を付け、状態ファイル（.sf-init-XXXX.env / .progress）を消す。
#   完了後は、読む場所がないため（完了済みかどうかは、このフォルダのクローンで判定する: _project_completed）。
#   印を付けられなかったとき（REPO_DIR がない・クローンがない・git config の失敗）は、警告して、状態ファイルは残す
#   （_finish_unfinished_setup と同じ扱い。消すと、完了済みとも、途中とも、判定できなくなるため。残った状態ファイルは、
#   進捗が 10 なので、次回は完了済みとして扱い、後片付けを試みる）。Token の値の行は、上で消してある。
#   途中で止まったときは、続きをやるために残る。--only N の実行は、状態を持ち越すため、消さない
if [[ "$END_PHASE" -eq 10 && -z "$ONLY_PHASE" ]]; then
    if mark_setup_complete "${REPO_DIR:-}"; then
        run rm -f "$SF_INIT_ENV_FILE" "$SF_INIT_PROGRESS_FILE" \
            || log "WARNING" "状態ファイルを削除できませんでした: ${SF_INIT_ENV_FILE}"
    else
        log "WARNING" "完了の印を付けられなかったため、状態ファイルは、残します（クローン: ${REPO_DIR:-なし}）: ${SF_INIT_ENV_FILE}"
    fi
fi

# 完了画面（できたこと / 次にやること / 管理者用のフォルダ）。途中までの実行（--only N など）でも、常に表示する
_org_count=$(( ${BRANCH_COUNT:-1} ))
_admin_dir="${REPO_DIR:-${INIT_DIR}/force-${COMPANY_NAME}}"
# 動作の確認の結果の行。$( ) の中に case を書かない（Bash 3.2 は、case の「)」を、$( ) の終わりと取り違える）
case "$VERIFY_RESULT" in
    done)    _verify_line="4. 動作の確認: 成功しました（リリースと削除を、各段階の組織で確認済みです）" ;;
    failed)  _verify_line="4. 動作の確認: 失敗した項目があります。上の [NG] を確認してください（削除のみのやり直し: sf-project.sh --verify --cleanup）" ;;
    skipped) _verify_line="4. 動作の確認は、あとで行えます: 管理者用フォルダで、~/sf-tools/bin/sf-project.sh --verify（または、作業フォルダ（${INIT_BASE}）で、同じオーナー・プロジェクト名で sf-project.sh を再実行して、2 を選ぶ）" ;;
    *)       _verify_line="4. 動作の確認は、あとで行えます: 管理者用フォルダで、~/sf-tools/bin/sf-project.sh --verify" ;;
esac
# 最初のメタデータの同期の結果の行（行わなかったときは、その理由）
case "$SYNC_RESULT" in
    done)   _sync_line="5. Salesforce のメタデータは、同期済みです（リポジトリにも、この管理者用のクローンにも、入っています）。以後は、平日 3 時間おきに、自動で同期されます" ;;
    failed) _sync_line="5. Salesforce のメタデータの同期は、できませんでした（セットアップは、完了しています）。次の定期実行（平日 3 時間おき）で入ります。すぐ同期するには: gh workflow run wf-metasync.yml -R ${REPO_FULL_NAME:-${GITHUB_OWNER}/force-${COMPANY_NAME}}（終わったら、管理者用フォルダで git pull origin main）" ;;
    *)  # 行わなかった: 理由を、実際の条件（上の同期の if）に合わせて出す
        if [[ "$END_PHASE" -ne 10 ]]; then
            _sync_line="5. （途中までの実行のため、メタデータの同期は、行っていません。定期実行は、平日 3 時間おきです）"
        elif [[ -n "$ONLY_PHASE" ]]; then
            _sync_line="5. （--only の実行のため、メタデータの同期は、行っていません。定期実行は、平日 3 時間おきです）"
        else
            _sync_line="5. （状態ファイルに、リポジトリの情報（REPO_DIR・REPO_FULL_NAME）がないため、メタデータの同期は、行っていません。定期実行は、平日 3 時間おきです）"
        fi ;;
esac
wizard_done "できました: ${REPO_FULL_NAME:-${GITHUB_OWNER}/force-${COMPANY_NAME}}" \
    "GitHub リポジトリ / Token / Slack 通知 / Salesforce の接続（${_org_count} 組織）" \
    -- \
    "1. 開発を始める人は、自分の作業フォルダで、次のコマンドを実行してください（管理者自身なら、次のフォルダ）" \
    "     cd \"${INIT_BASE}\"" \
    "     sf-job.sh" \
    "2. リポジトリを見る:" \
    "     https://github.com/${REPO_FULL_NAME:-${GITHUB_OWNER}/force-${COMPANY_NAME}}" \
    "3. 【管理者用フォルダ】は、残してあります（削除しないでください）:" \
    "     ${_admin_dir}" \
    "     ・ワークフローの更新・接続の確認・接続先の付け替えなど、管理者のメンテナンスに使います" \
    "$_admin_branch_line" \
    "$_admin_stale_line" \
    "     ・日常の開発には使わないでください（開発は、上の sf-job.sh の作業フォルダで行います）" \
    "$_verify_line" \
    "$_sync_line"

exit $RET_OK
