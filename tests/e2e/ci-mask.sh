#!/bin/bash
# ==============================================================================
# ci-mask.sh - GitHub Actions 上で、組織の ID・ユーザー名・My Domain の URL などを、公開ログに出さないよう、伏せる
# ==============================================================================
# .github/workflows/e2e.yml が、e2e の実行の前に、これを実行する（sf のインストールと、鍵一式の作成のあと）。
# sf-tools は公開リポジトリのため、Actions のログは誰でも読める。sf のログイン時の表示などに、組織のユーザー名・組織 ID・
# My Domain の URL が出る。GitHub は、Secret に登録した値だけを伏せるため、ここで、テスト用の組織（main・staging・develop）に
# 一度ログインして、その ID・ユーザー名・URL・アクセストークンを調べ、「::add-mask::」で、以降のログで伏せる。
# 調べたあとは、ログインを外す（sf の状態を、元に戻す）。値そのものは、何も表示しない。
# GitHub Actions 上だけで動く。
#
# 【環境変数】（任意）E2E_SFDX_AUTH_URL E2E_SFDX_AUTH_URL_STG E2E_SFDX_AUTH_URL_DEV（ある組織だけ処理する）
# ==============================================================================
set -u

if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
    echo "ci-mask.sh は、GitHub Actions 上だけで動きます。" >&2
    exit 1
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/e2e-mask.XXXXXX") || { echo "一時フォルダを作成できません。" >&2; exit 1; }  # VAR=$(cmd) のため run 不使用: common.sh を読まない単独のスクリプト
trap 'rm -rf "$work"' EXIT  # run 不使用: 一時フォルダ（認証 URL のファイル）の後始末

# 標準入力の JSON（sf org display --json）から、伏せる値を、1 行に 1 つ出力する
_values() {
    node -e '
        let s = ""; process.stdin.on("data", d => s += d).on("end", () => {
            let r; try { r = JSON.parse(s).result || {}; } catch (e) { return; }
            const out = [];
            if (r.id) { out.push(r.id); out.push(String(r.id).slice(0, 15)); }
            if (r.username) out.push(r.username);
            if (r.accessToken) out.push(r.accessToken);
            if (r.instanceUrl) { out.push(r.instanceUrl); try { out.push(new URL(r.instanceUrl).host); } catch (e) {} }
            if (r.alias) out.push(r.alias);
            out.filter(v => v && v.length >= 4 && !/[\r\n]/.test(v)).forEach(v => console.log(v));
        });
    '
}

count=0
for tier in "" _STG _DEV; do
    var="E2E_SFDX_AUTH_URL${tier}"
    url="${!var:-}"
    [[ -n "$url" ]] || continue
    alias="e2e-mask-probe${tier}"
    file="${work}/url${tier}"
    ( umask 077; printf '%s' "$url" > "$file" )
    if sf org login sfdx-url --sfdx-url-file "$file" --alias "$alias" > /dev/null 2>&1; then  # 条件チェック（出力は捨てる）
        json=$(sf org display --target-org "$alias" --json 2>/dev/null) || json=""  # VAR=$(cmd) のため run 不使用（値を出さない）
        while IFS= read -r v; do
            echo "::add-mask::${v}"
            count=$(( count + 1 ))
        done < <(printf '%s' "$json" | _values)
        sf org logout --target-org "$alias" --no-prompt > /dev/null 2>&1 || true  # 後始末（失敗しても続行）
    else
        echo "組織${tier:-（main）}にログインできなかったため、その組織の値は伏せられません（e2e の実行の中で、同じ原因で失敗する可能性があります）。"
    fi
    rm -f "$file"  # run 不使用: 認証 URL のファイルの削除
done
echo "ログに出さない値を ${count} 件、伏せるように登録しました（値は表示しません）。"
