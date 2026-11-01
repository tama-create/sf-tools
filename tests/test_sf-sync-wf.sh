#!/bin/bash
# ==============================================================================
# test_sf-sync-wf.sh - sf-sync-wf.sh のテスト
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
echo -e "${CLR_HEAD}=== sf-sync-wf.sh ===${CLR_RST}"

# テスト環境を作る。force-* のフォルダ（td）・モックの bin（mb）・sf-tools 一式を置いた HOME（mh）
#   雛形（mh の sf-tools/templates/.github/workflows/）に、2 つのワークフローを置き、
#   プロジェクト（td の .github/workflows/）には、雛形と同じものをコピーしておく
#   使い方: _wf_env td mb mh
_wf_env() {
    # 結果は、最後に printf -v で、呼び出し元の変数に代入する（nameref は Bash 4.3 以降のため使わない）
    local _t _m _h
    setup_std_env _t _m _h
    create_all_mocks "$_m"
    local src="$_h/sf-tools/templates/.github/workflows"
    rm -rf "$src"; mkdir -p "$src" "$_t/.github/workflows"
    printf 'name: A\njobs:\n  a:\n    steps:\n      - run: echo new-a\n' > "$src/wf-a.yml"
    printf 'name: B\njobs:\n  b:\n    steps:\n      - run: echo new-b\n' > "$src/wf-b.yml"
    cp "$src/wf-a.yml" "$src/wf-b.yml" "$_t/.github/workflows/"
    export MOCK_GIT_BRANCH="system-20261006"
    printf -v "$1" '%s' "$_t"
    printf -v "$2" '%s' "$_m"
    printf -v "$3" '%s' "$_h"
}

# sf-sync-wf.sh を実行する。使い方: _wf_run td mb mh 標準入力 [引数...]
_wf_run() {
    local td="$1" mb="$2" mh="$3" input="$4"; shift 4
    printf '%b' "$input" | ( cd "$td" && HOME="$mh" PATH="$mb:$PATH" bash "$mh/sf-tools/bin/sf-sync-wf.sh" "$@" ) 2>&1
}

# --help → 説明が表示される
test_help() {
    local out ec
    out=$(bash "$SF_TOOLS_DIR/bin/sf-sync-wf.sh" --help 2>&1); ec=$?
    assert_exit_ok "$ec" "--help → 終了コード 0"
    assert_output_contains "$out" "sf-sync-wf.sh" "--help → スクリプト名が表示される"
    assert_output_contains "$out" "system-日付" "--help → 更新の手順（作業用ブランチの名前）が表示される"
}

# force-* 以外 / 環境ブランチ / 不明なオプション → 拒否される
test_guards() {
    local td mb mh out ec
    _wf_env td mb mh

    local rd; rd=$(setup_regular_dir)
    out=$( cd "$rd" && HOME="$mh" PATH="$mb:$PATH" bash "$mh/sf-tools/bin/sf-sync-wf.sh" 2>&1 < /dev/null ); ec=$?
    assert_exit_fail "$ec" "force-* 以外 → エラー終了"
    teardown "$rd"

    local b
    for b in main staging develop; do
        echo "changed" >> "$td/.github/workflows/wf-a.yml"
        out=$(MOCK_GIT_BRANCH="$b" _wf_run "$td" "$mb" "$mh" "Y"); ec=$?
        assert_exit_fail "$ec" "環境ブランチ（${b}）→ エラー終了"
        assert_output_contains "$out" "環境ブランチ" "環境ブランチ（${b}）→ 拒否の理由が表示される"
        grep -q "changed" "$td/.github/workflows/wf-a.yml" && pass "環境ブランチ（${b}）→ ファイルは変更されない" || fail "環境ブランチ（${b}）→ ファイルは変更されない"
        cp "$mh/sf-tools/templates/.github/workflows/wf-a.yml" "$td/.github/workflows/wf-a.yml"
    done

    out=$(_wf_run "$td" "$mb" "$mh" "" --unknown); ec=$?
    assert_exit_fail "$ec" "不明なオプション → エラー終了"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb" "$mh"
}

