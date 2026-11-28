#!/bin/bash
# ==============================================================================
# phases/project/env.sh - sf-project.sh の部品: 環境変数の export・同時実行のロック・状態ファイルの確認（6 章）
# ==============================================================================
# bin/sf-project.sh が source する（単独では動かさない）。変数・関数は、sf-project.sh の 1〜2 章と、先に source した部品が用意する。
# 引数（"$@"）は、sf-project.sh のものが、そのまま見える（source に引数を渡さないため。shift も、sf-project.sh の引数に効く）。
# 2026-11-28 に、929 行あった sf-project.sh の 3〜6 章と 8 章を、部品に分けた（中身は変えずに移した。章の番号は、元のまま）。
# Phase のスクリプト（phases/init/）とは別のフォルダに置く（phases/init/ の *.sh は、単独で動かす前提のテストがあるため）。
# ==============================================================================
# shellcheck disable=SC2154  # 変数は、source する bin/sf-project.sh が用意する（この部品だけでは、代入が見えない）

# ------------------------------------------------------------------------------
# 6. 環境変数の export（各フェーズスクリプトから参照）
# ------------------------------------------------------------------------------
export SF_TOOLS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# .sf-init-XXXX.env は管理者用の作業フォルダに配置する（cd 後の PWD が admin/ になる）
export SF_INIT_ENV_FILE="${PWD}/.sf-init${_state_suffix}.env"

# 進捗ファイル（成功した Phase を記録する。.sf-init-XXXX.env とは別にする: 書き換えるときに、外部コマンドを使わないため）
export SF_INIT_PROGRESS_FILE="${PWD}/.sf-init${_state_suffix}.progress"

