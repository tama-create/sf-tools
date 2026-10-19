#!/bin/bash
# ==============================================================================
# test_integration-secrets.sh - 結合テスト L1: 秘密情報（成功でも失敗でも、漏れない）
# ==============================================================================
# sf-update-secret を、実際の git と fake の gh・sf で動かし、秘密鍵・コンシューマーキー（目印の文字列）が、
# 画面・ログ・呼び出しの記録・一時ファイルに、残らないことを確かめる。
# ハーネスと fake は tests/integration/lib.sh。計画: doc/integration-test-plan.md の 6.7
#
# 【シナリオ】
#   X7-1  秘密鍵の更新・コンシューマーキーの更新: 成功時も、失敗時（接続テストの失敗・gh secret set の失敗）も、秘密が漏れない
#   X7-2  終了後の一時ファイル（一時的なホームなど）が、残らない
#   B2L   更新した値が、期待どおりに、GitHub の fake に入る（CR を除いた秘密鍵の base64・コンシューマーキー）
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
source "$(dirname "${BASH_SOURCE[0]}")/integration/lib.sh"
echo -e "${CLR_HEAD}=== 結合テスト L1: 秘密情報 ===${CLR_RST}"

trap 'it_teardown' EXIT

KEY_MARK="ITPRIVKEY-7f3a9c"      # 秘密鍵の中の目印
CKEY_MARK="ITCONSUMERKEY-52b1e8" # コンシューマーキーの目印
KEY_INPUT=""

