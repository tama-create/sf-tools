#!/bin/bash
# ==============================================================================
# identity.sh - プロジェクトの特定（GitHub の URL の読み取り・origin の owner/repo・オーナーと XXXX の決定・origin の URL を伏せた表示）
# ==============================================================================
# lib/project.sh が source する（呼び出し側は、今までどおり lib/common.sh を読むだけでよい。単独では、source しない）。
# 2026-11-28 に、1013 行あった lib/project.sh から、テーマごとに分けた（中身は変えずに移した）。
# 関数の一覧と使い方は、lib/project.sh の冒頭コメント（【提供する関数】）にまとめてある。
# ==============================================================================
# shellcheck disable=SC2154  # 変数は、lib/common.sh と、それを読み込むスクリプトが用意する

# ------------------------------------------------------------------------------
# プロジェクトの特定（オーナーと、プロジェクト名 XXXX。リポジトリ名は force-XXXX）
# ------------------------------------------------------------------------------
# リポジトリ名は「force-」（固定）+ XXXX（任意。管理者が決める）。sf-project.sh と sf-job.sh は、どのリポジトリかを、
# フォルダ構成に頼らず（作業フォルダは、どこでもよい）、次の順で決める（上にあるものが優先）:
#   1. 引数（--owner / --project）
#   2. sf-job のみ: カレントの下にある、クローンの git remote（実際の設定から取るため、フォルダ名に依存しない）
#   3. 対話（オーナー: gh のログインから候補 / XXXX: 入力）
# 結果は、グローバル変数 GITHUB_OWNER / COMPANY_NAME（XXXX）にセットする。

# parse_github_remote - GitHub の URL から「owner repo」（空白区切り）を取り出す
#   対応: https://github.com/o/r(.git) / https://user@github.com/o/r / http://github.com/o/r / git@github.com:o/r(.git) /
#         ssh://git@github.com/o/r（末尾の / と .git は除く）
#   戻り値: 0 = 取り出した（標準出力に「owner repo」）/ 1 = GitHub の URL ではない・形が違う（owner/repo の 2 階層でない）
parse_github_remote() {
    local u="$1" rest
    case "$u" in
        https://github.com/*|https://*@github.com/*|http://github.com/*) rest="${u#*github.com/}" ;;
        git@github.com:*)        rest="${u#git@github.com:}" ;;
        ssh://git@github.com/*)  rest="${u#ssh://git@github.com/}" ;;
        *) return 1 ;;
    esac
    rest="${rest%/}"
    rest="${rest%.git}"
    case "$rest" in
        */*/*|/*|*/|"") return 1 ;;
        */*) ;;
        *) return 1 ;;
    esac
    echo "${rest%%/*} ${rest##*/}"
}

# origin_repo - そのフォルダの origin の URL から、GitHub の「owner/repo」を取り出して、変数に入れる
#   引数: 変数名 [フォルダ（省略時はカレント）]。$( ) の中で呼ばない（変数に入れて返す。set_var）
#   戻り値: 0 = 入れた / 1 = origin がない（URL を読めない）/ 2 = GitHub のリポジトリではない・形が違う（parse_github_remote）。
#   0 以外のとき、変数は空。URL には認証情報が入っていることがあるため、URL そのものは返さない（表示は git_origin_redacted）。
#   2026-11-28 に、9 か所で同じ形に書いていた「git remote get-url origin → parse_github_remote → owner/repo」をまとめた
origin_repo() {
    local _or_url _or_pair
    set_var "$1" ""
    # フォルダの指定がないときは -C を付けない（今までの呼び出しと同じ形にする。テストの偽の git も、この形で受ける）
    if [[ -n "${2:-}" ]]; then
        _or_url=$(git -C "$2" remote get-url origin 2>/dev/null) || return 1   # VAR=$(cmd) のため run 不使用
    else
        _or_url=$(git remote get-url origin 2>/dev/null) || return 1           # VAR=$(cmd) のため run 不使用
    fi
    _or_pair=$(parse_github_remote "$_or_url") || return 2                     # VAR=$(cmd) のため run 不使用
    set_var "$1" "${_or_pair%% *}/${_or_pair##* }"
}

# require_origin_repo - origin_repo の、取り出せなければ die する版（カレントの origin）
#   引数: 変数名。メッセージは 2 種類（origin がない／GitHub のリポジトリではない。URL は *** で伏せて出す）
require_origin_repo() {
    local _ror_rc=0
    origin_repo "$1" || _ror_rc=$?
    case $_ror_rc in
        0) return 0 ;;
        1) die "git remote（origin）の URL を取得できません。" ;;
        *) die "origin が GitHub のリポジトリではありません: $(git_origin_redacted .)" ;;
    esac
}