# 差分なし → 「最新です」で終了（確認を出さない）。CRLF だけの違いは、差分とみなさない
test_up_to_date() {
    local td mb mh out ec
    _wf_env td mb mh
    out=$(_wf_run "$td" "$mb" "$mh" "Y"); ec=$?
    assert_exit_ok "$ec" "差分なし → 終了コード 0"
    assert_output_contains "$out" "最新です" "差分なし → 「最新です」と表示される"
    assert_output_contains "$out" "管理者以外は、実行しないでください" "差分なしでも、冒頭に、管理者向けの警告ボックスが表示される"
    out=$(_wf_run "$td" "$mb" "$mh" "N"); ec=$?
    assert_exit_fail "$ec" "冒頭の確認で N → 中断（差分なしでも、確認を出す）"
    out=$(_wf_run "$td" "$mb" "$mh" "" --check); ec=$?
    assert_exit_ok "$ec" "--check → 確認なしで、終了コード 0（何も変更しないため）"
    echo "$out" | grep -q "管理者以外は、実行しないでください" && fail "--check → 警告ボックスを表示しない" || pass "--check → 警告ボックスを表示しない"

    sedi $'s/$/\r/' "$td/.github/workflows/wf-a.yml"   # CRLF にする（Windows の改行）
    out=$(_wf_run "$td" "$mb" "$mh" "Y"); ec=$?
    assert_exit_ok "$ec" "CRLF だけの違い → 終了コード 0"
    assert_output_contains "$out" "最新です" "CRLF だけの違い → 差分とみなさない"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb" "$mh"
}

# 差分あり: N / q → 変更しない。Y → 雛形の内容で上書き（新規ファイルも追加）
test_sync() {
    local td mb mh out ec
    _wf_env td mb mh
    local tmpl="$mh/sf-tools/templates/.github/workflows"
    echo "# project customized" >> "$td/.github/workflows/wf-a.yml"
    rm -f "$td/.github/workflows/wf-b.yml"   # このプロジェクトにない（新規）

    # 冒頭の確認で N / q → 差分を表示する前に中断する（何も変更しない）
    out=$(_wf_run "$td" "$mb" "$mh" "N"); ec=$?
    assert_exit_fail "$ec" "冒頭の確認で N → 中断（エラー終了）"
    assert_output_contains "$out" "管理者以外は、実行しないでください" "冒頭の確認 → 警告ボックスが表示される"
    echo "$out" | grep -q "差分あり: wf-a.yml" && fail "冒頭の確認で N → 差分は、表示されない" || pass "冒頭の確認で N → 差分は、表示されない"
    out=$(_wf_run "$td" "$mb" "$mh" "q"); ec=$?
    assert_exit_fail "$ec" "冒頭の確認で q → 中断（エラー終了）"
    grep -q "project customized" "$td/.github/workflows/wf-a.yml" && pass "冒頭の確認で N / q → ファイルは変更されない" || fail "冒頭の確認で N / q → ファイルは変更されない"

    out=$(_wf_run "$td" "$mb" "$mh" "YN"); ec=$?
    assert_exit_fail "$ec" "差分あり + 2 回目 N → 中断（エラー終了）"
    assert_output_contains "$out" "差分あり: wf-a.yml" "差分あり → 差分のあるファイルが表示される"
    assert_output_contains "$out" "new-a" "差分あり → diff の内容（雛形側）が表示される"
    assert_output_contains "$out" "新規（雛形にあり、このプロジェクトにない）: wf-b.yml" "差分あり → 新規のファイルが表示される"
    grep -q "project customized" "$td/.github/workflows/wf-a.yml" && pass "N → ファイルは変更されない" || fail "N → ファイルは変更されない"
    assert_file_not_exists "$td/.github/workflows/wf-b.yml" "N → 新規のファイルは、追加されない"

    out=$(_wf_run "$td" "$mb" "$mh" "Yq"); ec=$?
    assert_exit_fail "$ec" "差分あり + 2 回目 q → 中断（エラー終了）"
    grep -q "project customized" "$td/.github/workflows/wf-a.yml" && pass "q → ファイルは変更されない" || fail "q → ファイルは変更されない"

    out=$(_wf_run "$td" "$mb" "$mh" "YY"); ec=$?
    assert_exit_ok "$ec" "差分あり + Y → 終了コード 0"
    cmp -s "$tmpl/wf-a.yml" "$td/.github/workflows/wf-a.yml" && pass "Y → 差分のあるファイルが、雛形の内容になる" || fail "Y → 差分のあるファイルが、雛形の内容になる"
    cmp -s "$tmpl/wf-b.yml" "$td/.github/workflows/wf-b.yml" && pass "Y → 新規のファイルが追加される" || fail "Y → 新規のファイルが追加される"
    assert_output_contains "$out" "git diff .github/workflows/" "Y → 確認とコミットの案内が表示される"
    assert_file_not_contains "$MOCK_CALL_LOG" "git commit" "Y → 自動でコミットしない"
    assert_file_not_contains "$MOCK_CALL_LOG" "git push" "Y → 自動でプッシュしない"

    out=$(_wf_run "$td" "$mb" "$mh" "Y"); ec=$?
    assert_output_contains "$out" "最新です" "更新後 → 「最新です」になる"

    # 雛形にないファイルは、変更しない（情報として、表示するだけ）
    echo "name: Extra" > "$td/.github/workflows/wf-old.yml"
    echo "# again" >> "$td/.github/workflows/wf-a.yml"
    out=$(_wf_run "$td" "$mb" "$mh" "YY"); ec=$?
    assert_output_contains "$out" "雛形にないワークフロー" "雛形にないファイルが、情報として表示される"
    assert_file_exists "$td/.github/workflows/wf-old.yml" "雛形にないファイルは、削除されない"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb" "$mh"
}

