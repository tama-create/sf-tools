#!/bin/bash
# ==============================================================================
# ci-fixture.sh - GitHub Actions 上で、e2e の鍵一式（~/.sf-tools-e2e/fixture.env）を、環境変数から作る
# ==============================================================================
# .github/workflows/e2e.yml が、Secrets / Variables を環境変数に渡して、これを実行する。
# 必須の値が 1 つでも空なら、値は出さずに、変数名だけを表示して終了する（Secret の登録漏れを、すぐ分かるようにする）。
# GitHub Actions 上だけで動く（手元の鍵一式は、bootstrap.sh が作る。上書きしないため）。
#
# 【環境変数】（必須）E2E_OWNER E2E_GH_USER E2E_SLACK_CHANNEL_ID E2E_PAT_TOKEN E2E_SLACK_BOT_TOKEN E2E_SFDX_AUTH_URL
#             （任意）E2E_SFDX_AUTH_URL_STG E2E_SFDX_AUTH_URL_DEV（--add-tier・2 層・3 層の確認に必要）
# ==============================================================================
set -u

if [[ "${GITHUB_ACTIONS:-}" != "true" ]]; then
    echo "ci-fixture.sh は、GitHub Actions 上だけで動きます（手元の鍵一式は、bootstrap.sh が作ります）。" >&2
    exit 1
fi

missing=""
for v in E2E_OWNER E2E_GH_USER E2E_SLACK_CHANNEL_ID E2E_PAT_TOKEN E2E_SLACK_BOT_TOKEN E2E_SFDX_AUTH_URL; do
    [[ -n "${!v:-}" ]] || missing="${missing} ${v}"
done
if [[ -n "$missing" ]]; then
    echo "Secrets / Variables が未登録、または空です（値は表示しません）:${missing}" >&2
    echo "Settings → Environments → e2e に登録してください（.github/workflows/e2e.yml の冒頭を参照）。" >&2
    exit 1
fi

dir="$HOME/.sf-tools-e2e"
file="${dir}/fixture.env"
mkdir -p "$dir"  # run 不使用: common.sh を読まない単独のスクリプト（Actions の手順の準備のみ）
( umask 077
  {
      printf 'E2E_OWNER=%q\n'            "$E2E_OWNER"
      printf 'E2E_GH_USER=%q\n'          "$E2E_GH_USER"
      printf 'E2E_HOME_ROOT=%q\n'        "$HOME/e2e-home"
      printf 'E2E_PAT_TOKEN=%q\n'        "$E2E_PAT_TOKEN"
      printf 'E2E_SLACK_BOT_TOKEN=%q\n'  "$E2E_SLACK_BOT_TOKEN"
      printf 'E2E_SLACK_CHANNEL_ID=%q\n' "$E2E_SLACK_CHANNEL_ID"
      printf 'E2E_SFDX_AUTH_URL=%q\n'    "$E2E_SFDX_AUTH_URL"
      [[ -z "${E2E_SFDX_AUTH_URL_STG:-}" ]] || printf 'E2E_SFDX_AUTH_URL_STG=%q\n' "$E2E_SFDX_AUTH_URL_STG"
      [[ -z "${E2E_SFDX_AUTH_URL_DEV:-}" ]] || printf 'E2E_SFDX_AUTH_URL_DEV=%q\n' "$E2E_SFDX_AUTH_URL_DEV"
  } > "$file"
)
chmod 600 "$file"  # run 不使用: 同上（鍵一式を本人だけが読めるようにする）
mkdir -p "$HOME/e2e-home"  # run 不使用: 同上（作業フォルダの root）
echo "鍵一式を作りました: ${file}（値は表示しません）"