# normalize_project_name - 入力から XXXX（リポジトリ名 force-XXXX の、force- の後ろ）を取り出す
#   前後の空白を除き、先頭の「force-」（大文字小文字を問わない）が付いていれば除く（force-force-XXXX を防ぐ）。
#   使える文字: 英数字・ハイフン・アンダースコア・ピリオド。区切り（- _ .）は、英数字の間に、1 つだけ（連続・先頭・末尾は不可）。
#   50 文字まで（force- を除いたあとの長さ）・末尾の .git は不可。
#   理由: Phase 10 の外部クライアントアプリの名前（SF_TOOLS_ + force-XXXX の区切りを _ にしたもの + _glbloauth）が、
#   Salesforce の API 名の制約（連続した _ ・末尾の _ は不可。80 文字まで）を満たすため。守らないと、セットアップの終盤で失敗する
#   戻り値: 0 = 出力した（標準出力に XXXX）/ 1 = 不正（何も出さない）
normalize_project_name() {
    local n="$1"
    n="${n#"${n%%[![:space:]]*}"}"
    n="${n%"${n##*[![:space:]]}"}"
    case "$n" in [Ff][Oo][Rr][Cc][Ee]-*) n="${n:6}" ;; esac
    [[ "${#n}" -le 50 ]] || return 1
    [[ "$n" =~ ^[A-Za-z0-9]+([._-][A-Za-z0-9]+)*$ ]] || return 1
    case "$n" in *.git) return 1 ;; esac
    echo "$n"
}

# discover_clones - DIR/*/force-*/ のクローン（作業単位のフォルダの中の force-xxx）の git remote から「owner repo」を出す
#   フォルダ名ではなく、クローンに記録された住所（git clone のときに、Git が書き込む）から読む。
#   force- で始まる GitHub のリポジトリだけを対象にする（無関係なリポジトリは、無視する）。1 行に 1 つ、LC_ALL=C の sort -u で
#   重複を除く（大文字と小文字だけが違うものは、別の行のまま。呼び出し側が、区別せずに扱う）
discover_clones() {
    local d parsed
    for d in "$1"/*/force-*; do
        [[ -e "$d/.git" ]] || continue
        origin_repo parsed "$d" || continue   # origin がない・GitHub 以外は、飛ばす
        case "${parsed#*/}" in force-?*) echo "${parsed%%/*} ${parsed#*/}" ;; esac   # 出力は「owner repo」（空白区切り）
    done | LC_ALL=C sort -u  # run 不使用: 出力を、そのまま一覧として返す（パイプの部品）
}

# gh_owner_candidates - gh のログインから、オーナーの候補を 1 行ずつ出す（組織 → 自分のアカウント。重複なし）
#   引数: admin = 自分が管理者（admin かつ active）の組織（sf-project 用） / member = 自分が所属する組織（sf-job 用。省略時）
#   gh が使えない・未認証なら、何も出さない（呼び出し側が、入力に切り替える）。戻り値は、常に 0
gh_owner_candidates() {
    # run 不使用: 出力を、そのまま候補の一覧にする（gh の失敗は、何も出さない扱い）
    {
        if [[ "${1:-member}" == "admin" ]]; then
            gh api user/memberships/orgs --jq '.[] | select(.role=="admin" and .state=="active") | .organization.login' 2>/dev/null
        else
            gh api user/orgs --jq '.[].login' 2>/dev/null
        fi
        gh api user --jq .login 2>/dev/null
    } | awk 'NF && !seen[$0]++'
    return 0
}

# gh_existing_projects - そのオーナーにある force-* リポジトリの、XXXX（force- を除いた名前）を 1 行ずつ出す
#   引数: オーナー。gh repo list の最大 200 件から探す。gh が使えなければ、何も出さない。戻り値は、常に 0
#   run 不使用: 出力を、そのまま一覧にする（gh の失敗は、何も出さない扱い）
gh_existing_projects() {
    gh repo list "$1" --limit 200 --json name --jq '.[].name | select(startswith("force-")) | sub("^force-";"")' 2>/dev/null
    return 0
}

