#!/bin/bash
# ==============================================================================
# branches.sh - ブランチと段階（branches.txt の一覧・有効な段階・予約名・保護ブランチ・必須チェックの名前）
# ==============================================================================
# lib/project.sh が source する（呼び出し側は、今までどおり lib/common.sh を読むだけでよい。単独では、source しない）。
# 2026-11-28 に、1013 行あった lib/project.sh から、テーマごとに分けた（中身は変えずに移した）。
# 関数の一覧と使い方は、lib/project.sh の冒頭コメント（【提供する関数】）にまとめてある。
# ==============================================================================
# shellcheck disable=SC2154  # 変数は、lib/common.sh と、それを読み込むスクリプトが用意する

# get_branch_list - branches.txt からブランチ一覧を取得して echo する
# ------------------------------------------------------------------------------
# 【使い方】
#   branches=$(get_branch_list)
#
# 【ファイル参照先】
#   BRANCH_LIST_FILE（common.sh。sf-tools/config/branches.txt。カレントディレクトリ = force-* からの相対パス）
#
# 【動作】
#   1 行に 1 ブランチ。行末の CR を除き、# で始まる行（前に空白があってもよい）と、空白だけの行は読み飛ばす。
#
# 【戻り値】
#   RET_OK (0) : 常に。ブランチ一覧を、1 行に 1 つ echo する。
#                ファイルがない・ブランチが 1 つもないときは、WARNING を表示して main だけを echo する
# ------------------------------------------------------------------------------
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

# get_tier_list - branches.txt から、有効な段階（main / staging / develop）を、決まった順で echo する
# ------------------------------------------------------------------------------
# 【使い方】
#   tiers=$(get_tier_list)
#   tiers=$(get_tier_list --strict [FILE]) || die "..."   # 判断の材料がないときに止める（一方通行の確認 R0）
#
# 【ファイル参照先】
#   BRANCH_LIST_FILE（get_branch_list と同じ）
#
# 【動作】（規則の正本は doc/tier-scaling-design.md の 3.1。workflow の tier_enabled と同じ規則）
#   - 行末の CR と、行の前後の空白を除き、# で始まる行・空の行は読み飛ばす
#   - 段階の名前は main / staging / develop だけ。ほかの名前の行は、WARNING を出して無視する
#   - 同じ名前が 2 行あっても 1 つ。main の行がなくても、main は有効
#   - develop は、staging も有効なときだけ有効（ないときは、WARNING を出して無効にする）
#   - ファイルがない・段階の行が 1 つもないときは、main だけ（get_branch_list と同じ WARNING を出す）
#   - echo する順は、常に main → staging → develop（branches.txt の並びには頼らない）
#   - --strict（doc/one-way-promotion-design.md 3.2 の表）: ファイルがない・読めない・main の行がない（空・コメントだけを含む）・
#     develop はあるが staging がない → ERROR を出して戻り値 1（何も echo しない）。段階の名前でない行は、WARNING を出さずに無視する。
#     FILE を渡すと、BRANCH_LIST_FILE の代わりに読む（origin/main の branches.txt を一時ファイルに出して読むため）
#
# 【get_branch_list との違い】
#   get_branch_list は、branches.txt の全行（名前を問わない）を返す。保護するブランチの判定（is_protected_branch）に使う
#   （段階を外したブランチも、誤って直接 push しないよう、保護は緩めない）。get_tier_list は、段階として動かすものを
#   決めるところ（status.sh など）に使う。--strict は sf-promote-check.sh（一方通行の確認）が使う
#
# 【戻り値】
#   RET_OK (0) : 1 行に 1 つ echo する（--strict なしは、常に 0）
#   RET_NG (1) : --strict で、上の条件のとき
# ------------------------------------------------------------------------------
get_tier_list() {
    # --strict [FILE]: 判断の材料がないときに、main だけで通さない（一方通行の確認 R0。doc/one-way-promotion-design.md 3.2 の表）
    local strict=0 file="$BRANCH_LIST_FILE"
    if [[ "${1:-}" == "--strict" ]]; then
        strict=1
        [[ -n "${2:-}" ]] && file="$2"
    fi
    if [[ ! -f "$file" || ! -r "$file" ]]; then
        if [[ "$strict" -eq 1 ]]; then
            log "ERROR" "ブランチ構成ファイルが見つかりません（読めません）: ${file}"
            return $RET_NG
        fi
        log "WARNING" "ブランチ構成ファイルが見つかりません: ${file}（デフォルト: main のみ）"
        echo "main"
        return $RET_OK
    fi
    local line has_line=0 has_main=0 has_staging=0 has_develop=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"                               # CR 除去（Windows 対応）
        line="${line#"${line%%[![:space:]]*}"}"            # 先頭の空白を除く
        line="${line%"${line##*[![:space:]]}"}"            # 末尾の空白を除く
        [[ -z "$line" || "$line" == \#* ]] && continue     # 空行・コメント行スキップ
        has_line=1
        case "$line" in
            main)    has_main=1 ;;
            staging) has_staging=1 ;;
            develop) has_develop=1 ;;
            *)       [[ "$strict" -eq 1 ]] || log "WARNING" "${file} の「${line}」は、段階の名前（main / staging / develop）ではないため、段階としては無視します。" ;;
        esac
    done < "$file"
    if [[ "$strict" -eq 1 ]]; then
        if [[ "$has_main" -eq 0 ]]; then
            log "ERROR" "${file} に main の行がありません（段階の構成を判断できません）。"
            return $RET_NG
        fi
        if [[ "$has_develop" -eq 1 && "$has_staging" -eq 0 ]]; then
            log "ERROR" "${file} に develop がありますが、staging がありません（段階の構成の誤り）。"
            return $RET_NG
        fi
    elif [[ "$has_line" -eq 0 ]]; then
        log "WARNING" "${file} にブランチが定義されていません。デフォルト: main のみ"
    fi
    echo "main"
    [[ "$has_staging" -eq 1 ]] && echo "staging"
    if [[ "$has_develop" -eq 1 ]]; then
        if [[ "$has_staging" -eq 1 ]]; then
            echo "develop"
        else
            log "WARNING" "${file} に develop がありますが、staging がないため、develop は段階として無効です。"
        fi
    fi
    return $RET_OK
}

