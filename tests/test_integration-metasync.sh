#!/bin/bash
# ==============================================================================
# test_integration-metasync.sh - 結合テスト L1: sf-metasync（組織 → Git の同期）の、ローカルの動作・後始末の失敗
# ==============================================================================
# 実際の git と fake の sf（組織から取得したファイルは、state/sf.retrieve で決める）で、sf-metasync を、
# 作業ブランチから実行したときの、main への切替・取り込み・コミット・push・元のブランチへの復帰・stash の復元を確かめる。
# ハーネスと fake は tests/integration/lib.sh。計画: doc/integration-test-plan.md（B3 のローカル部分・X8-4・X8-5）
#
# 【シナリオ】
#   M0  フックのあるクローンから（ローカル実行）→ main への push と、staging への伝播の push は、フックを通さず
#       （--no-verify）、成功する（リポジトリは main・staging の 2 段。staging は、保護ブランチのため、フックが必ず拒否する）
#   M1  作業ブランチ（未コミットの変更あり）から実行 → main に同期のコミットが届く。元のブランチに戻り、stash が復元される
#   M2  組織側に変更なし → コミットを作らない。元のブランチに戻る
#   M3  組織からの取得の失敗 → 失敗で終わり、main は変わらず、元のブランチ・stash が復元される（X8-4）
#   M4  main の push が拒否される → 失敗で終わり、元のブランチ・stash が復元される。再実行で、未プッシュのコミットが届く（X8-4）
#   M5  手元の追跡中のファイルの変更が、同期のあとも失われない（stash の復元。同期は、同期の対象のフォルダにしか書かない）（X8-5）
#   M6  組織で削除した部品が、main から消え、staging にも伝播する（鏡像。取得結果にあるフォルダの中の削除）
#   M7  削除が多い（S4）→ 削除を保留し、追加・変更だけが届く。終了コード 3。--allow-mass-delete で解ける
#   M8  直近にマージされたファイルの削除は保留される（S5。実際の git log の確認）。終了コード 0
#   M9  --dry-run → 取得して計画を表示するだけ。origin・手元の HEAD・作業ブランチは変わらない
#   M10 コミットの前に中断（commit の失敗）→ 反映した分が HEAD に戻り、元のブランチに戻る
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
    it_seed_repo 2 || { fail "リポジトリの生成"; return 1; }   # main・staging（M0 で、伝播の push を確かめる）
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
    # 回帰: 伝播の push も、フックを通さない（以前は、フックが、保護ブランチ（staging）の上からの push として拒否し、伝播できなかった）
    assert_equals "$(_remote_ref staging)" "$(_remote_ref main)" "M0: origin の staging に、main が伝播する（フックに止められない）"
    it_out_has "伝播したブランチ: staging" && pass "M0: 伝播したブランチ（staging）が表示される" || fail "M0: 伝播したブランチ（staging）が表示される"
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
    # 回帰: 作業ブランチの作業用ファイル（sf-tools/release/JOB-A/。未追跡）は、main の同期のコミットに含めない（以前は含めていた）
    _it_git --git-dir="$IT_ORIGIN" ls-tree -r --name-only main | grep -q 'sf-tools/release/JOB-A/' && fail "M1: 作業ブランチの release/JOB-A/ を、main に入れない" "main に入っている" || pass "M1: 作業ブランチの release/JOB-A/ を、main に入れない"
    assert_equals "$(_cur "$CL")" "JOB-A" "M1: 元のブランチ（JOB-A）に戻る"
    assert_equals "$(_head "$CL")" "$h0" "M1: 元のブランチの HEAD は、変わらない"
    assert_equals "$(_stashes "$CL")" "0" "M1: stash が、残らない（復元された）"
    grep -q "手元の変更" "$CL/README.md" && pass "M1: 手元の未コミットの変更が、復元される" || fail "M1: 手元の未コミットの変更が、復元される"
    [[ -z "$(ls -d "$IT_ROOT"/tmp/sf-metasync-* 2>/dev/null)" ]] && pass "M1: 取得先の一時フォルダが、残らない" || fail "M1: 取得先の一時フォルダが、残らない"
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
    echo -e "\n${CLR_HEAD}--- M3: 組織からの取得の失敗 ---${CLR_RST}"
    local m0 h0; m0=$(_remote_ref main); h0=$(_head "$CL"); _dirty
    echo "Error (SomePermanentError): retrieve failed" > "$IT_STATE/sf.retrievefail"
    _meta
    assert_exit_fail "$IT_RC" "M3: 取得が失敗すると、sf-metasync は失敗で終わる"
    assert_equals "$(_remote_ref main)" "$m0" "M3: main は、変わらない"
    assert_equals "$(_cur "$CL")" "JOB-A" "M3: 元のブランチに戻る"
    assert_equals "$(_head "$CL")" "$h0" "M3: 元のブランチの HEAD は、変わらない"
    assert_equals "$(_stashes "$CL")" "0" "M3: stash が、残らない（復元された）"
    grep -q "手元の変更" "$CL/README.md" && pass "M3: 手元の未コミットの変更が、復元される" || fail "M3: 手元の未コミットの変更が、復元される"
    [[ -z "$(ls -d "$IT_ROOT"/tmp/sf-metasync-* 2>/dev/null)" ]] && pass "M3: 取得先の一時フォルダが、残らない" || fail "M3: 取得先の一時フォルダが、残らない"
    rm -f "$IT_STATE/sf.retrievefail"
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
    echo -e "\n${CLR_HEAD}--- M5: 手元の追跡中のファイルの変更は、同期のあとも失われない ---${CLR_RST}"
    # 手元の変更: README.md（追跡中。同期の対象のフォルダの外）。組織の取得結果に README.md があっても、同期は触らない
    echo "手元の変更（衝突しない）" >> "$CL/README.md"
    it_set_retrieve "README.md|組織から取得した内容" "force-app/main/default/classes/FromOrg5.cls|public class FromOrg5 { }"
    _meta
    assert_exit_ok "$IT_RC" "M5: 同期が成功する"
    assert_equals "$(_cur "$CL")" "JOB-A" "M5: 元のブランチに戻る"
    assert_equals "$(_stashes "$CL")" "0" "M5: stash が、残らない（復元された）"
    grep -q "手元の変更（衝突しない）" "$CL/README.md" && pass "M5: 手元の変更は、失われない" || fail "M5: 手元の変更は、失われない"
    _it_git --git-dir="$IT_ORIGIN" show main:README.md 2>/dev/null | grep -q "組織から取得した内容" && fail "M5: 同期の対象の外（README.md）は、main に書かない" "書かれた" || pass "M5: 同期の対象の外（README.md）は、main に書かない"
    _it_git -C "$CL" checkout -q -- README.md
}

