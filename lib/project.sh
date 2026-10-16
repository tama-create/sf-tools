#!/bin/bash
# ==============================================================================
# project.sh - プロジェクト（force-*・GitHub・組織・ブランチ）に関する関数
# ==============================================================================
# lib/common.sh から source される（呼び出し側は、common.sh だけを source すればよい。単独では、source しない）。
# common.sh の変数・関数（log / run / die / RET_* / 色の定義 など）を、使う。
#
# 【提供する関数】
#   get_target_org [ALIAS]    ... 接続先組織エイリアスを解決
#   check_force_dir           ... force-* ディレクトリ内か確認
#   resolve_init_identity     ... sf-init 用: オーナーとプロジェクト名（XXXX）を、引数・対話で決める
#   resolve_job_identity O P  ... sf-job 用: 同上（引数・カレントの下のクローンの git remote・対話）
#   parse_github_remote URL   ... GitHub の URL から「owner repo」を取り出す（HTTPS / SSH）
#   normalize_project_name X  ... 入力から XXXX（force- の後ろ）を取り出す（force- が付いていれば除く。不正なら戻り値 1）
#   discover_clones DIR       ... DIR/*/force-*/ のクローンの git remote から「owner repo」を取り出す
#   gh_owner_candidates MODE  ... gh のログインから、オーナーの候補を出す（MODE: admin / member）
#   check_gh_owner OWNER      ... gh 認証ユーザーが期待するオーナーと一致するか確認（組織の有効な admin も許可）
#   get_branch_list           ... branches.txt からブランチ一覧を取得
#   is_reserved_org_alias     ... 共有環境の組織エイリアス（sf-tools の予約名）か判定
#   is_protected_branch       ... 指定ブランチが branches.txt の保護対象か判定
#   ensure_sf_tools_latest    ... sf-tools（Git リポジトリ）が origin の最新であることを確認
#   clone_matches_repo DIR O R ... DIR が Git のクローンで、origin が GitHub の O/R か（完了済みのプロジェクトの判定に使う）
#   ensure_admin_branch DIR   ... 管理者用のクローンを、admin ブランチ（ローカル）にする（main の上で、作業しないため）
#   push_admin_branch DIR     ... admin ブランチを、GitHub にも作る（git push -u origin admin。強制 push はしない）
#   merge_package_xml OUT IN... ... package.xml 形式のマニフェストを 1 つに統合する（種類ごとに、メンバーを重複なく並べる）
# ==============================================================================

# merge_package_xml - package.xml 形式のマニフェストを、1 つに統合する
# ------------------------------------------------------------------------------
# 【使い方】 merge_package_xml OUT IN1 [IN2 ...]
# 【理由】   `sf project generate manifest` は、--source-dir と --metadata を同時に渡すと、両方の「共通部分」だけを返す
#           （重なりがなければ、<types> が 1 つもない空のマニフェストになる。しかも、成功として終わる）。
#           そのため、sf-release.sh は、[files] と [members] を、別々に生成して、ここで統合する。
# 【動作】   各入力の <types> を読み、種類 → メンバーの順に、重複を除いて並べる。<version> は、最初に見つかったもの。
#           awk と sort だけで動く（GNU / BSD 共通。追加の依存なし）
# 【戻り値】 0 = 出力した（メンバーが 1 つもなくても、空のマニフェストを出力する。判定は、呼び出し側）
# ------------------------------------------------------------------------------
merge_package_xml() {
    local out="$1" f ver
    shift
    ver=$(grep -h -o '<version>[^<]*</version>' "$@" 2>/dev/null | head -n 1)  # VAR=$(cmd) のため run 不使用
    [[ -n "$ver" ]] || ver="<version>64.0</version>"
    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<Package xmlns="http://soap.sforce.com/2006/04/metadata">'
        for f in "$@"; do
            awk '
                /<members>/ { s = $0; sub(/^[[:space:]]*<members>/, "", s); sub(/<\/members>[[:space:]]*$/, "", s); m[n++] = s }
                /<name>/    { t = $0; sub(/^[[:space:]]*<name>/, "", t); sub(/<\/name>[[:space:]]*$/, "", t)
                              for (i = 0; i < n; i++) printf "%s\t%s\n", t, m[i]
                              n = 0 }
            ' "$f"
        done | sort -u | awk -F'\t' '
            {
                if ($1 != cur) {
                    if (cur != "") { printf "        <name>%s</name>\n    </types>\n", cur }
                    print "    <types>"
                    cur = $1
                }
                printf "        <members>%s</members>\n", $2
            }
            END { if (cur != "") { printf "        <name>%s</name>\n    </types>\n", cur } }
        '
        printf '    %s\n' "$ver"
        printf '%s\n' '</Package>'
    } > "$out"
}

