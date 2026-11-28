#!/bin/bash
# ==============================================================================
# sf-next.sh - 次のPR先ブランチを確認するスクリプト
# ==============================================================================
# 現在のブランチ（の先端のコミット）が、どの段階（develop → staging → main）まで出たかを確かめ、次に PR を出してよい段階を
# 表示する。確認（Y/N/q）のうえ、PR の作成画面をブラウザで開く（PR そのものは作らない）。--create を付けたときは、
# ブラウザを開かずに、gh pr create で PR を作る（会話で AI が動かすとき。doc/ai-operation-design.md 11.2）。
# 判断は、一方通行のリリースの確認 sf-promote-check.sh --plan（doc/one-way-promotion-design.md 3.6）に任せる（ここでは計算しない）。
# 開発物は一方通行で、同じコミットのまま develop → staging → main と上げる。develop に出したあとに変えた（push した）ら、
# 次の出し先は develop に戻る（staging を勧めない）。
#
# 【使い方】
#   bash ~/sf-tools/bin/sf-next.sh [オプション]
#   bash ~/sf-tools/bin/sf-next.sh --create --title <題名> --body-file <ファイル>
#   bash ~/sf-tools/bin/sf-next.sh --status    # 判定して next-status.txt を書くだけ（ランチャーが裏で動かす）
#
# 【オプション】
#   --create               : 確認で Y のとき、ブラウザを開かずに、gh pr create で PR を作る。--title と --body-file の両方が要る
#   --title <題名>         : PR の題名（空でない 1 行。CR・LF を含まない。長さは GitHub が確かめる）。--create のときだけ指定できる
#   --body-file <ファイル> : PR の本文のファイル（あって、読めること。中身は空でもよく、整形しない）。--create のときだけ指定できる
#   --status               : 判定だけをする。処理の流れの 2 まで（next-status.txt を書く）で終わり、結果の表示・確認・PR の作成を
#                            しない（ランチャーが、画面を出したあとに裏で動かす。phases/start/launcher.sh の処理の流れ 6）。ログは
#                            ./sf-tools/logs/sf-next-status.log（手で動かしたときの sf-next.log を上書きしない）。--create と一緒には使えない。
#                            判定の結果を書けなかったときは、エラー（終了コード 1）
#   -v, --verbose          : コマンドの応答（出力）をコンソールにも表示する
#   -h, --help             : このヘルプを表示して終了する（1 つ目の引数のときだけ）
#   上記以外の引数（2 つ目以降の -h / --help を含む）は、「不明なオプションです」と表示して中断する。
#   オプションの誤り（値がない・--create に --title か --body-file がない・--create なしの --title / --body-file・題名の形・
#   本文のファイルがない）は、処理の流れの 1 より前に中断する（判定・通信をしない）
#
# 【処理の流れ】
#   1. 現在のブランチを取得する。取得できない（detached HEAD など）とき・保護ブランチ（branches.txt のブランチ。
#      ファイルがない・空のときは main）の上にいるときは、エラーで終了する
#   2. sf-promote-check.sh --plan --json を実行する（同じ sf-tools の bin/。手元のブランチの先端のコミット H について、段階を下から
#      順に見て、H にその段階のリリースの印（wf-release が付ける commit status）がない最初の段階を next_tier にする。
#      その段階で、積み重ねの確認（R2）もする）。結果は、最後の行の JSON から読む（node。lib/common.sh の json_get）
#      - 終了コード 2（判断できない。push していない変更がある・origin や PR の一覧が取れない・段階の構成の誤りなど）→ 理由を
#        表示して、エラーで終了する
#      - 終了コード 1（決まりを破っている。積み重ねの抜けなど）→ 理由を表示して、PR を勧めずにエラーで終了する
#      判定の前に、./sf-tools/logs/next-status.txt（前回の結果）を消す。判定できたら、そこに、先端のコミット（HEAD=）・次の段階
#      （NEXT=。全段階済みなら none）・発行中の PR（PR=）・対象が空か（SKIPPED=）・段階の一覧（TIERS=。下から順に空白区切り）を書く（ランチャーの表示用。一時ファイルに書いてから mv で置き換える。書けなくても続ける。--status のときだけエラーにする）
#   3. 結果を表示する（下の【補足】の表示）
#   4. 対象が空（deploy-target.txt・remove-target.txt に実質的な行がない）なら、その旨を表示して終了する（出すものがない）
#   5. next_tier が none なら「全段階にリリース済みです！」、next_tier へ開いている PR があれば「PR 発行中（#N）。マージを
#      待ってください」と表示して終了する
#   6. 「<next_tier> にPRを出しますか？」と確認する。next_tier が一番下の段階でないときは、前に「<1 つ前の段階> の組織で、
#      動作を確かめ終えましたか？」を付ける（印の表示だけを見て、確かめずに上の段階へ上げるのを防ぐため。確認の回数は増やさない）。
#      AI 操作では、質問の名前は next.pr（doc/ai-operation-design.md）
#        Y: ブラウザで <origin の URL>/compare/<next_tier>...<現在のブランチ>?expand=1 を開き、URL も表示する
#           （origin の URL は、http(s):// の URL に含まれる認証情報（//<ユーザー>:<Token>@ の部分）を除き、
#           git@github.com: / ssh://git@github.com/ を https://github.com/ に直し、末尾の .git を除いたもの。
#           origin の URL を取得できないときは、エラーで終了する）
#        Y（--create）: ブラウザを開かず、gh pr create --repo <OWNER/REPO> --base <next_tier> --head <現在のブランチ>
#           --title=<題名> --body-file=<ファイル> で PR を作り、作られた PR の URL を表示する（題名・ファイル名は、それぞれ
#           独立した 1 つの引数。= の形のため、題名が - で始まっても、別のオプションとして読まれない）。<OWNER/REPO> は、
#           上の直した origin の URL が https://github.com/<OWNER>/<REPO> の形（OWNER: 英数字で始まる英数字・-。REPO: 英数字・
#           . _ - で、. と .. は不可。ほかのホスト・余分なパス・? # は不可）のときだけ取る。合わない・gh pr create が失敗した
#           （理由を表示する）ときは、エラーで終了する。確かめてから作るまでの間に、同じ head・base の PR がほかで作られたときは、
#           GitHub が 2 つ目を拒むため、失敗として扱う
#        N: 何もせず終了する / q: 中断する（終了コード 1）
#
# 【前提条件】
#   - force-* ディレクトリ（プロジェクトのルート）で実行すること
#   - gh（GitHub CLI）が使えること（リリースの印・PR の一覧を読む）。git・node（npm 版の sf の前提）
#
# 【補足】
#   - 表示（段階は、下から順。<段階> は、origin/main の branches.txt の構成にあるものだけ）:
#       ✓ <段階>   リリース済み（このコミット）   : next_tier より下の段階
#       ▶ <段階>   次のPR先                       : next_tier（開いている PR がなければ）
#       → <段階>   PR発行中（#N）                 : next_tier へ開いている PR がある
#       ✗ <段階>                                  : next_tier より上の段階
#   - 表示例（develop にリリース済み / staging が次）:
#       ✓ develop   リリース済み（このコミット）
#       ▶ staging   次のPR先
#       ✗ main
#   - develop に出したあとに変更して push すると、先端のコミットが変わり、新しいコミットには印がないため、次の PR 先は develop に
#     なる（develop で確かめたものだけを上に上げる。原則どおり）
#   - 判定の本体は sf-promote-check.sh。環境変数 SF_PROMOTE_CHECK_CMD で、呼ぶコマンドを差し替えられる（テスト用。CI の強制は
#     ワークフロー側の sf-promote-check.sh が行うため、ここを差し替えても、決まりは破れない）
#   - 終了コード: 0 = 正常終了（N で終了した場合を含む） / 1 = エラー・q で中断・決まりを破っている / 20 = 確認待ち（AI 操作）
#   - ログ: ./sf-tools/logs/sf-next.log（実行のたびに作り直す。--status のときは sf-next-status.log）
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. 共通ライブラリの必須設定
# ------------------------------------------------------------------------------
SCRIPT_NAME="${0##*/}"; readonly SCRIPT_NAME="${SCRIPT_NAME%.sh}"
_log_name="$SCRIPT_NAME"
for _a in "$@"; do [[ "$_a" == "--status" ]] && _log_name="${SCRIPT_NAME}-status"; done   # 裏の判定は、別のログに書く
readonly LOG_FILE="./sf-tools/logs/${_log_name}.log"
readonly LOG_MODE="NEW"