# main の上に、同期以外のコミットを作って push する（PR のマージを模す）。引数: パス（リポジトリの根から）・内容
_commit_on_main() {
    local out rc
    out=$( _it_git -C "$CL" checkout -q main 2>&1 \
        && { mkdir -p "$(dirname "$CL/$1")"; printf '%s\n' "$2" > "$CL/$1"; } \
        && _it_git -C "$CL" add -A -- "$1" 2>&1 \
        && _it_git -C "$CL" commit -q --no-verify -m "Merge pull request #1 from JOB-X" 2>&1 \
        && _it_git -C "$CL" push -q --no-verify "$IT_ORIGIN" main 2>&1 )   # ssh の fake を通さず、bare の origin に直接 push する
    rc=$?
    [[ $rc -eq 0 ]] || echo "  （_commit_on_main の失敗: $out）"
    _it_git -C "$CL" checkout -q JOB-A
    return $rc
}
_in_main() { _it_git --git-dir="$IT_ORIGIN" ls-tree -r --name-only main | grep -q "$1"; }
_in_staging() { _it_git --git-dir="$IT_ORIGIN" ls-tree -r --name-only staging | grep -q "$1"; }

test_M6() {
    echo -e "\n${CLR_HEAD}--- M6: 組織で削除した部品が、main から消え、staging にも伝播する ---${CLR_RST}"
    it_set_retrieve "force-app/main/default/classes/Del6.cls|public class Del6 { }" "force-app/main/default/classes/Keep6.cls|public class Keep6 { }"
    _meta
    assert_exit_ok "$IT_RC" "M6: （前提）1 回目の同期が成功する"
    _in_main 'classes/Del6.cls' && pass "M6: （前提）1 回目で、Del6.cls が main に入る" || fail "M6: （前提）1 回目で、Del6.cls が main に入る"
    it_set_retrieve "force-app/main/default/classes/Keep6.cls|public class Keep6 { }"   # 組織から Del6 が削除された
    _meta
    assert_exit_ok "$IT_RC" "M6: 2 回目の同期が成功する"
    _in_main 'classes/Del6.cls' && fail "M6: 組織で削除した部品が、main から消える" "残っている" || pass "M6: 組織で削除した部品が、main から消える"
    _in_main 'classes/Keep6.cls' && pass "M6: 組織にある部品は、main に残る" || fail "M6: 組織にある部品は、main に残る"
    _in_staging 'classes/Del6.cls' && fail "M6: 削除が staging にも伝播する" "残っている" || pass "M6: 削除が staging にも伝播する"
    _in_main 'classes/.gitkeep' && pass "M6: .gitkeep は、削除しない" || fail "M6: .gitkeep は、削除しない"
}

