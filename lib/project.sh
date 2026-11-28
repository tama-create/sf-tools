#!/bin/bash
# ==============================================================================
# project.sh - プロジェクト（force-*・GitHub・組織・ブランチ）に関する関数
# ==============================================================================
# lib/common.sh から source される（呼び出し側は、common.sh だけを source すればよい。単独では、source しない）。
# common.sh の変数・関数（log / run / die / json_get / RET_* / BRANCH_LIST_FILE / SF_RESERVED_ORG_ALIASES など）と、
# input.sh の read_or_quit / ask_yn、platform.sh の set_var を、使う。
#
# 【提供する関数】
#   get_target_org [ALIAS]    ... 接続先組織エイリアスを解決
#   check_force_dir           ... force-* ディレクトリ内か確認
#   resolve_init_identity     ... sf-project 用: オーナーとプロジェクト名（XXXX）を、環境変数 SF_INIT_OWNER / SF_INIT_PROJECT・対話で決める
#   resolve_job_identity O P  ... sf-job 用: 同上（引数・カレントの下のクローンの git remote・対話）
#   prompt_project_identity MODE ... オーナーと XXXX を、対話で決める（MODE: init / job。上の 2 つが使う）
#   parse_github_remote URL   ... GitHub の URL から「owner repo」を取り出す（HTTPS / SSH）
#   origin_repo VAR [DIR]     ... DIR（既定: カレント）の origin から「owner/repo」を取り出して VAR に入れる（取れなければ戻り値 1・2）
#   require_origin_repo VAR   ... origin_repo の、取れなければ die する版（カレントの origin。URL は伏せて表示する）
#   normalize_project_name X  ... 入力から XXXX（force- の後ろ）を取り出す（force- が付いていれば除く。不正なら戻り値 1）
#   discover_clones DIR       ... DIR/*/force-*/ のクローンの git remote から「owner repo」を取り出す
#   gh_owner_candidates MODE  ... gh のログインから、オーナーの候補を出す（MODE: admin / member）
#   gh_existing_projects OWNER ... そのオーナーにある force-* リポジトリの XXXX を出す
#   check_gh_owner OWNER      ... gh 認証ユーザーが期待するオーナーと一致するか確認（大文字と小文字は区別しない。組織の有効な admin も許可）
#   get_branch_list           ... branches.txt からブランチ一覧を取得（全行。保護の判定用）
#   get_tier_list             ... branches.txt から、有効な段階（main / staging / develop）を決まった順で取得（診断用。--strict [FILE] は一方通行の確認 R0 用で、判断の材料がなければ戻り値 1）
#   is_reserved_org_alias     ... 共有環境の組織エイリアス（sf-tools の予約名）か判定
#   is_protected_branch       ... 指定ブランチが branches.txt の保護対象か判定
#   required_status_check_names ... ブランチ保護（Ruleset）の必須ステータスチェックの名前（ジョブ名）を、1 行に 1 つ出す
#   ensure_sf_tools_latest    ... sf-tools（Git リポジトリ）が origin の最新であることを確認
#   clone_matches_repo DIR O R ... DIR が Git のクローンで、origin が GitHub の O/R か（大文字と小文字は区別しない）
#   state_matches_repo FILE O R .. 状態ファイル（.sf-init-XXXX.env）の REPO_FULL_NAME が O/R か（大文字と小文字は区別しない）
#   mark_setup_complete DIR   ... クローンに、セットアップ完了の印（git config sf-tools.setup-complete=1）を付ける
#   clear_setup_mark DIR      ... 完了の印を 0（やり直し中）にする（やり直しの開始時）
#   clone_setup_completed DIR O R ... DIR が O/R のセットアップ済みのクローンか（印 1 / 印がなければ admin ブランチの有無。印 0 は未完了）
#   git_origin_redacted DIR   ... origin の URL を、認証情報を伏せて出す（エラーの文言・ログ用）
#   ensure_admin_branch DIR   ... 管理者用のクローンを、admin ブランチ（ローカル）にする（main の上で、作業しないため）
#   push_admin_branch DIR     ... admin ブランチを、GitHub にも作る（git push -u origin admin。強制 push はしない）
#   merge_package_xml OUT IN... ... package.xml 形式のマニフェストを 1 つに統合する（種類ごとに、メンバーを重複なく並べる。
#                               入力が読めない・書けないときは、OUT を削除して戻り値 1）
#   manifest_overlap A B      ... 2 つのマニフェストの両方にある「種類:メンバー」を、1 行に 1 つ出す（反映と削除の重なりの検出）
#   manifest_missing_in_org XML ORG ... 削除のマニフェストの「種類:メンバー」のうち、組織にないものを出す（確かめられたものだけ）
#   manifest_drop_pairs XML LIST ... マニフェストから、LIST の「種類:メンバー」を除く（メンバーのなくなった種類は、<types> ごと）
#   （内部用: _pick_from_list・_manifest_pairs。変数: _GH_OWNER_RE = GitHub のオーナー名の形式）
#
# 【ファイルの分け方】 2026-11-28 に、テーマごとのファイルに分けた。このファイルの最後で、順に source する:
#   lib/package-xml.sh（マニフェストの統合と比較）・lib/identity.sh（プロジェクトの特定・origin）・
#   lib/branches.sh（ブランチと段階）・lib/sftools-update.sh（sf-tools の最新化）・lib/admin-clone.sh（管理者用のクローン）。
#   このファイルに残すのは、接続先の組織・force-* の確認・gh のオーナーの確認（get_target_org・check_force_dir・check_gh_owner）
# ==============================================================================


