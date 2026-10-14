#!/bin/bash
# ==============================================================================
# test_init-common.sh - phases/init/init-common.sh の ensure_sf_tools_branch・JWT 用の証明書（発行先 subject）のテスト
# ==============================================================================
# 実際の Git（一時ディレクトリのローカル bare リポジトリ）を使う。外部ネットワークには接続しない。
#
# 【テストケース】
#   1. 最新・同じブランチ                → 通過
#   2. 遅れ + Y                          → pull して、戻り値 2（呼び出し側が、実行しなおす）
#   3. 遅れ + N                          → 更新せず続行
#   4. ブランチ違い + N                  → 中断
#   5. ブランチ違い + Y                  → 続行
#   6. 未コミット変更あり + 遅れ         → 更新せず続行
#   7. git fetch 失敗                    → 警告して続行
#   8. 遅れ + q                          → 中断
#   9. Git リポジトリでない              → 警告して続行
#  10. JWT 用の証明書                    → 発行先（subject）が空でない / 空なら、秘密鍵はそのままで証明書だけ作り直す
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== init-common.sh (ensure_sf_tools_branch) ===${CLR_RST}"

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

# origin(bare) と、更新用の作業用 clone(w)、検証対象の clone(sf-tools: development) を作る
# 戻り値: ベースディレクトリ
_mk_repos() {
    local b
    b=$(mktemp -d "${TMPDIR:-/tmp}/test-esb-XXXX")
    git init -q --bare "$b/origin.git"
    git clone -q "$b/origin.git" "$b/w" 2>/dev/null
    (
        cd "$b/w" || exit 1
        git checkout -q -b main && echo 1 > f && git add f && git commit -qm c1 && git push -q origin main
        git checkout -q -b development && echo 2 > f && git commit -qam c2 && git push -q origin development
    ) > /dev/null 2>&1
    git clone -q "$b/origin.git" "$b/sf-tools" 2>/dev/null
    git -C "$b/sf-tools" checkout -q development
    echo "$b"
}

# origin の development に新しいコミットを 1 つ追加する（検証対象を遅れさせる）
_advance_origin() {
    (
        cd "$1/w" || exit 1
        git checkout -q development && echo "$RANDOM" >> f && git commit -qam "new" && git push -q origin development
    ) > /dev/null 2>&1
}

# ensure_sf_tools_branch を単体で実行する
# 引数: $1=ベースdir（SF_TOOLS_DIR は $1/sf-tools）, $2=目標ブランチ, $3=標準入力
_run_esb() {
    printf '%b' "$3" | (
        export SF_INIT_MODE=1
        export SF_TOOLS_DIR="${4:-$1/sf-tools}"
        readonly SCRIPT_NAME=test
        readonly LOG_FILE=/dev/null
        readonly LOG_MODE=NEW
        source "${SF_TOOLS_DIR_REPO}/lib/common.sh"
        source "${SF_TOOLS_DIR_REPO}/phases/init/init-common.sh"
        ensure_sf_tools_branch "$2"
    ) > "$1/out.log" 2>&1
}
SF_TOOLS_DIR_REPO="$SF_TOOLS_DIR"

test_esb_up_to_date() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 最新・同じブランチ → 通過${CLR_RST}"
    local b; b=$(_mk_repos)
    _run_esb "$b" development ""
    assert_exit_ok $? "最新 → 終了コード 0"
    assert_file_contains "$b/out.log" "最新です" "「最新です」と表示される"
    teardown "$b"
}

test_esb_behind_yes() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 遅れ + Y → pull して中断${CLR_RST}"
    local b before after
    b=$(_mk_repos); _advance_origin "$b"
    before=$(git -C "$b/sf-tools" rev-list --count HEAD)
    _run_esb "$b" development 'Y\n'
    assert_equals "$?" "2" "遅れ + Y → 戻り値 2（更新した。呼び出し側が、実行しなおす）"
    after=$(git -C "$b/sf-tools" rev-list --count HEAD)
    [[ "$after" -eq $((before + 1)) ]] && pass "pull で 1 コミット進んだ" || fail "pull で 1 コミット進んだ" "前=${before} 後=${after}"
    assert_file_contains "$b/out.log" "更新しました" "更新した旨が表示される"
    teardown "$b"
}

