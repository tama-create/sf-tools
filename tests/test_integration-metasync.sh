#!/bin/bash
# ==============================================================================
# test_integration-metasync.sh - 結合テスト L1: sf-metasync（組織 → Git の同期）の、ローカルの動作・後始末の失敗
# ==============================================================================
# 実際の git と fake の sf（組織から取得したファイルは、state/sf.retrieve で決める）で、sf-metasync を、
# 作業ブランチから実行したときの、main への切替・取り込み・コミット・push・元のブランチへの復帰・stash の復元を確かめる。
# ハーネスと fake は tests/integration/lib.sh。計画: doc/integration-test-plan.md（B3 のローカル部分・X8-4・X8-5）
#
# 【シナリオ】
#   M0  フックのあるクローンから（ローカル実行）→ main への push は、フックを通さず（--no-verify）、成功する
#   M1  作業ブランチ（未コミットの変更あり）から実行 → main に同期のコミットが届く。元のブランチに戻り、stash が復元される
#   M2  組織側に変更なし → コミットを作らない。元のブランチに戻る
#   M3  差分の抽出（SGD）の失敗 → 失敗で終わり、元のブランチ・stash が復元される（X8-4）
#   M4  main の push が拒否される → 失敗で終わり、元のブランチ・stash が復元される。再実行で、未プッシュのコミットが届く（X8-4）
#   M5  stash を戻すとき、取得した内容と衝突する（後始末の一部が失敗）→ 残ったものの扱いを記録（X8-5）
# ==============================================================================
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.sh"
source "$(dirname "${BASH_SOURCE[0]}")/integration/lib.sh"
echo -e "${CLR_HEAD}=== 結合テスト L1: sf-metasync ===${CLR_RST}"

trap 'it_teardown' EXIT

_head() { _it_git -C "$1" rev-parse HEAD; }
_cur() { _it_git -C "$1" symbolic-ref --short HEAD 2>/dev/null; }
_stashes() { _it_git -C "$1" stash list | wc -l | tr -d ' '; }
_remote_ref() { _it_git --git-dir="$IT_ORIGIN" rev-parse "refs/heads/$1" 2>/dev/null; }
_meta() { it_run "$CL" -i 'Y\nY\n' bash "$IT_HOME/sf-tools/bin/sf-metasync.sh"; }   # 警告の確認 Y・コミットの確認 Y

test_setup() {
    it_setup || { fail "サンドボックスの作成"; return 1; }
    it_seed_repo 1 || { fail "リポジトリの生成"; return 1; }
    it_make_clone devA JOB-A || { fail "クローンの作成" "$(it_out)"; return 1; }
    CL="$IT_CL"
    IT_TIMEOUT=300
    pass "準備: クローン（JOB-A）を作った"
}

test_M0() {
    echo -e "\n${CLR_HEAD}--- M0: フックのあるクローンから実行（ローカル実行）---${CLR_RST}"
    local m0; m0=$(_remote_ref main); _dirty
    it_set_retrieve "force-app/main/default/classes/FromOrg.cls|public class FromOrg { }"
    assert_file_exists "$CL/.git/hooks/pre-push" "M0: （前提）クローンに、pre-push フックが入っている"
    _meta
    # sf-metasync の main への push は、pre-push フック（開発者の main への直接 push を止める）を、通さない（--no-verify）。
    #   サーバー側の保護（Ruleset）は、そのまま効く。以前は、フックに止められ、ローカルでは、最後の push で失敗した
    assert_exit_ok "$IT_RC" "M0: フックのあるクローンでも、sf-metasync の main への push が通る"
    [[ "$(_remote_ref main)" != "$m0" ]] && pass "M0: origin の main に、同期のコミットが届く" || fail "M0: origin の main に、同期のコミットが届く"
    assert_equals "$(_cur "$CL")" "JOB-A" "M0: 元のブランチに戻る"
    assert_equals "$(_stashes "$CL")" "0" "M0: stash が復元される"
    grep -q "手元の変更" "$CL/README.md" && pass "M0: 手元の未コミットの変更が、復元される" || fail "M0: 手元の未コミットの変更が、復元される"
    _it_git -C "$CL" checkout -q -- README.md
}