# .github/workflows/ がないプロジェクト → 雛形のすべてを追加する
test_no_workflows_dir() {
    local td mb mh out ec
    _wf_env td mb mh
    rm -rf "$td/.github"
    out=$(_wf_run "$td" "$mb" "$mh" "YY"); ec=$?
    assert_exit_ok "$ec" ".github/workflows/ がない + Y → 終了コード 0"
    assert_file_exists "$td/.github/workflows/wf-a.yml" ".github/workflows/ がない → wf-a.yml が追加される"
    assert_file_exists "$td/.github/workflows/wf-b.yml" ".github/workflows/ がない → wf-b.yml が追加される"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb" "$mh"
}

# --check → 差分があるかだけを調べる（変更しない・確認を出さない）
test_check() {
    local td mb mh out ec
    _wf_env td mb mh
    out=$(_wf_run "$td" "$mb" "$mh" "" --check); ec=$?
    assert_exit_ok "$ec" "--check + 差分なし → 終了コード 0"
    assert_output_contains "$out" "最新です" "--check + 差分なし → 「最新です」"

    echo "# customized" >> "$td/.github/workflows/wf-a.yml"
    out=$(_wf_run "$td" "$mb" "$mh" "" --check); ec=$?
    assert_exit_fail "$ec" "--check + 差分あり → 終了コード 1"
    assert_output_contains "$out" "差分あり: wf-a.yml" "--check + 差分あり → 差分が表示される"
    grep -q "customized" "$td/.github/workflows/wf-a.yml" && pass "--check → ファイルは変更されない" || fail "--check → ファイルは変更されない"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb" "$mh"
}