test_esb_behind_no() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 遅れ + N → 更新せず続行${CLR_RST}"
    local b before after
    b=$(_mk_repos); _advance_origin "$b"
    before=$(git -C "$b/sf-tools" rev-list --count HEAD)
    _run_esb "$b" development 'N\n'
    assert_exit_ok $? "遅れ + N → 終了コード 0"
    after=$(git -C "$b/sf-tools" rev-list --count HEAD)
    [[ "$after" -eq "$before" ]] && pass "更新されていない" || fail "更新されていない" "前=${before} 後=${after}"
    teardown "$b"
}

test_esb_branch_mismatch_no() {
    echo ""; echo -e "${CLR_HEAD}[TEST] ブランチ違い + N → 中断${CLR_RST}"
    local b; b=$(_mk_repos)
    _run_esb "$b" main 'N\n'
    assert_exit_fail $? "ブランチ違い + N → 中断"
    assert_file_contains "$b/out.log" "選択した環境は main です" "ブランチ違いの警告が表示される"
    teardown "$b"
}

test_esb_branch_mismatch_yes() {
    echo ""; echo -e "${CLR_HEAD}[TEST] ブランチ違い + Y → 続行${CLR_RST}"
    local b; b=$(_mk_repos)
    _run_esb "$b" main 'Y\n'
    assert_exit_ok $? "ブランチ違い + Y → 終了コード 0"
    teardown "$b"
}

test_esb_dirty_skips_update() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 未コミット変更あり + 遅れ → 更新せず続行${CLR_RST}"
    local b before after
    b=$(_mk_repos); _advance_origin "$b"
    echo dirty >> "$b/sf-tools/f"
    before=$(git -C "$b/sf-tools" rev-list --count HEAD)
    _run_esb "$b" development ""
    assert_exit_ok $? "未コミット変更あり → 終了コード 0（確認なしで続行）"
    after=$(git -C "$b/sf-tools" rev-list --count HEAD)
    [[ "$after" -eq "$before" ]] && pass "更新されていない" || fail "更新されていない" "前=${before} 後=${after}"
    assert_file_contains "$b/out.log" "更新しません" "更新しない旨が表示される"
    teardown "$b"
}

test_esb_fetch_failure() {
    echo ""; echo -e "${CLR_HEAD}[TEST] git fetch 失敗 → 警告して続行${CLR_RST}"
    local b; b=$(_mk_repos)
    git -C "$b/sf-tools" remote set-url origin "$b/nonexistent.git"
    _run_esb "$b" development ""
    assert_exit_ok $? "fetch 失敗 → 終了コード 0"
    assert_file_contains "$b/out.log" "接続できなかった" "確認をスキップした旨が表示される"
    teardown "$b"
}

test_esb_behind_quit() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 遅れ + q → 中断${CLR_RST}"
    local b; b=$(_mk_repos); _advance_origin "$b"
    _run_esb "$b" development 'q\n'
    assert_exit_fail $? "遅れ + q → 中断"
    teardown "$b"
}

test_esb_not_a_repo() {
    echo ""; echo -e "${CLR_HEAD}[TEST] Git リポジトリでない → 警告して続行${CLR_RST}"
    local b; b=$(mktemp -d "${TMPDIR:-/tmp}/test-esb-XXXX")
    mkdir -p "$b/plain"
    _run_esb "$b" development "" "$b/plain"
    assert_exit_ok $? "Git リポジトリでない → 終了コード 0"
    assert_file_contains "$b/out.log" "Git リポジトリではない" "スキップした旨が表示される"
    teardown "$b"
}