# 同じプロジェクト（同じ admin フォルダ・同じ XXXX）の sf-project を、同時に 2 つ動かさない（状態ファイルの取り合い・重複作成を防ぐ）。
#   ロックは、フォルダ（mkdir は、原子的）。中に、実行中の PID を書く。PID のプロセスが、もういなければ、古いロックとして引き継ぐ
#   （強制終了・SIGTERM では、ロックが残るため）。終了時に、削除する（EXIT トラップ）。
#   exec で実行しなおすとき（Phase 2 が終了コード 75 を返したとき）は、EXIT トラップが動かないため、exec の前に削除する
#   （残すと、実行しなおした側が、同じ PID のロックを「実行中」と判定して終了する）
_init_lock_dir="${PWD}/.sf-init${_state_suffix}.lock"
if ! mkdir "$_init_lock_dir" 2>/dev/null; then  # 条件チェックのため run 不使用（ロックの取得は、mkdir の成否で決まる）
    _init_lock_pid=$(cat "$_init_lock_dir/pid" 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
    if [[ "$_init_lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$_init_lock_pid" 2>/dev/null; then  # 存在確認のため run 不使用
        die "同じプロジェクト（${COMPANY_NAME}）の sf-project が、すでに実行中です（PID ${_init_lock_pid}。${_init_lock_dir}）。"
    fi
    log "WARNING" "前回の sf-project の、古いロックを引き継ぎます（実行中のプロセスは、ありません）: ${_init_lock_dir}"
    run rm -rf "$_init_lock_dir" || die "古いロックを削除できません: ${_init_lock_dir}"  # 実行中のプロセスがいないことは確認済み
    # 条件チェックのため run 不使用（ロックの取得は、mkdir の成否で決まる。失敗は、別の sf-project が先に取った場合）
    mkdir "$_init_lock_dir" 2>/dev/null || die "ロックを取得できません（別の sf-project が、同時に、起動した可能性があります）: ${_init_lock_dir}"
fi
echo "$$" > "$_init_lock_dir/pid"
trap 'rm -rf "$_init_lock_dir"' EXIT
# Phase 10 の、段階ごとの再開（完了した段階を、進捗に記録し、再実行ではスキップする）。--only のときは、使わない
[[ -z "$ONLY_PHASE" ]] && export SF_INIT_TIER_RESUME=1

# ファイル（KEY=値 の行）から、値を 1 つ取り出す（source しない）。引数: キー ファイル。なければ空
_kv_value() {
    grep "^${1}=" "$2" 2>/dev/null | tail -n 1 | sed 's/^[^=]*=//; s/\r$//; s/^"//; s/"$//'  # 取得専用のため run 不使用
}

# 完了済みのプロジェクトか（戻り値 0 = 完了済み）。完了時に、状態ファイルは消す（完了後は、読む場所がないため）ので、
#   ・状態ファイルが 2 つともある: 進捗が Phase 10 で、リポジトリが一致すること（以前の版が残した、または、完了の直前で
#     中断した、完了済みの状態）。一致しなければ、完了済みではない（クローンでは判定しない）
#   ・そろっていない: このフォルダ（admin）の、同じリポジトリのクローン（force-XXXX）が、セットアップ済みであること
#     （clone_setup_completed: クローンの git config sf-tools.setup-complete が 1。未設定のときは、admin ブランチがあれば、
#     印を導入する前の版で完了したものとみなす。0 は、やり直し中）。やり直しの開始時に、印を 0 にする
#   進捗が 2〜9（途中まで）のときは、完了済みではない（続きをやる、の対象）。結果: COMPLETED_REPO / COMPLETED_DIR / COMPLETED_AT
COMPLETED_REPO=""; COMPLETED_DIR=""; COMPLETED_AT=""
_project_completed() {
    local want="${GITHUB_OWNER}/force-${COMPANY_NAME}" _done _repo
    COMPLETED_REPO=""; COMPLETED_DIR=""; COMPLETED_AT=""
    if [[ -f "$SF_INIT_ENV_FILE" && -f "$SF_INIT_PROGRESS_FILE" ]]; then
        _done=$(_kv_value SF_INIT_DONE_PHASE "$SF_INIT_PROGRESS_FILE")   # VAR=$(cmd) のため run 不使用
        _repo=$(_kv_value REPO_FULL_NAME "$SF_INIT_ENV_FILE")            # VAR=$(cmd) のため run 不使用
        [[ "$_done" == "10" ]] && state_matches_repo "$SF_INIT_ENV_FILE" "$GITHUB_OWNER" "force-${COMPANY_NAME}" || return 1   # リポジトリ名は、大文字と小文字を区別しない
        COMPLETED_REPO="$_repo"
        COMPLETED_DIR=$(_kv_value REPO_DIR "$SF_INIT_ENV_FILE")          # VAR=$(cmd) のため run 不使用
        [[ -n "$COMPLETED_DIR" ]] || COMPLETED_DIR="${PWD}/force-${COMPANY_NAME}"   # REPO_DIR が状態ファイルにないとき（印を付けられず残ったときなど）は、管理者用のフォルダの、既定の場所
        COMPLETED_AT=$(_kv_value SF_INIT_DONE_AT "$SF_INIT_PROGRESS_FILE")  # VAR=$(cmd) のため run 不使用
        return 0
    fi
    clone_setup_completed "${PWD}/force-${COMPANY_NAME}" "$GITHUB_OWNER" "force-${COMPANY_NAME}" || return 1
    COMPLETED_REPO="$want"
    COMPLETED_DIR="${PWD}/force-${COMPANY_NAME}"
    return 0
}

# 前回、完了の直前で中断したときの後片付け（進捗は 10 まで進んだが、admin ブランチの作成・完了の印・状態ファイルの削除が、
#   済んでいない。以前の版が状態ファイルを残した場合も、同じ）。何度実行しても、同じ結果になる。引数: クローンのフォルダ
#   クローン（OWNER/force-XXXX のもの）があれば、admin ブランチにして GitHub にも push し（失敗は警告のみ）、完了の印を付けてから、
#   状態ファイルを削除する。印を付けられなければ、状態ファイルは残す。クローンがない・別のリポジトリのクローンなら、何もしない
_finish_unfinished_setup() {
    local dir="$1"
    [[ -d "$dir/.git" ]] || return 0   # クローンがないときは、何もしない（状態ファイルも、そのまま）
    # 渡されたクローン（状態ファイルの REPO_DIR、または admin/force-XXXX）が、このプロジェクトのものであること
    #   （別の場所の、別のクローンに、push しないため）
    clone_matches_repo "$dir" "$GITHUB_OWNER" "force-${COMPANY_NAME}" || return 0
    log "INFO" "前回のセットアップの、最後の後片付け（admin ブランチ・完了の印・状態ファイルの整理）が、済んでいません。いま、済ませます。"
    if ensure_admin_branch "$dir"; then
        push_admin_branch "$dir" || log "WARNING" "admin ブランチを GitHub に push できませんでした: ${dir}"
    else
        log "WARNING" "管理者用のクローンを admin ブランチにできませんでした: ${dir}"
    fi
    if mark_setup_complete "$dir"; then
        run rm -f "$SF_INIT_ENV_FILE" "$SF_INIT_PROGRESS_FILE" \
            || log "WARNING" "状態ファイルを削除できませんでした: ${SF_INIT_ENV_FILE}"
    else
        log "WARNING" "完了の印を付けられなかったため、状態ファイルは、残します: ${dir}"
    fi
    return 0
}

# origin に main ブランチがあることを確認する。なければ die（事実のみ）。引数: リポジトリ（OWNER/REPO） 理由の文（先頭に付ける）
#   gh で確認できないとき（通信の失敗など）も、確認できないため、die する
_require_origin_main() {
    local repo="$1" why="$2"
    gh api "repos/${repo}/branches/main" >/dev/null 2>&1 \
        || die "${why}が、${repo} の main ブランチを確認できません（状態ファイルと、実際の GitHub が、食い違っている可能性があります）。"   # 条件チェックのため run 不使用
}

# 前回の続きの確認（--resume N（2 以上）/ --only の指定がないときだけ。--owner / --project などは、あってよい）
#   前回、途中まで進んでいて（SF_INIT_DONE_PHASE が 2〜9）、状態ファイルのリポジトリ（REPO_FULL_NAME）が OWNER/force-XXXX なら、
#   「続きをやる / 最初からやり直す」を選ばせる。続きを選ぶと、Phase 1（環境チェック）を実行したうえで、次の Phase から始める
#   表示は、Phase の番号ではなく、利用者向けの名前（WIZ_PHASE_TITLES）で出す。
#   続きの対象でなく、完了済み（_project_completed）なら、完了済みの選択画面を出す
RESUMED=0
if [[ "$RESUME_PHASE" -eq 1 && -z "$ONLY_PHASE" ]]; then
    prev_done=""; prev_at=""; prev_repo=""
    if [[ -f "$SF_INIT_ENV_FILE" && -f "$SF_INIT_PROGRESS_FILE" ]]; then
        prev_done=$(_kv_value SF_INIT_DONE_PHASE "$SF_INIT_PROGRESS_FILE")   # VAR=$(cmd) のため run 不使用
        prev_at=$(_kv_value SF_INIT_DONE_AT "$SF_INIT_PROGRESS_FILE")        # VAR=$(cmd) のため run 不使用
        prev_repo=$(_kv_value REPO_FULL_NAME "$SF_INIT_ENV_FILE")            # VAR=$(cmd) のため run 不使用
    fi
    if [[ "$prev_done" =~ ^[0-9]+$ && "$prev_done" -ge 2 && "$prev_done" -lt 10 \
          ]] && state_matches_repo "$SF_INIT_ENV_FILE" "$GITHUB_OWNER" "force-${COMPANY_NAME}"; then
        next_phase=$((prev_done + 1))
        echo "" >&2
        log "INFO" "前回のセットアップは、「${WIZ_PHASE_TITLES[$prev_done]}」まで完了しています${prev_at:+（${prev_at}）}。（${prev_repo}）"
        echo "" >&2
        echo "    [1] 「${WIZ_PHASE_TITLES[$next_phase]}」から、続きをやる   ← おすすめ" >&2
        echo "    [2] 最初からやり直す（作成済みのリポジトリ・admin フォルダは、そのまま使います）" >&2
        echo "    [q] 中断" >&2
        echo "" >&2
        read_key resume_choice "  ▶ 番号を入力してください [1-2/q]: " "[12Qq]"
        # shellcheck disable=SC2154  # resume_choice は、read_key（lib/input.sh）が、名前で受け取って代入する
        case "$resume_choice" in
            1) # Phase 8（初回コミットの push）まで完了と記録されているのに、origin に main がないときは、続けない
               #   （状態ファイルと、実際の GitHub が、食い違っている。続けると、main のないまま、完了と表示してしまう）
               if [[ "$prev_done" -ge 8 ]]; then
                   _require_origin_main "$prev_repo" "「${WIZ_PHASE_TITLES[$prev_done]}」まで完了と記録されています"
               fi
               RESUMED=1
               START_PHASE=$next_phase
               END_PHASE=10
               ;;
            2) ;;  # 最初から（下で、完了の印を 0 にし、状態ファイルを削除する）
            *) die "中断しました。" ;;   # q / Q（終了コード 1）
        esac
    elif _project_completed; then
        # 状態ファイルが 1 つでも残っているとき（完了の直前の中断・以前の版）は、origin に main があること（なければ、終了する）
        if [[ -f "$SF_INIT_ENV_FILE" || -f "$SF_INIT_PROGRESS_FILE" ]]; then
            _require_origin_main "$COMPLETED_REPO" "セットアップは完了と記録されています"
        fi
        # 完了済みのプロジェクト: 「続きをやる」は意味がないため、完了済みであることと、できることを案内する
        prev_dir="$COMPLETED_DIR"; prev_repo="$COMPLETED_REPO"; prev_at="$COMPLETED_AT"
        # 状態ファイルが残っている（以前の版・完了の直前の中断）ときは、後片付けを済ませる
        if [[ -f "$SF_INIT_ENV_FILE" || -f "$SF_INIT_PROGRESS_FILE" ]]; then
            _finish_unfinished_setup "$prev_dir"
        fi
        echo "" >&2
        log "INFO" "このプロジェクトは、セットアップが、すでに完了しています${prev_at:+（${prev_at}）}。（${prev_repo}）"
        echo "" >&2
        echo "    [1] いまの Salesforce の接続を、見る（何も変更しません）   ← おすすめ" >&2
        echo "    [2] 動作を、確認する（Hello World を、各段階にリリースして、削除します。約 20 分）" >&2
        echo "    [3] 最初から、やり直す（作成済みのリポジトリは、そのまま使い、設定を、上書きします）" >&2
        echo "    [q] 終了" >&2
        echo "" >&2
        read_key done_choice "  ▶ 番号を入力してください [1-3/q]: " "[123Qq]"
        # shellcheck disable=SC2154  # done_choice も同様（read_key が代入する）
        case "$done_choice" in
            1) [[ -d "$prev_dir" ]] || die "管理者用のフォルダが見つかりません: ${prev_dir}"
               # 診断で不足があっても（終了コード 1）、表示のとおり。ここでは、エラー終了にしない
               ( cd "$prev_dir" && bash "${SF_TOOLS_DIR}/phases/init/status.sh" ) || true  # 画面への表示が目的のため run 不使用。不足の表示は status.sh が行い、終了コードは意図的に無視
               exit $RET_OK
               ;;
            2) [[ -d "$prev_dir" ]] || die "管理者用のフォルダが見つかりません: ${prev_dir}"
               # 動作の確認（verify.sh）。結果は、verify.sh が、表示する。確認は、verify.sh の中で、聞く
               ( cd "$prev_dir" && bash "${SF_TOOLS_DIR}/phases/init/verify.sh" )  # 対話があるため run 不使用
               exit $?
               ;;
            3) ;;  # 最初から（下で、完了の印を 0 にし、状態ファイルを削除する）
            *) exit $RET_OK ;;   # q / Q: 何もせずに終了（終了コード 0）
        esac
    fi
