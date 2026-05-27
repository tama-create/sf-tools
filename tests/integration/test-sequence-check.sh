#!/usr/bin/env bash
# ==============================================================================
# test-sequence-check.sh - シーケンスチェック全パターン統合テスト
# ==============================================================================
# gh CLI を使って PR シーケンスチェックを自動検証する。
# テスト対象のブランチ構成は sf-tools/config/branches.txt から動的に読み込む。
#
# 【ブランチ構成別のテスト件数】
#   main + staging + develop : ❌3 + ⚠️2 + ✅3 = 8 件
#   main + staging           : ❌1 + ⚠️1 + ✅2 = 4 件
#   main のみ                : ✅1 = 1 件
#
# 【使用方法】
#   cd /c/home/tamashimon-org/test/init/force-test
#   bash ~/sf-tools/tests/integration/test-sequence-check.sh
#
# 【前提条件】
#   - gh auth login 済み
#   - リポジトリ admin 権限を持つ PAT で認証済み（staging への直接 push に必要）
#   - sf-tools/config/branches.txt が配置済み
# ==============================================================================

set -uo pipefail

REPO="tamashimon-org/force-test"
TS=$(date +%H%M%S)

# ログ出力先
ROOT_DIR=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
LOG_DIR="$ROOT_DIR/sf-tools/logs"
LOG_FILE="$LOG_DIR/test-sequence-check.log"
mkdir -p "$LOG_DIR"
exec > >(tee "$LOG_FILE") 2>&1
echo "====== テスト開始: $(date '+%Y-%m-%d %H:%M:%S') ======"

# ==============================================================================
# branches.txt の読み込み
# ==============================================================================
BRANCH_LIST_FILE="$ROOT_DIR/sf-tools/config/branches.txt"
if [[ ! -f "$BRANCH_LIST_FILE" ]]; then
    BRANCH_LIST_FILE="$HOME/sf-tools/templates/defaults/branches.txt"
fi
if [[ ! -f "$BRANCH_LIST_FILE" ]]; then
    echo "[ERROR] branches.txt が見つかりません" >&2
    exit 1
fi

BRANCHES=()
while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    BRANCHES+=("$line")
done < "$BRANCH_LIST_FILE"