# get_target_org - 接続先組織エイリアスを解決して echo する
# ------------------------------------------------------------------------------
# 【使い方】
#   TARGET=$(get_target_org [ALIAS]) || die "組織を特定できません。"
#
# 【解決の優先順位】
#   1. 引数 ALIAS（明示指定）
#   2. 環境変数 SF_TARGET_ORG（GitHub Actions の secrets 等）
#   3. ローカル接続情報（sf org display の出力）
#
# 【戻り値】
#   RET_OK (0) : エイリアスを echo して正常終了
#   RET_NG (1) : どこからも特定できなかった場合
#
# 【使用例】
#   TARGET_ORG=$(get_target_org "$OPT_TARGET") || die "接続先を特定できません。"
#   TARGET_ORG=$(get_target_org)               || die "接続先を特定できません。"
# ------------------------------------------------------------------------------
get_target_org() {
    local target="$1"
    [[ -z "$target" ]] && target="$SF_TARGET_ORG"
    if [[ -z "$target" ]]; then
        local current_alias disp_json
        disp_json=$(run sf org display --json || echo "")  # VAR=$(cmd) のため run 不使用（出力の取得）
        current_alias=$(json_get "$disp_json" result.alias)  # VAR=$(cmd) のため run 不使用（値の抽出のみ）
        [[ -n "$current_alias" && "$current_alias" != "null" ]] && target="$current_alias"
    fi
    [[ -z "$target" ]] && return $RET_NG
    echo "$target"
    return $RET_OK
}

# check_force_dir - カレントディレクトリが force-* であるか確認する
# ------------------------------------------------------------------------------
# 【使い方】
#   check_force_dir || die "force-* ディレクトリ内で実行してください。"
#
# 【戻り値】
#   RET_OK (0) : カレントディレクトリ名が force- で始まる
#   RET_NG (1) : それ以外
# ------------------------------------------------------------------------------
check_force_dir() {
    [[ "$(basename "$PWD")" =~ ^force- ]] && return $RET_OK
    return $RET_NG
}

