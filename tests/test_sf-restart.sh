#!/bin/bash
# ==============================================================================
# test_sf-restart.sh - sf-restart.sh のテスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-restart.sh ===${CLR_RST}"

# 設定ファイルがクリアされる
test_clears_config_files() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    echo '{"target-org":"oldorg"}' > "$td/.sf/config.json"
    echo '{"defaultusername":"oldorg"}' > "$td/.sfdx/sfdx-config.json"

    # sf-start.sh スタブを bin/ に作成
    mkdir -p "$mh/sf-tools/bin"
    cat > "$mh/sf-tools/bin/sf-start.sh" << 'EOF'
#!/bin/bash
echo "sf-start called FORCE_RELOGIN=$FORCE_RELOGIN" >> "$MOCK_CALL_LOG"
exit 0
EOF
    chmod +x "$mh/sf-tools/bin/sf-start.sh"

    cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$mh/sf-tools/bin/sf-restart.sh" 2>&1 >/dev/null

    assert_file_not_exists "$td/.sf/config.json" ".sf/config.json がクリアされた"
    assert_file_not_exists "$td/.sfdx/sfdx-config.json" ".sfdx/sfdx-config.json がクリアされた"
    teardown "$td" "$mb" "$mh"
}

# sf-start.sh が FORCE_RELOGIN=1 で呼び出される
test_calls_sf_start_with_force_relogin() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"

    mkdir -p "$mh/sf-tools/bin"
    cat > "$mh/sf-tools/bin/sf-start.sh" << 'EOF'
#!/bin/bash
echo "sf-start called FORCE_RELOGIN=$FORCE_RELOGIN" >> "$MOCK_CALL_LOG"
exit 0
EOF
    chmod +x "$mh/sf-tools/bin/sf-start.sh"

    cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$mh/sf-tools/bin/sf-restart.sh" 2>&1 >/dev/null

    assert_file_contains "$MOCK_CALL_LOG" "FORCE_RELOGIN=1" "sf-start.sh が FORCE_RELOGIN=1 で呼び出された"
    teardown "$td" "$mb" "$mh"
}

# 回帰: sf-start.sh が失敗したら、削除した設定ファイルを戻す（以前は、2 つとも消えたままだった）
test_restores_config_on_failure() {
    local td mb mh out ec
    setup_std_env td mb mh
    create_all_mocks "$mb"
    echo '{"target-org":"oldorg"}' > "$td/.sf/config.json"
    echo '{"defaultusername":"oldorg"}' > "$td/.sfdx/sfdx-config.json"
    mkdir -p "$mh/sf-tools/bin"
    printf '#!/bin/bash
exit 1
' > "$mh/sf-tools/bin/sf-start.sh"     # 設定ファイルを書かずに失敗する
    chmod +x "$mh/sf-tools/bin/sf-start.sh"

    out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$mh/sf-tools/bin/sf-restart.sh" 2>&1)
    ec=$?

    assert_exit_fail "$ec" "sf-start.sh が失敗 → 終了コードも失敗"
    assert_file_contains "$td/.sf/config.json" "oldorg" "sf-start.sh が失敗 → .sf/config.json が元に戻る"
    assert_file_contains "$td/.sfdx/sfdx-config.json" "oldorg" "sf-start.sh が失敗 → .sfdx/sfdx-config.json が元に戻る"
    assert_output_contains "$out" "元の接続設定" "sf-start.sh が失敗 → 戻したことが表示される"

    # sf-start.sh が新しい設定を書いてから失敗したときは、新しい設定を、上書きしない
    printf '#!/bin/bash
echo "{\\"target-org\\":\\"neworg\\"}" > .sf/config.json
exit 1
' > "$mh/sf-tools/bin/sf-start.sh"
    (cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$mh/sf-tools/bin/sf-restart.sh" >/dev/null 2>&1)
    assert_file_contains "$td/.sf/config.json" "neworg" "新しい設定が書かれていれば、元の設定で上書きしない"
    # 退避用の一時フォルダは、残さない
    ls "${TMPDIR:-/tmp}"/sf-restart-* >/dev/null 2>&1         && fail "退避用の一時フォルダを残さない" "残っている"         || pass "退避用の一時フォルダを残さない"
    teardown "$td" "$mb" "$mh"
}

# 回帰: 退避（cp）に失敗したら、元の設定ファイルを消さずに中断する（以前は、退避の失敗を見ずに削除し、戻せなかった）
test_backup_failure_keeps_config() {
    local td mb mh out ec real_cp
    setup_std_env td mb mh
    create_all_mocks "$mb"
    echo '{"target-org":"oldorg"}' > "$td/.sf/config.json"
    echo '{"defaultusername":"oldorg"}' > "$td/.sfdx/sfdx-config.json"
    mkdir -p "$mh/sf-tools/bin"
    printf '#!/bin/bash\necho "sf-start called" >> "$MOCK_CALL_LOG"\nexit 1\n' > "$mh/sf-tools/bin/sf-start.sh"
    chmod +x "$mh/sf-tools/bin/sf-start.sh"
    # 退避先（sf-restart-XXXXXX）への cp だけ失敗させる。それ以外は、本物の cp を使う
    real_cp=$(command -v cp)
    cat > "$mb/cp" << CPEOF
#!/bin/bash
case "\${*: -1}" in */sf-restart-*) echo "cp: cannot create" >&2; exit 1 ;; esac
exec "$real_cp" "\$@"
CPEOF
    chmod +x "$mb/cp"

    out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$mh/sf-tools/bin/sf-restart.sh" 2>&1)
    ec=$?

    assert_exit_fail "$ec" "退避に失敗 → 中断する"
    assert_output_contains "$out" "を退避できません" "退避に失敗 → 理由を表示する"
    assert_file_contains "$td/.sf/config.json" "oldorg" "退避に失敗 → .sf/config.json を消さない"
    assert_file_contains "$td/.sfdx/sfdx-config.json" "oldorg" "退避に失敗 → .sfdx/sfdx-config.json を消さない"
    assert_file_not_contains "$MOCK_CALL_LOG" "sf-start called" "退避に失敗 → sf-start.sh を呼ばない"
    teardown "$td" "$mb" "$mh"
}

