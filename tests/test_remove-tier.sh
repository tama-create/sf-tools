#!/bin/bash
# ==============================================================================
# test_remove-tier.sh - sf-project.sh --remove-tier（phases/init/remove_tier.sh）のテスト
# ==============================================================================
# 設計: doc/tier-scaling-design.md の 5 章・9 章。
# 実際の git リポジトリ（ローカルのリモートつき。origin/main に branches.txt と workflow）と、gh の偽物（呼び出しを記録し、
# 一覧の問い合わせに決まった答えを返す）で動かす。sf-project.sh の引数の解析は、sf-project.sh を通して確かめる。
# 確認すること:
#   - 段階がない・develop があるのに staging を外す・workflow が古い（判定の部分が雛形と違う・印がない・wf-metasync が自分で push する）→ 止まる
#   - 影響の表示（main にない変更・開いている PR・接続情報の名前（値は出さない）・Ruleset）
#   - 作る PR の branches.txt から、その段階の行だけが消える（コメント・ほかの行は残る。CR・前後の空白があっても一致する）
#   - GitHub の設定（Secrets / Variables・Ruleset・ブランチ）を変えない（gh の書き込みは pr create だけ）
#   - --purge-secrets: 行がまだある → 止まる／決まった名前だけを消す／一部の失敗で終了コード 1、再実行で残りだけ
#   - sf-project.sh の引数: 値なし・--purge-secrets だけ・--add-tier との同時指定
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-project.sh --remove-tier ===${CLR_RST}"

TMPL_WF="$SF_TOOLS_DIR/templates/.github/workflows"

# gh の偽物を作る。呼び出しは $MOCK_CALL_LOG に記録する
#   MOCK_GH_SECRETS / MOCK_GH_VARIABLES : 一覧に返す名前（空白区切り）。delete で、ファイル（$MOCK_GH_STATE）からも消す
#   MOCK_GH_DELETE_FAIL                 : delete に失敗する名前（空白区切り）
_make_gh() {
    local mb="$1"
    cat > "$mb/gh" << 'GHEOF'
#!/bin/bash
echo "gh $*" >> "${MOCK_CALL_LOG:-/dev/null}"
st="${MOCK_GH_STATE:-/dev/null}"
case "$1 $2" in
    "api user") echo "tamashimon" ;;
    "secret list")   grep '^S ' "$st" 2>/dev/null | cut -c3- ;;
    "variable list")
        if [[ "$*" == *name,value* ]]; then grep '^V ' "$st" 2>/dev/null | cut -c3- | sed 's/$/=値/'
        else grep '^V ' "$st" 2>/dev/null | cut -c3-; fi ;;
    "secret delete"|"variable delete")
        for f in ${MOCK_GH_DELETE_FAIL:-}; do [[ "$3" == "$f" ]] && exit 1; done
        k=S; [[ "$1" == variable ]] && k=V
        grep -vx "$k $3" "$st" > "$st.tmp" 2>/dev/null; mv "$st.tmp" "$st" ;;
    "variable get") [[ "$3" == "SF_TOOLS_BRANCH" ]] && echo "${MOCK_GH_STB:-}" ;;
    "pr list") echo "#12 開いている PR" ;;
    "pr create") echo "https://github.com/tamashimon/force-testproject/pull/99" ;;
    "api repos/tamashimon/force-testproject/rulesets") echo "1 protect-main"; echo "2 protect-staging" ;;
    "api repos/tamashimon/force-testproject/rulesets/1") echo "refs/heads/main" ;;
    "api repos/tamashimon/force-testproject/rulesets/2") echo "refs/heads/staging" ;;
    *) exit 0 ;;
esac
GHEOF
    chmod +x "$mb/gh"
    # git の包み: origin の URL の問い合わせだけ、GitHub の形で返す（実体はローカルのベアリポジトリ。insteadOf で読み替える）。
    #   git remote get-url は insteadOf を展開して返すため、包みで答える。ほかは、包みのフォルダを PATH から除いて、ふだんの git に渡す
    #   （command -v git の絶対パスを exec すると、Windows では /cmd/git になり、引数の origin/main:… がパスに書き換えられるため）
    cat > "$mb/git" << 'GITEOF'