# ------------------------------------------------------------------------------
# JWT 用の証明書: 発行先（subject）が空の証明書を作らない・直す
#   Mac・Linux で -subj "//CN=…" を渡すと、発行先が空の証明書ができ、Salesforce が「証明書ではありません」と拒否した
#   （2026-10-14。Mac で sf-init を初めて通した実機）。実際の openssl を使う（モックにしない）
# ------------------------------------------------------------------------------
_jwt() {   # 引数: 式。common.sh と init-common.sh を読み込んだ子プロセスで評価する
    (
        export SF_INIT_MODE=1
        readonly SCRIPT_NAME=test LOG_FILE=/dev/null LOG_MODE=NEW
        source "${SF_TOOLS_DIR_REPO}/lib/common.sh"
        source "${SF_TOOLS_DIR_REPO}/phases/init/init-common.sh"
        eval "$1"
    ) 2>&1
}

test_jwt_cert_subject() {
    echo ""; echo -e "${CLR_HEAD}[TEST] JWT 用の証明書: 発行先（subject）が空でないこと${CLR_RST}"
    if ! command -v openssl > /dev/null 2>&1; then
        skip "openssl がないためスキップ"; return
    fi
    local td out rc sum1 sum2 key_sum
    td=$(mktemp -d "${TMPDIR:-/tmp}/test-jwt-XXXX")

    # -subj の値: Git Bash は //CN=、それ以外は /CN=
    out=$(_jwt 'OSTYPE=msys; _jwt_cert_subject_arg force-x')
    assert_equals "$out" "//CN=sf-jwt-force-x" "Git Bash: -subj は // で始める（Windows のパス変換の回避）"
    out=$(_jwt 'OSTYPE=darwin25; _jwt_cert_subject_arg force-x')
    assert_equals "$out" "/CN=sf-jwt-force-x" "macOS: -subj は / で始める"
    out=$(_jwt 'OSTYPE=linux-gnu; _jwt_cert_subject_arg force-x')
    assert_equals "$out" "/CN=sf-jwt-force-x" "Linux: -subj は / で始める"

    # 新規に生成した証明書には、発行先が入っている（この環境の OS の既定の書き方で）
    out=$(_jwt "generate_jwt_cert '$td/new' force-x"); rc=$?
    assert_equals "$rc" "0" "generate_jwt_cert: 生成できる（戻り値 0）"
    out=$(openssl x509 -in "$td/new/server.crt" -noout -subject 2>&1)
    assert_output_contains "$out" "sf-jwt-force-x" "生成した証明書に、発行先（CN=sf-jwt-force-x）が入っている"

    # 発行先が入っている既存の証明書は、触らない（鍵・証明書とも、そのまま）
    sum1=$(cksum < "$td/new/server.crt"); key_sum=$(cksum < "$td/new/server.key")
    _jwt "generate_jwt_cert '$td/new' force-x" > /dev/null
    sum2=$(cksum < "$td/new/server.crt")
    assert_equals "$sum2" "$sum1" "既存の（正常な）証明書は、作り直さない"
    assert_equals "$(cksum < "$td/new/server.key")" "$key_sum" "既存の秘密鍵は、変えない"

    # 発行先が空の証明書（以前の不具合でできたもの）を用意する。この環境の openssl で空にならなければ、スキップ
    mkdir -p "$td/bad"
    openssl genrsa -out "$td/bad/server.key" 2048 > /dev/null 2>&1
    openssl req -new -x509 -days 3650 -key "$td/bad/server.key" -out "$td/bad/server.crt" -subj "//CN=sf-jwt-force-x" > /dev/null 2>&1
    out=$(_jwt "_jwt_cert_subject_state '$td/bad/server.crt'; echo \"state=\$?\"")
    if [[ "$out" != *"state=1"* ]]; then
        skip "発行先が空の証明書を、この環境の openssl では作れないため、作り直しのテストはスキップ（state: ${out}）"
    else
        assert_output_contains "$out" "state=1" "空の発行先を、検出できる（戻り値 1）"
        key_sum=$(cksum < "$td/bad/server.key")
        out=$(_jwt "ensure_jwt_cert_subject '$td/bad' force-x"); rc=$?
        assert_equals "$rc" "0" "ensure_jwt_cert_subject: 空の証明書を、作り直せる（戻り値 0）"
        assert_output_contains "$out" "証明書だけを作り直します" "作り直す旨が表示される"
        out=$(openssl x509 -in "$td/bad/server.crt" -noout -subject 2>&1)
        assert_output_contains "$out" "sf-jwt-force-x" "作り直した証明書に、発行先が入っている"
        assert_equals "$(cksum < "$td/bad/server.key")" "$key_sum" "秘密鍵は、変わらない（GitHub の SF_PRIVATE_KEY と、ずれない）"
        assert_equals "$([[ -e "$td/bad/server.crt.tmp" ]] && echo yes || echo no)" "no" "一時ファイルを残さない"
        # 公開鍵が同じこと（作り直した証明書は、同じ秘密鍵に対応する）
        assert_equals "$(openssl x509 -in "$td/bad/server.crt" -noout -pubkey 2>/dev/null | cksum)" \
                      "$(openssl rsa -in "$td/bad/server.key" -pubout 2>/dev/null | cksum)" "作り直した証明書は、同じ秘密鍵に対応する"
    fi

    # 証明書ではないファイルは、触らない（読み取れない = 戻り値 2。作り直さない）
    mkdir -p "$td/junk"
    printf 'not a certificate\n' > "$td/junk/server.crt"; cp "$td/new/server.key" "$td/junk/server.key"
    out=$(_jwt "_jwt_cert_subject_state '$td/junk/server.crt'; echo \"state=\$?\"")
    assert_output_contains "$out" "state=2" "証明書ではないファイル: 読み取れない（戻り値 2）"
    _jwt "ensure_jwt_cert_subject '$td/junk' force-x" > /dev/null
    assert_equals "$(cat "$td/junk/server.crt")" "not a certificate" "証明書ではないファイルは、作り直さない（触らない）"

    rm -rf "$td"
}