# --remove → 雛形から廃止されたファイルだけを、二重の確認のうえ、削除する
test_remove() {
    local td mb mh out ec
    _wf_env td mb mh
    echo "name: Old" > "$td/.github/workflows/wf-old.yml"

    out=$(_wf_run "$td" "$mb" "$mh" "YN" --remove wf-old.yml); ec=$?
    assert_exit_fail "$ec" "--remove + 1 回目 Y・2 回目 N → 中断"
    assert_file_exists "$td/.github/workflows/wf-old.yml" "--remove + 2 回目 N → 削除されない"

    out=$(_wf_run "$td" "$mb" "$mh" "N" --remove wf-old.yml); ec=$?
    assert_exit_fail "$ec" "--remove + 1 回目 N → 中断"
    assert_file_exists "$td/.github/workflows/wf-old.yml" "--remove + 1 回目 N → 削除されない"

    out=$(_wf_run "$td" "$mb" "$mh" "YY" --remove wf-old.yml); ec=$?
    assert_exit_ok "$ec" "--remove + Y・Y → 終了コード 0"
    assert_file_not_exists "$td/.github/workflows/wf-old.yml" "--remove + Y・Y → 削除される"

    # 雛形にあるファイル・存在しないファイル・パスを含む名前・ファイル名の指定なし → 拒否される
    out=$(_wf_run "$td" "$mb" "$mh" "YY" --remove wf-a.yml); ec=$?
    assert_exit_fail "$ec" "--remove + 雛形にあるファイル → エラー終了"
    assert_output_contains "$out" "雛形にある" "--remove + 雛形にあるファイル → 理由が表示される"
    assert_file_exists "$td/.github/workflows/wf-a.yml" "--remove + 雛形にあるファイル → 削除されない"
    out=$(_wf_run "$td" "$mb" "$mh" "YY" --remove wf-none.yml); ec=$?
    assert_exit_fail "$ec" "--remove + 存在しないファイル → エラー終了"
    echo "name: Outside" > "$td/outside.yml"
    out=$(_wf_run "$td" "$mb" "$mh" "YY" --remove ../../outside.yml); ec=$?
    assert_exit_fail "$ec" "--remove + パスを含む名前 → エラー終了"
    assert_file_exists "$td/outside.yml" "--remove + パスを含む名前 → フォルダの外のファイルは、削除されない"
    out=$(_wf_run "$td" "$mb" "$mh" "" --remove); ec=$?
    assert_exit_fail "$ec" "--remove + ファイル名の指定なし → エラー終了"

    echo "name: Old" > "$td/.github/workflows/wf-old.yml"
    out=$(MOCK_GIT_BRANCH="main" _wf_run "$td" "$mb" "$mh" "YY" --remove wf-old.yml); ec=$?
    assert_exit_fail "$ec" "--remove + 環境ブランチ → エラー終了"
    assert_file_exists "$td/.github/workflows/wf-old.yml" "--remove + 環境ブランチ → 削除されない"
    unset MOCK_GIT_BRANCH

    # 回帰: --check と --remove の同時指定は、拒否する（以前は、--check なのに、確認 1 回だけで削除していた）
    echo "name: Old" > "$td/.github/workflows/wf-old.yml"
    out=$(_wf_run "$td" "$mb" "$mh" "Y
Y
" --check --remove wf-old.yml); ec=$?
    assert_exit_fail "$ec" "--check + --remove → エラー終了"
    assert_output_contains "$out" "同時に指定できません" "--check + --remove → 理由が表示される"
    assert_file_exists "$td/.github/workflows/wf-old.yml" "--check + --remove → 削除されない"
    out=$(_wf_run "$td" "$mb" "$mh" "Y
Y
" --remove wf-old.yml --check); ec=$?
    assert_exit_fail "$ec" "--remove + --check（順序を逆）→ エラー終了"
    assert_file_exists "$td/.github/workflows/wf-old.yml" "--remove + --check（順序を逆）→ 削除されない"
    teardown "$td" "$mb" "$mh"
}

# 実際の雛形（templates/.github/workflows/）と、sf-init が作るもの（雛形のコピー）が、同じであること
test_real_templates_are_synced() {
    local td mb mh out ec
    setup_std_env td mb mh
    create_all_mocks "$mb"
    mkdir -p "$td/.github"
    cp -r "$SF_TOOLS_DIR/templates/.github/workflows" "$td/.github/workflows"
    export MOCK_GIT_BRANCH="system-20261006"
    out=$(_wf_run "$td" "$mb" "$mh" "" --check); ec=$?
    assert_exit_ok "$ec" "実際の雛形のコピー → --check で差分なし"
    unset MOCK_GIT_BRANCH
    teardown "$td" "$mb" "$mh"
}

# 雛形 wf-validate.yml: PR コメントに載せるログから、ANSI エスケープコード（色の指定）を除いていること
#   残すと、PR のコメント・通知メールで「[34m」のように化ける。雛形の置換式を取り出して、実際に動かして確認する
test_validate_strips_ansi() {
    local tmpl="$SF_TOOLS_DIR/templates/.github/workflows/wf-validate.yml" line expr out
    line=$(grep -F 'ログ = ログ.replace(' "$tmpl" | head -1)
    assert_equals "$([[ -n "$line" ]] && echo yes || echo no)" "yes" "wf-validate.yml: ログから ANSI エスケープコードを除く処理がある"
    # コメントの作成（createComment）より前にあること
    local n_strip n_comment
    n_strip=$(grep -nF 'ログ = ログ.replace(' "$tmpl" | head -1 | cut -d: -f1)
    n_comment=$(grep -nF 'createComment' "$tmpl" | head -1 | cut -d: -f1)
    assert_equals "$([[ -n "$n_strip" && -n "$n_comment" && "$n_strip" -lt "$n_comment" ]] && echo yes || echo no)" "yes" "wf-validate.yml: 除く処理は、コメントの投稿より前にある"
    if [[ -z "${REAL_NODE_PATH:-}" ]]; then
        pass "（node がないため、置換式の実行は省略）"
        return 0
    fi
    expr=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*//')   # 例: ログ = ログ.replace(/.../g, '');
    out=$("$REAL_NODE_PATH" -e '
        let ログ = "\x1b[34m\x1b[1mValidated Source\x1b[22m\x1b[39m\n\x1b[1m\x1b[32mDry-run complete.\x1b[39m\x1b[22m\n\x1b[?25l▶ Waiting\x1b[?25h\n✔ Done (0ms)";
        '"$expr"'
        console.log(JSON.stringify(ログ), ログ.includes("\x1b") ? "ESC-REMAINS" : "ESC-CLEAN");
    ' 2>&1)
    assert_output_contains "$out" "ESC-CLEAN" "wf-validate.yml: 置換式を実行すると、ESC が残らない"
    assert_output_contains "$out" 'Validated Source\\nDry-run complete.\\n▶ Waiting\\n✔ Done (0ms)' "wf-validate.yml: 文字と記号（▶ ✔）は、そのまま残る"
}

# 雛形 wf-validate.yml: 終了コードが空（sf-release.sh まで届かなかった）を「✅ 検証成功」と表示しない。コメントの投稿を await で待つ
#   以前は parseInt('') || 0 で、空が 0（成功）になっていた。見出しを決める部分を取り出して、実際に動かして確認する
test_validate_result_heading() {
    local tmpl="$SF_TOOLS_DIR/templates/.github/workflows/wf-validate.yml" code out
    assert_file_contains "$tmpl" "await github.rest.issues.createComment" "wf-validate.yml: コメントの投稿を await で待つ"
    assert_file_not_contains "$tmpl" "parseInt(" "wf-validate.yml: 終了コードを parseInt で 0 に丸めない"
    assert_file_contains "$tmpl" "EXIT_CODE: \${{ steps.sf_validate.outputs.exit_code }}" "wf-validate.yml: 終了コードは、環境変数で受け取る"
    if [[ -z "${REAL_NODE_PATH:-}" ]]; then
        pass "（node がないため、見出しの判定の実行は省略）"
        return 0
    fi
    # 「const 終了コード文字列」から、if / else if / else の閉じ括弧（インデント 12 の }）までを取り出す
    code=$(awk '/const 終了コード文字列/{f=1} f{print} f && /^            }$/{exit}' "$tmpl")  # VAR=$(cmd) のため run 不使用
    out=$(EXIT_CODE="" "$REAL_NODE_PATH" -e "${code}; console.log(アイコン, 結果)" 2>&1)
    assert_output_contains "$out" "検証が実行されませんでした" "wf-validate.yml: 終了コードが空 → 「検証が実行されませんでした」"
    assert_output_not_contains "$out" "検証成功" "wf-validate.yml: 終了コードが空 → 「検証成功」と表示しない"
    out=$(EXIT_CODE="0" "$REAL_NODE_PATH" -e "${code}; console.log(アイコン, 結果)" 2>&1)
    assert_output_contains "$out" "✅ 検証成功" "wf-validate.yml: 終了コード 0 → ✅ 検証成功"
    out=$(EXIT_CODE="1" "$REAL_NODE_PATH" -e "${code}; console.log(アイコン, 結果)" 2>&1)
    assert_output_contains "$out" "❌ 検証失敗（終了コード 1）" "wf-validate.yml: 終了コード 1 → ❌ 検証失敗"
}

# 雛形の同時実行の制御（concurrency）と、手動の実行のブランチの制限（wf-release.yml）
test_wf_concurrency() {
    local d="$SF_TOOLS_DIR/templates/.github/workflows"
    assert_file_contains "$d/wf-propagate.yml" "group: propagate" "wf-propagate.yml: 伝播は 1 つずつ動く（concurrency）"
    assert_file_contains "$d/wf-metasync.yml" "group: metasync" "wf-metasync.yml: 同期は 1 つずつ動く（concurrency）"
    assert_file_contains "$d/wf-release.yml" "group: release-" "wf-release.yml: 同じマージ先へのリリースは 1 つずつ動く（concurrency）"
    # 待機中のリリースが、新しい実行に置き換えられて（取り消されて）、行われないまま終わらないこと
    assert_file_contains "$d/wf-release.yml" "queue: max" "wf-release.yml: 待機中のリリースを、取り消さずに残す（queue: max）"
    local f n
    for f in wf-propagate wf-metasync wf-release; do
        n=$(grep -cE '^ +cancel-in-progress: false$' "$d/${f}.yml")  # 設定の行だけを数える（コメントの行は除く）。VAR=$(cmd) のため run 不使用
        assert_equals "$n" "1" "${f}.yml: 実行中のものは取り消さない（cancel-in-progress: false）"
    done
    assert_file_contains "$d/wf-release.yml" "contains(fromJSON('[\"main\",\"staging\",\"develop\"]'), github.ref_name)" \
        "wf-release.yml: 手動の実行は、main / staging / develop でだけリリースする"
}

# 雛形の Slack への通知（3 本）: 応答の ok を確かめ、true でなければ ::warning を出す（ステップは失敗にしない）
#   確かめる式を取り出して、実際の node で動かす
test_wf_slack_response_checked() {
    local d="$SF_TOOLS_DIR/templates/.github/workflows" name line js rc
    for name in wf-release wf-propagate wf-sequence; do
        assert_file_contains "$d/${name}.yml" "::warning title=Slack 通知の失敗::" "${name}: Slack の応答が ok でなければ、::warning を出す"
        assert_file_contains "$d/${name}.yml" '-d "$PAYLOAD" || true)' "${name}: curl の失敗で、ステップを失敗にしない"
        line=$(grep -F "node -e 'process.exit(JSON.parse(" "$d/${name}.yml" | head -1)  # VAR=$(cmd) のため run 不使用
        [[ -n "$line" ]] && pass "${name}: 応答の JSON を node で確かめる" || { fail "${name}: 応答の JSON を node で確かめる"; continue; }
        [[ -n "${REAL_NODE_PATH:-}" ]] || continue
        js=$(printf '%s' "$line" | sed -E "s/^.*node -e '//; s/' \"\\\$RESPONSE\".*$//")  # VAR=$(cmd) のため run 不使用
        "$REAL_NODE_PATH" -e "$js" '{"ok":true,"channel":"C1"}' 2>/dev/null; rc=$?
        assert_equals "$rc" "0" "${name}: 応答 ok:true → 成功（警告なし）"
        "$REAL_NODE_PATH" -e "$js" '{"ok":false,"error":"invalid_auth"}' 2>/dev/null; rc=$?
        assert_equals "$([[ $rc -ne 0 ]] && echo ng || echo ok)" "ng" "${name}: 応答 ok:false → 警告"
        "$REAL_NODE_PATH" -e "$js" '' 2>/dev/null; rc=$?
        assert_equals "$([[ $rc -ne 0 ]] && echo ng || echo ok)" "ng" "${name}: 応答が空（curl の失敗）→ 警告"
    done
}

test_help
test_guards
test_up_to_date
test_sync
test_no_workflows_dir
test_check
test_remove
test_real_templates_are_synced
test_validate_strips_ansi
test_validate_result_heading
test_wf_concurrency
test_wf_slack_response_checked

print_summary