# _pick_from_list VAR 見出し 項目... - 番号で選ばせて、選んだ項目を VAR に入れる（q で中断 = die）
#   一覧は標準エラーに出す。範囲外・数字以外（9 桁を超える数字を含む）は、WARNING を出して再入力。
#   番号は 10 進数として読む（先頭に 0 があっても、8 進数として扱わない。08・09 も、8・9 として受け付ける）
_pick_from_list() {
    local _pl_var="$1" _pl_title="$2" _pl_n _pl_i=1 _pl_item _pl_ans _pl_num
    shift 2
    _pl_n=$#
    echo "  ${_pl_title}" >&2
    for _pl_item in "$@"; do
        echo "    ${_pl_i}. ${_pl_item}" >&2
        _pl_i=$(( _pl_i + 1 ))
    done
    while true; do
        read_or_quit _pl_ans "  番号を入力してください（q で中断）: "
        if [[ "$_pl_ans" =~ ^[0-9]{1,9}$ ]]; then
            _pl_num=$(( 10#$_pl_ans ))   # 10# = 10 進数（[[ -ge ]] は、08 を 8 進数として読み、エラーになるため）
            if [[ $_pl_num -ge 1 && $_pl_num -le $_pl_n ]]; then
                set_var "$_pl_var" "${!_pl_num}"
                return 0
            fi
        fi
        log "WARNING" "  1〜${_pl_n} の番号を入力してください。"
    done
}

# _GH_OWNER_RE - GitHub のオーナー名の形式（英数字とハイフン。先頭・末尾は英数字。39 文字まで）
_GH_OWNER_RE='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,37}[a-zA-Z0-9])?$'
# prompt_project_identity - 対話で、オーナーと XXXX を決める（GITHUB_OWNER / COMPANY_NAME が、すでにセットされていれば、その項目は聞かない）
#   引数: init（新しく作る。管理者）/ job（すでにあるプロジェクトを使う）
#   オーナー: gh のログインからの候補が 0 件なら入力、1 件ならそれを使う、複数なら番号で選ぶ
#   XXXX: 入力 → 確認（Y/N。N なら入力し直し）。init で、すでにあるリポジトリ名は断る（ただし、カレントの admin/ に、同じリポジトリの
#         管理者用のクローン、または状態ファイル .sf-init-XXXX.env があれば、確認なしで受け付ける）
#   結果: GITHUB_OWNER / COMPANY_NAME
prompt_project_identity() {
    local mode="$1" cands c raw norm existing exists
    local list=()
    if [[ -z "${GITHUB_OWNER:-}" ]]; then
        if [[ "$mode" == "init" ]]; then cands=$(gh_owner_candidates admin); else cands=$(gh_owner_candidates member); fi  # VAR=$(cmd) のため run 不使用
        while IFS= read -r c; do [[ -n "$c" ]] && list+=("$c"); done <<< "$cands"
        case ${#list[@]} in
            0)
                while true; do
                    read_or_quit GITHUB_OWNER "  GitHub のオーナー（組織名またはユーザー名）を入力してください: "
                    [[ "$GITHUB_OWNER" =~ $_GH_OWNER_RE ]] && break
                    log "WARNING" "  オーナー名が正しくありません（英数字とハイフンのみ）。"
                done ;;
            1)
                GITHUB_OWNER="${list[0]}"
                log "INFO" "  GitHub のオーナー: ${GITHUB_OWNER}（gh のログインから取得）" ;;
            *)
                _pick_from_list GITHUB_OWNER "GitHub のオーナーを選んでください:" "${list[@]}" ;;
        esac
    fi
    [[ -n "${COMPANY_NAME:-}" ]] && return 0

    existing=$(gh_existing_projects "$GITHUB_OWNER")  # VAR=$(cmd) のため run 不使用
    echo "" >&2
    if [[ "$mode" == "init" ]]; then
        echo "  リポジトリ名は「force-XXXX」の形です。" >&2
    else
        echo "  対象のリポジトリ名は「force-XXXX」の形です。" >&2
    fi
    echo "  「force-」は自動で付きます。XXXX の部分だけを入力してください。" >&2
    echo "     例: acme と入力 → force-acme" >&2
    if [[ -n "$existing" ]]; then
        echo "" >&2
        echo "  ${GITHUB_OWNER} に、すでにあるプロジェクト（XXXX）:" >&2
        echo "     $(printf '%s' "$existing" | tr '\n' '/' | sed 's#/$##; s#/# / #g')" >&2
    fi
    echo "" >&2
    while true; do
        read_or_quit raw "  XXXX（force- の後ろ）を入力してください: "
        norm=$(normalize_project_name "$raw") || {
            log "WARNING" "  使えない名前です。英数字・ハイフン・アンダースコア・ピリオドだけを使ってください（先頭は英数字）。"
            continue
        }
        [[ "$norm" != "$raw" ]] && log "INFO" "  force- は自動で付くため、「${norm}」として扱います。"
        exists=0
        printf '%s\n' "$existing" | grep -qixF -- "$norm" && exists=1   # 大文字と小文字は、区別しない（GitHub は、区別しない）
        if [[ "$mode" == "init" && $exists -eq 1 ]]; then
            if clone_matches_repo "${PWD}/admin/force-${norm}" "$GITHUB_OWNER" "force-${norm}" \
               || state_matches_repo "${PWD}/admin/.sf-init-${norm}.env" "$GITHUB_OWNER" "force-${norm}"; then
                # この作業フォルダに、同じリポジトリの管理者用のクローン、または、途中の状態がある: 断らずに、受け付ける
                #   （次の画面で、完了済みの案内・続きをやる、のどちらかが出る）
                log "INFO" "  ${GITHUB_OWNER}/force-${norm} の作業フォルダが、すでにあります（${PWD}/admin）。状態に応じて、次の画面に進みます。"
                COMPANY_NAME="$norm"
                return 0
            fi
            log "WARNING" "  ${GITHUB_OWNER}/force-${norm} は、すでに存在します。別の名前を入力してください。"
            continue
        fi
        echo "" >&2
        echo "  XXXX = ${norm}" >&2
        if [[ "$mode" == "init" ]]; then
            echo "  → 作るリポジトリ         : ${GITHUB_OWNER}/force-${norm}" >&2
            echo "  → 管理者用の作業フォルダ : ${PWD}/admin/force-${norm}" >&2
        else
            echo "  → 対象のリポジトリ       : ${GITHUB_OWNER}/force-${norm}" >&2
        fi
        if ask_yn "  これでよいですか？"; then break; fi
    done
    COMPANY_NAME="$norm"
}