test_M7() {
    echo -e "\n${CLR_HEAD}--- M7: 削除が多い（S4）→ 保留・終了コード 3 ---${CLR_RST}"
    local args=() i
    for i in $(seq 1 102); do args+=("force-app/main/default/classes/Bulk$i.cls|public class Bulk$i { }"); done
    it_set_retrieve "${args[@]}"
    _meta
    assert_exit_ok "$IT_RC" "M7: （前提）102 件の同期が成功する"
    it_set_retrieve "force-app/main/default/classes/Only7.cls|public class Only7 { }"   # 組織から、102 件が一度に消えた
    _meta
    assert_equals "$IT_RC" "3" "M7: 削除が多い → 保留（終了コード 3）"
    _in_main 'classes/Only7.cls' && pass "M7: 追加の分は、main に届く" || fail "M7: 追加の分は、main に届く"
    _in_main 'classes/Bulk1.cls' && pass "M7: 保留した削除のファイルは、main に残る" || fail "M7: 保留した削除のファイルは、main に残る"
    it_out_has "削除の保留" && pass "M7: 保留とその理由が表示される" || fail "M7: 保留とその理由が表示される"
    it_run "$CL" -i 'Y\nY\n' bash "$IT_HOME/sf-tools/bin/sf-metasync.sh" --allow-mass-delete
    assert_exit_ok "$IT_RC" "M7: --allow-mass-delete で、削除が通る"
    _in_main 'classes/Bulk1.cls' && fail "M7: --allow-mass-delete で、保留していた削除が行われる" "残っている" || pass "M7: --allow-mass-delete で、保留していた削除が行われる"
}

test_M8() {
    echo -e "\n${CLR_HEAD}--- M8: 直近にマージされたファイルの削除は、保留される（S5）---${CLR_RST}"
    _commit_on_main "force-app/main/default/classes/Merged8.cls" "public class Merged8 { }" || { fail "M8: （前提）main に、同期以外のコミットを作る"; return; }
    it_set_retrieve "force-app/main/default/classes/Other8.cls|public class Other8 { }"   # 組織には、まだ Merged8 がない
    _meta
    assert_exit_ok "$IT_RC" "M8: S5 の保留だけ → 終了コード 0"
    _in_main 'classes/Merged8.cls' && pass "M8: 直近にマージされたファイルは、削除されずに残る" || fail "M8: 直近にマージされたファイルは、削除されずに残る"
    _in_main 'classes/Other8.cls' && pass "M8: 追加の分は、main に届く" || fail "M8: 追加の分は、main に届く"
    it_out_has "S5" && pass "M8: 保留の理由（S5）が表示される" || fail "M8: 保留の理由（S5）が表示される"
}

test_M9() {
    echo -e "\n${CLR_HEAD}--- M9: --dry-run ---${CLR_RST}"
    local r0 h0; r0=$(it_remote_snap); h0=$(_head "$CL"); _dirty
    it_set_retrieve "force-app/main/default/classes/Dry9.cls|public class Dry9 { }"
    it_run "$CL" -i 'Y\n' bash "$IT_HOME/sf-tools/bin/sf-metasync.sh" --dry-run
    assert_exit_ok "$IT_RC" "M9: --dry-run が成功する"
    it_out_has "追加 1 件" && pass "M9: 計画が表示される" || fail "M9: 計画が表示される"
    assert_equals "$(it_remote_snap)" "$r0" "M9: origin のどのブランチも、変わらない"
    assert_equals "$(_head "$CL")" "$h0" "M9: 元のブランチの HEAD は、変わらない"
    assert_equals "$(_cur "$CL")" "JOB-A" "M9: 元のブランチに戻る"
    assert_equals "$(_stashes "$CL")" "0" "M9: stash が、残らない（復元された）"
    _it_git -C "$CL" checkout -q -- README.md
}

test_M10() {
    echo -e "\n${CLR_HEAD}--- M10: コミットの前に中断（commit の失敗）→ 反映した分が戻る ---${CLR_RST}"
    local m0; m0=$(_remote_ref main)
    printf '#!/bin/sh\nexit 1\n' > "$CL/.git/hooks/pre-commit"; chmod +x "$CL/.git/hooks/pre-commit"
    it_set_retrieve "force-app/main/default/classes/Abort10.cls|public class Abort10 { }"
    _meta
    assert_exit_fail "$IT_RC" "M10: commit が失敗すると、sf-metasync は失敗で終わる"
    assert_equals "$(_remote_ref main)" "$m0" "M10: origin の main は、変わらない"
    assert_equals "$(_cur "$CL")" "JOB-A" "M10: 元のブランチに戻る"
    _it_git -C "$CL" checkout -q main
    [[ ! -e "$CL/force-app/main/default/classes/Abort10.cls" ]] && pass "M10: 反映した（新しく書いた）ファイルが、main の作業ツリーから消える" || fail "M10: 反映した（新しく書いた）ファイルが、main の作業ツリーから消える"
    # sf-tools/release/（作業ブランチの作業用ファイル。未追跡）は、同期とは関係なく、いつもあるため、除く
    assert_equals "$(_it_git -C "$CL" status --porcelain -- . ':!sf-tools/release' | wc -l | tr -d ' ')" "0" "M10: main の作業ツリーは、きれい（HEAD に戻っている）"
    _it_git -C "$CL" checkout -q JOB-A
    rm -f "$CL/.git/hooks/pre-commit"
}

_it_timed() { local t0=$SECONDS rc; "$@"; rc=$?; echo "  （所要時間: $1 = $((SECONDS - t0)) 秒）"; return $rc; }

test_setup || { print_summary; exit 1; }
for _sc in ${IT_SCENARIOS:-M0 M1 M2 M3 M4 M5 M6 M7 M8 M9 M10}; do
    _it_timed "test_${_sc}" || break
done

print_summary
