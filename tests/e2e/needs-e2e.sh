#!/bin/bash
# ==============================================================================
# needs-e2e.sh - rr の前に、e2e が必要かを判定する（git の差分だけを見る。読み取りのみ）
# ==============================================================================
# e2e（GitHub Actions の e2e.yml。実環境の通し検証）は、1 回で、テスト用の組織の無料枠（月 2,000 分）を約 40 分ぶん使うため、
# mm（development への push）では動かさず、rr の最初の手順として、1 回だけ動かす（CLAUDE.md 1.2・1.3.2）。
# このスクリプトで「必要」と出たときだけ、rr の前に e2e を動かし、成功を確認する。
# 「e2e の対象のパス」の定義は、このスクリプトが正本（CLAUDE.md・dev-guide.md・dev-reference.md は、ここを指す）。
#
# 【対象のパス】
#   配布物 bin/ lib/ phases/ hooks/ templates/ config/ と、e2e 自体 tests/e2e/ .github/workflows/e2e.yml。
#   ただし、リリース・削除の流れから呼ばれない次の 4 ファイルは除く（変えても、e2e の結果が変わらないため）:
#     bin/sf-metasync.sh  bin/sf-upgrade.sh  lib/metasync.js  config/metasync-detect.txt
#   文書（doc/ site/ *.md）・単体テスト（tests/ の tests/e2e/ 以外）・.github/workflows/test.yml だけの変更は、対象外
#
# 【使い方】
#   bash tests/e2e/needs-e2e.sh [BASE [HEAD]]          # BASE...HEAD の差分（既定: origin/main と origin/development）
#   bash tests/e2e/needs-e2e.sh --last-change [HEAD]   # HEAD（既定 origin/development）までで、対象のパスを最後に変えたコミット
#
# 【出力と戻り値】
#   差分モード: 対象のパスで変わったファイルを、1 行に 1 つ表示する
#     0 = 変更あり（e2e が必要） / 1 = 変更なし（e2e は不要） / 2 = 引数・git のエラー
#   --last-change: そのコミットの SHA を 1 行表示する
#     0 = 表示した / 1 = 対象のパスを変えたコミットがない / 2 = 引数・git のエラー
#   e2e が成功済みかは、その SHA 以降の実行が success かで判定する（dev-reference.md 9.3）
#
# 【オプション】
#   -h, --help : このヘルプを表示する
# ==============================================================================

# 対象のパス（正本）と、除外の 4 ファイル。変えたら、tests/test_e2e.sh の確認も、CLAUDE.md などの説明も直す
E2E_TARGET_PATHS=(bin lib phases hooks templates config tests/e2e .github/workflows/e2e.yml)
E2E_EXCLUDE_PATHS=(bin/sf-metasync.sh bin/sf-upgrade.sh lib/metasync.js config/metasync-detect.txt)

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    awk '/^# ==/{f++; next} f==2{sub(/^# ?/,""); print} f==3{exit}' "${BASH_SOURCE[0]}"  # run 不使用: 設定の読み込み前に、ヘルプを出して終わるため
    exit 0
fi

# このスクリプトのあるリポジトリ（tests/e2e/ の 2 つ上）の中で、git を動かす
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 2  # run 不使用: 判定結果だけを標準出力に出すスクリプトのため

# git の絞り込み指定（pathspec）: 対象のパス + 除外（:!パス）
SPEC=("${E2E_TARGET_PATHS[@]}")
for _ex in "${E2E_EXCLUDE_PATHS[@]}"; do SPEC+=(":!${_ex}"); done

if [[ "${1:-}" == "--last-change" ]]; then
    [[ $# -le 2 ]] || { echo "引数が多すぎます（--last-change [HEAD]）" >&2; exit 2; }
    head_ref="${2:-origin/development}"
    # run 不使用: 結果を標準出力で受け取るため（失敗は、終了コードで判定する）
    if ! sha=$(git log -1 --format=%H "$head_ref" -- "${SPEC[@]}" 2>/dev/null); then
        echo "git log に失敗しました（${head_ref}）" >&2; exit 2
    fi
    [[ -n "$sha" ]] || exit 1
    echo "$sha"
    exit 0
fi

if [[ "${1:-}" == -* ]]; then
    echo "不明なオプションです: $1（-h で使い方を表示します）" >&2; exit 2
fi
[[ $# -le 2 ]] || { echo "引数が多すぎます（[BASE [HEAD]]）" >&2; exit 2; }

base_ref="${1:-origin/main}"
head_ref="${2:-origin/development}"
# run 不使用: 結果を標準出力で受け取るため（失敗は、終了コードで判定する）
if ! files=$(git diff --name-only "${base_ref}...${head_ref}" -- "${SPEC[@]}" 2>/dev/null); then
    echo "git diff に失敗しました（${base_ref}...${head_ref}）" >&2; exit 2
fi
if [[ -n "$files" ]]; then
    echo "$files"
    exit 0
fi
exit 1
