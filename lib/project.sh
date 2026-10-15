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
#   check_home_dir            ... ~/home/{owner}/{company}/ の正しい階層か確認し GITHUB_OWNER/COMPANY_NAME をセット
#   check_gh_owner OWNER      ... gh 認証ユーザーが期待するオーナーと一致するか確認（組織の有効な admin も許可）
#   get_branch_list           ... branches.txt からブランチ一覧を取得
#   is_reserved_org_alias     ... 共有環境の組織エイリアス（sf-tools の予約名）か判定
#   is_protected_branch       ... 指定ブランチが branches.txt の保護対象か判定
#   ensure_sf_tools_latest    ... sf-tools（Git リポジトリ）が origin の最新であることを確認
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

# check_home_dir - ~/home/{owner}/{company}/ の正しい階層か確認し変数をセットする
# ------------------------------------------------------------------------------
# 【使い方】
#   check_home_dir   # 失敗時は die で終了
#   # 成功時: GITHUB_OWNER / COMPANY_NAME がセットされる
#
# 【検証内容】
#   - PWD が */home/ 配下にある
#   - home/ からの深さがちょうど 2（{owner}/{company}）
#
# 【セット先変数】
#   GITHUB_OWNER  : 1つ上のフォルダ名（例: tamashimon-org）
#   COMPANY_NAME  : カレントフォルダ名（例: yamada）
# ------------------------------------------------------------------------------
check_home_dir() {
    local rest depth
    rest="${PWD#*/home/}"
    if [[ "$rest" == "$PWD" ]]; then
        # shellcheck disable=SC2088  # 利用者に見せる文面の「~」（展開させない）
        die "~/home/ 配下で実行してください。
  正しい場所: ~/home/{github-owner}/{company}/
  現在の場所: ${PWD}"
    fi
    depth=$(printf '%s' "$rest" | tr -cd '/' | wc -c)
    if [[ $depth -ne 1 ]]; then
        die "実行フォルダの階層が正しくありません。
  正しい場所: ~/home/{github-owner}/{company}/
  現在の場所: ${PWD}"
    fi
    GITHUB_OWNER=$(basename "$(dirname "$PWD")")
    COMPANY_NAME=$(basename "$PWD")
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