# ------------------------------------------------------------------------------
# 2. 共通ライブラリの読み込み
# ------------------------------------------------------------------------------
SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$SCRIPT_DIR/" == /* && "$SCRIPT_DIR/" != *//* && "$SCRIPT_DIR/" != */./* && "$SCRIPT_DIR/" != */../* ]] || SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON_LIB="${SCRIPT_DIR}/../lib/common.sh"

if [[ ! -f "$COMMON_LIB" ]]; then
    echo "[FATAL ERROR] Library not found: $COMMON_LIB" >&2
    exit 1
fi
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}"  # run 不使用: common.sh の読み込み前（run が未定義）
    exit 0
fi
source "$COMMON_LIB"

# 引数の解析（処理の流れの 1 より前。誤りがあれば、判定・通信をせずに中断する）
OPT_CREATE=0
OPT_STATUS=0
OPT_TITLE=""; OPT_TITLE_SET=0
OPT_BODY_FILE=""; OPT_BODY_SET=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose) shift ;;
        --create) OPT_CREATE=1; shift ;;
        --status) OPT_STATUS=1; shift ;;
        --title)
            [[ $# -ge 2 ]] || die "--title には、PR の題名を指定してください。"
            OPT_TITLE="$2"; OPT_TITLE_SET=1; shift 2 ;;
        --body-file)
            [[ $# -ge 2 && -n "$2" ]] || die "--body-file には、PR の本文のファイルを指定してください。"
            OPT_BODY_FILE="$2"; OPT_BODY_SET=1; shift 2 ;;
        *) die "不明なオプションです: $1" ;;
    esac
done
[[ $OPT_STATUS -eq 1 && $OPT_CREATE -eq 1 ]] && die "--status は、--create と一緒には使えません。"
if [[ $OPT_CREATE -eq 1 ]]; then
    [[ $OPT_TITLE_SET -eq 1 ]] || die "--create には、--title が要ります。"
    [[ $OPT_BODY_SET -eq 1 ]] || die "--create には、--body-file が要ります。"
    # 題名: 空でない 1 行（CR・LF を含まない）。長さは数えない（GitHub が確かめ、長すぎれば gh pr create の失敗になる。
    #   ${#…} は、ロケールが C だとバイトで数え、日本語の題名を誤って弾くため）
    [[ -n "$OPT_TITLE" ]] || die "PR の題名が空です。"
    case "$OPT_TITLE" in *$'\n'*|*$'\r'*) die "PR の題名は 1 行にしてください（改行を含みます）。" ;; esac
    [[ -f "$OPT_BODY_FILE" && -r "$OPT_BODY_FILE" ]] || die "PR の本文のファイルがない、または読めません: ${OPT_BODY_FILE}"
else
    [[ $OPT_TITLE_SET -eq 0 && $OPT_BODY_SET -eq 0 ]] || die "--title・--body-file は、--create と一緒に指定してください。"
fi

# ------------------------------------------------------------------------------
# 3. 現在のブランチ
# ------------------------------------------------------------------------------
log "HEADER" "次のPR先を確認します (${SCRIPT_NAME}.sh)"

CURRENT_BRANCH=$(run git symbolic-ref --short HEAD) \
    || die "現在のブランチを取得できません。"

# 保護ブランチ（branches.txt のブランチ。例: main/staging/develop）からは実行不可
if is_protected_branch "$CURRENT_BRANCH"; then
    die "${CURRENT_BRANCH} は保護ブランチ（sf-tools/config/branches.txt）のため、実行できません。"
fi

# ------------------------------------------------------------------------------
# 4. 一方通行のリリースの確認（sf-promote-check.sh --plan）
# ------------------------------------------------------------------------------
log "INFO" "どの段階まで出たかを確かめています（sf-promote-check.sh --plan）..."
# ランチャーの表示用の、前回の判定の結果は、判定の前に消す（判定できなかったときに、古い結果が残らないように）
readonly NEXT_STATUS_FILE="./sf-tools/logs/next-status.txt"
rm -f "$NEXT_STATUS_FILE" 2>/dev/null || true   # 意図的なエラー無視（ないときも続ける）
PC_CMD="${SF_PROMOTE_CHECK_CMD:-${SCRIPT_DIR}/sf-promote-check.sh}"
PC_RC=0
# VAR=$(cmd) のため run 不使用（判定の結果の JSON を読む。表示は、標準エラーに出る）。標準入力は閉じる（確認の質問に読ませない）
PC_OUT=$(bash "$PC_CMD" --plan --json </dev/null) || PC_RC=$?
PC_JSON=$(printf '%s\n' "$PC_OUT" | tail -n 1)
_pc() { json_get "$PC_JSON" "$@" 2>/dev/null; }   # 結果の JSON から読む（読めなければ空）

case "$PC_RC" in
    0) ;;
    1)
        log "ERROR" "一方通行のリリースの決まりを破っているため、PR を勧めません:"
        while IFS= read -r _d; do [[ -n "$_d" ]] && log "ERROR" "  ${_d}"; done <<< "$(_pc 'violations.*.detail')"
        die "決まりを破っています（doc/one-way-promotion-design.md）。"
        ;;
    *)
        _err=$(_pc error)
        die "次のPR先を判断できません: ${_err:-sf-promote-check.sh の結果を読めません（終了コード ${PC_RC}）}"
        ;;