# resolve_init_identity - sf-project 用: オーナーと XXXX を決める（環境変数 SF_INIT_OWNER / SF_INIT_PROJECT → 対話）
#   SF_INIT_OWNER / SF_INIT_PROJECT は、sf-project.sh が --owner / --project から export する。関数の引数は、取らない。
#   値が不正なら die。どちらかが空なら、prompt_project_identity init で、空の項目を対話で決める
#   結果: GITHUB_OWNER / COMPANY_NAME
#   決めた値は SF_INIT_OWNER / SF_INIT_PROJECT に export する（sf-tools を更新して、実行しなおすときと、Phase 2 が使う）
resolve_init_identity() {
    local a_owner="${SF_INIT_OWNER:-}" a_project="${SF_INIT_PROJECT:-}" norm=""
    if [[ -n "$a_project" ]]; then
        norm=$(normalize_project_name "$a_project") \
            || die "プロジェクト名（force-XXXX の XXXX）が正しくありません: ${a_project}
  英数字・ハイフン・アンダースコア・ピリオドだけを使えます（先頭は英数字）。force- は、自動で付きます。"
        [[ "$norm" != "$a_project" ]] && log "INFO" "force- は自動で付くため、「${norm}」として扱います。"
    fi
    if [[ -n "$a_owner" && ! "$a_owner" =~ $_GH_OWNER_RE ]]; then
        die "GitHub のオーナー名が正しくありません: ${a_owner}（英数字とハイフンのみ）"
    fi
    GITHUB_OWNER="$a_owner"
    COMPANY_NAME="$norm"
    if [[ -z "$GITHUB_OWNER" || -z "$COMPANY_NAME" ]]; then
        prompt_project_identity init
    fi
    export SF_INIT_OWNER="$GITHUB_OWNER" SF_INIT_PROJECT="$COMPANY_NAME"
    return 0
}

