#!/bin/bash
# ==============================================================================
# package-xml.sh - package.xml 形式のマニフェストの統合と比較（merge_package_xml・manifest_overlap・manifest_missing_in_org・manifest_drop_pairs）
# ==============================================================================
# lib/project.sh が source する（呼び出し側は、今までどおり lib/common.sh を読むだけでよい。単独では、source しない）。
# 2026-11-28 に、1013 行あった lib/project.sh から、テーマごとに分けた（中身は変えずに移した）。
# 関数の一覧と使い方は、lib/project.sh の冒頭コメント（【提供する関数】）にまとめてある。
# ==============================================================================
# shellcheck disable=SC2154  # 変数は、lib/common.sh と、それを読み込むスクリプトが用意する

# merge_package_xml - package.xml 形式のマニフェストを、1 つに統合する
# ------------------------------------------------------------------------------
# 【使い方】 merge_package_xml OUT IN1 [IN2 ...]
# 【理由】   `sf project generate manifest` は、--source-dir と --metadata を同時に渡すと、両方の「共通部分」だけを返す
#           （重なりがなければ、<types> が 1 つもない空のマニフェストになる。しかも、成功として終わる）。
#           そのため、sf-release.sh は、[files] と [members] を、別々に生成して、ここで統合する。
# 【動作】   各入力の <types> を読み、種類 → メンバーの順に、重複を除いて並べる（LC_ALL=C の sort -u の順 = バイト順。
#           ロケールに依存すると、macOS の sort -u が、別の日本語の名前を同じとみなして、消すことがあるため）。
#           <version> は、最初に見つかったもの（どの入力にもなければ 64.0）。
#           【前提】各 <types> の中で、<members> が <name> より前にあること（sf が生成する形）。<name> を読んだ時点で、
#           それまでの <members> を、その種類のものとする。<name> が <members> より前にある XML は、正しく統合できない
#           （その <members> は、次の <types> の種類に入り、最後の <types> のものは、捨てられる）
#           grep・awk・sort だけで動く（GNU / BSD 共通。追加の依存なし）
# 【戻り値】 0 = 出力した（メンバーが 1 つもなくても、空のマニフェストを出力する。判定は、呼び出し側）/
#           1 = 入力がない・入力が読めない（通常のファイルでない・読み取りの権限がない）・OUT に書けない。
#               ERROR を表示し、OUT を削除する（前回の古い OUT を、統合の結果として、使わせないため）
# ------------------------------------------------------------------------------
merge_package_xml() {
    local out="$1" f ver
    shift
    if [[ $# -eq 0 ]]; then
        log "ERROR" "merge_package_xml: 入力のマニフェストが、指定されていません。"
        rm -f "$out"  # run 不使用: 失敗の後始末（古い出力を残さない）
        return $RET_NG
    fi
    for f in "$@"; do
        if [[ ! -f "$f" || ! -r "$f" ]]; then
            log "ERROR" "merge_package_xml: 入力のマニフェストを読めません: ${f}"
            rm -f "$out"  # run 不使用: 失敗の後始末（古い出力を残さない）
            return $RET_NG
        fi
    done
    ver=$(grep -h -o '<version>[^<]*</version>' "$@" 2>/dev/null | head -n 1)  # VAR=$(cmd) のため run 不使用
    [[ -n "$ver" ]] || ver="<version>64.0</version>"
    {
        printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<Package xmlns="http://soap.sforce.com/2006/04/metadata">'
        # run 不使用: awk・sort は、パイプの部品（出力を、そのまま次の処理と OUT に渡す。ログには残さない）
        for f in "$@"; do
            awk '
                /<members>/ { s = $0; sub(/^[[:space:]]*<members>/, "", s); sub(/<\/members>[[:space:]]*$/, "", s); m[n++] = s }
                /<name>/    { t = $0; sub(/^[[:space:]]*<name>/, "", t); sub(/<\/name>[[:space:]]*$/, "", t)
                              for (i = 0; i < n; i++) printf "%s\t%s\n", t, m[i]
                              n = 0 }
            ' "$f"
        done | LC_ALL=C sort -u | awk -F'\t' '
            {
                if ($1 != cur) {
                    if (cur != "") { printf "        <name>%s</name>\n    </types>\n", cur }
                    print "    <types>"
                    cur = $1
                }
                printf "        <members>%s</members>\n", $2
            }
            END { if (cur != "") { printf "        <name>%s</name>\n    </types>\n", cur } }
        '
        printf '    %s\n' "$ver"
        printf '%s\n' '</Package>'
    } > "$out" || {
        log "ERROR" "merge_package_xml: 統合したマニフェストを書けません: ${out}"
        rm -f "$out"  # run 不使用: 失敗の後始末（書きかけの出力を残さない）
        return $RET_NG
    }
    return $RET_OK
}

# manifest_overlap - 2 つのマニフェスト（package.xml 形式）の、両方にある「種類:メンバー」を出す
# ------------------------------------------------------------------------------
# 【使い方】 manifest_overlap A B
# 【理由】   反映（package.xml）と削除（destructiveChanges.xml）の両方に同じものがあると、--pre-destructive-changes で
#           先に消したあと、反映で作り直す。項目なら、項目は残り、中のデータだけが消える（エラーにならない）。
#           deploy-target.txt にオブジェクトの本体（*.object-meta.xml）やフォルダを書くと、sf project generate manifest が
#           配下の項目を全部入れるため、remove-target.txt に書いた項目と重なる（2026-11-26・force-test-win の段階 3 で判明。
#           dry-run も成功のまま通った）。sf-release.sh が、マニフェストを作った直後に、これで確かめて止める
# 【動作】   merge_package_xml と同じ読み方（各 <types> の <members> を、次の <name> の種類のものとする）で、両方を
#           「種類:メンバー」の行にし、両方にある行を出す（LC_ALL=C の sort -u の順）。ワイルドカード（*）は、比べない
# 【戻り値】 0 = 読めた（重なりがなければ、何も出さない）/ 1 = どちらかが読めない
# ------------------------------------------------------------------------------
manifest_overlap() {
    local a="$1" b="$2" f
    for f in "$a" "$b"; do
        [[ -f "$f" && -r "$f" ]] || return $RET_NG
    done
    # 出力用のため run 不使用（両方の「種類:メンバー」を並べ、両方にある行だけを出す。プロセス置換は Bash 3.2 でも使える）
    LC_ALL=C comm -12 <(_manifest_pairs "$a") <(_manifest_pairs "$b")
    return $RET_OK
}

# _manifest_pairs - （内部用）マニフェストの <types> を「種類:メンバー」の行にする（重複なし・バイト順。* は出さない）
_manifest_pairs() {
    # run 不使用: awk・sort は、パイプの部品（manifest_overlap に渡すだけ）
    awk '
        /<members>/ { s = $0; sub(/^[[:space:]]*<members>/, "", s); sub(/<\/members>[[:space:]]*$/, "", s); m[n++] = s }
        /<name>/    { t = $0; sub(/^[[:space:]]*<name>/, "", t); sub(/<\/name>[[:space:]]*$/, "", t)
                      for (i = 0; i < n; i++) if (m[i] != "*") printf "%s:%s\n", t, m[i]
                      n = 0 }
    ' "$1" | LC_ALL=C sort -u
}

# manifest_missing_in_org - 削除のマニフェスト（destructiveChanges.xml）の「種類:メンバー」のうち、組織にないものを出す
# ------------------------------------------------------------------------------
# 【使い方】 manifest_missing_in_org XML ORG
# 【理由】   同じブランチで、削除を含む変更を何度も出すと（develop に出したあと、続きの変更をもう一度出す・個人の組織で
#           Deploy したあと Dryrun するなど）、2 回目からは、消す対象が組織にない。Salesforce は「No ApexClass named: X found」で、
#           検証・リリースの全体を失敗にする（2026-11-26・force-test-win の JOB-EQL-1 で発生）。sf-release.sh が、これで
#           組織にないものを調べ、削除から外す（manifest_drop_pairs）
# 【動作】   種類ごとに sf org list metadata --metadata-type <種類> --target-org ORG --json を 1 回呼び、組織にある名前の一覧
#           （result の fullName）と比べる。比べるときは、大文字・小文字を区別しない（「ある」と判断する側に寄せる）。
#           「ない」と出すのは、確かめられたときだけ。次のものは、確かめずに「ある」とみなす（出さない。今までどおり、
#           Salesforce が判断する）:
#             ・一覧が取れない種類（sf の失敗・status が 0 以外・JSON を読めない）。WARNING を表示する
#             ・フォルダの中にある種類（Report・Dashboard・Document・EmailTemplate。フォルダを指定しない一覧には出ないため）
#             ・ワイルドカード（*）と、英数字・「_」「.」「-」以外を含む名前（Layout の「%28」や空白など。一覧の書き方と、
#               マニフェストの書き方が、同じとは限らないため）
#           外しすぎ（組織にあるものを「ない」とする）と、消すはずのものが黙って残る。上の決まりは、その側に倒れないためのもの
# 【出力】   組織にない「種類:メンバー」を、1 行に 1 つ（マニフェストの書き方のまま。LC_ALL=C の sort -u の順）
# 【戻り値】 0 = 調べた（ないものがなければ、何も出さない）/ 1 = XML が読めない
# ------------------------------------------------------------------------------
manifest_missing_in_org() {
    local xml="$1" org="$2" pairs types t json st names p m lm
    [[ -f "$xml" && -r "$xml" ]] || return $RET_NG
    pairs=$(_manifest_pairs "$xml")  # VAR=$(cmd) のため run 不使用
    types=$(printf '%s\n' "$pairs" | awk -F: 'NF { print $1 }' | LC_ALL=C sort -u)  # VAR=$(cmd) のため run 不使用
    while IFS= read -r t; do
        [[ -z "$t" ]] && continue
        case "$t" in
            Report|Dashboard|Document|EmailTemplate) continue ;;  # フォルダの中の種類は、確かめない（ある、とみなす）
        esac
        log "CMD" "[${SCRIPT_NAME:-sf-tools}.sh] sf org list metadata --metadata-type ${t} --target-org ${org} --json"
        # VAR=$(cmd) のため run 不使用（一覧の JSON を読む。失敗は、下で判定する）
        #   標準入力は閉じる（この while の入力（種類の一覧）を、sf に読ませないため）
        json=$(sf org list metadata --metadata-type "$t" --target-org "$org" --json 2>/dev/null </dev/null) || json=""
        st=$(json_get "$json" status 2>/dev/null) || st=""  # VAR=$(cmd) のため run 不使用
        if [[ "$st" != "0" ]]; then
            log "WARNING" "  ${t}: 組織にあるかを確かめられませんでした（一覧が取れません）。削除の対象から外しません。"
            continue
        fi
        # 組織にある名前（小文字にする）。result が配列でないときは、1 件のオブジェクトとして読む
        names=$( { json_get "$json" 'result.*.fullName'; json_get "$json" 'result.fullName'; } 2>/dev/null \
            | awk 'NF' | tr '[:upper:]' '[:lower:]')  # VAR=$(cmd) のため run 不使用
        while IFS= read -r p; do
            [[ "${p%%:*}" == "$t" ]] || continue
            m="${p#*:}"
            [[ "$m" =~ ^[A-Za-z0-9_.-]+$ ]] || continue  # * や、書き方が違いうる名前は、確かめない（ある、とみなす）
            lm=$(printf '%s' "$m" | tr '[:upper:]' '[:lower:]')  # VAR=$(cmd) のため run 不使用
            printf '%s\n' "$names" | grep -qxF "$lm" || printf '%s\n' "$p"  # 条件チェック（一覧になければ、ない）
        done <<< "$pairs"
    done <<< "$types" | LC_ALL=C sort -u
    return $RET_OK
}

# manifest_drop_pairs - マニフェストから、指定の「種類:メンバー」を除く（その種類のメンバーがなくなれば、<types> ごと除く）
# ------------------------------------------------------------------------------
# 【使い方】 manifest_drop_pairs XML LIST   LIST は、1 行に 1 つの「種類:メンバー」（manifest_missing_in_org の出力）
# 【動作】   merge_package_xml と同じ読み方（各 <types> の <members> を、次の <name> の種類のものとする）。
#           <types> の外の行（<version> など）は、そのまま残す。書き換えは、一時ファイルに書いてから置き換える
# 【戻り値】 0 = 書き換えた / 1 = 読めない・書けない（XML は、元のまま）
# ------------------------------------------------------------------------------
manifest_drop_pairs() {
    local xml="$1" list="$2" tmp
    [[ -f "$xml" && -r "$xml" && -f "$list" && -r "$list" ]] || return $RET_NG
    tmp="${xml}.drop.tmp"
    # run 不使用: XML の書き換え（awk の出力を、一時ファイルへ）
    awk -v list="$list" '
        BEGIN { while ((getline l < list) > 0) if (l != "") d[l] = 1 }
        /<types>/   { in_t = 1; n = 0; next }
        in_t && /<members>/ { s = $0; sub(/^[[:space:]]*<members>/, "", s); sub(/<\/members>[[:space:]]*$/, "", s); m[n++] = s; next }
        in_t && /<name>/    { t = $0; sub(/^[[:space:]]*<name>/, "", t); sub(/<\/name>[[:space:]]*$/, "", t); next }
        in_t && /<\/types>/ {
            out = ""; k = 0
            for (i = 0; i < n; i++) if (!((t ":" m[i]) in d)) { out = out "        <members>" m[i] "</members>\n"; k++ }
            if (k > 0) printf "    <types>\n%s        <name>%s</name>\n    </types>\n", out, t
            in_t = 0; next
        }
        in_t { next }
        { print }
    ' "$xml" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return $RET_NG; }  # run 不使用: 失敗の後始末
    mv -f "$tmp" "$xml" 2>/dev/null || { rm -f "$tmp"; return $RET_NG; }  # run 不使用: 置き換え
    return $RET_OK
}