esac

NEXT_TARGET=$(_pc next_tier)
PR_OPEN=$(_pc pr_open)
SKIPPED=$(_pc skipped)
TIERS=()
while IFS= read -r _t; do [[ -n "$_t" ]] && TIERS+=("$_t"); done <<< "$(_pc 'tiers.*')"
[[ -n "$NEXT_TARGET" && ${#TIERS[@]} -gt 0 ]] || die "次のPR先を判断できません: sf-promote-check.sh の結果を読めません。"

# ランチャー（phases/start/launcher.sh）の表示のために、判定の結果を書く（Git の対象外の logs/。ランチャーは、HEAD が今の先端のコミットと
#   同じときだけ使う。書けなくても、このコマンドは続ける）
_head=$(git rev-parse -q --verify HEAD 2>/dev/null) || _head=""   # VAR=$(cmd) のため run 不使用
if [[ -n "$_head" ]]; then
    # 一時ファイルに書いてから置き換える（ランチャーの裏の判定と、前面の実行が同時に動いても、書きかけを読ませない）
    _st_tmp="${NEXT_STATUS_FILE}.$$"
    _st_ok=0
    if [[ ! -d "$NEXT_STATUS_FILE" ]] && printf 'HEAD=%s\nNEXT=%s\nPR=%s\nSKIPPED=%s\nTIERS=%s\n' "$_head" "$NEXT_TARGET" "$PR_OPEN" "$SKIPPED" "${TIERS[*]}" > "$_st_tmp" 2>/dev/null \
        && mv -f "$_st_tmp" "$NEXT_STATUS_FILE" 2>/dev/null; then   # if cmd（表示用のため、失敗しても続ける。--status のときだけ下で失敗にする。
        #   置き換え先がフォルダだと、mv はその中へ移して成功になるため、先に確かめる）
        _st_ok=1
    fi
    rm -f "$_st_tmp" 2>/dev/null || true   # 意図的なエラー無視（置き換えたあとは、もうない）
fi
if [[ $OPT_STATUS -eq 1 ]]; then
    [[ ${_st_ok:-0} -eq 1 ]] || die "判定の結果を書けませんでした: ${NEXT_STATUS_FILE}"
    log "SUCCESS" "判定の結果を書きました（${NEXT_STATUS_FILE}。次の段階: ${NEXT_TARGET}）"
    exit 0   # --status: 判定だけ（表示・確認・PR の作成はしない）
fi

# ------------------------------------------------------------------------------
# 5. 結果の表示
# ------------------------------------------------------------------------------
MAX_LEN=0
for target in "${TIERS[@]}"; do
    (( ${#target} > MAX_LEN )) && MAX_LEN=${#target}
done
pad() {
    local len="$1" s="" n
    for ((n=0; n<len; n++)); do s+=" "; done
    echo "$s"
}

echo "" >&2
echo -e "  ${CLR_INFO}${CURRENT_BRANCH} のリリース状況（先端のコミット）${CLR_RESET}" >&2
echo -e "  ${CLR_INFO}────────────────────────────${CLR_RESET}" >&2
_passed=1   # next_tier より下の段階か
for target in "${TIERS[@]}"; do
    name_pad=$(pad $(( MAX_LEN - ${#target} )))
    if [[ "$NEXT_TARGET" != "none" && "$target" == "$NEXT_TARGET" ]]; then
        _passed=0
        if [[ -n "$PR_OPEN" ]]; then
            echo -e "    ${CLR_INFO}→ ${target}${name_pad}   PR発行中（#${PR_OPEN}）${CLR_RESET}" >&2
        else
            echo -e "    ${CLR_WARNING}▶ ${target}${name_pad}   次のPR先${CLR_RESET}" >&2
        fi
    elif [[ "$_passed" -eq 1 ]]; then
        echo -e "    ${CLR_SUCCESS}✓ ${target}${name_pad}   リリース済み（このコミット）${CLR_RESET}" >&2
    else
        echo -e "    ${CLR_ERR}✗ ${target}${CLR_RESET}" >&2
    fi
done
echo "" >&2

# ------------------------------------------------------------------------------
# 6. PR 作成の確認
# ------------------------------------------------------------------------------
if [[ "$SKIPPED" == "true" ]]; then
    log "INFO" "ターゲットファイル（deploy-target.txt・remove-target.txt）に対象がないため、出すものがありません。"
    exit $RET_OK
fi
if [[ "$NEXT_TARGET" == "none" ]]; then
    log "SUCCESS" "全段階にリリース済みです！"
    exit $RET_OK
fi
if [[ -n "$PR_OPEN" ]]; then
    log "INFO" "${NEXT_TARGET} への PR（#${PR_OPEN}）が発行済みです。検証が緑になってから、マージしてください。"
    exit $RET_OK
fi

# 次の PR 先が一番下の段階でなければ、1 つ前の段階の組織で確かめたかを、同じ確認の中で聞く
CONFIRM_MSG="${NEXT_TARGET} にPRを出しますか？"
for idx in "${!TIERS[@]}"; do
    if [[ "${TIERS[$idx]}" == "$NEXT_TARGET" && $idx -gt 0 ]]; then
        CONFIRM_MSG="${TIERS[$((idx-1))]} の組織で、動作を確かめ終えましたか？ ${CONFIRM_MSG}"
        break
    fi
done

if ask_yn "$CONFIRM_MSG" next.pr; then   # next.pr: AI 操作の質問の名前（doc/ai-operation-design.md）
    # リモートリポジトリ情報を取得
    #   http(s):// の URL に含まれる認証情報（//<ユーザー>:<Token>@）は除く（Token を、画面・ログ・ブラウザの履歴に出さないため）。
    #   lib/project.sh の git_origin_redacted は *** に置き換える（表示用）ため、ブラウザで開く URL には使えない
    REPO_URL=$(git remote get-url origin 2>/dev/null \
        | sed 's#^\(https\{0,1\}://\)[^@/]*@#\1#; s|git@github\.com:|https://github.com/|; s|ssh://git@github\.com/|https://github.com/|; s|\.git$||')  # VAR=$(cmd) のため run 不使用
    [[ -n "$REPO_URL" ]] || die "origin の URL を取得できません。"
    if [[ $OPT_CREATE -eq 1 ]]; then
        # --create: gh pr create で PR を作る（doc/ai-operation-design.md 11.2）。リポジトリは、github.com の OWNER/REPO の形のときだけ
        _re='^https://github\.com/([A-Za-z0-9][A-Za-z0-9-]*)/([A-Za-z0-9._-]+)$'
        if [[ ! "$REPO_URL" =~ $_re ]] || [[ "${BASH_REMATCH[2]}" == "." || "${BASH_REMATCH[2]}" == ".." ]]; then
            die "origin が GitHub のリポジトリ（https://github.com/<OWNER>/<REPO>）の形ではないため、PR を作れません: ${REPO_URL}"
        fi
        REPO_SLUG="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        log "INFO" "PR を作ります（${REPO_SLUG}・${NEXT_TARGET} ← ${CURRENT_BRANCH}）: ${OPT_TITLE}"
        # VAR=$(cmd) のため run 不使用（作られた PR の URL・失敗の理由を読む）。題名・ファイル名は、それぞれ独立した 1 つの引数
        if PR_CREATED=$(gh pr create --repo "$REPO_SLUG" --base "$NEXT_TARGET" --head "$CURRENT_BRANCH" \
                "--title=${OPT_TITLE}" "--body-file=${OPT_BODY_FILE}" </dev/null 2>&1); then
            log "SUCCESS" "PR を作りました: $(printf '%s\n' "$PR_CREATED" | tail -n 1)"
        else
            log "ERROR" "gh pr create の出力:"
            while IFS= read -r _l; do [[ -n "$_l" ]] && log "ERROR" "  ${_l}"; done <<< "$PR_CREATED"
            die "PR を作れませんでした（gh pr create）。"
        fi
        exit $RET_OK
    fi
    PR_URL="${REPO_URL}/compare/${NEXT_TARGET}...${CURRENT_BRANCH}?expand=1"
    log "INFO" "ブラウザでPR作成画面を開きます..."
    # open_browser（lib/platform.sh）が、OS に合ったコマンドで開く（Git Bash: start / WSL: powershell / macOS: open / Linux: xdg-open）
    open_browser "$PR_URL"
    echo "  $PR_URL" >&2   # 開けなかった場合に備えて、URL も表示する
else
    log "INFO" "PR 作成をスキップしました。"
fi