NUM_BRANCHES=${#BRANCHES[@]}
MAIN_BRANCH="${BRANCHES[0]}"

# MERGE_PATH: マージ順序（下位→上位: develop, staging, main）
MERGE_PATH=()
for ((i=NUM_BRANCHES-1; i>=0; i--)); do
    MERGE_PATH+=("${BRANCHES[$i]}")
done

# NON_MAIN: main 以外のブランチ（マージ順）
NON_MAIN=()
for b in "${MERGE_PATH[@]}"; do
    [[ "$b" != "$MAIN_BRANCH" ]] && NON_MAIN+=("$b")
done
NUM_NON_MAIN=${#NON_MAIN[@]}

# 想定テスト件数
EXPECTED_BLOCK=$(( NUM_BRANCHES * (NUM_BRANCHES - 1) / 2 ))
EXPECTED_WARN=$(( NUM_BRANCHES - 1 ))
EXPECTED_PASS=$(( NUM_NON_MAIN > 0 ? NUM_NON_MAIN + 1 : 1 ))
EXPECTED_TOTAL=$(( EXPECTED_BLOCK + EXPECTED_WARN + EXPECTED_PASS ))

echo "ブランチ構成: ${BRANCHES[*]} (${NUM_BRANCHES}ブランチ)"
echo "構成ファイル: $BRANCH_LIST_FILE"
echo "想定テスト件数: ❌${EXPECTED_BLOCK} + ⚠️${EXPECTED_WARN} + ✅${EXPECTED_PASS} = ${EXPECTED_TOTAL} 件"

# ==============================================================================
# Feature ブランチの設計
# ==============================================================================
FEATURES=()
for ((i=0; i<NUM_NON_MAIN; i++)); do
    FEATURES+=("feature/seq-test-${i}-${TS}")
done
FEATURE_UNMERGED="feature/seq-test-none-${TS}"

# クリーンアップ対象
CREATED_BRANCHES=()
if [[ ${#FEATURES[@]} -gt 0 ]]; then
    CREATED_BRANCHES+=("${FEATURES[@]}")
fi
CREATED_BRANCHES+=("$FEATURE_UNMERGED")

PASS=0; FAIL=0; SKIP=0
COUNT_BLOCK=0; COUNT_WARN=0; COUNT_OK=0
CREATED_PRS=()

# カラー
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

# ==============================================================================
# GitHub API: branches.txt のリモート同期・復元
# ==============================================================================
ORIGINAL_BRANCHES_CONTENT=""

sync_branches_to_remote() {
  echo -e "\n${YELLOW}━━━ branches.txt をリモートに同期 ━━━${NC}"

  # 元の内容を保存（復元用）
  ORIGINAL_BRANCHES_CONTENT=$(gh api "repos/$REPO/contents/sf-tools/config/branches.txt" \
    --jq '.content' 2>/dev/null | tr -d '\n')

  # ローカルの branches.txt をエンコード
  local encoded sha
  encoded=$(base64 < "$BRANCH_LIST_FILE" | tr -d '\n')
  sha=$(gh api "repos/$REPO/contents/sf-tools/config/branches.txt" --jq '.sha' 2>/dev/null)

  if [[ -z "$sha" ]]; then
    echo "  [ERROR] リモートの branches.txt SHA を取得できません" >&2
    return 1
  fi

  # リモート main に反映
  gh api "repos/$REPO/contents/sf-tools/config/branches.txt" \
    -X PUT \
    -f message="test(seq-check): branches.txt を同期 (${BRANCHES[*]})" \
    -f content="$encoded" \
    -f sha="$sha" > /dev/null

  echo "  リモートに反映: ${BRANCHES[*]}"
  sleep 2
  git fetch origin "$MAIN_BRANCH" -q
  git reset --hard "origin/$MAIN_BRANCH" -q
  # Windows Git Bash で CRLF/LF 差分が残る場合があるため強制チェックアウト
  git checkout -- . 2>/dev/null || true
}

restore_branches_on_remote() {
  if [[ -z "$ORIGINAL_BRANCHES_CONTENT" ]]; then return; fi

  local sha
  sha=$(gh api "repos/$REPO/contents/sf-tools/config/branches.txt" --jq '.sha' 2>/dev/null)
  [[ -z "$sha" ]] && return

  gh api "repos/$REPO/contents/sf-tools/config/branches.txt" \
    -X PUT \
    -f message="test(seq-check): branches.txt を復元" \
    -f content="$ORIGINAL_BRANCHES_CONTENT" \
    -f sha="$sha" > /dev/null 2>&1 || true

  echo "  branches.txt を復元しました"
}

# ==============================================================================
# クリーンアップ（EXIT 時に必ず実行）
# ==============================================================================
cleanup() {
  echo -e "\n${YELLOW}━━━ クリーンアップ ━━━${NC}"

  for pr in "${CREATED_PRS[@]:-}"; do
    [[ -z "$pr" ]] && continue
    gh pr close "$pr" --repo "$REPO" --comment "[自動テスト完了] クローズします。" 2>/dev/null \
      && echo "  PR#$pr クローズ" || true
  done

  for br in "${CREATED_BRANCHES[@]:-}"; do
    [[ -z "$br" ]] && continue
    gh api "repos/$REPO/git/refs/heads/$br" -X DELETE 2>/dev/null \
      && echo "  remote: $br 削除" || true
    git branch -D "$br" 2>/dev/null || true
  done

  restore_branches_on_remote

  git merge --abort 2>/dev/null || true
  git rebase --abort 2>/dev/null || true
  git checkout -f "$MAIN_BRANCH" 2>/dev/null || true
  echo "  完了"
}
trap cleanup EXIT

# ==============================================================================
# PR 作成 → マージ順序を検証の結果を確認
# ==============================================================================
test_scenario() {
  local desc="$1" head="$2" base="$3" expected="$4"

  echo -e "\n${BLUE}▶ $desc${NC}"
  echo    "  $head → $base  (期待: $expected)"

  local pr_output
  pr_output=$(gh pr create --repo "$REPO" \
    --head "$head" --base "$base" \
    --title "[SEQ-TEST-$TS] $desc" \
    --body "⚠️ 自動テスト用 PR です。マージしないでください。" 2>&1) || true

  if ! echo "$pr_output" | grep -qE "^https://"; then
    echo -e "  ${YELLOW}⚠ スキップ${NC}: PR 作成失敗 → $pr_output"
    ((SKIP++)); return
  fi

  local pr_num
  pr_num=$(echo "$pr_output" | grep -oE '[0-9]+$')
  CREATED_PRS+=("$pr_num")
  echo "  PR#$pr_num 作成"

  # チェック完了まで最大 5 分待機
  local actual="timeout" _w
  for _w in $(seq 1 20); do
    sleep 15
    local checks
    checks=$(gh pr checks "$pr_num" --repo "$REPO" 2>&1 || true)

    if echo "$checks" | grep -qi "no checks"; then
      echo "  待機中... $((_w * 15))s (チェック未登録)"
      continue
    fi

    if echo "$checks" | grep -qE "\s(pending|in_progress)\s"; then
      echo "  待機中... $((_w * 15))s"
      continue
    fi

    local seq_result
    seq_result=$(echo "$checks" | grep "マージ順序を検証" | awk -F'\t' '{print $2}' | head -1)
    actual="${seq_result:-pass(skipped)}"
    break
  done

  echo "  マージ順序を検証: $actual"

  local ok=false
  [[ "$expected" == "fail" && "$actual" == "fail" ]] && ok=true
  [[ "$expected" == "pass" ]] && echo "$actual" | grep -qE "^pass" && ok=true

  if $ok; then
    echo -e "  ${GREEN}✅ PASS${NC}"
    ((PASS++))
  else
    echo -e "  ${RED}❌ FAIL${NC}  (期待: $expected, 実際: $actual)"
    ((FAIL++))
  fi
}

# ブランチを指定先に直接マージして push するヘルパー
merge_to() {
  local feature="$1" target="$2"
  local tmp="_${target}_tmp"
  git checkout -f -B "$tmp" "origin/$target"
  if ! git merge "$feature" --no-ff -X theirs -m "test(seq-check): merge $feature to $target"; then
    git merge --abort 2>/dev/null || true
    git checkout -f "$MAIN_BRANCH"
    git branch -D "$tmp" 2>/dev/null || true
    echo "  [ERROR] $feature → $target のマージに失敗しました" >&2
    return 1
  fi
  git push --no-verify origin "$tmp:$target"
  git checkout -f "$MAIN_BRANCH" && git branch -D "$tmp"
}

# ==============================================================================
# セットアップ
# ==============================================================================
cd "$ROOT_DIR"

echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${YELLOW}  シーケンスチェック統合テスト ($TS)${NC}"
echo -e "${YELLOW}  ${BRANCHES[*]} (想定: ${EXPECTED_TOTAL} テスト)${NC}"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# 前回の残骸ブランチをリモートから自動クリーンアップ
echo -e "\n${YELLOW}━━━ クリーンアップ（前回の残骸） ━━━${NC}"
stale_branches=$(git ls-remote --heads origin "refs/heads/feature/seq-test-*" 2>/dev/null \
  | awk '{print $2}' | sed 's|refs/heads/||')
if [[ -n "$stale_branches" ]]; then
  while IFS= read -r br; do
    git push --no-verify origin --delete "$br" 2>/dev/null && echo "  remote: $br 削除" || true
    git branch -D "$br" 2>/dev/null || true
  done <<< "$stale_branches"
else
  echo "  残骸ブランチなし"
fi

# ローカルの branches.txt をリモート main に同期（テスト後に自動復元）
sync_branches_to_remote

echo -e "\n${YELLOW}━━━ セットアップ ━━━${NC}"
git fetch origin "${BRANCHES[@]}"

# FEATURES[i]: NON_MAIN[0..i] にマージ済みのブランチを作成
for ((i=0; i<NUM_NON_MAIN; i++)); do
  desc=""
  for ((j=0; j<=i; j++)); do
    [[ -n "$desc" ]] && desc+="+"
    desc+="${NON_MAIN[$j]}"
  done
  echo "FEATURES[$i] を作成（${desc} にマージ）..."

  git checkout -f --no-track -b "${FEATURES[$i]}" "origin/$MAIN_BRANCH"
  git commit --allow-empty -m "test(seq-check): FEATURES[$i] $TS"
  git push --no-verify origin "${FEATURES[$i]}"

  for ((j=0; j<=i; j++)); do
    merge_to "${FEATURES[$i]}" "${NON_MAIN[$j]}"
  done
done

# 未マージの Feature ブランチ
echo "FEATURE_UNMERGED を作成（未マージ）..."
git checkout -f --no-track -b "$FEATURE_UNMERGED" "origin/$MAIN_BRANCH"
git commit --allow-empty -m "test(seq-check): FEATURE_UNMERGED $TS"
git push --no-verify origin "$FEATURE_UNMERGED"
git checkout -f "$MAIN_BRANCH"

echo "セットアップ完了"

# ==============================================================================
# テスト実行
# ==============================================================================
echo -e "\n${YELLOW}━━━ テスト実行 ━━━${NC}"

# ❌ エラーブロック（保護ブランチ間の PR はすべてブロック）
_before=$PASS
for ((i=0; i<NUM_BRANCHES; i++)); do
  for ((j=i+1; j<NUM_BRANCHES; j++)); do
    test_scenario "❌ ${BRANCHES[$j]} → ${BRANCHES[$i]}（ブロック）" \
      "${BRANCHES[$j]}" "${BRANCHES[$i]}" "fail"
  done
done
COUNT_BLOCK=$((PASS - _before))

# ⚠️ 警告のみ（前提ブランチ未マージの feature PR）
_before=$PASS
for ((i=1; i<${#MERGE_PATH[@]}; i++)); do
  target="${MERGE_PATH[$i]}"
  prereq="${MERGE_PATH[$((i-1))]}"
  test_scenario "⚠️  feature/* → ${target}（${prereq}未マージ）" \
    "$FEATURE_UNMERGED" "$target" "pass"
done
COUNT_WARN=$((PASS - _before))

# ✅ 正常通過
_before=$PASS
if [[ $NUM_NON_MAIN -gt 0 ]]; then
  test_scenario "✅ feature/* → ${NON_MAIN[0]}（制限なし）" \
    "$FEATURE_UNMERGED" "${NON_MAIN[0]}" "pass"

  for ((i=0; i<NUM_NON_MAIN; i++)); do
    if ((i < NUM_NON_MAIN - 1)); then
      target="${NON_MAIN[$((i+1))]}"
    else
      target="$MAIN_BRANCH"
    fi
    test_scenario "✅ feature/* → ${target}（${NON_MAIN[$i]}済み）" \
      "${FEATURES[$i]}" "$target" "pass"
  done
else
  test_scenario "✅ feature/* → ${MAIN_BRANCH}（制限なし）" \
    "$FEATURE_UNMERGED" "$MAIN_BRANCH" "pass"
fi
COUNT_OK=$((PASS - _before))

# ==============================================================================
# 結果サマリー
# ==============================================================================
TOTAL=$((PASS + FAIL + SKIP))
echo -e "\n${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  想定: ❌${EXPECTED_BLOCK}  ⚠️${EXPECTED_WARN}  ✅${EXPECTED_PASS}  = ${EXPECTED_TOTAL}件"
echo -e "  実績: ❌${COUNT_BLOCK}  ⚠️${COUNT_WARN}  ✅${COUNT_OK}  = ${TOTAL}件 (失敗: $FAIL / スキップ: $SKIP)"
echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

ALL_MATCH=true
[[ $COUNT_BLOCK -ne $EXPECTED_BLOCK ]] && ALL_MATCH=false
[[ $COUNT_WARN  -ne $EXPECTED_WARN  ]] && ALL_MATCH=false
[[ $COUNT_OK    -ne $EXPECTED_PASS  ]] && ALL_MATCH=false
[[ $FAIL -gt 0 || $SKIP -gt 0 ]]      && ALL_MATCH=false

if $ALL_MATCH; then
  echo ""
  echo -e "${GREEN}╔══════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║                                              ║${NC}"
  echo -e "${GREEN}║   🎉🎉🎉  全テスト 100% パス！  🎉🎉🎉       ║${NC}"
  echo -e "${GREEN}║                                              ║${NC}"
  echo -e "${GREEN}║   シーケンスチェック、完璧に動いています！   ║${NC}"
  echo -e "${GREEN}║                                              ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════╝${NC}"
  echo ""
fi

$ALL_MATCH && exit 0 || exit 1