# check_gh_owner - gh 認証ユーザーがリポジトリオーナーと一致するか確認する
# ------------------------------------------------------------------------------
# 【使い方】
#   check_gh_owner "$GITHUB_OWNER"          # 失敗時は die で終了
#   check_gh_owner "${REPO_FULL_NAME%%/*}"  # OWNER/REPO 形式からオーナーを抽出して渡す
#
# 【検証内容】
#   - gh api user でログイン中のユーザー名を取得
#   - 期待するオーナーと一致すれば通過
#   - 一致しない場合、オーナーが組織で認証ユーザーがその組織の有効な管理者（admin かつ active）なら通過
#   - 上記以外は die（組織 API が失敗した場合も通過させない）
#   - gh コマンドが使えない場合（ユーザー名が空）はチェックをスキップ（ネットワーク障害等への配慮）
# ------------------------------------------------------------------------------
check_gh_owner() {
    local expected_owner="$1"
    local gh_user org_status
    gh_user=$(gh api user --jq '.login' 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
    [[ -z "$gh_user" || "$gh_user" == "$expected_owner" ]] && return $RET_OK
    # 不一致: オーナーが組織なら、認証ユーザーがその組織の有効な管理者かを確認する
    org_status=$(gh api "user/memberships/orgs/${expected_owner}" --jq '.role + " " + .state' 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
    if [[ "$org_status" == "admin active" ]]; then
        log "INFO" "gh の認証ユーザー（${gh_user}）は組織 ${expected_owner} の管理者です。続行します。"
        return $RET_OK
    fi
    die "gh の認証ユーザー（${gh_user}）がリポジトリオーナー（${expected_owner}）と一致せず、組織の管理者（admin）でもありません。"
}

# ------------------------------------------------------------------------------
# プロジェクトの特定（オーナーと、プロジェクト名 XXXX。リポジトリ名は force-XXXX）
# ------------------------------------------------------------------------------
# リポジトリ名は「force-」（固定）+ XXXX（任意。管理者が決める）。sf-init.sh と sf-job.sh は、どのリポジトリかを、
# フォルダ構成に頼らず（作業フォルダは、どこでもよい）、次の順で決める（上にあるものが優先）:
#   1. 引数（--owner / --project）
#   2. sf-job のみ: カレントの下にある、クローンの git remote（実際の設定から取るため、フォルダ名に依存しない）
#   3. 対話（オーナー: gh のログインから候補 / XXXX: 入力）
# 結果は、グローバル変数 GITHUB_OWNER / COMPANY_NAME（XXXX）にセットする。

# parse_github_remote - GitHub の URL から「owner repo」（空白区切り）を取り出す
#   対応: https://github.com/o/r(.git) / https://user@github.com/o/r / git@github.com:o/r(.git) / ssh://git@github.com/o/r
#   戻り値: 0 = 取り出した / 1 = GitHub の URL ではない・形が違う
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

# normalize_project_name - 入力から XXXX（リポジトリ名 force-XXXX の、force- の後ろ）を取り出す
#   前後の空白を除き、先頭の「force-」（大文字小文字を問わない）が付いていれば除く（force-force-XXXX を防ぐ）。
#   使える文字: 英数字・ハイフン・アンダースコア・ピリオド（先頭は英数字・61 文字まで・.. や末尾の . / .git は不可）
#   戻り値: 0 = 出力した / 1 = 不正
normalize_project_name() {
    local n="$1"
    n="${n#"${n%%[![:space:]]*}"}"
    n="${n%"${n##*[![:space:]]}"}"
    case "$n" in [Ff][Oo][Rr][Cc][Ee]-*) n="${n:6}" ;; esac
    [[ "$n" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,60}$ ]] || return 1
    case "$n" in *..*|*.|*.git) return 1 ;; esac
    echo "$n"
}