#!/bin/bash
if [[ "$1 $2 $3" == "remote get-url origin" ]]; then echo "https://github.com/tamashimon/force-testproject.git"; exit 0; fi
_self=$(cd "$(dirname "$0")" && pwd)
PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -vxF "$_self" | paste -sd: -)
exec git "$@"
GITEOF
    chmod +x "$mb/git"
}

# テスト用のリポジトリ（origin は、ローカルのベアリポジトリ。URL だけ GitHub の形に見せるため、pushurl ではなく insteadOf を使う）
#   引数: 1=main の branches.txt（printf の書式）  2=workflow の版（new / old / msold）
#   出力: 作業ディレクトリ（force-testproject）
_make_repo() {
    local base clone
    base=$(mktemp -d "${TMPDIR:-/tmp}/rmtier-XXXX")
    git init -q --bare "$base/origin.git"
    mkdir -p "$base/force-testproject"
    clone="$base/force-testproject"
    (
        cd "$clone" || exit 1
        export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
        git init -q -b main 2>/dev/null || { git init -q && git checkout -q -b main; }
        git config core.autocrlf false
        git config url."$base/origin.git".insteadOf "https://github.com/tamashimon/force-testproject.git"
        git remote add origin "https://github.com/tamashimon/force-testproject.git"
        mkdir -p sf-tools/config .github/workflows
        printf "$1" > sf-tools/config/branches.txt
        cp "$TMPL_WF/"*.yml .github/workflows/
        case "$2" in
            old)   sed -i.bak 's/sf-tools: tier-check//' .github/workflows/wf-release.yml && rm -f .github/workflows/*.bak ;;
            block) sed -i.bak 's/grep -qxF -- staging || return 1/grep -qxF -- staging || return 0/' .github/workflows/wf-validate.yml && rm -f .github/workflows/*.bak ;;
            msold) printf '      - run: git push origin staging\n' >> .github/workflows/wf-metasync.yml ;;
        esac
        git add -A && git commit -q -m init
        git push -q origin main
        git branch develop && git branch staging
        git checkout -q develop && echo d > only-dev.txt && git add only-dev.txt && git commit -q -m "develop だけの変更"
        git push -q origin develop staging
        git checkout -q -b admin main
    ) > /dev/null 2>&1
    echo "$clone"
}

# remove_tier.sh を動かす。引数: 1=作業ディレクトリ  2=段階  3=purge（0/1）  4=標準入力  出力: ログ（標準出力＋標準エラー）。RC は $MB/rc
_rt() {
    local dir="$1"
    ( cd "$dir" && printf "$4" | HOME="$MH" PATH="$MB:$PATH" SF_TOOLS_DIR="$SF_TOOLS_DIR" REMOVE_TIER="$2" REMOVE_TIER_PURGE="$3" \
        GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
        bash "$SF_TOOLS_DIR/phases/init/remove_tier.sh" ) > "$MB/out" 2>&1
    echo $? > "$MB/rc"
    cat "$MB/out"
}

_setup() {
    MB=$(setup_mock_bin); MH=$(mktemp -d "${TMPDIR:-/tmp}/rmtier-home-XXXX")
    export MOCK_CALL_LOG="$MB/calls.log"; : > "$MOCK_CALL_LOG"
    export MOCK_GH_STATE="$MB/gh-state"
    printf 'S SF_CONSUMER_KEY_DEV\nS SF_PRIVATE_KEY\nV SF_USERNAME_DEV\nV SF_INSTANCE_URL_DEV\nV SF_ORG_ID_DEV\nV SF_USERNAME_PROD\n' > "$MOCK_GH_STATE"
    _make_gh "$MB"
}
_teardown() { rm -rf "$MB" "$MH" "${1%/force-testproject}"; unset MOCK_GH_DELETE_FAIL; }

# ------------------------------------------------------------------------------
test_remove_develop_ok() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] develop を外す → 行だけを消す PR を作る${CLR_RST}"
    _setup
    local repo out pr_branch content
    repo=$(_make_repo '# 段階の一覧\nmain\n staging \r\ndevelop \r\n' new)
    out=$(_rt "$repo" develop 0 'y\n')
    assert_equals "$(cat "$MB/rc")" "0" "成功する"
    assert_output_contains "$out" "段階の切り替えに対応しています" "workflow の確かめが通る"
    assert_output_contains "$out" "main にない変更: 1 件" "影響 a: develop にだけある変更の件数"
    assert_output_contains "$out" "develop だけの変更" "影響 a: その変更の一覧"
    assert_output_contains "$out" "#12 開いている PR" "影響 b: 開いている PR"
    assert_output_contains "$out" "SF_CONSUMER_KEY_DEV" "影響 c: 接続情報の名前"
    assert_output_not_contains "$out" "SF_USERNAME_PROD" "影響 c: ほかの段階の名前は出さない"
    assert_output_contains "$out" "d. develop を対象にする Ruleset: なし" "影響 d: develop を対象にする Ruleset はない"
    pr_branch=$(git -C "$repo" ls-remote --heads origin 'system-remove-tier-develop-*' | awk '{print $2}' | sed 's#refs/heads/##')
    [[ -n "$pr_branch" ]] && pass "作業用ブランチが push される" || fail "作業用ブランチが push される"
    git -C "$repo" fetch -q origin
    content=$(git -C "$repo" show "origin/${pr_branch}:sf-tools/config/branches.txt")
    assert_equals "$content" "$(printf '# 段階の一覧\nmain\n staging ')" "branches.txt から develop の行だけが消える（コメント・空白つきの staging は残る）"
    assert_file_contains "$MOCK_CALL_LOG" "gh pr create --base main" "PR を main 向けに作る"
    assert_file_not_contains "$MOCK_CALL_LOG" "delete" "Secrets / Variables を消さない"
    assert_file_not_contains "$MOCK_CALL_LOG" "-X PUT" "Ruleset を変えない"
    git -C "$repo" ls-remote --exit-code --heads origin develop > /dev/null && pass "develop ブランチを消さない" || fail "develop ブランチを消さない"
    assert_equals "$(git -C "$repo" symbolic-ref --short HEAD)" "admin" "実行前のブランチ（admin）に戻る"
    _teardown "$repo"
}

test_remove_refusals() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] 止まる場合${CLR_RST}"
    local repo out
    _setup; repo=$(_make_repo 'main\nstaging\n' new); out=$(_rt "$repo" develop 0 'y\n')
    assert_equals "$(cat "$MB/rc")" "1" "develop がない → 止まる"
    assert_output_contains "$out" "すでに外れています" "  → 理由"
    _teardown "$repo"
    _setup; repo=$(_make_repo 'main\nstaging\ndevelop\n' new); out=$(_rt "$repo" staging 0 'y\n')
    assert_equals "$(cat "$MB/rc")" "1" "develop があるのに staging を外す → 止まる"
    assert_output_contains "$out" "先に develop を外す" "  → 理由"
    _teardown "$repo"
    _setup; repo=$(_make_repo 'main\nstaging\ndevelop\n' old); out=$(_rt "$repo" develop 0 'y\n')
    assert_equals "$(cat "$MB/rc")" "1" "workflow に判定の呼び出しの印がない → 止まる"
    assert_output_contains "$out" "wf-release.yml" "  → 該当するファイル名"
    _teardown "$repo"
    _setup; repo=$(_make_repo 'main\nstaging\ndevelop\n' block); out=$(_rt "$repo" develop 0 'y\n')
    assert_equals "$(cat "$MB/rc")" "1" "判定の部分が雛形と違う → 止まる"
    assert_output_contains "$out" "wf-validate.yml" "  → 該当するファイル名"
    _teardown "$repo"
    _setup; repo=$(_make_repo 'main\nstaging\ndevelop\n' msold); out=$(_rt "$repo" develop 0 'y\n')
    assert_equals "$(cat "$MB/rc")" "1" "wf-metasync.yml が自分で push する → 止まる"
    assert_output_contains "$out" "wf-metasync.yml" "  → 該当するファイル名"
    _teardown "$repo"
    _setup; repo=$(_make_repo 'main\nstaging\ndevelop\n' new); out=$(_rt "$repo" develop 0 'n\n')
    assert_equals "$(cat "$MB/rc")" "1" "確認で N → 止まる"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh pr create" "  → PR を作らない"
    _teardown "$repo"
    _setup; repo=$(_make_repo 'main\nstaging\ndevelop\n' new); echo x > "$repo/dirty.txt"; out=$(_rt "$repo" develop 0 'y\n')
    assert_equals "$(cat "$MB/rc")" "1" "未コミットの変更がある → 止まる"
    _teardown "$repo"
}

test_remove_staging_ok() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] staging を外す（develop がない）→ Ruleset を表示する${CLR_RST}"
    _setup
    local repo out
    repo=$(_make_repo 'main\nstaging\n' new)
    out=$(_rt "$repo" staging 0 'y\n')
    assert_equals "$(cat "$MB/rc")" "0" "成功する"
    assert_output_contains "$out" "staging を対象にする Ruleset: protect-staging" "影響 d: protect-staging を表示する（変えない）"
    _teardown "$repo"
}

test_purge() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] --purge-secrets${CLR_RST}"
    local repo out
    _setup; repo=$(_make_repo 'main\nstaging\ndevelop\n' new); out=$(_rt "$repo" develop 1 'y\n')
    assert_equals "$(cat "$MB/rc")" "1" "行がまだある（PR が未マージ）→ 止まる"
    assert_file_not_contains "$MOCK_CALL_LOG" "delete" "  → 何も消さない"
    _teardown "$repo"
    _setup; repo=$(_make_repo 'main\nstaging\n' old); out=$(_rt "$repo" develop 1 'y\n')
    assert_equals "$(cat "$MB/rc")" "0" "行がない → 消す（workflow の確かめはしない）"
    assert_file_contains "$MOCK_CALL_LOG" "gh secret delete SF_CONSUMER_KEY_DEV" "Secret（SF_CONSUMER_KEY_DEV）を消す"
    assert_file_contains "$MOCK_CALL_LOG" "gh variable delete SF_USERNAME_DEV" "Variable（SF_USERNAME_DEV）を消す"
    assert_file_contains "$MOCK_CALL_LOG" "gh variable delete SF_ORG_ID_DEV" "Variable（SF_ORG_ID_DEV）を消す"
    assert_file_not_contains "$MOCK_CALL_LOG" "SF_PRIVATE_KEY" "決まった名前のほか（SF_PRIVATE_KEY）は消さない"
    assert_file_not_contains "$MOCK_CALL_LOG" "delete SF_USERNAME_PROD" "ほかの段階（PROD）は消さない"
    _teardown "$repo"
    _setup; export MOCK_GH_DELETE_FAIL="SF_INSTANCE_URL_DEV"; repo=$(_make_repo 'main\nstaging\n' new); out=$(_rt "$repo" develop 1 'y\n')
    assert_equals "$(cat "$MB/rc")" "1" "一部が消せない → 終了コード 1"
    assert_output_contains "$out" "残っているものだけを消します" "  → もう一度の実行を案内する"
    unset MOCK_GH_DELETE_FAIL; : > "$MOCK_CALL_LOG"
    out=$(_rt "$repo" develop 1 'y\n')
    assert_equals "$(cat "$MB/rc")" "0" "もう一度実行 → 残りだけを消して成功"
    assert_file_contains "$MOCK_CALL_LOG" "gh variable delete SF_INSTANCE_URL_DEV" "  → 残っていたものを消す"
    assert_file_not_contains "$MOCK_CALL_LOG" "gh secret delete SF_CONSUMER_KEY_DEV" "  → 消したものは、もう消さない"
    out=$(_rt "$repo" develop 1 '')
    assert_equals "$(cat "$MB/rc")" "0" "消すものがない → 確認なしで成功"
    assert_output_contains "$out" "消すものはありません" "  → その旨を表示する"
    _teardown "$repo"
}

test_sf_init_args() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] sf-project.sh の引数${CLR_RST}"
    local mb out rc
    mb=$(setup_mock_bin)
    out=$( cd "$mb" && HOME="$mb" bash "$SF_TOOLS_DIR/bin/sf-project.sh" --remove-tier < /dev/null 2>&1 ); rc=$?
    assert_exit_fail "$rc" "--remove-tier の値なし → 終了する"
    assert_output_contains "$out" "外す段階" "  → 理由"
    out=$( cd "$mb" && HOME="$mb" bash "$SF_TOOLS_DIR/bin/sf-project.sh" --purge-secrets < /dev/null 2>&1 ); rc=$?
    assert_exit_fail "$rc" "--purge-secrets だけ → 終了する"
    assert_output_contains "$out" "remove-tier と一緒に" "  → 理由"
    out=$( cd "$mb" && HOME="$mb" bash "$SF_TOOLS_DIR/bin/sf-project.sh" --add-tier develop --remove-tier develop < /dev/null 2>&1 ); rc=$?
    assert_exit_fail "$rc" "--add-tier と --remove-tier の同時指定 → 終了する"
    assert_output_contains "$out" "同時に指定できません" "  → 理由"
    out=$( cd "$mb" && HOME="$mb" bash "$SF_TOOLS_DIR/bin/sf-project.sh" --purge-secrets --remove-tier develop < /dev/null 2>&1 ); rc=$?
    assert_output_contains "$out" "tier を外すモード: develop（--purge-secrets）" "順を入れ替えても、--purge-secrets のモードになる"
    rm -rf "$mb"
}

# add_tier.sh（戻すとき）: 接続情報が残っていれば、つなぎ直さずに PR だけ作れる（doc/tier-scaling-design.md 6 章）
_at() {  # 1=作業ディレクトリ  2=標準入力
    ( cd "$1" && printf "$2" | HOME="$MH" PATH="$MB:$PATH" SF_TOOLS_DIR="$SF_TOOLS_DIR" ADD_TIER=develop         GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t         bash "$SF_TOOLS_DIR/phases/init/add_tier.sh" ) > "$MB/out" 2>&1
    echo $? > "$MB/rc"
    cat "$MB/out"
}
test_add_tier_reuse() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] --add-tier: つなぎ直さずに戻す${CLR_RST}"
    local repo out pr_branch
    _setup; repo=$(_make_repo 'main
staging
' new)
    # 段階を外しているあいだに main が進んだ（develop には伝播されていない）状態にする
    ( cd "$repo" && export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t         && git checkout -q main && echo z > z.txt && git add z.txt && git commit -q -m z && git push -q origin main && git checkout -q admin ) > /dev/null 2>&1
    out=$(_at "$repo" 'y
y
')
    assert_equals "$(cat "$MB/rc")" "0" "接続情報が 3 つとも残っている・Y → 成功する"
    assert_output_contains "$out" "接続情報が、GitHub に残っています" "  → 残っていることを表示する"
    assert_output_contains "$out" "SF_USERNAME_DEV=値" "  → 残っている情報（Variable）を表示する"
    assert_output_not_contains "$out" "秘密鍵が見つかりません" "  → つなぎ直さない（JWT の鍵を見ない）"
    assert_output_contains "$out" "main より 1 コミット遅れています" "  → 残っていたブランチの遅れを表示する"
    git -C "$repo" fetch -q origin
    pr_branch=$(git -C "$repo" ls-remote --heads origin 'system-add-tier-develop-*' | awk '{print $2}' | sed 's#refs/heads/##')
    assert_equals "$(git -C "$repo" show "origin/${pr_branch}:sf-tools/config/branches.txt" | tail -1)" "develop" "  → branches.txt に develop を戻す PR"
    _teardown "$repo"
    _setup; repo=$(_make_repo 'main
staging
' new)
    out=$(_at "$repo" 'y
n
')
    assert_equals "$(cat "$MB/rc")" "1" "N → つなぎ直す（この環境では JWT の鍵がないため止まる）"
    assert_output_contains "$out" "秘密鍵が見つかりません" "  → つなぎ直しに進む"
    _teardown "$repo"
    local miss
    for miss in "S SF_CONSUMER_KEY_DEV" "V SF_USERNAME_DEV" "V SF_INSTANCE_URL_DEV"; do
        _setup; grep -vx "$miss" "$MOCK_GH_STATE" > "$MOCK_GH_STATE.t"; mv "$MOCK_GH_STATE.t" "$MOCK_GH_STATE"
        repo=$(_make_repo 'main
staging
' new)
        out=$(_at "$repo" 'y
')
        assert_output_not_contains "$out" "つなぎ直さずに、段階だけ戻しますか" "${miss#? } が欠けている → 聞かずに、つなぎ直す"
        assert_output_contains "$out" "秘密鍵が見つかりません" "  → つなぎ直しに進む"
        _teardown "$repo"
    done
}

# status.sh の【段階の切り替え】（doc/tier-scaling-design.md 7 章）
_st() {  # 1=作業ディレクトリ
    ( cd "$1" && HOME="$MH" PATH="$MB:$PATH" SF_TOOLS_DIR="$SF_TOOLS_DIR" bash "$SF_TOOLS_DIR/phases/init/status.sh" ) > "$MB/out" 2>&1
    echo $? > "$MB/rc"
    cat "$MB/out"
}
test_status_tier_switch() {
    echo ""
    echo -e "${CLR_HEAD}[TEST] --status: 段階の切り替えの診断${CLR_RST}"
    local repo out
    _setup; repo=$(_make_repo 'main
staging
uat
' new); export MOCK_GH_STB="feature-x"
    out=$(_st "$repo")
    assert_output_contains "$out" "有効な段階: main staging" "有効な段階を表示する"
    assert_output_contains "$out" "develop ブランチは残っていますが、段階としては無効" "無効の段階のブランチが残っている → INFO"
    assert_output_contains "$out" "develop の接続情報が残っています" "無効の段階の接続情報が残っている → INFO"
    assert_output_contains "$out" "「uat」は、段階の名前" "段階の名前でない行 → WARNING"
    assert_output_contains "$out" "SF_TOOLS_BRANCH が「feature-x」" "SF_TOOLS_BRANCH が想定外 → WARNING"
    assert_output_not_contains "$out" "段階の切り替えに対応していません" "雛形と同じ workflow → 対応の WARNING は出ない"
    unset MOCK_GH_STB; _teardown "$repo"
    _setup; repo=$(_make_repo 'main
staging
develop
' old)
    out=$(_st "$repo")
    assert_output_contains "$out" "段階の切り替えに対応していません" "古い workflow → WARNING"
    assert_output_contains "$out" "wf-release.yml" "  → 該当するファイル名"
    _teardown "$repo"
    _setup; repo=$(_make_repo 'main
develop
' new)
    out=$(_st "$repo")
    assert_output_contains "$out" "staging がないため、develop は段階として無効" "develop だけ → ERROR"
    assert_equals "$(cat "$MB/rc")" "1" "  → 終了コード 1"
    _teardown "$repo"
}

test_remove_develop_ok
test_status_tier_switch
test_add_tier_reuse
test_remove_refusals
test_remove_staging_ok
test_purge
test_sf_init_args

print_summary