# sf-start.sh が成功したときは、元の設定を戻さない（新しい設定に置き換わる）
test_no_restore_on_success() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    echo '{"target-org":"oldorg"}' > "$td/.sf/config.json"
    mkdir -p "$mh/sf-tools/bin"
    printf '#!/bin/bash
exit 0
' > "$mh/sf-tools/bin/sf-start.sh"   # 何も書かずに成功する
    chmod +x "$mh/sf-tools/bin/sf-start.sh"
    (cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$mh/sf-tools/bin/sf-restart.sh" >/dev/null 2>&1)
    assert_file_not_exists "$td/.sf/config.json" "sf-start.sh が成功 → 元の設定を戻さない"
    teardown "$td" "$mb" "$mh"
}

# sf-start.sh が存在しない → エラー
test_no_sf_start() {
    local td mb mh
    setup_std_env td mb mh
    create_all_mocks "$mb"
    # sf-start.sh を bin/ に用意しない
    mkdir -p "$mh/sf-tools/bin"
    rm -f "$mh/sf-tools/bin/sf-start.sh"

    local out; out=$(cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$mh/sf-tools/bin/sf-restart.sh" 2>&1)
    local ec=$?

    assert_exit_fail $ec "sf-start.sh なし → エラー終了"
    teardown "$td" "$mb" "$mh"
}

# force-* 以外で実行 → エラー
test_outside_force_dir() {
    local rd mb mh
    rd=$(setup_regular_dir); mb=$(setup_mock_bin); export MOCK_CALL_LOG="$mb/calls.log"; mh=$(setup_mock_home)
    create_all_mocks "$mb"

    mkdir -p "$mh/sf-tools/bin"
    printf '#!/bin/bash\nexit 0\n' > "$mh/sf-tools/bin/sf-start.sh"
    chmod +x "$mh/sf-tools/bin/sf-start.sh"

    local out; out=$(cd "$rd" && HOME="$mh" PATH="$mb:$PATH" bash "$mh/sf-tools/bin/sf-restart.sh" 2>&1)
    local ec=$?

    assert_exit_fail $ec "force-* 外 → エラー終了"
    teardown "$rd" "$mb" "$mh"
}

test_clears_config_files
test_restores_config_on_failure
test_backup_failure_keeps_config
test_no_restore_on_success
test_calls_sf_start_with_force_relogin
test_no_sf_start
test_outside_force_dir

print_summary