# discover_clones - DIR/*/force-*/ のクローン（作業単位のフォルダの中の force-xxx）の git remote から「owner repo」を出す
#   フォルダ名ではなく、クローンに記録された住所（git clone のときに、Git が書き込む）から読む。
#   force- で始まる GitHub のリポジトリだけを対象にする（無関係なリポジトリは、無視する）。重複は除く
discover_clones() {
    local d u parsed
    for d in "$1"/*/force-*; do
        [[ -e "$d/.git" ]] || continue
        u=$(git -C "$d" remote get-url origin 2>/dev/null) || continue  # VAR=$(cmd) のため run 不使用
        parsed=$(parse_github_remote "$u") || continue
        case "${parsed##* }" in force-?*) echo "$parsed" ;; esac
    done | sort -u
}

# gh_owner_candidates - gh のログインから、オーナーの候補を 1 行ずつ出す（組織 → 自分のアカウント。重複なし）
#   引数: admin = 自分が管理者の組織（sf-init 用） / member = 自分が所属する組織（sf-job 用）
#   gh が使えない・未認証なら、何も出さない（呼び出し側が、入力に切り替える）
gh_owner_candidates() {
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
gh_existing_projects() {
    gh repo list "$1" --limit 200 --json name --jq '.[].name | select(startswith("force-")) | sub("^force-";"")' 2>/dev/null
    return 0
}

# _pick_from_list VAR 見出し 項目... - 番号で選ばせて、選んだ項目を VAR に入れる（q で中断）
_pick_from_list() {
    local _pl_var="$1" _pl_title="$2" _pl_n _pl_i=1 _pl_item _pl_ans
    shift 2
    _pl_n=$#
    echo "  ${_pl_title}" >&2
    for _pl_item in "$@"; do
        echo "    ${_pl_i}. ${_pl_item}" >&2
        _pl_i=$(( _pl_i + 1 ))
    done
    while true; do
        read_or_quit _pl_ans "  番号を入力してください（q で中断）: "
        if [[ "$_pl_ans" =~ ^[0-9]+$ ]] && [[ "$_pl_ans" -ge 1 && "$_pl_ans" -le $_pl_n ]]; then
            set_var "$_pl_var" "${!_pl_ans}"
            return 0
        fi
        log "WARNING" "  1〜${_pl_n} の番号を入力してください。"
    done
}

# 対話で、オーナーと XXXX を決める（GITHUB_OWNER / COMPANY_NAME が、すでにセットされていれば、その項目は聞かない）
#   引数: init（新しく作る。管理者）/ job（すでにあるプロジェクトを使う）
_GH_OWNER_RE='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,37}[a-zA-Z0-9])?$'
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
        printf '%s\n' "$existing" | grep -qxF -- "$norm" && exists=1
        if [[ "$mode" == "init" && $exists -eq 1 ]]; then
            if clone_matches_repo "${PWD}/admin/force-${norm}" "$GITHUB_OWNER" "force-${norm}"; then
                # この作業フォルダに、管理者用のクローンがある（セットアップ済み）: 次の画面で、状態の確認などを選べる
                log "INFO" "  ${GITHUB_OWNER}/force-${norm} は、すでに作成済みです（${PWD}/admin/force-${norm}）。次の画面で、接続の確認などを選べます。"
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

# resolve_init_identity - sf-init 用: オーナーと XXXX を決める（引数 SF_INIT_OWNER / SF_INIT_PROJECT → 対話）
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
#   引数: オーナー（空でもよい） XXXX（空でもよい）
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
    if [[ -n "$norm" ]]; then
        # XXXX は指定済み。オーナーは、指定がなければ、同じリポジトリのクローンから取る（なければ、対話）
        if [[ -z "$GITHUB_OWNER" ]]; then
            line=$(printf '%s\n' "$clones" | awk -v r="force-${norm}" '$2 == r { print $1; exit }')  # VAR=$(cmd) のため run 不使用
            GITHUB_OWNER="$line"
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

get_branch_list() {
    if [[ ! -f "$BRANCH_LIST_FILE" ]]; then
        log "WARNING" "ブランチ構成ファイルが見つかりません: ${BRANCH_LIST_FILE}（デフォルト: main のみ）"
        echo "main"
        return $RET_OK
    fi
    local branches="" line
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"                          # CR 除去（Windows 対応）
        [[ "$line" =~ ^[[:space:]]*# ]] && continue  # コメント行スキップ
        [[ -z "${line//[[:space:]]/}" ]] && continue  # 空行スキップ
        branches="${branches}${branches:+$'\n'}${line}"
    done < "$BRANCH_LIST_FILE"
    if [[ -z "$branches" ]]; then
        log "WARNING" "${BRANCH_LIST_FILE} にブランチが定義されていません。デフォルト: main のみ"
        echo "main"
        return $RET_OK
    fi
    echo "$branches"
    return $RET_OK
}

is_reserved_org_alias() {
    local alias_name="$1" reserved
    for reserved in $SF_RESERVED_ORG_ALIASES; do
        [[ "$alias_name" == "$reserved" ]] && return $RET_OK
    done
    return $RET_NG
}

# is_protected_branch - 指定ブランチが branches.txt の保護対象かを返す
# ------------------------------------------------------------------------------
# 【使い方】
#   is_protected_branch "staging" && die "直接プッシュ禁止"
#
# 【戻り値】
#   RET_OK (0) : 保護対象ブランチである
#   RET_NG (1) : 保護対象外
# ------------------------------------------------------------------------------
is_protected_branch() {
    local branch="$1"
    local branches
    branches=$(get_branch_list)
    echo "$branches" | grep -qx "$branch" && return $RET_OK
    return $RET_NG
}

# ensure_sf_tools_latest - sf-tools（Git リポジトリ）が、origin の最新であることを確認する（必須の確認）
# ------------------------------------------------------------------------------
# 【使い方】
#   ensure_sf_tools_latest [--no-update] [DIR]    # DIR は、省略時 $SF_TOOLS_DIR
#
# 【戻り値】
#   RET_OK (0) : 最新である（または、Git リポジトリでない・HEAD が分離状態・origin にブランチがない等で、
#                確認できないため、WARNING を出して続行する）
#   2          : 遅れていたため、git pull --ff-only で更新した。実行中のスクリプトが書き換わった可能性があるため、
#                呼び出し元は、再実行（exec）すること
#   （die）    : origin に接続できない・遅れているのに、ローカルに未コミットの変更または未 push のコミットがある・
#                更新を断った（N / q）・更新に失敗した・--no-update で遅れている
#
# 【動作】
#   - 古い sf-tools で、作成済みのプロジェクトのワークフローなどを書き換える事故を防ぐ。
#     「最新でなければ続行しない」ことが目的のため、origin に接続できないときは、続行せず、中断する
#   - --no-update: 確認の質問と更新をしない（読み取り専用の実行用）。遅れていれば、die
# ------------------------------------------------------------------------------
ensure_sf_tools_latest() {
    local no_update=0
    if [[ "${1:-}" == "--no-update" ]]; then no_update=1; shift; fi
    local dir="${1:-${SF_TOOLS_DIR:-}}"
    local cur dirty ahead behind line

    if [[ -z "$dir" ]] || ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then  # if cmd のため run 不使用
        log "WARNING" "sf-tools が Git リポジトリではないため、最新かどうかを確認できません。"
        return $RET_OK
    fi
    cur=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
    if [[ -z "$cur" ]]; then
        log "WARNING" "sf-tools の HEAD がブランチを指していないため、最新かどうかを確認できません。"
        return $RET_OK
    fi
    run git -C "$dir" fetch origin "$cur" \
        || die "origin に接続できないため、sf-tools が最新かどうかを確認できません。"
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
    ask_yn "▶ sf-tools を更新しますか？" || die "sf-tools が最新ではないため、続行できません。"
    run git -C "$dir" pull --ff-only origin "$cur" || die "sf-tools の更新に失敗しました。"
    log "SUCCESS" "sf-tools を更新しました。"
    return 2
}

# ensure_admin_branch - 管理者用のクローンを、admin ブランチ（ローカル）にする
# ------------------------------------------------------------------------------
# 【使い方】 ensure_admin_branch DIR
# 【理由】   管理者用のクローン（admin/force-XXXX）は、セットアップ後も、メンテナンス用に残る。main のままだと、
#           main の上で作業してしまう（main は保護ブランチ。sf-sync-wf.sh も、保護ブランチでは実行を断る）。
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
# 【用途】   セットアップが完了したプロジェクトの判定（完了時に、状態ファイルを消すため。管理者用のクローンが、ここにあり、
#           origin が同じリポジトリなら、完了済みとみなす）
# 【戻り値】 0 = 一致する / 1 = 一致しない（クローンではない・origin がない・GitHub 以外・別のリポジトリ）
clone_matches_repo() {
    local dir="${1:-}" owner="${2:-}" repo="${3:-}" url pair
    [[ -n "$dir" && -n "$owner" && -n "$repo" && -d "$dir" ]] || return 1
    url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1  # VAR=$(cmd) のため run 不使用
    pair=$(parse_github_remote "$url") || return 1                         # VAR=$(cmd) のため run 不使用
    [[ "$pair" == "${owner} ${repo}" ]]
}