fi

# 完了済みのプロジェクトで、--resume N（2 以上）または --only N を明示した場合は、拒否する（接続処理などを、確認なしで、
#   やり直さないため。--only も、同じ Phase を、確認なしで実行できてしまう。以前は、--only は拒否しなかった）。
#   やり直したいときは、--resume / --only を付けずに（--owner / --project は付けてよい）実行して選ぶ
#   （[1] 接続を見る / [2] 動作を確認 / [3] 最初から）か、--reconnect を使う
if [[ ( "$RESUME_PHASE" -gt 1 || -n "$ONLY_PHASE" ) ]] && _project_completed; then
    log "ERROR" "  このプロジェクト（${COMPLETED_REPO}）は、セットアップが、すでに完了しています。"
    log "WARNING" "  接続先を付け替える        : force-* の中で sf-project.sh --reconnect <main|staging|develop>"
    log "WARNING" "  いまの状態を見る・動作を確認する・最初からやり直す : --resume / --only を付けずに（--owner / --project は付けてよい）sf-project.sh を実行して、選んでください"
    die "完了済みのプロジェクトでは、--resume / --only は使えません。"
fi

# 新規実行時（--resume / --only 時、前回の続きを選んだ時以外）は、完了の印を 0 にし、前回の残骸を削除する（空ファイルは作らない）
if [[ "$RESUME_PHASE" -eq 1 && -z "$ONLY_PHASE" && "$RESUMED" -eq 0 ]]; then
    # 前回の「最初から、やり直す」が、途中で止まったままか（印が 0）を、利用者に知らせる（完了済みの案内も、続きの選択も、出ないため）
    if [[ ! -f "$SF_INIT_ENV_FILE" && ! -f "$SF_INIT_PROGRESS_FILE" \
          && "$(git -C "${PWD}/force-${COMPANY_NAME}" config --get sf-tools.setup-complete 2>/dev/null || true)" == "0" ]] \
       && clone_matches_repo "${PWD}/force-${COMPANY_NAME}" "$GITHUB_OWNER" "force-${COMPANY_NAME}"; then  # 条件チェックのため run 不使用
        log "INFO" "前回の「最初から、やり直す」が、途中で止まっています。最初から、やり直します（作成済みのリポジトリ・クローンは、そのまま使います）。"
    fi
    # 完了の印を 0（やり直し中）にする（やり直しの途中で止まったとき、クローンがあるだけで、完了済みと判定しないため）
    clear_setup_mark "${PWD}/force-${COMPANY_NAME}"
    # 新規実行時は残骸削除のみ（Phase 2 が初回書き出し）。消せないときは、前回の状態が残ったまま進まないよう、中断する
    run rm -f "$SF_INIT_ENV_FILE" "$SF_INIT_PROGRESS_FILE" || die "前回の状態ファイルを削除できません: ${SF_INIT_ENV_FILE}"
fi