# 作業ブランチに、未コミットの変更（追跡中のファイル）を作る
_dirty() { echo "手元の変更 $RANDOM" >> "$CL/README.md"; }

test_M1() {
    echo -e "\n${CLR_HEAD}--- M1: 作業ブランチから実行 → main に反映・元のブランチに戻る ---${CLR_RST}"
    local h0 m0; h0=$(_head "$CL"); m0=$(_remote_ref main)
    _dirty
    it_set_retrieve "force-app/main/default/classes/FromOrg1.cls|public class FromOrg1 { }"
    _meta
    [[ $IT_RC -eq 0 ]] || it_out | tail -30
    assert_exit_ok "$IT_RC" "M1: sf-metasync が成功する"
    [[ "$(_remote_ref main)" != "$m0" ]] && pass "M1: origin の main に、同期のコミットが届く" || fail "M1: origin の main に、同期のコミットが届く"
    _it_git --git-dir="$IT_ORIGIN" ls-tree -r --name-only main | grep -q 'classes/FromOrg1.cls' && pass "M1: 取得したファイルが、main に入る" || fail "M1: 取得したファイルが、main に入る"
    assert_equals "$(_cur "$CL")" "JOB-A" "M1: 元のブランチ（JOB-A）に戻る"
    assert_equals "$(_head "$CL")" "$h0" "M1: 元のブランチの HEAD は、変わらない"
    assert_equals "$(_stashes "$CL")" "0" "M1: stash が、残らない（復元された）"
    grep -q "手元の変更" "$CL/README.md" && pass "M1: 手元の未コミットの変更が、復元される" || fail "M1: 手元の未コミットの変更が、復元される"
    [[ -d "$CL/sf-tools/temp_delta_"* ]] 2>/dev/null && fail "M1: 一時フォルダ（temp_delta）が、残らない" || pass "M1: 一時フォルダ（temp_delta）が、残らない"
    _it_git -C "$CL" checkout -q -- README.md
}

test_M2() {
    echo -e "\n${CLR_HEAD}--- M2: 組織側に変更なし ---${CLR_RST}"
    local m0 h0; m0=$(_remote_ref main); h0=$(_head "$CL")
    it_set_retrieve "force-app/main/default/classes/FromOrg1.cls|public class FromOrg1 { }"   # すでに main にある内容と同じ
    _meta
    assert_exit_ok "$IT_RC" "M2: 変更がなくても、sf-metasync は成功する"
    it_out_has "変更はありませんでした" && pass "M2: 「変更はありませんでした」と表示される" || fail "M2: 「変更はありませんでした」と表示される"
    assert_equals "$(_remote_ref main)" "$m0" "M2: main は、変わらない"
    assert_equals "$(_cur "$CL")" "JOB-A" "M2: 元のブランチに戻る"
    assert_equals "$(_head "$CL")" "$h0" "M2: 元のブランチの HEAD は、変わらない"
}

test_M3() {
    echo -e "\n${CLR_HEAD}--- M3: 差分の抽出（SGD）の失敗 ---${CLR_RST}"
    local m0; m0=$(_remote_ref main); _dirty
    echo "SGD: unexpected failure" > "$IT_STATE/sf.sgdfail"
    _meta
    assert_exit_fail "$IT_RC" "M3: SGD が失敗すると、sf-metasync は失敗で終わる"
    assert_equals "$(_remote_ref main)" "$m0" "M3: main は、変わらない"
    assert_equals "$(_cur "$CL")" "JOB-A" "M3: 元のブランチに戻る"
    assert_equals "$(_stashes "$CL")" "0" "M3: stash が、残らない（復元された）"
    grep -q "手元の変更" "$CL/README.md" && pass "M3: 手元の未コミットの変更が、復元される" || fail "M3: 手元の未コミットの変更が、復元される"
    rm -f "$IT_STATE/sf.sgdfail"
    _it_git -C "$CL" checkout -q -- README.md
}