# is_reserved_org_alias - 共有環境の組織エイリアス（sf-tools の予約名）かを返す
# ------------------------------------------------------------------------------
# 【背景】
#   共有環境（main・staging・develop）へのリリースは、ローカルの PC からはできない。
#   GitHub にコミットし、レビューを通して、GitHub Actions で行う。
#   prod / staging / develop は、sf-tools が、共有環境の組織（prod は main の組織。組織の種類は、問わない）に使う名前
#   （GitHub Actions のワークフローが、JWT ログインで、この名前の組織を作る）。sf-project は、この PC の sf には、エイリアスを残さない
#   （接続テストは、一時的なホームの中で行う。運用中のエイリアスと衝突させないため）。
#   この名前を予約名とし、ローカルからのリリースを禁止する（sf-release.sh / sf-deploy.sh）。
#   main は、ブランチ名と同じ名前（互換のため、予約名に含める）。
#   予約名以外の名前を付けた本番組織は、名前では止められないため、sf-release.sh / sf-deploy.sh は、組織の種類も確認する
#   （lib/org.sh の org_local_release_check）。
#
# 【使い方】
#   is_reserved_org_alias "$TARGET_ORG" && die "ローカルからは実行できません。"
#
# 【判定】
#   SF_RESERVED_ORG_ALIASES（common.sh。prod / staging / develop / main）との完全一致（大文字と小文字は区別する）
#
# 【戻り値】
#   RET_OK (0) : 予約名（共有環境）
#   RET_NG (1) : それ以外
# ------------------------------------------------------------------------------
is_reserved_org_alias() {
    local alias_name="$1" reserved
    for reserved in $SF_RESERVED_ORG_ALIASES; do
        [[ "$alias_name" == "$reserved" ]] && return $RET_OK
    done
    return $RET_NG
}

# ------------------------------------------------------------------------------
# required_status_check_names - ブランチ保護（Ruleset）の必須ステータスチェックの名前
# ------------------------------------------------------------------------------
# 【使い方】
#   required_status_check_names     # 1 行に 1 つ（対象ファイル確認 / デプロイ検証 / 順序チェック）
#   名前は、ワークフロー（templates/.github/workflows/wf-validate.yml・wf-sequence.yml）の「ジョブ名」（name:）。
#   ワークフロー名は、含めない（「validate / 対象ファイル確認」の形では、永久に満たされず、PR がマージできなくなる）。
#   sf-project の Phase 9（Ruleset の作成）と、lib/diag.sh（sf-project.sh --status・--verify の、既存のプロジェクトの診断）が、使う。
#   ジョブ名を変えるときは、ここも直す（tests/test_sf-project.sh の突き合わせのテストが、食い違いを検出する）。
required_status_check_names() {
    printf '%s\n' "対象ファイル確認" "デプロイ検証" "順序チェック"
}

# ------------------------------------------------------------------------------
# is_protected_branch - 指定ブランチが branches.txt の保護対象かを返す
# ------------------------------------------------------------------------------
# 【使い方】
#   is_protected_branch "staging" && die "直接プッシュ禁止"
#
# 【判定】
#   get_branch_list の一覧（branches.txt のすべてのブランチ。ファイルがない・空なら main のみ）に、行全体で一致するか
#   （grep -qxF --。ブランチ名は、固定の文字列として比べる（. などを、正規表現として扱わない。- で始まる名前も、
#   オプションとして扱わない）。大文字と小文字は区別する（Git のブランチ名は、区別するため））
#
# 【戻り値】
#   RET_OK (0) : 保護対象ブランチである
#   RET_NG (1) : 保護対象外
# ------------------------------------------------------------------------------
is_protected_branch() {
    local branch="$1"
    local branches
    branches=$(get_branch_list)  # VAR=$(cmd) のため run 不使用
    printf '%s\n' "$branches" | grep -qxF -- "$branch" && return $RET_OK  # 条件チェックのため run 不使用
    return $RET_NG
}
