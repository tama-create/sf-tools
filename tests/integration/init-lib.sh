#!/bin/bash
# ==============================================================================
# init-lib.sh - sf-init の結合テスト（test_integration-init*.sh）の共通部品
# ==============================================================================
# tests/integration/lib.sh（ハーネス）を、読み込んだあとで、source する。
# 標準の入力（1 層）・sf-init の実行・完了後の状態の取得・秘密の漏れの検査・シグナルで止める実行、を提供する。
# ==============================================================================


PAT_MARK="ghp_ITPATMARK1234567890abcdefghijklmnopq"
SLACK_MARK="xoxb-ITSLACKMARK-9876543210"
CHAN="C0ITCHANNEL"

# 標準の入力（1 層）: 警告 Y・プロジェクト確認 Y・配布版 1・層 3（= 1 層）・PAT・（空）・Slack・チャンネル・（空）・ログイン先 1
FULL_INPUT="Y\nY\n1\n3\n${PAT_MARK}\n\n${SLACK_MARK}\n${CHAN}\n\n1\n"
# 再開の入力: 警告 Y・「続きをやる」1。続く質問のための入力は、停止点ごとに、足す
RESUME_HEAD="Y\n1\n"

_init() {   # 入力 [追加の引数]  → IT_RC・IT_OUT（作業フォルダは、$IT_WORK/proj）
    local inp="$1"; shift
    mkdir -p "$IT_WORK/proj"
    it_run "$IT_WORK/proj" -i "$inp" bash "$IT_HOME/sf-tools/bin/sf-init.sh" --owner "$IT_OWNER" --project "$IT_PROJECT" "$@"
}
_admin() { echo "$IT_WORK/proj/admin/$IT_REPO"; }
_progress() { sed -n 's/^SF_INIT_DONE_PHASE=//p' "$IT_WORK/proj/admin/.sf-init-${IT_PROJECT}.progress" 2>/dev/null; }
_names() { ls "$IT_STATE/$1" 2>/dev/null | sort | tr '\n' ','; }

# 完了後の状態を、1 行にする（基準と比べる）
_state() {
    local refs ruleset_n main_n
    refs=$(it_remote_snap | awk '{print $1}' | sed 's|refs/heads/||' | sort | tr '\n' ',')
    ruleset_n=$(ls "$IT_STATE/rulesets" 2>/dev/null | wc -l | tr -d ' ')
    main_n=$(it_remote_count main)
    echo "refs=${refs} main_commits=${main_n} secrets=$(_names secrets) variables=$(_names variables) rulesets=${ruleset_n} complete=$(_it_git -C "$(_admin)" config sf-tools.setup-complete 2>/dev/null)"
}

# 秘密の目印が、利用者に見える場所（出力・ログ・一時ファイル）に、残っていないこと。引数: 目印 説明
_leaks() { grep -rlF -- "$1" "$IT_ROOT"/out.*.txt "$IT_ROOT/tmp" $(find "$IT_ROOT" -type d -name logs -not -path "*/.git/*" 2>/dev/null) 2>/dev/null; }
_no_leak() {
    local l; l=$(_leaks "$1")
    [[ -z "$l" ]] && pass "X7-1: ${2} に、Token が残らない" || fail "X7-1: ${2} に、Token が残らない" "残っている場所: $(echo "$l" | head -3 | tr '\n' ' ')"
}

# 状態ファイル（.sf-init-XXXX.env）の PAT: Phase 8 の push が終わるまでは、権限 600 の状態ファイルにだけ置く設計。push 後は、消える
_pat_in_state() { grep -qF -- "$PAT_MARK" "$IT_WORK/proj/admin/.sf-init-${IT_PROJECT}.env" 2>/dev/null; }
_state_mode_600() { case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac   # Windows（NTFS）では、権限（600）を、確認できない（確認しない）
    local m; m=$(ls -l "$IT_WORK/proj/admin/.sf-init-${IT_PROJECT}.env" 2>/dev/null | cut -c1-10); [[ "$m" == "-rw-------" ]]; }

_fresh() { it_teardown; it_setup || return 1; }

# sf-init をバックグラウンドで起動し、指定の fake の呼び出しが始まったら、シグナルで止める。引数: 入力 呼び出しの目印（calls.log の語）シグナル
_init_kill() {
    local inp="$1" mark="$2" sig="$3" pid i
    mkdir -p "$IT_WORK/proj"
    printf '%b' "$inp" > "$IT_ROOT/kill.in"
    (
        cd "$IT_WORK/proj" || exit 99
        export HOME="$IT_HOME" PATH="$IT_BIN:$PATH" IT_STATE IT_ORIGIN SF_LAUNCHER_ACTIVE=1 SF_TOOLS_SF_CHECK_STAMP=/dev/null
        export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_SSH_COMMAND="$IT_BIN/ssh" TMPDIR="$IT_ROOT/tmp"
        unset GITHUB_ACTIONS CI GH_TOKEN GITHUB_TOKEN
        mkdir -p "$TMPDIR"
        exec bash "$IT_HOME/sf-tools/bin/sf-init.sh" --owner "$IT_OWNER" --project "$IT_PROJECT" < "$IT_ROOT/kill.in" > "$IT_ROOT/kill.out" 2>&1
    ) &
    pid=$!
    for i in $(seq 1 600); do
        grep -qF "$mark" "$IT_STATE/calls.log" 2>/dev/null && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done
    sleep 1
    kill "-$sig" "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    IT_KILL_RC=$?
    IT_OUT="$IT_ROOT/kill.out"
}

# 途中で止まった状態（Phase 8 の push が拒否された状態: 進捗は Phase 7 まで）を、新しいサンドボックスに作る。結果: IT_RC は、止まった実行のもの
mk_interrupted() {
    _fresh || return 1; IT_TIMEOUT=240
    git init -q --bare -b main "$IT_ORIGIN"; it_origin_reject on   # 空の bare を先に作り、push を拒否させる
    _init "$FULL_INPUT"
    it_origin_reject off
}