# 秘密の目印が、利用者に見える場所（画面の出力・ログのフォルダ・一時ファイル）に、残っていないこと。引数: 目印 説明
#   fake の呼び出しの記録（state/calls.log）と、故障注入の設定は、検査しない（コマンドへ渡した引数の記録であり、製品の出力ではない）
_leaks() { local d; grep -rlF -- "$1" "$IT_ROOT"/out.*.txt "$IT_ROOT/tmp" $(find "$IT_ROOT" -type d -name logs -not -path "*/.git/*" 2>/dev/null) 2>/dev/null; }
_no_leak() {
    local l; l=$(_leaks "$1")
    [[ -z "$l" ]] && pass "X7-1: ${2} に、秘密が残らない" || fail "X7-1: ${2} に、秘密が残らない" "残っている場所: $(echo "$l" | head -3 | tr '
' ' ')"
}
# 一時ファイル（サンドボックスの TMPDIR）に、何も残っていないこと
_tmp_clean() {
    local n; n=$(find "$IT_ROOT/tmp" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')
    [[ "$n" == "0" ]] && pass "X7-2: ${1} の後に、一時ファイルが残らない" || fail "X7-2: ${1} の後に、一時ファイルが残らない" "$(find "$IT_ROOT/tmp" -mindepth 1 2>/dev/null | head -3 | tr '\n' ' ')"
}

test_setup() {
    it_setup || { fail "サンドボックスの作成"; return 1; }
    it_seed_repo 1 || { fail "リポジトリの生成"; return 1; }
    it_make_clone devA JOB-A || { fail "クローンの作成" "$(it_out)"; return 1; }
    CL="$IT_CL"
    # 秘密鍵（CRLF の形。目印入り）。入力用のファイルは itkey.input（漏れの検査から除く）。JWT_DIR の server.key も用意する
    KEY_INPUT="$IT_ROOT/itkey.input"
    printf -- '-----BEGIN PRIVATE KEY-----\r\n%s\r\nAAAA\r\n-----END PRIVATE KEY-----\r\n' "$KEY_MARK" > "$KEY_INPUT"
    mkdir -p "$IT_HOME/.sf-jwt/$IT_REPO"
    cp "$KEY_INPUT" "$IT_HOME/.sf-jwt/$IT_REPO/itkey.input"
    cp "$KEY_INPUT" "$IT_HOME/.sf-jwt/$IT_REPO/server.key"
    mkdir -p "$IT_STATE/variables"; printf '%s' "it@example.invalid" > "$IT_STATE/variables/SF_USERNAME_PROD"
    pass "準備: クローンと秘密鍵の入力ファイルを作った"
    # 検査の自己確認（陽性対照）: 目印を出力するコマンドを動かすと、漏れとして検出される。検出できない検査は、意味がない
    it_run "$CL" echo "$KEY_MARK"
    [[ -n "$(_leaks "$KEY_MARK")" ]] && pass "準備: 漏れの検査は、目印を出力すると検出する（陽性対照）" || fail "準備: 漏れの検査は、目印を出力すると検出する（陽性対照）"
    rm -f "$IT_OUT"
}

test_private_key() {
    echo -e "\n${CLR_HEAD}--- X7-1・B2L: 秘密鍵の更新 ---${CLR_RST}"
    local want got
    it_calls_clear
    it_run "$CL" -i "Y\n1\n${KEY_INPUT}\nY\n" bash "$IT_HOME/sf-tools/bin/sf-update-secret.sh"
    assert_exit_ok "$IT_RC" "B2L: 秘密鍵の更新が成功する"
    assert_file_exists "$IT_STATE/secrets/SF_PRIVATE_KEY" "B2L: SF_PRIVATE_KEY が、GitHub の fake に入る"
    want=$(printf -- '-----BEGIN PRIVATE KEY-----\n%s\nAAAA\n-----END PRIVATE KEY-----\n' "$KEY_MARK" | base64_oneline)
    got=$(cat "$IT_STATE/secrets/SF_PRIVATE_KEY" 2>/dev/null)
    assert_equals "$got" "$want" "B2L: 入る値は、CR を除いた秘密鍵の base64"
    assert_equals "$(it_calls gh | grep -c 'secret set SF_PRIVATE_KEY')" "1" "B2L: gh secret set が 1 回呼ばれる（値は引数に出ない）"
    _no_leak "$KEY_MARK" "秘密鍵の更新（成功）の出力・ログ・一時ファイル"
    _tmp_clean "秘密鍵の更新"
}

test_consumer_key() {
    echo -e "\n${CLR_HEAD}--- X7-1・B2L・X7-2: コンシューマーキーの更新 ---${CLR_RST}"
    # 成功
    it_calls_clear
    it_run "$CL" -i "Y\n2\n1\n${CKEY_MARK}\nY\n1\n" bash "$IT_HOME/sf-tools/bin/sf-update-secret.sh"
    assert_exit_ok "$IT_RC" "B2L: コンシューマーキーの更新が成功する"
    assert_equals "$(cat "$IT_STATE/secrets/SF_CONSUMER_KEY_PROD" 2>/dev/null)" "$CKEY_MARK" "B2L: SF_CONSUMER_KEY_PROD に、入力した値が入る"
    assert_equals "$(it_calls sf | grep -c 'org login jwt')" "1" "B2L: JWT の接続テストが、更新の前に行われる"
    _no_leak "$CKEY_MARK" "コンシューマーキーの更新（成功）の出力・ログ・一時ファイル"
    _tmp_clean "コンシューマーキーの更新（成功）"

    # 失敗 1: JWT の接続テストが失敗（エラー出力に、キーが含まれる）→ 更新されない・秘密がマスクされる
    rm -f "$IT_STATE/secrets/SF_CONSUMER_KEY_PROD"
    it_fault_clear
    it_fault sf "org login jwt*" 1 99 1 "ERROR: invalid client-id ${CKEY_MARK} for the connected app"
    it_calls_clear
    it_run "$CL" -i "Y\n2\n1\n${CKEY_MARK}\nY\n1\n" bash "$IT_HOME/sf-tools/bin/sf-update-secret.sh"
    assert_exit_fail "$IT_RC" "X7-1: JWT の接続テストが失敗すると、sf-update-secret が失敗で終わる"
    assert_file_not_exists "$IT_STATE/secrets/SF_CONSUMER_KEY_PROD" "X7-1: 接続テストが失敗したら、Secret を更新しない"
    it_out_has "masked" && pass "X7-1: 失敗の出力で、キーがマスクされる" || fail "X7-1: 失敗の出力で、キーがマスクされる"
    _no_leak "$CKEY_MARK" "接続テストの失敗時の出力・ログ・一時ファイル"
    _tmp_clean "接続テストの失敗"

    # 失敗 2: gh secret set が失敗 → 失敗で終わる・秘密が残らない
    it_fault_clear
    it_fault gh "secret set*" 1 99 1 "HTTP 403: Resource not accessible by personal access token"
    it_calls_clear
    it_run "$CL" -i "Y\n2\n1\n${CKEY_MARK}\nY\n1\n" bash "$IT_HOME/sf-tools/bin/sf-update-secret.sh"
    assert_exit_fail "$IT_RC" "X7-1: gh secret set が失敗すると、sf-update-secret が失敗で終わる"
    assert_file_not_exists "$IT_STATE/secrets/SF_CONSUMER_KEY_PROD" "X7-1: 書き込みに失敗したら、値は入らない"
    _no_leak "$CKEY_MARK" "gh secret set の失敗時の出力・ログ・一時ファイル"
    _tmp_clean "gh secret set の失敗"
    it_fault_clear
}

test_private_key_failure() {
    echo -e "\n${CLR_HEAD}--- X7-1: 秘密鍵の更新の失敗 ---${CLR_RST}"
    rm -f "$IT_STATE/secrets/SF_PRIVATE_KEY"
    it_fault_clear
    it_fault gh "secret set*" 1 99 1 "HTTP 403: Resource not accessible by personal access token"
    it_calls_clear
    it_run "$CL" -i "Y\n1\n${KEY_INPUT}\nY\n" bash "$IT_HOME/sf-tools/bin/sf-update-secret.sh"
    assert_exit_fail "$IT_RC" "X7-1: 秘密鍵の gh secret set が失敗すると、失敗で終わる"
    _no_leak "$KEY_MARK" "秘密鍵の更新の失敗時の出力・ログ・一時ファイル"
    _tmp_clean "秘密鍵の更新の失敗"
    it_fault_clear
}

_it_timed() { local t0=$SECONDS rc; "$@"; rc=$?; echo "  （所要時間: $1 = $((SECONDS - t0)) 秒）"; return $rc; }

test_setup || { print_summary; exit 1; }
for _sc in ${IT_SCENARIOS:-private_key consumer_key private_key_failure}; do
    _it_timed "test_${_sc}" || break
done

print_summary