# 生成した証明書の発行先が空なら、generate_jwt_cert は中断する（モックの openssl で、空の発行先を再現する）
test_jwt_cert_empty_subject_dies() {
    echo ""; echo -e "${CLR_HEAD}[TEST] 生成した証明書の発行先が空 → 中断する（モックの openssl）${CLR_RST}"
    local mb td out rc
    mb=$(setup_mock_bin); create_mock_openssl "$mb"
    td=$(mktemp -d "${TMPDIR:-/tmp}/test-jwtm-XXXX")

    out=$(PATH="$mb:$PATH" MOCK_OPENSSL_SUBJECT="" _jwt "generate_jwt_cert '$td/j' force-x; echo \"RC=\$?\""); rc=$?
    assert_output_contains "$out" "発行先（subject）が空" "発行先が空 → 理由が表示される"
    assert_equals "$([[ "$out" == *"RC=0"* ]] && echo continued || echo stopped)" "stopped" "発行先が空 → 中断する（続行しない）"

    out=$(PATH="$mb:$PATH" _jwt "generate_jwt_cert '$td/ok' force-x; echo \"RC=\$?\"")
    assert_output_contains "$out" "RC=0" "発行先が入っていれば → 正常に完了する"

    teardown "$mb"; rm -rf "$td"
}

test_esb_up_to_date
test_jwt_cert_subject
test_jwt_cert_empty_subject_dies
test_esb_behind_yes
test_esb_behind_no
test_esb_branch_mismatch_no
test_esb_branch_mismatch_yes
test_esb_dirty_skips_update
test_esb_fetch_failure
test_esb_behind_quit
test_esb_not_a_repo

print_summary