# resolve_job_identity - sf-job 用: オーナーと XXXX を決める（引数 → カレントの下のクローン → 対話）
#   引数: オーナー（空でもよい） XXXX（空でもよい）。値が不正なら die
#   クローンは、discover_clones "$PWD"（オーナーの指定があれば、そのオーナーのものだけ）から探す:
#     XXXX の指定あり: オーナーの指定がなければ、同じ force-XXXX のクローン（大文字と小文字は区別しない）のオーナー
#                      （複数なら選ばせる）。クローンから決めたときは、XXXX も、クローンの綴り（大文字と小文字）にそろえる。
#                      なければ対話
#     XXXX の指定なし: クローンが 1 つならそれ、複数なら選ばせる、0 なら対話
#   結果: GITHUB_OWNER / COMPANY_NAME
resolve_job_identity() {
    local a_owner="${1:-}" a_project="${2:-}" norm="" clones line n
    local list=()
    if [[ -n "$a_project" ]]; then
        norm=$(normalize_project_name "$a_project") \
            || die "プロジェクト名（force-XXXX の XXXX）が正しくありません: ${a_project}
  英数字・ハイフン・アンダースコア・ピリオドだけを使えます（先頭は英数字）。force- は、自動で付きます。"
        [[ "$norm" != "$a_project" ]] && log "INFO" "force- は自動で付くため、「${norm}」として扱います。"
    fi
    if [[ -n "$a_owner" && ! "$a_owner" =~ $_GH_OWNER_RE ]]; then
        die "GitHub のオーナー名が正しくありません: ${a_owner}（英数字とハイフンのみ）"
    fi
    GITHUB_OWNER="$a_owner"
    COMPANY_NAME="$norm"
    clones=$(discover_clones "$PWD")  # VAR=$(cmd) のため run 不使用
    if [[ -n "$a_owner" ]]; then
        # --owner の指定があれば、そのオーナーのクローンだけを対象にする（大文字と小文字は区別しない）
        clones=$(printf '%s\n' "$clones" | awk -v o="$a_owner" 'tolower($1) == tolower(o)')  # VAR=$(cmd) のため run 不使用
    fi
    if [[ -n "$norm" ]]; then
        # XXXX は指定済み。オーナーは、指定がなければ、同じリポジトリのクローンから取る（なければ、対話）
        if [[ -z "$GITHUB_OWNER" ]]; then
            # 同じ XXXX のクローンが、複数のオーナーにあるときは、最初のものを、黙って使わず、選ばせる（別のオーナーの同名の
            #   リポジトリを、操作してしまわないため）。force-XXXX との一致も、オーナーの重複の除去も、大文字と小文字を区別しない
            #   （GitHub は、区別しない）。一致したクローンの「オーナー リポジトリ名」を、そのままの綴りで使う
            local pairs=() _p
            while IFS= read -r _p; do [[ -n "$_p" ]] && pairs+=("$_p"); done < <(printf '%s\n' "$clones" | awk -v r="force-${norm}" 'tolower($2) == tolower(r) && !seen[tolower($1)]++ { print $1 "/" $2 }')
            case ${#pairs[@]} in
                0) _p="" ;;
                1) _p="${pairs[0]}" ;;
                *) _p=""
                   _pick_from_list _p "どのオーナーの force-${norm} ですか？（このフォルダの下に、同じ名前で、複数のオーナーのクローンがあります）" "${pairs[@]}" ;;
            esac
            if [[ -n "$_p" ]]; then
                GITHUB_OWNER="${_p%%/*}"
                COMPANY_NAME="${_p##*/}"; COMPANY_NAME="${COMPANY_NAME#force-}"
            fi
        fi
        [[ -z "$GITHUB_OWNER" ]] && prompt_project_identity job
        return 0
    fi
    while IFS= read -r line; do [[ -n "$line" ]] && list+=("$line"); done <<< "$clones"
    n=${#list[@]}
    case $n in
        0)
            log "INFO" "このフォルダの下に、force-* のクローンが見つかりません。プロジェクトを指定してください。"
            prompt_project_identity job ;;
        1)
            GITHUB_OWNER="${list[0]%% *}"
            COMPANY_NAME="${list[0]##* }"; COMPANY_NAME="${COMPANY_NAME#force-}"
            log "INFO" "プロジェクト: ${GITHUB_OWNER}/force-${COMPANY_NAME}（このフォルダの下のクローンから取得）" ;;
        *)
            local labels=() i=0 pick=""
            while [[ $i -lt $n ]]; do labels+=("${list[$i]%% *}/${list[$i]##* }"); i=$(( i + 1 )); done
            _pick_from_list pick "どのプロジェクトですか？（このフォルダの下に、複数あります）" "${labels[@]}"
            GITHUB_OWNER="${pick%%/*}"
            COMPANY_NAME="${pick##*/}"; COMPANY_NAME="${COMPANY_NAME#force-}" ;;
    esac
    return 0
}

# git_origin_redacted - クローンの origin の URL を、認証情報（https://user:TOKEN@ の部分）を伏せて、標準出力に返す
#   エラーの文言・ログに、origin の URL を出すときに使う（Token つきの URL で作ったクローンが、画面とログに、Token を出さないため）。
#   引数: クローンのフォルダ（省略時はカレント）。「//」と「@」の間を *** にする。末尾に改行は付けない。
#   origin がなければ「なし」。戻り値は、常に 0
git_origin_redacted() {
    local u
    u=$(git -C "${1:-.}" remote get-url origin 2>/dev/null) || { printf '%s' "なし"; return 0; }  # VAR=$(cmd) のため run 不使用
    printf '%s' "$u" | sed 's#//[^@/]*@#//***@#'
}