# get_target_org - 接続先組織エイリアスを解決して echo する
# ------------------------------------------------------------------------------
# 【使い方】
#   TARGET=$(get_target_org [ALIAS]) || die "組織を特定できません。"
#
# 【解決の優先順位】
#   1. 引数 ALIAS（明示指定）
#   2. 環境変数 SF_TARGET_ORG（GitHub Actions の secrets 等）
#   3. ローカル接続情報（sf org display --json の result.alias。既定の組織にエイリアスがなければ、特定できない扱い）
#
# 【戻り値】
#   RET_OK (0) : エイリアスを echo して正常終了
#   RET_NG (1) : どこからも特定できなかった場合
#
# 【sf org display の、一時的な失敗への備え】
#   sf org display は、Salesforce に、アクセストークンの更新を、問い合わせることがある。一時的な失敗（理由が空の RefreshTokenAuthError など。
#   実機で、1 度だけ、新しいジョブのクローンの sf-dryrun が、「特定できません」で止まった）に備え、特定できなかったときは、待って、やり直す。
#   やり直しても、特定できなければ、sf の応答の要点（message）を、WARNING で、ログと画面に残す（原因を、あとから追えるように）。
#   SF_TOOLS_ORG_DISPLAY_TRIES（試行回数。既定 3）・SF_TOOLS_ORG_DISPLAY_WAIT（やり直すまでの待ち。秒。既定 2）
#
# 【使用例】
#   TARGET_ORG=$(get_target_org "$OPT_TARGET") || die "接続先を特定できません。"
#   TARGET_ORG=$(get_target_org)               || die "接続先を特定できません。"
# ------------------------------------------------------------------------------
get_target_org() {
    local target="$1"
    [[ -z "$target" ]] && target="$SF_TARGET_ORG"
    if [[ -z "$target" ]]; then
        local current_alias disp_json="" cause i tries="${SF_TOOLS_ORG_DISPLAY_TRIES:-3}" wait_sec="${SF_TOOLS_ORG_DISPLAY_WAIT:-2}"
        for (( i = 1; i <= tries; i++ )); do
            disp_json=$(run sf org display --json || echo "")  # run の出力（標準エラーを含む）を受け取る（失敗したときは、run が返すエラーの出力が入る。json_get で alias が取れず、やり直しに進む）
            current_alias=$(json_get "$disp_json" result.alias)  # VAR=$(cmd) のため run 不使用（値の抽出のみ）
            if [[ -n "$current_alias" && "$current_alias" != "null" ]]; then target="$current_alias"; break; fi
            (( i < tries )) && sleep "$wait_sec"  # run 不使用: 待機（一時的な失敗への備え）
        done
        if [[ -z "$target" ]]; then
            cause=$(json_get "$disp_json" message 2>/dev/null | head -1 | cut -c1-200)  # VAR=$(cmd) のため run 不使用（応答の要点だけ）
            log "WARNING" "sf org display で、接続先を取得できませんでした（${tries} 回試行）。sf の応答: ${cause:-（応答なし）}"
        fi
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
    [[ "$(basename "$PWD")" =~ ^force- ]] && return $RET_OK  # 条件チェックのため run 不使用
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
#   - 期待するオーナーと一致すれば通過（文字列の完全一致。大文字と小文字は区別しない。GitHub のユーザー名・組織名は、
#     大文字と小文字を区別しないため。Bash 3.2 には ${x,,} がないため、tr で小文字にして比べる）
#   - 一致しない場合、オーナーが組織で認証ユーザーがその組織の有効な管理者（admin かつ active）なら通過
#   - 上記以外は die（組織 API が失敗した場合も通過させない）
#   - gh コマンドが使えない場合（ユーザー名が空）はチェックをスキップ（ネットワーク障害等への配慮）
#   戻り値: RET_OK = 通過（組織の管理者として通過したときは、INFO を表示）。通過しなければ die
# ------------------------------------------------------------------------------
check_gh_owner() {
    local expected_owner="$1"
    local gh_user org_status gh_user_lc owner_lc
    gh_user=$(gh api user --jq '.login' 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
    [[ -z "$gh_user" ]] && return $RET_OK
    gh_user_lc=$(printf '%s' "$gh_user" | tr 'A-Z' 'a-z')          # VAR=$(cmd) のため run 不使用
    owner_lc=$(printf '%s' "$expected_owner" | tr 'A-Z' 'a-z')     # VAR=$(cmd) のため run 不使用
    [[ "$gh_user_lc" == "$owner_lc" ]] && return $RET_OK
    # 不一致: オーナーが組織なら、認証ユーザーがその組織の有効な管理者かを確認する
    org_status=$(gh api "user/memberships/orgs/${expected_owner}" --jq '.role + " " + .state' 2>/dev/null || true)  # VAR=$(cmd) のため run 不使用
    if [[ "$org_status" == "admin active" ]]; then
        log "INFO" "gh の認証ユーザー（${gh_user}）は組織 ${expected_owner} の管理者です。続行します。"
        return $RET_OK
    fi
    die "gh の認証ユーザー（${gh_user}）がリポジトリオーナー（${expected_owner}）と一致せず、組織の管理者（admin）でもありません。"
}

# ------------------------------------------------------------------------------
# テーマごとのファイル（2026-11-28 に、このファイルから分けた。冒頭コメントの【ファイルの分け方】）
# ------------------------------------------------------------------------------
_PROJECT_LIB_DIR="${BASH_SOURCE[0]%/*}"
for _project_part in package-xml identity branches sftools-update admin-clone; do
    source "${_PROJECT_LIB_DIR}/${_project_part}.sh" \
        || { echo "[FATAL ERROR] Library not found: ${_PROJECT_LIB_DIR}/${_project_part}.sh" >&2; exit 1; }  # run 不使用: ライブラリの読み込み
done
unset _project_part