test_M4() {
    echo -e "\n${CLR_HEAD}--- M4: main の push が拒否される → 再実行 ---${CLR_RST}"
    local m0; m0=$(_remote_ref main); _dirty
    it_set_retrieve "force-app/main/default/classes/FromOrg2.cls|public class FromOrg2 { }"
    it_origin_reject on
    _meta
    assert_exit_fail "$IT_RC" "M4: push が拒否されると、sf-metasync は失敗で終わる"
    assert_equals "$(_remote_ref main)" "$m0" "M4: origin の main は、変わらない"
    assert_equals "$(_cur "$CL")" "JOB-A" "M4: 元のブランチに戻る"
    assert_equals "$(_stashes "$CL")" "0" "M4: stash が、残らない（復元された）"
    grep -q "手元の変更" "$CL/README.md" && pass "M4: 手元の未コミットの変更が、復元される" || fail "M4: 手元の未コミットの変更が、復元される"
    # 手元の main に、push できなかったコミットが残る
    local ahead; ahead=$(_it_git -C "$CL" rev-list --count origin/main..main)
    echo "  手元の main の、push できなかったコミット: ${ahead} 件"
    it_origin_reject off
    _it_git -C "$CL" checkout -q -- README.md
    # 再実行（組織の内容は同じ）
    _meta
    echo "  再実行: rc=${IT_RC}（origin の main は、手元の未プッシュのコミットを、受け取ったか: $([[ "$(_remote_ref main)" != "$m0" ]] && echo はい || echo いいえ)）"
    assert_equals "$(_cur "$CL")" "JOB-A" "M4: 再実行でも、元のブランチに戻る"
    # 組織の内容が、手元の main のコミットと同じでも、未プッシュのコミットがあれば、push だけ行う（以前は、「変更なし」で、取り残された）
    assert_equals "$(_it_git -C "$CL" rev-list --count origin/main..main)" "0" "M4: 再実行で、push できなかったコミットが、origin に届く"
    [[ "$(_remote_ref main)" != "$m0" ]] && pass "M4: 再実行で、origin の main が進む" || fail "M4: 再実行で、origin の main が進む"
    it_out_has "未プッシュのコミットが" && pass "M4: 未プッシュのコミットの push だと、表示される" || fail "M4: 未プッシュのコミットの push だと、表示される"
}

test_M5() {
    echo -e "\n${CLR_HEAD}--- M5: stash を戻すとき、取得した内容と衝突する ---${CLR_RST}"
    # 手元の変更: README.md（追跡中）を変更。組織からの取得でも、README.md が変わる → stash pop が、衝突する
    echo "手元の変更（衝突する）" >> "$CL/README.md"
    it_set_retrieve "README.md|組織から取得した内容"
    _meta
    echo "  rc=${IT_RC} / ブランチ=$(_cur "$CL") / stash=$(_stashes "$CL") 件 / 未解決の衝突=$(_it_git -C "$CL" ls-files -u | wc -l | tr -d ' ')"
    assert_equals "$(_cur "$CL")" "JOB-A" "M5: 後始末の一部が失敗しても、元のブランチには、戻る"
    # 手元の変更が、失われていないこと: 作業フォルダに残っているか、stash に残っている
    if grep -q "手元の変更（衝突する）" "$CL/README.md" 2>/dev/null || [[ "$(_stashes "$CL")" != "0" ]]; then
        pass "M5: 手元の変更は、失われない（作業フォルダか stash に残る）"
    else
        fail "M5: 手元の変更は、失われない（作業フォルダか stash に残る）" "どこにも残っていない"
    fi
}

_it_timed() { local t0=$SECONDS rc; "$@"; rc=$?; echo "  （所要時間: $1 = $((SECONDS - t0)) 秒）"; return $rc; }

test_setup || { print_summary; exit 1; }
for _sc in ${IT_SCENARIOS:-M0 M1 M2 M3 M4 M5}; do
    _it_timed "test_${_sc}" || break
done

print_summary
